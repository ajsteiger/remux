import PencilKit
import SwiftUI
import UIKit

struct GhosttyAttachmentImageMarkupEditor: View {
    let imageURL: URL
    let onCancel: () -> Void
    let onDone: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: LoadPhase = .loading
    @State private var drawing = PKDrawing()
    @State private var toolPickerVisibilityRequest = UUID()
    @State private var canvasSize: CGSize = .zero
    @State private var isRendering = false
    @State private var saveFailureMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, phase.loadedImage == nil ? 0 : 88)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task(id: imageURL) {
            await loadImage()
        }
        .alert(
            "Annotation Unavailable",
            isPresented: saveFailureAlertBinding,
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(saveFailureMessage ?? "Annotation could not be saved.")
            }
        )
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                onCancel()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(minWidth: 72, minHeight: 44, alignment: .leading)
            }
            .disabled(isRendering)
            .accessibilityIdentifier("terminal.attachments.markup.cancel")

            Spacer()

            if phase.loadedImage != nil {
                toolbarIconButton(
                    systemName: "paintpalette",
                    accessibilityLabel: "Show annotation tools",
                    accessibilityIdentifier: "terminal.attachments.markup.tools"
                ) {
                    toolPickerVisibilityRequest = UUID()
                }

                toolbarIconButton(
                    systemName: "trash",
                    accessibilityLabel: "Clear annotation",
                    accessibilityIdentifier: "terminal.attachments.markup.clear"
                ) {
                    clearAnnotation()
                }
                .disabled(drawing.bounds.isEmpty || isRendering)
            }

            if isRendering {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
            }

            Button {
                finishAnnotation()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(minWidth: 64, minHeight: 44, alignment: .trailing)
            }
            .disabled(!canFinish)
            .accessibilityIdentifier("terminal.attachments.markup.done")
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.black.opacity(0.94))
    }

    private func toolbarIconButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.12), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                }
        }
        .disabled(isRendering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch phase {
        case .loading:
            ProgressView()
                .tint(.white)
                .controlSize(.large)

        case .loaded(let image):
            GeometryReader { geometry in
                let imageFrame = GhosttyAttachmentImageMarkupRenderer.aspectFitRect(
                    imageSize: image.size,
                    containerSize: geometry.size
                )

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                        .accessibilityHidden(true)

                    GhosttyAttachmentMarkupCanvas(
                        drawing: $drawing,
                        toolPickerVisibilityRequest: toolPickerVisibilityRequest
                    )
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .onAppear {
                        canvasSize = imageFrame.size
                    }
                    .onChange(of: imageFrame.size) { _, size in
                        canvasSize = size
                    }
                    .accessibilityLabel("Annotation canvas")
                    .accessibilityIdentifier("terminal.attachments.markup.canvas")
                }
            }

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                Text("Image could not be opened.")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.82))
        }
    }

    private func clearAnnotation() {
        guard !drawing.bounds.isEmpty else { return }
        drawing = PKDrawing()
    }

    private var canFinish: Bool {
        phase.loadedImage != nil && !isRendering && canvasSize.width > 0 && canvasSize.height > 0
    }

    private var saveFailureAlertBinding: Binding<Bool> {
        Binding {
            saveFailureMessage != nil
        } set: { isPresented in
            if !isPresented {
                saveFailureMessage = nil
            }
        }
    }

    private func loadImage() async {
        phase = .loading
        let data = try? await Task.detached(priority: .utility) {
            try Data(contentsOf: imageURL)
        }.value

        guard let data,
              let image = UIImage(data: data) else {
            phase = .failed
            return
        }

        phase = .loaded(image)
    }

    private func finishAnnotation() {
        guard case .loaded(let image) = phase, canFinish else { return }
        guard !drawing.bounds.isEmpty else {
            onCancel()
            dismiss()
            return
        }

        isRendering = true

        do {
            let data = try GhosttyAttachmentImageMarkupRenderer.renderPNGData(
                baseImage: image,
                drawing: drawing,
                canvasSize: canvasSize
            )
            onDone(data)
        } catch {
            isRendering = false
            saveFailureMessage = "Annotation could not be saved."
        }
    }
}

enum GhosttyAttachmentImageMarkupRenderer {
    enum RenderError: Error, Equatable {
        case invalidCanvasSize
        case invalidImageSize
        case encodingFailed
    }

