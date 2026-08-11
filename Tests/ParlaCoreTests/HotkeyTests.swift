import XCTest
@testable import ParlaCore

final class HotkeyTests: XCTestCase {
    func monitor(_ out: UnsafeMutablePointer<[HotkeyMonitor.Edge]>) -> HotkeyMonitor {
        // A store on a path that never exists: bindings stay at the defaults and
        // no test can be steered by the developer's real settings.json.
        let m = HotkeyMonitor(store: SettingsStore(url: URL(fileURLWithPath: "/dev/null/parla-tests")))
        m.onEdge = { out.pointee.append($0) }
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

    func testHandsFreeLatchesInCommandMode() {
        // Command mode is entered by holding shift at push-to-talk, so shift is
        // still down when the latch key arrives: the Space carries [.fn, .shift].
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.handle(keyCode: 63, modifiers: [.fn, .shift], at: 0)
        XCTAssertTrue(m.keyDown(keyCode: 49, modifiers: [.fn, .shift], at: 0.1)) // swallowed, not typed
        XCTAssertEqual(out, [.down(command: true), .handsFree])
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
        // Idle is exact like every other chord: nothing is held, so the "the
        // trigger is physically held" premise doesn't apply. macOS sets the fn
        // bit on arrows/Home/End/Page by itself, so an idle ⇧+PageDown (select
        // to the end) arrives as [.fn, .shift] and a loose match swallowed it.
        var out: [HotkeyMonitor.Edge] = []
        let m = monitor(&out)
        m.bindings.handsFree = KeyChord(121, .fn)                     // fn+PageDown
        XCTAssertFalse(m.keyDown(keyCode: 121, modifiers: [.fn, .shift], at: 0))
        XCTAssertEqual(out, [])
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
