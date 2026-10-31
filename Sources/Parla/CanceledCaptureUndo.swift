import AppKit
import ParlaCore

/// UI contains opaque authority and (only in preview) bounded text, never audio.
enum CanceledCaptureView: Equatable {
    case empty, offer(UUID), processing(UUID), preview(UUID, String)
    var token: UUID? {
        switch self { case .empty: return nil; case .offer(let t), .processing(let t), .preview(let t, _): return t }
    }
}

/// The queue captures this box, never a separately captured sample array. A native
/// borrower can outlive revocation; its serial barrier must run to actual exit.
final class CanceledCaptureJob: @unchecked Sendable {
    let token: UUID, epoch: UUID
    let generation: Int
    let request: RecognitionRequest
    let operation = PendingOperation(name: "Canceled capture preview") // no diagnostic store
    let startDeadline: TimeInterval, publicationDeadline: TimeInterval
    private let lock = NSLock()
    private var audio: [Float]?
    private let now: () -> TimeInterval
    var startedASR = false // main only
    init(token: UUID, epoch: UUID, generation: Int, request: RecognitionRequest, samples: [Float], now: @escaping () -> TimeInterval) {
        self.token = token; self.epoch = epoch; self.generation = generation; self.request = request
        audio = samples; self.now = now
        let accepted = now(); startDeadline = accepted + 15; publicationDeadline = accepted + 30
    }
    var shouldAbort: Bool { operation.shouldAbort || now() >= publicationDeadline }
    var audioCount: Int { lock.withLock { audio?.count ?? 0 } }
    func releaseAudio() { lock.withLock { audio = nil } }
    func transcript(_ handle: RecognitionHandle) async -> String? {
        let borrowed = lock.withLock { audio }
        guard let borrowed, !shouldAbort else { return nil }
        return await handle.finalResult(samples: borrowed, window: nil, shouldAbort: { self.shouldAbort }, rawOnly: true).text
    }
}

/// One main-thread logical owner. No recorder, storage, model, provider or field
/// capability is held here. Boundary probes are security-only and never prompt.
final class CanceledCaptureUndoController {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private struct Capture {
        let operation: UUID, generation: Int, epoch: UUID, request: RecognitionRequest
        var acknowledged = false
    }
    private struct Offer {
        let token: UUID, epoch: UUID, generation: Int, request: RecognitionRequest, expires: TimeInterval
        var samples: [Float]
    }
    private struct Preview { let token: UUID, generation: Int, text: String, expires: TimeInterval }
    private let configuration: () -> Settings?
    private let generation: () -> Int
    private let security: () -> OriginalCopySecurity
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let copy: (String) -> Void
    var render: (CanceledCaptureView) -> Void = { _ in }
    var enqueue: (CanceledCaptureJob) -> Void = { _ in }
    private(set) var view: CanceledCaptureView = .empty
    private var epoch = UUID()
    private var capture: Capture?
    private var offer: Offer?
    private var preview: Preview?
    private(set) var activeJob: CanceledCaptureJob?
    private var cancelExpiry: (() -> Void)?, cancelMonitor: (() -> Void)?, cancelStart: (() -> Void)?
    private var expiryID = UUID()
    private var shuttingDown = false
    private var shutdownCanceled = false
    var retainedAudioCount: Int { (offer?.samples.count ?? 0) + (activeJob?.audioCount ?? 0) }

