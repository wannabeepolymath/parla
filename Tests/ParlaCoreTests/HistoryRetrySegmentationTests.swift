import XCTest
@testable import ParlaCore

final class HistoryRetrySegmentationTests: XCTestCase {
    private func source(_ text: String) -> HistoryEntry { HistoryEntry(raw: text, cleaned: "Previous result") }
    private var long: String { String(repeating: "Tuesday no Wednesday not Thursday 15 50 userID != nil. ", count: 130) }
    func testUnicodeSeparatorsReconstructExactly() throws {
        for text in [long, "\r\n " + long + "\r\n\r\n" + long + " \t\n", String(repeating: "हिन्दी e\u{301} 👩🏽‍💻 🇮🇳\u{a0}", count: 350)] {
            let plan = try HistoryRetrySegmentPlan(original: text)
            XCTAssertEqual(plan.reconstructed(), text)
            XCTAssertEqual(Array(plan.reconstructed().utf8), Array(text.utf8))
            XCTAssertTrue((2...16).contains(plan.segments.count))
            for s in plan.segments { XCTAssertLessThanOrEqual(text[s.content].utf8.count, 4096); XCTAssertFalse(text[s.content].isEmpty) }
        }
    }
    func testParagraphPreferenceAndWhitespaceRunRemainExact() throws {
        let text = String(repeating: "word ", count: 450) + "\r\n\r\n" + String(repeating: "tail ", count: 650)
        let plan = try HistoryRetrySegmentPlan(original: text)
        XCTAssertTrue(String(text[plan.segments[0].separator]).contains("\r\n\r\n"))
        XCTAssertEqual(plan.reconstructed(), text)
        let whitespace = String(repeating: "word ", count: 850) + String(repeating: "\t", count: 10_000) + "last words"
        XCTAssertEqual(try HistoryRetrySegmentPlan(original: whitespace).reconstructed(), whitespace)
    }
    func testSingleCRLFIsNotAParagraphAndPunctuationWinsLater() throws {
        let text = String(repeating: "a", count: 2050) + "\r\n" + String(repeating: "word ", count: 200) + "end. " + String(repeating: "tail ", count: 500)
        let plan = try HistoryRetrySegmentPlan(original: text)
        let first = String(text[plan.segments[0].content])
        XCTAssertTrue(first.hasSuffix("end."))
        XCTAssertEqual(plan.reconstructed(), text)
    }

    func testFiniteByteTokenGraphemeAndCountRefusals() {
        for text in ["", "   \r\n", "one request", String(repeating: "界", count: 1400), String(repeating: "a", count: 4097), "a" + String(repeating: "\u{301}", count: 4096), String(repeating: "word ", count: 13_108)] {
            XCTAssertThrowsError(try HistoryRetrySegmentPlan(original: text), text.prefix(30).description)
        }
        XCTAssertNoThrow(try HistoryRetrySegmentPlan(original: String(repeating: "a", count: 4096) + " " + String(repeating: "b", count: 100)))
    }
    func testNonsecretPrepareWholeSnippetAndRuleBounds() throws {
        var settings = Settings(); settings.snippets = [long: "exact locked"]
        let request = try HistoryRetryRequest(segmentedSettings: settings, source: source(long), version: UUID())
        XCTAssertTrue(request.isSegmented); XCTAssertEqual(request.plannedSegments, 0)
        settings.snippets = ["Tuesday": "Wednesday"]
        XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: settings, source: source(long), version: UUID()))
        settings.snippets = [:]; settings.dictionary = Array(repeating: "hint", count: 257)
        XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: settings, source: source(long), version: UUID()))
        settings.dictionary = [String(repeating: "x", count: 65_537)]
        XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: settings, source: source(long), version: UUID()))
    }
    func testSharedGuardsAndLiteralWriterUseOnceOnlyPolicy() throws {
        let source = String(repeating: "a", count: 80)
        XCTAssertNil(CleanupOutput.validationFailure(String(repeating: "b", count: 16), source: source))
        XCTAssertNotNil(CleanupOutput.validationFailure(String(repeating: "b", count: 15), source: source))
        XCTAssertNil(CleanupOutput.validationFailure(String(repeating: "b", count: 360), source: source))
        XCTAssertNotNil(CleanupOutput.validationFailure(String(repeating: "b", count: 361), source: source))
        let rules = [LiteralReplacement(source: "A", replacement: "B"), LiteralReplacement(source: "B", replacement: "C"), LiteralReplacement(source: "across\r\nline", replacement: "joined")]
        XCTAssertEqual(try LiteralReplacement.boundedApply(rules, to: "A B across\r\nline", maximumBytes: 10), "B C joined")
        XCTAssertThrowsError(try LiteralReplacement.boundedApply(rules, to: "A B across\r\nline", maximumBytes: 9))
        XCTAssertEqual(try LiteralReplacement.boundedApply(rules, to: "अA A_A e\u{301}A", maximumBytes: 100), "अA A_A e\u{301}A")
    }
    func testDeadlineEqualityAttemptsUsageAndPayloadChecked() throws {
        var clock: TimeInterval = 10
        let p = HistoryRetryExecutionPolicy(planned: 2, now: { clock })
        XCTAssertEqual(try p.remaining(), 15)
        try p.attempt(); p.recordUsage(model: "one", input: 3, output: 4); p.completed()
        clock = 68; XCTAssertEqual(try p.remaining(), 2)
        try p.attempt(); p.recordUsage(model: "two", input: nil, output: -1)
        XCTAssertNil(p.metrics().promptTokens); XCTAssertNil(p.metrics().completionTokens)
        let partial = p.finish(.provider)
        XCTAssertEqual(partial.attempts?.count, 2); XCTAssertEqual(partial.attempts?.first?.inputTokens, 3)
        XCTAssertNil(partial.inputTokens); XCTAssertNil(partial.outputTokens); XCTAssertEqual(partial.usage, .mixed)
        XCTAssertTrue(p.metrics().cleanupModel!.contains("Mixed"))
        XCTAssertThrowsError(try p.attempt())
        try p.reserve(1024 * 1024); XCTAssertThrowsError(try p.reserve(1)); p.release(1024 * 1024)
        clock = 70; XCTAssertThrowsError(try p.check())
        XCTAssertEqual(p.finish().terminal, .deadline)
    }
    func testOldProvenanceJSONMeansWholeAndNoExperimentalDiagnosticContent() throws {
        let request = try HistoryRetryRequest(settings: Settings(), environment: [:], source: source("Original"), applyPreset: false, credentials: testCredentialStore())
        let provenance = HistoryRetryProvenance(date: Date(), configuration: request.configuration, usage: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance)) as? [String: Any])
        var config = try XCTUnwrap(object["configuration"] as? [String: Any]); config.removeValue(forKey: "mode"); object["configuration"] = config; object.removeValue(forKey: "segmented")
        let decoded = try JSONDecoder().decode(HistoryRetryProvenance.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.configuration.retryMode, .whole); XCTAssertNil(decoded.segmented)
    }
}

