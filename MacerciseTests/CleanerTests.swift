import Foundation
import Testing
@testable import Macercise

struct CleanerTests {
    let home = URL(filePath: "/Users/tester")

    @Test(arguments: [
        "/Users/tester/Documents/a.pdf",
        "/Users/tester/Downloads/movie.mov",
        "/Users/tester/Library/Caches/Google/Chrome/x",
        "/Applications/Foo.app",
        "/Users/tester/Applications/Bar.app",
        "/Users/tester/Library/Developer/Xcode/DerivedData/Macercise-abc",
        "/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,3 26.5.2",
        "/Users/tester/Library/Application Support/com.gone.app",
        "/Users/tester/Library/Containers/com.gone.app",
        "/Users/tester/Library/Application Support/Code/Cache",
        "/Users/tester/Library/Application Support/Code/GPUCache",
        "/Users/tester/.cache/puppeteer",
        "/Users/tester/Library/Logs/zoom.us",
        "/Users/tester/Library/Logs/CoreSimulator/old.log",
        "/Users/tester/Library/Developer/Xcode/Archives/2026-01-02/Macercise 1-2-26.xcarchive",
        "/Users/tester/Library/Saved Application State/com.gone.app.savedState",
        "/Users/tester/Library/HTTPStorages/com.gone.app",
        "/Users/tester/Library/WebKit/com.gone.app",
    ])
    func allowsUserFilesCachesAndApps(_ path: String) {
        #expect(Cleaner.isAllowed(URL(filePath: path), home: home))
    }

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
    ])
    func rejectsEverythingElse(_ path: String) {
        #expect(!Cleaner.isAllowed(URL(filePath: path), home: home))
    }

    @Test func rejectsPathThroughSymlinkedParent() throws {
        let home = try makeTempHome()
        let link = home.appending(path: "Documents/sys")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/System"))
        #expect(!Cleaner.isAllowed(link.appending(path: "Library"), home: home))
        // The link itself lives in the home folder; removing it doesn't touch /System.
        #expect(Cleaner.isAllowed(link, home: home))
    }

    @Test func permanentDeleteRemovesFile() throws {
        let file = try makeFileInRealHome()
        #expect(Cleaner.delete([file], mode: .permanent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func trashMovesFile() throws {
        let file = try makeFileInRealHome()
        #expect(Cleaner.delete([file], mode: .trash).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// The list can be stale: the user may have removed the file in Finder since the scan.
    @Test func deletingWhatIsAlreadyGoneSucceeds() throws {
        let file = try makeFileInRealHome()
        #expect(Cleaner.delete([file], mode: .permanent).isEmpty)
        #expect(Cleaner.delete([file], mode: .permanent).isEmpty)
    }

    @Test func refusedPathIsReportedNotDeleted() {
        let failures = Cleaner.delete([URL(filePath: "/System/Library/Kernels")], mode: .permanent)
        #expect(failures.count == 1)
    }

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        return home
    }

    /// delete() checks against the real home, so the fixture must live there (in Caches, which is allowed).
    private func makeFileInRealHome() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacerciseTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: UUID().uuidString)
        try Data("x".utf8).write(to: file)
        return file
    }

    @Test func commandItemsRunTheirCommand() {
        let ok = ScanItem(url: URL(filePath: "/tmp/ok"), name: "ok", size: 0, lastUsed: nil, kind: .packageCache, command: "true")
        let bad = ScanItem(url: URL(filePath: "/tmp/bad"), name: "bad", size: 0, lastUsed: nil, kind: .packageCache, command: "echo nope >&2; exit 3")
        let failures = Cleaner.clean([ok, bad], mode: .trash)
        #expect(failures.map(\.url) == [bad.url])
        #expect(failures.first?.reason == "nope")
    }

    /// An app whose removal failed keeps its data: wiping only the data would just reset the app.
    @Test func leftoversGoOnlyAfterTheApp() throws {
        let data = try makeFileInRealHome()
        let stuck = ScanItem(url: URL(filePath: "/System/Applications/Stuck.app"), name: "Stuck", size: 1, lastUsed: nil, kind: .app,
                             leftovers: [data])
        #expect(Cleaner.clean([stuck], mode: .permanent, removesLeftovers: true).count == 1)
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))

        let app = try makeFileInRealHome()
        let removable = ScanItem(url: app, name: "Gone", size: 1, lastUsed: nil, kind: .app, leftovers: [data])
        #expect(Cleaner.clean([removable], mode: .permanent, removesLeftovers: true).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    /// Leftovers may hold a notes app's only copy of the user's documents, so they stay unless asked for.
    @Test func leftoversStayByDefault() throws {
        let app = try makeFileInRealHome(), data = try makeFileInRealHome()
        let item = ScanItem(url: app, name: "Gone", size: 1, lastUsed: nil, kind: .app, leftovers: [data])
        #expect(Cleaner.clean([item], mode: .permanent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: app.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    /// Removing one copy of an app must not take the data another installed copy still uses (Chess stays in /System).
    @Test func leftoversStayWhileAnotherCopyIsInstalled() throws {
        let copy = try makeFileInRealHome(), data = try makeFileInRealHome()
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
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacerciseTests/logs-\(UUID().uuidString)")
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
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "Macercise-pid-\(UUID().uuidString)")
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
