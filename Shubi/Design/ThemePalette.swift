import SwiftUI

/// Every themed color of the summary and the scanning bars, one theme per case: changing a theme's colors changes only this table.
/// Sections keep their own colors: those say which section is which.
struct ThemePalette {
    /// The front wave, from its surface down: three stops, evenly spaced.
    let water: [Color]
    /// The translucent wave behind it, drawn at the asset's 35% opacity: three stops, evenly spaced.
    let backWater: [Color]
    /// The glass over the water, from the orb's middle out to its rim, opacity included: one stop per `glassStops`.
    let glass: [Color]
    /// The scheme whose text reads over the water: `.light` for dark text, `.dark` for white.
    let waterText: ColorScheme
    /// Labels on the white pills, 4.5:1 or better.
    let ink: Color
    /// Scanning bars and the reclaimable part of the disk bar.
    let accent: Color

    /// Where `glass`'s stops sit, from the orb's middle (0) to its rim (1): a sheen, clear glass, then the rim.
    static let glassStops: [Double] = [0, 0.45, 0.82, 0.95, 1]

    init(theme: Theme, colorScheme: ColorScheme) {
        switch (theme, colorScheme) {
        case (.aurora, _):
            // The aurora window's own mint, sky and lavender, one step deeper; indigo ink.
            water = [Color(red: 0.52, green: 0.86, blue: 0.78), Color(red: 0.53, green: 0.70, blue: 0.96), Color(red: 0.69, green: 0.58, blue: 0.95)]
            backWater = [Color(red: 0.72, green: 0.93, blue: 0.92), Color(red: 0.72, green: 0.80, blue: 1.0), Color(red: 0.84, green: 0.74, blue: 1.0)]
            glass = Self.glass(middle: 0.55, rim: 0.95)
            waterText = .light
            ink = Color(red: 0.33, green: 0.36, blue: 0.78)
            accent = Color(red: 0.53, green: 0.70, blue: 0.96)
        case (_, .dark):
            // Midnight blue: bright enough to read as water on a dark window without turning neon; white text over it.
            water = [Color(red: 0.33, green: 0.58, blue: 1.0), Color(red: 0.24, green: 0.38, blue: 0.92), Color(red: 0.36, green: 0.28, blue: 0.80)]
            backWater = [Color(red: 0.40, green: 0.62, blue: 1.0), Color(red: 0.32, green: 0.45, blue: 0.95), Color(red: 0.42, green: 0.36, blue: 0.88)]
            glass = Self.glass(middle: 0.06, rim: 0.35)
            waterText = .dark
            ink = Color(red: 0.20, green: 0.30, blue: 0.80)
            accent = Color(red: 0.33, green: 0.58, blue: 1.0)
        default:
            // Soft sky; blue-700 ink.
            water = [Color(red: 0.55, green: 0.82, blue: 1.0), Color(red: 0.33, green: 0.62, blue: 0.98), Color(red: 0.30, green: 0.48, blue: 0.92)]
            backWater = [Color(red: 0.75, green: 0.90, blue: 1.0), Color(red: 0.60, green: 0.78, blue: 1.0), Color(red: 0.55, green: 0.66, blue: 0.98)]
            glass = Self.glass(middle: 0.7, rim: 0.95)
            waterText = .light
            ink = Color(red: 0.114, green: 0.306, blue: 0.847)
            accent = Color(red: 0.33, green: 0.62, blue: 0.98)
        }
    }

    /// White glass: a sheen of `middle` opacity fading to clear, then a rim of `rim` opacity.
    private static func glass(middle: Double, rim: Double) -> [Color] {
        [middle, middle / 2, 0, rim / 2, rim].map { Color.white.opacity($0) }
    }
}
