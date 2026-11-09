import AppKit

nonisolated struct ScanItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case browserCache, cache, appData, app, document, largeFile
        case simulator, runtime, deviceSupport, derivedData, previews, packageCache, archive, log
    }

    let url: URL
    let name: String
    let size: Int64
    let lastUsed: Date?
    let kind: Kind
    /// What actually gets deleted. For a cache this is the cache folder's contents, not the folder.
    var targets: [URL]
    var isRunning = false
    /// The app whose files these are, checked again right before cleaning: it may have started since the scan.
    var ownerBundleID: String?
    /// Other apps that use the same files (Firefox editions share one cache), checked like the owner.
    var sharedWith: [String] = []
    /// Command-line tools that use these files without any app running (`xcodebuild`, `swift build`), checked like the owner.
    var usedByTools: [String] = []
    /// The owner is gone: an uninstalled app's cache or data, or a simulator whose runtime was removed.
    var isOrphaned = false
    /// No installed app owns it and it isn't an uninstalled app's either, so whether it's in use can't be checked.
    var isOwnerUnknown = false
    /// An app's data in ~/Library, deleted only after the app itself is gone.
    var leftovers: [URL] = []
    /// When set, cleaning runs this shell command (e.g. `xcrun simctl delete …`) instead of deleting `targets`.
    var command: String?
    /// Extra facts only the scanner knows, shown in the inspector.
    var details: [Fact] = []

    var id: URL { url }
    var lastUsedSort: Date { lastUsed ?? .distantPast }

    /// Smart clean takes only what apps and tools rebuild on their own, or what can no longer run.
    /// Not `DeletionRisk.Level.safe`: that also covers App Store apps and downloaded installers, which are the user's files.
    var isSmartCleanable: Bool {
        guard !isRunning, !isOwnerUnknown else { return false }
        switch kind {
        // Commands skip the trash and can do more than clear a cache: `brew cleanup --prune=all` also removes old kegs.
        case .browserCache, .cache, .derivedData, .deviceSupport, .packageCache: return command == nil
        // Xcode recreates preview devices for the next preview. Any other simulator holds apps and data the user put there,
        // even one whose runtime is gone: that only means it can't run until the runtime is back.
        case .previews: return true
        // Archives hold the only copy of a shipped build's symbols; old logs don't come back once deleted.
        case .app, .document, .largeFile, .appData, .simulator, .runtime, .archive, .log: return false
        }
    }

    init(url: URL, name: String, size: Int64, lastUsed: Date?, kind: Kind, targets: [URL]? = nil,
         isRunning: Bool = false, ownerBundleID: String? = nil, sharedWith: [String] = [], usedByTools: [String] = [], isOrphaned: Bool = false, isOwnerUnknown: Bool = false,
         leftovers: [URL] = [], command: String? = nil, details: [Fact] = []) {
        self.url = url
        self.name = name
        self.size = size
        self.lastUsed = lastUsed
        self.kind = kind
        self.targets = targets ?? [url]
        self.isRunning = isRunning
        self.ownerBundleID = ownerBundleID
        self.sharedWith = sharedWith
        self.usedByTools = usedByTools
        self.isOrphaned = isOrphaned
        self.isOwnerUnknown = isOwnerUnknown
        self.leftovers = leftovers
        self.command = command
        self.details = details
    }
}

/// Space on this disk, so an iCloud file whose data was evicted counts as 0.
nonisolated func allocatedSize(of url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
    guard values?.isDirectory == true else { return Int64(values?.totalFileAllocatedSize ?? 0) }
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        total += Int64((try? file.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
    }
    return total
}

nonisolated func directoryContents(_ url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
}

nonisolated func modificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

/// Single-quotes a value for `/bin/zsh -c`.
nonisolated func shellQuote(_ value: String) -> String {
    "'" + value.replacing("'", with: "'\\''") + "'"
}

/// A failed or hung external command, worded for the user.
nonisolated struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs a process and returns its standard output.
nonisolated func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws(CommandError) -> Data {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    // A tool that prompts (pod, yarn) reads EOF and fails instead of waiting forever.
    process.standardInput = FileHandle.nullDevice
    // Files, not pipes: a child that outlives a timed-out parent can't keep a read open.
    let logs = ["out", "err"].map { FileManager.default.temporaryDirectory.appending(path: "Macercise-\(UUID().uuidString).\($0)") }
    defer { logs.forEach { try? FileManager.default.removeItem(at: $0) } }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        let handles = try logs.map { log in
            FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
            return try FileHandle(forWritingTo: log)
        }
        defer { handles.forEach { try? $0.close() } }
        process.standardOutput = handles[0]
        process.standardError = handles[1]
        try process.run()
    } catch {
        throw CommandError(message: error.localizedDescription)
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        // Process starts the child in its own group and terminate() signals all of it; SIGKILL whatever ignores SIGTERM.
        // shortcut: a child that calls setsid()/setpgid() escapes both signals, and the PGID could be reused before the SIGKILL; track descendants with a supervisor if a scanned tool ever daemonizes.
        let group = getpgid(process.processIdentifier)
        process.terminate()
        _ = exited.wait(timeout: .now() + 2)
        if group > 0, group != getpgrp() { kill(-group, SIGKILL) }
        let limit = Duration.seconds(timeout).formatted(.units(allowed: [.minutes, .seconds], width: .wide).locale(.shown))
        throw CommandError(message: String(localized: "\(limit) 안에 끝나지 않아서 중단했어요", bundle: .shown, locale: .shown))
    }
    guard process.terminationStatus == 0 else {
        let errors = String(decoding: (try? Data(contentsOf: logs[1])) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandError(message: errors.isEmpty ? String(localized: "명령이 실패했어요 (종료 코드 \(process.terminationStatus))", bundle: .shown, locale: .shown) : String(errors.suffix(300)))
    }
    return (try? Data(contentsOf: logs[0])) ?? Data()
}

/// Whether an app with this bundle ID is running now.
nonisolated func isAppRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

/// Command-line builds use DerivedData and the SwiftPM cache with no app running.
nonisolated let buildTools = ["xcodebuild", "swift-build", "swift-package", "swift-test", "swift-run"]

/// Whether any process with one of these names is running now.
nonisolated func isProcessRunning(_ names: [String]) -> Bool {
    guard !names.isEmpty else { return false }
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return false }
    // Room for processes started between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let filled = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
    return pids.prefix(max(filled, 0)).contains { pid in
        pid > 0 && proc_name(pid, &buffer, UInt32(buffer.count)) > 0 && names.contains(String(cString: buffer))
    }
}

extension ScanItem {
    /// Whether the owner, an app sharing the files, or a tool using them is running now.
    nonisolated var isInUse: Bool {
        ([ownerBundleID].compactMap(\.self) + sharedWith).contains(where: isAppRunning) || isProcessRunning(usedByTools)
    }
}
