import AVFoundation
import CoreAudio
import XCTest
@testable import ParlaCore

final class AudioRecorderTests: XCTestCase {
    private final class SilentEngine: MicrophoneCaptureEngine {
        var isRunning = false
        var route = MicrophoneRoute(name: "Camo Microphone")
        var changed: (() -> Void)?
        func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws {
            isRunning = true; self.changed = changed
        }
        func stop() { isRunning = false }
    }

    func testSilentTakeReportsReasonDeviceAndRouteChange() throws {
        var clock: TimeInterval = 100
        let engine = SilentEngine()
        let recorder = AudioRecorder(engine: engine, captureClock: { clock }, scheduleRoute: { _, _ in {} })
        try recorder.start()
        engine.changed?()                      // a call grabbing the route mid-take
        recorder.append([Float](repeating: 0, count: 32_000))
        clock += 3
        _ = recorder.stop()
        let summary = try XCTUnwrap(recorder.lastCapture)
        let report = summary.noRecognitionReport()
        XCTAssertTrue(report.log.contains("reason=silence samples=32000"), report.log)
        XCTAssertTrue(report.log.contains("held=3.00s"), report.log)
        XCTAssertTrue(report.log.contains("firstPCM=0"), report.log)
        XCTAssertTrue(report.log.contains("device=\"Camo Microphone\""), report.log)
        XCTAssertTrue(report.log.contains("requested=system default routeChanged=1"), report.log)
        XCTAssertEqual(report.hud, "No sound from Camo Microphone — in use by another app?")

        var tap = AudioRecorder.CaptureSummary(); tap.sampleCount = 3_000; tap.heldSeconds = 0.3
        XCTAssertTrue(tap.noRecognitionReport().log.contains("reason=minimumDuration"))
        XCTAssertNil(tap.noRecognitionReport().hud, "an accidental tap stays quiet")
        XCTAssertTrue(AudioRecorder.CaptureSummary().noRecognitionReport().log.contains("reason=noSamples"))
        var emptyTap = AudioRecorder.CaptureSummary(); emptyTap.heldSeconds = 0.1
        XCTAssertNil(emptyTap.noRecognitionReport().hud, "a zero-sample tap stays quiet")
        var preRollTap = AudioRecorder.CaptureSummary(); preRollTap.sampleCount = 8_000; preRollTap.heldSeconds = 0.2
        XCTAssertTrue(preRollTap.noRecognitionReport().log.contains("reason=silence"))
        XCTAssertNil(preRollTap.noRecognitionReport().hud, "a silent tap carrying pre-roll stays quiet")
    }

    func testSummaryReportsTheUIDTheCaptureWasBoundWith() throws {
        let engine = SilentEngine()
        let recorder = AudioRecorder(engine: engine, scheduleRoute: { _, _ in {} })
        recorder.inputDeviceUID = "mic-A"
        try recorder.start()
        recorder.inputDeviceUID = "mic-B"       // picked mid-take; capture stays on A
        _ = recorder.stop()
        XCTAssertEqual(recorder.lastCapture?.requestedUID, "mic-A")
    }

    func testRMSEmptyIsZero() {
        XCTAssertEqual(AudioRecorder.rms([]), 0)
    }

    func testRMSZerosIsZero() {
        XCTAssertEqual(AudioRecorder.rms([Float](repeating: 0, count: 128)), 0)
    }

    func testRMSConstantSignal() {
        XCTAssertEqual(AudioRecorder.rms([Float](repeating: 0.5, count: 256)), 0.5, accuracy: 0.001)
    }

    func testSnapshotOfFreshRecorderIsEmpty() {
        XCTAssertTrue(AudioRecorder().snapshot().isEmpty)
    }

    func testFreshRecorderHasNoConversionFailures() {
        XCTAssertEqual(AudioRecorder().conversionFailures(), 0)
    }

