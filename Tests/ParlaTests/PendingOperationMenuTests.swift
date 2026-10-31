import AppKit
import XCTest
import ParlaCore
@testable import Parla

final class PendingOperationMenuTests: XCTestCase {
    @MainActor func testProcessingMenuRetainsActualTokenAndShowsCooperativeStopping() {
        let machine = DictationSession()
        _ = machine.handle(.startDictation(settings: Settings(), cleanupConfigured: true, live: false))
        _ = machine.handle(.recorderStarted(gen: machine.gen))
        _ = machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
        _ = machine.handle(.stopRequested)
        let op = machine.pendingOperation!
        let menu = NSMenu()
        AppDelegate.addPendingOperation(to: menu, operation: op, target: nil)
        XCTAssertEqual(menu.items.first?.representedObject as? UUID, op.id)
        XCTAssertNotNil(menu.items.first?.action)
        XCTAssertEqual(menu.items.first?.keyEquivalent, "", "idle Esc must not become discard")
        op.revoke(); menu.removeAllItems()
        AppDelegate.addPendingOperation(to: menu, operation: op, target: nil)
        XCTAssertNil(menu.items.first?.action)
        XCTAssertEqual(menu.items.first?.title, "Discarded — stopping work…")
        op.finish(); menu.removeAllItems()
        AppDelegate.addPendingOperation(to: menu, operation: op, target: nil)
        XCTAssertTrue(menu.items.isEmpty)
    }
}
