import XCTest
@testable import ParlaCore
@testable import Parla

final class B26AppCredentials: CredentialBackend {
    var reads = 0, statuses = 0
    var onRead: () -> Void = {}
    var result: CredentialRead = .value("owned-test-key")
    func status(_ scope: CredentialScope) -> CredentialStatus { statuses += 1; XCTFail("No status discovery"); return .missing }
    func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead { reads += 1; onRead(); return result }
    func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { XCTFail("No Keychain mutation"); return .error }
    func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation { XCTFail("No Keychain mutation"); return .error }
    func delete(_ scope: CredentialScope) -> CredentialMutation { XCTFail("No Keychain mutation"); return .error }
}
final class B26AppDocument {
    let id = UUID(), backend = B26AppCredentials()
    var bytes: Data?, failWrite = false
    var onDocumentRead: () -> Void = {}
    var historyBytes = Data("[]".utf8)
    init(provider: String = "openai-compatible", history: Bool = true) throws {
        var s = Settings(); s.cleanup.provider = provider; s.cleanup.baseURL = "https://context.test/v1"; s.cleanup.model = "exact-model"; s.cleanupModel = "exact-model"
        s.historyEnabled = history; s.recoveryAudioEnabled = false; s.automationEnabled = true; s.keepLastOriginalEnabled = true
        var p = DictationProfile(); p.id = id; p.name = "Fake editor"; p.target = "test.editor"; s.profiles = [p]
        bytes = try JSONEncoder().encode(s)
    }
    lazy var store = SettingsStore(url: URL(fileURLWithPath: "/synthetic-b26-app/settings.json"), credentials: CredentialStore(backend: backend),
        scratchpadIO: .init(read: { _ in self.bytes }, write: { bytes, _ in try self.write(bytes) }),
        documentIO: .init(read: { self.onDocumentRead(); return self.bytes }), atomicWrite: { bytes, _ in try self.write(bytes) })
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
    weak var handle: B26AppHandle?
    var held = false, completeOnly = false, exitOnly = false
    var status = 200
    var model: String? = "exact-model", text = "PREFIX_QUOTED_SENTINEL"
    var onConstruct: () -> Void = {}, onResume: () -> Void = {}, onCancel: () -> Void = {}
    var driver: HistoryRetryHTTP.Driver {
        { request, callbacks in
            self.constructed += 1; self.requests.append(request); self.callbacks = callbacks
            self.onConstruct()
            let handle = B26AppHandle(start: {
                self.resumed += 1; self.onResume()
                if !self.held { self.respond(request, callbacks) }
            }, stop: {
                self.canceled += 1; self.onCancel()
                if !self.held {
                    if !self.exitOnly { callbacks.completed(CancellationError()) }
                    if !self.completeOnly { callbacks.exited() }
                }
            })
            self.handle = handle; return handle
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
    var onDisarm: () -> Void = {}
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
        // Future runner owns this parent and a precreated private manifest.
        // No historical task root, directory sweep, or recording payload access.
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["PARLA_TEST_FIXTURE_MANIFEST"], !manifest.isEmpty else {
            XCTFail("Exclusive fixture manifest required"); throw CocoaError(.fileNoSuchFile)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: manifest))
        defer { try? handle.close() }
        let parent = environment["PARLA_B26_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadUnsupportedScheme) }
        if environment["PARLA_B26_FIXTURE_ROOT"] != nil {
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw CocoaError(.fileReadNoPermission) }
        }
        let directory = parent.appendingPathComponent("parla-b26-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let data = try JSONSerialization.data(withJSONObject: ["path": directory.path, "ownerPID": ProcessInfo.processInfo.processIdentifier,
            "purpose": "B26 empty recording directory", "cleanup": "preserved", "recordingReadScope": "fresh-owned-empty-only", "retention": "existing-policy-on-empty-directory"])
        try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
        recordings = RecordingStore(directory: directory, keepAll: false, writer: { _, _ in XCTFail("No audio writer") }, remover: { _ in XCTFail("No audio remover") })
    }
    func disarm() { disarms += 1; pendingLearner = false; activeLearner = false; onDisarm() }
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
              recognition: RecognitionClient? = nil, localRuntime: LocalCleanupRuntime = LocalCleanupRuntime()) -> Task<Void, Never> {
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
                        now: { self.time }, sleep: self.sleep, localRuntime: localRuntime, run: self.failoverRun, usage: { _, _, _ in XCTFail("No local usage") }, primitiveUsage: { _, _, _ in self.primitiveUsageCalls += 1 },
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
                let d = try B26AppDocument(provider: provider, history: history), r = try B26AppRig(d), field = B26AppField("中文😀 PRIVATE CONTEXT SENTINEL MUST STAY PRIVATE"), http = B26AppHTTP()
                http.onResume = { [unowned http] in http.text = http.resumed == 1 ? "PRIVATE CONTEXT SENTINEL MUST STAY PRIVATE" : "Dictated speech." }
                let before = Metrics.shared.snapshot(), s = try r.start()
                XCTAssertNotNil(s.surroundingTextGrant); XCTAssertNil(s.settings.physicalSurroundingTextGrant)
                await r.work(s, field: field, http: http).value
                XCTAssertEqual(field.issues, 1); XCTAssertEqual(http.resumed, 2); XCTAssertEqual(r.categories, 0)
                XCTAssertEqual(r.posted, ["Dictated speech."]); XCTAssertTrue(s.operation.hasExited)
                XCTAssertFalse(r.pendingLearner); XCTAssertFalse(r.activeLearner); XCTAssertGreaterThanOrEqual(r.disarms, 2); XCTAssertTrue(r.learned.isEmpty)
                XCTAssertNil(r.runtime.results.read()); XCTAssertEqual(Metrics.shared.snapshot(), before)
                XCTAssertEqual(d.history.entries.count, history ? 1 : 0)
                if history { XCTAssertEqual(d.history.entries[0].raw, r.raw); XCTAssertNil(d.history.entries[0].cleaned); XCTAssertEqual(d.history.entries[0].metrics, PipelineMetrics()) }
                XCTAssertFalse(String(decoding: d.historyBytes, as: UTF8.self).contains("PRIVATE CONTEXT SENTINEL"))
                let export = TranscriptExport(entries: d.history.entries.map { .init(text: $0.best, date: $0.date) }).encoded(content: .result, format: .text)
                XCTAssertFalse(String(decoding: export, as: UTF8.self).contains("PRIVATE CONTEXT SENTINEL"))
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

// Stage A finite fakes only. No native worker/qualification or quality oracle.
// Observation timers report failure; they NEVER represent operation exit.
private final class B26StageObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resolve(_ value: Bool) {
        let continuation = lock.withLock { let old = self.continuation; self.continuation = nil; return old }
        continuation?.resume(returning: value)
    }
}
private final class B26StageEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var observers: [B26StageObservation] = []
    var occurred: Bool { lock.withLock { signaled } }
    func signal() {
        let observers = lock.withLock { () -> [B26StageObservation] in
            signaled = true; let old = self.observers; self.observers = []; return old
        }
        for observer in observers { observer.resolve(true) }
    }
    func observe() async -> Bool {
        await withCheckedContinuation { continuation in
            let observer = B26StageObservation(continuation)
            let ready = lock.withLock { if signaled { return true }; observers.append(observer); return false }
            if ready { observer.resolve(true) }
            else { DispatchQueue.global().asyncAfter(deadline: .now() + 4) { observer.resolve(false) } }
        }
    }
}
private final class B26StageHold: @unchecked Sendable {
    let id = UUID(), entered = B26StageEvent(), returned = B26StageEvent()
    private let lock = NSLock()
    private var released = false, armed = false, failed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var timedOut: Bool { lock.withLock { failed } }
    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true; let old = self.waiters; self.waiters = []; return old
        }
        for waiter in waiters { waiter.resume() }
    }
    private func failRelease() {
        lock.withLock { if !released { failed = true } }
        release()
    }
    func wait() async {
        let arm = lock.withLock { if armed { return false }; armed = true; return true }
        if arm {
            // Independent non-MainActor fail-release; sticky failure cannot be
            // erased by a later normal release. No cancellation-dependent timer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.failRelease() }
        }
        entered.signal()
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if released { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
        returned.signal()
    }
}
private final class B26StageOwnedTask {
    let id = UUID(), completed = B26StageEvent()
    let task: Task<Void, Never>
    private let observer: Task<Void, Never>
    init(_ task: Task<Void, Never>) {
        self.task = task
        let completed = self.completed
        observer = Task { await task.value; completed.signal() }
    }
    func joinObserved(_ expected: UUID, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        XCTAssertEqual(id, expected, file: file, line: line)
        let returned = await completed.observe()
        XCTAssertTrue(returned, "Actual task return unobserved; keep its scope/lane pending", file: file, line: line)
        guard returned else { return false } // Not an exit signal or cleanup claim.
        await task.value; await observer.value
        return true
    }
}
private final class B26StageTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var held: UUID?
    weak var scope: SurroundingTextOperation?
    weak var backend: B26StageBackend?
    weak var admissionToken: B26StageAdmissionToken?
    weak var proofToken: B26StageProofToken?
    let phaseReturned = B26StageEvent(), canceledRead = B26StageEvent()
    func note(_ key: String) -> Int { lock.withLock { values[key, default: 0] += 1; return values[key]! } }
    func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
    func heldBy(_ id: UUID) { lock.withLock { held = id } }
    var heldID: UUID? { lock.withLock { held } }
}
private final class B26StageAdmissionToken {
    let trace: B26StageTrace
    init(_ trace: B26StageTrace) { self.trace = trace }
    deinit { _ = trace.note("admissionReleased") }
}
private final class B26StageProofToken {
    let trace: B26StageTrace
    init(_ trace: B26StageTrace) { self.trace = trace }
    deinit { _ = trace.note("proofReleased") }
}
private final class B26StageBackend {
    let trace: B26StageTrace, field: SurroundingTextField
    let hold: B26StageHold?
    let phase: Int // 0 read, 1...6 proof, 7 cleanup; finite selected site only.
    var savedAdmission: SurroundingTextOperation.Admit?
    let refuseFirst: Bool, throwIssue: Bool, cancelOnIssue: Bool
    let failure: Int
    let onProof: @MainActor (Int) -> Void
    let afterFinish: @MainActor () -> Void
    init(trace: B26StageTrace, hold: B26StageHold?, phase: Int, refuseFirst: Bool,
         throwIssue: Bool, cancelOnIssue: Bool, failure: Int, onProof: @escaping @MainActor (Int) -> Void,
         afterFinish: @escaping @MainActor () -> Void) {
        self.trace = trace; self.hold = hold; self.phase = phase; self.refuseFirst = refuseFirst
        self.throwIssue = throwIssue; self.cancelOnIssue = cancelOnIssue; self.failure = failure
        self.onProof = onProof; self.afterFinish = afterFinish
        field = .init(pid: 23, window: 42, field: 93, app: "test.editor", caret: 7)
    }
    deinit { _ = trace.note("backendReleased") }
    func pause(_ site: Int) async {
        if site == phase, let hold { trace.heldBy(hold.id); await hold.wait(); trace.phaseReturned.signal() }
    }
    func proof(_ admit: @escaping SurroundingTextOperation.Admit) async throws -> SurroundingTextField? {
        let number = trace.note("proof")
        if savedAdmission == nil {
            let token = B26StageAdmissionToken(trace); trace.admissionToken = token
            savedAdmission = { [token] in try withExtendedLifetime(token) { try admit() } }
        }
        await pause(number)
        _ = try admit() // Fresh per-job entry, AFTER any synthetic scheduling hold.
        _ = trace.note("metadataEntry")
        if failure == number { throw SurroundingTextFailure.refused }
        await MainActor.run { onProof(number) }
        return refuseFirst && number == 1 ? nil : field
    }
    @MainActor func issue(_ field: SurroundingTextField, _ range: NSRange, _ remaining: TimeInterval,
                          _ admit: @escaping SurroundingTextOperation.Admit) throws -> SurroundingTextRead {
        _ = trace.note("issue")
        XCTAssertEqual(range, field.request); XCTAssertGreaterThan(remaining, 0); XCTAssertLessThanOrEqual(remaining, 1)
        _ = try admit()
        if throwIssue { throw SurroundingTextFailure.refused }
        if cancelOnIssue { trace.scope?.cancel() }
        return SurroundingTextRead(value: {
            _ = self.trace.note("readStart")
            defer { _ = self.trace.note("readExit") }
            await self.pause(0)
            _ = try admit()
            if self.failure == 0 { throw SurroundingTextFailure.refused }
            return .init(field: field, range: range, units: Array("Stage A".utf16), startBoundaryProved: true)
        }, cancel: {
            _ = self.trace.note("readCancel"); self.trace.canceledRead.signal()
        })
    }
    func finish() async {
        _ = trace.note("finishEntry")
        await pause(7)
        savedAdmission = nil
        await MainActor.run { afterFinish() }
        _ = trace.note("finishExit")
    }
    static func port(_ trace: B26StageTrace, hold: B26StageHold? = nil, phase: Int = -1,
                     refuseFirst: Bool = false, throwIssue: Bool = false, cancelOnIssue: Bool = false, failure: Int = -1,
                     onProof: @escaping @MainActor (Int) -> Void = { _ in },
                     afterFinish: @escaping @MainActor () -> Void = {}) -> SurroundingTextPort {
        .init(open: { id, target in
            _ = trace.note("open")
            let backend = B26StageBackend(trace: trace, hold: hold, phase: phase, refuseFirst: refuseFirst,
                throwIssue: throwIssue, cancelOnIssue: cancelOnIssue, failure: failure, onProof: onProof, afterFinish: afterFinish)
            trace.backend = backend
            let proofToken = B26StageProofToken(trace); trace.proofToken = proofToken
            let scope = SurroundingTextOperation(operationID: id, target: target,
                proof: { admit in
                    defer { withExtendedLifetime(proofToken) {} }
                    return try await backend.proof(admit)
                },
                issue: { try backend.issue($0, $1, $2, $3) }, finishAndWaitForExit: { await backend.finish() })
            trace.scope = scope; return scope
        })
    }
}

