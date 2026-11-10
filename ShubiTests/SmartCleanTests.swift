import Foundation
import Testing
@testable import Shubi

struct SmartCleanTests {
    @Test(arguments: [ScanItem.Kind.browserCache, .cache, .derivedData, .deviceSupport, .packageCache])
    func rebuiltDataIsIncluded(_ kind: ScanItem.Kind) {
        #expect(item(kind).isSmartCleanable)
    }

    @Test func uninstalledAppCacheIsIncluded() {
        #expect(item(.cache, isOrphaned: true).isSmartCleanable)
    }

    /// Nothing can say whether an unidentified app is using its cache right now.
    @Test func cacheOfUnknownOwnerIsExcluded() {
        #expect(!item(.cache, isOwnerUnknown: true).isSmartCleanable)
    }

    @Test(arguments: [ScanItem.Kind.browserCache, .cache, .previews, .derivedData, .deviceSupport])
    func runningItemIsExcluded(_ kind: ScanItem.Kind) {
        #expect(!item(kind, isRunning: true).isSmartCleanable)
    }

    /// Commands skip the trash, and `brew cleanup --prune=all` also uninstalls old versions.
    @Test(arguments: [
        (ScanItem.Kind.packageCache, "brew cleanup --prune=all"),
        (.packageCache, "npm cache clean --force"),
    ])
    func commandItemIsExcluded(_ kind: ScanItem.Kind, _ command: String) {
        #expect(!item(kind, command: command).isSmartCleanable)
    }

    @Test(arguments: [
        ("Some.app", ScanItem.Kind.app),
        ("졸업논문_최종.docx", .document),
        ("Figma.dmg", .largeFile),
        ("com.gone.app", .appData),
        ("iOS 17.2", .runtime),
        ("Shubi 1.0.xcarchive", .archive),
        ("zoom.us", .log),
        // Even a verified AI cache: it sits next to the user's conversations.
        ("cache", .aiData(AIEntry(tool: .codex, category: .cache, isVerified: true))),
    ])
    func userFilesAndRuntimesAreExcluded(_ name: String, _ kind: ScanItem.Kind) {
        #expect(!item(kind, name: name, isOrphaned: kind == .appData).isSmartCleanable)
    }

    /// Xcode recreates preview devices, so their delete command is the one command smart clean runs.
    @Test func previewDevicesAreIncluded() {
        #expect(item(.previews, command: "xcrun simctl --set previews delete all").isSmartCleanable)
    }

    /// A simulator whose runtime is gone still holds the apps and data put on it; it only can't run until the runtime is back.
    @Test(arguments: [true, false])
    func simulatorsAreNeverIncluded(_ isOrphaned: Bool) {
        #expect(!item(.simulator, isOrphaned: isOrphaned, command: "xcrun simctl delete 'UDID'").isSmartCleanable)
    }

    private func item(_ kind: ScanItem.Kind, name: String = "item", isRunning: Bool = false, isOrphaned: Bool = false,
                      isOwnerUnknown: Bool = false, command: String? = nil) -> ScanItem {
        ScanItem(url: URL(filePath: "/tmp/\(name)"), name: name, size: 1, lastUsed: nil, kind: kind,
                 isRunning: isRunning, isOrphaned: isOrphaned, isOwnerUnknown: isOwnerUnknown, command: command)
    }
}
