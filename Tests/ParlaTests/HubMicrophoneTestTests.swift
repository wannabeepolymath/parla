import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import ParlaCore
@testable import Parla

private final class MicClock {
    var now: TimeInterval = 100
    var actions: [UUID: (TimeInterval, () -> Void)] = [:]
    var all: [() -> Void] = [] // deliberately retained canceled callbacks
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let id = UUID(); actions[id] = (now + delay, action); all.append(action)
        return { self.actions[id] = nil }
    }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = actions.filter({ $0.value.0 <= end }).min(by: { $0.value.0 < $1.value.0 }) {
            now = next.value.0; actions[next.key] = nil; next.value.1()
        }
        now = end
    }
}
private final class MicEngine: MicrophoneCaptureEngine {
    var isRunning = false
    var route = MicrophoneRoute(name: "PRIVATE_ACTUAL_INPUT", fallback: false)
    var starts = 0, stops = 0
    var fails = false
    var receive: ((AVAudioPCMBuffer) -> Void)?
    var changed: (() -> Void)?
    var requested: String?
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws {
        starts += 1; requested = requestedUID; self.receive = receive; self.changed = changed
        if fails { throw AudioRecorder.RecorderError.noInputFormat }
        isRunning = true
    }
    func stop() { stops += 1; isRunning = false; receive = nil; changed = nil }
    func feed(_ value: Float = 0.25, count: Int = 1600, rate: Double = 16_000) {
        receive?(Self.buffer(value, count: count, rate: rate))
    }
    static func buffer(_ value: Float, count: Int, rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, count)))!
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].initialize(repeating: value, count: count)
        return buffer
    }
}
/// Lets a held conversion exit exactly when the production adapter starts Stop.
private final class MicStopCapture: MicrophoneTestCapturing {
    let base: RecorderMicrophoneCapture
    let beforeStop: () -> Void
    init(recorder: AudioRecorder, beforeStop: @escaping () -> Void) {
        base = RecorderMicrophoneCapture(recorder: recorder); self.beforeStop = beforeStop
    }
    func start(operation: UUID, lease: CaptureAdmission.Lease) throws { try base.start(operation: operation, lease: lease) }
    func snapshot(operation: UUID) -> MicrophoneCaptureSnapshot? { base.snapshot(operation: operation) }
    func stop(operation: UUID) -> [Float] { beforeStop(); return base.stop(operation: operation) }
    func clear(operation: UUID) { base.clear(operation: operation) }
}

private final class MicPlayer: MicrophoneTestPlaying {
    var samples: [Float] = []
    var rate: Double?
    var done: ((Bool) -> Void)?
    var stops = 0
    var fails = false
    func play(samples: [Float], sampleRate: Double, finished: @escaping (Bool) -> Void) throws {
        self.samples = samples; rate = sampleRate; done = finished
        if fails { throw AudioRecorder.RecorderError.noInputFormat }
    }
    func stop() { samples = []; done = nil; stops += 1 }
}