extension SurroundingTextContextIntegrationTests {
    @MainActor func testStageA01NilOpenIsInertBeforePolicyOrParticipation() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        var opened = 0, slept = 0
        r.sleep = { _ in slept += 1; XCTFail("Nil open cannot create a watchdog") }
        let port = SurroundingTextPort(open: { id, target in
            opened += 1; XCTAssertEqual(id, s.operation.id); XCTAssertTrue(target == "test.editor"); return nil
        })
        XCTAssertNil(SurroundingTextPort.unsupported.open(s.operation.id, "test.editor"))
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
        guard await task.joinObserved(identity) else { return }
        XCTAssertEqual(opened, 1); XCTAssertEqual(slept, 0); XCTAssertEqual(f.proofs, 0); XCTAssertEqual(f.issues, 0)
        XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 1); XCTAssertEqual(r.primitiveUsageCalls, 1)
        XCTAssertFalse(s.surroundingTextRun.participated)
    }

    @MainActor func testStageA02HeldMetadataAndCleanupOwnLaneThroughGrantAndParentCancellation() async throws {
        // First, pre-read, post-credential, post-response, post-watchdog, drain.
        for phase in [1, 2, 4, 5, 6, 7] {
            for parentCancel in [false, true] {
                let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
                let hold = B26StageHold(), trace = B26StageTrace()
                defer { hold.release() }
                let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, hold: hold, phase: phase)))
                let identity = task.id
                let entered = await hold.entered.observe(); XCTAssertTrue(entered)
                guard entered else { hold.release(); _ = await task.joinObserved(identity); return }
                XCTAssertEqual(trace.heldID, hold.id); XCTAssertEqual(trace.scope?.operationID, s.operation.id)
                XCTAssertFalse(task.completed.occurred); XCTAssertFalse(s.operation.hasExited)
                let attempted = B26StageEvent(), revoked = B26StageEvent()
                if parentCancel { s.operation.requestAbort(); attempted.signal(); revoked.signal() }
                else {
                    // Independent contender: no MainActor hop and no same-thread
                    // recursive-lock success masquerading as cross-thread proof.
                    let store = d.store
                    DispatchQueue.global().async { attempted.signal(); store.revokeSurroundingTextContext(); revoked.signal() }
                }
                let didAttempt = await attempted.observe(), didRevoke = await revoked.observe()
                XCTAssertTrue(didAttempt); XCTAssertTrue(didRevoke)
                XCTAssertThrowsError(try trace.scope?.checkCancellation())
                let queued = B26StageEvent(), advanced = B26StageEvent()
                let successor = PendingOperation(name: "Stage A successor", diagnostics: nil)
                let second = B26StageOwnedTask(Task {
                    let barrier = PendingOperationQueue.enqueue(previous: task.task, operation: successor, completes: true, work: { advanced.signal() })
                    queued.signal(); await barrier.value
                })
                let successorID = second.id
                let didQueue = await queued.observe(); XCTAssertTrue(didQueue)
                XCTAssertFalse(advanced.occurred); XCTAssertFalse(s.operation.hasExited)
                hold.release()
                let returned = await hold.returned.observe(), phaseReturned = await trace.phaseReturned.observe()
                XCTAssertTrue(returned); XCTAssertTrue(phaseReturned); XCTAssertEqual(trace.heldID, hold.id)
                guard await task.joinObserved(identity), await second.joinObserved(successorID) else { return }
                XCTAssertTrue(advanced.occurred); XCTAssertTrue(s.operation.hasExited); XCTAssertFalse(hold.timedOut)
                XCTAssertEqual(trace.count("finishEntry"), 1); XCTAssertEqual(trace.count("finishExit"), 1)
                XCTAssertNil(trace.backend); XCTAssertNil(trace.admissionToken)
                if phase >= 4 || parentCancel { XCTAssertEqual(r.categories, 0) }
                else { XCTAssertEqual(r.categories, 1) }
                if phase >= 5 { XCTAssertNil(r.runtime.results.read()) } // Independent ordinary authority, prearm only.
                if phase <= 4 { XCTAssertEqual(h.constructed, 0) }
                XCTAssertFalse(r.posted == [h.text])
            }
        }
    }

    @MainActor func testStageA03RegistrationAndCancelBeforeStartDrainWithoutMetadataEntry() async throws {
        for cancelBeforeOpen in [false, true] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let base = B26StageBackend.port(trace)
            let port = SurroundingTextPort(open: { id, target in
                let scope = base.open(id, target)
                if cancelBeforeOpen { scope?.cancel() } // Latch-only, still inert.
                return scope
            })
            if !cancelBeforeOpen { d.store.revokeSurroundingTextContext() }
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
            guard await task.joinObserved(identity) else { return }
            XCTAssertEqual(trace.count("proof"), 0); XCTAssertEqual(trace.count("metadataEntry"), 0)
            XCTAssertEqual(trace.count("issue"), 0); XCTAssertEqual(trace.count("finishExit"), 1)
            XCTAssertEqual(h.constructed, 0); XCTAssertFalse(s.surroundingTextRun.participated)
        }
    }

    @MainActor func testStageA04IssueThrowAndArmedCanceledReadNeverResendCategory() async throws {
        for throwIssue in [false, true] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let port = B26StageBackend.port(trace, throwIssue: throwIssue, cancelOnIssue: !throwIssue)
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
            guard await task.joinObserved(identity) else { return }
            XCTAssertTrue(s.surroundingTextRun.participated); XCTAssertEqual(trace.count("issue"), 1)
            XCTAssertEqual(trace.count("readStart"), 0); XCTAssertEqual(trace.count("finishExit"), 1)
            XCTAssertEqual(trace.count("readCancel"), throwIssue ? 0 : 1)
            XCTAssertEqual(d.backend.reads, 0); XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
            XCTAssertTrue(r.posted == [r.raw]); XCTAssertTrue(r.learned.isEmpty)
        }
    }

    @MainActor func testStageA05ArmedNeverInvokedHandleAndRepeatedFinishOwnCleanup() async throws {
        let trace = B26StageTrace(), id = UUID(), port = B26StageBackend.port(trace)
        let scope = try XCTUnwrap(port.open(id, "test.editor"))
        let observed = try await scope.proof(admit: { 1 })
        let field = try XCTUnwrap(observed)
        let read = try scope.issue(field, range: field.request, admit: { 1 })
        XCTAssertEqual(trace.count("readStart"), 0); scope.cancel(); read.cancel()
        let done = B26StageOwnedTask(Task { await scope.finishAndWaitForExit(); await scope.finishAndWaitForExit() }), identity = done.id
        guard await done.joinObserved(identity) else { return }
        XCTAssertEqual(trace.count("readCancel"), 1); XCTAssertEqual(trace.count("readStart"), 0)
        XCTAssertEqual(trace.count("finishExit"), 1); XCTAssertNil(trace.backend); XCTAssertNil(trace.admissionToken)
        do { _ = try await scope.proof(admit: { 1 }); XCTFail("Closed scope cannot schedule") } catch {}
    }

    @MainActor func testStageA06DisarmRevocationParticipatesWithoutIssueCredentialsOrHTTP() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
        r.onDisarm = { r.onDisarm = {}; d.store.revokeSurroundingTextContext() }
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace))), identity = task.id
        guard await task.joinObserved(identity) else { return }
        XCTAssertTrue(s.surroundingTextRun.participated); XCTAssertEqual(trace.count("proof"), 2)
        XCTAssertEqual(trace.count("issue"), 0); XCTAssertEqual(trace.count("readStart"), 0)
        XCTAssertEqual(trace.count("finishExit"), 1); XCTAssertEqual(d.backend.reads, 0)
        XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0); XCTAssertTrue(r.posted == [r.raw])
        XCTAssertEqual(r.primitiveUsageCalls, 0); XCTAssertTrue(r.learned.isEmpty)
    }

    @MainActor func testStageA07HeldActualReadDeliversFakeCancelOutsideStoreAndWaitsForReturn() async throws {
        for parentCancel in [false, true] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let hold = B26StageHold(); defer { hold.release() }
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, hold: hold, phase: 0))), identity = task.id
            let entered = await hold.entered.observe(); XCTAssertTrue(entered)
            guard entered else { hold.release(); _ = await task.joinObserved(identity); return }
            XCTAssertEqual(trace.heldID, hold.id); XCTAssertEqual(trace.count("readStart"), 1)
            let revoked = B26StageEvent(), store = d.store
            if parentCancel { s.operation.requestAbort(); revoked.signal() }
            else { DispatchQueue.global().async { store.revokeSurroundingTextContext(); revoked.signal() } }
            let didRevoke = await revoked.observe(), delivered = await trace.canceledRead.observe()
            XCTAssertTrue(didRevoke); XCTAssertTrue(delivered)
            XCTAssertFalse(hold.returned.occurred); XCTAssertFalse(task.completed.occurred)
            XCTAssertEqual(trace.count("finishEntry"), 0); XCTAssertFalse(s.operation.hasExited)
            hold.release()
            let returned = await hold.returned.observe(); XCTAssertTrue(returned); XCTAssertEqual(trace.heldID, hold.id)
            guard await task.joinObserved(identity) else { return }
            XCTAssertEqual(trace.count("readCancel"), 1); XCTAssertEqual(trace.count("finishExit"), 1)
            XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0); XCTAssertEqual(d.backend.reads, 0)
            XCTAssertFalse(hold.timedOut); XCTAssertTrue(s.operation.hasExited)
        }
    }

    @MainActor func testStageA08NilMetadataWaitsForFinalCleanupBeforeCategory() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
        let hold = B26StageHold(); defer { hold.release() }
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, hold: hold, phase: 7, refuseFirst: true))), identity = task.id
        let entered = await hold.entered.observe(); XCTAssertTrue(entered)
        guard entered else { hold.release(); _ = await task.joinObserved(identity); return }
        XCTAssertEqual(trace.heldID, hold.id); XCTAssertEqual(trace.count("proof"), 1)
        XCTAssertEqual(r.categories, 0); XCTAssertEqual(h.constructed, 0); XCTAssertFalse(s.operation.hasExited)
        hold.release(); let returned = await hold.returned.observe(); XCTAssertTrue(returned)
        guard await task.joinObserved(identity) else { return }
        XCTAssertEqual(r.categories, 1); XCTAssertEqual(trace.count("finishExit"), 1)
        XCTAssertFalse(s.surroundingTextRun.participated); XCTAssertFalse(hold.timedOut)
    }

    @MainActor func testStageA09LogicalWindowsIncludeProofAndFinalDrainEquality() async throws {
        for site in [1, 2, 7] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let port = B26StageBackend.port(trace, onProof: { phase in
                if phase == site { r.time += site == 1 ? 15 : 1 }
            }, afterFinish: { if site == 7 { r.time += 15 } })
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
            guard await task.joinObserved(identity) else { return }
            XCTAssertEqual(trace.count("finishExit"), 1)
            if site <= 2 { XCTAssertEqual(trace.count("issue"), 0); XCTAssertEqual(h.constructed, 0) }
            else { XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.categories, 0); XCTAssertFalse(r.posted == [h.text]) }
        }
    }

    @MainActor func testStageA10SuccessfulDrainReleasesBackendAndAdmissionButKeepsRunAuthority() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
        let hold = B26StageHold(); defer { hold.release() }
        var checked = false
        r.beforeCompleted = {
            checked = true
            XCTAssertNil(trace.backend); XCTAssertNil(trace.admissionToken); XCTAssertNil(trace.proofToken); XCTAssertNil(trace.scope)
            XCTAssertEqual(trace.count("backendReleased"), 1); XCTAssertEqual(trace.count("admissionReleased"), 1); XCTAssertEqual(trace.count("proofReleased"), 1)
            do { try s.surroundingTextRun.check() } catch { XCTFail("Successful drain unexpectedly revoked run authority") }
            XCTAssertTrue(s.surroundingTextRun.insertionRequiresAuthority)
        }
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, hold: hold, phase: 7))), identity = task.id
        let entered = await hold.entered.observe(); XCTAssertTrue(entered)
        guard entered else { hold.release(); _ = await task.joinObserved(identity); return }
        XCTAssertEqual(trace.heldID, hold.id); XCTAssertEqual(trace.scope?.operationID, s.operation.id)
        XCTAssertNotNil(trace.backend); XCTAssertNotNil(trace.admissionToken); XCTAssertNotNil(trace.proofToken); XCTAssertFalse(checked)
        XCTAssertFalse(s.operation.hasExited); XCTAssertFalse(task.completed.occurred)
        hold.release(); let returned = await hold.returned.observe(); XCTAssertTrue(returned)
        guard await task.joinObserved(identity) else { return }
        XCTAssertFalse(hold.timedOut); XCTAssertTrue(checked); XCTAssertEqual(trace.count("proof"), 6); XCTAssertEqual(trace.count("finishExit"), 1)
        XCTAssertTrue(r.posted == [h.text]); XCTAssertEqual(r.categories, 0); XCTAssertTrue(r.learned.isEmpty)
        XCTAssertNoThrow(try s.surroundingTextRun.check())
    }

    @MainActor func testStageA11RevocationDuringFreshSubscriptionIsCoveredByTransientAuthority() async throws {
        for handoffRead in [1, 2] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            var handedOff = 0, observations = 0
            let port = B26StageBackend.port(trace, afterFinish: {
                d.onDocumentRead = {
                    observations += 1
                    guard observations == handoffRead else { return }
                    d.onDocumentRead = {}; handedOff += 1
                    XCTAssertNil(trace.backend); XCTAssertNil(trace.admissionToken); XCTAssertNil(trace.proofToken)
                    do { try s.surroundingTextRun.check() } catch { XCTFail("Run authority was absent before handoff revocation") }
                    d.store.revokeSurroundingTextContext()
                    do { try s.surroundingTextRun.check(); XCTFail("Revoked run authority remained usable") } catch { }
                    if handoffRead == 2 {
                        // Transient observer has been removed. The final run-only
                        // observer vetoes without closing/retaining the old scope.
                        do { try trace.scope?.checkCancellation() } catch { XCTFail("Run-only handoff unexpectedly canceled the retired scope") }
                    }
                }
            })
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
            guard await task.joinObserved(identity) else { return }
            XCTAssertEqual(handedOff, 1); XCTAssertEqual(observations, handoffRead)
            XCTAssertEqual(h.resumed, 1); XCTAssertEqual(r.categories, 0)
            XCTAssertFalse(r.posted == [h.text]); XCTAssertFalse(s.surroundingTextRun.insertionRequiresAuthority)
            XCTAssertThrowsError(try s.surroundingTextRun.check()); XCTAssertNil(trace.backend)
        }
    }
}

