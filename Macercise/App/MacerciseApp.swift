import SwiftUI

@main
struct MacerciseApp: App {
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

        Settings {
            SettingsView()
        }
    }
}
