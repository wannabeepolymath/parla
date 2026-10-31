import AppKit
import XCTest
@testable import ParlaCore

private final class FakeClipboardItem: ClipboardItem {
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
private final class FakeClipboardBoard: ClipboardBoard {
    var changeCount = 1, denied = false, nilItems = false
    var contents: [FakeClipboardItem] = [FakeClipboardItem([.string: Data("PRIVATE_ORIGINAL".utf8)])]
    var onClear: (() -> Void)?
    var onItems: (() -> Void)?, onMake: ((FakeClipboardItem) -> Void)?
    var onWrite: (([FakeClipboardItem]) -> Void)?
    var writeResults: [Bool] = []
    var clears = 0, writes = 0, makes = 0
    var makeFails = false
    var items: [ClipboardItem]? { onItems?(); return nilItems ? nil : contents }
    func makeItem() -> ClipboardItem? {
        makes += 1; guard !makeFails else { return nil }
        let item = FakeClipboardItem(); onMake?(item); return item
    }
    func clear() -> Int {
        clears += 1; changeCount += 1; contents = []
        let stamp = changeCount; onClear?(); return stamp
    }
    func write(_ items: [ClipboardItem]) -> Bool {
        writes += 1; contents = items.map { $0 as! FakeClipboardItem }; onWrite?(contents)
        return writeResults.isEmpty ? true : writeResults.removeFirst()
    }
    func copy(_ text: String) { changeCount += 1; contents = [FakeClipboardItem([.string: Data(text.utf8)])] }
    var values: ClipboardDelivery.Snapshot { contents.map(\.values) }
}
private final class ClipboardRig {
    final class Timer {
        let at: Double, action: () -> Void
        var canceled = false
        init(_ at: Double, _ action: @escaping () -> Void) { self.at = at; self.action = action }
    }
    let board = FakeClipboardBoard(), diagnostics = DiagnosticStore()
    var time = 100.0, posts = 0
    var timers: [Timer] = [], notices: [() -> Void] = []
    lazy var operation = PendingOperation(name: "PRIVATE_OPERATION", diagnostics: diagnostics)
    lazy var delivery = ClipboardDelivery(board: board, now: { [unowned self] in time }, schedule: { [unowned self] delay, action in
        let timer = Timer(time + delay, action); timers.append(timer)
        return { timer.canceled = true }
    }, enqueue: { [unowned self] in notices.append($0) })
    var current: FakeClipboardItem { board.contents[0] }
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

final class ClipboardDeliveryTransactionTests: XCTestCase {
    func testFixedAndEveryKnownRemoteUseEagerTextMarkersAndExactBaselineDelay() {
        for bundle in [nil, "com.microsoft.rdc.macos", "com.microsoft.windowsapp", "com.citrix.receiver.nomas",
                       "com.vmware.horizon", "com.anydesk.AnyDesk", "com.teamviewer.TeamViewer"] {
            let rig = ClipboardRig()
            let policy = Inserter.clipboardPolicy(mode: .fixed, bundleID: bundle)
            XCTAssertTrue(rig.paste(mode: policy.mode, delay: policy.delay))
            XCTAssertNil(rig.current.provider)
            XCTAssertEqual(rig.current.values[.string], Data("PRIVATE_PREPARED".utf8))
            XCTAssertEqual(rig.current.values.count, 5)
            for marker in ["TransientType", "ConcealedType", "AutoGeneratedType"] {
                XCTAssertEqual(rig.current.values[.init("org.nspasteboard.\(marker)")], Data())
            }
            XCTAssertEqual(rig.current.values[.init("org.nspasteboard.source")], Data("io.github.wannabeepolymath.parla".utf8))
            XCTAssertEqual(rig.timers[0].at, 100 + (bundle == nil ? 0.8 : 5))
            XCTAssertEqual(Inserter.clipboardPolicy(mode: .observableRequests, bundleID: bundle).mode,
                           bundle == nil ? .observableRequests : .remoteExcluded)
            rig.fire(rig.timers[0]); XCTAssertFalse(rig.delivery.isRestorePending)
        }
    }
    func testEveryRepresentationMultipleItemsAndEmptySnapshotRestoreExactly() {
        for empty in [false, true] {
            let rig = ClipboardRig()
            rig.board.contents = empty ? [] : [FakeClipboardItem([.string: Data("original".utf8), .rtf: Data([1, 2]), .png: Data([3]), .init("PRIVATE_UTI"): Data()]), FakeClipboardItem([.init("custom"): Data([8, 9])])]
            let original = rig.board.values
            XCTAssertTrue(rig.paste()); XCTAssertEqual(rig.timers[0].at, 108)
            rig.fire(rig.timers[0]); XCTAssertEqual(rig.board.values, original)
            XCTAssertEqual(rig.evidence?.restore, .restored); XCTAssertEqual(rig.evidence?.receipt, .noObservableReceipt)
        }
    }
    func testDeniedNilUnreadableAndMutatingSnapshotsRefuseBeforeClearOrPost() {
        for scenario in 0..<5 {
            let rig = ClipboardRig()
            switch scenario {
            case 0: rig.board.denied = true
            case 1: rig.board.nilItems = true
            case 2: rig.current.declaredTypes = [.rtf]
            case 3: rig.board.onItems = { rig.board.changeCount += 1 }
            default: rig.current.onRead = { rig.board.changeCount += 1 }
            }
            XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.posts, 0); XCTAssertEqual(rig.board.clears, 0)
            XCTAssertEqual(rig.evidence?.restore, .untouched)
        }
    }
    func testSnapshotDataItemRepresentationAndTypeNameCapsHaveExactBoundaries() {
        for extra in [0, 1] {
            let data = FakeClipboardBoard(); data.contents = [FakeClipboardItem([.string: Data(count: ClipboardDelivery.maxData + extra)])]
            XCTAssertEqual(ClipboardDelivery.snapshot(data, capped: true) != nil, extra == 0)
            let items = FakeClipboardBoard(); items.contents = (0..<(ClipboardDelivery.maxItems + extra)).map { _ in FakeClipboardItem() }
            XCTAssertEqual(ClipboardDelivery.snapshot(items, capped: true) != nil, extra == 0)
            let representations = FakeClipboardBoard()
            let pairs = (0..<(ClipboardDelivery.maxRepresentations + extra)).map { (NSPasteboard.PasteboardType("t\($0)"), Data()) }
            representations.contents = [FakeClipboardItem(Dictionary(uniqueKeysWithValues: pairs))]
            XCTAssertEqual(ClipboardDelivery.snapshot(representations, capped: true) != nil, extra == 0)
            let names = FakeClipboardBoard(); names.contents = [FakeClipboardItem([.init(String(repeating: "x", count: ClipboardDelivery.maxTypeBytes + extra)): Data()])]
            XCTAssertEqual(ClipboardDelivery.snapshot(names, capped: true) != nil, extra == 0)
            for source in [data, items, representations, names] {
                let rig = ClipboardRig(); rig.board.contents = source.contents
                XCTAssertEqual(rig.paste(), extra == 0)
                XCTAssertEqual(rig.board.clears, extra == 0 ? 1 : 0)
                if extra == 0 { rig.fire(rig.timers[0]); XCTAssertEqual(rig.board.values, source.values) }
            }
        }
        let aggregate = FakeClipboardBoard()
        aggregate.contents = [FakeClipboardItem([.string: Data(count: ClipboardDelivery.maxData), .rtf: Data([1])])]
        XCTAssertNil(ClipboardDelivery.snapshot(aggregate, capped: true))
        XCTAssertNotNil(ClipboardDelivery.snapshot(aggregate, capped: false))
        aggregate.contents = [FakeClipboardItem([
            .init(String(repeating: "x", count: ClipboardDelivery.maxTypeBytes)): Data(), .string: Data()])]
        XCTAssertNil(ClipboardDelivery.snapshot(aggregate, capped: true))
    }
    func testOverCapProductionRefusesWithoutUncappedFallbackAndUTF8TextBound() {
        for extra in [0, 1] {
            let rig = ClipboardRig()
            let text = String(repeating: "😀", count: ClipboardDelivery.maxText / 4) + (extra == 1 ? "x" : "")
            XCTAssertEqual(rig.paste(text), extra == 0)
            XCTAssertEqual(rig.board.clears, extra == 0 ? 1 : 0)
        }
        let rig = ClipboardRig(); rig.board.contents = [FakeClipboardItem([.rtf: Data(count: ClipboardDelivery.maxData + 1)])]
        XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.board.clears, 0); XCTAssertEqual(rig.posts, 0)
    }
    func testPreparationSetterAndRegistrationFailureLeaveOriginalUntouched() {
        for scenario in 0..<3 {
            let rig = ClipboardRig(); let original = rig.board.values
            if scenario == 0 { rig.board.makeFails = true }
            if scenario == 1 { rig.board.onMake = { $0.setterSucceeds = false } }
            if scenario == 2 { rig.board.onMake = { $0.registrationSucceeds = false } }
            XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.board.clears, 0)
            XCTAssertEqual(rig.posts, 0); XCTAssertEqual(rig.board.values, original)
        }
    }
    func testFalsePartialPublicationRollsBackOnceAndNeverPosts() {
        let rig = ClipboardRig(), original = [NSPasteboard.PasteboardType.string: Data("PRIVATE_ORIGINAL".utf8)]
        rig.board.writeResults = [false, true]
        XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.posts, 0)
        XCTAssertEqual(rig.board.values, [original]); XCTAssertFalse(rig.delivery.isRestorePending)
        XCTAssertEqual(rig.evidence?.end, .publicationFailed); XCTAssertEqual(rig.evidence?.restore, .restored)
    }
    func testPublicationFailureWithExternalOwnershipNeverRollsBackOverUserCopy() {
        let rig = ClipboardRig(); rig.board.writeResults = [false]
        rig.board.onWrite = { _ in rig.board.copy("new user") }
        XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.board.writes, 1)
        XCTAssertEqual(rig.current.values[.string], Data("new user".utf8)); XCTAssertEqual(rig.evidence?.restore, .skippedOwnershipChanged)
    }
    func testFailedRollbackAndRestoreRetainOriginalRefuseSecondPasteAndQuitUntilExternalCopy() {
        for rollback in [false, true] {
            let rig = ClipboardRig()
            if rollback { rig.board.writeResults = [false, false]; XCTAssertFalse(rig.paste()) }
            else { XCTAssertTrue(rig.paste()); rig.board.writeResults = [false]; rig.fire(rig.timers[0]) }
            XCTAssertTrue(rig.delivery.isRestorePending); XCTAssertTrue(rig.delivery.restoreFailed)
            XCTAssertEqual(rig.evidence?.restore, .failed)
            let writes = rig.board.writes
            XCTAssertFalse(rig.paste("second")); XCTAssertEqual(rig.board.writes, writes)
            var quit: Bool?; rig.delivery.beginShutdown { quit = $0 }; XCTAssertEqual(quit, false)
            rig.delivery.cancelShutdown()
            rig.board.copy("explicit original copy")
            XCTAssertTrue(rig.paste("second"))
            rig.fire(rig.timers.last!)
            XCTAssertEqual(rig.current.values[.string], Data("explicit original copy".utf8))
        }
    }
    func testRestorePreparationFailureDoesNotClearOrReportRestored() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); let clears = rig.board.clears
        rig.board.onMake = { $0.setterSucceeds = false }
        rig.fire(rig.timers[0]); XCTAssertEqual(rig.board.clears, clears)
        XCTAssertTrue(rig.delivery.isRestorePending); XCTAssertEqual(rig.evidence?.restore, .failed)
    }
    func testRequestsInPreparationPublicationAndPostPairAreServedButNeverEligible() {
        let rig = ClipboardRig()
        rig.board.onMake = { item in item.onRegister = { item.request() } }
        rig.board.onWrite = { items in items.first?.request() }
        XCTAssertTrue(rig.paste(post: {
            rig.current.request() // willPost window
            rig.current.request() // inside fake down/up pair
            rig.time += 0.1
        }))
        rig.flush()
        XCTAssertEqual(rig.current.cachedRead(), Data("PRIVATE_PREPARED".utf8))
        XCTAssertEqual(rig.evidence?.requests, 0); XCTAssertEqual(rig.timers.count, 1)
        rig.fire(rig.timers[0]); XCTAssertEqual(rig.evidence?.receipt, .noObservableReceipt)
    }
    func testWrongTypeItemNilBoardAndFailedSupplyNeverShortenLease() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste())
        rig.current.request(type: .rtf); rig.current.request(validItem: false)
        rig.current.request(validBoard: false); rig.current.request(succeeds: false)
        rig.current.provider?.finished(); rig.flush()
        XCTAssertEqual(rig.evidence?.requests, 0); XCTAssertEqual(rig.evidence?.supplyFailures, 1)
        XCTAssertEqual(rig.timers.count, 1); XCTAssertTrue(rig.delivery.isRestorePending)
        rig.fire(rig.timers[0]); XCTAssertEqual(rig.evidence?.end, .maximum)
    }
    func testObservableRequestHonorsFloorThenQuietAndCachedReadsDoNotCount() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste())
        rig.time = 100.1; rig.current.request(); rig.flush()
        XCTAssertEqual(rig.timers.last!.at, 100.8, accuracy: 0.00001)
        for _ in 0..<10 { XCTAssertNotNil(rig.current.cachedRead()) }
        rig.time = 100.7; rig.current.request(); rig.flush()
        XCTAssertEqual(rig.evidence?.requests, 2)
        XCTAssertEqual(rig.timers.last!.at, 101, accuracy: 0.00001)
        rig.fire(rig.timers[1], at: 100.8) // canceled old timer
        XCTAssertTrue(rig.delivery.isRestorePending)
        rig.fire(rig.timers.last!); XCTAssertFalse(rig.delivery.isRestorePending)
        XCTAssertEqual(rig.evidence?.end, .quietAfterObservableRequest)
        XCTAssertEqual(rig.evidence?.receipt, .observed)
    }
    func testTimerDrainsAlreadyEnteredCallbackBeforeQueuedNotice() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste())
        rig.time = 100.1; rig.current.request(); rig.flush(); let quiet = rig.timers.last!
        rig.time = 100.75; rig.current.request() // do not deliver main notification
        rig.fire(quiet, at: 100.8)
        XCTAssertTrue(rig.delivery.isRestorePending); XCTAssertEqual(rig.evidence?.requests, 1) // no stale settlement
        rig.flush(); XCTAssertEqual(rig.evidence?.requests, 2)
        XCTAssertEqual(rig.timers.last!.at, 101.05, accuracy: 0.00001)
        rig.fire(rig.timers.last!); XCTAssertFalse(rig.delivery.isRestorePending)
    }
    func testNoRequestMaximumNonextendableDeadlineAndBlockedClockOverrun() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste())
        rig.time = 107.9; rig.current.request(); rig.flush()
        XCTAssertEqual(rig.timers.last!.at, 108)
        rig.fire(rig.timers[0], at: 112)
        XCTAssertFalse(rig.delivery.isRestorePending); XCTAssertEqual(rig.evidence?.end, .maximum)
        XCTAssertEqual(rig.evidence?.elapsedMs, 12000)
        let blocked = ClipboardRig(); XCTAssertTrue(blocked.paste(post: { blocked.time = 110 }))
        XCTAssertEqual(blocked.timers[0].at, 110) // no new 8-second extension
        blocked.fire(blocked.timers[0]); XCTAssertEqual(blocked.evidence?.receipt, .noObservableReceipt)
    }
    func testInFlightSupplyDefersRestoreAsynchronouslyAndDoesNotDeadlockOrLoseLastRequest() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); let item = rig.current
        rig.time = 100.1; item.request(); rig.flush(); let quiet = rig.timers.last!
        rig.time = 100.75
        item.request(during: {
            rig.fire(quiet, at: 100.8)
            XCTAssertTrue(rig.delivery.isRestorePending); XCTAssertEqual(rig.board.clears, 1)
            XCTAssertFalse(rig.paste("nested during active supply")) // settles asynchronously, refuses publication
        })
        rig.flush()
        // Superseding paste requested settlement, but no event pair was retried.
        XCTAssertFalse(rig.delivery.isRestorePending); XCTAssertEqual(rig.posts, 1)
        XCTAssertEqual(rig.current.values[.string], Data("PRIVATE_ORIGINAL".utf8))
    }
    func testInFlightMaximumWaitsForSupplyCompletionIncludingFailedSupply() {
        for succeeds in [false, true] {
            let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); rig.time = 108
            rig.current.request(succeeds: succeeds, during: {
                rig.fire(rig.timers[0]); XCTAssertTrue(rig.delivery.isRestorePending)
            })
            rig.flush(); XCTAssertFalse(rig.delivery.isRestorePending)
            XCTAssertEqual(rig.evidence?.restore, .restored)
            XCTAssertEqual(rig.evidence?.requests, succeeds ? 1 : 0)
        }
    }
    func testSecondPasteSnapshotsRestoredOriginalAndStaleProviderTimerCannotTouchReusedCount() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste("first"))
        let old = rig.current, oldTimer = rig.timers[0]
        XCTAssertTrue(rig.paste("second")); let current = rig.current
        rig.board.changeCount = 2 // deliberately reuse old lease count
        old.request(); old.provider?.finished(); rig.flush(); rig.fire(oldTimer)
        XCTAssertTrue(rig.delivery.isRestorePending); XCTAssertTrue(rig.current === current)
        // Current lease has lost ownership even though an older count matches.
        rig.fire(rig.timers.last!); XCTAssertTrue(rig.current === current)
        XCTAssertEqual(rig.evidence?.restore, .skippedOwnershipChanged)
    }
    func testUserManagerAndExplicitCopySurviveSettlementAndBecomeNextSnapshot() {
        for copy in ["user", "manager", "explicit Original"] {
            let rig = ClipboardRig(); XCTAssertTrue(rig.paste("first")); rig.board.copy(copy)
            XCTAssertTrue(rig.paste("second")); rig.fire(rig.timers.last!)
            XCTAssertEqual(rig.current.values[.string], Data(copy.utf8))
        }
    }
    func testReentrantPasteDuringSnapshotPublicationPostingAndRestoreRefuses() {
        let rig = ClipboardRig(); var reentries = 0
        let nested = { XCTAssertFalse(rig.paste("nested")); reentries += 1 }
        rig.current.onRead = nested
        rig.board.onWrite = { _ in nested() }
        XCTAssertTrue(rig.paste(post: nested)); rig.fire(rig.timers[0])
        XCTAssertEqual(rig.posts, 1); XCTAssertGreaterThanOrEqual(reentries, 4)
    }
    func testRecursiveProviderSupplyHasNoLockAcrossSetterAndOnlyBoundedScalars() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); let item = rig.current
        item.request(during: { item.request() }); rig.flush()
        XCTAssertEqual(rig.evidence?.requests, 2); XCTAssertEqual(rig.evidence?.restore, .pending)
    }
    func testFinishedOperationClearAndDisableDoNotDropProviderAndLateDiagnosticsStayOnRealHandle() throws {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); let provider = rig.current
        rig.operation.finish()
        let next = PendingOperation(name: "next", diagnostics: rig.diagnostics); next.finish()
        provider.provider?.finished(); provider.request(); rig.flush()
        XCTAssertEqual(rig.diagnostics.snapshot().records[0].clipboard?.requests, 1)
        XCTAssertTrue(rig.diagnostics.snapshot().records[0].operationFinished)
        XCTAssertEqual(rig.diagnostics.snapshot().records[0].delivery, .postedUnverified)
        XCTAssertNil(rig.diagnostics.snapshot().records[1].clipboard)
        let frozen = try rig.diagnostics.snapshot().encoded()
        rig.diagnostics.clear(); provider.request(); rig.flush(); rig.fire(rig.timers.last!)
        XCTAssertTrue(rig.diagnostics.snapshot().records.isEmpty)
        XCTAssertFalse(rig.delivery.isRestorePending)
        XCTAssertFalse(String(decoding: frozen, as: UTF8.self).contains("PRIVATE_"))
    }
    func testDiagnosticOldDecodeEvictionAndFiniteNumericEvidence() throws {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); rig.time = .infinity
        rig.current.request(); rig.flush(); rig.fire(rig.timers[0], at: 200)
        let data = try rig.diagnostics.snapshot().encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "clipboard"); object["records"] = records
        let oldData = try JSONSerialization.data(withJSONObject: records[0])
        XCTAssertNil(try JSONDecoder().decode(DiagnosticRecord.self, from: oldData).clipboard)
        XCTAssertEqual(DiagnosticClipboard.milliseconds(.nan), 0)
        XCTAssertEqual(DiagnosticClipboard.milliseconds(-5), 0)
        let evict = DiagnosticStore(countLimit: 1)
        let old = evict.start(id: UUID(), origin: .dictation)
        let board = FakeClipboardBoard()
        var action: (() -> Void)?
        let delivery = ClipboardDelivery(board: board, schedule: { _, a in action = a; return {} })
        XCTAssertTrue(delivery.paste("PRIVATE_TEXT", mode: .observableRequests, diagnostics: old) {})
        _ = evict.start(id: UUID(), origin: .recovery)
        board.contents[0].request(); action?()
        XCTAssertEqual(evict.snapshot().records.count, 1); XCTAssertNil(evict.snapshot().records[0].clipboard)
    }
    func testGracefulShutdownDrainsLatchedPolicyStopsNewLeaseAndCancellationKeepsOriginal() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); var replies: [Bool] = []
        rig.delivery.beginShutdown { replies.append($0) }
        XCTAssertTrue(replies.isEmpty); XCTAssertFalse(rig.paste("during quit"))
        rig.current.request(); rig.flush(); rig.fire(rig.timers.last!)
        XCTAssertEqual(replies, [true]); XCTAssertEqual(rig.evidence?.end, .quietAfterObservableRequest)
        let cancel = ClipboardRig(); XCTAssertTrue(cancel.paste())
        cancel.delivery.beginShutdown { _ in XCTFail("canceled intent") }; cancel.delivery.cancelShutdown()
        XCTAssertTrue(cancel.delivery.isRestorePending); cancel.fire(cancel.timers[0])
        XCTAssertEqual(cancel.current.values[.string], Data("PRIVATE_ORIGINAL".utf8))
    }
}

