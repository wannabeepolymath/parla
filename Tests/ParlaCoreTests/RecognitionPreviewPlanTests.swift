import AVFoundation
import XCTest
@testable import ParlaCore

final class RecognitionPreviewPlanTests: XCTestCase {
    private func settings() -> Settings {
        var s = Settings(); s.streamPreviewEnabled = true
        s.recognitionPreviewModelID = "base.en"
        s.whisperModelPath = ModelCatalog.path(for: ModelCatalog.all[0])
        return s
    }
    func testOldJSONAndBothPersistedGatesAndExcludedOrigins() throws {
        for json in ["{}", #"{"recognitionPreviewModelID":null}"#] {
            XCTAssertNil(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).recognitionPreviewModelID)
        }
        let saved = settings()
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.recognitionPreviewModelID, "base.en")
        for i in 0..<6 {
            var s = saved
            if i == 0 { s.streamPreviewEnabled = false }
            if i == 1 { s.recognitionPreviewModelID = nil }
            if i == 2 { s.outputMode = .selectedPreset }
            let session = DictationSession.Session(gen: i, mode: i == 3 ? .command(selection: "source") : .dictation,
                settings: s, cleanupConfigured: false, live: i == 4, delivery: i == 5 ? .resultOnly : .keyboard)
            XCTAssertNil(session.previewPlan)
        }
    }
    func testResolvedProfileAutoDictionaryAndFinalEligibilityAreFrozen() throws {
        var s = settings(); s.language = "hi"; s.dictionary = ["Global"]
        var p = DictationProfile(); p.name = "Start"; p.target = "start.app"
        p.language = "auto"; p.dictionary = ["Profile"]
        p.whisperModelPath = ModelCatalog.path(for: ModelCatalog.all[1]); s.profiles = [p]
        let session = DictationSession.Session(gen: 4, mode: .dictation, settings: s, cleanupConfigured: false,
            recognitionDestination: .init(bundleID: "start.app"))
        let plan = try XCTUnwrap(session.previewPlan)
        XCTAssertEqual(plan.final, session.recognition); XCTAssertNil(plan.preview?.language)
        XCTAssertEqual(plan.preview?.dictionary, ["Profile", "Global"])
        XCTAssertEqual(plan.operationID, session.operation.id); XCTAssertEqual(plan.generation, 4)
        s.language = "es"; s.recognitionPreviewModelID = "missing"
        XCTAssertEqual(plan.modelID, "base.en"); XCTAssertNil(plan.preview?.language)
        XCTAssertNil(plan.refusal(directory: ModelCatalog.directory, catalog: ModelCatalog.all))
        for engine in [RecognitionEngine.appleSpeech, .parakeet, .invalid] {
            var other = settings(); other.recognitionEngine = engine
            let final = RecognitionRequest(settings: other)
            let candidate = try XCTUnwrap(RecognitionPreviewPlan(settings: other, final: final, generation: 1,
                operationID: UUID(), ordinaryPhysical: true))
            XCTAssertEqual(candidate.refusal(directory: ModelCatalog.directory, catalog: ModelCatalog.all), .ineligibleFinal)
            XCTAssertEqual(candidate.final, final)
        }
        var pinned = settings(); pinned.language = "hi"
        let candidate = try XCTUnwrap(RecognitionPreviewPlan(settings: pinned, final: RecognitionRequest(settings: pinned),
            generation: 1, operationID: UUID(), ordinaryPhysical: true))
        XCTAssertEqual(candidate.refusal(directory: ModelCatalog.directory, catalog: ModelCatalog.all), .languageUnavailable)
    }
    func testReducerRequiresOperationGenerationPhaseAndRecordingAndRevokesOnStopAndSuccessor() throws {
        let machine = DictationSession(diagnostics: nil)
        _ = machine.handle(.startDictation(settings: settings(), cleanupConfigured: false, live: false))
        _ = machine.handle(.recorderStarted(gen: machine.gen))
        _ = machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
        guard case .recording(let s) = machine.state else { return XCTFail("recording") }
        let phase = try XCTUnwrap(s.previewPlan?.phase)
        func event(_ gen: Int, _ operation: UUID, _ phase: RecognitionPreviewPhase) -> DictationSession.Event {
            .recognitionPreview(gen: gen, operationID: operation, phase: phase, update: .draft("draft", englishOnly: true))
        }
        XCTAssertEqual(machine.handle(event(s.gen, s.operation.id, phase)), [.hud(.speculativePreview(.draft("draft", englishOnly: true)))])
        XCTAssertTrue(machine.handle(event(s.gen, UUID(), phase)).isEmpty)
        XCTAssertTrue(machine.handle(event(s.gen, s.operation.id, RecognitionPreviewPhase())).isEmpty)
        _ = machine.handle(.stopRequested)
        XCTAssertFalse(phase.isCurrent); XCTAssertFalse(s.operation.shouldAbort)
        XCTAssertTrue(machine.handle(event(s.gen, s.operation.id, phase)).isEmpty)
        _ = machine.handle(.startDictation(settings: settings(), cleanupConfigured: false, live: false))
        XCTAssertTrue(machine.handle(event(s.gen, s.operation.id, phase)).isEmpty)
    }
    private final class Engine: MicrophoneCaptureEngine {
        var isRunning = false
        var route = MicrophoneRoute()
        func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws { isRunning = true }
        func stop() { isRunning = false }
    }
    func testActualRecorderSuffixOwnsLatestCopyAndRejectsForeignCapture() throws {
        let recorder = AudioRecorder(engine: Engine()), operation = UUID()
        try recorder.start(diagnosticOperation: operation)
        let audio = (0..<320_000).map { Float($0) }
        recorder.append(audio)
        let suffix = try XCTUnwrap(recorder.previewSuffix(operationID: operation))
        XCTAssertEqual(suffix.range, 80_000..<320_000); XCTAssertEqual(suffix.samples.count, 240_000)
        XCTAssertEqual(suffix.samples.first, 80_000); XCTAssertEqual(suffix.samples.last, 319_999)
        XCTAssertNil(recorder.previewSuffix(operationID: UUID()))
        recorder.append([42])
        XCTAssertEqual(suffix.samples.last, 319_999)
        _ = recorder.stop()
        XCTAssertNil(recorder.previewSuffix(operationID: operation))
        XCTAssertEqual(AudioRecorder.maxSamples, 9_600_000)
    }
    func testDisplaySuffixPreservesUTF8Boundary() {
        let text = String(repeating: "🌏é", count: 2000) + "last"
        let suffix = RecognitionPreviewLimits.displaySuffix(text)
        XCTAssertLessThanOrEqual(suffix.utf8.count, 4096)
        XCTAssertTrue(text.hasSuffix(suffix)); XCTAssertTrue(suffix.hasSuffix("last"))
    }
}
