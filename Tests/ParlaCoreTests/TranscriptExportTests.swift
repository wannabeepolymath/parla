import XCTest
import ParlaCore

final class TranscriptExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testPlainTextPreservesUTF8MultilineWhitespaceAndEmptyEntries() {
        let source = "  हिन्दी\nالعربية עברית 👩🏽‍💻 e\u{301}\r\n\nlast\t "
        let document = TranscriptExport(entries: [.init(text: source, date: date, appLabel: "Editor"),
                                                 .init(text: "", date: date)])
        let output = document.encoded(content: .original, format: .text)
        let expected = "Entry 1 · 1970-01-01T00:00:00Z · Original\nApp: Editor\n\n" + source
            + "\n\n--------\n\nEntry 2 · 1970-01-01T00:00:00Z · Original\n\n\n"
        XCTAssertEqual(output, Data(expected.utf8))
        XCTAssertEqual(String(data: output, encoding: .utf8), expected)
    }

    func testMarkdownFencesArbitrarySourceAndEscapesMetadataWithoutChangingSource() {
        let source = "# Heading\n```swift\nprint(1)\n```\n`````\n---\n[link](https://example.test)\nالعربية e\u{301} 😀"
        let document = TranscriptExport(entries: [.init(text: source, date: date,
                                                      appLabel: "Editor\r\n# [link](x) `code` <html> \\ end\u{2028}next")])
        let output = String(decoding: document.encoded(content: .result, format: .markdown), as: UTF8.self)
        XCTAssertEqual(output, "## Entry 1 · 1970-01-01T00:00:00Z · Result\n\nApp: Editor\\r\\n\\# \\[link\\]\\(x\\) \\`code\\` \\<html\\> \\\\ end next\n\n``````text\n" + source + "\n``````\n")
    }

    func testMarkdownEmptyAndTrailingNewlineRowsRemainDistinct() {
        let document = TranscriptExport(entries: [.init(text: "", date: date), .init(text: "line\n\n", date: date)])
        XCTAssertEqual(String(decoding: document.encoded(content: .original, format: .markdown), as: UTF8.self),
                       "## Entry 1 · 1970-01-01T00:00:00Z · Original\n\n```text\n\n```\n\n---\n\n## Entry 2 · 1970-01-01T00:00:00Z · Original\n\n```text\nline\n\n```\n")
        XCTAssertTrue(TranscriptExport(entries: []).encoded(content: .result, format: .text).isEmpty)
        XCTAssertTrue(TranscriptExport(entries: []).encoded(content: .result, format: .markdown).isEmpty)
    }

    func testPlainMetadataCannotCreateAnotherHeaderLine() {
        let document = TranscriptExport(entries: [.init(text: "content", date: date, appLabel: "App\nEntry 2\r\tlabel")])
        let output = String(decoding: document.encoded(content: .result, format: .text), as: UTF8.self)
        XCTAssertTrue(output.contains("App: App\\nEntry 2\\r\\tlabel\n\ncontent"))
    }

    func testSuggestedNamesAreNeutralUTCDateAndCorrectExtension() {
        XCTAssertEqual(TranscriptExport.Format.text.suggestedFilename(now: date), "parla-transcripts-1970-01-01.txt")
        XCTAssertEqual(TranscriptExport.Format.markdown.suggestedFilename(now: date.addingTimeInterval(86400)), "parla-transcripts-1970-01-02.md")
    }
}
