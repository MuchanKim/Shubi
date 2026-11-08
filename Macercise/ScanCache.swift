import Foundation

/// Scan results shared by the summary and section screens, so moving between them doesn't rescan.
/// Holds the task rather than its result, so a screen opened mid-scan joins the running scan.
final class ScanCache {
    static let shared = ScanCache()

    private var tasks: [AnyHashable: Task<[ScanItem], any Error>] = [:]

    func task(for key: AnyHashable, scan: @escaping @Sendable () async throws -> [ScanItem]) -> Task<[ScanItem], any Error> {
        if let task = tasks[key] { return task }
        let task = Task { try await scan() }
        tasks[key] = task
        return task
    }

    func invalidate(_ key: AnyHashable) { tasks[key] = nil }

    /// After a delete: other sections may list the same space (a runtime's simulator count, the summary totals).
    func invalidateAll() { tasks = [:] }
}
