import AppKit
import UniformTypeIdentifiers

nonisolated enum BrowserScanner {
    struct Browser {
        /// The app's display name; also used to match the app when the bundle ID differs.
        let name: String
        let bundleID: String
        /// Relative to ~/Library/Caches. `bundleID` is always checked too.
        var cachePaths: [String] = []
    }

    // Browsers sharing a cache folder (Firefox editions) list it each; the first one listed names the item,
    // and all of them keep it from being cleaned while running.
    static let known: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari"),
        Browser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview"),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", cachePaths: ["Google/Chrome"]),
        Browser(name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta", cachePaths: ["Google/Chrome Beta"]),
        Browser(name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary", cachePaths: ["Google/Chrome Canary"]),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", cachePaths: ["Chromium"]),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", cachePaths: ["Microsoft Edge"]),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", cachePaths: ["Firefox"]),
        Browser(name: "Firefox Developer Edition", bundleID: "org.mozilla.firefoxdeveloperedition", cachePaths: ["Firefox"]),
        Browser(name: "Firefox Nightly", bundleID: "org.mozilla.nightly", cachePaths: ["Firefox"]),
        Browser(name: "Zen", bundleID: "app.zen-browser.zen", cachePaths: ["zen"]),
        Browser(name: "Floorp", bundleID: "one.ablaze.floorp", cachePaths: ["Floorp"]),
        Browser(name: "LibreWolf", bundleID: "io.gitlab.librewolf-community", cachePaths: ["librewolf"]),
        Browser(name: "Waterfox", bundleID: "net.waterfox.waterfox", cachePaths: ["Waterfox"]),
        Browser(name: "Tor Browser", bundleID: "org.torproject.torbrowser"),
        Browser(name: "Mullvad Browser", bundleID: "net.mullvad.mullvadbrowser"),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", cachePaths: ["Arc"]),
        Browser(name: "Dia", bundleID: "company.thebrowser.dia", cachePaths: ["Dia"]),
        Browser(name: "Comet", bundleID: "ai.perplexity.comet", cachePaths: ["Comet"]),
        Browser(name: "Aside", bundleID: "at.studio.AsideBrowser", cachePaths: ["Aside"]),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", cachePaths: ["BraveSoftware/Brave-Browser"]),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", cachePaths: ["Vivaldi"]),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera"),
        Browser(name: "Opera GX", bundleID: "com.operasoftware.OperaGX"),
        Browser(name: "Naver Whale", bundleID: "com.naver.Whale", cachePaths: ["Naver/Whale"]),
        Browser(name: "Yandex", bundleID: "ru.yandex.desktop.yandex-browser", cachePaths: ["Yandex/YandexBrowser"]),
        Browser(name: "Thorium", bundleID: "org.chromium.Thorium", cachePaths: ["Thorium"]),
        Browser(name: "Sidekick", bundleID: "com.pushplaylabs.sidekick", cachePaths: ["Sidekick"]),
        Browser(name: "Orion", bundleID: "com.kagi.kagimacOS"),
        Browser(name: "DuckDuckGo", bundleID: "com.duckduckgo.macos.browser"),
        Browser(name: "SigmaOS", bundleID: "com.sigmaos.sigmaos.macos"),
    ]

    /// Top-level ~/Library/Caches folders this scanner covers, so the app cache list doesn't repeat them.
    static func cacheFolderNames() -> Set<String> { cacheFolderNames(of: browsers(installed: installedBrowsers())) }

    static func cacheFolderNames(of browsers: [Browser]) -> Set<String> {
        Set(browsers.flatMap { $0.cachePaths.map { String($0.split(separator: "/")[0]) } + [$0.bundleID] })
    }

    /// `known`, plus installed browsers missing from it with a cache folder guessed from their name.
    static func browsers(installed: [String: URL]) -> [Browser] {
        let knownIDs = Set(known.map(\.bundleID))
        return known + installed.filter { !knownIDs.contains($0.key) }.map { id, url in
            let name = url.deletingPathExtension().lastPathComponent
            return Browser(name: name, bundleID: id, cachePaths: [name])
        }
    }

    /// Apps that register for https and HTML but aren't browsers.
    private static let notBrowsers: Set<String> = ["com.googlecode.iterm2", "dev.warp.Warp-Stable"]

    @concurrent static func scan() async -> [ScanItem] {
        let fm = FileManager.default
        let caches = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches")
        let installed = installedBrowsers()
        let all = browsers(installed: installed)
        func folders(of browser: Browser) -> [URL] {
            (browser.cachePaths + [browser.bundleID]).map { caches.appending(path: $0).standardizedFileURL }
        }
        func app(of browser: Browser) -> URL? {
            installed[browser.bundleID] ?? installed.values.first { $0.deletingPathExtension().lastPathComponent == browser.name }
        }
        // Every browser that lists a folder may be the one using it, under its listed ID or, for a copy found by name,
        // the ID that copy actually runs as.
        var users: [URL: Set<String>] = [:]
        for browser in all {
            let ids = [browser.bundleID] + [app(of: browser).flatMap { Bundle(url: $0)?.bundleIdentifier }].compactMap(\.self)
            for folder in folders(of: browser) { users[folder, default: []].formUnion(ids) }
        }
        var claimed: Set<URL> = []
        return all.compactMap { browser in
            let appURL = app(of: browser)
            // Unreadable folders (Safari without Full Disk Access) are skipped; the banner explains why.
            let dirs = folders(of: browser)
                .filter { claimed.insert($0).inserted && (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) != nil }
            guard let first = dirs.first else { return nil }
            let sharers = dirs.reduce(into: Set<String>()) { $0.formUnion(users[$1] ?? []) }.subtracting([browser.bundleID])
            return ScanItem(
                url: first,
                // A cache left behind by an uninstalled browser is pure waste, so it's listed too.
                name: appURL == nil ? String(localized: "\(browser.name) (삭제된 앱)", bundle: .shown, locale: .shown) : browser.name,
                size: dirs.reduce(0) { $0 + allocatedSize(of: $1) },
                lastUsed: appURL.flatMap { NSMetadataItem(url: $0)?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date },
                kind: .browserCache,
                targets: dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] },
                isRunning: ([browser.bundleID] + sharers).contains(where: isAppRunning),
                ownerBundleID: browser.bundleID,
                sharedWith: sharers.sorted(),
                isOrphaned: appURL == nil
            )
        }
    }

    /// Bundle ID → app URL for every app that opens both https links and HTML files.
    private static func installedBrowsers() -> [String: URL] {
        let workspace = NSWorkspace.shared
        let htmlViewers = Set(workspace.urlsForApplications(toOpen: .html).compactMap { Bundle(url: $0)?.bundleIdentifier })
        var result: [String: URL] = [:]
        for url in workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!) {
            guard let id = Bundle(url: url)?.bundleIdentifier, htmlViewers.contains(id), !notBrowsers.contains(id),
                  result[id] == nil else { continue }
            result[id] = url
        }
        // Known browsers that don't register as handlers (rare) are still found by bundle ID.
        for browser in known where result[browser.bundleID] == nil {
            result[browser.bundleID] = workspace.urlForApplication(withBundleIdentifier: browser.bundleID)
        }
        return result
    }
}
