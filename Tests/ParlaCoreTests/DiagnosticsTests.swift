import XCTest
@testable import ParlaCore

private final class DiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 100
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
private final class DiagnosticRecognition: RecognitionClient {
    let clock: DiagnosticClock
    var result: String? = "SOURCE_SENTINEL"
    var during: (() -> Void)?
    var calls = 0
    init(_ clock: DiagnosticClock) { self.clock = clock }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        calls += 1; clock.advance(0.4); during?(); return result
    }
}
private struct DiagnosticProviderFake: CleanupProviding {
    let clock: DiagnosticClock
    var action: () async throws -> String = { "Cleaned result" }
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        clock.advance(0.6); return try await action()
    }
}
private actor DiagnosticGate {
    let entered = XCTestExpectation(description: "gate entered")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}

/// Inert adapters around the same capture coordinator, queue, handle, Pipeline,
/// reducer and dispatch seam used by the app. No microphone/native app I/O.
@MainActor private final class DiagnosticRig {
    let clock = DiagnosticClock()
    let diagnostics: DiagnosticStore
    let machine: DictationSession
    var settings = Settings()
    var facts: CaptureDiagnosticState?
    var deadline: (() -> Void)?
    var samples = [Float](repeating: 0.2, count: 8000)
    var captured: [Float] = []
    var firstPCM = true
    var conversionFailure = false
    var captureFails = false
    var posted = true
    var inserts = 0
    var effects: [DictationSession.Effect] = []
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var instruction: String?
    lazy var capture = CaptureDiagnosticCoordinator(snapshot: { [unowned self] id in self.facts?.operationID == id ? self.facts : nil },
        now: clock.now, schedule: { [unowned self] _, action in self.deadline = action; return {} })
    init() {
        diagnostics = DiagnosticStore(now: clock.now)
        machine = DictationSession(diagnostics: diagnostics)
        settings.historyEnabled = false
        settings.whisperModelPath = "/PRIVATE_PATH/ggml-base.en.bin"
    }
    func send(_ event: DictationSession.Event) {
        machine.send(event) { effect in
            effects.append(effect)
            switch effect {
            case .applyPreferencesAndStartCapture:
                guard case .starting(let s) = machine.state else { return }
                do {
                    try capture.start(operation: s.operation) { id in
                        if captureFails { throw CocoaError(.fileReadUnknown) }
                        facts = CaptureDiagnosticState(operationID: id!, started: clock.now())
                        clock.advance(0.02)
                        if firstPCM { facts?.input(hasPCM: true, conversionFailed: conversionFailure, now: clock.now()) }
                    }
                    send(.recorderStarted(gen: s.gen))
                } catch { send(.recorderFailed(gen: s.gen, message: "PRIVATE_CAPTURE_ERROR")) }
            case .sampleFocus(let gen): send(.focusSampled(gen: gen, focus: .editable))
            case .stopCapture(let discard):
                captured = capture.stop(discard: discard) {
                    facts?.stop(sampleCount: samples.count, rms: AudioRecorder.rms(samples))
                    return samples
                }
                if discard { captured = [] }
            case .abortOperation(let operation): operation.requestAbort()
            case .polish(let s, let landed): pending = (s, landed)
            case .transform(_, let instruction): self.instruction = instruction
            case .insertText:
                guard machine.effectOperation?.authorizeDispatch() != false else { return }
                _ = DiagnosticDispatch.paste(diagnostics: machine.effectOperation?.diagnostics) {
                    clock.advance(0.03); inserts += 1; return posted
                }
            default: break
            }
        }
    }
    func start() -> DictationSession.Session {
        send(.startDictation(settings: settings, cleanupConfigured: true, live: false))
        guard case .recording(let s) = machine.state else { fatalError("fake capture did not start") }
        return s
    }
    func run(_ s: DictationSession.Session, client: RecognitionClient, previous: Task<Void, Never>? = nil,
             provider: CleanupProviding? = nil, window: StreamWindow? = nil,
             beforeCompletion: (() async -> Void)? = nil, focus: Inserter.FocusTarget = .editable) -> Task<Void, Never> {
        let samples = captured
        return PendingOperationQueue.enqueue(previous: previous, operation: s.operation, completes: true, work: {
            let handle = try! RecognitionHandle(request: s.recognition, diagnostics: s.operation.diagnostics) { _ in
                self.clock.advance(0.2); return client
            }
            let ownedWindow = window.map { handle.window(confirmedText: $0.confirmedText, cutSample: $0.cutSample) }
            await DictationProcessing.final(operation: s.operation, samples: samples, window: ownedWindow, prepare: {
                handle
            }, recognized: { _, raw in
                await MainActor.run {
                    self.send(.transcribed(s, raw: raw, probe: .init(focus: focus, deferInsertionUntilClean: true)))
                    defer { self.pending = nil }
                    return self.pending
                }
            }, clean: { context in
                let pipeline = Pipeline(outputSettings: context.0.effectiveSettings, bundleID: nil, diagnostics: s.operation.diagnostics) { _ in
                    provider ?? DiagnosticProviderFake(clock: self.clock)
                }
                return await pipeline.clean(transcript: context.1.raw)
            }, completed: { context, text, failure in
                await beforeCompletion?()
                await MainActor.run { self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: focus)) }
            })
        })
    }
    func record(_ operation: PendingOperation) -> DiagnosticRecord { diagnostics.snapshot().records.first { $0.id == operation.id }! }
}

