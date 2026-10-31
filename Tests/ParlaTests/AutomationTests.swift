import XCTest
import AppIntents
import ParlaCore
@testable import Parla

@MainActor final class AutomationTestClock: AutomationClock {
    var now: TimeInterval = 100
    private var actions: [UUID: (TimeInterval, @MainActor () -> Void)] = [:]
    var scheduled: (() -> Void)?
    var count: Int { actions.count }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID(); actions[id] = (now + seconds, action); scheduled?()
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
actor AutomationWorkGate {
    let entered = XCTestExpectation(description: "owned gate entered")
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}
final class AutomationRecognition: RecognitionClient, @unchecked Sendable {
    var text: String? = "raw dictated text"
    var held = false
    let entered = XCTestExpectation(description: "inert native entered")
    let exit = RecognitionTestLatch()
    private let lock = NSLock()
    private var abort: (() -> Bool)?
    private var callCount = 0
    var calls: Int { lock.withLock { callCount } }
    var abortRequested: Bool { lock.withLock { abort?() == true } }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        lock.withLock { abort = shouldAbort; callCount += 1 }
        if held { entered.fulfill(); await exit.wait() }
        return text // deliberately noncooperative, no actual model
    }
}
final class AutomationProvider: CleanupProviding, @unchecked Sendable {
    var text = "Clean final text."
    var held = false
    var failing = false
    let entered = XCTestExpectation(description: "inert provider entered")
    let canceled = XCTestExpectation(description: "owned provider abort")
    var revoked: () -> Bool = { true }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var calls = 0
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        calls += 1
        if !held { if failing { throw CancellationError() }; return text }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }; entered.fulfill()
            }
        } onCancel: { XCTAssertTrue(self.revoked()); self.canceled.fulfill() }
    }
    func complete() {
        let saved = lock.withLock { let c = continuation; continuation = nil; return c }
        if failing { saved?.resume(throwing: CancellationError()) } else { saved?.resume(returning: text) }
    }
}

/// Real lifecycle gate, broker, invocation host, reducer, processing and queue.
/// Only native/device/disk/provider sinks are fakes; no AppDelegate or Hub.
@MainActor final class AutomationRig {
    let clock = AutomationTestClock()
    let diagnostic = DiagnosticStore()
    lazy var machine = DictationSession(diagnostics: diagnostic)
    var settings: Settings = {
        var s = Settings(); s.automationEnabled = true; s.whisperModelPath = "/inert/verified-model.bin"
        s.cleanupEnabled = false; s.outputMode = .raw; return s
    }()
    lazy var runtime = AutomationRuntime(clock: clock, enabled: { [weak self] in self?.settings.automationEnabled == true })
    var broker: AutomationBroker { runtime.broker }
    var results: DictationResultStore { runtime.results }
    var secure = false
    var ax = true
    var capabilityFailure: AutomationFailure?
    var recognitionCapability: ((RecognitionRequest) -> AutomationFailure?)?
    var recognitionEntry: ((RecognitionRequest) -> Void)?
    var acknowledge = true
    var recorderFails = false
    var nativeGeneration = 0
    var captures = 0
    var resolutions = 0
    var finalizations = 0
    var acquisitions = 0
    var entries = 0
    var stops = 0
    var abortions: [UUID] = []
    var history: [String] = []
    var insertions: [String] = []
    var effects: [DictationSession.Effect] = []
    var accepted: DictationSession.Session?
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var foundationFactory: RecognitionFactory?
    var captureObserved: (() -> Void)?
    var beforeEffect: ((DictationSession.Effect) -> Void)?
    lazy var host = DictationInvocationHost(machine: machine, broker: broker, results: results,
        settings: { [weak self] in self?.settings }, configured: { $0.cleanupEnabled },
        capabilities: { [weak self] request in
            if let check = self?.recognitionCapability { return check(request) }
            return self?.capabilityFailure
        }, secure: { [weak self] in self?.secure == true },
        keyboardAllowed: { [weak self] in self?.ax == true }, automationAllowed: { [weak self] in self?.settings.automationEnabled == true },
        explicitEntry: { [weak self] in self?.entries += 1 }, send: { [weak self] in self?.send($0) },
        deliberateASREntry: { [weak self] in self?.recognitionEntry?($0) })
    func register() { broker.register(host) }
    func send(_ event: DictationSession.Event) {
        if case .discardPending(let token) = event { host.discarded(token) }
        if case .operationFinished(let operation) = event { host.finished(operation) }
        machine.send(event) { effect in
            beforeEffect?(effect)
            if machine.effectOperation?.shouldAbort == true { return }
            effects.append(effect)
            switch effect {
            case .captureAccepted(let session): accepted = session; host.accepted(session)
            case .captureAcknowledged(let session): host.acknowledged(session)
            case .captureFinalizing(let session): host.finalizing(session)
            case .finalResult(let session, let result): host.completed(session, result: result)
            case .applyPreferencesAndStartCapture:
                nativeGeneration = machine.gen
                captures += 1; captureObserved?()
                if recorderFails { send(.recorderFailed(gen: machine.gen, message: "inert failure")) }
                else if acknowledge { send(.recorderStarted(gen: machine.gen)) }
            case .sampleFocus(let gen): send(.focusSampled(gen: gen, focus: secure ? .secure : .editable))
            case .stopCapture: stops += 1; nativeGeneration = 0
            case .stopOwnedCapture(let generation, _):
                if nativeGeneration == generation { stops += 1; nativeGeneration = 0 }
            case .abortOperation(let operation):
                XCTAssertTrue(operation.shouldAbort, "revoke precedes abort/disposal")
                abortions.append(operation.id); operation.requestAbort()
            case .transcribeFinal: finalizations += 1
            case .polish(let session, let landed): pending = (session, landed)
            case .appendHistory(let raw, let cleaned, _): history.append(cleaned ?? raw)
            case .insertText(let text, _, _): insertions.append(text)
            case .secureRefusal: host.secureRefusal { XCTAssertNil(results.read()) }
            default: break
            }
        }
    }
    func request() -> AutomationRequestID { broker.makeRequestID() }
    func start() async throws -> AutomationStart { try await broker.start(requestID: request()).get() }
    func keyboard() {
        XCTAssertTrue(host.keyboard(.startDictation(settings: settings, cleanupConfigured: settings.cleanupEnabled,
                                                   live: false, recognitionDestination: .init(bundleID: "com.unrelated.app"))))
    }
    func complete(_ session: DictationSession.Session, raw: String? = "raw", text: String = "final", failure: String? = nil) {
        send(.transcribed(session, raw: raw, probe: .init(focus: secure ? .secure : .unknown, bundleID: "com.unrelated.app", deferInsertionUntilClean: true)))
        if let (output, landed) = pending {
            pending = nil; send(.cleanReady(output, landed, text: text, failure: failure, focus: secure ? .secure : .unknown))
        }
    }
    func run(_ session: DictationSession.Session, client: AutomationRecognition = AutomationRecognition(),
             provider: AutomationProvider = AutomationProvider(), previous: Task<Void, Never>? = nil,
             acquisition: AutomationWorkGate? = nil, beforeMain: AutomationWorkGate? = nil,
             beforePublication: AutomationWorkGate? = nil) -> Task<Void, Never> {
        let samples = (0..<8000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        return PendingOperationQueue.enqueue(previous: previous, operation: session.operation, completes: true, work: {
            await DictationProcessing.final(operation: session.operation, samples: samples, window: nil, prepare: {
                if let acquisition { await acquisition.hold() }
                guard !session.operation.shouldAbort else { return nil }
                await MainActor.run { self.acquisitions += 1 }
                if let factory = await MainActor.run(body: { self.foundationFactory }) {
                    return try! await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: factory,
                        operation: session.operation, capture: session.operation.id)
                }
                return try! RecognitionHandle(request: session.recognition) { _ in client }
            }, recognized: { _, raw in
                if let beforeMain { await beforeMain.hold() }
                return await MainActor.run {
                    self.send(.transcribed(session, raw: raw, probe: .init(focus: self.secure ? .secure : .unknown,
                                                                         bundleID: "com.unrelated.app", deferInsertionUntilClean: true)))
                    defer { self.pending = nil }; return self.pending
                }
            }, clean: { (context: (DictationSession.Session, DictationSession.Landed)) in
                await Pipeline(outputSettings: context.0.effectiveSettings, bundleID: context.1.bundleID,
                               failureLogging: context.0.delivery == .resultOnly ? .contentFree : .details) { _ in provider }
                    .clean(transcript: context.1.raw)
            }, completed: { context, text, failure in
                if let beforePublication { await beforePublication.hold() }
                await MainActor.run { self.send(.cleanReady(context.0, context.1, text: text, failure: failure,
                                                            focus: self.secure ? .secure : .unknown)) }
            })
        }, finished: { await MainActor.run { self.send(.operationFinished(session.operation)) } })
    }
}

