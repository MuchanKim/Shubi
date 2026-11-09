import Synchronization
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

    /// Pastel light background, faint enough that the summary's water stays the most colorful thing on screen:
    /// mint, sky and lavender around a white center, so text keeps its light-mode contrast.
    static let auroraGradient = MeshGradient(
        width: 3, height: 3,
        points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
        colors: [
            Color(red: 0.89, green: 0.97, blue: 0.95), Color(red: 0.90, green: 0.95, blue: 1.00), Color(red: 0.95, green: 0.92, blue: 1.00),
            Color(red: 0.91, green: 0.96, blue: 1.00), .white, Color(red: 0.98, green: 0.93, blue: 0.98),
            Color(red: 0.93, green: 0.92, blue: 1.00), Color(red: 1.00, green: 0.95, blue: 0.92), Color(red: 0.92, green: 0.97, blue: 0.96),
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

    /// Saves the choice for the next launch and shows it now: strings come from its .lproj from here on,
    /// and the windows rebuild in it.
    func choose() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        // The system's own list, not the defaults search list, which still holds a launch argument's override.
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let code = self == .system ? Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: system).first ?? "ko" : rawValue
        let locale = Locale(identifier: code)
        chosenLanguage.withLock { $0 = (Bundle.strings(in: code) ?? .main, locale) }
        // Scans keep the strings they were made with: screens scan again, in place, for names and details in the new language.
        ScanCache.shared.invalidateAll()
        ShownLanguage.shared.locale = locale
    }
}

/// The language the windows show.
@Observable final class ShownLanguage {
    static let shared = ShownLanguage()
    var locale = Locale.current

    /// Called by every string lookup. On the main thread, in a view body, it makes that view redraw when the language
    /// changes: only the strings change, and every view keeps its state.
    nonisolated static func track() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { _ = shared.locale }
    }
}

/// The language chosen in Settings during this run; nil until then. Behind a lock: scanners localize off the main actor.
private nonisolated let chosenLanguage = Mutex<(bundle: Bundle, locale: Locale)?>(nil)

nonisolated extension Bundle {
    /// For `String(localized:bundle:)`. Foundation looks strings up in the language settled at launch,
    /// so every lookup names this bundle to follow a language chosen since without a restart.
    static var shown: Bundle {
        ShownLanguage.track()
        return chosenLanguage.withLock { $0?.bundle } ?? .main
    }

    /// The app's strings in one language; nil for a language it doesn't have.
    static func strings(in code: String) -> Bundle? {
        main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

nonisolated extension Locale {
    /// Passed with `Bundle.shown`: the bundle picks the strings, and the locale picks their plural forms.
    static var shown: Locale {
        ShownLanguage.track()
        return chosenLanguage.withLock { $0?.locale } ?? .current
    }
}

nonisolated extension LocalizedStringResource {
    /// This string in the language chosen since launch, like `Bundle.shown`.
    var shown: Self {
        var copy = self
        copy.locale = .shown
        return copy
    }
}

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
