import Foundation
import XCTest
@testable import ParlaCore
@testable import Parla

private final class AsyncOriginClient: RecognitionClient {
    let entered = XCTestExpectation(description: "origin recognition suspended")
    let exit = RecognitionTestLatch()
    var prompt: String?, language: String?
    var samples = 0
    func recognize(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        self.samples = samples.count; prompt = initialPrompt; self.language = language
        entered.fulfill(); await exit.wait()
        return .completed(.init(text: " raw preview \n"))
    }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        await recognize(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort).text
    }
}

final class AsyncRecognitionOriginTests: XCTestCase {
    private var settings: Settings {
        var settings = Settings(); settings.whisperModelPath = "/owned/ggml-base.en.bin"
        settings.language = "hi"; settings.dictionary = ["Frozen"]; settings.canceledCaptureUndoEnabled = true
        return settings
    }
    private func factory() -> RecognitionFactory {
        RecognitionFactory(native: { _, _ in XCTFail("An admitted exact resident must be borrowed"); throw CancellationError() },
            runtime: { .init(nativeVersion: "fake", buildScope: "fake") },
            metadata: { _ in .init(bytes: 8, modified: 1) }, directory: URL(fileURLWithPath: "/owned"), admit: { _, _ in })
    }
    private func resident(_ client: RecognitionClient, request: RecognitionRequest, factory: RecognitionFactory) throws -> RecognitionResident {
        .init(request: request, identity: try factory.resolve(request), instance: UUID(), client: client)
    }
    func testActualSetupWarmupAwaitsSuspensionAndRevocationBeforeReturningHandle() async throws {
        for cancel in [false, true] {
            let client = AsyncOriginClient(), operation = PendingOperation(name: "setup"), factory = factory()
            let request = RecognitionRequest(settings: settings), owner = try resident(client, request: request, factory: factory)
            let task = Task { try await RecognitionAcquisition.prepare(request: request, resident: owner, factory: factory, operation: operation) }
            await fulfillment(of: [client.entered], timeout: 2)
            XCTAssertNil(client.prompt); XCTAssertEqual(client.language, "hi"); XCTAssertEqual(client.samples, 16_000)
            if cancel { operation.revoke(); operation.requestAbort() }
            client.exit.signal()
            do { let handle = try await task.value; XCTAssertFalse(cancel); XCTAssertTrue(handle.client === client) }
            catch { XCTAssertTrue(cancel) }
        }
    }
    func testActualTryoutWaitsForAsyncClientBeforeDisplayCompletion() async throws {
        let client = AsyncOriginClient(), factory = factory(), request = RecognitionRequest(settings: settings)
        let owner = try resident(client, request: request, factory: factory)
        var completed = false
        let task = Task {
            let text = await RecognitionAcquisition.tryout(samples: Array(repeating: 0.2, count: 8000), request: request, resident: owner, factory: factory)
            completed = true; return text
        }
        await fulfillment(of: [client.entered], timeout: 2)
        XCTAssertFalse(completed); XCTAssertEqual(client.prompt, "Frozen"); XCTAssertEqual(client.language, "hi")
        client.exit.signal()
        let result = await task.value
        XCTAssertEqual(result, " raw preview \n"); XCTAssertTrue(completed)
    }
    @MainActor func testActualB57DispatcherRetainsDrainOwnershipAcrossSuspensionAndRevocation() async throws {
        for cancel in [false, true] {
            let saved = settings, client = AsyncOriginClient(), factory = factory()
            var generation = 1, copies: [String] = [], ordinary = 0, successor = false
            let controller = CanceledCaptureUndoController(configuration: { saved }, generation: { generation }, security: { .safe },
                now: { 100 }, schedule: { _, _ in {} }, copy: { copies.append($0) })
            let session = DictationSession.Session(gen: 1, mode: .dictation, settings: saved, cleanupConfigured: false, live: false)
            let owner = try resident(client, request: session.recognition, factory: factory)
            let runner = CanceledCaptureRecognition(controller: controller, typedResident: { owner }, factory: factory, verify: { _ in true })
            let dispatcher = DictationExecutionDispatcher(preview: runner, ordinary: { _, _, _ in ordinary += 1 })
            var chain: Task<Void, Never>?
            controller.enqueue = { job in chain = dispatcher.enqueue(.canceledCaptureUndo(job), previous: nil) }
            controller.accepted(session, physical: true); controller.acknowledged(session)
            session.operation.revoke(); generation = 2
            let context = DictationSession.CanceledCapture(generation: 1, operation: session.operation, request: session.recognition, reason: .explicitCancel)
            controller.transferred(Array(repeating: 0.2, count: 8000), context: context, deadline: 103)
            controller.present(generation: 1)
            controller.undo(token: try XCTUnwrap(controller.view.token))
            let job = try XCTUnwrap(controller.activeJob)
            await fulfillment(of: [client.entered], timeout: 2)
            XCTAssertEqual(client.samples, 8000); XCTAssertEqual(client.language, "hi"); XCTAssertEqual(client.prompt, "Frozen")
            if cancel { controller.invalidate(); XCTAssertEqual(job.audioCount, 0) }
            let next = PendingOperationQueue.enqueue(previous: chain, operation: PendingOperation(name: "next"), completes: true) { successor = true }
            XCTAssertTrue(controller.activeJob === job); XCTAssertFalse(job.operation.hasExited); XCTAssertFalse(successor)
            client.exit.signal(); await next.value
            XCTAssertTrue(job.operation.hasExited); XCTAssertNil(controller.activeJob); XCTAssertEqual(job.audioCount, 0)
            XCTAssertTrue(successor); XCTAssertEqual(ordinary, 0); XCTAssertTrue(copies.isEmpty)
            if cancel { XCTAssertEqual(controller.view, .empty) }
            else { XCTAssertEqual(controller.view, .preview(job.token, " raw preview \n")) }
            controller.invalidate()
        }
    }
}
