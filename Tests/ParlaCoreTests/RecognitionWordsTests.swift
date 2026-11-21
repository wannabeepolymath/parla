import XCTest
@testable import ParlaCore

final class RecognitionWordsTests: XCTestCase {
    private func token(_ text: String, _ start: Int64, _ end: Int64, id: Int32 = 1, segment: Int = 0) -> RecognitionWords.Token {
        .init(id: id, bytes: Array(text.utf8), start: start, end: end, segment: segment)
    }
    func testTokensAssembleIntoWordsWithPunctuationAndSpecialsDropped() {
        let words = RecognitionWords.assemble(tokens: [
            token(" Hello", 10, 20), token(",", 20, 22), token("<|0.40|>", 22, 22, id: 50_400),
            token(" wor", 30, 35), token("ld", 35, 40), token(".", 40, 41), token("<|endoftext|>", 41, 41, id: 50_256),
        ], eot: 50_256)
        XCTAssertEqual(words, [.init(text: "Hello,", start: 10, end: 22, segment: 0), .init(text: "world.", start: 30, end: 41, segment: 0)])
    }
    func testMultiByteCharacterSplitAcrossTokensDecodesAsOneWord() {
        let bytes = Array(" नमस्ते".utf8)
        let words = RecognitionWords.assemble(tokens: [
            .init(id: 1, bytes: Array(bytes[..<5]), start: 0, end: 5, segment: 0),
            .init(id: 2, bytes: Array(bytes[5...]), start: 5, end: 9, segment: 0),
        ], eot: 50_256)
        XCTAssertEqual(words, [.init(text: "नमस्ते", start: 0, end: 9, segment: 0)])
    }
    func testValidationRefusesOutOfBoundsAndDecreasingStarts() {
        XCTAssertNoThrow(try RecognitionWords(sourceSampleCount: 16_000, words: [.init(text: "a", start: 0, end: 100, segment: 0)]))
        XCTAssertThrowsError(try RecognitionWords(sourceSampleCount: 16_000, words: [.init(text: "a", start: 0, end: 101, segment: 0)]))
        XCTAssertThrowsError(try RecognitionWords(sourceSampleCount: 16_000, words: [.init(text: "a", start: 10, end: 20, segment: 0),
                                                                                    .init(text: "b", start: 5, end: 30, segment: 0)]))
        XCTAssertThrowsError(try RecognitionWords(sourceSampleCount: 16_000, words: [.init(text: "a", start: 20, end: 10, segment: 0)]))
    }
}
