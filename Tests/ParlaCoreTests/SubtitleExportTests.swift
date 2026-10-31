import XCTest
@testable import ParlaCore

final class SubtitleExportTests: XCTestCase {
    private func segments(_ cues: [RecognitionSegments.Cue]) throws -> RecognitionSegments {
        try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 9_600_000, cues: cues)
    }
    func testIndependentManualBytesAndDecodedTextTimesOracle() throws {
        let native = try segments([.init(text: "A & B --> <v X>", start: 100, end: 200),
            .init(text: "NOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻", start: 700, end: 800)])
        let expected = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nA &amp; B --&gt; &lt;v X&gt;\n\n2\n00:00:07.000 --> 00:00:08.000\nNOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻\n\n"
        let data = try SubtitleExport.encoded(native)
        XCTAssertEqual(data, Data(expected.utf8)); XCTAssertEqual(Array(data.prefix(8)), [87, 69, 66, 86, 84, 84, 10, 10])
        // Manual structural/semantic oracle, not a WebVTT parser/player claim.
        let blocks = String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 4); XCTAssertEqual(blocks[0], "WEBVTT"); XCTAssertEqual(blocks[3], "")
        let first = blocks[1].components(separatedBy: "\n"), second = blocks[2].components(separatedBy: "\n")
        XCTAssertEqual(first[0], "1"); XCTAssertEqual(first[1], "00:00:01.000 --> 00:00:02.000")
        XCTAssertEqual(second[0], "2"); XCTAssertEqual(second[1], "00:00:07.000 --> 00:00:08.000")
        // Decode only the three deliberately emitted named references, once.
        func decoded(_ text: String) -> String {
            text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        }
        XCTAssertEqual(decoded(first[2]), "A & B --> <v X>")
        XCTAssertEqual(second.dropFirst(2).joined(separator: "\n"), "NOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻")
        XCTAssertEqual(expected.components(separatedBy: " --> ").count - 1, 2)
        XCTAssertFalse(expected.contains("<v ")); XCTAssertFalse(expected.contains("00:00:02.000 --> 00:00:07.000"))
    }
    func testIndependentEntityTagsArrowUnicodeAndExportOnlyNewlines() throws {
        let cases: [(String, String)] = [
            ("&lt;v Alice&gt;", "&amp;lt;v Alice&amp;gt;"),
            ("<v Alice>Hello</v>", "&lt;v Alice&gt;Hello&lt;/v&gt;"),
            ("00:00:03.000 --> 00:00:04.000", "00:00:03.000 --&gt; 00:00:04.000"),
            ("<00:00:01.500><b>X</b><script>X</script>", "&lt;00:00:01.500&gt;&lt;b&gt;X&lt;/b&gt;&lt;script&gt;X&lt;/script&gt;"),
            ("one\r\ntwo\rthree", "one\ntwo\nthree"),
            ("العربية שלום 123 क्‍ष 👩🏽‍💻 می\u{200c}روم", "العربية שלום 123 क्‍ष 👩🏽‍💻 می\u{200c}روم")]
        for (text, escaped) in cases {
            let native = try segments([.init(text: text, start: 1, end: 2)])
            XCTAssertEqual(try SubtitleExport.encoded(native), Data("WEBVTT\n\n1\n00:00:00.010 --> 00:00:00.020\n\(escaped)\n\n".utf8))
            XCTAssertEqual(native.cues[0].text, text)
        }
    }
    func testConservativePayloadControlsAndBlankLinesRefuseWholeFile() throws {
        let bad = ["", " ", "\t", "\none", "one\n", "one\n\ntwo", "one\n \t\ntwo", "one\r\rthree"]
        let controls: [UInt32] = Array(0...31).filter { ![9, 10, 13].contains($0) } + Array(0x7F...0x9F)
            + [0x2028, 0x2029, 0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for text in bad + controls.map({ "a" + String(UnicodeScalar($0)!) + "b" }) {
            let native = try segments([.init(text: "good", start: 0, end: 1), .init(text: text, start: 1, end: 2)])
            XCTAssertThrowsError(try SubtitleExport.encoded(native))
        }
        XCTAssertThrowsError(try SubtitleExport.encoded(segments([])))
    }
    func testExactCarriesGrowingHoursNoFloatingPointAndOverflow() throws {
        let oracles: [(Int64, String)] = [(0, "00:00:00.000"), (1, "00:00:00.010"), (5999, "00:00:59.990"),
            (6000, "00:01:00.000"), (359999, "00:59:59.990"), (360000, "01:00:00.000"),
            (35999999, "99:59:59.990"), (36000000, "100:00:00.000")]
        for (tick, expected) in oracles { XCTAssertEqual(try SubtitleExport.timestamp(tick: tick), expected) }
        for tick in [Int64(-1), Int64.max] { XCTAssertThrowsError(try SubtitleExport.timestamp(tick: tick)) }
    }
    func testEqualStartsOverlapAdjacencyAndTenMillisecondGapRemainUnattributed() throws {
        let native = try segments([.init(text: "a", start: 100, end: 300), .init(text: "b", start: 100, end: 200),
            .init(text: "c", start: 200, end: 400), .init(text: "d", start: 401, end: 500)])
        let expected = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:03.000\na\n\n2\n00:00:01.000 --> 00:00:02.000\nb\n\n3\n00:00:02.000 --> 00:00:04.000\nc\n\n4\n00:00:04.010 --> 00:00:05.000\nd\n\n"
        XCTAssertEqual(try SubtitleExport.encoded(native), Data(expected.utf8))
    }
    func testFullByteBudgetIncludesHeaderIDsTimingSeparatorsAndEscapes() throws {
        let native = try segments([.init(text: "&", start: 0, end: 1)])
        let expected = Data("WEBVTT\n\n1\n00:00:00.000 --> 00:00:00.010\n&amp;\n\n".utf8)
        XCTAssertEqual(expected.count, 47)
        XCTAssertEqual(try SubtitleExport.encode(native, maximumBytes: 47), expected)
        XCTAssertThrowsError(try SubtitleExport.encode(native, maximumBytes: 46))
        // 1 MiB of ampersands => 5 MiB escaped payload + 42 framing bytes.
        let maximum = try segments([.init(text: String(repeating: "&", count: 1_048_576), start: 0, end: 1)])
        XCTAssertEqual(try SubtitleExport.encoded(maximum).count, 5_242_922)
        XCTAssertEqual(SubtitleExport.maximumBytes, 8_388_608)
        XCTAssertThrowsError(try SubtitleExport.encode(native, maximumBytes: -1))
    }
}