    func testFailedBufferIsCountedNotAppended() {
        let recorder = AudioRecorder()
        recorder.append(nil)
        XCTAssertEqual(recorder.conversionFailures(), 1)
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    /// The cap is what keeps an unattended hands-free latch from growing the
    /// buffer (and the Metal load) without bound.
    func testAppendStopsAtSampleCap() {
        let recorder = AudioRecorder()
        var reasons: [AudioRecorder.EndReason] = []
        recorder.onEnd = { reasons.append($0) }
        let chunk = [Float](repeating: 0.1, count: 16_000) // 1s
        for _ in 0..<(AudioRecorder.maxSamples / chunk.count + 5) { recorder.append(chunk) }
        let count = recorder.snapshot().count
        XCTAssertGreaterThanOrEqual(count, AudioRecorder.maxSamples)
        XCTAssertLessThan(count, AudioRecorder.maxSamples + chunk.count)
        XCTAssertEqual(reasons, [.sampleLimit]) // once, not once per late buffer
    }

    func testEndCaptureDropsLaterBuffersAndFiresOnce() {
        let recorder = AudioRecorder()
        var reasons: [AudioRecorder.EndReason] = []
        recorder.onEnd = { reasons.append($0) }
        recorder.append([1, 2, 3])
        recorder.endCapture(.deviceLost)
        recorder.endCapture(.sampleLimit)
        recorder.append([4, 5, 6])
        recorder.append(nil)
        XCTAssertEqual(recorder.snapshot(), [1, 2, 3]) // what was captured survives
        XCTAssertEqual(recorder.conversionFailures(), 0)
        XCTAssertEqual(reasons, [.deviceLost])
    }

    // MARK: - Pre-roll ring

    /// Values 0..<count, so a test can tell newest from oldest by inspection.
    private func ramp(_ count: Int) -> [Float] { (0..<count).map(Float.init) }

    func testPreRollKeepsTheNewestPrependWindow() {
        var ring = PreRollRing()
        ring.write(ramp(20_000), now: 10)
        let out = ring.take(now: 10, mediaPlaying: false)
        // Ring trims to its 1.0s capacity (4000..<20000); take yields the
        // newest 0.45s of that.
        XCTAssertEqual(out.count, PreRollRing.prependSamples)
        XCTAssertEqual(out.first, Float(20_000 - PreRollRing.prependSamples))
        XCTAssertEqual(out.last, 19_999)
    }

    func testPreRollShorterThanTheWindowIsReturnedWhole() {
        var ring = PreRollRing()
        ring.write([1, 2, 3], now: 5)
        XCTAssertEqual(ring.take(now: 5, mediaPlaying: false), [1, 2, 3])
    }

    /// Successive tap buffers must read as one stream, not as separate writes.
    func testPreRollWritesAccumulateAcrossBuffers() {
        var ring = PreRollRing()
        ring.write([1, 2], now: 1)
        ring.write([3, 4], now: 2)
        XCTAssertEqual(ring.take(now: 2, mediaPlaying: false), [1, 2, 3, 4])
    }

    /// A prepend that happened twice would duplicate speech at the splice.
    func testTakeEmptiesTheRing() {
        var ring = PreRollRing()
        ring.write([1, 2, 3], now: 5)
        _ = ring.take(now: 5, mediaPlaying: false)
        XCTAssertTrue(ring.take(now: 5, mediaPlaying: false).isEmpty)
    }

    func testEmptyRingYieldsNoPreRoll() {
        var ring = PreRollRing()
        XCTAssertTrue(ring.take(now: 5, mediaPlaying: false).isEmpty)
    }

    /// A tap that stopped feeding leaves audio from a different moment behind.
    func testStalePreRollIsDiscarded() {
        var ring = PreRollRing()
        ring.write([1, 2, 3], now: 100)
        XCTAssertTrue(ring.take(now: 100 + PreRollRing.maxAge + 0.01, mediaPlaying: false).isEmpty)
    }

    func testPreRollAtTheAgeLimitSurvives() {
        var ring = PreRollRing()
        ring.write([1, 2, 3], now: 100)
        XCTAssertEqual(ring.take(now: 100 + PreRollRing.maxAge, mediaPlaying: false), [1, 2, 3])
    }

    /// The same signal, read without consuming the ring: start() uses it to
    /// rebuild a warm engine that claims to be running but has stopped feeding.
    func testRingThatStoppedBeingFedIsStale() {
        var ring = PreRollRing()
        ring.write([1, 2, 3], now: 100)
        XCTAssertFalse(ring.isStale(now: 100 + PreRollRing.maxAge))
        XCTAssertTrue(ring.isStale(now: 100 + PreRollRing.maxAge + 0.01))
    }

    /// Just built or just reset — the first buffer is ~85 ms away. Calling that
    /// stale would cold-rebuild a healthy engine on every quick re-press.
    func testRingNotYetWrittenIsNotStale() {
        var ring = PreRollRing()
        XCTAssertFalse(ring.isStale(now: 1_000))
        ring.write([1], now: 100)
        ring.reset()
        XCTAssertFalse(ring.isStale(now: 1_000))
    }

    /// Media playing at press time means the ring holds the user's speakers, not
    /// the user — and it is dropped, not trimmed.
    func testPreRollDiscardedWhenMediaWasPlaying() {
        var ring = PreRollRing()
        ring.write([1, 2, 3], now: 5)
        XCTAssertTrue(ring.take(now: 5, mediaPlaying: true).isEmpty)
        XCTAssertTrue(ring.take(now: 5, mediaPlaying: false).isEmpty) // dropped, not deferred
    }

    // MARK: - Transport gate

    /// The gate that keeps a warm engine off AirPods (A2DP → HFP downgrade and
    /// the route-change feedback loop, docs/research/03-latency.md §7).
    func testBluetoothTransportsAreGated() {
        XCTAssertTrue(AudioRecorder.isBluetoothTransport(kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(AudioRecorder.isBluetoothTransport(kAudioDeviceTransportTypeBluetoothLE))
    }

    func testWiredTransportsAreNotGated() {
        for raw in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                    kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                    kAudioDeviceTransportTypeUnknown] {
            XCTAssertFalse(AudioRecorder.isBluetoothTransport(raw), "\(raw) should stay warmable")
        }
    }

    // MARK: - Teardown gate

    /// The permanently-silent-mic regression: start()'s cold path builds an
    /// input unit whatever TCC says, and a unit started before the grant
    /// delivers zeros forever. `warm` alone latched that unit, so every later
    /// dictation reused it until relaunch.
    func testEngineBuiltBeforeTheMicGrantIsTornDownEvenWhenWarm() {
        XCTAssertTrue(AudioRecorder.shouldTeardown(warm: true, builtAuthorized: false,
                                                   bluetooth: false, capturedNothing: false))
    }

    /// The whole point of warmth: a legitimately warm engine is kept.
    func testAuthorizedWarmEngineIsKept() {
        XCTAssertFalse(AudioRecorder.shouldTeardown(warm: true, builtAuthorized: true,
                                                    bluetooth: false, capturedNothing: false))
    }

    /// A warm engine that delivered not one sample — pre-roll included — has
    /// stopped feeding its tap. Kept, it would make every later dictation silent
    /// too: the stale-ring check in start() cannot see it once stop() has reset
    /// the ring. Costs one rebuild after a tap too short to span a buffer.
    func testWarmEngineThatCapturedNothingIsTornDown() {
        XCTAssertTrue(AudioRecorder.shouldTeardown(warm: true, builtAuthorized: true,
                                                   bluetooth: false, capturedNothing: true))
    }

    // MARK: - Route change

    /// AVAudioEngine stops itself on a configuration change and nothing restarts
    /// it, so a dictation in flight went on "recording" silence to the end.
    func testRouteChangeMidCaptureResumesOnAStoppedEngine() {
        XCTAssertEqual(AudioRecorder.rebuildAction(live: true, engineRunning: false, resumes: 0), .resumeCapture)
    }

    /// The press itself built a fresh engine after the change (start() does
    /// when the old one stopped): rebuilding again would only cut a hole in it.
    func testRouteChangeMidCaptureLeavesARunningEngineAlone() {
        XCTAssertEqual(AudioRecorder.rebuildAction(live: true, engineRunning: true, resumes: 0), .none)
    }

    /// `isRunning` alone is not proof: an engine can report running and deliver
    /// nothing. Under a capture the tap's own heartbeat is the second opinion.
    func testEngineCountsAsFedOnlyWhileBuffersKeepArriving() {
        XCTAssertTrue(AudioRecorder.recentlyFed(lastFeed: 10, now: 10.1))
        XCTAssertFalse(AudioRecorder.recentlyFed(lastFeed: 10, now: 10 + AudioRecorder.feedGap + 0.01))
        // Just built: its first buffer is still on the way. Not evidence of a stall.
        XCTAssertTrue(AudioRecorder.recentlyFed(lastFeed: nil, now: 10))
    }

    /// A rebuild can provoke the next route change. Idle, that loop only costs
    /// rebuilds; under a capture each lap is a hole in the dictation, so after a
    /// few the capture ends and what was said is finalized.
    func testRouteThatWillNotSettleEndsTheCapture() {
        let limit = AudioRecorder.maxResumes
        XCTAssertEqual(AudioRecorder.rebuildAction(live: true, engineRunning: false, resumes: limit - 1),
                       .resumeCapture)
        XCTAssertEqual(AudioRecorder.rebuildAction(live: true, engineRunning: false, resumes: limit),
                       .endCapture)
    }

    func testRouteChangeWhileIdleRewarms() {
        XCTAssertEqual(AudioRecorder.rebuildAction(live: false, engineRunning: false, resumes: 0), .rewarm)
        XCTAssertEqual(AudioRecorder.rebuildAction(live: false, engineRunning: true, resumes: 0), .rewarm)
    }

    func testColdOrBluetoothStillTearsDown() {
        XCTAssertTrue(AudioRecorder.shouldTeardown(warm: false, builtAuthorized: true,
                                                   bluetooth: false, capturedNothing: false))
        XCTAssertTrue(AudioRecorder.shouldTeardown(warm: true, builtAuthorized: true,
                                                   bluetooth: true, capturedNothing: false))
    }
}
