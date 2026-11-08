import SwiftUI

@main
struct MacerciseApp: App {
    init() {
        NSApplication.shared.appearance = Theme.saved.appearance
        _ = AppLanguage.atLaunch
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

enum SidebarSection: CaseIterable, Identifiable {
    case summary, developer, browser, appCache, orphanedData, packageCache, logs, old, large

    var id: Self { self }

    var title: String {
        switch self {
        case .summary: String(localized: "요약")
        case .developer: String(localized: "개발자")
        case .browser: String(localized: "브라우저 캐시")
        case .appCache: String(localized: "앱 캐시")
        case .orphanedData: String(localized: "삭제된 앱의 데이터")
        case .packageCache: String(localized: "패키지 캐시")
        case .logs: String(localized: "로그")
        case .old: String(localized: "오래된 항목")
        case .large: String(localized: "대용량 파일")
        }
    }

    var icon: String {
        switch self {
        case .summary: "chart.pie"
        case .developer: "hammer"
        case .browser: "globe"
        case .appCache: "square.stack.3d.up"
        case .orphanedData: "questionmark.folder"
        case .packageCache: "shippingbox"
        case .logs: "doc.text"
        case .old: "clock.arrow.circlepath"
        case .large: "externaldrive"
        }
    }

    /// Shared by the sidebar tiles and the summary rows, so a section reads as the same color everywhere.
    var tint: Color {
        switch self {
        case .summary: .green
        case .developer: .blue
        case .browser: .teal
        case .appCache: .purple
        case .orphanedData: .orange
        case .packageCache: .brown
        case .logs: .indigo
        case .old: .pink
        case .large: .red
        }
    }
}

struct ContentView: View {
    @State private var section: SidebarSection? = .summary
    @AppStorage(Theme.storageKey) private var theme = Theme.default

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $section)
            // In the sidebar, not above the screen: a table that doesn't start at the toolbar draws its header under a blur band.
            .safeAreaInset(edge: .bottom) { FullDiskAccessBanner() }
            .navigationSplitViewColumnWidth(min: Layout.sidebarMinWidth, ideal: Layout.sidebarIdealWidth, max: Layout.sidebarMaxWidth)
        } detail: {
            Group {
                switch section {
                case .summary, nil: SummaryView(section: $section)
                case .developer: DeveloperView()
                case .browser: BrowserCacheView()
                case .appCache: AppCacheView()
                case .orphanedData: OrphanedDataView()
                case .packageCache: PackageCacheView()
                case .logs: LogsView()
                case .old: OldItemsView()
                case .large: LargeFilesView()
                }
            }
            .navigationTitle(section?.title ?? "Macercise")
        }
        // Not an empty view for the other themes: that leaves the window transparent.
        .containerBackground(theme == .aurora ? AnyShapeStyle(Theme.auroraGradient) : AnyShapeStyle(.windowBackground), for: .window)
    }
}