@MainActor final class HubMicrophoneTestTests: XCTestCase {
    private var root: URL!
    private var clock: MicClock!
    private var engine: MicEngine!
    private var admission: CaptureAdmission!
    private var recorder: AudioRecorder!
    private var controller: MicrophoneTestController!
    private var hub: HubModel!
    private var backend: FakeCredentialBackend!
    private var permission = true
    private var allowed = true
    private var playbackAllowed = true
    private var player: MicPlayer!
    private var playerCreations = 0
    private var forbidden = 0
    private var permissionChecks = 0
    private var historyReads = 0
    private var baselineHistoryReads = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-microphone-3e-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = MicClock(); engine = MicEngine(); admission = CaptureAdmission(); backend = FakeCredentialBackend()
        recorder = AudioRecorder(engine: engine, admission: admission, scheduleRoute: clock.schedule)
        recorder.inputDeviceUID = "PRIVATE_REQUESTED_UID"
        installController()
    }
    private func installController(capture: MicrophoneTestCapturing? = nil) {
        controller = MicrophoneTestController(capture: capture ?? RecorderMicrophoneCapture(recorder: recorder), admission: admission,
            allowed: { [unowned self] in self.allowed }, permission: { [unowned self] in self.permissionChecks += 1; return self.permission },
            playbackAllowed: { [unowned self] in self.playbackAllowed }, now: { [unowned self] in self.clock.now }, schedule: clock.schedule)
        player = MicPlayer()
        controller.playerFactory = { [unowned self] in self.playerCreations += 1; return self.player }
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        let history = HistoryStore(url: root.appendingPathComponent("history.json"), persistence: .init(read: { [unowned self] _ in
            self.historyReads += 1; throw CocoaError(.fileReadNoSuchFile)
        }, writeAtomically: { [unowned self] _, _ in self.forbidden += 1 }))
        let recordings = RecordingStore(directory: root.appendingPathComponent("audio"), keepAll: false, requireValidatedPolicy: true,
            writer: { [unowned self] _, _ in self.forbidden += 1 }, remover: { [unowned self] _ in self.forbidden += 1 })
        hub = HubModel(store: store, history: history, clipboard: { [unowned self] _ in self.forbidden += 1 },
                       recordings: recordings,
                       shortcutLabels: ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } }),
                       diagnostics: DiagnosticStore(), microphoneTest: controller)
        hub.retryFactory = { [unowned self] _, _, _, _ in self.forbidden += 1; throw CancellationError() }
        hub.onDownloadModel = { [unowned self] _ in self.forbidden += 1 }
        hub.onTryoutStart = { [unowned self] in self.forbidden += 1; return nil }
        hub.onTryoutStop = { [unowned self] _ in self.forbidden += 1 }
        hub.onRecoveryTranscribe = { [unowned self] _, _, _ in self.forbidden += 1 }
        hub.onSaved = { [unowned self] in self.forbidden += 1 }
        hub.historyExportWriter = { [unowned self] _, _ in self.forbidden += 1 }
        recorder.onLevel = { [unowned self] _ in self.forbidden += 1 }
        recorder.onEnd = { [unowned self] _ in self.forbidden += 1 }
        baselineHistoryReads = historyReads
    }
    override func tearDownWithError() throws {
        hub.clearMicrophoneTest()
        assertDisposed()
        XCTAssertTrue(admission.isAvailable)
        XCTAssertEqual(clock.actions.count, 0)
        XCTAssertEqual(forbidden, 0)
        XCTAssertEqual(historyReads, baselineHistoryReads)
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        hub = nil; controller = nil; recorder = nil
        try FileManager.default.removeItem(at: root)
    }
    private func assertDisposed(file: StaticString = #filePath, line: UInt = #line) {
        let retained = recorder.retainedAudioCounts
        XCTAssertEqual(retained.samples, 0, file: file, line: line)
        XCTAssertEqual(retained.preRoll, 0, file: file, line: line)
        XCTAssertFalse(retained.converter, file: file, line: line)
        XCTAssertTrue(recorder.snapshot().isEmpty, file: file, line: line)
        XCTAssertFalse(engine.isRunning, file: file, line: line)
    }
    private func recordAndStop() {
        hub.startMicrophoneTest(); engine.feed(); clock.advance(0.2); hub.stopMicrophoneTest()
    }
    func testHubIsInertUntilExplicitStartAndNeedsNoModelProviderOrHistory() throws {
        XCTAssertFalse(hub.modelLoaded)
        XCTAssertEqual(engine.starts, 0); XCTAssertEqual(permissionChecks, 0)
        _ = HubMicrophoneTestView(model: hub, test: controller).body
        XCTAssertEqual(engine.starts, 0); XCTAssertEqual(permissionChecks, 0)
        recordAndStop()
        XCTAssertEqual(controller.captureStatus, .signal)
        XCTAssertEqual(controller.review.count, 1600); XCTAssertEqual(playerCreations, 0)
        XCTAssertTrue(hub.history.entries.isEmpty); XCTAssertTrue(hub.diagnostics.snapshot().records.isEmpty)
        XCTAssertFalse(String(decoding: try hub.diagnostics.snapshot().encoded(), as: UTF8.self).contains("PRIVATE_"))
        assertDisposed()
        XCTAssertFalse(admission.isAvailable, "review holds admission until Clear")
    }
    func testPermissionRefusalAndStartFailureAreDistinctFromSilentPCM() {
        permission = false; hub.startMicrophoneTest()
        guard case .refused = controller.state else { return XCTFail("explicit permission guidance") }
        XCTAssertEqual(engine.starts, 0); XCTAssertTrue(admission.isAvailable)
        permission = true; engine.fails = true; hub.startMicrophoneTest()
        guard case .failed = controller.state else { return XCTFail("start failure") }
        assertDisposed(); XCTAssertTrue(admission.isAvailable)
        engine.fails = false; hub.startMicrophoneTest(); engine.feed(0); clock.advance(0.2)
        XCTAssertEqual(controller.state, .silentPCM)
        hub.stopMicrophoneTest(); XCTAssertEqual(controller.captureStatus, .silentPCM)
    }
    func testNoPCMDeadlineAndMaximumRunCloseEvenWithoutCallbacks() {
        hub.startMicrophoneTest(); clock.advance(1.9)
        XCTAssertEqual(controller.state, .starting)
        clock.advance(0.2); XCTAssertEqual(controller.state, .noPCM)
        clock.advance(8); XCTAssertFalse(controller.capturing)
        XCTAssertEqual(controller.state, .stopped); XCTAssertEqual(controller.captureStatus, .noPCM)
        XCTAssertEqual(clock.actions.count, 0); assertDisposed()
    }
    func testStopClassifiesFinalFactsAfterHeldConversionDrains() async throws {
        for conversionFails in [false, true] {
            let entered = expectation(description: "conversion entered"), exited = expectation(description: "callback exited")
            let release = DispatchSemaphore(value: 0)
            recorder = AudioRecorder(engine: engine, admission: admission, conversion: { _ in
                entered.fulfill(); release.wait()
                return conversionFails ? nil : [Float](repeating: 0.25, count: 1600)
            }, scheduleRoute: clock.schedule)
            installController(capture: MicStopCapture(recorder: recorder, beforeStop: { release.signal() }))
            hub.startMicrophoneTest()
            let receive = try XCTUnwrap(engine.receive)
            DispatchQueue.global().async {
                receive(MicEngine.buffer(0.25, count: 1600, rate: 16_000)); exited.fulfill()
            }
            await fulfillment(of: [entered], timeout: 2)
            hub.stopMicrophoneTest()
            await fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(controller.captureStatus, conversionFails ? .conversionFailure : .signal)
            XCTAssertEqual(controller.review.count, conversionFails ? 0 : 1600)
            XCTAssertEqual(controller.sampleCount, controller.review.count)
            XCTAssertEqual(controller.state, .stopped)
            assertDisposed()
            hub.clearMicrophoneTest()
            XCTAssertTrue(admission.isAvailable)
        }
    }

    func testConversionFailureIsNotSilentPCMAndDisposesAdapter() {
        recorder = AudioRecorder(engine: engine, admission: admission, conversion: { _ in nil }, scheduleRoute: clock.schedule)
        installController()
        hub.startMicrophoneTest(); engine.feed(0); clock.advance(0.2)
        XCTAssertEqual(controller.state, .conversionFailure)
        hub.stopMicrophoneTest(); XCTAssertEqual(controller.captureStatus, .conversionFailure)
        XCTAssertTrue(controller.review.isEmpty); assertDisposed()
    }
    func testOversizedChunkSampleLimitAndLateBuffersCannotGrowStorage() {
        hub.startMicrophoneTest()
        let late = engine.receive!
        engine.feed(0.25, count: 170_003)
        late(MicEngine.buffer(0.9, count: 80_000, rate: 16_000))
        XCTAssertEqual(recorder.snapshot().count, 160_000)
        clock.advance(0.2)
        XCTAssertFalse(controller.capturing); XCTAssertEqual(controller.review.count, 160_000)
        XCTAssertTrue(controller.review.allSatisfy { $0 == 0.25 })
        hub.stopMicrophoneTest(); XCTAssertEqual(controller.review.count, 160_000)
        late(MicEngine.buffer(0.9, count: 100, rate: 16_000)); assertDisposed()
    }
    func testReal44100And48000StreamingConversionIncludesBoundedTailAndCorrectReplayRate() {
        for rate in [44_100.0, 48_000.0] {
            hub.startMicrophoneTest()
            for _ in 0..<10 { engine.feed(0.2, count: Int(rate / 10), rate: rate) }
            hub.stopMicrophoneTest()
            XCTAssertEqual(controller.review.count, 16_000, accuracy: 32)
            XCTAssertEqual(AudioRecorder.rms(controller.review), 0.2, accuracy: 0.01)
            assertDisposed(); hub.listenMicrophoneTest()
            XCTAssertEqual(player.rate, 16_000); XCTAssertEqual(player.samples, controller.review)
            hub.stopListeningMicrophoneTest(); XCTAssertTrue(player.samples.isEmpty)
            hub.clearMicrophoneTest()
        }
        XCTAssertEqual(playerCreations, 2)
    }
    func testConvertedOversizedTailCannotExceedCeiling() {
        hub.startMicrophoneTest()
        for _ in 0..<9 { engine.feed(count: 48_000, rate: 48_000) }
        engine.feed(count: 96_000, rate: 48_000)
        hub.stopMicrophoneTest()
        XCTAssertEqual(controller.review.count, 160_000); assertDisposed()
    }
    func testActualFallbackChangedUnknownAndLostRouteEvidence() {
        hub.startMicrophoneTest()
        XCTAssertEqual(controller.route.name, "PRIVATE_ACTUAL_INPUT")
        XCTAssertEqual(engine.requested, "PRIVATE_REQUESTED_UID")
        engine.route = MicrophoneRoute(name: "PRIVATE_FALLBACK", fallback: true)
        engine.changed?(); clock.advance(0.6)
        XCTAssertEqual(controller.route.name, "PRIVATE_FALLBACK"); XCTAssertEqual(controller.route.fallback, true)
        XCTAssertTrue(controller.routeChanged)
        engine.route = MicrophoneRoute(); clock.advance(0.2)
        XCTAssertNil(controller.route.name); XCTAssertNil(controller.route.fallback)
        engine.isRunning = false; engine.changed?(); clock.advance(0.6)
        XCTAssertEqual(controller.state, .routeLost); assertDisposed()
    }
    func testListenIsExplicitAndLazyAndStopListeningReleasesPlayerCopy() {
        hub.startMicrophoneTest(); engine.feed(); hub.listenMicrophoneTest()
        XCTAssertEqual(playerCreations, 0)
        hub.stopMicrophoneTest(); XCTAssertEqual(playerCreations, 0)
        hub.listenMicrophoneTest(); XCTAssertEqual(playerCreations, 1)
        XCTAssertEqual(controller.state, .listening); XCTAssertEqual(player.samples.count, 1600)
        let oldEnd = player.done!
        hub.stopListeningMicrophoneTest(); XCTAssertTrue(player.samples.isEmpty)
        XCTAssertEqual(controller.review.count, 1600)
        hub.listenMicrophoneTest(); oldEnd(false)
        XCTAssertEqual(controller.state, .listening)
        player.done?(true); XCTAssertFalse(controller.playerActive)
        XCTAssertTrue(player.samples.isEmpty); XCTAssertEqual(controller.review.count, 1600)
        hub.clearMicrophoneTest(); XCTAssertFalse(controller.hasReview)
    }
    func testRecoveryPlaybackConflictRefusesWithoutCancelingEitherOwner() {
        playbackAllowed = false; hub.startMicrophoneTest()
        XCTAssertEqual(engine.starts, 0)
        playbackAllowed = true; recordAndStop(); playbackAllowed = false; hub.listenMicrophoneTest()
        XCTAssertEqual(playerCreations, 0); XCTAssertTrue(controller.hasReview)
        hub.playRecovery(root.appendingPathComponent("unrelated.wav"))
        XCTAssertEqual(hub.recoveryMessage, "Clear the microphone test before recovery playback.")
        XCTAssertTrue(controller.hasReview)
    }
    func testClearPageLeaveWindowCloseResignAndQuitDisposeRealHubController() {
        for event in [MicrophoneTestLifecycle.pageLeave, .windowClose, .resign, .quit] {
            for stopped in [false, true] {
                hub.startMicrophoneTest(); engine.feed(count: 4410, rate: 44_100)
                if stopped { hub.stopMicrophoneTest(); hub.listenMicrophoneTest() }
                let pending = clock.all
                let native = engine.receive
                let end = player.done
                hub.microphoneTestLifecycle(event)
                pending.forEach { $0() }; native?(MicEngine.buffer(0.9, count: 100, rate: 16_000)); end?(false)
                XCTAssertEqual(controller.state, .idle); XCTAssertFalse(controller.hasReview)
                XCTAssertFalse(controller.playerActive); XCTAssertTrue(player.samples.isEmpty)
                XCTAssertTrue(admission.isAvailable); XCTAssertEqual(clock.actions.count, 0); assertDisposed()
            }
        }
    }
    func testRetainedHubWindowDelegateConsumesCloseAndResignWithoutOnDisappear() {
        let window = HubWindowController(model: hub) // no NSWindow construction or show/refresh
        recordAndStop(); hub.listenMicrophoneTest()
        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.ownsSession); assertDisposed()
        hub.startMicrophoneTest(); engine.feed()
        window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(controller.ownsSession); assertDisposed()
    }
    func testRestartRejectsOldPCMRouteTimersAndPlayerEndWithoutReleasingNewLease() {
        hub.startMicrophoneTest(); engine.feed()
        let native = engine.receive!, route = engine.changed!, timers = clock.all
        hub.stopMicrophoneTest(); hub.listenMicrophoneTest(); let end = player.done!
        hub.startMicrophoneTest()
        let starts = engine.starts
        native(MicEngine.buffer(0.9, count: 1600, rate: 16_000)); route(); timers.forEach { $0() }; end(false)
        XCTAssertEqual(controller.state, .starting); XCTAssertTrue(recorder.snapshot().isEmpty)
        XCTAssertEqual(engine.starts, starts); XCTAssertFalse(admission.isAvailable)
        engine.feed(0.1); hub.stopMicrophoneTest()
        XCTAssertEqual(controller.review, [Float](repeating: 0.1, count: 1600))
    }
    func testColdTestDropsWarmPrerollAndNeverRewarmsOnStopClearOrSettingsSave() {
        recorder.setWarm(true)
        XCTAssertTrue(engine.isRunning)
        engine.feed(0.9)
        XCTAssertGreaterThan(recorder.retainedAudioCounts.preRoll, 0)
        let oldWarmCallback = engine.receive!
        hub.startMicrophoneTest()
        XCTAssertEqual(recorder.retainedAudioCounts.preRoll, 0)
        oldWarmCallback(MicEngine.buffer(0.9, count: 1600, rate: 16_000))
        engine.feed(0.1); hub.stopMicrophoneTest()
        XCTAssertEqual(controller.review, [Float](repeating: 0.1, count: 1600))
        let starts = engine.starts
        recorder.setWarm(true); hub.clearMicrophoneTest(); recorder.setWarm(true)
        XCTAssertEqual(engine.starts, starts); assertDisposed()
        recorder.resumeWarmthOnExplicitEntry()
        XCTAssertEqual(engine.starts, starts + 1)
        recorder.setWarm(false)
    }
    func testStaleLeaseAndSuspensionReleaseCannotReleaseNewOwner() {
        let prior = admission.acquire(.shortcut)!
        hub.startMicrophoneTest(); XCTAssertEqual(engine.starts, 0)
        admission.release(prior); recordAndStop()
        admission.release(prior); XCTAssertFalse(admission.isAvailable)
        let other = HotkeyMonitor.acquireSuspension()
        hub.clearMicrophoneTest(); XCTAssertTrue(HotkeyMonitor.suspended)
        HotkeyMonitor.releaseSuspension(other)
        XCTAssertFalse(HotkeyMonitor.suspended)
    }
}

