import XCTest
@testable import ParlaCore
@testable import Parla

final class B26AppCredentials: CredentialBackend {
    var reads = 0, statuses = 0
    var onRead: () -> Void = {}
    func status(_ scope: CredentialScope) -> CredentialStatus { statuses += 1; XCTFail("No status discovery"); return .missing }
    func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead { reads += 1; onRead(); return .value("owned-test-key") }
    func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { XCTFail("No Keychain mutation"); return .error }
    func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { XCTFail("No Keychain mutation"); return .error }
    func delete(_ scope: CredentialScope) -> CredentialMutation { XCTFail("No Keychain mutation"); return .error }
}
final class B26AppDocument {
    let id = UUID(), backend = B26AppCredentials()
    var bytes: Data?, failWrite = false
    var historyBytes = Data("[]".utf8)
    init(provider: String = "openai-compatible", history: Bool = true) throws {
        var s = Settings(); s.cleanup.provider = provider; s.cleanup.baseURL = "https://context.test/v1"; s.cleanup.model = "exact-model"; s.cleanupModel = "exact-model"
        s.historyEnabled = history; s.recoveryAudioEnabled = false; s.automationEnabled = true; s.keepLastOriginalEnabled = true
        var p = DictationProfile(); p.id = id; p.name = "Fake editor"; p.target = "test.editor"; s.profiles = [p]
        bytes = try JSONEncoder().encode(s)
    }
    lazy var store = SettingsStore(url: URL(fileURLWithPath: "/synthetic-b26-app/settings.json"), credentials: CredentialStore(backend: backend),
        scratchpadIO: .init(read: { _ in self.bytes }, write: { bytes, _ in try self.write(bytes) }),
        documentIO: .init(read: { self.bytes }), atomicWrite: { bytes, _ in try self.write(bytes) })
    lazy var history = HistoryStore(url: URL(fileURLWithPath: "/synthetic-b26-app/history.json"), persistence: .init(read: { _ in self.historyBytes }, writeAtomically: { bytes, _ in self.historyBytes = bytes }))
    func write(_ bytes: Data) throws { if failWrite { throw CocoaError(.fileWriteOutOfSpace) }; self.bytes = bytes }
    func patch(_ change: (inout [String: Any]) -> Void) throws {
        var root = try JSONSerialization.jsonObject(with: XCTUnwrap(bytes)) as! [String: Any]; change(&root)
        bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    @discardableResult func enable() throws -> Settings { _ = try store.confirmSurroundingText(store.reviewSurroundingText(profileID: id)); return store.load() }
}
final class B26AppRecognition: RecognitionClient {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? { text }
}
struct B26AppCategory: HTTPPosting {
    let call: (URLRequest) throws -> (Data, URLResponse)
    func post(_ request: URLRequest) async throws -> (Data, URLResponse) { try call(request) }
}
final class B26AppHandle: HistoryRetryHTTPHandle {
    let start: () -> Void, stop: () -> Void
    init(start: @escaping () -> Void, stop: @escaping () -> Void) { self.start = start; self.stop = stop }
    func resume() { start() }; func cancel() { stop() }
}
func b26AppResponse(_ request: URLRequest, status: Int = 200, model: String? = "exact-model", text: String = "PREFIX_QUOTED_SENTINEL") throws -> (Data, HTTPURLResponse) {
    var object: [String: Any] = ["choices": [["message": ["content": text]]], "content": [["type": "text", "text": text]], "usage": ["input_tokens": 5, "output_tokens": 6, "prompt_tokens": 5, "completion_tokens": 6]]
    object["model"] = model
    return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
final class B26AppField: @unchecked Sendable {
    let lock = NSLock()
    var field: SurroundingTextField?
    let prefix: String
    var proofs = 0, issues = 0, cancels = 0
    var read: (() async throws -> SurroundingTextResponse)?
    var onIssue: () -> Void = {}
    init(_ prefix: String = "PREFIX_QUOTED_SENTINEL") {
        self.prefix = prefix
        field = SurroundingTextField(pid: 23, window: 42, field: 93, app: "test.editor", caret: prefix.utf16.count)
    }
    func change(_ field: SurroundingTextField?) { lock.withLock { self.field = field } }
    var port: SurroundingTextPort {
        .init(proof: { self.lock.withLock { self.proofs += 1; return self.field } }, issue: { field, range, timeout in
            XCTAssertEqual(range, field.request); XCTAssertLessThanOrEqual(range.length, 512); XCTAssertLessThanOrEqual(timeout, 1)
            self.issues += 1; self.onIssue()
            return SurroundingTextRead(value: {
                if let read = self.read { return try await read() }
                return SurroundingTextResponse(field: field, range: range, units: Array(self.prefix.utf16), startBoundaryProved: true)
            }, cancel: { self.lock.withLock { self.cancels += 1 } })
        })
    }
}
final class B26AppHTTP: @unchecked Sendable {
    var constructed = 0, resumed = 0, canceled = 0
    var requests: [URLRequest] = []
    var callbacks: HistoryRetryHTTPCallbacks?
    var held = false, completeOnly = false, exitOnly = false
    var status = 200
    var model: String? = "exact-model", text = "PREFIX_QUOTED_SENTINEL"
    var onConstruct: () -> Void = {}, onResume: () -> Void = {}
    var driver: HistoryRetryHTTP.Driver {
        { request, callbacks in
            self.constructed += 1; self.requests.append(request); self.callbacks = callbacks
            self.onConstruct()
            return B26AppHandle(start: {
                self.resumed += 1; self.onResume()
                if !self.held { self.respond(request, callbacks) }
            }, stop: {
                self.canceled += 1
                if !self.held {
                    if !self.exitOnly { callbacks.completed(CancellationError()) }
                    if !self.completeOnly { callbacks.exited() }
                }
            })
        }
    }
    func respond(_ request: URLRequest, _ c: HistoryRetryHTTPCallbacks) {
        let (body, response) = try! b26AppResponse(request, status: status, model: model, text: text)
        _ = c.response(response); _ = c.data(body)
        if !exitOnly { c.completed(nil) }
        if !completeOnly { c.exited() }
    }
    func finish() { if let c = callbacks { c.completed(nil); c.exited() } }
}

@MainActor final class B26AppRig {
    let d: B26AppDocument
    let diagnostics = DiagnosticStore(now: { 100 }, appVersion: { nil },
        osVersion: { .init(majorVersion: 14, minorVersion: 0, patchVersion: 0) })
    lazy var machine = DictationSession(diagnostics: diagnostics)
    let failoverRun = CleanupFailoverRun()
    let clock = AutomationTestClock()
    lazy var runtime = AutomationRuntime(clock: clock, enabled: { true })
    lazy var sink = HistoryPersistenceSink(history: d.history, settings: d.store)
    var accepted: DictationSession.Session?
    var pending: (DictationSession.Session, DictationSession.Landed)?
    var posted: [String] = [], learned: [String] = [], originals: [String] = []
    var pendingLearner = true, activeLearner = true, disarms = 0
    var primitiveUsageCalls = 0
    var onOriginalConfiguration: (() -> Void)?
    var onPosterConfiguration: (() -> Void)?
    var nativePosting = false
    var categories = 0, storageEntries: [OrdinaryDictationFinalization.Entry] = []
    var categoryStatus = 200, categoryBodies: [Data] = [], logs: [String] = []
    var backup: HistoryRetryHTTP.Driver?
    var recognizedFocus = Inserter.FocusTarget.editable
    var beforeCompleted: () -> Void = {}
    var environment: [String: String] = [:]
    var sleep: ((TimeInterval) async throws -> Void)?
    var hud: [HUDState] = []
    var currentFocus = Inserter.FocusTarget.editable
    var target = "test.editor", raw = "raw dictated speech"
    var time: TimeInterval = 100
    let recordings: RecordingStore
    lazy var original = OriginalCopyController(configuration: { self.onOriginalConfiguration?(); return self.d.store.load() }, generation: { self.machine.gen }, now: { self.time },
        schedule: { _, _ in {} }, security: { .safe }, copy: { self.originals.append($0) })
    lazy var inserter: DictationInsertionExecutor = {
        let configuration: () -> Settings? = { self.onPosterConfiguration?(); return self.d.store.load() }
        let native: DictationInsertionExecutor.ConfiguredPoster = { text, _, _, dispatch in
            self.nativePosting = true; defer { self.nativePosting = false }
            dispatch(); self.posted.append(text); return true
        }
        let value = DictationInsertionExecutor(originals: original,
            post: DictationInsertionExecutor.configuredPoster(configuration: configuration, native: native),
            preparedPost: DictationInsertionExecutor.configuredPreparedPoster(configuration: configuration, native: native),
            didPost: { self.learned.append($0) })
        value.disarmLearning = { self.disarm() }; return value
    }()
    lazy var host = DictationInvocationHost(machine: machine, broker: runtime.broker, results: runtime.results,
        settings: { self.d.store.load() }, configured: { _ in true }, capabilities: { _ in nil }, secure: { false },
        keyboardAllowed: { true }, automationAllowed: { true }, explicitEntry: {}, send: { self.send($0) })
    init(_ document: B26AppDocument) throws {
        d = document
        // Explicit new private filesystem control for the existing recording owner's
        // bounded empty-directory policy read. No historical or app resource is used.
        let directory = URL(fileURLWithPath: "/private/tmp/parla-implementation-2026-10-28/wave7h1-resume1-child-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        if let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] {
            let data = try JSONSerialization.data(withJSONObject: ["path": directory.path, "ownerPID": ProcessInfo.processInfo.processIdentifier, "purpose": "B26 empty recording directory", "cleanup": "preserved"])
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10])); try handle.close()
        } else { XCTFail("Exclusive fixture manifest required") }
        recordings = RecordingStore(directory: directory, keepAll: false, writer: { _, _ in XCTFail("No audio writer") }, remover: { _ in XCTFail("No audio remover") })
    }
    func disarm() { disarms += 1; pendingLearner = false; activeLearner = false }
    func send(_ event: DictationSession.Event) {
        original.observe(event); sink.beginEvent(for: event, currentGeneration: machine.gen)
        machine.send(event) { effect in
            original.observe(effect)
            switch effect {
            case .captureAccepted(let s): accepted = s; host.accepted(s)
            case .captureAcknowledged(let s): host.acknowledged(s)
            case .captureFinalizing(let s): host.finalizing(s)
            case .applyPreferencesAndStartCapture: send(.recorderStarted(gen: machine.gen))
            case .sampleFocus(let g): send(.focusSampled(gen: g, focus: .editable))
            case .polish(let s, let l): pending = (s, l)
            case .finalResult(let s, let result): host.completed(s, result: result)
            case .insertText(let text, _, let context): _ = inserter.insert(text, original: context, operation: machine.effectOperation, contextRun: machine.effectSurroundingTextRun)
            case .appendHistory: _ = sink.record(effect, metrics: {
                if self.machine.effectSurroundingTextRun?.participated == true { XCTFail("Context History must own metrics") }
                return nil
            })
            case .hud(let value): if let value = sink.feedback(value) { hud.append(value) }
            case .abortOperation(let operation): operation.requestAbort()
            default: break
            }
        }
    }
    func start(reviewed: Bool = true, live: Bool = false) throws -> DictationSession.Session {
        if reviewed { _ = try d.enable() }
        let s = d.store.preparingPhysicalSurroundingText(d.store.load(), destination: .init(bundleID: "test.editor"), live: live)
        XCTAssertTrue(host.keyboard(.startDictation(settings: s, cleanupConfigured: true, live: live, recognitionDestination: .init(bundleID: "test.editor"),
            cleanupFailoverGrant: d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary))))
        let session = try XCTUnwrap(accepted); send(.stopRequested); return session
    }
    func work(_ s: DictationSession.Session, field: B26AppField, http: B26AppHTTP,
              previous: Task<Void, Never>? = nil, port: SurroundingTextPort? = nil,
              recognition: RecognitionClient? = nil) -> Task<Void, Never> {
        PendingOperationQueue.enqueue(previous: previous, operation: s.operation, completes: true, work: {
            defer { s.surroundingTextRun.finish() }
            let final = OrdinaryDictationFinalization(recordings: self.recordings, settings: self.d.store, entered: { self.storageEntries.append($0) })
            await final.run(operation: s.operation, samples: [Float](repeating: 0.2, count: 8000), window: nil,
                prepare: { _, _ in try! RecognitionHandle(request: s.recognition) { _ in recognition ?? B26AppRecognition(text: self.raw) } }, recognized: { _, recognized in
                    await MainActor.run {
                        self.send(.transcribed(s, raw: recognized, probe: .init(focus: self.recognizedFocus, bundleID: self.target, deferInsertionUntilClean: true)))
                        final.resolve(transcript: recognized, secure: false)
                        defer { self.pending = nil }; return self.pending
                    }
                }, clean: { pair in
                    await DictationCleanupOutput.clean(session: pair.0, landed: pair.1, store: self.d.store, environment: self.environment,
                        primaryHTTP: B26AppCategory { request in
                            self.categories += 1; self.categoryBodies.append(request.httpBody!)
                            return try b26AppResponse(request, status: self.categoryStatus, text: "Category result.")
                        },
                        primaryDriver: { request, callbacks in
                            B26AppHandle(start: {
                                self.categories += 1; self.categoryBodies.append(request.httpBody!)
                                do {
                                    let (data, response) = try b26AppResponse(request, status: self.categoryStatus, text: "Category result.")
                                    _ = callbacks.response(response as! HTTPURLResponse); _ = callbacks.data(data); callbacks.completed(nil)
                                } catch { callbacks.completed(error) }
                                callbacks.exited()
                            }, stop: {})
                        },
                        backupDriver: self.backup ?? { _, _ in XCTFail("No backups"); return B26AppHandle(start: {}, stop: {}) },
                        now: { self.time }, sleep: self.sleep, run: self.failoverRun, usage: { _, _, _ in XCTFail("No local usage") }, primitiveUsage: { _, _, _ in self.primitiveUsageCalls += 1 },
                        contextPort: port ?? field.port, contextDriver: http.driver, disarmLearning: { self.disarm() }, contextLog: { self.logs.append($0) })
                }, completed: { pair, text, failure in
                    await MainActor.run {
                        self.beforeCompleted()
                        self.send(.cleanReady(pair.0, pair.1, text: text, failure: failure, focus: self.currentFocus, metrics: pair.0.surroundingTextRun.metrics ?? (self.failoverRun.participated ? self.failoverRun.metrics : nil)))
                    }
                }, drain: { await self.failoverRun.drain() })
        }, finished: { await MainActor.run { self.host.finished(s.operation) } })
    }
}

