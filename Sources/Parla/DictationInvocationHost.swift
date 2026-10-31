import Foundation
import ParlaCore

/// The shared keyboard/mouse/automation admission and completion seam. Native probes
/// and the existing interpreter are injected; this never constructs a recorder.
@MainActor final class DictationInvocationHost: AutomationHost {
    let inputAuthority: PhysicalInputAuthority
    let captureAdmission: CaptureAdmission
    let machine: DictationSession
    let broker: AutomationBroker
    let results: DictationResultStore
    private let settings: () -> Settings?
    private let captureCleanupGrant: (Settings, CleanupFailoverOrigin) -> CleanupFailoverGrant?
    private let ordinaryBusyReason: () -> String?
    private let busyFeedback: (String) -> Void
    private let configured: (Settings) -> Bool
    private let capabilities: (RecognitionRequest) -> AutomationFailure?
    private let secure: () -> Bool
    private let keyboardAllowed: () -> Bool
    private let automationAllowed: () -> Bool
    private let explicitEntry: () -> Void
    private let deliberateASREntry: (RecognitionRequest) -> Void
    private let send: (DictationSession.Event) -> Void
    private let invalidateOriginal: () -> Void
    private let invalidateCanceledCapture: () -> Void
    private let captureAccepted: (DictationSession.Session, Bool) -> Void
    private var physicalStartInProgress = false
    private var pendingMouse: MousePress?
    private var mouseOwner: (press: MousePress, session: DictationSession.Session)?
    private var eligibility: (operation: UUID, epoch: UInt64)?
    private(set) var tryoutActive = false
    private var tryoutSuspension: UUID?
    private var shortcut: (lease: CaptureAdmission.Lease, suspension: UUID)?

    init(machine: DictationSession, inputAuthority: PhysicalInputAuthority = PhysicalInputAuthority(), captureAdmission: CaptureAdmission = CaptureAdmission(), broker: AutomationBroker, results: DictationResultStore,
         settings: @escaping () -> Settings?,
         captureCleanupGrant: @escaping (Settings, CleanupFailoverOrigin) -> CleanupFailoverGrant? = { _, _ in nil },
         configured: @escaping (Settings) -> Bool,
         capabilities: @escaping (RecognitionRequest) -> AutomationFailure?, secure: @escaping () -> Bool,
         keyboardAllowed: @escaping () -> Bool, automationAllowed: @escaping () -> Bool,
         explicitEntry: @escaping () -> Void, send: @escaping (DictationSession.Event) -> Void,
         deliberateASREntry: @escaping (RecognitionRequest) -> Void = { _ in },
         invalidateOriginal: @escaping () -> Void = {},
         invalidateCanceledCapture: @escaping () -> Void = {},
         captureAccepted: @escaping (DictationSession.Session, Bool) -> Void = { _, _ in },
         ordinaryBusyReason: @escaping () -> String? = { nil }, busyFeedback: @escaping (String) -> Void = { _ in }) {
        self.ordinaryBusyReason = ordinaryBusyReason; self.busyFeedback = busyFeedback
        self.captureCleanupGrant = captureCleanupGrant
        self.invalidateCanceledCapture = invalidateCanceledCapture; self.captureAccepted = captureAccepted
        self.inputAuthority = inputAuthority
        self.captureAdmission = captureAdmission; self.machine = machine; self.broker = broker; self.results = results; self.settings = settings
        self.configured = configured; self.capabilities = capabilities; self.secure = secure
        self.keyboardAllowed = keyboardAllowed; self.automationAllowed = automationAllowed
        self.deliberateASREntry = deliberateASREntry
        self.explicitEntry = explicitEntry; self.send = send; self.invalidateOriginal = invalidateOriginal
    }
    deinit {
        if let tryoutSuspension { HotkeyMonitor.releaseSuspension(tryoutSuspension) }
        if let shortcut { captureAdmission.release(shortcut.lease); HotkeyMonitor.releaseSuspension(shortcut.suspension) }
    }
    func secureEvidence() -> Bool { secure() }
    func startAutomation() -> AutomationFailure? {
        if ordinaryBusyReason() != nil { return .busy }
        invalidateCanceledCapture()
        guard automationAllowed() else { return .unavailable }
        guard captureAdmission.isAvailable, !machine.isCapturing, !tryoutActive else { return .busy }
        guard !secure() else { invalidateOriginal(); results.clear(); return .secure }
        guard var snapshot = settings() else { return .unavailable }
        // FIRST delivery is result-only; selected-text/dictated presets are refused.
        guard snapshot.outputMode != .selectedPreset else { return .unsupportedOutputMode }
        snapshot.profiles = []
        snapshot.streamPreviewEnabled = false
        let request = RecognitionRequest(settings: snapshot)
        deliberateASREntry(request)
        if let failure = capabilities(request) { return failure }
        // Migration is an explicit request boundary; never on passive bootstrap.
        explicitEntry()
        // Migration may have removed legacy decode-only credentials. Keep every
        // recognition/output setting frozen while retaining migration refusal on failure.
        if let migrated = settings() {
            snapshot.anthropicApiKey = migrated.anthropicApiKey
            snapshot.cleanup.apiKey = migrated.cleanup.apiKey
        }
        send(.startAutomation(settings: snapshot, cleanupConfigured: configured(snapshot),
            cleanupFailoverGrant: captureCleanupGrant(snapshot, .shortcutsOrdinary)))
        synchronizeInput()
        return nil
    }
    /// Existing AX/modifier/selection sampling remains in the keyboard adapter.
    /// Only starts preempt; an old key-up never stops an automation reservation.
    @discardableResult func keyboard(_ event: DictationSession.Event) -> Bool {
        if case .startDictation = event, let reason = ordinaryBusyReason() { busyFeedback(reason); return false }
        switch event {
        case .startDictation, .startCommand, .startSavedPreset:
            guard captureAdmission.allowsKeyboard, keyboardAllowed(), !tryoutActive else { return false }
            invalidateCanceledCapture()
            inputAuthority.invalidateQueuedMouseStarts()
            cancelOwnedMouse()
            broker.preempt()
            explicitEntry()
        case .stopRequested, .cancelRequested, .handsFreeLatched:
            switch machine.state {
            case .starting(let s), .recording(let s):
                guard s.delivery == .keyboard, mouseOwner?.session.operation != s.operation else { return false }
            default: return false
            }
        default: return false
        }
        if case .cancelRequested = event { clearResult() }
        switch event {
        case .startDictation, .startCommand, .startSavedPreset:
            physicalStartInProgress = true
            send(event)
            physicalStartInProgress = false
        default: send(event)
        }
        synchronizeInput()
        return true
    }

