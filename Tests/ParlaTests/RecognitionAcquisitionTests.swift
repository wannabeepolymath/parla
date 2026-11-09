import XCTest
import ParlaCore
@testable import Parla

final class RecognitionAcquisitionTests: XCTestCase {
    private let audio = [Float](repeating: 0.2, count: 8000)
    private func settings(_ path: String = "/owned/ggml-base.en.bin") -> Settings {
        var settings = Settings(); settings.whisperModelPath = path; return settings
    }
    func testActualAppAcquisitionAdmitsBeforeBorrowAndKeepsProfileSessionOwned() async throws {
        let probe = FoundationNativeProbe(), factory = probe.factory(), epoch = UUID()
        let global = RecognitionRequest(settings: settings())
        let handle = try await RecognitionAcquisition.acquire(request: global, resident: nil, factory: factory)
        let borrow = try await RecognitionAcquisition.acquire(request: global, resident: handle.resident, factory: factory)
        XCTAssertTrue(borrow.client === handle.client); XCTAssertEqual(probe.admissions, 2)
        XCTAssertTrue(RecognitionAcquisition.mayPromote(handle, global: global, epoch: epoch, currentEpoch: epoch, current: global, factory: factory))
        let profile = RecognitionRequest(settings: settings("/owned/ggml-small.en-q5_1.bin"))
        let scoped = try await RecognitionAcquisition.acquire(request: profile, resident: handle.resident, factory: factory)
        XCTAssertEqual(probe.paths, [global.modelPath, profile.modelPath])
        XCTAssertFalse(RecognitionAcquisition.mayPromote(scoped, global: global, epoch: epoch, currentEpoch: epoch, current: global, factory: factory))
        probe.admission = { _, _ in throw RecordingStore.Failure("refused fixture admission") }
        await recognitionAssertThrows(try await RecognitionAcquisition.acquire(request: global, resident: handle.resident, factory: factory))
        XCTAssertEqual(probe.paths.count, 2)
    }
    func testHeldActualAppConstructorCannotPromoteAcrossEpochEvenAfterSelectionReturns() async throws {
        let probe = FoundationNativeProbe(), factory = probe.factory()
        let global = RecognitionRequest(settings: settings()), originalEpoch = UUID()
        var currentEpoch = originalEpoch
        probe.construct = { currentEpoch = UUID() } // selection changed away and back during noncancellable init
        let handle = try await RecognitionAcquisition.acquire(request: global, resident: nil, factory: factory)
        recognitionAssertEqual(await handle.finalResult(samples: audio, window: nil).text, "native original")
        XCTAssertFalse(RecognitionAcquisition.mayPromote(handle, global: global, epoch: originalEpoch, currentEpoch: currentEpoch, current: global, factory: factory))
        probe.construct = nil; probe.generation = .init(bytes: 9, modified: 2)
        XCTAssertFalse(RecognitionAcquisition.mayPromote(handle, global: global, epoch: originalEpoch, currentEpoch: originalEpoch, current: global, factory: factory))
    }
    func testLegacyDefaultCustomAndFrozenProfileRecognitionVersusLandingOutput() async throws {
        for json in ["{}", #"{"whisperModelPath":null}"#] {
            let saved = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
            XCTAssertEqual(RecognitionRequest(settings: saved).modelPath, WhisperTranscriber.defaultModelPath())
        }
        let probe = FoundationNativeProbe(), factory = probe.factory()
        var saved = settings("/custom/ggml-base.en.bin"); saved.language = "en"; saved.dictionary = ["Global"]
        var profile = DictationProfile(); profile.name = "start"; profile.target = "start.app"
        profile.language = "auto"; profile.dictionary = ["Profile"]; profile.whisperModelPath = "/owned/ggml-small.en-q5_1.bin"
        saved.profiles = [profile]
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.whisperModelPath, saved.whisperModelPath)
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: decoded, cleanupConfigured: false,
            recognitionDestination: .init(bundleID: "start.app"))
        XCTAssertNil(session.recognition.language); XCTAssertEqual(session.recognition.dictionary, ["Profile", "Global"])
        let handle = try await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: factory)
        saved.whisperModelPath = "/new.bin"; saved.language = "es"; saved.dictionary = ["New"]
        recognitionAssertEqual(await handle.commandResult(samples: audio).text, "native original")
        XCTAssertEqual(probe.calls.last?.language, "en"); XCTAssertEqual(probe.calls.last?.prompt, "Profile, Global")
        XCTAssertEqual(handle.request.modelPath, "/owned/ggml-small.en-q5_1.bin")
        XCTAssertEqual(session.settings.whisperModelPath, "/custom/ggml-base.en.bin")
        XCTAssertEqual(session.settings.dictionary, ["Global"])
    }
    func testSetupWarmupUsesNativeDefaultsFrozenLanguageAndNoManualPrompt() async throws {
        let native = FoundationNativeProbe()
        var saved = settings(); saved.language = "hi"; saved.dictionary = ["ManualHint"]
        let handle = try await RecognitionAcquisition.acquire(request: RecognitionRequest(settings: saved), resident: nil, factory: native.factory())
        let result = await handle.recognize([Float](repeating: 0, count: 16000), pass: .warmup)
        XCTAssertEqual(result.pass, .warmup)
        XCTAssertEqual(native.calls.count, 1); XCTAssertNil(native.calls[0].prompt)
        XCTAssertEqual(native.calls[0].language, "hi"); XCTAssertEqual(native.calls[0].samples.count, 16000)
    }
    func testTryoutActualEntryAcquiresBeforeFloorAndAlwaysProjectsEmpty() async {
        let probe = FoundationNativeProbe(), factory = probe.factory(), request = RecognitionRequest(settings: settings())
        recognitionAssertEqual(await RecognitionAcquisition.tryout(samples: [], request: request, resident: nil, factory: factory), "")
        XCTAssertEqual(probe.paths.count, 1); XCTAssertTrue(probe.calls.isEmpty); XCTAssertEqual(probe.releases, 1)
        for output in [WhisperNativeDecode(status: 0), .init(status: 4), .init(status: 0, segments: ["tryout"])] {
            probe.outputs = [output]
            let expected = output.status == 0 ? output.segments.joined() : ""
            recognitionAssertEqual(await RecognitionAcquisition.tryout(samples: audio, request: request, resident: nil, factory: factory), expected)
        }
        XCTAssertEqual(probe.calls.count, 3); XCTAssertEqual(probe.releases, 4)
    }
    func testActualHubCapabilitiesOnlyObserveLoadedSelectionAndDoNotConstructOrScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave4b1-hub-\(UUID())")
        try recordWave4BFixture(root, "created")
        defer { try? FileManager.default.removeItem(at: root); try? recordWave4BFixture(root, "removed") }
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        try store.save(settings())
        let hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")),
                           recordings: RecordingStore(directory: root.appendingPathComponent("audio")))
        hub.refresh()
        let probe = FoundationNativeProbe(); probe.multilingual = false
        var handle: RecognitionHandle? = try await RecognitionAcquisition.acquire(request: RecognitionRequest(settings: settings()), resident: nil, factory: probe.factory())
        hub.observedRecognition = (handle!.request.selection, handle!.client.capabilities)
        handle = nil
        XCTAssertEqual(probe.releases, 1) // UI projection retains no native owner
        let reads = probe.metadataReads
        for _ in 0..<10 {
            XCTAssertEqual(hub.recognitionCapabilities.modelLanguages, .englishOnly)
            XCTAssertTrue(hub.recognitionCapabilityDetail.contains("English only"))
        }
        hub.settings.whisperModelPath = "/custom/ggml-base.en.bin"
        XCTAssertEqual(hub.recognitionCapabilities.modelLanguages, .unknown)
        XCTAssertEqual(hub.recognitionCapabilityDetail, "")
        XCTAssertEqual(probe.paths.count, 1); XCTAssertEqual(probe.metadataReads, reads)
        hub.flushPendingSave()
    }
    private final class TransformClient: CleanupProviding {
        var instructions: [String] = []
        func clean(transcript: String, context: CleanupContext) async throws -> String {
            instructions.append(transcript); return "transformed"
        }
    }
    func testDictatedPresetAndSpokenCommandUseRealNativeFrozenRecognitionAndOutput() async throws {
        for command in [false, true] {
            let native = FoundationNativeProbe(), factory = native.factory(), provider = TransformClient()
            var saved = settings(); saved.language = "hi"; saved.dictionary = ["Global"]
            let preset = TransformPreset(name: "Rewrite", instruction: "be concise")
            saved.transformPresets = [preset]; saved.selectedPresetID = preset.id
            saved.outputMode = command ? .cleanup : .selectedPreset
            let machine = DictationSession()
            let event: DictationSession.Event = command
                ? .startCommand(settings: saved, cleanupConfigured: true, focus: .editable, selection: "selected source")
                : .startDictation(settings: saved, cleanupConfigured: true, live: false)
            _ = machine.handle(event)
            let acknowledged = machine.handle(.recorderStarted(gen: machine.gen))
            let focus = command ? [] : machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
            XCTAssertTrue((acknowledged + focus).contains(.ensureModelLoaded))
            guard case .recording(let session) = machine.state else { return XCTFail("Expected capture") }
            let handle = try await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: factory, operation: session.operation)
            saved.language = "es"; saved.dictionary = ["later"]
            if command {
                let instruction = await DictationProcessing.command(operation: session.operation, handle: handle, samples: audio)
                let text = try await session.transform(instruction: XCTUnwrap(instruction)) { _ in provider }
                XCTAssertEqual(text, "transformed")
            } else {
                let raw = try recognitionUnwrap(await handle.finalResult(samples: audio, window: nil).text)
                let pipeline = Pipeline(outputSettings: session.effectiveSettings, bundleID: nil) { _ in provider }
                let result = await pipeline.clean(transcript: raw)
                XCTAssertEqual(result.text, "transformed")
            }
            XCTAssertEqual(native.calls.count, 1); XCTAssertEqual(native.calls[0].language, "hi")
            XCTAssertEqual(native.calls[0].prompt, "Global"); XCTAssertEqual(provider.instructions.count, 1)
        }
    }
    func testSelectedTextPresetReducerAndHistoryTextRetryHaveZeroRecognitionEntry() async throws {
        let native = FoundationNativeProbe(), provider = TransformClient()
        var saved = settings(); saved.cleanupEnabled = true
        let preset = TransformPreset(name: "Rewrite", instruction: "be concise")
        saved.transformPresets = [preset]; saved.selectedPresetID = preset.id
        let machine = DictationSession()
        let effects = machine.handle(.startSavedPreset(settings: saved, cleanupConfigured: true, selection: "selected source",
            target: .init(focus: .editable)))
        XCTAssertFalse(effects.contains(.ensureModelLoaded))
        XCTAssertFalse(effects.contains { if case .applyPreferencesAndStartCapture = $0 { return true }; return false })
        guard case .runSavedPreset(let session)? = effects.first(where: { if case .runSavedPreset = $0 { return true }; return false }) else { return XCTFail("Expected text transform") }
        let result = await DictationProcessing.transform(operation: session.operation) {
            try await session.transform(instruction: session.preset!.intent) { _ in provider }
        }
        XCTAssertEqual(result?.text, "transformed")
        let entry = HistoryEntry(raw: "raw text", cleaned: nil, appName: nil)
        saved.cleanupEnabled = false
        let retry = try HistoryRetryRequest(settings: saved, environment: [:], source: entry, applyPreset: false,
            credentials: testCredentialStore())
        let output = try await retry.run(source: entry.raw, factory: { _, _, _, _ in
            XCTFail("Cleanup disabled text retry must be local"); return provider
        })
        XCTAssertEqual(output.0, "raw text")
        XCTAssertTrue(native.paths.isEmpty); XCTAssertTrue(native.calls.isEmpty); XCTAssertEqual(native.admissions, 0)
    }
    func testAcquisitionCancellationDuringConstructorReturnsNoHandleAndNoFallback() async throws {
        let probe = FoundationNativeProbe(), op = PendingOperation(name: "held")
        probe.construct = { op.revoke(); op.requestAbort() }
        await recognitionAssertThrows(try await RecognitionAcquisition.acquire(request: RecognitionRequest(settings: settings()), resident: nil, factory: probe.factory(), operation: op))
        XCTAssertEqual(probe.paths.count, 1); XCTAssertEqual(probe.releases, 1); XCTAssertTrue(probe.calls.isEmpty)
    }
}
