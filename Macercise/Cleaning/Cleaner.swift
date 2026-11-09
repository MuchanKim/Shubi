import Foundation

nonisolated enum Cleaner {
    enum Mode: Sendable { case trash, permanent }

    struct Failure: Identifiable, Sendable {
        let url: URL
        let reason: String
        var id: URL { url }
    }

    /// Only the user's own files, caches, developer build data, app data folders and installed apps may be deleted.
    static func isAllowed(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        // Resolve the parent only: deleting a symlink itself is harmless, but a symlinked parent could point anywhere.
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = parent.appending(path: url.lastPathComponent).path(percentEncoded: false)
        let parentPath = parent.path(percentEncoded: false).trimmingSuffix("/")
        let home = home.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/")

        func under(_ root: String) -> Bool { path.hasPrefix(root + "/") && path.count > root.count + 1 }
        // Whole app or device folders only, never something inside another app's data.
        func childOf(_ root: String) -> Bool { parentPath == root }

        if under("/Applications") || under(home + "/Applications") || under(home + "/Library/Caches") { return true }
        let developer = home + "/Library/Developer/Xcode"
        if childOf(developer + "/DerivedData") { return true }
        if ["iOS", "watchOS", "tvOS", "visionOS"].contains(where: { childOf(developer + "/\($0) DeviceSupport") }) { return true }
        if childOf(home + "/Library/Application Support") || childOf(home + "/Library/Containers") { return true }
        // A Chromium (Electron) app's own cache folders inside its data folder, never the folder or its other contents.
        let support = home + "/Library/Application Support/"
        if path.hasPrefix(support) {
            let inside = path.dropFirst(support.count).split(separator: "/", omittingEmptySubsequences: false)
            if inside.count >= 2, !inside[0].isEmpty, !inside[0].hasPrefix("com.apple."), LibraryScanner.chromiumCacheNames.contains(inside.dropFirst().joined(separator: "/")) {
                return true
            }
        }
        if under(home + "/Library/Logs") { return true }
        if parent.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/") == developer + "/Archives",
           url.pathExtension == "xcarchive" { return true }
        // What an uninstalled app leaves behind, found by its bundle ID.
        if ["Saved Application State", "HTTPStorages", "WebKit"].contains(where: { childOf(home + "/Library/\($0)") }) { return true }
        if under(home + "/Library") { return false }
        guard under(home) else { return false }
        // Tools' download caches (XDG), one folder at a time.
        if childOf(home + "/.cache") { return true }
        // Hidden top-level folders (~/.ssh, ~/.Trash, ...) are off limits.
        return !path.dropFirst(home.count + 1).hasPrefix(".")
    }

    /// Cleans each item by its command or by deleting its targets. One failure doesn't stop the rest.
    /// An app's leftover data goes too only when the user asked for it.
    static func clean(_ items: [ScanItem], mode: Mode, removesLeftovers: Bool = false) -> [Failure] {
        items.flatMap { item in
            // The scan may be minutes old; deleting a cache now would pull files out from under the app.
            if let owner = item.ownerBundleID, isAppRunning(owner) {
                return [Failure(url: item.url, reason: String(localized: "실행 중이라 건너뛰었어요. 앱을 종료한 뒤 다시 정리하세요.", bundle: .shown, locale: .shown))]
            }
            // shortcut: command-line users (xcodebuild, swift build, Playwright tests) aren't apps, so they aren't checked; track their processes if one breaks mid-run.
            if let command = item.command {
                return run(command).map { [Failure(url: item.url, reason: $0)] } ?? []
            }
            // Each log is checked right before it goes: one written to since the scan is current again.
            let failures = item.kind == .log
                ? item.targets.flatMap { LibraryScanner.isOld($0, before: .now.addingTimeInterval(-LibraryScanner.logRetention)) ? delete([$0], mode: mode) : [] }
                : delete(item.targets, mode: mode)
            // Only once the app itself is gone: deleting its data while the app stays would just reset it.
            guard removesLeftovers, failures.isEmpty, !item.leftovers.isEmpty else { return failures }
            // Another copy of the app (an older or newer build elsewhere) still uses the same data.
            if let id = item.ownerBundleID, !LibraryScanner.installedCopies(of: id, excluding: item.targets).isEmpty { return [] }
            return delete(item.leftovers, mode: mode)
        }
    }

    static func delete(_ urls: [URL], mode: Mode) -> [Failure] {
        urls.compactMap { url -> Failure? in
            guard isAllowed(url) else { return Failure(url: url, reason: String(localized: "허용되지 않은 경로", bundle: .shown, locale: .shown)) }
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
