import CoreGraphics
import Foundation
import GhosttyKit

/// Manages the lifetime of pane-preview image requests for a single open
/// instance of the panes sheet.
///
/// Owned by the parent (`GhosttySurfaceScreen`), created at the moment of
/// `showPanes()` tap, and explicitly torn down via `cancelAll()` from the
/// sheet's `onDismiss`.
///
/// Architecture invariants for preview request ownership:
///
/// - The session is frozen to the **opening logical top-level**. Pane
///   membership within that top-level may update via `reconcile(leafIDs:)`
///   from the sheet. If Ghostty rebuilds that logical top-level with new
///   surface IDs, the parent may call `retarget(topLevelID:leafIDs:)` to keep
///   the sheet attached to the replacement tree.
/// - The C preview request handle is held by the session for each pane in
///   `.pending` state. Every transition out of `.pending` (deliver / cancel /
///   reconcile-removal) releases that handle exactly once via
///   `dropRequest(for:)`.
/// - Pixel buffers are copied into Swift-owned memory in the C callback,
///   then `ghostty_surface_free_preview_image` is called immediately. The
///   resulting `CGImage` owns the Swift copy via a `CGDataProvider` whose
///   release callback frees the buffer. This avoids the Ghostty allocator
///   lifetime hazard at app teardown.
/// - The C callback hops to MainActor before mutating session state, and
///   verifies session liveness + generation match before building a CGImage
///   it would otherwise immediately discard.
///
/// Inline kitty/sixel graphics are not represented in v1 thumbnails; only
/// text, cursor, and colors are included.
@MainActor
final class GhosttyPanePreviewSession: ObservableObject {
    private static let transientRetryAttempts = 6
    private static let transientRetryDelay: Duration = .milliseconds(180)

    enum PreviewStartResult {
        case started(ghostty_surface_preview_request_t)
        case surfaceUnavailable
        case rejected
    }

    struct PreviewRequestClient {
        typealias Start = @MainActor (
            UUID,
            ghostty_surface_preview_image_options_s,
            UnsafeMutableRawPointer?,
            ghostty_surface_preview_image_callback_f
        ) -> PreviewStartResult

        let start: Start
        let cancel: @MainActor (ghostty_surface_preview_request_t) -> Void
        let release: @MainActor (ghostty_surface_preview_request_t) -> Void
    }

    /// Per-pane preview state observed by the panes sheet. The `failed` case
    /// preserves the raw Ghostty status so future UI can disambiguate
    /// surface-closed vs invalid-options vs render-failed.
    enum PreviewState {
        case pending
        case ready(CGImage)
        case failed(ghostty_surface_preview_status_e)
    }

    let id = UUID()

    /// Top-level (window) this session is currently bound to.
    @Published private(set) var topLevelID: UUID

    @Published private(set) var imagesByPaneID: [UUID: PreviewState] = [:]

    private weak var registry: GhosttyRuntimeSurfaceRegistry?
    private let displayScale: CGFloat
    private let previewRequestClient: PreviewRequestClient?
    private let retryDelay: Duration
    private var pendingRequests: [UUID: ghostty_surface_preview_request_t] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0

    init(
        topLevelID: UUID,
        leafIDs: [UUID],
        registry: GhosttyRuntimeSurfaceRegistry,
        scale: CGFloat = PanePreviewLayout.currentScale()
    ) {
        self.topLevelID = topLevelID
        self.registry = registry
        self.displayScale = scale
        self.previewRequestClient = nil
        self.retryDelay = Self.transientRetryDelay
        startInitialRequests(leafIDs: leafIDs)
    }

    init(
        topLevelID: UUID,
        leafIDs: [UUID],
        scale: CGFloat = PanePreviewLayout.currentScale(),
        retryDelay: Duration? = nil,
        previewRequestClient: PreviewRequestClient
    ) {
        self.topLevelID = topLevelID
        self.registry = nil
        self.displayScale = scale
        self.previewRequestClient = previewRequestClient
        self.retryDelay = retryDelay ?? Self.transientRetryDelay
        startInitialRequests(leafIDs: leafIDs)
    }

    private func startInitialRequests(leafIDs: [UUID]) {
        for paneID in leafIDs {
            startRequest(
                for: paneID,
                paneCount: max(1, leafIDs.count),
                remainingRetryAttempts: Self.transientRetryAttempts
            )
        }
    }

