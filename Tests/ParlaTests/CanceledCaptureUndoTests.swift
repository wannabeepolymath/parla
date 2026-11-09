import AVFoundation
import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

private final class UndoClock: @unchecked Sendable {
    struct Timer { let at: Double; let action: () -> Void }
    private let lock = NSLock()
    private var value = 100.0
    var time: Double { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    var timers: [UUID: Timer] = [:]
    var stale: [() -> Void] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) -> () -> Void {
        let id = UUID(); timers[id] = Timer(at: time + delay, action: action); stale.append(action)
        return { self.timers[id] = nil }
    }
    func advance(_ interval: Double) {
        let end = time + interval
        while let next = timers.filter({ $0.value.at <= end }).min(by: { $0.value.at < $1.value.at }) {
            time = next.value.at; timers[next.key] = nil; next.value.action()
        }
        time = end
    }
}
extension UndoClock: AutomationClock {
    var now: TimeInterval { time }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        schedule(seconds) { MainActor.assumeIsolated { action() } }
    }
}
private final class UndoEngine: MicrophoneCaptureEngine {
    var isRunning = false
    var route = MicrophoneRoute()
    var starts = 0, stops = 0
    var receive: ((AVAudioPCMBuffer) -> Void)?, changed: (() -> Void)?, onStop: (() -> Void)?
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws {
        starts += 1; isRunning = true; self.receive = receive; self.changed = changed
    }
    func stop() { stops += 1; isRunning = false; receive = nil; changed = nil; onStop?() }
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AudioRecorder.targetFormat, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        b.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { b.floatChannelData![0][i] = sample }
        return b
    }
    func feed(_ samples: [Float]) { receive?(Self.buffer(samples)) }
}
private final class UndoClient: RecognitionClient, @unchecked Sendable {
    let lock = NSLock()
    var text: String? = " raw preview \n"
    var held = false
    let entered = XCTestExpectation(description: "native ASR entered"), exit = RecognitionTestLatch()
    private var abort: (() -> Bool)?
    var onCall: (() -> Void)?
    private(set) var calls = 0
    private(set) var prompt: String?, language: String?
    var abortRequested: Bool { lock.withLock { abort?() == true } }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        lock.withLock { calls += 1; abort = shouldAbort; prompt = initialPrompt; self.language = language }
        onCall?()
        if held { entered.fulfill(); await exit.wait() }
        return text
    }
}
private final class UndoProvider: CleanupProviding {
    var calls = 0
    func clean(transcript: String, context: CleanupContext) async throws -> String { calls += 1; return "ordinary cleaned" }
}
private actor UndoGate {
    let entered = XCTestExpectation(description: "queued barrier entered")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}

