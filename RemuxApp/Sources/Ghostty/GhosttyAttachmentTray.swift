import SwiftUI
import UIKit

struct GhosttyAttachmentTray: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let onPhotosSelected: () -> Void
    let onFilesSelected: () -> Void
    let onPasteSelected: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            attachmentAction(
                title: "Photos",
                systemName: "photo",
                accessibilityIdentifier: "terminal.attachments.photos",
                action: onPhotosSelected
            )

            attachmentAction(
                title: "Files",
                systemName: "doc",
                accessibilityIdentifier: "terminal.attachments.files",
                action: onFilesSelected
            )

            attachmentAction(
                title: "Paste",
                systemName: "clipboard",
                accessibilityIdentifier: "terminal.attachments.paste",
                action: onPasteSelected
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .ghosttyAttachmentActionGroupSurface()
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
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
    static let actionGroupFill = Color.primary.opacity(0.026)
    static let actionGroupStroke = Color.primary.opacity(0.06)
    static let actionButtonFill = Color.primary.opacity(0.035)
    static let actionButtonStroke = Color.primary.opacity(0.075)
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

    func ghosttyAttachmentActionGroupSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)

        return self
            .background(GhosttyAttachmentTrayStyle.actionGroupFill, in: shape)
            .overlay {
                shape.strokeBorder(GhosttyAttachmentTrayStyle.actionGroupStroke, lineWidth: 0.75)
            }
            .contentShape(shape)
    }

    @ViewBuilder
    func ghosttyAttachmentActionButtonSurface(
        isPressed: Bool,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background(
                    isPressed ? chromeStyle.toolbarButtonActiveFill : GhosttyAttachmentTrayStyle.actionButtonFill,
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        isPressed ? chromeStyle.accent.opacity(0.20) : GhosttyAttachmentTrayStyle.actionButtonStroke,
                        lineWidth: 0.75
                    )
                }
                .contentShape(shape)
        } else {
            self
                .background(
                    isPressed ? Color.primary.opacity(0.06) : GhosttyAttachmentTrayStyle.actionButtonFill,
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        isPressed ? Color.primary.opacity(0.12) : GhosttyAttachmentTrayStyle.actionButtonStroke,
                        lineWidth: 0.75
                    )
                }
                .contentShape(shape)
        }
    }
}