    // No `deinit` cleanup: under Swift 6 isolation, deinit runs on whatever
    // thread releases the last reference and cannot touch @MainActor state.
    // The parent contract is to call `cancelAll()` from the sheet's
    // `onDismiss` before dropping this object. The userdata box's weak self
    // ensures any callback that fires after deinit no-ops cleanly; what we'd
    // lose if a parent forgets `cancelAll()` is the Ghostty-side request
    // handle release — small leak, fixable in caller.

    // MARK: - Public API

    /// Reconcile in-flight requests against an updated leaf ID set within
    /// the frozen top-level. Adds requests for new panes, cancels+releases
    /// requests for removed panes. Existing pending requests are untouched.
    func reconcile(leafIDs: [UUID]) {
        let newSet = Set(leafIDs)
        let currentSet = Set(imagesByPaneID.keys)
        let paneCount = max(1, leafIDs.count)

        for removedID in currentSet.subtracting(newSet) {
            dropRequest(for: removedID)
            imagesByPaneID.removeValue(forKey: removedID)
        }
        for retainedID in currentSet.intersection(newSet) {
            guard shouldRetryPreview(for: retainedID) else { continue }
            startRequest(
                for: retainedID,
                paneCount: paneCount,
                remainingRetryAttempts: Self.transientRetryAttempts
            )
        }
        for addedID in newSet.subtracting(currentSet) {
            startRequest(
                for: addedID,
                paneCount: paneCount,
                remainingRetryAttempts: Self.transientRetryAttempts
            )
        }
    }

    /// Rebind this session to a replacement runtime tree for the same logical
    /// top-level, then reconcile previews against the replacement leaves.
    func retarget(topLevelID: UUID, leafIDs: [UUID]) {
        self.topLevelID = topLevelID
        reconcile(leafIDs: leafIDs)
    }

    /// Cancel every in-flight request and release each handle. Bumps
    /// generation so any callback already past the C side becomes stale on
    /// arrival. Safe to call multiple times. Does not clear
    /// `imagesByPaneID` so currently-displayed previews remain visible
    /// while the sheet animates out.
    func cancelAll() {
        generation &+= 1
        for task in retryTasks.values {
            task.cancel()
        }
        retryTasks.removeAll()
        for paneID in Array(pendingRequests.keys) {
            dropRequest(for: paneID)
        }
    }

    // MARK: - Internal: request lifecycle

