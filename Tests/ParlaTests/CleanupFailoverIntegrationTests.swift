import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

final class B21AppDocument {
    var bytes: Data?
    var historyBytes = Data("[]".utf8)
    var failWrite = false
    let backend = FakeCredentialBackend()
    init() throws {
        var s = Settings(); s.cleanup.provider = "openai-compatible"; s.cleanup.baseURL = "https://primary.test/v1"; s.cleanup.model = "primary"
        s.automationEnabled = true; s.nativePreparationSafeStartEnabled = false; s.historyEnabled = true; s.recoveryAudioEnabled = false
        bytes = try JSONEncoder().encode(s)
    }
    lazy var store = SettingsStore(url: URL(fileURLWithPath: "/synthetic-b21-app/settings.json"), credentials: CredentialStore(backend: backend),
        scratchpadIO: .init(read: { _ in self.bytes }, write: { b, _ in if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }; self.bytes = b }),
        documentIO: .init(read: { self.bytes }), atomicWrite: { b, _ in if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }; self.bytes = b })
    lazy var history = HistoryStore(url: URL(fileURLWithPath: "/synthetic-b21-app/history.json"), persistence: .init(read: { _ in self.historyBytes }, writeAtomically: { b, _ in self.historyBytes = b }))
    var row: CleanupBackup { .init(baseURL: "https://backup.test/v1", model: "backup", source: .keylessCompatible) }
    func enable(two: Bool = false) throws -> Settings {
        let rows = [row] + (two ? [.init(baseURL: "https://backup2.test/v1", model: "backup2", source: .keylessCompatible)] : [])
        _ = try store.confirmCleanupFailover(store.reviewCleanupFailover(backups: rows)); return store.load()
    }
}
struct B21AppHTTP: HTTPPosting {
    let action: (URLRequest) async throws -> (Data, URLResponse)
    func post(_ r: URLRequest) async throws -> (Data, URLResponse) { try await action(r) }
}
final class B21AppHandle: HistoryRetryHTTPHandle {
    let start: () -> Void, stop: () -> Void
    init(start: @escaping () -> Void, stop: @escaping () -> Void = {}) { self.start = start; self.stop = stop }
    func resume() { start() }; func cancel() { stop() }
}
func b21Response(_ r: URLRequest, status: Int, text: String = "Polished.") -> (Data, URLResponse) {
    let b = status == 200 ? Data("{\"choices\":[{\"message\":{\"content\":\"\(text)\"}}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3}}".utf8) : Data("{}".utf8)
    return (b, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
func b21CanonicalBody(_ request: URLRequest) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
func b21Deliver(_ request: URLRequest, _ callbacks: HistoryRetryHTTPCallbacks, status: Int, text: String = "Polished.") {
    let (data, response) = b21Response(request, status: status, text: text)
    _ = callbacks.response(response as! HTTPURLResponse); _ = callbacks.data(data); callbacks.completed(nil); callbacks.exited()
}
final class B21AppRecognition: RecognitionClient {
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? { "polished" }
}
final class B21Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0.0
    var now: TimeInterval { lock.withLock { value } }
    func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
}
/// Fake completion and true exit are independent. Cleanup is idempotent even if
/// an assertion/expectation times out, and never relies on cancellation as exit.
final class B21HeldHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: HistoryRetryHTTPCallbacks?
    private var request: URLRequest?
    private var released = false, didCancel = false
    var entered: () -> Void = {}, canceled: () -> Void = {}
    var driver: HistoryRetryHTTP.Driver { { request, callbacks in
        let alreadyReleased = self.lock.withLock { self.request = request; self.callbacks = callbacks; return self.released }
        return B21AppHandle(start: {
            self.entered()
            if alreadyReleased { self.release() }
        }, stop: {
            let first = self.lock.withLock { let first = !self.didCancel; self.didCancel = true; return first }
            if first { callbacks.completed(CancellationError()); self.canceled() }
        })
    } }
    func release(lateSuccess: Bool = false) {
        let state = lock.withLock { released = true; return (request, callbacks) }
        if let request = state.0, let callbacks = state.1 {
            if lateSuccess { let (data, response) = b21Response(request, status: 200); _ = callbacks.response(response as! HTTPURLResponse); _ = callbacks.data(data) }
            callbacks.completed(nil); callbacks.exited()
        }
    }
}
func b21Evidence(_ object: [String: Any]) throws {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PARLA_B21_EVIDENCE"])
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
    try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10]))
}
@MainActor final class B21AppRig {
    let document: B21AppDocument
    let diagnostics = DiagnosticStore()
    lazy var machine = DictationSession(diagnostics: diagnostics)
    let admission = LocalCleanupAdmission()
    let clock = AutomationTestClock()
    let recordings: RecordingStore
    lazy var runtime = AutomationRuntime(clock: clock, enabled: { true })
    lazy var sink = HistoryPersistenceSink(history: document.history, settings: document.store)
    var accepted: DictationSession.Session?
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var inserts = 0, completions = 0, recognitions = 0, entries = 0
    var inserted: [String] = [], feedback: [String] = []
    var secureCompletion = false, expectsOwnedHistory = false
    var onCompleted: () -> Void = {}
    lazy var host = DictationInvocationHost(machine: machine, broker: runtime.broker, results: runtime.results,
        settings: { self.document.store.load() }, captureCleanupGrant: { self.document.store.captureCleanupFailoverGrant(settings: $0, origin: $1) },
        configured: { _ in true }, capabilities: { _ in nil }, secure: { false }, keyboardAllowed: { true }, automationAllowed: { true },
        explicitEntry: { self.entries += 1 }, send: { self.send($0) }, ordinaryBusyReason: { self.admission.ordinaryBusyReason }, busyFeedback: { self.feedback.append($0) })
    init(_ document: B21AppDocument) throws {
        self.document = document
        let parent = try XCTUnwrap(ProcessInfo.processInfo.environment["PARLA_B21_FIXTURE_ROOT"])
        let directory = URL(fileURLWithPath: parent).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let manifest = try XCTUnwrap(ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: manifest)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: ["path": directory.path, "ownerPID": ProcessInfo.processInfo.processIdentifier, "purpose": "B21 empty recording policy directory", "cleanup": "retained"]) + Data([10]))
        recordings = RecordingStore(directory: directory, keepAll: false, writer: { _, _ in XCTFail("No recording IO") }, remover: { _ in XCTFail("No removal") })
    }
    func makeRun() -> CleanupFailoverRun {
        let operation = accepted!.operation
        return CleanupFailoverRun(admit: { await MainActor.run { self.admission.admitOrdinaryFailover(operation) } })
    }
    func send(_ event: DictationSession.Event) {
        sink.beginEvent(for: event, currentGeneration: machine.gen)
        machine.send(event) { fx in
            switch fx {
            case .captureAccepted(let s): accepted = s; host.accepted(s)
            case .captureAcknowledged(let s): host.acknowledged(s)
            case .captureFinalizing(let s): host.finalizing(s)
            case .applyPreferencesAndStartCapture: send(.recorderStarted(gen: machine.gen))
            case .sampleFocus(let g): send(.focusSampled(gen: g, focus: .editable))
            case .polish(let s, let l): pending = (s, l)
            case .finalResult(let s, let r): host.completed(s, result: r)
            case .insertText(let text, _, _): inserts += 1; inserted.append(text)
            case .appendHistory: _ = sink.record(fx, metrics: { XCTAssertFalse(self.expectsOwnedHistory, "Participating history must own metrics"); return nil })
            case .abortOperation(let o): o.requestAbort()
            default: break
            }
        }
    }
    func start(automation: Bool) throws -> DictationSession.Session {
        if automation { XCTAssertNil(host.startAutomation()) }
        else {
            let settings = document.store.load()
            XCTAssertTrue(host.keyboard(.startDictation(settings: settings, cleanupConfigured: true, live: false,
                cleanupFailoverGrant: document.store.captureCleanupFailoverGrant(settings: settings, origin: .physicalOrdinary))))
        }
        let s = try XCTUnwrap(accepted); send(.stopRequested); return s
    }
    func run(_ s: DictationSession.Session, primary: HTTPPosting = B21AppHTTP(action: { _ in XCTFail("No primitive route"); throw CancellationError() }),
             primaryDriver: @escaping HistoryRetryHTTP.Driver = { r, c in B21AppHandle(start: { b21Deliver(r, c, status: 503) }) },
             driver: @escaping HistoryRetryHTTP.Driver, run: CleanupFailoverRun,
             previous: Task<Void, Never>? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             sleep: ((TimeInterval) async throws -> Void)? = nil, baseline: Bool = false) -> Task<Void, Never> {
        let dispatcher = DictationExecutionDispatcher(makePreview: { preconditionFailure("Ordinary dispatch only") }, ordinary: { session, samples, _ in
            let finalizer = OrdinaryDictationFinalization(recordings: self.recordings, settings: self.document.store)
            await finalizer.run(operation: session.operation, samples: samples, window: nil,
                prepare: { _, _ in await MainActor.run { self.recognitions += 1 }; return try! RecognitionHandle(request: session.recognition) { _ in B21AppRecognition() } },
                recognized: { _, raw in await MainActor.run {
                    self.send(.transcribed(session, raw: raw, probe: .init(focus: .editable, deferInsertionUntilClean: true)))
                    finalizer.resolve(transcript: raw, secure: false)
                    defer { self.pending = nil }; return self.pending
                } }, clean: { context in
                    if baseline {
                        // Same adapter, credential precedence, execution limits, exact
                        // request/input and primary schedule as the failover arm.
                        // Branch only AFTER that real primary attempt fails.
                        let policy = HistoryRetryExecutionPolicy(planned: 1, budget: 15, now: now)
                        let settings = context.0.effectiveSettings
                        let pipeline = Pipeline(outputSettings: settings, bundleID: context.1.bundleID, failureLogging: .contentFree) { selected in
                            let access = CleanupAccess.network(try resolveOrdinaryFailoverPrimaryCredential(settings: selected, env: [:], credentials: self.document.store.credentials))
                            return try ParlaCore.makeCleanupClient(settings: selected, env: [:], credentials: self.document.store.credentials, access: access,
                                http: HistoryRetryHTTP(policy: policy, driver: primaryDriver), executionPolicy: policy, usage: { _, _, _ in XCTFail("Failed baseline has no producer") })
                        }
                        return await pipeline.clean(transcript: context.1.raw)
                    }
                    return await DictationCleanupOutput.clean(session: context.0, landed: context.1, store: self.document.store, environment: [:],
                        primaryHTTP: primary, primaryDriver: primaryDriver, backupDriver: driver, now: now, sleep: sleep,
                        run: run, usage: { _, _, _ in XCTFail("No local usage") }, primitiveUsage: { _, _, _ in XCTFail("No global usage") })
                }, completed: { context, text, failure in await MainActor.run {
                    self.completions += 1; self.expectsOwnedHistory = baseline || run.participated
                    self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: self.secureCompletion ? .secure : .editable,
                        metrics: baseline ? PipelineMetrics() : (run.participated ? run.metrics : nil)))
                    self.onCompleted()
                } }, drain: { await run.drain() })
        })
        return dispatcher.enqueue(.ordinary(s, samples: [Float](repeating: 0.2, count: 8000), ledger: "fixture"), previous: previous, finished: {
            await MainActor.run { self.admission.exited(s.operation); self.host.finished(s.operation) }
        })
    }
}
final class CleanupFailoverIntegrationTests: XCTestCase {
    @MainActor func testB21ActualHostReducerQueueProcessingShippingAdapterAndResultOnly() async throws {
        for automation in [false, true] {
            let d = try B21AppDocument(); _ = try d.enable(); let rig = try B21AppRig(d), s = try rig.start(automation: automation)
            XCTAssertEqual(s.cleanupFailoverGrant?.operationID, s.operation.id)
            let run = rig.makeRun(); var backups = 0
            await rig.run(s, driver: { r, c in backups += 1; return B21AppHandle(start: { b21Deliver(r, c, status: 200) }) }, run: run).value
            XCTAssertEqual(backups, 1); XCTAssertEqual(run.snapshot.acceptedProducerOrdinal, 1); XCTAssertTrue(s.operation.hasExited)
            XCTAssertEqual(rig.completions, 1); XCTAssertEqual(rig.recognitions, 1)
            XCTAssertEqual(d.history.entries.count, 1)
            if automation { XCTAssertEqual(rig.runtime.results.read()?.text, "Polished."); XCTAssertEqual(rig.inserts, 0) }
            else { XCTAssertEqual(rig.inserted, ["Polished."]); XCTAssertEqual(d.history.entries.first?.metrics?.promptTokens, 12) }
        }
    }
    @MainActor func testB21CaptureWithoutGrantCannotGainOneAfterEnable() async throws {
        let d = try B21AppDocument(), rig = try B21AppRig(d), settings = d.store.load()
        XCTAssertNil(d.store.captureCleanupFailoverGrant(settings: settings, origin: .physicalOrdinary))
        let s = try rig.start(automation: false); _ = try d.enable()
        var backups = 0; let run = CleanupFailoverRun()
        await rig.run(s, primary: B21AppHTTP(action: { r in b21Response(r, status: 503) }), driver: { _, _ in backups += 1; return B21AppHandle(start: {}) }, run: run).value
        XCTAssertEqual(backups, 0); XCTAssertFalse(run.participated)
    }
    @MainActor func testB21ShippingLifecycleIntentCancelsPrimaryAndCanceledQuitCannotRevive() async throws {
        let d = try B21AppDocument(), settings = try d.enable(), rig = try B21AppRig(d), s = try rig.start(automation: true)
        let entered = expectation(description: "primary held"), canceled = expectation(description: "primary canceled"), held = B21HeldHTTP()
        held.entered = { entered.fulfill() }; held.canceled = { canceled.fulfill() }
        let run = rig.makeRun(), chain = rig.run(s, primaryDriver: held.driver, driver: { _, _ in XCTFail("No backups"); return B21AppHandle(start: {}) }, run: run)
        // No throws or early returns until the owned held work has been released.
        await fulfillment(of: [entered], timeout: 3)
        let coordinator = TerminationCoordinator(clipboard: { $0(false) }, updater: { $0(true) },
            localCleanup: { reply in rig.admission.beginShutdown(chain: { chain }, reply: reply) }, cancelLocalCleanup: { rig.admission.cancelShutdown() },
            cancelClipboard: {}, cancelUpdater: {}, reply: { _ in XCTFail("Canceled quit") }, failure: {}, onIntent: { AppDelegate.cleanupFailoverIntent(d.store) })
        XCTAssertEqual(coordinator.request(), .terminateCancel); XCTAssertTrue(s.operation.shouldAbort)
        await fulfillment(of: [canceled], timeout: 3); XCTAssertFalse(s.operation.hasExited)
        XCTAssertNotNil(rig.admission.ordinaryBusyReason)
        held.release(); await chain.value; await run.drain()
        XCTAssertTrue(s.operation.hasExited); XCTAssertNil(rig.admission.ordinaryBusyReason); XCTAssertNil(rig.runtime.results.read())
        XCTAssertNil(d.store.captureCleanupFailoverGrant(settings: settings, origin: .physicalOrdinary)); _ = try d.enable()
        XCTAssertNotNil(d.store.captureCleanupFailoverGrant(settings: d.store.load(), origin: .physicalOrdinary))
    }
    @MainActor func testB21ActiveBackupDisableRetainsActualExitQueueBarrier() async throws {
        let d = try B21AppDocument(); _ = try d.enable(); let rig = try B21AppRig(d), s = try rig.start(automation: true)
        let entered = expectation(description: "backup active"), canceled = expectation(description: "backup canceled"), held = B21HeldHTTP()
        held.entered = { entered.fulfill() }; held.canceled = { canceled.fulfill() }
        let run = rig.makeRun(), chain = rig.run(s, driver: held.driver, run: run)
        await fulfillment(of: [entered], timeout: 3)
        do { _ = try d.store.disableCleanupFailover(expected: d.store.load().cleanupFailover) } catch { XCTFail("Disable: \(error)") }
        await fulfillment(of: [canceled], timeout: 3); XCTAssertFalse(s.operation.hasExited)
        let next = PendingOperation(name: "next"), advanced = expectation(description: "next after exit")
        let successor = PendingOperationQueue.enqueue(previous: chain, operation: next, completes: true, work: { XCTAssertTrue(s.operation.hasExited); advanced.fulfill() })
        XCTAssertFalse(next.hasExited); held.release(); await successor.value; await run.drain()
        await fulfillment(of: [advanced], timeout: 3); XCTAssertNil(run.snapshot.acceptedProducerOrdinal)
    }
}


