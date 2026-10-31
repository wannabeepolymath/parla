import Foundation
import XCTest
@testable import ParlaCore

private final class SpeechTestConverter: AppleSpeechConverter {
    let format: AppleSpeechFormat
    let samples: [Float]
    var consumedSourceSamples = 0
    var ended = false
    var fail = false, badBytes = false
    init(_ samples: [Float], rate: Int32 = 16_000) { self.samples = samples; format = .init(rate: rate, channels: 1, bytesPerFrame: 4) }
    func next() throws -> AppleSpeechBuffer? {
        if fail { throw AppleSpeechRefusal.conversion }
        guard consumedSourceSamples < samples.count else { ended = true; return nil }
        let count = min(16_000, samples.count - consumedSourceSamples); consumedSourceSamples += count
        let frames = count * Int(format.rate) / 16_000
        return .init(frames: frames, bytes: badBytes ? 1_048_577 : frames * 4, payload: NSObject())
    }
}
private final class SpeechTestSession: AppleSpeechSession {
    let lock = NSLock()
    var events: [AppleSpeechEvent] = []
    var converterFailure = false, collectorFailure = false, finalizeFailure = false, early = false, badBytes = false
    var rate: Int32 = 16_000
    var converterCalls = 0, finalizeCalls = 0, cancelCalls = 0, consumed = 0
    var collected = false
    private var collector: CheckedContinuation<Void, Error>?
    let entered = XCTestExpectation(description: "finalize entered")
    var holdFinalize = false
    var holdCancel = false
    let cancelEntered = XCTestExpectation(description: "native cancel held")
    let cancelLatch = RecognitionTestLatch()
    private var finalizer: CheckedContinuation<Void, Never>?
    func converter(samples: [Float]) async throws -> AppleSpeechConverter {
        converterCalls += 1; let c = SpeechTestConverter(samples, rate: rate); c.fail = converterFailure; c.badBytes = badBytes; return c
    }
    func collect(ready: @escaping () -> Void, _ emit: @escaping (AppleSpeechEvent) throws -> Void) async throws {
        ready()
        for event in events { try emit(event) }
        if collectorFailure { throw AppleSpeechRefusal.results }
        try await withCheckedThrowingContinuation { c in
            let finished = lock.withLock { () -> Bool in if collected { return true }; collector = c; return false }
            if finished { c.resume() }
        }
    }
    private func finishCollector() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in collected = true; let c = collector; collector = nil; return c }; c?.resume()
    }
    func analyze(_ input: AppleSpeechInput) async throws -> AppleSpeechTime? {
        if early { return .init(0, rate) }
        while let (buffer, _) = try input.next() { consumed += buffer.frames }
        return consumed == 0 ? nil : .init(Int64(consumed), rate)
    }
    func finalize(through: AppleSpeechTime) async throws {
        finalizeCalls += 1
        if holdFinalize { await withCheckedContinuation { c in lock.withLock { finalizer = c }; entered.fulfill() } }
        if finalizeFailure { throw AppleSpeechRefusal.native }
        finishCollector()
    }
    func releaseFinalize() { let c = lock.withLock { let c = finalizer; finalizer = nil; return c }; c?.resume() }
    func cancelAndFinish() async {
        lock.withLock { cancelCalls += 1 }
        if holdCancel { cancelEntered.fulfill(); await cancelLatch.wait() }
        finishCollector()
    }
}
private final class SpeechDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var waiters: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    private var canceled = Set<UUID>()
    let waiting = XCTestExpectation(description: "monotonic watchdog waiting")
    var clock: AppleSpeechClock { .init(now: { self.lock.withLock { self.time } }, wait: { delay in try await self.sleep(delay) }) }
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let stop = lock.withLock { () -> Bool in
                    if canceled.remove(id) != nil { return true }; waiters[id] = (time + delay, c); return false
                }
                if stop { c.resume(throwing: CancellationError()) }
                waiting.fulfill()
            }
        }, onCancel: {
            let c = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let c = self.waiters.removeValue(forKey: id)?.1 { return c }; self.canceled.insert(id); return nil
            }; c?.resume(throwing: CancellationError())
        })
    }
    func advance(to value: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            time = value; let ready = waiters.filter { $0.value.0 <= value }; for id in ready.keys { waiters.removeValue(forKey: id) }; return ready.values.map { $0.1 }
        }; ready.forEach { $0.resume() }
    }
}
final class AppleSpeechTests: XCTestCase {
    private let audio = [Float](repeating: 0.2, count: 32_001)
    private func settings() -> Settings {
        var s = Settings(); s.recognitionEngine = .appleSpeech; s.appleSpeechLocale = "en-US"; s.dictionary = ["private-hint"]; s.whisperModelPath = "/private/saved.bin"; return s
    }
    private func event(_ text: String, _ start: Int64, _ end: Int64, final: Bool = true) -> AppleSpeechEvent {
        .init(text: text, start: .init(start, 16_000), end: .init(end, 16_000), finalization: .init(end, 16_000), isFinal: final)
    }
    private func factory(_ session: SpeechTestSession, releases: @escaping () -> Void = {}, available: @escaping () throws -> Void = {}) -> RecognitionFactory {
        RecognitionFactory(appleBottom: .init(available: available, session: { _ in session }), appleInstalledUse: { _, operation in
            AppleSpeechLease(operation: operation ?? PendingOperation(name: "test"), retirement: releases)
        }, native: { _, _ in XCTFail("Whisper entered"); throw AppleSpeechRefusal.native },
        preparation: RecognitionPreparation(storage: { XCTFail("B53 storage opened"); throw AppleSpeechRefusal.native }),
        preparationPermission: { XCTFail("Whisper permission queried"); return false }, runtime: { XCTFail("runtime queried"); return .init(nativeVersion: "", buildScope: "") }, metadata: { _ in XCTFail("metadata queried"); return nil }, admit: { _, _ in XCTFail("Whisper admission") })
    }
    func testSettingsMalformedExplicitValuesStayFiniteThroughStoreAndProfiles() throws {
        for json in ["{}", #"{"recognitionEngine":null,"appleSpeechLocale":null}"#] {
            XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).recognitionEngine, .whisper)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave4f2-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try fixture(root, "created"); defer { try? FileManager.default.removeItem(at: root); try? fixture(root, "removed") }
        let url = root.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url, credentials: testCredentialStore())
        for json in [#"{"recognitionEngine":"future","nativePreparationSafeStartEnabled":"bad"}"#, #"{"recognitionEngine":"future"}"#, #"{"recognitionEngine":23}"#, #"{"recognitionEngine":{},"profiles":[{}]}"#, #"{"recognitionEngine":"appleSpeech","appleSpeechLocale":23}"#, #"{"recognitionEngine":"appleSpeech","appleSpeechLocale":"auto"}"#] {
            try Data(json.utf8).write(to: url)
            let read = SettingsStore(url: url, credentials: testCredentialStore())
            XCTAssertEqual(RecognitionRequest(settings: read.load()).selection, .invalid)
        }
        var s = settings(), p = DictationProfile(); p.name = "profile"; p.target = "test.app"; p.language = "auto"; s.profiles = [p]
        let conflict = ProfileResolver.resolve(s, at: .init(bundleID: "test.app"))
        XCTAssertEqual(RecognitionRequest(settings: conflict.settings).selection, .invalid)
        p.recognitionEngine = .appleSpeech; s.profiles = [p]
        XCTAssertEqual(RecognitionRequest(settings: ProfileResolver.resolve(s, at: .init(bundleID: "test.app")).settings).selection, .invalid)
        XCTAssertTrue(AppleSpeechLocale.isValid("en_US")); XCTAssertFalse(AppleSpeechLocale.isValid("en--US"))
        p.recognitionEngine = .whisper; s.profiles = [p]
        XCTAssertEqual(RecognitionRequest(settings: ProfileResolver.resolve(s, at: .init(bundleID: "test.app")).settings).selection.engine, .whisper)
        p.recognitionEngine = nil; p.appleSpeechLocale = "ja-JP"; s.profiles = [p]
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: s, cleanupConfigured: false, recognitionDestination: .init(bundleID: "test.app"))
        s.appleSpeechLocale = "en-GB"
        XCTAssertEqual(session.recognition.selection, .appleSpeech(locale: "ja-JP")); XCTAssertEqual(session.settings.appleSpeechLocale, "en-US")
        let roundtrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundtrip.whisperModelPath, "/private/saved.bin"); XCTAssertEqual(roundtrip.profiles[0].appleSpeechLocale, "ja-JP")
        _ = store
    }
    private func fixture(_ root: URL, _ action: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }; try file.seekToEnd()
        try file.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
    }
    func testActualFactoryAndAdapterUseFullPCMNoWhisperPromptWindowOrRuntime() async throws {
        let session = SpeechTestSession(); session.events = [event("日本", 0, 16_000), event("語。", 16_000, 32_000)]
        var retired = 0
        let factory = factory(session, releases: { retired += 1 }), request = RecognitionRequest(settings: settings())
        let handle = try await factory.acquire(request: request)
        XCTAssertTrue(handle.client is AppleSpeechRecognition); XCTAssertNil(handle.identity?.runtime)
        XCTAssertEqual(handle.identity?.artifact, .systemAssetsRevisionUnknown); XCTAssertFalse(handle.identity?.reusable ?? true)
        let window = handle.window(confirmedText: "Whisper private prefix", cutSample: 16_000)
        let result = await handle.finalResult(samples: audio, window: window)
        XCTAssertEqual(result.text, "日本語。"); XCTAssertEqual(session.consumed, audio.count); XCTAssertEqual(session.finalizeCalls, 1)
        XCTAssertEqual(retired, 1) // the live handle keeps its separate acquisition lease
        let refused = await handle.recognize(audio, pass: .fullFinal, initialPrompt: "required")
        XCTAssertEqual(refused.native, .failed(.unsupportedCapability)); XCTAssertEqual(session.converterCalls, 1)
        for pass in [RecognitionHandle.Pass.warmup, .streamHead("private"), .streamTail("private"), .windowedFinal("private")] {
            recognitionAssertEqual(await handle.recognize(audio, pass: pass).native, .failed(.unsupportedCapability))
        }
    }
    func testWholeBatchResultAndConverterFailuresDiscardFragmentsAndEmptyRemainsCompleted() async throws {
        let duplicate = event("hello ", 0, 8_000)
        let cases: [([AppleSpeechEvent], Bool)] = [([duplicate, duplicate, event("world", 8_000, 16_000)], true),
            ([event("text", 8_000, 16_000), duplicate], false), ([event("volatile", 0, 16_000, final: false)], false),
            ([event("outside", 0, 64_000)], false), ([event(String(repeating: "a", count: 1_048_577), 0, 16_000)], false)]
        for (events, success) in cases {
            let session = SpeechTestSession(); session.events = events
            let handle = try await factory(session).acquire(request: RecognitionRequest(settings: settings()))
            let result = await handle.recognize(audio, pass: .fullFinal)
            XCTAssertEqual(result.native.text != nil, success)
            if success { XCTAssertEqual(result.text, "hello world") }
        }
        for mode in 0..<5 {
            let session = SpeechTestSession(); session.events = [duplicate]
            session.converterFailure = mode == 0; session.collectorFailure = mode == 1; session.finalizeFailure = mode == 2; session.early = mode == 3; session.badBytes = mode == 4
            let handle = try await factory(session).acquire(request: RecognitionRequest(settings: settings()))
            recognitionAssertNil(await handle.recognize(audio, pass: .fullFinal).native.text)
        }
        let empty = SpeechTestSession(), handle = try await factory(empty).acquire(request: RecognitionRequest(settings: settings()))
        let result = await handle.recognize([], pass: .fullFinal)
        XCTAssertEqual(result.native, .completed(.init(text: "", requestedLocale: "en-US", resolvedLocale: "en-US"))); XCTAssertFalse(result.canceled)
    }
    func testUnsupportedAndUnknownFactoryDispatchHasNoWhisperOrNativeEntry() async throws {
        for reason in [AppleSpeechRefusal.unsupported, .deviceUnavailable, .unsupportedLocale, .assetsUnavailable, .needsPreparation] {
            let session = SpeechTestSession()
            await recognitionAssertThrows(try await factory(session, available: { throw reason }).acquire(request: RecognitionRequest(settings: settings())))
            XCTAssertEqual(session.converterCalls, 0)
        }
        let session = SpeechTestSession(); var s = settings(); s.recognitionEngine = .invalid
        await recognitionAssertThrows(try await factory(session).acquire(request: RecognitionRequest(settings: s)))
        XCTAssertEqual(session.converterCalls, 0)
    }
    func testLateFinalizeEvidenceRetainedButRevocationKeepsQueueAndLeaseUntilExit() async throws {
        let session = SpeechTestSession(); session.events = [event("late", 0, 16_000)]; session.holdFinalize = true
        let operation = PendingOperation(name: "held Apple final"), request = RecognitionRequest(settings: settings())
        var retired = 0, successor = 0, result: RecognitionPassResult?
        let factory = factory(session, releases: { retired += 1 })
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
            let handle = try! await factory.acquire(request: request, operation: operation)
            result = await handle.recognize(self.audio, pass: .fullFinal, shouldAbort: { operation.shouldAbort })
        }
        await fulfillment(of: [session.entered], timeout: 3)
        operation.revoke(); operation.requestAbort()
        let next = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "next"), completes: true) { successor += 1 }
        XCTAssertEqual(retired, 0); XCTAssertEqual(successor, 0); XCTAssertFalse(operation.hasExited)
        session.releaseFinalize(); await next.value
        XCTAssertEqual(result?.native.text, "late"); XCTAssertTrue(result?.canceled == true); XCTAssertNil(result?.text)
        XCTAssertEqual(retired, 2); XCTAssertEqual(successor, 1); XCTAssertEqual(session.cancelCalls, 1)
    }
    func testMonotonicEqualityExpiresAndBothFinalizeAndNativeCancelMustActuallyExit() async throws {
        let clock = SpeechDeadlineClock(), session = SpeechTestSession()
        session.events = [event("late", 0, 16_000)]; session.holdFinalize = true; session.holdCancel = true
        var retired = 0, successor = false
        var factory = factory(session, releases: { retired += 1 }); factory.appleClock = clock.clock
        let operation = PendingOperation(name: "deadline"), request = RecognitionRequest(settings: settings())
        var result: RecognitionPassResult?
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
            let handle = try! await factory.acquire(request: request, operation: operation)
            result = await handle.recognize(self.audio, pass: .fullFinal, shouldAbort: { operation.shouldAbort })
        }
        await fulfillment(of: [session.entered, clock.waiting], timeout: 3)
        clock.advance(to: 160) // equality, not strictly greater
        await fulfillment(of: [session.cancelEntered], timeout: 3)
        let next = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "next"), completes: true) { successor = true }
        XCTAssertTrue(operation.shouldAbort); XCTAssertFalse(successor); XCTAssertEqual(retired, 0)
        session.releaseFinalize()
        XCTAssertFalse(operation.hasExited); XCTAssertEqual(retired, 0)
        session.cancelLatch.signal(); await next.value
        XCTAssertEqual(result?.native.text, "late"); XCTAssertTrue(result?.canceled == true)
        XCTAssertEqual(retired, 2); XCTAssertTrue(successor); XCTAssertEqual(session.cancelCalls, 1)
    }
    func testNegotiatedFractionalRatioRationalOverflowAndResultEventBound() async throws {
        let session = SpeechTestSession(); session.rate = 44_100
        let handle = try await factory(session).acquire(request: RecognitionRequest(settings: settings()))
        let result = await handle.recognize(audio, pass: .fullFinal)
        XCTAssertEqual(result.native.text, ""); XCTAssertEqual(session.consumed, audio.count * 44_100 / 16_000)
        for events in [[AppleSpeechEvent(text: "invalid", start: .init(Int64.max, 1), end: .init(Int64.max, 2), finalization: .init(Int64.max, 3))],
                       Array(repeating: event("duplicate", 0, 16_000), count: 10_001)] {
            let invalid = SpeechTestSession(); invalid.events = events
            let h = try await factory(invalid).acquire(request: RecognitionRequest(settings: settings()))
            recognitionAssertNil(await h.recognize(audio, pass: .fullFinal).native.text)
        }
        let invalidPCM = SpeechTestSession(), h = try await factory(invalidPCM).acquire(request: RecognitionRequest(settings: settings()))
        recognitionAssertNil(await h.recognize([.nan], pass: .fullFinal).native.text)
        XCTAssertEqual(invalidPCM.converterCalls, 0)
    }

    func testActualAppleDiagnosticExportContainsOnlyFiniteIdentityAndNoPrivateCanaries() async throws {
        let diagnostics = DiagnosticStore(), operation = PendingOperation(name: "private-operation-name", origin: .dictation, diagnostics: diagnostics)
        let native = SpeechTestSession(); native.events = [event("PRIVATE_TRANSCRIPT", 0, 16_000)]
        let handle = try await factory(native).acquire(request: RecognitionRequest(settings: settings()), diagnostics: operation.diagnostics)
        _ = await handle.recognize(audio, pass: .fullFinal, diagnostics: operation.diagnostics)
        operation.finish()
        let exported = String(decoding: try JSONEncoder().encode(diagnostics.snapshot()), as: UTF8.self)
        XCTAssertTrue(exported.contains("appleSpeech")); XCTAssertTrue(exported.contains("systemUnknown"))
        for canary in ["en-US", "private-hint", "/private", "saved.bin", "PRIVATE_TRANSCRIPT", "private-operation-name", "reservation"] {
            XCTAssertFalse(exported.contains(canary))
        }
    }

}
