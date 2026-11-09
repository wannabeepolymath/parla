import XCTest
@testable import ParlaCore

private actor WorkGate {
    let entered = XCTestExpectation(description: "gate entered")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class HeldRecognition: RecognitionClient, @unchecked Sendable {
    let entered = XCTestExpectation(description: "native entered")
    let exit = RecognitionTestLatch()
    private let lock = NSLock()
    private var abort: (() -> Bool)?
    var held = false
    var onCall: (() -> Void)?
    private(set) var calls = 0
    var abortRequested: Bool { lock.withLock { abort?() == true } }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        lock.withLock { calls += 1; abort = shouldAbort }
        onCall?()
        if held { entered.fulfill(); await exit.wait() }
        return "original speech" // deliberately ignores abort, like a late native callback
    }
}

private final class HeldCleanup: CleanupProviding, @unchecked Sendable {
    let entered = XCTestExpectation(description: "cleanup entered")
    let cancelled = XCTestExpectation(description: "cleanup abort requested")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    var observedRevoke: () -> Bool = { false }
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }; entered.fulfill()
            }
        }, onCancel: {
            XCTAssertTrue(self.observedRevoke(), "authority must be revoked before request cancellation")
            self.cancelled.fulfill()
        })
    }
    func complete(failing: Bool) {
        let held = lock.withLock { let held = continuation; continuation = nil; return held }
        if failing { held?.resume(throwing: CancellationError()) } else { held?.resume(returning: "cleaned speech") }
    }
}

/// Fake recorder/effect sinks around the actual reducer + production queue +
/// finalization interpreter. No AppDelegate, AX, clipboard, model or live stores.
@MainActor private final class DictationRig {
    let machine = DictationSession()
    var samples = (0..<8000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    var effects: [DictationSession.Effect] = []
    var inserted: [String] = []
    var history: [String] = []
    var disposal: [UUID] = []
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var beforeEffect: ((DictationSession.Effect) -> Void)?
    var disposalFails = false
    var stashes = 0
    var acquisitions = 0

    func send(_ event: DictationSession.Event) {
        machine.send(event) { effect in
            beforeEffect?(effect)
            if machine.effectOperation?.shouldAbort == true { return }
            effects.append(effect)
            switch effect {
            case .applyPreferencesAndStartCapture:
                send(.recorderStarted(gen: machine.gen))
            case .sampleFocus(let gen): send(.focusSampled(gen: gen, focus: .editable))
            case .stopCapture(let discard): if discard { samples = [] }
            case .abortOperation(let op):
                XCTAssertTrue(op.shouldAbort); disposal.append(op.id)
                if disposalFails { send(.operationDisposalFailed(op, message: "Audio deletion failed; file remains")) }
                op.requestAbort()
            case .polish(let s, let landed): pending = (s, landed)
            case .insertText(let text, _, _): if machine.effectOperation?.authorizeDispatch() != false { inserted.append(text) }
            case .appendHistory(let raw, _, _), .appendTransformHistory(let raw, _, _, _, _): history.append(raw)
            default: break
            }
        }
    }
    func start(cleanup: Bool = true) -> DictationSession.Session {
        var settings = Settings(); settings.cleanupEnabled = cleanup; settings.whisperModelPath = "/fake/model.bin"
        send(.startDictation(settings: settings, cleanupConfigured: cleanup, live: false))
        guard case .recording(let s) = machine.state else { fatalError("fake recorder did not start") }
        return s
    }
    func stop() { send(.stopRequested) }
    func discard(_ s: DictationSession.Session) { send(.discardPending(token: s.operation.id)) }
    func run(_ s: DictationSession.Session, client: RecognitionClient, previous: Task<Void, Never>? = nil,
             acquisition: WorkGate? = nil, window: StreamWindow? = nil, cleanup: CleanupProviding? = nil,
             beforeDelivery: WorkGate? = nil) -> Task<Void, Never> {
        let captured = samples
        return PendingOperationQueue.enqueue(previous: previous, operation: s.operation, completes: true, work: {
            let handle = try! RecognitionHandle(request: s.recognition) { _ in client }
            let ownedWindow = window.map { handle.window(confirmedText: $0.confirmedText, cutSample: $0.cutSample) }
            await DictationProcessing.final(operation: s.operation, samples: captured, window: ownedWindow, prepare: {
                await MainActor.run { self.acquisitions += 1 }
                if let acquisition { await acquisition.wait() }
                guard !s.operation.shouldAbort else { return nil }
                await MainActor.run { self.stashes += 1 }
                return handle
            }, recognized: { _, raw in
                if let beforeDelivery { await beforeDelivery.wait() }
                return await MainActor.run {
                    self.send(.transcribed(s, raw: raw, probe: .init(focus: .editable, deferInsertionUntilClean: true)))
                    defer { self.pending = nil }
                    return self.pending
                }
            }, clean: { context in
                let (output, landed) = context
                let pipeline = Pipeline(outputSettings: output.effectiveSettings, bundleID: nil) { _ in cleanup! }
                return await pipeline.clean(transcript: landed.raw)
            }, completed: { context, text, failure in
                await MainActor.run { self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: .editable)) }
            })
        }, finished: { await MainActor.run { self.send(.operationFinished(s.operation)) } })
    }
}

