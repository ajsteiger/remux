import SwiftUI

struct GhosttyPendingAttachmentPreview: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let attachments: [GhosttyPendingAttachment]
    let canSend: Bool
    let isSending: Bool
    let sendUploadCount: Int
    let sendProgress: GhosttyAttachmentTransferProgress?
    let onOpen: () -> Void
    let onSend: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.chromeControlPress()
                onOpen()
            } label: {
                HStack(spacing: 10) {
                    pendingAttachmentIcon

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                        .opacity(canOpen ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .accessibilityLabel(openAccessibilityLabel)
            .accessibilityHint(canOpen ? "Open attachment preview." : "Preview is not available yet.")
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Button {
                    Haptic.chromeControlPress()
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(GhosttyPendingAttachmentRemoveButtonStyle())
                .disabled(isSending)
                .opacity(isSending ? 0.58 : 1)
                .accessibilityLabel(removeAccessibilityLabel)
                .accessibilityIdentifier("terminal.attachments.pending.remove")

                if canSend {
                    Button {
                        Haptic.chromeControlPress()
                        onSend()
                    } label: {
                        Text("Send")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .frame(width: 58, height: 30)
                    }
                    .buttonStyle(GhosttyPendingAttachmentSendButtonStyle(chromeStyle: chromeStyle))
                    .accessibilityHint("Send attachment.")
                    .accessibilityIdentifier("terminal.attachments.pending.send")
                } else {
                    GhosttyPendingAttachmentStatusBadge(
                        chromeStyle: chromeStyle,
                        isSending: isSending,
                        uploadCount: sendUploadCount,
                        progress: sendProgress
                    )
                        .accessibilityIdentifier("terminal.attachments.pending.status")
                }
            }
        }
        .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .ghosttyPendingAttachmentPreviewSurface()
    }

    private var pendingAttachmentIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: representativeSystemName)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: 38, height: 38)
                .ghosttyPendingAttachmentIconSurface(chromeStyle: chromeStyle)
                .accessibilityHidden(true)

            if attachments.count > 1 {
                Text("\(attachments.count)")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(chromeStyle.accentForeground)
                    .frame(minWidth: 13, minHeight: 13)
                    .padding(.horizontal, attachments.count > 9 ? 3 : 0)
                    .background(chromeStyle.accent.opacity(0.9), in: Capsule())
                    .offset(x: 4, y: -4)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 42, height: 38)
    }

    private var title: String {
        guard attachments.count > 1 else {
            return attachments.first?.title ?? "Attachment"
        }

        if attachments.allSatisfy({ $0.kind == .photo }) {
            return "\(attachments.count) photos"
        }

        if attachments.allSatisfy({ $0.kind == .video }) {
            return "\(attachments.count) videos"
        }

        if attachments.allSatisfy({ [.photo, .video, .media].contains($0.kind) }) {
            return "\(attachments.count) media"
        }

        if attachments.allSatisfy({ $0.kind == .file }) {
            return "\(attachments.count) files"
        }

        return "\(attachments.count) attachments"
    }

    private var detail: String {
        guard attachments.count > 1 else {
            return attachments.first?.detail ?? "Attachment"
        }

        let visibleTitles = attachments.prefix(2).map(\.detail).joined(separator: ", ")
        let overflow = attachments.count > 2 ? " +\(attachments.count - 2)" : ""
        return "\(visibleTitles)\(overflow)"
    }

    private var representativeSystemName: String {
        attachments.first?.systemName ?? "paperclip"
    }

    private var canOpen: Bool {
        attachments.contains(where: \.isPreviewable) && !isSending
    }

    private var openAccessibilityLabel: String {
        attachments.count > 1 ? "Preview attachments" : "Preview attachment"
    }

    private var removeAccessibilityLabel: String {
        attachments.count > 1 ? "Remove attachments" : "Remove attachment"
    }
}

private struct GhosttyPendingAttachmentStatusBadge: View {
    let chromeStyle: GhosttyTerminalChromeStyle
    let isSending: Bool
    let uploadCount: Int
    let progress: GhosttyAttachmentTransferProgress?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isSending ? "arrow.up" : "checkmark")
                .font(.system(size: 10, weight: .bold))
                .symbolRenderingMode(.monochrome)

            Text(label)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(chromeStyle.accent)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(chromeStyle.selectedFill)

                    if isSending {
                        Capsule()
                            .fill(chromeStyle.accent.opacity(0.34))
                            .frame(width: proxy.size.width * progressFraction)
                    }
                }
            }
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(chromeStyle.accent.opacity(0.22), lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeOut(duration: 0.18), value: progressFraction)
        .animation(.easeOut(duration: 0.12), value: isSending)
    }

    private var label: String {
        guard isSending else {
            return "Staged"
        }

        let totalUploadCount = progress?.totalUploadCount ?? uploadCount
        guard totalUploadCount > 1 else {
            return "Sending"
        }

        let currentUploadIndex = progress?.currentUploadIndex ?? 1
        return "Sending \(currentUploadIndex) of \(totalUploadCount)"
    }

    private var progressFraction: Double {
        guard isSending, let progress else {
            return 0
        }
        return progress.currentUploadFraction
    }

    private var accessibilityLabel: String {
        guard isSending else {
            return "Attachment staged"
        }

        let totalUploadCount = progress?.totalUploadCount ?? uploadCount
        guard let progress else {
            if totalUploadCount > 1 {
                return "Attachment sending 1 of \(totalUploadCount)"
            }
            return "Attachment sending"
        }

        let percent = Int((progress.currentUploadFraction * 100).rounded())
        if totalUploadCount > 1 {
            return "Attachment sending \(progress.currentUploadIndex) of \(totalUploadCount), \(percent) percent"
        }

        return "Attachment sending, \(percent) percent"
    }
}

private struct GhosttyPendingAttachmentRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.10 : 0.052),
                in: Circle()
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GhosttyPendingAttachmentSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let chromeStyle: GhosttyTerminalChromeStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? chromeStyle.accentForeground : GhosttyPhoneChromePalette.chromeSecondaryForeground)
            .background(sendFill(isPressed: configuration.isPressed), in: Capsule())
            .overlay {
                Capsule().strokeBorder(sendStroke, lineWidth: 0.75)
            }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func sendFill(isPressed: Bool) -> Color {
        guard isEnabled else {
            return Color.primary.opacity(0.055)
        }

        return chromeStyle.accent.opacity(isPressed ? 0.84 : 0.72)
    }

    private var sendStroke: Color {
        isEnabled ? chromeStyle.accent.opacity(0.22) : Color.primary.opacity(0.07)
    }
}

private extension View {
    @ViewBuilder
    func ghosttyPendingAttachmentPreviewSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(GhosttyAttachmentTrayStyle.panelGlassTint),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentTrayStyle.panelGlassStroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttyAttachmentTrayStyle.panelGlassShadow, radius: 14, y: 8)
                .contentShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(GhosttyAttachmentTrayStyle.fallbackPanelFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentTrayStyle.fallbackPanelStroke, lineWidth: 1)
                }
                .shadow(color: GhosttyAttachmentTrayStyle.fallbackShadow, radius: 14, y: 8)
        }
    }

    @ViewBuilder
    func ghosttyPendingAttachmentIconSurface(
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

        self
            .foregroundStyle(chromeStyle.accent)
            .background(chromeStyle.toolbarButtonActiveFill, in: shape)
            .overlay {
                shape.strokeBorder(GhosttyAttachmentTrayStyle.pendingIconStroke, lineWidth: 0.75)
            }
            .contentShape(shape)
    }
}
