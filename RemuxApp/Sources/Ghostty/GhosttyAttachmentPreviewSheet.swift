import QuickLook
import SwiftUI
import UIKit

struct GhosttyAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @State private var selectedAttachmentID: UUID?
    @Binding var attachments: [GhosttyPendingAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if attachments.count > 1 {
                attachmentStrip
            }

            attachmentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .onAppear {
            ensureSelectedAttachment()
        }
        .onChange(of: attachments) { _, _ in
            ensureSelectedAttachment()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            GhosttyAttachmentPreviewHeader(
                caption: previewCaption,
                title: previewTitle
            )

            Spacer()

            Button {
                Haptic.tap()
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 38)
            }
            .buttonStyle(GhosttyAttachmentPreviewDoneButtonStyle())
            .accessibilityIdentifier("terminal.attachments.preview.done")
        }
    }

    private var attachmentStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        Button {
                            Haptic.selection()
                            withAnimation(.easeOut(duration: 0.16)) {
                                selectedAttachmentID = attachment.id
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: attachment.systemName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .symbolRenderingMode(.monochrome)

                                Text(attachment.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(
                                        maxWidth: GhosttyAttachmentPreviewStyle.chipTitleMaxWidth,
                                        alignment: .leading
                                    )
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 34)
                        }
                        .buttonStyle(
                            GhosttyAttachmentPreviewChipButtonStyle(
                                isSelected: isSelected(attachment),
                                chromeStyle: chromeStyle
                            )
                        )
                        .id(attachment.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
            .onChange(of: selectedAttachmentID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier("terminal.attachments.preview.strip")
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if let attachment = selectedAttachment {
            attachmentPreviewCard(attachment)
        } else {
            unavailablePreviewCard
        }
    }

    private func attachmentPreviewCard(_ attachment: GhosttyPendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            attachmentPreviewBody(attachment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsOverlayActions(for: attachment) {
                previewOverlayActions(for: attachment)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func previewOverlayActions(for attachment: GhosttyPendingAttachment) -> some View {
        Button {
            Haptic.chromeControlPress()
            removeAttachment(attachment)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(
            GhosttyAttachmentPreviewActionButtonStyle(
                foreground: GhosttySheetPalette.primary
            )
        )
        .accessibilityLabel("Remove attachment")
        .accessibilityIdentifier("terminal.attachments.preview.remove-selected")
    }

    private func showsOverlayActions(for attachment: GhosttyPendingAttachment) -> Bool {
        guard case .text = attachment.payload else { return true }
        return false
    }

    @ViewBuilder
    private func attachmentPreviewBody(_ attachment: GhosttyPendingAttachment) -> some View {
        switch attachment.payload {
        case .imageData(let data):
            imagePreview(data)
        case .file(let url):
            filePreview(url)
        case .link(let url):
            linkPreview(url)
        case .text:
            textPreview(textBinding: textBinding(for: attachment))
        default:
            unavailablePreview
        }
    }

    @ViewBuilder
    private func imagePreview(_ data: Data) -> some View {
        if let image = UIImage(data: data) {
            GhosttyAttachmentInteractiveImagePreview(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ghosttyAttachmentPreviewContentSurface(
                    fill: GhosttyAttachmentPreviewStyle.mediaFill
                )
        } else {
            unavailablePreview
        }
    }

    private func filePreview(_ url: URL) -> some View {
        GhosttyAttachmentQuickLookPreview(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ghosttyAttachmentPreviewContentSurface()
            .accessibilityIdentifier("terminal.attachments.file-preview")
    }

    private func linkPreview(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(chromeStyle.accent)
                        .accessibilityHidden(true)

                    Text(linkTitle(for: url))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(GhosttySheetPalette.primary)
                        .lineLimit(1)
                }

                Text(url.absoluteString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            Link(destination: url) {
                Label("Open Link", systemImage: "arrow.up.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(chromeStyle.accent)
                    .background(chromeStyle.selectedFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(chromeStyle.accent.opacity(0.18), lineWidth: 0.75)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GhosttyAttachmentPreviewStyle.contentPadding)
        .ghosttyAttachmentPreviewContentSurface()
        .accessibilityIdentifier("terminal.attachments.link-preview")
    }

    private func linkTitle(for url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return "Link"
        }

        return host
    }

    @ViewBuilder
    private func textPreview(textBinding: Binding<String>) -> some View {
        TextEditor(text: textBinding)
            .font(.system(size: 14, weight: .regular, design: .monospaced))
            .foregroundStyle(GhosttySheetPalette.primary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .tint(chromeStyle.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(GhosttyAttachmentPreviewStyle.contentPadding)
            .ghosttyAttachmentPreviewContentSurface()
            .accessibilityIdentifier("terminal.attachments.text-editor")
    }

    private var unavailablePreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(GhosttySheetPalette.secondary)

            Text("Preview unavailable")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GhosttySheetPalette.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GhosttyAttachmentPreviewStyle.contentPadding)
        .ghosttyAttachmentPreviewContentSurface()
    }

    private var unavailablePreviewCard: some View {
        unavailablePreview
    }

    private var selectedAttachment: GhosttyPendingAttachment? {
        if let selectedAttachmentID,
           let attachment = attachments.first(where: { $0.id == selectedAttachmentID }) {
            return attachment
        }

        return attachments.first(where: \.isPreviewable) ?? attachments.first
    }

    private var previewCaption: String {
        attachments.count == 1 ? "Staged" : "\(attachments.count) staged"
    }

    private var previewTitle: String {
        guard attachments.count == 1,
              let selectedAttachment else {
            return "Attachments"
        }

        return selectedAttachment.previewSheetTitle
    }

    private func isSelected(_ attachment: GhosttyPendingAttachment) -> Bool {
        selectedAttachment?.id == attachment.id
    }

    private func ensureSelectedAttachment() {
        guard !attachments.isEmpty else {
            selectedAttachmentID = nil
            return
        }

        if let selectedAttachmentID,
           attachments.contains(where: { $0.id == selectedAttachmentID }) {
            return
        }

        selectedAttachmentID = (attachments.first(where: \.isPreviewable) ?? attachments[0]).id
    }

    private func textBinding(for attachment: GhosttyPendingAttachment) -> Binding<String> {
        Binding {
            guard let currentAttachment = attachments.first(where: { $0.id == attachment.id }),
                  case .text(let text) = currentAttachment.payload else {
                return ""
            }

            return text
        } set: { text in
            updateTextAttachment(id: attachment.id, text: text)
        }
    }

    private func updateTextAttachment(id: UUID, text: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }

        attachments[index] = attachments[index].updatingText(text)
    }

    private func removeAttachment(_ attachment: GhosttyPendingAttachment) {
        withAnimation(.easeOut(duration: 0.16)) {
            attachments.removeAll { $0.id == attachment.id }
        }
        GhosttyAttachmentStagingStore.cleanup([attachment])
    }
}

private struct GhosttyAttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.update(url: url) {
            controller.reloadData()
        }
    }

    static func dismantleUIViewController(
        _ controller: QLPreviewController,
        coordinator: Coordinator
    ) {
        coordinator.stopAccessing()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private var url: URL
        private var accessedURL: URL?

        init(url: URL) {
            self.url = url
            super.init()
            startAccessing(url)
        }

        func update(url: URL) -> Bool {
            guard self.url != url else { return false }
            stopAccessing()
            self.url = url
            startAccessing(url)
            return true
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }

        private func startAccessing(_ url: URL) {
            if url.startAccessingSecurityScopedResource() {
                accessedURL = url
            }
        }

        func stopAccessing() {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }
}

private extension GhosttyPendingAttachment {
    var previewSheetTitle: String {
        switch kind {
        case .photo, .pasteboardImage:
            "Image"
        case .video:
            "Video"
        case .media:
            "Media"
        case .file:
            "File"
        case .pasteboardLink:
            "Link"
        case .pasteboardText:
            "Text"
        }
    }
}

private struct GhosttyAttachmentPreviewHeader: View {
    let caption: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(GhosttySheetPalette.tertiary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GhosttySheetPalette.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct GhosttyAttachmentInteractiveImagePreview: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> GhosttyAttachmentInteractiveImageView {
        let view = GhosttyAttachmentInteractiveImageView()
        view.configure(image: image)
        return view
    }

    func updateUIView(_ view: GhosttyAttachmentInteractiveImageView, context: Context) {
        view.configure(image: image)
    }
}

private final class GhosttyAttachmentInteractiveImageView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var displayedImage: UIImage?
    private var laidOutBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: UIImage) {
        guard displayedImage !== image else { return }
        displayedImage = image
        imageView.image = image
        laidOutBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.size != laidOutBounds else { return }
        laidOutBounds = bounds.size
        resetImageLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func setup() {
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.backgroundColor = .black
        scrollView.bouncesZoom = true
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    private func resetImageLayout() {
        guard let image = displayedImage, !bounds.isEmpty else { return }

        scrollView.zoomScale = 1
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4

        let fittedSize = fittedImageSize(image.size, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize
        centerImage()
    }

    private func fittedImageSize(_ imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame

        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    @objc
    private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }

        let targetZoomScale = min(scrollView.maximumZoomScale, 2.5)
        let point = recognizer.location(in: imageView)
        let width = scrollView.bounds.width / targetZoomScale
        let height = scrollView.bounds.height / targetZoomScale
        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        scrollView.zoom(to: rect, animated: true)
    }
}

private struct GhosttyAttachmentPreviewDoneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GhosttySheetPalette.primary)
            .ghosttyAttachmentPreviewDoneButtonSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GhosttyAttachmentPreviewChipButtonStyle: ButtonStyle {
    let isSelected: Bool
    let chromeStyle: GhosttyTerminalChromeStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? chromeStyle.accent : GhosttySheetPalette.primary)
            .ghosttyAttachmentPreviewChipSurface(
                isSelected: isSelected,
                isPressed: configuration.isPressed,
                chromeStyle: chromeStyle
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GhosttyAttachmentPreviewActionButtonStyle: ButtonStyle {
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .ghosttyAttachmentPreviewOverlayActionSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum GhosttyAttachmentPreviewStyle {
    static let contentFill = GhosttySheetPalette.row
    static let mediaFill = Color.black.opacity(0.84)
    static let contentStroke = GhosttySheetPalette.stroke
    static let controlFill = GhosttySheetPalette.controlFill
    static let controlPressedFill = Color(uiColor: .tertiarySystemFill)
    static let controlStroke = GhosttySheetPalette.stroke
    static let contentCornerRadius: CGFloat = 16
    static let chipTitleMaxWidth: CGFloat = 220
    static let contentPadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
}

private extension View {
    func ghosttyAttachmentPreviewDoneButtonSurface(isPressed: Bool) -> some View {
        let shape = Capsule()

        return self
            .background(
                isPressed
                    ? GhosttyAttachmentPreviewStyle.controlPressedFill
                    : GhosttyAttachmentPreviewStyle.controlFill,
                in: shape
            )
            .overlay {
                shape.strokeBorder(GhosttyAttachmentPreviewStyle.controlStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }

    func ghosttyAttachmentPreviewChipSurface(
        isSelected: Bool,
        isPressed: Bool,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        let shape = Capsule()
        let fill = attachmentPreviewChipFill(
            isSelected: isSelected,
            isPressed: isPressed,
            chromeStyle: chromeStyle
        )
        let stroke = isSelected ? GhosttySheetPalette.selectedStroke(chromeStyle) : GhosttyAttachmentPreviewStyle.controlStroke

        return self
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(stroke, lineWidth: isSelected ? 1 : 0.75)
            }
            .contentShape(shape)
    }

    private func attachmentPreviewChipFill(
        isSelected: Bool,
        isPressed: Bool,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> Color {
        if isSelected {
            return chromeStyle.selectedFill
        }

        return isPressed
            ? GhosttyAttachmentPreviewStyle.controlPressedFill
            : GhosttyAttachmentPreviewStyle.controlFill
    }

    @ViewBuilder
    func ghosttyAttachmentPreviewContentSurface(
        fill: Color = GhosttyAttachmentPreviewStyle.contentFill
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GhosttyAttachmentPreviewStyle.contentCornerRadius,
            style: .continuous
        )

        self
            .background(fill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(GhosttyAttachmentPreviewStyle.contentStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }

    @ViewBuilder
    func ghosttyAttachmentPreviewOverlayActionSurface(isPressed: Bool) -> some View {
        let shape = Circle()

        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(GhosttyAttachmentTrayStyle.panelGlassTint)
                        .interactive(),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentTrayStyle.panelGlassStroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttyAttachmentTrayStyle.panelGlassShadow, radius: 12, y: 7)
                .contentShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(isPressed ? GhosttyAttachmentPreviewStyle.controlPressedFill : GhosttyAttachmentPreviewStyle.controlFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentPreviewStyle.controlStroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttyAttachmentTrayStyle.fallbackShadow, radius: 12, y: 7)
                .contentShape(shape)
        }
    }
}
