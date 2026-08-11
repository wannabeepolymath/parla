import XCTest
@testable import ParlaCore

/// The whole point of this file is the REJECTIONS. A missed correction costs one
/// dictation; a learned wrong one is injected into whisper's initial_prompt and
/// the cleanup prompt of every future dictation. Each test below is a way that
/// could happen, and none of them may.
final class DictionaryLearnerTests: XCTestCase {

    // The one shape that is allowed through, used as the base for the rejections
    // so each of them differs from an accept by exactly the thing under test.
    let typed = "Meeting with Shunade tomorrow"

    func propose(inserted: String? = nil, before: String? = nil, after: String,
                 dictionary: [String] = []) -> DictionaryLearner.Proposal? {
        DictionaryLearner.propose(inserted: inserted ?? typed, before: before ?? typed,
                                  after: after, dictionary: dictionary)
    }

    // MARK: - The single legitimate accept

    func testPhoneticCorrectionIsProposed() {
        let p = propose(after: "Meeting with Sinead tomorrow")
        XCTAssertEqual(p?.from, "Shunade")
        XCTAssertEqual(p?.to, "Sinead")
    }

    func testProposalSurvivesSurroundingPunctuation() {
        let p = DictionaryLearner.propose(inserted: "I met Shunade, twice",
                                          before: "I met Shunade, twice",
                                          after: "I met Sinead, twice", dictionary: [])
        XCTAssertEqual(p?.to, "Sinead") // the comma is not part of the entry
    }

    func testCorrectionInsideALongerFieldIsProposed() {
        // Pre-existing text the user wrote earlier surrounds Parla's insertion.
        let p = DictionaryLearner.propose(
            inserted: typed,
            before: "Notes from today. \(typed). More notes.",
            after: "Notes from today. Meeting with Sinead tomorrow. More notes.",
            dictionary: [])
        XCTAssertEqual(p?.to, "Sinead")
    }

    // MARK: - Multi-token and rewrite edits

    func testTwoWordsChangedIsRejected() {
        XCTAssertNil(propose(after: "Meeting with Sinead today"))
    }

    func testWholeFieldRewriteIsRejected() {
        XCTAssertNil(propose(after: "Lunch about Sinead instead"))
    }

    func testWordInsertedIsRejected() {
        XCTAssertNil(propose(after: "Meeting with Sinead O'Connor tomorrow"))
    }

    func testWordDeletedIsRejected() {
        XCTAssertNil(propose(after: "Meeting with tomorrow"))
    }

    func testFieldClearedIsRejected() {
        XCTAssertNil(propose(after: ""))
    }

    func testAppendedTextIsRejected() {
        // Continuing to dictate/type after the insertion is not a correction.
        XCTAssertNil(propose(after: "\(typed) at noon"))
    }

    // MARK: - Distance: replacing a word is not correcting it

    func testUnrelatedReplacementIsRejected() {
        XCTAssertNil(propose(after: "Meeting with everyone tomorrow"))
    }

    func testDistantWordIsRejectedEvenWhenShapeMatches() {
        // Same length, single substitution — only the edit distance says no.
        XCTAssertNil(propose(after: "Meeting with Bourbons tomorrow"))
    }

    func testDistanceRatioBoundary() {
        // "Shunade" → "Sinead" is 4 edits over 7 chars = 0.57, the phonetic case
        // the 0.65 ratio exists to admit. Guard the constant itself.
        let d = Eval.editDistance("shunade".map { String($0) }, "sinead".map { String($0) })
        XCTAssertEqual(d, 4)
        XCTAssertLessThanOrEqual(Double(d), DictionaryLearner.maxDistanceRatio * 7)

        // The other edge, and the one that costs something to get wrong: 4 edits
        // over 6 chars is 0.67, just past the ratio, and must not propose. The
        // accept above only fails if someone *tightens* the constant — a missed
        // correction. This fails if they widen it, which is how a word Parla never
        // misheard gets into every future prompt. Together they pin the window.
        XCTAssertEqual(Eval.editDistance("marina".map { String($0) },
                                         "maxwel".map { String($0) }), 4)
        XCTAssertNil(DictionaryLearner.propose(inserted: "Meeting with Marina tomorrow",
                                               before: "Meeting with Marina tomorrow",
                                               after: "Meeting with Maxwel tomorrow",
                                               dictionary: []))
    }

    // MARK: - Edits Parla did not cause

    func testCorrectionToTextParlaDidNotTypeIsRejected() {
        // Parla inserted only the last word; the user fixed a typo in their own
        // earlier sentence that happens to share the field.
        XCTAssertNil(DictionaryLearner.propose(
            inserted: "tomorrow",
            before: "Meeting with Shunade tomorrow",
            after: "Meeting with Sinead tomorrow", dictionary: []))
    }

    func testNoChangeIsRejected() {
        XCTAssertNil(propose(after: typed))
    }