final class DiagnosticsTests: XCTestCase {
    @MainActor func testProductionQueueSeparatesWaitAcquisitionASRProviderAndPaste() async throws {
        let rig = DiagnosticRig(), gate = DiagnosticGate()
        let previous = Task { await gate.wait() }
        await fulfillment(of: [gate.entered], timeout: 2)
        let s = rig.start(); rig.send(.stopRequested)
        // Mutable UI settings cannot rename the frozen request or resolved handle.
        rig.settings.whisperModelPath = "/changed/ggml-large-v3-turbo-q5_0.bin"
        let task = rig.run(s, client: DiagnosticRecognition(rig.clock), previous: previous)
        rig.clock.advance(1); await gate.release(); await task.value
        let record = rig.record(s.operation)
        func timing(_ stage: DiagnosticStage) throws -> DiagnosticTiming { try XCTUnwrap(record.timings.first { $0.stage == stage }) }
        XCTAssertEqual(try timing(.queueWait).totalMs, 1000, accuracy: 0.001)
        XCTAssertEqual(try timing(.acquisition).totalMs, 200, accuracy: 0.001)
        XCTAssertEqual(try timing(.asr).totalMs, 400, accuracy: 0.001)
        XCTAssertEqual(try timing(.provider).totalMs, 600, accuracy: 0.001)
        XCTAssertEqual(try timing(.delivery).totalMs, 30, accuracy: 0.001)
        XCTAssertLessThanOrEqual(try XCTUnwrap(timing(.cleanup).lastEndMs), try XCTUnwrap(timing(.delivery).firstStartMs))
        XCTAssertEqual(record.requestedASR, .unavailable); XCTAssertEqual(record.resolvedASR, .unavailable) // matching custom basename is not catalog identity
        XCTAssertEqual(record.frozenProviderModel, .haiku); XCTAssertEqual(record.requestedProviderModel, .unavailable); XCTAssertEqual(record.resolvedProviderModel, .unavailable)
        XCTAssertEqual(record.delivery, .postedUnverified); XCTAssertEqual(record.providerOutcome, .returned)
        XCTAssertEqual(record.firstPCMDeadline, .receivedInTime); XCTAssertEqual(record.capture, .signal)
        XCTAssertTrue(record.operationFinished); XCTAssertEqual(rig.inserts, 1)
    }