/// Reducer drain → production cancel executor → owned recorder → real controller
/// → actual NSButton target → typed dispatcher/queue → fresh handle/fake native.
/// Ordinary positive control uses the SAME production storage finalizer, pipeline,
/// reducer, HistoryPersistenceSink, insertion executor and invocation result host.
@MainActor private final class UndoRig {
    let root: URL, store: SettingsStore, backend = FakeCredentialBackend()
    let clock = UndoClock(), engine = UndoEngine(), machine = DictationSession(diagnostics: DiagnosticStore())
    let client = UndoClient(), provider = UndoProvider(), admission = CaptureAdmission()
    let input = PhysicalInputAuthority(), results = DictationResultStore()
    var settings: Settings
    var configValid = true, security: OriginalCopySecurity = .safe
    var onSecurity: (() -> Void)?
    var securityReads = 0, loads = 0, verifies = 0, ordinaryRuns = 0, entries: [OrdinaryDictationFinalization.Entry] = []
    var accesses: [RecordingStore.Access] = [], writes = 0, removes = 0, historyWrites = 0, inserts = 0, corrections = 0
    var onCopy: ((String) -> Void)?
    var copies: [String] = [], effects: [DictationSession.Effect] = [], frames: [CanceledCaptureView] = []
    var resultsPublished = 0, mirror = 0, recorderGeneration = 0
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var accepted: [DictationSession.Session] = []
    var deadline = 0.0
    var chain: Task<Void, Never>?
    var acknowledge = true, physical = true, modelVerified = true, loadFails = false
    var beforeTransfer: (() -> Void)?, onVerify: (() -> Void)?, onLoad: (() -> Void)?
    var foundationFactory: RecognitionFactory?
    var foundationResident: RecognitionResident?
    var preparationNotices: [PreparationRefusal] = []
    var residentBoundary: (() async -> Void)?
    var afterRecognition: (() -> Void)?
    var diskSnapshot: [String: Data] = [:]
    lazy var recordings = RecordingStore(directory: root.appendingPathComponent("audio"), keepAll: true,
        access: { [unowned self] in accesses.append($0) }, writer: { [unowned self] samples, url in
            writes += 1; try RecordingStore.writeWAV(samples, to: url)
        }, remover: { [unowned self] url in removes += 1; try FileManager.default.removeItem(at: url) })
    lazy var history = HistoryStore(url: root.appendingPathComponent("history.json"), persistence: .init(
        read: { try Data(contentsOf: $0) }, writeAtomically: { [unowned self] data, url in
            historyWrites += 1; try data.write(to: url, options: .atomic)
        }))
    lazy var sink = HistoryPersistenceSink(history: history, settings: store)
    lazy var recorder = AudioRecorder(engine: engine, admission: admission, captureClock: { [clock] in clock.time }, scheduleRoute: clock.schedule)
    lazy var diagnostics = CaptureDiagnosticCoordinator(snapshot: { [unowned self] in recorder.diagnosticSnapshot(for: $0) }, now: { [clock] in clock.time }, schedule: clock.schedule)
    lazy var controller = CanceledCaptureUndoController(configuration: { [unowned self] in configValid ? settings : nil },
        generation: { [unowned self] in machine.gen }, security: { [unowned self] in securityReads += 1; onSecurity?(); return security },
        now: { [clock] in clock.time }, schedule: clock.schedule, copy: { [unowned self] in copies.append($0); onCopy?($0) })
    lazy var actions = CanceledCaptureHUDActions(controller)
    lazy var cancellation = CanceledCaptureCancellationExecutor(controller: controller, ownedGeneration: { [unowned self] in recorderGeneration },
        transfer: { [unowned self] operation, retain in
            XCTAssertTrue(accepted.last(where: { $0.operation.id == operation })!.operation.shouldAbort)
            if machine.gen == recorderGeneration + 1 { XCTAssertEqual(mirror, 0) }
            recorderGeneration = 0
            beforeTransfer?()
            var result: [Float]?
            _ = diagnostics.stop(discard: true) { result = recorder.stopCanceledCapture(operationID: operation, retain: retain); return [] }
            return result
        })
    lazy var recognition: CanceledCaptureRecognition = {
        if let factory = foundationFactory {
            return CanceledCaptureRecognition(controller: controller, typedResident: { [unowned self] in foundationResident }, factory: factory,
                preparationRefused: { [unowned self] in preparationNotices.append($0) },
                verify: { [unowned self] _ in verifies += 1; return modelVerified })
        }
        return CanceledCaptureRecognition(controller: controller, resident: { [unowned self] in
        await residentBoundary?(); return (nil, nil)
    }, verify: { [unowned self] _ in verifies += 1; onVerify?(); return modelVerified }, load: { [unowned self] _ in
        loads += 1; onLoad?(); if loadFails { throw CancellationError() }; return client
    })
    }()
    lazy var dispatcher = DictationExecutionDispatcher(preview: recognition, ordinary: { [unowned self] session, samples, ledger in
        await ordinary(session, samples: samples, ledger: ledger)
    })
    lazy var originals = OriginalCopyController(configuration: { [unowned self] in settings }, generation: { [unowned self] in machine.gen },
        now: { [clock] in clock.time }, schedule: clock.schedule, security: { .safe }, copy: { _ in XCTFail("Original copy") })
    lazy var insertion = DictationInsertionExecutor(originals: originals, post: { [unowned self] _, _, willPost in
        inserts += 1; willPost(); return true
    }, didPost: { [unowned self] _ in corrections += 1 })
    lazy var broker = AutomationBroker(clock: clock, results: results, enabled: { true })
    lazy var host = DictationInvocationHost(machine: machine, inputAuthority: input, captureAdmission: admission, broker: broker, results: results,
        settings: { [unowned self] in settings }, configured: { _ in true }, capabilities: { _ in nil }, secure: { false },
        keyboardAllowed: { true }, automationAllowed: { true }, explicitEntry: {}, send: { [unowned self] in send($0) },
        invalidateCanceledCapture: { [unowned self] in controller.deliberateEntry() },
        captureAccepted: { [unowned self] session, fromPhysical in controller.accepted(session, physical: fromPhysical && physical) })

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave3i-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = Settings(); s.canceledCaptureUndoEnabled = true; s.whisperModelPath = "/fake/frozen.bin"
        s.language = "en"; s.dictionary = ["frozen hint"]; s.automationEnabled = true
        settings = s
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        try store.save(s)
        controller.render = { [unowned self] in frames.append($0) }
        controller.enqueue = { [unowned self] in chain = dispatcher.enqueue(.canceledCaptureUndo($0), previous: chain) }
        broker.register(host)
        try Data("CANARY".utf8).write(to: root.appendingPathComponent("canary"))
        try recordFixture("created")
    }
    private func recordFixture(_ action: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
    }
    func send(_ event: DictationSession.Event) {
        switch event {
        case .cancelRequested: deadline = controller.cancellationDeadline()
        case .startDictation, .startCommand, .startSavedPreset, .startAutomation, .discardPending: controller.invalidate()
        case .focusSampled(_, .secure): controller.invalidate()
        default: break
        }
        sink.beginEvent(for: event, currentGeneration: machine.gen)
        machine.send(event) { effect in
            mirror = machine.isCapturing ? machine.gen : 0
            effects.append(effect)
            switch effect {
            case .captureAccepted(let s): accepted.append(s); host.accepted(s)
            case .captureAcknowledged(let s): controller.acknowledged(s); host.acknowledged(s)
            case .captureFinalizing(let s): host.finalizing(s)
            case .applyPreferencesAndStartCapture:
                recorderGeneration = machine.gen
                try! diagnostics.start(operation: accepted.last!.operation) { try recorder.start(diagnosticOperation: $0) }
                if acknowledge { send(.recorderStarted(gen: machine.gen)) }
            case .sampleFocus(let g): send(.focusSampled(gen: g, focus: .editable))
            case .abortOperation(let op): XCTAssertTrue(op.shouldAbort); op.requestAbort()
            case .cancelCapture(let context): cancellation.execute(context, deadline: deadline)
            case .presentCanceledCapture(let generation): controller.present(generation: generation)
            case .stopCapture(let discard), .stopOwnedCapture(_, let discard):
                recorderGeneration = 0; _ = diagnostics.stop(discard: discard) { recorder.stop() }
            case .transcribeFinal(let s, let ledger):
                let samples = recorder.snapshot()
                chain = dispatcher.enqueue(.ordinary(s, samples: samples, ledger: ledger), previous: chain)
            case .polish(let s, let landed): pending = (s, landed)
            case .insertText(let text, _, let original): _ = insertion.insert(text, original: original, operation: machine.effectOperation)
            case .appendHistory, .appendTransformHistory: _ = sink.record(effect)
            case .finalResult(let s, let result): resultsPublished += 1; host.completed(s, result: result)
            case .secureRefusal: controller.invalidate()
            default: break
            }
        }
        host.synchronizeInput()
    }
    @discardableResult func start(live: Bool = false) -> DictationSession.Session {
        XCTAssertTrue(host.keyboard(.startDictation(settings: settings, cleanupConfigured: true, live: live)))
        return accepted.last!
    }
    func cancel(silent: Bool = false) { _ = host.keyboard(.cancelRequested(silent: silent, reason: silent ? .shortRelease : .explicitCancel)) }
    func offer(count: Int = 8000) { _ = start(); engine.feed(Array(repeating: 0.25, count: count)); cancel() }
    func button(_ action: CanceledCaptureHUDActions.Action, token: UUID? = nil) -> CanceledCaptureButton {
        let button = CanceledCaptureButton(title: "", target: nil, action: nil)
        actions.bind(button, action: action, token: token ?? controller.view.token)
        return button
    }
    func click(_ button: CanceledCaptureButton) {
        _ = (button.target as? NSObject)?.perform(button.action, with: button)
    }
    func undo() { click(button(.undo)) }
    func settle() async { await chain?.value }
    func ordinary(_ s: DictationSession.Session, samples: [Float], ledger: String) async {
        ordinaryRuns += 1
        let finalizer = OrdinaryDictationFinalization(recordings: recordings, settings: store, entered: { [unowned self] in entries.append($0) })
        await finalizer.run(operation: s.operation, samples: samples, window: nil, prepare: { _, _ in
            if let factory = self.foundationFactory {
                return try! await RecognitionAcquisition.acquire(request: s.recognition, resident: nil, factory: factory,
                    operation: s.operation, capture: s.operation.id)
            }
            return try! RecognitionHandle(request: s.recognition) { _ in self.client }
        }, recognized: { _, raw in
            self.send(.transcribed(s, raw: raw, probe: .init(focus: .editable, deferInsertionUntilClean: true)))
            finalizer.resolve(transcript: raw, secure: false)
            defer { self.pending = nil }; return self.pending
        }, clean: { context in
            let pipeline = Pipeline(outputSettings: context.0.effectiveSettings, bundleID: nil, makeClient: { _ in self.provider })
            return await pipeline.clean(transcript: context.1.raw)
        }, completed: { context, text, failure in
            self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: .editable))
        })
    }
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file) }
            else { result[String(file.path.dropFirst(root.path.count))] = Data() }
        }
        return result
    }
    func armZero() throws {
        _ = recordings; _ = history; _ = sink; _ = insertion
        diskSnapshot = try snapshot()
        entries = []; accesses = []; writes = 0; removes = 0; historyWrites = 0; inserts = 0; corrections = 0
        ordinaryRuns = 0; resultsPublished = 0; provider.calls = 0
    }
    func assertZero(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(ordinaryRuns + entries.count + accesses.count + writes + removes + historyWrites + inserts + corrections + resultsPublished + provider.calls, 0, file: file, line: line)
        XCTAssertEqual(try snapshot(), diskSnapshot, file: file, line: line)
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0, file: file, line: line)
    }
    func close() throws {
        controller.invalidate(); diagnostics.clear()
        if recorderGeneration != 0, let s = accepted.last { _ = recorder.stopCanceledCapture(operationID: s.operation.id, retain: false) }
        XCTAssertNil(controller.activeJob)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("canary")), Data("CANARY".utf8))
        try FileManager.default.removeItem(at: root)
        try recordFixture("removed")
    }
}

