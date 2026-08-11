import XCTest
@testable import ParlaCore

final class HistoryTests: XCTestCase {
    func tempStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return HistoryStore(url: dir.appendingPathComponent("history.json"))
    }

    func testAppendNewestFirst() {
        let store = tempStore()
        store.append(HistoryEntry(raw: "one"))
        store.append(HistoryEntry(raw: "two"))
        XCTAssertEqual(store.entries.map(\.raw), ["two", "one"])
    }

    func testCapDropsOldest() {
        let store = tempStore()
        for i in 0..<(HistoryStore.cap + 5) { store.append(HistoryEntry(raw: "\(i)")) }
        XCTAssertEqual(store.entries.count, HistoryStore.cap)
        XCTAssertEqual(store.entries.first?.raw, "\(HistoryStore.cap + 4)") // newest kept
        XCTAssertEqual(store.entries.last?.raw, "5")                        // oldest 0..4 dropped
    }

    func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let a = HistoryStore(url: url)
        a.append(HistoryEntry(raw: "raw text", cleaned: "cleaned text", appName: "TextEdit"))
        let b = HistoryStore(url: url) // reload from disk
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.entries.first?.raw, "raw text")
        XCTAssertEqual(b.entries.first?.cleaned, "cleaned text")
        XCTAssertEqual(b.entries.first?.appName, "TextEdit")
    }

    func testClear() {
        let store = tempStore()
        store.append(HistoryEntry(raw: "x"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(HistoryStore(url: store.url).entries.isEmpty) // persisted
    }

    func testBestPrefersCleaned() {
        XCTAssertEqual(HistoryEntry(raw: "r", cleaned: "c").best, "c")
        XCTAssertEqual(HistoryEntry(raw: "r").best, "r") // nil cleaned falls back to raw
    }

    func testHistoryEnabledDefaultTrue() {
        XCTAssertTrue(Settings().historyEnabled)
    }

    // MARK: - Pipeline metrics

    func testMetricsRoundTripAndOldFileStillDecodes() throws {
        var m = PipelineMetrics()
        m.captureMs = 1200
        m.cleanupModel = "claude-haiku-4-5"
        m.promptTokens = 400
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let a = HistoryStore(url: url)
        a.append(HistoryEntry(raw: "r", metrics: m))
        XCTAssertEqual(HistoryStore(url: url).entries.first?.metrics, m)

        // A file written before metrics existed, and a half-written metrics blob.
        let old = #"[{"date":770000000,"raw":"old"}, {"date":770000001,"raw":"partial","metrics":{"asrMs":7}}]"#
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].metrics)
        XCTAssertEqual(decoded[1].metrics?.asrMs, 7)
        XCTAssertNil(decoded[1].metrics?.totalMs)
    }

    func testMetricsCollectorDerivesSegmentsFromStamps() {
        let metrics = Metrics()
        XCTAssertNil(metrics.snapshot()) // nothing known ⇒ nothing written
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        metrics.mark(.fnDown, at: ms(1000))
        metrics.mark(.fnUp, at: ms(3000))
        metrics.mark(.finalPassDone, at: ms(3400))
        metrics.mark(.landed, at: ms(3450))
        metrics.mark(.cleanedSwapped, at: ms(4200))
        metrics.update { $0.promptTokens = 360 }
        let m = metrics.snapshot()
        XCTAssertEqual(m?.captureMs, 2000)
        XCTAssertEqual(m?.asrMs, 400)
        XCTAssertEqual(m?.insertMs, 50)
        XCTAssertEqual(m?.cleanupMs, 750)
        XCTAssertEqual(m?.totalMs, 3200)
        XCTAssertEqual(m?.promptTokens, 360)
        // fn-down starts a fresh dictation; nothing leaks into the next one.
        metrics.mark(.fnDown, at: ms(9000))
        XCTAssertNil(metrics.snapshot())
    }

    func testPricingLongestPrefixWinsAndUnknownIsUnpriced() {
        // 400 in + 130 out on Haiku 4.5 ($1/$5 per MTok).
        XCTAssertEqual(CleanupPricing.usd(model: "claude-haiku-4-5-20251001",
                                          promptTokens: 400, completionTokens: 130)!,
                       0.00105, accuracy: 1e-9)
        // flash-lite must not bill at flash rates.
        XCTAssertEqual(CleanupPricing.usd(model: "gemini-2.5-flash-lite",
                                          promptTokens: 1_000_000, completionTokens: 0)!,
                       0.10, accuracy: 1e-9)
        XCTAssertNil(CleanupPricing.usd(model: "llama3.2", promptTokens: 500, completionTokens: 500))
    }

    func testCostEstimateCountsUnpricedSeparatelyAndProjects() {
        let now = Date()
        let entries = [
            entry(now.addingTimeInterval(-3600), model: "claude-haiku-4-5", prompt: 1_000_000, completion: 0),
            entry(now.addingTimeInterval(-7200), model: "qwen3-local", prompt: 900, completion: 900),
            HistoryEntry(date: now, raw: "no metrics at all"),
        ]
        let est = CleanupCostEstimate.over(entries, now: now)!
        XCTAssertEqual(est.usd, 1.0, accuracy: 1e-9)   // the local model adds nothing
        XCTAssertEqual(est.dictations, 2)
        XCTAssertEqual(est.unpriced, 1)
        XCTAssertEqual(est.since, now.addingTimeInterval(-7200))
        XCTAssertEqual(est.monthlyUSD!, 360, accuracy: 1e-6) // $1 per 2h → 30 days
        XCTAssertNil(CleanupCostEstimate.over([HistoryEntry(raw: "x")]))
        // Under an hour of span, a projection would be noise, not a forecast.
        XCTAssertNil(CleanupCostEstimate.over(
            [entry(now.addingTimeInterval(-60), model: "claude-haiku-4-5", prompt: 100, completion: 100)],
            now: now)!.monthlyUSD)
    }

    private func entry(_ date: Date, model: String, prompt: Int, completion: Int) -> HistoryEntry {
        var m = PipelineMetrics()
        m.cleanupModel = model
        m.promptTokens = prompt
        m.completionTokens = completion
        return HistoryEntry(date: date, raw: "r", metrics: m)
    }

    func testHistoryEnabledTolerantDecode() throws {
        // Missing key ⇒ default true; present ⇒ honored; partial file ⇒ no reset.
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertTrue(missing.historyEnabled)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"historyEnabled":false}"#.utf8))
        XCTAssertFalse(off.historyEnabled)
    }
}
