import XCTest
import whisper
@testable import ParlaCore

/// Fake C operations under the production C params/abort/index mapper, never a model.
final class TimedNativeProbe: @unchecked Sendable {
    var texts: [UnsafeMutablePointer<CChar>?] = []
    var starts: [Int64], ends: [Int64]
    var countOverride: Int32?
    var multilingual = true, layers: Int32 = 6, vocab: Int32 = 51_864
    var status: Int32 = 0, pollAbort = false
    var calls = 0, probes = 0, releases = 0, admissions = 0
    var events: [String] = []
    var params: [whisper_full_params] = []
    var languages: [String] = [], prompts: [String?] = [], sampleCounts: [Int32] = []
    var hold: (() -> Void)?
    init(bytes: [[UInt8]?] = [Array("A & B --> <v X>".utf8), Array("second".utf8)],
         starts: [Int64] = [100, 700], ends: [Int64] = [200, 800], terminated: Bool = true) {
        self.starts = starts; self.ends = ends
        for bytes in bytes {
            guard var bytes else { texts.append(nil); continue }
            if terminated { bytes.append(0) }
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
            texts.append(pointer)
        }
    }
    deinit { for pointer in texts { pointer?.deallocate() } }
    func context() -> WhisperCContext {
        var api = WhisperCContext.API()
        api.multilingual = multilingual; api.nTextLayer = layers; api.nVocab = vocab
        api.knowsLanguage = { ["en", "hi", "es"].contains($0) }
        api.spokenLanguage = { self.probes += 1; return "en" }
        api.full = { params, samples, count in
            self.calls += 1; self.params.append(params); self.sampleCounts.append(count)
            self.languages.append(String(cString: params.language))
            self.prompts.append(params.initial_prompt.map { String(cString: $0) })
            XCTAssertNotNil(samples)
            self.hold?()
            if self.pollAbort { _ = params.abort_callback?(params.abort_callback_user_data) }
            return self.status
        }
        api.count = { self.events.append("count"); return self.countOverride ?? Int32(self.texts.count) }
        api.text = { index in self.events.append("text\(index)"); return self.texts[Int(index)].map { UnsafePointer($0) } }
        api.start = { index in self.events.append("start\(index)"); return self.starts[Int(index)] }
        api.end = { index in self.events.append("end\(index)"); return self.ends[Int(index)] }
        api.release = { self.releases += 1 }
        return WhisperCContext(api: api)
    }
    func factory() -> RecognitionFactory {
        RecognitionFactory(native: { _, _ in self.context() }, runtime: { .init(nativeVersion: "fake-bottom", buildScope: "wave7c1") },
            metadata: { _ in nil }, admit: { _, _ in self.admissions += 1 })
    }
}