@MainActor final class CanceledCaptureUndoTests: XCTestCase {
    func testRealFactoryOrdinaryPositiveControlThenB57HasZeroStorageProviderOrPrefixReuse() async throws {
        let r = try UndoRig(); defer { try! r.close() }
        let native = FoundationNativeProbe(); native.multilingual = false
        r.foundationFactory = native.factory()
        r.settings.whisperModelPath = "/owned/ggml-base.en.bin"; try r.store.save(r.settings)
        r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000)); r.send(.stopRequested); await r.settle()
        XCTAssertEqual(r.ordinaryRuns, 1); XCTAssertTrue(r.entries.contains(.stash)); XCTAssertTrue(r.entries.contains(.resolve))
        XCTAssertEqual(r.writes, 1); XCTAssertGreaterThan(r.historyWrites, 0); XCTAssertGreaterThan(r.inserts, 0)
        XCTAssertEqual(r.provider.calls, 1); XCTAssertEqual(native.paths.count, 1); XCTAssertEqual(native.calls.count, 1)
        XCTAssertTrue(try r.snapshot().values.contains { String(decoding: $0, as: UTF8.self).contains("native original") })
        try r.armZero()
        r.offer()
        let token = try XCTUnwrap(r.controller.view.token, "Expected cancellation offer")
        r.undo()
        XCTAssertNotNil(r.controller.activeJob, "Undo must enqueue a job")
        await r.settle()
        XCTAssertEqual(native.paths.count, 2); XCTAssertEqual(native.calls.count, 2)
        XCTAssertEqual(native.calls.last?.samples.count, 8000)
        XCTAssertEqual(native.calls.last?.prompt, "frozen hint")
        XCTAssertEqual(r.controller.view, .preview(token, "native original"))
        XCTAssertTrue(r.copies.isEmpty); XCTAssertEqual(r.client.calls, 0)
        try r.assertZero(); XCTAssertEqual(native.releases, 2)
    }

    func testB57RealFactoryReadOnlyAdmissionBeforeBorrowAndFullAudioWithoutWindow() async throws {
        let r = try UndoRig(); defer { r.foundationResident = nil; try! r.close() }
        let native = FoundationNativeProbe(), factory = native.factory()
        r.foundationFactory = factory; r.settings.whisperModelPath = "/owned/ggml-base.en.bin"
        let owner = try await factory.acquire(request: RecognitionRequest(settings: r.settings))
        let foreignWindow = owner.window(confirmedText: "FOREIGN_PREFIX", cutSample: 8000)
        XCTAssertTrue(owner.owns(foreignWindow))
        r.foundationResident = owner.resident
        try r.armZero(); r.offer(); let token = try XCTUnwrap(r.controller.view.token); r.undo(); await r.settle()
        XCTAssertEqual(native.paths.count, 1); XCTAssertEqual(native.admissions, 2)
        XCTAssertEqual(native.calls.count, 1); XCTAssertEqual(native.calls[0].samples.count, 8000)
        XCTAssertEqual(native.calls[0].prompt, "frozen hint")
        XCTAssertEqual(r.controller.view, .preview(token, "native original")); try r.assertZero()
        r.controller.invalidate()
        native.admission = { _, policy in
            XCTAssertTrue(policy == .readOnlyCatalog); throw RecordingStore.Failure("fixture read-only refusal")
        }
        r.offer(); r.undo(); await r.settle()
        XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(native.calls.count, 1)
        XCTAssertEqual(native.paths.count, 1); try r.assertZero()
    }

    func testB57RealNativeHeldDecodeRevokesPublicationAndRetainsContextUntilExit() async throws {
        let r = try UndoRig(); defer { try! r.close() }
        let native = FoundationNativeProbe(), entered = expectation(description: "bottom native entered"), exit = DispatchSemaphore(value: 0)
        native.decode = { entered.fulfill(); exit.wait() }
        r.foundationFactory = native.factory(); r.settings.whisperModelPath = "/owned/ggml-base.en.bin"
        try r.armZero(); r.offer(); r.undo()
        await fulfillment(of: [entered], timeout: 3)
        r.controller.invalidate()
        XCTAssertEqual(r.controller.retainedAudioCount, 0); XCTAssertEqual(native.releases, 0)
        XCTAssertEqual(r.controller.view, .empty)
        exit.signal(); await r.settle()
        XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(native.releases, 1)
        try r.assertZero()
    }

    func testProductionPathRawPreviewExplicitCopyAndLiveOrdinaryPositiveControl() async throws {
        let r = try UndoRig(); defer { try! r.close() }
        r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000)); r.send(.stopRequested); await r.settle()
        XCTAssertEqual(r.ordinaryRuns, 1); XCTAssertTrue(r.entries.contains(.stash)); XCTAssertTrue(r.entries.contains(.resolve))
        XCTAssertTrue(r.accesses.contains(.configure)); XCTAssertTrue(r.accesses.contains(.prune))
        XCTAssertEqual(r.writes, 1); XCTAssertGreaterThan(r.removes, 0)
        XCTAssertGreaterThan(r.historyWrites, 0); XCTAssertEqual(r.provider.calls, 1)
        XCTAssertGreaterThan(r.inserts, 0); XCTAssertGreaterThan(r.corrections, 0); XCTAssertGreaterThan(r.resultsPublished, 0)
        XCTAssertTrue(try r.snapshot().keys.contains(where: { $0.hasSuffix(".txt") }))
        try r.armZero()
        r.offer(); let old = r.accepted.last!.operation
        XCTAssertTrue(old.shouldAbort); XCTAssertEqual(r.controller.retainedAudioCount, 8000)
        let undo = r.button(.undo); XCTAssertEqual(undo.accessibilityLabel(), "Undo canceled dictation")
        r.click(undo); let job = r.controller.activeJob!
        XCTAssertNotEqual(job.operation.id, old.id); XCTAssertNil(job.operation.diagnostics)
        r.click(undo); await r.settle()
        XCTAssertEqual(r.loads, 1); XCTAssertEqual(r.client.calls, 2)
        XCTAssertEqual(r.controller.view, .preview(job.token, " raw preview \n"))
        XCTAssertEqual(r.controller.retainedAudioCount, 0); XCTAssertTrue(r.copies.isEmpty)
        r.click(r.button(.copy)); XCTAssertEqual(r.copies, [" raw preview \n"])
        XCTAssertTrue(old.shouldAbort); try r.assertZero()
    }

    func testDefaultMissingNullFalseMalformedCodableFailClosed() throws {
        XCTAssertFalse(Settings().canceledCaptureUndoEnabled)
        for json in ["{}", #"{"canceledCaptureUndoEnabled":null}"#, #"{"canceledCaptureUndoEnabled":false}"#] {
            XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).canceledCaptureUndoEnabled)
        }
        for value in ["1", #""true""#, "[]", "{}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data("{\"canceledCaptureUndoEnabled\":\(value)}".utf8)))
        }
        var s = Settings(); s.canceledCaptureUndoEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).canceledCaptureUndoEnabled)
    }

    func testDefaultAndExcludedCancelPreserveEffectsAndNeverProbeSecurity() async throws {
        for enabled in [false, true] {
            let r = try UndoRig(); defer { try! r.close() }
            r.settings.canceledCaptureUndoEnabled = enabled; r.physical = false
            try r.armZero(); r.offer(); await r.settle()
            XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.securityReads, 0)
            XCTAssertTrue(r.effects.contains(.hud(.cancelled)))
            if !enabled { XCTAssertTrue(r.effects.contains(.stopCapture(discard: true))); XCTAssertTrue(r.effects.contains(.discardStreamWindow)) }
            try r.assertZero()
        }
    }

    func testOptInTimingStartingAndLiveExclusions() async throws {
        for mode in 0..<5 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            if mode == 0 { r.settings.canceledCaptureUndoEnabled = false }
            if mode == 1 { r.acknowledge = false }
            if mode == 3 { r.security = .unavailable }
            if mode == 4 { r.security = .secure }
            _ = r.start(live: mode == 2); r.engine.feed(Array(repeating: 0.25, count: 8000))
            r.settings.canceledCaptureUndoEnabled = true; r.cancel(); await r.settle()
            XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.loads, 0); try r.assertZero()
        }
    }

    func testWholeSampleCapsFiniteRMSAndElapsed() async throws {
        for (count, value, elapsed, allowed) in [(6399,Float(0.25),1.0,false),(6400,0.25,10,true),(160000,0.25,10,true),(160001,0.25,1,false),(8000,0,1,false),(8000,Float.nan,1,false),(8000,Float.infinity,1,false),(8000,0.00001,1,false),(8000,0.25,10.001,false)] {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            _ = r.start(); r.engine.feed(Array(repeating: value, count: count)); r.clock.time += elapsed; r.cancel()
            XCTAssertEqual(r.controller.view.token != nil, allowed, "count \(count) elapsed \(elapsed)")
            XCTAssertEqual(r.recorder.retainedAudioCounts.samples, 0)
            XCTAssertEqual(r.recorder.retainedAudioCounts.preRoll, 0); XCTAssertFalse(r.recorder.retainedAudioCounts.converter)
            XCTAssertTrue(r.admission.isAvailable); XCTAssertEqual(r.engine.starts, 1)
            await r.settle(); try r.assertZero()
        }
        var tail = Array(repeating: Float(0.25), count: 8000); tail[7999] = .nan
        XCTAssertFalse(CanceledCaptureLimits.accepts(tail, elapsed: 1))
    }

    func testMetadataBoundsWholeRequestNoTruncation() throws {
        for (path, language, dictionary, allowed) in [(4096,64,128,true),(4097,64,128,false),(4096,65,128,false),(4096,64,129,false)] {
            var s = Settings(); s.whisperModelPath = String(repeating: "m", count: path); s.language = String(repeating: "e", count: language)
            s.dictionary = Array(repeating: "hint", count: dictionary)
            XCTAssertEqual(CanceledCaptureLimits.accepts(RecognitionRequest(settings: s)), allowed)
        }
        var s = Settings(); s.dictionary = [String(repeating: "é", count: 8192)]
        XCTAssertTrue(CanceledCaptureLimits.accepts(RecognitionRequest(settings: s)))
        s.dictionary[0] += "x"; XCTAssertFalse(CanceledCaptureLimits.accepts(RecognitionRequest(settings: s)))
    }

    func testExactOfferTTLStaleTimersAndDoubleUndo() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.offer(); let stale = r.button(.undo); let timers = r.clock.stale
        r.clock.time += 3; r.click(stale)
        XCTAssertEqual(r.controller.view, .empty); XCTAssertNil(r.controller.activeJob)
        r.offer(); let current = r.controller.view
        timers.forEach { $0() }; r.click(stale); XCTAssertEqual(r.controller.view, current)
        r.undo(); r.undo(); await r.settle(); XCTAssertEqual(r.client.calls, 1)
        let preview = r.controller.view
        // Retained old offer/work timer callbacks cannot expire a later preview.
        r.clock.stale.dropLast(2).forEach { $0() }
        XCTAssertEqual(r.controller.view, preview)
        try r.assertZero()
    }

    func testSlowTransferUsesAcceptedCancelDeadline() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.beforeTransfer = { r.clock.time += 3 }
        r.offer(); XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.controller.retainedAudioCount, 0)
        await r.settle(); try r.assertZero()
    }

    func testEmptyUnavailableOversizeAndLoadFailureHaveNoStorageOrRetry() async throws {
        for scenario in 0..<6 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            switch scenario {
            case 0: r.client.text = nil
            case 1: r.client.text = ""
            case 2: r.client.text = " \n"
            case 3: r.client.text = String(repeating: "é", count: 8193)
            case 4: r.modelVerified = false
            default: r.loadFails = true
            }
            r.offer(); r.undo(); await r.settle()
            XCTAssertEqual(r.controller.view, .empty); XCTAssertNil(r.controller.activeJob)
            XCTAssertEqual(r.controller.retainedAudioCount, 0); XCTAssertTrue(r.copies.isEmpty)
            if scenario == 4 { XCTAssertEqual(r.loads, 0); XCTAssertEqual(r.client.calls, 0) }
            try r.assertZero()
        }
    }

    func testTextCapExactAndPreviewTTLDoesNotRenewOnCopy() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.client.text = String(repeating: "é", count: 8192)
        r.offer(); r.undo(); await r.settle(); let button = r.button(.copy)
        r.clock.advance(29.999); r.click(button); XCTAssertEqual(r.copies.count, 1)
        r.clock.time += 0.001; r.click(button); XCTAssertEqual(r.copies.count, 1)
        XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.clock.timers.count, 0); try r.assertZero()
    }

    func testConfigAndSecurityRefuseAtCancelUndoCopyAndMonitor() async throws {
        for boundary in 0..<4 {
            for secure in [false, true] {
                let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
                r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000))
                func refuse() { if secure { r.security = .unavailable } else { r.configValid = false } }
                if boundary == 0 { refuse() }; r.cancel()
                if boundary == 1 { refuse() }; r.undo(); await r.settle()
                if boundary == 2 { refuse() }
                if boundary == 3 { refuse(); r.clock.advance(0.2) }
                r.click(r.button(.copy))
                XCTAssertTrue(r.copies.isEmpty); XCTAssertEqual(r.controller.view, .empty)
                XCTAssertEqual(r.controller.retainedAudioCount, 0); try r.assertZero()
            }
        }
    }

    func testQueuedRevocationReleasesOwnerWithoutLoadingOrBlockingNextBarrier() async throws {
        for expire in [false, true] {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let gate = UndoGate(), entered = gate.entered
            r.chain = Task { await gate.wait() }
            await fulfillment(of: [entered], timeout: 2)
            r.offer(); r.undo(); let job = r.controller.activeJob!
            if expire { r.clock.advance(15) } else { r.controller.invalidate() }
            XCTAssertEqual(job.audioCount, 0); XCTAssertTrue(job.operation.shouldAbort)
            XCTAssertNotNil(r.controller.activeJob)
            await gate.release(); await r.settle()
            XCTAssertNil(r.controller.activeJob); XCTAssertEqual(r.loads, 0); XCTAssertEqual(r.client.calls, 0)
            var next = false
            let tail = Task { await r.chain?.value; next = true }; await tail.value; XCTAssertTrue(next)
            try r.assertZero()
        }
    }

    func testResidentAsyncBoundaryRechecksEveryAuthority() async throws {
        for change in 0..<4 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let gate = UndoGate(), entered = gate.entered
            r.residentBoundary = { await gate.wait() }
            r.offer(); r.undo(); await fulfillment(of: [entered], timeout: 2)
            switch change {
            case 0: r.security = .secure
            case 1: r.configValid = false
            case 2: r.controller.shutdown()
            default: _ = r.start()
            }
            await gate.release(); await r.settle()
            XCTAssertEqual(r.loads, 0); XCTAssertEqual(r.client.calls, 0); XCTAssertEqual(r.controller.view, .empty)
            try r.assertZero()
        }
    }

    func testHeldNativeLoadRechecksAfterReturnAndKeepsDrainUntilExit() async throws {
        for change in 0..<4 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let entered = XCTestExpectation(description: "load entered"), exit = DispatchSemaphore(value: 0)
            r.onLoad = { entered.fulfill(); exit.wait() }
            r.offer(); r.undo(); await fulfillment(of: [entered], timeout: 2)
            switch change {
            case 0: r.security = .secure; r.clock.advance(0.2)
            case 1: r.configValid = false; r.clock.advance(0.2)
            case 2: r.controller.shutdown()
            default: r.offer()
            }
            XCTAssertNotNil(r.controller.activeJob); XCTAssertEqual(r.controller.retainedAudioCount, 0)
            exit.signal(); await r.settle()
            XCTAssertEqual(r.client.calls, 0); XCTAssertNil(r.controller.activeJob); XCTAssertEqual(r.controller.view, .empty)
            try r.assertZero()
        }
    }

    func testHeldASRRevocationPreventsPublicationAndNextNativeWaitsForActualExit() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.client.held = true; r.offer(); r.undo()
        await fulfillment(of: [r.client.entered], timeout: 2)
        let job = r.controller.activeJob!
        r.controller.invalidate(); XCTAssertTrue(r.client.abortRequested); XCTAssertEqual(job.audioCount, 0)
        // A new capture is permitted, but cannot retain a second Undo job/offer.
        r.offer(); XCTAssertEqual(r.controller.view, .empty)
        let next = UndoClient(), nextOperation = PendingOperation(name: "next native")
        r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: nextOperation, completes: true) {
            _ = await next.transcribe([0.2], initialPrompt: nil, language: nil, shouldAbort: nil)
        }
        XCTAssertEqual(next.calls, 0); XCTAssertFalse(job.operation.hasExited)
        r.client.exit.signal(); await r.settle()
        XCTAssertEqual(next.calls, 1); XCTAssertTrue(job.operation.hasExited)
        XCTAssertEqual(r.controller.view, .empty); XCTAssertNil(r.controller.activeJob); try r.assertZero()
    }

    func testPostASRAndPublicationDeadlineSecurityAndConfigRace() async throws {
        for change in 0..<4 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            r.client.held = true; r.offer(); r.undo()
            await fulfillment(of: [r.client.entered], timeout: 2)
            switch change {
            case 0: r.security = .unavailable
            case 1: r.configValid = false
            case 2: r.clock.time += 30
            default: r.controller.invalidate()
            }
            r.client.exit.signal(); await r.settle()
            XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.controller.retainedAudioCount, 0); try r.assertZero()
        }
    }

    func testStaleHUDDiscardAndDisableReenableCannotRevive() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.offer(); let old = r.button(.discard), undo = r.button(.undo)
        r.settings.canceledCaptureUndoEnabled = false; r.controller.configurationChanged()
        r.settings.canceledCaptureUndoEnabled = true; r.controller.configurationChanged()
        r.click(undo); XCTAssertEqual(r.controller.view, .empty)
        r.offer(); let current = r.controller.view; r.click(old); XCTAssertEqual(r.controller.view, current)
        r.click(r.button(.discard)); XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.clock.timers.count, 0)
        await r.settle(); try r.assertZero()
    }

    func testRecorderOwnedTransferStaleCallbackAdmissionWarmthAndDiagnostics() throws {
        let r = try UndoRig(); defer { try! r.close() }
        r.recorder.setWarm(true); r.offer()
        XCTAssertEqual(r.engine.starts, 1); XCTAssertFalse(r.engine.isRunning)
        r.recorder.setWarm(true); XCTAssertEqual(r.engine.starts, 1)
        XCTAssertTrue(r.settings.canceledCaptureUndoEnabled)
        let old = r.accepted.last!
        XCTAssertEqual(old.operation.diagnostics.map { _ in r.recorder.diagnosticSnapshot(for: old.operation.id)?.outcome == .signal }, true)
        r.controller.invalidate(); let current = r.start()
        XCTAssertNil(r.recorder.stopCanceledCapture(operationID: old.operation.id, retain: true))
        XCTAssertEqual(r.recorderGeneration, current.gen); XCTAssertTrue(r.engine.isRunning)
        let stale = r.engine.receive!
        r.engine.feed(Array(repeating: 0.25, count: 8000)); r.cancel()
        stale(UndoEngine.buffer(Array(repeating: 0.25, count: 8000)))
        XCTAssertEqual(r.recorder.retainedAudioCounts.samples, 0); XCTAssertEqual(r.recorder.retainedAudioCounts.preRoll, 0)
        XCTAssertFalse(r.recorder.retainedAudioCounts.converter); XCTAssertTrue(r.admission.isAvailable)
    }

    func testNoPostStartPCMInternalReasonAndPhysicalShortRelease() async throws {
        for kind in 0..<3 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero(); r.start()
            if kind > 0 { r.engine.feed(Array(repeating: 0.25, count: 8000)) }
            if kind == 1 { _ = r.host.keyboard(.cancelRequested(silent: true, reason: .internalCancellation)) }
            else { r.cancel(silent: true) }
            XCTAssertEqual(r.controller.view.token != nil, kind == 2)
            XCTAssertTrue(r.effects.contains(.hideHUD)); await r.settle(); try r.assertZero()
        }
    }

    func testReentrantAbortAndTransferCannotStopOrHideNewCapture() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        let old = r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000))
        old.operation.installAbort { r.start() }
        r.cancel()
        XCTAssertGreaterThan(r.machine.gen, old.gen + 1); XCTAssertTrue(r.machine.isCapturing)
        XCTAssertTrue(r.engine.isRunning); XCTAssertEqual(r.recorderGeneration, r.machine.gen)
        XCTAssertEqual(r.controller.view, .empty)
        let oldCancel = r.effects.firstIndex(of: .abortOperation(old.operation))!
        XCTAssertFalse(r.effects.suffix(from: oldCancel).contains(.hud(.cancelled)))
        await r.settle(); try r.assertZero()
    }

    func testActualB25TerminationCompatibilityAndExplicitCopyOwnership() async throws {
        for phase in 0..<3 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let clipboard = ExperimentRig(); XCTAssertTrue(clipboard.paste())
            r.offer()
            if phase > 0 { r.undo(); await r.settle() }
            if phase == 2 {
                // Use same explicit writer contract as production; changes count.
                r.onCopy = clipboard.board.copy
                r.click(r.button(.copy))
            }
            var update: ((Bool) -> Void)?, replies: [Bool] = [], failed = 0
            let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown, updater: { update = $0 },
                cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: {}, reply: { replies.append($0) }, failure: { failed += 1 })
            let request = CanceledCaptureTermination(undo: r.controller, coordinator: coordinator)
            XCTAssertEqual(request.request(), .terminateLater)
            XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.controller.retainedAudioCount, 0)
            update?(true)
            if phase == 1 { clipboard.board.writeResults = [false] }
            clipboard.fire(clipboard.timers[0]); clipboard.flush()
            if phase == 1 {
                XCTAssertEqual(replies, [false]); XCTAssertEqual(failed, 1)
                XCTAssertTrue(clipboard.delivery.restoreFailed); XCTAssertTrue(clipboard.delivery.isRestorePending)
                r.controller.configurationChanged(); XCTAssertEqual(r.controller.view, .empty)
                clipboard.board.writeResults = [true]; clipboard.delivery.beginShutdown { _ in }
            } else {
                XCTAssertEqual(replies, [true])
                if phase == 2 { XCTAssertEqual(clipboard.board.contents.first?.values[.string], Data(" raw preview \n".utf8)) }
            }
            try r.assertZero()
        }
    }
}

