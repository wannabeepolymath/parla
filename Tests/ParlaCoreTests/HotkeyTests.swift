import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    func monitor(_ out: UnsafeMutablePointer<[HotkeyMonitor.Edge]>) -> HotkeyMonitor {
        // A store on a path that never exists: bindings stay at the defaults and
        // no test can be steered by the developer's real settings.json.
        let m = HotkeyMonitor(store: SettingsStore(url: URL(fileURLWithPath: "/dev/null/parla-tests")))
        m.onEdge = { out.pointee.append($0) }
        m.keyIsPhysicallyDown = { _ in false } // no HID in tests; injected where it matters
        return m
    }

    /// Drive the pure machine with (keyCode, fn held, time) flagsChanged events.
    func edges(_ events: [(UInt16, Bool, TimeInterval)]) -> [HotkeyMonitor.Edge] {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        for (code, active, t) in events {
            m.handle(keyCode: code, modifiers: active ? [.fn] : [], at: t)
        }
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
        m.handle(keyCode: 63, modifiers: [.fn, .shift], at: 0)
        m.handle(keyCode: 63, modifiers: [], at: 0.5) // shift released while speaking
        XCTAssertEqual(out, [.down(command: true), .up(short: false)])
    }

    func testCommandModeLatchedAtDownNotUp() {
        // Shift held only at release (not at fn-down) ⇒ plain dictation.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        m.handle(keyCode: 63, modifiers: [.shift], at: 0.5)
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testShiftFlagsChangedDoesNotDoubleFireOrCancel() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)          // fn down
        m.handle(keyCode: 56, modifiers: [.fn, .shift], at: 0.1) // shift pressed
        m.handle(keyCode: 56, modifiers: [.fn], at: 0.2)         // shift released
        m.handle(keyCode: 63, modifiers: [], at: 0.5)            // fn up
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testUpWithoutDownIgnored() {
        XCTAssertEqual(edges([(63, false, 0)]), [])
    }

    func testKeypressWhileHeldCancelsAndSwallowsUp() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        XCTAssertFalse(m.keyDown(keyCode: 123, modifiers: [.fn], at: 0.2)) // fn+arrow: cancels, passes through
        m.handle(keyCode: 63, modifiers: [], at: 0.5)                     // fn released after
        XCTAssertEqual(out, [.down(command: false), .cancel])             // no trailing .up
    }

    func testKeypressWhileIdleIgnored() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 0, at: 0))
        XCTAssertEqual(out, [])
    }

    // MARK: reconcile — a release the tap never saw

    /// The tap was disabled (or deaf) when the trigger came up. Without this the
    /// capture runs on — mic open, room recorded — until the next keystroke.
    func testMissedReleaseIsSynthesizedAndTheNextPressStartsFresh() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        m.reconcile(triggerDown: false, at: 3)
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
        m.handle(keyCode: 63, modifiers: [.fn], at: 4)                     // not a no-op any more
        XCTAssertEqual(out, [.down(command: false), .up(short: false), .down(command: false)])
    }

    func testReconcileLeavesAHeldTriggerAlone() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        m.reconcile(triggerDown: true, at: 3)
        XCTAssertEqual(out, [.down(command: false)])
    }

    /// Hands-free is meant to outlive the release, so a missed one ends nothing —
    /// but the stale "held" bit must clear, or once the latch is stopped the
    /// front app's own fn+Space is swallowed as if it were the tail of ours.
    func testReconcileDoesNotEndHandsFreeButClearsTheHeldBit() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch; release then missed
        m.reconcile(triggerDown: false, at: 3)
        XCTAssertEqual(out, [.down(command: false), .handsFree])
        XCTAssertTrue(m.keyDown(keyCode: 49, at: 4))                       // bare Space stops it
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
        XCTAssertFalse(m.keyDown(keyCode: 49, modifiers: [.fn], at: 5))    // idle, trigger up: not ours
    }

    /// The gap reconcile's 5 s cadence leaves: the release slipped past AND the
    /// user re-pressed before the next tick — the re-press re-arms `triggerHeld`,
    /// so the tick sees a held key and ends nothing, and the two dictations
    /// finalize as ONE transcript. The same physical key going down again is
    /// itself proof the release was missed, so the session splits right there.
    func testRepressAfterMissedReleaseSplitsTheSessions() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.keyIsPhysicallyDown = { $0 == 63 }               // the re-press is a real press
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)     // down; its release then missed
        m.handle(keyCode: 63, modifiers: [.fn], at: 5)     // pressed again
        XCTAssertEqual(out, [.down(command: false), .up(short: false), .down(command: false)])
        m.handle(keyCode: 63, modifiers: [], at: 7)        // this release arrives normally
        XCTAssertEqual(out, [.down(command: false), .up(short: false), .down(command: false),
                             .up(short: false)])
    }

    func testTwinEventsDoNotSplitTheSession() {
        // Left and right option share the flag bit, so both twin events spell
        // "trigger down" — neither is a re-press of the key that started the
        // session: the twin's press carries its own keyCode, and the bound key's
        // release under a twin-held bit reports physically up.
        var down = Set<UInt16>()
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.keyIsPhysicallyDown = { down.contains($0) }
        m.bindings.pushToTalk = KeyChord(61)                              // right option
        m.bindings.handsFree = KeyChord(49, .opt)
        down = [61]; m.handle(keyCode: 61, modifiers: [.opt], at: 0)      // right down → push
        down = [61, 58]; m.handle(keyCode: 58, modifiers: [.opt], at: 1)  // left down too
        down = [58]; m.handle(keyCode: 61, modifiers: [.opt], at: 2)      // right up, bit held
        XCTAssertEqual(out, [.down(command: false)])                      // one session, still live
        down = []; m.handle(keyCode: 58, modifiers: [], at: 3)            // left up: bit clears
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testReconcileWhileIdleIsSilent() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.reconcile(triggerDown: false, at: 1)
        m.reconcile(triggerDown: true, at: 2)
        XCTAssertEqual(out, [])
    }

    // MARK: endSession — the capture ended by itself (10-minute cap, mic lost)

    func testSelfEndedHandsFreeDoesNotSwallowTheNextSpaceReturnOrEsc() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)
        m.handle(keyCode: 63, modifiers: [], at: 0.3)
        m.endSession()
        XCTAssertFalse(m.keyDown(keyCode: 49, at: 700))                    // the user's own Space
        XCTAssertFalse(m.keyDown(keyCode: 36, at: 701))                    // …and Return
        XCTAssertFalse(m.keyDown(keyCode: 53, at: 702))                    // …and Esc
        XCTAssertEqual(out, [.down(command: false), .handsFree, .dismiss])
    }

    func testSelfEndedPushIgnoresTheLateReleaseAndTheNextPressStarts() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        m.endSession()
        m.handle(keyCode: 63, modifiers: [], at: 600)                      // trigger finally released
        XCTAssertEqual(out, [.down(command: false)])
        m.handle(keyCode: 63, modifiers: [.fn], at: 601)
        XCTAssertEqual(out, [.down(command: false), .down(command: false)])
    }

    // MARK: delivery — the tap runs on its own thread, edges land on main

    /// Let everything already queued on main run.
    func drainMain() {
        let done = expectation(description: "main drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// As start() configures it: the machine decides on the tap thread and
    /// returns at once; the edges — and the capture start behind `.down` — run
    /// on main afterwards, in the order they were decided.
    func testTapEdgesAreDeliveredOnMainLaterAndInOrder() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.deliversOnMain = true
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        m.handle(keyCode: 63, modifiers: [], at: 0.5)
        XCTAssertEqual(out, [])                                            // nothing ran inside the "callback"
        drainMain()
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    /// The cap fires on main while a press the tap has already accepted is
    /// still queued behind it. Unlatching then would leave the monitor idle
    /// under a recording session, and its release would end nothing.
    func testEndSessionLeavesAPressMainHasNotSeenYet() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.deliversOnMain = true
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)                     // accepted, .down still queued
        m.endSession()
        m.handle(keyCode: 63, modifiers: [], at: 0.5)
        drainMain()
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    /// …and with nothing queued it applies, exactly as it does off the tap.
    func testEndSessionAppliesOnceMainHasCaughtUp() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.deliversOnMain = true
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch
        m.handle(keyCode: 63, modifiers: [], at: 0.3)
        drainMain()
        m.endSession()
        XCTAssertFalse(m.keyDown(keyCode: 49, at: 700))                    // not swallowed as a stop
        drainMain()
        XCTAssertEqual(out, [.down(command: false), .handsFree])
    }

    // MARK: hands-free (fn+Space)

    func testHandsFreeLatchSurvivesFnReleaseAndFnStops() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)                     // fn down → push
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1))   // fn+Space: latch, swallowed
        m.handle(keyCode: 63, modifiers: [], at: 0.3)                      // fn release: NO .up
        XCTAssertEqual(out, [.down(command: false), .handsFree])
        m.handle(keyCode: 63, modifiers: [.fn], at: 5)                     // fn press: stop + transcribe
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn], at: 5.05))  // the chord's Space: swallowed, no restart
        m.handle(keyCode: 63, modifiers: [], at: 5.1)                      // fn release: idle, no edges
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testHandsFreeSpaceStopsWhenFnHeldThroughout() {
        // fn never released after the latch: no fn-down stop can fire, so the
        // second fn+Space must stop it.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn], at: 2))     // stop
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testTypingDuringHandsFreeDoesNotCancel() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch hands-free
        m.handle(keyCode: 63, modifiers: [], at: 0.3)
        XCTAssertFalse(m.keyDown(keyCode: 0, at: 1))                       // plain typing passes through
        XCTAssertEqual(out, [.down(command: false), .handsFree])           // still recording
    }

    func testSpaceStopsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch hands-free
        m.handle(keyCode: 63, modifiers: [], at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 49, at: 2))                       // plain Space: stop, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testReturnStopsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch hands-free
        m.handle(keyCode: 63, modifiers: [], at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 36, at: 2))                       // Return: stop, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testEscCancelsHandsFree() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)
        m.handle(keyCode: 63, modifiers: [], at: 0.3)
        XCTAssertTrue(m.keyDown(keyCode: 53, at: 1))                       // Esc: cancel, swallowed
        XCTAssertEqual(out, [.down(command: false), .handsFree, .cancel])
    }

    func testSpaceAfterStopWithFnStillHeldIsSwallowedNoOp() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)              // latch
        _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 2)                // stop (fn never released)
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn], at: 3))     // swallowed, must NOT restart
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testLatchedStateSweepSwallowsOnlyWhitespace() {
        // The sweep that was missing: from the LATCHED state every one of the 32
        // modifier sets on Space and Return was swallowed, so ⌘Space (Spotlight),
        // ⌃Space (input source) and ⌘Return (send) died at the tap. Swallowing is
        // only justified for the sets that would type whitespace — bare and
        // shifted — plus the latch chord itself.
        for raw in 0..<32 {
            let mods = KeyChord.Modifiers(rawValue: raw)
            for key: UInt16 in [49, 36] {
                var out: [HotkeyMonitor.Edge] = []
                let m = monitor(&out)
                m.handle(keyCode: 63, modifiers: [.fn], at: 0)
                _ = m.keyDown(keyCode: 49, modifiers: [.fn], at: 0.1)   // latch
                m.handle(keyCode: 63, modifiers: [], at: 0.2)           // trigger released
                let bare = mods.subtracting(.shift)
                let stops = bare.isEmpty || (key == 49 && bare == .fn)  // whitespace, or the chord
                let what = KeyChord(key, mods).display
                XCTAssertEqual(m.keyDown(keyCode: key, modifiers: mods, at: 1), stops, what)
                XCTAssertEqual(out, stops
                    ? [.down(command: false), .handsFree, .up(short: false)]
                    : [.down(command: false), .handsFree], what)  // else: still recording
            }
        }
    }

    func testHandsFreeLatchesInCommandMode() {
        // Command mode is entered by holding shift at push-to-talk, so shift is
        // still down when the latch key arrives: the Space carries [.fn, .shift].
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn, .shift], at: 0)
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn, .shift], at: 0.1)) // swallowed, not typed
        XCTAssertEqual(out, [.down(command: true), .handsFree])
    }

    func testCommandModeLatchTailIsSwallowedAfterTheStop() {
        // Shift stays down through command mode, so the tail Space of the stop
        // chord arrives as fn+shift+Space. Without the same tolerance the live
        // latch has, that space leaked into the field right before the transcript.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn, .shift], at: 0)
        _ = m.keyDown(keyCode: 49, modifiers: [.fn, .shift], at: 0.1)            // latch
        _ = m.keyDown(keyCode: 49, modifiers: [.fn, .shift], at: 2)              // stop (fn still held)
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn, .shift], at: 2.1)) // tail: swallowed
        XCTAssertEqual(out, [.down(command: true), .handsFree, .up(short: false)])
    }

    func testIdleLatchChordPassesThroughWhenTheTriggerIsNotHeld() {
        // The trigger bit can be set without Parla ever seeing the press: the
        // twin key (CGEventFlags has no left/right), a key held before the tap
        // started, or one pressed while the Hub was recording a binding. Nothing
        // is recording, so ⌥Space belongs to the front app (non-breaking space).
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.pushToTalk = KeyChord(61)          // right option
        m.bindings.handsFree = KeyChord(49, .opt)
        XCTAssertFalse(m.keyDown(keyCode: 49, modifiers: [.opt], at: 0))
        XCTAssertFalse(m.keyDown(keyCode: 49, modifiers: [.opt], at: 1)) // and again, forever
        XCTAssertEqual(out, [])
    }

    // MARK: esc + paste-last while idle

    func testEscWhileHeldCancelsAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)
        XCTAssertTrue(m.keyDown(keyCode: 53, modifiers: [.fn], at: 0.2))
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
        XCTAssertTrue(m.keyDown(keyCode: 9, modifiers: [.ctrl, .cmd], at: 0))
        XCTAssertEqual(out, [.pasteLast])
    }

    func testCtrlCmdSOpensScratchpadAndIsSwallowed() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertTrue(m.keyDown(keyCode: 1, modifiers: [.ctrl, .cmd], at: 0))
        XCTAssertEqual(out, [.openScratchpad])
    }

    func testPlainCmdVIgnored() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 9, modifiers: [.cmd], at: 0))
        XCTAssertEqual(out, [])
    }

    // MARK: exact modifier match (the superset bug)

    func testExtraModifierDoesNotFirePasteLast() {
        // ⌃⌘⇧V belongs to the front app: the old `cmd, ctrl` contains-check
        // fired here AND swallowed the event.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 9, modifiers: [.ctrl, .cmd, .shift], at: 0))
        XCTAssertFalse(m.keyDown(keyCode: 9, modifiers: [.ctrl, .cmd, .opt], at: 1))
        XCTAssertFalse(m.keyDown(keyCode: 9, modifiers: [.ctrl, .cmd, .fn], at: 2))
        XCTAssertFalse(m.keyDown(keyCode: 1, modifiers: [.ctrl, .cmd, .shift], at: 3))
        XCTAssertEqual(out, [])
    }

    func testExtraModifierDoesNotLatchHandsFree() {
        // SHIFT is the only extra the latch tolerates (command mode holds it —
        // see testHandsFreeLatchesInCommandMode). fn+⌘+Space is Spotlight and
        // fn+⌃+Space switches input source: while push-to-talk is held they must
        // cancel the dictation and PASS THROUGH, not latch hands-free and keep
        // recording after fn is released.
        for extra: KeyChord.Modifiers in [.cmd, .ctrl, .opt] {
            var out: [HotkeyMonitor.Edge] = []
            let m = monitor(&out)
            m.handle(keyCode: 63, modifiers: [.fn], at: 0)
            XCTAssertFalse(m.keyDown(keyCode: 49, modifiers: [.fn, extra], at: 0.1))
            XCTAssertEqual(out, [.down(command: false), .cancel])
        }
    }

    func testIdleChordWithSyntheticFnDoesNotHitHandsFree() {
        // macOS sets the fn bit on arrows/Home/End/Page by itself, so an idle
        // ⇧+PageDown (select to the end) arrives as [.fn, .shift] and spells the
        // binding exactly. Only the trigger being down makes it ours, and here
        // nothing is held, so it belongs to the front app.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.handsFree = KeyChord(121, .fn)                     // fn+PageDown
        XCTAssertFalse(m.keyDown(keyCode: 121, modifiers: [.fn, .shift], at: 0))
        XCTAssertEqual(out, [])
    }

    func testHandWrittenArrowChordFiresOnTheDecoratedEvent() throws {
        // The other half of that synthetic bit: a chord typed into settings.json
        // carries no fn, the event always does, so every hand-written arrow /
        // Home / End / Page / F-key chord was dead on arrival.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.pasteLast = try JSONDecoder().decode(
            KeyChord.self, from: Data("\"ctrl+cmd+down\"".utf8))
        XCTAssertTrue(m.keyDown(keyCode: 125, modifiers: [.ctrl, .cmd, .fn], at: 0))
        XCTAssertEqual(out, [.pasteLast])
    }

    func testMissingModifierDoesNotFire() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        XCTAssertFalse(m.keyDown(keyCode: 9, modifiers: [.ctrl], at: 0))
        XCTAssertEqual(out, [])
    }

    // MARK: rebinding

    func testReboundPushToTalkOnRightOption() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.pushToTalk = KeyChord(61)          // right option
        m.bindings.handsFree = KeyChord(49, .opt)
        m.handle(keyCode: 63, modifiers: [.fn], at: 0)     // fn is nobody's trigger now
        m.handle(keyCode: 61, modifiers: [.opt], at: 1)
        m.handle(keyCode: 61, modifiers: [], at: 2)
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testTwinOfTheReboundTriggerFinishesTheSession() {
        // Left and right option set the SAME flag bit, so after the bound right
        // option is released the bit is still set and no ".up" can fire from it;
        // the release that clears the bit is the twin's, whose keyCode a keyCode
        // guard ignores — the session stayed in .push and the next key cancelled.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.pushToTalk = KeyChord(61)                 // right option
        m.bindings.handsFree = KeyChord(49, .opt)
        m.handle(keyCode: 61, modifiers: [.opt], at: 0)      // right down → push
        m.handle(keyCode: 58, modifiers: [.opt], at: 0.1)    // left down too
        m.handle(keyCode: 61, modifiers: [.opt], at: 0.2)    // right up: left still holds the bit
        XCTAssertEqual(out, [.down(command: false)])         // still recording
        m.handle(keyCode: 58, modifiers: [], at: 0.5)        // left up: bit clears
        XCTAssertEqual(out, [.down(command: false), .up(short: false)])
    }

    func testReboundHandsFreeLatches() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.pushToTalk = KeyChord(61)
        m.bindings.handsFree = KeyChord(36, .opt)     // right-option + Return
        m.handle(keyCode: 61, modifiers: [.opt], at: 0)
        XCTAssertTrue(m.keyDown(keyCode: 36, modifiers: [.opt], at: 0.1))
        m.handle(keyCode: 61, modifiers: [], at: 0.2)
        XCTAssertEqual(out, [.down(command: false), .handsFree])
        XCTAssertTrue(m.keyDown(keyCode: 36, at: 3))  // Return still stops it
        XCTAssertEqual(out, [.down(command: false), .handsFree, .up(short: false)])
    }

    func testReboundChordFiresAndOldChordDoesNot() {
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.pasteLast = KeyChord(35, [.opt, .cmd])  // ⌥⌘P
        XCTAssertTrue(m.keyDown(keyCode: 35, modifiers: [.opt, .cmd], at: 0))
        XCTAssertFalse(m.keyDown(keyCode: 9, modifiers: [.ctrl, .cmd], at: 1))
        XCTAssertEqual(out, [.pasteLast])
    }

    func testRefreshBindingsLoadsFromSettingsAndDropsAnUnusableSet() throws {
        // The Settings→bindings path a real user exercises: every other rebinding
        // test assigns `m.bindings` directly and skips the load entirely.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let m = HotkeyMonitor(store: SettingsStore(url: url))

        try Data(#"{"hotkeys": {"pushToTalk": "rightoption", "handsFree": "opt+space"}}"#.utf8)
            .write(to: url)
        m.refreshBindings()
        XCTAssertEqual(m.bindings.pushToTalk, KeyChord(61))
        XCTAssertEqual(m.bindings.handsFree, KeyChord(49, .opt))

        // Hand-edited nonsense: the unparseable chord falls back per field, and a
        // set that would leave Parla unreachable (V can't be held) is dropped
        // whole — so fn+Space still works rather than no hotkey at all.
        try Data(#"{"hotkeys": {"pushToTalk": "v", "handsFree": "ctrl+banana"}}"#.utf8).write(to: url)
        m.refreshBindings()
        XCTAssertEqual(m.bindings, HotkeyBindings())
    }

    // MARK: chord serialization

    func testChordRoundTripsThroughJSON() throws {
        let chords = [KeyChord(63), KeyChord(49, .fn), KeyChord(9, [.ctrl, .cmd]),
                      KeyChord(35, [.opt, .cmd, .shift]), KeyChord(122), KeyChord(19, [.ctrl])]
        for chord in chords {
            let data = try JSONEncoder().encode(chord)
            XCTAssertEqual(try JSONDecoder().decode(KeyChord.self, from: data), chord)
        }
    }

    func testChordEncodesReadably() throws {
        let text = String(data: try JSONEncoder().encode(KeyChord(9, [.ctrl, .cmd])), encoding: .utf8)
        XCTAssertEqual(text, "\"ctrl+cmd+v\"")
        XCTAssertEqual(String(data: try JSONEncoder().encode(KeyChord(63)), encoding: .utf8), "\"fn\"")
    }

    func testChordParsesHandWrittenForms() throws {
        func parse(_ s: String) throws -> KeyChord {
            try JSONDecoder().decode(KeyChord.self, from: Data("\"\(s)\"".utf8))
        }
        XCTAssertEqual(try parse("Control+Command+V"), KeyChord(9, [.ctrl, .cmd]))
        XCTAssertEqual(try parse("alt + shift + space"), KeyChord(49, [.opt, .shift]))
        XCTAssertEqual(try parse("fn"), KeyChord(63))          // fn as the key
        XCTAssertEqual(try parse("fn+space"), KeyChord(49, .fn)) // fn as a modifier
        // Hand-written and recorded must converge on the keys macOS decorates
        // with fn all by itself, or the chord can never match an event.
        XCTAssertEqual(try parse("ctrl+cmd+down"), KeyChord(125, [.ctrl, .cmd, .fn]))
        XCTAssertEqual(try parse("cmd+f13"), KeyChord(105, [.cmd, .fn]))
        XCTAssertNotEqual(KeyChord(63, .fn), KeyChord(63))       // not on 63: fn IS the key there
        XCTAssertThrowsError(try parse("ctrl+nope"))
        XCTAssertThrowsError(try parse("hyper+v"))
    }

    func testChordDisplay() {
        XCTAssertEqual(KeyChord(9, [.ctrl, .cmd]).display, "⌃ ⌘ V")
        XCTAssertEqual(KeyChord(49, .fn).display, "fn Space")
        XCTAssertEqual(KeyChord(63).display, "fn")
    }

    // MARK: settings decode

    func testSettingsDefaultsMatchTheShippedChords() {
        let s = Settings()
        XCTAssertEqual(s.hotkeys.pushToTalk, KeyChord(63))
        XCTAssertEqual(s.hotkeys.handsFree, KeyChord(49, .fn))
        XCTAssertEqual(s.hotkeys.pasteLast, KeyChord(9, [.ctrl, .cmd]))
        XCTAssertEqual(s.hotkeys.openScratchpad, KeyChord(1, [.ctrl, .cmd]))
        XCTAssertNil(s.hotkeys.problem())
    }

    func testSettingsDecodesHotkeysAndToleratesGarbage() throws {
        let json = """
        {"hotkeys": {"pasteLast": "opt+cmd+p", "openScratchpad": "ctrl+banana"}, "hudIdleSize": "large"}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.hotkeys.pasteLast, KeyChord(35, [.opt, .cmd]))
        XCTAssertEqual(s.hotkeys.openScratchpad, KeyChord(1, [.ctrl, .cmd])) // bad chord ⇒ default
        XCTAssertEqual(s.hudIdleSize, "large")                               // rest of the file survives
    }

    // MARK: collision detection

    func testDefaultsAreValid() {
        XCTAssertNil(HotkeyBindings().problem())
    }

    func testPushToTalkMustBeABareModifier() {
        var b = HotkeyBindings()
        b.pushToTalk = KeyChord(9)             // V held would type "vvvv…"
        XCTAssertNotNil(b.problem())
        b.pushToTalk = KeyChord(63, [.cmd])    // fn with a modifier is not a hold key
        XCTAssertNotNil(b.problem())
        b.pushToTalk = KeyChord(57)            // caps lock latches
        XCTAssertNotNil(b.problem())
    }

    func testPushToTalkCannotBeShift() {
        var b = HotkeyBindings()
        b.pushToTalk = KeyChord(56)
        b.handsFree = KeyChord(49, .shift)
        XCTAssertNotNil(b.problem())           // shift means command mode
    }

    func testChordsCannotBeBareModifiersOrEsc() {
        var b = HotkeyBindings()
        b.pasteLast = KeyChord(55, [.ctrl])    // ⌘ is a modifier: no keyDown ever arrives
        XCTAssertNotNil(b.problem())
        b = HotkeyBindings()
        b.openScratchpad = KeyChord(53, [.ctrl, .cmd]) // Esc is always cancel
        XCTAssertNotNil(b.problem())
    }

    func testHandsFreeMustBeReachableWhileHoldingTheTrigger() {
        var b = HotkeyBindings()
        b.pushToTalk = KeyChord(61)            // right option
        XCTAssertNotNil(b.problem())           // hands-free still fn+Space ⇒ unreachable
        b.handsFree = KeyChord(49, .opt)
        XCTAssertNil(b.problem())
    }

    func testHandsFreeOnAnFnDecoratedKeyStaysReachable() {
        // fn+Down stores no fn (macOS adds it to every arrow press anyway), so
        // the "must include fn" check must not read it as unreachable — that
        // would revert the whole set to the defaults behind the user's back.
        var b = HotkeyBindings()
        b.handsFree = KeyChord(125, .fn)       // fn+Down
        XCTAssertNil(b.problem())
    }

    func testIdleChordsNeedAModifierAndMustAvoidTheTrigger() {
        var b = HotkeyBindings()
        b.pasteLast = KeyChord(9)              // bare V fires while typing
        XCTAssertNotNil(b.problem())
        b = HotkeyBindings()
        b.pasteLast = KeyChord(9, [.fn, .cmd]) // fn starts dictation before V lands
        XCTAssertNotNil(b.problem())
    }

    func testDuplicateChordsAreRefused() {
        var b = HotkeyBindings()
        b.openScratchpad = b.pasteLast
        XCTAssertNotNil(b.problem())
        b = HotkeyBindings()
        b.pasteLast = KeyChord(49, .fn)        // same as hands-free
        XCTAssertNotNil(b.problem())
    }
}