extension ClipboardDeliveryTransactionTests {
    func testFailedPreClearRestoreKeepsPromisedPayloadAvailableWithoutNewReceipt() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); let item = rig.current
        rig.board.makeFails = true; rig.fire(rig.timers[0])
        XCTAssertTrue(rig.delivery.restoreFailed); XCTAssertTrue(rig.current === item)
        item.request(); rig.flush()
        XCTAssertEqual(item.cachedRead(), Data("PRIVATE_PREPARED".utf8))
        XCTAssertEqual(rig.evidence?.requests, 0); XCTAssertEqual(rig.evidence?.restore, .failed)
        XCTAssertTrue(rig.delivery.isRestorePending)
    }
    func testLostOwnershipBeforeMailboxDrainCannotEstablishReceiptEvidence() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste())
        rig.current.request(); rig.board.copy("new owner")
        rig.fire(rig.timers[0])
        XCTAssertFalse(rig.diagnostics.snapshot().records[0].receiptObserved)
        XCTAssertEqual(rig.evidence?.requests, 0); XCTAssertEqual(rig.evidence?.restore, .skippedOwnershipChanged)
    }
    func testFulfillmentDuringRestoreItemPreparationIsSuppressedAndSettlesAfterSafeCompletion() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste()); let item = rig.current
        var supplies = 0
        rig.board.onMake = { _ in item.request(during: { supplies += 1 }) }
        rig.fire(rig.timers[0]); rig.flush()
        XCTAssertEqual(supplies, 1); XCTAssertEqual(rig.evidence?.requests, 0)
        XCTAssertEqual(rig.evidence?.restore, .restored)
    }
    func testLateRequestAtMaximumAndDuplicateNoticesNeverExtendMaximumOrCreateMoreThanTwoActiveTimers() {
        let rig = ClipboardRig(); XCTAssertTrue(rig.paste())
        for index in 1...20 {
            rig.time = 100 + Double(index) * 0.1; rig.current.request(); rig.flush()
            XCTAssertLessThanOrEqual(rig.timers.filter { !$0.canceled }.count, 2)
        }
        rig.time = 108; rig.current.request(); rig.flush()
        XCTAssertFalse(rig.delivery.isRestorePending); XCTAssertEqual(rig.evidence?.end, .maximum)
        XCTAssertEqual(rig.evidence?.requests, 21)
        rig.timers.forEach { $0.action() }; rig.flush()
        XCTAssertEqual(rig.posts, 1); XCTAssertEqual(rig.evidence?.restore, .restored)
    }
}

