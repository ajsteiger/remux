import SwiftUI

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
        .accessibilityIdentifier("terminal.attachments.preview.sheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            GhosttyAttachmentPreviewHeader(
                caption: "\(attachments.count) STAGED",
                title: attachments.count == 1 ? "Attachment" : "Attachments"
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
                .accessibilityIdentifier("terminal.attachments.preview.content")
        } else {
            unavailablePreviewCard
        }
    }

    private func attachmentPreviewCard(_ attachment: GhosttyPendingAttachment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: attachment.systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        chromeStyle.toolbarButtonActiveFill,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .foregroundStyle(chromeStyle.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(GhosttySheetPalette.primary)

                    Text(attachment.detail)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(GhosttySheetPalette.secondary)
                }

                Spacer(minLength: 0)
            }

            unavailablePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(GhosttyAttachmentPreviewStyle.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ghosttyAttachmentPreviewContentSurface()
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
    }

    private var unavailablePreviewCard: some View {
        unavailablePreview
            .padding(GhosttyAttachmentPreviewStyle.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ghosttyAttachmentPreviewContentSurface()
    }

    private var selectedAttachment: GhosttyPendingAttachment? {
        if let selectedAttachmentID,
           let attachment = attachments.first(where: { $0.id == selectedAttachmentID }) {
            return attachment
        }

        return attachments.first(where: \.isPreviewable) ?? attachments.first
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
}

private struct GhosttyAttachmentPreviewHeader: View {
    let caption: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(GhosttySheetPalette.tertiary)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(GhosttySheetPalette.primary)
        }
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

private enum GhosttyAttachmentPreviewStyle {
    static let contentFill = GhosttyShortcutSurfacePalette.contentFill
    static let contentStroke = GhosttyShortcutSurfacePalette.contentStroke
    static let controlFill = GhosttySheetPalette.controlFill
    static let controlPressedFill = Color(uiColor: .tertiarySystemFill)
    static let controlStroke = GhosttySheetPalette.stroke
    static let contentCornerRadius = GhosttyShortcutSurfacePalette.cornerRadiusLarge
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

    func ghosttyAttachmentPreviewContentSurface() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GhosttyAttachmentPreviewStyle.contentCornerRadius,
            style: .continuous
        )

        return self
            .background(GhosttyAttachmentPreviewStyle.contentFill, in: shape)
            .overlay {
                shape.strokeBorder(GhosttyAttachmentPreviewStyle.contentStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }
}
