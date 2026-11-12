import XCTest
import AVFoundation
import ParlaCore
#if !SOURCE_CHECK
@testable import Parla
#endif

final class DeliveryTests: XCTestCase {
    func completed() -> DictationSession {
        var session = DictationSession(); session.destination = .keyboard
        session.keyboardInstance = UUID(); session.documentID = UUID(); session.phase = .completed; session.result = "Ready to send."
        return session
    }
    func testExplicitConsentAndIdentityAreBothRequired() throws {
        let session = completed(); let instance = try XCTUnwrap(session.keyboardInstance); let document = try XCTUnwrap(session.documentID)
        func allowed(request: UUID? = nil, owner: UUID? = nil, field: UUID? = nil, sensitive: Bool = false, reviewed: Bool = true, now: Date = Date()) -> Bool {
            DeliveryGuard.canConsume(session, request: request ?? session.id, instance: owner ?? instance, document: field ?? document, sensitive: sensitive, explicitlyReviewed: reviewed, now: now)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(request: UUID()))
        XCTAssertFalse(allowed(owner: UUID()), "A relaunched extension must not inherit insertion consent")
        XCTAssertFalse(allowed(field: UUID()), "A later document must not receive an earlier result")
        XCTAssertFalse(allowed(sensitive: true)); XCTAssertFalse(allowed(reviewed: false))
        XCTAssertFalse(allowed(now: session.expires))
    }
    func testCancelledAndSpentCapabilitiesCannotBeConsumed() throws {
        var session = completed(); let document = try XCTUnwrap(session.documentID); let instance = try XCTUnwrap(session.keyboardInstance)
        for phase in [SessionPhase.cancelled, .consumed, .processing, .failed] {
            session.phase = phase
            XCTAssertFalse(DeliveryGuard.canConsume(session, request: session.id, instance: instance, document: document, sensitive: false, explicitlyReviewed: true, now: Date()))
        }
    }
}
final class SessionStorageTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!
    override func setUpWithError() throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("parla-unit-tests", isDirectory: true)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = SessionStore(file: ProtectedFile(url: directory.appendingPathComponent("session.json"), initial: { SessionEnvelope() }))
    }
    override func tearDownWithError() throws { if let directory { try FileManager.default.removeItem(at: directory) } }
    func testCancelDefeatsLateCompletionAndDuplicateCommands() throws {
        let request = try store.request(destination: .keyboard, document: UUID(), instance: UUID())
        try store.command(.cancel, id: request.id, generation: request.generation)
        try store.command(.stop, id: request.id, generation: request.generation)
        XCTAssertFalse(try store.update(id: request.id, generation: request.generation) { $0.phase = .completed; $0.result = "late" })
        XCTAssertEqual(try store.read()?.phase, .cancelled); XCTAssertNil(try store.read()?.result)
    }
    func testNewAttemptHasDistinctIdentityAndRejectsOldGeneration() throws {
        let first = try store.request(destination: .app)
        XCTAssertThrowsError(try store.request(destination: .app))
        try store.command(.cancel, id: first.id, generation: first.generation)
        let next = try store.request(destination: .app)
        XCTAssertNotEqual(first.id, next.id); XCTAssertNotEqual(first.generation, next.generation)
        XCTAssertFalse(try store.update(id: first.id, generation: first.generation) { $0.result = "wrong" })
        XCTAssertFalse(try store.update(id: next.id, generation: first.generation) { $0.result = "wrong generation" })
        XCTAssertNil(try store.read()?.result)
    }
    func testOwnedTransitionSurvivesReplacementWithoutCancellingTheNewRequest() throws {
        let otherProcess = SessionStore(file: ProtectedFile(url: directory.appendingPathComponent("session.json"), initial: { SessionEnvelope() }))
        for phase in [SessionPhase.recording, .processing] {
            let first = try store.request(destination: .keyboard)
            let owned = try XCTUnwrap(store.updateSnapshot(id: first.id, generation: first.generation) { $0.phase = phase })
            // Another process replaces shared state before the coordinator adopts its returned snapshot.
            try otherProcess.command(.cancel, id: first.id, generation: first.generation)
            let replacement = try otherProcess.request(destination: .keyboard)
            XCTAssertEqual(try store.read()?.id, replacement.id)
            XCTAssertEqual(owned.id, first.id); XCTAssertEqual(owned.generation, first.generation)
            XCTAssertEqual(owned.phase, phase)
            // Teardown must address the owned operation, never the later shared request.
            try store.command(.cancel, id: owned.id, generation: owned.generation)
            XCTAssertEqual(try otherProcess.read()?.id, replacement.id)
            XCTAssertEqual(try otherProcess.read()?.phase, .requested)
            XCTAssertNil(try store.updateSnapshot(id: first.id, generation: first.generation) { $0.phase = .recording })
            try otherProcess.command(.cancel, id: replacement.id, generation: replacement.generation)
        }
    }
    func testOneTimeClaimPersistsBeforeInsertionEvenAcrossIndependentStoreInstances() throws {
        let instance = UUID(); let document = UUID()
        let request = try store.request(destination: .keyboard, document: document, instance: instance)
        try store.update(id: request.id, generation: request.generation) { $0.phase = .completed; $0.result = "Only once" }
        let independent = SessionStore(file: ProtectedFile(url: directory.appendingPathComponent("session.json"), initial: { SessionEnvelope() }))
        XCTAssertEqual(try independent.consume(request: request.id, instance: instance, document: document, sensitive: false, reviewed: true), "Only once")
        XCTAssertNil(try store.consume(request: request.id, instance: instance, document: document, sensitive: false, reviewed: true))
        XCTAssertEqual(try store.read()?.phase, .consumed); XCTAssertNotNil(try store.read()?.acknowledgedAt)
    }
    func testExpiryRemovesTransientTextAndPreventsResurrection() throws {
        let request = try store.request(destination: .app)
        try store.update(id: request.id, generation: request.generation) { $0.phase = .completed; $0.result = "temporary"; $0.expires = Date().addingTimeInterval(-1) }
        XCTAssertNil(try store.read()?.result)
        XCTAssertFalse(try store.update(id: request.id, generation: request.generation) { $0.result = "resurrected" })
    }
    func testCorruptStorageIsNotSilentlyOverwritten() throws {
        _ = try store.request(destination: .app)
        let url = directory.appendingPathComponent("session.json"); let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.read()); XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