extension SurroundingTextContextIntegrationTests {
    @MainActor func testStageA12HTTPCancelKeepsScopeSlotAndRequiresCompletionPlusExit() async throws {
        for parentCancel in [false, true] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let entered = B26StageEvent(), canceled = B26StageEvent(), release = B26StageHold()
            defer { release.release() }
            // Even failure/early assertion paths independently release BOTH HTTP
            // acknowledgments. This task is owned and observed before its join.
            let callbacks = B26StageHTTPRelease()
            let failRelease = B26StageOwnedTask(Task { await release.wait(); callbacks.release() }), releaseID = failRelease.id
            let releaseEntered = await release.entered.observe(); XCTAssertTrue(releaseEntered)
            h.held = true; h.onResume = { [weak h] in guard let h else { XCTFail("HTTP fake released before resume"); return }; callbacks.install(h.callbacks, handleID: h.handle.map(ObjectIdentifier.init)); entered.signal() }; h.onCancel = { canceled.signal() }
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace))), identity = task.id
            let didEnter = await entered.observe(); XCTAssertTrue(didEnter)
            guard didEnter else {
                release.release(); _ = await failRelease.joinObserved(releaseID); _ = await task.joinObserved(identity); return
            }
            let handleID = h.handle.map(ObjectIdentifier.init)
            XCTAssertNotNil(handleID); XCTAssertEqual(callbacks.handleID, handleID)
            XCTAssertEqual(trace.count("proof"), 4); XCTAssertEqual(trace.count("readExit"), 1)
            XCTAssertEqual(trace.scope?.operationID, s.operation.id)
            if parentCancel { s.operation.requestAbort() } else { d.store.revokeSurroundingTextContext() }
            let didCancel = await canceled.observe(); XCTAssertTrue(didCancel)
            XCTAssertThrowsError(try trace.scope?.checkCancellation())
            XCTAssertFalse(task.completed.occurred); XCTAssertFalse(s.operation.hasExited)
            h.callbacks?.completed(CancellationError())
            XCTAssertFalse(task.completed.occurred); XCTAssertEqual(trace.count("proof"), 4)
            let queued = B26StageEvent(), advanced = B26StageEvent()
            let next = B26StageOwnedTask(Task {
                let barrier = PendingOperationQueue.enqueue(previous: task.task,
                    operation: PendingOperation(name: "Stage A HTTP successor", diagnostics: nil), completes: true, work: { advanced.signal() })
                queued.signal(); await barrier.value
            }), nextID = next.id
            let didQueue = await queued.observe(); XCTAssertTrue(didQueue); XCTAssertFalse(advanced.occurred)
            release.release()
            let released = await release.returned.observe(); XCTAssertTrue(released)
            XCTAssertEqual(callbacks.handleID, handleID)
            guard await failRelease.joinObserved(releaseID), await task.joinObserved(identity), await next.joinObserved(nextID) else { return }
            XCTAssertEqual(trace.count("proof"), 4); XCTAssertEqual(trace.count("finishExit"), 1)
            XCTAssertTrue(advanced.occurred); XCTAssertTrue(s.operation.hasExited); XCTAssertEqual(r.categories, 0)
            XCTAssertFalse(r.posted == [h.text]); XCTAssertFalse(release.timedOut)
        }
    }

    @MainActor func testStageA13HTTPActualExitPrecedesNextOwnedMetadata() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
        let httpEntered = B26StageEvent(), proofHold = B26StageHold(), httpHold = B26StageHold(), callbacks = B26StageHTTPRelease()
        defer { proofHold.release(); httpHold.release() }
        let httpRelease = B26StageOwnedTask(Task { await httpHold.wait(); callbacks.release() }), httpReleaseID = httpRelease.id
        let releaseEntered = await httpHold.entered.observe(); XCTAssertTrue(releaseEntered)
        h.held = true; h.onResume = { [weak h] in guard let h else { XCTFail("HTTP fake released before resume"); return }; callbacks.install(h.callbacks, handleID: h.handle.map(ObjectIdentifier.init)); httpEntered.signal() }
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, hold: proofHold, phase: 5))), identity = task.id
        let entered = await httpEntered.observe(); XCTAssertTrue(entered)
        guard entered else {
            httpHold.release(); proofHold.release(); _ = await httpRelease.joinObserved(httpReleaseID); _ = await task.joinObserved(identity); return
        }
        let handleID = h.handle.map(ObjectIdentifier.init)
        XCTAssertNotNil(handleID); XCTAssertEqual(callbacks.handleID, handleID)
        // Deliver valid result and completion while withholding actual exit.
        if let request = h.requests.first, let c = h.callbacks {
            let response = try b26AppResponse(request)
            _ = c.response(response.1); _ = c.data(response.0); c.completed(nil)
        } else { XCTFail("Missing owned fake HTTP handle") }
        XCTAssertEqual(trace.count("proof"), 4); XCTAssertFalse(proofHold.entered.occurred)
        httpHold.release()
        let httpReturned = await httpHold.returned.observe(), proofEntered = await proofHold.entered.observe()
        XCTAssertTrue(httpReturned); XCTAssertTrue(proofEntered)
        guard proofEntered else {
            proofHold.release(); _ = await httpRelease.joinObserved(httpReleaseID); _ = await task.joinObserved(identity); return
        }
        XCTAssertEqual(trace.heldID, proofHold.id); XCTAssertEqual(trace.count("proof"), 5)
        XCTAssertFalse(s.operation.hasExited)
        let revoked = B26StageEvent(), store = d.store
        DispatchQueue.global().async { store.revokeSurroundingTextContext(); revoked.signal() }
        let didRevoke = await revoked.observe(); XCTAssertTrue(didRevoke)
        XCTAssertThrowsError(try trace.scope?.checkCancellation()); XCTAssertFalse(task.completed.occurred)
        proofHold.release(); let returned = await proofHold.returned.observe(); XCTAssertTrue(returned)
        XCTAssertEqual(callbacks.handleID, handleID)
        guard await httpRelease.joinObserved(httpReleaseID), await task.joinObserved(identity) else { return }
        XCTAssertEqual(trace.count("finishExit"), 1); XCTAssertEqual(r.categories, 0)
        XCTAssertFalse(proofHold.timedOut); XCTAssertFalse(httpHold.timedOut); XCTAssertFalse(r.posted == [h.text])
    }

    @MainActor func testStageA14WatchdogReturnThenFinalProofStillHaveParentCancellationOwner() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
        let watchdog = B26StageHold(), finalProof = B26StageHold(), httpReturned = B26StageEvent()
        defer { watchdog.release(); finalProof.release() }
        r.sleep = { _ in await watchdog.wait() }
        h.onResume = { httpReturned.signal() }
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, hold: finalProof, phase: 6))), identity = task.id
        let entered = await watchdog.entered.observe(), http = await httpReturned.observe()
        XCTAssertTrue(entered); XCTAssertTrue(http)
        guard entered && http else {
            watchdog.release(); finalProof.release(); _ = await task.joinObserved(identity); return
        }
        XCTAssertFalse(s.operation.hasExited); XCTAssertFalse(finalProof.entered.occurred)
        let queued = B26StageEvent(), advanced = B26StageEvent()
        let next = B26StageOwnedTask(Task {
            let barrier = PendingOperationQueue.enqueue(previous: task.task,
                operation: PendingOperation(name: "Stage A watchdog successor", diagnostics: nil), completes: true, work: { advanced.signal() })
            queued.signal(); await barrier.value
        }), nextID = next.id
        let didQueue = await queued.observe(); XCTAssertTrue(didQueue); XCTAssertFalse(advanced.occurred)
        watchdog.release()
        let watchdogReturned = await watchdog.returned.observe(), finalEntered = await finalProof.entered.observe()
        XCTAssertTrue(watchdogReturned); XCTAssertTrue(finalEntered)
        guard finalEntered else { finalProof.release(); _ = await task.joinObserved(identity); _ = await next.joinObserved(nextID); return }
        XCTAssertEqual(trace.heldID, finalProof.id); XCTAssertEqual(trace.scope?.operationID, s.operation.id)
        s.operation.requestAbort()
        XCTAssertThrowsError(try trace.scope?.checkCancellation()); XCTAssertFalse(s.operation.hasExited); XCTAssertFalse(advanced.occurred)
        finalProof.release(); let returned = await finalProof.returned.observe(); XCTAssertTrue(returned)
        guard await task.joinObserved(identity), await next.joinObserved(nextID) else { return }
        XCTAssertTrue(advanced.occurred); XCTAssertEqual(trace.count("finishExit"), 1)
        XCTAssertFalse(watchdog.timedOut); XCTAssertFalse(finalProof.timedOut); XCTAssertEqual(r.categories, 0)
    }

    @MainActor func testStageA15LegacyMainActorCallbacksAndCancelReturnAreOwned() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP()
        let readHold = B26StageHold(), cancelEntered = B26StageEvent()
        defer { readHold.release() }
        let field = try XCTUnwrap(f.field)
        var proofCalls = 0, issues = 0
        // A synchronous fake cancel can stall. It is NEVER called on Settings'
        // stack: an independent revoke must return while this callback is held.
        let synchronousCancel = B26StageSynchronousHold()
        defer { synchronousCancel.release() }
        let port = SurroundingTextPort(proof: {
            MainActor.preconditionIsolated(); proofCalls += 1; return field
        }, issue: { field, range, remaining in
            MainActor.preconditionIsolated(); issues += 1
            XCTAssertGreaterThan(remaining, 0); XCTAssertLessThanOrEqual(remaining, 1)
            return SurroundingTextRead(value: {
                await readHold.wait()
                return .init(field: field, range: range, units: Array(f.prefix.utf16), startBoundaryProved: true)
            }, cancel: { cancelEntered.signal(); synchronousCancel.wait() })
        })
        // A separate finite observer is unnecessary for the synchronous hold;
        // its own global fail-release is independent of MainActor/cooperative work.
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
        let entered = await readHold.entered.observe(); XCTAssertTrue(entered)
        guard entered else { readHold.release(); synchronousCancel.release(); _ = await task.joinObserved(identity); return }
        let revoked = B26StageEvent(), store = d.store
        DispatchQueue.global().async { store.revokeSurroundingTextContext(); revoked.signal() }
        let didRevoke = await revoked.observe(), didCancel = await cancelEntered.observe()
        XCTAssertTrue(didRevoke); XCTAssertTrue(didCancel)
        XCTAssertFalse(s.operation.hasExited); XCTAssertFalse(task.completed.occurred)
        readHold.release(); let readReturned = await readHold.returned.observe(); XCTAssertTrue(readReturned)
        XCTAssertFalse(task.completed.occurred) // Read return alone cannot hide held cancellation handoff.
        synchronousCancel.release()
        let cancelReturned = await synchronousCancel.returned.observe(); XCTAssertTrue(cancelReturned)
        guard await task.joinObserved(identity) else { return }
        XCTAssertEqual(proofCalls, 2); XCTAssertEqual(issues, 1); XCTAssertFalse(readHold.timedOut); XCTAssertFalse(synchronousCancel.timedOut)
        XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 0)
    }
}