final class SurroundingTextContextIntegrationTests: XCTestCase {
    @MainActor func testS1EmptyReadSuppressesPrimitiveUsageAndUnsupportedKeepsBaselineUsage() async throws {
        for unsupported in [false, true] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(""), h = B26AppHTTP()
            await r.work(s, field: f, http: h, port: unsupported ? .unsupported : f.port).value
            XCTAssertEqual(f.issues, unsupported ? 0 : 1)
            XCTAssertEqual(r.categories, 1); XCTAssertEqual(h.constructed, 0)
            XCTAssertEqual(r.primitiveUsageCalls, unsupported ? 1 : 0)
            XCTAssertEqual(r.posted, ["Category result."])
        }
    }
    @MainActor func testS2OriginalConfigurationObservationVetoesAcceptedContextInsertion() async throws {
        for revoke in [false, true] {
            let d = try B26AppDocument(history: true), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            var reads = 0
            r.beforeCompleted = {
                r.onOriginalConfiguration = {
                    r.onOriginalConfiguration = nil; reads += 1
                    do { try s.surroundingTextRun.check() } catch { XCTFail("Run must still be open before the configuration read") }
                    if revoke { try! d.patch { $0["surroundingTextContext"] = NSNull() } }
                }
            }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(reads, 1); XCTAssertEqual(h.resumed, 1)
            XCTAssertEqual(r.posted, revoke ? [] : ["PREFIX_QUOTED_SENTINEL"])
            if revoke { XCTAssertThrowsError(try s.surroundingTextRun.check()); XCTAssertNil(r.original.refresh().token) }
            else { XCTAssertNoThrow(try s.surroundingTextRun.check()); XCTAssertNotNil(r.original.refresh().token) }
            XCTAssertTrue(r.learned.isEmpty); XCTAssertNil(r.runtime.results.read())
            XCTAssertEqual(d.history.entries.count, 1); XCTAssertEqual(d.history.entries.first?.raw, r.raw)
            XCTAssertNil(d.history.entries.first?.cleaned); XCTAssertEqual(d.history.entries.first?.metrics, PipelineMetrics())
        }
    }
    @MainActor func testS2PreparedPostingRevalidatesEachConfigurationBoundary() async throws {
        for (phase, keepOriginal) in [("poster", false), ("poster", true), ("prepared-first", true), ("prepared-second", true)] {
            for revoke in [false, true] {
                let d = try B26AppDocument(history: true)
                if !keepOriginal { try d.patch { $0["keepLastOriginalEnabled"] = false } }
                let r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
                var originalReads = 0, posterReads = 0, observations = 0
                func change() {
                    observations += 1
                    do { try s.surroundingTextRun.check() } catch { XCTFail("Authority must be live before this read") }
                    if revoke { try! d.patch { $0["surroundingTextContext"] = NSNull() } }
                }
                r.beforeCompleted = {
                    r.onOriginalConfiguration = {
                        XCTAssertFalse(r.nativePosting, "Configuration must not be read inside native posting")
                        originalReads += 1
                        if (phase == "prepared-first" && originalReads == 2) || (phase == "prepared-second" && originalReads == 3) { change() }
                    }
                    r.onPosterConfiguration = {
                        XCTAssertFalse(r.nativePosting); posterReads += 1
                        if phase == "poster" { change() }
                    }
                }
                await r.work(s, field: f, http: h).value
                XCTAssertEqual(observations, 1); XCTAssertEqual(posterReads, 1)
                XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.categories, 0)
                XCTAssertEqual(r.posted, revoke ? [] : ["PREFIX_QUOTED_SENTINEL"])
                if revoke { XCTAssertThrowsError(try s.surroundingTextRun.check()); XCTAssertNil(r.original.refresh().token) }
                else if keepOriginal { XCTAssertNotNil(r.original.refresh().token) }
                else { XCTAssertNil(r.original.refresh().token) }
                XCTAssertTrue(r.learned.isEmpty); XCTAssertNil(r.runtime.results.read())
                XCTAssertEqual(d.history.entries.count, 1); XCTAssertEqual(d.history.entries.first?.raw, r.raw)
                XCTAssertNil(d.history.entries.first?.cleaned); XCTAssertEqual(d.history.entries.first?.metrics, PipelineMetrics())
                XCTAssertTrue(s.operation.hasExited)
            }
        }
    }
    @MainActor func testA26A28A30ConnectedBothSerializersRawHistoryOriginalAndLearner() async throws {
        for provider in ["anthropic", "openai-compatible"] {
            for history in [false, true] {
                let d = try B26AppDocument(provider: provider, history: history), r = try B26AppRig(d), field = B26AppField("中文😀 PREFIX_QUOTED_SENTINEL"), http = B26AppHTTP()
                let before = Metrics.shared.snapshot(), s = try r.start()
                XCTAssertNotNil(s.surroundingTextGrant); XCTAssertNil(s.settings.physicalSurroundingTextGrant)
                await r.work(s, field: field, http: http).value
                XCTAssertEqual(field.issues, 1); XCTAssertEqual(http.resumed, 1); XCTAssertEqual(r.categories, 0)
                XCTAssertEqual(r.posted, ["PREFIX_QUOTED_SENTINEL"]); XCTAssertTrue(s.operation.hasExited)
                XCTAssertFalse(r.pendingLearner); XCTAssertFalse(r.activeLearner); XCTAssertGreaterThanOrEqual(r.disarms, 2); XCTAssertTrue(r.learned.isEmpty)
                XCTAssertNil(r.runtime.results.read()); XCTAssertEqual(Metrics.shared.snapshot(), before)
                XCTAssertEqual(d.history.entries.count, history ? 1 : 0)
                if history { XCTAssertEqual(d.history.entries[0].raw, r.raw); XCTAssertNil(d.history.entries[0].cleaned); XCTAssertEqual(d.history.entries[0].metrics, PipelineMetrics()) }
                XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains("PREFIX_QUOTED_SENTINEL"))
                let export = TranscriptExport(entries: d.history.entries.map { .init(text: $0.best, date: $0.date) }).encoded(content: .result, format: .text)
                XCTAssertFalse(String(decoding: export, as: UTF8.self).contains("PREFIX_QUOTED_SENTINEL"))
                let token = try XCTUnwrap(r.original.refresh().token); XCTAssertTrue(r.original.copyOriginal(token: token)); XCTAssertEqual(r.originals, [r.raw])
                XCTAssertTrue(r.storageEntries.contains(.stash)); XCTAssertTrue(r.storageEntries.contains(.resolve))
                // Future category-only learning remains available through the same executor.
                let ordinary = DictationSession.Session(gen: r.machine.gen, mode: .dictation, settings: d.store.load(), cleanupConfigured: true, diagnostics: nil)
                XCTAssertEqual(r.inserter.insert("Later category.", original: nil, operation: ordinary.operation), true)
                XCTAssertEqual(r.learned, ["Later category."])
            }
        }
    }
    @MainActor func testA01A16A18UnsupportedIsPreIssuanceCategoryOnce() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        XCTAssertTrue(SurroundingTextPort.nativeQualifications.isEmpty)
        await r.work(s, field: f, http: h, port: .unsupported).value
        XCTAssertEqual(f.issues, 0); XCTAssertEqual(h.resumed, 0); XCTAssertEqual(r.categories, 1); XCTAssertFalse(s.surroundingTextRun.participated)
        XCTAssertEqual(r.posted, ["Category result."])
    }
    @MainActor func testA03RawOffSnippetNeverCallsContextPortOrFactory() async throws {
        for branch in ["raw", "off", "snippet"] {
            let d = try B26AppDocument(history: false); var settings = try d.enable()
            if branch == "raw" { settings.outputMode = .raw }
            if branch == "off" { settings.cleanupEnabled = false }
            if branch == "snippet" { settings.snippets = ["raw dictated speech": "Locked"] }
            try d.store.save(settings, replacing: d.store.load())
            let r = try B26AppRig(d), s = try r.start(reviewed: false), f = B26AppField(), h = B26AppHTTP()
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(f.proofs, 0); XCTAssertEqual(f.issues, 0); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
            XCTAssertEqual(r.posted, [branch == "snippet" ? "Locked" : r.raw])
        }
    }
    @MainActor func testA04CaptureBeforeEnableAndA05OutputRetargetCannotGainGrant() async throws {
        for old in [true, false] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(reviewed: !old), f = B26AppField(), h = B26AppHTTP()
            if old { _ = try d.enable() } else { r.target = "test.other" }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(f.issues, 0); XCTAssertEqual(h.resumed, 0); XCTAssertEqual(r.categories, 1)
        }
    }
    @MainActor func testA08A24HeldReadCancellationJoinsLaneBeforeNextOperation() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        let entered = expectation(description: "issued bounded read"), release = RecognitionTestLatch()
        let field = try XCTUnwrap(f.field)
        f.read = { entered.fulfill(); await release.wait(); return .init(field: field, range: field.request, units: Array(f.prefix.utf16), startBoundaryProved: true) }
        let first = r.work(s, field: f, http: h)
        await fulfillment(of: [entered], timeout: 3)
        d.store.revokeSurroundingTextContext(); XCTAssertFalse(s.operation.hasExited)
        var nextStarted = false
        let next = PendingOperation(name: "Next fake operation", diagnostics: nil)
        let second = PendingOperationQueue.enqueue(previous: first, operation: next, completes: true, work: { nextStarted = true })
        XCTAssertFalse(nextStarted); release.signal(); await second.value
        XCTAssertTrue(nextStarted); XCTAssertTrue(s.operation.hasExited); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0); XCTAssertEqual(d.backend.reads, 0)
    }
    @MainActor func testA09CredentialChangeRecheckedBeforeClientConstruction() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        let original = d.bytes
        d.backend.onRead = {
            try! d.patch { $0["surroundingTextContext"] = NSNull() }
            _ = try? d.store.savedRetrySnapshot() // actual raw-byte read remembers invalidity
            d.bytes = original
        }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(d.backend.reads, 1); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
    }
    @MainActor func testA10ConstructedSuspendedHandleCannotResumeAfterRevocation() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        h.onConstruct = { d.store.revokeSurroundingTextContext() }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(h.constructed, 1); XCTAssertEqual(h.resumed, 0); XCTAssertGreaterThan(h.canceled, 0); XCTAssertTrue(s.operation.hasExited); XCTAssertEqual(r.categories, 0)
    }
    @MainActor func testA11A23CompletedAndExitedBothRequiredAfterCancel() async throws {
        for completedFirst in [true, false] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            h.completeOnly = completedFirst; h.exitOnly = !completedFirst
            let entered = expectation(description: "resumed"); h.onResume = { entered.fulfill() }
            let task = r.work(s, field: f, http: h)
            await fulfillment(of: [entered], timeout: 3)
            d.store.revokeSurroundingTextContext(); XCTAssertFalse(s.operation.hasExited)
            h.finish(); await task.value
            XCTAssertTrue(s.operation.hasExited); XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.categories, 0); XCTAssertFalse(r.posted.contains("PREFIX_QUOTED_SENTINEL")); XCTAssertNil(r.runtime.results.read())
        }
    }
    @MainActor func testA13A27ProviderErrorsAndModelEchoHaveNoSecondarySink() async throws {
        for kind in ["503", "alias", "missing"] {
            let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            if kind == "503" { h.status = 503; h.text = "PREFIX_QUOTED_SENTINEL owned-test-key" }
            if kind == "alias" { h.model = "PREFIX_QUOTED_SENTINEL" }
            if kind == "missing" { h.model = nil }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.categories, 0); XCTAssertNil(r.runtime.results.read()); XCTAssertTrue(r.learned.isEmpty)
            XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains("PREFIX_QUOTED_SENTINEL"))
            XCTAssertEqual(d.history.entries.first?.metrics, PipelineMetrics())
            XCTAssertEqual(r.posted, [kind == "missing" ? "PREFIX_QUOTED_SENTINEL" : r.raw])
        }
    }
    @MainActor func testA14A16A17FieldCaretSecurityChangedAtReadOrAfterCredentialsRefuses() async throws {
        for phase in ["read", "credential"] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            if phase == "read" { f.onIssue = { f.change(nil) } }
            else { d.backend.onRead = { f.change(nil) } }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(f.issues, 1); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
        }
    }
    @MainActor func testA18IssuedInvalidRangeIsRawWithoutCategoryRetry() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), field = try XCTUnwrap(f.field)
        f.read = { .init(field: field, range: field.request, units: [], startBoundaryProved: true) }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0); XCTAssertEqual(r.posted, [r.raw])
    }
    @MainActor func testA20ExactDocumentStartEmptyResponseAllowsOneCategoryRequest() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(""), h = B26AppHTTP()
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(r.categories, 1); XCTAssertEqual(h.constructed, 0); XCTAssertTrue(s.surroundingTextRun.participated); XCTAssertFalse(s.surroundingTextRun.insertionOnly)
    }
    @MainActor func testA24ReadAndOverallEqualityExpireBeforeCredentialsOrResume() async throws {
        for elapsed: TimeInterval in [1, 15] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), field = try XCTUnwrap(f.field)
            f.read = { r.time += elapsed; return .init(field: field, range: field.request, units: Array(f.prefix.utf16), startBoundaryProved: true) }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.resumed, 0); XCTAssertEqual(r.categories, 0); XCTAssertTrue(s.operation.hasExited)
        }
    }
    @MainActor func testA25QuitIntentCannotReviveHeldReadAfterReconfirm() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        f.onIssue = { AppDelegate.cleanupFailoverIntent(d.store); _ = try? d.enable() }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(h.resumed, 0); XCTAssertEqual(r.categories, 0)
    }
    @MainActor func testA26StaleAndNoDestinationKeepOnlyRawHistoryAndFiniteHUD() async throws {
        for stale in [false, true] {
            let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            h.onResume = {
                if stale { _ = r.machine.handle(.startDictation(settings: d.store.load(), cleanupConfigured: true, live: false)) }
                else { r.currentFocus = .none }
            }
            await r.work(s, field: f, http: h).value
            XCTAssertTrue(r.posted.isEmpty); XCTAssertEqual(d.history.entries.first?.raw, r.raw); XCTAssertNil(d.history.entries.first?.cleaned); XCTAssertNil(r.runtime.results.read())
            if !stale { XCTAssertTrue(r.hud.contains(.notice("Context result withheld; raw text only in History"))) }
        }
    }
    @MainActor func testA29ActualShortcutsPresetTransformAndHistoryRetryAdaptersHaveNoContext() async throws {
        let d = try B26AppDocument(history: false); _ = try d.enable(); let r = try B26AppRig(d), f = B26AppField(), h = B26AppHTTP()
        XCTAssertNil(r.host.startAutomation()); let automation = try XCTUnwrap(r.accepted); r.send(.stopRequested)
        await r.work(automation, field: f, http: h).value
        XCTAssertNil(automation.surroundingTextGrant); XCTAssertEqual(f.proofs, 0); XCTAssertEqual(r.categories, 1)
        var settings = d.store.load(); let preset = TransformPreset(name: "Rewrite", instruction: "Polish")
        settings.transformPresets = [preset]; settings.selectedPresetID = preset.id; settings.outputMode = .selectedPreset
        let command = DictationSession.Session(gen: 0, mode: .command(selection: "selected"), settings: settings, cleanupConfigured: true, diagnostics: nil)
        var calls = 0
        let factory: (Settings) throws -> CleanupProviding = { selected in
            calls += 1
            return try makeCleanupClient(settings: selected, env: [:], credentials: d.store.credentials,
                http: B26AppCategory { request in
                    XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("preceding_text")); return try b26AppResponse(request, text: "Result.")
                }, usage: { _, _, _ in })
        }
        _ = try await command.transform(instruction: "Polish", makeClient: factory)
        let landed = DictationSession.Landed(landing: .pending, raw: r.raw, insertText: "", bundleID: "test.editor", appName: nil, singleLine: false)
        let presetSession = DictationSession.Session(gen: 0, mode: .dictation, settings: settings, cleanupConfigured: true, diagnostics: nil)
        _ = await DictationCleanupOutput.clean(session: presetSession, landed: landed, store: d.store, environment: [:], primaryHTTP: B26AppCategory { request in
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("preceding_text")); return try b26AppResponse(request, text: "Result.")
        }, run: CleanupFailoverRun(), usage: { _, _, _ in }, contextPort: f.port, contextDriver: h.driver, disarmLearning: {})
        settings.outputMode = .cleanup
        let retry = try HistoryRetryRequest(settings: settings, environment: [:], source: .init(raw: "historical"), applyPreset: false, credentials: d.store.credentials)
        _ = try await retry.run(source: "historical", factory: { selected, _, _, _ in try factory(selected) })
        XCTAssertEqual(calls, 2); XCTAssertEqual(f.issues, 0); XCTAssertEqual(h.constructed, 0)
    }
}