extension SubtitleExportTests {
    func testSRTIndependentLiteralBytesCountersUnicodeAndGaps() throws {
        let texts = [" Q&A: 5 & 6; AT&T", "NOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻"]
        let native = try segments([.init(text: texts[0], start: 100, end: 200), .init(text: texts[1], start: 700, end: 800)])
        let expected = Data("1\n00:00:01,000 --> 00:00:02,000\n Q&A: 5 & 6; AT&T\n\n2\n00:00:07,000 --> 00:00:08,000\nNOTE\nSTYLE\nREGION\nمرحبا 123 שלום 45\nनमस्ते 👩🏽‍💻\n\n".utf8)
        let data = try SubtitleExport.encoded(native, format: .srt)
        XCTAssertEqual(data, expected); XCTAssertEqual(data.count, 164)
        XCTAssertEqual(Array(data.prefix(2)), [49, 10]); XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertFalse(data.contains(13)); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("WEBVTT"))
        let blocks = String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 3); XCTAssertEqual(blocks.last, "")
        for index in 0..<2 {
            XCTAssertEqual(blocks[index].components(separatedBy: "\n").dropFirst(2).joined(separator: "\n"), texts[index])
        }
    }
    func testSRTExportOnlyNewlineNormalizationAndLiteralPositives() throws {
        let cases = [("one\r\ntwo\rthree", "one\ntwo\nthree"), ("Q&A", "Q&A"), ("AT&T", "AT&T"),
            ("&", "&"), ("&;", "&;"), ("fish & chips; tea", "fish & chips; tea"),
            ("＜fullwidth＞", "＜fullwidth＞"), (" leading and trailing ", " leading and trailing "), ("a\tb", "a\tb"),
            ("العربية שלום 123 क्‍ष 👩🏽‍💻 می\u{200c}روم", "العربية שלום 123 क्‍ष 👩🏽‍💻 می\u{200c}روم")]
        for (text, payload) in cases {
            let native = try segments([.init(text: text, start: 1, end: 2)])
            XCTAssertEqual(try SubtitleExport.encoded(native, format: .srt), Data("1\n00:00:00,010 --> 00:00:00,020\n\(payload)\n\n".utf8))
            XCTAssertEqual(native.cues[0].text, text)
        }
    }
    func testSRTEqualStartsOverlapAdjacencyAndGapPreserveNativeOrder() throws {
        let native = try segments([.init(text: "a", start: 100, end: 300), .init(text: "b", start: 100, end: 200),
            .init(text: "c", start: 200, end: 400), .init(text: "d", start: 401, end: 500)])
        let expected = "1\n00:00:01,000 --> 00:00:03,000\na\n\n2\n00:00:01,000 --> 00:00:02,000\nb\n\n3\n00:00:02,000 --> 00:00:04,000\nc\n\n4\n00:00:04,010 --> 00:00:05,000\nd\n\n"
        XCTAssertEqual(try SubtitleExport.encoded(native, format: .srt), Data(expected.utf8))
    }
    func testSRTMarkupRefusesWholeFileWithVTTFallback() throws {
        for text in ["<", ">", "{", "}", "\\", "a --> b", "<i>x</i>", "<v X>", "{\\an8}x", "a\\Nb",
                     "&amp;", "&lt;v X&gt;", "&#60;", "&#x3C;", "AT&T;"] {
            let native = try segments([.init(text: "good", start: 0, end: 1), .init(text: text, start: 1, end: 2)])
            XCTAssertThrowsError(try SubtitleExport.encoded(native, format: .srt)) {
                XCTAssertEqual($0 as? SubtitleExport.Refusal, .markup, text)
            }
            XCTAssertNoThrow(try SubtitleExport.encoded(native, format: .webVTT))
        }
    }
    func testSRTSharedBlankControlBidiAndEmptyRefusalsPrecedeMarkup() throws {
        let bad = ["", " ", "\t", "\none", "one\n", "one\n\ntwo", "one\n \t\ntwo", "one\r\rthree"]
        let controls: [UInt32] = Array(0...31).filter { ![9, 10, 13].contains($0) } + Array(0x7F...0x9F)
            + [0x2028, 0x2029, 0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for text in bad + controls.map({ "a" + String(UnicodeScalar($0)!) + "b" }) {
            let native = try segments([.init(text: "<", start: 0, end: 1), .init(text: text, start: 1, end: 2)])
            XCTAssertThrowsError(try SubtitleExport.encoded(native, format: .srt)) {
                XCTAssertEqual($0 as? SubtitleExport.Refusal, .payload)
            }
        }
        XCTAssertThrowsError(try SubtitleExport.encoded(segments([]), format: .srt)) {
            XCTAssertEqual($0 as? SubtitleExport.Refusal, .empty)
        }
    }
    func testSRTHundredHourBoundaryAndTimePrecedenceKeepVTTGrowingHours() throws {
        let last = try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 5_760_000_000,
            cues: [.init(text: "a", start: 35_999_998, end: 35_999_999)])
        XCTAssertEqual(try SubtitleExport.encoded(last, format: .srt), Data("1\n99:59:59,980 --> 99:59:59,990\na\n\n".utf8))
        let over = try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 5_760_000_000,
            cues: [.init(text: "<", start: 0, end: 1), .init(text: "a", start: 35_999_999, end: 36_000_000)])
        XCTAssertThrowsError(try SubtitleExport.encoded(over, format: .srt)) {
            XCTAssertEqual($0 as? SubtitleExport.Refusal, .overflow)
        }
        XCTAssertEqual(try SubtitleExport.encoded(over), Data("WEBVTT\n\n1\n00:00:00.000 --> 00:00:00.010\n&lt;\n\n2\n99:59:59.990 --> 100:00:00.000\na\n\n".utf8))
    }
    func testSRTWholeByteBudgetIncludesCountersTimingSeparatorsAndUTF8() throws {
        let native = try segments([.init(text: "a", start: 0, end: 1)])
        let expected = Data("1\n00:00:00,000 --> 00:00:00,010\na\n\n".utf8)
        XCTAssertEqual(expected.count, 35)
        XCTAssertEqual(try SubtitleExport.encode(native, format: .srt, maximumBytes: 35), expected)
        for cap in [34, -1] {
            XCTAssertThrowsError(try SubtitleExport.encode(native, format: .srt, maximumBytes: cap)) {
                XCTAssertEqual($0 as? SubtitleExport.Refusal, .limit)
            }
        }
        let marked = try segments([.init(text: "<", start: 0, end: 1), .init(text: "a", start: 1, end: 2)])
        XCTAssertThrowsError(try SubtitleExport.encode(marked, format: .srt, maximumBytes: 69)) {
            XCTAssertEqual($0 as? SubtitleExport.Refusal, .limit)
        }
        let unicode = try segments([.init(text: "👩🏽‍💻", start: 0, end: 1)])
        let unicodeBytes = Data("1\n00:00:00,000 --> 00:00:00,010\n👩🏽‍💻\n\n".utf8)
        XCTAssertEqual(unicodeBytes.count, 49)
        XCTAssertEqual(try SubtitleExport.encode(unicode, format: .srt, maximumBytes: 49), unicodeBytes)
        XCTAssertThrowsError(try SubtitleExport.encode(unicode, format: .srt, maximumBytes: 48)) {
            XCTAssertEqual($0 as? SubtitleExport.Refusal, .limit)
        }
        let maximum = try segments([.init(text: String(repeating: "a", count: 1_048_576), start: 0, end: 1)])
        XCTAssertEqual(try SubtitleExport.encoded(maximum, format: .srt).count, 1_048_610)
        XCTAssertEqual(SubtitleExport.maximumBytes, 8_388_608)
        // Counter width is output framing too: ten cues add one byte at cue 10.
        let ten = try segments((0..<10).map { .init(text: "a", start: Int64($0), end: Int64($0 + 1)) })
        XCTAssertEqual(try SubtitleExport.encode(ten, format: .srt, maximumBytes: 351).count, 351)
        XCTAssertThrowsError(try SubtitleExport.encode(ten, format: .srt, maximumBytes: 350)) {
            XCTAssertEqual($0 as? SubtitleExport.Refusal, .limit)
        }
    }
    func testDefaultAndExplicitWebVTTPreserveExistingEscapedBytes() throws {
        let native = try segments([.init(text: "A & B --> <v X>", start: 100, end: 200)])
        XCTAssertEqual(try SubtitleExport.encoded(native), try SubtitleExport.encoded(native, format: .webVTT))
        XCTAssertEqual(try SubtitleExport.encoded(native), Data("WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nA &amp; B --&gt; &lt;v X&gt;\n\n".utf8))
    }
}
