import XCTest
@testable import ParlaCore

final class GuardedDictationEditsTests: XCTestCase {
    private final class FieldRig {
        typealias Field = DictationField<String>
        var field: Field? = Field(process: 42, bundleID: "test.editor", identity: "composer",
            value: "hello SELECT suffix", selection: NSRange(location: 6, length: 6))
        var time: TimeInterval = 100
        var writes: [Field] = []
        var acceptWrite = true
        var applyWrite = true
        var onRead: (() -> Void)?
        lazy var edits = GuardedDictationEdits(read: { [unowned self] in onRead?(); return field },
            write: { [unowned self] desired in
                writes.append(desired)
                if applyWrite { field = desired }
                return acceptWrite
            }, now: { [unowned self] in time })
        let raw = "um 😀 raw"
        let cleaned = "Clean 😀"
        func change(value: String? = nil, selection: NSRange? = nil, identity: String? = nil,
                    process: Int32? = nil, bundleID: String? = nil, secure: Bool = false) {
            let old = field!
            field = Field(process: process ?? old.process, bundleID: bundleID ?? old.bundleID,
                identity: identity ?? old.identity, value: value ?? old.value,
                selection: selection ?? old.selection, secure: secure)
        }
        func land(file: StaticString = #filePath, line: UInt = #line) throws {
            let token = try XCTUnwrap(edits.beginInsertion(raw: raw, cleaned: cleaned), file: file, line: line)
            change(value: "hello Clean 😀 suffix", selection: NSRange(location: 14, length: 0))
            XCTAssertTrue(edits.confirmInsertion(token, posted: true), file: file, line: line)
            XCTAssertNotNil(edits.receipt, file: file, line: line)
        }
    }

    func testUndoRestoresReplacedSelectionAndCaretAtInsertionPoint() throws {
        let rig = FieldRig(); try rig.land()
        let receipt = try XCTUnwrap(rig.edits.receipt)
        XCTAssertEqual(receipt.raw, rig.raw); XCTAssertEqual(receipt.cleaned, rig.cleaned)
        XCTAssertEqual(receipt.insertedRange, NSRange(location: 6, length: 8))
        XCTAssertEqual(receipt.timestamp, 100)
        XCTAssertEqual(rig.edits.perform(.undo), .replaced)
        XCTAssertEqual(rig.field?.value, "hello SELECT suffix")
        XCTAssertEqual(rig.field?.selection, NSRange(location: 6, length: 0))
        XCTAssertEqual(rig.writes.count, 1); XCTAssertNil(rig.edits.receipt)
    }

    func testRestoreRawPreservesSurroundingsAndUnicodeCaret() throws {
        let rig = FieldRig(); try rig.land()
        XCTAssertEqual(rig.edits.perform(.restoreRaw), .replaced)
        XCTAssertEqual(rig.field?.value, "hello um 😀 raw suffix")
        XCTAssertEqual(rig.field?.selection, NSRange(location: 15, length: 0))
        XCTAssertEqual(rig.writes.count, 1); XCTAssertNil(rig.edits.receipt)
    }

    private func refuses(_ alter: (FieldRig) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        for action in [GuardedDictationEdits<String>.Action.undo, .restoreRaw] {
            let rig = FieldRig(); try rig.land(); alter(rig)
            let before = rig.field
            XCTAssertEqual(rig.edits.perform(action), .refused, file: file, line: line)
            XCTAssertEqual(rig.field, before, file: file, line: line)
            XCTAssertTrue(rig.writes.isEmpty, file: file, line: line)
            XCTAssertNil(rig.edits.receipt, file: file, line: line)
        }
    }
    func testEditedValueRefusesWithoutWrite() throws { try refuses { $0.change(value: "user edit") } }
    func testMovedCaretRefusesWithoutWrite() throws { try refuses { $0.change(selection: NSRange(location: 0, length: 0)) } }
    func testSelectedTextRefusesWithoutWrite() throws { try refuses { $0.change(selection: NSRange(location: 6, length: 8)) } }
    func testRefocusedElementRefusesWithoutWrite() throws { try refuses { $0.change(identity: "other composer") } }
    func testDifferentProcessRefusesWithoutWrite() throws { try refuses { $0.change(process: 43) } }
    func testDifferentBundleRefusesWithoutWrite() throws { try refuses { $0.change(bundleID: "other.editor") } }
    func testSecureFieldRefusesWithoutWrite() throws { try refuses { $0.change(secure: true) } }
    func testUnavailableFieldRefusesWithoutWrite() throws { try refuses { $0.field = nil } }
    func testExactTenMinuteExpiryRefusesWithoutWrite() throws { try refuses { $0.time += 600 } }