final class AutomationTests: XCTestCase {
    @MainActor func testResultOnlyAutomationActualFactoryAndWhisperAdapterNeverInsert() async throws {
        let rig = AutomationRig(), probe = FoundationNativeProbe()
        rig.foundationFactory = probe.factory(); rig.register()
        let started = try await rig.start()
        let session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested)
        await rig.run(session).value
        let result = try await rig.broker.stop(sessionID: started.sessionID).get()
        XCTAssertEqual(result.text, "native original")
        XCTAssertEqual(probe.paths, [session.recognition.modelPath])
        XCTAssertEqual(probe.calls.count, 1); XCTAssertEqual(probe.calls.first?.samples.count, 8000)
        XCTAssertTrue(rig.insertions.isEmpty); XCTAssertEqual(rig.history, ["native original"])
        XCTAssertEqual(probe.releases, 1)
        XCTAssertEqual(rig.results.read()?.text, "native original")
    }
    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    @MainActor func testColdPassiveCommandsAndActualOrderedBootstrapAreInert() async throws {
        let rig = AutomationRig()
        let unknown = AutomationSessionID(process: rig.broker.process, id: UUID())
        XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable))
        expectEqual(await rig.broker.stop(sessionID: unknown), .failure(.staleSession))
        XCTAssertEqual(rig.broker.cancel(sessionID: unknown), .failure(.staleSession))
        var order: [String] = []
        let startup = ApplicationStartupCoordinator(configure: { order.append("configure") },
            register: { order.append("register"); rig.register() }, services: { order.append("services") },
            migrate: { order.append("migrate") }, setup: { order.append("setup-model") }, warmMic: { order.append("warm-mic") })
        startup.bootstrap(); startup.bootstrap()
        XCTAssertEqual(order, ["configure", "register", "services"])
        XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable)); XCTAssertEqual(rig.captures, 0)
        XCTAssertEqual(rig.acquisitions, 0); XCTAssertEqual(rig.entries, 0); XCTAssertTrue(rig.effects.isEmpty)
        startup.enterDictation(); XCTAssertEqual(Array(order.suffix(2)), ["migrate", "warm-mic"])
        startup.enterSetup(); XCTAssertEqual(Array(order.suffix(3)), ["migrate", "setup-model", "warm-mic"])
    }
    @MainActor func testHostAbsentTimeoutLateRegistrationAndReplayCannotCapture() async throws {
        let rig = AutomationRig(), scheduled = expectation(description: "readiness deadline")
        rig.clock.scheduled = { scheduled.fulfill() }
        let request = rig.request()
        let task = Task { await rig.broker.start(requestID: request) }
        await fulfillment(of: [scheduled], timeout: 2); rig.clock.scheduled = nil
        XCTAssertEqual(rig.broker.waiterCount, 1); rig.clock.advance(5)
        expectEqual(await task.value, .failure(.timeout)); rig.register()
        expectEqual(await rig.broker.start(requestID: request), .failure(.timeout))
        XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.broker.waiterCount, 0); XCTAssertEqual(rig.clock.count, 0)
        rig.clock.advance(60)
        expectEqual(await rig.broker.start(requestID: request), .failure(.staleSession))
    }
    @MainActor func testTimelyHostRegistrationAndDuplicateStartUseOneRealGeneration() async throws {
        let rig = AutomationRig(), scheduled = expectation(description: "waiting for host")
        rig.clock.scheduled = { scheduled.fulfill() }
        let request = rig.request(), first = Task { await rig.broker.start(requestID: request) }
        await fulfillment(of: [scheduled], timeout: 2); rig.clock.scheduled = nil
        let second = Task { await rig.broker.start(requestID: request) }
        rig.register()
        let a = try await first.value.get(), b = try await second.value.get()
        XCTAssertEqual(a, b); XCTAssertEqual(rig.captures, 1); XCTAssertEqual(rig.machine.gen, 1)
        XCTAssertEqual(rig.broker.waiterCount, 0); XCTAssertEqual(rig.clock.count, 0)
        expectEqual(await rig.broker.start(requestID: rig.request()), .failure(.busy))
        XCTAssertEqual(rig.broker.cancel(sessionID: a.sessionID), .success(.canceled))
    }
    @MainActor func testRecorderFailureIsBoundBeforeSynchronousFailure() async {
        let rig = AutomationRig(); rig.recorderFails = true; rig.register()
        let result = await rig.broker.start(requestID: rig.request())
        XCTAssertEqual(result, .failure(.unavailable)); XCTAssertEqual(rig.captures, 1)
        XCTAssertEqual(rig.broker.terminalCount, 1); XCTAssertEqual(rig.broker.waiterCount, 0)
        XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable))
    }
    @MainActor func testDelayedAcknowledgementStopBeforeReadyFinalizesOnceAndDuplicatesJoin() async throws {
        let rig = AutomationRig(), captured = expectation(description: "capture requested")
        rig.acknowledge = false; rig.captureObserved = { captured.fulfill() }; rig.register()
        let request = rig.request(), start = Task { await rig.broker.start(requestID: request) }
        await fulfillment(of: [captured], timeout: 2)
        let id = try XCTUnwrap(rig.broker.reservedSessionID), session = try XCTUnwrap(rig.accepted)
        let stop = Task { await rig.broker.stop(sessionID: id) }
        await Task.yield()
        rig.send(.recorderStarted(gen: session.gen))
        _ = try await start.value.get()
        let duplicate = Task { await rig.broker.stop(sessionID: id) }
        rig.send(.captureEnded(gen: session.gen, reason: .deviceLost))
        rig.complete(session, text: "only final")
        expectEqual(try await stop.value.get().text, "only final")
        expectEqual(try await duplicate.value.get().text, "only final")
        XCTAssertEqual(rig.finalizations, 1); XCTAssertEqual(rig.broker.waiterCount, 0)
        expectEqual(try await rig.broker.start(requestID: request).get().status, .completed)
        XCTAssertEqual(rig.captures, 1)
    }
    @MainActor func testReadinessDeadlineStillAppliesAfterStopBeforeAckAndLateAckIsInert() async throws {
        let rig = AutomationRig(), captured = expectation(description: "delayed capture")
        rig.acknowledge = false; rig.captureObserved = { captured.fulfill() }; rig.register()
        let start = Task { await rig.broker.start(requestID: rig.request()) }
        await fulfillment(of: [captured], timeout: 2)
        let id = try XCTUnwrap(rig.broker.reservedSessionID), session = try XCTUnwrap(rig.accepted)
        let stop = Task { await rig.broker.stop(sessionID: id) }; await Task.yield()
        rig.clock.advance(5)
        expectEqual(await start.value, .failure(.timeout)); expectEqual(await stop.value, .failure(.timeout))
        rig.send(.recorderStarted(gen: session.gen)); rig.complete(session)
        XCTAssertTrue(session.operation.shouldAbort); XCTAssertEqual(rig.finalizations, 0)
        XCTAssertTrue(rig.history.isEmpty); XCTAssertNil(rig.results.read()); XCTAssertEqual(rig.clock.count, 0)
    }
    @MainActor func testStopDeadlineCancelsOwnedPendingAndNeverReturnsAnOlderResult() async throws {
        let rig = AutomationRig(); rig.register()
        let first = try await rig.start(); let old = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); rig.complete(old, text: "old text")
        XCTAssertEqual(try rig.broker.getLast().get().text, "old text")
        let second = try await rig.start(); let current = try XCTUnwrap(rig.accepted)
        let scheduled = expectation(description: "stop deadline"); rig.clock.scheduled = { scheduled.fulfill() }
        let stop = Task { await rig.broker.stop(sessionID: second.sessionID) }
        await fulfillment(of: [scheduled], timeout: 2); rig.clock.scheduled = nil
        rig.clock.advance(30)
        expectEqual(await stop.value, .failure(.timeout)); XCTAssertTrue(current.operation.shouldAbort)
        XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable)); XCTAssertEqual(rig.broker.cancel(sessionID: first.sessionID), .success(.alreadyCompleted))
        rig.complete(current); XCTAssertEqual(rig.history, ["old text"])
    }
    @MainActor func testCancellationDisableQuitAndWaiterOverflowRemoveAllWaiters() async throws {
        for mode in 0..<3 {
            let rig = AutomationRig(), scheduled = expectation(description: "pending host")
            rig.clock.scheduled = { scheduled.fulfill() }
            let task = Task { await rig.broker.start(requestID: rig.request()) }
            await fulfillment(of: [scheduled], timeout: 2); rig.clock.scheduled = nil
            if mode == 0 { task.cancel() }
            else if mode == 1 { rig.settings.automationEnabled = false; rig.broker.configurationChanged(enabled: false) }
            else { rig.broker.quit() }
            let expected: AutomationFailure = mode == 0 ? .canceled : mode == 1 ? .disabled : .shuttingDown
            expectEqual(await task.value, .failure(expected)); rig.register()
            XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.broker.waiterCount, 0); XCTAssertEqual(rig.clock.count, 0)
        }
        let rig = AutomationRig(), captured = expectation(description: "awaiting ack")
        rig.register(); rig.acknowledge = false; rig.captureObserved = { captured.fulfill() }
        let request = rig.request(), first = Task { await rig.broker.start(requestID: request) }
        await fulfillment(of: [captured], timeout: 2)
        var others: [Task<Result<AutomationStart, AutomationFailure>, Never>] = []
        for _ in 0..<7 { others.append(Task { await rig.broker.start(requestID: request) }); await Task.yield() }
        XCTAssertEqual(rig.broker.waiterCount, 8)
        expectEqual(await rig.broker.start(requestID: request), .failure(.waiterLimit))
        rig.broker.configurationChanged(enabled: false)
        expectEqual(await first.value, .failure(.disabled))
        for task in others { expectEqual(await task.value, .failure(.disabled)) }
        XCTAssertEqual(rig.broker.waiterCount, 0)
    }
    @MainActor func testKeyboardPreemptionOldIDsCannotStopNewCaptureAndTryoutOwnsAdmission() async throws {
        let rig = AutomationRig(); rig.register(); let automation = try await rig.start()
        let old = try XCTUnwrap(rig.accepted); rig.keyboard(); let keyboard = try XCTUnwrap(rig.accepted)
        XCTAssertTrue(old.operation.shouldAbort); XCTAssertEqual(keyboard.delivery, .keyboard)
        XCTAssertEqual(rig.broker.cancel(sessionID: automation.sessionID), .failure(.superseded))
        expectEqual(await rig.broker.stop(sessionID: automation.sessionID), .failure(.superseded))
        guard case .recording(let foreground) = rig.machine.state else { return XCTFail("new keyboard capture must remain live") }
        XCTAssertEqual(foreground.operation, keyboard.operation)
        expectEqual(await rig.broker.start(requestID: rig.request()), .failure(.busy))
        XCTAssertTrue(rig.host.keyboard(.cancelRequested(silent: true)))
        XCTAssertTrue(rig.host.beginTryout())
        expectEqual(await rig.broker.start(requestID: rig.request()), .failure(.busy))
        XCTAssertFalse(rig.host.keyboard(.startDictation(settings: rig.settings, cleanupConfigured: false, live: false)))
        rig.host.endTryout(); XCTAssertEqual(rig.broker.cancel(sessionID: automation.sessionID), .failure(.superseded))
    }
    @MainActor func testPendingCancellationUsesRetainedTokenEvenWhenLatestPendingChanges() async throws {
        let rig = AutomationRig(); rig.register(); let start = try await rig.start(); let old = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested)
        // Deliberately move the menu pointer through the real reducer; cancellation
        // must still use the retained token rather than whichever pointer is latest.
        rig.send(.startDictation(settings: rig.settings, cleanupConfigured: false, live: false))
        let keyboard = try XCTUnwrap(rig.accepted); rig.send(.stopRequested)
        XCTAssertEqual(rig.machine.pendingOperation, keyboard.operation)
        XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.canceled))
        XCTAssertTrue(old.operation.shouldAbort); XCTAssertFalse(keyboard.operation.shouldAbort)
        XCTAssertEqual(rig.abortions, [old.operation.id])
        XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.alreadyCanceled))
    }
    @MainActor func testNeutralResultOnlyAndMissingAXVersusSecureMicModelAndPresetRefusals() async throws {
        for refusal in [AutomationFailure.microphoneUnavailable, .modelUnavailable] {
            let rig = AutomationRig(); rig.capabilityFailure = refusal; rig.register()
            expectEqual(await rig.broker.start(requestID: rig.request()), .failure(refusal)); XCTAssertEqual(rig.captures, 0)
        }
        let secure = AutomationRig(); secure.secure = true; secure.register()
        expectEqual(await secure.broker.start(requestID: secure.request()), .failure(.secure)); XCTAssertEqual(secure.captures, 0)
        let preset = AutomationRig(); preset.settings.outputMode = .selectedPreset; preset.register()
        expectEqual(await preset.broker.start(requestID: preset.request()), .failure(.unsupportedOutputMode)); XCTAssertEqual(preset.captures, 0)
        let rig = AutomationRig(); rig.ax = false
        var profile = DictationProfile(); profile.name = "Unrelated"; profile.target = "com.unrelated.app"
        rig.settings.profiles = [profile]; rig.register(); _ = try await rig.start()
        let session = try XCTUnwrap(rig.accepted)
        XCTAssertTrue(session.settings.profiles.isEmpty); XCTAssertEqual(session.recognitionProfileName, "Global settings")
        rig.send(.stopRequested); rig.complete(session, text: "neutral\nparagraph")
        XCTAssertEqual(try rig.broker.getLast().get().text, "neutral\nparagraph")
        XCTAssertTrue(rig.insertions.isEmpty)
        XCTAssertFalse(rig.effects.contains { effect in
            switch effect { case .sampleFocus, .insertText, .replaceTailIfOurs, .eraseTypedIfOurs, .startStreamLoop, .warmCleanupEndpoint: return true; default: return false }
        })
        let wrong = AutomationSessionID(process: UUID(), id: UUID())
        XCTAssertEqual(rig.broker.cancel(sessionID: wrong), .failure(.staleSession))
    }
    @MainActor private func refuseSecureCommand(_ rig: AutomationRig, preset: Bool) {
        rig.secure = true
        let event: DictationSession.Event = preset
            ? .startSavedPreset(settings: rig.settings, cleanupConfigured: true, selection: nil, target: .init(focus: .secure))
            : .startCommand(settings: rig.settings, cleanupConfigured: true, focus: .secure, selection: nil)
        XCTAssertTrue(rig.host.keyboard(event))
        rig.secure = false
    }
    @MainActor func testSecureCommandRefusalInvalidatesPriorResultAfterFocusBecomesNonsecure() async throws {
        for preset in [false, true] {
            let rig = AutomationRig(); rig.register(); _ = try await rig.start()
            let session = try XCTUnwrap(rig.accepted)
            rig.send(.stopRequested); rig.complete(session, text: "prior eligible result")
            XCTAssertEqual(try rig.broker.getLast().get().text, "prior eligible result")
            let generation = rig.machine.gen, epoch = rig.results.epoch
            refuseSecureCommand(rig, preset: preset)
            XCTAssertEqual(rig.machine.gen, generation); XCTAssertGreaterThan(rig.results.epoch, epoch)
            XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable))
            XCTAssertFalse(session.operation.shouldAbort)
        }
    }
    @MainActor func testSecureCommandRefusalBlocksHeldRetrievalButPreservesKeyboardDeliveryAndHistory() async throws {
        for preset in [false, true] {
            let rig = AutomationRig(); rig.register(); rig.keyboard()
            let session = try XCTUnwrap(rig.accepted), gate = AutomationWorkGate()
            rig.send(.stopRequested)
            let task = rig.run(session, beforePublication: gate)
            await fulfillment(of: [gate.entered], timeout: 2)
            let generation = rig.machine.gen, epoch = rig.results.epoch
            refuseSecureCommand(rig, preset: preset)
            XCTAssertEqual(rig.machine.gen, generation); XCTAssertGreaterThan(rig.results.epoch, epoch)
            await gate.release(); await task.value
            XCTAssertFalse(session.operation.shouldAbort)
            XCTAssertEqual(rig.insertions, ["raw dictated text"]); XCTAssertEqual(rig.history, ["raw dictated text"])
            XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable))
        }
    }
    @MainActor func testSecureCompletionHasNoHistoryOrResultAndMissingAXNeverBecomesPaste() async throws {
        let rig = AutomationRig(); rig.register(); let start = try await rig.start(); let session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); rig.secure = true; rig.complete(session, text: "PRIVATE-CANARY")
        expectEqual(await rig.broker.stop(sessionID: start.sessionID), .failure(.secure))
        XCTAssertTrue(rig.history.isEmpty); XCTAssertNil(rig.results.read()); XCTAssertTrue(rig.insertions.isEmpty)
        let data = try JSONEncoder().encode(rig.diagnostic.snapshot())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-CANARY"))
    }
    @MainActor func testActualPipelineRawCleanupLiteralLocalFallbackAndHistoryOffFinalText() async throws {
        for mode in 0..<5 {
            let rig = AutomationRig(); rig.settings.historyEnabled = false
            rig.settings.outputMode = mode == 0 ? .raw : .cleanup
            rig.settings.cleanupEnabled = mode == 1 || mode == 3
            if mode == 2 || mode == 3 { rig.settings.replacements = [.init(source: "raw", replacement: "local")] }
            if mode == 4 { rig.settings.snippets = ["raw dictated text": "literal locked"] }
            rig.register(); let start = try await rig.start(), session = try XCTUnwrap(rig.accepted)
            rig.send(.stopRequested)
            let provider = AutomationProvider(); provider.failing = mode == 3
            let work = rig.run(session, provider: provider); await work.value
            let result = try await rig.broker.stop(sessionID: start.sessionID).get()
            XCTAssertEqual(result.text, ["raw dictated text", "Clean final text.", "local dictated text", "local dictated text", "literal locked"][mode])
            XCTAssertEqual(result.outcome, mode == 3 ? .localFallback : .final)
            XCTAssertTrue(rig.history.isEmpty); XCTAssertTrue(rig.insertions.isEmpty)
            XCTAssertEqual(rig.effects.filter { if case .finalResult = $0 { return true }; return false }.count, 1)
            XCTAssertFalse(rig.effects.contains(.hud(.error("History off — text discarded"))))
            XCTAssertEqual(provider.calls, mode == 1 || mode == 3 ? 1 : 0)
        }
    }
    @MainActor func testEmptyNilUnavailableAndMinimumDurationHaveTypedTerminalFailures() async throws {
        for (result, expected) in [(DictationFinalResult.failure(.minimumDuration), AutomationFailure.minimumDuration),
                                   (.failure(.unavailable), .unavailable), (.failure(.empty), .empty)] {
            let rig = AutomationRig(); rig.register(); let start = try await rig.start(), session = try XCTUnwrap(rig.accepted)
            rig.send(.stopRequested)
            if case .failure(let failure) = result { rig.send(.resultUnavailable(session, failure)) }
            expectEqual(await rig.broker.stop(sessionID: start.sessionID), .failure(expected))
            XCTAssertTrue(rig.history.isEmpty); XCTAssertNil(rig.results.read())
        }
        let rig = AutomationRig(); rig.register(); let start = try await rig.start(); let s = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); rig.complete(s, raw: nil)
        expectEqual(await rig.broker.stop(sessionID: start.sessionID), .failure(.unavailable))
    }
    @MainActor func testCancelAtQueueAcquisitionMainAndPublicationCannotOutputOrOverlap() async throws {
        for boundary in 0..<4 {
            let rig = AutomationRig(); rig.register(); let start = try await rig.start(), session = try XCTUnwrap(rig.accepted)
            rig.send(.stopRequested)
            let gate = AutomationWorkGate()
            let previous = boundary == 0 ? Task { await gate.hold() } : nil
            if boundary == 0 { await fulfillment(of: [gate.entered], timeout: 2) }
            let task = rig.run(session, previous: previous, acquisition: boundary == 1 ? gate : nil,
                               beforeMain: boundary == 2 ? gate : nil, beforePublication: boundary == 3 ? gate : nil)
            if boundary != 0 { await fulfillment(of: [gate.entered], timeout: 2) }
            XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.canceled))
            expectEqual(await rig.broker.stop(sessionID: start.sessionID), .failure(.canceled))
            await gate.release(); await task.value
            XCTAssertTrue(rig.history.isEmpty); XCTAssertTrue(rig.insertions.isEmpty); XCTAssertNil(rig.results.read())
            XCTAssertTrue(session.operation.hasExited)
        }
    }
    @MainActor func testNoncooperativeNativeAndProviderKeepActualExitBarrierAfterImmediateCancel() async throws {
        for native in [true, false] {
            let rig = AutomationRig(); rig.settings.outputMode = .cleanup; rig.settings.cleanupEnabled = true; rig.register()
            let start = try await rig.start(), session = try XCTUnwrap(rig.accepted); rig.send(.stopRequested)
            let client = AutomationRecognition(), provider = AutomationProvider()
            client.held = native; provider.held = !native; provider.failing = !native
            provider.revoked = { session.operation.shouldAbort }
            let task = rig.run(session, client: client, provider: provider)
            await fulfillment(of: [native ? client.entered : provider.entered], timeout: 2)
            XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.canceled))
            expectEqual(await rig.broker.stop(sessionID: start.sessionID), .failure(.canceled))
            if native { XCTAssertTrue(client.abortRequested) } else { await fulfillment(of: [provider.canceled], timeout: 2) }
            rig.keyboard(); let newer = try XCTUnwrap(rig.accepted)
            rig.send(.stopRequested); let nextClient = AutomationRecognition()
            let next = rig.run(newer, client: nextClient, previous: task)
            XCTAssertEqual(nextClient.calls, 0); XCTAssertFalse(session.operation.hasExited)
            if native { client.exit.signal() } else { provider.complete() }
            await next.value
            XCTAssertTrue(session.operation.hasExited); XCTAssertEqual(nextClient.calls, 1)
            XCTAssertEqual(rig.history, ["Clean final text."]); XCTAssertEqual(rig.insertions, ["Clean final text."])
        }
    }
    @MainActor func testClearEpochWhileHeldDoesNotCancelNormalKeyboardOrIndependentWork() async throws {
        let rig = AutomationRig(); rig.register(); rig.keyboard(); let session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested)
        let gate = AutomationWorkGate(), independent = PendingOperation(name: "independent retry", diagnostics: nil)
        let task = rig.run(session, beforePublication: gate)
        await fulfillment(of: [gate.entered], timeout: 2)
        var cleared = false
        HistoryClearAction.run(invalidateResult: { rig.host.clearResult() }, clearHistory: { cleared = true })
        await gate.release(); await task.value
        XCTAssertFalse(session.operation.shouldAbort)
        XCTAssertTrue(cleared); XCTAssertNil(rig.results.read()); XCTAssertFalse(independent.shouldAbort)
        let nextGate = AutomationWorkGate()
        let automated = try await rig.start(), current = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); let held = rig.run(current, beforePublication: nextGate)
        await fulfillment(of: [nextGate.entered], timeout: 2)
        rig.host.clearResult(); await nextGate.release(); await held.value
        expectEqual(await rig.broker.stop(sessionID: automated.sessionID), .failure(.unavailable))
        XCTAssertFalse(current.operation.shouldAbort); XCTAssertFalse(independent.shouldAbort)
        XCTAssertEqual(rig.history.count, 2)
    }
    @MainActor func testRAMAbsoluteTTLUTF8LimitClearDisableQuitAndTextFreeTombstones() async throws {
        let rig = AutomationRig(); rig.register()
        let first = try await rig.start(), session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); rig.complete(session, text: String(repeating: "é", count: 32768))
        XCTAssertEqual(try rig.broker.getLast().get().text.utf8.count, 65536)
        rig.clock.advance(299); _ = try rig.broker.getLast().get(); rig.clock.advance(1)
        XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable))
        expectEqual(await rig.broker.stop(sessionID: first.sessionID), .failure(.staleSession))
        let oversize = try await rig.start(), second = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); rig.complete(second, text: String(repeating: "é", count: 32769))
        expectEqual(await rig.broker.stop(sessionID: oversize.sessionID), .failure(.resultLimit))
        XCTAssertNil(rig.results.read())
        for _ in 0..<20 { let start = try await rig.start(); XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.canceled)) }
        XCTAssertEqual(rig.broker.terminalCount, 16); XCTAssertEqual(rig.broker.waiterCount, 0)
        rig.clock.advance(60); XCTAssertEqual(rig.broker.terminalCount, 0)
        rig.broker.configurationChanged(enabled: false); XCTAssertEqual(rig.broker.getLast(), .failure(.disabled))
        rig.broker.quit(); XCTAssertEqual(rig.broker.getLast(), .failure(.shuttingDown)); XCTAssertEqual(rig.clock.count, 0)
    }
    @MainActor func testCancelBetweenReducerEffectsRevokesPublicationHistoryAndReturnedText() async throws {
        let rig = AutomationRig(); rig.register(); let start = try await rig.start(); let session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested)
        rig.beforeEffect = { effect in
            if case .finalResult = effect {
                rig.beforeEffect = nil
                XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.canceled))
            }
        }
        rig.complete(session, text: "NEVER-PUBLISHED-CANARY")
        expectEqual(await rig.broker.stop(sessionID: start.sessionID), .failure(.canceled))
        XCTAssertTrue(rig.history.isEmpty); XCTAssertNil(rig.results.read())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(rig.diagnostic.snapshot()), as: UTF8.self).contains("NEVER-PUBLISHED-CANARY"))
    }
    @MainActor func testClearDisableAndCancellationAfterResumeBeforeReturnCannotExposeText() async throws {
        for action in 0..<3 {
            let rig = AutomationRig(); rig.register(); let start = try await rig.start(), session = try XCTUnwrap(rig.accepted)
            let scheduled = expectation(description: "stop registered")
            rig.clock.scheduled = { scheduled.fulfill() }
            let stop = Task { await rig.broker.stop(sessionID: start.sessionID) }
            await fulfillment(of: [scheduled], timeout: 2); rig.clock.scheduled = nil
            rig.complete(session, text: "held between completion and return")
            if action == 0 { rig.host.clearResult() }
            else if action == 1 { rig.broker.configurationChanged(enabled: false) }
            else { stop.cancel() }
            let expected: AutomationFailure = action == 0 ? .unavailable : action == 1 ? .disabled : .canceled
            expectEqual(await stop.value, .failure(expected))
            XCTAssertEqual(rig.broker.waiterCount, 0)
        }
    }
    @MainActor func testCaptureCancelBeforeAckAndMenuPendingDiscardSettleImmediately() async throws {
        let rig = AutomationRig(), captured = expectation(description: "requested capture")
        rig.acknowledge = false; rig.captureObserved = { captured.fulfill() }; rig.register()
        let start = Task { await rig.broker.start(requestID: rig.request()) }
        await fulfillment(of: [captured], timeout: 2)
        let id = try XCTUnwrap(rig.broker.reservedSessionID), session = try XCTUnwrap(rig.accepted)
        start.cancel(); expectEqual(await start.value, .failure(.canceled))
        rig.send(.recorderStarted(gen: session.gen)); XCTAssertFalse(rig.machine.isCapturing)
        XCTAssertEqual(rig.broker.cancel(sessionID: id), .success(.alreadyCanceled))
        rig.acknowledge = true; rig.captureObserved = nil
        let next = try await rig.start(), pending = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested)
        let gate = AutomationWorkGate(), task = rig.run(pending, acquisition: gate)
        await fulfillment(of: [gate.entered], timeout: 2)
        rig.send(.discardPending(token: pending.operation.id))
        expectEqual(await rig.broker.stop(sessionID: next.sessionID), .failure(.canceled))
        XCTAssertTrue(pending.operation.shouldAbort); XCTAssertFalse(pending.operation.hasExited)
        await gate.release(); await task.value
        XCTAssertNil(rig.results.read()); XCTAssertTrue(rig.history.isEmpty)
    }
    @MainActor func testFrozenGlobalRequestAndDuplicateFinalCallbacksDoNotRepeatHistoryOrResults() async throws {
        let rig = AutomationRig(); rig.settings.outputMode = .cleanup; rig.register()
        let start = try await rig.start(), session = try XCTUnwrap(rig.accepted)
        rig.settings.whisperModelPath = "/inert/different-model.bin"; rig.settings.language = "hi"
        rig.settings.outputMode = .selectedPreset; rig.settings.replacements = [.init(source: "raw", replacement: "changed")]
        XCTAssertEqual(session.recognition.modelPath, "/inert/verified-model.bin"); XCTAssertNil(session.recognition.language)
        rig.send(.stopRequested); let task = rig.run(session); await task.value
        let original = try await rig.broker.stop(sessionID: start.sessionID).get()
        XCTAssertEqual(original.text, "raw dictated text")
        let count = rig.effects.count
        rig.complete(session, text: "duplicate callback")
        XCTAssertEqual(rig.effects.count, count); XCTAssertEqual(rig.history, [original.text])
        XCTAssertEqual(try rig.broker.getLast().get(), original)
        XCTAssertEqual(rig.broker.cancel(sessionID: start.sessionID), .success(.alreadyCompleted))
        XCTAssertEqual(rig.broker.getLast(), .failure(.unavailable))
    }
    @MainActor func testResultIndependentOfRealHistoryPersistenceFailureWithoutHubOrLiveStores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wave3d1-automation-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        try settings.save(Settings())
        let history = HistoryStore(url: directory.appendingPathComponent("history.json"), persistence: .init(writeAtomically: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        let sink = HistoryPersistenceSink(history: history, settings: settings)
        let rig = AutomationRig(); rig.register(); let start = try await rig.start(), session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); rig.complete(session, text: "eligible despite failed disk")
        sink.beginEvent()
        for effect in rig.effects { _ = sink.record(effect) }
        XCTAssertNotNil(history.lastError); XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(history.pendingEntries.count, 1)
        expectEqual(try await rig.broker.stop(sessionID: start.sessionID).get().text, "eligible despite failed disk")
    }
    func testAutomationSettingDefaultsOffAndRoundTripsWithoutChangingHistoryPolicy() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.automationEnabled); XCTAssertTrue(old.historyEnabled)
        var settings = old; settings.automationEnabled = true
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testActualResultOnlyProviderFailureLogExcludesEchoedContent() async throws {
        struct EchoError: Error, CustomStringConvertible { var description: String { "PRIVATE-RAW-ERROR-CANARY" } }
        struct EchoProvider: CleanupProviding {
            func clean(transcript: String, context: CleanupContext) async throws -> String { throw EchoError() }
        }
        var settings = Settings(); settings.whisperModelPath = "/inert/model.bin"
        var logs: [String] = []
        let diagnostics = DiagnosticStore(), operation = PendingOperation(name: "Dictation", diagnostics: nil)
        operation.observe(in: diagnostics, origin: .dictation)
        var pipeline = Pipeline(outputSettings: settings, bundleID: nil, diagnostics: operation.diagnostics, failureLogging: .contentFree) { _ in EchoProvider() }
        pipeline.log = { logs.append($0) }
        let result = await pipeline.clean(transcript: "PRIVATE-RAW-ERROR-CANARY")
        XCTAssertEqual(result.text, "PRIVATE-RAW-ERROR-CANARY"); XCTAssertNotNil(result.failure)
        XCTAssertEqual(logs, ["Parla cleanup failed; using local fallback"])
        XCTAssertFalse(String(decoding: try diagnostics.snapshot().encoded(), as: UTF8.self).contains("PRIVATE-RAW-ERROR-CANARY"))
    }

}

