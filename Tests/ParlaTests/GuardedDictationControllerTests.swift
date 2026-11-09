import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

final class GuardedDictationControllerTests: XCTestCase {
    private final class Rig {
        struct Timer { let delay: TimeInterval; let fire: () -> Void }
        var field = DictationField(process: 42, bundleID: "test.app", identity: "field",
            value: "prefix ", selection: NSRange(location: 7, length: 0))
        var time: TimeInterval = 100
        var timers: [Timer] = []
        var writes = 0
        lazy var edits = GuardedDictationEdits(read: { [unowned self] in field },
            write: { [unowned self] in writes += 1; field = $0; return true }, now: { [unowned self] in time })
        lazy var controller = GuardedDictationController(edits: edits, now: { [unowned self] in time },
            schedule: { [unowned self] delay, action in
                timers.append(Timer(delay: delay, fire: action)); return {}
            })
        func applied() {
            field = DictationField(process: 42, bundleID: "test.app", identity: "field",
                value: "prefix Clean", selection: NSRange(location: 12, length: 0))
        }
        func land(file: StaticString = #filePath, line: UInt = #line) {
            controller.willPost(raw: "um raw", cleaned: "Clean"); applied(); controller.completed(posted: true)
            XCTAssertNotNil(controller.refresh(), file: file, line: line)
        }
    }

    @MainActor func testDelayedPasteReadbackPublishesOnlyAfterExactConfirmation() throws {
        let rig = Rig()
        rig.controller.willPost(raw: "um raw", cleaned: "Clean"); rig.controller.completed(posted: true)
        XCTAssertNil(rig.controller.refresh()); XCTAssertEqual(rig.timers.first?.delay, 0.05)
        rig.applied(); rig.timers[0].fire()
        let token = try XCTUnwrap(rig.controller.refresh())
        XCTAssertEqual(rig.controller.perform(.restoreRaw, token: token), .replaced)
        XCTAssertEqual(rig.field.value, "prefix um raw"); XCTAssertEqual(rig.writes, 1)
    }

    @MainActor func testExpiryAndCanceledOldTimerCannotClearNewReceipt() throws {
        let rig = Rig(); rig.land()
        let oldTimer = try XCTUnwrap(rig.timers.first)
        rig.controller.clear()
        rig.field = DictationField(process: 42, bundleID: "test.app", identity: "field",
            value: "prefix ", selection: NSRange(location: 7, length: 0))
        rig.land(); oldTimer.fire()
        XCTAssertNotNil(rig.controller.refresh())
        rig.time += 600
        XCTAssertNil(rig.controller.refresh()); XCTAssertNil(rig.edits.receipt)
        XCTAssertEqual(rig.writes, 0)
    }

    @MainActor func testClearRejectsStaleMenuTokenAndDelayedConfirmation() throws {
        let rig = Rig(); rig.land(); let token = try XCTUnwrap(rig.controller.refresh())
        rig.controller.clear()
        XCTAssertEqual(rig.controller.perform(.undo, token: token), .refused)
        rig.controller.willPost(raw: "raw", cleaned: "next"); rig.controller.completed(posted: true)
        let delayed = try XCTUnwrap(rig.timers.last)
        rig.controller.clear(); delayed.fire()
        XCTAssertNil(rig.controller.refresh()); XCTAssertNil(rig.edits.receipt); XCTAssertEqual(rig.writes, 0)
    }

    @MainActor func testFailedOrNeverConfirmedPasteLeavesNoReceiptAfterBoundedReads() {
        for posted in [false, true] {
            let rig = Rig(); rig.land()
            rig.controller.willPost(raw: "next", cleaned: "next"); rig.controller.completed(posted: posted)
            for index in 1..<rig.timers.count + 21 {
                if index < rig.timers.count { rig.timers[index].fire() }
            }
            XCTAssertNil(rig.controller.refresh()); XCTAssertNil(rig.edits.receipt)
            XCTAssertLessThanOrEqual(rig.timers.count, 21); XCTAssertEqual(rig.writes, 0)
        }
    }

    @MainActor func testNextAcceptedCaptureAndSecureEvidenceClearReceipt() {
        let rig = Rig(); rig.land()
        let machine = DictationSession(diagnostics: nil)
        machine.send(.startDictation(settings: Settings(), cleanupConfigured: false, live: false)) {
            rig.controller.observe($0)
        }
        XCTAssertNil(rig.controller.refresh()); XCTAssertNil(rig.edits.receipt)
        rig.field = DictationField(process: 42, bundleID: "test.app", identity: "field",
            value: "prefix ", selection: NSRange(location: 7, length: 0))
        rig.land(); rig.controller.observe(.focusSampled(gen: machine.gen, focus: .secure))
        XCTAssertNil(rig.controller.refresh()); XCTAssertEqual(rig.writes, 0)
    }

    @MainActor func testMenuActionsRequireReceiptAndHideLegacyOffStatus() throws {
        let originals = OriginalCopyController(configuration: { Settings() }, generation: { 1 },
            security: { .safe }, copy: { _ in XCTFail("automatic copy") })
        let actions = OriginalCopyMenuActions(controller: originals), menu = NSMenu(), receipt = UUID()
        var invoked: [(GuardedDictationEdits<Inserter.FieldIdentity>.Action, UUID)] = []
        actions.edit = { invoked.append(($0, $1)) }
        AppDelegate.addOriginalCopy(to: menu, status: .unavailable, target: actions, receipt: receipt)
        XCTAssertEqual(menu.items.prefix(3).map(\.title), ["Undo last dictation", "Restore original text", "Copy original text"])
        XCTAssertTrue(menu.items[0].isEnabled); XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertFalse(menu.items[2].isEnabled)
        actions.undoLastDictation(menu.items[0]); actions.restoreRawText(menu.items[1])
        XCTAssertEqual(invoked.count, 2); XCTAssertEqual(invoked.first?.0, .undo)
        XCTAssertEqual(invoked.dropFirst().first?.0, .restoreRaw); XCTAssertTrue(invoked.allSatisfy { $0.1 == receipt })
        menu.removeAllItems()
        AppDelegate.addOriginalCopy(to: menu, status: .disabled, target: actions)
        XCTAssertEqual(menu.items.count, 3) // two disabled actions and separator
        XCTAssertTrue(menu.items.prefix(2).allSatisfy { !$0.isEnabled && $0.action == nil })
        XCTAssertFalse(menu.items.contains { $0.title == "Turned off" || $0.title == "Copy original text" })
    }
}
