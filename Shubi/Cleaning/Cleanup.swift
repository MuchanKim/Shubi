import Foundation
import Observation

/// Every deletion goes through here, one at a time: Smart Clean, and the delete sheets in any window.
/// It outlives the screens that start it, so leaving one mid-run neither drops nor repeats the run;
/// when a run ends, every screen in every window scans again for what's left.
@Observable final class Cleanup {
    static let shared = Cleanup()
    private(set) var isRunning = false
    /// Counts finished runs, so screens reload after each.
    private(set) var finished = 0
    /// Smart Clean's failures, shown by the window wherever the user is. A delete sheet shows its own.
    var smartCleanFailures: [Cleaner.Failure] = []
    /// From the tap to the last deletion, so the summary shows the clean working instead of standing still.
    private(set) var isSmartCleaning = false
    /// What's still to delete, counting down item by item; nil while the clean scans first.
    private(set) var smartCleanLeft: Int64?
    /// Everything Smart Clean has deleted since launch; never reset, so a disk reading taken mid-clean subtracts only what came after it.
    private(set) var smartCleanFreed: Int64 = 0

    /// Starts a run unless one is going. Each `true` must be followed by `end()`.
    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func end() {
        ScanCache.shared.invalidateAll()
        isRunning = false
        finished += 1
    }

    /// Scans again first, since an app idle at the last scan may be running now, and deletes only what this scan found.
    /// Deletes for good, so the space comes back at once instead of sitting in the Trash.
    func smartClean(scans: [(key: AnyHashable, scan: @Sendable () async throws -> [ScanItem])]) {
        guard begin() else { return }
        isSmartCleaning = true
        ScanCache.shared.invalidateAll()
        // Through the cache, so screens opened meanwhile share this scan instead of starting their own.
        let pending = scans.map { ScanCache.shared.task(for: $0.key, scan: $0.scan) }
        Task {
            var found: [ScanItem] = []
            // A failed scan only leaves its items out, as on the summary.
            for task in pending { found += (try? await task.value) ?? [] }
            let targets = found.filter(\.isSmartCleanable)
            smartCleanLeft = targets.reduce(0) { $0 + $1.size }
            var failures: [Cleaner.Failure] = []
            // One item at a time, off the main actor, so the total counts down and the water drops as space comes back.
            for item in targets {
                let failed = await Task.detached { Cleaner.clean([item], mode: .permanent) }.value
                failures += failed
                smartCleanLeft? -= item.size
                if failed.isEmpty { smartCleanFreed += item.size }
            }
            smartCleanFailures = failures
            isSmartCleaning = false
            smartCleanLeft = nil
            end()
        }
    }
}
