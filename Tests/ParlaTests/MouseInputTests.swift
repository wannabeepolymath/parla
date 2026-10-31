import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

@MainActor private final class MouseClock: AutomationClock {
    var now: TimeInterval = 100
    var timers: [UUID: @MainActor () -> Void] = [:]
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID(); timers[id] = action
        return { self.timers[id] = nil }
    }
}
private final class MouseRecognition: RecognitionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        lock.withLock { count += 1 }; return "inert dictation"
    }
}
private final class MouseProvider: CleanupProviding, @unchecked Sendable {
    var calls = 0
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        calls += 1; return "Inert final text."
    }
}

/// Native receive → exact injected production main hop → production router →
/// invocation host → real reducer/processing queue. Only world/recorder/sinks
/// are inert, and no live settings, HID, credential or input API is consulted.
@MainActor private final class MouseRig {
    let root: URL
    let store: SettingsStore
    let backend = FakeCredentialBackend()
    let clock = MouseClock()
    let admission = CaptureAdmission()
    let authority = PhysicalInputAuthority()
    let machine = DictationSession(diagnostics: DiagnosticStore())
    lazy var runtime = AutomationRuntime(clock: clock, enabled: { true })
    lazy var host = DictationInvocationHost(machine: machine, inputAuthority: authority, captureAdmission: admission,
        broker: runtime.broker, results: runtime.results, settings: { [weak self] in self?.store.load() },
        configured: { _ in true }, capabilities: { _ in nil }, secure: { [weak self] in self?.secure == true },
        keyboardAllowed: { [weak self] in self?.allowed == true }, automationAllowed: { true },
        explicitEntry: { [weak self] in self?.entries += 1 }, send: { [weak self] in self?.send($0) })
    lazy var router = DictationInputRouter(host: host, prepare: { [weak self] in self?.startEvent },
        secureRefused: { [weak self] in self?.secureRefusals += 1 })
    lazy var monitor: HotkeyMonitor = {
        let value = HotkeyMonitor(store: store, inputAuthority: authority, captureAdmission: admission,
                                  buttonState: { [weak self] number in
                                      guard let self else { return .unknown }
                                      let action = beforeButtonRead; beforeButtonRead = nil; action?()
                                      return buttons[number] ?? .unknown
                                  })
        value.keyIsPhysicallyDown = { _ in false }
        value.deliversOnMain = true
        value.enqueueOnMain = { [weak self] in self?.mainQueue.append($0) }
        value.onMouseEdge = { [weak self] edge in
            if case .down(let press) = edge { self?.presses.append(press) }
            self?.router.mouse(edge)
        }
        value.onEdge = { [weak self] edge in
            guard let self else { return }
            switch edge {
            case .down(let command):
                if command {
                    _ = host.keyboard(.startCommand(settings: store.load(), cleanupConfigured: true, focus: .editable, selection: "inert selection"))
                } else { _ = host.keyboard(startEvent) }
            case .up(let short): _ = host.keyboard(short ? .cancelRequested(silent: true) : .stopRequested)
            case .cancel: _ = host.keyboard(.cancelRequested(silent: false))
            case .handsFree: _ = host.keyboard(.handsFreeLatched)
            default: break
            }
        }
        value.onTapStatus = { [weak self] in self?.statuses.append($0) }
        value.receiveTapStatus(.ready)
        return value
    }()
    var buttons: [Int: MouseButtonState] = [2: .down, 3: .down, 4: .down, 15: .down]
    var beforeButtonRead: (() -> Void)?
    var mainQueue: [() -> Void] = []
    var statuses: [InputTapStatus] = []
    var presses: [MousePress] = []
    var secure = false, focusSecure = false, allowed = true, recorderFails = false, acknowledge = true
    var entries = 0, captures = 0, stops = 0, secureRefusals = 0, finalizations = 0
    var lease: CaptureAdmission.Lease?
    var recordingGeneration = 0
    var accepted: [DictationSession.Session] = []
    var finals: [DictationSession.Session] = []
    var discarded: [UUID] = []
    var insertions: [String] = [], history: [String] = []
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var processTask: Task<Void, Never>?
    let recognition = MouseRecognition(), provider = MouseProvider()
    var foundationFactory: RecognitionFactory?
    var startEvent: DictationSession.Event {
        .startDictation(settings: store.load(), cleanupConfigured: true, live: false)
    }
    init(binding: Int? = 2) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-mouse-3f-\(UUID())")
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = Settings(); settings.automationEnabled = true; settings.outputMode = .cleanup
        settings.whisperModelPath = "/inert/no-model"; settings.mouseBinding = binding.flatMap { MouseButtonBinding(buttonNumber: $0) }
        try store.save(settings)
        runtime.broker.register(host)
        _ = monitor; drain()
    }
    func close() throws {
        monitor.receiveTapStatus(.unavailable); drain()
        if machine.isCapturing { send(.cancelRequested(silent: true)) }
        host.endTryout(); mainQueue.removeAll(); clock.timers.removeAll()
        if let lease { admission.release(lease); self.lease = nil }
        try FileManager.default.removeItem(at: root)
    }
    func bind(_ number: Int?) throws {
        var settings = store.load(); settings.mouseBinding = number.flatMap { MouseButtonBinding(buttonNumber: $0) }
        try store.save(settings); monitor.reloadMouseConfiguration()
    }
    @discardableResult func down(_ number: Int = 2) -> Bool { monitor.receiveMouseEvent(button: number, isDown: true, at: clock.now) }
    @discardableResult func up(_ number: Int = 2, after seconds: TimeInterval = 1) -> Bool {
        clock.now += seconds; return monitor.receiveMouseEvent(button: number, isDown: false, at: clock.now)
    }
    func drainOne() { if !mainQueue.isEmpty { mainQueue.removeFirst()() } }
    func drain() { while !mainQueue.isEmpty { drainOne() } }
    func keyboard() { _ = host.keyboard(startEvent) }
    func send(_ event: DictationSession.Event) {
        machine.send(event) { effect in
            switch effect {
            case .captureAccepted(let session): accepted.append(session); host.accepted(session)
            case .captureAcknowledged(let session): host.acknowledged(session)
            case .captureFinalizing(let session): host.finalizing(session)
            case .finalResult(let session, let result): host.completed(session, result: result)
            case .applyPreferencesAndStartCapture:
                captures += 1; recordingGeneration = machine.gen
                lease = admission.acquire(.dictation)
                XCTAssertNotNil(lease)
                if recorderFails {
                    if let lease { admission.release(lease); self.lease = nil }
                    send(.recorderFailed(gen: machine.gen, message: "inert"))
                } else if acknowledge { send(.recorderStarted(gen: machine.gen)) }
            case .sampleFocus(let gen): send(.focusSampled(gen: gen, focus: focusSecure ? .secure : .editable))
            case .stopCapture:
                stops += 1; recordingGeneration = 0
                if let lease { admission.release(lease); self.lease = nil }
            case .stopOwnedCapture(let gen, _):
                if recordingGeneration == gen {
                    stops += 1; recordingGeneration = 0
                    if let lease { admission.release(lease); self.lease = nil }
                }
            case .abortOperation(let operation):
                XCTAssertTrue(operation.shouldAbort); discarded.append(operation.id); operation.requestAbort()
            case .transcribeFinal(let session, _), .transcribeCommand(let session): finalizations += 1; finals.append(session)
            case .polish(let session, let landed): pending = (session, landed)
            case .insertText(let text, _, _): insertions.append(text)
            case .appendHistory(let raw, let cleaned, _): history.append(cleaned ?? raw)
            case .secureRefusal: secureRefusals += 1
            default: break
            }
        }
        host.synchronizeInput()
    }
    /// Same serialized pending-operation queue and final recognition/provider
    /// adapter as AppDelegate. All sinks are captured here, never native I/O.
    func process(_ session: DictationSession.Session) -> Task<Void, Never> {
        let previous = processTask
        let task = PendingOperationQueue.enqueue(previous: previous, operation: session.operation, completes: true, work: {
            await DictationProcessing.final(operation: session.operation, samples: [Float](repeating: 0.2, count: 8000), window: nil,
                prepare: {
                    if let factory = await MainActor.run(body: { self.foundationFactory }) {
                        return try! await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: factory,
                            operation: session.operation, capture: session.operation.id)
                    }
                    return try! RecognitionHandle(request: session.recognition) { _ in self.recognition }
                },
                recognized: { _, raw in
                    await MainActor.run {
                        self.send(.transcribed(session, raw: raw, probe: .init(focus: .editable, deferInsertionUntilClean: true)))
                        defer { self.pending = nil }; return self.pending
                    }
                }, clean: { context in
                    await Pipeline(outputSettings: context.0.effectiveSettings, bundleID: nil) { _ in self.provider }
                        .clean(transcript: context.1.raw)
                }, completed: { context, text, failure in
                    await MainActor.run { self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: .editable)) }
                })
        }, finished: { await MainActor.run { self.send(.operationFinished(session.operation)) } })
        processTask = task; return task
    }
}

