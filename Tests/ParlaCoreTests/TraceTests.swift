import CoreAudio
import XCTest
@testable import ParlaCore

final class TraceTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testLineIsEmptyWithoutStamps() {
        XCTAssertEqual(Trace.line(stamps: [], transport: "usb"), "")
    }

    func testLineDeltasAreRelativeToThePreviousStamp() {
        let line = Trace.line(stamps: [
            ("fn_down", 10 * ms),
            ("recorder_start_returned", 22 * ms),
            ("first_pcm_callback", 110 * ms),
        ], transport: "usb")
        XCTAssertEqual(line, "parla-trace transport=usb fn_down=0ms "
            + "recorder_start_returned=+12.0ms first_pcm_callback=+88.0ms total=100.0ms")
    }

    func testLineSortsByTimestampNotInsertionOrder() {
        let line = Trace.line(stamps: [
            ("landed", 5 * ms),
            ("fn_down", 1 * ms),
        ], transport: "builtin")
        XCTAssertEqual(line, "parla-trace transport=builtin fn_down=0ms landed=+4.0ms total=4.0ms")
    }

    func testSingleStampHasZeroTotal() {
        XCTAssertEqual(Trace.line(stamps: [("fn_down", 7 * ms)], transport: "unknown"),
                       "parla-trace transport=unknown fn_down=0ms total=0.0ms")
    }

    // MARK: - Recording

    func testFirstStampWins() {
        let trace = Trace()
        trace.mark(.fnDown, at: 0)
        trace.mark(.firstPCM, at: 90 * ms)
        trace.mark(.firstPCM, at: 200 * ms) // every later tap buffer
        XCTAssertEqual(trace.take(),
                       "parla-trace transport=unknown fn_down=0ms first_pcm_callback=+90.0ms total=90.0ms")
    }

    func testFnDownStartsANewDictation() {
        let trace = Trace()
        trace.mark(.fnDown, at: 0)
        trace.mark(.firstPCM, at: 90 * ms)
        trace.mark(.fnDown, at: 500 * ms) // next press: previous stamps must not leak in
        trace.mark(.landed, at: 600 * ms)
        XCTAssertEqual(trace.take(),
                       "parla-trace transport=unknown fn_down=0ms landed=+100.0ms total=100.0ms")
    }

    func testTakeClearsStampsButKeepsTransport() {
        let trace = Trace()
        trace.setTransport("bluetooth")
        trace.mark(.fnDown, at: 0)
        XCTAssertFalse(trace.take().isEmpty)
        XCTAssertEqual(trace.take(), "")
        trace.mark(.fnUp, at: 3 * ms)
        XCTAssertEqual(trace.take(), "parla-trace transport=bluetooth fn_up=0ms total=0.0ms")
    }

    func testTransportNames() {
        XCTAssertEqual(Trace.transportName(kAudioDeviceTransportTypeBuiltIn), "builtin")
        XCTAssertEqual(Trace.transportName(kAudioDeviceTransportTypeUSB), "usb")
        XCTAssertEqual(Trace.transportName(kAudioDeviceTransportTypeBluetooth), "bluetooth")
        XCTAssertEqual(Trace.transportName(kAudioDeviceTransportTypeBluetoothLE), "bluetooth_le")
        XCTAssertEqual(Trace.transportName(0), "unknown")
    }

    /// The gate is the whole point: without PARLA_TRACE the call sites — one of
    /// them on the audio thread — must record nothing at all.
    func testStaticFacadeIsInertWhenDisabled() throws {
        try XCTSkipIf(Trace.enabled, "PARLA_TRACE=1: the facade is live")
        Trace.mark(.fnDown)
        Trace.setTransport("usb")
        Trace.flush()
        XCTAssertEqual(Trace.shared.take(), "")
    }
}
