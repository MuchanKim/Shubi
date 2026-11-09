import Lottie
import SwiftUI

/// Disk usage, the smart clean action, and how much each cleanup section could free, measured by running every scanner.
struct SummaryView: View {
    @Binding var section: SidebarSection?

    @State private var results: [SidebarSection: SectionScan] = [:]
    @State private var disk: (total: Int64, available: Int64)?
    @State private var reloadCount = 0
    @State private var showSmartClean = false
    @State private var opensSmartCleanAfterScan = false
    /// nil when the Trash can't be read without Full Disk Access.
    @State private var trashSize: Int64?
    @State private var confirmEmptyTrash = false
    @State private var isEmptyingTrash = false
    @State private var trashError: String?
    @AppStorage(Theme.storageKey) private var theme = Theme.default
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: ThemePalette { ThemePalette(theme: theme, colorScheme: colorScheme) }
    @State private var fillsTankWhileScanning = true
    /// Bumped by a filling rescan: a fresh tank starts empty instead of draining the old water first.
    @State private var tankFill = 0
    @State private var finishedScans = 0
    @FocusState private var isSmartCleanFocused: Bool

    /// Each section's scans, keyed like the section screens key them in `ScanCache`.
    /// Old items and large files aren't counted: they're the user's own files, not "reclaimable" space.
    private static let scanned: [(SidebarSection, [(key: AnyHashable, scan: @Sendable () async throws -> [ScanItem])])] = [
        (.developer, DeveloperView.Target.allCases.map { ($0, $0.scan) }),
        (.browser, [(SidebarSection.browser, BrowserScanner.scan)]),
        (.appCache, [(SidebarSection.appCache, LibraryScanner.appCaches)]),
        (.orphanedData, [(SidebarSection.orphanedData, LibraryScanner.orphanedData)]),
        (.packageCache, [(SidebarSection.packageCache, PackageCacheScanner.scan)]),
        (.logs, [(SidebarSection.logs, LibraryScanner.oldLogs)]),
    ]

    private var isScanning: Bool { results.count < Self.scanned.count }
    /// Finished scans out of all of them: the water rising is the scan's progress bar.
    private var scanProgress: Double { Double(finishedScans) / Double(Self.scanned.map(\.1.count).reduce(0, +)) }
    /// A failed section shows no size, so its partial one isn't counted either.
    private var split: DiskBreakdown {
        DiskBreakdown(sections: Self.scanned.compactMap { entry in
            results[entry.0].flatMap { $0.failed ? nil : (entry.0, $0.size) }
        }, disk: disk)
    }
    private var smartCleanItems: [ScanItem] {
        Self.scanned.flatMap { results[$0.0]?.items ?? [] }.filter(\.isSmartCleanable).sorted { $0.size > $1.size }
    }