// Native source entry points; all runtime/settings/capabilities and native work
// remain the inert real-broker rig above. No AppDelegate or live store is used.
extension AutomationTests {
    private func nativeValue<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
    @MainActor private func nativeFailure(_ expected: AutomationIntentError,
                                          _ action: () async throws -> Void,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected fixed failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationIntentError, expected, file: file, line: line) }
    }
    @MainActor func testNativeMetadataConstructorsAndSuggestionsDoNotResolveOrCapture() async throws {
        XCTAssertNil(AutomationIntentRuntime.resolver)
        let rig = AutomationRig()
        try await AutomationIntentRuntime.$resolver.withValue({ rig.resolutions += 1; return rig.runtime }) {
            _ = StartParlaDictationIntent(); _ = StopParlaDictationIntent()
            _ = CancelParlaDictationIntent(); _ = GetLastParlaResultIntent()
            XCTAssertEqual(ParlaAppShortcuts.appShortcuts.count, 4)
            XCTAssertEqual(StartParlaDictationIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
            XCTAssertEqual(StopParlaDictationIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
            XCTAssertEqual(CancelParlaDictationIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
            XCTAssertEqual(GetLastParlaResultIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
            XCTAssertTrue(StartParlaDictationIntent.openAppWhenRun && StopParlaDictationIntent.openAppWhenRun)
            XCTAssertTrue(CancelParlaDictationIntent.openAppWhenRun && GetLastParlaResultIntent.openAppWhenRun)
            let suggestions = try await ParlaAutomationResultQuery().suggestedEntities()
            let invalid = try await ParlaAutomationResultQuery().entities(for: ["", "not an ID"])
            let empty = try await ParlaAutomationResultQuery().entities(for: [])
            XCTAssertTrue(suggestions.isEmpty && invalid.isEmpty && empty.isEmpty)
            XCTAssertEqual(rig.resolutions, 0); XCTAssertEqual(rig.captures, 0)
        }
        XCTAssertNil(AutomationIntentRuntime.resolver)
    }
    @MainActor func testNativeActualPerformDuplicateStartStopAndExplicitEntityQuery() async throws {
        let rig = AutomationRig(); rig.register(); rig.settings.historyEnabled = false; rig.ax = false
        try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
            let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
            let repeated = try await StartParlaDictationIntent().perform().value
            XCTAssertEqual(repeated, control); XCTAssertEqual(rig.captures, 1)
            let session = try XCTUnwrap(rig.accepted)
            XCTAssertEqual(try AutomationIntentID.controlSession(control).id, rig.broker.reservedSessionID?.id)
            let stopping = expectation(description: "actual stop effect")
            rig.clock.scheduled = { stopping.fulfill() }
            let stop = Task { try await StopParlaDictationIntent(controlSession: control).perform().value }
            await fulfillment(of: [stopping], timeout: 2); rig.clock.scheduled = nil
            rig.complete(session, raw: "final\n日本語", text: "final\n日本語")
            let result = try nativeValue(try await stop.value)
            XCTAssertEqual(result.text, "final\n日本語"); XCTAssertEqual(result.outcome, "final")
            XCTAssertNotEqual(control, result.id)
            XCTAssertEqual(result.id, AutomationIntentID.result(process: rig.broker.process, operation: session.operation.id))
            let duplicate = try await StopParlaDictationIntent(controlSession: control).perform().value
            let last = try await GetLastParlaResultIntent().perform().value
            XCTAssertEqual(duplicate?.text, result.text); XCTAssertEqual(last?.id, result.id)
            XCTAssertEqual(rig.stops, 1); XCTAssertEqual(rig.finalizations, 1)
            let query = ParlaAutomationResultQuery()
            let resolved = try await query.entities(for: [result.id, result.id])
            XCTAssertEqual(resolved.map(\.text), [result.text])
            let unrequested = try await query.entities(for: [AutomationIntentID.result(process: rig.broker.process, operation: UUID())])
            XCTAssertTrue(unrequested.isEmpty)
            XCTAssertTrue(rig.history.isEmpty && rig.insertions.isEmpty)
            _ = try await StartParlaDictationIntent().perform()
            XCTAssertEqual(rig.captures, 2)
            await nativeFailure(.refused(.unavailable)) { _ = try await StopParlaDictationIntent(controlSession: control).perform() }
            expectEqual(try await CancelParlaDictationIntent(controlSession: control).perform().value, "Already completed")
            XCTAssertEqual(rig.captures, 2); XCTAssertFalse(try XCTUnwrap(rig.accepted).operation.shouldAbort)
            _ = try await CancelParlaDictationIntent(controlSession: AutomationIntentID.control(try XCTUnwrap(rig.broker.reservedSessionID))).perform()
        }
        XCTAssertNil(AutomationIntentRuntime.resolver)
    }
    @MainActor func testNativeCancelDuplicatesStrictCodecAndOldHandleCannotTouchKeyboard() async throws {
        let rig = AutomationRig(); rig.register()
        try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
            let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
            let malformed = ["", control + ":extra", control.uppercased(), control.replacingOccurrences(of: ":1:", with: ":2:"),
                             control.replacingOccurrences(of: ":1:", with: ":01:"), ":1::", String(repeating: "x", count: 4096),
                             control.replacingOccurrences(of: "parla-control", with: "parla-result"), String(control.dropLast())]
            for value in malformed {
                await nativeFailure(.invalidSession) { _ = try await StopParlaDictationIntent(controlSession: value).perform() }
                await nativeFailure(.invalidSession) { _ = try await CancelParlaDictationIntent(controlSession: value).perform() }
            }
            XCTAssertEqual(rig.stops, 0); XCTAssertTrue(rig.abortions.isEmpty)
            let foreign = AutomationIntentID.control(.init(process: UUID(), id: UUID()))
            let unknown = AutomationIntentID.control(.init(process: rig.broker.process, id: UUID()))
            for value in [foreign, unknown] {
                await nativeFailure(.refused(.staleSession)) { _ = try await StopParlaDictationIntent(controlSession: value).perform() }
                await nativeFailure(.refused(.staleSession)) { _ = try await CancelParlaDictationIntent(controlSession: value).perform() }
            }
            expectEqual(try await CancelParlaDictationIntent(controlSession: control).perform().value, "Canceled")
            expectEqual(try await CancelParlaDictationIntent(controlSession: control).perform().value, "Already canceled")
            XCTAssertEqual(rig.abortions.count, 1)
            rig.keyboard(); let keyboard = try XCTUnwrap(rig.accepted), generation = rig.machine.gen
            await nativeFailure(.refused(.canceled)) { _ = try await StopParlaDictationIntent(controlSession: control).perform() }
            _ = try await CancelParlaDictationIntent(controlSession: control).perform()
            XCTAssertEqual(rig.machine.gen, generation); XCTAssertFalse(keyboard.operation.shouldAbort)
            XCTAssertEqual(rig.captures, 2); XCTAssertEqual(rig.abortions.count, 1)
            rig.send(.cancelRequested(silent: true))
        }
    }
    @MainActor func testNativeDisabledBusyCapabilityAndRecorderFailuresAreFixed() async throws {
        let disabled = AutomationRig(); disabled.settings.automationEnabled = false
        await AutomationIntentRuntime.$resolver.withValue({ disabled.runtime }) {
            await nativeFailure(.refused(.disabled)) { _ = try await StartParlaDictationIntent().perform() }
            await nativeFailure(.refused(.disabled)) { _ = try await GetLastParlaResultIntent().perform() }
            let id = AutomationIntentID.control(.init(process: disabled.broker.process, id: UUID()))
            await nativeFailure(.refused(.disabled)) { _ = try await StopParlaDictationIntent(controlSession: id).perform() }
            await nativeFailure(.refused(.disabled)) { _ = try await CancelParlaDictationIntent(controlSession: id).perform() }
        }
        XCTAssertEqual(disabled.captures, 0); XCTAssertTrue(disabled.effects.isEmpty)
        for failure in [AutomationFailure.microphoneUnavailable, .modelUnavailable, .secure, .busy, .unsupportedOutputMode, .unavailable] {
            let rig = AutomationRig(); rig.register()
            if failure == .secure { rig.secure = true }
            else if failure == .busy { rig.keyboard() }
            else if failure == .unsupportedOutputMode { rig.settings.outputMode = .selectedPreset }
            else if failure == .unavailable { rig.recorderFails = true }
            else { rig.capabilityFailure = failure }
            await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
                await nativeFailure(.refused(failure)) { _ = try await StartParlaDictationIntent().perform() }
            }
            XCTAssertEqual(rig.entries, failure == .busy || failure == .unavailable ? 1 : 0)
            if failure == .busy { rig.send(.cancelRequested(silent: true)) }
        }
        XCTAssertEqual(AutomationIntentError.invalidSession.errorDescription, "Parla automation: invalid session.")
        XCTAssertEqual(AutomationIntentError.refused(.secure).errorDescription, "Parla automation: secure.")
    }
    @MainActor func testNativeAbsentAndLateHostReadinessAndActiveWaitingJoin() async throws {
        for late in [false, true] {
            let rig = AutomationRig(), waiting = expectation(description: "native readiness")
            rig.clock.scheduled = { waiting.fulfill() }
            try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
                await nativeFailure(.refused(.unavailable)) { _ = try await GetLastParlaResultIntent().perform() }
                let first = Task { try await StartParlaDictationIntent().perform().value }
                await fulfillment(of: [waiting], timeout: 2); rig.clock.scheduled = nil
                if late {
                    let second = Task { try await StartParlaDictationIntent().perform().value }
                    rig.register()
                    let a = try await first.value, b = try await second.value
                    XCTAssertEqual(a, b); XCTAssertEqual(rig.captures, 1)
                    _ = try await CancelParlaDictationIntent(controlSession: try XCTUnwrap(a)).perform()
                } else {
                    rig.clock.advance(5)
                    await nativeFailure(.refused(.timeout)) { _ = try await first.value }
                    rig.register(); XCTAssertEqual(rig.captures, 0)
                }
                XCTAssertEqual(rig.broker.waiterCount, 0)
            }
        }
    }
    @MainActor func testNativeFinalEligibilityClearDisableSecureExpiryAndNoOldEntity() async throws {
        for invalidation in ["clear", "disable", "secure", "expiry", "new", "history-clear"] {
            let rig = AutomationRig(); rig.register()
            try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
                let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
                let session = try XCTUnwrap(rig.accepted); rig.send(.stopRequested); rig.complete(session, raw: "eligible", text: "eligible")
                let entity = try nativeValue(try await GetLastParlaResultIntent().perform().value)
                switch invalidation {
                case "disable": rig.settings.automationEnabled = false; rig.broker.configurationChanged(enabled: false)
                case "secure": rig.secure = true
                case "expiry": rig.clock.advance(300)
                case "new": _ = try await StartParlaDictationIntent().perform()
                default: rig.host.clearResult()
                }
                let queried = try await ParlaAutomationResultQuery().entities(for: [entity.id])
                XCTAssertTrue(queried.isEmpty)
                let expected: AutomationFailure = invalidation == "disable" ? .disabled : invalidation == "secure" ? .secure : .unavailable
                await nativeFailure(.refused(expected)) { _ = try await GetLastParlaResultIntent().perform() }
                // Stop's terminal map may prune at 60s, before the RAM lifetime.
                let stopExpected: AutomationFailure = invalidation == "expiry" ? .staleSession : expected
                await nativeFailure(.refused(stopExpected)) { _ = try await StopParlaDictationIntent(controlSession: control).perform() }
                if let id = rig.broker.reservedSessionID { _ = rig.broker.cancel(sessionID: id) }
                XCTAssertEqual(entity.text, "eligible", "already returned caller text cannot be revoked")
            }
        }
    }
    @MainActor func testNativeActualPipelineFinalOutcomeHistoryOffAndFailures() async throws {
        for mode in 0..<5 {
            let rig = AutomationRig(); rig.settings.historyEnabled = false
            rig.settings.outputMode = mode == 0 ? .raw : .cleanup
            rig.settings.cleanupEnabled = mode == 1 || mode == 3
            if mode == 2 || mode == 3 { rig.settings.replacements = [.init(source: "raw", replacement: "local")] }
            if mode == 4 { rig.settings.snippets = ["raw dictated text": "literal locked"] }
            rig.register()
            try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
                let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
                let session = try XCTUnwrap(rig.accepted); rig.send(.stopRequested)
                let provider = AutomationProvider(); provider.failing = mode == 3
                await rig.run(session, provider: provider).value
                let result = try nativeValue(try await StopParlaDictationIntent(controlSession: control).perform().value)
                XCTAssertEqual(result.text, ["raw dictated text", "Clean final text.", "local dictated text", "local dictated text", "literal locked"][mode])
                XCTAssertEqual(result.outcome, mode == 3 ? "localFallback" : "final")
                XCTAssertTrue(rig.history.isEmpty && rig.insertions.isEmpty)
            }
        }
        for raw in [Optional<String>.none, "", String(repeating: "é", count: 32769)] {
            let rig = AutomationRig(); rig.register()
            try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
                let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
                rig.send(.stopRequested); rig.complete(try XCTUnwrap(rig.accepted), raw: raw, text: raw ?? "")
                let failure: AutomationFailure = raw == nil ? .unavailable : raw == "" ? .empty : .resultLimit
                await nativeFailure(.refused(failure)) { _ = try await StopParlaDictationIntent(controlSession: control).perform() }
                await nativeFailure(.refused(.unavailable)) { _ = try await GetLastParlaResultIntent().perform() }
            }
        }
    }
    @MainActor func testNativeCancellationAndClearAfterStopResumeNeverReturnStaleText() async throws {
        for invalidation in ["clear", "cancel", "secure", "disable"] {
            let rig = AutomationRig(); rig.register()
            try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
                let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
                let stopping = expectation(description: "stop wait installed")
                rig.clock.scheduled = { stopping.fulfill() }
                let stop = Task { try await StopParlaDictationIntent(controlSession: control).perform().value }
                await fulfillment(of: [stopping], timeout: 2); rig.clock.scheduled = nil
                rig.complete(try XCTUnwrap(rig.accepted), raw: "must not return")
                switch invalidation {
                case "cancel": stop.cancel()
                case "secure": rig.secure = true
                case "disable": rig.settings.automationEnabled = false; rig.broker.configurationChanged(enabled: false)
                default: rig.host.clearResult()
                }
                let expected: AutomationFailure = invalidation == "cancel" ? .canceled : invalidation == "secure" ? .secure : invalidation == "disable" ? .disabled : .unavailable
                await nativeFailure(.refused(expected)) { _ = try await stop.value }
                XCTAssertEqual(rig.broker.waiterCount, 0)
            }
        }
        let rig = AutomationRig(), waiting = expectation(description: "cancel readiness")
        rig.clock.scheduled = { waiting.fulfill() }
        await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
            let start = Task { try await StartParlaDictationIntent().perform() }
            await fulfillment(of: [waiting], timeout: 2); rig.clock.scheduled = nil; start.cancel()
            await nativeFailure(.refused(.canceled)) { _ = try await start.value }
            rig.register(); XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.broker.waiterCount, 0)
        }
    }
}

