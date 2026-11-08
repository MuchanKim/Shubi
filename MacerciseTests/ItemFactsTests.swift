import Foundation
import Testing
@testable import Macercise

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

    @Test func unavailableSimulatorIsSafe() {
        let sim = ScanItem(url: URL(filePath: "/tmp/sim"), name: "iPhone", size: 1, lastUsed: nil, kind: .simulator, isOrphaned: true)
        #expect(ItemFacts.risk(for: sim, facts: []).level == .safe)
    }

    @Test func orphanedAppDataNeedsCaution() {
        let data = ScanItem(url: URL(filePath: "/tmp/com.gone.app"), name: "com.gone.app", size: 1, lastUsed: nil, kind: .appData, isOrphaned: true)
        #expect(ItemFacts.risk(for: data, facts: []).level == .caution)
    }
}