    @MainActor func testNoPCMDeadlineObservesWithoutStopAndDiffersFromSilenceAndMinimumDuration() async {
        let noPCM = DiagnosticRig(); noPCM.firstPCM = false; noPCM.samples = []
        let a = noPCM.start(); noPCM.clock.advance(2); noPCM.deadline?()
        XCTAssertTrue(noPCM.machine.isCapturing)
        XCTAssertEqual(noPCM.record(a.operation).firstPCMDeadline, .noFirstPCM)
        noPCM.send(.stopRequested)
        await noPCM.run(a, client: DiagnosticRecognition(noPCM.clock)).value
        XCTAssertEqual(noPCM.record(a.operation).asr, .minimumDuration)
        for (samples, outcome, asr) in [([Float](repeating: 0, count: 8000), DiagnosticCaptureOutcome.noMeaningfulSignal, DiagnosticASR.silence),
                                          ([Float](repeating: 0.2, count: 50), .minimumDuration, .minimumDuration)] {
            let rig = DiagnosticRig(); rig.samples = samples
            let s = rig.start(); rig.send(.stopRequested)
            let client = DiagnosticRecognition(rig.clock)
            await rig.run(s, client: client).value
            XCTAssertEqual(rig.record(s.operation).firstPCMDeadline, .receivedInTime)
            XCTAssertEqual(rig.record(s.operation).capture, outcome); XCTAssertEqual(rig.record(s.operation).asr, asr)
            XCTAssertEqual(client.calls, 0); XCTAssertEqual(rig.inserts, 0)
        }
    }

    @MainActor func testCaptureFailureConversionFailureLatePCMAndWrongOwner() async {
        let rig = DiagnosticRig(); rig.conversionFailure = true
        let s = rig.start(); rig.send(.stopRequested)
        XCTAssertEqual(rig.record(s.operation).capture, .conversionFailure)
        var wrong = CaptureDiagnosticState(operationID: UUID(), started: rig.clock.now())
        wrong.input(hasPCM: true, conversionFailed: false, now: rig.clock.now() - 0.1)
        XCTAssertNil(wrong.firstPCM, "A warm callback beginning before capture is not live first PCM")
        wrong.input(hasPCM: true, conversionFailed: false, now: rig.clock.now())
        s.operation.diagnostics?.observeCapture(wrong, deadline: true)
        XCTAssertEqual(rig.record(s.operation).capture, .conversionFailure)
        let failed = DiagnosticRig(); failed.captureFails = true
        failed.send(.startDictation(settings: failed.settings, cleanupConfigured: true, live: false))
        XCTAssertEqual(failed.diagnostics.snapshot().records.first?.capture, .captureFailure)
        XCTAssertFalse(failed.machine.isCapturing)
        let late = DiagnosticRig(); late.firstPCM = false
        let l = late.start(); late.clock.advance(2.5)
        late.facts?.input(hasPCM: true, conversionFailed: false, now: late.clock.now())
        late.deadline?()
        XCTAssertEqual(late.record(l.operation).firstPCMDeadline, .noFirstPCM)
        XCTAssertNotNil(late.record(l.operation).firstPCMMs)
    }

    @MainActor func testCancellationBeforeQueueAndDuringProviderDoesNotDeliverOrTakeNewHUD() async {
        let rig = DiagnosticRig(), gate = DiagnosticGate()
        let previous = Task { await gate.wait() }
        await fulfillment(of: [gate.entered], timeout: 2)
        let s = rig.start(); rig.send(.stopRequested)
        let client = DiagnosticRecognition(rig.clock), task = rig.run(s, client: client, previous: previous)
        rig.send(.discardPending(token: s.operation.id)); let newer = rig.start()
        await gate.release(); await task.value
        XCTAssertEqual(rig.record(s.operation).reason, .discarded); XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(rig.machine.state, .recording(newer)); XCTAssertEqual(rig.inserts, 0)

        let held = DiagnosticRig(), providerGate = DiagnosticGate()
        let old = held.start(); held.send(.stopRequested)
        let provider = DiagnosticProviderFake(clock: held.clock, action: { await providerGate.wait(); return "late result" })
        let work = held.run(old, client: DiagnosticRecognition(held.clock), provider: provider)
        await fulfillment(of: [providerGate.entered], timeout: 2)
        held.send(.discardPending(token: old.operation.id)); let current = held.start()
        await providerGate.release(); await work.value
        XCTAssertEqual(held.record(old.operation).reason, .discarded)
        XCTAssertEqual(held.record(old.operation).providerOutcome, .canceled)
        XCTAssertEqual(held.record(old.operation).delivery, .withheld)
        XCTAssertEqual(held.machine.state, .recording(current)); XCTAssertEqual(held.inserts, 0)
    }