extension CleanupFailoverIntegrationTests {
    @MainActor func testB21ShippingAdapterOffRawPresetProfileLocalAndSnippetOriginsStayClosed() async throws {
        for kind in 0..<7 {
            let d=try B21AppDocument();var s=try d.enable();let grant=d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)
            if kind == 0{s.outputMode = .raw}
            if kind == 1{s.cleanupEnabled=false}
            if kind == 2{let p=TransformPreset(name:"Rewrite",instruction:"Polish");s.transformPresets=[p];s.selectedPresetID=p.id;s.outputMode = .selectedPreset}
            if kind == 3{s.cleanup.model="profile-model"}
            if kind == 4{s.cleanup.provider="apple-intelligence";s.cleanup.localSourceLocale="en"}
            if kind == 5{s.snippets=["polished":"locked"]}
            let mode:DictationSession.Mode=kind == 6 ? .command(selection:"selection"):.dictation
            let session=DictationSession.Session(gen:1,mode:mode,settings:s,cleanupConfigured:true,diagnostics:nil,cleanupFailoverGrant:grant)
            let landed=DictationSession.Landed(landing:.history,raw:"polished",insertText:"",bundleID:nil,appName:nil)
            var primary=0,backup=0,local=0;let run=CleanupFailoverRun()
            let runtime=LocalCleanupRuntime(availability:{_ in local += 1;return .unavailable},language:{_ in XCTFail("Unavailable local language");return [:]},generate:{_,_ in XCTFail("Unavailable local generation");return ""},now:{0},appLocale:{"en"})
            _=await DictationCleanupOutput.clean(session:session,landed:landed,store:d.store,environment:[:],primaryHTTP:B21AppHTTP(action:{r in primary += 1;return b21Response(r,status:503)}),
                backupDriver:{_,_ in backup += 1;return B21AppHandle(start:{})},localRuntime:runtime,run:run,usage:{_,_,_ in},primitiveUsage:{_,_,_ in})
            XCTAssertEqual(backup,0);XCTAssertFalse(run.participated)
            XCTAssertEqual(primary,[0,1,4,5].contains(kind) ? 0:1)
            if kind == 4{XCTAssertEqual(local,1)}
        }
    }
    @MainActor func testB21WholeHistoryAndTransformAndEvalPrimitiveNeverAcquireBackup() async throws {
        let d=try B21AppDocument(),s=try d.enable();var posts=0
        let http=B21AppHTTP(action:{r in posts += 1;return b21Response(r,status:503)})
        // The same primitive used by eval remains single-provider with a configured chain.
        let primitive=try ParlaCore.makeCleanupClient(settings:s,env:[:],credentials:d.store.credentials,http:http,usage:{_,_,_ in})
        do{_=try await primitive.clean(transcript:"polished",context:.init(dictionary:[],snippets:[:],appName:nil));XCTFail("503")}catch{}
        XCTAssertEqual(posts,1)
        do{_=try await IntentionalTransform(source:"polished",instruction:"Rewrite",settings:s).run{selected in
            try ParlaCore.makeCleanupClient(settings:selected,env:[:],credentials:d.store.credentials,http:http,usage:{_,_,_ in})
        };XCTFail("503")}catch{}
        XCTAssertEqual(posts,2)
        let retry=try HistoryRetryRequest(settings:s,environment:[:],source:.init(raw:"polished"),applyPreset:false,credentials:d.store.credentials)
        do{_=try await retry.run(source:"polished",factory:{selected,env,access,usage in
            try ParlaCore.makeCleanupClient(settings:selected,env:env,credentials:d.store.credentials,access:access,http:http,usage:usage)
        });XCTFail("503")}catch{}
        XCTAssertEqual(posts,3);XCTAssertEqual(cleanupWarmURL(settings:s,env:[:],credentials:d.store.credentials)?.host,"primary.test")
    }
}