    func testImmediateRereadRejectsChangeAfterAvailabilityCheck() throws {
        let rig = FieldRig(); try rig.land()
        XCTAssertNotNil(rig.edits.receipt)
        rig.onRead = { [unowned rig] in rig.change(value: "last instant edit") }
        XCTAssertEqual(rig.edits.perform(.undo), .refused)
        XCTAssertTrue(rig.writes.isEmpty)
    }

    func testReadbackMismatchIsUnverifiedAndNeverWritesAgain() throws {
        for action in [GuardedDictationEdits<String>.Action.undo, .restoreRaw] {
            let rig = FieldRig(); try rig.land(); rig.applyWrite = false
            XCTAssertEqual(rig.edits.perform(action), .unverified)
            XCTAssertEqual(rig.writes.count, 1)
            XCTAssertEqual(rig.edits.perform(action), .refused)
            XCTAssertEqual(rig.writes.count, 1)
        }
    }

    func testFailedNativeReturnIsUnverifiedEvenWhenValueLands() throws {
        let rig = FieldRig(); try rig.land(); rig.acceptWrite = false
        XCTAssertEqual(rig.edits.perform(.restoreRaw), .unverified)
        XCTAssertEqual(rig.edits.perform(.undo), .refused)
        XCTAssertEqual(rig.writes.count, 1)
    }

    func testUnverifiedOrFailedInsertionHasNoReceiptOrWrite() throws {
        for posted in [false, true] {
            let rig = FieldRig(); try rig.land()
            let token = try XCTUnwrap(rig.edits.beginInsertion(raw: "next raw", cleaned: "next"))
            XCTAssertNil(rig.edits.receipt)
            XCTAssertFalse(rig.edits.confirmInsertion(token, posted: posted))
            XCTAssertEqual(rig.edits.perform(.undo), .refused)
            XCTAssertTrue(rig.writes.isEmpty)
        }
    }

    func testNextDictationClearsReceiptAndLateConfirmationCannotRevive() throws {
        let rig = FieldRig(); try rig.land()
        let old = try XCTUnwrap(rig.edits.beginInsertion(raw: "next", cleaned: "next"))
        rig.edits.clear()
        XCTAssertFalse(rig.edits.confirmInsertion(old, posted: true))
        XCTAssertNil(rig.edits.receipt)
        XCTAssertEqual(rig.edits.perform(.restoreRaw), .refused)
        XCTAssertTrue(rig.writes.isEmpty)
    }

    func testInsertionReadbackRequiresSameIdentitySecurityValueAndSelection() throws {
        let alterations: [(FieldRig) -> Void] = [
            { $0.change(identity: "other") }, { $0.change(process: 43) },
            { $0.change(bundleID: "other") }, { $0.change(secure: true) },
            { $0.change(value: "different") }, { $0.change(selection: NSRange(location: 0, length: 0)) }
        ]
        for alter in alterations {
            let rig = FieldRig(); try rig.land()
            let token = try XCTUnwrap(rig.edits.beginInsertion(raw: "raw", cleaned: "next"))
            rig.change(value: "hello Clean 😀next suffix", selection: NSRange(location: 18, length: 0))
            alter(rig)
            XCTAssertFalse(rig.edits.confirmInsertion(token, posted: true))
            XCTAssertNil(rig.edits.receipt); XCTAssertTrue(rig.writes.isEmpty)
        }
    }

    func testExactUTF16ComparisonRejectsCanonicallyEquivalentEdit() throws {
        let rig = FieldRig(); try rig.land()
        rig.change(value: "é", selection: NSRange(location: 1, length: 0))
        let token = try XCTUnwrap(rig.edits.beginInsertion(raw: "raw", cleaned: "x"))
        rig.change(value: "e\u{301}x", selection: NSRange(location: 2, length: 0))
        XCTAssertFalse(rig.edits.confirmInsertion(token, posted: true))
        XCTAssertNil(rig.edits.receipt); XCTAssertTrue(rig.writes.isEmpty)
    }

    func testSecureOrInvalidRangeAtDispatchDoesNotCapture() throws {
        for invalid in [false, true] {
            let rig = FieldRig(); try rig.land()
            if invalid { rig.change(selection: NSRange(location: 1_000, length: 0)) }
            else { rig.change(secure: true) }
            XCTAssertNil(rig.edits.beginInsertion(raw: "raw", cleaned: "next"))
            XCTAssertNil(rig.edits.receipt); XCTAssertTrue(rig.writes.isEmpty)
        }
    }
}
