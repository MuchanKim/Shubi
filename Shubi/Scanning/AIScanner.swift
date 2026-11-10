import Foundation

/// What AI tools keep on disk, listed from the `AITool` catalog, plus session folders of tools that aren't in it, for review only.
nonisolated enum AIScanner {
    /// A file written this recently belongs to a session that is running. Ten minutes, not two: an agent waiting on a
    /// long build or test run writes nothing meanwhile.
    static let inUseWindow: TimeInterval = 10 * 60

    /// Also the scan cache key: its own type, so it can't collide with another section's key.
    enum Scope: Hashable, Sendable { case all, tool(AITool), unknown }

    enum Presence: Hashable, Sendable {
        case installed, uninstalled
        /// The login shell failed and no app or file was found. Treated as installed: a wrong "삭제됨" invites deleting a
        /// live tool's conversations.
        case unknown

        var label: String {
            switch self {
            case .installed: String(localized: "설치됨", bundle: .shown, locale: .shown)
            case .uninstalled: String(localized: "삭제됨", bundle: .shown, locale: .shown)
            case .unknown: String(localized: "알 수 없음", bundle: .shown, locale: .shown)
            }
        }
    }

    @concurrent static func scan(_ scope: Scope) async -> [ScanItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return items(scope, home: home, presence: presence(of: tools(in: scope), home: home), now: .now)
    }

    static func tools(in scope: Scope) -> [AITool] {
        switch scope {
        case .all: AITool.allCases
        case .tool(let tool): [tool]
        case .unknown: []
        }
    }

    /// Apps by bundle ID, binaries in the home folder, and one login shell for every tool's commands.
    static func presence(of tools: [AITool], home: URL) -> [AITool: Presence] {
        let commands = tools.flatMap(\.spec.install.commands)
        // nil: the shell failed, so what's on PATH can't be told.
        let onPath = commands.isEmpty ? [] : try? PackageCacheScanner.installedBinaries(commands)
        return Dictionary(uniqueKeysWithValues: tools.map { tool in
            let install = tool.spec.install
            let found = install.apps.contains { !LibraryScanner.installedCopies(of: $0, excluding: []).isEmpty }
                || install.files.contains { FileManager.default.fileExists(atPath: home.appending(path: $0).path(percentEncoded: false)) }
                || install.commands.contains { onPath?.contains($0) == true }
            let presence: Presence = if found { .installed } else if onPath == nil && !install.commands.isEmpty { .unknown } else { .uninstalled }
            return (tool, presence)
        })
    }

    /// Reads only what's under `home`, so tests run it on a fixture home with made-up presence.
    static func items(_ scope: Scope, home: URL, presence: [AITool: Presence], now: Date) -> [ScanItem] {
        let tools = tools(in: scope)
        let titles = SessionTitles(home: home, tools: tools)
        let unknown: [ScanItem] = if case .tool = scope { [] } else { unknownFolders(home: home) }
        return tools.flatMap { rows(of: $0, home: home, presence: presence[$0] ?? .unknown, titles: titles, now: now) } + unknown
    }

    /// What one row shows and what deleting it takes.
    private struct Group {
        let url: URL
        var targets: [URL]
        /// Shown when the tool's files give no title.
        let name: String
        /// What the title is looked up by: the session ID, or the thread ID an output folder is named after.
        let key: String
        /// A folder whose contents are the targets: a cache or log root.
        var isRoot = false
    }

    private static func rows(of tool: AITool, home: URL, presence: Presence, titles: SessionTitles, now: Date) -> [ScanItem] {
        let spec = tool.spec
        let processes = spec.install.processes + (spec.install.versions.map { directoryContents(home.appending(path: $0)).map(\.lastPathComponent) } ?? [])
        let isToolRunning = isProcessRunning(processes) || spec.install.apps.contains(where: isAppRunning)
        return [(spec.review, false), (spec.delete, true)].flatMap { column, isVerified in
            column.flatMap { category, patterns in
                let listed = AIEntry(tool: tool, category: category, isVerified: isVerified)
                let (found, isFound) = groups(patterns.map(AIGlob.init), as: listed, home: home)
                // A conversation's files are found under several folders; one that couldn't be read may hold more of them.
                let isWhole = isFound || category != .conversation
                return found.compactMap { group -> ScanItem? in
                    let (size, newest, isComplete) = measure(group.targets)
                    guard size > 0 else { return nil }
                    // A session is in use while it's being written; a cache or log while its tool runs.
                    let isSession = category == .conversation || category == .output
                    let about = isSession ? titles.describe(group.url, key: group.key, using: spec.titles) : (title: nil, project: nil)
                    var details = [fact("도구", spec.name), fact("설치 상태", presence.label)]
                    // What can't be read can't be told unused, and a file linked from elsewhere goes by where it really is:
                    // both are shown for review instead of offered and then skipped or half deleted.
                    var blocker: LocalizedStringResource?
                    if isVerified, !isComplete || !isWhole {
                        blocker = "일부 파일을 읽지 못했어요"
                    } else if isVerified, !group.targets.allSatisfy({ Cleaner.aiEntry(atRealPathOf: $0, home: home) == listed }) {
                        blocker = "다른 위치로 연결된 폴더에 있어요"
                    }
                    if let blocker { details.append(fact("지우지 않는 이유", String(localized: blocker.shown))) }
                    let entry = blocker == nil ? listed : AIEntry(tool: tool, category: category, isVerified: false)
                    if let project = about.project { details.append(fact("프로젝트", project)) }
                    if group.isRoot {
                        details.append(fact("들어 있는 항목", String(localized: "\(group.targets.count)개", bundle: .shown, locale: .shown)))
                    } else if group.targets.count > 1 {
                        details.append(fact("함께 지워지는 항목", group.targets.dropFirst().map { "~/" + relative($0, to: home) }.joined(separator: "\n")))
                    }
                    return ScanItem(
                        url: group.url,
                        name: about.title ?? group.name,
                        size: size,
                        lastUsed: newest,
                        kind: .aiData(entry),
                        targets: group.targets,
                        isRunning: isSession ? newest.map { now.timeIntervalSince($0) < inUseWindow } ?? false : isToolRunning,
                        // Checked again right before cleaning. Not for sessions: Claude running elsewhere doesn't make last month's
                        // conversation in use.
                        ownerBundleID: isSession ? nil : spec.install.apps.first,
                        sharedWith: isSession ? [] : Array(spec.install.apps.dropFirst()),
                        usedByTools: isSession ? [] : processes,
                        isOrphaned: presence == .uninstalled,
                        details: details
                    )
                }
            }
        }
    }

    /// The matches of `entry`'s globs, in rows: one per session, one per output, one per cache or log root.
    /// `isComplete` is false when a folder on the way couldn't be read, so a session may be missing some of its files.
    private static func groups(_ globs: [AIGlob], as entry: AIEntry, home: URL) -> (groups: [Group], isComplete: Bool) {
        let expanded = globs.map { ($0, $0.expand(in: home)) }
        // Only what the classifier gives this entry, so a row never lists what the cleaner would refuse or file differently.
        let matches = expanded.map { glob, found in
            (glob, found.urls.filter { AITool.entry(forHomeRelative: relative($0, to: home)) == entry })
        }
        let isComplete = expanded.allSatisfy(\.1.isComplete)
        let isNamed = { (glob: AIGlob) in !glob.segments.contains(where: AIGlob.isWildcard) }
        // A glob without a wildcard names one path, and its row is named by that path.
        let named = matches.filter { isNamed($0.0) }.flatMap(\.1).map { url in
            Group(url: url, targets: [url], name: "~/" + relative(url, to: home), key: url.lastPathComponent)
        }
        return (named + group(matches.filter { !isNamed($0.0) }, as: entry.category, home: home), isComplete)
    }

    private static func group(_ matches: [(AIGlob, [URL])], as category: AICategory, home: URL) -> [Group] {
        switch category {
        case .conversation:
            // A transcript and the folders named after the same session are one row, named by the first glob's match.
            var groups: [Group] = []
            var bySession: [String: Int] = [:]
            for url in matches.flatMap(\.1) {
                let session = sessionID(of: url)
                if let index = bySession[session] {
                    groups[index].targets.append(url)
                } else {
                    bySession[session] = groups.count
                    groups.append(Group(url: url, targets: [url], name: session, key: session))
                }
            }
            return groups
        case .output:
            return matches.flatMap { glob, urls in
                let fixed = glob.segments.prefix { !AIGlob.isWildcard($0) }.count
                return urls.map { url in
                    let name = relative(url, to: home).split(separator: "/").dropFirst(fixed).joined(separator: "/")
                    return Group(url: url, targets: [url], name: name, key: url.lastPathComponent)
                }
            }
        case .cache, .log, .toolData:
            let byFolder = Dictionary(grouping: matches.flatMap(\.1)) { relative($0.deletingLastPathComponent(), to: home) }
            return byFolder.keys.sorted().map { folder in
                Group(url: home.appending(path: folder), targets: byFolder[folder] ?? [], name: "~/" + folder, key: folder, isRoot: true)
            }
        }
    }

    /// Folder names AI tools keep their sessions under.
    private static let sessionFolderNames: Set<String> = ["sessions", "conversations", "chats", "threads"]
    /// Hidden folders many tools share (XDG) or the system owns: a session folder in one says nothing about an AI tool.
    private static let sharedFolders: Set<String> = [".local", ".config", ".cache", ".Trash"]

    /// Session-like folders up to three levels into hidden home folders no catalog tool owns, one review-only row each.
    /// The row is the session folder, not the hidden folder: `~/.android` is an SDK of many GB around a few KB of agent chats.
    /// A false positive costs a row, never a deletion: the classifier refuses everything outside the catalog.
    static func unknownFolders(home: URL) -> [ScanItem] {
        let skipped = AITool.knownRoots.union(sharedFolders)
        let roots = directoryContents(home).map(\.lastPathComponent).filter { $0.hasPrefix(".") && !skipped.contains($0) }
            .map { home.appending(path: $0) }
            // Not a link: one into another folder would list that folder's sessions as this one's.
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let folders = roots.flatMap { root -> [URL] in
            // By path: it yields paths below `root`, where a URL enumerator would resolve a symlink above it.
            guard let walker = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else { return [] }
            var found: [URL] = []
            for case let path as String in walker where walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if sessionFolderNames.contains((path as NSString).lastPathComponent) {
                    found.append(root.appending(path: path))
                    walker.skipDescendants()
                } else if walker.level >= 3 {
                    walker.skipDescendants()
                }
            }
            return found
        }
        return folders.compactMap { folder in
            let (size, newest, _) = measure([folder])
            guard size > 0 else { return nil }
            return ScanItem(url: folder, name: "~/" + relative(folder, to: home), size: size, lastUsed: newest,
                            kind: .aiData(AIEntry(tool: nil, category: .conversation, isVerified: false)))
        }
    }

    /// `url`'s path below `home`, as the catalog's globs are written: no leading or trailing slash.
    static func relative(_ url: URL, to home: URL) -> String {
        let base = home.path(percentEncoded: false)
        let path = url.path(percentEncoded: false).dropFirst(base.hasSuffix("/") ? base.count : base.count + 1)
        return String(path.hasSuffix("/") ? path.dropLast() : path)
    }

    private static func fact(_ label: LocalizedStringResource, _ value: String) -> Fact {
        Fact(label: String(localized: label.shown), value: value)
    }

    /// What the cleaner does with a row right now; the scan may be minutes old.
    enum CleanCheck: Equatable {
        case delete([URL])
        case skip(String)
    }

    /// A conversation or output goes whole or not at all, never half a session: it's skipped if any of its files was
    /// written lately, can't be read, is really somewhere this entry's rules don't cover, or appeared since the scan.
    /// A cache or log keeps just its fresh, unreadable and misfiled files.
    static func cleanCheck(_ item: ScanItem, as entry: AIEntry, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           now: Date) -> CleanCheck {
        // Fresh URLs: scanned ones cache the dates they had at scan time.
        let targets = item.targets.map { URL(filePath: $0.path(percentEncoded: false)) }
        func isFresh(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) < inUseWindow } ?? false }
        func isFiled(_ url: URL) -> Bool { Cleaner.aiEntry(atRealPathOf: url, home: home) == entry }
        guard entry.reviewOnly == nil else { return .skip(String(localized: "Shubi는 이 항목을 지우지 않아요", bundle: .shown, locale: .shown)) }
        switch entry.category {
        case .conversation, .output:
            guard targets.allSatisfy(isFiled) else { return .skip(String(localized: "허용되지 않은 경로", bundle: .shown, locale: .shown)) }
            if entry.category == .conversation, let tool = entry.tool {
                let current = sessionFiles(sessionID(of: item.url), of: tool, as: entry, home: home)
                guard current.isComplete else { return .skip(String(localized: "일부 파일을 읽지 못해 건너뛰었어요.", bundle: .shown, locale: .shown)) }
                guard Set(current.urls).isSubset(of: Set(targets)) else {
                    return .skip(String(localized: "스캔한 뒤 이 대화에 새 파일이 생겼어요. 다시 스캔한 뒤 정리하세요.", bundle: .shown, locale: .shown))
                }
            }
            let (_, newest, isComplete) = measure(targets)
            guard isComplete else { return .skip(String(localized: "일부 파일을 읽지 못해 건너뛰었어요.", bundle: .shown, locale: .shown)) }
            return isFresh(newest)
                ? .skip(String(localized: "방금 쓰인 항목이라 건너뛰었어요. 도구를 닫은 뒤 다시 정리하세요.", bundle: .shown, locale: .shown))
                : .delete(targets)
        case .cache, .log, .toolData:
            return .delete(targets.filter { url in
                guard isFiled(url) else { return false }
                let check = measure([url])
                return check.isComplete && !isFresh(check.newest)
            })
        }
    }

    /// The files a session has now under `tool`'s conversation globs, found the way the scan groups them.
    /// shortcut: every session re-reads its folders, so N sessions in one folder cost O(N²) name reads (2,000 in one
    /// folder took 28 s in a Debug build); list each folder once per clean run if folders that large show up.
    private static func sessionFiles(_ session: String, of tool: AITool, as entry: AIEntry, home: URL) -> (urls: [URL], isComplete: Bool) {
        let found = (tool.spec.delete[.conversation] ?? []).map { AIGlob($0).expand(in: home, session: session) }
        let urls = found.flatMap(\.urls).filter {
            sessionID(of: $0) == session && AITool.entry(forHomeRelative: relative($0, to: home)) == entry
        }
        return (urls, found.allSatisfy(\.isComplete))
    }

    /// What a session's files share: the last UUID in the name, lowercased (a Codex rollout's name starts with its time,
    /// and a UUID means the same in either case), else the name before its first ".".
    static func sessionID(of url: URL) -> String { sessionID(ofName: url.lastPathComponent) }

    static func sessionID(ofName name: String) -> String {
        if let uuid = name.matches(of: #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#).last {
            return String(name[uuid.range]).lowercased()
        }
        return String(name.prefix { $0 != "." })
    }

    /// Space on disk and the newest write inside, in one walk. A folder's own date counts: it changes when a file is added.
    /// `isComplete` is false when something inside couldn't be read, so its size and date are only a lower bound.
    static func measure(_ urls: [URL]) -> (size: Int64, newest: Date?, isComplete: Bool) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var size: Int64 = 0
        var newest: Date?
        var isComplete = true
        func add(_ url: URL) -> Bool {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch CocoaError.fileReadNoSuchFile {
                // Gone since it was listed: nothing left to measure or to protect.
                return false
            } catch {
                isComplete = false
                return false
            }
            size += Int64(values.totalFileAllocatedSize ?? 0)
            if let date = values.contentModificationDate, date > newest ?? .distantPast { newest = date }
            return values.isDirectory == true
        }
        for url in urls where add(url) {
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) { _, _ in
                isComplete = false
                return true
            }
            for case let file as URL in walker ?? .init() {
                _ = add(file)
            }
        }
        return (size, newest, isComplete)
    }
}