    private func startRequest(
        for paneID: UUID,
        paneCount: Int,
        remainingRetryAttempts: Int
    ) {
        guard pendingRequests[paneID] == nil else { return }
        cancelRetry(for: paneID)

        let pixelBudget = PanePreviewLayout.physicalPixelBudget(
            paneCount: paneCount,
            scale: displayScale
        )

        let options = ghostty_surface_preview_image_options_s(
            max_width_px: pixelBudget.width,
            max_height_px: pixelBudget.height,
            include_cursor: true
        )

        let box = PreviewCallbackBox(
            session: self,
            paneID: paneID,
            generation: generation
        )
        let userdata = Unmanaged.passRetained(box).toOpaque()

        switch startPreviewRequest(
            paneID: paneID,
            options: options,
            userdata: userdata
        ) {
        case .started(let request):
            pendingRequests[paneID] = request
            imagesByPaneID[paneID] = .pending

        case .surfaceUnavailable:
            Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).release()
            imagesByPaneID[paneID] = .failed(GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED)
            scheduleRetry(
                for: paneID,
                paneCount: paneCount,
                remainingRetryAttempts: remainingRetryAttempts
            )

        case .rejected:
            // Synchronous rejection (e.g., immediate alloc failure). Reclaim
            // the box we just retained and mark the pane failed.
            Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).release()
            imagesByPaneID[paneID] = .failed(GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED)
            scheduleRetry(
                for: paneID,
                paneCount: paneCount,
                remainingRetryAttempts: remainingRetryAttempts
            )
        }
    }

    /// Cancel-and-release the C request handle for a pane. Ownership rule:
    /// any caller that transitions a pane out of `.pending` MUST go through
    /// this method to release the handle exactly once.
    private func dropRequest(for paneID: UUID) {
        cancelRetry(for: paneID)
        guard let request = pendingRequests.removeValue(forKey: paneID) else {
            return
        }
        cancelPreviewRequest(request)
        releasePreviewRequest(request)
    }

    /// Called from the C callback after main-actor hop. The callback has
    /// already done generation/liveness checks and built (or chose not to
    /// build) a CGImage. We finalize state and release the handle.
    fileprivate func deliver(
        paneID: UUID,
        generation: UInt64,
        status: ghostty_surface_preview_status_e,
        image: CGImage?
    ) {
        guard generation == self.generation else { return }
        guard pendingRequests[paneID] != nil else { return }

        // Release the handle exactly once on transition out of `.pending`.
        if let request = pendingRequests.removeValue(forKey: paneID) {
            releasePreviewRequest(request)
        }

        if status == GHOSTTY_SURFACE_PREVIEW_STATUS_OK, let image = image {
            imagesByPaneID[paneID] = .ready(image)
        } else {
            imagesByPaneID[paneID] = .failed(status)
        }
    }

    fileprivate var currentGeneration: UInt64 { generation }

    private func shouldRetryPreview(for paneID: UUID) -> Bool {
        guard pendingRequests[paneID] == nil else { return false }

        switch imagesByPaneID[paneID] {
        case .failed(let status):
            return status == GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED ||
                status == GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED

        default:
            return false
        }
    }

    private func scheduleRetry(
        for paneID: UUID,
        paneCount: Int,
        remainingRetryAttempts: Int
    ) {
        guard remainingRetryAttempts > 0 else { return }
        guard imagesByPaneID[paneID] != nil else { return }

        cancelRetry(for: paneID)
        let retryDelay = retryDelay
        retryTasks[paneID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
            guard let self else { return }

            retryTasks[paneID] = nil
            guard imagesByPaneID[paneID] != nil else { return }
            guard pendingRequests[paneID] == nil else { return }

            startRequest(
                for: paneID,
                paneCount: max(paneCount, imagesByPaneID.count),
                remainingRetryAttempts: remainingRetryAttempts - 1
            )
        }
    }

    private func cancelRetry(for paneID: UUID) {
        retryTasks.removeValue(forKey: paneID)?.cancel()
    }

    private func startPreviewRequest(
        paneID: UUID,
        options: ghostty_surface_preview_image_options_s,
        userdata: UnsafeMutableRawPointer?
    ) -> PreviewStartResult {
        if let previewRequestClient {
            return previewRequestClient.start(paneID, options, userdata, previewImageCallback)
        }

        guard let managed = registry?.managedSurface(for: paneID) else {
            return .surfaceUnavailable
        }

        guard let request = managed.controlSurface.renderPreviewImageAsync(
            options: options,
            userdata: userdata,
            callback: previewImageCallback
        ) else {
            return .rejected
        }

        return .started(request)
    }

    private func cancelPreviewRequest(_ request: ghostty_surface_preview_request_t) {
        if let previewRequestClient {
            previewRequestClient.cancel(request)
        } else {
            GhosttyKitControlSurface.cancelPreviewRequest(request)
        }
    }

    private func releasePreviewRequest(_ request: ghostty_surface_preview_request_t) {
        if let previewRequestClient {
            previewRequestClient.release(request)
        } else {
            GhosttyKitControlSurface.releasePreviewRequest(request)
        }
    }
}

// MARK: - Callback box (heap-allocated, FFI-bridged)

/// Userdata payload retained across the FFI boundary. Heap-allocated on
/// `Unmanaged.passRetained` at submit time and consumed by
/// `Unmanaged.takeRetainedValue` at the start of the callback. Holds a weak
/// session reference so a callback that arrives after the session is gone
/// no-ops cleanly without touching freed state.
///
/// Sendability: `@unchecked Sendable` because `paneID`/`generation` are
/// immutable Sendable values and the weak `session` reference is only
/// dereferenced on the MainActor (after the hop in `previewImageCallback`).
/// We never touch `session.someProperty` from the Ghostty preview thread.
/// Sendable wrapper for an `UnsafeMutableRawPointer?` so we can hop a pixel
/// buffer from the Ghostty preview thread into a `@MainActor` Task without
/// running afoul of Swift 6 strict isolation. Safety is enforced by the
/// callback pipeline: the buffer is allocated, populated, and sent exactly
/// once; only the receiving MainActor closure dereferences or deallocates.
private struct SendablePixelBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
}

private final class PreviewCallbackBox: @unchecked Sendable {
    weak var session: GhosttyPanePreviewSession?
    let paneID: UUID
    let generation: UInt64

    init(session: GhosttyPanePreviewSession, paneID: UUID, generation: UInt64) {
        self.session = session
        self.paneID = paneID
        self.generation = generation
    }
}