    init(configuration: @escaping () -> Settings?, generation: @escaping () -> Int,
         security: @escaping () -> OriginalCopySecurity,
         now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         schedule: @escaping Schedule = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return { item.cancel() }
         }, copy: @escaping (String) -> Void) {
        self.configuration = configuration; self.generation = generation; self.security = security
        self.now = now; self.schedule = schedule; self.copy = copy
    }
    private func configured() -> Bool {
        guard !shuttingDown, let settings = configuration() else { return false }
        return settings.canceledCaptureUndoEnabled && settings.outputMode != .selectedPreset
    }
    private func show(_ value: CanceledCaptureView) { view = value; render(value) }
    func invalidate() {
        precondition(Thread.isMainThread)
        epoch = UUID(); expiryID = UUID(); capture = nil; offer = nil; preview = nil
        activeJob?.operation.revoke(); activeJob?.releaseAudio()
        cancelExpiry?(); cancelExpiry = nil; cancelMonitor?(); cancelMonitor = nil
        cancelStart?(); cancelStart = nil
        if view != .empty { show(.empty) }
        activeJob?.operation.requestAbort() // retain drain bookkeeping until real exit
    }
    func observe(_ event: DictationSession.Event) {
        switch event {
        case .focusSampled(_, .secure), .cleanReady(_, _, _, _, .secure, _): invalidate()
        case .transcribed(_, _, let probe) where probe.focus == .secure: invalidate()
        case .transformReady(_, _, let probe, _, _) where probe.focus == .secure: invalidate()
        case .resultUnavailable(_, .secure): invalidate()
        default: break
        }
    }
    func shutdown() { shuttingDown = true; shutdownCanceled = false; invalidate() }
    func quitCanceled() { if shuttingDown { shutdownCanceled = true } }
    /// A canceled quit never restores prior authority. Only deliberate new input
    /// can leave shutdown mode, and it still needs fresh start-latched permission.
    func deliberateEntry() {
        invalidate()
        if shutdownCanceled { shuttingDown = false; shutdownCanceled = false }
    }
    func configurationChanged(valid: Bool = true) {
        if !valid || !configured() { invalidate() }
    }
    func accepted(_ session: DictationSession.Session, physical: Bool) {
        invalidate() // direct/automation entry defense before recorder/model effects
        let acceptedEpoch = epoch
        guard physical, configured(), session.settings.canceledCaptureUndoEnabled,
              session.delivery == .keyboard, !session.live, session.mode == .dictation,
              session.settings.outputMode != .selectedPreset, !session.operation.shouldAbort,
              CanceledCaptureLimits.accepts(session.recognition), security() == .safe else { return }
        guard epoch == acceptedEpoch, generation() == session.gen, configured(), !session.operation.shouldAbort else { return }
        capture = Capture(operation: session.operation.id, generation: session.gen, epoch: epoch, request: session.recognition)
    }
    func acknowledged(_ session: DictationSession.Session) {
        if capture?.operation == session.operation.id, capture?.generation == session.gen { capture?.acknowledged = true }
    }
    /// Called at the accepted cancel event, before any abort/stop can stall.
    func cancellationDeadline() -> TimeInterval { now() + 3 }
    func permitsTransfer(_ context: DictationSession.CanceledCapture, deadline: TimeInterval) -> Bool {
        guard let capture, capture.operation == context.operation.id, capture.generation == context.generation,
              capture.epoch == epoch, capture.request == context.request, capture.acknowledged,
              context.reason.permitsUndo, generation() == context.generation + 1,
              activeJob == nil, now() < deadline, configured() else { return false }
        guard security() == .safe else { return false }
        return self.capture?.operation == context.operation.id && self.capture?.epoch == epoch
            && generation() == context.generation + 1 && now() < deadline && configured() && activeJob == nil
    }
    func transferred(_ samples: [Float]?, context: DictationSession.CanceledCapture, deadline: TimeInterval) {
        guard capture?.operation == context.operation.id else { return }
        guard let samples, permitsTransfer(context, deadline: deadline),
              CanceledCaptureLimits.accepts(samples, elapsed: 0) else {
            if capture?.operation == context.operation.id { capture = nil }
            return
        }
        let token = UUID()
        offer = Offer(token: token, epoch: epoch, generation: generation(), request: context.request, expires: deadline, samples: samples)
        capture = nil
        armExpiry(token: token, deadline: deadline)
        monitor(token: token)
    }
    /// Interpreter calls this after the ordinary cancellation hide/toast effects.
    func present(generation canceledGeneration: Int) {
        guard let offer, offer.generation == canceledGeneration + 1, validOffer(offer.token) else { return }
        show(.offer(offer.token))
    }
    private func validOffer(_ token: UUID) -> Bool {
        guard let offer, offer.token == token, offer.epoch == epoch else { return false }
        guard offer.generation == generation(), now() < offer.expires, configured() else { invalidate(); return false }
        let safe = security() == .safe
        guard self.offer?.token == token, epoch == offer.epoch else { return false }
        guard safe, offer.generation == generation(), now() < offer.expires, configured() else { invalidate(); return false }
        return true
    }
    func undo(token: UUID) {
        guard offer?.token == token, validOffer(token), let offered = offer else { return }
        offer = nil; cancelExpiry?(); cancelExpiry = nil
        let job = CanceledCaptureJob(token: token, epoch: epoch, generation: offered.generation,
            request: offered.request, samples: offered.samples, now: now)
        activeJob = job; show(.processing(token))
        armExpiry(token: token, deadline: job.publicationDeadline)
        cancelStart = schedule(max(0, job.startDeadline - now())) { [weak self, weak job] in
            guard let self, let job, self.activeJob === job, self.epoch == job.epoch, !job.startedASR else { return }
            if self.now() >= job.startDeadline { self.invalidate() }
        }
        enqueue(job)
    }
    func authorize(_ job: CanceledCaptureJob, startingASR: Bool = false) -> Bool {
        guard activeJob === job, epoch == job.epoch else { return false }
        guard generation() == job.generation, !job.shouldAbort, configured(),
              !startingASR || now() < job.startDeadline else { invalidate(); return false }
        let safe = security() == .safe
        guard activeJob === job, epoch == job.epoch else { return false }
        guard safe, generation() == job.generation, !job.shouldAbort, configured(),
              !startingASR || now() < job.startDeadline else { invalidate(); return false }
        return true
    }
    func beginASR(_ job: CanceledCaptureJob) -> Bool {
        guard authorize(job, startingASR: true) else { return false }
        job.startedASR = true
        cancelStart?(); cancelStart = nil
        return true
    }
    func publish(_ text: String?, job: CanceledCaptureJob) {
        job.releaseAudio()
        guard epoch == job.epoch, activeJob === job else { return }
        guard authorize(job) else { return }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16_384 else { invalidate(); return }
        let deadline = now() + 30
        preview = Preview(token: job.token, generation: job.generation, text: text, expires: deadline)
        show(.preview(job.token, text)); armExpiry(token: job.token, deadline: deadline)
    }
    /// Also runs for queue jobs skipped before their work closure is entered.
    func exited(_ job: CanceledCaptureJob) {
        job.releaseAudio()
        guard activeJob === job else { return }
        activeJob = nil
        if epoch == job.epoch, preview?.token != job.token { invalidate() }
    }
    func discard(token: UUID) { if view.token == token { invalidate() } }
    @discardableResult func copyPreview(token: UUID) -> Bool {
        guard preview?.token == token, let value = preview else { return false }
        let copyEpoch = epoch
        guard value.generation == generation(), now() < value.expires, configured() else { invalidate(); return false }
        let safe = security() == .safe
        guard epoch == copyEpoch, preview?.token == token else { return false }
        guard safe, value.generation == generation(), now() < value.expires, configured() else { invalidate(); return false }
        copy(value.text); return true
    }
    private func armExpiry(token: UUID, deadline: TimeInterval) {
        cancelExpiry?()
        let id = UUID(); expiryID = id
        cancelExpiry = schedule(max(0, deadline - now())) { [weak self] in
            guard let self, self.expiryID == id, self.view.token == token || self.offer?.token == token else { return }
            if self.now() >= deadline { self.invalidate() }
        }
    }
    private func monitor(token: UUID) {
        cancelMonitor?()
        cancelMonitor = schedule(0.2) { [weak self] in
            guard let self, self.offer?.token == token || self.view.token == token else { return }
            let observedEpoch = self.epoch
            let safe = self.configured() && self.security() == .safe
            guard self.epoch == observedEpoch, self.offer?.token == token || self.view.token == token else { return }
            guard safe,
                  self.offer.map({ self.now() < $0.expires && $0.generation == self.generation() }) ?? true,
                  self.preview.map({ self.now() < $0.expires && $0.generation == self.generation() }) ?? true,
                  self.activeJob.map({ !$0.shouldAbort && ($0.startedASR || self.now() < $0.startDeadline) && $0.generation == self.generation() }) ?? true
            else { self.invalidate(); return }
            self.monitor(token: token)
        }
    }
    deinit { cancelExpiry?(); cancelMonitor?(); cancelStart?() }
}

