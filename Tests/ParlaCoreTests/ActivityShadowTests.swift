import XCTest
@testable import ParlaCore

final class ActivityShadowTests: XCTestCase {
    private func analyze(_ pcm: [Float], abort: () -> Bool = { false }, clock: () -> Double = { 0 }) -> DiagnosticActivityShadow {
        pcm.withUnsafeBufferPointer { ActivityShadow.analyze($0, shouldAbort: abort, clock: clock) }
    }
    private func tone(_ frames: Int, amplitude: Float = 0.1) -> [Float] {
        (0..<(frames * 320)).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }
    func testLegacySettingAndFrozenPermissionHasOnlyNewCaptureAuthority() throws {
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).energyActivityShadowEnabled)
        var settings = Settings(); settings.energyActivityShadowEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).energyActivityShadowEnabled)
        let machine = DictationSession(diagnostics: nil)
        _ = machine.handle(.startDictation(settings: settings, cleanupConfigured: false, live: false))
        let permission = try XCTUnwrap(machine.activityShadowPermission)
        _ = machine.handle(.recorderStarted(gen: machine.gen)); _ = machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
        _ = machine.handle(.stopRequested)
        XCTAssertTrue(permission.isCurrent)
        machine.revokeActivityShadow(); XCTAssertFalse(permission.isCurrent)
        _ = machine.handle(.startDictation(settings: settings, cleanupConfigured: false, live: false))
        XCTAssertTrue(try XCTUnwrap(machine.activityShadowPermission).isCurrent)
        XCTAssertFalse(permission.isCurrent)
        let second = try XCTUnwrap(machine.activityShadowPermission)
        _ = machine.handle(.cancelRequested(silent: false))
        XCTAssertFalse(second.isCurrent)
    }
    func testStartOffExcludedModesAndSecureDoNotAcquirePermission() {
        var settings = Settings()
        XCTAssertNil(DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: false, diagnostics: nil).activityShadowPermission)
        settings.energyActivityShadowEnabled = true
        for session in [
            DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: false, live: true, diagnostics: nil),
            DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: false, diagnostics: nil, delivery: .resultOnly),
            DictationSession.Session(gen: 1, mode: .command(selection: "canary"), settings: settings, cleanupConfigured: true, diagnostics: nil),
            DictationSession.Session(gen: 1, mode: .savedPreset(selection: "canary", preset: .init(name: "x", instruction: "x")), settings: settings, cleanupConfigured: true, diagnostics: nil),
            DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: false, focus: .secure, diagnostics: nil)
        ] { XCTAssertNil(session.activityShadowPermission) }
        settings.outputMode = .selectedPreset
        XCTAssertNil(DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: true, diagnostics: nil).activityShadowPermission)
    }
    func testEmptyExactDigitalZeroAndSubnumericNonzeroAreDifferent() {
        XCTAssertEqual(analyze([]).reason, .empty)
        let zero = analyze([Float](repeating: 0, count: 6401))
        XCTAssertEqual(zero.reason, .digitalZero); XCTAssertTrue(zero.wouldRejectProxy)
        XCTAssertEqual(zero.frames, 21); XCTAssertEqual(zero.sampleVisits, 6401)
        XCTAssertEqual(zero.validated(originalCount: 6401), zero)
        for tiny in [Float.leastNonzeroMagnitude, Float.leastNormalMagnitude, Float(1e-10)] {
            let f = analyze(tone(30, amplitude: tiny)); XCTAssertEqual(f.state, .noDecision); XCTAssertFalse(f.wouldRejectProxy)
        }
    }
    func testWholeComparisonAbstainsOnRawNonfiniteClippedOutscaleAndDCWithoutMutation() {
        for bits: UInt32 in [0x7fc00001, 0x7f800000, 0xff800000, 0x3f800000, 0xbf800000, 0x40000000] {
            for index in [0, 4000, 7999] {
                var pcm = tone(25); pcm[index] = Float(bitPattern: bits)
                let before = pcm.map(\.bitPattern), f = analyze(pcm)
                XCTAssertEqual(f.state, .noDecision); XCTAssertNil(f.activity); XCTAssertNil(f.retained)
                XCTAssertFalse(f.wouldRejectProxy); XCTAssertEqual(pcm.map(\.bitPattern), before)
            }
        }
        XCTAssertEqual(analyze([Float](repeating: 0.25, count: 8000)).reason, .dcDominated)
        XCTAssertEqual(analyze([Float](repeating: 0.2, count: 8000)).state, .noDecision)
    }
    func testNoiseAndContinuousLowContrastDoNotImplySpeechAbsence() {
        XCTAssertEqual(analyze(tone(100)).reason, .lowContrast)
        let pcm = (0..<32000).map { Float(($0 * 17) % 31 - 15) / 1000 }
        let f = analyze(pcm); XCTAssertEqual(f.state, .noDecision); XCTAssertFalse(f.wouldRejectProxy)
    }
    func testOneFrameAnchorPaddingAndAllInternalGapsRemainInSingleEnvelope() {
        var pcm = [Float](repeating: 0, count: 64000)
        pcm.replaceSubrange(16000..<16320, with: tone(1))
        pcm.replaceSubrange(40000..<40320, with: tone(1))
        let f = analyze(pcm)
        XCTAssertEqual(f.activity, .init(16000, 40320)); XCTAssertEqual(f.retained, .init(12000, 44320))
        XCTAssertEqual(f.runs, 2); XCTAssertEqual(f.state, .complete)
        XCTAssertEqual(f.validated(originalCount: pcm.count), f)
    }
    func testShortClipNeverSuggestsTrimAndPartialFrameUsesActualDenominator() {
        var pcm = [Float](repeating: 0, count: 3201); pcm[3199] = -0.1; pcm[3200] = 0.1
        // Last one-sample frame is entirely DC: abstain, rather than divide by 320.
        XCTAssertEqual(analyze(pcm).reason, .dcDominated)
        let short = [Float](repeating: 0, count: 3200) + tone(1)
        let f = analyze(short); XCTAssertEqual(f.reason, .shortRetained); XCTAssertNil(f.retained)
        var partial = [Float](repeating: 0, count: 16000)
        partial.replaceSubrange(12800..<13120, with: tone(1))
        partial += [0.1, -0.1]
        let p = analyze(partial); XCTAssertEqual(p.frames, 51); XCTAssertEqual(p.activity?.end, 16002)
        XCTAssertEqual(p.retained?.end, 16002)
    }
    func testPaddingSavingsEqualityAndNearBandExtendEdges() {
        // Bin 0's upper edge is the reference for clips with >=20% zero frames.
        let reference = ActivityShadow.upperEdge(0)
        let band = Float(sqrt(reference * 3)), high = Float(sqrt(reference * 8))
        var pcm = [Float](repeating: 0, count: 64000)
        pcm.replaceSubrange(8000..<8320, with: tone(1, amplitude: band))
        pcm.replaceSubrange(16000..<16320, with: tone(1, amplitude: high))
        let f = analyze(pcm)
        XCTAssertEqual(f.activity?.start, 8000); XCTAssertEqual(f.retained?.start, 0)
        var equality = [Float](repeating: 0, count: 40000)
        equality.replaceSubrange(12160..<12480, with: tone(1))
        XCTAssertEqual(analyze(equality).removedLeading, 8160)
        equality = [Float](repeating: 0, count: 40000)
        equality.replaceSubrange(11840..<12160, with: tone(1))
        XCTAssertEqual(analyze(equality).removedLeading, 0)
        XCTAssertEqual(ActivityShadow.bin(pow(2, -24)), 64)
        XCTAssertEqual(ActivityShadow.upperEdge(64), pow(2, -24 + 48.0 / 128))
        XCTAssertEqual(ActivityShadow.bin(1), 127)
    }
    func testWholeClipTwentiethPercentileUsesCeilingRank() {
        for (frames, zeroFrames, reason) in [(20, 4, DiagnosticActivityShadow.Reason.activity), (20, 3, .lowContrast), (21, 4, .lowContrast), (21, 5, .activity)] {
            let pcm = [Float](repeating: 0, count: zeroFrames * 320) + tone(frames - zeroFrames)
            XCTAssertEqual(analyze(pcm).reason, reason)
        }
    }
    func test128RunsRetainedAnd129AbstainsWithoutTruncation() {
        for runs in [128, 129] {
            var pcm = [Float](repeating: 0, count: 16000)
            for _ in 0..<runs { pcm += tone(1); pcm += [Float](repeating: 0, count: 320) }
            pcm += [Float](repeating: 0, count: 16000)
            let f = analyze(pcm)
            XCTAssertEqual(f.reason, runs == 128 ? .activity : .runLimit)
            if runs == 129 { XCTAssertNil(f.activity); XCTAssertNil(f.retained) }
        }
    }
    func testTenMinuteBoundsAndOverCapReadsNoPrefixIncludingRawNaN() {
        let pcm = [Float](repeating: 0, count: ActivityShadow.maximumSamples)
        let f = analyze(pcm)
        XCTAssertEqual(f.reason, .digitalZero); XCTAssertEqual(f.sampleVisits, 9600000)
        XCTAssertEqual(f.frames, 30000); XCTAssertEqual(f.classifiedFrames, 30000)
        XCTAssertLessThanOrEqual(f.histogramVisits, 128)
        XCTAssertEqual(ActivityShadow.declaredArrayPayloadBytes, 241024)
        var over = pcm; over.append(Float(bitPattern: 0x7fc00001))
        var clockReads = 0
        let excess = analyze(over, clock: { clockReads += 1; return 0 })
        XCTAssertEqual(excess.reason, .overLimit); XCTAssertEqual(excess.sampleVisits, 0); XCTAssertEqual(clockReads, 0)
        XCTAssertEqual(over.last?.bitPattern, 0x7fc00001)
    }
    func testDeadlineNonfiniteBackwardAndCancellationInBothPasses() {
        let pcm = [Float](repeating: 0, count: 6400)
        for bad in [Double.nan, Double.infinity, -1, 0.050] {
            var reads = 0
            let f = analyze(pcm, clock: { reads += 1; return reads == 1 ? 0 : bad })
            XCTAssertEqual(f.reason, bad == 0.050 ? .deadline : .invalidClock)
            XCTAssertFalse(f.wouldRejectProxy)
        }
        for threshold in [3, 24] { // feature frame and classification frame respectively.
            var polls = 0
            let f = analyze(pcm, abort: { polls += 1; return polls >= threshold })
            XCTAssertEqual(f.reason, .canceled); XCTAssertLessThanOrEqual(f.sampleVisits, pcm.count)
            XCTAssertNil(f.retained); XCTAssertFalse(f.wouldRejectProxy)
        }
    }
    func testMalformedProducerValidationAnd2048ByteAllowlist() throws {
        let pcm = [Float](repeating: 0, count: 16000) + tone(1) + [Float](repeating: 0, count: 16000)
        let fact = analyze(pcm)
        for mutate: (inout DiagnosticActivityShadow) -> Void in [
            { $0.activity = .init(-1, 10) }, { $0.retained = .init(0, Int.max) },
            { $0.suggestionApplied = true }, { $0.frames = 30001 }, { $0.revision = 999 },
            { $0.actual.prefixSamples = Int.max }, { $0.removedLeading = 1 },
            { $0.retained = .init(16000, 32320); $0.removedLeading = 16000; $0.removedTrailing = 0 }
        ] {
            var bad = fact; mutate(&bad)
            let valid = bad.validated(originalCount: pcm.count)
            XCTAssertEqual(valid.reason, .invalidResult); XCTAssertNil(valid.activity); XCTAssertNil(valid.retained)
        }
        let bytes = try JSONEncoder().encode(fact)
        XCTAssertLessThanOrEqual(bytes.count, 2048)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), Set(["revision", "state", "reason", "originalSamples", "frames", "runs", "sampleVisits", "classifiedFrames", "histogramVisits", "roundingClamped", "activity", "retained", "removedLeading", "removedTrailing", "wouldRejectProxy", "suggestionApplied", "actual"]))
    }
}