final class PendingDictationTests: XCTestCase {
    @MainActor func testDiscardBeforeDequeueSkipsAcquisitionStashAndAllEffects() async {
        let rig = DictationRig(), client = HeldRecognition(), gate = WorkGate()
        let previous = Task { await gate.wait() }
        await fulfillment(of: [gate.entered], timeout: 2)
        let s = rig.start(); rig.stop()
        let task = rig.run(s, client: client, previous: previous)
        rig.discard(s); rig.discard(s)
        await gate.release(); await task.value
        XCTAssertEqual(rig.acquisitions, 0); XCTAssertEqual(rig.stashes, 0); XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(rig.disposal, [s.operation.id]); XCTAssertTrue(rig.inserted.isEmpty); XCTAssertTrue(rig.history.isEmpty)
        XCTAssertNil(rig.machine.pendingOperation); XCTAssertTrue(s.operation.hasExited)
    }

    @MainActor func testDiscardDuringAcquisitionThenNewCaptureRejectsOldCompletion() async {
        let rig = DictationRig(), gate = WorkGate(), client = HeldRecognition()
        let s = rig.start(); rig.stop()
        let task = rig.run(s, client: client, acquisition: gate)
        await fulfillment(of: [gate.entered], timeout: 2)
        rig.discard(s); let newer = rig.start()
        let count = rig.effects.count
        await gate.release(); await task.value
        XCTAssertEqual(rig.stashes, 0); XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(rig.effects.count, count); XCTAssertEqual(rig.machine.state, .recording(newer))
        XCTAssertTrue(rig.inserted.isEmpty); XCTAssertTrue(rig.history.isEmpty)
    }