    var body: some View {
        // No scroll view: the window's minimum height already fits both columns.
        HStack(alignment: .top, spacing: Layout.Spacing.xl) {
            ringPanel
            breakdown
        }
        .padding(Layout.pageMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            Button("다시 스캔", systemImage: "arrow.clockwise") { rescan() }
        }
        .sheet(isPresented: $showSmartClean) {
            DeleteSheet(items: smartCleanItems, missesFailedScans: results.values.contains(where: \.failed), onDeleted: { rescan(fillingTank: false) })
        }
        .confirmationDialog("휴지통을 비울까요?", isPresented: $confirmEmptyTrash) {
            Button("휴지통 비우기", role: .destructive, action: emptyTrash)
        } message: {
            Text("직접 버린 파일을 포함해 휴지통의 모든 항목이 영구 삭제돼요.")
        }
        .alert("휴지통을 비우지 못했어요", isPresented: Binding { trashError != nil } set: { if !$0 { trashError = nil } }) {
        } message: {
            Text(trashError ?? "")
        }
        .task(id: reloadCount) {
            await measureDisk()
            // A rescan during the measurement has started a newer task; this one must not reset its count.
            guard !Task.isCancelled else { return }
            // Also when the task restarts without a rescan, so the count never runs past the total.
            finishedScans = 0
            // Start every scan before awaiting any, so they run in parallel.
            let pending = Self.scanned.map { section, sources in
                (section, sources.map { ($0.key, ScanCache.shared.task(for: $0.key, scan: $0.scan)) })
            }
            // Each scan lands as soon as it finishes, not in list order, so the tank fills as the scan goes;
            // a section is shown once all of its scans are in.
            await withTaskGroup(of: (index: Int, source: Int, items: [ScanItem]?).self) { group in
                for (index, entry) in pending.enumerated() {
                    for (source, task) in entry.1.map(\.1).enumerated() {
                        group.addTask { (index, source, try? await task.value) }
                    }
                }
                // nil for a scan that failed: it only leaves its items out, and its section screen shows why.
                var landed = pending.map { [[ScanItem]?](repeating: nil, count: $0.1.count) }
                var remaining = pending.map(\.1.count)
                for await done in group {
                    guard !Task.isCancelled else { return }
                    finishedScans += 1
                    landed[done.index][done.source] = done.items
                    remaining[done.index] -= 1
                    guard remaining[done.index] == 0 else { continue }
                    let (section, sources) = pending[done.index]
                    let failed = landed[done.index].indices.filter { landed[done.index][$0] == nil }
                    // Retry on the next scan, like the section screens do.
                    failed.forEach { ScanCache.shared.invalidate(sources[$0].0) }
                    results[section] = SectionScan(items: landed[done.index].flatMap { $0 ?? [] }, failed: !failed.isEmpty)
                }
            }
            guard !Task.isCancelled else { return }
            if opensSmartCleanAfterScan {
                opensSmartCleanAfterScan = false
                showSmartClean = !smartCleanItems.isEmpty
            }
        }
    }

