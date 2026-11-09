import SwiftUI

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
struct DiskBar: View {
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
