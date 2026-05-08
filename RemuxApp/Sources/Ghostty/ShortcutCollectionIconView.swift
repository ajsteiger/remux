import SwiftUI

struct ShortcutPaletteTabIcon: View {
    let tab: ShortcutPaletteTabID

    var body: some View {
        switch tab {
        case .favorites:
            Image(systemName: "star")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
        case .collection(let collection):
            ShortcutCollectionIconView(collection: collection, variant: .tab)
        case .appAction(let action):
            Image(systemName: action.systemImageName)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
        }
    }
}

struct ShortcutCollectionIconView: View {
    enum Variant {
        case tab
        case settings
    }

    let collection: ShortcutCollectionID
    var variant: Variant = .settings

    var body: some View {
        switch collection {
        case .shell:
            Image(systemName: "terminal")
                .font(.system(size: variant == .tab ? 16 : 15.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
        case .claude:
            ClaudeShortcutGlyph()
                .frame(
                    width: variant == .tab ? 18 : 19,
                    height: variant == .tab ? 18 : 19
                )
        case .codex:
            CodexShortcutGlyph(variant: variant)
                .frame(
                    width: variant == .tab ? 24 : 25,
                    height: variant == .tab ? 18 : 20
                )
        }
    }
}

private struct ClaudeShortcutGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)

            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(.foreground)
                        .frame(width: size * 0.14, height: size * 0.43)
                        .offset(y: -size * 0.23)
                        .rotationEffect(.degrees(Double(index) * 45))
                        .opacity(index.isMultiple(of: 2) ? 0.98 : 0.76)
                }

                Circle()
                    .fill(.foreground)
                    .frame(width: size * 0.20, height: size * 0.20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct CodexShortcutGlyph: View {
    let variant: ShortcutCollectionIconView.Variant

    var body: some View {
        Text("Cx")
            .font(.system(size: variant == .tab ? 11.5 : 12.5, weight: .bold, design: .rounded))
            .minimumScaleFactor(0.85)
            .lineLimit(1)
    }
}
