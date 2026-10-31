import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

final class ExperimentItem: ClipboardItem {
    var values: [NSPasteboard.PasteboardType: Data]
    var declaredTypes: [NSPasteboard.PasteboardType]?
    var types: [NSPasteboard.PasteboardType] { declaredTypes ?? Array(values.keys) }
    var provider: ClipboardRequestProvider?
    var onRead: (() -> Void)?, onRegister: (() -> Void)?
    var setterSucceeds = true, registrationSucceeds = true
    init(_ values: [NSPasteboard.PasteboardType: Data] = [:]) { self.values = values }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { onRead?(); return values[type] }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        guard setterSucceeds else { return false }; values[type] = data; return true
    }
    func register(_ provider: ClipboardRequestProvider) -> Bool {
        self.provider = provider; onRegister?(); return registrationSucceeds
    }
    func request(validBoard: Bool = true, validItem: Bool = true, type: NSPasteboard.PasteboardType = .string,
                 succeeds: Bool = true, during: (() -> Void)? = nil) {
        provider?.provide(validBoard: validBoard, validItem: validItem, type: type) { data in
            during?()
            if succeeds { self.values[type] = data }; return succeeds
        }
    }
    func cachedRead() -> Data? { values[.string] } // does not invoke the provider
}
final class ExperimentBoard: ClipboardBoard {
    var changeCount = 1, denied = false, nilItems = false
    var contents: [ExperimentItem] = [ExperimentItem([.string: Data("PRIVATE_ORIGINAL".utf8)])]
    var onItems: (() -> Void)?, onMake: ((ExperimentItem) -> Void)?
    var onWrite: (([ExperimentItem]) -> Void)?
    var writeResults: [Bool] = []
    var clears = 0, writes = 0, makes = 0
    var makeFails = false
    var items: [ClipboardItem]? { onItems?(); return nilItems ? nil : contents }
    func makeItem() -> ClipboardItem? {
        makes += 1; guard !makeFails else { return nil }
        let item = ExperimentItem(); onMake?(item); return item
    }
    func clear() -> Int { clears += 1; changeCount += 1; contents = []; return changeCount }
    func write(_ items: [ClipboardItem]) -> Bool {
        writes += 1; contents = items.map { $0 as! ExperimentItem }; onWrite?(contents)
        return writeResults.isEmpty ? true : writeResults.removeFirst()
    }
    func copy(_ text: String) { changeCount += 1; contents = [ExperimentItem([.string: Data(text.utf8)])] }
    var values: ClipboardDelivery.Snapshot { contents.map(\.values) }
}
final class ExperimentRig {
    final class Timer {
        let at: Double, action: () -> Void
        var canceled = false
        init(_ at: Double, _ action: @escaping () -> Void) { self.at = at; self.action = action }
    }
    let board = ExperimentBoard(), diagnostics = DiagnosticStore()
    var time = 100.0, posts = 0
    var timers: [Timer] = [], notices: [() -> Void] = []
    lazy var operation = PendingOperation(name: "PRIVATE_OPERATION", diagnostics: diagnostics)
    lazy var delivery = ClipboardDelivery(board: board, now: { [unowned self] in time }, schedule: { [unowned self] delay, action in
        let timer = Timer(time + delay, action); timers.append(timer)
        return { timer.canceled = true }
    }, enqueue: { [unowned self] in notices.append($0) })
    var current: ExperimentItem { board.contents[0] }
    var evidence: DiagnosticClipboard? { diagnostics.snapshot().records.first?.clipboard }
    func paste(_ text: String = "PRIVATE_PREPARED", mode: ClipboardRestoreMode = .observableRequests,
               delay: Double = 0.8, post: (() -> Void)? = nil) -> Bool {
        DiagnosticDispatch.paste(diagnostics: operation.diagnostics) {
            delivery.paste(text, restoreAfter: delay, mode: mode, diagnostics: operation.diagnostics) {
                self.posts += 1; post?()
            }
        }
    }
    func flush() { let queued = notices; notices = []; queued.forEach { $0() } }
    func fire(_ timer: Timer, at: Double? = nil) { time = at ?? timer.at; timer.action() }
}

