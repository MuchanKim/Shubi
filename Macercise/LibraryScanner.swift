import AppKit
import Synchronization

/// App caches and data folders left in ~/Library, matched to their owning app by folder name.
nonisolated enum LibraryScanner {
    private static let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")

    @concurrent static func appCaches() async -> [ScanItem] {
        cachesFolderItems() + electronCaches()
    }

    private static func cachesFolderItems() -> [ScanItem] {
        let skipped = BrowserScanner.cacheFolderNames().union(PackageCacheScanner.cacheFolderNames)
        let installed = installedBundleIDs()
        return directoryContents(library.appending(path: "Caches")).compactMap { folder in
            let name = folder.lastPathComponent
            guard !skipped.contains(name), !isSystemOwned(name) else { return nil }
            let contents = directoryContents(folder)
            let size = allocatedSize(of: folder)
            guard !contents.isEmpty, size > 0 else { return nil }
            let owner = owningApp(of: name)
            let orphaned = owner == nil && isOrphaned(name, installed: installed)
            let ownerID = owner.flatMap { Bundle(url: $0)?.bundleIdentifier }
            return ScanItem(
                url: folder,
                name: owner.map(displayName) ?? name,
                size: size,
                lastUsed: modificationDate(folder),
                kind: .cache,
                targets: contents,
                isRunning: ownerID.map(isAppRunning) ?? false,
                ownerBundleID: ownerID,
                isOrphaned: orphaned,
                isOwnerUnknown: owner == nil && !orphaned,
                details: owner.map { [Fact(label: String(localized: "앱"), value: $0.path(percentEncoded: false))] } ?? []
            )
        }
    }

    /// Chromium's disk caches inside an Electron app's data folder (`~/Library/Application Support/<app>/Cache`, ...).
    static let chromiumCacheNames: Set<String> = [
        // Not `Service Worker/CacheStorage`: web apps fill it themselves (offline content), so it may not come back.
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
    ]

    /// A data folder's Chromium caches, or none when the folder isn't a Chromium profile: a lone "Cache" folder could be anything.
    static func chromiumCaches(in folder: URL) -> [URL] {
        let present = chromiumCacheNames.sorted().map { folder.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        let isChromium = ["Code Cache", "GPUCache"].contains { FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
        return isChromium ? present : []
    }

    /// Electron apps (VS Code, Slack, Discord, ...) keep a browser's caches in their data folder instead of ~/Library/Caches.
    private static func electronCaches() -> [ScanItem] {
        let apps = installedAppsByName()
        let installed = installedBundleIDs()
        return directoryContents(library.appending(path: "Application Support")).compactMap { folder in
            let name = folder.lastPathComponent
            // An uninstalled app's whole folder is already listed under orphaned data; counting its caches again would double it.
            guard !isSystemOwned(name), !(isOrphaned(name, installed: installed) && owningApp(of: name) == nil) else { return nil }
            let caches = chromiumCaches(in: folder)
            let size = caches.reduce(0) { $0 + allocatedSize(of: $1) }
            guard size > 0 else { return nil }
            // The folder is named after the app's product name, not its bundle ID ("Code" for VS Code).
            let owner = apps[name.lowercased()]
            let ownerID = owner.flatMap { Bundle(url: $0)?.bundleIdentifier }
            return ScanItem(
                url: folder,
                name: owner.map(displayName) ?? name,
                size: size,
                lastUsed: caches.compactMap(modificationDate).max(),
                kind: .cache,
                targets: caches,
                isRunning: ownerID.map(isAppRunning) ?? false,
                ownerBundleID: ownerID,
                // Unmatched names (Miro keeps "RealtimeBoard") can't be checked for use, so smart clean skips them.
                isOwnerUnknown: ownerID == nil,
                details: [Fact(label: String(localized: "캐시 종류"), value: String(localized: "Electron 앱 캐시"))]
                    + (owner.map { [Fact(label: String(localized: "앱"), value: $0.path(percentEncoded: false))] } ?? [])
            )
        }
    }

    /// Installed apps by lowercased file name, bundle name and executable name.
    private static func installedAppsByName() -> [String: URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let apps = SpotlightScanner.query("kMDItemContentType == \"com.apple.application-bundle\"",
                                          scopes: [URL(filePath: "/Applications"), home.appending(path: "Applications")])
            .compactMap(\.url)
            .map { url in
                let info = Bundle(url: url)?.infoDictionary
                let names = [url.deletingPathExtension().lastPathComponent, info?["CFBundleName"] as? String, info?["CFBundleExecutable"] as? String]
                return (url: url, bundleID: info?["CFBundleIdentifier"] as? String, names: names.compactMap { $0 })
            }
        return uniqueOwners(apps)
    }

    /// Names only one app answers to. When two different apps share a name, the folder can't be pinned on either.
    static func uniqueOwners(_ apps: [(url: URL, bundleID: String?, names: [String])]) -> [String: URL] {
        var candidates: [String: [(url: URL, bundleID: String?)]] = [:]
        for app in apps {
            for name in Set(app.names.map { $0.lowercased() }) { candidates[name, default: []].append((app.url, app.bundleID)) }
        }
        return candidates.compactMapValues { found in
            // Two copies of the same app are still one owner.
            Set(found.map(\.bundleID)).count == 1 ? found[0].url : nil
        }
    }

    static let logRetention: TimeInterval = 30 * 86_400

    /// Logs in ~/Library/Logs untouched for 30 days, grouped by their top-level folder.
    @concurrent static func oldLogs() async -> [ScanItem] {
        let cutoff = Date.now.addingTimeInterval(-logRetention)
        return directoryContents(library.appending(path: "Logs")).compactMap { entry in
            let old = oldLogs(in: entry, before: cutoff)
            let size = old.reduce(0) { $0 + allocatedSize(of: $1) }
            guard size > 0 else { return nil }
            return ScanItem(url: entry, name: entry.lastPathComponent, size: size, lastUsed: modificationDate(entry), kind: .log,
                            targets: old, details: [Fact(label: String(localized: "30일 넘은 파일"), value: String(localized: "\(old.count)개"))])
        }
    }

    /// Each file under `entry` last written before the cutoff. Files only, never the folder:
    /// a file that couldn't be read, or one written after the scan, must not go with it.
    static func oldLogs(in entry: URL, before cutoff: Date) -> [URL] {
        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return isOld(entry, before: cutoff) ? [entry] : []
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var old: [URL] = []
        // Filtered while walking, so a large log tree isn't held in memory.
        for case let file as URL in FileManager.default.enumerator(at: entry, includingPropertiesForKeys: Array(keys)) ?? .init() {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isRegularFile == true, let date = values?.contentModificationDate, date < cutoff { old.append(file) }
        }
        return old
    }

    /// A regular file whose last write is before the cutoff, read from disk now. Unreadable counts as not old.
    static func isOld(_ url: URL, before cutoff: Date) -> Bool {
        // A fresh URL: the scanned one caches the modification date it had at scan time.
        let values = try? URL(filePath: url.path(percentEncoded: false)).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        return values?.isRegularFile == true && (values?.contentModificationDate.map { $0 < cutoff } ?? false)
    }

    /// What an app keeps in ~/Library under its bundle ID, deleted with the app.
    /// Name-only folders (`Application Support/Slack`) are left alone: another app could share the name.
    /// Preferences stay too: cfprefsd caches them and may write a deleted plist back, and they're a few kilobytes.
    static func leftovers(ofApp bundleID: String, at app: URL) -> [URL] {
        // Another installed copy of the app still uses this data.
        guard bundleID.split(separator: ".").count >= 2, installedCopies(of: bundleID, excluding: [app]).isEmpty else { return [] }
        var paths = ["Application Support/\(bundleID)", "Caches/\(bundleID)",
                     "Saved Application State/\(bundleID).savedState", "HTTPStorages/\(bundleID)",
                     "HTTPStorages/\(bundleID).binarycookies", "WebKit/\(bundleID)", "Logs/\(bundleID)"]
        // Touching another app's container without Full Disk Access makes macOS prompt.
        if FullDiskAccess.isGranted { paths.append("Containers/\(bundleID)") }
        return paths.map { library.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Installed copies of an app other than `excluded`, anywhere but a Trash. Other disks count:
    /// a copy there may share this data, and a mounted installer image only errs toward keeping it.
    static func installedCopies(of bundleID: String, excluding excluded: [URL]) -> [URL] {
        // Path components, so a trailing slash on a directory URL doesn't matter.
        let skip = Set(excluded.map(\.standardizedFileURL.pathComponents))
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).filter { url in
            let components = url.standardizedFileURL.pathComponents
            return !skip.contains(components) && !isInTrash(components) && FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    /// The home Trash or another disk's `.Trashes`.
    static func isInTrash(_ components: [String]) -> Bool {
        components.contains(".Trash") || components.contains(".Trashes")
    }

    /// The home Trash's size, or nil when it can't be read (it needs Full Disk Access).
    @concurrent static func trashSize() async -> Int64? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"),
                                                                       includingPropertiesForKeys: nil) else { return nil }
        return items.reduce(0) { $0 + allocatedSize(of: $1) }
    }

    /// Data folders named after an app bundle ID whose app is no longer installed.
    @concurrent static func orphanedData() async -> [ScanItem] {
        // Reading other apps' containers needs Full Disk Access; without it macOS prompts on every scan.
        let roots = ["Application Support"] + (FullDiskAccess.isGranted ? ["Containers"] : [])
        let installed = installedBundleIDs()
        return roots.flatMap { root in
            directoryContents(library.appending(path: root)).compactMap { folder -> ScanItem? in
                let name = folder.lastPathComponent
                // LaunchServices backs up Spotlight, which misses apps while it reindexes.
                guard !isSystemOwned(name), isOrphaned(name, installed: installed), owningApp(of: name) == nil else { return nil }
                let size = allocatedSize(of: folder)
                guard size > 0 else { return nil }
                return ScanItem(url: folder, name: name, size: size, lastUsed: modificationDate(folder),
                                kind: .appData, isOrphaned: true, details: [Fact(label: String(localized: "위치"), value: "~/Library/\(root)")])
            }
        }
    }

    /// The installed app a folder belongs to. Helper folders like `com.google.antigravity.ShipIt` match their parent app.
    static func owningApp(of folderName: String) -> URL? {
        var parts = folderName.split(separator: ".")
        while parts.count >= 2 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")),
               // LaunchServices remembers apps from unmounted disk images and deleted bundles.
               FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
               !url.path(percentEncoded: false).hasPrefix("/Volumes/") {
                return url
            }
            parts.removeLast()
        }
        return nil
    }

    /// Errs toward "not orphaned": a wrong "orphaned" label invites deleting a live app's data.
    static func isOrphaned(_ folderName: String, installed: Set<String>) -> Bool {
        let parts = folderName.split(separator: ".")
        // `zoom.us`, `Battle.net`, `io.branch` are product or SDK names, not bundle IDs.
        // An empty list means Spotlight couldn't answer, not that nothing is installed.
        guard !installed.isEmpty, parts.count >= 3, !folderName.contains(" ") else { return false }
        let vendor = parts.prefix(2).joined(separator: ".")
        return !installed.contains { id in
            // Same app, its helpers (`.ShipIt`, `-Extension`), or another app from the same vendor that may share data.
            folderName == id || folderName.hasPrefix(id + ".") || folderName.hasPrefix(id + "-")
                || id.split(separator: ".").prefix(2).joined(separator: ".") == vendor
        }
    }

    private static let recentInstalled = Mutex<(date: Date, ids: Set<String>)?>(nil)

    /// Bundle IDs of every app Spotlight knows about, outside mounted disk images.
    /// The summary runs both library scans at once; the lock makes the second wait for and reuse the first's query.
    static func installedBundleIDs() -> Set<String> {
        recentInstalled.withLock { recent in
            if let recent, recent.date.timeIntervalSinceNow > -30 { return recent.ids }
            let ids = queryInstalledBundleIDs()
            recent = (.now, ids)
            return ids
        }
    }

    private static func queryInstalledBundleIDs() -> Set<String> {
        Set(SpotlightScanner.query("kMDItemContentType == \"com.apple.application-bundle\"", scopes: [URL(filePath: "/")])
            .filter { !($0.url?.path(percentEncoded: false).hasPrefix("/Volumes/") ?? true) }
            .compactMap { $0.string(kMDItemCFBundleIdentifier) })
    }

    private static func isSystemOwned(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix(".")
    }

    private static func displayName(_ app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }
}

nonisolated enum FullDiskAccess {
    /// ~/Library/Safari is unreadable without Full Disk Access, so it doubles as a probe.
    static var isGranted: Bool {
        let safari = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(at: safari, includingPropertiesForKeys: nil)) != nil
    }
}
