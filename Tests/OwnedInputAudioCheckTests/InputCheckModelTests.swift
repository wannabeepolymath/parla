import XCTest
@testable import ParlaCore
@testable import parla_owned_input_audio_check

private final class CheckClock {
    var now: TimeInterval = 0
    var next = 0
    var actions: [Int: (TimeInterval, () -> Void)] = [:]
    var all: [() -> Void] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        next += 1; let id = next
        actions[id] = (now + delay, action); all.append(action)
        return { self.actions[id] = nil }
    }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = actions.filter({ $0.value.0 <= end }).min(by: {
            $0.value.0 == $1.value.0 ? $0.key < $1.key : $0.value.0 < $1.value.0
        }) {
            now = next.value.0; actions[next.key] = nil; next.value.1()
        }
        now = end
    }
}
private final class CaptureBottom: MicrophoneTestCapturing {
    var starts = 0, stops = 0, clears = 0, snapshots = 0
    var current: UUID?
    var samples: [Float] = []
    var snapshotEnabled = true, failStart = false
    var ended: AudioRecorder.EndReason?
    func start(operation: UUID, lease: CaptureAdmission.Lease) throws {
        starts += 1; current = operation
        if failStart { throw InertFailure.forbiddenWrite }
    }
    func snapshot(operation: UUID) -> MicrophoneCaptureSnapshot? {
        snapshots += 1
        guard current == operation, snapshotEnabled else { return nil }
        return MicrophoneCaptureSnapshot(facts: nil, route: .init(name: "PRIVATE_ROUTE_NOT_FOR_RECEIPT", fallback: false),
            sampleCount: samples.count, level: 0.25, hasSignal: !samples.isEmpty, conversionFailures: 0, ended: ended)
    }
    func stop(operation: UUID) -> [Float] { guard current == operation else { return [] }; stops += 1; return samples }
    func clear(operation: UUID) { guard current == operation else { return }; clears += 1; current = nil; samples = [] }
}
private final class PlayerBottom: MicrophoneTestPlaying {
    var plays = 0, stops = 0
    var done: ((Bool) -> Void)?
    func play(samples: [Float], sampleRate: Double, finished: @escaping (Bool) -> Void) throws { plays += 1; done = finished }
    func stop() { stops += 1; done = nil }
}
private final class MicRig {
    let capture = CaptureBottom(), player = PlayerBottom(), clock = CheckClock(), admission = CaptureAdmission()
    var permission = MicPermission.granted, permissionReads = 0, requests = 0, playerCreations = 0
    var requestDone: ((Bool) -> Void)?
    var allowed = true
    lazy var mic = MicCheck(capture: capture, admission: admission,
        permission: { [unowned self] in permissionReads += 1; return permission },
        request: { [unowned self] in requests += 1; requestDone = $0 }, allowed: { [unowned self] in allowed },
        retained: { RetainedCounts(samples: 0, preRoll: 0, converter: false) },
        playerFactory: { [unowned self] in playerCreations += 1; return player },
        now: { [unowned self] in clock.now }, schedule: clock.schedule)
}
private final class MouseRig {
    let settings = InputCheckSettings(), authority = PhysicalInputAuthority(), admission = CaptureAdmission(), clock = CheckClock()
    var scope = true, creates = 0, registrations = 0
    var status = InputTapStatus.ready
    var queue: [() -> Void] = []
    lazy var mouse = MouseCheck(settings: settings, authority: authority, admission: admission,
        create: { [unowned self] in
            creates += 1
            let m = HotkeyMonitor(store: settings.store, inputAuthority: authority, captureAdmission: admission,
                tapEvents: .otherMouseOnly, buttonState: { _ in .down })
            m.deliversOnMain = true; m.enqueueOnMain = { [unowned self] in queue.append($0) }
            return m
        }, startMonitor: { [unowned self] in registrations += 1; $0.receiveTapStatus(status) },
        scope: { [unowned self] in scope }, schedule: clock.schedule)
    func arm() { mouse.rebind(MouseButtonBinding(buttonNumber: 2)); mouse.arm(acknowledged: true); drain() }
    @discardableResult func down(_ time: Double = 1) -> Bool { mouse.monitor!.receiveMouseEvent(button: 2, isDown: true, at: time) }
    @discardableResult func up(_ time: Double = 2) -> Bool { mouse.monitor!.receiveMouseEvent(button: 2, isDown: false, at: time) }
    func drain() { while !queue.isEmpty { queue.removeFirst()() } }
    func finishOnPhaseExpiry(_ completed: @escaping () -> Void) {
        mouse.phaseExpired = { [weak self] in completed(); self?.mouse.finish({}) }
    }
}

