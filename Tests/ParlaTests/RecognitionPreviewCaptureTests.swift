import AppKit
import AVFoundation
import XCTest
@testable import ParlaCore
@testable import Parla

final class RecognitionPreviewCaptureTests: XCTestCase {
    @MainActor private final class Capture {
        let root: URL
        let store: SettingsStore
        let recordings: RecordingStore
        let hub: HubModel
        let native = FoundationNativeProbe()
        let diagnostics = DiagnosticStore()
        let machine: DictationSession
        var session: DictationSession.Session!
        var body: RecognitionPreviewCapture!
        var chain: Task<Void, Never>?
        var recording = true, secure = false
        var updates: [RecognitionPreviewUpdate] = []
        var hud: [HUDState] = []
        var entries: [OrdinaryDictationFinalization.Entry] = []
        var raw: [String?] = [], delivered: [String] = []
        var passInstances: [UUID] = []
        var shadowAnalyses = 0
        var pending: (DictationSession.Session, DictationSession.Landed)?
        var suffixRead: ((UUID) -> RecognitionPreviewSuffix?)?
        var tick: (() -> Void)?
        var onUpdate: ((RecognitionPreviewUpdate) -> Void)?
        var preparation: NativePreparation?
        var now: TimeInterval = 0
        var count = 320_000
        var stopAfterDraft = true
        var alias: RecognitionHandle?
        var factory: RecognitionFactory {
            var f = native.factory(); f.directory = ModelCatalog.directory
            if let preparation {
                f.preparation = preparation.core
                f.preparationPermission = { preparation.core.matchesSavedPermission(self.store.load()) }
                let native = f.native
                f.guardedNative = { path, compute, permit in try permit.nativeEntry { try native(path, compute) } }
            }
            return f
        }
        init(preview: String = "base.en", final: String = "base.en") throws {
            root = URL(fileURLWithPath: "/tmp/parla-implementation-2026-10-28").appendingPathComponent("wave4h1-fixture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try recordWave4BFixture(root, "created")
            let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "path": root.path, "inode": attrs[.systemFileNumber] as! NSNumber,
                "uid": attrs[.ownerAccountID] as! NSNumber,
                "birth": (attrs[.creationDate] as! Date).timeIntervalSince1970]).write(to: root.appendingPathComponent("owner.json"))
            store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore())
            recordings = RecordingStore(directory: root.appendingPathComponent("audio"))
            hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")), recordings: recordings)
            machine = DictationSession(diagnostics: diagnostics)
            var settings = Settings(); settings.whisperModelPath = ModelCatalog.directory.appendingPathComponent("ggml-\(final).bin").path
            settings.cleanupEnabled = false; settings.outputMode = .raw; settings.warmMic = false
            settings.dictionary = ["FrozenDictionary"]; settings.streamPreviewEnabled = false
            try store.save(settings)
            hub.refreshPreparationConfiguration()
            hub.settings.recognitionPreviewModelID = preview
            hub.settings.streamPreviewEnabled = true
            hub.flushPendingSave()
        }
        func start(destination: ProfileDestination = .init()) throws {
            send(.startDictation(settings: store.load(), cleanupConfigured: false, live: false, recognitionDestination: destination))
            send(.recorderStarted(gen: machine.gen)); send(.focusSampled(gen: machine.gen, focus: .editable))
            guard case .recording(let s) = machine.state else { throw RecordingStore.Failure("capture refused") }
            session = s
            let plan = try XCTUnwrap(s.previewPlan)
            body = RecognitionPreviewCapture(plan: plan, operation: s.operation, factory: factory,
                selectionEpoch: hub.modelSelectionEpoch, preparationEpoch: preparation?.core.admissionEpoch, capturing: { self.recording },
                suffix: { id in
                    XCTAssertEqual(id, s.operation.id)
                    if let read = self.suffixRead { return read(id) }
                    return RecognitionPreviewSuffix(copying: Self.audio(self.count))
                }, secure: RecognitionPreviewCapture.secureEvidence({ self.secure }, shadow: s.activityShadowPermission), publish: { update in
                    self.updates.append(update)
                    self.onUpdate?(update)
                    self.send(.recognitionPreview(gen: s.gen, operationID: s.operation.id, phase: plan.phase, update: update))
                    if case .draft = update, self.stopAfterDraft { self.stop() }
                }, clear: {
                    self.send(.recognitionPreviewRevoked(gen: s.gen, operationID: s.operation.id, phase: plan.phase))
                }, releaseAliases: { self.alias = nil }, clock: { self.now }, pause: {
                    self.now += 1
                    self.tick?()
                    await Task.yield()
                })
            hub.onRecognitionPreviewRevoked = { self.body.revoke() }
            preparation?.onChange = { _ in self.body.preparationChanged(self.preparation?.core.admissionEpoch) }
        }
        static func audio(_ count: Int) -> [Float] { (0..<count).map { 0.1 + Float($0 % 11) / 100 } }
        func send(_ event: DictationSession.Event) {
            machine.send(event) { effect in
                if case .hud(let state) = effect { hud.append(state) }
                if case .insertText(let text, _, _) = effect { delivered.append(text) }
                if case .polish(let session, let landed) = effect { pending = (session, landed) }
            }
        }
        func stop() { recording = false; send(.stopRequested) }
        func enqueuePreview() {
            chain = PendingOperationQueue.enqueue(previous: chain, operation: session.operation) { await self.body.run() }
        }
        func configurePreparation(_ enabled: Bool) throws {
            let memory = PreviewPreparationMemory()
            let build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
            let core = RecognitionPreparation(storage: { memory }, build: { build })
            let owner = NativePreparation(core: core)
            var settings = store.load()
            if enabled {
                let consent = UUID(); try core.prepareConsent(consent)
                settings.nativePreparationSafeStartEnabled = true; settings.nativePreparationConsent = consent
            }
            try store.save(settings)
            owner.configure(settings, epoch: hub.modelSelectionEpoch)
            preparation = owner
            native.generation = .init(bytes: ModelCatalog.all[0].bytes, modified: 1)
        }
        func enqueueFinal() {
            let s = session!, full = Self.audio(count)
            chain = PendingOperationQueue.enqueue(previous: chain, operation: s.operation, completes: true) {
                let finalizer = OrdinaryDictationFinalization(recordings: self.recordings, settings: self.store,
                    entered: { self.entries.append($0) })
                await finalizer.run(operation: s.operation, samples: full, window: nil,
                    shadow: s.activityShadowPermission, separatePreview: true,
                    shadowCurrent: { s.gen == self.machine.gen && self.machine.activityShadowPermission == s.activityShadowPermission },
                    analyze: { pcm, abort in self.shadowAnalyses += 1; return ActivityShadow.analyze(pcm, shouldAbort: abort, clock: { 0 }) }, prepare: { _, _ in
                    XCTAssertEqual(self.entries, [.stash])
                    do { return try await self.body.acquireFinal() }
                    catch { return nil }
                }, recognized: { handle, raw in
                    self.passInstances.append(handle.instance)
                    self.raw.append(raw)
                    finalizer.resolve(transcript: raw, secure: false)
                    self.pending = nil
                    self.send(.transcribed(s, raw: raw, probe: .init(focus: .editable)))
                    return self.pending
                }, clean: { context in
                    let pipeline = Pipeline(outputSettings: context.0.effectiveSettings, bundleID: nil, makeClient: { _ in
                        XCTFail("Raw final must not call a provider")
                        throw RecordingStore.Failure("unexpected provider")
                    })
                    return await pipeline.clean(transcript: context.1.raw)
                }, completed: { context, text, failure in
                    finalizer.observeSecurity(secure: false)
                    self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: .editable))
                })
            }
        }
    }
    @MainActor func testSavedHubThroughRealPreviewAndOrdinaryFinalUsesFreshSameAndDifferentInstances() async throws {
        for final in ["base.en", "large-v3-turbo-q5_0"] {
            let c = try Capture(final: final)
            c.native.outputs = [.init(status: 0, segments: ["speculative draft"]), .init(status: 0, segments: ["authoritative final"])]
            try c.start(); c.enqueuePreview(); await c.chain?.value
            XCTAssertFalse(c.session.operation.shouldAbort)
            XCTAssertEqual(c.native.releases, 1)
            XCTAssertEqual(c.native.calls.first?.samples, Array(Capture.audio(c.count).suffix(240_000)))
            c.enqueueFinal(); await c.chain?.value
            XCTAssertEqual(c.native.paths.count, 2); XCTAssertEqual(c.native.releases, 2)
            XCTAssertEqual(c.native.peakLive, 1)
            XCTAssertEqual(c.native.events, ["construct:1", "release:1", "construct:2", "release:2"])
            XCTAssertEqual(c.native.calls.last?.samples, Capture.audio(c.count))
            XCTAssertEqual(c.native.calls.map(\.instance), [1, 2])
            XCTAssertEqual(c.native.calls.map(\.prompt), ["FrozenDictionary", "FrozenDictionary"])
            XCTAssertEqual(c.raw.compactMap { $0 }, ["authoritative final"])
            XCTAssertEqual(c.delivered, ["authoritative final"])
            XCTAssertEqual(c.entries, [.stash, .resolve])
            let record = try XCTUnwrap(c.diagnostics.snapshot().records.last)
            XCTAssertEqual(record.asr, .text); XCTAssertEqual(record.preview?.requests, 1)
            XCTAssertEqual(record.requestedASR, DiagnosticASRModel(rawValue: final))
            XCTAssertEqual(record.resolvedASR, DiagnosticASRModel(rawValue: final))
            XCTAssertEqual(record.preview?.maximumSamples, 240_000)
            XCTAssertEqual(record.timings.first(where: { $0.stage == .previewASR })?.calls, 1)
            XCTAssertFalse(String(decoding: try c.diagnostics.snapshot().encoded(), as: UTF8.self).contains("speculative draft"))
        }
    }
    @MainActor func testEnergyShadowRunsOnlyOnFreshFinalOriginalWithActualPreviewRoute() async throws {
        for final in ["base.en", "large-v3-turbo-q5_0"] {
            let c = try Capture(final: final)
            c.hub.settings.energyActivityShadowEnabled = true; c.hub.flushPendingSave()
            c.native.outputs = [.init(status: 0, segments: ["PRIVATE_DRAFT"]), .init(status: 0, segments: ["authoritative final"])]
            try c.start(); c.enqueuePreview(); await c.chain?.value
            XCTAssertEqual(c.shadowAnalyses, 0)
            XCTAssertNil(c.diagnostics.snapshot().records.last?.activityShadow)
            c.enqueueFinal(); await c.chain?.value
            XCTAssertEqual(c.shadowAnalyses, 1); XCTAssertEqual(c.native.calls.map(\.instance), [1, 2])
            XCTAssertEqual(c.native.calls.last?.samples, Capture.audio(c.count))
            let fact = try XCTUnwrap(c.diagnostics.snapshot().records.last?.activityShadow)
            XCTAssertEqual(fact.actual.separatePreview, true); XCTAssertEqual(fact.actual.selection, .fullPass)
            XCTAssertEqual(fact.originalSamples, c.count); XCTAssertEqual(c.raw.compactMap { $0 }, ["authoritative final"])
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(fact), as: UTF8.self).contains("PRIVATE_DRAFT"))
        }
    }
    @MainActor func testPreviewSecureEvidencePermanentlyRevokesShadowBeforeEditableFinal() async throws {
        let c = try Capture()
        c.hub.settings.energyActivityShadowEnabled = true; c.hub.flushPendingSave()
        c.native.outputs = [.init(status: 0, segments: ["draft"]), .init(status: 0, segments: ["final"])]
        c.stopAfterDraft = false
        c.onUpdate = { if case .draft = $0 { c.secure = true } }
        try c.start(); c.enqueuePreview(); await c.chain?.value
        XCTAssertFalse(try XCTUnwrap(c.session.previewPlan).phase.isCurrent)
        XCTAssertFalse(try XCTUnwrap(c.session.activityShadowPermission).isCurrent)
        XCTAssertFalse(c.session.operation.shouldAbort)
        c.secure = false; c.stop(); c.enqueueFinal(); await c.chain?.value
        XCTAssertEqual(c.shadowAnalyses, 0)
        XCTAssertNil(c.diagnostics.snapshot().records.last?.activityShadow)
        XCTAssertEqual(c.raw.compactMap { $0 }, ["final"])
        XCTAssertEqual(c.delivered, ["final"])
        XCTAssertEqual(c.native.calls.map(\.instance), [1, 2])
    }
    @MainActor func testPreviewDetectedLanguageDoesNotSeedFreshFinalAndNoDraftPromptFeedback() async throws {
        let c = try Capture(preview: "large-v3-turbo-q5_0", final: "large-v3-turbo-q5_0")
        c.native.detectedLanguage = "hi"
        try c.start(); c.enqueuePreview(); await c.chain?.value
        c.enqueueFinal(); await c.chain?.value
        XCTAssertEqual(c.native.calls.map(\.language), ["en", "hi", "en", "hi"])
        XCTAssertEqual(c.native.calls.map(\.instance), [1, 1, 2, 2])
        XCTAssertTrue(c.native.calls.allSatisfy { $0.prompt == "FrozenDictionary" })
        XCTAssertEqual(c.native.peakLive, 1)
    }
    @MainActor func testSuccessfulDraftCannotBecomeFinalAfterFailureEmptyQuietOrAcquisitionRefusal() async throws {
        for outcome in 0..<4 {
            let c = try Capture()
            c.native.outputs = [.init(status: 0, segments: ["preview only"]),
                outcome == 0 ? .init(status: 3) : .init(status: 0)]
            try c.start(); c.enqueuePreview(); await c.chain?.value
            if outcome == 2 { c.count = 0 }
            if outcome == 3 { c.native.admission = { _, _ in throw RecordingStore.Failure("fixture refused") } }
            c.enqueueFinal(); await c.chain?.value
            XCTAssertTrue(c.delivered.isEmpty)
            XCTAssertTrue(c.raw.compactMap { $0 }.allSatisfy(\.isEmpty))
            XCTAssertFalse(c.raw.compactMap { $0 }.contains("preview only"))
        }
    }
    @MainActor func testHeldConstructorAndDecodeKeepFinalAndSuccessorBehindActualExit() async throws {
        for heldConstructor in [true, false] {
            let c = try Capture(); c.stopAfterDraft = false
            let entered = expectation(description: "native entered"), gate = DispatchSemaphore(value: 0)
            let hold = { entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success) }
            if heldConstructor { c.native.construct = hold } else { c.native.decode = hold }
            try c.start(); c.enqueuePreview()
            await fulfillment(of: [entered], timeout: 5)
            c.stop(); c.body.revoke()
            XCTAssertFalse(c.session.operation.shouldAbort); XCTAssertFalse(c.session.operation.hasExited)
            XCTAssertEqual(c.native.paths.count, 1); XCTAssertFalse(c.updates.contains { if case .draft = $0 { return true }; return false })
            c.native.construct = nil; c.native.decode = nil
            c.enqueueFinal()
            var successor = false
            let tail = PendingOperationQueue.enqueue(previous: c.chain, operation: PendingOperation(name: "successor"), completes: true) { successor = true }
            XCTAssertFalse(successor)
            gate.signal(); await tail.value
            XCTAssertTrue(successor); XCTAssertEqual(c.native.paths.count, 2)
            XCTAssertEqual(c.native.peakLive, 1); XCTAssertEqual(c.native.releases, 2)
            XCTAssertFalse(c.updates.contains { if case .draft = $0 { return true }; return false })
        }
    }
    @MainActor func testSecureEvidenceAndDraftSettingsRevokeForRestOfCapture() async throws {
        for secure in [true, false] {
            let c = try Capture(); c.stopAfterDraft = false
            try c.start()
            if secure { c.secure = true }
            else { c.hub.settings.recognitionPreviewModelID = "small.en-q5_1"; c.hub.flushPendingSave() }
            c.enqueuePreview(); await c.chain?.value
            XCTAssertFalse(c.body.plan.phase.isCurrent)
            XCTAssertTrue(c.native.paths.isEmpty)
            c.secure = false
            await c.body.run()
            XCTAssertTrue(c.native.paths.isEmpty)
            XCTAssertTrue(c.updates.allSatisfy { if case .draft = $0 { return false }; return true })
            c.stop(); c.enqueueFinal(); await c.chain?.value
            XCTAssertEqual(c.native.paths.count, 1)
        }
    }
    @MainActor func testPreviewOnlySavesAndProjectionStayPassiveAndFailedSaveDoesNotEnable() throws {
        let c = try Capture()
        var setups = 0, revokes = 0
        c.hub.onSaved = { setups += 1 }; c.hub.onRecognitionPreviewRevoked = { revokes += 1 }
        for _ in 0..<4 {
            _ = c.hub.recognitionPreviewChoices; _ = c.hub.recognitionPreviewUnavailableID
            _ = c.hub.recognitionCapabilities; _ = c.hub.recognitionCapabilityDetail
        }
        c.hub.settings.recognitionPreviewModelID = "missing"; c.hub.flushPendingSave()
        XCTAssertEqual(c.hub.recognitionPreviewUnavailableID, "missing")
        c.hub.settings.streamPreviewEnabled = false; c.hub.flushPendingSave()
        XCTAssertEqual(setups, 0); XCTAssertGreaterThan(revokes, 0)
        XCTAssertTrue(c.native.paths.isEmpty); XCTAssertEqual(c.native.admissions, 0)
        c.hub.onPreparationBeforeSave = { _ in throw RecordingStore.Failure("fixture save refused") }
        c.hub.settings.streamPreviewEnabled = true; c.hub.flushPendingSave()
        XCTAssertNotNil(c.hub.saveError); XCTAssertFalse(c.store.load().streamPreviewEnabled)
    }

    @MainActor func testMissingPreviewIsNonfatalAndOldAliasesDieBeforePreviewConstruction() async throws {
        for missing in [true, false] {
            let c = try Capture(final: "large-v3-turbo-q5_0")
            try c.start()
            // Acquire stale ownership through the real factory, never a hand-made handle.
            c.alias = try await RecognitionAcquisition.acquire(request: c.session.recognition, resident: nil, factory: c.factory)
            if missing {
                c.native.admission = { path, _ in
                    if path.hasSuffix("ggml-base.en.bin") { throw RecordingStore.Failure("missing fixture preview") }
                }
            }
            c.enqueuePreview(); await c.chain?.value
            if missing {
                XCTAssertEqual(c.native.paths.count, 1)
                XCTAssertTrue(c.updates.contains(.status(.unavailable)))
                c.stop()
            } else {
                XCTAssertEqual(c.native.events.prefix(3), ["construct:1", "release:1", "construct:2"])
            }
            c.enqueueFinal(); await c.chain?.value
            XCTAssertEqual(c.native.peakLive, 1)
            XCTAssertEqual(c.native.paths.last, c.session.recognition.modelPath)
            XCTAssertEqual(c.delivered, ["native original"])
        }
    }

    @MainActor func testLateSecureEvidenceClearsDraftAndCancellationCannotPaintSuccessor() async throws {
        for cancel in [true, false] {
            let c = try Capture(); c.stopAfterDraft = false
            let entered = expectation(description: "held pass"), gate = DispatchSemaphore(value: 0)
            c.native.decode = { entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success) }
            try c.start(); c.enqueuePreview()
            await fulfillment(of: [entered], timeout: 5)
            if cancel {
                c.send(.cancelRequested(silent: false)); c.session.operation.requestAbort()
                c.send(.startDictation(settings: c.store.load(), cleanupConfigured: false, live: false))
            } else { c.secure = true }
            c.native.decode = nil; gate.signal(); await c.chain?.value
            XCTAssertFalse(c.body.plan.phase.isCurrent)
            XCTAssertFalse(c.updates.contains { if case .draft = $0 { return true }; return false })
            XCTAssertEqual(c.native.releases, 1)
            if cancel { XCTAssertTrue(c.session.operation.shouldAbort) }
        }
    }

    private final class Engine: MicrophoneCaptureEngine {
        var isRunning = false
        var route = MicrophoneRoute()
        func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws { isRunning = true }
        func stop() { isRunning = false }
    }
    @MainActor func testTenMinuteCaptureBoundsCadenceRequestsAndHUDWithoutRetainingNativeTestPCM() async throws {
        let c = try Capture(); c.stopAfterDraft = false; c.native.retainSamples = false
        c.native.outputs = [.init(status: 0, segments: [String(repeating: "🌏", count: 3000)])]
        let recorder = AudioRecorder(engine: Engine()), chunk = [Float](repeating: 0.2, count: 16_000)
        try c.start(); try recorder.start(diagnosticOperation: c.session.operation.id)
        recorder.append(chunk)
        var totals: [Int] = [], starts: [TimeInterval] = []
        c.suffixRead = { id in
            let value = recorder.previewSuffix(operationID: id)
            if let value { totals.append(value.totalCount); starts.append(c.now) }
            return value
        }
        c.tick = { recorder.append(chunk) }
        c.enqueuePreview(); await c.chain?.value
        XCTAssertEqual(c.native.calls.count, 600); XCTAssertEqual(totals.last, 9_600_000)
        XCTAssertTrue(c.native.sampleCounts.allSatisfy { $0 <= 240_000 })
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 1 })
        XCTAssertTrue(zip(totals, totals.dropFirst()).allSatisfy { $1 - $0 >= 16_000 })
        XCTAssertTrue(c.updates.contains(.status(.limitReached)))
        for case .draft(let text, _) in c.updates { XCTAssertLessThanOrEqual(text.utf8.count, 4096) }
        let record = try XCTUnwrap(c.diagnostics.snapshot().records.last)
        XCTAssertEqual(record.preview?.requests, 600); XCTAssertEqual(record.preview?.maximumSamples, 240_000)
        XCTAssertEqual(record.asr, .unknown)
        _ = recorder.stop(); c.stop()
    }

    private final class PreviewPreparationMemory: PreparationStorage {
        var data: Data?
        func read() throws -> Data? { data }
        func replace(_ data: Data, authorized: () -> Bool) throws {
            guard authorized() else { throw PreparationRefusal.revoked }; self.data = data
        }
        func quarantine() throws { data = nil }
        func reset(_ data: Data) throws { self.data = data }
    }
    private struct NoDownload: CatalogDownloadTransport {
        func fetch(_ request: URLRequest, to file: URL, maximum: Int64, chunkMaximum: Int64) async throws -> HTTPURLResponse {
            XCTFail("No download belongs to preview or termination")
            throw RecordingStore.Failure("unexpected fixture download")
        }
    }
    @MainActor func testCompleteConcreteQuitCompositionWaitsHeldPreviewWithSafeStartOffAndOnAndClipboardVeto() async throws {
        for enabled in [false, true] {
            for veto in [false, true] {
                let c = try Capture(); c.stopAfterDraft = false
                try c.configurePreparation(enabled)
                let nativeOwner = try XCTUnwrap(c.preparation)
                let apple = AppleOwnerRig().owner
                let parakeet = ParakeetPreparation(storage: ParakeetInstallationStorage(root: c.root.appendingPathComponent("parakeet"), transport: NoDownload()))
                let local = LocalCleanupAdmission()
                let download = CatalogDownloadOwner(root: c.root.appendingPathComponent("downloads"), catalog: [], transport: NoDownload(), cache: VerifiedCache(url: c.root.appendingPathComponent("cache.json")))
                let clipboard = ExperimentRig(), updater = UpdateTerminationIntent()
                XCTAssertTrue(clipboard.paste())
                let entered = expectation(description: "held preview"), gate = DispatchSemaphore(value: 0)
                c.native.decode = { entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success) }
                try c.start(); c.enqueuePreview()
                await fulfillment(of: [entered], timeout: 5)
                let replied = expectation(description: "once-only quit reply")
                let drained = expectation(description: "all concrete native participants exited"); drained.expectedFulfillmentCount = 3
                var replies: [Bool] = []
                let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown,
                    updater: { updater.request(waitingForInstall: false, committing: false, cancelInstall: {}, reply: $0) },
                    download: download.beginShutdown, cancelDownload: download.cancelShutdown,
                    preparation: { reply in nativeOwner.beginShutdown(chain: { c.chain }) { reply($0); drained.fulfill() } },
                    cancelPreparation: nativeOwner.cancelShutdown,
                    appleSpeech: { reply in apple.beginShutdown(chain: { c.chain }) { reply($0); drained.fulfill() } },
                    cancelAppleSpeech: apple.cancelShutdown,
                    parakeet: { reply in parakeet.beginShutdown(chain: { c.chain }) { reply($0); drained.fulfill() } },
                    cancelParakeet: parakeet.cancelShutdown,
                    localCleanup: { local.beginShutdown(chain: { c.chain }, reply: $0) }, cancelLocalCleanup: local.cancelShutdown,
                    cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: updater.cancel,
                    reply: { replies.append($0); replied.fulfill() }, failure: {})
                // This is the same early invalidation called by applicationShouldTerminate.
                c.body.revoke()
                XCTAssertEqual(coordinator.request(), .terminateLater)
                XCTAssertFalse(c.body.plan.phase.isCurrent)
                XCTAssertEqual(c.native.releases, 0)
                XCTAssertTrue(parakeet.admissionClosed)
                if veto { clipboard.board.writeResults = [false] }
                clipboard.fire(clipboard.timers[0])
                if veto { await fulfillment(of: [replied], timeout: 2) }
                else { XCTAssertTrue(replies.isEmpty) }
                XCTAssertEqual(c.native.releases, 0)
                c.native.decode = nil; gate.signal(); await c.chain?.value
                await fulfillment(of: [drained], timeout: 3)
                if !veto { await fulfillment(of: [replied], timeout: 3) }
                XCTAssertEqual(replies, [!veto])
                XCTAssertEqual(c.native.releases, 1); XCTAssertTrue(c.recording)
                XCTAssertFalse(c.updates.contains { if case .draft = $0 { return true }; return false })
                await c.body.run() // canceled quit never resumes this preview phase
                XCTAssertEqual(c.native.paths.count, 1)
                if veto { XCTAssertTrue(clipboard.delivery.isRestorePending); XCTAssertTrue(clipboard.delivery.restoreFailed) }
            }
        }
    }
    @MainActor func testSafeStartStandardColdPreviewAndStalePermissionRefusesFreshFinal() async throws {
        let c = try Capture()
        try c.configurePreparation(true); try c.start()
        c.enqueuePreview(); await c.chain?.value
        XCTAssertEqual(c.native.paths.count, 1); XCTAssertEqual(c.native.calls.count, 1)
        XCTAssertEqual(c.native.sampleCounts, [240_000]) // no synthetic warmup
        c.preparation?.revokeDraft()
        c.enqueueFinal(); await c.chain?.value
        XCTAssertEqual(c.native.paths.count, 1)
        XCTAssertTrue(c.delivered.isEmpty); XCTAssertTrue(c.raw.isEmpty)
        XCTAssertEqual(c.entries, [.stash])
    }
    @MainActor func testStartProfileFreezesAutoDictionaryAndFinalDespiteLaterSavedSettings() async throws {
        let c = try Capture(final: "large-v3-turbo-q5_0")
        var saved = c.store.load(), profile = DictationProfile()
        profile.name = "Start"; profile.target = "start.app"; profile.language = "auto"
        profile.whisperModelPath = ModelCatalog.path(for: ModelCatalog.all[1]); profile.dictionary = ["Profile"]
        saved.profiles = [profile]; saved.language = "hi"; try c.store.save(saved)
        try c.start(destination: .init(bundleID: "start.app"))
        c.enqueuePreview(); await c.chain?.value
        saved.language = "es"; saved.dictionary = ["Later"]
        saved.whisperModelPath = "/custom/new.bin"; try c.store.save(saved)
        c.enqueueFinal(); await c.chain?.value
        XCTAssertEqual(c.native.paths, [ModelCatalog.path(for: ModelCatalog.all[0]), ModelCatalog.path(for: ModelCatalog.all[1])])
        XCTAssertEqual(c.native.calls.map(\.prompt), ["Profile, FrozenDictionary", "Profile, FrozenDictionary"])
        XCTAssertEqual(c.native.calls.map(\.language), ["en", "en"])
        XCTAssertNil(c.session.recognition.language)
        XCTAssertNotEqual(c.session.recognition, RecognitionRequest(settings: c.session.settings))
        XCTAssertNotEqual(c.session.recognition, RecognitionRequest(settings: saved))
    }
    @MainActor func testSlowPassRereadsLatestAndRequiresNewSamplesWithoutCatchup() async throws {
        let c = try Capture(); c.stopAfterDraft = false
        let recorder = AudioRecorder(engine: Engine())
        try c.start(); try recorder.start(diagnosticOperation: c.session.operation.id)
        recorder.append([Float](repeating: 0.2, count: 16_000))
        c.suffixRead = { recorder.previewSuffix(operationID: $0) }
        c.native.decode = {
            if c.native.calls.count == 1 {
                recorder.append([Float](repeating: 0.3, count: 8000)); c.now += 5
            }
        }
        var pauses = 0, drafts = 0
        c.tick = {
            c.now -= 0.9; pauses += 1
            recorder.append([Float](repeating: 0.4, count: 4000))
        }
        c.onUpdate = { update in
            if case .draft = update { drafts += 1; if drafts == 2 { c.stop() } }
        }
        c.enqueuePreview(); await c.chain?.value
        XCTAssertEqual(c.native.sampleCounts, [16_000, 32_000])
        XCTAssertEqual(pauses, 2); XCTAssertEqual(c.native.calls.last?.samples.last, 0.4)
        _ = recorder.stop()
    }
    @MainActor func testOffPathRetainsSameOwnerLongWindowFinalShortcutThroughOrdinaryFinalization() async throws {
        for gate in [false, true] {
            let c = try Capture()
            var settings = c.store.load(); settings.streamPreviewEnabled = gate; settings.recognitionPreviewModelID = nil
            try c.store.save(settings)
            let s = DictationSession.Session(gen: 1, mode: .dictation, settings: c.store.load(), cleanupConfigured: false, diagnostics: c.diagnostics)
            XCTAssertNil(s.previewPlan)
            let handle = try await RecognitionAcquisition.acquire(request: s.recognition, resident: nil, factory: c.factory,
                operation: s.operation, capture: s.operation.id)
            let full = Capture.audio(320_000)
            c.native.outputs = [.init(status: 0, segments: ["confirmed"]), .init(status: 0, segments: ["tail"])]
            let head = try recognitionUnwrap(await DictationProcessing.stream(operation: s.operation, handle: handle,
                samples: Array(full.prefix(160_000)), pass: .streamHead(""), sampleRange: 0..<160_000, capturing: { true }))
            let window = handle.window(confirmedText: head, cutSample: 160_000)
            let finalizer = OrdinaryDictationFinalization(recordings: c.recordings, settings: c.store)
            var final: String?
            await finalizer.run(operation: s.operation, samples: full, window: window,
                prepare: { _, _ in handle }, recognized: { _, raw in final = raw; return raw },
                clean: { ($0, nil) }, completed: { _, _, _ in })
            XCTAssertEqual(final, "confirmed tail")
            XCTAssertEqual(c.native.paths.count, 1); XCTAssertEqual(c.native.sampleCounts, [160_000, 160_000])
            XCTAssertNil(c.diagnostics.snapshot().records.last?.preview)
        }
    }
    @MainActor func testConcreteRestartDrainWaitsHeldPreviewAndRejectedRestartDoesNotReviveIt() async throws {
        for enabled in [false, true] {
            let c = try Capture(); c.stopAfterDraft = false; try c.configurePreparation(enabled)
            let nativeOwner = try XCTUnwrap(c.preparation), apple = AppleOwnerRig().owner
            let parakeet = ParakeetPreparation(storage: ParakeetInstallationStorage(root: c.root.appendingPathComponent("parakeet"), transport: NoDownload()))
            let local = LocalCleanupAdmission()
            let entered = expectation(description: "held preview"), gate = DispatchSemaphore(value: 0)
            c.native.decode = { entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success) }
            try c.start(); c.enqueuePreview(); await fulfillment(of: [entered], timeout: 5)
            c.body.revoke() // same pre-reservation invalidation as claimRestartIfSafe
            XCTAssertTrue(parakeet.reserveRestart()); XCTAssertTrue(apple.reserveRestart()); XCTAssertTrue(local.reserveRestart())
            var settled = false, rejected = 0
            let restart = Task { @MainActor in
                let drained = await parakeet.drainRestart(chain: { c.chain })
                XCTAssertTrue(drained)
                await apple.retireForRestart()
                let claimed = await nativeOwner.claimRestart(chain: { c.chain }, allowed: { c.machine.state == .idle },
                    claimOther: { XCTFail("Recording capture cannot claim restart"); return false }, rejected: {
                        parakeet.releaseRestart(); apple.releaseRestart(); local.releaseRestart(); rejected += 1
                    })
                settled = true; return claimed
            }
            XCTAssertFalse(settled); XCTAssertEqual(c.native.releases, 0)
            c.native.decode = nil; gate.signal()
            let claimed = await restart.value
            XCTAssertFalse(claimed); XCTAssertEqual(rejected, 1); XCTAssertEqual(c.native.releases, 1)
            XCTAssertFalse(c.body.plan.phase.isCurrent); XCTAssertTrue(c.recording)
            await c.body.run(); XCTAssertEqual(c.native.paths.count, 1)
        }
    }
}
