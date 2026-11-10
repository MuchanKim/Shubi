import Foundation

/// The AI tools Shubi knows. `spec` is one switch, so a tool without an entry fails the build.
nonisolated enum AITool: String, CaseIterable, Hashable, Sendable, Identifiable {
    case claudeCode, claudeApp, codex, geminiCLI, antigravity, cursor, t3Code, aside

    var id: Self { self }

    struct Spec: Sendable {
        let name: String
        var install = Install()
        var titles: Titles = .none
        /// Home-relative globs Shubi may delete, by what they hold. This is the cleaner's whole allow-list for the tool:
        /// settings, credentials and databases are safe because nothing here names them.
        var delete: [AICategory: [String]] = [:]
        /// Home-relative globs listed so the space is visible, never deleted: paths not verified to come back, and the
        /// tool's own state. A review glob wins over a delete glob that matches the same path.
        var review: [AICategory: [String]] = [:]
        /// What deleting a conversation leaves behind, added to its verdict.
        var conversationCaveat: LocalizedStringResource?
    }

    struct Install: Sendable {
        /// Looked up on a login shell's PATH.
        var commands: [String] = []
        /// Bundle IDs. Any installed copy outside a Trash counts.
        var apps: [String] = []
        /// Home-relative binaries a login shell's PATH can miss (`~/.local/bin` is often added only in .zshrc).
        var files: [String] = []
        /// Names the tool runs under (`proc_name`). Node CLIs show up as `node`.
        var processes: [String] = []
        /// Home-relative folder of version-named binaries: the native Claude Code runs as `2.1.319`, not as `claude`.
        var versions: String?
    }

    enum Titles: Sendable { case none, claudeTranscript, codexIndex }

    var spec: Spec {
        let support = "Library/Application Support"
        // A VS Code fork's own caches and logs. Chromium's caches next to them stay in App cache; `User` holds settings
        // and chat databases.
        func editor(_ app: String) -> (delete: [AICategory: [String]], review: [AICategory: [String]]) {
            ([.log: ["\(support)/\(app)/logs/*"],
              .cache: ["\(support)/\(app)/CachedData/*", "\(support)/\(app)/CachedExtensionVSIXs/*", "\(support)/\(app)/CachedProfilesData/*"]],
             [.toolData: ["\(support)/\(app)/User"]])
        }
        switch self {
        case .claudeCode:
            return Spec(
                name: "Claude Code",
                install: Install(commands: ["claude"], files: [".local/bin/claude"], processes: ["claude"], versions: ".local/share/claude/versions"),
                titles: .claudeTranscript,
                delete: [
                    // A transcript, its subagents folder and its /rewind checkpoints share the session ID, so they are one row.
                    // `memory/` next to them isn't UUID-shaped and never matches.
                    .conversation: [".claude/projects/*/\(Self.uuid).jsonl", ".claude/projects/*/\(Self.uuid)", ".claude/file-history/\(Self.uuid)"],
                    .cache: [".claude/shell-snapshots/*", ".claude/paste-cache/*", ".claude/cache/*"],
                ],
                review: [.log: [".claude/jobs", ".claude/daemon.log"]])
        case .claudeApp:
            return Spec(
                name: "Claude",
                install: Install(apps: ["com.anthropic.claudefordesktop"]),
                // The VM image holds session data; the bundled CLIs may be what the app runs.
                review: [.toolData: ["\(support)/Claude/vm_bundles/*", "\(support)/Claude/claude-code", "\(support)/Claude/claude-code-vm"]])
        case .codex:
            return Spec(
                name: "Codex",
                install: Install(commands: ["codex"], apps: ["com.openai.codex"], processes: ["codex"]),
                titles: .codexIndex,
                delete: [
                    .conversation: [".codex/sessions/*/*/*/rollout-*.jsonl*", ".codex/archived_sessions/rollout-*.jsonl*"],
                    // One folder per thread and per day: a whole root is always recent, so the age filter would never pick it.
                    .output: [".codex/generated_images/*", ".codex/visualizations/*/*/*"],
                    .cache: [".codex/cache/*", ".codex/.tmp/*", ".codex/tmp/*", ".codex/shell_snapshots/*"],
                ],
                conversationCaveat: "Codex 대화 목록에는 이름이 남을 수 있어요.")
        case .geminiCLI:
            return Spec(
                name: "Gemini CLI",
                install: Install(commands: ["gemini"], processes: ["gemini", "node"]),
                // `tmp/<project>/logs.json` is the prompt history the CLI reads back, so it isn't listed.
                delete: [.conversation: [".gemini/tmp/*/chats/session-*.json"], .cache: [".gemini/tmp/bin/*"]],
                review: [.conversation: [".gemini/history"]])
        case .antigravity:
            let editor = editor("Antigravity")
            return Spec(
                name: "Antigravity",
                install: Install(apps: ["com.google.antigravity"]),
                delete: editor.delete.merging([
                    .conversation: [".gemini/antigravity/conversations/\(Self.uuid).pb", ".gemini/antigravity/brain/\(Self.uuid)"],
                    .output: [".gemini/antigravity/browser_recordings/*", ".gemini/antigravity/html_artifacts/*"],
                ]) { $0 + $1 },
                review: editor.review.merging([
                    .cache: [".gemini/antigravity/implicit"],
                    // A logged-in browser profile.
                    .toolData: [".gemini/antigravity-browser-profile"],
                ]) { $0 + $1 })
        case .cursor:
            let editor = editor("Cursor")
            return Spec(name: "Cursor", install: Install(apps: ["com.todesktop.230313mzl4w4u92"]), delete: editor.delete, review: editor.review)
        case .t3Code:
            return Spec(
                name: "T3 Code",
                install: Install(commands: ["t3"], apps: ["com.t3tools.t3code"]),
                // Threads are rows in statev2.sqlite, not files.
                delete: [.log: [".t3/userdata/logs/*"], .cache: [".t3/caches/*"]],
                review: [.output: [".t3/userdata/attachments", ".t3/userdata/browser-artifacts"]])
        case .aside:
            return Spec(
                name: "Aside",
                install: Install(apps: ["at.studio.AsideBrowser"]),
                delete: [
                    .conversation: [".aside/u/*/sessions/*"],
                    .cache: [".aside/cache/*", ".aside/u/*/cache/*"],
                    .log: [".aside/logs/*"],
                ],
                // Downloaded runtimes and models: not verified to be downloaded again.
                review: [.cache: [".aside/runtime", ".aside/models"]])
        }
    }

    /// 8-4-4-4-12 hex digits, so `memory`, `skills` and other siblings of a session never match.
    private static let uuid = [8, 4, 4, 4, 12].map { String(repeating: "[0-9a-fA-F]", count: $0) }.joined(separator: "-")
}