extension CanceledCaptureUndoTests {
    func testExcludedModesAndAuxiliaryEntryUseNoUndoAcquisition() async throws {
        for kind in 0..<7 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            switch kind {
            case 0:
                _ = r.host.keyboard(.startCommand(settings: r.settings, cleanupConfigured: true, focus: .editable, selection: "selection"))
            case 1:
                r.settings.outputMode = .selectedPreset; r.settings.transformPresets = [.init(name: "test", instruction: "rewrite")]
                r.settings.selectedPresetID = r.settings.transformPresets[0].id; r.start()
            case 2: XCTAssertNil(r.host.startAutomation())
            case 3:
                r.settings.transformPresets = [.init(name: "test", instruction: "rewrite")]; r.settings.selectedPresetID = r.settings.transformPresets[0].id
                _ = r.host.keyboard(.startSavedPreset(settings: r.settings, cleanupConfigured: true, selection: "selection", target: .init(focus: .editable)))
            case 4: XCTAssertTrue(r.host.beginTryout()); r.physical = false; r.send(.startDictation(settings: r.settings, cleanupConfigured: true, live: false))
            case 5: r.physical = false; r.send(.startDictation(settings: r.settings, cleanupConfigured: true, live: false))
            default: r.start(live: true)
            }
            r.engine.feed(Array(repeating: 0.25, count: 8000))
            r.send(.cancelRequested(silent: false, reason: .explicitCancel)); await r.settle()
            XCTAssertEqual(r.controller.view, .empty); XCTAssertEqual(r.loads, 0); XCTAssertEqual(r.securityReads, 0)
            r.host.endTryout(); try r.assertZero()
        }
    }

    func testActualMouseShortReleaseInternalLossAndPreemptionBeforeNewCapture() async throws {
        for mode in 0..<4 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let press = MousePress(button: 2, at: r.clock.time, tracksPhysicalState: true, inputEpoch: r.input.snapshot.epoch,
                admissionRevision: r.admission.revision, suspensionRevision: HotkeyMonitor.suspensionRevision)
            let router = DictationInputRouter(host: r.host, prepare: { .startDictation(settings: r.settings, cleanupConfigured: true, live: false) }, secureRefused: { XCTFail("safe") })
            router.mouse(.down(press)); r.engine.feed(Array(repeating: 0.25, count: 8000))
            switch mode {
            case 0: router.mouse(.up(press, short: true))
            case 1: router.mouse(.cancel(press))
            case 2: r.start() // invalidates before cancelOwnedMouse's internal preemption
            default: router.captureEnded(generation: r.machine.gen, reason: .deviceLost)
            }
            XCTAssertEqual(r.controller.view.token != nil, mode == 0)
            if mode == 2 { XCTAssertTrue(r.machine.isCapturing); XCTAssertFalse(r.frames.contains(where: { if case .offer = $0 { return true }; return false })) }
            let before = r.machine.gen; router.mouse(.up(press, short: true)); XCTAssertEqual(r.machine.gen, before)
            await r.settle(); try r.assertZero()
        }
    }

    func testHandsFreeAndStartBoundaryInvalidations() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.start(); _ = r.host.keyboard(.handsFreeLatched); r.engine.feed(Array(repeating: 0.25, count: 8000)); r.cancel()
        XCTAssertNotNil(r.controller.view.token)
        XCTAssertTrue(r.host.beginTryout()); XCTAssertEqual(r.controller.view, .empty); r.host.endTryout()
        r.offer(); let lease = r.host.beginShortcutRecording(); XCTAssertNotNil(lease); XCTAssertEqual(r.controller.view, .empty)
        r.host.endShortcutRecording(lease!)
        r.offer(); r.insertion.beforeStoredInsertion = r.controller.invalidate
        XCTAssertTrue(r.insertion.insertStored("explicit stored text")); XCTAssertEqual(r.controller.view, .empty)
        XCTAssertEqual(r.inserts, 1); r.inserts = 0
        await r.settle(); try r.assertZero()
    }

    func testModelVerificationIsReadOnlyMissingUnknownAndChangedMetadataRefuse() throws {
        let r = try UndoRig(); defer { try! r.close() }
        let directory = r.root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ModelCatalog.default.filename)
        try Data("model fixture metadata only".utf8).write(to: url)
        let cache = VerifiedCache(url: directory.appendingPathComponent("verified.json")); cache.record(url)
        var s = Settings(); s.whisperModelPath = url.path
        let before = try r.snapshot()
        XCTAssertTrue(CanceledCaptureModel.verified(RecognitionRequest(settings: s), cache: cache, directory: directory))
        XCTAssertFalse(CanceledCaptureModel.verified(RecognitionRequest(settings: s), cache: cache))
        XCTAssertEqual(try r.snapshot(), before)
        try Data("changed size".utf8).write(to: url)
        let changed = try r.snapshot()
        XCTAssertFalse(CanceledCaptureModel.verified(RecognitionRequest(settings: s), cache: cache, directory: directory))
        XCTAssertEqual(try r.snapshot(), changed)
        s.whisperModelPath = directory.appendingPathComponent("custom.bin").path
        XCTAssertFalse(CanceledCaptureModel.verified(RecognitionRequest(settings: s), cache: cache, directory: directory))
        try FileManager.default.removeItem(at: url); s.whisperModelPath = url.path
        XCTAssertFalse(CanceledCaptureModel.verified(RecognitionRequest(settings: s), cache: cache, directory: directory))
    }

    func testVerificationBoundaryAndPreASRLoadDeadlineRaces() async throws {
        for mode in 0..<4 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let entered = XCTestExpectation(description: "verification entered"), exit = DispatchSemaphore(value: 0)
            var first = true
            r.onVerify = { if first { first = false; entered.fulfill(); exit.wait() } }
            r.offer(); r.undo(); await fulfillment(of: [entered], timeout: 2)
            switch mode {
            case 0: r.configValid = false
            case 1: r.security = .secure
            case 2: r.controller.shutdown()
            default: r.clock.time += 15
            }
            exit.signal(); await r.settle()
            XCTAssertEqual(r.loads, 0); XCTAssertEqual(r.client.calls, 0); XCTAssertEqual(r.controller.view, .empty)
            try r.assertZero()
        }
    }

    func testFreshResidentHandleUsesFrozenRequestRawAndNeverOldWindow() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.recognition = CanceledCaptureRecognition(controller: r.controller, resident: { ("/fake/frozen.bin", r.client) },
            verify: { _ in true }, load: { _ in XCTFail("resident match must not load alternate model"); return r.client })
        r.offer()
        let frozen = r.accepted.last!.recognition
        r.settings.dictionary = ["changed"]; r.settings.language = "hi"
        r.settings.snippets = ["raw preview": "DO NOT EXPAND"]
        r.settings.replacements = [.init(source: "raw", replacement: "DO NOT REPLACE")]
        r.undo(); let job = r.controller.activeJob!; await r.settle()
        XCTAssertEqual(job.request, frozen); XCTAssertEqual(r.client.language, "en")
        XCTAssertTrue(r.client.prompt?.contains("frozen hint") == true); XCTAssertFalse(r.client.prompt?.contains("changed") == true)
        XCTAssertEqual(r.controller.view, .preview(job.token, " raw preview \n")); XCTAssertEqual(r.controller.retainedAudioCount, 0)
        try r.assertZero()
    }

    func testOldNativeExitDoesNotClearNewCaptureEligibility() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.client.held = true; r.offer(); r.undo(); await fulfillment(of: [r.client.entered], timeout: 2)
        let newCapture = r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000))
        r.client.exit.signal(); await r.settle()
        XCTAssertTrue(r.machine.isCapturing); XCTAssertFalse(newCapture.operation.shouldAbort)
        r.cancel(); XCTAssertNotNil(r.controller.view.token)
        try r.assertZero()
    }

    func testRecorderRouteCapConversionAndReentrantStopAreWholeRefusals() throws {
        for reason in [AudioRecorder.EndReason.deviceLost, .sampleLimit] {
            let r = try UndoRig(); defer { try! r.close() }
            r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000)); r.recorder.endCapture(reason); r.cancel()
            XCTAssertEqual(r.controller.view, .empty); XCTAssertTrue(r.admission.isAvailable)
            XCTAssertEqual(r.recorder.retainedAudioCounts.samples, 0)
        }
        let engine = UndoEngine(), admission = CaptureAdmission(), operation = UUID()
        let recorder = AudioRecorder(engine: engine, admission: admission, conversion: { _ in nil })
        try recorder.start(diagnosticOperation: operation); engine.feed(Array(repeating: 0.25, count: 8000))
        engine.onStop = { do { try recorder.start(diagnosticOperation: UUID()); XCTFail("reentrant start must refuse") } catch {} }
        XCTAssertNil(recorder.stopCanceledCapture(operationID: operation, retain: true))
        XCTAssertTrue(admission.isAvailable); XCTAssertEqual(recorder.retainedAudioCounts.samples, 0)
        XCTAssertFalse(recorder.retainedAudioCounts.converter)
    }

    func testAllUndoOutcomesKeepRecoveryPoliciesAndCanariesUnchanged() async throws {
        for recovery in [false, true] {
            for result: String? in ["raw", nil, "", String(repeating: "x", count: 16_385)] {
                let r = try UndoRig(); defer { try! r.close() }
                r.settings.recoveryAudioEnabled = recovery; try r.store.save(r.settings)
                // Live actual writer/remover and corpus policy proved in ordinary positive control.
                r.recordings.configure(settings: r.settings, error: nil)
                try r.armZero(); r.client.text = result
                r.offer(); r.undo(); await r.settle(); try r.assertZero()
            }
        }
    }

    func testStaleOfferAndWorkTimersCannotExpireLaterPreview() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.offer(); let oldOfferTimers = r.clock.stale
        r.undo(); let oldWorkTimers = r.clock.stale
        await r.settle(); let preview = r.controller.view
        r.clock.time += 3; oldOfferTimers.forEach { $0() }; XCTAssertEqual(r.controller.view, preview)
        // Old job publication deadline can coincide with preview's deadline only
        // with instantaneous ASR; move preview publication later in next case.
        r.controller.invalidate(); r.clock.time = 200
        r.client.held = true; r.offer(); r.undo(); await fulfillment(of: [r.client.entered], timeout: 2)
        let canceledJobTimers = r.clock.stale
        r.clock.time += 5; r.client.exit.signal(); await r.settle(); let delayedPreview = r.controller.view
        r.clock.time = 230; (oldWorkTimers + canceledJobTimers).forEach { $0() }
        XCTAssertEqual(r.controller.view, delayedPreview); try r.assertZero()
    }

    func testActualHubPassiveMixedNetZeroGeneralAndDisableErrorHooks() throws {
        let r = try UndoRig(); defer { try! r.close() }
        let hub = HubModel(store: r.store, history: r.history, clipboard: { _ in XCTFail("Hub clipboard") }, recordings: r.recordings,
            shortcutLabels: ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } }), diagnostics: DiagnosticStore())
        hub.settings = r.store.load(); hub.flushPendingSave()
        var general = 0, passive = 0, invalidations = 0, validities: [Bool] = []
        hub.onSaved = { general += 1 }; hub.onMouseBindingSaved = { passive += 1 }
        hub.onCanceledCaptureInvalidate = { invalidations += 1; r.controller.invalidate() }
        hub.onCanceledCaptureConfigurationChanged = { validities.append($0); r.controller.configurationChanged(valid: $0) }
        hub.settings.canceledCaptureUndoEnabled = false; hub.flushPendingSave()
        XCTAssertEqual(general, 0); XCTAssertEqual(passive, 1); XCTAssertGreaterThan(invalidations, 0)
        hub.settings.canceledCaptureUndoEnabled = true; hub.settings.mouseBinding = .init(buttonNumber: 2)
        hub.settings.keepLastOriginalEnabled = true; hub.settings.clipboardReceiptRestoreEnabled = true; hub.flushPendingSave()
        XCTAssertEqual(general, 0); XCTAssertEqual(passive, 2)
        hub.settings.canceledCaptureUndoEnabled = false; hub.settings.canceledCaptureUndoEnabled = true
        hub.settings.warmMic.toggle(); hub.settings.warmMic.toggle(); hub.flushPendingSave()
        XCTAssertEqual(general, 0); XCTAssertEqual(passive, 3)
        hub.settings.warmMic.toggle(); hub.flushPendingSave(); XCTAssertEqual(general, 1)
        r.offer(); hub.settings.canceledCaptureUndoEnabled = false; XCTAssertEqual(r.controller.view, .empty)
        hub.flushPendingSave()
        try Data(#"{"canceledCaptureUndoEnabled":"invalid"}"#.utf8).write(to: r.store.url)
        hub.settings.showHudAlways.toggle(); hub.flushPendingSave()
        XCTAssertNotNil(hub.loadError); XCTAssertEqual(validities.last, false)
        XCTAssertEqual(r.backend.reads + r.backend.statuses + r.backend.adds + r.backend.updates + r.backend.deletes, 0)
        hub.flushPendingSave()
    }
}

