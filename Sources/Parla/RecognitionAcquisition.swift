import Foundation
import ParlaCore

/// Small acquisition body on AppDelegate's existing processTask chain. No queue or dispatcher here.
enum RecognitionAcquisition {
    enum Role { case final, preview }
    /// A nonisolated async body runs on the generic executor even when entered from main-actor UI.
    /// It stays inside the awaited processTask child; no new queue or cancellable barrier is created.
    static func prepareOffMain(request: RecognitionRequest, resident: RecognitionResident?, factory: RecognitionFactory,
                               operation: PendingOperation, selectionEpoch: UUID? = nil, preparationEpoch: UUID? = nil) async throws -> RecognitionHandle {
        try await prepare(request: request, resident: resident, factory: factory, operation: operation,
            selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch)
    }
    /// Enabled setup and Retry use this one serial work body, with no nested processTask append.
    static func prepare(request: RecognitionRequest, resident: RecognitionResident?, factory: RecognitionFactory,
                        operation: PendingOperation, selectionEpoch: UUID? = nil, preparationEpoch: UUID? = nil) async throws -> RecognitionHandle {
        let handle = try await acquire(request: request, resident: resident, factory: factory, operation: operation,
            selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch)
        guard request.selection.engine == .whisper else { return handle }
        guard !operation.shouldAbort else { throw CancellationError() }
        let result = await handle.recognize([Float](repeating: 0, count: 16_000), pass: .warmup, shouldAbort: { operation.shouldAbort })
        guard case .completed = result.native, !result.canceled, handle.preparationIsCurrent else {
            throw factory.preparation?.snapshot.refusal ?? PreparationRefusal.revoked
        }
        return handle
    }
    static func acquire(request: RecognitionRequest, resident: RecognitionResident?,
                        factory: RecognitionFactory, operation: PendingOperation? = nil,
                        capture: UUID = UUID(), policy: RecognitionAdmission = .standard,
                        selectionEpoch: UUID? = nil, preparationEpoch: UUID? = nil,
                        role: Role = .final, phaseAborted: (() -> Bool)? = nil) async throws -> RecognitionHandle {
        try await factory.acquire(request: request, resident: resident, policy: policy,
            shouldAbort: { operation?.shouldAbort == true || phaseAborted?() == true },
            diagnostics: role == .final ? operation?.diagnostics : nil, capture: capture,
            operation: operation, selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch)
    }
    static func mayPromote(_ handle: RecognitionHandle, global: RecognitionRequest,
                           epoch: UUID, currentEpoch: UUID, current: RecognitionRequest,
                           factory: RecognitionFactory) -> Bool {
        guard handle.request.selection.engine == .whisper, handle.preparationIsCurrent, epoch == currentEpoch, global == current, handle.request == global,
              let identity = handle.identity,
              let observed = try? factory.resolve(current) else { return false }
        // A fresh custom acquisition may become resident, but may never be borrowed by a later acquisition.
        return identity.engine == observed.engine && identity.selection == observed.selection
            && identity.artifact == observed.artifact && identity.generation == observed.generation
            && identity.runtime == observed.runtime
    }
    /// The actual tryout queue/completion hook. Cancellation revokes publication,
    /// while the existing queue retains acquisition/worker/IO through actual exit.
    static func enqueueTryout(previous: Task<Void, Never>?, operation: PendingOperation,
                              work: @escaping () async -> String,
                              current: @escaping @MainActor () -> Bool,
                              done: @escaping @MainActor (String) -> Void,
                              finished: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        PendingOperationQueue.enqueue(previous: previous, operation: operation, completes: true, work: {
            let text = await work()
            await MainActor.run {
                guard !operation.shouldAbort, current() else { return }
                done(text)
            }
        }, finished: { await finished() })
    }
    /// Tryout intentionally acquires before the floor, and maps failure/empty to an empty display.
    static func tryout(samples: [Float], request: RecognitionRequest, resident: RecognitionResident?,
                       factory: RecognitionFactory, operation: PendingOperation? = nil, selectionEpoch: UUID? = nil, preparationEpoch: UUID? = nil,
                       refused: (PreparationRefusal) -> Void = { _ in }) async -> String {
        let handle: RecognitionHandle
        do { handle = try await acquire(request: request, resident: resident, factory: factory, operation: operation, selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch) }
        catch { if let reason = error as? PreparationRefusal { refused(reason) }; return "" }
        guard operation?.shouldAbort != true, Pipeline.recognitionSkip(samples: samples) == nil else { return "" }
        let result = await handle.recognize(samples, pass: .fullFinal, shouldAbort: { operation?.shouldAbort == true })
        guard operation?.shouldAbort != true else { return "" }
        return result.text ?? ""
    }
}
