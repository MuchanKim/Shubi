import Foundation

nonisolated enum Cleaner {
    enum Mode: Sendable { case trash, permanent }

    struct Failure: Identifiable, Sendable {
        let url: URL
        let reason: String
        var id: URL { url }
    }

    /// Where each kind of item may be deleted from. Each kind gets only its own rules: a cache folder that links into
    /// ~/Documents or into another app's data folder resolves outside the caches, so it can't take those files with it.
    enum Policy: Sendable, CaseIterable {
        case cache, developer, appData, app, log
        /// XcodeBuildMCP's builds: a workspace's DerivedData, never the locks and state next to it.
        case mcpBuild
        /// Documents and large files the user picked: anything in the home folder outside ~/Library, ~/Applications
        /// and hidden folders.
        case ownFiles
        /// AI tools' sessions, outputs, caches and logs: exactly the `delete:` globs of the `AITool` catalog. Their settings,
        /// credentials and databases sit in the same folders and match none.
        case aiData

        /// An uninstalled app leaves caches and logs next to its data; each is held to its own folder's rules.
        init(leftover: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            let path = leftover.standardizedFileURL.path(percentEncoded: false)
            let library = home.path(percentEncoded: false).trimmingSuffix("/") + "/Library/"
            self = path.hasPrefix(library + "Caches/") ? .cache : path.hasPrefix(library + "Logs/") ? .log : .appData
        }

        init(_ kind: ScanItem.Kind) {
            switch kind {
            case .browserCache, .cache, .packageCache: self = .cache
            // Simulators, runtimes, their caches, previews and test clones are cleaned by command, not by deleting files.
            case .derivedData, .deviceSupport, .archive, .simulator, .runtime, .runtimeCache, .previews, .testDevices: self = .developer
            case .mcpBuild: self = .mcpBuild
            case .appData: self = .appData
            case .app: self = .app
            case .log: self = .log
            case .document, .largeFile: self = .ownFiles
            case .aiData: self = .aiData
            }
        }
    }

    /// Where deleting `url` really acts. Only the parent is resolved: deleting a symlink itself is harmless, but a
    /// symlinked parent could point anywhere.
    private static func realPath(of url: URL, home: URL) -> (path: String, parent: URL, home: String) {
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        return (parent.appending(path: url.lastPathComponent).path(percentEncoded: false), parent,
                home.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/"))
    }

    /// The AI catalog's entry for where `url` really is. A link from one tool's folder into another's must not let the
    /// other folder's files go by the first folder's rules.
    static func aiEntry(atRealPathOf url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AIEntry? {
        let (path, _, home) = realPath(of: url, home: home)
        guard path.hasPrefix(home + "/") else { return nil }
        return AITool.entry(forHomeRelative: String(path.dropFirst(home.count + 1)))
    }

    static func isAllowed(_ url: URL, as policy: Policy, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let (path, parent, home) = realPath(of: url, home: home)
        let parentPath = parent.path(percentEncoded: false).trimmingSuffix("/")

        func under(_ root: String) -> Bool { path.hasPrefix(root + "/") && path.count > root.count + 1 }
        // Whole app or device folders only, never something inside another app's data.
        func childOf(_ root: String) -> Bool { parentPath == root }
        let developer = home + "/Library/Developer/Xcode"

        switch policy {
        case .cache:
            // Tools' download caches (XDG), one folder at a time.
            if under(home + "/Library/Caches") || childOf(home + "/.cache") { return true }
            // A Chromium (Electron) app's own cache folders inside its data folder, never the folder or its other contents.
            let support = home + "/Library/Application Support/"
            guard path.hasPrefix(support) else { return false }
            let inside = path.dropFirst(support.count).split(separator: "/", omittingEmptySubsequences: false)
            return inside.count >= 2 && !inside[0].isEmpty && !inside[0].hasPrefix("com.apple.")
                && LibraryScanner.chromiumCacheNames.contains(inside.dropFirst().joined(separator: "/"))
        case .developer:
            if childOf(developer + "/DerivedData") { return true }
            if ["iOS", "watchOS", "tvOS", "visionOS"].contains(where: { childOf(developer + "/\($0) DeviceSupport") }) { return true }
            return parent.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/") == developer + "/Archives"
                && url.pathExtension == "xcarchive"
        case .mcpBuild:
            return url.lastPathComponent == "DerivedData"
                && parent.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/") == home + "/Library/Developer/XcodeBuildMCP/workspaces"
        case .appData:
            // An app's data folder, or what an uninstalled app leaves behind, found by its bundle ID.
            return ["Application Support", "Containers", "Saved Application State", "HTTPStorages", "WebKit"]
                .contains { childOf(home + "/Library/\($0)") }
        case .app:
            return under("/Applications") || under(home + "/Applications")
        case .log:
            return under(home + "/Library/Logs")
        case .ownFiles:
            // Hidden top-level folders (~/.ssh, ~/.Trash, ...) are off limits.
            func inside(_ root: String) -> Bool { path == root || under(root) }
            return under(home) && !inside(home + "/Library") && !inside(home + "/Applications")
                && !path.dropFirst(home.count + 1).hasPrefix(".")
        case .aiData:
            return under(home) && AITool.isDeletable(homeRelative: String(path.dropFirst(home.count + 1)))
        }
    }

    /// Cleans each item by its command or by deleting its targets. One failure doesn't stop the rest.
    /// An app's leftover data goes too only when the user asked for it.
    static func clean(_ items: [ScanItem], mode: Mode, removesLeftovers: Bool = false) -> [Failure] {
        items.flatMap { item in
            // The scan may be minutes old; deleting a cache now would pull files out from under the app or a build.
            if item.isInUse {
                return [Failure(url: item.url, reason: String(localized: "실행 중이라 건너뛰었어요. 앱을 종료한 뒤 다시 정리하세요.", bundle: .shown, locale: .shown))]
            }
            // A device started since the scan maps the cache, in any device set; unknown counts as in use.
            // shortcut: a runtime swapped for another build of it since the scan isn't caught, and simctl would remove the new build's cache; recheck `simctl runtime list` here if runtimes get updated in place.
            if item.kind == .runtimeCache, (try? DeveloperScanner.runtimesInUse()).map({ DeveloperScanner.isMapped(item.url, runtimesInUse: $0) }) ?? true {
                return [Failure(url: item.url, reason: String(localized: "시뮬레이터가 켜져 있어서 건너뛰었어요. 시뮬레이터를 끈 뒤 다시 정리하세요.", bundle: .shown, locale: .shown))]
            }
            if let command = item.command {
                return run(command).map { [Failure(url: item.url, reason: $0)] } ?? []
            }
            let failures: [Failure] = switch item.kind {
            // Each log is checked right before it goes: one written to since the scan is current again.
            case .log:
                item.targets.flatMap { LibraryScanner.isOld($0, before: .now.addingTimeInterval(-LibraryScanner.logRetention)) ? delete([$0], as: .log, mode: mode) : [] }
            // A session in use again, grown or moved since the scan is skipped whole; a cache or log keeps just its fresh files.
            case .aiData(let entry):
                switch AIScanner.cleanCheck(item, as: entry, now: .now) {
                case .delete(let urls): delete(urls, as: .aiData, mode: mode)
                case .skip(let reason): [Failure(url: item.url, reason: reason)]
                }
            default:
                delete(item.targets, as: Policy(item.kind), mode: mode)
            }
            // Only once the app itself is gone: deleting its data while the app stays would just reset it.
            guard removesLeftovers, failures.isEmpty, !item.leftovers.isEmpty else { return failures }
            // Another copy of the app (an older or newer build elsewhere) still uses the same data.
            if let id = item.ownerBundleID, !LibraryScanner.installedCopies(of: id, excluding: item.targets).isEmpty { return [] }
            return item.leftovers.flatMap { delete([$0], as: Policy(leftover: $0), mode: mode) }
        }
    }

    static func delete(_ urls: [URL], as policy: Policy, mode: Mode) -> [Failure] {
        urls.compactMap { url -> Failure? in
            guard isAllowed(url, as: policy) else { return Failure(url: url, reason: String(localized: "허용되지 않은 경로", bundle: .shown, locale: .shown)) }
            do {
                switch mode {
                case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                case .permanent: try FileManager.default.removeItem(at: url)
                }
                return nil
            } catch CocoaError.fileNoSuchFile {
                // Already gone, e.g. removed in Finder after the scan: the goal is met.
                return nil
            } catch where isPermissionError(error) {
                // Apps installed by the App Store or an installer are owned by root; Finder asks for the admin password.
                guard mode == .trash else {
                    return Failure(url: url, reason: String(localized: "관리자 권한이 필요해요. 해당 항목 화면에서 '휴지통으로 이동'을 고르면 암호를 입력해 지울 수 있어요.", bundle: .shown, locale: .shown))
                }
                let script = "tell application \"Finder\" to delete (POSIX file \(appleScriptString(url.path(percentEncoded: false))) as alias)"
                return run("/usr/bin/osascript -e \(shellQuote(script))").map { Failure(url: url, reason: $0) }
            } catch {
                return Failure(url: url, reason: error.localizedDescription)
            }
        }
    }

    /// Runs a shell command in a login shell (so Homebrew, npm, … are on PATH). Returns an error message on failure.
    static func run(_ command: String, timeout: TimeInterval = 600) -> String? {
        do {
            _ = try runProcess("/bin/zsh", ["-lc", command], timeout: timeout)
            return nil
        } catch {
            return error.message
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError)
            || (underlying?.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(underlying?.code))
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
}

private extension String {
    nonisolated func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}