extension SurroundingTextContextIntegrationTests {
    @MainActor func testA01A31DefaultOffPreservesCategoryDeliveryRetrievalAndLearning() async throws {
        let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(reviewed: false), f = B26AppField(), h = B26AppHTTP()
        await r.work(s, field: f, http: h).value
        XCTAssertNil(s.surroundingTextGrant); XCTAssertEqual(f.proofs, 0); XCTAssertEqual(h.constructed, 0)
        XCTAssertEqual(r.categories, 1); XCTAssertEqual(r.posted, ["Category result."])
        XCTAssertEqual(r.runtime.results.read()?.text, "Category result."); XCTAssertEqual(r.learned, r.posted)
        XCTAssertEqual(d.history.entries.first?.cleaned, "Category result.")
        XCTAssertFalse(String(decoding: try XCTUnwrap(r.categoryBodies.first), as: UTF8.self).contains("preceding_text"))
    }
    @MainActor func testA12A15CategoryB21BackupSecureRaceNeverReceivesContext() async throws {
        for secure in [false, true] {
            let d = try B26AppDocument(); _ = try d.enable()
            let row = CleanupBackup(baseURL: "https://backup.test/v1", model: "exact-model", source: .keylessCompatible)
            _ = try d.store.confirmCleanupFailover(d.store.reviewCleanupFailover(backups: [row]))
            let r = try B26AppRig(d), s = try r.start(reviewed: false), f = B26AppField(), h = B26AppHTTP()
            r.categoryStatus = 503; h.held = true; h.text = "Backup category."
            let entered = expectation(description: "category-only backup resumed"); h.onResume = { entered.fulfill() }
            r.backup = h.driver
            let task = r.work(s, field: f, http: h)
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertNil(s.surroundingTextGrant); XCTAssertNotNil(s.cleanupFailoverGrant)
            XCTAssertEqual(f.proofs, 0); XCTAssertEqual(f.issues, 0); XCTAssertEqual(r.categories, 1)
            for request in h.requests {
                let body = String(decoding: request.httpBody!, as: UTF8.self)
                XCTAssertFalse(body.contains("preceding_text")); XCTAssertFalse(body.contains(f.prefix))
            }
            if secure { r.currentFocus = .secure }
            h.respond(try XCTUnwrap(h.requests.first), try XCTUnwrap(h.callbacks)); await task.value
            XCTAssertTrue(s.operation.hasExited); XCTAssertEqual(h.resumed, 1)
            XCTAssertEqual(r.posted, secure ? [] : ["Backup category."])
            XCTAssertEqual(d.history.entries.count, secure ? 0 : 1)
            XCTAssertFalse(s.surroundingTextRun.participated)
        }
    }
    @MainActor func testA14SecureLandingClosesBeforeContextMetadataOrNetwork() async throws {
        let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        r.recognizedFocus = .secure
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.proofs, 0); XCTAssertEqual(f.issues, 0); XCTAssertEqual(d.backend.reads, 0)
        XCTAssertEqual(r.categories, 0); XCTAssertEqual(h.constructed, 0); XCTAssertTrue(r.posted.isEmpty); XCTAssertTrue(d.history.entries.isEmpty)
    }
    @MainActor func testA14A16A17ChangedNontextProofCannotResumeOldRead() async throws {
        let variants: [SurroundingTextField?] = [nil,
            .init(pid: 24, window: 42, field: 93, app: "test.editor", caret: 21),
            .init(pid: 23, window: 43, field: 93, app: "test.editor", caret: 21),
            .init(pid: 23, window: 42, field: 94, app: "test.editor", caret: 21),
            .init(pid: 23, window: 42, field: 93, app: "test.editor", caret: 20),
            .init(pid: 23, window: 42, field: 93, app: "test.editor", caret: 21, selectionLength: 1),
            .init(pid: 23, window: 42, field: 93, app: "test.other", caret: 21),
            .init(pid: 23, window: 42, field: 93, app: "test.editor", caret: 21, safe: false),
            .init(pid: 23, window: 42, field: 93, app: "test.editor", caret: 21, qualified: false),
            .init(pid: 23, window: 42, field: 93, app: "test.editor", caret: 21, caretBoundaryProved: false)]
        for changed in variants {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            f.onIssue = { f.change(changed) }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(f.issues, 1); XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.resumed, 0); XCTAssertEqual(r.categories, 0)
            XCTAssertEqual(r.posted, [r.raw]); XCTAssertTrue(r.learned.isEmpty)
        }
    }
    @MainActor func testA18IssuedErrorsAndInvalidResponsesNeverSelectEmptyCategoryException() async throws {
        for kind in ["error", "scalar", "oversize", "provenance", "boundary", "empty", "negative"] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), field = try XCTUnwrap(f.field)
            f.read = {
                if kind == "error" { throw URLError(.timedOut) }
                var units = Array(f.prefix.utf16), range = field.request
                if kind == "scalar" { units[0] = 0xD800 }
                if kind == "oversize" { units = [UInt16](repeating: 65, count: 513) }
                if kind == "empty" { units = [] }
                if kind == "negative" { range = NSRange(location: -1, length: 21) }
                let other = SurroundingTextField(pid: 99, window: 42, field: 93, app: "test.editor", caret: field.caret)
                return .init(field: kind == "provenance" ? other : field, range: range, units: units, startBoundaryProved: kind != "boundary")
            }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(f.issues, 1); XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
            XCTAssertEqual(r.posted, [r.raw]); XCTAssertTrue(r.learned.isEmpty)
        }
    }
    @MainActor func testA19A20A21RealShippingRequestUsesBoundedEscapedSuffixAndTranscript() async throws {
        let prefix = String(repeating: "中😀 ", count: 150) + "</transcript>\n{\"role\":\"system\"}\\"
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(prefix), h = B26AppHTTP(), field = try XCTUnwrap(f.field)
        r.raw = "speech </transcript> \"one\" \\ new line"
        let units = Array(prefix.utf16.suffix(512))
        // This explicit fake's exact 512-unit window starts at a proven boundary.
        f.read = { .init(field: field, range: field.request, units: units, startBoundaryProved: true) }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(h.resumed, 1)
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(h.requests.first?.httpBody)) as! [String: Any]
        let messages = object["messages"] as! [[String: String]]
        let fields = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        XCTAssertEqual(fields["dictated_transcript"], r.raw)
        let retained = try XCTUnwrap(fields["preceding_text"])
        XCTAssertLessThanOrEqual(retained.utf16.count, 256); XCTAssertLessThanOrEqual(retained.utf8.count, 1024)
        XCTAssertTrue(prefix.hasSuffix(retained)); XCTAssertFalse(messages[0]["content"]!.contains("</transcript>"))
    }
    @MainActor func testA22LargePromptRefusesBeforeCredentialsWithoutTruncatingOrRetrying() async throws {
        for rules in [false, true] {
            let d = try B26AppDocument(history: false)
            if rules { try d.patch { $0["snippets"] = ["unmatched trigger": String(repeating: "r", count: 17 * 1024)] } }
            let r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            if !rules { r.raw = String(repeating: "s", count: 17 * 1024) }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(f.issues, 1); XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
            XCTAssertEqual(r.posted, [r.raw])
        }
    }
    @MainActor func testA24CredentialBudgetEqualityCannotConstructOrResume() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        d.backend.onRead = { r.time += 15 }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(d.backend.reads, 1); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
    }
    @MainActor func testA25ActualDiscardDuringReadWaitsForExitAndNeverDelivers() async throws {
        let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        let entered = expectation(description: "range owned"), release = RecognitionTestLatch(), field = try XCTUnwrap(f.field)
        f.read = { entered.fulfill(); await release.wait(); return .init(field: field, range: field.request, units: Array(f.prefix.utf16), startBoundaryProved: true) }
        let task = r.work(s, field: f, http: h)
        await fulfillment(of: [entered], timeout: 3)
        r.send(.discardOwnedOperation(s.operation, generation: s.gen))
        XCTAssertTrue(s.operation.shouldAbort); XCTAssertFalse(s.operation.hasExited)
        release.signal(); await task.value
        XCTAssertTrue(s.operation.hasExited); XCTAssertEqual(h.constructed, 0); XCTAssertTrue(r.posted.isEmpty); XCTAssertTrue(d.history.entries.isEmpty)
    }
    @MainActor func testA27MaliciousModelAndErrorSentinelsStayOutOfDiagnosticsMetricsExportsAndLogs() async throws {
        for error in [false, true] {
            let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            let global = Metrics.shared.snapshot()
            h.model = "PREFIX_QUOTED_SENTINEL owned-test-key error-endpoint focus-token digest"
            if error { h.status = 503; h.text = h.model! }
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(Metrics.shared.snapshot(), global); XCTAssertEqual(d.history.entries.first?.metrics, PipelineMetrics())
            let projection = String(decoding: try r.diagnostics.snapshot().encoded(), as: UTF8.self)
                + String(decoding: d.historyBytes, as: UTF8.self) + r.logs.joined()
            for sentinel in [f.prefix, "owned-test-key", "error-endpoint", "focus-token", "digest"] { XCTAssertFalse(projection.contains(sentinel)) }
            XCTAssertEqual(r.logs, ["Parla cleanup failed; using local fallback"])
            XCTAssertTrue(r.diagnostics.snapshot().records.contains { $0.providerRequestAttempted && !$0.timings.isEmpty })
        }
    }
}


