import XCTest
@testable import ParlaCore

final class PipelineTests: XCTestCase {
    func makePipeline(transcript: String,
                      snippets: [String: String] = [:],
                      cleanup: @escaping (String, CleanupContext) async throws -> String)
    -> Pipeline {
        var settings = Settings()
        settings.dictionary = ["Kubernetes", "Daksh"]
        settings.snippets = snippets
        return Pipeline(
            transcribe: { _, prompt in
                XCTAssertEqual(prompt, "Kubernetes, Daksh")
                return transcript
            },
            cleanup: cleanup,
            settings: { settings },
            frontAppName: { "Mail" })
    }

    func testHappyPath() async {
        let p = makePipeline(transcript: "um hello") { t, ctx in
            XCTAssertEqual(t, "um hello")
            XCTAssertEqual(ctx.appName, "Mail")
            return "Hello."
        }
        let out = await p.process(samples: [0.1])
        XCTAssertEqual(out, "Hello.")
    }

    func testCleanupResultIsSanitized() async {
        let p = makePipeline(transcript: "um hello") { _, _ in "\"Cleaned.\"" }
        let out = await p.process(samples: [0.1])
        XCTAssertEqual(out, "Cleaned.")
    }

    func testCleanupFailureFallsBackToRawTranscript() async {
        let p = makePipeline(transcript: "raw words") { _, _ in
            throw CleanupError(description: "boom")
        }
        let out = await p.process(samples: [0.1])
        XCTAssertEqual(out, "raw words")
    }

    func testCleanReportsFailureOnThrow() async {
        let p = makePipeline(transcript: "raw words") { _, _ in
            throw CleanupError(description: "cleanup API 401", userMessage: "API key expired")
        }
        let result = await p.clean(transcript: "raw words")
        XCTAssertEqual(result.text, "raw words")
        XCTAssertEqual(result.failure, "API key expired")
    }

    func testCleanReportsSuccess() async {
        let p = makePipeline(transcript: "raw words") { t, _ in "Raw words." }
        let result = await p.clean(transcript: "raw words")
        XCTAssertEqual(result.text, "Raw words.")
        XCTAssertNil(result.failure)
    }

    func testEmptyTranscriptReturnsNil() async {
        let p = makePipeline(transcript: "  ") { t, _ in t }
        let out = await p.process(samples: [0.1])
        XCTAssertNil(out)
    }

    // Repetition-loop class output (see the ponytail ceiling in Pipeline.clean)
    // must never replace the raw transcript.
    func testDegenerateOutputFallsBackToRaw() async {
        let p = makePipeline(transcript: "hello there") { t, _ in
            String(repeating: t + " ", count: 30)
        }
        let result = await p.clean(transcript: "hello there")
        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.failure, "cleanup returned invalid text")
    }

    // Pins the exact boundary: allowance = 2*raw + 200, failure strictly above it.
    func testLengthAllowanceBoundary() async {
        let raw = String(repeating: "a", count: 10) // allowance = 2*10 + 200 = 220

        let over = makePipeline(transcript: raw) { _, _ in String(repeating: "b", count: 221) }
        let overResult = await over.clean(transcript: raw)
        XCTAssertNotNil(overResult.failure)
        XCTAssertEqual(overResult.text, raw)

        let atLimit = makePipeline(transcript: raw) { _, _ in String(repeating: "b", count: 220) }
        let atResult = await atLimit.clean(transcript: raw)
        XCTAssertNil(atResult.failure)
        XCTAssertEqual(atResult.text.count, 220)
    }

    // Configured snippet expansions legitimately grow output — they raise the
    // allowance so a triggered expansion isn't misread as a repetition loop.
    func testSnippetExpansionsRaiseAllowance() async {
        let expansion = String(repeating: "x", count: 630)
        // Not a bare "cal one": that fast-paths past the LLM (and the allowance).
        let raw = "say cal one" // base allowance 2*11 + 200 = 222
        let p = makePipeline(transcript: raw,
                             snippets: ["cal one": expansion]) { _, _ in expansion }
        let result = await p.clean(transcript: raw)
        XCTAssertNil(result.failure) // 630 > 222, but ≤ 222 + 630
        XCTAssertEqual(result.text, expansion)
    }

    // literal_locked: the transcript IS the trigger, so expand it here and never
    // ask the model to do a substitution the code already knows.
    func testExactSnippetMatchSkipsCleanup() async {
        let p = makePipeline(transcript: "cal one",
                             snippets: ["cal one": "https://cal.com/daksh"]) { _, _ in
            XCTFail("exact snippet match must not reach the LLM")
            return "cleaned"
        }
        let result = await p.clean(transcript: "cal one")
        XCTAssertEqual(result.text, "https://cal.com/daksh")
        XCTAssertNil(result.failure)
    }

    // ASR punctuates and capitalizes as it pleases; the trigger must survive that.
    func testExactSnippetMatchIgnoresCaseAndPunctuation() async {
        let p = makePipeline(transcript: "cal one",
                             snippets: ["cal one": "URL"]) { _, _ in
            XCTFail("exact snippet match must not reach the LLM")
            return "cleaned"
        }
        for spoken in ["Cal one.", "CAL ONE!", "  cal, one  ", "Cal One?"] {
            let result = await p.clean(transcript: spoken)
            XCTAssertEqual(result.text, "URL", spoken)
        }
    }

    // Anything the trigger doesn't cover whole goes to the LLM as before —
    // embedded triggers are the prompt block's job, not the fast path's.
    func testNearMissDoesNotFastPath() async {
        let p = makePipeline(transcript: "x",
                             snippets: ["cal one": "URL"]) { t, _ in "cleaned:" + t }
        for spoken in ["send cal one", "cal one please", "cal two", "calone"] {
            let result = await p.clean(transcript: spoken)
            XCTAssertEqual(result.text, "cleaned:" + spoken, spoken)
        }
    }

    func testRepeatedSnippetExpansionsRaiseAllowancePerOccurrence() async {
        let expansion = String(repeating: "x", count: 260)
        let cleaned = expansion + expansion
        let p = makePipeline(transcript: "cal one and cal one",
                             snippets: ["cal one": expansion]) { _, _ in cleaned }
        let result = await p.clean(transcript: "cal one and cal one")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.text, cleaned)
    }

    func testUnusedSnippetDoesNotRaiseAllowance() async {
        let expansion = String(repeating: "x", count: 630)
        let p = makePipeline(transcript: "hello", // base allowance 2*5 + 200 = 210
                             snippets: ["cal one": expansion]) { _, _ in expansion }
        let result = await p.clean(transcript: "hello")
        XCTAssertEqual(result.text, "hello")
        XCTAssertNotNil(result.failure)
    }

    // A bare quote pair sanitizes to nothing — success with empty text would
    // pass swapPlan's non-empty check upstream, so it must report failure here.
    func testSanitizedToEmptyFallsBackToRaw() async {
        let p = makePipeline(transcript: "raw words") { _, _ in "\"\"" }
        let result = await p.clean(transcript: "raw words")
        XCTAssertEqual(result.text, "raw words")
        XCTAssertEqual(result.failure, "cleanup returned no text")
    }
}