@MainActor private final class MicAutomationClock: AutomationClock {
    let clock: MicClock
    init(_ clock: MicClock) { self.clock = clock }
    var now: TimeInterval { clock.now }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        clock.schedule(seconds) { MainActor.assumeIsolated { action() } }
    }
}

/// Actual invocation host -> reducer -> recorder; hardware/model/delivery effects are inert.
@MainActor private final class MicInvocationRig {
    let machine = DictationSession()
    let recorder: AudioRecorder
    let clock = MicClock()
    lazy var runtime = AutomationRuntime(clock: MicAutomationClock(clock), enabled: { true })
    var starts = 0, history = 0, insertions = 0, asr = 0, entries = 0
    var settings: ParlaCore.Settings = { var s = ParlaCore.Settings(); s.automationEnabled = true; s.cleanupEnabled = false; s.outputMode = .raw; return s }()
    lazy var host = DictationInvocationHost(machine: machine, captureAdmission: recorder.admission,
        broker: runtime.broker, results: runtime.results,
        settings: { [unowned self] in self.settings }, configured: { _ in false }, capabilities: { _ in nil }, secure: { false },
        keyboardAllowed: { true }, automationAllowed: { true }, explicitEntry: { [unowned self] in self.entries += 1 },
        send: { [unowned self] in self.send($0) })
    init(_ recorder: AudioRecorder) { self.recorder = recorder; runtime.broker.register(host) }
    func send(_ event: DictationSession.Event) {
        machine.send(event) { effect in
            switch effect {
            case .captureAccepted(let session): host.accepted(session)
            case .captureAcknowledged(let session): host.acknowledged(session)
            case .applyPreferencesAndStartCapture:
                starts += 1
                do { try recorder.start(); send(.recorderStarted(gen: machine.gen)) }
                catch { send(.recorderFailed(gen: machine.gen, message: "inert failure")) }
            case .sampleFocus(let gen): send(.focusSampled(gen: gen, focus: .editable))
            case .stopCapture, .stopOwnedCapture: _ = recorder.stop()
            case .appendHistory: history += 1
            case .insertText: insertions += 1
            case .transcribeFinal: asr += 1
            case .abortOperation(let operation): operation.requestAbort()
            default: break
            }
        }
    }
    @discardableResult func keyboardStart() -> Bool {
        host.keyboard(.startDictation(settings: settings, cleanupConfigured: false, live: false,
                                      recognitionDestination: ProfileDestination(bundleID: "inert.app")))
    }
    func cancel() { _ = host.keyboard(.cancelRequested(silent: true)) }
}