extension AutomationTests {
    @MainActor func testNativeOverlappingStopsJoinAndCancellationRevokesPendingWork() async throws {
        let rig = AutomationRig(); rig.register()
        try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
            let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
            let waiting = expectation(description: "native stop completion deadline")
            rig.clock.scheduled = { waiting.fulfill() }
            let first = Task { try await StopParlaDictationIntent(controlSession: control).perform().value }
            await fulfillment(of: [waiting], timeout: 2); rig.clock.scheduled = nil
            let joinedStart = try await StartParlaDictationIntent().perform().value
            XCTAssertEqual(joinedStart, control); XCTAssertEqual(rig.captures, 1)
            let second = Task { try await StopParlaDictationIntent(controlSession: control).perform().value }
            for _ in 0..<100 where rig.broker.waiterCount < 2 { await Task.yield() }
            XCTAssertEqual(rig.broker.waiterCount, 2); XCTAssertEqual(rig.stops, 1)
            let session = try XCTUnwrap(rig.accepted)
            first.cancel()
            await nativeFailure(.refused(.canceled)) { _ = try await first.value }
            await nativeFailure(.refused(.canceled)) { _ = try await second.value }
            XCTAssertTrue(session.operation.shouldAbort); XCTAssertEqual(rig.abortions, [session.operation.id])
            rig.complete(session, raw: "late forbidden", text: "late forbidden")
            await nativeFailure(.refused(.unavailable)) { _ = try await GetLastParlaResultIntent().perform() }
            XCTAssertEqual(rig.broker.waiterCount, 0); XCTAssertEqual(rig.captures, 1)
        }
    }
    @MainActor func testNativeExplicitTerminalFailureAndTaskCancellationAtAllActions() async throws {
        let rig = AutomationRig(); rig.register()
        try await AutomationIntentRuntime.$resolver.withValue({ rig.runtime }) {
            let control = try nativeValue(try await StartParlaDictationIntent().perform().value)
            let session = try XCTUnwrap(rig.accepted); rig.send(.stopRequested)
            rig.send(.resultUnavailable(session, .minimumDuration))
            await nativeFailure(.refused(.minimumDuration)) { _ = try await StopParlaDictationIntent(controlSession: control).perform() }
            let next = try nativeValue(try await StartParlaDictationIntent().perform().value)
            let cancel = Task { try await CancelParlaDictationIntent(controlSession: next).perform() }
            cancel.cancel()
            await nativeFailure(.refused(.canceled)) { _ = try await cancel.value }
            XCTAssertEqual(rig.abortions.count, 0, "a canceled adapter must not execute Cancel")
            let last = Task { try await GetLastParlaResultIntent().perform() }
            last.cancel()
            await nativeFailure(.refused(.canceled)) { _ = try await last.value }
            let query = Task { try await ParlaAutomationResultQuery().entities(for: [AutomationIntentID.result(process: rig.broker.process, operation: session.operation.id)]) }
            query.cancel()
            let values = try await query.value; XCTAssertTrue(values.isEmpty)
            _ = try await CancelParlaDictationIntent(controlSession: next).perform()
        }
    }
}