    static func outputFilename(for sourceFilename: String) -> String {
        let component = sourceFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { character in
                character == "/" || character == "\\"
            }
            .last
            .map(String.init) ?? "image"
        let stem = URL(fileURLWithPath: component)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stem.isEmpty ? "image" : stem)-annotated.png"
    }

    static func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    @MainActor
    static func renderPNGData(
        baseImage: UIImage,
        drawing: PKDrawing,
        canvasSize: CGSize
    ) throws -> Data {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw RenderError.invalidCanvasSize
        }

        let imageSize = baseImage.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            throw RenderError.invalidImageSize
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(baseImage.scale, 1)
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let renderedImage = renderer.image { context in
            baseImage.draw(in: CGRect(origin: .zero, size: imageSize))

            var drawingImage: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawingImage = drawing.image(
                    from: CGRect(origin: .zero, size: canvasSize),
                    scale: format.scale
                )
            }
            drawingImage?.draw(in: CGRect(origin: .zero, size: imageSize))
        }

        guard let data = renderedImage.pngData(), !data.isEmpty else {
            throw RenderError.encodingFailed
        }
        return data
    }
}

private struct GhosttyAttachmentMarkupCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let toolPickerVisibilityRequest: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.isScrollEnabled = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.delegate = context.coordinator
        context.coordinator.attachToolPicker(
            to: canvasView,
            visibilityRequest: toolPickerVisibilityRequest
        )
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        if canvasView.drawing != drawing {
            canvasView.drawing = drawing
        }
        context.coordinator.updateToolPicker(
            for: canvasView,
            visibilityRequest: toolPickerVisibilityRequest
        )
    }

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.detachToolPicker(from: uiView)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding private var drawing: PKDrawing
        private let toolPicker: PKToolPicker
        private var lastVisibilityRequest: UUID?

        init(drawing: Binding<PKDrawing>) {
            _drawing = drawing
            toolPicker = Self.makeToolPicker()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }

        func attachToolPicker(
            to canvasView: PKCanvasView,
            visibilityRequest: UUID
        ) {
            toolPicker.addObserver(canvasView)
            showToolPicker(for: canvasView, visibilityRequest: visibilityRequest)
        }

        func updateToolPicker(
            for canvasView: PKCanvasView,
            visibilityRequest: UUID
        ) {
            guard lastVisibilityRequest != visibilityRequest || !canvasView.isFirstResponder else {
                return
            }

            showToolPicker(for: canvasView, visibilityRequest: visibilityRequest)
        }

        func detachToolPicker(from canvasView: PKCanvasView) {
            toolPicker.setVisible(false, forFirstResponder: canvasView)
            toolPicker.removeObserver(canvasView)
        }

        private func showToolPicker(
            for canvasView: PKCanvasView,
            visibilityRequest: UUID
        ) {
            lastVisibilityRequest = visibilityRequest

            if canvasView.window == nil {
                DispatchQueue.main.async { [weak self, weak canvasView] in
                    guard let self, let canvasView, canvasView.window != nil else { return }
                    self.showToolPicker(
                        for: canvasView,
                        visibilityRequest: visibilityRequest
                    )
                }
                return
            }

            canvasView.becomeFirstResponder()
            toolPicker.setVisible(true, forFirstResponder: canvasView)
        }

        private static func makeToolPicker() -> PKToolPicker {
            let pen = PKToolPickerInkingItem(
                type: .pen,
                color: .systemBlue,
                width: 5,
                identifier: "remux.markup.pen"
            )
            pen.allowsColorSelection = true

            let marker = PKToolPickerInkingItem(
                type: .marker,
                color: .systemYellow,
                width: 16,
                identifier: "remux.markup.marker"
            )
            marker.allowsColorSelection = true

            let monoline = PKToolPickerInkingItem(
                type: .monoline,
                color: .white,
                width: 7,
                identifier: "remux.markup.monoline"
            )
            monoline.allowsColorSelection = true

            let eraser = PKToolPickerEraserItem(type: .bitmap)
            let lasso = PKToolPickerLassoItem()
            let ruler = PKToolPickerRulerItem()
            let picker = PKToolPicker(
                toolItems: [
                    pen,
                    marker,
                    monoline,
                    eraser,
                    lasso,
                    ruler,
                ]
            )
            picker.selectedToolItem = pen
            picker.showsDrawingPolicyControls = false
            picker.colorUserInterfaceStyle = .light
            picker.overrideUserInterfaceStyle = .dark
            return picker
        }
    }
}

private enum LoadPhase {
    case loading
    case loaded(UIImage)
    case failed

    var loadedImage: UIImage? {
        guard case .loaded(let image) = self else { return nil }
        return image
    }
}