// MARK: - C callback (runs on Ghostty's preview thread)

/// File-scope `let` so the function pointer address is stable for the C ABI.
/// Closures with captures cannot be passed as `@convention(c)` callbacks.
///
/// Responsibilities, in order:
/// 1. Take ownership of the userdata box (balances `passRetained` on submit).
/// 2. Capture image metadata (width/height/stride/status) into local
///    constants, copy pixels into a Swift-owned buffer, then call
///    `ghostty_surface_free_preview_image` immediately.
/// 3. Hop to MainActor; verify session liveness + generation match.
/// 4. Build a `CGImage` from the Swift-owned copy if status is OK; otherwise
///    deallocate the copy.
/// 5. Hand off to the session's `deliver` for state transition.
private let previewImageCallback: ghostty_surface_preview_image_callback_f = { userdata, status, image in
    guard let userdata else { return }
    let box = Unmanaged<PreviewCallbackBox>.fromOpaque(userdata).takeRetainedValue()

    // Capture metadata before freeing the Ghostty buffer.
    let width = image.width
    let height = image.height
    let stride = image.stride
    let pixelStatus = status

    var pixelCopy: UnsafeMutableRawPointer?
    var byteCount = 0

    if pixelStatus == GHOSTTY_SURFACE_PREVIEW_STATUS_OK,
       let sourcePixels = image.pixels,
       height > 0,
       stride > 0 {
        byteCount = Int(stride) * Int(height)
        let copy = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        copy.copyMemory(from: sourcePixels, byteCount: byteCount)
        pixelCopy = copy
    }

    // Always free the Ghostty-owned image regardless of status. Safe on a
    // zeroed image.
    var mutableImage = image
    GhosttyKitControlSurface.freePreviewImage(&mutableImage)

    // Capture immutable values for the MainActor hop. `box` is Sendable
    // (declared @unchecked above); paneID/generation are primitive
    // Sendable values; raw pointers go through a Sendable wrapper.
    let capturedBox = box
    let capturedPixelBuffer = SendablePixelBuffer(pointer: pixelCopy)
    let capturedPaneID = box.paneID
    let capturedGeneration = box.generation

    Task { @MainActor in
        // Local mutable copy so makeCGImage can null it out on ownership
        // transfer to a CGDataProvider.
        var localPixelCopy = capturedPixelBuffer.pointer

        // Stale check: session gone, or generation mismatch, or pane already
        // removed via reconcile.
        guard let session = capturedBox.session else {
            localPixelCopy?.deallocate()
            return
        }
        guard session.currentGeneration == capturedGeneration else {
            localPixelCopy?.deallocate()
            return
        }
        guard session.imagesByPaneID[capturedPaneID] != nil else {
            localPixelCopy?.deallocate()
            return
        }

        let cgImage = makeCGImage(
            pixelCopy: &localPixelCopy,
            width: width,
            height: height,
            stride: stride
        )

        // makeCGImage sets localPixelCopy to nil iff ownership transferred
        // into a CGDataProvider. Otherwise we still own it.
        localPixelCopy?.deallocate()

        session.deliver(
            paneID: capturedPaneID,
            generation: capturedGeneration,
            status: pixelStatus,
            image: cgImage
        )
    }
}

/// Build a CGImage from a Swift-owned BGRA8 sRGB pixel buffer.
///
/// On success: ownership of `pixelCopy` transfers to the returned CGImage's
/// data provider, and `pixelCopy` is set to nil so the caller does not
/// double-free. On failure: `pixelCopy` is left untouched for the caller to
/// deallocate.
private func makeCGImage(
    pixelCopy: inout UnsafeMutableRawPointer?,
    width: UInt32,
    height: UInt32,
    stride: UInt32
) -> CGImage? {
    guard let copy = pixelCopy, width > 0, height > 0, stride > 0 else {
        return nil
    }
    let byteCount = Int(stride) * Int(height)

    guard let provider = CGDataProvider(
        dataInfo: copy,
        data: copy,
        size: byteCount,
        releaseData: { _, ptr, _ in
            UnsafeMutableRawPointer(mutating: ptr).deallocate()
        }
    ) else {
        return nil
    }
    // Provider now owns the buffer. Whether or not CGImage construction
    // succeeds, the provider going out of scope (or being released by a
    // CGImage that retained it) frees the buffer via the release callback.
    pixelCopy = nil

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        return nil
    }

    return CGImage(
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: Int(stride),
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}
