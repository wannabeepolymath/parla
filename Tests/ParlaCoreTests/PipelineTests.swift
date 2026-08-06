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
        let p = makePipeline(transcript: "cal one", // base allowance 2*7 + 200 = 214
                             snippets: ["cal one": expansion]) { _, _ in expansion }
        let result = await p.clean(transcript: "cal one")
        XCTAssertNil(result.failure) // 630 > 214, but ≤ 214 + 630
        XCTAssertEqual(result.text, expansion)
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

    // The ceiling only catches runaway expansion. A model that ANSWERS or
    // summarises the transcript comes back far shorter, and that was typed
    // straight over the user's words.
    func testDrasticallyShorterOutputFallsBackToRaw() async {
        let raw = String(repeating: "word ", count: 30) // 150 chars
        let p = makePipeline(transcript: raw) { _, _ in "Sure!" }
        let result = await p.clean(transcript: raw)
        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.failure, "cleanup returned truncated text")
    }

    // Heavy but legitimate filler removal must NOT trip the floor — this is the
    // exact case cleanup exists for.
    func testHeavyFillerRemovalSurvivesTheFloor() async {
        let raw = "um so like you know the thing is basically that I think we should "
            + "probably just go ahead and ship it on friday I guess"  // 129 chars
        let cleaned = "We should ship it on Friday."                    // 28 chars, 21%
        let p = makePipeline(transcript: raw) { _, _ in cleaned }
        let result = await p.clean(transcript: raw)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.text, cleaned)
    }

    // Short utterances shrink by large ratios all the time ("um, yeah" -> "Yeah.")
    // so the floor deliberately does not apply to them.
    func testShortTranscriptExemptFromFloor() async {
        let p = makePipeline(transcript: "um yeah ok sure") { _, _ in "OK." }
        let result = await p.clean(transcript: "um yeah ok sure")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.text, "OK.")
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