final class ClipboardExperimentTests: XCTestCase {
    func testCombinedTerminationRepliesExactlyOnceAfterBothOwnersInEitherOrder() {
        for clipboardFirst in [false, true] {
            var board: ((Bool) -> Void)?, update: ((Bool) -> Void)?
            var replies: [Bool] = [], cancels = 0
            let coordinator = TerminationCoordinator(clipboard: { board = $0 }, updater: { update = $0 },
                cancelClipboard: { cancels += 1 }, cancelUpdater: { cancels += 1 },
                reply: { replies.append($0) }, failure: { XCTFail("unexpected failure") })
            XCTAssertEqual(coordinator.request(), .terminateLater)
            XCTAssertEqual(coordinator.request(), .terminateLater)
            if clipboardFirst { board?(true) } else { update?(true) }
            XCTAssertTrue(replies.isEmpty)
            if clipboardFirst { update?(true) } else { board?(true) }
            XCTAssertEqual(replies, [true]); board?(true); update?(true)
            XCTAssertEqual(replies, [true]); XCTAssertEqual(cancels, 0)
        }
    }
    func testActualLeaseAndCombinedUpdaterCompletionKeepProviderAliveUntilQuietSettlement() {
        let rig = ExperimentRig(); XCTAssertTrue(rig.paste())
        var update: ((Bool) -> Void)?, replies: [Bool] = []
        let coordinator = TerminationCoordinator(clipboard: rig.delivery.beginShutdown, updater: { update = $0 },
            cancelClipboard: rig.delivery.cancelShutdown, cancelUpdater: {}, reply: { replies.append($0) },
            failure: { XCTFail("unexpected failure") })
        XCTAssertEqual(coordinator.request(), .terminateLater)
        update?(true); XCTAssertTrue(replies.isEmpty)
        XCTAssertFalse(rig.paste("quit blocked"))
        rig.current.provider?.finished(); rig.current.request(); rig.flush()
        rig.fire(rig.timers.last!)
        XCTAssertEqual(replies, [true]); XCTAssertFalse(rig.delivery.isRestorePending)
        update?(true); XCTAssertEqual(replies, [true])
    }
    func testFailedOwnedRestoreCancelsCombinedQuitRetainsOriginalAndMenuStatusIsContentFree() {
        let rig = ExperimentRig(); XCTAssertTrue(rig.paste())
        var updaterReply: ((Bool) -> Void)?, replies: [Bool] = [], cancels = 0, failures = 0
        let coordinator = TerminationCoordinator(clipboard: rig.delivery.beginShutdown, updater: { updaterReply = $0 },
            cancelClipboard: rig.delivery.cancelShutdown, cancelUpdater: { cancels += 1 },
            reply: { replies.append($0) }, failure: { failures += 1 })
        XCTAssertEqual(coordinator.request(), .terminateLater)
        rig.board.writeResults = [false]; rig.fire(rig.timers[0])
        XCTAssertEqual(replies, [false]); XCTAssertEqual(cancels, 1); XCTAssertEqual(failures, 1)
        updaterReply?(true); XCTAssertEqual(replies, [false])
        XCTAssertTrue(rig.delivery.isRestorePending); XCTAssertTrue(rig.delivery.restoreFailed)
        XCTAssertFalse(rig.paste("no unsafe restart or second paste"))
        let menu = NSMenu(); AppDelegate.addClipboardRestoreStatus(to: menu, failed: rig.delivery.restoreFailed)
        XCTAssertEqual(menu.items.count, 1); XCTAssertNil(menu.items[0].action)
        XCTAssertFalse(menu.items[0].title.contains("PRIVATE_"))
        XCTAssertEqual(coordinator.request(), .terminateCancel); XCTAssertEqual(replies, [false])
        rig.board.copy("recovery copy")
        XCTAssertEqual(coordinator.request(), .terminateLater)
        updaterReply?(true); XCTAssertEqual(replies, [false, true])
    }
    func testSynchronousTerminationNeedsNoLateApplicationReplyAndFailedOwnerCancelsIntentOnly() {
        var replies = 0, canceled = 0, failed = 0
        let ready = TerminationCoordinator(clipboard: { $0(true) }, updater: { $0(true) }, cancelClipboard: {},
            cancelUpdater: {}, reply: { _ in replies += 1 }, failure: { failed += 1 })
        XCTAssertEqual(ready.request(), .terminateNow); XCTAssertEqual(replies, 0)
        let bad = TerminationCoordinator(clipboard: { $0(false) }, updater: { _ in },
            cancelClipboard: { canceled += 1 }, cancelUpdater: { canceled += 1 },
            reply: { _ in replies += 1 }, failure: { failed += 1 })
        XCTAssertEqual(bad.request(), .terminateCancel); XCTAssertEqual(replies, 0)
        XCTAssertEqual(canceled, 2); XCTAssertEqual(failed, 1)
    }
    func testFreshConfigurationFactoryDrivesOrdinaryAndStoredExecutorIntoActualDelivery() {
        let rig = ExperimentRig()
        var settings: Settings? = Settings(), reads = 0, dispatches = 0, corrections = 0
        let original = OriginalCopyController(configuration: { settings }, generation: { 0 }, security: { .safe }, copy: { _ in XCTFail() })
        let post = DictationInsertionExecutor.configuredPoster(configuration: { reads += 1; return settings },
            native: { text, diagnostic, mode, dispatch in
                rig.delivery.paste(text, mode: mode, diagnostics: diagnostic) { dispatch(); dispatches += 1 }
            })
        let executor = DictationInsertionExecutor(originals: original, post: post, didPost: { _ in corrections += 1 })
        XCTAssertEqual(executor.insert("fixed", original: nil, operation: rig.operation), true)
        XCTAssertNil(rig.current.provider); rig.fire(rig.timers.last!)
        settings?.clipboardReceiptRestoreEnabled = true
        XCTAssertTrue(executor.insertStored("experimental stored")); XCTAssertNotNil(rig.current.provider)
        rig.current.request(); rig.flush(); rig.fire(rig.timers.last!)
        XCTAssertEqual(corrections, 1) // stored still has no correction learning
        settings = nil // invalid authoritative config
        XCTAssertTrue(executor.insertStored("invalid config uses baseline")); XCTAssertNil(rig.current.provider)
        rig.fire(rig.timers.last!)
        settings = Settings(); settings?.clipboardReceiptRestoreEnabled = true
        XCTAssertEqual(executor.insert("experimental ordinary", original: nil, operation: PendingOperation(name: "next")), true)
        XCTAssertNotNil(rig.current.provider); XCTAssertEqual(reads, 4); XCTAssertEqual(dispatches, 4)
        settings?.clipboardReceiptRestoreEnabled = false
        original.clear(); rig.operation.finish()
        rig.current.request(); rig.flush(); rig.fire(rig.timers.last!)
        XCTAssertFalse(rig.delivery.isRestorePending)
    }
    func testStoredPasteDoesNotBorrowPriorDiagnosticHandle() {
        let rig = ExperimentRig(); var settings = Settings(); settings.clipboardReceiptRestoreEnabled = true
        let originals = OriginalCopyController(configuration: { settings }, generation: { 0 }, security: { .safe }, copy: { _ in })
        let executor = DictationInsertionExecutor(originals: originals,
            post: DictationInsertionExecutor.configuredPoster(configuration: { settings }, native: { text, diagnostics, mode, hook in
                XCTAssertNil(diagnostics)
                return rig.delivery.paste(text, mode: mode, diagnostics: diagnostics, postPaste: hook)
            }), didPost: { _ in XCTFail("stored learning") })
        _ = rig.operation
        XCTAssertTrue(executor.insertStored("PRIVATE_HISTORY")); rig.current.request(); rig.flush(); rig.fire(rig.timers.last!)
        XCTAssertNil(rig.diagnostics.snapshot().records[0].clipboard)
    }
}

