import Foundation
import Testing
@testable import Shubi

struct CleanerTests {
    let home = URL(filePath: "/Users/tester")

    @Test(arguments: [
        ("/Users/tester/Documents/a.pdf", Cleaner.Policy.ownFiles),
        ("/Users/tester/Downloads/movie.mov", .ownFiles),
        ("/Users/tester/Library/Caches/Google/Chrome/x", .cache),
        ("/Users/tester/Library/Application Support/Code/Cache", .cache),
        ("/Users/tester/Library/Application Support/Code/GPUCache", .cache),
        ("/Users/tester/.cache/puppeteer", .cache),
        ("/Applications/Foo.app", .app),
        ("/Users/tester/Applications/Bar.app", .app),
        ("/Users/tester/Library/Developer/Xcode/DerivedData/Shubi-abc", .developer),
        ("/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/Shubi-abc/DerivedData", .mcpBuild),
        ("/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,3 26.5.2", .developer),
        ("/Users/tester/Library/Developer/Xcode/Archives/2026-01-02/Shubi 1-2-26.xcarchive", .developer),
        ("/Users/tester/Library/Application Support/com.gone.app", .appData),
        ("/Users/tester/Library/Containers/com.gone.app", .appData),
        ("/Users/tester/Library/Saved Application State/com.gone.app.savedState", .appData),
        ("/Users/tester/Library/HTTPStorages/com.gone.app", .appData),
        ("/Users/tester/Library/WebKit/com.gone.app", .appData),
        ("/Users/tester/Library/Logs/zoom.us", .log),
        ("/Users/tester/Library/Logs/CoreSimulator/old.log", .log),
        // A VS Code fork's Chromium cache stays App cache's, never the AI section's.
        ("/Users/tester/Library/Application Support/Cursor/Cache", .cache),
        ("/Users/tester/.claude/projects/-Users-tester-x/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e.jsonl", .aiData),
        ("/Users/tester/.claude/projects/-Users-tester-x/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e", .aiData),
        ("/Users/tester/.claude/file-history/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e", .aiData),
        ("/Users/tester/.claude/shell-snapshots/snapshot-zsh-1.sh", .aiData),
        ("/Users/tester/.codex/sessions/2026/11/10/rollout-2026-11-10T01-32-09-01a1c127-1d76-7f71-8777-73c0c632c3d3.jsonl.zst", .aiData),
        ("/Users/tester/.codex/generated_images/019f2872-e2a0-78e3-b4a3-265f27a69674", .aiData),
        ("/Users/tester/.codex/visualizations/2026/10/03", .aiData),
        ("/Users/tester/.codex/.tmp/plugins", .aiData),
        ("/Users/tester/.gemini/tmp/project/chats/session-2026-03-13T04-41-2a206734.json", .aiData),
        ("/Users/tester/.gemini/antigravity/conversations/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e.pb", .aiData),
        ("/Users/tester/.gemini/antigravity/brain/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e", .aiData),
        ("/Users/tester/.aside/u/0/sessions/2026-10-20_JToejm1S7wLNdswA", .aiData),
        ("/Users/tester/.t3/userdata/logs/desktop.trace.ndjson", .aiData),
        ("/Users/tester/Library/Application Support/Cursor/logs/20261010T101010", .aiData),
        ("/Users/tester/Library/Application Support/Antigravity/CachedData/abc", .aiData),
    ])
    func eachKindIsAllowedOnlyWhereItLives(_ path: String, _ policy: Cleaner.Policy) {
        #expect(Cleaner.isAllowed(URL(filePath: path), as: policy, home: home))
        // Under any other kind's rules the same path is refused: a cache is never deleted as an app's data, and so on.
        for other in Self.policies where other != policy {
            #expect(!Cleaner.isAllowed(URL(filePath: path), as: other, home: home), "\(path) as \(other)")
        }
    }

    static let policies = Cleaner.Policy.allCases