extension CanceledCaptureUndoTests {
    func testActualResamplerDrainIsIncludedInWholeBufferDecision() throws {
        for outputCount in [6399, 6400, 160000, 160001] {
            let clock = UndoClock(), engine = UndoEngine(), operation = UUID()
            let recorder = AudioRecorder(engine: engine, captureClock: { clock.time }, scheduleRoute: clock.schedule)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputCount * 3))!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(buffer.frameLength))
            let reference = Resampler()
            let head = reference.convert(buffer, to: AudioRecorder.targetFormat) ?? []
            let expected = head + reference.flush()
            XCTAssertEqual(expected.count, outputCount)
            try recorder.start(diagnosticOperation: operation); engine.receive?(buffer)
            XCTAssertTrue(recorder.retainedAudioCounts.converter)
            let transferred = recorder.stopCanceledCapture(operationID: operation, retain: true)
            XCTAssertEqual(transferred != nil, (6400...160000).contains(expected.count))
            if let transferred { XCTAssertEqual(transferred, expected) }
            XCTAssertEqual(recorder.retainedAudioCounts.samples, 0); XCTAssertFalse(recorder.retainedAudioCounts.converter)
            XCTAssertEqual(recorder.retainedAudioCounts.preRoll, 0)
        }
    }

    func testTapResetBeforeCancelAndOldRouteCallbackAfterTransferRefuse() throws {
        let r = try UndoRig(); defer { try! r.close() }
        r.start(); let oldRoute = r.engine.changed!
        r.engine.feed(Array(repeating: 0.25, count: 8000)); oldRoute(); r.cancel()
        XCTAssertEqual(r.controller.view, .empty); XCTAssertFalse(r.engine.isRunning)
        oldRoute(); r.clock.advance(1)
        XCTAssertFalse(r.engine.isRunning); XCTAssertEqual(r.engine.starts, 1)
        XCTAssertTrue(r.admission.isAvailable); XCTAssertFalse(r.recorder.retainedAudioCounts.converter)
    }

    func testRealQuitEntryDuringQueueLoadAndASRRevokesWithoutDroppingB25Provider() async throws {
        for phase in 0..<3 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            let clipboard = ExperimentRig(); XCTAssertTrue(clipboard.paste())
            let originalProvider = clipboard.current.provider
            let gate = UndoGate(), entered = XCTestExpectation(description: "load gate"), exit = DispatchSemaphore(value: 0)
            if phase == 0 {
                r.chain = Task { await gate.wait() }; await fulfillment(of: [gate.entered], timeout: 2)
            } else if phase == 1 { r.onLoad = { entered.fulfill(); exit.wait() } }
            else { r.client.held = true }
            r.offer(); r.undo()
            if phase == 1 { await fulfillment(of: [entered], timeout: 2) }
            if phase == 2 { await fulfillment(of: [r.client.entered], timeout: 2) }
            let job = r.controller.activeJob!
            var update: ((Bool) -> Void)?, replies: [Bool] = []
            let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown, updater: { update = $0 },
                cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: {}, reply: { replies.append($0) }, failure: { XCTFail("unexpected") })
            let quit = CanceledCaptureTermination(undo: r.controller, coordinator: coordinator)
            XCTAssertEqual(quit.request(), .terminateLater)
            XCTAssertTrue(job.operation.shouldAbort); XCTAssertEqual(job.audioCount, 0); XCTAssertNotNil(r.controller.activeJob)
            XCTAssertTrue(clipboard.current.provider === originalProvider); XCTAssertTrue(clipboard.delivery.isRestorePending)
            XCTAssertTrue(replies.isEmpty)
            if phase == 0 { await gate.release() }; if phase == 1 { exit.signal() }; if phase == 2 { r.client.exit.signal() }
            await r.settle(); XCTAssertNil(r.controller.activeJob); XCTAssertEqual(r.controller.view, .empty)
            update?(true); clipboard.fire(clipboard.timers[0]); clipboard.flush()
            XCTAssertEqual(replies, [true]); try r.assertZero()
        }
    }
}

