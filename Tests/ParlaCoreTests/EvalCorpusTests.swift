import XCTest
import CryptoKit
import Darwin
@testable import ParlaCore

/// Every declaration/text/byte here is test-authored. Dummy .wav files are NOT
/// valid human audio, consent, participant identities or reference evidence.
final class EvalCorpusFixture {
    let root: URL
    let now = 1_800_000_000.0
    var manifest: [String: EvalCorpusJSON]
    var rows: [[String: EvalCorpusJSON]] = []
    var count: Int
    var recorded = false
    var preserveSymlinks = false
    init(count: Int = 1, noSpeech: Bool = false, words: Int = 3) throws {
        self.count = count
        // /private/tmp avoids the /tmp symlink, which production correctly refuses.
        root = URL(fileURLWithPath: "/private/tmp/parla-wave8a1-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        manifest = [:]
        try record("created"); recorded = true
        var cases: [EvalCorpusJSON] = []
        let text = noSpeech ? "" : (0..<words).map { "word\($0)" }.joined(separator: " ")
        for i in 0..<count {
            let audio = Data("TEST-AUTHORED-DUMMY-NOT-AUDIO-\(i)".utf8)
            let aHash = EvalCorpusIO.digest(audio)
            try audio.write(to: root.appendingPathComponent("a\(i).wav"))
            var refs: [EvalCorpusJSON] = []
            for role in ["raw", "golden"] {
                let path = "r\(i).\(role).txt", data = Data(text.utf8)
                try data.write(to: root.appendingPathComponent(path))
                refs.append(.object([
                    "path": .string(path), "sha256": .string(EvalCorpusIO.digest(data)), "revision": .string("TEST-ref-v1"),
                    "review": .string("reviewed"), "reviewer": .string("TEST-reviewer"), "reviewedAt": .number("1790000000"),
                    "audioSHA256": .string(aHash), "takeID": .string("TEST-take-\(i)"), "draftOrigin": .string("independent-human")
                ]))
            }
            cases.append(.object([
                "id": .string("TEST-case-\(i)"), "provenance": .string(noSpeech ? "human-no-speech" : "human-speech"),
                "takeID": .string("TEST-take-\(i)"), "familyID": .string("TEST-family-\(i)"), "parentIDs": .array([]),
                "lineageComplete": .bool(true), "speakersComplete": .bool(true), "speakerIDs": .array([.string("TEST-speaker")]),
                "consentIDs": .array([.string("TEST-consent")]), "split": .string("development"), "repetitionGroup": .string("TEST-prompt"),
                "cohorts": .array([.string("TEST-microphone")]),
                "audio": .object(["path": .string("a\(i).wav"), "sha256": .string(aHash), "bytes": .number(String(audio.count))]),
                "verbatim": refs[0], "cleaned": refs[1]
            ]))
        }
        manifest = [
            "version": .number("1"), "corpusID": .string("TEST-only-not-human-evidence"), "revision": .string("TEST-manifest-v1"),
            "purpose": .string("human-qualification"), "protocolRevision": .string("TEST-protocol"), "snapshotAt": .number("1790000000"),
            "cohorts": .array([.object(["id": .string("TEST-microphone"), "dimension": .string("microphone")]),
                               .object(["id": .string("TEST-language"), "dimension": .string("language")])]),
            "speakers": .array([.object(["id": .string("TEST-speaker"), "identityGroup": .string("TEST-person"),
                                          "identityKnown": .bool(true), "aliasesReconciled": .bool(true), "cohorts": .array([.string("TEST-language")])])]),
            "consents": .array([.object([
                "id": .string("TEST-consent"), "revision": .string("TEST-v1"), "speakerIDs": .array([.string("TEST-speaker")]),
                "attester": .string("TEST-attester"), "effectiveAt": .number("1780000000"), "reviewedAt": .number("1790000000"),
                "retentionUntil": .number("2000000000"), "status": .string("active"), "withdrawalEffectiveAt": .null,
                "uses": .array(["binding-check", "reference-review", "asr", "cleanup"].map(EvalCorpusJSON.string)),
                "destinations": .array(["local", "provider", "external-command"].map(EvalCorpusJSON.string)),
                "accessPolicyRevision": .string("TEST-access"), "withdrawalPolicyRevision": .string("TEST-withdrawal")
            ])]), "cases": .array(cases)
        ]
    }
    deinit {
        if preserveSymlinks { try? record("preserved-symlink"); return }
        try? FileManager.default.removeItem(at: root); try? record("removed")
    }
    func record(_ event: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("\(event)\t\(getpid())\t\(root.path)\n".utf8))
    }
    static func encode(_ json: EvalCorpusJSON) -> String {
        switch json {
        case .object(let o): return "{" + o.keys.sorted().map { encode(.string($0)) + ":" + encode(o[$0]!) }.joined(separator: ",") + "}"
        case .array(let a): return "[" + a.map(encode).joined(separator: ",") + "]"
        case .string(let s): return String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
    var manifestPath: String { root.appendingPathComponent("manifest.json").path }
    @discardableResult func writeManifest() throws -> String {
        try Data(Self.encode(.object(manifest)).utf8).write(to: URL(fileURLWithPath: manifestPath))
        return manifestPath
    }
    func mutateCase(_ index: Int = 0, _ change: (inout [String: EvalCorpusJSON]) -> Void) {
        guard case .array(var cases) = manifest["cases"], case .object(var c) = cases[index] else { preconditionFailure() }
        change(&c); cases[index] = .object(c); manifest["cases"] = .array(cases)
    }
    func mutateConsent(_ change: (inout [String: EvalCorpusJSON]) -> Void) {
        guard case .array(var array) = manifest["consents"], case .object(var c) = array[0] else { preconditionFailure() }
        change(&c); array[0] = .object(c); manifest["consents"] = .array(array)
    }
    func makeRun(id: String = "TEST-run-A", route: String = "asr-only", hypothesis: String? = nil) throws -> [String: EvalCorpusJSON] {
        try writeManifest()
        guard case .array(let cases) = manifest["cases"] else { preconditionFailure() }
        let legs = route == "asr-only" ? ["asr"] : (route == "reference-cleanup" ? ["cleanup"] : ["asr", "cleanup"])
        var rows: [EvalCorpusJSON] = []
        for c in cases {
            let obj = try c.object("id provenance takeID familyID parentIDs lineageComplete speakersComplete speakerIDs consentIDs split repetitionGroup cohorts audio verbatim cleaned")
            let audio = try obj.field("audio").object("path sha256 bytes")
            let raw = try obj.field("verbatim").object("path sha256 revision review reviewer reviewedAt audioSHA256 takeID draftOrigin")
            let rawPath = try raw.field("path").string()
            let rawText = try String(contentsOf: root.appendingPathComponent(rawPath), encoding: .utf8)
            let asr = hypothesis ?? rawText
            for leg in legs {
                let ref = try obj.field(leg == "asr" ? "verbatim" : "cleaned").object("path sha256 revision review reviewer reviewedAt audioSHA256 takeID draftOrigin")
                let input = leg == "asr" ? try audio.field("sha256").string() : EvalCorpusIO.digest(Data((route == "reference-cleanup" ? rawText : asr).utf8))
                rows.append(.object([
                    "caseID": try obj.field("id"), "leg": .string(leg), "audioSHA256": try audio.field("sha256"),
                    "referenceSHA256": try ref.field("sha256"), "referenceRevision": try ref.field("revision"),
                    "status": .string("success"), "reason": .null, "hypothesis": .string(asr), "seconds": .number("0.25"),
                    "inputOrigin": .string(leg == "asr" ? "audio" : (route == "reference-cleanup" ? "verbatim-reference" : "asr-hypothesis")),
                    "inputSHA256": .string(input)
                ]))
            }
        }
        return ["version": .number("1"), "runID": .string(id), "manifestSHA256": .string(EvalCorpusIO.digest(try Data(contentsOf: URL(fileURLWithPath: manifestPath)))),
                "manifestRevision": .string("TEST-manifest-v1"), "route": .string(route),
                "engines": .array(legs.map { .object(["leg": .string($0), "id": .string("TEST-engine"), "revision": .string("TEST-v1"), "configRevision": .string("TEST-config"), "transport": .string("local")]) }), "rows": .array(rows)]
    }
    func writeRun(_ run: [String: EvalCorpusJSON], name: String = "run.json") throws -> String {
        let path = root.appendingPathComponent(name)
        try Data(Self.encode(.object(run)).utf8).write(to: path)
        return path.path
    }
    func check(results: String? = nil, against: String? = nil, clock: (() -> Double)? = nil, afterRead: (() throws -> Void)? = nil) throws -> String {
        try writeManifest()
        return try EvalCorpus.evaluate(.init(manifest: manifestPath, results: results, against: against), clock: clock ?? { self.now }, afterRead: afterRead)
    }
    static func mutateRow(_ run: inout [String: EvalCorpusJSON], index: Int = 0, _ change: (inout [String: EvalCorpusJSON]) -> Void) {
        guard case .array(var rows) = run["rows"], case .object(var row) = rows[index] else { preconditionFailure() }
        change(&row); rows[index] = .object(row); run["rows"] = .array(rows)
    }
}

final class EvalCorpusTests: XCTestCase {
    func testMetadataOnlyAndSharedHeaderExtraction() throws {
        let f = try EvalCorpusFixture()
        let text = try f.check()
        XCTAssertTrue(text.contains("no model quality measured")); XCTAssertFalse(text.contains("speech-scored="))
        XCTAssertTrue(text.contains("consent truth/legal adequacy")); XCTAssertTrue(text.contains("speakers=1 takes=1"))
        XCTAssertEqual(EvalCorpus.parseCaseFile("# category: x\n# app: A\n# bundle: b\n hi \n").body, "hi")
        XCTAssertEqual(EvalCorpus.parseCaseFile("#define FOO\nhello").body, "#define FOO\nhello")
    }
    func testStrictJSONDepthDuplicatesTypesAndMalformed() throws {
        for json in ["", "{}x", "{\"x\":1,\"\\u0078\":2}", "{\"x\":true,\"x\":false}", "[1,]", "[01]", "[1.]", "[1e]", "[NaN]", "[\"\\uD800\"]", "[\"\n\"]", "[true false]"] {
            XCTAssertThrowsError(try EvalCorpusJSON.parse(Data(json.utf8)))
        }
        let depth32 = String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)
        XCTAssertNoThrow(try EvalCorpusJSON.parse(Data(depth32.utf8)))
        XCTAssertThrowsError(try EvalCorpusJSON.parse(Data(("[" + depth32 + "]").utf8)))
        for json in ["true", "1.0", "1e0", "-1", "253402300800"] {
            XCTAssertThrowsError(try EvalCorpusJSON.parse(Data(json.utf8)).integer())
        }
    }
    func testSchemaVersionKnownKeysCountsAndProvenance() throws {
        for mutate: (inout [String: EvalCorpusJSON]) -> Void in [
            { $0["version"] = .number("2") }, { $0["corpusID"] = .string("PRIVATE path") },
            { $0["unknown"] = .bool(true) }, { $0.removeValue(forKey: "protocolRevision") },
            { $0["cases"] = .array([]) }, { $0["purpose"] = .string("unknown") }
        ] {
            let f = try EvalCorpusFixture(); mutate(&f.manifest); XCTAssertThrowsError(try f.check())
        }
        for origin in ["tts", "synthetic-signal", "authored", "unknown"] {
            let f = try EvalCorpusFixture(); f.mutateCase { $0["provenance"] = .string(origin) }; XCTAssertThrowsError(try f.check())
        }
        let f = try EvalCorpusFixture(); f.mutateCase { c in
            if case .object(var ref) = c["verbatim"] { ref["draftOrigin"] = .string("script"); c["verbatim"] = .object(ref) }
        }; XCTAssertThrowsError(try f.check())
    }
    func testConsentBoundariesAndUseTimeRefresh() throws {
        for status in ["pending", "unknown", "withdrawn", "revoked"] {
            let f = try EvalCorpusFixture(); f.mutateConsent { $0["status"] = .string(status) }; XCTAssertThrowsError(try f.check())
        }
        for key in ["retentionUntil", "effectiveAt", "reviewedAt"] {
            let f = try EvalCorpusFixture(); f.mutateConsent { $0[key] = .number(key == "retentionUntil" ? "1800000000" : "1900000000") }; XCTAssertThrowsError(try f.check())
        }
        let f = try EvalCorpusFixture(); f.mutateConsent { $0["retentionUntil"] = .number("1800000001") }
        XCTAssertNoThrow(try f.check())
        var calls = 0
        XCTAssertThrowsError(try f.check(clock: { calls += 1; return calls == 1 ? f.now : f.now + 1 }))
        let g = try EvalCorpusFixture(); g.mutateConsent { $0["uses"] = .array([.string("binding-check"), .string("reference-review")]) }
        XCTAssertNoThrow(try g.check())
        let run = try g.writeRun(g.makeRun()); XCTAssertThrowsError(try g.check(results: run))
        let h = try EvalCorpusFixture(); h.mutateConsent { $0["withdrawalEffectiveAt"] = .number("1900000000") }; XCTAssertThrowsError(try h.check())
    }
    func testSplitTakeFamilyAliasAndDuplicateBindingRefusals() throws {
        for field in ["takeID", "familyID", "split"] {
            let f = try EvalCorpusFixture(count: 2)
            f.mutateCase(1) { $0[field] = .string(field == "split" ? "holdout" : "TEST-\(field == "takeID" ? "take" : "family")-0") }
            if field == "familyID" { f.mutateCase(1) { $0["split"] = .string("holdout") } }
            XCTAssertThrowsError(try f.check())
        }
        let f = try EvalCorpusFixture(count: 2)
        // Same prompt and independently captured takes in one split are valid.
        XCTAssertTrue(try f.check().contains("speakers=1 takes=2"))
        f.mutateCase(1) { $0["speakerIDs"] = .array([.string("unknown")]) }; XCTAssertThrowsError(try f.check())
        let g = try EvalCorpusFixture(count: 2)
        g.mutateCase(1) { $0["parentIDs"] = .array([.string("TEST-case-0")]) }; XCTAssertThrowsError(try g.check())
    }
    func testPathSyntaxNoFollowHardlinksKindsAndChangedBytes() throws {
        for path in ["/private/tmp/out.wav", "../out.wav", "a/./b.wav", "a//b.wav", ".hidden.wav", "A?.wav", "a%2e.wav", "a\\b.wav", "C:a.wav", "~a.wav", "a .wav", "é.wav", "a.wav\n"] {
            XCTAssertThrowsError(try EvalCorpusIO.components(path))
        }
        for variant in ["leaf", "parent", "hardlink", "fifo", "hash"] {
            let f = try EvalCorpusFixture()
            let original = f.root.appendingPathComponent("a0.wav"), target = f.root.appendingPathComponent("target.wav")
            switch variant {
            case "leaf":
                f.preserveSymlinks = true
                try FileManager.default.moveItem(at: original, to: target)
                try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
            case "parent":
                f.preserveSymlinks = true
                let real = f.root.appendingPathComponent("real"); try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
                try FileManager.default.moveItem(at: original, to: real.appendingPathComponent("a0.wav"))
                try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("alias"), withDestinationURL: real)
                f.mutateCase { if case .object(var a) = $0["audio"] { a["path"] = .string("alias/a0.wav"); $0["audio"] = .object(a) } }
            case "hardlink": XCTAssertEqual(link(original.path, target.path), 0)
            case "fifo": try FileManager.default.removeItem(at: original); XCTAssertEqual(mkfifo(original.path, 0o600), 0)
            default: try Data("PRIVATE-CANARY".utf8).write(to: original)
            }
            XCTAssertThrowsError(try f.check()) { XCTAssertFalse($0.localizedDescription.contains("PRIVATE")); XCTAssertFalse($0.localizedDescription.contains(f.root.path)) }
        }
    }
    func testDescriptorRootAndReplacementDuringAndAfterRead() throws {
        let f = try EvalCorpusFixture(); try f.writeManifest()
        f.preserveSymlinks = true
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        XCTAssertThrowsError(try EvalCorpusIO(manifest: alias.appendingPathComponent("manifest.json").path))
        var once = false
        XCTAssertThrowsError(try f.check(afterRead: {
            if !once { once = true; try Data("{}".utf8).write(to: URL(fileURLWithPath: f.manifestPath), options: .atomic) }
        }))
        try f.writeManifest()
        let io = try EvalCorpusIO(manifest: f.manifestPath); _ = try io.manifest(f.manifestPath)
        let file = f.root.appendingPathComponent("a0.wav")
        _ = try io.payload("a0.wav", extension: ".wav", limit: 100, retain: false)
        try Data("replacement".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try io.revalidate())
    }
    func testTextTokensCountAndFileBudgets() throws {
        XCTAssertEqual(try EvalCorpus.tokenCount(String(repeating: "x ", count: 2048)), 2048)
        XCTAssertThrowsError(try EvalCorpus.tokenCount(String(repeating: "x ", count: 2049)))
        XCTAssertThrowsError(try EvalCorpus.tokenCount(String(repeating: "x", count: 32769)))
        let f = try EvalCorpusFixture(); try f.writeManifest()
        let io = try EvalCorpusIO(manifest: f.manifestPath)
        XCTAssertThrowsError(try io.payload("a0.wav", extension: ".wav", limit: 1, retain: false))
        f.manifest["cohorts"] = .array((0..<33).map { .object(["id": .string("c\($0)"), "dimension": .string("other")]) })
        XCTAssertThrowsError(try f.check())
        let g = try EvalCorpusFixture(); g.mutateCase { if case .object(var a) = $0["audio"] { a["bytes"] = .number("67108865"); $0["audio"] = .object(a) } }; XCTAssertThrowsError(try g.check())
    }
    func testRecomputedScoresOverlappingCohortsAndOperationalCounts() throws {
        let f = try EvalCorpusFixture(count: 3)
        var run = try f.makeRun(hypothesis: "incorrect")
        EvalCorpusFixture.mutateRow(&run, index: 1) { $0["status"] = .string("failed"); $0["reason"] = .string("decode"); $0["hypothesis"] = .null }
        EvalCorpusFixture.mutateRow(&run, index: 2) { $0["status"] = .string("skipped"); $0["reason"] = .string("not-attempted"); $0["hypothesis"] = .null; $0["seconds"] = .null }
        let path = try f.writeRun(run), text = try f.check(results: path)
        XCTAssertTrue(text.contains("scheduled=3 attempted=2 scored=1 operational-failed=1 skipped=1"))
        XCTAssertTrue(text.contains("quality-failed(>20%)=1/1")); XCTAssertTrue(text.contains("cohort/TEST-language")); XCTAssertTrue(text.contains("cohort/TEST-microphone"))
        XCTAssertFalse(text.contains("incorrect")); XCTAssertFalse(text.contains(f.root.path))
        EvalCorpusFixture.mutateRow(&run) { $0["wer"] = .number("0") }; XCTAssertThrowsError(try f.check(results: f.writeRun(run)))
    }
    func testNoSpeechEmptySuccessAndUnavailableWER() throws {
        let f = try EvalCorpusFixture(noSpeech: true)
        let empty = try f.writeRun(f.makeRun())
        let text = try f.check(results: empty)
        XCTAssertTrue(text.contains("WER=unavailable")); XCTAssertTrue(text.contains("hallucinations=0/1"))
        let hallucinated = try f.writeRun(f.makeRun(hypothesis: "PRIVATE-CANARY"))
        let report = try f.check(results: hallucinated)
        XCTAssertTrue(report.contains("hallucinations=1/1")); XCTAssertFalse(report.contains("PRIVATE-CANARY"))
        let g = try EvalCorpusFixture(); let p = try g.writeRun(g.makeRun(hypothesis: ""))
        XCTAssertTrue(try g.check(results: p).contains("quality-failed(>20%)=1/1"))
    }
    func testRunCoverageTypedFailuresDurationsBindingsAndRoutes() throws {
        let f = try EvalCorpusFixture()
        let valid = try f.makeRun()
        for mutate: (inout [String: EvalCorpusJSON]) -> Void in [
            { $0["manifestSHA256"] = .string(String(repeating: "0", count: 64)) },
            { $0["manifestRevision"] = .string("stale") }, { $0["rows"] = .array([]) },
            { if case .array(let rows) = $0["rows"] { $0["rows"] = .array(rows + rows) } },
            { $0["route"] = .string("unknown") }
        ] { var r = valid; mutate(&r); XCTAssertThrowsError(try f.check(results: f.writeRun(r))) }
        for (key, value): (String, EvalCorpusJSON) in [
            ("seconds", .number("-1")), ("seconds", .number("1e999")), ("leg", .string("unknown")),
            ("caseID", .string("extra")), ("referenceRevision", .string("stale")), ("hypothesis", .null),
            ("status", .string("failed")), ("inputOrigin", .string("verbatim-reference")),
            ("reason", .string("not-attempted"))
        ] { var r = valid; EvalCorpusFixture.mutateRow(&r) { $0[key] = value }; XCTAssertThrowsError(try f.check(results: f.writeRun(r))) }
        let pipeline = try f.makeRun(route: "asr-pipeline")
        XCTAssertNoThrow(try f.check(results: f.writeRun(pipeline)))
        var failed = pipeline
        EvalCorpusFixture.mutateRow(&failed, index: 0) { $0["status"] = .string("failed"); $0["reason"] = .string("decode"); $0["hypothesis"] = .null }
        XCTAssertThrowsError(try f.check(results: f.writeRun(failed)))
        EvalCorpusFixture.mutateRow(&failed, index: 1) { $0["status"] = .string("skipped"); $0["reason"] = .string("upstream-failed"); $0["hypothesis"] = .null; $0["seconds"] = .null; $0["inputOrigin"] = .string("unavailable"); $0["inputSHA256"] = .null }
        XCTAssertTrue(try f.check(results: f.writeRun(failed)).contains("operational-failed=1"))
    }
    func testSavedRunDurationRejectsNegativeSpellingBeforeRounding() throws {
        let f = try EvalCorpusFixture()
        let valid = try f.makeRun()
        for seconds in ["0", "0.0", "1e-999", "1e-3", "0.25"] {
            var run = valid
            EvalCorpusFixture.mutateRow(&run) { $0["seconds"] = .number(seconds) }
            XCTAssertNoThrow(try f.check(results: f.writeRun(run)), seconds)
        }
        for status in ["success", "failed"] {
            for seconds in ["-1e-999", "-1e-324", "-0", "-0.0", "-4e-324", "-1"] {
                var run = valid
                EvalCorpusFixture.mutateRow(&run) {
                    $0["seconds"] = .number(seconds)
                    if status == "failed" {
                        $0["status"] = .string("failed"); $0["reason"] = .string("decode"); $0["hypothesis"] = .null
                    }
                }
                XCTAssertThrowsError(try f.check(results: f.writeRun(run)), "\(status): \(seconds)")
            }
        }
    }
    func testPairedRoutesFailuresAndDifferentPipelineInputs() throws {
        let f = try EvalCorpusFixture()
        let a = try f.writeRun(f.makeRun(route: "asr-pipeline"), name: "a.json")
        let b = try f.writeRun(f.makeRun(id: "TEST-run-B", route: "asr-pipeline", hypothesis: "different"), name: "b.json")
        let text = try f.check(results: a, against: b)
        XCTAssertTrue(text.contains("pipeline-dependent")); XCTAssertTrue(text.contains("input-different-success-pairs=1"))
        XCTAssertTrue(text.contains("both-success=1")); XCTAssertFalse(text.contains("different\n"))
        let incompatible = try f.writeRun(f.makeRun(id: "TEST-run-C", route: "reference-cleanup"), name: "c.json")
        XCTAssertThrowsError(try f.check(results: a, against: incompatible))
        var bad = try f.makeRun(id: "TEST-run-B", route: "asr-pipeline")
        EvalCorpusFixture.mutateRow(&bad, index: 1) { $0["status"] = .string("failed"); $0["reason"] = .string("engine"); $0["hypothesis"] = .null }
        let p = try f.writeRun(bad, name: "b.json")
        XCTAssertTrue(try f.check(results: a, against: p).contains("unilateral-nonsuccess=1"))
    }
    func testCombinedCellBudgetBeforeScoring() throws {
        let f = try EvalCorpusFixture(count: 4, words: 2048)
        let a = try f.writeRun(f.makeRun(), name: "a.json")
        // 4 * 2049² exceeds 16,777,216 even for one run.
        XCTAssertThrowsError(try f.check(results: a)) { XCTAssertEqual($0 as? EvalCorpusError, .bounds) }
        let g = try EvalCorpusFixture(count: 2, words: 2048)
        let x = try g.writeRun(g.makeRun(), name: "a.json")
        let y = try g.writeRun(g.makeRun(id: "TEST-run-B"), name: "b.json")
        XCTAssertThrowsError(try g.check(results: x, against: y)) { XCTAssertEqual($0 as? EvalCorpusError, .bounds) }
    }
}

