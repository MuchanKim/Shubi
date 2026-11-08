import SwiftUI

struct ItemInspector: View {
    let item: ScanItem

    @State private var facts: [Fact] = []

    var body: some View {
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
        .task(id: item.id) { facts = await ItemFacts.facts(for: item) }
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