extension SurroundingTextContextIntegrationTests {
    @MainActor func testA11ObservedRevocationAfterProviderExitStillDropsContextBeforeInsertion() async throws {
        let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        r.beforeCompleted = { d.store.revokeSurroundingTextContext() }
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(f.issues, 1); XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.categories, 0)
        XCTAssertEqual(r.posted, [r.raw]); XCTAssertTrue(r.learned.isEmpty); XCTAssertNil(r.runtime.results.read())
        XCTAssertEqual(d.history.entries.first?.raw, r.raw); XCTAssertNil(d.history.entries.first?.cleaned)
        XCTAssertEqual(d.history.entries.first?.metrics, PipelineMetrics()); XCTAssertTrue(s.operation.hasExited)
    }
    @MainActor func testA20EmptyPrefixCategoryUsageDoesNotBorrowOrMutateGlobalMetrics() async throws {
        let d = try B26AppDocument(), r = try B26AppRig(d), s = try r.start(), f = B26AppField(""), h = B26AppHTTP()
        let global = Metrics.shared.snapshot()
        await r.work(s, field: f, http: h).value
        XCTAssertEqual(r.categories, 1); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(Metrics.shared.snapshot(), global)
        XCTAssertEqual(d.history.entries.first?.metrics, PipelineMetrics()); XCTAssertTrue(r.learned.isEmpty)
    }
}