    @MainActor func testStaleParkedAndPartialProviderFailureAreHonest() async {
        let rig = DiagnosticRig(), gate = DiagnosticGate()
        let s = rig.start(); rig.send(.stopRequested)
        let task = rig.run(s, client: DiagnosticRecognition(rig.clock), beforeCompletion: { await gate.wait() })
        await fulfillment(of: [gate.entered], timeout: 2)
        let newer = rig.start(); await gate.release(); await task.value
        XCTAssertEqual(rig.record(s.operation).reason, .staleGeneration)
        XCTAssertTrue(rig.record(s.operation).staleCompletion)
        XCTAssertEqual(rig.record(s.operation).delivery, .withheld)
        XCTAssertEqual(rig.machine.state, .recording(newer)); XCTAssertEqual(rig.inserts, 0)
        let failed = DiagnosticRig(); let f = failed.start(); failed.send(.stopRequested)
        let provider = DiagnosticProviderFake(clock: failed.clock, action: { throw NSError(domain: "PRIVATE_PROVIDER_BODY", code: 1) })
        await failed.run(f, client: DiagnosticRecognition(failed.clock), provider: provider).value
        XCTAssertEqual(failed.record(f.operation).providerOutcome, .failed)
        XCTAssertEqual(failed.record(f.operation).delivery, .postedUnverified) // raw fallback, no invented provider success
        XCTAssertEqual(failed.inserts, 1)
    }

    @MainActor func testCurrentNoDestinationRecordsWithholdingForCleanupAndRawWithHistoryOnOrOff() async {
        for mode in [DictationOutputMode.cleanup, .raw] {
            for historyEnabled in [true, false] {
                let rig = DiagnosticRig()
                rig.settings.outputMode = mode; rig.settings.historyEnabled = historyEnabled
                let session = rig.start(); rig.send(.stopRequested)
                await rig.run(session, client: DiagnosticRecognition(rig.clock), focus: .none).value
                let record = rig.record(session.operation)
                XCTAssertEqual(record.reason, .noDestination)
                XCTAssertEqual(record.delivery, .withheld)
                XCTAssertTrue(record.operationFinished); XCTAssertEqual(rig.inserts, 0)
                XCTAssertEqual(rig.effects.contains { if case .appendHistory = $0 { return true }; return false }, historyEnabled)
            }
        }
    }

    @MainActor func testASRNilEmptyCanceledAndConfirmedWindowHaveDistinctEvidence() async {
        for value in [nil, ""] as [String?] {
            let rig = DiagnosticRig(), client = DiagnosticRecognition(DiagnosticClock())
            client.result = value
            let s = rig.start(); rig.send(.stopRequested); await rig.run(s, client: client).value
            XCTAssertEqual(rig.record(s.operation).asr, value == nil ? .nilOrError : .empty)
            XCTAssertEqual(rig.inserts, 0)
        }
        let rig = DiagnosticRig(), client = DiagnosticRecognition(DiagnosticClock())
        let s = rig.start(); rig.send(.stopRequested)
        client.during = { s.operation.revoke() }
        await rig.run(s, client: client).value
        XCTAssertEqual(rig.record(s.operation).asr, .canceled); XCTAssertEqual(rig.inserts, 0)
        let windowed = DiagnosticRig(); let w = windowed.start(); windowed.send(.stopRequested)
        let unused = DiagnosticRecognition(windowed.clock)
        await windowed.run(w, client: unused, window: .init(confirmedText: "confirmed", cutSample: windowed.captured.count)).value
        XCTAssertEqual(windowed.record(w.operation).asr, .confirmedWindow); XCTAssertEqual(unused.calls, 0)
    }

    @MainActor func testLocalOffSnippetSecureAndRefusedPasteEvidence() async {
        for snippet in [false, true] {
            let rig = DiagnosticRig(); rig.settings.cleanupEnabled = false
            if snippet { rig.settings.snippets = ["SOURCE_SENTINEL": "PRIVATE_SNIPPET"] }
            let s = rig.start(); rig.send(.stopRequested); await rig.run(s, client: DiagnosticRecognition(rig.clock)).value
            XCTAssertEqual(rig.record(s.operation).providerOutcome, snippet ? .localSnippet : .off)
            XCTAssertFalse(rig.record(s.operation).timings.contains { $0.stage == .provider })
        }
        let rig = DiagnosticRig(); let s = rig.start(); rig.send(.stopRequested)
        await rig.run(s, client: DiagnosticRecognition(rig.clock), focus: .secure).value
        XCTAssertEqual(rig.record(s.operation).reason, .secure); XCTAssertEqual(rig.record(s.operation).delivery, .refused)
        let refused = DiagnosticRig(); refused.posted = false
        let r = refused.start(); refused.send(.stopRequested)
        await refused.run(r, client: DiagnosticRecognition(refused.clock)).value
        XCTAssertEqual(refused.record(r.operation).delivery, .refused)
    }