    @MainActor private func discardHeldFinal(window: StreamWindow?) async {
        let rig = DictationRig(), client = HeldRecognition(); client.held = true
        let s = rig.start(cleanup: false); rig.stop()
        let task = rig.run(s, client: client, window: window)
        await fulfillment(of: [client.entered], timeout: 2)
        rig.discard(s)
        XCTAssertTrue(client.abortRequested)
        let newer = rig.start(cleanup: false); rig.stop()
        let nextClient = HeldRecognition()
        let next = rig.run(newer, client: nextClient, previous: task)
        let count = rig.effects.count
        XCTAssertEqual(nextClient.calls, 0, "barrier must wait for native exit")
        client.exit.signal(); await next.value
        XCTAssertTrue(s.operation.hasExited)
        XCTAssertEqual(rig.inserted, ["original speech"]); XCTAssertEqual(rig.history, ["original speech"])
        XCTAssertGreaterThan(rig.effects.count, count)
    }
    @MainActor func testDiscardFullFinalKeepsSerialNativeBarrier() async { await discardHeldFinal(window: nil) }
    @MainActor func testDiscardConfirmedWindowTailKeepsSerialNativeBarrier() async {
        await discardHeldFinal(window: StreamWindow(confirmedText: "confirmed", cutSample: 0))
    }
    @MainActor func testDiscardConfirmedOnlyResultBeforeMainDelivery() async {
        let rig = DictationRig(), gate = WorkGate(), client = HeldRecognition()
        let s = rig.start(cleanup: false); rig.stop()
        let task = rig.run(s, client: client, window: .init(confirmedText: "confirmed", cutSample: rig.samples.count), beforeDelivery: gate)
        await fulfillment(of: [gate.entered], timeout: 2)
        rig.discard(s); let newer = rig.start(); let count = rig.effects.count
        await gate.release(); await task.value
        XCTAssertEqual(client.calls, 0); XCTAssertTrue(rig.inserted.isEmpty); XCTAssertTrue(rig.history.isEmpty)
        XCTAssertEqual(rig.effects.count, count); XCTAssertEqual(rig.machine.state, .recording(newer))
    }
    @MainActor private func discardHeldCleanup(failing: Bool) async {
        let rig = DictationRig(), client = HeldRecognition(), cleanup = HeldCleanup()
        let s = rig.start(); rig.stop(); cleanup.observedRevoke = { s.operation.shouldAbort }
        let task = rig.run(s, client: client, cleanup: cleanup)
        await fulfillment(of: [cleanup.entered], timeout: 2)
        rig.discard(s)
        await fulfillment(of: [cleanup.cancelled], timeout: 2)
        let newer = rig.start(); let count = rig.effects.count
        cleanup.complete(failing: failing); await task.value
        XCTAssertTrue(rig.inserted.isEmpty); XCTAssertTrue(rig.history.isEmpty)
        XCTAssertEqual(rig.effects.count, count); XCTAssertEqual(rig.machine.state, .recording(newer))
    }
    @MainActor func testDiscardCleanupSuccessCannotDeliver() async { await discardHeldCleanup(failing: false) }
    @MainActor func testDiscardCleanupCancellationFallbackCannotDeliver() async { await discardHeldCleanup(failing: true) }

    @MainActor func testOldRawStillLandsUnlessExplicitlyDiscardedAndIdleCancelStaysCaptureOnly() {
        let rig = DictationRig(); let old = rig.start(cleanup: false); rig.stop()
        rig.send(.cancelRequested(silent: false)); XCTAssertFalse(old.operation.shouldAbort)
        _ = rig.start(cleanup: false)
        rig.send(.transcribed(old, raw: "old raw", probe: .init(focus: .editable)))
        XCTAssertEqual(rig.inserted, ["old raw"]); XCTAssertEqual(rig.history, ["old raw"])
        rig.discard(old)
        XCTAssertTrue(rig.effects.contains(.hud(.done)))
        rig.send(.transcribed(old, raw: "late duplicate", probe: .init(focus: .editable)))
        XCTAssertEqual(rig.inserted, ["old raw"]); XCTAssertEqual(rig.history, ["old raw"])
    }
    @MainActor func testDiscardImmediatelyBeforeDispatchRejectsQueuedInsertionHistoryAndHUD() {
        let rig = DictationRig(); let s = rig.start(cleanup: false); rig.stop()
        rig.beforeEffect = { effect in
            if case .log = effect { rig.beforeEffect = nil; rig.discard(s) }
        }
        rig.send(.transcribed(s, raw: "never posted", probe: .init(focus: .editable)))
        XCTAssertTrue(rig.inserted.isEmpty); XCTAssertTrue(rig.history.isEmpty)
        XCTAssertFalse(rig.effects.contains(.hud(.done))); XCTAssertEqual(rig.disposal, [s.operation.id])
    }
    @MainActor func testTooLateDiscardDoesNotUndoDispatchedTextOrSavedHistory() {
        let rig = DictationRig(); let s = rig.start(cleanup: false); rig.stop()
        rig.send(.transcribed(s, raw: "posted", probe: .init(focus: .editable)))
        rig.discard(s); rig.discard(s)
        XCTAssertEqual(rig.inserted, ["posted"]); XCTAssertEqual(rig.history, ["posted"])
        XCTAssertEqual(rig.disposal, [s.operation.id])
        XCTAssertTrue(rig.effects.contains(.hud(.notice("Some text may already be typed — the rest was discarded"))))
    }

