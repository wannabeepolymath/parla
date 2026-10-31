import Carbon
import XCTest
@testable import ParlaCore

final class ShortcutDisplayTests: XCTestCase {
    func testSamePhysicalPositionsAcrossQwertyAzertyAndQwertz() throws {
        let layouts: [[UInt16: String]] = [
            [0: "a", 12: "q", 16: "y", 6: "z"],
            [0: "q", 12: "a", 16: "y", 6: "w"],
            [0: "a", 12: "q", 16: "z", 6: "y"],
        ]
        for (index, layout) in layouts.enumerated() {
            let formatter = ShortcutDisplayFormatter { layout[$0] }
            XCTAssertEqual(formatter.display(KeyChord(0, [.ctrl, .cmd])), "⌃ ⌘ " + ["a", "q", "a"][index])
            XCTAssertEqual(formatter.display(KeyChord(16)), ["y", "y", "z"][index])
            for (code, label) in layout {
                let chord = KeyChord(code, [.ctrl, .opt])
                XCTAssertEqual(formatter.display(chord), "⌃ ⌥ \(label)")
                XCTAssertTrue(chord.matches(code, [.ctrl, .opt]))
                XCTAssertFalse(chord.matches(code, [.ctrl, .opt, .shift]))
            }
        }
    }

    func testPrintableBasePunctuationUnicodeAndUnavailableLabels() {
        for label in ["q", "!", "[", "é", "e\u{301}", "अ", "字", "´"] {
            let formatter = ShortcutDisplayFormatter { _ in label }
            XCTAssertEqual(formatter.display(KeyChord(12, [.shift, .opt])), "⌥ ⇧ \(label)")
        }
        for label: String? in [nil, "", "\n", "\t", " ", "\u{0}", "\u{200B}", "\u{F700}", "\u{FFFF}", "\u{FFFD}", "two"] {
            let formatter = ShortcutDisplayFormatter { _ in label }
            XCTAssertEqual(formatter.display(KeyChord(9, [.ctrl, .cmd])), "⌃ ⌘ V (physical key 9)")
            XCTAssertEqual(formatter.display(KeyChord(10)), "Physical key 10")
        }
    }

