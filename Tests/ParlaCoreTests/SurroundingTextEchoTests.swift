import XCTest
@testable import ParlaCore

final class SurroundingTextEchoTests: XCTestCase {
    private let raw = "please send the report tomorrow"

    func testFormattingOnlyUnicodeDifferencesStillCountAsEcho() {
        for context in ["Private se\u{00AD}cret token stays here", "Private sec\u{200B}ret token stays here",
                        "\u{FF30}rivate secret token stays here", "Private secret token \u{FF53}tays here"] {
            XCTAssertTrue(SurroundingTextPrefix(text: context).containsUnsupportedEcho(in: "Private secret token stays", dictated: raw), context)
        }
    }

    func testRemovedFillersDoNotMakeDictatedPhraseUnsupported() {
        let prefix = SurroundingTextPrefix(text: "We hope you have a nice day.")
        XCTAssertFalse(prefix.containsUnsupportedEcho(in: "Have a nice day.", dictated: "have uh a nice day"))
    }

    func testUnrelatedOutputIsAccepted() {
        XCTAssertFalse(SurroundingTextPrefix(text: "Private secret token stays here").containsUnsupportedEcho(in: "Please send the report tomorrow.", dictated: raw))
    }
}
