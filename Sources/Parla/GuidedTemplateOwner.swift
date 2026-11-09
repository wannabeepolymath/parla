import Combine
import CryptoKit
import Foundation
import ParlaCore

/// Main-thread owner. Only the per-take work body runs on the existing serial queue.
/// Publication revocation and actual native/converter exit are separate obligations.
final class GuidedTemplateOwner: ObservableObject {
    struct Configuration: Equatable {
        let request: RecognitionRequest
        let inputUID: String?
        let safeStart: Bool
        let consent: UUID?
        let dictionarySignature: Data
        init(_ saved: Settings) {
            var bounded = Settings()
            bounded.recognitionEngine = saved.recognitionEngine; bounded.whisperModelPath = saved.whisperModelPath
            bounded.appleSpeechLocale = saved.appleSpeechLocale; bounded.parakeetModelID = saved.parakeetModelID
            bounded.parakeetLanguageFilter = saved.parakeetLanguageFilter; bounded.language = saved.language
            bounded.recognitionConfigurationInvalid = saved.recognitionConfigurationInvalid
            bounded.dictionary = VocabularyHints.select(saved.dictionary, byteLimit: VocabularyHints.asrBytes)
            request = RecognitionRequest(settings: bounded); inputUID = saved.inputDeviceUID
            safeStart = saved.nativePreparationSafeStartEnabled; consent = saved.nativePreparationConsent
            dictionarySignature = Data(SHA256.hash(data: (try? JSONEncoder().encode(saved.dictionary)) ?? Data()))
        }
    }
    typealias Enqueue = (PendingOperation, @escaping () async -> Void, @escaping () async -> Void) -> Void
    @Published private(set) var session: GuidedTemplateSession?
    @Published private(set) var busy = false
    @Published private(set) var recording = false
    @Published private(set) var message: String?
    @Published private(set) var route = MicrophoneRoute()
    var clock: () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    var date: () -> Date = Date.init
    var schedule: (TimeInterval, @escaping () -> Void) -> (() -> Void) = { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
    var security: () -> Bool = { AppDelegate.automationSecureEvidence() }
    var permission: () -> Bool = { false }
    var allowed: () -> Bool = { false }
    var draftReady: () -> Bool = { false }
    var preparationEpoch: () -> UUID? = { nil }
    var selectionEpoch: () -> UUID = { UUID() }
    var preparationRefusal: (RecognitionRequest) -> String? = { _ in "Recognition unavailable." }
    var operationPreparationRefusal: ((RecognitionRequest, PendingOperation, UUID?, UUID?) -> String?)?
    var discardedPreparationAuthority: ((RecognitionRequest, PendingOperation, UUID?, UUID?) -> String?)?
    var invalidatePriorAuthority: () -> Void = {}
    var suspend: () -> UUID = HotkeyMonitor.acquireSuspension
    var unsuspend: (UUID) -> Void = HotkeyMonitor.releaseSuspension
    var enqueue: Enqueue?
    var factory: (RecognitionRequest) -> RecognitionFactory = { _ in RecognitionFactory() }
    var resident: () -> RecognitionResident? = { nil }
    private weak var store: SettingsStore?
    private var capture: GuidedTemplateCapturing?
    private var admission: CaptureAdmission?
    private var local: LocalCleanupAdmission?
    private var lease: CaptureAdmission.Lease?
    private var suspension: UUID?
    private var lifetime: PendingOperation?
    private var operation: PendingOperation?
    private var discardedTake: (operation: PendingOperation, take: GuidedTemplateSession.Take)?
    private var configuration: Configuration?
    private var frozenPreparation: UUID?, frozenSelection: UUID?
    private var identity: UUID?
    private var barrierOwed = false
    private var cancelExpiry: (() -> Void)?, cancelTakeLimit: (() -> Void)?
    var frozenEngine: RecognitionEngine? { configuration?.request.selection.engine }
    var recognitionSummary: String? {
        guard let request = configuration?.request else { return nil }
        switch request.selection {
        case .whisper: return "Whisper · " + (request.language ?? "Auto-detect")
        case .appleSpeech(let locale): return "Apple Speech · " + locale
        case .parakeet(_, let filter): return "Parakeet · " + (filter ?? "Auto-detect")
        case .invalid: return "Speech recognition unavailable"
        }
    }
    var ownsSession: Bool { lifetime != nil }
    var readyForRestart: Bool { !ownsSession && !busy && !recording && lease == nil && operation == nil }
    func bind(store: SettingsStore, capture: GuidedTemplateCapturing, admission: CaptureAdmission, local: LocalCleanupAdmission) {
        self.store = store; self.capture = capture; self.admission = admission; self.local = local
    }
    func notice(_ text: String) { message = text }

    /// Registers and reserves synchronously BEFORE the first queued await.
    func begin(_ definition: GuidedTemplateDefinition) {
        guard !ownsSession, let store, let capture, let admission, let local, let enqueue else { notice("Wait for the current form to stop."); return }
        guard !security(), draftReady(), allowed(), permission() else { notice("Save your settings, finish dictating, leave any password field and allow the microphone first."); return }
        do {
            let saved = try store.savedRetrySnapshot(), config = Configuration(saved)
            guard saved.guidedTemplates.definitions.contains(definition), config.request.selection.engine != .invalid else { throw GuidedTemplateFailure("Settings changed. Try again.") }
            if let reason = preparationRefusal(config.request) { throw GuidedTemplateFailure(reason) }
            let state = try GuidedTemplateSession(definition: definition, now: clock())
            let registration = PendingOperation(name: "Guided voice form")
            guard MainActor.assumeIsolated({ local.admit(registration) }) else { throw GuidedTemplateFailure("Parla is quitting.") }
            lifetime = registration; identity = state.id
            guard let acquired = admission.acquire(.guidedTemplate) else { dispose(); throw GuidedTemplateFailure("Finish the other recording first.") }
            lease = acquired; suspension = suspend()
            do { try capture.reserve(session: state.id, lease: acquired) }
            catch { dispose(); throw error }
            configuration = config; frozenPreparation = preparationEpoch(); frozenSelection = selectionEpoch()
            session = state; busy = true; barrierOwed = true
            invalidatePriorAuthority()
            let barrier = PendingOperation(name: "Guided form admission barrier")
            message = "Getting ready…"
            cancelExpiry = schedule(1_200) { [weak self] in
                guard self?.identity == state.id else { return }; self?.cancel("Form expired after 20 minutes.")
            }
            enqueue(barrier, {}, { [weak self] in
                await MainActor.run {
                    guard let self, self.identity == state.id else { return }
                    self.barrierOwed = false; self.busy = false
                    if self.session == nil { self.dispose() }
                    else if self.boundary() != nil { self.message = "Ready. Record each field." }
                }
            })
        } catch { notice(error.localizedDescription) }
    }
    /// Security is checked before all other stale/configuration guards.
    @discardableResult func boundary() -> Settings? {
        guard !security() else { cancel("Form canceled because a password field was active."); return nil }
        guard let session, let configuration, let store else { return nil }
        guard !session.isExpired(now: clock()), lifetime?.shouldAbort != true,
              frozenPreparation == preparationEpoch(), frozenSelection == selectionEpoch(),
              let saved = try? store.savedRetrySnapshot(), !saved.recognitionConfigurationInvalid,
              Configuration(saved) == configuration,
              saved.guidedTemplates.definitions.contains(session.definition),
              currentPreparationRefusal(configuration.request) == nil else {
            cancel("Form canceled because settings changed."); return nil
        }
        guard draftReady() else { notice("Wait for your settings to save, then try again."); return nil }
        return saved
    }
    private func isDiscarded(_ attempt: PendingOperation) -> Bool {
        discardedTake?.operation === attempt && session?.take == discardedTake?.take
    }
    private func currentPreparationRefusal(_ request: RecognitionRequest) -> String? {
        if let operation {
            if isDiscarded(operation) {
                if let check = discardedPreparationAuthority {
                    return check(request, operation, frozenSelection, frozenPreparation)
                }
                return preparationRefusal(request)
            }
            // The queue finishes before the owner handoff; this is readiness, not permit reuse.
            if operation.hasExited { return preparationRefusal(request) }
            if let check = operationPreparationRefusal {
                return check(request, operation, frozenSelection, frozenPreparation)
            }
        }
        return preparationRefusal(request)
    }
    func observeSaved() { if session != nil { _ = boundary() } }
    func relevantDraftChanged() { if ownsSession { cancel("Form canceled because settings changed.") } }
    func preparationChanged() { if session != nil { _ = boundary() } }
    func observe(_ event: DictationSession.Event) {
        switch event {
        case .focusSampled(_, .secure), .cleanReady(_, _, _, _, .secure, _), .resultUnavailable(_, .secure): cancel("Form canceled because a password field was active.")
        case .transcribed(_, _, let probe) where probe.focus == .secure: cancel("Form canceled because a password field was active.")
        case .transformReady(_, _, let probe, _, _) where probe.focus == .secure: cancel("Form canceled because a password field was active.")
        default: break
        }
    }
    func start() {
        guard !busy, !recording, boundary() != nil, permission(), var state = session,
              let lease, let capture, let configuration else { return }
        do {
            let take = try state.start(now: clock()); session = state
            try capture.start(session: state.id, capture: take.capture, lease: lease, inputUID: configuration.inputUID)
            recordingCapture = take.capture
            recording = true; route = MicrophoneRoute(); message = "Recording… (up to 30 seconds)"
            cancelTakeLimit = schedule(30) { [weak self] in self?.captureEnded(session: take.session, capture: take.capture) }
        } catch {
            if let take = session?.take { session?.settle(take, text: nil) }
            notice(error.localizedDescription)
        }
    }
    func captureEnded(session id: UUID, capture idCapture: UUID) {
        guard identity == id, session?.take?.capture == idCapture, recording else { return }
        discardTake(); notice("Recording stopped or hit the time limit. Record the field again.")
    }
    func stop() {
        guard recording, let take = session?.take, let lease, let capture, let enqueue, let config = configuration else { return }
        recording = false; recordingCapture = nil; cancelTakeLimit?(); cancelTakeLimit = nil
        guard let audio = capture.stop(session: take.session, capture: take.capture, lease: lease), audio.complete,
              !audio.samples.isEmpty, audio.samples.count <= 480_000, audio.samples.allSatisfy(\.isFinite),
              Pipeline.recognitionSkip(samples: audio.samples) == nil, boundary() != nil else {
            session?.settle(take, text: nil); notice("Nothing was recorded. Record the field again."); return
        }
        route = audio.route; busy = true
        let attempt = PendingOperation(name: "Guided field recognition"); discardedTake = nil; operation = attempt
        let result = ResultBox()
        message = "Transcribing…"
        enqueue(attempt, { [weak self] in
            guard let self else { return }
            do {
                guard await MainActor.run(body: { !attempt.shouldAbort && !self.isDiscarded(attempt) && self.session?.take == take && self.boundary() != nil }) else { return }
                let ports = await MainActor.run { (self.resident(), self.factory(config.request), self.frozenSelection, self.frozenPreparation) }
                attempt.advance(.acquiring)
                let handle = try await RecognitionAcquisition.acquire(request: config.request, resident: ports.0, factory: ports.1,
                    operation: attempt, capture: take.capture, selectionEpoch: ports.2, preparationEpoch: ports.3)
                guard await MainActor.run(body: { !attempt.shouldAbort && !self.isDiscarded(attempt) && self.session?.take == take && self.boundary() != nil }),
                      handle.request == config.request, handle.capture == take.capture, handle.preparationIsCurrent else { return }
                attempt.advance(.recognizing)
                let final = await handle.finalResult(samples: audio.samples, window: nil, shouldAbort: { attempt.shouldAbort }, rawOnly: true)
                guard !attempt.shouldAbort, handle.preparationIsCurrent, case .pass(let pass) = final.provenance,
                      pass.pass == .fullFinal, pass.instance == handle.instance, pass.identity == handle.identity,
                      pass.sampleRange == 0..<audio.samples.count, !pass.canceled,
                      case .completed(let payload) = pass.native,
                      GuidedTemplateDefinitionText.accepts(payload.text) else { return }
                await MainActor.run { if !attempt.shouldAbort, !self.isDiscarded(attempt), self.session?.take == take, self.boundary() != nil { result.text = payload.text } }
            } catch { /* No retry, fallback or retention. Owed completion settles below. */ }
        }, { [weak self] in
            await MainActor.run {
                defer { result.text = nil }
                guard let self, self.operation == attempt else { return }
                let discarded = self.isDiscarded(attempt)
                self.operation = nil; self.discardedTake = nil; self.busy = false
                if self.session != nil, self.boundary() != nil, !attempt.shouldAbort, !discarded {
                    self.session?.settle(take, text: result.text)
                    self.message = result.text == nil ? "No speech recognized. Record the field again." : "Check or edit the text, then accept it."
                } else if self.session != nil { self.session?.settle(take, text: nil) }
                if self.session == nil { self.dispose() }
            }
        })
    }
    private final class ResultBox { var text: String? }
    func discardTake() {
        guard let take = session?.take else { session?.discardCandidate(); return }
        cancelTakeLimit?(); cancelTakeLimit = nil
        if recording, let lease { capture?.clear(session: take.session, capture: take.capture, lease: lease); recording = false }
        if let operation {
            discardedTake = (operation, take) // Before revoke: it synchronously notifies preparation.
            operation.revoke(); operation.requestAbort()
        } else { session?.settle(take, text: nil) }
    }
    func editCandidate(_ text: String) { guard boundary() != nil else { return }; do { try session?.editCandidate(text) } catch { notice(error.localizedDescription) } }
    func accept() { guard !busy, boundary() != nil else { return }; do { try session?.accept() } catch { notice(error.localizedDescription) } }
    func skip() { guard !busy, boundary() != nil else { return }; do { try session?.skip() } catch { notice(error.localizedDescription) } }
    func back() { guard !busy, boundary() != nil else { return }; session?.back() }
    func review() { guard !busy, boundary() != nil else { return }; do { try session?.review() } catch { notice(error.localizedDescription) } }
    func approve(_ id: UUID) { guard !busy, boundary() != nil else { return }; session?.approve(id, date: date()) }
    func copy(using write: (String) -> Void) {
        guard boundary() != nil, let completion = session?.completion else { return }
        write(completion.body); notice("Copied.")
    }
    func save(history: HistoryStore) {
        guard let saved = boundary(), saved.historyEnabled, let state = session, !state.saved, let completion = state.completion else { return }
        history.reload(countLimit: saved.historyTextCount)
        guard boundary() != nil else { return }
        let entry = HistoryEntry(id: completion.id, date: completion.date, raw: completion.body)
        if history.appendReviewed(entry) { session?.markSaved(completion.id); notice("Saved to history.") }
        else { notice("Couldn't save to history. Try again.") }
    }
    func cancel(_ reason: String = "Form canceled.") {
        guard ownsSession else { return }
        lifetime?.revoke(); discardedTake = nil; session = nil // revoke all publication before closing native capture
        cancelExpiry?(); cancelExpiry = nil; cancelTakeLimit?(); cancelTakeLimit = nil
        if recording, let id = identity, let lease {
            // Capture identity is retained separately from the revoked publication state.
            if let activeCapture { capture?.clear(session: id, capture: activeCapture, lease: lease) }
            recording = false
        }
        operation?.revoke(); operation?.requestAbort()
        message = reason
        if !barrierOwed, operation == nil { dispose() } else { busy = true }
    }
    // The capture identity survives publication revocation until synchronous clear joins.
    private var activeCapture: UUID? { session?.take?.capture ?? recordingCapture }
    private var recordingCapture: UUID?
    private func dispose() {
        guard !barrierOwed, operation == nil, !recording else { return }
        if let id = identity, let lease { capture?.release(session: id, lease: lease); admission?.release(lease) }
        if let suspension { unsuspend(suspension) }
        if let lifetime { lifetime.finish(); MainActor.assumeIsolated { local?.exited(lifetime) } }
        cancelExpiry?(); cancelExpiry = nil; cancelTakeLimit?(); cancelTakeLimit = nil
        lease = nil; suspension = nil; lifetime = nil; identity = nil; configuration = nil
        frozenPreparation = nil; frozenSelection = nil; recordingCapture = nil; discardedTake = nil; session = nil; busy = false; route = MicrophoneRoute()
    }
}

private enum GuidedTemplateDefinitionText {
    static func accepts(_ text: String) -> Bool { text.utf8.count <= 8_192 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