extension HubMicrophoneTestTests {
    func testRealInvocationHostRefusesKeyboardAutomationTryoutAndShortcutDuringCaptureReviewAndListen() async {
        let rig = MicInvocationRig(recorder)
        for phase in 0..<3 {
            hub.startMicrophoneTest(); engine.feed()
            if phase > 0 { hub.stopMicrophoneTest() }
            if phase == 2 { hub.listenMicrophoneTest() }
            XCTAssertTrue(HotkeyMonitor.suspended)
            XCTAssertFalse(rig.keyboardStart())
            let result = await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID())
            XCTAssertEqual(result, .failure(.busy))
            XCTAssertFalse(rig.host.beginTryout()); XCTAssertNil(rig.host.beginShortcutRecording())
            XCTAssertEqual(rig.starts + rig.asr + rig.history + rig.insertions + rig.entries, 0)
            XCTAssertEqual(engine.starts, phase + 1)
            hub.clearMicrophoneTest()
            XCTAssertFalse(HotkeyMonitor.suspended)
        }
        rig.runtime.broker.quit()
        XCTAssertEqual(rig.clock.actions.count, 0)
    }
    func testNativeMouseReceiveAndProductionRouterAreExcludedAcrossActualHubCaptureReviewListen() throws {
        let rig = MicInvocationRig(recorder)
        let store = SettingsStore(url: root.appendingPathComponent("mouse-settings.json"), credentials: CredentialStore(backend: backend))
        var settings = rig.settings; settings.mouseBinding = MouseButtonBinding(buttonNumber: 2)
        try store.save(settings)
        defer { try! FileManager.default.removeItem(at: store.url) }
        let monitor = HotkeyMonitor(store: store, inputAuthority: rig.host.inputAuthority,
                                    captureAdmission: admission, buttonState: { _ in .down })
        var queue: [() -> Void] = []
        monitor.deliversOnMain = true; monitor.enqueueOnMain = { queue.append($0) }
        let router = DictationInputRouter(host: rig.host, prepare: {
            .startDictation(settings: settings, cleanupConfigured: false, live: false)
        }, secureRefused: { XCTFail("No secure input is injected") })
        monitor.onMouseEdge = { router.mouse($0) }
        monitor.receiveTapStatus(.ready)
        func drain() { while !queue.isEmpty { queue.removeFirst()() } }
        drain()
        for phase in 0..<3 {
            // This native down predates the exclusion; main must still refuse
            // after the real controller acquires admission/suspension.
            XCTAssertTrue(monitor.receiveMouseEvent(button: 2, isDown: true, at: 100))
            hub.startMicrophoneTest(); engine.feed()
            if phase > 0 { hub.stopMicrophoneTest() }
            if phase == 2 { hub.listenMicrophoneTest() }
            drain(); XCTAssertEqual(rig.starts, 0)
            XCTAssertTrue(monitor.receiveMouseEvent(button: 2, isDown: false, at: 101)); drain()
            XCTAssertFalse(monitor.receiveMouseEvent(button: 2, isDown: true, at: 102))
            XCTAssertFalse(monitor.receiveMouseEvent(button: 2, isDown: false, at: 103))
            XCTAssertEqual(rig.asr + rig.history + rig.insertions + rig.entries, 0)
            XCTAssertTrue(controller.ownsSession)
            hub.clearMicrophoneTest(); drain()
        }
        XCTAssertEqual(engine.starts, 3); rig.runtime.broker.quit()
    }
    func testSelfTestNeverPreemptsExistingKeyboardAutomationTryoutOrShortcut() async throws {
        let rig = MicInvocationRig(recorder)
        allowed = false // production predicate includes reducer/tryout ownership, beyond physical lease
        XCTAssertTrue(rig.keyboardStart())
        let oldGen = rig.machine.gen, oldStarts = engine.starts
        hub.startMicrophoneTest()
        XCTAssertEqual(rig.machine.gen, oldGen); XCTAssertEqual(engine.starts, oldStarts)
        XCTAssertTrue(rig.machine.isCapturing); rig.cancel()
        allowed = true
        let automation = try await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID()).get()
        let automationStarts = engine.starts
        hub.startMicrophoneTest()
        XCTAssertEqual(engine.starts, automationStarts); XCTAssertTrue(rig.machine.isCapturing)
        _ = rig.runtime.broker.cancel(sessionID: automation.sessionID)
        XCTAssertTrue(rig.host.beginTryout()); XCTAssertTrue(HotkeyMonitor.suspended)
        allowed = !rig.host.tryoutActive
        hub.startMicrophoneTest(); XCTAssertFalse(controller.ownsSession)
        XCTAssertTrue(rig.host.tryoutActive); rig.host.endTryout(); allowed = true
        hub.onShortcutBegin = { rig.host.beginShortcutRecording() }
        hub.onShortcutEnd = { rig.host.endShortcutRecording($0) }
        let shortcut = try XCTUnwrap(hub.onShortcutBegin())
        XCTAssertTrue(HotkeyMonitor.suspended)
        hub.startMicrophoneTest(); XCTAssertFalse(controller.ownsSession)
        XCTAssertFalse(rig.keyboardStart()); XCTAssertEqual(rig.host.startAutomation(), .busy)
        hub.onShortcutEnd(shortcut); recordAndStop()
        hub.onShortcutEnd(shortcut) // old row cannot unsuspend or release a test
        XCTAssertTrue(HotkeyMonitor.suspended); XCTAssertFalse(admission.isAvailable)
        XCTAssertEqual(rig.asr + rig.history + rig.insertions, 0)
        hub.clearMicrophoneTest(); rig.runtime.broker.quit()
    }
    func testLateAdapterClearStopAndTimersCannotStopSubsequentDictationOwner() {
        hub.startMicrophoneTest(); engine.feed()
        let id = controller.operation!
        let pcm = engine.receive!, route = engine.changed!, timers = clock.all
        hub.clearMicrophoneTest()
        let rig = MicInvocationRig(recorder)
        XCTAssertTrue(rig.keyboardStart())
        let starts = engine.starts
        recorder.clearMicrophoneTest(operation: id)
        XCTAssertTrue(recorder.stopMicrophoneTest(operation: id).isEmpty)
        pcm(MicEngine.buffer(0.9, count: 170_000, rate: 16_000)); route(); timers.forEach { $0() }
        XCTAssertTrue(rig.machine.isCapturing); XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.starts, starts); XCTAssertTrue(recorder.snapshot().isEmpty)
        XCTAssertFalse(admission.isAvailable); XCTAssertEqual(controller.state, .idle)
        rig.cancel(); rig.runtime.broker.quit()
    }
}