    @MainActor func testSpokenSavedAndDictatedTransformOriginsUseProductionRequests() async throws {
        for spoken in [true, false] {
            let rig = DiagnosticRig()
            let preset = TransformPreset(name: "PRIVATE_PRESET", instruction: "PRIVATE_INSTRUCTION")
            rig.settings.transformPresets = [preset]; rig.settings.selectedPresetID = preset.id
            let target = LandingProbe(focus: .editable, appName: "PRIVATE_APP")
            let s: DictationSession.Session
            if spoken {
                rig.send(.startCommand(settings: rig.settings, cleanupConfigured: true, focus: .editable,
                    selection: "PRIVATE_SELECTION", transformTarget: target))
                guard case .recording(let active) = rig.machine.state else { return XCTFail("Spoken capture should start") }
                s = active; rig.send(.stopRequested)
            } else {
                rig.send(.startSavedPreset(settings: rig.settings, cleanupConfigured: true, selection: "PRIVATE_SELECTION", target: target))
                s = try XCTUnwrap(rig.effects.compactMap { effect in
                    if case .runSavedPreset(let session) = effect { return session }; return nil
                }.first)
            }
            let task = PendingOperationQueue.enqueue(previous: nil, operation: s.operation, completes: true, work: {
                var instruction = preset.intent
                if spoken {
                    let handle = try! RecognitionHandle(request: s.recognition, diagnostics: s.operation.diagnostics) { _ in DiagnosticRecognition(rig.clock) }
                    guard let heard = await DictationProcessing.command(operation: s.operation, handle: handle, samples: rig.captured) else { return }
                    await MainActor.run { rig.send(.commandHeard(s, instruction: heard)) }
                    instruction = await MainActor.run { rig.instruction ?? "" }
                }
                guard let result = await DictationProcessing.transform(operation: s.operation, request: {
                    try await s.transform(instruction: instruction) { _ in DiagnosticProviderFake(clock: rig.clock) }
                }) else { return }
                await MainActor.run {
                    rig.send(.transformReady(s, text: result.text,
                        probe: .init(focus: .editable, selectionStillMatches: true, destinationStillMatches: true), failure: result.failure))
                }
            })
            await task.value
            let record = rig.record(s.operation)
            XCTAssertEqual(record.origin, spoken ? .spokenTransform : .savedTransform)
            XCTAssertEqual(record.providerOutcome, .returned); XCTAssertEqual(record.delivery, .postedUnverified)
            XCTAssertEqual(rig.inserts, 1)
            XCTAssertEqual(record.asr, spoken ? .text : .unknown)
        }
        let rig = DiagnosticRig(), preset = TransformPreset(name: "PRIVATE_PRESET", instruction: "PRIVATE_INSTRUCTION")
        rig.settings.outputMode = .selectedPreset; rig.settings.transformPresets = [preset]; rig.settings.selectedPresetID = preset.id
        let s = rig.start(); rig.send(.stopRequested)
        await rig.run(s, client: DiagnosticRecognition(rig.clock)).value
        XCTAssertEqual(rig.record(s.operation).origin, .dictatedPreset)
        XCTAssertEqual(rig.record(s.operation).providerOutcome, .returned)
        XCTAssertEqual(rig.record(s.operation).delivery, .postedUnverified)
    }

    @MainActor func testOldCaptureDeadlineAfterNewCaptureAndClearCannotCrossOwners() {
        let rig = DiagnosticRig(); rig.firstPCM = false
        let old = rig.start(), oldDeadline = rig.deadline
        let current = rig.start()
        let currentBefore = rig.record(current.operation)
        rig.clock.advance(3); oldDeadline?()
        XCTAssertEqual(rig.record(current.operation), currentBefore)
        XCTAssertEqual(rig.record(old.operation).reason, .supersededCapture)
        XCTAssertEqual(rig.record(old.operation).capture, .canceled)
        XCTAssertEqual(rig.machine.state, .recording(current))
        rig.diagnostics.clear(); rig.deadline?(); rig.send(.cancelRequested(silent: false))
        XCTAssertTrue(rig.diagnostics.snapshot().records.isEmpty)
    }