/// Owns one exact HTTP callback handle. Release-before-install is remembered;
/// only the test's real callbacks settle the transfer, never an observation timer.
private final class B26StageHTTPRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: HistoryRetryHTTPCallbacks?
    private var released = false
    private var identity: ObjectIdentifier?
    var handleID: ObjectIdentifier? { lock.withLock { identity } }
    func install(_ callbacks: HistoryRetryHTTPCallbacks?, handleID: ObjectIdentifier?) {
        let release = lock.withLock { self.callbacks = callbacks; identity = handleID; return released }
        if release { callbacks?.completed(nil); callbacks?.exited() }
    }
    func release() {
        let callbacks = lock.withLock { () -> HistoryRetryHTTPCallbacks? in
            guard !released else { return nil }; released = true; return self.callbacks
        }
        callbacks?.completed(nil); callbacks?.exited()
    }
}
/// Deliberately blocking legacy TEST callback, never a native worker. A timed
/// condition has an independent global release and sticky failure; it cannot
/// block Settings, main, or teardown indefinitely. Production cancel is a latch.
private final class B26StageSynchronousHold: @unchecked Sendable {
    let returned = B26StageEvent()
    private let condition = NSCondition()
    private var released = false, failed = false
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return failed }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func wait() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.condition.lock()
            if !self.released { self.failed = true }
            self.released = true; self.condition.broadcast(); self.condition.unlock()
        }
        // One bounded wait. A spurious wake refuses this hold rather than polling.
        condition.lock()
        if !released {
            let signaled = condition.wait(until: Date().addingTimeInterval(5))
            if !released || !signaled { failed = true }
        }
        condition.unlock(); returned.signal()
    }
}

