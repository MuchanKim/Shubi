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
