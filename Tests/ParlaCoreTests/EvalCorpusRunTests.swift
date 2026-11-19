import XCTest
@testable import ParlaCore

/// Every manifest, tone and reference here is test-authored (`synthetic-signal`,
/// `nonhuman-regression`). None of it is human speech or corpus evidence.
final class EvalCorpusRunTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        // /private/tmp avoids the /tmp symlink, which EvalCorpusIO correctly refuses.
        root = URL(fileURLWithPath: "/private/tmp/parla-corpus-run-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// 16 kHz mono 16-bit PCM. `hz == 0` writes digital silence (gate-skipped).
    private func wav(hz: Double, samples: Int = 8000) -> Data {
        var pcm = Data()
        for i in 0..<samples {
            let value = hz == 0 ? 0 : Int16(9000 * sin(2 * .pi * hz * Double(i) / 16000))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var out = Data("RIFF".utf8)
        out.append(le(UInt32(36 + pcm.count))); out.append(Data("WAVEfmt ".utf8))
        out.append(le(UInt32(16))); out.append(le(UInt16(1))); out.append(le(UInt16(1)))
        out.append(le(UInt32(16000))); out.append(le(UInt32(32000))); out.append(le(UInt16(2))); out.append(le(UInt16(16)))
        out.append(Data("data".utf8)); out.append(le(UInt32(pcm.count))); out.append(pcm)
        return out
    }

    /// Writes a nonhuman-regression manifest with one case per tone, in order.
    private func manifest(tones: [Double]) throws -> String {
        var cases: [EvalCorpusJSON] = []
        for (i, hz) in tones.enumerated() {
            let audio = wav(hz: hz), aHash = EvalCorpusIO.digest(audio)
            try audio.write(to: root.appendingPathComponent("a\(i).wav"))
            var refs: [EvalCorpusJSON] = []
            for role in ["raw", "golden"] {
                let path = "r\(i).\(role).txt", data = Data("test tone \(i)".utf8)
                try data.write(to: root.appendingPathComponent(path))
                refs.append(.object([
                    "path": .string(path), "sha256": .string(EvalCorpusIO.digest(data)), "revision": .string("TEST-ref-v1"),
                    "review": .string("reviewed"), "reviewer": .string("TEST-reviewer"), "reviewedAt": .number("1690000000"),
                    "audioSHA256": .string(aHash), "takeID": .string("TEST-take-\(i)"), "draftOrigin": .string("authored")
                ]))
            }
            cases.append(.object([
                "id": .string("TEST-case-\(i)"), "provenance": .string("synthetic-signal"),
                "takeID": .string("TEST-take-\(i)"), "familyID": .string("TEST-family-\(i)"), "parentIDs": .array([]),
                "lineageComplete": .bool(true), "speakersComplete": .bool(true), "speakerIDs": .array([]), "consentIDs": .array([]),
                "split": .string("development"), "repetitionGroup": .string("TEST-group-\(i)"), "cohorts": .array([.string("TEST-signal")]),
                "audio": .object(["path": .string("a\(i).wav"), "sha256": .string(aHash), "bytes": .number(String(audio.count))]),
                "verbatim": refs[0], "cleaned": refs[1]
            ]))
        }
        let manifest: [String: EvalCorpusJSON] = [
            "version": .number("1"), "corpusID": .string("TEST-synthetic-not-human"), "revision": .string("TEST-manifest-v1"),
            "purpose": .string("nonhuman-regression"), "protocolRevision": .string("TEST-protocol"), "snapshotAt": .number("1700000000"),
            "cohorts": .array([.object(["id": .string("TEST-signal"), "dimension": .string("other")])]),
            "speakers": .array([]), "consents": .array([]), "cases": .array(cases)
        ]
        let path = root.appendingPathComponent("manifest.json").path
        try Data(EvalCorpusFixture.encode(.object(manifest)).utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
    private func options(_ manifest: String) -> EvalCorpusRun.Options {
        .init(manifest: manifest, out: root.appendingPathComponent("run.json").path, runID: "TEST-run",
              configRevision: "TEST-config", whisperModel: nil, context: nil)
    }
    private let engine = EvalCorpusRun.Engine(id: "TEST-engine", revision: "unknown", configRevision: "TEST-config")
    private func pass(_ native: RecognitionNativeOutcome, canceled: Bool = false) -> RecognitionPassResult {
        RecognitionPassResult(identity: nil, instance: UUID(), pass: .fullFinal, sampleRange: nil, native: native, canceled: canceled)
    }
    private struct Row: Decodable { let caseID: String, status: String, reason: String?, hypothesis: String?, seconds: Double? }
    private struct Saved: Decodable { let rows: [Row] }

    func testProducedRunIsAdmittedByExistingChecker() async throws {
        let path = try manifest(tones: [440, 660])
        let options = self.options(path)
        let report = try await EvalCorpusRun.produce(options, engine: engine) { _ in self.pass(.completed(.init(text: " test tone "))) }
        XCTAssertTrue(report.contains("run=TEST-run route=asr-only"), report)
        // The existing checker, run independently, admits the produced file.
        let checked = try EvalCorpus.evaluate(.init(manifest: path, results: options.out, against: nil))
        XCTAssertTrue(checked.contains("scored=2"), checked)
        let attrs = try FileManager.default.attributesOfItem(atPath: options.out)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTypedOutcomesMapToSchemaRows() async throws {
        let path = try manifest(tones: [440, 550, 660, 770, 0])
        let options = self.options(path)
        var outcomes = [pass(.completed(.init(text: " hello "))), pass(.completed(.init(text: ""))),
                        pass(.failed(.nativeDecode)), pass(.canceled, canceled: true)]
        _ = try await EvalCorpusRun.produce(options, engine: engine) { _ in outcomes.removeFirst() }
        XCTAssertTrue(outcomes.isEmpty, "the gate-skipped case never reaches the recognizer")
        let rows = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: options.out))).rows
        XCTAssertEqual(rows.map(\.caseID), (0..<5).map { "TEST-case-\($0)" }, "manifest order")
        XCTAssertEqual(rows.map(\.status), ["success", "success", "failed", "failed", "skipped"])
        XCTAssertEqual(rows.map(\.reason), [nil, nil, "decode", "cancelled", "policy"])
        XCTAssertEqual(rows.map(\.hypothesis), ["hello", "", nil, nil, nil])
        XCTAssertNil(rows[4].seconds); XCTAssertNotNil(rows[2].seconds)
        _ = try EvalCorpus.evaluate(.init(manifest: path, results: options.out, against: nil))
    }

    func testMissingASRConsentIsRefusedBeforeRecognition() async throws {
        let f = try EvalCorpusFixture()
        f.mutateConsent { $0["uses"] = .array([.string("binding-check"), .string("reference-review")]) }
        // A real tone, so only the consent check stands between the case and the recognizer.
        let audio = wav(hz: 440), aHash = EvalCorpusIO.digest(audio)
        try audio.write(to: f.root.appendingPathComponent("a0.wav"))
        f.mutateCase { c in
            c["audio"] = .object(["path": .string("a0.wav"), "sha256": .string(aHash), "bytes": .number(String(audio.count))])
            for role in ["verbatim", "cleaned"] {
                guard case .object(var ref) = c[role] else { return }
                ref["audioSHA256"] = .string(aHash); c[role] = .object(ref)
            }
        }
        let path = try f.writeManifest()
        let options = EvalCorpusRun.Options(manifest: path, out: f.root.appendingPathComponent("run.json").path, runID: "TEST-run",
                                            configRevision: "TEST-config", whisperModel: nil, context: nil)
        var called = false
        do {
            _ = try await EvalCorpusRun.produce(options, engine: engine) { _ in called = true; return nil }
            XCTFail("missing asr consent must refuse")
        } catch {}
        XCTAssertFalse(called, "no audio reaches the recognizer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.out))
    }

    func testOtherFailuresAndMissingEngineAreEngineRows() {
        XCTAssertEqual(EvalCorpusRun.row(nil).reason, "engine")
        XCTAssertEqual(EvalCorpusRun.row(pass(.failed(.clientUnavailable))).reason, "engine")
        XCTAssertEqual(EvalCorpusRun.row(pass(.completed(.init(text: "x")), canceled: true)).reason, "cancelled")
        XCTAssertEqual(EvalCorpusRun.engine(modelPath: "/nowhere/custom.bin", configRevision: "c"),
                       .init(id: "custom", revision: "unknown", configRevision: "c"))
        for model in ModelCatalog.all {
            let engine = EvalCorpusRun.engine(modelPath: ModelCatalog.directory.appendingPathComponent(model.filename).path, configRevision: "c")
            XCTAssertEqual(engine.id, model.id.replacingOccurrences(of: ".", with: "-"))
            XCTAssertEqual(engine.revision, String(model.sha256.prefix(16)))
            XCTAssertNoThrow(try EvalCorpusJSON.string(engine.id).id()); XCTAssertNoThrow(try EvalCorpusJSON.string(engine.revision).id())
        }
    }

    func testStrictArguments() {
        let ok = ["corpus-run", "m.json", "--out", "/private/tmp/o.json", "--run-id", "r", "--config-revision", "c"]
        XCTAssertNoThrow(try EvalCorpusRun.options(ok))
        for bad in [ok + ["--unknown", "x"], ok + ["--out", "p.json"], Array(ok.prefix(2)) + Array(ok.suffix(4)),
                    ["verify"] + ok, ok.map { $0 == "r" ? "bad id" : $0 }, ok.map { $0 == "/private/tmp/o.json" ? "/private/tmp/o.txt" : $0 }] {
            XCTAssertThrowsError(try EvalCorpusRun.options(bad), "\(bad)")
        }
    }
}
