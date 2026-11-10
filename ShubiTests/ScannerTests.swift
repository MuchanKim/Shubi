import Foundation
import Testing
@testable import Shubi

/// Runs every scanner against this Mac: results vary, but IDs must be unique (Table requires it).
struct ScannerTests {
    @Test(arguments: ["browser", "appCaches", "orphanedData", "simulators", "runtimes", "deviceSupport", "derivedData", "previews",
                      "archives", "logs", "ai", "packages"])
    func scanResultsHaveUniqueIDs(_ scanner: String) async throws {
        let items: [ScanItem] = switch scanner {
        case "browser": await BrowserScanner.scan()
        case "appCaches": await LibraryScanner.appCaches()
        case "orphanedData": await LibraryScanner.orphanedData()
        case "simulators": try await DeveloperScanner.simulators()
        case "runtimes": try await DeveloperScanner.runtimes()
        case "deviceSupport": await DeveloperScanner.deviceSupport()
        case "derivedData": await DeveloperScanner.derivedData()
        case "previews": await DeveloperScanner.previews()
        case "archives": await DeveloperScanner.archives()
        case "logs": await LibraryScanner.oldLogs()
        case "ai": await AIScanner.scan(.all)
        default: try await PackageCacheScanner.scan()
        }
        #expect(Set(items.map(\.id)).count == items.count)
    }

    /// A lone "Cache" folder isn't enough: only a Chromium profile's caches are taken, and never its settings.
    @Test func chromiumCachesNeedAChromiumProfile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Shubi-electron-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let electron = root.appending(path: "Code"), other = root.appending(path: "Other")
        for path in ["Code/Cache", "Code/GPUCache", "Code/Service Worker/CacheStorage", "Code/User", "Other/Cache"] {
            try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
        #expect(Set(LibraryScanner.chromiumCaches(in: electron).map(\.lastPathComponent)) == ["Cache", "GPUCache"])
        #expect(LibraryScanner.chromiumCaches(in: other).isEmpty)
    }

    /// A folder an app still writes to keeps its recent files; a quiet one goes whole.
    @Test func oldLogsKeepRecentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Shubi-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cutoff = Date.now.addingTimeInterval(-LibraryScanner.logRetention)
        func file(_ path: String, daysAgo: Double) throws -> URL {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-daysAgo * 86_400)],
                                                  ofItemAtPath: url.path(percentEncoded: false))
            return url
        }
        let stale = try file("Active/old.log", daysAgo: 40)
        _ = try file("Active/new.log", daysAgo: 1)
        let quietA = try file("Quiet/a.log", daysAgo: 60)
        let quietB = try file("Quiet/sub/b.log", daysAgo: 45)
        _ = try file("Fresh/c.log", daysAgo: 2)

        #expect(LibraryScanner.oldLogs(in: root.appending(path: "Active"), before: cutoff).map(\.lastPathComponent) == [stale.lastPathComponent])
        // Files, never the folder: anything written to it after the scan stays.
        #expect(Set(LibraryScanner.oldLogs(in: root.appending(path: "Quiet"), before: cutoff).map(\.lastPathComponent))
                == [quietA.lastPathComponent, quietB.lastPathComponent])
        #expect(LibraryScanner.oldLogs(in: root.appending(path: "Fresh"), before: cutoff).isEmpty)
    }

    /// Without a real bundle ID there's nothing to match ~/Library folders against.
    @Test func appWithoutBundleIDHasNoLeftovers() {
        let app = URL(filePath: "/Applications/Some.app")
        #expect(LibraryScanner.leftovers(ofApp: "", at: app).isEmpty)
        #expect(LibraryScanner.leftovers(ofApp: "Caches", at: app).isEmpty)
    }

    /// A name two different apps answer to can't pin a data folder on either; two copies of one app still can.
    @Test func sharedNamesHaveNoOwner() {
        let a = URL(filePath: "/Applications/A.app"), b = URL(filePath: "/Applications/B.app"), a2 = URL(filePath: "/Users/x/Applications/A.app")
        let owners = LibraryScanner.uniqueOwners([
            (a, "com.a.app", ["A", "Electron"]),
            (b, "com.b.app", ["B", "Electron"]),
            (a2, "com.a.app", ["A"]),
        ])
        #expect(owners["a"] != nil)
        #expect(owners["b"] == b)
        #expect(owners["electron"] == nil)
    }

    @Test func helperFoldersMatchTheirParentApp() {
        #expect(LibraryScanner.owningApp(of: "com.apple.calculator.helper") != nil)
        #expect(LibraryScanner.owningApp(of: "com.surely.not.installed.zzz") == nil)
    }

    @Test func processOutputIsReturned() throws {
        #expect(try runProcess("/bin/echo", ["hi"], timeout: 5) == Data("hi\n".utf8))
    }

    @Test func failingProcessThrowsItsError() {
        #expect(throws: CommandError.self) { try runProcess("/bin/zsh", ["-c", "echo broken >&2; exit 1"], timeout: 5) }
    }

    @Test func runtimeNamesAreReadable() {
        #expect(DeveloperScanner.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-4") == "iOS 26.4")
        #expect(DeveloperScanner.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-2") == "watchOS 11.2")
    }

    /// A device can be unavailable while its runtime is still installed; only a removed runtime makes it orphaned.
    @Test(arguments: [("com.apple.CoreSimulator.SimRuntime.iOS-18-0", true), ("com.apple.CoreSimulator.SimRuntime.iOS-26-2", false)])
    func simulatorIsOrphanedOnlyWhenItsRuntimeIsGone(_ runtime: String, _ expected: Bool) {
        let installed: Set<String> = ["com.apple.CoreSimulator.SimRuntime.iOS-26-2", "com.apple.CoreSimulator.SimRuntime.watchOS-11-2"]
        #expect(DeveloperScanner.isOrphaned(runtime: runtime, installedRuntimes: installed) == expected)
    }

    /// Otherwise the same folder is listed, counted and smart-cleaned as both a browser cache and an app cache.
    @Test func detectedBrowserCacheFoldersAreCovered() {
        let browsers = BrowserScanner.browsers(installed: ["com.example.newbrowser": URL(filePath: "/Applications/New Browser.app")])
        let covered = BrowserScanner.cacheFolderNames(of: browsers)
        #expect(covered.isSuperset(of: ["New Browser", "com.example.newbrowser", "Google", "com.google.Chrome"]))
    }
}