/// Shared production cancellation seam: revoked operation authority is deliberately
/// unnecessary for owned disposal. Native generation and operation identity own it.
final class CanceledCaptureCancellationExecutor {
    let controller: CanceledCaptureUndoController
    private let ownedGeneration: () -> Int
    private let transfer: (UUID, Bool) -> [Float]?
    init(controller: CanceledCaptureUndoController, ownedGeneration: @escaping () -> Int,
         transfer: @escaping (UUID, Bool) -> [Float]?) {
        self.controller = controller; self.ownedGeneration = ownedGeneration; self.transfer = transfer
    }
    func execute(_ context: DictationSession.CanceledCapture, deadline: TimeInterval) {
        guard ownedGeneration() == context.generation else { return }
        let retain = controller.permitsTransfer(context, deadline: deadline)
        let samples = transfer(context.operation.id, retain)
        controller.transferred(samples, context: context, deadline: deadline)
    }
}

/// Only read-only installed metadata qualifies this origin. Never calls the
/// cache-writing verifyInstalled, hashes/downloads a substitute, or changes model.
enum CanceledCaptureModel {
    static func verified(_ request: RecognitionRequest, cache: VerifiedCache = VerifiedCache(), directory: URL = ModelCatalog.directory) -> Bool {
        guard request.selection.engine == .whisper else { return false }
        let url = URL(fileURLWithPath: request.modelPath)
        return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && ModelCatalog.model(atPath: request.modelPath) != nil && cache.isVerified(url)
    }
}