extension HistoryRetrySegmentationTests {
    func testModeBindingInvalidModelsSourceAndExactRuleLimits() throws {
        var s = Settings(); s.cleanup.provider = "openai-compatible"; s.cleanup.baseURL = "https://example.test/v1"; s.cleanup.model = "named"
        let entry = source(long), version = UUID()
        let a = try HistoryRetryRequest(segmentedSettings: s, source: entry, version: version)
        let b = try HistoryRetryRequest(segmentedSettings: s, source: entry, version: version)
        XCTAssertTrue(a.sameExperimentalRequest(as: a)); XCTAssertFalse(a.sameExperimentalRequest(as: b))
        for model in ["", "   ", String(repeating: "x", count: 161)] {
            s.cleanup.model = model
            XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: s, source: entry, version: version))
        }
        s.cleanup.model = "named"
        for url in ["ftp://host", "https://user:pass@host", "https://host/path?secret=query", "https://host/#fragment"] {
            s.cleanup.baseURL = url
            XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: s, source: entry, version: version))
        }
        s.cleanupEnabled = false
        for text in ["", " \r\n\t", String(repeating: "x", count: 64 * 1024 + 1)] {
            XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: s, source: source(text), version: version))
        }
        let previous = HistoryEntry(raw: "Original", cleaned: String(repeating: "x", count: 128 * 1024 + 1))
        XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: s, source: previous, version: version))
        s.dictionary = [String(repeating: "x", count: 64 * 1024)]
        XCTAssertNoThrow(try HistoryRetryRequest(segmentedSettings: s, source: source("Original"), version: version))
        s.dictionary[0] += "x"
        XCTAssertThrowsError(try HistoryRetryRequest(segmentedSettings: s, source: source("Original"), version: version))
        let usage = HistoryRetryExecutionPolicy(planned: 2)
        try usage.attempt(); usage.recordUsage(model: "m", input: Int.max, output: 0)
        try usage.attempt(); usage.recordUsage(model: "m", input: 1, output: nil)
        XCTAssertNil(usage.metrics().promptTokens); XCTAssertNil(usage.metrics().completionTokens)
    }
}


extension HistoryRetrySegmentationTests {
    func testB21ExplicitBudgetKeepsB30SixtySecondDefault() throws {
        var time = 0.0
        let legacy = HistoryRetryExecutionPolicy(planned:2,now:{time})
        let ordinary = HistoryRetryExecutionPolicy(planned:2,budget:15,now:{time})
        time = 15; try legacy.check(); XCTAssertThrowsError(try ordinary.check())
        time = 59.999; try legacy.check(); time = 60; XCTAssertThrowsError(try legacy.check())
        let count = HistoryRetryExecutionPolicy(planned:2);try count.attempt();try count.attempt();XCTAssertThrowsError(try count.attempt())
        try count.reserve(1024*1024);XCTAssertThrowsError(try count.reserve(1));count.release(1024*1024)
    }
}


extension HistoryRetrySegmentationTests {
    func testB21JoinedWatchdogActuallyExitsEvenWhenSleepIgnoresCancellation() async throws {
        let entered=expectation(description:"watchdog entered"),canceled=expectation(description:"watchdog cancellation requested")
        let release=RecognitionTestLatch(),lock=NSLock();var returned=false
        let policy=HistoryRetryExecutionPolicy(planned:1,budget:15,now:{0},sleep:{_ in
            await withTaskCancellationHandler(operation:{entered.fulfill();await release.wait()},onCancel:{canceled.fulfill()})
        })
        let task=Task{defer{lock.withLock{returned=true}};return try await policy.joined{"value"}}
        await fulfillment(of:[entered,canceled],timeout:3);XCTAssertFalse(lock.withLock{returned})
        release.signal();let value=try await task.value;XCTAssertEqual(value,"value");XCTAssertTrue(lock.withLock{returned})
    }
}
