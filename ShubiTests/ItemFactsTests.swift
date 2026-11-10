import Foundation
import Testing
@testable import Shubi

struct ItemFactsTests {
    let calculator = ScanItem(url: URL(filePath: "/System/Applications/Calculator.app"), name: "Calculator",
                              size: 1_000, lastUsed: Calendar.current.date(byAdding: .day, value: -10, to: .now), kind: .app)

    @Test func appFactsComeFromTheBundle() async {
        let facts = await ItemFacts.facts(for: calculator)
        #expect(facts.contains { $0.signal == .bundleID("com.apple.calculator") })
        #expect(facts.contains { $0.signal == .fromAppStore(false) })
        let lastUsed = calculator.lastUsed!.formatted(date: .abbreviated, time: .omitted)
        #expect(facts.contains { $0.value == String(localized: "\(lastUsed) (\(10)일 전)") })
    }

    @Test func orphanedCacheIsSafe() {
        let cache = ScanItem(url: URL(filePath: "/tmp/Comet"), name: "Comet", size: 1, lastUsed: nil, kind: .browserCache, isOrphaned: true)
        let risk = ItemFacts.risk(for: cache, facts: [])
        #expect(risk.level == .safe)
        #expect(risk.title == String(localized: "앱이 이미 삭제된 캐시예요"))
    }

    @Test func managementAppIsRisky() {
        let app = ScanItem(url: URL(filePath: "/Applications/Self Service.app"), name: "Self Service", size: 1, lastUsed: nil, kind: .app)
        #expect(ItemFacts.risk(for: app, facts: [signal(.bundleID("com.jamfsoftware.selfservice.mac"))]).level == .risky)
    }

    @Test(arguments: [
        ([Fact.Signal.fromAppStore(true)], DeletionRisk.Level.safe),
        ([.fromAppStore(false)], .caution),
        ([.fromAppStore(true), .systemComponents(hasExtensions: false)], .caution),
        ([.fromAppStore(false), .systemComponents(hasExtensions: true)], .risky),
    ])
    func appVerdicts(_ signals: [Fact.Signal], _ expected: DeletionRisk.Level) {
        let app = ScanItem(url: URL(filePath: "/Applications/Some.app"), name: "Some", size: 1, lastUsed: nil, kind: .app)
        #expect(ItemFacts.risk(for: app, facts: signals.map(signal)).level == expected)
    }

    @Test(arguments: [
        ("Figma.dmg", [Fact.Signal](), DeletionRisk.Level.safe),
        ("lecture.mp4", [.downloadSource("https://example.com/lecture.mp4")], .safe),
        ("졸업논문_최종.docx", [], .caution),
        ("Figma.dmg", [.inICloud], .caution),
    ])
    func fileVerdicts(_ name: String, _ signals: [Fact.Signal], _ expected: DeletionRisk.Level) {
        let file = ScanItem(url: URL(filePath: "/tmp/\(name)"), name: name, size: 1, lastUsed: nil, kind: .document)
        #expect(ItemFacts.risk(for: file, facts: signals.map(signal)).level == expected)
    }

    @Test(arguments: [(0, DeletionRisk.Level.safe), (3, .caution)])
    func runtimeVerdictDependsOnSimulatorsUsingIt(_ users: Int, _ expected: DeletionRisk.Level) {
        let runtime = ScanItem(url: URL(filePath: "/tmp/rt.dmg"), name: "iOS 17.2", size: 1, lastUsed: nil, kind: .runtime)
        #expect(ItemFacts.risk(for: runtime, facts: [signal(.simulatorsUsingRuntime(users))]).level == expected)
    }

    /// Verdicts read only the signal, so the label and value text (localized at runtime) don't matter here.
    private func signal(_ signal: Fact.Signal) -> Fact { Fact(label: "", value: "", signal: signal) }

    /// A missing runtime doesn't make the apps and data on the simulator worthless.
    @Test func unavailableSimulatorNeedsCaution() {
        let sim = ScanItem(url: URL(filePath: "/tmp/sim"), name: "iPhone", size: 1, lastUsed: nil, kind: .simulator, isOrphaned: true)
        #expect(ItemFacts.risk(for: sim, facts: []).level == .caution)
    }

    /// `brew cleanup --prune=all` also uninstalls older versions of installed formulae.
    @Test func homebrewCleanupNeedsCaution() {
        let brew = ScanItem(url: URL(filePath: "/tmp/Homebrew"), name: "Homebrew", size: 1, lastUsed: nil, kind: .packageCache,
                            command: "brew cleanup --prune=all")
        #expect(ItemFacts.risk(for: brew, facts: []).level == .caution)
    }

    @Test(arguments: [
        AIEntry(tool: nil, category: .conversation, isVerified: false),
        AIEntry(tool: .claudeApp, category: .toolData, isVerified: false),
        AIEntry(tool: .aside, category: .cache, isVerified: false),
    ])
    func reviewOnlyAIDataSaysShubiWontDeleteIt(_ entry: AIEntry) {
        let risk = ItemFactsTests.risk(of: entry)
        #expect(risk.level == .caution)
        #expect(risk.title == String(localized: "Shubi는 이 항목을 지우지 않아요"))
    }

    /// Deleting a Codex rollout leaves its row in Codex's own index.
    @Test func codexConversationMentionsItsIndex() {
        let caveat = String(localized: "Codex 대화 목록에는 이름이 남을 수 있어요.")
        #expect(Self.risk(of: AIEntry(tool: .codex, category: .conversation, isVerified: true)).reason.contains(caveat))
        #expect(!Self.risk(of: AIEntry(tool: .claudeCode, category: .conversation, isVerified: true)).reason.contains(caveat))
    }

    @Test func aiVerdictsFollowWhatTheFileHolds() {
        #expect(Self.risk(of: AIEntry(tool: .codex, category: .cache, isVerified: true)).level == .safe)
        #expect(Self.risk(of: AIEntry(tool: .t3Code, category: .log, isVerified: true)).level == .safe)
        #expect(Self.risk(of: AIEntry(tool: .codex, category: .output, isVerified: true)).level == .caution)
        let leftover = Self.risk(of: AIEntry(tool: .antigravity, category: .conversation, isVerified: true), isOrphaned: true)
        #expect(leftover.level == .caution)
        #expect(leftover.title == String(localized: "삭제된 도구의 대화 기록이에요"))
    }

    private static func risk(of entry: AIEntry, isOrphaned: Bool = false) -> DeletionRisk {
        let item = ScanItem(url: URL(filePath: "/tmp/ai"), name: "ai", size: 1, lastUsed: nil, kind: .aiData(entry), isOrphaned: isOrphaned)
        return ItemFacts.risk(for: item, facts: [])
    }

    @Test func orphanedAppDataNeedsCaution() {
        let data = ScanItem(url: URL(filePath: "/tmp/com.gone.app"), name: "com.gone.app", size: 1, lastUsed: nil, kind: .appData, isOrphaned: true)
        #expect(ItemFacts.risk(for: data, facts: []).level == .caution)
    }
}