    @Test(arguments: [
        "/System/Library/Kernels",
        "/Applications",
        "/Users/tester",
        "/Users/tester/Library/Preferences/com.foo.plist",
        "/Users/tester/Library/Caches",
        "/Users/tester/.ssh/id_rsa",
        "/Users/tester/Documents/../Library/Keychains",
        "/Users/other/Documents/a.pdf",
        // Only whole app/project folders, never something inside them or the parent itself.
        "/Users/tester/Library/Application Support/com.gone.app/data.db",
        "/Users/tester/Library/Application Support",
        "/Users/tester/Library/Developer/Xcode/DerivedData",
        "/Users/tester/Library/Developer/CoreSimulator/Devices/ABC",
        // XcodeBuildMCP's builds only, never the workspace with its locks and state, or a file inside the builds.
        "/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/Shubi-abc",
        "/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/Shubi-abc/state",
        "/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/DerivedData",
        "/Users/tester/Library/Developer/XcodeBuildMCP/workspaces/Shubi-abc/DerivedData/Build",
        // An Electron app's settings and data next to its caches, or something inside a cache.
        "/Users/tester/Library/Application Support/Code/User",
        // Web apps fill CacheStorage themselves, so it may hold offline content that never comes back.
        "/Users/tester/Library/Application Support/Slack/Service Worker/CacheStorage",
        "/Users/tester/Library/Application Support/Code/Cache/data_0",
        "/Users/tester/Library/Application Support/com.apple.foo/Cache",
        "/Users/tester/.cache",
        "/Users/tester/.cache/../.ssh",
        "/Users/tester/Library/Logs",
        "/Users/tester/Library/Developer/Xcode/Archives/2026-01-02",
        "/Users/tester/Library/Developer/Xcode/Archives/2026-01-02/notes.txt",
        "/Users/tester/Library/Preferences/com.gone.app.plist",
        "/Users/tester/Library/Saved Application State",
        // The folders themselves, never as the user's own files.
        "/Users/tester/Library",
        "/Users/tester/Applications",
        // An AI tool's settings, credentials, databases and memory, next to what may go.
        "/Users/tester/.claude",
        "/Users/tester/.claude/settings.json",
        "/Users/tester/.claude/CLAUDE.md",
        "/Users/tester/.claude/skills/x",
        "/Users/tester/.claude/history.jsonl",
        "/Users/tester/.claude/sessions/x",
        "/Users/tester/.claude/projects/-x",
        "/Users/tester/.claude/projects/-x/memory",
        "/Users/tester/.claude/projects/-x/memory/MEMORY.md",
        "/Users/tester/.claude/projects/-x/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e.jsonl.bak",
        // A session folder goes whole, never piece by piece.
        "/Users/tester/.claude/projects/-x/0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e/subagents/a.jsonl",
        "/Users/tester/.claude/cache",
        "/Users/tester/.claude/cache/../settings.json",
        "/Users/tester/.codex/auth.json",
        "/Users/tester/.codex/config.toml",
        "/Users/tester/.codex/state_5.sqlite",
        "/Users/tester/.codex/logs_2.sqlite",
        "/Users/tester/.codex/session_index.jsonl",
        "/Users/tester/.codex/sessions",
        "/Users/tester/.codex/sessions/2026/11/10",
        "/Users/tester/.codex/sessions/2026/11/10/notes.txt",
        "/Users/tester/.codex/generated_images",
        // A wildcard never matches a leading dot.
        "/Users/tester/.codex/cache/.lock",
        "/Users/tester/.gemini/oauth_creds.json",
        "/Users/tester/.gemini/tmp/project/logs.json",
        "/Users/tester/.gemini/antigravity",
        "/Users/tester/.gemini/antigravity/user_settings.pb",
        "/Users/tester/.gemini/antigravity-browser-profile/Default",
        "/Users/tester/.aside/password-manager",
        "/Users/tester/.aside/password-manager/vault",
        "/Users/tester/.aside/credentials.json",
        "/Users/tester/.aside/u/0/state.db",
        "/Users/tester/.aside/runtime/node",
        "/Users/tester/.t3/statev2.sqlite",
        "/Users/tester/.t3/worktrees/x",
        "/Users/tester/.t3/userdata/attachments/a.png",
        "/Users/tester/Library/Application Support/Cursor/User/settings.json",
        "/Users/tester/Library/Application Support/Claude/vm_bundles/claudevm.bundle/sessiondata.img",
        // Listed for review only: not verified, the tool's own state, or a tool Shubi doesn't know.
        "/Users/tester/.claude/jobs",
        "/Users/tester/.gemini/history",
        "/Users/tester/.gemini/antigravity/implicit",
        "/Users/tester/.aside/runtime",
        "/Users/tester/.t3/userdata/attachments",
        "/Users/tester/Library/Application Support/Cursor/User",
        "/Users/tester/Library/Application Support/Claude/vm_bundles/claudevm.bundle",
        "/Users/tester/.android/studio/agent/conversations",
    ])
    func rejectsEverythingElse(_ path: String) {
        for policy in Self.policies {
            #expect(!Cleaner.isAllowed(URL(filePath: path), as: policy, home: home), "\(policy)")
        }
    }