    @MainActor func testEveryLateCompletionIsRejectedByItsTokenAfterNewCapture() {
        let rig = DictationRig(); let s = rig.start(); rig.stop(); rig.discard(s)
        let newer = rig.start(), count = rig.effects.count
        let landed = DictationSession.Landed(landing: .pending, raw: "raw", insertText: "", bundleID: nil, appName: nil)
        let events: [DictationSession.Event] = [
            .transcribed(s, raw: "late raw", probe: .init(focus: .editable)),
            .transcribed(s, raw: nil, probe: .init(focus: .editable)),
            .commandHeard(s, instruction: "change it"), .commandHeard(s, instruction: ""),
            .cleanReady(s, landed, text: "late clean", failure: nil, focus: .editable),
            .cleanReady(s, landed, text: "raw fallback", failure: "failure", focus: .editable),
            .transformReady(s, text: "late transform", probe: .init(focus: .editable, selectionStillMatches: true, destinationStillMatches: true)),
            .legUnavailable(s, message: "late failure"), .streamPreview(gen: s.gen, text: "late preview")]
        for event in events { rig.send(event) }
        XCTAssertEqual(rig.effects.count, count); XCTAssertEqual(rig.machine.state, .recording(newer))
    }

    func testEveryRecognitionPassReceivesAbortAndRejectsIgnoredAbort() async throws {
        let samples = (0..<8000).map { Float(sin(Double($0))) * 0.5 }
        for pass in [RecognitionHandle.Pass.streamHead("head"), .streamTail("head"), .windowedFinal("head"), .fullFinal, .command] {
            let op = PendingOperation(name: "pass"), client = HeldRecognition()
            client.onCall = { op.revoke() }
            let handle = try RecognitionHandle(request: RecognitionRequest(settings: Settings())) { _ in client }
            recognitionAssertNil(await handle.transcribe(samples, pass: pass, shouldAbort: { op.shouldAbort }))
            XCTAssertTrue(client.abortRequested)
        }
        let op = PendingOperation(name: "confirmed"), client = HeldRecognition()
        let handle = try RecognitionHandle(request: RecognitionRequest(settings: Settings())) { _ in client }
        op.revoke()
        recognitionAssertNil(await handle.finalTranscript(samples: samples, window: .init(confirmedText: "confirmed", cutSample: samples.count), shouldAbort: { op.shouldAbort }))
        recognitionAssertNil(await handle.commandInstruction(samples: samples, shouldAbort: { op.shouldAbort }))
        XCTAssertEqual(client.calls, 0)
    }
    @MainActor func testSpokenCommandAbortBeforeProviderAndSavedPresetRequestCancellation() async throws {
        // Spoken command recognition uses its own cooperative callback.
        let rig = DictationRig()
        var settings = Settings(); settings.whisperModelPath = "/fake/model.bin"
        rig.send(.startCommand(settings: settings, cleanupConfigured: true, focus: .editable, selection: "source"))
        guard case .recording(let spoken) = rig.machine.state else { return XCTFail("command capture") }
        rig.stop()
        let client = HeldRecognition(); client.held = true
        let captured = rig.samples
        let task = PendingOperationQueue.enqueue(previous: nil, operation: spoken.operation, completes: true) {
            let handle = try! RecognitionHandle(request: spoken.recognition) { _ in client }
            let instruction = await DictationProcessing.command(operation: spoken.operation, handle: handle, samples: captured)
            await MainActor.run { rig.send(.commandHeard(spoken, instruction: instruction ?? "")) }
        }
        await fulfillment(of: [client.entered], timeout: 2)
        rig.discard(spoken); XCTAssertTrue(client.abortRequested)
        _ = rig.start(); let count = rig.effects.count
        client.exit.signal(); await task.value
        XCTAssertEqual(rig.effects.count, count)
        XCTAssertFalse(rig.effects.contains { if case .transform = $0 { return true }; return false })

        for failing in [false, true] {
            let selection = DictationRig(), held = HeldCleanup()
            let preset = TransformPreset(name: "French", instruction: "Translate into French")
            settings.transformPresets = [preset]; settings.selectedPresetID = preset.id
            selection.send(.startSavedPreset(settings: settings, cleanupConfigured: true, selection: "source", target: .init(focus: .editable)))
            guard case .runSavedPreset(let saved) = selection.effects.last else { return XCTFail("saved preset") }
            held.observedRevoke = { saved.operation.shouldAbort }
            let request = PendingOperationQueue.enqueue(previous: nil, operation: saved.operation, completes: true) {
                let result = await DictationProcessing.transform(operation: saved.operation) {
                    try await saved.transform(instruction: preset.intent) { _ in held }
                }
                if let result {
                    await MainActor.run { selection.send(.transformReady(saved, text: result.text,
                        probe: .init(focus: .editable, selectionStillMatches: true, destinationStillMatches: true), failure: result.failure)) }
                }
            }
            await fulfillment(of: [held.entered], timeout: 2)
            selection.discard(saved); await fulfillment(of: [held.cancelled], timeout: 2)
            _ = selection.start(); let count = selection.effects.count
            held.complete(failing: failing); await request.value
            XCTAssertEqual(selection.effects.count, count); XCTAssertTrue(selection.inserted.isEmpty); XCTAssertTrue(selection.history.isEmpty)
        }
    }

