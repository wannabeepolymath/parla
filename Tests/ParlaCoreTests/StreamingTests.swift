import XCTest
@testable import ParlaCore

final class StreamingTests: XCTestCase {
    // MARK: quietestCut

    func testCutLandsInSilentGap() {
        // 2s of loud signal with a 100ms silent gap at 0.8s.
        var samples = [Float](repeating: 0.5, count: 32_000)
        let gap = 12_800 ..< 14_400
        for i in gap { samples[i] = 0 }
        let cut = StreamWindow.quietestCut(samples: samples, near: 12_000,
                                           radius: 8_000, window: 1_600)
        XCTAssertTrue(gap.contains(cut), "cut \(cut) not inside the silent gap \(gap)")
    }

    func testCutStaysWithinSearchRange() {
        let samples = [Float](repeating: 0.3, count: 32_000)
        let cut = StreamWindow.quietestCut(samples: samples, near: 16_000,
                                           radius: 4_000, window: 1_600)
        XCTAssertTrue((12_000...20_000).contains(cut))
    }

    func testCutFallsBackWhenNoRoomToSearch() {
        // Not enough samples to fit a window → target clamped.
        XCTAssertEqual(StreamWindow.quietestCut(samples: [], near: 100), 0)
        XCTAssertEqual(StreamWindow.quietestCut(samples: [Float](repeating: 0.1, count: 500),
                                                near: 100_000),
                       500)
    }

    func testCutNeverExceedsSampleCount() {
        let samples = [Float](repeating: 0.2, count: 20_000)
        let cut = StreamWindow.quietestCut(samples: samples, near: 19_000,
                                           radius: 4_000, window: 1_600)
        XCTAssertTrue(cut > 0 && cut <= samples.count)
    }

    // MARK: tailPrompt

    func testTailPromptEmptyIsNil() {
        XCTAssertNil(StreamWindow.tailPrompt(dictionary: [], confirmed: ""))
    }

    func testTailPromptDictionaryOnly() {
        XCTAssertEqual(StreamWindow.tailPrompt(dictionary: ["Kubernetes", "Daksh"], confirmed: ""),
                       "Kubernetes, Daksh")
    }

    func testTailPromptTruncatesConfirmedContext() {
        let confirmed = String(repeating: "a", count: 300)
        let p = StreamWindow.tailPrompt(dictionary: ["K8s"], confirmed: confirmed)!
        XCTAssertEqual(p, "K8s " + String(repeating: "a", count: 200))
    }

    func testTailPromptReservesContextTokensWithABudget() {
        let budget = PromptBudget(capacity: 20, count: { $0.utf8.count })
        XCTAssertEqual(StreamWindow.tailPrompt(dictionary: ["alpha", "beta"], confirmed: "hello world",
                                               budget: budget, reserve: 8), "alpha, beta lo world")
    }

    func testTailPromptGivesUnusedReserveToTheDictionary() {
        let budget = PromptBudget(capacity: 18, count: { $0.utf8.count })
        // "alpha, beta, gamma" is 18: the whole capacity, nothing held back for context.
        XCTAssertEqual(StreamWindow.tailPrompt(dictionary: ["alpha", "beta", "gamma"], confirmed: "",
                                               budget: budget, reserve: 8), "alpha, beta, gamma")
    }

    // MARK: join

    func testJoin() {
        XCTAssertEqual(StreamWindow.join("a", "b"), "a b")
        XCTAssertEqual(StreamWindow.join("", "b"), "b")
        XCTAssertEqual(StreamWindow.join("a", ""), "a")
        XCTAssertEqual(StreamWindow.join("", ""), "")
    }
}