    /// Own a mouse hold only through the reducer's real captureAccepted effect.
    /// Native consumption alone is never capture authority. A queued down is
    /// refused after another source, exclusion lease or suspension intervened.
    @discardableResult func mouseDown(_ press: MousePress, prepare: () -> DictationSession.Event?, secureRefused: () -> Void) -> Bool {
        if let reason = ordinaryBusyReason() { busyFeedback(reason); return false }
        guard press.isValid, press.inputEpoch == inputAuthority.snapshot.epoch,
              press.admissionRevision == captureAdmission.revision,
              press.suspensionRevision == HotkeyMonitor.suspensionRevision,
              !HotkeyMonitor.suspended, captureAdmission.allowsKeyboard, keyboardAllowed(), !tryoutActive else { return false }
        switch machine.state {
        case .starting(let session), .recording(let session):
            guard session.delivery == .resultOnly else { return false }
        default: break
        }
        invalidateCanceledCapture()
        guard !secure() else { secureRefusal(secureRefused); press.invalidate(); return false }
        guard let event = prepare(), press.isValid else { press.invalidate(); return false }
        broker.preempt() // same deliberate physical-start preemption as keyboard
        guard !machine.isCapturing else { press.invalidate(); return false }
        explicitEntry()
        pendingMouse = press
        physicalStartInProgress = true
        send(event)
        physicalStartInProgress = false
        pendingMouse = nil
        synchronizeInput()
        return mouseOwner?.press == press
    }
    func mouseEnd(_ press: MousePress, short: Bool? = nil) {
        guard let owner = mouseOwner, owner.press == press else { return }
        mouseOwner = nil; press.invalidate()
        guard ownsCapture(owner.session) else { synchronizeInput(); return }
        if short == nil || short == true { clearResult() }
        // A release before recorder acknowledgement cannot successfully stop a
        // starting reducer. Cancel it so a late acknowledgement cannot revive it.
        if short == false, case .recording = machine.state { send(.stopRequested) }
        else { send(.cancelRequested(silent: true, reason: short == true ? .shortRelease : .internalCancellation)) }
        synchronizeInput()
    }
    private func ownsCapture(_ session: DictationSession.Session) -> Bool {
        switch machine.state {
        case .starting(let current), .recording(let current):
            return current.gen == session.gen && current.operation == session.operation && !current.operation.shouldAbort
        default: return false
        }
    }
    private func cancelOwnedMouse() {
        if let owner = mouseOwner { mouseEnd(owner.press) }
    }
    /// Called after the production reducer drain, including native failure and
    /// secure refusal. Cache only: the tap never samples focus or reducer state.
    func synchronizeInput() {
        if let owner = mouseOwner, !ownsCapture(owner.session) {
            owner.press.invalidate(); mouseOwner = nil
        }
        switch machine.state {
        case .starting(let session), .recording(let session):
            inputAuthority.setSource(mouseOwner?.session.operation == session.operation ? .mouse : session.delivery == .resultOnly ? .automation : .keyboard)
        default: inputAuthority.setSource(.none)
        }
    }
    func captureEnded(generation: Int, reason: AudioRecorder.EndReason) {
        if let owner = mouseOwner, owner.session.gen == generation { mouseEnd(owner.press); return }
        send(.captureEnded(gen: generation, reason: reason))
        synchronizeInput()
    }
    func beginTryout() -> Bool {
        invalidateCanceledCapture()
        guard captureAdmission.allowsKeyboard, !tryoutActive else { return false }
        broker.preempt()
        guard captureAdmission.isAvailable, !machine.isCapturing else { return false }
        invalidateOriginal()
        results.clear(); eligibility = nil; tryoutActive = true
        tryoutSuspension = HotkeyMonitor.acquireSuspension()
        return true
    }
    func endTryout() {
        tryoutActive = false
        if let tryoutSuspension { HotkeyMonitor.releaseSuspension(tryoutSuspension) }; tryoutSuspension = nil
    }
    func beginShortcutRecording() -> CaptureAdmission.Lease? {
        invalidateCanceledCapture()
        guard shortcut == nil, !tryoutActive, !machine.isCapturing,
              let lease = captureAdmission.acquire(.shortcut) else { return nil }
        invalidateOriginal()
        shortcut = (lease, HotkeyMonitor.acquireSuspension())
        return lease
    }
    func endShortcutRecording(_ lease: CaptureAdmission.Lease) {
        guard let owned = shortcut, owned.lease == lease else { return }
        shortcut = nil
        captureAdmission.release(lease); HotkeyMonitor.releaseSuspension(owned.suspension)
    }
    func stopAutomation(_ session: DictationSession.Session) {
        guard case .recording(let current) = machine.state, current.operation == session.operation,
              current.gen == session.gen else { return }
        send(.stopRequested)
        synchronizeInput()
    }
    func cancelAutomation(_ session: DictationSession.Session) {
        switch machine.state {
        case .starting(let current), .recording(let current):
            if current.operation == session.operation { send(.cancelRequested(silent: true)); synchronizeInput(); return }
        default: break
        }
        // Retained authority, even after pendingOperation points at newer work.
        send(.discardOwnedOperation(session.operation, generation: session.gen))
    }
    func accepted(_ session: DictationSession.Session) {
        captureAccepted(session, physicalStartInProgress && !tryoutActive)
        if let press = pendingMouse { mouseOwner = (press, session) }
        else {
            mouseOwner?.press.invalidate(); mouseOwner = nil
            inputAuthority.invalidateQueuedMouseStarts()
        }
        synchronizeInput()
        let epoch: UInt64
        if automationAllowed() { epoch = results.begin(session.operation) }
        else { results.clear(); epoch = results.epoch }
        eligibility = (session.operation.id, epoch)
        if session.delivery == .resultOnly { broker.accepted(session, epoch: epoch) }
    }
    func acknowledged(_ session: DictationSession.Session) { broker.acknowledged(session) }
    func finalizing(_ session: DictationSession.Session) { broker.finalizing(session) }
    func completed(_ session: DictationSession.Session, result: DictationFinalResult) {
        guard session.gen == machine.gen, !session.operation.shouldAbort else { return }
        let failure: DictationResultFailure?
        if secure() || result == .failure(.secure) {
            invalidateOriginal()
            results.clear(); eligibility = nil
            // Revoke before later history effects in the reducer drain.
            session.operation.diagnostics?.disposition(.secure, delivery: .refused)
            if session.delivery == .resultOnly {
                session.operation.revoke(reason: .secure)
                send(.discardOwnedOperation(session.operation, generation: session.gen))
            }
            failure = .secure
        } else if session.surroundingTextRun.insertionOnly {
            results.invalidate(operationID: session.operation.id); eligibility = nil
            failure = .unavailable
        } else if let eligibility, eligibility.operation == session.operation.id {
            failure = results.publish(result, operation: session.operation, epoch: eligibility.epoch)
        } else { failure = .unavailable }
        broker.completed(session, failure: failure)
    }
    func discarded(_ operationID: UUID) {
        invalidateOriginal()
        results.invalidate(operationID: operationID)
        if eligibility?.operation == operationID { eligibility = nil }
        broker.discarded(operationID)
    }
    func finished(_ operation: PendingOperation) { broker.finished(operation) }
    func clearResult() { results.clear(); eligibility = nil }
    /// Refusal can precede capture acceptance. Invalidate retrieval without
    /// revoking a pending keyboard operation or changing its generation.
    func secureRefusal(_ feedback: () -> Void) { invalidateOriginal(); clearResult(); feedback() }
}