extension CanceledCaptureUndoTests {
    func testReentrantSecurityProbeNeverCopiesOrClearsNewCaptureAuthority() async throws {
        for phase in 0..<3 {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            r.offer()
            if phase == 1 { r.undo(); await r.settle() }
            let button = r.button(phase == 1 ? .copy : .undo)
            r.onSecurity = { r.onSecurity = nil; r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000)) }
            if phase == 2 { r.clock.advance(0.2) } else { r.click(button) }
            XCTAssertTrue(r.copies.isEmpty); XCTAssertTrue(r.machine.isCapturing)
            r.cancel(); XCTAssertNotNil(r.controller.view.token)
            await r.settle(); try r.assertZero()
        }
    }

    func testRealRecordingWriterFailurePositiveControlAndUndoZeroEntry() async throws {
        let r = try UndoRig(); defer { try! r.close() }
        var attempted = 0, removalAttempts = 0
        r.recordings = RecordingStore(directory: r.root.appendingPathComponent("failing-audio"), keepAll: false,
            access: { r.accesses.append($0) }, writer: { _, _ in attempted += 1; throw CocoaError(.fileWriteNoPermission) },
            remover: { url in removalAttempts += 1; try FileManager.default.removeItem(at: url) })
        r.start(); r.engine.feed(Array(repeating: 0.25, count: 8000)); r.send(.stopRequested); await r.settle()
        XCTAssertEqual(attempted, 1); XCTAssertGreaterThan(removalAttempts, 0)
        XCTAssertGreaterThan(r.historyWrites, 0); XCTAssertGreaterThan(r.inserts, 0)
        try r.armZero(); let beforeRemoval = removalAttempts
        r.offer(); r.undo(); await r.settle()
        XCTAssertEqual(attempted, 1); XCTAssertEqual(removalAttempts, beforeRemoval); try r.assertZero()
    }
}

