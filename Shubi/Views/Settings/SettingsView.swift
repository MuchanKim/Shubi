import SwiftUI

struct SettingsView: View {
    @AppStorage(Theme.storageKey) private var theme = Theme.default
    @State private var language: AppLanguage? = AppLanguage.saved

    var body: some View {
        Form {
            Section("테마") {
                HStack(spacing: Layout.Spacing.l) {
                    ForEach(Theme.allCases) { option in
                        ThemeCard(theme: option, isSelected: option == theme) { theme = option }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                Picker("언어", selection: $language) {
                    ForEach(AppLanguage.allCases) { $0.title.tag(Optional($0)) }
                }
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, ShownLanguage.shared.locale)
        .frame(width: Layout.settingsWidth)
        // A grouped Form scrolls by default and comes up a little short; sized to its content it needs no scroller.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: theme) { NSApp.appearance = theme.appearance }
        .onChange(of: language) { language?.choose() }
    }
}

private struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: Layout.Spacing.s) {
                swatch
                    .frame(width: Layout.themeSwatchWidth, height: Layout.themeSwatchHeight)
                    .clipShape(.rect(cornerRadius: Layout.Spacing.s))
                    .overlay {
                        RoundedRectangle(cornerRadius: Layout.Spacing.s)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 1)
                    }
                Text(theme.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var swatch: some View {
        let light = Color(white: 0.97)
        // Darker than a dark-mode form row, so the card still reads as a swatch there.
        let dark = Color(white: 0.08)
        switch theme {
        case .system: HStack(spacing: 0) { light; dark }
        case .light: light
        case .dark: dark
        case .aurora: Theme.auroraGradient
        }
    }
}