extension ClipboardDeliveryTransactionTests {
    func testShutdownReenteredDuringPreparationRefusesNewPublicationAndRepliesOnlyAfterAttemptDrains() {
        for duringRead in [false, true] {
            let rig = ClipboardRig(); var replies: [Bool] = [], inside = false
            let quit = {
                inside = true
                rig.delivery.beginShutdown { XCTAssertFalse(inside); replies.append($0) }
                XCTAssertTrue(replies.isEmpty); inside = false
            }
            if duringRead { rig.current.onRead = quit } else { rig.board.onMake = { _ in quit() } }
            XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.board.clears, 0)
            XCTAssertEqual(replies, [true]); XCTAssertEqual(rig.posts, 0)
        }
    }
    func testShutdownReenteredInsidePostingKeepsPromiseAndWaitsForExistingLatchedLease() {
        let rig = ClipboardRig(); var replies: [Bool] = []
        XCTAssertTrue(rig.paste(post: { rig.delivery.beginShutdown { replies.append($0) } }))
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(rig.delivery.isRestorePending)
        rig.current.request(); rig.flush(); rig.fire(rig.timers.last!)
        XCTAssertEqual(replies, [true]); XCTAssertEqual(rig.posts, 1)
    }
}

extension ClipboardDeliveryTransactionTests {
    func testShutdownDuringClearOrPublicationRollsBackBeforeAnyEventPair() {
        for duringClear in [true, false] {
            let rig = ClipboardRig(); var replies: [Bool] = []
            let quit = {
                rig.board.onClear = nil; rig.board.onWrite = nil
                rig.delivery.beginShutdown { replies.append($0) }
                XCTAssertTrue(replies.isEmpty)
            }
            if duringClear { rig.board.onClear = quit } else { rig.board.onWrite = { _ in quit() } }
            XCTAssertFalse(rig.paste()); XCTAssertEqual(rig.posts, 0)
            XCTAssertEqual(replies, [true]); XCTAssertFalse(rig.delivery.isRestorePending)
            XCTAssertEqual(rig.evidence?.end, .shutdown); XCTAssertEqual(rig.evidence?.receipt, .unknown)
            XCTAssertEqual(rig.current.values[.string], Data("PRIVATE_ORIGINAL".utf8))
        }
    }
}