final class InputCheckModelTests: XCTestCase {
    func testInertInitializationAndRAMSettingsHaveNoBottomEffects() {
        let rig = MicRig(); _ = rig.mic
        XCTAssertEqual(rig.capture.starts, 0); XCTAssertEqual(rig.capture.snapshots, 0)
        XCTAssertEqual(rig.permissionReads, 0); XCTAssertEqual(rig.requests, 0); XCTAssertEqual(rig.playerCreations, 0)
        XCTAssertTrue(rig.clock.actions.isEmpty)
        let mouse = MouseRig(); _ = mouse.mouse
        XCTAssertEqual(mouse.creates, 0); XCTAssertEqual(mouse.registrations, 0)
        mouse.settings.bind(MouseButtonBinding(buttonNumber: 3))
        XCTAssertEqual(mouse.settings.store.load().mouseBinding?.buttonNumber, 3)
        XCTAssertEqual(mouse.settings.backend.calls, 0)
    }
    func testPermissionRefusalAndGrantRequireFreshExplicitStart() {
        let rig = MicRig(); rig.permission = .notDetermined
        rig.mic.start(); XCTAssertEqual(rig.capture.starts, 0); XCTAssertTrue(rig.admission.isAvailable)
        rig.mic.allowMicrophone(); XCTAssertEqual(rig.requests, 1)
        rig.requestDone?(true)
        XCTAssertEqual(rig.capture.starts, 0); XCTAssertFalse(rig.mic.capturing)
        XCTAssertEqual(rig.mic.receipt.permission, .granted)
        rig.permission = .granted; rig.mic.start()
        XCTAssertEqual(rig.capture.starts, 1); XCTAssertTrue(rig.mic.capturing)
        rig.mic.clear(); XCTAssertTrue(rig.admission.isAvailable)
    }
    func testPermissionCallbackAfterLeaveCannotChangeNewSession() {
        let rig = MicRig(); rig.permission = .notDetermined
        rig.mic.start(); rig.mic.allowMicrophone(); let stale = rig.requestDone
        rig.mic.clear(); rig.permission = .denied; rig.mic.start()
        stale?(true)
        XCTAssertEqual(rig.mic.receipt.permission, .denied); XCTAssertEqual(rig.capture.starts, 0)
    }
    func testNoPCMStopsAtIndependentTenSecondDeadlineAndNoIdlePolling() {
        let rig = MicRig(); rig.capture.snapshotEnabled = false
        rig.mic.start(); rig.clock.advance(9.9)
        XCTAssertTrue(rig.mic.capturing); XCTAssertEqual(rig.mic.state, .noPCM)
        rig.clock.advance(0.1)
        XCTAssertFalse(rig.mic.capturing); XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.mic.receipt.runs[0].ended, .deadline)
        XCTAssertTrue(rig.clock.actions.isEmpty)
        let snapshots = rig.capture.snapshots; rig.clock.advance(60)
        XCTAssertEqual(rig.capture.snapshots, snapshots); rig.mic.clear()
    }
    func testListenOnlyAfterStopAndUserAnswerIsSeparateFromCompletion() {
        let rig = MicRig(); rig.capture.samples = Array(repeating: 0.2, count: 1600)
        rig.mic.start(); rig.mic.listen(); XCTAssertEqual(rig.playerCreations, 0)
        rig.mic.stop(); rig.mic.listen()
        XCTAssertEqual(rig.player.plays, 1); XCTAssertNil(rig.mic.receipt.runs[0].heardConfirmed)
        rig.player.done?(true)
        XCTAssertNil(rig.mic.receipt.runs[0].heardConfirmed); XCTAssertTrue(rig.mic.askingHeard)
        rig.mic.heard(true); XCTAssertEqual(rig.mic.receipt.runs[0].heardConfirmed, true)
        rig.mic.clear(); XCTAssertEqual(rig.mic.review.count, 0); XCTAssertTrue(rig.admission.isAvailable)
        XCTAssertEqual(rig.mic.receipt.runs[0].retainedAfterClear, RetainedCounts(samples: 0, preRoll: 0, converter: false))
    }
    func testClearReleasesPlayerAndStalePlaybackAndPollCannotAffectNextRun() {
        let rig = MicRig(); rig.capture.samples = [0.1]
        rig.mic.start(); let staleTicks = rig.clock.all; rig.mic.stop(); rig.mic.listen()
        let stalePlayback = rig.player.done
        rig.mic.clear(); XCTAssertEqual(rig.player.stops, 1); XCTAssertTrue(rig.admission.isAvailable)
        rig.capture.samples = [0.2, 0.3]; rig.mic.start()
        stalePlayback?(true); staleTicks.forEach { $0() }
        XCTAssertTrue(rig.mic.capturing); XCTAssertFalse(rig.mic.askingHeard)
        XCTAssertEqual(rig.mic.sampleCount, 2); XCTAssertNil(rig.mic.receipt.runs[1].heardConfirmed)
        rig.mic.clear(); XCTAssertTrue(rig.clock.actions.isEmpty)
    }
    func testSampleCapRouteLossAndStartFailureStayFinite() {
        let capped = MicRig(); capped.capture.samples = Array(repeating: 0, count: 160_001)
        capped.mic.start(); XCTAssertFalse(capped.mic.capturing)
        XCTAssertEqual(capped.mic.review.count, 160_000); XCTAssertEqual(capped.mic.receipt.runs[0].ended, .sampleLimit); capped.mic.clear()
        let lost = MicRig(); lost.capture.ended = .deviceLost
        lost.mic.start(); XCTAssertEqual(lost.mic.state, .routeLost); XCTAssertEqual(lost.mic.receipt.runs[0].ended, .deviceLost); lost.mic.clear()
        for snapshots in [true, false] {
            let failed = MicRig(); failed.capture.failStart = true; failed.capture.snapshotEnabled = snapshots
            let suspendedBefore = HotkeyMonitor.suspended
            failed.mic.start(); XCTAssertEqual(failed.mic.state, .failed); XCTAssertTrue(failed.admission.isAvailable)
            XCTAssertEqual(failed.mic.receipt.runs[0].ended, .startFailed); XCTAssertTrue(failed.clock.actions.isEmpty)
            XCTAssertEqual(failed.mic.receipt.runs[0].status, .failed)
            XCTAssertFalse(failed.mic.capturing); XCTAssertEqual(failed.mic.captureStatus, .idle)
            XCTAssertTrue(failed.mic.review.isEmpty); XCTAssertNil(failed.capture.current)
            XCTAssertEqual(failed.capture.clears, 1); XCTAssertEqual(HotkeyMonitor.suspended, suspendedBefore)
            XCTAssertEqual(failed.mic.receipt.runs[0].retainedAfterClear, RetainedCounts(samples: 0, preRoll: 0, converter: false))
            failed.capture.failStart = false; failed.capture.samples = [0.2]
            failed.mic.start(); XCTAssertTrue(failed.mic.capturing)
            failed.mic.clear(); XCTAssertTrue(failed.admission.isAvailable)
            XCTAssertEqual(failed.mic.receipt.runs[0].ended, .startFailed)
            XCTAssertEqual(failed.mic.receipt.runs[1].ended, .cleared)
            XCTAssertEqual(HotkeyMonitor.suspended, suspendedBefore)
        }
    }
    func testLayoutWatchDeadlineStaleNotificationsAndCanonicalBytes() {
        let clock = CheckClock(); var reads = 0, removals = 0
        var notify: (() -> Void)?
        let ram = InputCheckSettings(), saved = InputCheckSettings().canonical()
        let originalBytes = ram.read(); var letter = "Q"
        let layout = LayoutCheck(snapshot: { reads += 1; let label = letter; return ShortcutDisplayFormatter { $0 == 0 ? label : nil } },
            observe: { notify = $0; return { removals += 1 } }, canonical: ram.canonical, schedule: clock.schedule)
        XCTAssertEqual(reads, 0)
        layout.watch(); let stale = notify; letter = "A"; notify?()
        XCTAssertEqual(layout.receipt.switchesSeen, 1); XCTAssertTrue(layout.receipt.savedUnchanged)
        clock.advance(60); XCTAssertFalse(layout.watching); XCTAssertEqual(removals, 1)
        let before = reads; stale?(); XCTAssertEqual(reads, before)
        XCTAssertEqual(saved, ram.canonical()); XCTAssertEqual(originalBytes, ram.read())
        XCTAssertEqual(layout.receipt.labelsChanged, 1); XCTAssertEqual(ram.backend.calls, 0)
    }
    func testDisarmedQueuedDownCannotBecomeAcceptedAfterRearm() {
        let rig = MouseRig(); rig.arm(); XCTAssertTrue(rig.down())
        rig.mouse.disarm(); rig.mouse.arm(acknowledged: true); rig.drain()
        XCTAssertEqual(rig.mouse.receipt.accepted, 0); XCTAssertEqual(rig.mouse.receipt.refusedQueued, 1)
        XCTAssertEqual(rig.mouse.monitor?.pendingMouseReleaseCount, 1)
        XCTAssertTrue(rig.up()); rig.drain(); rig.mouse.finish({})
    }
    func testFocusLossAndRebindRevokeActivePressWithoutLosingDebt() {
        let rig = MouseRig(); rig.arm(); rig.down(); rig.drain()
        rig.scope = false; rig.mouse.focusLost()
        XCTAssertFalse(rig.mouse.armed); XCTAssertEqual(rig.mouse.receipt.cancels, 1)
        XCTAssertEqual(rig.mouse.monitor?.pendingMouseReleaseCount, 1)
        XCTAssertTrue(rig.up()); rig.drain()
        rig.scope = true; rig.mouse.arm(acknowledged: true); rig.down(3); rig.drain()
        rig.mouse.rebind(nil); rig.drain()
        XCTAssertFalse(rig.mouse.armed); XCTAssertEqual(rig.mouse.monitor?.pendingMouseReleaseCount, 1)
        XCTAssertTrue(rig.up(4)); rig.drain(); rig.mouse.finish({})
        XCTAssertEqual(rig.mouse.receipt.holds, 0); XCTAssertEqual(rig.mouse.receipt.cancels, 2)
    }
    func testUnacknowledgedArmAndUnavailableNeverStartOrReopenPhase() {
        let rig = MouseRig(); rig.mouse.rebind(MouseButtonBinding(buttonNumber: 2))
        rig.mouse.arm(acknowledged: false); XCTAssertEqual(rig.creates, 0)
        rig.status = .unavailable; rig.mouse.arm(acknowledged: true)
        XCTAssertFalse(rig.mouse.armed); XCTAssertTrue(rig.mouse.onlyFinish)
        rig.mouse.monitor?.receiveTapStatus(.ready); rig.drain(); rig.mouse.arm(acknowledged: true)
        XCTAssertFalse(rig.mouse.armed); XCTAssertEqual(rig.registrations, 1)
        rig.mouse.finish({}); XCTAssertEqual(rig.mouse.receipt.result, .notTested)
    }
    func testPendingFinishWaitsOnlyTwoSecondsAndDoesNotClaimSettlement() {
        let rig = MouseRig(); rig.arm(); rig.down(); rig.drain()
        var completions = 0
        XCTAssertTrue(rig.mouse.finish { completions += 1 })
        XCTAssertEqual(completions, 0); XCTAssertFalse(rig.mouse.armed)
        rig.clock.advance(2)
        XCTAssertEqual(completions, 1); XCTAssertEqual(rig.mouse.receipt.result, .incomplete)
        XCTAssertEqual(rig.mouse.receipt.pendingAtFinish, 1); XCTAssertNotNil(rig.mouse.monitor)
        rig.up(); rig.drain() // only test fixture cleanup, never a synthetic native up
    }
    func testReleaseInsideFinishWindowSettlesDebtWithoutInventingAnUpIntent() {
        let rig = MouseRig(); rig.arm(); rig.down(); rig.drain()
        var completed = false
        XCTAssertTrue(rig.mouse.finish { completed = true })
        rig.up(); rig.drain(); rig.clock.advance(2)
        XCTAssertTrue(completed); XCTAssertEqual(rig.mouse.receipt.pendingAtFinish, 0)
        XCTAssertEqual(rig.mouse.receipt.result, .balanced); XCTAssertEqual(rig.mouse.receipt.holds, 0)
        XCTAssertEqual(rig.mouse.receipt.cancels, 1)
    }
    func testOffReceiverBaselineCountsOtherButtonsWithoutClaimingSuppression() {
        let rig = MouseRig()
        rig.mouse.receiver(button: 2, down: true); rig.mouse.receiver(button: 2, down: false)
        XCTAssertEqual(rig.mouse.receiverOtherPresses, 1); XCTAssertEqual(rig.mouse.receiverOtherReleases, 1)
        rig.mouse.finish({}); XCTAssertEqual(rig.mouse.receipt.result, .notTested)
    }
    func testBalancedPairAndReceiverLeakHaveDifferentOutcomes() {
        for leaked in [false, true] {
            let rig = MouseRig(); rig.arm(); rig.down(); rig.drain()
            if leaked { rig.mouse.receiver(button: 2, down: true) }
            rig.up(); rig.drain()
            XCTAssertFalse(rig.mouse.finish({}))
            XCTAssertEqual(rig.mouse.receipt.result, leaked ? .incomplete : .balanced)
            XCTAssertEqual(rig.mouse.receipt.holds, 1); XCTAssertEqual(rig.mouse.receipt.pendingAtFinish, 0)
        }
    }
    func testArmDeadlineAndFiveMinuteCapCannotRearmFromStaleTimer() {
        let rig = MouseRig(); rig.arm(); let stale = rig.clock.all
        rig.clock.advance(30); XCTAssertFalse(rig.mouse.armed)
        rig.mouse.arm(acknowledged: true); stale.last?(); XCTAssertTrue(rig.mouse.armed)
        var finishes = 0; rig.finishOnPhaseExpiry { finishes += 1 }
        rig.clock.advance(270)
        XCTAssertEqual(finishes, 1); XCTAssertEqual(rig.mouse.receipt.result, .incomplete)
    }
    func testFinishedPhaseOwnerIsReleasedBeforeAnotherMonitorStarts() {
        let suspendedBefore = HotkeyMonitor.suspended
        weak var released: MouseRig?
        do {
            let rig = MouseRig(); released = rig
            rig.arm(); rig.finishOnPhaseExpiry({}); rig.clock.advance(300)
            XCTAssertEqual(rig.mouse.receipt.result, .incomplete)
        }
        XCTAssertNil(released)
        XCTAssertEqual(HotkeyMonitor.suspended, suspendedBefore)
        let fresh = MouseRig(); fresh.arm()
        XCTAssertTrue(fresh.down()); fresh.drain()
        XCTAssertEqual(fresh.mouse.receipt.accepted, 1)
        XCTAssertTrue(fresh.up()); fresh.drain()
        fresh.mouse.finish({}); XCTAssertEqual(fresh.mouse.receipt.result, .balanced)
    }
    func testActiveClearRemainsDistinctFromStartFailure() {
        let rig = MicRig(); let suspendedBefore = HotkeyMonitor.suspended
        rig.mic.start(); XCTAssertTrue(rig.mic.capturing)
        rig.mic.clear()
        XCTAssertEqual(rig.mic.receipt.runs[0].ended, .cleared)
        XCTAssertEqual(rig.mic.state, .idle); XCTAssertTrue(rig.admission.isAvailable)
        XCTAssertEqual(HotkeyMonitor.suspended, suspendedBefore)
    }
    func testInterruptedTapCannotOfferSilentRearmUntilItRecovers() {
        for status: InputTapStatus in [.disabled, .invalidPort, .permissionLost] {
            let rig = MouseRig(); rig.arm(); XCTAssertTrue(rig.mouse.armed)
            rig.mouse.monitor?.receiveTapStatus(status); rig.drain()
            XCTAssertFalse(rig.mouse.armed); XCTAssertFalse(rig.mouse.canArm)
            let arms = rig.mouse.receipt.arms
            rig.mouse.arm(acknowledged: true); XCTAssertEqual(rig.mouse.receipt.arms, arms)
            rig.mouse.monitor?.receiveTapStatus(.ready); rig.drain()
            XCTAssertTrue(rig.mouse.canArm); rig.mouse.arm(acknowledged: true)
            XCTAssertTrue(rig.down()); rig.drain(); XCTAssertEqual(rig.mouse.receipt.accepted, 1)
            XCTAssertTrue(rig.up()); rig.drain(); rig.mouse.finish({})
            XCTAssertEqual(rig.mouse.receipt.result, .incomplete)
        }
    }
    func testReceiptHasOnlyClosedStringValuesAndNullUnansweredHeard() throws {
        let rig = MicRig(); rig.capture.samples = [0.1]; rig.mic.start(); rig.mic.stop(); rig.mic.clear()
        let receipt = InputCheckReceipt(arch: .arm64, osMajorMinor: .init(major: 13, minor: 3),
            layout: LayoutReceipt(), microphone: rig.mic.receipt, mouse: MouseReceipt())
        let bytes = try JSONEncoder().encode(receipt)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let allowed: Set<String> = ["parla-input-check", "arm64", "notRead", "granted", "stoppedBeforePCM", "stopped", "notTested", "nativeCapture", "parentVerificationRequired", "notClaimed", "notObserved", "parentMustClassifyForcedExit"]
        func inspect(_ value: Any) {
            if let value = value as? String { XCTAssertTrue(allowed.contains(value), value) }
            else if let value = value as? [String: Any] { value.values.forEach(inspect) }
            else if let value = value as? [Any] { value.forEach(inspect) }
            else { XCTAssertTrue(value is NSNumber || value is NSNull) }
        }
        inspect(json)
        let mic = try XCTUnwrap(json["microphone"] as? [String: Any]); let runs = try XCTUnwrap(mic["runs"] as? [[String: Any]])
        XCTAssertTrue(runs[0]["heardConfirmed"] is NSNull)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE_ROUTE_NOT_FOR_RECEIPT"))
    }
}
