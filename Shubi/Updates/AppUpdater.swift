import Combine
import Sparkle

/// Sparkle, reading the appcast published with each GitHub release. It checks once a day on its own;
/// the app menu's "Check for Updates…" checks now.
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