extension HubMicrophoneTestTests {
    func testOrdinaryReplacementAndAutomationPreemptionStillUseOnePhysicalRecorder() async throws {
        var normalLevels = 0
        recorder.onLevel = { _ in normalLevels += 1 }
        let rig = MicInvocationRig(recorder)
        XCTAssertTrue(rig.keyboardStart()); engine.feed(0.1)
        XCTAssertTrue(rig.keyboardStart()); XCTAssertEqual(engine.starts, 1)
        XCTAssertTrue(recorder.snapshot().isEmpty); engine.feed(0.2)
        rig.cancel(); XCTAssertTrue(admission.isAvailable)
        XCTAssertEqual(normalLevels, 2)
        _ = try await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID()).get()
        XCTAssertTrue(rig.keyboardStart())
        XCTAssertTrue(rig.machine.isCapturing); XCTAssertFalse(admission.isAvailable)
        rig.cancel()
        _ = try await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID()).get()
        XCTAssertTrue(rig.host.beginTryout())
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertTrue(admission.isAvailable)
        rig.host.endTryout(); rig.runtime.broker.quit()
        XCTAssertEqual(rig.asr + rig.history + rig.insertions, 0)
    }
    func testEarlyStopUnknownAndNonfiniteLevelAreTruthfulAndBounded() {
        hub.startMicrophoneTest(); hub.stopMicrophoneTest()
        XCTAssertEqual(controller.captureStatus, .stoppedBeforePCM)
        hub.startMicrophoneTest(); engine.feed(.infinity); clock.advance(0.2)
        XCTAssertEqual(controller.level, 0); XCTAssertEqual(controller.state, .conversionFailure)
        hub.startMicrophoneTest(); engine.feed(2); clock.advance(0.2)
        XCTAssertEqual(controller.level, 1)
    }
    func testPlayerFailureDisposesPlaybackButRetainsOnlyControllerReview() {
        recordAndStop(); player.fails = true; hub.listenMicrophoneTest()
        guard case .failed = controller.state else { return XCTFail("playback failure") }
        XCTAssertFalse(controller.playerActive); XCTAssertTrue(player.samples.isEmpty)
        XCTAssertEqual(controller.review.count, 1600); assertDisposed()
    }
}
