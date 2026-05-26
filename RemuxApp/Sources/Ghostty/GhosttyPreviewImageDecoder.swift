import CoreGraphics
import GhosttyKit

@MainActor
final class GhosttyPreviewRequestLease {
    private let cancelAction: @MainActor (ghostty_surface_preview_request_t) -> Void
    private let releaseAction: @MainActor (ghostty_surface_preview_request_t) -> Void
    private var request: ghostty_surface_preview_request_t?
    private var cancelWhenInstalled = false
    private var releaseWhenInstalled = false

    init(
        cancel: @escaping @MainActor (ghostty_surface_preview_request_t) -> Void,
        release: @escaping @MainActor (ghostty_surface_preview_request_t) -> Void
    ) {
        self.cancelAction = cancel
        self.releaseAction = release
    }

    func install(_ request: ghostty_surface_preview_request_t) {
        guard self.request == nil else { return }
        guard !releaseWhenInstalled else {
            if cancelWhenInstalled {
                cancelAction(request)
            }
            releaseAction(request)
            return
        }
        self.request = request
    }

    func cancelAndRelease() {
        cancelWhenInstalled = true
        releaseWhenInstalled = true
        guard let request else { return }
        self.request = nil
        cancelAction(request)
        releaseAction(request)
    }

    func release() {
        releaseWhenInstalled = true
        guard let request else { return }
        self.request = nil
        releaseAction(request)
    }
}

struct GhosttyPreviewPixelBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
}

enum GhosttyPreviewImageDecoder {
    static let maxByteCount = 64 * 1024 * 1024

    static func copyPixels(
        status: ghostty_surface_preview_status_e,
        image: ghostty_surface_preview_image_s
    ) -> (
        pixelCopy: GhosttyPreviewPixelBuffer,
        status: ghostty_surface_preview_status_e
    ) {
        guard status == GHOSTTY_SURFACE_PREVIEW_STATUS_OK else {
            return (GhosttyPreviewPixelBuffer(pointer: nil), status)
        }
        guard let sourcePixels = image.pixels,
              let byteCount = byteCount(width: image.width, height: image.height, stride: image.stride)
        else {
            return (
                GhosttyPreviewPixelBuffer(pointer: nil),
                GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED
            )
        }

        let copy = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        copy.copyMemory(from: sourcePixels, byteCount: byteCount)
        return (GhosttyPreviewPixelBuffer(pointer: copy), status)
    }

    /// Builds a CGImage from a Swift-owned BGRA8 sRGB pixel buffer.
    ///
    /// On success, ownership of `pixelCopy` transfers to the returned image's
    /// data provider and `pixelCopy` is set to nil. On failure, `pixelCopy`
    /// remains owned by the caller.
    static func makeCGImage(
        pixelCopy: inout UnsafeMutableRawPointer?,
        width: UInt32,
        height: UInt32,
        stride: UInt32
    ) -> CGImage? {
        guard let copy = pixelCopy,
              let byteCount = byteCount(width: width, height: height, stride: stride)
        else {
            return nil
        }

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

    static func byteCount(width: UInt32, height: UInt32, stride: UInt32) -> Int? {
        guard width > 0, height > 0, stride > 0 else { return nil }

        let widthBytes = UInt64(width) * 4
        let rowBytes = UInt64(stride)
        guard rowBytes >= widthBytes else { return nil }

        let byteCount = rowBytes * UInt64(height)
        guard byteCount > 0,
              byteCount <= UInt64(maxByteCount),
              byteCount <= UInt64(Int.max)
        else {
            return nil
        }
        return Int(byteCount)
    }
}