extension AutomationTests {
    @MainActor func testSafeStartCachedPreflightAndAuthoritativeLateRefusalResolveAllWaiters() async throws {
        let p = try PreparationAppRig(), r = AutomationRig()
        r.settings = p.store.load(); r.settings.automationEnabled = true
        r.register()
        p.owner.core.revokeDraft()
        r.capabilityFailure = p.owner.cachedRefusal(for: RecognitionRequest(settings: r.settings)) == nil ? nil : .modelUnavailable
        expectEqual(await r.broker.start(requestID: r.request()), .failure(.modelUnavailable))
        XCTAssertEqual(r.captures, 0); XCTAssertEqual(r.entries, 0)
        r.capabilityFailure = nil // a cached-ready race; factory remains authoritative after queue wait
        let start = try await r.start(), session = try XCTUnwrap(r.accepted)
        let scheduled = expectation(description: "stop waiter registered")
        r.clock.scheduled = { scheduled.fulfill() }
        let stop = Task { await r.broker.stop(sessionID: start.sessionID) }
        await fulfillment(of: [scheduled], timeout: 2); r.clock.scheduled = nil
        do { _ = try await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: p.factory, operation: session.operation); XCTFail() }
        catch { r.send(.legUnavailable(session, message: (error as? PreparationRefusal)?.description ?? "unavailable")) }
        r.send(.operationFinished(session.operation))
        expectEqual(await stop.value, .failure(.unavailable))
        XCTAssertEqual(r.broker.waiterCount, 0); XCTAssertNil(r.results.read())
        XCTAssertTrue(r.history.isEmpty); XCTAssertTrue(r.insertions.isEmpty); XCTAssertTrue(p.probe.paths.isEmpty)
        try await p.close()
    }
}


