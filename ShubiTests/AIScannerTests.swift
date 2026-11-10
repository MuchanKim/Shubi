import Foundation
import Testing
@testable import Shubi

/// Every test scans its own fixture home in the temporary folder, never the real ~/.claude or ~/.codex.
struct AIScannerTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "Shubi-ai-home-\(UUID().uuidString)")
    let session = "0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e"
    let thread = "019f2872-e2a0-78e3-b4a3-265f27a69674"

    @discardableResult
    private func write(_ path: String, _ contents: String = "x", daysAgo: Double = 40) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        // The folder too: adding a file dates it, and a session folder dated now is in use.
        for path in [url, url.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-daysAgo * 86_400)],
                                                  ofItemAtPath: path.path(percentEncoded: false))
        }
        return url
    }

    private func scan(_ scope: AIScanner.Scope, _ presence: AIScanner.Presence = .installed) -> [ScanItem] {
        let tools = AIScanner.tools(in: scope)
        return AIScanner.items(scope, home: home, presence: Dictionary(uniqueKeysWithValues: tools.map { ($0, presence) }), now: .now)
    }

    private func clean() { try? FileManager.default.removeItem(at: home) }

    /// A transcript, its subagents and its /rewind checkpoints go together; its memory and the settings never show.
    @Test func claudeSessionIsOneRowWithItsFolders() throws {
        defer { clean() }
        let transcript = try write(".claude/projects/-Users-tester-app/\(session).jsonl", """
            {"type":"ai-title","aiTitle":"Crash on launch","sessionId":"\(session)"}
            {"type":"user","cwd":"/Users/tester/app","message":"hi"}
            {"type":"custom-title","customTitle":"Fix the ⌘10 crash"}
            {"type":"ai-title","aiTitle":"Keyboard shortcut trap"}
            """)
        try write(".claude/projects/-Users-tester-app/\(session)/subagents/a.jsonl")
        try write(".claude/file-history/\(session)/v1")
        let memory = try write(".claude/projects/-Users-tester-app/memory/MEMORY.md")
        let settings = try write(".claude/settings.json")

        let items = scan(.tool(.claudeCode))
        let row = try #require(items.first)
        #expect(items.count == 1)
        #expect(row.kind == .aiData(AIEntry(tool: .claudeCode, category: .conversation, isVerified: true)))
        #expect(row.url == transcript)
        #expect(Set(row.targets) == [transcript, home.appending(path: ".claude/projects/-Users-tester-app/\(session)"),
                                     home.appending(path: ".claude/file-history/\(session)")])
        #expect(row.name == "Fix the ⌘10 crash")
        #expect(row.details.contains { $0.value == "/Users/tester/app" })
        #expect(!items.flatMap(\.targets).contains { [memory, settings, home.appending(path: ".claude/projects/-Users-tester-app/memory")].contains($0) })
    }

    /// Claude Code writes its title records again as a session goes on, so the newest is near the end of a long transcript.
    @Test func claudeTitleIsReadFromTheEndOfALongTranscript() throws {
        defer { clean() }
        let filler = String(repeating: #"{"type":"assistant","message":"\#(String(repeating: "a", count: 1_000))"}"# + "\n", count: 200)
        try write(".claude/projects/-x/\(session).jsonl",
                  #"{"type":"ai-title","aiTitle":"First guess"}"# + "\n" + filler + #"{"type":"custom-title","customTitle":"Renamed later"}"# + "\n")
        #expect(scan(.tool(.claudeCode)).map(\.name) == ["Renamed later"])
    }

    /// Codex appends a line per rename to its index; rollouts and image folders take the newest name.
    @Test func codexRowsTakeTheirThreadNameFromTheIndex() throws {
        defer { clean() }
        try write(".codex/session_index.jsonl", """
            {"id":"\(thread)","thread_name":"Draft","updated_at":"2026-11-01T00:00:00Z"}
            not json
            {"id":"\(thread)","thread_name":"Release notes","updated_at":"2026-11-02T00:00:00Z"}
            """)
        let rollout = try write(".codex/sessions/2026/11/10/rollout-2026-11-10T01-32-09-\(thread).jsonl.zst")
        try write(".codex/generated_images/\(thread)/a.png")
        try write(".codex/visualizations/2026/10/03/chart.html")
        let images = home.appending(path: ".codex/generated_images/\(thread)"), day = home.appending(path: ".codex/visualizations/2026/10/03")
        try write(".codex/auth.json")
        try write(".codex/state_5.sqlite")

        let names = Dictionary(uniqueKeysWithValues: scan(.tool(.codex)).map { ($0.url, $0.name) })
        #expect(names == [rollout: "Release notes", images: "Release notes", day: "2026/10/03"])
    }

    /// A session written minutes ago is running; a cache root lists its contents as one row; a named path is its own row.
    @Test func recentSessionsAreInUseAndCacheRootsAreOneRow() throws {
        defer { clean() }
        try write(".aside/u/0/sessions/2026-11-10_live/messages.jsonl", daysAgo: 0)
        try write(".aside/u/0/sessions/2026-10-01_old/messages.jsonl")
        let live = home.appending(path: ".aside/u/0/sessions/2026-11-10_live"), old = home.appending(path: ".aside/u/0/sessions/2026-10-01_old")
        let cached = try [write(".aside/cache/a"), write(".aside/cache/b")]
        try write(".aside/runtime/node")
        try write(".aside/password-manager/vault")
        try write(".aside/credentials.json")

        let items = scan(.tool(.aside))
        let runtime = try #require(items.first { $0.url == home.appending(path: ".aside/runtime") })
        #expect(runtime.name == "~/.aside/runtime")
        #expect(runtime.isReviewOnly)
        #expect(items.first { $0.url == live }?.isRunning == true)
        #expect(items.first { $0.url == old }?.isRunning == false)
        let cache = try #require(items.first { $0.url == home.appending(path: ".aside/cache") })
        #expect(cache.name == "~/.aside/cache")
        #expect(Set(cache.targets) == Set(cached))
        #expect(items.count == 4)
    }

    /// A tool that's gone leaves its rows marked, not hidden; a tool whose install couldn't be checked counts as installed.
    @Test(arguments: [(AIScanner.Presence.uninstalled, true), (.unknown, false), (.installed, false)])
    func uninstalledToolsLeaveMarkedRows(_ presence: AIScanner.Presence, _ isOrphaned: Bool) throws {
        defer { clean() }
        try write(".gemini/antigravity/conversations/\(session).pb")
        try write(".gemini/antigravity/brain/\(session)/plan.md")
        let item = try #require(scan(.tool(.antigravity), presence).first)
        #expect(item.targets.count == 2)
        #expect(item.isOrphaned == isOrphaned)
        let name = "Antigravity"
        #expect(item.aiToolName == (isOrphaned ? String(localized: "\(name) (삭제됨)") : name))
    }

    /// Session folders of tools Shubi doesn't know are shown, never offered; shared and known folders aren't searched.
    @Test func unknownSessionFoldersAreReviewOnly() throws {
        defer { clean() }
        try write(".android/studio/agent/conversations/c1.json")
        let found = home.appending(path: ".android/studio/agent/conversations")
        try write(".local/state/tuist/sessions/s.json")
        try write(".gstack/sessions/.keep", "")
        try write(".deep/a/b/c/sessions/s.json")
        try write(".claude/sessions/live.json")

        let items = scan(.unknown)
        #expect(items.map(\.url) == [found])
        #expect(items.allSatisfy { $0.isReviewOnly && !$0.canDelete && !$0.isSmartCleanable })
        #expect(items.allSatisfy { !Cleaner.isAllowed($0.url, as: .aiData, home: home) })
    }

    /// Listing and allowing agree across the whole catalog: every glob's match is listed, a deletable row's targets pass
    /// the cleaner, and a review row's targets don't.
    @Test func everyListedTargetIsWhatTheCleanerAllows() throws {
        defer { clean() }
        let samples = try AIToolsTests.globs.map { glob in (glob, try write(AIToolsTests.sample(glob.pattern))) }
        let items = scan(.all)
        for (glob, sample) in samples {
            let row = items.first { $0.targets.contains(sample) }
            #expect(row?.kind == .aiData(AIEntry(tool: glob.tool, category: glob.category, isVerified: glob.isDelete)), "\(glob.pattern)")
        }
        for item in items {
            for target in item.targets {
                #expect(Cleaner.isAllowed(target, as: .aiData, home: home) == !item.isReviewOnly, "\(target.path(percentEncoded: false))")
            }
        }
    }

    private func check(_ item: ScanItem) -> AIScanner.CleanCheck {
        guard case .aiData(let entry) = item.kind else { return .skip("not AI data") }
        return AIScanner.cleanCheck(item, as: entry, home: home, now: .now)
    }

    private func isSkipped(_ check: AIScanner.CleanCheck) -> Bool {
        if case .skip = check { true } else { false }
    }

    @Test func freshFilesAreKeptAtCleanTime() throws {
        defer { clean() }
        let transcript = try write(".claude/projects/-Users-tester-app/\(session).jsonl")
        let old = try write(".claude/shell-snapshots/old.sh")
        try write(".claude/shell-snapshots/fresh.sh", daysAgo: 0)
        let items = scan(.tool(.claudeCode))
        let conversation = try #require(items.first { $0.url == transcript })
        let cache = try #require(items.first { $0.targets.contains(old) })
        #expect(check(conversation) == .delete([transcript]))
        #expect(check(cache) == .delete([old]))
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: transcript.path(percentEncoded: false))
        #expect(isSkipped(check(conversation)))
    }

    /// What can't be read can't be told unused: the row is review-only, and a scan that missed it doesn't delete it later.
    @Test func unreadableSessionIsNeverDeleted() throws {
        let folder = home.appending(path: ".claude/projects/-Users-tester-app/\(session)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "subagents").path(percentEncoded: false))
            clean()
        }
        try write(".claude/projects/-Users-tester-app/\(session).jsonl")
        // A subagent writing right now, behind folders dated last month.
        try write(".claude/projects/-Users-tester-app/\(session)/subagents/agent.jsonl", daysAgo: 0)
        for path in [folder.appending(path: "subagents"), folder] {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: path.path(percentEncoded: false))
        }
        let readable = try #require(scan(.tool(.claudeCode)).first { $0.targets.contains(folder) })
        #expect(readable.isRunning)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.appending(path: "subagents").path(percentEncoded: false))
        let row = try #require(scan(.tool(.claudeCode)).first { $0.targets.contains(folder) })
        #expect(row.isReviewOnly)
        #expect(!row.canDelete)
        // Scanned while readable, as if the scan were a few minutes old.
        #expect(check(readable) == .skip(String(localized: "일부 파일을 읽지 못해 건너뛰었어요.", bundle: .shown, locale: .shown)))
    }

    /// A session that grew a file since the scan is skipped whole instead of losing its transcript under a live subagent.
    @Test func sessionGrownSinceTheScanIsSkipped() throws {
        defer { clean() }
        let transcript = try write(".claude/projects/-Users-tester-app/\(session).jsonl")
        let row = try #require(scan(.tool(.claudeCode)).first { $0.url == transcript })
        try write(".claude/file-history/\(session)/checkpoint", daysAgo: 40)
        #expect(check(row) == .skip(String(localized: "스캔한 뒤 이 대화에 새 파일이 생겼어요. 다시 스캔한 뒤 정리하세요.", bundle: .shown, locale: .shown)))
    }

    /// A tool folder linked elsewhere is refused by the cleaner, so it's listed for review rather than offered.
    @Test func linkedToolFolderIsReviewOnly() throws {
        defer { clean() }
        let elsewhere = home.appending(path: "dotfiles/codex")
        try write("dotfiles/codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(thread).jsonl")
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".codex"), withDestinationURL: elsewhere)
        let row = try #require(scan(.tool(.codex)).first { $0.name.contains(thread) || $0.url.lastPathComponent.contains(thread) })
        #expect(row.isReviewOnly)
        #expect(isSkipped(check(row)))
    }

    /// A Codex thread's rollouts share its ID, not their file names, which start with the time each was written.
    @Test func codexRolloutsOfOneThreadAreOneRow() throws {
        defer { clean() }
        let first = try write(".codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(thread).jsonl")
        let second = try write(".codex/archived_sessions/rollout-2026-10-02T09-00-00-\(thread).jsonl.zst")
        let rows = scan(.tool(.codex)).filter { $0.targets.contains(first) || $0.targets.contains(second) }
        #expect(rows.count == 1)
        #expect(Set(rows.first?.targets ?? []) == [first, second])
    }

    /// A folder that can't be listed may hold more of a session's files: its conversations are review-only, and one
    /// scanned before the folder became unreadable is skipped at clean time.
    @Test func sessionWithAnUnlistableFolderIsNeverDeleted() throws {
        let history = home.appending(path: ".claude/file-history")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: history.path(percentEncoded: false))
            clean()
        }
        let transcript = try write(".claude/projects/-Users-tester-app/\(session).jsonl")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let scanned = try #require(scan(.tool(.claudeCode)).first { $0.url == transcript })
        #expect(scanned.canDelete)
        // The empty folder simply can't be listed any more, with nothing else changed.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: history.path(percentEncoded: false))
        #expect(check(scanned) == .skip(String(localized: "일부 파일을 읽지 못해 건너뛰었어요.", bundle: .shown, locale: .shown)))
        #expect(try #require(scan(.tool(.claudeCode)).first { $0.url == transcript }).isReviewOnly)
    }

    /// A link from one tool's folder into another's doesn't let that folder's files go by the first tool's rules.
    @Test func linkIntoAnotherToolsFolderIsNotFiledThere() throws {
        defer { clean() }
        let transcript = try write(".claude/projects/p/\(session).jsonl")
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".codex/cache"), withDestinationURL: transcript.deletingLastPathComponent())
        let cache = try #require(scan(.tool(.codex)).first { $0.url == home.appending(path: ".codex/cache") })
        #expect(cache.isReviewOnly)
        #expect(isSkipped(check(cache)))
        // Even handed over as a verified Codex cache, the transcript isn't filed there.
        let verified = ScanItem(url: cache.url, name: cache.name, size: cache.size, lastUsed: nil,
                                kind: .aiData(AIEntry(tool: .codex, category: .cache, isVerified: true)), targets: cache.targets)
        #expect(check(verified) == .delete([]))
        #expect(FileManager.default.fileExists(atPath: transcript.path(percentEncoded: false)))
    }

    /// A companion that appears in a folder whose date is then put back is still found: folders are read fresh.
    @Test func companionBehindARestoredFolderDateIsFound() throws {
        defer { clean() }
        let transcript = try write(".claude/projects/-Users-tester-app/\(session).jsonl")
        let history = home.appending(path: ".claude/file-history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let dated = try FileManager.default.attributesOfItem(atPath: history.path(percentEncoded: false))[.modificationDate]
        let scanned = try #require(scan(.tool(.claudeCode)).first { $0.url == transcript })
        try write(".claude/file-history/\(session)/live", daysAgo: 40)
        try FileManager.default.setAttributes([.modificationDate: try #require(dated)], ofItemAtPath: history.path(percentEncoded: false))
        #expect(check(scanned) == .skip(String(localized: "스캔한 뒤 이 대화에 새 파일이 생겼어요. 다시 스캔한 뒤 정리하세요.", bundle: .shown, locale: .shown)))
    }

    /// A folder that can't be read makes the list incomplete; one that isn't there doesn't.
    @Test func expandTellsMissingFromUnreadable() throws {
        defer { clean() }
        let folder = try write(".codex/cache/a").deletingLastPathComponent()
        #expect(AIGlob(".codex/cache/*").expand(in: home).isComplete)
        let missing = AIGlob(".codex/tmp/*").expand(in: home)
        #expect(missing.urls.isEmpty && missing.isComplete)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false)) }
        #expect(!AIGlob(".codex/cache/*").expand(in: home).isComplete)
    }

    /// A UUID means the same in either case: an upper-case companion is the same session, found at scan and clean time.
    @Test func sessionIDsIgnoreUUIDCase() throws {
        defer { clean() }
        let transcript = try write(".claude/projects/-Users-tester-app/\(session).jsonl")
        try write(".claude/projects/-Users-tester-app/\(session.uppercased())/subagents/a.jsonl")
        let upper = home.appending(path: ".claude/projects/-Users-tester-app/\(session.uppercased())")
        let row = try #require(scan(.tool(.claudeCode)).first { $0.url == transcript })
        #expect(Set(row.targets) == [transcript, upper])
        let alone = ScanItem(url: transcript, name: "alone", size: 1, lastUsed: nil, kind: row.kind, targets: [transcript])
        #expect(check(alone) == .skip(String(localized: "스캔한 뒤 이 대화에 새 파일이 생겼어요. 다시 스캔한 뒤 정리하세요.", bundle: .shown, locale: .shown)))
    }

    /// Index IDs and file names in either case find the same title.
    @Test func codexTitlesIgnoreUUIDCase() throws {
        defer { clean() }
        try write(".codex/session_index.jsonl", #"{"id":"\#(thread.uppercased())","thread_name":"Upper index"}"#)
        let rollout = try write(".codex/sessions/2026/11/10/rollout-2026-11-10T01-32-09-\(thread.uppercased()).jsonl")
        try write(".codex/generated_images/\(thread)/a.png")
        let items = scan(.tool(.codex))
        #expect(items.first { $0.targets.contains(rollout) }?.name == "Upper index")
        #expect(items.first { $0.url == home.appending(path: ".codex/generated_images/\(thread)") }?.name == "Upper index")
    }
}
