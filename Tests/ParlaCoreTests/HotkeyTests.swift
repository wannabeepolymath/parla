import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    func monitor(_ out: UnsafeMutablePointer<[HotkeyMonitor.Edge]>) -> HotkeyMonitor {
        let m = HotkeyMonitor()
        m.onEdge = { out.pointee.append($0) }
        return m
    }

    /// Drive the pure machine with (keyCode, fnActive, time) flagsChanged events.
    func edges(_ events: [(UInt16, Bool, TimeInterval)]) -> [HotkeyMonitor.Edge] {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        for (code, active, t) in events { m.handle(keyCode: code, fnActive: active, at: t) }
        return out
    }

    // MARK: push-to-talk (unchanged behavior)

    func testLongPressAndRelease() {
        XCTAssertEqual(edges([(63, true, 0), (63, false, 0.5)]), [.down(command: false), .up(short: false)])
    }

    func testShortTapFlaggedShort() {
        XCTAssertEqual(edges([(63, true, 0), (63, false, 0.1)]), [.down(command: false), .up(short: true)])
    }

    func testOtherModifierIgnored() {
        XCTAssertEqual(edges([(58, true, 0), (58, false, 0.5)]), [])
    }

    func testRepeatedDownFiresOnce() {
        XCTAssertEqual(edges([(63, true, 0), (63, true, 0.1), (63, false, 0.5)]),
                       [.down(command: false), .up(short: false)])
    }

    func testShiftAtDownIsCommand() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, shiftActive: true, at: 0)
        m.handle(keyCode: 63, fnActive: false, shiftActive: false, at: 0.5) // shift released while speaking
        XCTAssertEqual(out, [.down(command: true), .up(short: false)])
    }

    func testCommandModeLatchedAtDownNotUp() {
        // Shift held only at release (not at fn-down) ⇒ plain dictation.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, shiftActive: false, at: 0)
        m.handle(keyCode: 63, fnActive: false, shiftActive: true, at: 0.5)
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testShiftFlagsChangedDoesNotDoubleFireOrCancel() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, shiftActive: false, at: 0)    // fn down
        m.handle(keyCode: 56, fnActive: true, shiftActive: true, at: 0.1)   // shift pressed
        m.handle(keyCode: 56, fnActive: true, shiftActive: false, at: 0.2)  // shift released
        m.handle(keyCode: 63, fnActive: false, shiftActive: false, at: 0.5) // fn up
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testUpWithoutDownIgnored() {
        XCTAssertEqual(edges([(63, false, 0)]), [])
    }

    func testKeypressWhileHeldCancelsAndSwallowsUp() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        XCTAssertFalse(m.keyDown(keyCode: 123, fnActive: true, at: 0.2)) // fn+arrow: cancels, passes through
        m.handle(keyCode: 63, fnActive: false, at: 0.5)                  // fn released after
        XCTAssertEqual(out, [.down(command: false), .cancel])            // no trailing .up
    }

    func testKeypressWhileIdleIgnored() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 0, at: 0))
        XCTAssertEqual(out, [])
    }

    // MARK: hands-free (fn+Space)

    func testHandsFreeLatchSurvivesFnReleaseAndFnStops() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)                       // fn down → push
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 0.1))     // fn+Space: latch, swallowed
        m.handle(keyCode: 63, fnActive: false, at: 0.3)                    // fn release: NO .up
        XCTAssertEqual(out, [.down(command: false), .handsFree])
        m.handle(keyCode: 63, fnActive: true, at: 5)                       // fn press: stop + transcribe
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 5.05))    // the chord's Space: swallowed, no restart
        m.handle(keyCode: 63, fnActive: false, at: 5.1)                    // fn release: idle, no edges
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testHandsFreeSpaceStopsWhenFnHeldThroughout() {
        // fn never released after the latch: no fn-down stop can fire, so the
        // second fn+Space must stop it.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 2))       // stop
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testTypingDuringHandsFreeDoesNotCancel() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch hands-free
        m.handle(keyCode: 63, fnActive: false, at: 0.3)
        XCTAssertFalse(m.keyDown(keyCode: 0, at: 1))                       // plain typing passes through
        XCTAssertEqual(out, [.down(command: false), .handsFree])           // still recording
    }

    func testSpaceStopsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch hands-free
        m.handle(keyCode: 63, fnActive: false, at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 49, at: 2))                       // plain Space: stop, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testReturnStopsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch hands-free
        m.handle(keyCode: 63, fnActive: false, at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 36, at: 2))                       // Return: stop, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testEscCancelsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)
        m.handle(keyCode: 63, fnActive: false, at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 53, at: 1))                       // Esc: cancel, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .cancel])
    }

    func testSpaceAfterStopWithFnStillHeldIsSwallowedNoOp() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 0.1)                // latch
        _ = m.keyDown(keyCode: 49, fnActive: true, at: 2)                  // stop (fn never released)
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 3))       // swallowed, must NOT restart
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    // MARK: esc + paste-last while idle

    func testEscWhileHeldCancelsAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)
        XCTAssertTrue(m.keyDown(keyCode: 53, fnActive: true, at: 0.2))
        XCTAssertEqual(out, [.down(command: false), .cancel])
    }

    func testEscWhileIdleDismissesAndPassesThrough() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 53, at: 0))
        XCTAssertEqual(out, [.dismiss])
    }

    func testCtrlCmdVPastesLastAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertTrue(m.keyDown(keyCode: 9, cmd: true, ctrl: true, at: 0))
        XCTAssertEqual(out, [.pasteLast])
    }

    func testCtrlCmdSOpensScratchpadAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertTrue(m.keyDown(keyCode: 1, cmd: true, ctrl: true, at: 0))
        XCTAssertEqual(out, [.openScratchpad])
    }

    func testPlainCmdVIgnored() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 9, cmd: true, at: 0))
        XCTAssertEqual(out, [])
    }

    // ⌃⌥⌘V / ⌃⇧⌘V are somebody else's shortcut — matching them stole the key
    // AND typed the last transcript into whatever had focus.
    func testChordsRequireExactModifiers() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 9, cmd: true, ctrl: true, opt: true, at: 0))
        XCTAssertFalse(m.keyDown(keyCode: 9, cmd: true, ctrl: true, shift: true, at: 0))
        XCTAssertFalse(m.keyDown(keyCode: 1, cmd: true, ctrl: true, opt: true, at: 0))
        XCTAssertFalse(m.keyDown(keyCode: 1, cmd: true, ctrl: true, shift: true, at: 0))
        XCTAssertEqual(out, [])
        // The exact chords still work.
        XCTAssertTrue(m.keyDown(keyCode: 9, cmd: true, ctrl: true, at: 1))
        XCTAssertTrue(m.keyDown(keyCode: 1, cmd: true, ctrl: true, at: 2))
        XCTAssertEqual(out, [.pasteLast, .openScratchpad])
    }

    // MARK: refusal rollback

    // handle() commits session = .push before the delegate can refuse the
    // fn-down (password field / nothing selected / mic failure). Without a
    // rollback the monitor stays mid-session: the next Space is swallowed by a
    // dictation that never started.
    func testResetAfterRefusedDownRestoresIdle() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)   // .down — delegate will refuse
        m.reset()                                      // delegate refused
        // A plain Space must now pass through untouched, not be eaten.
        XCTAssertFalse(m.keyDown(keyCode: 49, at: 0.5))
        XCTAssertEqual(out, [.down(command: false)])   // no phantom .cancel
        // Esc must dismiss a toast, not cancel a nonexistent dictation.
        XCTAssertFalse(m.keyDown(keyCode: 53, at: 0.6))
        XCTAssertEqual(out, [.down(command: false), .dismiss])
    }

    func testResetAfterRefusedDownThenHandsFreeLatch() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, fnActive: true, at: 0)             // .down — refused
        XCTAssertTrue(m.keyDown(keyCode: 49, fnActive: true, at: 0.1)) // latched .handsFree
        m.reset()                                                // delegate saw isRecording == false
        XCTAssertFalse(m.keyDown(keyCode: 49, at: 1))            // Space is the user's again
        XCTAssertEqual(out, [.down(command: false), .handsFree])
        // And a fresh dictation still works.
        m.handle(keyCode: 63, fnActive: true, at: 2)
        m.handle(keyCode: 63, fnActive: false, at: 3)
        XCTAssertEqual(out, [.down(command: false), .handsFree,
                             .down(command: false), .up(short: false)])
    }
}
