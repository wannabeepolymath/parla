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
}
