import Foundation
import XCTest
@testable import ParlaCore

/// A native-free client that truly suspends and deliberately returns success after cancellation.
final class RecognitionSuspension: RecognitionClient {
    let entered = XCTestExpectation(description: "async recognition suspended")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RecognitionNativeOutcome, Never>?
    private(set) var prompt: String?
    private(set) var language: String?
    func recognize(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock { self.prompt = initialPrompt; self.language = language; self.continuation = continuation }
            entered.fulfill()
        }
    }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        await recognize(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort).text
    }
    func finish(_ text: String = "late native text") {
        let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
        pending?.resume(returning: .completed(.init(text: text)))
    }
}

final class AsyncRecognitionTests: XCTestCase {
    private let audio = [Float](repeating: 0.2, count: 16_000)
    @MainActor func testTimedProductionMapperLeavesMainActorAndRetainsQueueUntilActualExit() async throws {
        let p = TimedNativeProbe(bytes: [Array("held".utf8)], starts: [0], ends: [1])
        let entered = expectation(description: "timed native full held"), exit = DispatchSemaphore(value: 0)
        p.hold = { XCTAssertFalse(Thread.isMainThread); entered.fulfill(); exit.wait() }
        let operation = PendingOperation(name: "timed fake full")
        var published = 0, nextEntered = 0
        let factory = p.factory(), frozen = request
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
            let handle = try! await factory.acquire(request: frozen)
            let result = await handle.timedFileResult(samples: self.audio, shouldAbort: { operation.shouldAbort })
            XCTAssertNil(result.text); XCTAssertNil(result.segments)
            if result.text != nil { published += 1 }
        }
        await fulfillment(of: [entered], timeout: 3)
        operation.revoke(); operation.requestAbort()
        let second = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "next"), completes: true) { nextEntered += 1 }
        XCTAssertFalse(operation.hasExited); XCTAssertEqual(nextEntered, 0); XCTAssertEqual(p.releases, 0)
        exit.signal(); await second.value
        XCTAssertTrue(operation.hasExited); XCTAssertEqual(p.releases, 1); XCTAssertEqual(p.calls, 1)
        XCTAssertEqual(published, 0); XCTAssertEqual(nextEntered, 1)
    }
    private var request: RecognitionRequest {
        var settings = Settings(); settings.language = "hi"; settings.dictionary = ["Frozen"]
        return RecognitionRequest(settings: settings)
    }
    private final class NativeBottom: WhisperNativeContext {
        var multilingual: Bool { false }
        func knowsLanguage(_ code: String) -> Bool { code == "en" }
        func spokenLanguage() -> String? { nil }
        func decode(_ samples: [Float], initialPrompt: String?, language: String,
                    configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
            XCTAssertFalse(Thread.isMainThread, "The real adapter must leave MainActor before blocking decode")
            return .init(status: 0, segments: [" native result "])
        }
    }
    @MainActor func testMainActorEntryUsesRealDefaultFactoryAndWhisperOffMainForConstructionAndDecode() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let factory = RecognitionFactory(native: { _, _ in
            XCTAssertFalse(Thread.isMainThread, "Awaited production acquisition must leave MainActor before construction")
            return NativeBottom()
        }, runtime: { .init(nativeVersion: "fake", buildScope: "fake") }, metadata: { _ in nil }, admit: { _, _ in })
        let handle = try await factory.acquire(request: request)
        XCTAssertTrue(handle.client is WhisperTranscriber)
        let result = await handle.recognize(audio, pass: .fullFinal)
        XCTAssertEqual(result.native, .completed(.init(text: "native result")))
        XCTAssertTrue(Thread.isMainThread)
    }
    func testPipelineProcessWaitsForSuspendedCallbackBeforeCleanupAndReturn() async throws {
        let client = RecognitionSuspension()
        var cleaned: [String] = []
        let pipeline = Pipeline(transcribe: { samples, prompt in
            await client.transcribe(samples, initialPrompt: prompt, language: "hi", shouldAbort: nil)
        }, cleanup: { text, _ in cleaned.append(text); return "polished" }, settings: { Settings() }, frontBundleID: { nil })
        let work = Task { await pipeline.process(samples: audio) }
        await fulfillment(of: [client.entered], timeout: 2)
        XCTAssertTrue(cleaned.isEmpty)
        client.finish("spoken")
        let result = await work.value
        XCTAssertEqual(result, "polished"); XCTAssertEqual(cleaned, ["spoken"])
    }
    func testCanceledFinalKeepsClientAndQueueUntilActualReturnAndCannotReachPublication() async throws {
        let operation = PendingOperation(name: "suspended final")
        var client: RecognitionSuspension? = RecognitionSuspension()
        weak var borrower = client
        let entered = client!.entered, frozen = request
        var recognized = 0, cleaned = 0, delivered = 0, successor = 0
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) { [owned = client!] in
            let handle = try! RecognitionHandle(request: frozen) { _ in owned }
            await DictationProcessing.final(operation: operation, samples: self.audio, window: nil,
                prepare: { handle }, recognized: { _, _ -> String? in recognized += 1; return "raw/history" },
                clean: { text in cleaned += 1; return (text, nil) }, completed: { _, _, _ in delivered += 1 })
        }
        client = nil
        await fulfillment(of: [entered], timeout: 2)
        operation.revoke(); operation.requestAbort()
        let next = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "successor"), completes: true) { successor += 1 }
        XCTAssertNotNil(borrower); XCTAssertFalse(operation.hasExited); XCTAssertEqual(successor, 0)
        XCTAssertEqual(recognized + cleaned + delivered, 0)
        borrower?.finish()
        await next.value
        XCTAssertTrue(operation.hasExited); XCTAssertEqual(successor, 1)
        XCTAssertEqual(recognized + cleaned + delivered, 0); XCTAssertNil(borrower)
    }
    func testSuspendedHandlePreservesLateCompletionEvidenceAndSuppressesText() async throws {
        let client = RecognitionSuspension(), operation = PendingOperation(name: "late evidence")
        let handle = try RecognitionHandle(request: request) { _ in client }
        let task = Task { await handle.recognize(audio, pass: .command, shouldAbort: { operation.shouldAbort }) }
        await fulfillment(of: [client.entered], timeout: 2)
        operation.revoke(); client.finish()
        let result = await task.value
        XCTAssertEqual(result.native, .completed(.init(text: "late native text")))
        XCTAssertTrue(result.canceled); XCTAssertNil(result.text)
        XCTAssertEqual(client.language, "hi"); XCTAssertEqual(client.prompt, "Frozen")
    }
    func testSuspendedStreamAndCommandAwaitFinalTextAndHonorRevocation() async throws {
        for cancel in [false, true] {
            for command in [false, true] {
                let client = RecognitionSuspension(), operation = PendingOperation(name: "origin")
                let handle = try RecognitionHandle(request: request) { _ in client }
                let task = Task {
                    if command { return await DictationProcessing.command(operation: operation, handle: handle, samples: audio) }
                    return await DictationProcessing.stream(operation: operation, handle: handle, samples: audio,
                        pass: .streamTail("prefix"), capturing: { true })
                }
                await fulfillment(of: [client.entered], timeout: 2)
                if cancel { operation.revoke(); operation.requestAbort() }
                client.finish("tail")
                let result = await task.value
                XCTAssertEqual(result, cancel ? nil : "tail")
                XCTAssertEqual(client.language, "hi")
                XCTAssertTrue(client.prompt?.contains("Frozen") == true)
            }
        }
    }
}
