import SwiftUI

/// A highlight sweeping along a track, for a scan of unknown length; it stands still under Reduce Motion.
struct ScanningBar: View {
    @AppStorage(Theme.storageKey) private var theme = Theme.default
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint = ThemePalette(theme: theme, colorScheme: colorScheme).accent
        TimelineView(.animation(paused: reduceMotion)) { context in
            // One sweep every 1.2 s, from just off the leading end to just off the trailing one; centered when still.
            let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            GeometryReader { proxy in
                let highlight = proxy.size.width * 0.4
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: highlight)
                    .offset(x: (proxy.size.width + highlight) * phase - highlight)
            }
        }
        .frame(height: Layout.Spacing.xs)
        .background(.fill.tertiary)
        .clipShape(.capsule)
        // VoiceOver hears a progress indicator, as it did with the spinner this replaces.
        .accessibilityRepresentation { ProgressView() }
    }
}
