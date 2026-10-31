import XCTest
@testable import Parla

final class ScratchpadSpellingPolicyTests: XCTestCase {
    private func token(_ text: String, _ selection: NSRange? = nil) throws -> ScratchpadSpellingPolicy.Token {
        try ScratchpadSpellingPolicy.token(Array(text.utf16), selection: selection ?? NSRange(location: 0, length: text.utf16.count))
    }
    private func choices(_ original: String, _ words: [String]) throws -> ScratchpadSpellingPolicy.Choices {
        try ScratchpadSpellingPolicy.candidates(original: Array(original.utf16), words: words, now: { 0 })
    }
    func testWholeTokensAndInteriorEndCaretPreserveRanges() throws {
        for text in ["openai", "abc_def", "abc123", "École", "cafe\u{301}", "अनामिका", "العربية", "\u{10428}\u{10429}\u{1042A}"] {
            let result = try token(text)
            XCTAssertEqual(result.units, Array(text.utf16), text)
            let document = "!" + text + " 🙂"
            let range = NSRange(location: 1, length: text.utf16.count)
            XCTAssertEqual(try token(document, range).range, range)
            XCTAssertEqual(try token(document, NSRange(location: NSMaxRange(range), length: 0)).range, range)
        }
        XCTAssertEqual(try token("openai openai!", NSRange(location: 9, length: 0)).range, NSRange(location: 7, length: 6))
        XCTAssertEqual(try token("openai.", NSRange(location: 6, length: 0)).range, NSRange(location: 0, length: 6))
    }
    func testInvalidRangesAndGraphemeCutsNeverRoundOrExpand() {
        let text = "cafe\u{301} abc"
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0),
                      NSRange(location: Int.max, length: Int.max), NSRange(location: 0, length: Int.max),
                      NSRange(location: 0, length: 0), NSRange(location: 4, length: 0),
                      NSRange(location: 0, length: 4), NSRange(location: 1, length: 4),
                      NSRange(location: 0, length: 6), NSRange(location: 6, length: 0),
                      NSRange(location: 5, length: 4)] {
            XCTAssertThrowsError(try token(text, range), "\(range)")
        }
        XCTAssertThrowsError(try token("\u{10428}abc", NSRange(location: 1, length: 0)))
        XCTAssertThrowsError(try token("openai openai"))
        XCTAssertThrowsError(try token(" openai "))
        XCTAssertThrowsError(try token(""))
    }
    func testCompoundPoisonEmojiJoinerAndShortWordsRefuseFragments() {
        let fragments: [(String, NSRange)] = [
            ("foo-bar", NSRange(location: 0, length: 3)), ("foo.bar", NSRange(location: 4, length: 3)),
            ("O’Connor", NSRange(location: 2, length: 6)), ("foo@example.com", NSRange(location: 0, length: 3)),
            ("/openai", NSRange(location: 1, length: 6)), ("foo\\openai", NSRange(location: 4, length: 6)),
            ("foo..bar", NSRange(location: 0, length: 3)), ("abc\u{200D}def", NSRange(location: 0, length: 3)),
            ("abc \u{301}", NSRange(location: 0, length: 3)),
            ("abc.\u{301}", NSRange(location: 0, length: 3)),
            ("abc\u{202E}", NSRange(location: 0, length: 3)), ("abc\u{FFFC}", NSRange(location: 0, length: 3))
        ]
        for (text, range) in fragments { XCTAssertThrowsError(try token(text, range), text) }
        for invalid in ["ab", "१२३", "123", "___", "\u{301}", "👨‍👩‍👧‍👦", "👍🏽", "🇮🇳", "abc\u{FE0F}", "abc\u{0000}", "abc\u{200B}", "abc\u{200C}", "abc\u{034F}", "abc\u{180B}", "abc\u{115F}", "a😀bc"] {
            XCTAssertThrowsError(try token(invalid), invalid)
        }
        XCTAssertThrowsError(try ScratchpadSpellingPolicy.token([0xD800, 97, 98, 99], selection: NSRange(location: 1, length: 3)))
        XCTAssertThrowsError(try ScratchpadSpellingPolicy.token([97, 98, 99, 0xDC00], selection: NSRange(location: 0, length: 3)))
        XCTAssertThrowsError(try token("क्‍ष", NSRange(location: 1, length: 0)))
        // Declared joiner allowance is only mark→joiner→letter INSIDE one cluster;
        // segmentation that places it between clusters conservatively refuses.
        XCTAssertFalse(ScratchpadSpellingPolicy.admitted("abc\u{200D}def"))
    }
    func testCanonicalNoopEarliestRepresentativeCaseTiesAndLiteralOutput() throws {
        XCTAssertEqual(try choices("cafe\u{301}", ["café", "cafe\u{301}", "Café", "CAFÉ"]).outputs.map { Array($0.utf16) }, [Array("café".utf16), Array("Café".utf16), Array("CAFÉ".utf16)])
        XCTAssertEqual(try choices("cafe\u{301}", ["cafe\u{301}", "café"]).outputs, [])
        XCTAssertEqual(try choices("café", ["café", "cafe\u{301}"]).outputs, [])
        XCTAssertEqual(try choices("openai", ["openai", "OpenAI", "OPENAI", "OpenAI"]).outputs, ["OpenAI", "OPENAI"])
        XCTAssertFalse(ScratchpadSpellingPolicy.exact("café", "cafe\u{301}"))
        XCTAssertEqual(try choices("opneai", ["OpenAI"]).outputs, [])
        XCTAssertEqual(try choices("cafe", ["Café"]).outputs, [])
        XCTAssertEqual(try choices("ＡＢＣ", ["ABC"]).outputs, [])
        XCTAssertEqual(ScratchpadSpellingPolicy.key("İSTANBUL"), "i\u{307}stanbul")
    }
    func testFiveRetainedAndMoreFinishFullScanWithBoundedNoopKey() throws {
        let words = ["openai", "OpenAI", "OPENAI", "Openai", "oPENAI", "opENAI", "opeNAI", "openAI", "OpenAI"]
        let result = try choices("openai", words)
        XCTAssertEqual(result.outputs, Array(words[1...5])); XCTAssertTrue(result.more)
        XCTAssertEqual(result.examinedBytes, words.reduce(0) { $0 + $1.utf8.count })
        XCTAssertFalse(try choices("openai", ["OpenAI", "OPENAI", "OpenAI"]).more)
        XCTAssertTrue(try choices("openai", [" two words", "x\ny", "👨‍👩‍👧‍👦", "ab", "openai"]).outputs.isEmpty)
    }
    func testEveryBoundAndCompleteBudgetRefusalNeverReturnsPartialAuthority() throws {
        XCTAssertThrowsError(try choices("openai", [String](repeating: "OpenAI", count: 10_001)))
        let huge = String(repeating: "a", count: 1_000_000)
        let result = try choices("openai", [huge, "OpenAI"])
        XCTAssertEqual(result.examinedBytes, 257 + 6); XCTAssertEqual(result.outputs, ["OpenAI"])
        var clock = 0.0
        XCTAssertThrowsError(try ScratchpadSpellingPolicy.candidates(original: Array("openai".utf16), words: ["OpenAI", "OPENAI"], now: {
            defer { clock += 0.006 }; return clock
        }))
        XCTAssertThrowsError(try token(String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try token("abc" + String(repeating: "\u{301}", count: 130)))
        XCTAssertThrowsError(try token(String(repeating: "a", count: 65_537), NSRange(location: 3, length: 0)))
        XCTAssertTrue(ScratchpadSpellingPolicy.snapshotFitsBudget(65_536))
        XCTAssertFalse(ScratchpadSpellingPolicy.snapshotFitsBudget(Int.max))
        let max = String(repeating: "a", count: 64)
        XCTAssertEqual(try token(max).units.count, 64)
        // More than 128 UTF-16 / 256 UTF-8 units refuse even at <=64 clusters.
        XCTAssertThrowsError(try token(String(repeating: "a\u{301}\u{302}", count: 64)))
    }
}
