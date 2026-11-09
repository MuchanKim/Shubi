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
        ScanCache.shared.invalidateAll()
        // Through the cache, so screens opened meanwhile share this scan instead of starting their own.
        let pending = scans.map { ScanCache.shared.task(for: $0.key, scan: $0.scan) }
        Task {
            var found: [ScanItem] = []
            // A failed scan only leaves its items out, as on the summary.
            for task in pending { found += (try? await task.value) ?? [] }
            let targets = found.filter(\.isSmartCleanable)
            smartCleanFailures = await Task.detached { Cleaner.clean(targets, mode: .permanent) }.value
            end()
        }
    }
}