extension ClipboardExperimentTests {
    func testActualUpdaterTerminationOwnerCancelsOnlyBeforeCommitAndCombinesOnceWithLease() {
        for committing in [false, true] {
            let rig = ExperimentRig(); XCTAssertTrue(rig.paste())
            let update = UpdateTerminationIntent()
            var installCanceled = 0, replies: [Bool] = []
            let coordinator = TerminationCoordinator(clipboard: rig.delivery.beginShutdown,
                updater: { update.request(waitingForInstall: true, committing: committing,
                    cancelInstall: { installCanceled += 1 }, reply: $0) },
                cancelClipboard: rig.delivery.cancelShutdown, cancelUpdater: update.cancel,
                reply: { replies.append($0) }, failure: { XCTFail("unexpected failure") })
            XCTAssertEqual(coordinator.request(), .terminateLater)
            XCTAssertEqual(installCanceled, committing ? 0 : 1)
            rig.fire(rig.timers[0]); XCTAssertTrue(replies.isEmpty); XCTAssertTrue(update.isPending)
            update.complete(); XCTAssertEqual(replies, [true]); update.complete()
            XCTAssertEqual(replies, [true]); XCTAssertFalse(update.isPending)
        }
    }
    func testUpdaterIntentCancellationDoesNotCompleteOrAlterInstallSafetyBarrier() {
        let intent = UpdateTerminationIntent(); var committing = true, replies = 0, cancels = 0
        intent.request(waitingForInstall: true, committing: committing, cancelInstall: { cancels += 1 }, reply: { _ in replies += 1 })
        intent.cancel(); intent.complete()
        XCTAssertTrue(committing); XCTAssertEqual(cancels, 0); XCTAssertEqual(replies, 0)
        committing = false
        intent.request(waitingForInstall: false, committing: committing, cancelInstall: { cancels += 1 }, reply: { _ in replies += 1 })
        XCTAssertEqual(cancels, 0); XCTAssertEqual(replies, 1); XCTAssertFalse(intent.isPending)
    }
}
