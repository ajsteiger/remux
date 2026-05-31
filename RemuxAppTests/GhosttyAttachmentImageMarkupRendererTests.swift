import PencilKit
import UIKit
import XCTest
@testable import Remux

final class GhosttyAttachmentImageMarkupRendererTests: XCTestCase {
    func testOutputFilenameUsesAnnotatedPNGName() {
        XCTAssertEqual(
            GhosttyAttachmentImageMarkupRenderer.outputFilename(for: "../Screenshot.jpeg"),
            "Screenshot-annotated.png"
        )
        XCTAssertEqual(
            GhosttyAttachmentImageMarkupRenderer.outputFilename(for: "   "),
            "image-annotated.png"
        )
    }

    func testAspectFitRectCentersImageWithinContainer() {
        let rect = GhosttyAttachmentImageMarkupRenderer.aspectFitRect(
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 25, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
    }

    @MainActor
    func testRenderPNGDataProducesPreviewableAnnotatedImage() throws {
        let baseImage = try makeImage(width: 80, height: 60)
        let drawing = makeDrawing(color: .red)

        let output = try GhosttyAttachmentImageMarkupRenderer.renderPNGData(
            baseImage: baseImage,
            drawing: drawing,
            canvasSize: CGSize(width: 80, height: 60)
        )

        XCTAssertFalse(output.isEmpty)
        XCTAssertNotNil(UIImage(data: output))
        XCTAssertNotNil(GhosttyAttachmentImagePreviewData.makePreviewDataSynchronously(from: output))
    }

    @MainActor
    func testRenderPNGDataPreservesWhiteInk() throws {
        let baseImage = try makeImage(width: 80, height: 60, fill: .black)
        let drawing = makeHorizontalDrawing(color: .white, width: 22)

        let output = try GhosttyAttachmentImageMarkupRenderer.renderPNGData(
            baseImage: baseImage,
            drawing: drawing,
            canvasSize: CGSize(width: 80, height: 60)
        )

        let pixel = try brightestPixel(from: output, in: CGRect(x: 20, y: 20, width: 40, height: 20))
        XCTAssertGreaterThan(pixel.red, 0.82)
        XCTAssertGreaterThan(pixel.green, 0.82)
        XCTAssertGreaterThan(pixel.blue, 0.82)
        XCTAssertGreaterThan(pixel.alpha, 0.95)
    }

    @MainActor
    func testRenderPNGDataPreservesTransparentBasePixels() throws {
        let baseImage = try makeTransparentImage(width: 80, height: 60)
        let drawing = makeHorizontalDrawing(color: .white, width: 12)

        let output = try GhosttyAttachmentImageMarkupRenderer.renderPNGData(
            baseImage: baseImage,
            drawing: drawing,
            canvasSize: CGSize(width: 80, height: 60)
        )

        XCTAssertLessThan(try renderedPixel(from: output, x: 2, y: 2).alpha, 0.05)
        XCTAssertLessThan(try renderedPixel(from: output, x: 2, y: 57).alpha, 0.05)
        XCTAssertLessThan(try renderedPixel(from: output, x: 77, y: 2).alpha, 0.05)
        XCTAssertLessThan(try renderedPixel(from: output, x: 77, y: 57).alpha, 0.05)
    }

    @MainActor
    func testRenderPNGDataRejectsInvalidCanvasSize() throws {
        XCTAssertThrowsError(
            try GhosttyAttachmentImageMarkupRenderer.renderPNGData(
                baseImage: try makeImage(width: 80, height: 60),
                drawing: PKDrawing(),
                canvasSize: .zero
            )
        ) { error in
            XCTAssertEqual(
                error as? GhosttyAttachmentImageMarkupRenderer.RenderError,
                .invalidCanvasSize
            )
        }
    }

    @MainActor
    private func makeImage(
        width: Int,
        height: Int,
        fill: UIColor = .white
    ) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            fill.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeTransparentImage(width: Int, height: Int) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeDrawing(color: UIColor, width: CGFloat = 6) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 10, y: 10),
                timeOffset: 0,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 70, y: 50),
                timeOffset: 0.1,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private func makeHorizontalDrawing(color: UIColor, width: CGFloat) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 20, y: 30),
                timeOffset: 0,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 60, y: 30),
                timeOffset: 0.1,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private func renderedPixel(from data: Data, x: Int, y: Int) throws -> RGBA {
        let pixels = try renderedPixels(from: data)
        XCTAssertGreaterThan(pixels.width, x)
        XCTAssertGreaterThan(pixels.height, y)

        return pixels.pixel(x: x, y: y)
    }

    private func brightestPixel(from data: Data, in rect: CGRect) throws -> RGBA {
        let pixels = try renderedPixels(from: data)
        let minX = max(Int(rect.minX.rounded(.down)), 0)
        let maxX = min(Int(rect.maxX.rounded(.up)), pixels.width)
        let minY = max(Int(rect.minY.rounded(.down)), 0)
        let maxY = min(Int(rect.maxY.rounded(.up)), pixels.height)

        var brightest = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let pixel = pixels.pixel(x: x, y: y)
                if pixel.brightness > brightest.brightness {
                    brightest = pixel
                }
            }
        }
        return brightest
    }

    private func renderedPixels(from data: Data) throws -> PixelBuffer {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let width = image.width
        let height = image.height

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func pixel(x: Int, y: Int) -> RGBA {
            let offset = ((y * width) + x) * 4
            return RGBA(
                red: CGFloat(bytes[offset]) / 255,
                green: CGFloat(bytes[offset + 1]) / 255,
                blue: CGFloat(bytes[offset + 2]) / 255,
                alpha: CGFloat(bytes[offset + 3]) / 255
            )
        }
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        var brightness: CGFloat {
            max(red, green, blue)
        }
    }
}
