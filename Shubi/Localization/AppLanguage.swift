import Synchronization
import SwiftUI

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