final class RetentionTests: XCTestCase {
    func testRetentionBoundaryAndNeverPolicy() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(RetentionPolicy.keep.retains(.distantPast, now: now))
        XCTAssertFalse(RetentionPolicy.never.retains(now, now: now))
        XCTAssertFalse(RetentionPolicy.day.retains(now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(RetentionPolicy.day.retains(now.addingTimeInterval(-86_399), now: now))
    }
    @MainActor func testPolicyChangeDeletesBothTextAndAudioAndPreservesNotes() throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("parla-retention-tests/\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); try store.prepareDirectories()
        let name = UUID().uuidString + ".wav"; let audio = try XCTUnwrap(store.audioURL(name)); try Data([1,2,3]).write(to: audio)
        let old = Transcript(date: Date().addingTimeInterval(-90_000), raw: "old", audioName: name)
        try store.mutate { $0.transcripts = [old]; $0.notes = [Note(text: "Keep this note")] }
        var preferences = store.library.preferences; preferences.retention = .day; try store.savePreferences(preferences)
        XCTAssertTrue(store.library.transcripts.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(store.library.notes.first?.text, "Keep this note")
        preferences.retention = .never; try store.savePreferences(preferences)
        try store.mutate { $0.transcripts.append(Transcript(raw: "never retained")) }
        XCTAssertTrue(store.library.transcripts.isEmpty)
    }
}
/// Injected seams only: no model, network, microphone or Keychain.
private struct StubCleanup: CleanupProviding {
    let reply: (String) throws -> String
    func clean(transcript: String, context: CleanupContext) async throws -> String { try reply(transcript) }
}
final class DesktopCoreGlueTests: XCTestCase {
    private func settings(_ body: (inout Settings) -> Void = { _ in }) -> Settings { var s = Settings(); body(&s); return s }
    private func pipeline(_ s: Settings, reply: @escaping (String) throws -> String) -> Pipeline {
        Pipeline(outputSettings: s, bundleID: nil, failureLogging: .contentFree) { _ in StubCleanup(reply: reply) }
    }
    private let speech = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.2 }

    func testRecognitionUsesPipelineVocabularyHintsAndCleanupOutput() async throws {
        let s = settings { $0.dictionary = ["Parla", "SwiftUI"] }
        var prompt: String?
        let raw = try await DictationEngine.recognize(speech, pipeline: pipeline(s) { _ in "unused" }) {
            { _, hint in prompt = hint; return "  hello parla  " }
        }
        XCTAssertEqual(raw, "hello parla"); XCTAssertEqual(prompt, "Parla, SwiftUI")
        let outcome = await DictationEngine.finish(raw: raw, pipeline: pipeline(s) { _ in "Hello, Parla." })
        XCTAssertEqual(outcome, .init(raw: "hello parla", cleaned: "Hello, Parla.", final: "Hello, Parla.", cleanupFailure: nil))
    }
    func testSilenceAndShortAudioNeverAcquireAModel() async {
        var acquired = false
        for samples in [[Float](repeating: 0, count: 32_000), [Float](repeating: 0.3, count: 3_000)] {
            do {
                _ = try await DictationEngine.recognize(samples, pipeline: pipeline(settings()) { $0 }) { acquired = true; return { _, _ in "invented" } }
                XCTFail("The desktop floor must refuse silence and sub-0.4 s audio")
            } catch {}
        }
        XCTAssertFalse(acquired)
    }
    func testCleanupFailureKeepsRawTextWithReason() async {
        let outcome = await DictationEngine.finish(raw: "keep me", pipeline: pipeline(settings()) { _ in throw CleanupError(description: "fixture", userMessage: "provider unavailable") })
        XCTAssertEqual(outcome.final, "keep me"); XCTAssertNil(outcome.cleaned); XCTAssertEqual(outcome.cleanupFailure, "provider unavailable")
    }
    func testRawModeSkipsProviderAndLocalRulesApplyWithCleanupOff() async {
        var called = false
        let raw = await DictationEngine.finish(raw: "teh plan", pipeline: pipeline(settings { $0.outputMode = .raw }) { _ in called = true; return "x" })
        XCTAssertEqual(raw.final, "teh plan"); XCTAssertNil(raw.cleaned); XCTAssertFalse(called)
        let local = settings { $0.cleanupEnabled = false; $0.replacements = [LiteralReplacement(source: "teh", replacement: "the")]; $0.snippets = ["sign off": "Best, D."] }
        let replaced = await DictationEngine.finish(raw: "teh plan", pipeline: pipeline(local) { _ in called = true; return "x" })
        XCTAssertEqual(replaced.final, "the plan")
        let locked = await DictationEngine.finish(raw: "Sign off.", pipeline: pipeline(local) { _ in called = true; return "x" })
        XCTAssertEqual(locked.final, "Best, D."); XCTAssertFalse(called)
    }
    func testMissingModelIsReportedBeforeCaptureAndNeverReplaced() throws {
        let missing = settings { $0.recognitionEngine = .whisper; $0.whisperModelPath = ModelCatalog.directory.appendingPathComponent("ggml-\(UUID()).bin").path }
        XCTAssertNotNil(DictationEngine.recognitionIssue(missing))
        XCTAssertNotNil(DictationEngine.recognitionIssue(settings { $0.recognitionEngine = .invalid }))
        // A stale container path follows today's models directory; unknown paths stay as they are.
        let moved = settings { $0.whisperModelPath = "/old/container/Library/Application Support/Parla/models/ggml-small.en-q5_1.bin" }
        XCTAssertEqual(AppSettings.normalized(moved).whisperModelPath, ModelCatalog.path(for: ModelCatalog.all[1]))
        XCTAssertEqual(AppSettings.normalized(missing).whisperModelPath, missing.whisperModelPath)
    }
    func testModelVerificationRefusesWrongBytesAndLeavesInstalledFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-model-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelCatalog.default
        let destination = root.appendingPathComponent(model.filename), cache = VerifiedCache(url: root.appendingPathComponent("verified.json"))
        try Data("installed".utf8).write(to: destination)
        for bytes in [Data("<!doctype html><title>Sign in</title>".utf8), Data(count: 1_024)] {
            let staged = root.appendingPathComponent("staged"); try bytes.write(to: staged)
            XCTAssertThrowsError(try ModelCatalog.install(staged: staged, as: model, at: destination, cache: cache)) { error in
                XCTAssertTrue((error as? ModelFileError)?.description.contains("expected \(model.bytes) bytes") == true)
            }
            XCTAssertEqual(try Data(contentsOf: destination), Data("installed".utf8))
            XCTAssertFalse(cache.isVerified(destination))
        }
    }
    func testRetainedAudioRoundTripsAs16kMonoPCM16() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parla-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingStore.writeWAV(speech, to: url)
        let format = try AVAudioFile(forReading: url).fileFormat
        XCTAssertEqual(format.sampleRate, 16_000); XCTAssertEqual(format.channelCount, 1); XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
        let back = try Eval.loadSamples(url: url)
        XCTAssertEqual(back.count, speech.count)
        XCTAssertLessThan(zip(back, speech).map { abs($0 - $1) }.max() ?? 1, 1.0 / 16_000)
    }
    func testResamplerStreamsAnyTapFormatTo16kMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let resampler = Resampler()
        var total = 0
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)); buffer.frameLength = 4_800
            total += try XCTUnwrap(resampler.convert(buffer)).count
        }
        total += resampler.flush().count
        XCTAssertEqual(Double(total), 16_000, accuracy: 64) // one second of 48 kHz stereo
    }
}