    /// The disk ring with smart clean inside it: the one action this screen is for.
    private var ringPanel: some View {
        VStack(spacing: Layout.Spacing.l) {
            // The level after cleaning up, only once the scan has settled the numbers.
            let cleaned = isScanning ? nil : split.cleanedLevel
            // Smart clean doesn't depend on reading the disk size.
            ZStack {
                let used = disk.map { Double($0.total - $0.available) / Double(max($0.total, 1)) }
                // While scanning, the water rises with each finished scan and reaches the real level when the scan ends.
                let level = (used ?? 0) * (isScanning && fillsTankWhileScanning ? scanProgress : 1)
                DiskTank(fraction: used, level: level, palette: palette)
                    .id(tankFill)
                smartCleanCenter
                    // Once the water covers the middle, the text sits on the water, not on the glass and the window behind it.
                    .environment(\.colorScheme, level < 0.6 ? colorScheme : palette.waterText)
            }
            .frame(width: Layout.ringSize, height: Layout.ringSize)
            VStack(spacing: Layout.Spacing.xs) {
                if let disk {
                    let used = disk.total - disk.available
                    let percent = (Double(used) / Double(max(disk.total, 1))).formatted(.percent.precision(.fractionLength(0)))
                    Text("\(disk.available.formatted(.byteCount(style: .file))) 남음")
                        .font(.title2.weight(.semibold))
                    Text("\(disk.total.formatted(.byteCount(style: .file))) 중 \(percent) 사용")
                        .foregroundStyle(.secondary)
                    if let cleaned {
                        // Cleaning moves items to the Trash by default: the space comes back only once it's emptied.
                        Text("모두 정리하고 휴지통을 비우면 약 \(cleaned.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("디스크 용량을 읽지 못했어요").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            trashCard
            if !isScanning && results.values.contains(where: \.failed) {
                Label("일부 항목을 스캔하지 못해 정리 대상에서 빠졌어요", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(Layout.Spacing.xl)
        // Fills the column, so the card ends where the breakdown does at any window height.
        .frame(width: Layout.ringPanelWidth)
        .frame(maxHeight: .infinity)
        .background(.fill.quaternary, in: .rect(cornerRadius: Layout.cornerRadius))
    }

    @ViewBuilder private var smartCleanCenter: some View {
        let items = smartCleanItems
        let total = items.reduce(0) { $0 + $1.size }
        VStack(spacing: Layout.Spacing.s) {
            if !isScanning, items.isEmpty, results.values.contains(where: \.failed) {
                // Nothing found, but a failed scan may have missed some: not a clean bill of health.
                Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                Text("일부 항목을 확인하지 못했어요").font(.callout).foregroundStyle(.primary.opacity(0.75))
            } else if !isScanning, items.isEmpty {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                Text("정리할 항목이 없어요").font(.callout).foregroundStyle(.primary.opacity(0.75))
            } else {
                // "0GB" rather than the formatter's "Zero KB" before the first section lands.
                let amount = total > 0 ? total.formatted(.byteCount(style: .file))
                                       : total.formatted(.byteCount(style: .file, allowedUnits: .gb, spellsOutZero: false))
                // While scanning, the rising water is the only progress shown, and the total climbs as each section lands.
                VStack(spacing: 0) {
                    Text(amount)
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(total)))
                        .animation(reduceMotion ? nil : .smooth, value: total)
                    Text("안전하게 비울 수 있어요").font(.caption).foregroundStyle(.primary.opacity(0.75))
                }
                .accessibilityRepresentation {
                    // VoiceOver still hears a progress indicator, which the screen shows only as water.
                    if isScanning {
                        ProgressView(value: scanProgress) { Text(amount) }
                            .accessibilityHint("안전하게 비울 수 있어요")
                    } else {
                        VStack { Text(amount); Text("안전하게 비울 수 있어요") }
                            .accessibilityElement(children: .combine)
                    }
                }
                Button("스마트 정리", action: smartClean)
                    .buttonStyle(TankButtonStyle(ink: palette.ink, isFocused: isSmartCleanFocused))
                    .focused($isSmartCleanFocused)
                    .focusEffectDisabled()
                    .help("다시 만들어지는 캐시와 빌드 데이터, 쓸 수 없게 된 시뮬레이터만 지워요. 실행 중인 앱의 캐시와 내 파일은 그대로 둬요.")
                    // Kept in the layout while scanning, so the total doesn't jump when the button appears.
                    .opacity(isScanning ? 0 : 1)
                    .disabled(isScanning)
                    .accessibilityHidden(isScanning)
            }
        }
    }

    /// Emptying the Trash frees space at once, unlike everything the scans found.
    private var trashCard: some View {
        HStack(spacing: Layout.Spacing.m) {
            SymbolTile(systemName: "trash.fill", tint: .gray, size: Layout.iconTileSize)
            VStack(alignment: .leading, spacing: Layout.Spacing.xxs) {
                Text(trashSize.flatMap { $0 > 0 ? String(localized: "휴지통 \($0.formatted(.byteCount(style: .file)))") : nil }
                     ?? String(localized: "휴지통"))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("비우면 바로 공간이 생겨요").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Secondary: smart clean is this screen's one primary action.
            Button("비우기") { confirmEmptyTrash = true }
                .accessibilityLabel("휴지통 비우기")
                // Not disabled at 0: only the home Trash is measured, while Finder also empties other disks' Trash.
                .disabled(isEmptyingTrash)
                .help("이 맥의 휴지통 크기예요. 외장 디스크의 휴지통도 함께 비워요.")
        }
        .padding(Layout.Spacing.m)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: Layout.cornerRadius))
    }

    private var breakdown: some View {
        let split = split
        return VStack(alignment: .leading, spacing: Layout.Spacing.m) {
            VStack(alignment: .leading, spacing: Layout.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.Spacing.s) {
                    Text("정리할 수 있는 공간")
                        .help("앱 데이터나 시뮬레이터처럼 확인이 필요한 항목도 포함한 크기예요.")
                    // While scanning, the sections found so far; nothing before the first lands, rather than "0 KB".
                    if !split.sections.isEmpty {
                        Text(split.reclaimable, format: .byteCount(style: .file))
                    }
                    if let ratio = split.fractionOfDisk(split.reclaimable), !split.sections.isEmpty {
                        Text("디스크의 \(ratio.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                if let disk = split.disk {
                    DiskBar(split: split, reclaimableFill: palette.accent)
                    HStack(spacing: Layout.Spacing.m) {
                        legendItem("정리 가능", palette.accent)
                        legendItem("그 외 사용 \(split.otherUsed.formatted(.byteCount(style: .file)))", DiskBar.otherFill)
                        legendItem("남음 \(disk.available.formatted(.byteCount(style: .file)))", DiskBar.freeFill)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            VStack(spacing: 0) {
                ForEach(Self.scanned, id: \.0) { entry in
                    if entry.0 != Self.scanned.first?.0 { Divider().padding(.leading, Layout.rowDividerInset) }
                    SectionRow(section: entry.0, scan: results[entry.0], share: results[entry.0].flatMap { $0.failed ? nil : split.share($0.size) }) {
                        section = entry.0
                    }
                    // Rows share the window's spare height instead of leaving it empty below the card.
                    .frame(minHeight: Layout.rowMinHeight, maxHeight: .infinity)
                }
            }
            .background(.fill.quaternary, in: .rect(cornerRadius: Layout.cornerRadius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func legendItem(_ title: LocalizedStringKey, _ swatch: some ShapeStyle) -> some View {
        HStack(spacing: Layout.Spacing.xs) {
            RoundedRectangle(cornerRadius: 2).fill(swatch)
                .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.separator) }
                .frame(width: Layout.Spacing.s, height: Layout.Spacing.s)
            Text(title)
        }
    }

    private func measureDisk() async {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        if let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage {
            disk = (Int64(total), available)
        }
        let trash = await LibraryScanner.trashSize()
        // A rescan during the measurement has started a newer task, whose size must not be overwritten by this one's.
        guard !Task.isCancelled else { return }
        trashSize = trash
    }

    /// Finder empties every Trash (other volumes' too) and works without Full Disk Access.
    private func emptyTrash() {
        isEmptyingTrash = true
        Task {
            trashError = await Task.detached { Cleaner.run("/usr/bin/osascript -e 'tell application \"Finder\" to empty trash'") }.value
            await measureDisk()
            isEmptyingTrash = false
        }
    }

    /// Rescans first: what was idle or uninstalled at the last scan may be in use now.
    private func smartClean() {
        rescan()
        opensSmartCleanAfterScan = true
    }

    /// `fillingTank`: the water drains and rises again as sections finish, to show the scan working.
    /// Off after a cleanup, so the water goes straight to the new level instead of refilling.
    private func rescan(fillingTank: Bool = true) {
        fillsTankWhileScanning = fillingTank
        if fillingTank { tankFill += 1 }
        // A plain rescan must not open the sheet a pending smart clean asked for.
        opensSmartCleanAfterScan = false
        ScanCache.shared.invalidateAll()
        results = [:]
        finishedScans = 0
        reloadCount += 1
    }
}

private struct SectionScan {
    let items: [ScanItem]
    /// At least one of the section's scans failed, so `items` may be incomplete.
    let failed: Bool

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// The disk split for the summary's bar: what each finished section could free, the rest of the used space, and free space.
struct DiskBreakdown {
    /// Finished sections' reclaimable sizes, in display order.
    let sections: [(section: SidebarSection, size: Int64)]
    /// nil when the disk size couldn't be read: there's no bar then.
    let disk: (total: Int64, available: Int64)?

    var reclaimable: Int64 { sections.reduce(0) { $0 + $1.size } }
    /// Clamped: the scanned sizes can add up to more than the volume reports as used, with clones or purgeable space.
    var otherUsed: Int64 { disk.map { max(0, $0.total - $0.available - reclaimable) } ?? 0 }

    /// `size` as a fraction of the bar, which spans the disk, or more when the scans overshoot its used space, so nothing overflows.
    func fractionOfBar(_ size: Int64) -> Double {
        guard let disk else { return 0 }
        return Double(size) / Double(max(disk.total, reclaimable + disk.available, 1))
    }

    /// `size` as a fraction of the disk's real capacity, for the figures shown in words; nil without a capacity to divide by.
    func fractionOfDisk(_ size: Int64) -> Double? {
        guard let disk, disk.total > 0 else { return nil }
        return Double(size) / Double(disk.total)
    }

    /// The used fraction left with everything reclaimable cleaned up. nil with nothing to clean, without the disk size,
    /// or when the scans count more than the disk reports as used (clones, purgeable space): there's no honest estimate then.
    var cleanedLevel: Double? {
        guard let disk, reclaimable > 0, reclaimable <= disk.total - disk.available else { return nil }
        return fractionOfDisk(otherUsed)
    }

    /// A section's part of everything reclaimable.
    func share(_ size: Int64) -> Double { reclaimable > 0 ? Double(size) / Double(reclaimable) : 0 }
}

/// The whole disk in one bar: the reclaimable space in the accent, the rest of the used space, then free space.
/// One block, not one per section: the list below it already splits the reclaimable space.
private struct DiskBar: View {
    let split: DiskBreakdown
    let reclaimableFill: Color

    static let otherFill = Color.secondary.opacity(0.3)
    static let freeFill = Color.secondary.opacity(0.12)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                Rectangle().fill(reclaimableFill).frame(width: width * split.fractionOfBar(split.reclaimable))
                Rectangle().fill(Self.otherFill).frame(width: width * split.fractionOfBar(split.otherUsed))
            }
        }
        .frame(height: Layout.Spacing.m)
        .background(Self.freeFill)
        .clipShape(.rect(cornerRadius: Layout.Spacing.xs))
        .animation(reduceMotion ? nil : .smooth, value: split.reclaimable)
        // The header and the legend say the same in words.
        .accessibilityHidden(true)
    }
}

/// Disk usage as water in a glass orb: the fuller the disk, the higher the water.
private struct DiskTank: View {
    /// The disk's used fraction, for accessibility; nil until the disk size is read.
    let fraction: Double?
    /// Where the water is drawn (0 empty, 1 full): the used fraction, or less while a scan fills it.
    let level: Double
    let palette: ThemePalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var water = Water()
    /// Off a few seconds after the water stops: the waves finish their cycle and rest, so an idle summary draws nothing.
    @State private var isWaving = true

    var body: some View {
        // "water filling Glass orb" by Aneesh Ravi, LottieFiles, Lottie Simple License (https://lottiefiles.com/page/license),
        // split in two files: the waves, and the glass drawn over them.
        ZStack {
            LottieView(animation: .named("DiskTank"))
                // The Core Animation engine ignores closure value providers, and the water's height is one.
                .configuration(LottieConfiguration(renderingEngine: .mainThread))
                // Drawn on the CPU every frame, so no more often than the asset's own 30 fps.
                .configure(\.respectAnimationFrameRate, to: true)
                // Frames 0…116 loop the waves seamlessly; the code, not the timeline, sets how high they are.
                // Resting ends on frame 116, the loop's seam, so waving again from frame 0 doesn't jump.
                .playbackMode(reduceMotion ? .paused(at: .frame(0))
                              : .playing(isWaving ? .fromFrame(0, toFrame: 116, loopMode: .loop) : .fromFrame(nil, toFrame: 116, loopMode: .playOnce)))
                // A paused animation never asks the closures again, so under Reduce Motion a new level arrives as a new provider.
                .valueProvider(reduceMotion ? PointValueProvider(TankMotion.frontWave.position(forLevel: level)) : water.front,
                               for: "Shape Layer 2.Transform.Position")
                .valueProvider(reduceMotion ? PointValueProvider(TankMotion.backWave.position(forLevel: level)) : water.back,
                               for: "Shape Layer 6.Transform.Position")
                .valueProvider(GradientValueProvider(palette.water.map { $0.lottie() }), for: "Shape Layer 2.Rectangle 1.Gradient Fill 1.Colors")
                .valueProvider(GradientValueProvider(palette.backWater.map { $0.lottie() }), for: "Shape Layer 6.Rectangle 1.Gradient Fill 1.Colors")
            // Static, and on the default engine: the main-thread one drops gradients with transparency, which is all the glass is.
            LottieView(animation: .named("DiskTankGlass"))
                // The asset's rim is near-black; the palette's is light, as if part of the window.
                .valueProvider(GradientValueProvider(palette.glass.map { $0.lottie() }, locations: ThemePalette.glassStops),
                               for: "Shape Layer 1.Ellipse 1.Gradient Fill 1.Colors")
        }
        // The canvas is 307×283 around a 250-point orb: drawn this large, the orb itself fills the ring's size,
        // and only the canvas's empty margins spill past it.
        .frame(width: Layout.ringSize * 307 / 250, height: Layout.ringSize * 283 / 250)
        .frame(width: Layout.ringSize, height: Layout.ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("디스크 사용률")
        .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
        // A new view starts its water at the bottom.
        .onAppear { water.move = water.move.retargeted(to: level, at: .now) }
        .onChange(of: level) { _, new in water.move = water.move.retargeted(to: new, at: .now) }
        .task(id: level) {
            isWaving = true
            // The longest move, then a moment to settle.
            try? await Task.sleep(for: .seconds(TankMotion.fullRangeDuration + 2))
            if !Task.isCancelled { isWaving = false }
        }
    }
}

/// The water's current move, read by Lottie on every frame: the drawn water is wherever the move has it at that moment.
private final class Water {
    var move = TankMotion.Move(from: 0, to: 0, start: .distantPast, duration: 0)
    lazy var front = provider(for: TankMotion.frontWave)
    lazy var back = provider(for: TankMotion.backWave)

    private func provider(for wave: TankMotion.Wave) -> PointValueProvider {
        // Weak: the animation view can draw a last frame after this view's state is gone.
        PointValueProvider { [weak self] _ in wave.position(forLevel: self?.move.level(at: .now) ?? 0) }
    }
}

/// How `DiskTank` places and moves its water.
nonisolated enum TankMotion {
    /// Even a 1%p change takes this long, so the water is seen to move.
    static let minimumDuration: TimeInterval = 1
    /// Filling the orb from empty to full takes this long; a longer move takes its share of it.
    static let fullRangeDuration: TimeInterval = 2

    /// The water moving from one level to another, easing to a stop.
    struct Move: Equatable {
        var from: Double
        var to: Double
        var start: Date
        var duration: TimeInterval
        /// Level per second at `start`, carried over from the move this one replaced: scans landing a moment apart
        /// would otherwise stop the water dead each time, and it would fall far behind.
        var velocity: Double = 0

        /// Where the water is at `time`.
        func level(at time: Date) -> Double {
            let t = progress(at: time)
            guard t < 1 else { return to }
            // Cubic Hermite: leaves `from` at `velocity` and arrives at `to` at rest.
            return from + (to - from) * t * t * (3 - 2 * t) + velocity * duration * t * (1 - t) * (1 - t)
        }

        func velocity(at time: Date) -> Double {
            let t = progress(at: time)
            guard t < 1 else { return 0 }
            return 6 * (to - from) * t * (1 - t) / duration + velocity * (1 - t) * (1 - 3 * t)
        }

        /// A move to `level` from wherever the water is at `time`, at the speed it has there, so it never jumps or stops dead.
        func retargeted(to level: Double, at time: Date) -> Move {
            let here = self.level(at: time)
            let change = level - here
            let duration = max(TankMotion.minimumDuration, abs(change) * TankMotion.fullRangeDuration)
            // Only speed toward the new level carries over, and at most 3× the average: any faster and the water overshoots.
            let carried = change == 0 ? 0 : min(max(velocity(at: time) * duration / change, 0), 3)
            return Move(from: here, to: level, start: time, duration: duration, velocity: carried * change / duration)
        }

        private func progress(at time: Date) -> Double { duration > 0 ? min(max(time.timeIntervalSince(start) / duration, 0), 1) : 1 }
    }

    /// A wave layer's designed path: at `empty` on frame 0, at `full` on frame 122.
    struct Wave {
        let empty: CGPoint
        let full: CGPoint

        /// On its own path, so the two waves keep the designer's offset at every level.
        func position(forLevel level: Double) -> CGPoint {
            let t = TankMotion.pathFraction(forLevel: level)
            return CGPoint(x: empty.x + (full.x - empty.x) * t, y: empty.y + (full.y - empty.y) * t)
        }
    }

    static let frontWave = Wave(empty: CGPoint(x: 392, y: 351), full: CGPoint(x: -118, y: 71))
    static let backWave = Wave(empty: CGPoint(x: 222, y: 351), full: CGPoint(x: -128, y: 71))

    /// How far along its path a wave sits at `level` (0 empty, 1 full) of the orb. From the asset: the orb spans y 16…266,
    /// and a wave's mean surface sits 63 above its layer position, its rounded crests 16 higher still.
    /// Empty keeps the crests just below the orb; full puts the mean surface at its top.
    static func pathFraction(forLevel level: Double) -> Double {
        let empty = 266 + 63 + 16.0, full = 16 + 63.0
        let y = empty - (empty - full) * min(max(level, 0), 1)
        return (351 - y) / (351 - 71)
    }
}

private extension Color {
    /// Lottie takes its own color type. The palette's colors are fixed RGB, so a default environment resolves them.
    func lottie() -> LottieColor {
        let resolved = resolve(in: EnvironmentValues())
        return LottieColor(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue), a: Double(resolved.opacity))
    }
}

/// A white pill in the water's color, instead of a system-blue button that ignores the bowl.
private struct TankButtonStyle: ButtonStyle {
    let ink: Color
    /// The button's own focus, passed in: `\.isFocused` here can report an ancestor's focus instead.
    let isFocused: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, Layout.Spacing.l)
            .padding(.vertical, Layout.Spacing.s)
            .background(.white.opacity(isHovered ? 1 : 0.92), in: .capsule)
            // Drawn here, since the system ring is turned off for this button: it would be a rectangle around a pill.
            .overlay { if isFocused { Capsule().strokeBorder(ink, lineWidth: 2) } }
            .shadow(color: .black.opacity(0.18), radius: configuration.isPressed ? 1 : 4, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
    }
}

/// One section's reclaimable size and its part of the total.
private struct SectionRow: View {
    let section: SidebarSection
    /// nil while the section is still scanning.
    let scan: SectionScan?
    /// The section's part of everything reclaimable; nil while it scans or when its scan failed.
    let share: Double?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Layout.Spacing.m) {
                // The sidebar's tile: the row opens that section.
                SymbolTile(systemName: section.icon, tint: section.tint, size: Layout.iconTileSize)
                VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                    Text(section.title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Layout.Spacing.m)
                if let share {
                    // A few MB of a large total would round to 0.0%, as if the section had nothing.
                    Text(share > 0 && share < 0.001 ? "<\(0.001.formatted(.percent.precision(.fractionLength(1))))"
                                                    : share.formatted(.percent.precision(.fractionLength(1))))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                trailing
                    .frame(width: Layout.sizeColumnWidth, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Layout.cardPadding)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        guard let scan else { return String(localized: "스캔 중…") }
        return scan.failed ? String(localized: "스캔하지 못했어요") : String(localized: "\(scan.items.count)개 항목")
    }

    @ViewBuilder private var trailing: some View {
        if scan == nil {
            ScanningBar()
        } else if scan?.failed == true {
            // A failed section shows no total: a partial one would read as the whole section.
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("스캔 실패")
        } else if let scan {
            Text(scan.size, format: .byteCount(style: .file))
                .font(.body.weight(.medium))
                .monospacedDigit()
        }
    }
}