extension EvalCorpusTests {
    func testDifferentSpeakersSamePromptHeldoutAndAliasLeakage() throws {
        let f = try EvalCorpusFixture(count: 2)
        guard case .array(var people) = f.manifest["speakers"], case .object(var person) = people[0],
              case .array(var consents) = f.manifest["consents"], case .object(var consent) = consents[0] else { return XCTFail() }
        person["id"] = .string("TEST-speaker-2"); person["identityGroup"] = .string("TEST-person-2"); people.append(.object(person))
        f.manifest["speakers"] = .array(people)
        consent["id"] = .string("TEST-consent-2"); consent["speakerIDs"] = .array([.string("TEST-speaker-2")]); consents.append(.object(consent))
        f.manifest["consents"] = .array(consents)
        f.mutateCase(1) { $0["speakerIDs"] = .array([.string("TEST-speaker-2")]); $0["consentIDs"] = .array([.string("TEST-consent-2")]); $0["split"] = .string("holdout") }
        XCTAssertTrue(try f.check().contains("speakers=2 takes=2"))
        person["identityGroup"] = .string("TEST-person"); people[1] = .object(person); f.manifest["speakers"] = .array(people)
        XCTAssertThrowsError(try f.check()) { XCTAssertEqual($0 as? EvalCorpusError, .split) }
    }
    func testNonhumanPurposeIsExplicitAndNeverHumanEvidence() throws {
        let f = try EvalCorpusFixture()
        f.manifest["purpose"] = .string("nonhuman-regression"); f.manifest["speakers"] = .array([]); f.manifest["consents"] = .array([])
        f.mutateCase { $0["provenance"] = .string("tts"); $0["speakerIDs"] = .array([]); $0["consentIDs"] = .array([]); $0["cohorts"] = .array([.string("TEST-language"), .string("TEST-microphone")]) }
        XCTAssertTrue(try f.check().contains("purpose=nonhuman-regression"))
    }
    func testReferenceIdentityReviewAndFullFileHashWithLegacyHeaders() throws {
        for field in ["review", "audioSHA256", "takeID", "revision"] {
            let f = try EvalCorpusFixture()
            if field == "revision" {
                let run = try f.writeRun(f.makeRun())
                f.mutateCase { if case .object(var ref) = $0["verbatim"] { ref[field] = .string("TEST-ref-v2"); $0["verbatim"] = .object(ref) } }
                XCTAssertThrowsError(try f.check(results: run))
            } else {
                f.mutateCase { if case .object(var ref) = $0["verbatim"] { ref[field] = .string(field == "review" ? "unresolved" : (field == "audioSHA256" ? String(repeating: "0", count: 64) : "TEST-other-take")); $0["verbatim"] = .object(ref) } }
                XCTAssertThrowsError(try f.check())
            }
        }
        let f = try EvalCorpusFixture()
        let bytes = Data("# category: TEST\n# app: TEST\nword0 word1 word2".utf8)
        try bytes.write(to: f.root.appendingPathComponent("r0.raw.txt"))
        XCTAssertThrowsError(try f.check())
        f.mutateCase { if case .object(var ref) = $0["verbatim"] { ref["sha256"] = .string(EvalCorpusIO.digest(bytes)); $0["verbatim"] = .object(ref) } }
        XCTAssertNoThrow(try f.check())
    }
    func testSelectedRunNoFollowAndParentDirectoryReplacement() throws {
        let f = try EvalCorpusFixture()
        let run = try f.writeRun(f.makeRun())
        let alias = f.root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: run)); f.preserveSymlinks = true
        XCTAssertThrowsError(try f.check(results: alias.path))
        try f.writeManifest()
        let io = try EvalCorpusIO(manifest: f.manifestPath)
        let directory = f.root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("TEST-bytes".utf8).write(to: directory.appendingPathComponent("a.wav"))
        _ = try io.payload("payload/a.wav", extension: ".wav", limit: 100, retain: false)
        try FileManager.default.moveItem(at: directory, to: f.root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try io.revalidate())
    }
    func testCountAggregateAndExactByteBoundsWithoutLargePayloadReads() throws {
        let f = try EvalCorpusFixture()
        let path = try f.writeManifest()
        let io = try EvalCorpusIO(manifest: path)
        let boundary = Data(repeating: 120, count: 32_768)
        try boundary.write(to: f.root.appendingPathComponent("boundary.txt"))
        XCTAssertEqual(try io.payload("boundary.txt", extension: ".txt", limit: 32_768, retain: true).bytes, 32_768)
        try (boundary + Data([120])).write(to: f.root.appendingPathComponent("excess.txt"))
        XCTAssertThrowsError(try io.payload("excess.txt", extension: ".txt", limit: 32_768, retain: true))
        XCTAssertThrowsError(try EvalCorpusJSON.array(Array(repeating: .null, count: 257)).array(limit: 256))
        XCTAssertThrowsError(try EvalCorpusJSON.array(Array(repeating: .null, count: 129)).array(limit: 128))
        XCTAssertThrowsError(try EvalCorpusJSON.array(Array(repeating: .null, count: 513)).array(limit: 512))
        XCTAssertThrowsError(try EvalCorpusJSON.string(String(repeating: "x", count: 65)).id())
        let huge = f.root.appendingPathComponent("huge.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: 33_554_433); try handle.close()
        XCTAssertThrowsError(try io.run(huge.path)) { XCTAssertEqual($0 as? EvalCorpusError, .bounds) }
        XCTAssertThrowsError(try EvalCorpusIO.components(String(repeating: "a", count: 253) + ".wav"))
    }
    func testPairTransportRefusalBothFailuresSkipsAndIsolatedCleanup() throws {
        let f = try EvalCorpusFixture()
        let aRun = try f.makeRun(route: "reference-cleanup")
        let a = try f.writeRun(aRun, name: "a.json")
        var bRun = try f.makeRun(id: "TEST-run-B", route: "reference-cleanup")
        if case .array(var engines) = bRun["engines"], case .object(var engine) = engines[0] {
            engine["transport"] = .string("provider"); engines[0] = .object(engine); bRun["engines"] = .array(engines)
        }
        XCTAssertThrowsError(try f.check(results: a, against: f.writeRun(bRun, name: "b.json")))
        var failedA = aRun
        EvalCorpusFixture.mutateRow(&failedA) { $0["status"] = .string("failed"); $0["reason"] = .string("engine"); $0["hypothesis"] = .null }
        var failedB = failedA; failedB["runID"] = .string("TEST-run-B")
        let x = try f.writeRun(failedA, name: "a.json"), y = try f.writeRun(failedB, name: "b.json")
        let text = try f.check(results: x, against: y)
        XCTAssertTrue(text.contains("both-success=0")); XCTAssertTrue(text.contains("bilateral-failed=1")); XCTAssertTrue(text.contains("mean-paired-WER-delta=unavailable"))
        EvalCorpusFixture.mutateRow(&failedB) { $0["status"] = .string("skipped"); $0["reason"] = .string("policy"); $0["seconds"] = .null }
        let mixed = try f.check(results: x, against: f.writeRun(failedB, name: "b.json"))
        XCTAssertTrue(mixed.contains("unilateral-failed=1")); XCTAssertTrue(mixed.contains("B-skipped=1"))
    }
}
