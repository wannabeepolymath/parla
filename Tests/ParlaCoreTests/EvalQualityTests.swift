import XCTest
@testable import ParlaCore

final class EvalQualityTests: XCTestCase {
    private let email = "Hi Mira,\n\nThanks."

    private func policy(protected: [String] = [], alternatives: [String] = []) throws -> Eval.QualityPolicy {
        let object: [String: Any] = ["version": 1, "cases": [
            ["name": "sample", "protected": protected, "alternatives": alternatives]
        ]]
        return try Eval.qualityPolicy(from: JSONSerialization.data(withJSONObject: object))
    }

    private func results(_ hypothesis: String, leg: String = "cleanup") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            ["name": "sample", "leg": leg, "hypothesis": hypothesis,
             "reference": hypothesis] // An untrusted run cannot replace the golden.
        ])
    }

    private func check(_ reference: String, _ hypothesis: String,
                       protected: [String] = [], alternatives: [String] = []) throws -> [String] {
        try Eval.checkQuality(policy: policy(protected: protected, alternatives: alternatives),
                              references: ["sample": reference], results: results(hypothesis))
    }

    func testParagraphRegressionLeavesOldMeasuresUnchanged() throws {
        let flat = "Hi Mira, Thanks."
        XCTAssertEqual(Eval.normalize(email), Eval.normalize(flat))
        XCTAssertEqual(Eval.wer(reference: email, hypothesis: flat).rate, 0)
        XCTAssertNotEqual(Eval.normalizeStructure(email), Eval.normalizeStructure(flat))
        XCTAssertEqual(Eval.newlineLayout(email), [2, 2])
        XCTAssertEqual(Eval.newlineLayout(flat), [])
        XCTAssertFalse(try check(email, flat).isEmpty)
        XCTAssertFalse(try check(email, "Hi Mira,\nThanks.").isEmpty)
    }

    func testHorizontalWhitespaceLineEndingsAndOuterWhitespaceAreValid() throws {
        for variant in [" \r\n\tHi   Mira,\r\n \t\r\nThanks.\r\n ",
                        "Hi\tMira,\r\rThanks.", "Hi Mira,\u{2028}\u{2028}Thanks."] {
            XCTAssertEqual(Eval.normalizeStructure(variant), email)
            XCTAssertEqual(Eval.newlineLayout(variant), Eval.newlineLayout(email))
            XCTAssertTrue(try check(email, variant).isEmpty)
        }
    }

    func testNewlinePositionsAndSingleLineConstraints() throws {
        XCTAssertNotEqual(Eval.newlineLayout("one two\nthree"), Eval.newlineLayout("one\ntwo three"))
        XCTAssertEqual(Eval.newlineLayout("ONE two!\nthree?"), Eval.newlineLayout("one two\nthree"))
        XCTAssertFalse(try check("git status; git diff --staged", "git status;\ngit diff --staged").isEmpty)
    }

    func testPunctuationCaseAndCodeSymbolsAreProtectedDespiteZeroWER() throws {
        for (reference, actual, literal) in [
            ("Can you disable autoPay?", "Can you disable autoPay.", "?"),
            ("Keep userID != nil.", "Keep userID == nil.", "!="),
            ("Keep userID != nil.", "Keep userId != nil.", "userID")
        ] {
            XCTAssertEqual(Eval.wer(reference: reference, hypothesis: actual).rate, 0)
            XCTAssertNotEqual(Eval.normalize(reference), Eval.normalize(actual))
            let failures = try check(reference, actual, protected: [literal])
            XCTAssertTrue(failures.contains { $0.contains("protected literal count changed") })
        }
        XCTAssertFalse(try check("userID", "userID userID", protected: ["userID"]).isEmpty)
    }

    func testQuantityCurrencyNegationAndURLMutationsFail() throws {
        for (reference, actual, literal) in [
            ("Set the timeout to 15 seconds.", "Set the timeout to 50 seconds.", "15"),
            ("Transfer $12.50.", "Transfer €12.50.", "$12.50"),
            ("Do not disable autoPay.", "Do disable autoPay.", "not"),
            ("Open https://example.com/a?x=1&y=2.", "Open https://example.com/a?x=2&y=1.",
             "https://example.com/a?x=1&y=2")
        ] {
            XCTAssertFalse(try check(reference, actual, protected: [literal]).isEmpty)
        }
    }

    func testOnlyExplicitAlternativeIsAccepted() throws {
        XCTAssertTrue(try check("Can you disable autoPay?", "Could you disable autoPay?",
                                protected: ["autoPay", "?"], alternatives: ["Could you disable autoPay?"]).isEmpty)
        XCTAssertFalse(try check("Can you disable autoPay?", "Disable autoPay.", protected: ["autoPay", "?"]).isEmpty)
    }

    func testMalformedAndMissingPolicyFieldsFail() {
        for json in [
            "{}", "[]", "not json", #"{"version":2,"cases":[]}"#,
            #"{"version":1,"cases":[]}"#,
            #"{"version":1,"cases":[{"name":"sample","alternatives":[]}]}"#,
            #"{"version":1,"cases":[{"name":"sample","protected":[],"alternatives":[],"maxWER":1}]}"#,
            #"{"version":1,"cases":[{"name":"../sample","protected":[],"alternatives":[]}]}"#,
            #"{"version":1,"cases":[{"name":"sample","protected":[""],"alternatives":[]}]}"#,
            #"{"version":1,"cases":[{"name":"sample","protected":["x","x"],"alternatives":[]}]}"#,
            #"{"version":1,"cases":[{"name":"sample","protected":[],"alternatives":[" "]}]}"#,
            #"{"version":1,"cases":[{"name":"sample","protected":[],"alternatives":[]},{"name":"sample","protected":[],"alternatives":[]}]}"#
        ] {
            XCTAssertThrowsError(try Eval.qualityPolicy(from: Data(json.utf8)), json)
        }
    }

    func testMissingInconsistentAndEmptyGoldensFail() throws {
        let p = try policy()
        for references in [[:], ["sample": "x", "extra": "x"], ["sample": " \n "]] {
            XCTAssertThrowsError(try Eval.checkQuality(policy: p, references: references, results: results("x")))
        }
        XCTAssertThrowsError(try check("userID", "userID", protected: ["absent"]))
        XCTAssertThrowsError(try check("userID", "userID", protected: ["userID"], alternatives: ["userId"]))
        XCTAssertThrowsError(try check("userID", "userID", alternatives: [" userID "]))
    }

    func testMissingMalformedDuplicateAndUnknownResultsFail() throws {
        let p = try policy()
        for json in [
            "[]", "{}", "not json",
            #"[{"name":"sample","leg":"asr","hypothesis":"x"}]"#,
            #"[{"name":"sample","leg":"cleanup"}]"#,
            #"[{"name":"sample","leg":"cleanup","hypothesis":null}]"#,
            #"[{"name":"other","leg":"cleanup","hypothesis":"x"}]"#,
            #"[{"name":"sample","leg":"unknown","hypothesis":"x"}]"#,
            #"[{"name":"sample","leg":"cleanup","hypothesis":"x"},{"name":"sample","leg":"cleanup","hypothesis":"x"}]"#
        ] {
            XCTAssertThrowsError(try Eval.checkQuality(policy: p, references: ["sample": "x"],
                                                      results: Data(json.utf8)), json)
        }
    }

    func testFullRunCanIncludeASRAlongsideRequiredCleanup() throws {
        let json = #"[{"name":"sample","leg":"asr","hypothesis":"raw"},{"name":"sample","leg":"cleanup","hypothesis":"x","engine":"real-provider","seconds":1}]"#
        XCTAssertTrue(try Eval.checkQuality(policy: policy(), references: ["sample": "x"],
                                            results: Data(json.utf8)).isEmpty)
    }

    func testReviewedCorpusAndMinimalPairMutations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval/quality")
        let p = try Eval.qualityPolicy(from: Data(contentsOf: root.appendingPathComponent("rules.json")))
        var references: [String: String] = [:]
        for rule in p.cases {
            let text = try String(contentsOf: root.appendingPathComponent("cases/\(rule.name).golden.txt"), encoding: .utf8)
            references[rule.name] = text.components(separatedBy: "\n").drop(while: { $0.hasPrefix("# ") })
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let data = try Data(contentsOf: root.appendingPathComponent("reviewed-results.json"))
        XCTAssertEqual(p.cases.count, 25)
        XCTAssertTrue(try Eval.checkQuality(policy: p, references: references, results: data).isEmpty)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for (target, replacement) in [
            ("like-literal", "like-filler"), ("sort-literal", "sort-filler"),
            ("you-know-literal", "you-know-filler"), ("sort-hedge", "sort-filler"), ("correction-negation", "correction-replace"),
            ("question", "statement"), ("negative", "positive"), ("quantity-fifteen", "quantity-fifty"),
            ("money-fifty", "money-five"), ("money-fifty", "money-euro"),
            ("url-one", "url-two"), ("identifier-not-equal", "identifier-equal")
        ] {
            var mutated = original
            let index = try XCTUnwrap(mutated.firstIndex { $0["name"] as? String == target })
            mutated[index]["hypothesis"] = references[replacement]
            let failures = try Eval.checkQuality(policy: p, references: references,
                                                 results: JSONSerialization.data(withJSONObject: mutated))
            XCTAssertFalse(failures.isEmpty, "\(target) must reject \(replacement)")
        }
    }
}
