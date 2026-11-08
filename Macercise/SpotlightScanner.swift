import AppKit
import CoreServices
import Foundation

// shortcut: Spotlight only sees indexed volumes; add a FileManager fallback if unindexed disks matter.
nonisolated enum SpotlightScanner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    // shortcut: results are capped to the largest N to keep the table fast; raise or paginate if users hit it.
    private static let resultLimit = 2000

    @concurrent static func oldApps(unusedFor days: Int) async -> [ScanItem] {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let ownID = Bundle.main.bundleIdentifier
        return query("kMDItemContentType == \"com.apple.application-bundle\"",
                     scopes: [URL(filePath: "/Applications"), home.appending(path: "Applications")])
            .compactMap { item -> ScanItem? in
                // No build-date fallback here: an app bundle's modification date is when it was built, not used.
                // Auto-updates (Chrome, Slack, ...) wipe the record, so "no record" stays in the list as unknown.
                let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                guard let url = item.url, lastUsed.map({ $0 < cutoff }) ?? true,
                      // Helper apps inside another bundle (EA app.app/.../EALaunchHelper.app) break their host if removed.
                      !url.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") }) else { return nil }
                let bundleID = item.string(kMDItemCFBundleIdentifier) ?? ""
                guard !bundleID.hasPrefix("com.apple."), bundleID != ownID,
                      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
                let leftovers = LibraryScanner.leftovers(ofApp: bundleID, at: url)
                // Spotlight's size for a bundle is unreliable, so measure it. Leftovers aren't counted: removing them is opt-in.
                return ScanItem(url: url, name: url.deletingPathExtension().lastPathComponent,
                                size: allocatedSize(of: url), lastUsed: lastUsed, kind: .app,
                                ownerBundleID: bundleID.isEmpty ? nil : bundleID, leftovers: leftovers)
            }
    }

    @concurrent static func oldDocuments(unusedFor days: Int) async -> [ScanItem] {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let iso = cutoff.ISO8601Format()
        let items = query("(kMDItemLastUsedDate < $time.iso(\(iso)) || kMDItemContentModificationDate < $time.iso(\(iso))) && kMDItemContentType != \"public.folder\"",
                          scopes: ["Documents", "Desktop", "Downloads"].map { home.appending(path: $0) })
            .compactMap { item -> ScanItem? in
                guard let url = item.url, isLooseFile(url), let lastUsed = item.lastUsed, lastUsed < cutoff else { return nil }
                // Spotlight reports an evicted iCloud file at full size, but deleting it frees nothing here.
                let size = allocatedSize(of: url)
                guard size > 0 else { return nil }
                return ScanItem(url: url, name: url.lastPathComponent, size: size, lastUsed: lastUsed, kind: .document)
            }
        return Array(items.sorted { $0.size > $1.size }.prefix(resultLimit))
    }

    @concurrent static func largeFiles(minBytes: Int64, videosOnly: Bool) async -> [ScanItem] {
        var q = "kMDItemFSSize > \(minBytes)"
        if videosOnly { q += " && kMDItemContentTypeTree == \"public.movie\"" }
        let library = home.appending(path: "Library").path(percentEncoded: false) + "/"
        let items = query(q, scopes: [home])
            .compactMap { item -> ScanItem? in
                // ~/Library is excluded: Cleaner refuses to delete there anyway (except Caches).
                guard let url = item.url, isLooseFile(url), !url.path(percentEncoded: false).hasPrefix(library) else { return nil }
                let size = allocatedSize(of: url)
                guard size > minBytes else { return nil }
                return ScanItem(url: url, name: url.lastPathComponent, size: size, lastUsed: item.lastUsed, kind: .largeFile)
            }
        return Array(items.sorted { $0.size > $1.size }.prefix(resultLimit))
    }

    /// Bundles macOS only treats as packages while their app is installed.
    private static let packageExtensions: Set<String> = [
        "fcpbundle", "logicx", "band", "imovielibrary", "photoslibrary", "pvm", "vmwarevm", "utm", "sparsebundle",
    ]

    /// Not hidden, and not inside a package (a Photos or Final Cut library, a VM): removing one file breaks the whole.
    static func isLooseFile(_ url: URL) -> Bool {
        let parents = sequence(first: url.deletingLastPathComponent()) { $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil }
        return !url.pathComponents.contains { $0.hasPrefix(".") }
            && !parents.contains { parent in
                packageExtensions.contains(parent.pathExtension.lowercased())
                    || (try? parent.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            }
    }

    static func query(_ string: String, scopes: [URL]) -> [MDItem] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, string as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            MDQueryGetResultAtIndex(query, index).map { Unmanaged<MDItem>.fromOpaque($0).takeUnretainedValue() }
        }
    }
}

extension MDItem {
    nonisolated func string(_ key: CFString) -> String? { MDItemCopyAttribute(self, key) as? String }
    nonisolated var url: URL? { string(kMDItemPath).map { URL(filePath: $0) } }
    /// For files only: never-opened files have no last-used date, so fall back to the last modification.
    nonisolated var lastUsed: Date? {
        (MDItemCopyAttribute(self, kMDItemLastUsedDate) as? Date)
            ?? (MDItemCopyAttribute(self, kMDItemContentModificationDate) as? Date)
    }
}