struct OrphanDetectionTests {
    let installed: Set<String> = ["us.zoom.xos", "com.charliemonroe.Downie-4", "com.openai.codex", "com.google.antigravity"]

    @Test(arguments: [
        "zoom.us",                                     // product name, not a bundle ID
        "io.branch",                                   // SDK name
        "com.charliemonroe.Downie-4-Downie-Extension", // extension joined with "-"
        "com.google.antigravity.ShipIt",               // helper joined with "."
        "com.openai.chat",                             // same vendor as an installed app
    ])
    func liveOrUnknownFoldersAreNotOrphaned(_ name: String) {
        #expect(!LibraryScanner.isOrphaned(name, installed: installed))
    }

    @Test func uninstalledVendorIsOrphaned() {
        #expect(LibraryScanner.isOrphaned("com.spotify.client", installed: installed))
    }

    /// Spotlight returns nothing while it reindexes or when indexing is off.
    @Test func unknownInstallListOrphansNothing() {
        #expect(!LibraryScanner.isOrphaned("com.spotify.client", installed: []))
    }
}

struct FileSizeTests {
    /// Final Cut, Parallels and UTM may be uninstalled, so macOS no longer knows their folders are packages.
    @Test(arguments: ["Movie.app/Contents", "Project.fcpbundle/Media", "Windows.pvm", "Linux.utm/Data", "Win.vmwarevm"])
    func filesInsidePackagesAreNotLoose(_ package: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Shubi-pkg-\(UUID().uuidString)")
        let inside = root.appending(path: "\(package)/clip.mov")
        let loose = root.appending(path: "Movies/clip.mov")
        defer { try? FileManager.default.removeItem(at: root) }
        for file in [inside, loose] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 1).write(to: file)
        }
        #expect(!SpotlightScanner.isLooseFile(inside))
        #expect(SpotlightScanner.isLooseFile(loose))
    }

    @Test func fileSizeIsItsAllocatedSize() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "Shubi-size-\(UUID().uuidString)")
        try Data(count: 100_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(allocatedSize(of: file) >= 100_000)
    }
}
