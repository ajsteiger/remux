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
            Image("ShortcutClaudeMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(
                    width: variant == .tab ? 18.5 : 19.5,
                    height: variant == .tab ? 18.5 : 19.5
                )
        case .codex:
            Image("ShortcutOpenAIMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(
                    width: variant == .tab ? 18.5 : 19.5,
                    height: variant == .tab ? 18.5 : 19.5
                )
        }
    }
}
