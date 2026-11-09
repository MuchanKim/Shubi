import Foundation

/// Download caches of developer package managers, cleaned with each tool's own command.
nonisolated enum PackageCacheScanner {
    struct Tool {
        let name: String
        /// The executable that must be on PATH; nil when the cache is plain files.
        let binary: String?
        /// Relative to the home folder.
        let cachePath: String
        let cleanCommand: String?
    }

    /// Computed, so the localized names follow a language change at the next scan.
    static var tools: [Tool] { [
        Tool(name: "Homebrew", binary: "brew", cachePath: "Library/Caches/Homebrew", cleanCommand: "brew cleanup --prune=all"),
        Tool(name: "npm", binary: "npm", cachePath: ".npm/_cacache", cleanCommand: "npm cache clean --force"),
        Tool(name: "Yarn", binary: "yarn", cachePath: "Library/Caches/Yarn", cleanCommand: "yarn cache clean"),
        Tool(name: "pnpm", binary: "pnpm", cachePath: "Library/pnpm/store", cleanCommand: "pnpm store prune"),
        Tool(name: "Bun", binary: "bun", cachePath: ".bun/install/cache", cleanCommand: "bun pm cache rm"),
        Tool(name: "pip", binary: "pip3", cachePath: "Library/Caches/pip", cleanCommand: "pip3 cache purge"),
        Tool(name: "CocoaPods", binary: "pod", cachePath: "Library/Caches/CocoaPods", cleanCommand: "pod cache clean --all"),
        Tool(name: String(localized: "Go 모듈", bundle: .shown, locale: .shown), binary: "go", cachePath: "go/pkg/mod", cleanCommand: "go clean -modcache"),
        Tool(name: "Swift Package Manager", binary: nil, cachePath: "Library/Caches/org.swift.swiftpm", cleanCommand: nil),
        Tool(name: String(localized: "Playwright 브라우저", bundle: .shown, locale: .shown), binary: nil, cachePath: "Library/Caches/ms-playwright", cleanCommand: nil),
    ] }

    /// Top-level ~/Library/Caches folders listed here, so the app cache list doesn't repeat them.
    static let cacheFolderNames: Set<String> = Set(tools.compactMap { tool in
        tool.cachePath.hasPrefix("Library/Caches/") ? String(tool.cachePath.split(separator: "/")[2]) : nil
    })

    @concurrent static func scan() async throws -> [ScanItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let available = try installedBinaries(tools.compactMap(\.binary))
        return try toolCaches(home: home, available: available) + xdgCaches(home: home)
    }

    /// `~/.cache` (XDG): CLI tools keep downloads and runtimes here.
    /// Which tool owns a folder, and whether it's running, can't be told, so smart clean leaves them alone.
    private static func xdgCaches(home: URL) -> [ScanItem] {
        directoryContents(home.appending(path: ".cache")).compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let size = allocatedSize(of: folder)
            guard size > 0 else { return nil }
            return ScanItem(url: folder, name: folder.lastPathComponent, size: size, lastUsed: modificationDate(folder), kind: .cache,
                            isOwnerUnknown: true, details: [Fact(label: String(localized: "위치", bundle: .shown, locale: .shown), value: "~/.cache")])
        }
    }

    private static func toolCaches(home: URL, available: Set<String>) throws -> [ScanItem] {
        tools.compactMap { tool in
            let folder = home.appending(path: tool.cachePath)
            guard tool.binary.map(available.contains) ?? true else { return nil }
            let size = allocatedSize(of: folder)
            guard size > 0 else { return nil }
            return ScanItem(
                url: folder,
                name: tool.name,
                size: size,
                lastUsed: modificationDate(folder),
                kind: .packageCache,
                // Tools without a clean command keep plain files; delete what's inside, like other caches.
                targets: tool.cleanCommand == nil ? directoryContents(folder) : nil,
                command: tool.cleanCommand,
                details: tool.cleanCommand.map { [Fact(label: String(localized: "정리 명령", bundle: .shown, locale: .shown), value: $0)] } ?? []
            )
        }
    }

    /// GUI apps don't get the user's PATH, so ask a login shell.
    private static func installedBinaries(_ names: [String]) throws -> Set<String> {
        // `true` last: the exit status would otherwise be that of the last missing tool.
        let script = names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ") + "; true"
        let output = try runProcess("/bin/zsh", ["-lc", script], timeout: 30)
        // Login shells may print banners; keep only lines that are one of the names.
        return Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)).intersection(names)
    }
}
