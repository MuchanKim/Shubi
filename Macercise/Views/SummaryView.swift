import ImageIO
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

    private var tint: WaterTint { WaterTint(theme: theme, colorScheme: colorScheme) }
    @State private var fillsTankWhileScanning = true
    /// Bumped by a filling rescan: a fresh tank starts empty instead of draining the old water first.
    @State private var tankFill = 0

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
            // Start every scan before awaiting any, so they run in parallel.
            let pending = Self.scanned.map { section, sources in
                (section, sources.map { ($0.key, ScanCache.shared.task(for: $0.key, scan: $0.scan)) })
            }
            // Each section lands as soon as its scans finish, not in list order, so the tank fills as the scan goes.
            await withTaskGroup(of: (index: Int, items: [ScanItem], failed: [Int]).self) { group in
                for (index, entry) in pending.enumerated() {
                    let tasks = entry.1.map(\.1)
                    group.addTask {
                        var items: [ScanItem] = []
                        var failed: [Int] = []
                        // A failed scan only leaves its items out; its section screen shows why.
                        for (source, task) in tasks.enumerated() {
                            switch await task.result {
                            case .success(let scanned): items += scanned
                            case .failure: failed.append(source)
                            }
                        }
                        return (index, items, failed)
                    }
                }
                for await done in group {
                    guard !Task.isCancelled else { return }
                    let (section, sources) = pending[done.index]
                    // Retry on the next scan, like the section screens do.
                    done.failed.forEach { ScanCache.shared.invalidate(sources[$0].0) }
                    results[section] = SectionScan(items: done.items, failed: !done.failed.isEmpty)
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
            // Smart clean doesn't depend on reading the disk size.
            ZStack {
                let used = disk.map { Double($0.total - $0.available) / Double(max($0.total, 1)) }
                // While scanning, the water rises with each finished section and reaches the real level when the scan ends.
                let scanned = Double(results.count) / Double(Self.scanned.count)
                DiskTank(fraction: used, level: (used ?? 0) * (isScanning && fillsTankWhileScanning ? scanned : 1), tint: tint)
                    .id(tankFill)
                smartCleanCenter
            }
            .frame(width: Layout.ringSize, height: Layout.ringSize)
            VStack(spacing: Layout.Spacing.xs) {
                if let disk {
                    let used = disk.total - disk.available
                    let percent = (Double(used) / Double(max(disk.total, 1))).formatted(.percent.precision(.fractionLength(0)))
                    Text("\(disk.available.formatted(.byteCount(style: .file))) 남음")
                        .font(.title2.bold())
                    Text("\(disk.total.formatted(.byteCount(style: .file))) 중 \(percent) 사용")
                        .foregroundStyle(.secondary)
                } else {
                    Text("디스크 용량을 읽지 못했어요").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Button {
                confirmEmptyTrash = true
            } label: {
                Label(trashSize.flatMap { $0 > 0 ? String(localized: "휴지통 비우기 · \($0.formatted(.byteCount(style: .file)))") : nil }
                        ?? String(localized: "휴지통 비우기"),
                      systemImage: "trash")
                    .monospacedDigit()
            }
            // Not disabled at 0: only the home Trash is measured, while Finder also empties other disks' Trash.
            .disabled(isEmptyingTrash)
            .help("이 맥의 휴지통 크기예요. 외장 디스크의 휴지통도 함께 비워요.")
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
        VStack(spacing: Layout.Spacing.s) {
            if isScanning {
                ProgressView().controlSize(.small)
                Text("스캔 중…").font(.callout).foregroundStyle(.secondary)
            } else if items.isEmpty, results.values.contains(where: \.failed) {
                // Nothing found, but a failed scan may have missed some: not a clean bill of health.
                Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                Text("일부 항목을 확인하지 못했어요").font(.callout).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                Text("정리할 항목이 없어요").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    Text(items.reduce(0) { $0 + $1.size }, format: .byteCount(style: .file))
                        .font(.title.bold())
                        .monospacedDigit()
                    Text("안전하게 비울 수 있어요").font(.caption).foregroundStyle(.secondary)
                }
                Button("스마트 정리", systemImage: "sparkles", action: smartClean)
                    .buttonStyle(TankButtonStyle(ink: tint.ink))
                    .focusEffectDisabled()
                    .help("다시 만들어지는 캐시와 빌드 데이터, 쓸 수 없게 된 시뮬레이터만 지워요. 실행 중인 앱의 캐시와 내 파일은 그대로 둬요.")
            }
        }
    }

    private var breakdown: some View {
        // A failed section's partial size would shrink every other bar.
        let largest = Self.scanned.compactMap { results[$0.0] }.filter { !$0.failed }.map(\.size).max() ?? 0
        return VStack(alignment: .leading, spacing: Layout.Spacing.m) {
            Text("정리할 수 있는 공간").font(.title3.bold())
                .help("앱 데이터나 시뮬레이터처럼 확인이 필요한 항목도 포함한 크기예요.")
            VStack(spacing: 0) {
                ForEach(Self.scanned, id: \.0) { entry in
                    if entry.0 != Self.scanned.first?.0 { Divider().padding(.leading, Layout.rowDividerInset) }
                    SectionRow(section: entry.0, scan: results[entry.0], largest: largest) {
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

    private func measureDisk() async {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        if let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage {
            disk = (Int64(total), available)
        }
        trashSize = await LibraryScanner.trashSize()
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
        reloadCount += 1
    }
}

private struct SectionScan {
    let items: [ScanItem]
    /// At least one of the section's scans failed, so `items` may be incomplete.
    let failed: Bool

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Disk usage as water in a glass bowl: the fuller the disk, the higher the water.
struct DiskTank: View {
    /// The disk's used fraction, for accessibility; nil until the disk size is read.
    let fraction: Double?
    /// Where the water is drawn (0 empty, 1 full): the used fraction, or less while a scan fills it.
    let level: Double
    let tint: WaterTint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = Self.progress(forLevel: level)
        // "Circle wave animation" by Gonext technologies, LottieFiles, Lottie Simple License (https://lottiefiles.com/page/license).
        // Played as designed, from wherever the water is now to the new level, then left still:
        // rising as a scan fills it, falling when emptying the Trash frees space.
        LottieView(animation: .named("DiskTank"))
            .playbackMode(reduceMotion ? .paused(at: .progress(progress)) : .playing(.fromProgress(nil, toProgress: progress, loopMode: .playOnce)))
            // The asset's water is green; the bowl's rim and glow are gray, which a hue rotation leaves alone.
            .imageProvider(WaterImages(density: tint.density))
            .hueRotation(tint.hue)
            // Gray stays gray: only the water gets deeper.
            .saturation(tint.saturation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("디스크 사용률")
            .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
    }

    /// The animation progress at which the water's mean surface sits at `level` (0 empty, 1 full) of the bowl.
    /// From the asset: the bowl spans y 47…465; the water layer moves linearly from y 785.79 (frame 0) to 321.79 (frame 59)
    /// of 60, and its mean surface sits 309.3 above that position (image row 12 against anchor 199.43, scaled 165%).
    nonisolated static func progress(forLevel level: Double) -> Double {
        let surfaceY = 465 - 418 * min(max(level, 0), 1)
        let frame = (785.79 - (surfaceY + 309.3)) / 464 * 59
        return min(max(frame / 60, 0), 1)
    }
}

/// The asset's embedded images, with the water ("image_0") made `density` times more opaque.
nonisolated struct WaterImages: AnimationImageProvider, Equatable {
    let density: Double

    func imageForAsset(asset: ImageAsset) -> CGImage? {
        // Embedded images carry their PNG as a data URI in `name`.
        guard let comma = asset.name.firstIndex(of: ","),
              let data = Data(base64Encoded: String(asset.name[asset.name.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return asset.id == "image_0" && density != 1 ? Self.denser(image, by: density) ?? image : image
    }

    func contentsGravity(for _: ImageAsset) -> CALayerContentsGravity { .resize }

    /// Scales every premultiplied channel, which raises opacity and keeps the color.
    static func denser(_ image: CGImage, by factor: Double) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for i in 0..<context.bytesPerRow * image.height {
            pixels[i] = UInt8(min(255, Double(pixels[i]) * factor))
        }
        return context.makeImage()
    }
}

/// Each theme's water color, and a label ink that reads 4.5:1 or better on the white pill.
struct WaterTint {
    let hue: Angle
    /// The asset's water is a pale wash; aurora's pastel background needs it denser and deeper to read.
    let density: Double
    let saturation: Double
    let ink: Color

    init(theme: Theme, colorScheme: ColorScheme) {
        switch (theme, colorScheme) {
        case (.aurora, _):
            // Violet, from the aurora gradient, and denser than the other themes; purple-700 ink.
            hue = .degrees(145)
            density = 3.2
            saturation = 1.6
            ink = Color(red: 0.494, green: 0.133, blue: 0.808)
        case (_, .dark):
            // Cyan reads brighter than blue through the translucent water on a dark background; cyan-700 ink.
            hue = .degrees(80)
            density = 1
            saturation = 1
            ink = Color(red: 0.055, green: 0.455, blue: 0.565)
        default:
            // Sky blue; blue-700 ink.
            hue = .degrees(100)
            density = 1
            saturation = 1
            ink = Color(red: 0.114, green: 0.306, blue: 0.847)
        }
    }
}

/// A white pill in the water's color, instead of a system-blue button that ignores the bowl.
private struct TankButtonStyle: ButtonStyle {
    let ink: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
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

/// One section's reclaimable size, with a bar relative to the largest section.
private struct SectionRow: View {
    let section: SidebarSection
    /// nil while the section is still scanning.
    let scan: SectionScan?
    let largest: Int64
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            HStack(spacing: Layout.Spacing.m) {
                Image(systemName: section.icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(section.tint)
                    .frame(width: Layout.iconTileSize, height: Layout.iconTileSize)
                    .background(section.tint.opacity(0.14), in: .rect(cornerRadius: Layout.Spacing.s))
                VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                    Text(section.title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: Layout.rowTitleWidth, alignment: .leading)
                bar
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

    private var bar: some View {
        let fraction = scan.flatMap { $0.failed || largest == 0 ? nil : Double($0.size) / Double(largest) } ?? 0
        return GeometryReader { proxy in
            Capsule().fill(.fill.tertiary)
                .overlay(alignment: .leading) {
                    // A sliver stays visible for tiny sections, so the row doesn't read as empty.
                    Capsule().fill(section.tint.gradient)
                        .frame(width: fraction > 0 ? max(proxy.size.width * fraction, Layout.Spacing.s) : 0)
                }
        }
        .frame(height: Layout.Spacing.s)
        .animation(reduceMotion ? nil : .smooth, value: fraction)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var trailing: some View {
        if scan == nil {
            ProgressView().controlSize(.small)
        } else if scan?.failed == true {
            // A failed section shows no total: a partial one would read as the whole section.
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("스캔 실패")
        } else if let scan {
            Text(scan.size, format: .byteCount(style: .file))
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
    }
}