/// Session titles from each tool's own files, parsed into plain strings here and nowhere else.
nonisolated struct SessionTitles {
    private let codexNames: [String: String]

    init(home: URL, tools: [AITool]) {
        codexNames = tools.contains { $0.spec.titles == .codexIndex } ? Self.codexNames(index: home.appending(path: ".codex/session_index.jsonl")) : [:]
    }

    /// The title, and for Claude the folder the session ran in.
    func describe(_ row: URL, key: String, using source: AITool.Titles) -> (title: String?, project: String?) {
        switch source {
        case .none: (nil, nil)
        case .claudeTranscript: row.pathExtension == "jsonl" ? Self.claudeTranscript(row) : (nil, nil)
        // A rollout's name ends in its thread ID; an image folder is named after it.
        case .codexIndex: (codexNames[String(key.suffix(36)).lowercased()], nil)
        }
    }

    /// Thread names by ID. Later lines win: a rename is appended.
    static func codexNames(index: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: index) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String, let name = object["thread_name"] as? String, !name.isEmpty else { continue }
            // Keyed like session IDs: a UUID means the same in either case.
            names[id.lowercased()] = name
        }
        return names
    }

    /// Title and working folder from a transcript's first and last 64 KB, whole lines only. Claude Code appends its title
    /// records again as a session goes on, so the newest one is near the end; `cwd` is on the first lines.
    /// The newest `customTitle` (a /rename) beats any `aiTitle`.
    /// shortcut: a title written only in the middle of a long transcript is missed and the row shows the session ID; read
    /// the whole file if that shows up.
    static func claudeTranscript(_ url: URL) -> (title: String?, project: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let chunk = 65_536
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        var lines: [Data.SubSequence]
        if size <= UInt64(chunk * 2) {
            lines = ((try? handle.readToEnd()) ?? Data()).split(separator: UInt8(ascii: "\n"))
        } else {
            let head = (try? handle.read(upToCount: chunk)) ?? Data()
            try? handle.seek(toOffset: size - UInt64(chunk))
            let tail = (try? handle.readToEnd()) ?? Data()
            // The cut ends of each chunk are half lines.
            lines = head.split(separator: UInt8(ascii: "\n")).dropLast() + tail.split(separator: UInt8(ascii: "\n")).dropFirst()
        }
        var custom: String?, ai: String?, project: String?
        for line in lines where line.firstRange(of: Data("Title\"".utf8)) != nil || (project == nil && line.firstRange(of: Data("\"cwd\"".utf8)) != nil) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["type"] as? String == "custom-title", let title = object["customTitle"] as? String, !title.isEmpty { custom = title }
            if object["type"] as? String == "ai-title", let title = object["aiTitle"] as? String, !title.isEmpty { ai = title }
            if project == nil { project = object["cwd"] as? String }
        }
        return (custom ?? ai, project)
    }
}