    @MainActor func testStreamHeadAndTailLateCallbacksCannotTakeOverNewCapture() async {
        for pass in [RecognitionHandle.Pass.streamHead("confirmed"), .streamTail("confirmed")] {
            let rig = DictationRig(), client = HeldRecognition(); client.held = true
            let s = rig.start(), captured = rig.samples
            let stream = PendingOperationQueue.enqueue(previous: nil, operation: s.operation) {
                let handle = try! RecognitionHandle(request: s.recognition) { _ in client }
                let text = await DictationProcessing.stream(operation: s.operation, handle: handle, samples: captured,
                    pass: pass, capturing: { true })
                if let text { await MainActor.run { rig.send(.streamPreview(gen: s.gen, text: text)) } }
            }
            await fulfillment(of: [client.entered], timeout: 2)
            rig.stop(); rig.discard(s); XCTAssertTrue(client.abortRequested)
            let newer = rig.start(), count = rig.effects.count
            client.exit.signal(); await stream.value
            XCTAssertEqual(rig.effects.count, count); XCTAssertEqual(rig.machine.state, .recording(newer))
            XCTAssertTrue(rig.inserted.isEmpty); XCTAssertTrue(rig.history.isEmpty)
        }
    }

    @MainActor func testDisposalFailureFeedbackSurvivesDiscardNoticeAndDoesNotReplaceNewSecureRefusal() {
        let rig = DictationRig(); rig.disposalFails = true
        let s = rig.start(); rig.stop(); rig.discard(s)
        XCTAssertEqual(rig.effects.last, .hud(.error("Audio deletion failed; file remains")))
        rig.beforeEffect = { effect in
            if case .sampleFocus(let gen) = effect { rig.send(.focusSampled(gen: gen, focus: .secure)) }
        }
        rig.send(.startDictation(settings: Settings(), cleanupConfigured: true, live: false))
        // A later secure refusal remains stronger than the old operation's error.
        XCTAssertTrue(rig.effects.contains(.secureRefusal("Not supported in password fields")))
        rig.send(.operationDisposalFailed(s.operation, message: "old error"))
        XCTAssertFalse(rig.effects.contains(.hud(.error("old error"))))
        rig.send(.legUnavailable(s, message: "old native error"))
        XCTAssertFalse(rig.effects.contains(.hud(.error("old native error"))))
    }

}