/// What an AI tool's file holds. Decides deletability together with `AIEntry.isVerified`.
nonisolated enum AICategory: Hashable, Sendable {
    case conversation, output, cache, log
    /// The tool's own state: a VM image, bundled binaries, a logged-in browser profile, settings. Always review-only,
    /// even if someone writes it under `delete:`.
    case toolData
}

/// The AI half of `ScanItem.Kind.aiData`. Only the AI section and the `.aiData` arms of the kind switches read it.
nonisolated struct AIEntry: Hashable, Sendable {
    /// nil: a hidden folder in ~ that looks like an AI tool's session store but isn't in the catalog.
    let tool: AITool?
    let category: AICategory
    /// Matched a `delete:` glob. A `review:` glob or discovery gives false.
    let isVerified: Bool

    enum ReviewOnly: Hashable, Sendable { case unknownTool, toolState, unverified }

    /// Derived, never stored, so the dimmed row and the cleaner's refusal can't disagree.
    var reviewOnly: ReviewOnly? {
        if tool == nil { return .unknownTool }
        if category == .toolData { return .toolState }
        return isVerified ? nil : .unverified
    }

    var categoryName: String {
        switch category {
        case .conversation: String(localized: "대화", bundle: .shown, locale: .shown)
        case .output: String(localized: "생성한 파일", bundle: .shown, locale: .shown)
        case .cache: String(localized: "캐시", bundle: .shown, locale: .shown)
        case .log: String(localized: "로그", bundle: .shown, locale: .shown)
        case .toolData: String(localized: "도구 데이터", bundle: .shown, locale: .shown)
        }
    }

    func risk(isOrphaned: Bool) -> DeletionRisk {
        if let reviewOnly { return Self.notDeleted(reviewOnly) }
        switch category {
        case .conversation:
            if isOrphaned {
                return DeletionRisk(level: .caution, title: "삭제된 도구의 대화 기록이에요",
                                    reason: "도구를 다시 설치해도 이 대화를 이어 갈 수 없어요. 휴지통에 있는 동안은 되살릴 수 있어요.")
            }
            let reason: LocalizedStringResource = if let caveat = tool?.spec.conversationCaveat {
                "이 대화를 다시 열거나 이어 갈 수 없어요. 휴지통에 있는 동안은 되살릴 수 있어요. \(String(localized: caveat.shown))"
            } else {
                "이 대화를 다시 열거나 이어 갈 수 없어요. 휴지통에 있는 동안은 되살릴 수 있어요."
            }
            return DeletionRisk(level: .caution, title: "대화 기록이 지워져요", reason: reason)
        case .output:
            return DeletionRisk(level: .caution, title: "도구가 만든 파일이에요",
                                reason: "이미지나 녹화처럼 도구가 만든 파일이에요. 다른 곳에 저장해 두지 않았다면 휴지통을 비운 뒤에는 되살릴 수 없어요.")
        case .cache:
            return isOrphaned
                ? DeletionRisk(level: .safe, title: "앱이 이미 삭제된 캐시예요", reason: "다시 쓰일 일이 없는 공간이에요.")
                : DeletionRisk(level: .safe, title: "다시 생기는 임시 파일이에요", reason: "도구가 필요할 때 다시 만들어요.")
        case .log:
            return DeletionRisk(level: .safe, title: "도구의 기록 파일이에요", reason: "문제를 조사할 때만 쓰여요. 지워도 도구는 그대로 동작해요.")
        case .toolData:
            // `reviewOnly` is already `.toolState` for every tool's data; this keeps the switch exhaustive.
            return Self.notDeleted(.toolState)
        }
    }

    private static func notDeleted(_ why: ReviewOnly) -> DeletionRisk {
        let reason: LocalizedStringResource = switch why {
        case .unknownTool: "어떤 도구가 남긴 폴더인지 알 수 없어서 보여 주기만 해요. 필요 없다면 Finder에서 직접 확인하세요."
        case .toolState: "도구가 직접 쓰는 데이터예요. 가상 머신, 내장 실행 파일, 설정이나 로그인 정보가 들어 있을 수 있어요."
        case .unverified: "지워도 되는지 확인되지 않아서 보여 주기만 해요. 필요 없다면 Finder에서 직접 확인하세요."
        }
        return DeletionRisk(level: .caution, title: "Shubi는 이 항목을 지우지 않아요", reason: reason)
    }
}

