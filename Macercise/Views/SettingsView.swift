import SwiftUI

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark, aurora

    static let storageKey = "theme"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .system: "시스템"
        case .light: "라이트"
        case .dark: "다크"
        case .aurora: "오로라"
        }
    }

    /// nil follows the system. Set on `NSApp`, so sheets, alerts and Quick Look follow it too.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .aurora: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static let `default` = Theme.system

    static var saved: Theme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Theme.init) ?? .default
    }

    /// Pastel light background: mint, sky and lavender around a white center, so text keeps its light-mode contrast.
    static let auroraGradient = MeshGradient(
        width: 3, height: 3,
        points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
        colors: [
            Color(red: 0.80, green: 0.95, blue: 0.91), Color(red: 0.82, green: 0.90, blue: 1.00), Color(red: 0.90, green: 0.85, blue: 1.00),
            Color(red: 0.84, green: 0.93, blue: 1.00), .white, Color(red: 0.97, green: 0.88, blue: 0.96),
            Color(red: 0.88, green: 0.86, blue: 1.00), Color(red: 1.00, green: 0.90, blue: 0.86), Color(red: 0.86, green: 0.95, blue: 0.93),
        ]
    )
}

/// The per-app language override, stored where System Settings › Language & Region › Applications stores it.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ko, en

    var id: Self { self }

    var title: Text {
        switch self {
        case .system: Text("시스템 설정")
        // Each language names itself, whatever the app's current language.
        case .ko: Text(verbatim: "한국어")
        case .en: Text(verbatim: "English")
        }
    }

    /// nil when the override is a language this app doesn't offer (say Japanese): that's neither "system" nor a choice here.
    static var saved: AppLanguage? {
        let languages = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!)?["AppleLanguages"] as? [String]
        guard let code = languages?.first else { return .system }
        return allCases.first { $0 != .system && code.hasPrefix($0.rawValue) }
    }

    /// What this run of the app shows: strings are looked up at launch, so a change needs a restart.
    /// `MacerciseApp.init` reads it first, so it's captured at launch rather than when Settings first opens.
    static let atLaunch = saved

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct SettingsView: View {
    @AppStorage(Theme.storageKey) private var theme = Theme.default
    @State private var language: AppLanguage? = AppLanguage.atLaunch

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
                // No restart button: quitting in the middle of a cleanup would leave it half done.
                if language != AppLanguage.atLaunch {
                    Text("앱을 다시 열면 바뀌어요.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        // A grouped Form scrolls by default and comes up a little short; sized to its content it needs no scroller.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: theme) { NSApp.appearance = theme.appearance }
        .onChange(of: language) { language?.save() }
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
