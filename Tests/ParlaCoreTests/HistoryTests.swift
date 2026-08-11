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

    /// The cleanup POST goes out after the text lands, so the user can start the
    /// next dictation while it is still in flight. Its tokens must be billed to
    /// the dictation that paid for them, and must not follow the new one.
    func testLatePolishLandsOnItsOwnDictationNotTheNewOne() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        // Dictation 1 reaches the landing; its cleanup POST is still out.
        metrics.mark(.fnDown, at: ms(1000))
        metrics.mark(.fnUp, at: ms(3000))
        metrics.mark(.finalPassDone, at: ms(3400))
        metrics.mark(.landed, at: ms(3450))
        metrics.update { $0.model = "small.en" }

        // The user starts dictation 2 before that POST comes back.
        metrics.mark(.fnDown, at: ms(5000))
        metrics.mark(.fnUp, at: ms(6000))

        // Dictation 1's cleanup finally resolves and its entry is written.
        metrics.update { $0.cleanupModel = "claude-haiku-4-5"; $0.promptTokens = 400 }
        metrics.mark(.cleanedSwapped, at: ms(6200))
        let first = metrics.snapshot()
        XCTAssertEqual(first?.captureMs, 2000)  // 1's own fn-down→fn-up, not 2's
        XCTAssertEqual(first?.insertMs, 50)
        XCTAssertEqual(first?.cleanupMs, 2750)  // landed 3450 → swapped 6200
        XCTAssertEqual(first?.model, "small.en")
        XCTAssertEqual(first?.promptTokens, 400)

        // Dictation 2 kept its own stamps and never saw 1's tokens.
        metrics.mark(.finalPassDone, at: ms(6400))
        metrics.mark(.landed, at: ms(6450))
        metrics.mark(.cleanedSwapped, at: ms(6800))
        let second = metrics.snapshot()
        XCTAssertEqual(second?.captureMs, 1000) // 5000 → 6000
        XCTAssertEqual(second?.cleanupMs, 350)  // 6450 → 6800, not 1's swap
        XCTAssertNil(second?.promptTokens)
        XCTAssertNil(second?.cleanupModel)
        XCTAssertNil(second?.model)
    }

    /// History off: no row is ever written, so `awaitingHistory` stays true even
    /// for a dictation whose polish already came back. Parking on that alone
    /// hands its numbers to whatever row is written next — and then that one's
    /// to the row after it, permanently one behind. A resolved dictation is owed
    /// nothing and must never park.
    func testResolvedDictationDoesNotParkWhenNoHistoryRowIsWritten() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }

        // Dictation 1 runs to completion. History is off, so no snapshot() call
        // ever follows — nothing marks the bucket as recorded.
        metrics.mark(.fnDown, at: ms(1000))
        metrics.mark(.fnUp, at: ms(3000))
        metrics.mark(.landed, at: ms(3100))
        metrics.update { $0.model = "d1-model"; $0.promptTokens = 111 }
        metrics.mark(.cleanedSwapped, at: ms(3500))

        // The user turns history back on and dictates again.
        metrics.mark(.fnDown, at: ms(9000))
        metrics.mark(.fnUp, at: ms(10_000))
        metrics.mark(.landed, at: ms(10_100))
        metrics.update { $0.model = "d2-model"; $0.promptTokens = 222 }
        metrics.mark(.cleanedSwapped, at: ms(10_400))

        // Dictation 2's row must be dictation 2's.
        let second = metrics.snapshot()
        XCTAssertEqual(second?.captureMs, 1000)   // 9000 → 10000, not 1's 2000
        XCTAssertEqual(second?.model, "d2-model")
        XCTAssertEqual(second?.promptTokens, 222)
    }

    /// Cleanup unconfigured: the entry is written straight after landing, so
    /// nothing is in flight and the next dictation must own the collector
    /// outright — the park is for pending polish only.
    func testNoPolishDictationIsNotParkedForTheNextOne() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        metrics.mark(.fnDown, at: ms(1000))
        metrics.mark(.fnUp, at: ms(2000))
        metrics.mark(.landed, at: ms(2100))
        XCTAssertEqual(metrics.snapshot()?.captureMs, 1000)

        metrics.mark(.fnDown, at: ms(4000))
        metrics.mark(.fnUp, at: ms(4500))
        metrics.update { $0.model = "small.en" }
        let m = metrics.snapshot()
        XCTAssertEqual(m?.captureMs, 500)
        XCTAssertEqual(m?.model, "small.en")
    }

    /// The dictation that writes history while a park is outstanding is the LIVE
    /// one (dictation 2 here has no polish of its own, so it writes at landing).
    /// The park belongs to dictation 1 and is claimed only by dictation 1's own
    /// write, which the `.cleanedSwapped` stamp immediately precedes.
    func testParkIsClaimedByItsOwnWriteNotTheNextDictationsWrite() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        // Dictation 1 lands; its cleanup POST is still out.
        metrics.mark(.fnDown, at: ms(1000))
        metrics.mark(.fnUp, at: ms(3000))
        metrics.mark(.landed, at: ms(3450))
        metrics.update { $0.model = "small.en" }

        // Dictation 2 runs with cleanup off, so its row is written before 1's
        // polish comes back.
        metrics.mark(.fnDown, at: ms(5000))
        metrics.mark(.fnUp, at: ms(6000))
        metrics.mark(.landed, at: ms(6100))
        let second = metrics.snapshot()
        XCTAssertEqual(second?.captureMs, 1000) // 2's own 5000 → 6000, not 1's 2000
        XCTAssertNil(second?.model)             // 1's whisper model stays with 1

        // Dictation 1's polish finally resolves and its row is written.
        metrics.update { $0.cleanupModel = "claude-haiku-4-5"; $0.promptTokens = 400 }
        metrics.mark(.cleanedSwapped, at: ms(7000))
        let first = metrics.snapshot()
        XCTAssertEqual(first?.captureMs, 2000)  // still 1's own capture
        XCTAssertEqual(first?.cleanupMs, 3550)  // landed 3450 → swapped 7000
        XCTAssertEqual(first?.model, "small.en")
        XCTAssertEqual(first?.promptTokens, 400)
    }

    /// A polish that never comes back must not leave the park sitting there
    /// swallowing every later dictation's tokens and stamps.
    func testUnresolvedParkDoesNotOutliveTheNextDictation() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        metrics.mark(.fnDown, at: ms(1000))     // dictation 1: polish never returns
        metrics.mark(.fnUp, at: ms(2000))
        metrics.mark(.landed, at: ms(2100))

        metrics.mark(.fnDown, at: ms(4000))     // parks 1
        metrics.mark(.fnUp, at: ms(4500))
        metrics.mark(.landed, at: ms(4600))
        XCTAssertEqual(metrics.snapshot()?.captureMs, 500)

        metrics.mark(.fnDown, at: ms(7000))     // 1 is an orphan by now — drop it
        metrics.mark(.fnUp, at: ms(8000))
        metrics.update { $0.promptTokens = 111 }
        metrics.mark(.landed, at: ms(8100))
        metrics.mark(.cleanedSwapped, at: ms(8300))
        let third = metrics.snapshot()
        XCTAssertEqual(third?.captureMs, 1000)      // 7000 → 8000
        XCTAssertEqual(third?.cleanupMs, 200)       // its own swap, not the orphan's
        XCTAssertEqual(third?.promptTokens, 111)    // billed here, not to the orphan
    }

    /// The interleaving a "replace the park on every fn-down" rule destroys:
    /// dictation 2 is cancelled (Esc, or a short tap) while dictation 1's polish
    /// is still out. A cancel never lands, so it proves nothing about 1's POST —
    /// evicting the park on dictation 3's fn-down bills 1's swap and tokens to 3.
    func testCancelledDictationDoesNotEvictAParkWhosePolishIsStillOut() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        // Dictation 1 lands; its cleanup POST is still out.
        metrics.mark(.fnDown, at: ms(1000))
        metrics.mark(.fnUp, at: ms(3000))
        metrics.mark(.landed, at: ms(3450))
        metrics.update { $0.model = "small.en" }

        // Dictation 2 starts (parking 1) and is cancelled: no fn-up, no landing,
        // no history row — nothing that says anything about 1.
        metrics.mark(.fnDown, at: ms(5000))
        // Dictation 3 starts while 1's POST is *still* out.
        metrics.mark(.fnDown, at: ms(6000))
        metrics.mark(.fnUp, at: ms(7000))

        // 1's polish finally resolves and 1's row is written.
        metrics.update { $0.cleanupModel = "claude-haiku-4-5"; $0.promptTokens = 400 }
        metrics.mark(.cleanedSwapped, at: ms(7200))
        let first = metrics.snapshot()
        XCTAssertEqual(first?.captureMs, 2000)  // 1's own fn-down→fn-up, not 3's
        XCTAssertEqual(first?.cleanupMs, 3750)  // landed 3450 → swapped 7200
        XCTAssertEqual(first?.model, "small.en")
        XCTAssertEqual(first?.promptTokens, 400)

        // Dictation 3 kept its own stamps and was billed none of 1's numbers.
        metrics.mark(.landed, at: ms(7400))
        metrics.mark(.cleanedSwapped, at: ms(7600))
        let third = metrics.snapshot()
        XCTAssertEqual(third?.captureMs, 1000)  // 6000 → 7000
        XCTAssertEqual(third?.cleanupMs, 200)   // 7400 → 7600, not 1's swap
        XCTAssertNil(third?.promptTokens)
        XCTAssertNil(third?.cleanupModel)
    }

    /// The other half of the rule: a park whose swap already came back is owed
    /// nothing even when the dictations after it never land (here one that heard
    /// no transcript). Its own write never claimed it because history was off
    /// when it swapped, so it must be dropped rather than handed to a later row.
    func testResolvedParkIsNotClaimedByALaterDictationsRow() {
        let metrics = Metrics()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        metrics.mark(.fnDown, at: ms(1000))         // dictation 1, history off
        metrics.mark(.fnUp, at: ms(2500))
        metrics.mark(.landed, at: ms(2600))         // …so no row is ever written

        metrics.mark(.fnDown, at: ms(4000))         // parks 1
        metrics.update { $0.promptTokens = 400 }
        metrics.mark(.cleanedSwapped, at: ms(4200)) // 1's polish is back, unclaimed
        metrics.mark(.fnUp, at: ms(4500))           // dictation 2: silence…
        metrics.mark(.finalPassDone, at: ms(4600))  // …no transcript, never lands

        metrics.mark(.fnDown, at: ms(7000))         // dictation 3, history back on
        metrics.mark(.fnUp, at: ms(8000))
        metrics.mark(.landed, at: ms(8100))
        let third = metrics.snapshot()
        XCTAssertEqual(third?.captureMs, 1000)      // 7000 → 8000, not 1's 1500
        XCTAssertNil(third?.promptTokens)           // 1's tokens stayed with 1
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
