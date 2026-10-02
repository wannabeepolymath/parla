import AppKit
import XCTest
@testable import ParlaCore

final class ClipboardDeliveryTests: XCTestCase {
    private final class UnreadableProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {}
    }
    let board = NSPasteboard.withUniqueName()
    var timers: [() -> Void] = []
    lazy var delivery = ClipboardDelivery(board: board, schedule: { _, action in self.timers.append(action) })

    override func tearDown() {
        board.releaseGlobally()
        super.tearDown()
    }

    func seed() -> ClipboardDelivery.Snapshot {
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data("{\\rtf1\\ansi original}".utf8), forType: .rtf)
        first.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        let second = NSPasteboardItem()
        second.setData(Data([7, 8, 9]), forType: .init("com.parla.test.custom"))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([first, second]))
        return ClipboardDelivery.snapshot(board)!
    }

    func testPasteExposesWholeEmailThenRestoresEveryOriginalRepresentation() {
        let original = seed()
        let text = "Hi Sam,\n\nThanks for the update. 😀\n\nBest,\nAlex"
        var posted = false
        XCTAssertTrue(delivery.paste(text) {
            posted = true
            XCTAssertEqual(self.board.string(forType: .string), text)
            XCTAssertNotNil(self.board.data(forType: .init("org.nspasteboard.TransientType")))
            XCTAssertNotNil(self.board.data(forType: .init("org.nspasteboard.ConcealedType")))
        })
        XCTAssertTrue(posted)
        XCTAssertEqual(timers.count, 1)
        timers[0]()
        XCTAssertEqual(ClipboardDelivery.snapshot(board), original)
    }

    func testUserCopyDuringPasteIsNeverOverwritten() {
        _ = seed()
        XCTAssertTrue(delivery.paste("dictation") {})
        board.clearContents()
        board.setString("new user copy", forType: .string)
        timers[0]()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testOverlappingPastesRestoreOriginalAndIgnoreOldTimer() {
        let original = seed()
        XCTAssertTrue(delivery.paste("first") {})
        XCTAssertTrue(delivery.paste("second") {})
        timers[0]()
        XCTAssertEqual(board.string(forType: .string), "second")
        timers[1]()
        XCTAssertEqual(ClipboardDelivery.snapshot(board), original)
    }

    func testUserCopyBetweenPastesBecomesNewOriginal() {
        _ = seed()
        XCTAssertTrue(delivery.paste("first") {})
        board.clearContents()
        board.setString("new user copy", forType: .string)
        XCTAssertTrue(delivery.paste("second") {})
        timers[0]()
        timers[1]()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testEmptyClipboardIsRestoredEmpty() {
        board.clearContents()
        XCTAssertTrue(delivery.paste("dictation") {})
        timers[0]()
        XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
    }

    func testUnreadableClipboardIsNeverClearedAndNoPasteIsPosted() {
        let item = NSPasteboardItem()
        let provider = UnreadableProvider()
        let type = NSPasteboard.PasteboardType("com.parla.test.unreadable")
        item.setDataProvider(provider, forTypes: [type])
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        let stamp = board.changeCount
        var posted = false
        XCTAssertFalse(delivery.paste("dictation") { posted = true })
        XCTAssertFalse(posted)
        XCTAssertEqual(board.changeCount, stamp)
        XCTAssertTrue(board.types?.contains(type) ?? false)
    }
}
