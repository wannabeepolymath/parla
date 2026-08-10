import XCTest
@testable import ParlaCore

final class AudioRecorderTests: XCTestCase {
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
}