extension AutomationTests {
    @MainActor func testPassiveBootstrapReconcilesPreparedAppleAutomationAfterRelaunchWithoutHub() async throws {
        let apple = AppleOwnerRig(), rig = AutomationRig(), native = AppleOriginSession()
        apple.memory.data = try AppleSpeechReservationRecord(entries: [.init(locale: "en-US", state: .owned, prepared: true)]).encoded()
        apple.reserved = ["en-US"]
        rig.settings.recognitionEngine = .appleSpeech; rig.settings.appleSpeechLocale = "en-US"
        rig.foundationFactory = apple.factory(native)
        rig.recognitionCapability = { request in apple.owner.cachedRefusal(for: request, deliberate: true) == nil ? nil : .modelUnavailable }
        var reconciliations = 0
        let startup = ApplicationStartupCoordinator(configure: {}, reconcileSpeech: {
            reconciliations += 1; apple.owner.configure(rig.settings)
        }, register: { rig.register() }, services: {}, migrate: { XCTFail("Passive bootstrap must not migrate") },
            setup: { XCTFail("Passive bootstrap must not prepare or infer") }, warmMic: { XCTFail("Passive bootstrap must not open the mic") })
        startup.bootstrap(); startup.bootstrap(); await apple.wait()
        XCTAssertEqual(reconciliations, 1)
        XCTAssertNil(apple.owner.cachedRefusal(for: RecognitionRequest(settings: rig.settings)))
        XCTAssertEqual(apple.reserves + apple.requests + apple.releases + native.calls, 0)
        let started = try await rig.start(), session = try XCTUnwrap(rig.accepted)
        rig.send(.stopRequested); await rig.run(session).value
        let result = try await rig.broker.stop(sessionID: started.sessionID).get()
        XCTAssertEqual(result.text, "spoken original"); XCTAssertTrue(rig.insertions.isEmpty)
        XCTAssertEqual(apple.reserves + apple.requests + apple.releases, 0)
    }
    @MainActor func testResultOnlyAutomationActualAppleFactoryPreparedOwnerNeverInsertsOrInstalls() async throws {
        let apple = AppleOwnerRig(); apple.configure(); await apple.wait(); await apple.prepare()
        let native = AppleOriginSession(), rig = AutomationRig()
        rig.settings.recognitionEngine = .appleSpeech; rig.settings.appleSpeechLocale = "en-US"
        rig.foundationFactory = apple.factory(native); rig.register()
        let mutations = apple.requests + apple.reserves
        let started = try await rig.start(), session = try XCTUnwrap(rig.accepted)
        XCTAssertEqual(session.recognition.selection, .appleSpeech(locale: "en-US"))
        rig.send(.stopRequested); await rig.run(session).value
        let result = try await rig.broker.stop(sessionID: started.sessionID).get()
        XCTAssertEqual(result.text, "spoken original"); XCTAssertTrue(rig.insertions.isEmpty)
        XCTAssertEqual(rig.results.read()?.text, "spoken original"); XCTAssertEqual(native.calls, 1)
        XCTAssertEqual(apple.requests + apple.reserves, mutations)
    }
}
