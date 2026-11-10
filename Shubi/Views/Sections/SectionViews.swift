import SwiftUI

struct BrowserCacheView: View {
    @State private var unusedDays = 30

    var body: some View {
        let cutoff = Date.now.addingTimeInterval(-Double(unusedDays) * 86_400)
        ItemTable(scanKey: SidebarSection.browser, scan: BrowserScanner.scan,
                  preselect: { !$0.isRunning && ($0.isOrphaned || $0.lastUsed.map { $0 < cutoff } ?? false) })
            // The scan doesn't depend on the cutoff; recreating the table reapplies the preselection to the cached result.
            .id(unusedDays)
            .toolbar {
                Picker("미사용 기준", selection: $unusedDays) {
                    Text("7일 이상 미사용").tag(7)
                    Text("30일 이상 미사용").tag(30)
                    Text("90일 이상 미사용").tag(90)
                }
            }
    }
}

struct AIToolsView: View {
    @State private var scope = AIScanner.Scope.all
    @State private var unusedDays = 30

    var body: some View {
        let cutoff = Date.now.addingTimeInterval(-Double(unusedDays) * 86_400)
        // ItemTable leaves running and review-only rows out of the preselection itself.
        ItemTable(scanKey: scope, scan: { [scope] in await AIScanner.scan(scope) },
                  preselect: { $0.lastUsed.map { $0 < cutoff } ?? false }, showsTool: true)
            // As in BrowserCacheView: recreating the table reapplies the preselection to the cached scan.
            .id(unusedDays)
            .toolbar {
                Picker("도구", selection: $scope) {
                    Text("모든 도구").tag(AIScanner.Scope.all)
                    ForEach(AITool.allCases) { Text(verbatim: $0.spec.name).tag(AIScanner.Scope.tool($0)) }
                    Text("알 수 없는 도구").tag(AIScanner.Scope.unknown)
                }
                Picker("미사용 기준", selection: $unusedDays) {
                    Text("7일 이상 미사용").tag(7)
                    Text("30일 이상 미사용").tag(30)
                    Text("90일 이상 미사용").tag(90)
                }
            }
    }
}

struct OldItemsView: View {
    enum Target: CaseIterable {
        case apps, documents

        var title: LocalizedStringResource {
            switch self {
            case .apps: "앱"
            case .documents: "문서"
            }
        }
    }

    @State private var target = Target.apps
    @State private var days = 180

    var body: some View {
        ItemTable(scanKey: "\(target)-\(days)") { [target, days] in
            switch target {
            case .apps: await SpotlightScanner.oldApps(unusedFor: days)
            case .documents: await SpotlightScanner.oldDocuments(unusedFor: days)
            }
        }
        .toolbar {
            Picker("종류", selection: $target) {
                ForEach(Target.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            Picker("기간", selection: $days) {
                Text("90일").tag(90)
                Text("180일").tag(180)
                Text("1년").tag(365)
            }
        }
    }
}

struct LargeFilesView: View {
    @State private var minMB: Int64 = 500
    @State private var videosOnly = false

    var body: some View {
        ItemTable(scanKey: "\(minMB)-\(videosOnly)") { [minMB, videosOnly] in
            await SpotlightScanner.largeFiles(minBytes: minMB * 1_000_000, videosOnly: videosOnly)
        }
        .toolbar {
            Picker("필터", selection: $videosOnly) {
                Text("전체").tag(false)
                Text("동영상만").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("최소 크기", selection: $minMB) {
                Text("100MB 이상").tag(Int64(100))
                Text("500MB 이상").tag(Int64(500))
                Text("1GB 이상").tag(Int64(1000))
            }
        }
    }
}

struct AppCacheView: View {
    var body: some View {
        ItemTable(scanKey: SidebarSection.appCache, scan: LibraryScanner.appCaches, preselect: { $0.isOrphaned && !$0.isRunning })
    }
}

struct OrphanedDataView: View {
    var body: some View {
        ItemTable(scanKey: SidebarSection.orphanedData, scan: LibraryScanner.orphanedData)
    }
}

struct DeveloperView: View {
    enum Target: CaseIterable {
        case simulators, runtimes, deviceSupport, derivedData, previews, archives

        var title: LocalizedStringResource {
            switch self {
            case .simulators: "시뮬레이터"
            case .runtimes: "런타임"
            case .deviceSupport: "DeviceSupport"
            case .derivedData: "DerivedData"
            case .previews: "Previews"
            case .archives: "Archives"
            }
        }

        nonisolated var scan: @Sendable () async throws -> [ScanItem] {
            switch self {
            case .simulators: DeveloperScanner.simulators
            case .runtimes: DeveloperScanner.runtimes
            case .deviceSupport: DeveloperScanner.deviceSupport
            case .derivedData: DeveloperScanner.derivedData
            case .previews: DeveloperScanner.previews
            case .archives: DeveloperScanner.archives
            }
        }
    }

    @State private var target = Target.simulators

    var body: some View {
        ItemTable(scanKey: target, scan: target.scan, preselect: { $0.kind == .simulator && $0.isOrphaned })
        .toolbar {
            Picker("종류", selection: $target) {
                ForEach(Target.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
        }
    }
}

struct PackageCacheView: View {
    var body: some View {
        ItemTable(scanKey: SidebarSection.packageCache, scan: PackageCacheScanner.scan)
    }
}

struct LogsView: View {
    var body: some View {
        // Every listed log is already 30 days old.
        ItemTable(scanKey: SidebarSection.logs, scan: LibraryScanner.oldLogs, preselect: { _ in true })
    }
}