/// Distinct typed origin on the actual shared queue. Ordinary finalization's
/// capabilities are not passed to the Undo runner.
enum DictationExecutionOrigin {
    case ordinary(DictationSession.Session, samples: [Float], ledger: String)
    case canceledCaptureUndo(CanceledCaptureJob)
}
final class DictationExecutionDispatcher {
    private let makePreview: () -> CanceledCaptureRecognition
    lazy var preview = makePreview()
    private let ordinary: (DictationSession.Session, [Float], String) async -> Void
    init(preview: CanceledCaptureRecognition, ordinary: @escaping (DictationSession.Session, [Float], String) async -> Void) {
        makePreview = { preview }; self.ordinary = ordinary
    }
    init(makePreview: @escaping () -> CanceledCaptureRecognition, ordinary: @escaping (DictationSession.Session, [Float], String) async -> Void) {
        self.makePreview = makePreview; self.ordinary = ordinary
    }
    func enqueue(_ origin: DictationExecutionOrigin, previous: Task<Void, Never>?, finished: @escaping () async -> Void = {}) -> Task<Void, Never> {
        switch origin {
        case .ordinary(let session, let samples, let ledger):
            return PendingOperationQueue.enqueue(previous: previous, operation: session.operation, completes: true,
                work: { await self.ordinary(session, samples, ledger) }, finished: finished)
        case .canceledCaptureUndo(let job):
            return PendingOperationQueue.enqueue(previous: previous, operation: job.operation, completes: true,
                work: { await self.preview.run(job) }, finished: {
                    await MainActor.run { self.preview.controller.exited(job) }
                    await finished()
                })
        }
    }
}
final class CanceledCaptureRecognition {
    let controller: CanceledCaptureUndoController
    private let resident: () async -> (String?, RecognitionClient?)
    private let verify: (RecognitionRequest) -> Bool
    private let load: ((String) throws -> RecognitionClient)?
    private let typedResident: () async -> RecognitionResident?
    private let factory: RecognitionFactory
    private let preparationRefused: (PreparationRefusal) -> Void
    init(controller: CanceledCaptureUndoController,
         resident: @escaping () async -> (String?, RecognitionClient?) = { (nil, nil) },
         typedResident: @escaping () async -> RecognitionResident? = { nil },
         factory: RecognitionFactory = RecognitionFactory(),
         preparationRefused: @escaping (PreparationRefusal) -> Void = { _ in },
         verify: @escaping (RecognitionRequest) -> Bool = { CanceledCaptureModel.verified($0) },
         load: ((String) throws -> RecognitionClient)? = nil) {
        self.controller = controller; self.resident = resident; self.verify = verify; self.load = load
        self.typedResident = typedResident; self.factory = factory
        self.preparationRefused = preparationRefused
    }
    func run(_ job: CanceledCaptureJob) async {
        defer { job.releaseAudio() }
        guard job.request.selection.engine == .whisper else { return }
        guard await MainActor.run(body: { controller.authorize(job) }) else { return }
        let (path, client) = await resident()
        guard await MainActor.run(body: { controller.authorize(job, startingASR: true) }), !job.shouldAbort else { return }
        guard verify(job.request), !job.shouldAbort else { return }
        guard await MainActor.run(body: { controller.authorize(job, startingASR: true) }), !job.shouldAbort else { return }
        do {
            guard verify(job.request), !job.shouldAbort else { return }
            let handle: RecognitionHandle
            if let load { // Existing generic-client test seam; production always uses the default factory below.
                handle = try RecognitionHandle(request: job.request, residentPath: path, resident: client) { path in
                    guard !job.shouldAbort else { throw CancellationError() }
                    return try load(path)
                }
            } else {
                let owner = await typedResident()
                handle = try await factory.acquire(request: job.request, resident: owner, policy: .readOnlyCatalog,
                    shouldAbort: { job.shouldAbort }, capture: job.operation.id, operation: job.operation)
            }
            guard await MainActor.run(body: { controller.beginASR(job) }), !job.shouldAbort else { return }
            let raw = await job.transcript(handle)
            job.releaseAudio()
            guard await MainActor.run(body: { controller.authorize(job) }) else { return }
            await MainActor.run { controller.publish(raw, job: job) }
        } catch {
            if let reason = error as? PreparationRefusal { await MainActor.run { preparationRefused(reason) } }
            // No waiting job, hidden retry, storage, provider or delivery capability.
        }
    }
}

