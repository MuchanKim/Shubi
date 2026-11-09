import Foundation
import Testing
@testable import Shubi

struct LanguageTests {
    // Looks up through each .lproj directly: switching the app-wide language here would race the suites
    // that compare localized strings in parallel.
    @Test(arguments: [("en", "Overview"), ("ko", "요약")])
    func eachLanguageHasItsOwnStrings(code: String, summary: String) throws {
        let bundle = try #require(Bundle.strings(in: code))
        #expect(String(localized: "요약", bundle: bundle, locale: Locale(identifier: code)) == summary)
    }

    @Test(arguments: [(1, "1 item"), (2, "2 items")])
    func pluralsFollowTheChosenLanguageNotTheLaunchOne(count: Int, text: String) throws {
        // The bundle alone would pick plural forms by the launch locale: "1 items" in a Korean session.
        let english = try #require(Bundle.strings(in: "en"))
        #expect(String(localized: "\(count)개 항목", bundle: english, locale: Locale(identifier: "en")) == text)
    }

    @Test func aLanguageTheAppDoesNotHaveHasNoStrings() {
        #expect(Bundle.strings(in: "ja") == nil)
    }
}
