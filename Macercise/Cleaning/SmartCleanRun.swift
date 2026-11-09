import Foundation
import Observation

/// The one smart clean that can run at a time, from its scan to its last deletion. It outlives the summary screen,
/// so leaving that screen mid-clean neither drops nor repeats it; the window shows its failures wherever the user is.
@Observable final class SmartCleanRun {
    static let shared = SmartCleanRun()
    private(set) var isCleaning = false
    /// Counts finished cleans, so the summary rescans after each.
    private(set) var finished = 0
    var failures: [Cleaner.Failure] = []

    /// Scans again first, since an app idle at the last scan may be running now, and deletes only what this scan found.
    /// Deletes for good, so the space comes back at once instead of sitting in the Trash.
    func start(scans: [(key: AnyHashable, scan: @Sendable () async throws -> [ScanItem])]) {
        guard !isCleaning else { return }
        isCleaning = true
        ScanCache.shared.invalidateAll()
        // Through the cache, so screens opened meanwhile share this scan instead of starting their own.
        let pending = scans.map { ScanCache.shared.task(for: $0.key, scan: $0.scan) }
        Task {
            var found: [ScanItem] = []
            // A failed scan only leaves its items out, as on the summary.
            for task in pending { found += (try? await task.value) ?? [] }
            let targets = found.filter(\.isSmartCleanable)
            let failed = await Task.detached { Cleaner.clean(targets, mode: .permanent) }.value
            // Every screen scans again for what's left, including those not on screen now.
            ScanCache.shared.invalidateAll()
            failures = failed
            isCleaning = false
            finished += 1
        }
    }
}
