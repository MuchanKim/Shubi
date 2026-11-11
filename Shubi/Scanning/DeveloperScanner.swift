import AppKit

/// Xcode leftovers: simulators, simulator runtimes, device symbols and build folders.
nonisolated enum DeveloperScanner {
    private static let developer = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer")
    private static let xcode = developer.appending(path: "Xcode")
    private static let xcodeBundleID = "com.apple.dt.Xcode"

    private struct Device: Decodable {
        let udid, name: String
        let dataPath: String?
        let dataPathSize: Int64?
        let lastUsedAt: Date?
        let isAvailable: Bool
        let state: String?
    }

    /// Runtime identifier → its devices.
    private static func devices() throws -> [String: [Device]] {
        struct List: Decodable { let devices: [String: [Device]] }
        return try simctl(["list", "devices", "-j"], as: List.self).devices
    }

    @concurrent static func simulators() async throws -> [ScanItem] {
        struct RuntimeList: Decodable { let runtimes: [InstalledRuntime] }
        struct InstalledRuntime: Decodable { let identifier: String }
        let devices = try devices()
        let installed = Set(try simctl(["list", "runtimes", "-j"], as: RuntimeList.self).runtimes.map(\.identifier))
        return devices.flatMap { runtime, devices in
            let orphaned = isOrphaned(runtime: runtime, installedRuntimes: installed)
            return devices.map { device in
                let folder = device.dataPath.map { URL(filePath: $0).deletingLastPathComponent() }
                let status = orphaned ? String(localized: "사용할 수 없음 (런타임이 없어요)", bundle: .shown, locale: .shown) : device.isAvailable ? String(localized: "사용 가능", bundle: .shown, locale: .shown) : String(localized: "사용할 수 없음", bundle: .shown, locale: .shown)
                return ScanItem(
                    url: folder ?? URL(filePath: "/simulator/\(device.udid)"),
                    name: "\(device.name) · \(runtimeName(runtime))",
                    size: device.dataPathSize ?? 0,
                    lastUsed: device.lastUsedAt,
                    kind: .simulator,
                    // simctl refuses to delete a booted device.
                    isRunning: device.state == "Booted",
                    isOrphaned: orphaned,
                    command: "xcrun simctl delete \(shellQuote(device.udid))",
                    details: [Fact(label: String(localized: "상태", bundle: .shown, locale: .shown), value: status), Fact(label: "UDID", value: device.udid)]
                )
            }
        }
    }

    @concurrent static func runtimes() async throws -> [ScanItem] {
        struct Runtime: Decodable {
            let identifier, version, runtimeIdentifier, path: String
            let build: String?
            let sizeBytes: Int64?
            let lastUsedAt: Date?
            let deletable: Bool?
        }
        let runtimes = try simctl(["runtime", "list", "-j"], as: [String: Runtime].self)
        // Only the device count: a failing `simctl list runtimes` shouldn't take this list down with the simulators.
        let devices = try devices()
        let images = runtimes.values.filter { $0.deletable ?? false }.map { runtime in
            let name = runtimeName(runtime.runtimeIdentifier)
            let users = devices[runtime.runtimeIdentifier]?.count ?? 0
            return ScanItem(
                url: URL(filePath: runtime.path),
                name: "\(name) (\(runtime.version))",
                size: runtime.sizeBytes ?? 0,
                lastUsed: runtime.lastUsedAt,
                kind: .runtime,
                command: "xcrun simctl runtime delete \(shellQuote(runtime.identifier))",
                details: [Fact(label: String(localized: "이 런타임을 쓰는 시뮬레이터", bundle: .shown, locale: .shown), value: String(localized: "\(users)개", bundle: .shown, locale: .shown),
                                     signal: .simulatorsUsingRuntime(users))]
            )
        }
        let installed = runtimes.values.compactMap { runtime in runtime.build.map { (identifier: runtime.runtimeIdentifier, build: $0) } }
        let caches = osBuild.map { dyldCaches(in: URL(filePath: "/Library/Developer/CoreSimulator/Caches/dyld/\($0)"), installed: installed) } ?? []
        // Unknown counts as in use: removing a mapped cache could pull it out from under a running device.
        let inUse = try? runtimesInUse()
        return images + caches.map { cache, runtime in
            let command = "xcrun simctl runtime dyld_shared_cache remove \(shellQuote(runtime))"
            return ScanItem(url: cache, name: String(localized: "\(runtimeName(runtime)) dyld 캐시", bundle: .shown, locale: .shown),
                            size: allocatedSize(of: cache), lastUsed: modificationDate(cache), kind: .runtimeCache,
                            isRunning: inUse.map { isMapped(cache, runtimesInUse: $0) } ?? true,
                            command: command, details: [Fact(label: String(localized: "정리 명령", bundle: .shown, locale: .shown), value: command)])
        }
    }

    /// The runtimes' dyld shared caches in `folder`, named `<runtime identifier>.<build>`. Only an installed runtime's:
    /// simctl refuses any other identifier, and the folders belong to root.
    /// shortcut: a cache whose runtime was deleted is left out, since only root can remove it; add an admin-prompted delete if those pile up.
    /// shortcut: so is a runtime installed in two builds, since simctl removes by identifier and could take the other build's cache; list them if simctl ever takes a build.
    static func dyldCaches(in folder: URL, installed: [(identifier: String, build: String)]) -> [(folder: URL, runtime: String)] {
        let builds = Dictionary(installed.map { ($0.identifier, 1) }, uniquingKeysWith: +)
        return directoryContents(folder).compactMap { cache in
            installed.first { builds[$0.identifier] == 1 && "\($0.identifier).\($0.build)" == cache.lastPathComponent }.map { (cache, $0.identifier) }
        }
    }

    /// Runtimes with a device that isn't shut down in any of Xcode's device sets: tests, previews, playgrounds and
    /// Interface Builder boot their own devices outside the default set.
    /// shortcut: a set at a path only another tool knows (idb, a CI script) isn't checked; read CoreSimulator's open sets if one shows up.
    static func runtimesInUse() throws -> Set<String> {
        struct List: Decodable { let devices: [String: [Device]] }
        // simctl refuses a set whose folder isn't there yet.
        let sets = [("testing", developer.appending(path: "XCTestDevices")), ("previews", xcode.appending(path: "UserData/Previews/Simulator Devices")),
                    ("playgrounds", developer.appending(path: "XCPGDevices")), ("interfacebuilder", xcode.appending(path: "UserData/IB Support/Simulator Devices"))]
            .filter { FileManager.default.fileExists(atPath: $0.1.path(percentEncoded: false)) }
            .map { ["--set", $0.0] }
        return try Set(([[]] + sets).flatMap { set in
            try simctl(set + ["list", "devices", "-j"], as: List.self).devices.filter { $0.value.contains { isRunning(state: $0.state) } }.keys
        })
    }

    /// Booting and shutting down devices map the cache too; only a confirmed shutdown frees it.
    static func isRunning(state: String?) -> Bool { state != "Shutdown" }

    /// A running device maps its runtime's cache, `<runtime identifier>.<build>`.
    static func isMapped(_ cache: URL, runtimesInUse: Set<String>) -> Bool {
        runtimesInUse.contains { cache.lastPathComponent.hasPrefix($0 + ".") }
    }

    /// Simulator dyld caches are kept per macOS build, in a folder named after it (`26A428`).
    private static var osBuild: String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// `isAvailable` alone can't tell a removed runtime from one that's installed but temporarily unusable.
    static func isOrphaned(runtime: String, installedRuntimes: Set<String>) -> Bool {
        !installedRuntimes.contains(runtime)
    }

    @concurrent static func deviceSupport() async -> [ScanItem] {
        let xcodeIsRunning = isXcodeRunning
        return ["iOS", "watchOS", "tvOS", "visionOS"].flatMap { platform in
            directoryContents(xcode.appending(path: "\(platform) DeviceSupport"))
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .map { folder in
                    // Xcode reads these symbols while it debugs a connected device.
                    ScanItem(url: folder, name: "\(platform) · \(folder.lastPathComponent)", size: allocatedSize(of: folder),
                             lastUsed: modificationDate(folder), kind: .deviceSupport, isRunning: xcodeIsRunning, ownerBundleID: xcodeBundleID)
                }
        }
    }

    @concurrent static func derivedData() async -> [ScanItem] {
        let buildIsRunning = isProcessRunning(buildTools)
        let inUse = isXcodeRunning || buildIsRunning
        let xcodeBuilds = directoryContents(xcode.appending(path: "DerivedData"))
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { folder in
                // Xcode writes an open project's builds and index here.
                ScanItem(url: folder, name: projectName(folder), size: allocatedSize(of: folder),
                         lastUsed: modificationDate(folder), kind: .derivedData, isRunning: inUse, ownerBundleID: xcodeBundleID,
                         usedByTools: buildTools)
            }
        // XcodeBuildMCP builds through xcodebuild into `workspaces/<Project>-<hash>/DerivedData`, next to its locks and state.
        let mcpBuilds = directoryContents(developer.appending(path: "XcodeBuildMCP/workspaces"))
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { workspace -> ScanItem? in
                let folder = workspace.appending(path: "DerivedData")
                let size = allocatedSize(of: folder)
                guard size > 0 else { return nil }
                return ScanItem(url: folder, name: "\(projectName(workspace)) · XcodeBuildMCP", size: size,
                                lastUsed: modificationDate(folder), kind: .mcpBuild, isRunning: buildIsRunning, usedByTools: buildTools)
            }
        return xcodeBuilds + mcpBuilds
    }

    /// Folders are named `<Project>-<hash>`.
    private static func projectName(_ folder: URL) -> String {
        let name = folder.lastPathComponent
        let project = name.split(separator: "-").dropLast().joined(separator: "-")
        return project.isEmpty ? name : project
    }

    /// Simulators Xcode creates for SwiftUI previews, kept in their own device set.
    @concurrent static func previews() async -> [ScanItem] {
        let folder = xcode.appending(path: "UserData/Previews/Simulator Devices")
        let size = allocatedSize(of: folder)
        guard size > 0 else { return [] }
        let command = "xcrun simctl --set previews delete all"
        return [ScanItem(url: folder, name: String(localized: "SwiftUI Preview 시뮬레이터", bundle: .shown, locale: .shown), size: size, lastUsed: modificationDate(folder),
                         kind: .previews,
                         // Xcode holds booted preview devices open while it runs.
                         isRunning: isXcodeRunning, ownerBundleID: xcodeBundleID,
                         command: command, details: [Fact(label: String(localized: "정리 명령", bundle: .shown, locale: .shown), value: command)])]
    }

    /// Clones Xcode makes of a simulator to run tests in parallel, kept in their own device set.
    @concurrent static func testDevices() async -> [ScanItem] {
        let folder = developer.appending(path: "XCTestDevices")
        let size = allocatedSize(of: folder)
        guard size > 0 else { return [] }
        let command = "xcrun simctl --set testing delete all"
        return [ScanItem(url: folder, name: String(localized: "병렬 테스트 시뮬레이터", bundle: .shown, locale: .shown), size: size, lastUsed: modificationDate(folder),
                         kind: .testDevices,
                         // `xcodebuild test` boots clones with Xcode closed.
                         isRunning: isXcodeRunning || isProcessRunning(buildTools), ownerBundleID: xcodeBundleID, usedByTools: buildTools,
                         command: command, details: [Fact(label: String(localized: "정리 명령", bundle: .shown, locale: .shown), value: command)])]
    }

    /// Builds archived for distribution, in `Archives/<date>/<name>.xcarchive`.
    @concurrent static func archives() async -> [ScanItem] {
        directoryContents(xcode.appending(path: "Archives"))
            .flatMap { directoryContents($0).filter { $0.pathExtension == "xcarchive" } }
            .map { archive in
                let info = NSDictionary(contentsOf: archive.appending(path: "Info.plist"))
                let name = info?["Name"] as? String ?? archive.deletingPathExtension().lastPathComponent
                let version = (info?["ApplicationProperties"] as? [String: Any])?["CFBundleShortVersionString"] as? String
                return ScanItem(url: archive, name: version.map { "\(name) \($0)" } ?? name, size: allocatedSize(of: archive),
                                lastUsed: info?["CreationDate"] as? Date ?? modificationDate(archive), kind: .archive)
            }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` → `iOS 26.4`
    static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        guard let dash = last.firstIndex(of: "-") else { return last }
        return last[..<dash] + " " + last[last.index(after: dash)...].replacing("-", with: ".")
    }

    private static var isXcodeRunning: Bool { isAppRunning(xcodeBundleID) }

    /// Throws instead of returning nothing: a broken simctl (unaccepted Xcode license, a stuck CoreSimulator) isn't "no simulators".
    private static func simctl<T: Decodable>(_ arguments: [String], as type: T.Type) throws -> T {
        // The first call after boot starts CoreSimulatorService, which can take a while.
        let output = try runProcess("/usr/bin/xcrun", ["simctl"] + arguments, timeout: 60)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: output)
        } catch {
            throw CommandError(message: String(localized: "simctl 결과를 읽지 못했어요", bundle: .shown, locale: .shown))
        }
    }
}
