import SwiftUI

/// Floating compass overlay shown while the spacebar long-press cursor
/// trackpad gesture is active. The active arrow saturates from a soft accent
/// to a vivid one as the user pushes further from the lock point — matching
/// the analog acceleration model so users see directly how committed their
/// finger is. A perimeter ring fills with the same intensity as a secondary
/// signal.
struct GhosttyKeyboardCursorTrackpadHUD: View {
    let state: GhosttyKeyboardCursorTrackpad.HUDState

    private let cornerRadius: CGFloat = 14
    private let dimensions: CGFloat = 64

    var body: some View {
        ZStack {
            arrow(for: .up)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            arrow(for: .down)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            arrow(for: .left)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            arrow(for: .right)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .padding(8)
        .frame(width: dimensions, height: dimensions)
        .background(GhosttyPhoneChromePalette.dock.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .overlay(
            intensityRing
        )
        .shadow(color: Color.black.opacity(0.28), radius: 6, y: 2)
        .opacity(state.isVisible ? 1 : 0)
        .scaleEffect(state.isVisible ? 1 : 0.94)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: state.isVisible)
        .animation(.easeOut(duration: 0.10), value: state.activeDirection)
        .animation(.easeOut(duration: 0.08), value: state.intensity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var intensityRing: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .trim(from: 0, to: max(0.001, state.intensity))
            .stroke(
                GhosttyPhoneChromePalette.accent.opacity(0.45 + 0.55 * state.intensity),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .opacity(state.intensity > 0 ? 1 : 0)
    }

    @ViewBuilder
    private func arrow(for direction: GhosttyKeyboardCursorTrackpad.Direction) -> some View {
        let active = state.activeDirection == direction
        Image(systemName: symbolName(for: direction))
            .font(.system(size: active ? 13 + 2 * state.intensity : 11, weight: .bold))
            .foregroundStyle(arrowColor(active: active))
            .scaleEffect(active ? 1 + 0.08 * state.intensity : 1)
    }

    private func arrowColor(active: Bool) -> Color {
        guard active else { return Color.white.opacity(0.45) }
        let baseAlpha: CGFloat = 0.55
        return GhosttyPhoneChromePalette.accent.opacity(baseAlpha + (1 - baseAlpha) * state.intensity)
    }

    private func symbolName(for direction: GhosttyKeyboardCursorTrackpad.Direction) -> String {
        switch direction {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}