extension SurroundingTextContextIntegrationTests {
    @MainActor func testStageA16FiniteProofReadCredentialAndTransportErrorsAlwaysDrain() async throws {
        for failure in [0, 1, 2, 3, 4, 5, 6, 8, 9] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let credentialReadsBeforeWork = d.backend.reads
            if failure == 8 { d.backend.result = .denied }
            if failure == 9 { h.status = 503 }
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: B26StageBackend.port(trace, failure: failure))), identity = task.id
            guard await task.joinObserved(identity) else { return }
            XCTAssertEqual(trace.count("finishEntry"), 1); XCTAssertEqual(trace.count("finishExit"), 1)
            XCTAssertNil(trace.backend); XCTAssertNil(trace.admissionToken); XCTAssertTrue(s.operation.hasExited)
            if failure == 1 || failure == 2 {
                XCTAssertFalse(s.surroundingTextRun.participated); XCTAssertEqual(r.categories, 1)
            } else {
                XCTAssertTrue(s.surroundingTextRun.participated); XCTAssertEqual(r.categories, 0)
                XCTAssertTrue(r.posted == [r.raw]); XCTAssertTrue(r.learned.isEmpty)
            }
            if failure == 8 { XCTAssertEqual(d.backend.reads, credentialReadsBeforeWork + 1) }
            if failure <= 4 || failure == 8 { XCTAssertEqual(h.constructed, 0) }
        }
    }
}

