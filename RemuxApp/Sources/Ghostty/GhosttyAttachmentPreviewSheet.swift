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
        guard case .text = attachment.previewPayload else { return true }
        return false
    }

    @ViewBuilder
    private func attachmentPreviewBody(_ attachment: GhosttyPendingAttachment) -> some View {
        switch attachment.previewPayload {
        case .imageData(let data):
            imagePreview(data)
        case .file(let url):
            filePreview(url)
        case .securityScopedFile(let file):
            filePreview(file)
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

    private func filePreview(_ file: GhosttySecurityScopedAttachmentFile) -> some View {
        GhosttyAttachmentQuickLookPreview(file: file)
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