extension CanceledCaptureUndoTests {
    func testFailedRestartRestoresOnlyFutureCaptureEligibilityAndPreservesPendingQuit() async throws {
        for pendingQuit in [false, true] {
            let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
            r.offer(); let oldUndo = r.button(.undo)
            r.controller.shutdown() // accepted restart claim revokes the old offer
            let update = UpdateTerminationIntent()
            var clipboard: ((Bool) -> Void)?, replies: [Bool] = []
            let coordinator = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: {
                update.request(waitingForInstall: true, committing: true, cancelInstall: {}, reply: $0)
            }, cancelClipboard: {}, cancelUpdater: update.cancel,
                reply: { replies.append($0) }, failure: r.controller.quitCanceled)
            let quit = CanceledCaptureTermination(undo: r.controller, coordinator: coordinator)
            if pendingQuit { XCTAssertEqual(quit.request(), .terminateLater) }
            XCTAssertEqual(update.installFailed(releaseRestart: quit.restartFailed), pendingQuit)
            r.controller.configurationChanged(); r.click(oldUndo)
            XCTAssertEqual(r.controller.view, .empty, "failure never revives old authority")
            r.offer()
            XCTAssertEqual(r.controller.view.token != nil, !pendingQuit)
            if pendingQuit {
                XCTAssertTrue(replies.isEmpty, "clipboard still owns quit settlement")
                clipboard?(false)
                XCTAssertEqual(replies, [false])
                r.offer(); XCTAssertNotNil(r.controller.view.token)
            }
            await r.settle(); try r.assertZero()
        }
    }
    func testPendingQuitStaysShutDownAndCanceledQuitRequiresFutureDeliberateCapture() async throws {
        let r = try UndoRig(); defer { try! r.close() }; try r.armZero()
        r.offer(); let oldUndo = r.button(.undo)
        var clipboard: ((Bool) -> Void)?, updater: ((Bool) -> Void)?
        let coordinator = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: { updater = $0 },
            cancelClipboard: {}, cancelUpdater: {}, reply: { _ in }, failure: r.controller.quitCanceled)
        let quit = CanceledCaptureTermination(undo: r.controller, coordinator: coordinator)
        XCTAssertEqual(quit.request(), .terminateLater)
        r.offer(); XCTAssertEqual(r.controller.view, .empty, "physical entry cannot reopen Undo while quit waits")
        clipboard?(false); updater?(true)
        r.controller.configurationChanged(); r.click(oldUndo); XCTAssertEqual(r.controller.view, .empty)
        r.offer(); XCTAssertNotNil(r.controller.view.token, "only future deliberate capture creates fresh eligibility")
        await r.settle(); try r.assertZero()
    }
}