extension CleanupFailoverIntegrationTests {
    @MainActor func testB21SixSamePrimaryPairedComparisonsThroughActualAppSeams() async throws {
        for automation in [false, true] {
            for scenario in ["quick", "exhaustion", "terminal", "insufficient", "deadline", "delayedExit"] {
                var sharedPrimary: URLRequest?
                let primaryBoundary = scenario == "insufficient" ? 12.001 : 1.0
                for baseline in [true, false] {
                    let d = try B21AppDocument(); _ = try d.enable(two: true)
                    let rig = try B21AppRig(d), s = try rig.start(automation: automation), run = rig.makeRun(), clock = B21Clock(), sleeper = RecognitionTestLatch(), held = B21HeldHTTP()
                    let entered = XCTestExpectation(description: "held backup"), receipt = expectation(description: "logical receipt")
                    held.entered = { entered.fulfill() }
                    var requests: [URLRequest] = [], received = -1.0
                    rig.onCompleted = { received = clock.now; sleeper.signal(); receipt.fulfill() }
                    let primary: HistoryRetryHTTP.Driver = { r, c in
                        requests.append(r)
                        return B21AppHandle(start: { clock.set(primaryBoundary); b21Deliver(r, c, status: scenario == "terminal" ? 401 : 503) })
                    }
                    let backup: HistoryRetryHTTP.Driver = { r, c in
                        requests.append(r)
                        if scenario == "deadline" || scenario == "delayedExit" { return held.driver(r, c) }
                        return B21AppHandle(start: { clock.set(Double(requests.count)); b21Deliver(r, c, status: scenario == "quick" ? 200 : 503) })
                    }
                    let chain = rig.run(s, primaryDriver: primary, driver: backup, run: run, now: { clock.now }, sleep: { _ in await sleeper.wait() }, baseline: baseline)
                    if !baseline, scenario == "deadline" || scenario == "delayedExit" {
                        await fulfillment(of: [entered], timeout: 3); clock.set(15); sleeper.signal()
                    }
                    await fulfillment(of: [receipt], timeout: 3)
                    let frozen = run.snapshot, history = d.history.entries, result = rig.runtime.results.read()?.text, inserts = rig.inserted
                    let diagnostic = rig.diagnostics.snapshot().records.first { $0.id == s.operation.id }?.cleanupFailover
                    Metrics.shared.mark(.fnDown); Metrics.shared.update { $0.cleanupModel = "unrelated-job"; $0.promptTokens = 777 }
                    let globalBeforeExit = Metrics.shared.snapshot()
                    if !baseline, scenario == "deadline" || scenario == "delayedExit" {
                        XCTAssertFalse(s.operation.hasExited); XCTAssertNotNil(rig.admission.ordinaryBusyReason)
                        XCTAssertEqual(rig.completions, 1); XCTAssertEqual(received, 15)
                        clock.set(scenario == "delayedExit" ? 42 : 15)
                    }
                    // Always release every held fixture and sleeper before awaiting exit,
                    // including expectation/assertion failure paths.
                    held.release(lateSuccess: true); sleeper.signal(); await chain.value; await run.drain()
                    XCTAssertTrue(s.operation.hasExited); XCTAssertNil(rig.admission.ordinaryBusyReason)
                    XCTAssertEqual(run.snapshot, frozen); XCTAssertEqual(rig.diagnostics.snapshot().records.first { $0.id == s.operation.id }?.cleanupFailover, diagnostic)
                    XCTAssertEqual(Metrics.shared.snapshot(), globalBeforeExit); XCTAssertEqual(d.history.entries, history); XCTAssertEqual(rig.runtime.results.read()?.text, result); XCTAssertEqual(rig.inserted, inserts)
                    XCTAssertEqual(rig.completions, 1); XCTAssertEqual(rig.recognitions, 1)
                    let expectedText = !baseline && scenario == "quick" ? "Polished." : "polished"
                    XCTAssertEqual(automation ? result : inserts.first, expectedText)
                    XCTAssertEqual(d.history.entries.count, 1)
                    XCTAssertEqual(requests.count, baseline ? 1 : scenario == "exhaustion" ? 3 : ["quick", "deadline", "delayedExit"].contains(scenario) ? 2 : 1)
                    if baseline { sharedPrimary = requests.first; XCTAssertEqual(received, primaryBoundary) }
                    else {
                        let actual = try XCTUnwrap(requests.first), shared = try XCTUnwrap(sharedPrimary)
                        XCTAssertEqual(actual.url, shared.url); XCTAssertEqual(actual.httpMethod, shared.httpMethod)
                        XCTAssertEqual(try b21CanonicalBody(actual), try b21CanonicalBody(shared)); XCTAssertEqual(actual.allHTTPHeaderFields, shared.allHTTPHeaderFields); XCTAssertEqual(actual.timeoutInterval, shared.timeoutInterval)
                        XCTAssertEqual(run.snapshot.acceptedProducerOrdinal, scenario == "quick" ? 1 : nil)
                    }
                    try b21Evidence(["kind": "comparison", "case": scenario, "origin": automation ? "shortcutsOrdinary" : "physicalOrdinary", "arm": baseline ? "samePrimaryRaw" : "failover",
                        "primaryBoundary": primaryBoundary, "callerReceipt": received, "actualExit": clock.now, "waitAfterPrimary": received - primaryBoundary,
                        "requests": requests.count, "extraRequestsAfterPrimary": requests.count - 1, "destinations": requests.map { $0.url!.host! },
                        "primaryRequestBodyCanonical": try b21CanonicalBody(requests[0]).base64EncodedString(), "rawPrimaryBytesEqual": requests[0].httpBody == sharedPrimary?.httpBody,
                        "selected": expectedText, "acceptedProducer": run.snapshot.acceptedProducerOrdinal ?? -1, "completionCount": rig.completions,
                        "historyCount": history.count, "insertCount": inserts.count, "ownedSnapshotUnchangedAfterExit": run.snapshot == frozen])
                }
            }
        }
    }
    @MainActor func testB21HeldCredentialLeavesStoreAndMainResponsiveAndDeadlineDrains() async throws {
        for backupKey in [false, true] {
            let d = try B21AppDocument()
            if backupKey {
                let row = CleanupBackup(baseURL: "https://backup.test/v1", model: "backup", source: .scopedKeychain)
                _ = try d.store.confirmCleanupFailover(d.store.reviewCleanupFailover(backups: [row]))
            } else { _ = try d.enable() }
            let rig = try B21AppRig(d), s = try rig.start(automation: true), run = rig.makeRun(), clock = B21Clock(), sleeper = RecognitionTestLatch()
            let entered = expectation(description: "credential held"), receipt = expectation(description: "deadline receipt"), release = DispatchSemaphore(value: 0)
            var timedOut = false
            d.backend.onRead = {
                if !backupKey || d.backend.reads == 2 {
                    entered.fulfill(); timedOut = release.wait(timeout: .now() + 8) != .success
                }
            }
            rig.onCompleted = { sleeper.signal(); receipt.fulfill() }
            let chain = rig.run(s, driver: { _, _ in XCTFail("Expired credential cannot construct backup"); return B21AppHandle(start: {}) }, run: run, now: { clock.now }, sleep: { _ in await sleeper.wait() })
            await fulfillment(of: [entered], timeout: 3)
            let responsiveStart = ProcessInfo.processInfo.systemUptime
            _ = d.store.load(); d.store.revokeCleanupFailover()
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - responsiveStart, 0.5)
            XCTAssertEqual(rig.host.startAutomation(), .busy)
            clock.set(15); sleeper.signal(); await fulfillment(of: [receipt], timeout: 3)
            XCTAssertFalse(s.operation.hasExited); XCTAssertEqual(rig.runtime.results.read()?.text, "polished")
            release.signal(); sleeper.signal(); await chain.value; await run.drain()
            XCTAssertFalse(timedOut); XCTAssertEqual(rig.completions, 1); XCTAssertTrue(s.operation.hasExited)
            try b21Evidence(["kind": "responsiveness", "held": backupKey ? "backupCredential" : "primaryCredential", "mainAndStoreSeconds": ProcessInfo.processInfo.systemUptime - responsiveStart, "callerBeforeExit": true, "fixtureReleased": true])
        }
    }
    @MainActor func testB21BusyOwnerPreservesGrandfatheredCaptureAndQueuesOrDiscardsIt() async throws {
        for discard in [false, true] {
            let d = try B21AppDocument(); _ = try d.enable(); let rig = try B21AppRig(d), a = try rig.start(automation: false)
            // B starts before A selects eligible cleanup; the gate does not reserve
            // merely because A captured a grant.
            let settings = d.store.load()
            XCTAssertTrue(rig.host.keyboard(.startDictation(settings: settings, cleanupConfigured: true, live: false,
                cleanupFailoverGrant: d.store.captureCleanupFailoverGrant(settings: settings, origin: .physicalOrdinary))))
            let b = try XCTUnwrap(rig.accepted), run = CleanupFailoverRun(admit: { await MainActor.run { rig.admission.admitOrdinaryFailover(a.operation) } })
            let held = B21HeldHTTP(), entered = expectation(description: "A active"), receipt = expectation(description: "A logical result"), sleeper = RecognitionTestLatch(), clock = B21Clock()
            held.entered = { entered.fulfill() }; rig.onCompleted = { receipt.fulfill() }
            let chainA = rig.run(a, primaryDriver: held.driver, driver: { _, _ in XCTFail("No backup after expiry"); return B21AppHandle(start: {}) }, run: run, now: { clock.now }, sleep: { _ in await sleeper.wait() })
            await fulfillment(of: [entered], timeout: 3)
            let gen = rig.machine.gen, entries = rig.entries, reads = d.backend.reads
            XCTAssertFalse(rig.host.keyboard(.startDictation(settings: settings, cleanupConfigured: true, live: false)))
            XCTAssertEqual(rig.host.startAutomation(), .busy)
            let press = MousePress(button: 3, at: 0, tracksPhysicalState: false, inputEpoch: 0, admissionRevision: 0, suspensionRevision: 0)
            XCTAssertFalse(rig.host.mouseDown(press, prepare: { XCTFail("Busy before preparation"); return nil }, secureRefused: { XCTFail("No probe") }))
            XCTAssertEqual(rig.machine.gen, gen); XCTAssertEqual(rig.entries, entries); XCTAssertEqual(d.backend.reads, reads)
            XCTAssertTrue(rig.machine.isCapturing); XCTAssertFalse(b.operation.shouldAbort)
            // Production lifecycle guard refuses a still-recording successor.
            XCTAssertTrue(rig.admission.hasOrdinaryFailover && rig.machine.isCapturing)
            clock.set(15); sleeper.signal(); await fulfillment(of: [receipt], timeout: 3)
            XCTAssertTrue(rig.machine.isCapturing); XCTAssertFalse(b.operation.shouldAbort); XCTAssertFalse(a.operation.hasExited)
            XCTAssertTrue(rig.host.keyboard(.stopRequested))
            if discard { rig.send(.discardOwnedOperation(b.operation, generation: b.gen)) }
            rig.onCompleted = {}
            let runB = CleanupFailoverRun(admit: { await MainActor.run { rig.admission.admitOrdinaryFailover(b.operation) } })
            let chainB = rig.run(b, primaryDriver: { r, c in B21AppHandle(start: { b21Deliver(r, c, status: 200) }) }, driver: { _, _ in XCTFail("No B backup"); return B21AppHandle(start: {}) }, run: runB, previous: chainA)
            XCTAssertEqual(rig.recognitions, 1); XCTAssertFalse(b.operation.hasExited)
            held.release(lateSuccess: true); sleeper.signal(); await chainB.value; await run.drain(); await runB.drain()
            XCTAssertTrue(a.operation.hasExited); XCTAssertTrue(b.operation.hasExited)
            XCTAssertEqual(rig.recognitions, discard ? 1 : 2); XCTAssertEqual(b.operation.shouldAbort, discard)
            XCTAssertNil(rig.admission.ordinaryBusyReason)
        }
    }
    @MainActor func testB21AdmissionLifecycleOrderingAndRestartDrain() async throws {
        let admission = LocalCleanupAdmission(), op = PendingOperation(name: "eligible")
        XCTAssertTrue(admission.reserveRestart()); XCTAssertFalse(admission.admitOrdinaryFailover(op)); admission.releaseRestart()
        XCTAssertTrue(admission.admitOrdinaryFailover(op))
        XCTAssertTrue(admission.reserveRestart()); XCTAssertTrue(op.shouldAbort)
        admission.releaseRestart(); XCTAssertNotNil(admission.ordinaryBusyReason)
        XCTAssertFalse(admission.admitOrdinaryFailover(PendingOperation(name: "successor")))
        op.finish(); admission.exited(op); XCTAssertNil(admission.ordinaryBusyReason)
        var reply: Bool?
        admission.beginShutdown(chain: { nil }, reply: { reply = $0 }); XCTAssertEqual(reply, true)
        XCTAssertFalse(admission.admitOrdinaryFailover(PendingOperation(name: "after intent"))); admission.cancelShutdown()
    }
    @MainActor private func observeDefaultSleeper(backup: Bool) async throws {
        guard ProcessInfo.processInfo.environment["PARLA_B21_ELAPSED_CASE"] == (backup ? "backup" : "primary") else { throw XCTSkip("Serial controlled elapsed observation only") }
        let d = try B21AppDocument(); _ = try d.enable(); let rig = try B21AppRig(d), s = try rig.start(automation: backup), run = rig.makeRun(), held = B21HeldHTTP()
        let entered = expectation(description: "held HTTP"), receipt = expectation(description: "15 second caller result")
        held.entered = { entered.fulfill() }
        let started = ProcessInfo.processInfo.systemUptime; var received = 0.0
        rig.onCompleted = { received = ProcessInfo.processInfo.systemUptime; receipt.fulfill() }
        let immediate: HistoryRetryHTTP.Driver = { r, c in B21AppHandle(start: { b21Deliver(r, c, status: 503) }) }
        // Omit both clock and sleep: this is the actual cross-module default path.
        let chain = rig.run(s, primaryDriver: backup ? immediate : held.driver, driver: backup ? held.driver : immediate, run: run)
        await fulfillment(of: [entered], timeout: 3); await fulfillment(of: [receipt], timeout: 19)
        XCTAssertFalse(s.operation.hasExited); XCTAssertEqual(rig.completions, 1); XCTAssertNotNil(rig.admission.ordinaryBusyReason)
        XCTAssertGreaterThanOrEqual(received - started, 14.8); XCTAssertLessThan(received - started, 19)
        let frozen = run.snapshot
        held.release(lateSuccess: true); await chain.value; await run.drain()
        let exited = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(run.snapshot, frozen); XCTAssertEqual(rig.completions, 1); XCTAssertTrue(s.operation.hasExited)
        try b21Evidence(["kind": "elapsed", "held": backup ? "backup" : "primary", "secondsToCaller": received - started, "secondsToActualExit": exited - started,
            "callerBeforeWithheldExit": received < exited, "completionCount": rig.completions, "fixtureReleasedAndDrained": true, "defaultSleepOmitted": true])
    }
    @MainActor func testB21SerialElapsedDefaultSleepHeldPrimary() async throws { try await observeDefaultSleeper(backup: false) }
    @MainActor func testB21SerialElapsedDefaultSleepHeldBackup() async throws { try await observeDefaultSleeper(backup: true) }
}