extension SurroundingTextContextIntegrationTests {
    @MainActor func testStageA17ExactOperationBindingAndNormalCloseDoNotBorrowAuthority() async throws {
        for wrongTarget in [false, true] {
            let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
            let base = B26StageBackend.port(trace)
            let port = SurroundingTextPort(open: { id, target in
                base.open(wrongTarget ? id : UUID(), wrongTarget ? "test.other" : target)
            })
            let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
            guard await task.joinObserved(identity) else { return }
            XCTAssertEqual(trace.count("proof"), 0); XCTAssertEqual(trace.count("issue"), 0)
            XCTAssertEqual(trace.count("finishExit"), 1); XCTAssertEqual(h.constructed, 0)
            XCTAssertFalse(s.surroundingTextRun.participated)
        }
        let trace = B26StageTrace(), port = B26StageBackend.port(trace)
        let scope = try XCTUnwrap(port.open(UUID(), "test.editor"))
        let task = B26StageOwnedTask(Task { await scope.finishAndWaitForExit() }), identity = task.id
        guard await task.joinObserved(identity) else { return }
        XCTAssertNoThrow(try scope.checkCancellation()) // Normal close is NOT cancel/revoke.
        do { _ = try await scope.proof(admit: { 1 }); XCTFail("Closed scope cannot schedule") } catch {}
        XCTAssertEqual(trace.count("proof"), 0); XCTAssertEqual(trace.count("finishExit"), 1); XCTAssertNil(trace.backend)
    }
}

