import SwiftUI

/// Grouped sections with colored icon tiles and a selection card, instead of the system's accent highlight.
struct Sidebar: View {
    @Binding var selection: SidebarSection?

    /// One value, not a Bool per view: nested Bool focus states are all true at once, which drew two rings.
    fileprivate enum Focus: Hashable {
        /// Clicking a row focuses the list, so ↑/↓ then move between sections like a List; the table keeps its own arrows.
        case list
        /// Tab reaches a row button only with keyboard navigation turned on.
        case row(SidebarSection)
    }

    @FocusState private var focus: Focus?
    /// The list got focus from a click or a ⌘-number, not from Tab: no ring then, so a click leaves a plain card.
    @State private var isListFocusFromPointer = false

    private static let groups: [(title: LocalizedStringResource?, sections: [SidebarSection])] = [
        (nil, [.summary]),
        ("정리", [.developer, .browser, .appCache, .orphanedData, .packageCache, .logs]),
        ("내 파일", [.old, .large]),
        // Last, so ⌘1…⌘9 keep pointing where they did.
        ("AI", [.ai]),
    ]

    /// Display order, which ↑/↓ and ⌘-numbers follow.
    fileprivate static let order: [SidebarSection] = {
        let order = groups.flatMap(\.sections)
        assert(order.count == SidebarSection.allCases.count && Set(order) == Set(SidebarSection.allCases), "every section appears in the sidebar once")
        return order
    }()

    /// ⌘1…⌘9 in sidebar order, then ⌘0 for the tenth; none after that rather than a key that doesn't exist.
    static func shortcut(for section: SidebarSection) -> KeyboardShortcut? {
        guard let index = order.firstIndex(of: section), index < 10 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.Spacing.l) {
                    ForEach(Self.groups, id: \.sections) { group in
                        VStack(alignment: .leading, spacing: Layout.Spacing.xxs) {
                            if let title = group.title {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, Layout.Spacing.s)
                                    .padding(.bottom, Layout.Spacing.xs)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(group.sections) { section in
                                SidebarRow(section: section, isSelected: section == selection, focus: $focus,
                                           hasKeyboardListFocus: focus == .list && !isListFocusFromPointer) {
                                    // Only a plain key (Space, Return on a Tab-focused row) is the keyboard; a click or a
                                    // ⌘-number leaves a plain card. Focus alone can't tell them apart.
                                    let event = NSApp.currentEvent
                                    isListFocusFromPointer = !(event?.type == .keyDown && event?.modifierFlags.contains(.command) == false)
                                    focus = .list
                                    selection = section
                                }
                                .id(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, Layout.Spacing.m)
                .padding(.vertical, Layout.Spacing.s)
            }
            .focusable()
            .focused($focus, equals: .list)
            // The selected card's ring shows keyboard focus instead of a ring around the whole sidebar.
            .focusEffectDisabled()
            .onChange(of: focus) { if focus != .list { isListFocusFromPointer = false } }
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(.upArrow) { move(by: -1) }
            // A short window scrolls the sidebar; keep the row picked by keyboard in view.
            .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        // From a Tab-focused row, move from that row and take focus along, so focus and selection stay on one row.
        let focusedRow: SidebarSection? = if case .row(let section) = focus { section } else { nil }
        let all = Self.order
        let index = (focusedRow ?? selection).flatMap(all.firstIndex(of:)) ?? 0
        guard all.indices.contains(index + offset) else { return .handled }
        selection = all[index + offset]
        if focusedRow != nil { focus = .row(all[index + offset]) }
        return .handled
    }
}

private struct SidebarRow: View {
    let section: SidebarSection
    let isSelected: Bool
    let focus: FocusState<Sidebar.Focus?>.Binding
    /// Tab reached the list itself, so the selected row shows where ↑/↓ will act.
    let hasKeyboardListFocus: Bool
    let select: () -> Void

    @State private var isHovered = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: select) {
            HStack(spacing: Layout.Spacing.s) {
                SymbolTile(systemName: section.icon, tint: section.tint)
                Text(section.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, Layout.Spacing.s)
            .frame(maxWidth: .infinity, minHeight: Layout.sidebarRowHeight, alignment: .leading)
            .background { background }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The sidebar's `focusEffectDisabled` also hides this button's ring, so `background` draws one.
        .focused(focus, equals: .row(section))
        // ⌘-numbers in sidebar order: the buttons don't get the arrow-key navigation a List had.
        .keyboardShortcut(Sidebar.shortcut(for: section))
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.Spacing.s)
        // Keyboard focus only, never after a click; an inactive window shows none.
        let hasKeyboardFocus = appearsActive && (focus.wrappedValue == .row(section) || isSelected && hasKeyboardListFocus)
        // The tint pushed toward black (white in dark mode) by 35%: at least 3:1 against the sidebar and the card.
        let focusRing = shape.strokeBorder(section.tint.mix(with: colorScheme == .dark ? .white : .black, by: 0.35), lineWidth: 1.5)
        if isSelected {
            // One neutral card for every section and focus state: the icon tile already carries the section's color.
            shape.fill(.background)
                .overlay { if hasKeyboardFocus { focusRing } }
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        } else if hasKeyboardFocus {
            focusRing
        } else if isHovered {
            shape.fill(.fill.quaternary)
        }
    }
}

/// A white symbol on a tile of its tint's gradient: the app's icon style, in the sidebar and on the summary.
struct SymbolTile: View {
    let systemName: String
    let tint: Color
    var size = Layout.sidebarTileSize

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size / 2, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 6 / 22))
            .accessibilityHidden(true)
    }
}