extension CleanupFailoverIntegrationTests {
    @MainActor func testB21ProductionRestartGraphWaitsForPrimaryActualExit() async throws {
        let d = try B21AppDocument(); _ = try d.enable(); let rig = try B21AppRig(d), s = try rig.start(automation: true)
        let imports = try SavedImportRig(), restart = SavedRestartRig(imports)
        let entered = expectation(description: "primary active"), canceled = expectation(description: "restart canceled primary"), held = B21HeldHTTP()
        held.entered = { entered.fulfill() }; held.canceled = { canceled.fulfill() }
        let run = CleanupFailoverRun(admit: { await MainActor.run { imports.admission.admitOrdinaryFailover(s.operation) } })
        let chain = rig.run(s, primaryDriver: held.driver, driver: { _, _ in XCTFail("No backup after restart"); return B21AppHandle(start: {}) }, run: run)
        imports.chain = chain
        await fulfillment(of: [entered], timeout: 3)
        var claimed = false
        let request = Task { await restart.claim {
            XCTAssertTrue(s.operation.hasExited); claimed = true; return false
        } }
        await fulfillment(of: [canceled], timeout: 3)
        XCTAssertFalse(claimed); XCTAssertFalse(s.operation.hasExited); XCTAssertTrue(s.operation.shouldAbort)
        held.release(); await chain.value; await run.drain()
        let allowed = await request.value; XCTAssertFalse(allowed); XCTAssertTrue(claimed)
        imports.admission.exited(s.operation); restart.release(); try await imports.close()
    }
    @MainActor func testB21CompletionSecurityVetoAndHistoryOffStayIndependentOfCleanupSuccess() async throws {
        for secure in [false, true] {
            let d = try B21AppDocument()
            if !secure { var settings = d.store.load(); settings.historyEnabled = false; _ = try d.store.save(settings) }
            _ = try d.enable(); let rig = try B21AppRig(d); rig.secureCompletion = secure
            let s = try rig.start(automation: true), run = rig.makeRun()
            await rig.run(s, primaryDriver: { r, c in B21AppHandle(start: { b21Deliver(r, c, status: 200) }) }, driver: { _, _ in XCTFail("No backup"); return B21AppHandle(start: {}) }, run: run).value
            XCTAssertEqual(d.history.entries.count, 0); XCTAssertEqual(rig.inserts, 0)
            XCTAssertEqual(rig.runtime.results.read()?.text, secure ? nil : "Polished."); XCTAssertEqual(rig.completions, 1)
        }
    }
}
