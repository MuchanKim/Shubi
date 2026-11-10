import Foundation
import Testing
@testable import Shubi

/// The catalog is the AI section's whole deletion allow-list, so these pin what it may and may not name.
struct AIToolsTests {
    typealias Glob = (tool: AITool, category: AICategory, pattern: String, isDelete: Bool)

    static let globs: [Glob] = AITool.allCases.flatMap { tool in
        tool.spec.delete.flatMap { category, patterns in patterns.map { (tool, category, $0, true) } }
            + tool.spec.review.flatMap { category, patterns in patterns.map { (tool, category, $0, false) } }
    }

    /// A path the pattern matches: each wildcard filled with a plain name.
    static func sample(_ pattern: String) -> String {
        pattern.replacing(#/\[[^\]]*\]/#, with: "a").replacing("*", with: "x").replacing("?", with: "a")
    }

    /// Each glob classifies as its own tool and kind: delete globs are deletable, review globs never are.
    @Test func everyGlobClassifiesAsWritten() {
        for glob in Self.globs {
            let path = Self.sample(glob.pattern)
            let entry = AITool.entry(forHomeRelative: path)
            #expect(entry == AIEntry(tool: glob.tool, category: glob.category, isVerified: glob.isDelete), "\(path)")
            #expect(AITool.isDeletable(homeRelative: path) == (glob.isDelete && glob.category != .toolData), "\(path)")
        }
    }

    @Test func toolStateIsNeverDeletable() {
        #expect(!Self.globs.contains { $0.isDelete && $0.category == .toolData })
        #expect(AIEntry(tool: .claudeApp, category: .toolData, isVerified: true).reviewOnly == .toolState)
    }

    /// Package cache, App cache and Orphaned data already list these; listing them here too would count them twice.
    @Test func noGlobReachesWhatOtherSectionsList() {
        for glob in Self.globs {
            let segments = AIGlob(glob.pattern).segments
            #expect(segments.count >= 2, "a whole tool folder: \(glob.pattern)")
            #expect(segments.first != ".cache" && Array(segments.prefix(2)) != ["Library", "Caches"], "\(glob.pattern)")
            if Array(segments.prefix(2)) == ["Library", "Application Support"] {
                #expect(segments.count >= 4, "a whole app data folder: \(glob.pattern)")
                #expect(!LibraryScanner.chromiumCacheNames.contains(segments[3]), "\(glob.pattern)")
            }
        }
    }

    /// A cache or log glob with a wildcard lists a root's contents ("cache/*"), so its row is the root and deleting it
    /// leaves the root in place.
    @Test func cacheAndLogGlobsListARootsContents() {
        for glob in Self.globs where [.cache, .log, .toolData].contains(glob.category) {
            let segments = AIGlob(glob.pattern).segments
            #expect(!segments.contains(where: AIGlob.isWildcard) || AIGlob.isWildcard(segments.last!), "\(glob.pattern)")
        }
    }

    @Test func globsMatchSegmentBySegment() {
        let glob = AIGlob(".codex/cache/*")
        #expect(glob.matches(".codex/cache/models".split(separator: "/")))
        #expect(!glob.matches(".codex/cache/models/a".split(separator: "/")))
        #expect(!glob.matches(".codex/cache/.lock".split(separator: "/")))
    }
}