extension CanceledCaptureUndoTests {
    func testSafeStartB57ColdRefusalExitsAndPreparedBorrowHasZeroGuardWrites() async throws {
        let p = try PreparationAppRig(), r = try UndoRig()
        defer { r.foundationResident = nil; try! r.close() }
        r.settings = p.store.load(); r.settings.canceledCaptureUndoEnabled = true
        r.foundationFactory = p.factory
        try r.armZero(); r.offer(); r.undo(); await r.settle()
        XCTAssertEqual(r.controller.view, .empty); XCTAssertNil(r.controller.activeJob)
        XCTAssertEqual(r.preparationNotices, [.preparedResidentRequired])
        XCTAssertTrue(p.probe.paths.isEmpty); XCTAssertTrue(p.probe.calls.isEmpty)
        try r.assertZero()
        let request = RecognitionRequest(settings: r.settings)
        let prepared = try await RecognitionAcquisition.prepare(request: request, resident: nil, factory: p.factory,
            operation: PendingOperation(name: "deliberate preparation"))
        r.foundationResident = prepared.resident
        let warmBytes = try Data(contentsOf: p.health.appendingPathComponent("health.json")), warmWrites = p.faults.journalWrites
        r.offer(); r.undo(); await r.settle()
        XCTAssertEqual(r.controller.view, .empty); XCTAssertNil(r.controller.activeJob)
        XCTAssertEqual(r.preparationNotices, [.preparedResidentRequired, .preparedResidentRequired])
        XCTAssertEqual(p.probe.calls.count, 1); XCTAssertEqual(p.faults.journalWrites, warmWrites)
        XCTAssertEqual(try Data(contentsOf: p.health.appendingPathComponent("health.json")), warmBytes)
        // A fresh standard operation primes real readiness. The refused offer is already disposed.
        let real = try await p.factory.acquire(request: request, resident: prepared.resident,
            operation: PendingOperation(name: "new real origin"))
        _ = await real.recognize([Float](repeating: 0.2, count: 8000), pass: .fullFinal)
        r.foundationResident = real.resident
        p.probe.outputs = [.init(status: 0, segments: ["native original"])]
        let bytes = try Data(contentsOf: p.health.appendingPathComponent("health.json")), writes = p.faults.journalWrites
        p.probe.admission = { _, policy in XCTAssertEqual(policy, .readOnlyCatalog) }
        r.offer(); let token = try XCTUnwrap(r.controller.view.token); r.undo(); await r.settle()
        XCTAssertEqual(r.controller.view, .preview(token, "native original")); XCTAssertNil(r.controller.activeJob)
        XCTAssertEqual(p.probe.paths.count, 1); XCTAssertEqual(p.probe.calls.count, 3)
        XCTAssertEqual(p.faults.journalWrites, writes)
        XCTAssertEqual(try Data(contentsOf: p.health.appendingPathComponent("health.json")), bytes)
        try r.assertZero()
        p.probe.admission = nil
        try await p.close()
    }
}