extension SurroundingTextContextIntegrationTests {
    @MainActor func testStageA18SubscriptionRefusalStillDrainsInertScopeBeforeCategory() async throws {
        let d = try B26AppDocument(history: false), r = try B26AppRig(d), s = try r.start(), f = B26AppField(), h = B26AppHTTP(), trace = B26StageTrace()
        let base = B26StageBackend.port(trace)
        var admissions = 0
        let port = SurroundingTextPort(open: { id, target in
            let scope = base.open(id, target)
            // Pure test-scaffolding assignment, no query/job in the factory.
            d.onDocumentRead = {
                admissions += 1
                if admissions == 2 {
                    d.onDocumentRead = {}; d.store.revokeSurroundingTextContext()
                }
            }
            return scope
        })
        let task = B26StageOwnedTask(r.work(s, field: f, http: h, port: port)), identity = task.id
        guard await task.joinObserved(identity) else { return }
        XCTAssertEqual(admissions, 2); XCTAssertEqual(trace.count("proof"), 0)
        XCTAssertEqual(trace.count("issue"), 0); XCTAssertEqual(trace.count("finishExit"), 1)
        XCTAssertEqual(h.constructed, 0); XCTAssertEqual(r.categories, 1); XCTAssertFalse(s.surroundingTextRun.participated)
    }
}