    /// A cache folder that links into ~/Documents or into another app's data folder takes nothing with it.
    @Test(arguments: ["Documents", "Library/Application Support"])
    func cacheFolderLinkedElsewhereIsRefused(_ destination: String) throws {
        let home = try makeTempHome()
        let target = home.appending(path: destination)
        let file = target.appending(path: "SomeApp/data.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        let caches = home.appending(path: "Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appending(path: "Firefox"), withDestinationURL: target)
        // What the scanner would list as the cache's contents.
        let throughCache = caches.appending(path: "Firefox/SomeApp")
        #expect(!Cleaner.isAllowed(throughCache, as: .cache, home: home))
    }

    /// An AI cache entry that links into ~/Documents may go itself, but takes nothing through it. A tool folder kept
    /// in a dotfiles repo resolves outside the catalog, so nothing in it is deleted.
    @Test func aiPathsThroughSymlinksAreRefused() throws {
        let home = try makeTempHome()
        try Data("x".utf8).write(to: home.appending(path: "Documents/notes.txt"))
        let cache = home.appending(path: ".claude/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache.appending(path: "link"), withDestinationURL: home.appending(path: "Documents"))
        #expect(Cleaner.isAllowed(cache.appending(path: "link"), as: .aiData, home: home))
        #expect(!Cleaner.isAllowed(cache.appending(path: "link/notes.txt"), as: .aiData, home: home))

        let dotfiles = home.appending(path: "dotfiles/codex/cache")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".codex"), withDestinationURL: home.appending(path: "dotfiles/codex"))
        #expect(!Cleaner.isAllowed(home.appending(path: ".codex/cache/x"), as: .aiData, home: home))
    }

    /// A workspace that links into ~/Documents takes nothing from there, even a folder named DerivedData.
    @Test func mcpWorkspaceLinkedElsewhereIsRefused() throws {
        let home = try makeTempHome()
        let project = home.appending(path: "Documents/Project")
        try FileManager.default.createDirectory(at: project.appending(path: "DerivedData"), withIntermediateDirectories: true)
        let workspaces = home.appending(path: "Library/Developer/XcodeBuildMCP/workspaces")
        try FileManager.default.createDirectory(at: workspaces.appending(path: "Real-abc/DerivedData"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspaces.appending(path: "Project-abc"), withDestinationURL: project)
        #expect(Cleaner.isAllowed(workspaces.appending(path: "Real-abc/DerivedData"), as: .mcpBuild, home: home))
        #expect(!Cleaner.isAllowed(workspaces.appending(path: "Project-abc/DerivedData"), as: .mcpBuild, home: home))
    }

    @Test func rejectsPathThroughSymlinkedParent() throws {
        let home = try makeTempHome()
        let link = home.appending(path: "Documents/sys")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/System"))
        #expect(!Cleaner.isAllowed(link.appending(path: "Library"), as: .ownFiles, home: home))
        // The link itself lives in the home folder; removing it doesn't touch /System.
        #expect(Cleaner.isAllowed(link, as: .ownFiles, home: home))
    }

    @Test func permanentDeleteRemovesFile() throws {
        let file = try makeFileInRealHome()
        #expect(Cleaner.delete([file], as: .cache, mode: .permanent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func trashMovesFile() throws {
        let file = try makeFileInRealHome()
        #expect(Cleaner.delete([file], as: .cache, mode: .trash).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// The list can be stale: the user may have removed the file in Finder since the scan.
    @Test func deletingWhatIsAlreadyGoneSucceeds() throws {
        let file = try makeFileInRealHome()
        #expect(Cleaner.delete([file], as: .cache, mode: .permanent).isEmpty)
        #expect(Cleaner.delete([file], as: .cache, mode: .permanent).isEmpty)
    }

    @Test func refusedPathIsReportedNotDeleted() {
        let failures = Cleaner.delete([URL(filePath: "/System/Library/Kernels")], as: .ownFiles, mode: .permanent)
        #expect(failures.count == 1)
    }

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        return home
    }

    /// delete() checks against the real home, so the fixture must live there, where its kind is allowed:
    /// caches by default, `Applications/ShubiTests` for an app, `Library/Application Support` for an app's data.
    private func makeFileInRealHome(_ folder: String = "Library/Caches/ShubiTests") throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "ShubiTests-" + UUID().uuidString)
        try Data("x".utf8).write(to: file)
        return file
    }

    private func makeAppInRealHome() throws -> URL { try makeFileInRealHome("Applications/ShubiTests") }
    private func makeAppDataInRealHome() throws -> URL { try makeFileInRealHome("Library/Application Support") }

    @Test func commandItemsRunTheirCommand() {
        let ok = ScanItem(url: URL(filePath: "/tmp/ok"), name: "ok", size: 0, lastUsed: nil, kind: .packageCache, command: "true")
        let bad = ScanItem(url: URL(filePath: "/tmp/bad"), name: "bad", size: 0, lastUsed: nil, kind: .packageCache, command: "echo nope >&2; exit 3")
        let failures = Cleaner.clean([ok, bad], mode: .trash)
        #expect(failures.map(\.url) == [bad.url])
        #expect(failures.first?.reason == "nope")
    }

    /// An app whose removal failed keeps its data: wiping only the data would just reset the app.
    @Test func leftoversGoOnlyAfterTheApp() throws {
        let data = try makeAppDataInRealHome()
        let stuck = ScanItem(url: URL(filePath: "/System/Applications/Stuck.app"), name: "Stuck", size: 1, lastUsed: nil, kind: .app,
                             leftovers: [data])
        #expect(Cleaner.clean([stuck], mode: .permanent, removesLeftovers: true).count == 1)
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))

        let app = try makeAppInRealHome()
        let removable = ScanItem(url: app, name: "Gone", size: 1, lastUsed: nil, kind: .app, leftovers: [data])
        #expect(Cleaner.clean([removable], mode: .permanent, removesLeftovers: true).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    /// An uninstalled app leaves data, caches and logs; each goes under its own folder's rules.
    @Test func leftoversInEveryLibraryFolderGoWithTheApp() throws {
        let app = try makeAppInRealHome()
        let leftovers = try ["Library/Application Support", "Library/Caches", "Library/Logs"].map { try makeFileInRealHome($0) }
        defer { leftovers.forEach { try? FileManager.default.removeItem(at: $0) } }
        let item = ScanItem(url: app, name: "Gone", size: 1, lastUsed: nil, kind: .app, leftovers: leftovers)
        #expect(Cleaner.clean([item], mode: .permanent, removesLeftovers: true).isEmpty)
        for leftover in leftovers { #expect(!FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false))) }
    }

    /// Leftovers may hold a notes app's only copy of the user's documents, so they stay unless asked for.
    @Test func leftoversStayByDefault() throws {
        let app = try makeAppInRealHome(), data = try makeAppDataInRealHome()
        defer { try? FileManager.default.removeItem(at: data) }
        let item = ScanItem(url: app, name: "Gone", size: 1, lastUsed: nil, kind: .app, leftovers: [data])
        #expect(Cleaner.clean([item], mode: .permanent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: app.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    /// Removing one copy of an app must not take the data another installed copy still uses (Chess stays in /System).
    @Test func leftoversStayWhileAnotherCopyIsInstalled() throws {
        let copy = try makeAppInRealHome(), data = try makeAppDataInRealHome()
        defer { try? FileManager.default.removeItem(at: data) }
        let item = ScanItem(url: copy, name: "Chess", size: 1, lastUsed: nil, kind: .app, ownerBundleID: "com.apple.Chess", leftovers: [data])
        #expect(Cleaner.clean([item], mode: .permanent, removesLeftovers: true).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    /// A copy on another disk still counts; one in any Trash doesn't.
    @Test func copiesInTrashDontCountButOtherDisksDo() {
        #expect(!LibraryScanner.isInTrash(URL(filePath: "/Volumes/External/Applications/A.app").pathComponents))
        #expect(LibraryScanner.isInTrash(URL(filePath: "/Users/x/.Trash/A.app").pathComponents))
        #expect(LibraryScanner.isInTrash(URL(filePath: "/Volumes/External/.Trashes/501/A.app").pathComponents))
    }

    /// A log written to after the scan is current again and stays; an untouched one goes.
    @Test func logWrittenSinceTheScanStays() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/ShubiTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = folder.appending(path: "written.log"), untouched = folder.appending(path: "untouched.log")
        for log in [written, untouched] {
            try Data("x".utf8).write(to: log)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-40 * 86_400)],
                                                  ofItemAtPath: log.path(percentEncoded: false))
        }
        // The scan reads (and caches) both files' old dates.
        let targets = LibraryScanner.oldLogs(in: folder, before: .now.addingTimeInterval(-LibraryScanner.logRetention))
        #expect(targets.count == 2)
        try Data("new line".utf8).write(to: written)

        let item = ScanItem(url: folder, name: "logs", size: 2, lastUsed: nil, kind: .log, targets: targets)
        #expect(Cleaner.clean([item], mode: .permanent).isEmpty)
        #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: untouched.path(percentEncoded: false)))
    }

    /// A session written to since the scan is in use again; an old one still only goes from where the catalog allows.
    /// A session is checked whole before anything goes: one file outside the catalog keeps all of them.
    /// Freshness and growth since the scan are checked on a fixture home in `AIScannerTests`.
    @Test func aiSessionOutsideTheCatalogIsRefusedWhole() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Shubi-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = folder.appending(path: "written.jsonl"), old = folder.appending(path: "old.jsonl")
        try Data("x".utf8).write(to: written)
        try Data("x".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-86_400)], ofItemAtPath: old.path(percentEncoded: false))
        let session = ScanItem.Kind.aiData(AIEntry(tool: .claudeCode, category: .conversation, isVerified: true))

        // Outside the home folder, so outside every catalog path.
        let stray = Cleaner.clean([ScanItem(url: old, name: "old", size: 1, lastUsed: nil, kind: session, targets: [old, written])], mode: .permanent)
        #expect(stray.map(\.reason) == [String(localized: "허용되지 않은 경로")])
        for file in [written, old] { #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false))) }
    }

    /// An app started after the scan keeps its files; Finder is always running.
    @Test func itemOfAppRunningNowIsSkipped() throws {
        let file = try makeFileInRealHome()
        let running = ScanItem(url: file, name: "cache", size: 1, lastUsed: nil, kind: .cache, ownerBundleID: "com.apple.finder")
        #expect(Cleaner.clean([running], mode: .permanent).map(\.url) == [file])
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let idle = ScanItem(url: file, name: "cache", size: 1, lastUsed: nil, kind: .cache, ownerBundleID: "com.example.not-installed")
        #expect(Cleaner.clean([idle], mode: .permanent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// Command-line builds and other apps sharing the files count as using them, like the owner.
    @Test func itemInUseByAToolOrASharingAppIsSkipped() throws {
        let file = try makeFileInRealHome()
        let building = ScanItem(url: file, name: "cache", size: 1, lastUsed: nil, kind: .cache, usedByTools: ["Shubi"])
        #expect(building.isInUse)
        #expect(Cleaner.clean([building], mode: .permanent).map(\.url) == [file])
        let shared = ScanItem(url: file, name: "cache", size: 1, lastUsed: nil, kind: .browserCache,
                              ownerBundleID: "com.example.not-installed", sharedWith: ["com.apple.finder"])
        #expect(shared.isInUse)
        let idle = ScanItem(url: file, name: "cache", size: 1, lastUsed: nil, kind: .cache, usedByTools: ["no-such-tool"])
        #expect(!idle.isInUse)
        #expect(Cleaner.clean([idle], mode: .permanent).isEmpty)
    }

    /// An app on an external drive is installed, even one mounted read-only; only a disk image's isn't.
    @Test func appsOutsideDiskImagesCountAsInstalled() {
        #expect(!LibraryScanner.isOnInstallerImage(URL(filePath: "/Applications/Safari.app")))
        #expect(!LibraryScanner.isOnInstallerImage(URL(filePath: "/Volumes/Unreadable/App.app")))
    }

    @Test func commandsCantWaitForInput() {
        #expect(Cleaner.run("read answer", timeout: 5) != nil)
    }

    @Test func commandsThatHangAreStopped() {
        let start = Date.now
        #expect(Cleaner.run("sleep 30", timeout: 1) != nil)
        #expect(Date.now.timeIntervalSince(start) < 10)
    }

    /// A tool's child that ignores SIGTERM must not keep running after the UI says "stopped".
    @Test func timeoutStopsChildrenThatIgnoreTerm() throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "Shubi-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "(trap '' TERM; exec sleep 300) & echo $! > \(shellQuote(pidFile.path(percentEncoded: false))); wait"
        #expect(Cleaner.run(script, timeout: 3) != nil)
        let child = try #require(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date.now.addingTimeInterval(5)
        while kill(child, 0) == 0, Date.now < deadline { usleep(100_000) }
        let alive = kill(child, 0) == 0
        if alive { kill(child, SIGKILL) }
        #expect(!alive)
    }

    @Test func shellQuoteSurvivesQuotes() {
        #expect(Cleaner.run("test \(shellQuote("it's")) = \"it's\"") == nil)
    }
}
