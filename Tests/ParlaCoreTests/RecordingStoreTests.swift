import XCTest
@testable import ParlaCore

final class RecordingStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-recordings-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(keepAll: Bool = false) -> RecordingStore {
        RecordingStore(directory: dir, keepAll: keepAll)
    }

    private func tone(_ count: Int = 1600) -> [Float] {
        (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    }

    // MARK: - Write

    /// The whole eval-corpus claim rests on this: what lands on disk has to be
    /// the same 16 kHz mono WAV `eval/cases` holds, readable by the same loader.
    func testStashWritesWAVReadableByEval() throws {
        let url = try XCTUnwrap(store().stash(tone()))
        XCTAssertEqual(url.pathExtension, "wav")
        let back = try Eval.loadSamples(url: url)
        XCTAssertEqual(back.count, 1600)
        // 16-bit quantization, not a re-encode: the waveform must survive.
        for (a, b) in zip(tone(), back) { XCTAssertEqual(a, b, accuracy: 0.001) }
    }

    func testStashOfEmptyAudioWritesNothing() {
        XCTAssertNil(store().stash([]))
        XCTAssertTrue(store().recordings().isEmpty)
    }

    /// Two stashes only collide when both land in the same millisecond, so simply
    /// stashing twice exercises the dodge on maybe half of runs and silently
    /// proves nothing on the rest. Claim every name this second and the next can
    /// produce instead: the stash then cannot help but find its own name taken.
    func testStashDodgesAnExistingRecordingInsteadOfOverwritingIt() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        for second in [now, now.addingTimeInterval(1)] {
            let stem = RecordingStore.name(second).dropLast(3) // …-HHmmss-, minus the SSS
            for ms in 0..<1000 {
                try Data().write(to: dir.appendingPathComponent("\(stem)\(String(format: "%03d", ms)).wav"))
            }
        }
        // A failure here means the stash took more than a second, which is its own
        // bug report — it never means the collision path went untested.
        let url = try XCTUnwrap(store().stash(tone()))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-1.wav"), url.lastPathComponent)
        XCTAssertEqual(try Eval.loadSamples(url: url).count, 1600)
        // And the name it dodged still holds the file that was there: the point of
        // the dodge is that the earlier recording is not what pays for the clash.
        let claimed = dir.appendingPathComponent(
            url.lastPathComponent.replacingOccurrences(of: "-1.wav", with: ".wav"))
        XCTAssertEqual(try Data(contentsOf: claimed).count, 0)
    }

    // MARK: - Resolve

    func testTranscriptDeletesTheRecording() throws {
        let s = store()
        let url = try XCTUnwrap(s.stash(tone()))
        s.resolve(url, transcript: "hello there", secure: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The Handy #1332 case: no transcript came back, so the audio is the only
    /// thing left that proves the dictation happened.
    func testNoTranscriptKeepsTheRecording() throws {
        let s = store()
        let url = try XCTUnwrap(s.stash(tone()))
        s.resolve(url, transcript: nil, secure: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        s.resolve(url, transcript: "", secure: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Focus moved into a password field between fn-down and landing. The
    /// reducer drops the transcript; this must drop the audio, in corpus mode
    /// too — that gate is not allowed to be a way past this rule.
    func testSecureDeletesTheRecordingEvenInCorpusMode() throws {
        for keepAll in [false, true] {
            let s = store(keepAll: keepAll)
            let url = try XCTUnwrap(s.stash(tone()))
            s.resolve(url, transcript: "hunter2", secure: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "secure recording survived (keepAll: \(keepAll))")
            XCTAssertTrue(s.recordings().isEmpty)
        }
    }

    // MARK: - Corpus mode

    func testCorpusModeKeepsSuccessesWithAHypothesisSidecar() throws {
        let s = store(keepAll: true)
        let url = try XCTUnwrap(s.stash(tone()))
        s.resolve(url, transcript: "hello there", secure: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let hyp = dir.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".hyp.txt")
        XCTAssertEqual(try String(contentsOf: hyp, encoding: .utf8), "hello there")
        // .raw.txt is what parla-eval scores the ASR leg against, and it has to
        // be what a human heard — never whisper's own guess.
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(written.contains { $0.hasSuffix(".raw.txt") })
    }

    func testSidecarIsDeletedWithItsRecording() throws {
        let s = store(keepAll: true)
        let url = try XCTUnwrap(s.stash(tone()))
        s.resolve(url, transcript: "hello", secure: false)
        s.clear()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: - Retention

    func testPruneDropsOnlyWhatIsPastRetention() throws {
        let s = store()
        let old = try XCTUnwrap(s.stash(tone()))
        let fresh = try XCTUnwrap(s.stash(tone()))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Double(RecordingStore.retentionDays + 1) * 86_400)],
            ofItemAtPath: old.path)
        XCTAssertEqual(s.prune(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// Exactly at the boundary the file stays: retention is "older than N days",
    /// so a 7-day-old recording on a 7-day policy is not yet expired.
    func testPruneKeepsAFileExactlyAtTheBoundary() throws {
        let s = store()
        let url = try XCTUnwrap(s.stash(tone()))
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-Double(RecordingStore.retentionDays) * 86_400)],
            ofItemAtPath: url.path)
        XCTAssertEqual(s.prune(now: now), 0)
    }

    func testSummaryCountsAndSizesWhatIsThere() throws {
        let s = store()
        XCTAssertEqual(s.summary(), RecordingStore.Summary(count: 0, bytes: 0))
        _ = s.stash(tone())
        let summary = s.summary()
        XCTAssertEqual(summary.count, 1)
        XCTAssertGreaterThan(summary.bytes, 3200) // 1600 frames × 16-bit + header
    }

    func testClearEmptiesTheFolder() throws {
        let s = store()
        _ = s.stash(tone())
        _ = s.stash(tone())
        s.clear()
        XCTAssertTrue(s.recordings().isEmpty)
        XCTAssertEqual(s.summary().count, 0)
    }

    func testNamesSortNewestFirst() {
        let early = RecordingStore.name(Date(timeIntervalSince1970: 1_000_000))
        let late = RecordingStore.name(Date(timeIntervalSince1970: 1_000_060))
        XCTAssertLessThan(early, late)
    }
}
