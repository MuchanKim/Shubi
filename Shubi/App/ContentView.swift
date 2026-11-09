import SwiftUI

enum SidebarSection: CaseIterable, Identifiable {
    case summary, developer, browser, appCache, orphanedData, packageCache, logs, old, large

    var id: Self { self }

    var title: String {
        switch self {
        case .summary: String(localized: "요약", bundle: .shown, locale: .shown)
        case .developer: String(localized: "개발자", bundle: .shown, locale: .shown)
        case .browser: String(localized: "브라우저 캐시", bundle: .shown, locale: .shown)
        case .appCache: String(localized: "앱 캐시", bundle: .shown, locale: .shown)
        case .orphanedData: String(localized: "삭제된 앱의 데이터", bundle: .shown, locale: .shown)
        case .packageCache: String(localized: "패키지 캐시", bundle: .shown, locale: .shown)
        case .logs: String(localized: "로그", bundle: .shown, locale: .shown)
        case .old: String(localized: "오래된 항목", bundle: .shown, locale: .shown)
        case .large: String(localized: "대용량 파일", bundle: .shown, locale: .shown)
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
            .navigationTitle(section?.title ?? "Shubi")
        }
        // Here, not on the summary: the user may have left it while the clean ran.
        .alert(Text("\(Cleanup.shared.smartCleanFailures.count)개 항목을 지우지 못했어요"),
               isPresented: Binding { !Cleanup.shared.smartCleanFailures.isEmpty } set: { if !$0 { Cleanup.shared.smartCleanFailures = [] } }) {
        } message: {
            Text(verbatim: Cleanup.shared.smartCleanFailures.map { "\($0.url.path(percentEncoded: false)): \($0.reason)" }.joined(separator: "\n"))
        }
        // `Text` follows this; strings looked up in code redraw through `ShownLanguage.track()`.
        .environment(\.locale, ShownLanguage.shared.locale)
        // Not an empty view for the other themes: that leaves the window transparent.
        .containerBackground(theme == .aurora ? AnyShapeStyle(Theme.auroraGradient) : AnyShapeStyle(.windowBackground), for: .window)
    }
}
