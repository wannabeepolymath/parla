import XCTest
@testable import ParlaCore

final class VocabularyTests: XCTestCase {
    func testByteBudgetsNormalizeDeduplicateAndRetainPriority() {
        let saved = ["  Café\n name ", "CAFÉ name", String(repeating: "界", count: 100), "次"]
        XCTAssertEqual(VocabularyHints.select(saved, byteLimit: 15), ["Café name", "次"])
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(VocabularyHints.select(["first", "second"], byteLimit: 6), ["first"])
        XCTAssertEqual(VocabularyHints.select([" ", "a"], byteLimit: 0), [])
    }

    func testSharedHintsBoundAllPromptPathsIncludingCommandAndTail() async {
        let words = [String(repeating: "界", count: 1_000)] + (0..<2_000).map { "Name\($0)" }
        let asr = VocabularyHints.asrPrompt(words)!
        XCTAssertLessThanOrEqual(asr.utf8.count, VocabularyHints.asrBytes)
        XCTAssertTrue(asr.hasPrefix("Name0, Name1"))
        var settings = Settings()
        settings.dictionary = words
        let pipeline = Pipeline(transcribe: { _, prompt in
            XCTAssertEqual(prompt, asr)
            return "hello"
        }, cleanup: { text, _ in text }, settings: { settings }, frontBundleID: { nil })
        recognitionAssertEqual(await pipeline.transcript(samples: [Float](repeating: 0.1, count: 6_400)), "hello")
        let tail = StreamWindow.tailPrompt(dictionary: words, confirmed: String(repeating: "界", count: 300))!
        XCTAssertTrue(tail.hasPrefix(asr + " "))
        XCTAssertTrue(tail.hasSuffix(String(repeating: "界", count: 200)))
        XCTAssertLessThanOrEqual(tail.utf8.count, VocabularyHints.asrBytes + 1 + StreamWindow.confirmedContextBytes)
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 5_000)
        XCTAssertEqual(StreamWindow.tailPrompt(dictionary: ["name"], confirmed: hugeGrapheme), "name")
        for selection in [nil, "selected text"] {
            let ctx = CleanupContext(dictionary: words, snippets: [:], appName: nil, selection: selection)
            let joined = ctx.dictionary.joined(separator: ", ")
            XCTAssertLessThanOrEqual(joined.utf8.count, VocabularyHints.cleanupBytes)
            XCTAssertTrue(PromptBuilder.system(context: ctx).contains(joined))
            XCTAssertFalse(PromptBuilder.system(context: ctx).contains(words[0]))
        }
    }

    func testTokenBudgetKeepsPriorityTermsOfAnOverBudgetDictionary() {
        let words = (0..<200).map { "Name\($0)" }
        let budget = PromptBudget(capacity: 223, count: { $0.utf8.count })
        let selected = VocabularyHints.select(words, budget: budget)
        XCTAssertEqual(selected.first, "Name0")
        XCTAssertLessThan(selected.count, words.count)
        let prompt = VocabularyHints.asrPrompt(words, budget: budget)
        XCTAssertEqual(prompt, selected.joined(separator: ", "))
        XCTAssertLessThanOrEqual(prompt?.utf8.count ?? .max, 223)
        // No budget: the byte selection, unchanged.
        XCTAssertEqual(VocabularyHints.select(words, budget: nil), VocabularyHints.select(words, byteLimit: VocabularyHints.asrBytes))
        XCTAssertEqual(VocabularyHints.asrPrompt(words), VocabularyHints.asrPrompt(words, budget: nil))
    }

    func testFinalJoinedGuardHoldsForANonAdditiveCounter() {
        // A separator piece costs its bytes alone, but the joined string pays 1 more per ", ".
        let count: (String) -> Int = { s in
            s.hasPrefix(", ") ? s.utf8.count : s.utf8.count + s.components(separatedBy: ", ").count - 1
        }
        let words = ["alpha", "beta", "gamma", "d", "epsilon"]
        XCTAssertEqual(VocabularyHints.select(["alpha", "beta"], budget: PromptBudget(capacity: 11, count: count)), ["alpha"])
        for capacity in 0...40 {
            let budget = PromptBudget(capacity: capacity, count: count)
            let selected = VocabularyHints.select(words, budget: budget)
            XCTAssertLessThanOrEqual(count(selected.joined(separator: ", ")), capacity, "capacity \(capacity)")
            if let tail = StreamWindow.tailPrompt(dictionary: words, confirmed: "hello world", budget: budget, reserve: 8) {
                XCTAssertLessThanOrEqual(count(tail), capacity, "tail capacity \(capacity)")
            }
        }
    }

    func testRetainedCountIsExactOnlyWithABudget() {
        // HubModel.retainedVocabularyCount: count = select(words, budget:).count, exact = budget != nil.
        let words = (0..<200).map { "Name\($0)" }
        let tokens = VocabularyHints.select(words, budget: PromptBudget(capacity: 223, count: { $0.utf8.count })).count
        let bytes = VocabularyHints.select(words, budget: nil).count
        XCTAssertEqual(bytes, VocabularyHints.select(words, byteLimit: VocabularyHints.asrBytes).count)
        XCTAssertLessThan(tokens, bytes)
    }

    func testUnicodeBoundariesOverlapsTiesLiteralOutputAndNoCascade() {
        let rules: [LiteralReplacement] = [
            .init(source: "cat", replacement: "dog"),
            .init(source: "cat nap", replacement: "$1\\folder\nnext"),
            .init(source: "dog", replacement: "wolf"),
            .init(source: "cat", replacement: "later tie"),
            .init(source: "café", replacement: "coffee"),
            .init(source: "हिंदी", replacement: "Hindi"),
            .init(source: "two", replacement: "2"),
        ]
        XCTAssertEqual(LiteralReplacement.apply(rules, to: "cat nap, cat dog concatenate cat_name écat cat界"),
                       "$1\\folder\nnext, dog wolf concatenate cat_name écat cat界")
        XCTAssertEqual(LiteralReplacement.apply(rules, to: "café cafés हिंदी हिंदीभाषा"), "coffee cafés Hindi हिंदीभाषा")
        XCTAssertEqual(LiteralReplacement.apply(rules, to: "Cat 2 two too"), "Cat 2 2 too")
        XCTAssertEqual(LiteralReplacement.apply([.init(source: "", replacement: "oops")], to: "same"), "same")
    }

    func testPipelineAppliesOnceAfterSuccessAndFailureAndLocksSnippets() async {
        var settings = Settings()
        settings.replacements = [.init(source: "cat", replacement: "dog"), .init(source: "dog", replacement: "wolf")]
        settings.snippets = ["shortcut": "cat\n$1\\literal"]
        for fail in [false, true] {
            let pipeline = Pipeline(transcribe: { _, _ in nil }, cleanup: { text, _ in
                if fail { throw URLError(.timedOut) }
                return text
            }, settings: { settings }, frontBundleID: { nil })
            let result = await pipeline.clean(transcript: "cat")
            XCTAssertEqual(result.text, "dog")
            XCTAssertEqual(result.failure, fail ? "cleanup timed out" : nil)
            let snippet = await pipeline.clean(transcript: "Shortcut!")
            XCTAssertEqual(snippet.text, "cat\n$1\\literal")
        }
        XCTAssertEqual(Pipeline.snippetExpansion(transcript: "say it", snippets: ["say it!": "a", "say it?": "b"]), "a")
    }

    func testLegacyDecodeAndReplacementRoundtrip() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{\"dictionary\":[\"old\"]}".utf8))
        XCTAssertTrue(old.replacements.isEmpty)
        var settings = old
        settings.replacements = [.init(source: "界", replacement: "$1\\\n")]
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