@MainActor final class MouseInputTests: XCTestCase {
    func testMouseKeyboardAndHandsFreeActualFinalizationUseRealWhisperFactory() async throws {
        for source in 0..<3 {
            let rig = try MouseRig(); try recordWave4BFixture(rig.root, "created")
            defer { try! rig.close(); try! recordWave4BFixture(rig.root, "removed") }
            let native = FoundationNativeProbe(); rig.foundationFactory = native.factory()
            if source == 0 {
                XCTAssertTrue(rig.down()); rig.drain(); XCTAssertTrue(rig.up()); rig.drain()
            } else {
                rig.keyboard()
                if source == 2 { XCTAssertTrue(rig.host.keyboard(.handsFreeLatched)) }
                rig.send(.stopRequested)
            }
            let session = try XCTUnwrap(rig.finals.last)
            await rig.process(session).value
            XCTAssertEqual(native.paths, [session.recognition.modelPath])
            XCTAssertEqual(native.calls.count, 1); XCTAssertEqual(native.calls[0].samples.count, 8000)
            XCTAssertFalse(rig.history.isEmpty); XCTAssertFalse(rig.insertions.isEmpty)
            XCTAssertEqual(native.releases, 1); XCTAssertEqual(rig.recognition.calls, 0)
        }
    }
    func testOldAbsentAndInvalidMouseSettingsPreserveCanonicalKeyboard() throws {
        let old = #"{"hotkeys":{"pushToTalk":"rightcontrol","handsFree":"ctrl+space","pasteLast":"cmd+v","openScratchpad":"cmd+s"},"language":"hi"}"#
        let baseline = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertNil(baseline.mouseBinding); XCTAssertNil(Settings().mouseBinding)
        for invalid in ["0", "1", "-1", "16", "999999999999999999999", "2.5", #""2""#, "true", "{}", "[]"] {
            let json = String(old.dropLast()) + #", "mouseBinding":{"buttonNumber":\#(invalid)}}"#
            let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
            XCTAssertNil(decoded.mouseBinding, json); XCTAssertNotNil(decoded.mouseBindingProblem)
            XCTAssertEqual(decoded.hotkeys, baseline.hotkeys); XCTAssertEqual(decoded.language, "hi")
        }
        for value in ["true", #""middle""#, "[]"] {
            let json = String(old.dropLast()) + #", "mouseBinding":\#(value)}"#
            let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
            XCTAssertNil(decoded.mouseBinding); XCTAssertNotNil(decoded.mouseBindingProblem); XCTAssertEqual(decoded.hotkeys, baseline.hotkeys)
        }
        for number in [2, 3, 15] {
            var settings = baseline; settings.mouseBinding = MouseButtonBinding(buttonNumber: number)
            let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.mouseBinding?.buttonNumber, number); XCTAssertEqual(decoded.hotkeys, baseline.hotkeys)
        }
        let hotkeys = try JSONEncoder().encode(baseline.hotkeys)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBindings.self, from: hotkeys), baseline.hotkeys)
    }
    func testNoBindingNoSuppressionCaptureOrCredentialRead() throws {
        let rig = try MouseRig(binding: nil); defer { try! rig.close() }
        for number in 0...17 { XCTAssertFalse(rig.down(number)); XCTAssertFalse(rig.up(number)) }
        rig.drain(); XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.backend.reads, 0); XCTAssertEqual(rig.entries, 0)
    }
    func testMiddleAndExplicitExtrasConsumeExactlyOwnedEdges() throws {
        for button in [2, 3, 15] {
            let rig = try MouseRig(binding: button); defer { try! rig.close() }
            for other in [0, 1, 2, 3, 4, 15, 16] where other != button {
                XCTAssertFalse(rig.down(other)); XCTAssertFalse(rig.up(other))
            }
            XCTAssertTrue(rig.down(button)); XCTAssertTrue(rig.down(button)); rig.drain()
            XCTAssertEqual(rig.captures, 1); XCTAssertTrue(rig.machine.isCapturing)
            XCTAssertTrue(rig.up(button)); XCTAssertFalse(rig.up(button)); rig.drain()
            XCTAssertEqual(rig.stops, 1); XCTAssertEqual(rig.finalizations, 1)
        }
    }
    func testActualNativeAdapterIgnoresSyntheticAndUnrelatedEvents() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        func fixture(marker: Int64) throws -> CGEvent {
            let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
            source.userData = marker
            return try XCTUnwrap(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                                        mouseCursorPosition: .zero, mouseButton: .center))
        }
        let synthetic = try fixture(marker: Inserter.syntheticMarker)
        XCTAssertNotNil(rig.monitor.process(type: .otherMouseDown, event: synthetic)); rig.drain()
        XCTAssertEqual(rig.captures, 0)
        let event = try fixture(marker: 0)
        event.timestamp = 100_000_000_000
        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 2)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 0)
        XCTAssertNil(rig.monitor.process(type: .otherMouseDown, event: event)); rig.drain()
        XCTAssertNotNil(rig.monitor.process(type: .otherMouseUp, event: synthetic))
        for type: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel, .otherMouseDragged] {
            XCTAssertNotNil(rig.monitor.process(type: type, event: event))
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertNotNil(rig.monitor.process(type: .otherMouseUp, event: event))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2); event.timestamp += 1_000_000_000
        XCTAssertNil(rig.monitor.process(type: .otherMouseUp, event: event)); rig.drain()
        XCTAssertEqual(rig.finalizations, 1); XCTAssertEqual(rig.captures, 1)
    }
    func testQueuedShortTapDiscardsWithoutRecognitionAndNormalHoldFinalizesOnce() async throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up(after: 0.1)); XCTAssertEqual(rig.captures, 0)
        rig.drain(); XCTAssertEqual(rig.captures, 1); XCTAssertEqual(rig.finalizations, 0); XCTAssertEqual(rig.stops, 1)
        XCTAssertTrue(rig.accepted[0].operation.shouldAbort)
        XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up()); XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up())
        rig.drain(); XCTAssertEqual(rig.captures, 3); XCTAssertEqual(rig.finalizations, 2)
        let session = try XCTUnwrap(rig.finals.last)
        await rig.process(session).value
        XCTAssertEqual(rig.recognition.calls, 1); XCTAssertEqual(rig.provider.calls, 1)
        XCTAssertEqual(rig.insertions.count, 1); XCTAssertEqual(rig.history.count, 1)
        XCTAssertFalse(rig.up()); rig.monitor.reconcileMouseButtons(); rig.drain()
        XCTAssertEqual(rig.finalizations, 2); XCTAssertEqual(rig.recognition.calls, 1)
    }
    func testEscAndCaptureCancellationKeepReleaseDebtAndDoNotAffectNewKeyboard() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain()
        XCTAssertTrue(rig.monitor.receiveKeyDown(keyCode: 53, modifiers: [], at: rig.clock.now)); rig.drain()
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0)
        rig.keyboard(); let session = try XCTUnwrap(rig.accepted.last)
        XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertTrue(rig.machine.isCapturing); XCTAssertEqual(rig.machine.gen, session.gen)
        XCTAssertFalse(session.operation.shouldAbort); XCTAssertEqual(rig.stops, 1)
        XCTAssertFalse(rig.up()); XCTAssertEqual(rig.captures, 2)
    }
    func testSecurePreflightAndPostStartRefusalDoNotLeavePhantomCapture() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        rig.secure = true; XCTAssertTrue(rig.down()); rig.drain()
        XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.secureRefusals, 1)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.finalizations, 0)
        rig.secure = false; rig.focusSecure = true
        XCTAssertTrue(rig.down()); rig.drain()
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.stops, 1)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.finalizations, 0)
        rig.focusSecure = false; rig.keyboard(); XCTAssertTrue(rig.machine.isCapturing)
    }
    func testSuspensionDuringOriginalPressAndCompletedSuspensionBeforeDrain() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain()
        let token = HotkeyMonitor.acquireSuspension()
        HotkeyMonitor.releaseSuspension(token) // exclusion happened even though no longer suspended
        XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0)
        XCTAssertTrue(rig.down())
        let second = HotkeyMonitor.acquireSuspension(); HotkeyMonitor.releaseSuspension(second)
        rig.drain(); XCTAssertEqual(rig.captures, 1)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.finalizations, 0)
    }
    func testRebindRemovalAndMultipleTransitionsPreserveOriginalDebts() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain(); let original = rig.accepted[0]
        try rig.bind(3); XCTAssertTrue(rig.down(3)); rig.drain()
        XCTAssertTrue(original.operation.shouldAbort); XCTAssertEqual(rig.captures, 2)
        let new = try XCTUnwrap(rig.accepted.count > 1 ? rig.accepted[1] : nil)
        XCTAssertTrue(rig.up(2)); rig.drain(); XCTAssertFalse(new.operation.shouldAbort); XCTAssertTrue(rig.machine.isCapturing)
        try rig.bind(nil); rig.drain(); XCTAssertTrue(new.operation.shouldAbort)
        XCTAssertFalse(rig.down(4)); XCTAssertFalse(rig.up(4))
        try rig.bind(4); try rig.bind(15); try rig.bind(3)
        XCTAssertTrue(rig.up(3)); XCTAssertFalse(rig.up(3)); rig.drain()
        XCTAssertEqual(rig.finalizations, 0); XCTAssertEqual(rig.stops, 2)
        XCTAssertTrue(rig.down(3)); XCTAssertTrue(rig.up(3)); rig.drain(); XCTAssertEqual(rig.finalizations, 1)
    }
    func testRebindRevokesDownStillQueuedAndUnconsumedDownNeverAcquiresAnUp() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertFalse(rig.down(3)); try rig.bind(3); XCTAssertFalse(rig.up(3))
        XCTAssertTrue(rig.down(3)); try rig.bind(4); XCTAssertTrue(rig.up(3)); rig.drain()
        XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.finalizations, 0)
        XCTAssertFalse(rig.up(4)); XCTAssertTrue(rig.down(4)); XCTAssertTrue(rig.up(4)); rig.drain()
        XCTAssertEqual(rig.captures, 1); XCTAssertEqual(rig.finalizations, 1)
    }
    func testPhysicalReleaseWithoutEventCancelsAndTrustedHeldStateDoesNot() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain()
        rig.monitor.reconcileMouseButtons(); rig.drain(); XCTAssertTrue(rig.machine.isCapturing)
        rig.buttons[2] = .up; rig.monitor.reconcileMouseButtons(); rig.monitor.reconcileMouseButtons(); rig.drain()
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0); XCTAssertEqual(rig.stops, 1)
        XCTAssertFalse(rig.up()); XCTAssertEqual(rig.discarded.count, 1)
        rig.buttons[2] = .down; XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertEqual(rig.finalizations, 1)
    }
    func testUnknownOrUntrackedPhysicalStateConservativelyCancelsButRetainsUpDebt() throws {
        for initial in [MouseButtonState.unknown, .up, .down] {
            let rig = try MouseRig(); defer { try! rig.close() }
            rig.buttons[2] = initial; XCTAssertTrue(rig.down()); rig.drain()
            rig.buttons[2] = .unknown; rig.monitor.reconcileMouseButtons(); rig.drain()
            XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0)
            for _ in 0..<20 { rig.monitor.receiveTapStatus(.disabled); rig.monitor.reconcileMouseButtons() }
            rig.drain(); XCTAssertEqual(rig.stops, 1)
            XCTAssertTrue(rig.up()); XCTAssertFalse(rig.up()); XCTAssertEqual(rig.discarded.count, 1)
        }
    }
    func testTapDisableInvalidPortPermissionLossUnavailableAndRetryUseResetSeam() throws {
        for status in [InputTapStatus.disabled, .invalidPort, .permissionLost, .unavailable] {
            let rig = try MouseRig(); defer { try! rig.close() }
            XCTAssertTrue(rig.down()); rig.drain()
            rig.monitor.receiveTapStatus(status); rig.monitor.receiveTapStatus(status); rig.drain()
            XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0); XCTAssertEqual(rig.stops, 1)
            XCTAssertFalse(rig.down(3)); XCTAssertTrue(rig.up()); XCTAssertFalse(rig.down())
            rig.monitor.receiveTapStatus(.ready); rig.drain()
            XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up()); rig.drain()
            XCTAssertEqual(rig.finalizations, 1); XCTAssertEqual(rig.statuses.suffix(2), [status, .ready])
        }
    }
    func testActualTapDisabledCallbackCancelsWithoutAnyNativeTapCreation() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain()
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(source: source))
        XCTAssertNotNil(rig.monitor.process(type: .tapDisabledByTimeout, event: event)); rig.drain()
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0)
        XCTAssertEqual(rig.monitor.tapStatus, .disabled); XCTAssertTrue(rig.up())
    }
    func testRecorderUnplugCancelsOnlyOwnedMouseWhileKeyboardLostReleaseStillFinalizes() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain(); let mouse = rig.accepted[0]
        rig.router.captureEnded(generation: mouse.gen, reason: .deviceLost)
        XCTAssertTrue(mouse.operation.shouldAbort); XCTAssertEqual(rig.finalizations, 0)
        rig.keyboard(); let keyboard = try XCTUnwrap(rig.accepted.last)
        rig.router.captureEnded(generation: mouse.gen, reason: .deviceLost)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertTrue(rig.machine.isCapturing)
        rig.router.captureEnded(generation: keyboard.gen, reason: .deviceLost)
        XCTAssertEqual(rig.finalizations, 1)
        rig.monitor.handle(keyCode: 63, modifiers: [.fn], at: 200); rig.drain()
        rig.monitor.reconcile(triggerDown: false, at: .greatestFiniteMagnitude); rig.drain()
        XCTAssertEqual(rig.finalizations, 2)
    }
    func testKeyboardPreemptsOwnedMouseBeforeNewCaptureAndLateEdgesCannotStopIt() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain(); let mouse = rig.accepted[0]
        rig.monitor.handle(keyCode: 63, modifiers: [.fn], at: 200)
        XCTAssertTrue(rig.up()); rig.drain()
        let keyboard = try XCTUnwrap(rig.accepted.last)
        XCTAssertTrue(mouse.operation.shouldAbort); XCTAssertEqual(rig.captures, 2); XCTAssertEqual(rig.stops, 1)
        rig.router.mouse(.up(rig.presses[0], short: false)); rig.router.mouse(.cancel(rig.presses[0]))
        XCTAssertTrue(rig.machine.isCapturing); XCTAssertFalse(keyboard.operation.shouldAbort)
        XCTAssertEqual(rig.finalizations, 0)
        rig.monitor.handle(keyCode: 63, modifiers: [], at: 201); rig.drain(); XCTAssertEqual(rig.finalizations, 1)
    }
    func testActiveKeyboardOrKeyboardHandsFreeCannotBeStolenByMouse() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        rig.monitor.handle(keyCode: 63, modifiers: [.fn, .shift], at: 100); rig.drain()
        XCTAssertTrue(rig.accepted[0].isCommand); XCTAssertFalse(rig.down()); XCTAssertFalse(rig.up())
        XCTAssertTrue(rig.monitor.receiveKeyDown(keyCode: 49, modifiers: [.fn, .shift], at: 101)); rig.drain()
        rig.monitor.handle(keyCode: 63, modifiers: [], at: 102); rig.drain()
        XCTAssertTrue(rig.machine.isCapturing); XCTAssertFalse(rig.down()); XCTAssertFalse(rig.up())
        XCTAssertTrue(rig.monitor.receiveKeyDown(keyCode: 36, modifiers: [], at: 103)); rig.drain(); XCTAssertEqual(rig.finalizations, 1)
    }
    func testMousePhysicalStartPreemptsAutomationAndLateMouseCannotStopNewAutomation() async throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        let automation = try await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID()).get()
        XCTAssertTrue(rig.down()); rig.drain()
        XCTAssertEqual(rig.captures, 2); XCTAssertEqual(rig.stops, 1); XCTAssertTrue(rig.accepted[0].operation.shouldAbort)
        let mouse = rig.accepted[1]
        rig.host.mouseEnd(rig.presses[0])
        let newer = try await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID()).get()
        XCTAssertNotEqual(automation.sessionID, newer.sessionID)
        XCTAssertTrue(rig.up()); rig.drain()
        rig.router.mouse(.cancel(rig.presses[0])); XCTAssertTrue(rig.machine.isCapturing)
        XCTAssertTrue(mouse.operation.shouldAbort); XCTAssertEqual(rig.finalizations, 0)
        XCTAssertFalse(rig.accepted.last!.operation.shouldAbort)
    }
    func testQueuedMouseDownUpAfterNewKeyboardOrAutomationNeverAcquiresAuthority() async throws {
        for automation in [false, true] {
            let rig = try MouseRig(); defer { try! rig.close() }
            XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up()); XCTAssertEqual(rig.captures, 0)
            if automation { _ = try await rig.runtime.broker.start(requestID: rig.runtime.broker.makeRequestID()).get() }
            else { rig.keyboard() }
            let owner = try XCTUnwrap(rig.accepted.last)
            rig.drain(); XCTAssertEqual(rig.captures, 1); XCTAssertEqual(rig.stops, 0); XCTAssertEqual(rig.finalizations, 0)
            XCTAssertTrue(rig.machine.isCapturing); XCTAssertFalse(owner.operation.shouldAbort)
        }
    }
    func testQueuedCancelAndUpAfterNewOwnerCannotFinalizeOrRevokeIt() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain()
        try rig.bind(3) // cancel still on actual main queue
        rig.keyboard(); let owner = try XCTUnwrap(rig.accepted.last)
        XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertFalse(owner.operation.shouldAbort); XCTAssertTrue(rig.machine.isCapturing)
        XCTAssertEqual(rig.finalizations, 0); XCTAssertEqual(rig.stops, 1)
    }
    func testB55ReviewListenTryoutAndShortcutExclusionsAtNativeAndQueuedMainBoundaries() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        for owner in [CaptureAdmission.Owner.microphoneTest, .shortcut] {
            let lease = try XCTUnwrap(rig.admission.acquire(owner))
            XCTAssertFalse(rig.down()); XCTAssertFalse(rig.up()); rig.admission.release(lease)
            XCTAssertTrue(rig.down())
            let intervening = try XCTUnwrap(rig.admission.acquire(owner)); rig.admission.release(intervening)
            rig.drain(); XCTAssertEqual(rig.captures, 0); XCTAssertTrue(rig.up()); rig.drain()
        }
        XCTAssertTrue(rig.host.beginTryout()); XCTAssertFalse(rig.down()); XCTAssertFalse(rig.up()); rig.host.endTryout()
        XCTAssertTrue(rig.down()); XCTAssertTrue(rig.host.beginTryout()); rig.host.endTryout()
        rig.drain(); XCTAssertEqual(rig.captures, 0); XCTAssertTrue(rig.up()); rig.drain()
        let shortcut = try XCTUnwrap(rig.host.beginShortcutRecording())
        XCTAssertFalse(rig.down()); XCTAssertFalse(rig.up()); rig.host.endShortcutRecording(shortcut)
        XCTAssertTrue(rig.down()); rig.drain(); XCTAssertFalse(rig.host.beginTryout()); XCTAssertNil(rig.host.beginShortcutRecording())
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.finalizations, 1)
    }
    func testQueuedResetAndRepeatedRebindsDoNotCreateDuplicateProcessingOrOutput() async throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain(); let canceled = rig.accepted[0]
        for button in 3...15 { try rig.bind(button); _ = rig.down(button) }
        for _ in 0..<20 { rig.monitor.receiveTapStatus(.invalidPort) }
        rig.keyboard(); let current = try XCTUnwrap(rig.accepted.last)
        for button in 2...15 { XCTAssertTrue(rig.up(button)); XCTAssertFalse(rig.up(button)) }
        rig.drain(); XCTAssertEqual(rig.captures, 2); XCTAssertEqual(rig.stops, 1)
        XCTAssertFalse(current.operation.shouldAbort); XCTAssertTrue(canceled.operation.shouldAbort)
        _ = rig.host.keyboard(.stopRequested); XCTAssertEqual(rig.finalizations, 1)
        await rig.process(canceled).value; await rig.process(current).value
        XCTAssertEqual(rig.recognition.calls, 1); XCTAssertEqual(rig.provider.calls, 1)
        XCTAssertEqual(rig.insertions.count, 1); XCTAssertEqual(rig.history.count, 1)
    }
    func testExclusionInterveningInsideNativeDownCannotAuthorizeQueuedCapture() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        rig.beforeButtonRead = {
            let lease = rig.host.beginShortcutRecording()
            XCTAssertNotNil(lease)
            if let lease { rig.host.endShortcutRecording(lease) }
        }
        XCTAssertTrue(rig.down()); rig.drain()
        XCTAssertEqual(rig.captures, 0); XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertEqual(rig.finalizations, 0)
    }
    func testResetBeforeQueuedDownOrCompletedPairRevokesStartBeforeRetry() throws {
        for releaseBeforeReset in [false, true] {
            let rig = try MouseRig(); defer { try! rig.close() }
            XCTAssertTrue(rig.down())
            if releaseBeforeReset { XCTAssertTrue(rig.up()) }
            rig.monitor.receiveTapStatus(.disabled); rig.monitor.receiveTapStatus(.ready); rig.drain()
            XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.finalizations, 0)
            if !releaseBeforeReset { XCTAssertTrue(rig.up()) }
            XCTAssertTrue(rig.down()); XCTAssertTrue(rig.up()); rig.drain()
            XCTAssertEqual(rig.captures, 1); XCTAssertEqual(rig.finalizations, 1)
        }
    }
    func testOldMousePressCannotStopCancelOrRestartNewMouseOperation() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain(); let oldPress = try XCTUnwrap(rig.presses.last)
        XCTAssertTrue(rig.up()); XCTAssertTrue(rig.down())
        rig.drain(); let current = try XCTUnwrap(rig.accepted.last)
        rig.router.mouse(.up(oldPress, short: false)); rig.router.mouse(.cancel(oldPress)); rig.router.mouse(.down(oldPress))
        XCTAssertEqual(rig.captures, 2); XCTAssertEqual(rig.finalizations, 1)
        XCTAssertEqual(rig.machine.gen, current.gen); XCTAssertTrue(rig.machine.isCapturing)
        XCTAssertFalse(current.operation.shouldAbort)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.finalizations, 2)
    }
    func testNativeSyntheticKeyboardCancelAndRepeatLeaveMouseMarkerPolicyIntact() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain()
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState)); source.userData = Inserter.syntheticMarker
        let synthetic = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true))
        XCTAssertNotNil(rig.monitor.process(type: .keyDown, event: synthetic)); rig.drain()
        XCTAssertTrue(rig.machine.isCapturing)
        XCTAssertTrue(rig.monitor.receiveKeyDown(keyCode: 53, modifiers: [], at: rig.clock.now)); rig.drain()
        XCTAssertTrue(rig.monitor.receiveKeyDown(keyCode: 53, modifiers: [], isRepeat: true, at: rig.clock.now))
        XCTAssertFalse(rig.monitor.receiveKeyDown(keyCode: 0, modifiers: [], isRepeat: true, at: rig.clock.now))
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.stops, 1); XCTAssertEqual(rig.finalizations, 0)
    }
    func testReleaseBeforeAcknowledgementCancelsAndLateAckCannotReviveOrTouchNewCapture() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        rig.acknowledge = false
        XCTAssertTrue(rig.down()); rig.drain(); let old = try XCTUnwrap(rig.accepted.last)
        XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertTrue(old.operation.shouldAbort); XCTAssertFalse(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0)
        rig.acknowledge = true; rig.keyboard(); let current = try XCTUnwrap(rig.accepted.last)
        rig.send(.recorderStarted(gen: old.gen)); rig.send(.focusSampled(gen: old.gen, focus: .editable))
        rig.router.mouse(.up(rig.presses[0], short: false))
        XCTAssertEqual(rig.machine.gen, current.gen); XCTAssertTrue(rig.machine.isCapturing); XCTAssertEqual(rig.stops, 1)
    }
    func testExternalCaptureCancelAndLateNativeReleaseKeepNewOwnerIntact() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        XCTAssertTrue(rig.down()); rig.drain(); let old = try XCTUnwrap(rig.accepted.last)
        rig.send(.cancelRequested(silent: false)); rig.keyboard()
        let current = try XCTUnwrap(rig.accepted.last)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertTrue(old.operation.shouldAbort)
        XCTAssertFalse(current.operation.shouldAbort); XCTAssertTrue(rig.machine.isCapturing); XCTAssertEqual(rig.finalizations, 0)
    }
    func testMouseOnlyHubSaveReloadsBindingWithoutGeneralModelMicOrCredentialEntry() throws {
        let rig = try MouseRig(binding: nil); defer { try! rig.close() }
        let history = HistoryStore(url: rig.root.appendingPathComponent("history.json"))
        let recordings = RecordingStore(directory: rig.root.appendingPathComponent("audio"), keepAll: false)
        let labels = ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } })
        let hub = HubModel(store: rig.store, history: history, recordings: recordings, shortcutLabels: labels,
                           diagnostics: DiagnosticStore())
        hub.settings = rig.store.load() // injected settings; no native permission/layout queries
        var generalEntries = 0, mouseEntries = 0
        hub.onSaved = { generalEntries += 1 }
        hub.onMouseBindingSaved = { mouseEntries += 1; rig.monitor.reloadMouseConfiguration() }
        let keyboard = hub.settings.hotkeys
        for number: Int? in [2, 3, 15, nil] {
            hub.settings.mouseBinding = number.flatMap { MouseButtonBinding(buttonNumber: $0) }
            hub.flushPendingSave(); rig.drain()
            XCTAssertEqual(rig.store.load().mouseBinding?.buttonNumber, number)
            XCTAssertEqual(rig.store.load().hotkeys, keyboard)
        }
        XCTAssertEqual(mouseEntries, 4); XCTAssertEqual(generalEntries, 0)
        XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.entries, 0); XCTAssertEqual(rig.backend.reads, 0)
        XCTAssertNil(rig.store.load().mouseBinding); XCTAssertFalse(rig.down())
        // Coalesced choices return to Off before one debounce/flush.
        hub.settings.mouseBinding = MouseButtonBinding(buttonNumber: 2)
        hub.settings.mouseBinding = nil
        hub.flushPendingSave(); rig.drain()
        XCTAssertEqual(mouseEntries, 5); XCTAssertEqual(generalEntries, 0)
        XCTAssertNil(rig.store.load().mouseBinding)
        XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.entries, 0); XCTAssertEqual(rig.backend.reads, 0)
        // A genuine non-mouse change must still reach general preferences.
        hub.settings.mouseBinding = MouseButtonBinding(buttonNumber: 2)
        hub.settings.mouseBinding = nil
        hub.settings.showHudAlways.toggle()
        hub.flushPendingSave(); rig.drain()
        XCTAssertEqual(mouseEntries, 5); XCTAssertEqual(generalEntries, 1)
    }
    func testRecorderStartFailureAndAdmissionRefusalRemainBalanced() throws {
        let rig = try MouseRig(); defer { try! rig.close() }
        rig.recorderFails = true; XCTAssertTrue(rig.down()); rig.drain()
        XCTAssertFalse(rig.machine.isCapturing); XCTAssertTrue(rig.admission.isAvailable)
        XCTAssertTrue(rig.up()); rig.drain(); XCTAssertEqual(rig.finalizations, 0)
        rig.allowed = false; XCTAssertTrue(rig.down()); rig.drain(); XCTAssertTrue(rig.up()); rig.drain()
        XCTAssertEqual(rig.captures, 1); XCTAssertFalse(rig.machine.isCapturing)
    }
}
