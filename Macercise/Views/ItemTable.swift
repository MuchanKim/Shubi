import QuickLook
import SwiftUI

/// Shared scan → list → select → delete flow. `scanKey` also names the result in `ScanCache`, so it must be unique per scan.
struct ItemTable<Key: Hashable>: View {
    let scanKey: Key
    let scan: @Sendable () async throws -> [ScanItem]
    var preselect: (ScanItem) -> Bool = { _ in false }

    @State private var items: [ScanItem] = []
    @State private var selection: Set<ScanItem.ID> = []
    @State private var isScanning = false
    @State private var failure: String?
    @State private var reloadCount = 0
    @State private var deleting: DeleteTargets?
    /// The scan the list shows, to tell a language change (scan again in place) from a reload (start over).
    @State private var loaded: ScanTrigger<Key>?
    @State private var sortOrder = [KeyPathComparator(\ScanItem.size, order: .reverse)]
    @State private var showInspector = true
    @State private var previewURL: URL?
    @AppStorage(Theme.storageKey) private var theme = Theme.default

    // Running apps can't be deleted safely, so they never count as selected.
    private var selected: [ScanItem] { items.filter { selection.contains($0.id) && !$0.isRunning } }
    private var inspected: ScanItem? { selection.count == 1 ? items.first { selection.contains($0.id) } : nil }

    var body: some View {
        let sorted = items.sorted(using: sortOrder)
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("이름", value: \.name) { item in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(item.name)
                    if item.isRunning {
                        Text("실행 중").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(item.isRunning ? 0.5 : 1)
            }
            .width(min: Layout.nameColumnMinWidth)
            TableColumn("크기", value: \.size) { Text($0.size, format: .byteCount(style: .file)) }
                .width(Layout.sizeColumnWidth)
            TableColumn("마지막 사용", value: \.lastUsedSort) { item in
                if let lastUsed = item.lastUsed {
                    Text(lastUsed.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .shown)))
                } else {
                    // No record isn't "never used": an app update or Spotlight reindex can clear it.
                    Text("기록 없음").help("앱 업데이트 등으로 사용 기록이 지워졌을 수 있어요.")
                }
            }
            .width(Layout.dateColumnWidth)
            TableColumn("위치") {
                Text($0.url.deletingLastPathComponent().path(percentEncoded: false))
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: Layout.locationColumnMinWidth)
        }
        // Let the aurora gradient show through instead of a white slab.
        .scrollContentBackground(theme == .aurora ? .hidden : .automatic)
        .contextMenu(forSelectionType: ScanItem.ID.self) { ids in
            Button("미리보기") { previewURL = ids.first }
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(Array(ids)) }
        } primaryAction: { ids in
            NSWorkspace.shared.activateFileViewerSelecting(Array(ids))
        }
        // Space opens Quick Look, like Finder.
        .onKeyPress(.space) {
            guard let first = sorted.first(where: { selection.contains($0.id) }) else { return .ignored }
            previewURL = first.url
            return .handled
        }
        .quickLookPreview($previewURL, in: sorted.map(\.url))
        // Before `.inspector`, so the overlay centers on the table, not on the table plus the inspector.
        .overlay {
            if isScanning {
                VStack(spacing: Layout.Spacing.s) {
                    Text("스캔 중…").foregroundStyle(.secondary)
                    ScanningBar().frame(width: Layout.scanningBarWidth)
                }
                .accessibilityRepresentation { ProgressView("스캔 중…") }
            } else if let failure {
                ContentUnavailableView("스캔하지 못했어요", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if items.isEmpty {
                ContentUnavailableView("정리할 항목이 없어요", systemImage: "sparkles")
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let inspected {
                    ItemInspector(item: inspected)
                } else {
                    ContentUnavailableView("항목을 하나 선택하세요", systemImage: "info.circle")
                }
            }
            .inspectorColumnWidth(min: Layout.inspectorMinWidth, ideal: Layout.inspectorIdealWidth, max: Layout.inspectorMaxWidth)
            .toolbar {
                Button("정보", systemImage: "info.circle") { showInspector.toggle() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(selected.count)개 선택").foregroundStyle(.secondary)
                Text(selected.reduce(0) { $0 + $1.size }, format: .byteCount(style: .file))
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Button("다시 스캔", systemImage: "arrow.clockwise") {
                    ScanCache.shared.invalidate(scanKey)
                    reloadCount += 1
                }
                Button("삭제…", role: .destructive) {
                    deleting = DeleteTargets(items: selected)
                }
                    .disabled(selected.isEmpty)
            }
            // 16, not the page margin: lines up with the table rows, which keep the system's inset.
            .padding(.horizontal, Layout.Spacing.l)
            .padding(.vertical, Layout.Spacing.m)
            .background(.bar)
        }
        .sheet(item: $deleting) { targets in
            DeleteSheet(items: targets.items) {
                ScanCache.shared.invalidateAll()
                reloadCount += 1
            }
        }
        // Restarted, and the superseded scan's result dropped, by any change of the key, a reload or the language.
        .task(id: ScanTrigger(key: scanKey, reload: reloadCount, language: ShownLanguage.shared.locale.identifier)) {
            let trigger = ScanTrigger(key: scanKey, reload: reloadCount, language: ShownLanguage.shared.locale.identifier)
            // A language change scans again in place: the list keeps its selection and sort, and only the words change.
            let inPlace = loaded.map { $0.key == trigger.key && $0.reload == trigger.reload } ?? false
            if !inPlace {
                // Clear the previous scan's list, so its selection can't be deleted while this one runs.
                items = []
                selection = []
                failure = nil
                isScanning = true
                // The cleared list stands for no scan, so going back to it before this one lands starts over too.
                loaded = nil
            }
            let result = await ScanCache.shared.task(for: scanKey, scan: scan).result
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let scanned):
                items = scanned
                if inPlace {
                    selection.formIntersection(scanned.map(\.id))
                } else {
                    selection = Set(scanned.filter(preselect).map(\.id))
                }
                failure = nil
                // Only a list that's on screen can be refreshed in place.
                loaded = trigger
            case .failure(let error):
                failure = error.localizedDescription
                // Retry on the next visit, e.g. after the user accepts the Xcode license.
                ScanCache.shared.invalidate(scanKey)
            }
            isScanning = false
        }
    }
}

private struct ScanTrigger<Key: Hashable>: Equatable {
    let key: Key
    let reload: Int
    let language: String
}