    func testDeliveryReceiptCannotPromoteButPositiveAXReadbackCan() {
        let store = DiagnosticStore(), op = PendingOperation(name: "PRIVATE_NAME", diagnostics: store)
        op.diagnostics?.receipt()
        XCTAssertEqual(store.snapshot().records[0].delivery, .notAttempted)
        XCTAssertTrue(DiagnosticDispatch.paste(diagnostics: op.diagnostics) { true })
        op.diagnostics?.receipt()
        XCTAssertEqual(store.snapshot().records[0].delivery, .postedUnverified)
        DiagnosticDispatch.replacement(.unverified, diagnostics: op.diagnostics)
        XCTAssertEqual(store.snapshot().records[0].delivery, .axWriteUnverified)
        DiagnosticDispatch.replacement(.replaced, diagnostics: op.diagnostics)
        XCTAssertEqual(store.snapshot().records[0].delivery, .axConfirmed)
        XCTAssertTrue(store.snapshot().records[0].receiptObserved)
    }

    func testCountByteBoundsPruneActiveRecordsAndClearRejectsOldCallbacks() throws {
        let store = DiagnosticStore(countLimit: 3, byteLimit: 2500)
        let old = PendingOperation(name: "old", diagnostics: store), span = old.diagnostics?.begin(.provider)
        for index in 0..<40 {
            let operation = PendingOperation(name: "arbitrary name", diagnostics: store)
            for stage in DiagnosticStage.allCases { operation.diagnostics?.begin(stage).end() }
            if index.isMultiple(of: 2) { operation.finish() }
            XCTAssertLessThanOrEqual(store.snapshot().records.count, 3)
            XCTAssertLessThanOrEqual(try store.snapshot().encoded().count, 2500)
        }
        XCTAssertFalse(store.snapshot().records.contains { $0.id == old.id })
        store.clear(); span?.end(); old.finish(); old.diagnostics?.receipt()
        XCTAssertTrue(store.snapshot().records.isEmpty)
        let countBound = DiagnosticStore(countLimit: 2)
        let retained = (0..<20).map { _ in PendingOperation(name: "active", diagnostics: countBound) }
        XCTAssertEqual(countBound.snapshot().records.map(\.id), retained.suffix(2).map(\.id))
    }
}


extension DiagnosticsTests {
    func testB21FiniteAttemptProvenanceAcceptedOnlyAfterAdjudicationAndLateCallbacksStayEvicted() throws {
        let store = DiagnosticStore(countLimit:1,now:{0},appVersion:{"1.2.3"},osVersion:{.init(majorVersion:14,minorVersion:0,patchVersion:0)})
        let op = store.start(id:UUID(),origin:.dictation), run = CleanupFailoverRun();run.observe(op)
        var s = B21SettingsDocument.primary;s.cleanup.model = "private-model-sentinel"
        let i = run.begin(s);run.started(i);run.usage(i,model:"private-model-sentinel",input:12,output:3);run.outcome(i,.returned);run.candidate(i,acceptance:{})
        XCTAssertNil(run.snapshot.acceptedProducerOrdinal);try run.adjudicate(accepted:true);XCTAssertEqual(run.snapshot.acceptedProducerOrdinal,0)
        let data = try store.snapshot().encoded(), text = String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("private-model-sentinel"));XCTAssertFalse(text.contains("primary.test"));XCTAssertTrue(text.contains("acceptedProducerOrdinal"))
        XCTAssertEqual(run.snapshot.attempts.first?.resolved,.unavailable)
        store.clear();run.outcome(i,.deadline);XCTAssertTrue(store.snapshot().records.isEmpty)
        let late = store.start(id:UUID(),origin:.dictation);_=store.start(id:UUID(),origin:.dictation);late.providerModel("claude-sonnet-5")
        XCTAssertEqual(store.snapshot().records.count,1);XCTAssertEqual(store.snapshot().records.first?.resolvedProviderModel,.unavailable)
    }
}
