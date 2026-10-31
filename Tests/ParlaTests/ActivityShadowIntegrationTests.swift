import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

final class ActivityShadowIntegrationTests: XCTestCase {
    @MainActor private final class Capture {
        let root: URL, store: SettingsStore, history: HistoryStore, recordings: RecordingStore, hub: HubModel
        let diagnostics = DiagnosticStore(), native = FoundationNativeProbe()
        let machine: DictationSession
        let sink: HistoryPersistenceSink
        var session: DictationSession.Session!
        var chain: Task<Void, Never>?
        var entries: [OrdinaryDictationFinalization.Entry] = []
        var raw: [String?] = [], delivered: [String] = []
        var pending: (DictationSession.Session, DictationSession.Landed)?
        var analyses = 0, generalSaves = 0, providerCalls = 0
        var landingSecure = false, completionSecure = false, omitAdjudication = false
        var missing = false, incomplete = false, clearDuring = false, evictDuring = false
        var windowCut: Int?, foreignWindow = false, separatePreview = false
        var injected: ActivityShadow.Analyzer?
        var afterStash: (() -> Void)?
        var preparation: NativePreparation?
        lazy var dispatcher = DictationExecutionDispatcher(makePreview: { fatalError("ordinary never creates B57") },
            ordinary: { s, pcm, _ in await self.finalize(s, pcm) })
        init(enabled: Bool = true, recovery: Bool = false, historyEnabled: Bool = true,
             mode: DictationOutputMode = .raw, snippet: Bool = false, failSave: Bool = false) throws {
            root = URL(fileURLWithPath: "/tmp/parla-implementation-2026-10-28/wave4i1-fixture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try recordWave4BFixture(root, "created")
            let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "path": root.path, "inode": attrs[.systemFileNumber] as! NSNumber,
                "uid": attrs[.ownerAccountID] as! NSNumber,
                "birth": (attrs[.creationDate] as! Date).timeIntervalSince1970]).write(to: root.appendingPathComponent("owner.json"))
            store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore(),
                atomicWrite: { data, url in if failSave { throw RecordingStore.Failure("fixture save failure") }; try data.write(to: url, options: .atomic) })
            history = HistoryStore(url: root.appendingPathComponent("history.json"))
            recordings = RecordingStore(directory: root.appendingPathComponent("audio"), keepAll: false, requireValidatedPolicy: true)
            hub = HubModel(store: store, history: history, recordings: recordings, diagnostics: diagnostics)
            machine = DictationSession(diagnostics: diagnostics); sink = HistoryPersistenceSink(history: history, settings: store)
            if !failSave {
                var settings = Settings(); settings.whisperModelPath = ModelCatalog.directory.appendingPathComponent("ggml-base.en.bin").path
                settings.cleanupEnabled = false; settings.outputMode = mode; settings.warmMic = false
                settings.historyEnabled = historyEnabled; settings.recoveryAudioEnabled = recovery
                settings.language = "en"; settings.dictionary = ["PRIVATE_DICTIONARY"]
                if snippet { settings.snippets = ["native original": "snippet result"] }
                try store.save(settings)
            }
            hub.refreshPreparationConfiguration()
            hub.onSaved = { self.generalSaves += 1 }
            hub.onActivityShadowRevoked = { self.machine.revokeActivityShadow() }
            hub.settings.energyActivityShadowEnabled = enabled; hub.flushPendingSave()
        }
        nonisolated static func audio(_ n: Int = 32000) -> [Float] { (0..<n).map { $0.isMultiple(of: 2) ? 0.1 : -0.1 } }
        func start(live: Bool = false, delivery: DictationSession.Delivery = .keyboard, destination: ProfileDestination = .init()) {
            if delivery == .resultOnly { send(.startAutomation(settings: store.load(), cleanupConfigured: false)) }
            else { send(.startDictation(settings: store.load(), cleanupConfigured: false, live: live, recognitionDestination: destination)) }
            send(.recorderStarted(gen: machine.gen)); send(.focusSampled(gen: machine.gen, focus: .editable))
        }
        func send(_ event: DictationSession.Event) {
            sink.beginEvent(for: event, currentGeneration: machine.gen)
            machine.send(event) { effect in
                if case .captureAccepted(let s) = effect { session = s }
                if case .polish(let s, let landed) = effect { pending = (s, landed) }
                if case .insertText(let text, _, _) = effect { delivered.append(text) }
                _ = sink.record(effect, metrics: { nil })
            }
        }
        func enqueue(_ pcm: [Float] = Capture.audio()) {
            let s = session!
            send(.stopRequested)
            chain = dispatcher.enqueue(.ordinary(s, samples: pcm, ledger: ""), previous: chain)
        }
        var fact: DiagnosticActivityShadow? { diagnostics.snapshot().records.first(where: { $0.id == session.operation.id })?.activityShadow }
        func finalize(_ s: DictationSession.Session, _ pcm: [Float]) async {
            let f = OrdinaryDictationFinalization(recordings: recordings, settings: store, entered: { self.entries.append($0) })
            var streamed: RecognitionHandle?, window: StreamWindow?
            if let cut = windowCut {
                do {
                    let handle = try await RecognitionAcquisition.acquire(request: s.recognition, resident: nil,
                        factory: factory(), operation: s.operation, capture: s.operation.id)
                    let head = await DictationProcessing.stream(operation: s.operation, handle: handle,
                        samples: Array(pcm.prefix(cut)), pass: .streamHead(""), sampleRange: 0..<cut, capturing: { true })
                    window = handle.window(confirmedText: head ?? "", cutSample: cut)
                    if !foreignWindow { streamed = handle }
                } catch { XCTFail("fixture stream acquisition failed") }
            }
            await f.run(operation: s.operation, samples: pcm, window: window, shadow: s.activityShadowPermission,
                separatePreview: separatePreview,
                shadowCurrent: { s.gen == self.machine.gen && self.machine.activityShadowPermission == s.activityShadowPermission },
                analyze: { samples, abort in
                    self.analyses += 1
                    return self.injected?(samples, abort) ?? ActivityShadow.analyze(samples, shouldAbort: abort)
                }, prepare: { _, _ in
                    self.afterStash?()
                    if self.missing { f.resolve(transcript: nil, secure: self.landingSecure); return nil }
                    if let streamed { return streamed }
                    do {
                        var factory = self.factory()
                        if let preparation = self.preparation {
                            factory.preparation = preparation.core
                            factory.preparationPermission = { preparation.core.matchesSavedPermission(self.store.load()) }
                            let native = factory.native
                            factory.guardedNative = { path, compute, permit in try permit.nativeEntry { try native(path, compute) } }
                        }
                        let h = try await RecognitionAcquisition.acquire(request: s.recognition, resident: nil, factory: factory,
                            operation: s.operation, capture: s.operation.id, selectionEpoch: self.hub.modelSelectionEpoch,
                            preparationEpoch: self.preparation?.core.admissionEpoch)
                        if self.incomplete { s.operation.diagnostics?.update { $0.capture = .conversionFailure } }
                        return h
                    } catch { f.resolve(transcript: nil, secure: self.landingSecure); return nil }
                }, recognized: { _, raw in
                    self.raw.append(raw)
                    if !self.omitAdjudication { f.resolve(transcript: raw, secure: self.landingSecure || s.focus == .secure) }
                    if self.clearDuring { self.hub.clearDiagnostics() }
                    if self.evictDuring { for _ in 0..<65 { _ = self.diagnostics.start(id: UUID(), origin: .unknown) } }
                    self.pending = nil
                    self.send(.transcribed(s, raw: raw, probe: .init(focus: self.landingSecure ? .secure : .editable, deferInsertionUntilClean: true)))
                    return self.pending
                }, clean: { context in
                    await Pipeline(outputSettings: context.0.effectiveSettings, bundleID: nil, makeClient: { _ in
                        self.providerCalls += 1; throw RecordingStore.Failure("unexpected provider")
                    }).clean(transcript: context.1.raw)
                }, completed: { context, text, failure in
                    if !self.omitAdjudication { f.observeSecurity(secure: self.completionSecure) }
                    self.send(.cleanReady(context.0, context.1, text: text, failure: failure, focus: self.completionSecure ? .secure : .editable))
                })
        }
        func deterministic() { injected = { ActivityShadow.analyze($0, shouldAbort: $1, clock: { 0 }) } }
        func factory() -> RecognitionFactory {
            var f = native.factory(); f.directory = ModelCatalog.directory; return f
        }
        func configurePreparation(_ enabled: Bool) throws {
            let memory = ShadowPreparationMemory(), build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
            let core = RecognitionPreparation(storage: { memory }, build: { build })
            let owner = NativePreparation(core: core)
            var settings = store.load()
            if enabled {
                let consent = UUID(); try core.prepareConsent(consent)
                settings.nativePreparationSafeStartEnabled = true; settings.nativePreparationConsent = consent
            }
            try store.save(settings); owner.configure(settings, epoch: hub.modelSelectionEpoch)
            preparation = owner
            native.generation = .init(bytes: ModelCatalog.all[0].bytes, modified: 1)
        }
    }
    @MainActor func testRealSavedHubDispatcherDefaultFactoryAndLocalAnalyzerPreservePCMRequestRawOutputStorage() async throws {
        for enabled in [false, true] {
            let c = try Capture(enabled: enabled, recovery: true)
            c.start(); let pcm = Capture.audio(); c.enqueue(pcm); await c.chain?.value
            XCTAssertEqual(c.generalSaves, 0); XCTAssertEqual(c.analyses, enabled ? 1 : 0)
            XCTAssertEqual(c.native.calls.count, 1); XCTAssertEqual(c.native.calls[0].samples.map(\.bitPattern), pcm.map(\.bitPattern))
            XCTAssertEqual(c.native.calls[0].prompt, "PRIVATE_DICTIONARY"); XCTAssertEqual(c.native.calls[0].language, "en")
            XCTAssertEqual(c.entries, [.stash, .resolve]); XCTAssertEqual(c.raw.compactMap { $0 }, ["native original"])
            XCTAssertEqual(c.delivered, ["native original"]); XCTAssertEqual(c.providerCalls, 0)
            XCTAssertEqual(c.history.entries.count, 1)
            if enabled {
                XCTAssertEqual(c.fact?.actual.selection, .fullPass); XCTAssertEqual(c.fact?.actual.native, .completed)
                XCTAssertEqual(c.fact?.actual.text, .present); XCTAssertFalse(try XCTUnwrap(c.fact).suggestionApplied)
            } else { XCTAssertNil(c.fact) }
        }
    }
    @MainActor func testSnippetCleanupOffHistoryOffRecoveryOffArePositiveControls() async throws {
        for snippet in [false, true] {
            let c = try Capture(recovery: false, historyEnabled: false, mode: snippet ? .cleanup : .raw, snippet: snippet)
            c.deterministic(); c.start(); c.enqueue(); await c.chain?.value
            XCTAssertEqual(c.delivered, [snippet ? "snippet result" : "native original"])
            XCTAssertEqual(c.raw.compactMap { $0 }, ["native original"]); XCTAssertTrue(c.history.entries.isEmpty)
            XCTAssertEqual(c.entries, [.stash, .resolve]); XCTAssertEqual(c.providerCalls, 0); XCTAssertEqual(c.analyses, 1)
            XCTAssertEqual(c.fact?.actual.selection, .fullPass)
        }
    }
    @MainActor func testBeforeFloorMinimumSilenceEmptyAndAcquisitionUnavailableAreDistinct() async throws {
        for n in [0, 3200, 6400, 8000] {
            let c = try Capture(); c.deterministic(); c.start(); c.enqueue([Float](repeating: 0, count: n)); await c.chain?.value
            XCTAssertEqual(c.analyses, 1); XCTAssertTrue(c.native.calls.isEmpty)
            XCTAssertEqual(c.fact?.actual.selection, .fullFloorSkip)
            XCTAssertEqual(c.fact?.actual.skip, n < 6400 ? .minimumDuration : .silence)
            XCTAssertEqual(c.fact?.reason, n == 0 ? .empty : .digitalZero)
            XCTAssertEqual(c.fact?.actual.native, .notRun)
        }
        let c = try Capture(); c.missing = true; c.start(); c.enqueue(); await c.chain?.value
        XCTAssertEqual(c.analyses, 0); XCTAssertEqual(c.fact?.state, .notRun)
        XCTAssertEqual(c.fact?.reason, .acquisitionUnavailable); XCTAssertEqual(c.entries, [.stash, .resolve])
    }
    @MainActor func testStashObservedInvalidSettingsRevokesShadowWithoutChangingFrozenFinal() async throws {
        for repairedDuringPrepare in [false, true] {
            let c = try Capture()
            c.deterministic(); c.windowCut = 16000
            c.native.outputs = [.init(status: 0, segments: ["head"]), .init(status: 0, segments: ["tail"])]
            c.start()
            let url = c.root.appendingPathComponent("settings.json")
            let valid = try Data(contentsOf: url)
            try Data("{invalid".utf8).write(to: url, options: .atomic)
            c.afterStash = {
                XCTAssertNotNil(c.store.lastError)
                if repairedDuringPrepare {
                    do { try valid.write(to: url, options: .atomic) }
                    catch { XCTFail("Could not repair the fixture settings"); return }
                    _ = c.store.load()
                    XCTAssertNil(c.store.lastError)
                }
            }
            c.enqueue(); await c.chain?.value
            XCTAssertFalse(try XCTUnwrap(c.session.activityShadowPermission).isCurrent)
            XCTAssertEqual(c.analyses, 0)
            XCTAssertNil(c.fact)
            XCTAssertEqual(c.raw.compactMap { $0 }, ["head tail"])
            XCTAssertEqual(c.delivered, ["head tail"])
            XCTAssertEqual(c.native.calls.count, 2)
        }
    }
    @MainActor func testIncompleteCaptureAndMalformedAnalyzerDoNotChangeNativeOutput() async throws {
        for malformed in [false, true] {
            let c = try Capture(); c.incomplete = !malformed
            c.injected = { pcm, _ in
                var f = DiagnosticActivityShadow(state: .complete, reason: .activity, originalSamples: pcm.count)
                f.activity = .init(-1, Int.max); return f
            }
            c.start(); c.enqueue(); await c.chain?.value
            XCTAssertEqual(c.fact?.reason, malformed ? .invalidResult : .captureIncomplete)
            XCTAssertNil(c.fact?.activity); XCTAssertNil(c.fact?.retained)
            XCTAssertEqual(c.analyses, malformed ? 1 : 0); XCTAssertEqual(c.delivered, ["native original"])
            XCTAssertEqual(c.native.calls.count, 1)
        }
    }
    @MainActor func testOwnedWindowActualPrefixTailSkipFailureAndForeignFallback() async throws {
        for outcome in 0..<4 {
            let c = try Capture(); c.deterministic(); c.windowCut = 16000; c.foreignWindow = outcome == 3
            c.native.outputs = [.init(status: 0, segments: ["confirmed prefix"]),
                outcome == 2 ? .init(status: 7) : .init(status: 0, segments: ["selected tail"])]
            let pcm = outcome == 1 ? Capture.audio(16000) + [Float](repeating: 0, count: 3200) : Capture.audio()
            c.start(); c.enqueue(pcm); await c.chain?.value
            XCTAssertEqual(c.analyses, 1); XCTAssertEqual(c.fact?.originalSamples, pcm.count)
            if outcome == 3 {
                XCTAssertEqual(c.fact?.actual.selection, .fullPass); XCTAssertEqual(c.fact?.actual.prefixSamples, 0)
                XCTAssertEqual(c.native.calls.last?.samples.map(\.bitPattern), pcm.map(\.bitPattern))
            } else {
                XCTAssertEqual(c.fact?.actual.selection, .ownedWindowAssembly); XCTAssertEqual(c.fact?.actual.prefixSamples, 16000)
                XCTAssertEqual(c.fact?.actual.selectedRange, .init(16000, pcm.count))
                XCTAssertEqual(c.fact?.actual.native, outcome == 1 ? .notRun : outcome == 2 ? .failed : .completed)
                XCTAssertEqual(c.fact?.actual.skip, outcome == 1 ? .minimumDuration : nil)
                XCTAssertEqual(c.fact?.actual.text, .present)
                XCTAssertEqual(c.raw.compactMap { $0 }, [outcome == 0 ? "confirmed prefix selected tail" : "confirmed prefix"])
                XCTAssertEqual(c.native.calls.count, outcome == 1 ? 1 : 2)
            }
        }
    }
    @MainActor func testSavedPreviewSelectorWithoutActualPreviewReportsOrdinaryRoute() async throws {
        let c = try Capture(); c.hub.settings.recognitionPreviewModelID = "not-installed"; c.hub.settings.streamPreviewEnabled = true
        c.hub.flushPendingSave(); c.start(); c.enqueue(); await c.chain?.value
        XCTAssertEqual(c.fact?.actual.separatePreview, false); XCTAssertEqual(c.native.calls.count, 1)
    }
    @MainActor func testFrozenProfileLanguageDictionaryAndOutputUseStartSettings() async throws {
        let c = try Capture(); c.deterministic()
        var settings = c.store.load(), profile = DictationProfile()
        profile.name = "PRIVATE_PROFILE"; profile.target = "start.app"; profile.language = "hi"; profile.dictionary = ["ProfileWord"]
        settings.profiles = [profile]; try c.store.save(settings)
        c.start(destination: .init(bundleID: "start.app"))
        settings.language = "es"; settings.dictionary = ["LaterWord"]; settings.outputMode = .selectedPreset
        try c.store.save(settings) // frozen Session is deliberately unchanged; no Hub draft event.
        c.enqueue(); await c.chain?.value
        XCTAssertEqual(c.native.calls.first?.language, "hi"); XCTAssertEqual(c.native.calls.first?.prompt, "ProfileWord, PRIVATE_DICTIONARY")
        XCTAssertEqual(c.delivered, ["native original"]); XCTAssertEqual(c.analyses, 1)
        XCTAssertEqual(c.fact?.actual.selection, .fullPass)
    }
    @MainActor func testNativeFullFailureAndCompletedEmptyAreActualDistinctFacts() async throws {
        for outcome in 0..<3 {
            let c = try Capture(); c.deterministic(); c.native.outputs = [.init(status: outcome == 0 ? 0 : 3, abortObserved: outcome == 2)]
            c.start(); c.enqueue(); await c.chain?.value
            XCTAssertEqual(c.fact?.actual.selection, .fullPass)
            XCTAssertEqual(c.fact?.actual.native, outcome == 1 ? .failed : outcome == 2 ? .canceled : .completed)
            XCTAssertEqual(c.fact?.actual.text, .absent); XCTAssertEqual(c.analyses, 1); XCTAssertEqual(c.native.calls.count, 1)
        }
    }
    @MainActor func testRecorderFailureAndKnownStartSecureHaveNoFinalOrShadowEntry() throws {
        for secure in [false, true] {
            let c = try Capture()
            c.send(.startDictation(settings: c.store.load(), cleanupConfigured: false, live: false))
            let s = c.session!
            if secure {
                c.send(.recorderStarted(gen: c.machine.gen)); c.send(.focusSampled(gen: c.machine.gen, focus: .secure))
            } else { c.send(.recorderFailed(gen: c.machine.gen, message: "fixture capture failed")) }
            XCTAssertEqual(c.machine.state, .idle); XCTAssertEqual(c.analyses, 0); XCTAssertTrue(c.entries.isEmpty)
            XCTAssertTrue(c.native.calls.isEmpty); XCTAssertNil(c.fact)
            if secure { XCTAssertFalse(try XCTUnwrap(s.activityShadowPermission).isCurrent) }
        }
    }
    @MainActor func testCommandTryoutWarmupAndStreamAdaptersSucceedWithoutShadowPorts() async throws {
        let c = try Capture(); let request = RecognitionRequest(settings: c.store.load())
        let operation = PendingOperation(name: "excluded adapters", diagnostics: c.diagnostics)
        let handle = try await c.factory().acquire(request: request)
        let command = await DictationProcessing.command(operation: operation, handle: handle, samples: Capture.audio())
        XCTAssertEqual(command, "native original")
        let tryout = await RecognitionAcquisition.tryout(samples: Capture.audio(), request: request, resident: nil, factory: c.factory())
        XCTAssertEqual(tryout, "native original")
        let warmup = await handle.recognize(Capture.audio(), pass: .warmup)
        XCTAssertEqual(warmup.text, "native original")
        for pass in [RecognitionHandle.Pass.streamHead(""), .streamTail("")] {
            let result = await DictationProcessing.stream(operation: operation, handle: handle, samples: Capture.audio(), pass: pass, capturing: { true })
            XCTAssertEqual(result, "native original")
        }
        XCTAssertEqual(c.analyses, 0); XCTAssertTrue(c.diagnostics.snapshot().records.allSatisfy { $0.activityShadow == nil })
    }
    @MainActor func testStartOffMidCaptureEnableAndFailedSaveCannotGrantPermission() async throws {
        let c = try Capture(enabled: false); c.start()
        c.hub.settings.energyActivityShadowEnabled = true; c.hub.flushPendingSave()
        c.enqueue(); await c.chain?.value
        XCTAssertEqual(c.analyses, 0); XCTAssertNil(c.fact); XCTAssertEqual(c.delivered, ["native original"])
        c.start(); c.enqueue(); await c.chain?.value
        XCTAssertEqual(c.analyses, 1)
        let failed = try Capture(failSave: true); XCTAssertNotNil(failed.hub.saveError)
        failed.start(); XCTAssertNil(failed.session.activityShadowPermission)
    }
    @MainActor func testDraftDisableReenableAndCorruptSettingsIrrevocablyRevoke() async throws {
        for corrupt in [false, true] {
            let c = try Capture(); c.start(); let permission = try XCTUnwrap(c.session.activityShadowPermission)
            if corrupt {
                try Data("{".utf8).write(to: c.store.url); c.hub.refreshPreparationConfiguration()
            } else {
                c.hub.settings.energyActivityShadowEnabled = false
                c.hub.settings.energyActivityShadowEnabled = true; c.hub.flushPendingSave()
            }
            XCTAssertFalse(permission.isCurrent); c.enqueue(); await c.chain?.value
            XCTAssertEqual(c.analyses, 0); XCTAssertNil(c.fact)
        }
    }
    @MainActor func testShadowOnlyProjectionSaveAndCoalescedRevertHaveNoPreparationOrGeneralSetup() throws {
        let c = try Capture(enabled: false)
        var prepared = 0, parakeetDrafts = 0, beforeSaves = 0
        c.hub.onPreparationSaved = { _ in prepared += 1 }
        c.hub.onParakeetDraftChanged = { parakeetDrafts += 1 }
        c.hub.onPreparationBeforeSave = { _ in beforeSaves += 1 }
        c.hub.settings.energyActivityShadowEnabled = true; c.hub.flushPendingSave()
        XCTAssertTrue(c.store.load().energyActivityShadowEnabled)
        XCTAssertEqual(prepared, 0); XCTAssertEqual(parakeetDrafts, 0); XCTAssertEqual(c.generalSaves, 0)
        c.hub.settings.energyActivityShadowEnabled = false; c.hub.settings.energyActivityShadowEnabled = true
        c.hub.flushPendingSave()
        XCTAssertEqual(prepared, 0); XCTAssertEqual(parakeetDrafts, 0); XCTAssertEqual(c.generalSaves, 0)
        XCTAssertEqual(beforeSaves, 2); XCTAssertTrue(c.native.paths.isEmpty)
        c.hub.settings.language = "es"; c.hub.flushPendingSave()
        XCTAssertEqual(prepared, 1); XCTAssertEqual(c.generalSaves, 1)
    }
    @MainActor func testNilRawSecureLandingLateCompletionAndMissingAdjudicationWithhold() async throws {
        for condition in 0..<4 {
            let c = try Capture(); c.deterministic()
            c.landingSecure = condition == 0 || condition == 1; c.completionSecure = condition == 2
            c.omitAdjudication = condition == 3
            c.start(); c.enqueue(condition == 0 ? [Float](repeating: 0, count: 8000) : Capture.audio()); await c.chain?.value
            XCTAssertEqual(c.analyses, 1); XCTAssertNil(c.fact)
            if condition < 3 { XCTAssertFalse(try XCTUnwrap(c.session.activityShadowPermission).isCurrent) }
        }
    }
    @MainActor func testSecureEvidenceArrivingDuringHeldNativeErasesPendingAnalysis() async throws {
        let c = try Capture(); c.deterministic()
        let entered = expectation(description: "native after analysis"), gate = DispatchSemaphore(value: 0)
        c.native.decode = { entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success) }
        c.start(); c.enqueue(); await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(c.analyses, 1); XCTAssertNil(c.fact)
        c.landingSecure = true; c.native.decode = nil; gate.signal(); await c.chain?.value
        XCTAssertNil(c.fact); XCTAssertFalse(try XCTUnwrap(c.session.activityShadowPermission).isCurrent)
    }
    @MainActor func testClearAndEvictionDuringFinalNeverReinsertFactsAndFrozenReviewDoesNotChange() async throws {
        for eviction in [false, true] {
            let c = try Capture(); c.deterministic(); c.start(); c.hub.prepareDiagnostics()
            let frozen = try XCTUnwrap(c.hub.diagnosticReview)
            c.clearDuring = !eviction; c.evictDuring = eviction; c.enqueue(); await c.chain?.value
            XCTAssertNil(c.fact)
            if eviction { XCTAssertEqual(c.hub.diagnosticReview, frozen) }
        }
    }
    @MainActor func testActualFactsReachFrozenHubReviewExplicitExportAndCanariesStayAbsent() async throws {
        let c = try Capture(); c.deterministic(); c.start(); c.enqueue(); await c.chain?.value
        c.hub.prepareDiagnostics(); let frozen = try XCTUnwrap(c.hub.diagnosticReview)
        let field = try JSONEncoder().encode(try XCTUnwrap(c.fact))
        XCTAssertLessThanOrEqual(field.count, 2048)
        let text = String(decoding: field, as: UTF8.self)
        for canary in ["native original", "PRIVATE_DICTIONARY", "/owned", c.session.operation.id.uuidString, "prompt", "language", "instance", "identity"] { XCTAssertFalse(text.contains(canary)) }
        var writes: [Data] = []; var cancel = true, fail = false
        c.hub.diagnosticPanel = { _ in cancel ? nil : c.root.appendingPathComponent("review.json") }
        c.hub.diagnosticWriter = { data, _ in if fail { throw RecordingStore.Failure("PRIVATE_ERROR") }; writes.append(data) }
        c.hub.exportDiagnostics(); XCTAssertTrue(writes.isEmpty); XCTAssertEqual(c.hub.diagnosticReview, frozen)
        cancel = false; fail = true; c.hub.exportDiagnostics(); XCTAssertEqual(c.hub.diagnosticReview, frozen)
        fail = false; c.hub.exportDiagnostics(); XCTAssertEqual(writes, [frozen]); XCTAssertNil(c.hub.diagnosticReview)
    }
    @MainActor func testHeldAnalyzerCancelOrSuccessorStaysInsideActualExitBarrier() async throws {
        for cancel in [false, true] {
            let c = try Capture(); let entered = expectation(description: "held shadow"), gate = DispatchSemaphore(value: 0)
            c.injected = { pcm, _ in entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
                return DiagnosticActivityShadow(reason: .lowContrast, originalSamples: pcm.count) }
            c.start(); let s = c.session!; c.enqueue()
            await fulfillment(of: [entered], timeout: 5)
            if cancel { c.send(.discardOwnedOperation(s.operation, generation: s.gen)); s.operation.requestAbort() }
            else { c.start() }
            var successor = false
            let tail = PendingOperationQueue.enqueue(previous: c.chain, operation: PendingOperation(name: "successor"), completes: true) {
                _ = try? await c.native.factory().acquire(request: s.recognition); successor = true
            }
            XCTAssertFalse(s.operation.hasExited); XCTAssertEqual(c.native.paths.count, 1)
            XCTAssertTrue(c.native.calls.isEmpty); XCTAssertFalse(successor)
            gate.signal(); await tail.value
            XCTAssertTrue(s.operation.hasExited); XCTAssertTrue(successor)
            XCTAssertNil(c.diagnostics.snapshot().records.first(where: { $0.id == s.operation.id })?.activityShadow)
            XCTAssertEqual(c.native.calls.count, cancel ? 0 : 1)
        }
    }
    @MainActor func testPositiveResultOnlyAndLiveOriginsHaveZeroShadowEntry() async throws {
        for delivery in [DictationSession.Delivery.keyboard, .resultOnly] {
            let c = try Capture(); c.start(live: delivery == .keyboard, delivery: delivery)
            c.enqueue(); await c.chain?.value
            XCTAssertEqual(c.analyses, 0); XCTAssertNil(c.fact); XCTAssertEqual(c.native.calls.count, 1)
        }
    }
    private final class ShadowPreparationMemory: PreparationStorage {
        var data: Data?
        func read() throws -> Data? { data }
        func replace(_ data: Data, authorized: () -> Bool) throws { guard authorized() else { throw PreparationRefusal.revoked }; self.data = data }
        func quarantine() throws { data = nil }
        func reset(_ data: Data) throws { self.data = data }
    }
    private struct NoDownload: CatalogDownloadTransport {
        func fetch(_ request: URLRequest, to file: URL, maximum: Int64, chunkMaximum: Int64) async throws -> HTTPURLResponse { XCTFail("shadow must not download"); throw RecordingStore.Failure("unexpected download") }
    }
    @MainActor func testCompleteQuitCompositionWaitsHeldAnalysisSafeStartOffOnAndClipboardVeto() async throws {
        for enabled in [false, true] { for veto in [false, true] {
            let c = try Capture(); try c.configurePreparation(enabled)
            let owner = try XCTUnwrap(c.preparation), apple = AppleOwnerRig().owner
            let parakeet = ParakeetPreparation(storage: ParakeetInstallationStorage(root: c.root.appendingPathComponent("parakeet"), transport: NoDownload()))
            let local = LocalCleanupAdmission()
            let download = CatalogDownloadOwner(root: c.root.appendingPathComponent("downloads"), catalog: [], transport: NoDownload(), cache: VerifiedCache(url: c.root.appendingPathComponent("cache.json")))
            let clipboard = ExperimentRig(), updater = UpdateTerminationIntent(); XCTAssertTrue(clipboard.paste())
            let entered = expectation(description: "held analysis"), gate = DispatchSemaphore(value: 0)
            c.injected = { pcm, _ in entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success); return .init(reason: .lowContrast, originalSamples: pcm.count) }
            c.start(); c.enqueue(); await fulfillment(of: [entered], timeout: 5)
            let replied = expectation(description: "quit reply"), drained = expectation(description: "native drains"); drained.expectedFulfillmentCount = 3
            var replies: [Bool] = []
            let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown,
                updater: { updater.request(waitingForInstall: false, committing: false, cancelInstall: {}, reply: $0) },
                download: download.beginShutdown, cancelDownload: download.cancelShutdown,
                preparation: { reply in owner.beginShutdown(chain: { c.chain }) { reply($0); drained.fulfill() } }, cancelPreparation: owner.cancelShutdown,
                appleSpeech: { reply in apple.beginShutdown(chain: { c.chain }) { reply($0); drained.fulfill() } }, cancelAppleSpeech: apple.cancelShutdown,
                parakeet: { reply in parakeet.beginShutdown(chain: { c.chain }) { reply($0); drained.fulfill() } }, cancelParakeet: parakeet.cancelShutdown,
                localCleanup: { local.beginShutdown(chain: { c.chain }, reply: $0) }, cancelLocalCleanup: local.cancelShutdown,
                cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: updater.cancel,
                reply: { replies.append($0); replied.fulfill() }, failure: {})
            c.machine.revokeActivityShadow()
            XCTAssertEqual(coordinator.request(), .terminateLater)
            if veto { clipboard.board.writeResults = [false] }
            clipboard.fire(clipboard.timers[0])
            if veto { await fulfillment(of: [replied], timeout: 2) } else { XCTAssertTrue(replies.isEmpty) }
            XCTAssertFalse(c.session.operation.hasExited); XCTAssertTrue(c.native.calls.isEmpty)
            gate.signal(); await c.chain?.value; await fulfillment(of: [drained], timeout: 3)
            if !veto { await fulfillment(of: [replied], timeout: 3) }
            XCTAssertEqual(replies, [!veto]); XCTAssertNil(c.fact); XCTAssertFalse(try XCTUnwrap(c.session.activityShadowPermission).isCurrent)
        } }
    }
    @MainActor func testRestartCompositionWaitsHeldAnalysisAndRejectedRestartNeverRevivesPermission() async throws {
        for enabled in [false, true] {
            let c = try Capture(); try c.configurePreparation(enabled)
            let owner = try XCTUnwrap(c.preparation), apple = AppleOwnerRig().owner
            let parakeet = ParakeetPreparation(storage: ParakeetInstallationStorage(root: c.root.appendingPathComponent("parakeet"), transport: NoDownload()))
            let local = LocalCleanupAdmission(), gate = DispatchSemaphore(value: 0), entered = expectation(description: "held analysis")
            c.injected = { pcm, _ in entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 10), .success); return .init(reason: .lowContrast, originalSamples: pcm.count) }
            c.start(); c.enqueue(); await fulfillment(of: [entered], timeout: 5)
            c.machine.revokeActivityShadow()
            XCTAssertTrue(parakeet.reserveRestart()); XCTAssertTrue(apple.reserveRestart()); XCTAssertTrue(local.reserveRestart())
            var settled = false
            let restart = Task { @MainActor in
                let drained = await parakeet.drainRestart(chain: { c.chain }); XCTAssertTrue(drained)
                await apple.retireForRestart()
                let result = await owner.claimRestart(chain: { c.chain }, allowed: { false }, claimOther: { false }, rejected: {
                    parakeet.releaseRestart(); apple.releaseRestart(); local.releaseRestart()
                }); settled = true; return result
            }
            XCTAssertFalse(settled); XCTAssertTrue(c.native.calls.isEmpty)
            gate.signal(); let claimed = await restart.value; XCTAssertFalse(claimed)
            XCTAssertFalse(try XCTUnwrap(c.session.activityShadowPermission).isCurrent); XCTAssertNil(c.fact)
            c.injected = nil; c.preparation = nil; c.start(); c.enqueue(); await c.chain?.value
            XCTAssertTrue(try XCTUnwrap(c.session.activityShadowPermission).isCurrent); XCTAssertNotNil(c.fact)
        }
    }
}
