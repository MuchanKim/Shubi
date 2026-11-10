import SwiftUI
import Testing
@testable import Shubi

@MainActor
struct SidebarTests {
    /// ⌘1…⌘9 stay where users learned them; the tenth section gets ⌘0 instead of trapping on a key named "10".
    @Test func everySectionGetsItsOwnShortcut() {
        let keys = SidebarSection.allCases.compactMap { Sidebar.shortcut(for: $0)?.key.character }
        #expect(Set(keys).count == SidebarSection.allCases.count)
        #expect(Sidebar.shortcut(for: .summary)?.key.character == "1")
        #expect(Sidebar.shortcut(for: .large)?.key.character == "9")
        #expect(Sidebar.shortcut(for: .ai)?.key.character == "0")
    }
}