extension SurroundingTextContextIntegrationTests {
    @MainActor func testA07A30ShippingContextUsesOrdinaryEnvironmentPrecedenceWithoutKeychain() async throws {
        for provider in ["anthropic", "openai-compatible"] {
            let d = try B26AppDocument(provider: provider, history: false)
            if provider == "openai-compatible" {
                try d.patch { root in
                    var cleanup = root["cleanup"] as! [String: Any]; cleanup["apiKeyEnvVar"] = "B26_TEST_KEY"; root["cleanup"] = cleanup
                }
            }
            let r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
            r.environment = [provider == "anthropic" ? "ANTHROPIC_API_KEY" : "B26_TEST_KEY": "environment-at-request"]
            await r.work(s, field: f, http: h).value
            XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.resumed, 1)
            let request = try XCTUnwrap(h.requests.first)
            XCTAssertEqual(request.value(forHTTPHeaderField: provider == "anthropic" ? "x-api-key" : "Authorization"),
                provider == "anthropic" ? "environment-at-request" : "Bearer environment-at-request")
        }
    }
    @MainActor func testA24WatchdogActualExitOwnsLaneAfterHTTPCompleted() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        let entered = expectation(description: "watchdog borrowed sleeper"), completed = expectation(description: "HTTP completed and exited")
        let release = RecognitionTestLatch(); var watchdogExited = false
        r.sleep = { _ in entered.fulfill(); await release.wait(); watchdogExited = true }
        h.onResume = { completed.fulfill() }
        let first = r.work(s, field: f, http: h)
        await fulfillment(of: [entered, completed], timeout: 3)
        XCTAssertFalse(s.operation.hasExited); XCTAssertFalse(watchdogExited)
        let next = PendingOperation(name: "Watchdog successor", diagnostics: nil); var advanced = false
        let second = PendingOperationQueue.enqueue(previous: first, operation: next, completes: true, work: {
            XCTAssertTrue(watchdogExited); XCTAssertTrue(s.operation.hasExited); advanced = true
        })
        XCTAssertFalse(advanced); release.signal(); await second.value
        XCTAssertTrue(advanced); XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.posted, [h.text])
    }
}
