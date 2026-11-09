import SwiftUI

@main
struct ShubiApp: App {
    @StateObject private var updater = AppUpdater()

    init() {
        NSApplication.shared.appearance = Theme.saved.appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        }
        .defaultSize(width: Layout.windowDefaultWidth, height: Layout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                // The menu bar's own items keep the language the app launched in, so this one does too.
                Button(String(localized: "업데이트 확인…", bundle: .shown, locale: .shown)) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
