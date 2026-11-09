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
    enum Policy: Sendable {
        case cache, developer, appData, app, log
        /// Documents and large files the user picked: anything in the home folder outside ~/Library, ~/Applications
        /// and hidden folders.
        case ownFiles

        /// An uninstalled app leaves caches and logs next to its data; each is held to its own folder's rules.
        init(leftover: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            let path = leftover.standardizedFileURL.path(percentEncoded: false)
            let library = home.path(percentEncoded: false).trimmingSuffix("/") + "/Library/"
            self = path.hasPrefix(library + "Caches/") ? .cache : path.hasPrefix(library + "Logs/") ? .log : .appData
        }

        init(_ kind: ScanItem.Kind) {
            switch kind {
            case .browserCache, .cache, .packageCache: self = .cache
            // Simulators, runtimes and previews are cleaned by command, not by deleting files.
            case .derivedData, .deviceSupport, .archive, .simulator, .runtime, .previews: self = .developer
            case .appData: self = .appData
            case .app: self = .app
            case .log: self = .log
            case .document, .largeFile: self = .ownFiles
            }
        }
    }

    static func isAllowed(_ url: URL, as policy: Policy, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        // Resolve the parent only: deleting a symlink itself is harmless, but a symlinked parent could point anywhere.
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = parent.appending(path: url.lastPathComponent).path(percentEncoded: false)
        let parentPath = parent.path(percentEncoded: false).trimmingSuffix("/")
        let home = home.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/")

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
            if let command = item.command {
                return run(command).map { [Failure(url: item.url, reason: $0)] } ?? []
            }
            // Each log is checked right before it goes: one written to since the scan is current again.
            let failures = item.kind == .log
                ? item.targets.flatMap { LibraryScanner.isOld($0, before: .now.addingTimeInterval(-LibraryScanner.logRetention)) ? delete([$0], as: .log, mode: mode) : [] }
                : delete(item.targets, as: Policy(item.kind), mode: mode)
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
