import CoreGraphics
import Foundation
import GhosttyKit
import SwiftUI
import UIKit

enum TerminalThemePreviewSample {
    static func output(for theme: TerminalTheme) -> Data {
        Data(sample(for: theme).utf8)
    }

    private static let esc = "\u{1B}["
    private static let reset = "\(esc)0m"

    private static func sample(for _: TerminalTheme) -> String {
        paletteSample()
    }

    private static func paletteSample() -> String {
        [
            "\(esc)2J\(esc)H\(esc)?25h",
            paletteCodeLine(number: 1, segments: [
                PaletteRun("#include ", "\(esc)34m"),
                PaletteRun("<iostream>", "\(esc)32m"),
            ]),
            paletteCodeLine(number: 2, segments: []),
            paletteCodeLine(number: 3, segments: [
                PaletteRun("int", "\(esc)33m"),
                PaletteRun(" main() {", reset),
            ]),
            paletteCodeLine(number: 4, segments: [
                PaletteRun("    std::cout << ", reset),
                PaletteRun("\"remux\"", "\(esc)32m"),
                PaletteRun(";", reset),
            ]),
            paletteCodeLine(number: 5, segments: [
                PaletteRun("}", reset),
            ], terminator: ""),
            "\(esc)6;1H\(esc)44;30m NORMAL \(esc)48;5;8;37m test.cpp \(esc)K\(reset)",
            "\(esc)4;28H",
        ].joined()
    }

    private struct PaletteRun {
        let text: String
        let sgr: String

        init(_ text: String, _ sgr: String) {
            self.text = text
            self.sgr = sgr
        }
    }

    private static func paletteCodeLine(
        number: Int,
        segments: [PaletteRun],
        terminator: String = "\r\n"
    ) -> String {
        var line = "\(reset)\(esc)K\(esc)38;5;8m\(number) "
        for segment in segments {
            line += "\(segment.sgr)\(segment.text)"
        }
        return "\(line)\(reset)\(terminator)"
    }
}

struct TerminalThemePreviewRenderRequest: Equatable {
    let settings: TerminalSettings
    let pointSize: CGSize
    let scale: CGFloat
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init?(settings: TerminalSettings, pointSize: CGSize, scale: CGFloat) {
        let safeWidth = pointSize.width.rounded(.down)
        let safeHeight = pointSize.height.rounded(.down)
        guard safeWidth.isFinite, safeWidth > 0,
              safeHeight.isFinite, safeHeight > 0
        else {
            return nil
        }

        let safeScale = max(scale.isFinite && scale > 0 ? scale : 1, 1)
        let metrics = GhosttySurfaceDisplayMetrics(
            size: CGSize(width: safeWidth, height: safeHeight),
            scale: safeScale
        )

        self.settings = settings
        self.pointSize = CGSize(width: safeWidth, height: safeHeight)
        self.scale = safeScale
        self.pixelWidth = metrics.pixelWidth
        self.pixelHeight = metrics.pixelHeight
    }
}

@MainActor
final class TerminalThemePreviewRenderer: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(CGImage)
        case failed
    }

    @Published private(set) var state: State = .idle

    private var currentRequest: TerminalThemePreviewRenderRequest?
    private var renderTask: Task<Void, Never>?

    deinit {
        renderTask?.cancel()
    }

    func render(settings: TerminalSettings, pointSize: CGSize, scale: CGFloat) {
        guard let request = TerminalThemePreviewRenderRequest(
            settings: settings,
            pointSize: pointSize,
            scale: scale
        ) else {
            renderTask?.cancel()
            currentRequest = nil
            state = .idle
            return
        }

        guard request != currentRequest else { return }

        currentRequest = request
        renderTask?.cancel()
        state = .loading

        renderTask = Task { @MainActor [weak self] in
            do {
                let image = try await TerminalThemePreviewImageRenderer.renderImage(for: request)
                guard !Task.isCancelled, self?.currentRequest == request else { return }
                self?.state = .ready(image)
            } catch {
                guard !Task.isCancelled, self?.currentRequest == request else { return }
                self?.state = .failed
            }
        }
    }
}

enum TerminalThemePreviewImageRenderer {
    enum RenderError: Error {
        case outputRejected
        case requestRejected
        case renderFailed
    }