/// A home-relative pattern of `/`-separated segments, each matched by fnmatch(3) with FNM_PERIOD: `*`, `?` and `[...]`
/// never cross a `/` and never match a leading `.`. Listing and allowing both go through this type, so the cleaner allows
/// exactly what the scanner can list. Not glob(3): the home path is never parsed as a pattern.
nonisolated struct AIGlob: Hashable, Sendable {
    let segments: [String]

    init(_ pattern: String) {
        segments = pattern.split(separator: "/").map(String.init)
    }

    func matches(_ components: [Substring]) -> Bool {
        components.count == segments.count && zip(segments, components).allSatisfy { Self.match($0, String($1)) }
    }

    /// Literal segments are appended if they exist; wildcard segments list the folder and keep the names that match.
    /// `isComplete` is false when a folder on the way couldn't be read: a match may be missing, so nothing may be
    /// judged on the list being whole.
    /// With `session`, only names containing it are kept at the last segment, before any URL is made: re-finding one
    /// session's files among thousands stays cheap. Callers still check the session ID itself.
    /// Folders are read fresh every time: a reused listing can miss a change that keeps the folder's date.
    func expand(in home: URL, session: String? = nil) -> (urls: [URL], isComplete: Bool) {
        var isComplete = true
        let last = segments.count - 1
        let urls = segments.enumerated().reduce([home]) { urls, step in
            let (index, segment) = step
            // Without case: a session ID's UUID is lowercased, and callers compare the ID itself afterwards.
            let keeps = { (name: String) in index < last || session.map { name.range(of: $0, options: .caseInsensitive) != nil } ?? true }
            return urls.flatMap { url -> [URL] in
                guard Self.isWildcard(segment) else {
                    guard keeps(segment) else { return [] }
                    let next = url.appending(path: segment)
                    guard let exists = Self.exists(next.path(percentEncoded: false)) else { isComplete = false; return [] }
                    return exists ? [next] : []
                }
                guard let names = Self.names(in: url.path(percentEncoded: false)) else { isComplete = false; return [] }
                return names.filter { keeps($0) && Self.match(segment, $0) }.sorted().map { url.appending(path: $0) }
            }
        }
        return (urls, isComplete)
    }

    /// The names in the folder at `path` (following links); empty when there's no folder there; nil when it can't be read.
    static func names(in path: String) -> [String]? {
        guard let isFolder = isFolder(path) else { return nil }
        return isFolder ? try? FileManager.default.contentsOfDirectory(atPath: path) : []
    }

    /// Whether something is at `path` (following links); nil when that can't be told, such as behind an unreadable folder.
    static func exists(_ path: String) -> Bool? {
        var info = stat()
        return stat(path, &info) == 0 ? true : isMissing(errno) ? false : nil
    }

    private static func isFolder(_ path: String) -> Bool? {
        var info = stat()
        guard stat(path, &info) == 0 else { return isMissing(errno) ? false : nil }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    private static func isMissing(_ error: Int32) -> Bool { error == ENOENT || error == ENOTDIR }

    static func isWildcard(_ segment: String) -> Bool { segment.contains(where: "*?[".contains) }

    private static func match(_ pattern: String, _ name: String) -> Bool { fnmatch(pattern, name, FNM_PERIOD) == 0 }
}

nonisolated extension AITool {
    /// Every catalog glob with the entry it gives. Review globs come first, so they win over a delete glob for the same path.
    private static let rules: [(glob: AIGlob, entry: AIEntry)] = {
        func rules(_ column: (Spec) -> [AICategory: [String]], verified: Bool) -> [(glob: AIGlob, entry: AIEntry)] {
            allCases.flatMap { tool in
                column(tool.spec).flatMap { category, globs in
                    globs.map { (AIGlob($0), AIEntry(tool: tool, category: category, isVerified: verified)) }
                }
            }
        }
        return rules(\.review, verified: false) + rules(\.delete, verified: true)
    }()

    /// First component of every glob (`.claude`, `.gemini`, `Library`). Unknown-tool discovery skips these.
    static let knownRoots = Set(rules.compactMap { $0.glob.segments.first })

    /// The single classifier, for the scanner's rows and the cleaner's allow-list alike.
    static func entry(forHomeRelative path: String) -> AIEntry? {
        let components = path.split(separator: "/")
        return rules.first { $0.glob.matches(components) }?.entry
    }

    /// Written out so the cleaner can't make the `entry(...)?.reviewOnly == nil` mistake, which is true for an unknown path.
    static func isDeletable(homeRelative path: String) -> Bool {
        entry(forHomeRelative: path).map { $0.reviewOnly == nil } ?? false
    }
}

extension ScanItem {
    /// The AI section's tool column: the tool, "(삭제됨)" when it's uninstalled. Empty for other kinds.
    nonisolated var aiToolName: String {
        guard case .aiData(let entry) = kind else { return "" }
        guard let tool = entry.tool else { return String(localized: "알 수 없는 도구", bundle: .shown, locale: .shown) }
        return isOrphaned ? String(localized: "\(tool.spec.name) (삭제됨)", bundle: .shown, locale: .shown) : tool.spec.name
    }

    nonisolated var aiCategoryName: String {
        if case .aiData(let entry) = kind { entry.categoryName } else { "" }
    }
}
