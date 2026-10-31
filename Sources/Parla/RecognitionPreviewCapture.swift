import Foundation
import ParlaCore

/// One capture body, awaited by the existing processTask lane. No output/storage
/// ports and no native owner survives run(). Stop revokes only this phase.
final class RecognitionPreviewCapture {
    /// One production security binding shared with isolated capture tests.
    static func secureEvidence(_ probe: @escaping @MainActor () -> Bool,
                               shadow: ActivityShadowPermission?) -> @MainActor () -> Bool {
        {
            let secure = probe()
            if secure { shadow?.revoke() }
            return secure
        }
    }

    let plan: RecognitionPreviewPlan
    let operation: PendingOperation
    let factory: RecognitionFactory
    let selectionEpoch: UUID
    let preparationEpoch: UUID?
    private let capturing: () -> Bool
    private let suffix: (UUID) -> RecognitionPreviewSuffix?
    private let secure: @MainActor () -> Bool
    private let publish: @MainActor (RecognitionPreviewUpdate) -> Void
    private let clear: @MainActor () -> Void
    private let releaseAliases: () async -> Void
    private let clock: () -> TimeInterval
    private let pause: () async -> Void

    init(plan: RecognitionPreviewPlan, operation: PendingOperation, factory: RecognitionFactory,
         selectionEpoch: UUID, preparationEpoch: UUID?, capturing: @escaping () -> Bool,
         suffix: @escaping (UUID) -> RecognitionPreviewSuffix?,
         secure: @escaping @MainActor () -> Bool,
         publish: @escaping @MainActor (RecognitionPreviewUpdate) -> Void,
         clear: @escaping @MainActor () -> Void,
         releaseAliases: @escaping () async -> Void,
         clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         pause: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 50_000_000) }) {
        self.plan = plan; self.operation = operation; self.factory = factory
        self.selectionEpoch = selectionEpoch; self.preparationEpoch = preparationEpoch
        self.capturing = capturing; self.suffix = suffix; self.secure = secure
        self.publish = publish; self.clear = clear; self.releaseAliases = releaseAliases
        self.clock = clock; self.pause = pause
    }
    var aborted: Bool {
        !plan.phase.isCurrent || operation.shouldAbort || !capturing()
            || preparationEpoch != factory.preparation?.admissionEpoch
    }
    @MainActor func preparationChanged(_ currentEpoch: UUID?) {
        if preparationEpoch != currentEpoch { revoke() }
    }
    @MainActor func revoke() { plan.phase.revoke(); clear() }

    private func deliver(_ update: RecognitionPreviewUpdate) async {
        guard !aborted else { return }
        await MainActor.run {
            guard !self.aborted else { return }
            guard !self.secure() else { self.revoke(); return }
            self.publish(update)
        }
    }
    private func status(_ value: RecognitionPreviewStatus) async {
        operation.diagnostics?.update { $0.preview?.status = value }
        await deliver(.status(value))
    }
    func run() async {
        operation.diagnostics?.update { $0.preview = DiagnosticPreview(modelID: plan.modelID) }
        let lifetime = operation.diagnostics?.begin(.previewLifetime)
        defer { lifetime?.end() }
        guard !aborted, let request = plan.preview else {
            if !aborted { await status(.unavailable) }; return
        }
        await status(.loading)
        guard !aborted else { return }
        var handle: RecognitionHandle?
        do {
            let span = operation.diagnostics?.begin(.previewAcquisition)
            defer { span?.end() }
            // Validate both installed owned choices before evicting the old resident.
            _ = try factory.resolve(plan.final)
            _ = try factory.resolve(request)
            guard !aborted else { return }
            await releaseAliases()
            guard !aborted else { return }
            handle = try await RecognitionAcquisition.acquire(request: request, resident: nil,
                factory: factory, operation: operation, capture: plan.operationID,
                selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch,
                role: .preview, phaseAborted: { self.aborted })
        } catch {
            await status(.unavailable); return
        }
        // Even an uncancellable constructor cannot publish after revocation.
        guard !aborted else { handle = nil; return }
        await status(.ready)
        var lastCount = 0, requests = 0
        var lastStart = -TimeInterval.infinity
        while !aborted {
            if requests == RecognitionPreviewLimits.requests {
                await status(.limitReached); break
            }
            guard clock() - lastStart >= RecognitionPreviewLimits.interval else { await pause(); continue }
            // Scope copied PCM to one pass. No queued or accumulated snapshots.
            if let count = await pass(handle: handle!, lastCount: lastCount, requestStarted: {
                lastStart = self.clock(); requests += 1
            }) { lastCount = count }
            guard !aborted else { break }
            await pause()
        }
        handle = nil // actual native exit and destruction precede the next queue child
    }
    private func pass(handle: RecognitionHandle, lastCount: Int, requestStarted: () -> Void) async -> Int? {
        guard !aborted else { return nil }
        let allowed = await MainActor.run { () -> Bool in
            guard !self.aborted else { return false }
            guard !self.secure() else { self.revoke(); return false }
            return true
        }
        guard allowed, !aborted, let snapshot = suffix(plan.operationID),
              snapshot.totalCount - lastCount >= RecognitionPreviewLimits.newSamples else { return nil }
        requestStarted()
        operation.diagnostics?.update {
            guard var preview = $0.preview else { return }
            preview.requests += 1
            preview.maximumSamples = max(preview.maximumSamples, snapshot.samples.count)
            $0.preview = preview
        }
        let span = operation.diagnostics?.begin(.previewASR)
        let result = await handle.recognize(snapshot.samples, pass: .hudPreview, sampleRange: snapshot.range,
            shouldAbort: { self.aborted })
        span?.end()
        guard !aborted else { return snapshot.totalCount }
        if let text = result.text, !text.isEmpty {
            await deliver(.draft(RecognitionPreviewLimits.displaySuffix(text), englishOnly: plan.englishOnly))
        } else { await status(result.text == nil ? .unavailable : .empty) }
        return snapshot.totalCount
    }
    /// Called only inside OrdinaryDictationFinalization.run's prepare closure,
    /// after run() really exited on the same lane. No resident can be borrowed.
    func acquireFinal() async throws -> RecognitionHandle {
        plan.phase.revoke()
        await releaseAliases()
        return try await RecognitionAcquisition.acquire(request: plan.final, resident: nil,
            factory: factory, operation: operation, capture: plan.operationID,
            selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch)
    }
}