    func testEmptyEverythingIsRejected() {
        XCTAssertNil(DictionaryLearner.propose(inserted: "", before: "", after: "", dictionary: []))
    }

    func testInsertionIntoAnEmptyBaselineIsRejected() {
        XCTAssertNil(DictionaryLearner.propose(inserted: typed, before: "", after: typed,
                                               dictionary: []))
    }

    // MARK: - Not dictionary material

    func testCaseOnlyFixIsRejected() {
        // Canonical comparison (Eval) sees no edit at all — capitalization is a
        // formatting fix, not a mishearing.
        XCTAssertNil(DictionaryLearner.propose(inserted: "we use parla daily",
                                               before: "we use parla daily",
                                               after: "we use Parla daily", dictionary: []))
    }

    func testPunctuationOnlyFixIsRejected() {
        XCTAssertNil(DictionaryLearner.propose(inserted: "hello, world again",
                                               before: "hello, world again",
                                               after: "hello world again", dictionary: []))
    }

    func testNumberSpellingFixIsRejected() {
        // Eval's normalizer folds "eleven" and "11" together, so this never even
        // registers as an edit — and a numeral is not a dictionary entry.
        XCTAssertNil(DictionaryLearner.propose(inserted: "call at eleven please",
                                               before: "call at eleven please",
                                               after: "call at 11 please", dictionary: []))
    }

    func testTokenWithDigitsIsRejected() {
        XCTAssertNil(DictionaryLearner.propose(inserted: "the model gpt4o wrote it",
                                               before: "the model gpt4o wrote it",
                                               after: "the model gpt4p wrote it", dictionary: []))
    }

    func testShortWordIsRejected() {
        XCTAssertNil(DictionaryLearner.propose(inserted: "we use ci here",
                                               before: "we use ci here",
                                               after: "we use cd here", dictionary: []))
    }

    func testVeryLongWordIsRejected() {
        let long = String(repeating: "a", count: 30)
        XCTAssertNil(DictionaryLearner.propose(inserted: "prefix \(long) suffix",
                                               before: "prefix \(long) suffix",
                                               after: "prefix \(long)b suffix", dictionary: []))
    }

    func testNonWordTokenIsRejected() {
        XCTAssertNil(DictionaryLearner.propose(inserted: "mail me at sinead@example.com",
                                               before: "mail me at sinead@example.com",
                                               after: "mail me at shinead@example.com",
                                               dictionary: []))
    }

    // MARK: - Already known

    func testCorrectedWordAlreadyInDictionaryIsRejected() {
        XCTAssertNil(propose(after: "Meeting with Sinead tomorrow", dictionary: ["sinead"]))
    }

    func testMisheardWordAlreadyInDictionaryIsRejected() {
        // The user deliberately has "Shunade"; the change is not Parla's error.
        XCTAssertNil(propose(after: "Meeting with Sinead tomorrow", dictionary: ["Shunade"]))
    }

    // MARK: - Store

    func tempStore() -> DictionaryLearner.Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DictionaryLearner.Store(url: dir.appendingPathComponent("proposals.json"))
    }

    func testAddIsIdempotentPerCorrection() {
        let store = tempStore()
        let p = DictionaryLearner.Proposal(from: "Shunade", to: "Sinead")
        XCTAssertTrue(store.add(p))
        XCTAssertFalse(store.add(DictionaryLearner.Proposal(from: "shunade", to: "SINEAD")))
        XCTAssertEqual(store.pending.count, 1)
    }

    func testDismissalIsPermanent() {
        let store = tempStore()
        let p = DictionaryLearner.Proposal(from: "Shunade", to: "Sinead")
        store.add(p)
        store.resolve(p, dismissed: true)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.add(p), "a dismissed correction must never be proposed again")
    }

    func testAcceptRemovesWithoutBlocking() {
        let store = tempStore()
        let p = DictionaryLearner.Proposal(from: "Shunade", to: "Sinead")
        store.add(p)
        store.resolve(p, dismissed: false)
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testCapDropsOldest() {
        let store = tempStore()
        for i in 0..<(DictionaryLearner.Store.cap + 3) {
            store.add(DictionaryLearner.Proposal(from: "word\(i)", to: "term\(i)"))
        }
        XCTAssertEqual(store.pending.count, DictionaryLearner.Store.cap)
        XCTAssertEqual(store.pending.first?.to, "term3")
    }

    func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("proposals.json")
        let a = DictionaryLearner.Store(url: url)
        a.add(DictionaryLearner.Proposal(from: "Shunade", to: "Sinead"))
        let dismissed = DictionaryLearner.Proposal(from: "Kafka", to: "Kafkaesque")
        a.add(dismissed)
        a.resolve(dismissed, dismissed: true)

        let b = DictionaryLearner.Store(url: url)
        XCTAssertEqual(b.pending.map(\.to), ["Sinead"])
        XCTAssertFalse(b.add(dismissed), "dismissals must survive a relaunch")
    }
}