final class RecognitionSegmentsTests: XCTestCase {
    private let audio = [Float](repeating: 0.2, count: 128_000)
    private func request(language: String? = "hi") -> RecognitionRequest {
        var settings = Settings(); settings.whisperModelPath = "/fake/timed.bin"; settings.language = language
        settings.dictionary = ["Frozen"]
        return RecognitionRequest(settings: settings)
    }
    func testProductionCMapperCopiesMatchingIndicesAndRawProjectionSeparately() async throws {
        let p = TimedNativeProbe(bytes: [Array("[MUSIC] Hello".utf8), Array(" world".utf8)])
        var handle: RecognitionHandle? = try await p.factory().acquire(request: request())
        let result = await handle!.timedFileResult(samples: audio)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.segments?.cues.map(\.text), ["[MUSIC] Hello", " world"])
        XCTAssertEqual(result.segments?.cues.map(\.start), [100, 700])
        XCTAssertEqual(result.segments?.cues.map(\.end), [200, 800])
        XCTAssertEqual(p.events, ["count", "text0", "start0", "end0", "text1", "start1", "end1"])
        guard case .pass(let pass) = result.provenance else { return XCTFail("Full pass expected") }
        XCTAssertEqual(pass.pass, .fullFinal); XCTAssertEqual(pass.sampleRange, 0..<128_000)
        XCTAssertEqual(pass.identity, handle?.identity); XCTAssertEqual(pass.instance, handle?.instance)
        handle = nil; XCTAssertEqual(p.releases, 1)
        XCTAssertEqual(result.segments?.cues[1].text, " world", "Copied before native free")
        XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.probes, 0)
    }
    func testNativeFailureObservedAbortAndLateCancelNeverDeliverTiming() async throws {
        for variant in 0..<3 {
            let p = TimedNativeProbe(); var canceled = false
            if variant == 0 { p.status = -7 }
            if variant == 1 { p.pollAbort = true; p.hold = { canceled = true } }
            if variant == 2 { p.hold = { canceled = true } }
            let handle = try await p.factory().acquire(request: request())
            let result = await handle.timedFileResult(samples: audio, shouldAbort: { canceled })
            XCTAssertNil(result.segments); XCTAssertNil(result.text)
            if variant < 2 { XCTAssertTrue(p.events.isEmpty) }
            if variant == 2 {
                guard case .pass(let pass) = result.provenance, case .completed(let evidence) = pass.native else { return XCTFail("Late native success retained") }
                XCTAssertNotNil(evidence.segments); XCTAssertTrue(pass.canceled)
            }
            XCTAssertEqual(p.calls, 1)
        }
    }
    func testObservedAbortCannotBeReenabledByLaterFalsePoll() async throws {
        let p = TimedNativeProbe(); var abort = false
        p.pollAbort = true; p.hold = { abort = true }
        let handle = try await p.factory().acquire(request: request())
        let result = await handle.timedFileResult(samples: audio, shouldAbort: {
            let answer = abort; abort = false; return answer
        })
        XCTAssertNil(result.text); XCTAssertNil(result.segments); XCTAssertTrue(p.events.isEmpty)
        XCTAssertEqual(p.calls, 1)
        guard case .pass(let pass) = result.provenance else { return XCTFail("Expected pass evidence") }
        XCTAssertEqual(pass.native, .canceled)
    }
    func testIndexNilMalformedUTF8AndCountCapsHaveNoPrefixSalvage() async throws {
        let cases = [TimedNativeProbe(bytes: [Array("valid".utf8), nil]),
                     TimedNativeProbe(bytes: [Array("valid".utf8), [0xC3, 0x28]]),
                     TimedNativeProbe(), TimedNativeProbe()]
        cases[2].countOverride = 10_001; cases[3].countOverride = -1
        for p in cases {
            let handle = try await p.factory().acquire(request: request())
            let result = await handle.timedFileResult(samples: audio)
            XCTAssertEqual(result.text, ""); XCTAssertNil(result.segments)
            XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.probes, 0)
        }
    }
    func testNativeByteBudgetIncludesWhitespaceAndBoundedNullScan() async throws {
        // Exactly 1 MiB succeeds; one more native byte fails, including a span
        // which raw marker/whitespace filtering would otherwise discard.
        for extra in [0, 1] {
            let p = TimedNativeProbe(bytes: [Array("X".utf8), Array(repeating: 32, count: 1_048_575 + extra)], starts: [0, 1], ends: [1, 2])
            let handle = try await p.factory().acquire(request: request())
            let result = await handle.timedFileResult(samples: audio)
            XCTAssertEqual(result.text, extra == 0 ? "X" : "")
            XCTAssertEqual(result.segments != nil, extra == 0)
        }
        // A buffer with no null in the entire permitted scan range is bounded.
        let p = TimedNativeProbe(bytes: [Array(repeating: 65, count: 1_048_577)], starts: [0], ends: [1], terminated: false)
        let handle = try await p.factory().acquire(request: request())
        let result = await handle.timedFileResult(samples: audio)
        XCTAssertNil(result.segments); XCTAssertEqual(result.text, "")
    }
    func testNativeSegmentCountBoundaryCountsEvenEmptySpans() async throws {
        let p = TimedNativeProbe(bytes: Array(repeating: [], count: 10_000), starts: Array(repeating: 0, count: 10_000), ends: Array(repeating: 1, count: 10_000))
        let handle = try await p.factory().acquire(request: request())
        let result = await handle.timedFileResult(samples: audio)
        XCTAssertEqual(result.segments?.cues.count, 10_000); XCTAssertEqual(result.text, "")
        XCTAssertThrowsError(try SubtitleExport.encoded(XCTUnwrap(result.segments)))
    }
    func testTimingOnlyInvalidityKeepsWholeBoundedRawWithoutRepairDecode() async throws {
        let cases: [([Int64], [Int64])] = [([-1, 700], [200, 800]), ([100, 700], [100, 800]),
                               ([700, 100], [800, 200]), ([100, 700], [200, 801]),
                               ([0, 700], [3000, 800]), ([100, 700], [200, Int64.max])]
        for (starts, ends) in cases {
            let p = TimedNativeProbe(bytes: [Array("first ".utf8), Array("second".utf8)], starts: starts, ends: ends)
            let handle = try await p.factory().acquire(request: request())
            let result = await handle.timedFileResult(samples: audio)
            XCTAssertEqual(result.text, "first second"); XCTAssertNil(result.segments)
            XCTAssertEqual(p.calls, 1); XCTAssertEqual(p.probes, 0)
        }
    }
    func testKnownClockSourceMathAndGapOverlapOrderAreExact() throws {
        let cues: [RecognitionSegments.Cue] = [.init(text: "one", start: 100, end: 300), .init(text: "equal", start: 100, end: 200),
                                              .init(text: "overlap", start: 200, end: 400), .init(text: "gap", start: 700, end: 800)]
        XCTAssertEqual(try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 128_000, cues: cues).cues, cues)
        for clock in [RecognitionSegments.Clock.unknown] {
            XCTAssertThrowsError(try RecognitionSegments(clock: clock, sourceSampleCount: 128_000, cues: cues))
        }
        for count in [0, 127_999] { XCTAssertThrowsError(try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: count, cues: cues)) }
        XCTAssertThrowsError(try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: Int.max,
            cues: [.init(text: "overflow", start: 0, end: Int64.max)]))
        XCTAssertThrowsError(try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 160,
            cues: Array(repeating: .init(text: "", start: 0, end: 1), count: 10_001)))
        XCTAssertThrowsError(try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 160,
            cues: [.init(text: String(repeating: "é", count: 524_289), start: 0, end: 1)]))
    }
    func testTimingAccessorsRejectOtherPassesRangesAssemblyAndCanceledDelivery() throws {
        let segments = try RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: 16_000,
            cues: [.init(text: "native", start: 0, end: 100)])
        let payload = RecognitionNativeOutcome.completed(.init(text: "raw", segments: segments))
        for kind in [RecognitionPassKind.streamHead, .streamTail, .windowedFinal, .command, .warmup, .hudPreview] {
            let pass = RecognitionPassResult(identity: nil, instance: UUID(), pass: kind, sampleRange: 0..<16_000, native: payload, canceled: false)
            XCTAssertNil(pass.segments)
        }
        for range in [nil, 1..<16_000, 0..<15_999] as [Range<Int>?] {
            let pass = RecognitionPassResult(identity: nil, instance: UUID(), pass: .fullFinal, sampleRange: range, native: payload, canceled: false)
            XCTAssertNil(pass.segments)
        }
        let canceled = RecognitionPassResult(identity: nil, instance: UUID(), pass: .fullFinal, sampleRange: 0..<16_000, native: payload, canceled: true)
        XCTAssertNil(canceled.segments)
        let valid = RecognitionPassResult(identity: nil, instance: UUID(), pass: .fullFinal, sampleRange: 0..<16_000, native: payload, canceled: false)
        XCTAssertEqual(valid.segments, segments)
        XCTAssertNil(RecognitionFinalResult(text: nil, provenance: .pass(valid)).segments)
        XCTAssertNil(RecognitionFinalResult(text: "raw", provenance: .canceled).segments)
    }
}