    @MainActor
    static func renderImage(for request: TerminalThemePreviewRenderRequest) async throws -> CGImage {
        let view = GhosttyKitSurfaceView(
            frame: CGRect(origin: .zero, size: request.pointSize)
        )
        view.contentScaleFactor = request.scale
        view.applyTerminalTheme(request.settings.theme)

        let runtime = try GhosttyKitRuntime(terminalSettings: request.settings)
        let surface = try runtime.makeManualHostSurface(
            view: view,
            initialSize: request.pointSize
        )

        guard surface.processOutput(TerminalThemePreviewSample.output(for: request.settings.theme)) else {
            surface.setBackingExited(true)
            throw RenderError.outputRejected
        }

        return try await withCheckedThrowingContinuation { continuation in
            let lease = GhosttyPreviewRequestLease(
                cancel: { GhosttyKitControlSurface.cancelPreviewRequest($0) },
                release: { GhosttyKitControlSurface.releasePreviewRequest($0) }
            )
            let box = TerminalThemePreviewCallbackBox(
                continuation: continuation,
                surface: surface,
                view: view,
                runtime: runtime,
                requestLease: lease
            )
            let userdata = Unmanaged.passRetained(box).toOpaque()
            let options = ghostty_surface_preview_image_options_s(
                max_width_px: request.pixelWidth,
                max_height_px: request.pixelHeight,
                include_cursor: true
            )

            guard let previewRequest = surface.renderPreviewImageAsync(
                options: options,
                userdata: userdata,
                callback: terminalThemePreviewImageCallback
            ) else {
                Unmanaged<TerminalThemePreviewCallbackBox>.fromOpaque(userdata).release()
                surface.setBackingExited(true)
                continuation.resume(throwing: RenderError.requestRejected)
                return
            }

            lease.install(previewRequest)
        }
    }
}

private final class TerminalThemePreviewCallbackBox: @unchecked Sendable {
    let continuation: CheckedContinuation<CGImage, Error>
    let surface: GhosttyKitControlSurface
    let view: GhosttyKitSurfaceView
    let runtime: GhosttyKitRuntime
    let requestLease: GhosttyPreviewRequestLease

    init(
        continuation: CheckedContinuation<CGImage, Error>,
        surface: GhosttyKitControlSurface,
        view: GhosttyKitSurfaceView,
        runtime: GhosttyKitRuntime,
        requestLease: GhosttyPreviewRequestLease
    ) {
        self.continuation = continuation
        self.surface = surface
        self.view = view
        self.runtime = runtime
        self.requestLease = requestLease
    }

    @MainActor
    func complete(
        pixelStatus: ghostty_surface_preview_status_e,
        pixelCopy: GhosttyPreviewPixelBuffer,
        width: UInt32,
        height: UInt32,
        stride: UInt32
    ) {
        var localPixelCopy = pixelCopy.pointer
        requestLease.release()
        defer {
            localPixelCopy?.deallocate()
            surface.setBackingExited(true)
            withExtendedLifetime(view) {}
            withExtendedLifetime(runtime) {}
        }

        guard pixelStatus == GHOSTTY_SURFACE_PREVIEW_STATUS_OK,
              let image = GhosttyPreviewImageDecoder.makeCGImage(
                pixelCopy: &localPixelCopy,
                width: width,
                height: height,
                stride: stride
              )
        else {
            continuation.resume(throwing: TerminalThemePreviewImageRenderer.RenderError.renderFailed)
            return
        }

        continuation.resume(returning: image)
    }
}

private let terminalThemePreviewImageCallback: ghostty_surface_preview_image_callback_f = { userdata, status, image in
    guard let userdata else { return }
    let box = Unmanaged<TerminalThemePreviewCallbackBox>.fromOpaque(userdata).takeRetainedValue()

    let width = image.width
    let height = image.height
    let stride = image.stride
    let pixelResult = GhosttyPreviewImageDecoder.copyPixels(status: status, image: image)
    let pixelStatus = pixelResult.status
    let pixelCopy = pixelResult.pixelCopy

    var mutableImage = image
    GhosttyKitControlSurface.freePreviewImage(&mutableImage)

    Task { @MainActor in
        box.complete(
            pixelStatus: pixelStatus,
            pixelCopy: pixelCopy,
            width: width,
            height: height,
            stride: stride
        )
    }
}
