import SwiftUI
import UIKit

struct GhosttyAttachmentTray: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let onPhotosSelected: () -> Void
    let onFilesSelected: () -> Void
    let onPasteSelected: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            attachmentAction(
                title: "Photos",
                systemName: "photo",
                accessibilityIdentifier: "terminal.attachments.photos",
                action: onPhotosSelected
            )

            attachmentDivider

            attachmentAction(
                title: "Files",
                systemName: "doc",
                accessibilityIdentifier: "terminal.attachments.files",
                action: onFilesSelected
            )

            attachmentDivider

            attachmentAction(
                title: "Paste",
                systemName: "clipboard",
                accessibilityIdentifier: "terminal.attachments.paste",
                action: onPasteSelected
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .ghosttyAttachmentTraySurface()
        .accessibilityElement(children: .contain)
    }

    private func attachmentAction(
        title: String,
        systemName: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            GhosttyAttachmentActionLabel(title: title, systemName: systemName)
        }
        .buttonStyle(GhosttyAttachmentActionButtonStyle(chromeStyle: chromeStyle))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var attachmentDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 0.75, height: 44)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

private struct GhosttyAttachmentActionLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(height: 22)

            Text(title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
    }
}

private struct GhosttyAttachmentActionButtonStyle: ButtonStyle {
    let chromeStyle: GhosttyTerminalChromeStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? chromeStyle.accent : GhosttyPhoneChromePalette.chromeForeground)
            .ghosttyAttachmentActionButtonSurface(isPressed: configuration.isPressed, chromeStyle: chromeStyle)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum GhosttyAttachmentTrayStyle {
    static let panelGlassTint = Color.primary.opacity(0.055)
    static let panelGlassStroke = Color.primary.opacity(0.14)
    static let panelGlassShadow = Color.black.opacity(0.16)
    static let fallbackPanelFill = Color(uiColor: .secondarySystemBackground).opacity(0.72)
    static let fallbackPanelStroke = Color.primary.opacity(0.08)
    static let fallbackShadow = Color.black.opacity(0.20)
    static let pendingIconStroke = Color.primary.opacity(0.08)
}

extension View {
    @ViewBuilder
    func ghosttyAttachmentTraySurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

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
                .shadow(color: GhosttyAttachmentTrayStyle.panelGlassShadow, radius: 18, y: 10)
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
                .shadow(color: GhosttyAttachmentTrayStyle.fallbackShadow, radius: 18, y: 10)
        }
    }

    @ViewBuilder
    func ghosttyAttachmentActionButtonSurface(
        isPressed: Bool,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        self
            .background(
                isPressed ? chromeStyle.toolbarButtonActiveFill : Color.clear,
                in: shape
            )
            .contentShape(shape)
    }
}