/// Consumed by the actual AppDelegate bootstrap. Read-only language readiness
/// reconciliation performs no inference, download, permission, microphone,
/// provider or credential work. Explicit entry remains deliberate.
@MainActor final class ApplicationStartupCoordinator {
    private let configure: () -> Void
    private let reconcileSpeech: () -> Void
    private let register: () -> Void
    private let services: () -> Void
    private let migrate: () -> Void
    private let setup: () -> Void
    private let warmMic: () -> Void
    private var bootstrapped = false
    init(configure: @escaping () -> Void, reconcileSpeech: @escaping () -> Void = {},
         register: @escaping () -> Void, services: @escaping () -> Void,
         migrate: @escaping () -> Void, setup: @escaping () -> Void, warmMic: @escaping () -> Void) {
        self.configure = configure; self.reconcileSpeech = reconcileSpeech
        self.register = register; self.services = services
        self.migrate = migrate; self.setup = setup; self.warmMic = warmMic
    }
    func bootstrap() {
        guard !bootstrapped else { return }; bootstrapped = true
        configure(); reconcileSpeech(); register(); services()
    }
    func enterSetup() { migrate(); setup(); warmMic() }
    func enterDictation() { migrate(); warmMic() }
}

/// Thin production callbacks shared by main, Onboarding and owned origin tests.
/// These do not acquire, prepare or route output; real factory admission follows.
@MainActor enum ParakeetAudioEntry {
    /// A factory value with the existing owner, without constructing Whisper's
    /// optional Safe Start service. Actual trust still runs in real acquisition.
    static func factory(owner: ParakeetPreparation, bottom: RecognitionFactory = RecognitionFactory()) -> RecognitionFactory {
        var factory = bottom; owner.bindFactory(&factory); return factory
    }
    static func deliberate(_ request: RecognitionRequest, owner: ParakeetPreparation) {
        if request.selection.engine == .parakeet { owner.deliberateEntry() }
    }
    static func refusal(_ request: RecognitionRequest, owner: ParakeetPreparation) -> ParakeetInstallationRefusal? {
        owner.cachedRefusal(for: request)
    }
    static func capabilities(_ request: RecognitionRequest, owner: ParakeetPreparation,
                             microphone: () -> Bool, otherEngine: () -> AutomationFailure?) -> AutomationFailure? {
        guard request.selection.engine == .parakeet else { return otherEngine() }
        guard refusal(request, owner: owner) == nil else { return .modelUnavailable }
        return microphone() ? nil : .microphoneUnavailable
    }
    static func recovery(_ request: RecognitionRequest, owner: ParakeetPreparation) throws {
        deliberate(request, owner: owner)
        if let reason = refusal(request, owner: owner) { throw reason }
    }
    static func reconcile(_ settings: Settings, valid: Bool, owner: ParakeetPreparation) {
        owner.configure(settings, valid: valid); owner.reconcileOnce()
    }
    /// Called after physical focus/output guards, before credentials or recorder.
    static func physical(_ settings: Settings, destination: ProfileDestination,
                         owner: ParakeetPreparation) -> ParakeetInstallationRefusal? {
        let request = RecognitionRequest(settings: ProfileResolver.resolve(settings, at: destination).settings)
        deliberate(request, owner: owner)
        return refusal(request, owner: owner)
    }
    static func tryout(_ request: RecognitionRequest, owner: ParakeetPreparation,
                       otherEngine: () -> String?) -> String? {
        guard request.selection.engine == .parakeet else { return otherEngine() }
        deliberate(request, owner: owner)
        return refusal(request, owner: owner)?.message
    }
}
