import Testing
@testable import Shubi

@MainActor
struct CleanupTests {
    /// One deletion at a time, across Smart Clean and every delete sheet.
    @Test func aSecondRunWaitsForTheFirstToEnd() {
        let cleanup = Cleanup()
        #expect(cleanup.begin())
        #expect(!cleanup.begin())
        cleanup.end()
        #expect(cleanup.finished == 1)
        #expect(cleanup.begin())
        cleanup.end()
    }
}
