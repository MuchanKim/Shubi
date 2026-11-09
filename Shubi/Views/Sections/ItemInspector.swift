import SwiftUI

struct ItemInspector: View {
    let item: ScanItem

    /// Tagged with what they were made from (the item as scanned, and the language): while newer facts load,
    /// nothing is judged on stale ones.
    @State private var made: (key: [AnyHashable], facts: [Fact])?

    private var key: [AnyHashable] { [item, ShownLanguage.shared.locale] }

    var body: some View {
        let facts = made?.key == key ? made?.facts ?? [] : []
        Form {
            if !facts.isEmpty {
                let risk = ItemFacts.risk(for: item, facts: facts)
                Section("삭제 영향") {
                    VStack(alignment: .leading, spacing: Layout.Spacing.s) {
                        Label(risk.title, systemImage: risk.level.icon)
                            .font(.headline)
                            .foregroundStyle(risk.level.color)
                        Text(risk.reason).textSelection(.enabled)
                    }
                }
            }
            Section("정보") {
                ForEach(facts, id: \.self) { fact in
                    LabeledContent(fact.label) {
                        Text(fact.value).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Again when the item is rescanned (its details are words from the scan) or the language changes.
        .task(id: key) {
            let key = key
            let facts = await ItemFacts.facts(for: item)
            guard !Task.isCancelled else { return }
            made = (key, facts)
        }
    }
}

private extension DeletionRisk.Level {
    var icon: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .risky: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .risky: .red
        }
    }
}