/// Actual NSButton targets, testable without constructing a native panel. Each
/// button carries the token from its own paint; a stale button never uses new UI.
final class CanceledCaptureButton: NSButton {
    var captureToken: UUID?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class CanceledCaptureHUDActions: NSObject {
    private let controller: CanceledCaptureUndoController
    init(_ controller: CanceledCaptureUndoController) { self.controller = controller }
    enum Action { case undo, copy, discard }
    func bind(_ button: CanceledCaptureButton, action: Action, token: UUID?) {
        button.captureToken = token; button.target = self
        switch action {
        case .undo: button.action = #selector(undo(_:)); button.setAccessibilityLabel("Undo capture cancellation")
        case .copy: button.action = #selector(copy(_:)); button.setAccessibilityLabel("Copy canceled capture transcript")
        case .discard: button.action = #selector(discard(_:)); button.setAccessibilityLabel("Discard canceled capture")
        }
    }
    @objc func undo(_ sender: CanceledCaptureButton) { if let token = sender.captureToken { controller.undo(token: token) } }
    @objc func discard(_ sender: CanceledCaptureButton) { if let token = sender.captureToken { controller.discard(token: token) } }
    @objc func copy(_ sender: CanceledCaptureButton) { if let token = sender.captureToken { controller.copyPreview(token: token) } }
}