    func testNamedKeysAndBothModifierSidesNeverConsultLayout() {
        let formatter = ShortcutDisplayFormatter { _ in XCTFail("Named key lookup"); return "x" }
        let names: [UInt16: String] = [
            54: "RightCmd", 55: "Cmd", 56: "Shift", 60: "RightShift", 58: "Option", 61: "RightOption",
            59: "Control", 62: "RightControl", 63: "fn", 49: "Space", 36: "Return", 48: "Tab",
            51: "Delete", 53: "Esc", 115: "Home", 116: "PageUp", 117: "FwdDelete", 119: "End",
            121: "PageDown", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
        ]
        for (key, name) in names { XCTAssertEqual(formatter.display(KeyChord(key)), name) }
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, key) in fkeys.enumerated() {
            XCTAssertEqual(formatter.display(KeyChord(key, [.fn, .ctrl])), "⌃ F\(index + 1)")
        }
        XCTAssertEqual(formatter.display(KeyChord(49, [.fn, .ctrl, .opt, .shift, .cmd])), "fn ⌃ ⌥ ⇧ ⌘ Space")
    }

    func testCanonicalCodableAndPhysicalMatchingStayIdenticalAcrossLayouts() throws {
        var bindings = HotkeyBindings()
        bindings.runSelectedPreset = KeyChord(16, [.ctrl, .cmd])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(bindings)
        XCTAssertEqual(String(data: try encoder.encode(bindings.pasteLast), encoding: .utf8), #""ctrl+cmd+v""#)
        XCTAssertEqual(String(data: try encoder.encode(bindings.runSelectedPreset), encoding: .utf8), #""ctrl+cmd+y""#)
        for letter in ["v", "ж", "字"] {
            let formatter = ShortcutDisplayFormatter { _ in letter }
            XCTAssertEqual(formatter.display(bindings.pasteLast), "⌃ ⌘ \(letter)")
            XCTAssertTrue(bindings.pasteLast.matches(9, [.ctrl, .cmd]))
            XCTAssertFalse(bindings.pasteLast.matches(9, [.ctrl, .cmd, .shift]))
            let roundtrip = try JSONDecoder().decode(HotkeyBindings.self, from: before)
            XCTAssertEqual(roundtrip, bindings)
            XCTAssertEqual(try encoder.encode(roundtrip), before)
            XCTAssertNil(roundtrip.problem())
        }
    }

    func testValidationDisplayClosurePreservesDefaultRules() {
        var bindings = HotkeyBindings()
        bindings.handsFree = KeyChord(49, .cmd)
        XCTAssertEqual(bindings.problem(), "hands-free is pressed while holding push to talk, so it must include fn")
        XCTAssertEqual(bindings.problem(display: { _ in "trigger label" }),
                       "hands-free is pressed while holding push to talk, so it must include trigger label")
        bindings.handsFree = KeyChord(49, .fn)
        bindings.runSelectedPreset = bindings.pasteLast
        XCTAssertEqual(bindings.problem(), bindings.problem(display: { _ in "different label" }))
    }

    // Minimal native-endian uchr fixture, from the SDK's UCKeyboardLayout table
    // definitions. Real UCKeyTranslate reads this; no input source is installed
    // or selected. It has one explicit keyboard type, a base table and a dead key.
    private func layout(type: UInt32 = 42) -> Data {
        var data = Data(repeating: 0, count: 344)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        put(UInt16(kUCKeyLayoutHeaderFormat), at: 0); put(UInt16(0x0100), at: 2)
        put(UInt32(1), at: 8); put(type, at: 12); put(type, at: 16)
        put(UInt32(40), at: 20); put(UInt32(52), at: 24)
        put(UInt32(320), at: 28); put(UInt32(336), at: 32)
        put(UInt16(kUCKeyModifiersToTableNumFormat), at: 40); put(UInt32(1), at: 44)
        put(UInt16(kUCKeyToCharTableIndexFormat), at: 52); put(UInt16(128), at: 54)
        put(UInt32(1), at: 56); put(UInt32(64), at: 60)
        for code in 0..<128 { put(UInt16(0xFFFF), at: 64 + code * 2) }
        for (key, scalar): (Int, UInt16) in [(12, 0x71), (24, 0x3D), (10, 0xA7), (93, 0xA5), (94, 0x5F), (95, 0x2C), (14, 0xE9), (39, 0x4000)] {
            put(scalar, at: 64 + key * 2)
        }
        put(UInt16(kUCKeyStateRecordsIndexFormat), at: 320); put(UInt16(1), at: 322)
        put(UInt32(328), at: 324); put(UInt16(0xFFFF), at: 328); put(UInt16(1), at: 330)
        put(UInt16(kUCKeyStateEntryTerminalFormat), at: 334)
        put(UInt16(kUCKeyStateTerminatorsFormat), at: 336); put(UInt16(1), at: 338)
        put(UInt16(0xB4), at: 340)
        return data
    }

    func testActualCarbonBaseAndDeadKeyTranslationIsStateless() {
        let formatter = ShortcutDisplayFormatter.keyboardLayout(data: layout(), keyboardType: 42)
        XCTAssertEqual(formatter.display(KeyChord(12)), "q")
        XCTAssertEqual(formatter.display(KeyChord(24, .shift)), "⇧ =") // base, never Shift's '+'
        XCTAssertEqual(formatter.display(KeyChord(14)), "é")
        XCTAssertEqual(formatter.display(KeyChord(39)), "´")
        XCTAssertEqual(formatter.display(KeyChord(12)), "q") // no lingering dead-key state
        XCTAssertEqual(formatter.display(KeyChord(0)), "A (physical key 0)") // no output
    }

    func testCarbonTranslationFailureUsesExplicitPhysicalFallback() {
        var invalidHeader = layout()
        invalidHeader[0] = 0; invalidHeader[1] = 0
        let formatter = ShortcutDisplayFormatter.keyboardLayout(data: invalidHeader, keyboardType: 42)
        XCTAssertEqual(formatter.display(KeyChord(12)), "Q (physical key 12)")
    }

    func testISOJISPositionsRequireAvailableHardwareMapping() {
        for type: UInt32 in [41, 42, 44] { // fixture types, not a hardware qualification
            let formatter = ShortcutDisplayFormatter.keyboardLayout(data: layout(type: type), keyboardType: type)
            XCTAssertEqual(formatter.display(KeyChord(10)), "§")
            XCTAssertEqual(formatter.display(KeyChord(93)), "¥")
            XCTAssertEqual(formatter.display(KeyChord(94)), "_")
            XCTAssertEqual(formatter.display(KeyChord(95)), ",")
        }
        for type: UInt32? in [nil, 0, 99] {
            let formatter = ShortcutDisplayFormatter.keyboardLayout(data: layout(), keyboardType: type)
            XCTAssertEqual(formatter.display(KeyChord(10)), "Physical key 10")
            XCTAssertEqual(formatter.display(KeyChord(93)), "Physical key 93")
            XCTAssertEqual(formatter.display(KeyChord(12)), "Q (physical key 12)")
        }
        // Carbon's declared default table can supply standard positions, but
        // cannot establish an extra ISO/JIS position for unmatched hardware.
        let generic = ShortcutDisplayFormatter.keyboardLayout(data: layout(type: 0), keyboardType: 42)
        XCTAssertEqual(generic.display(KeyChord(10)), "Physical key 10")
        XCTAssertEqual(generic.display(KeyChord(93)), "Physical key 93")
        XCTAssertEqual(generic.display(KeyChord(12)), "q")
        for data: Data? in [nil, Data(), Data(repeating: 0, count: 40)] {
            let formatter = ShortcutDisplayFormatter.keyboardLayout(data: data, keyboardType: 42)
            XCTAssertEqual(formatter.display(KeyChord(12)), "Q (physical key 12)")
        }
    }
}
