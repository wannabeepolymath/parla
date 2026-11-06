import AppKit
import Combine
import ParlaCore

/// Scalar projection only: no transcript in menu titles, tooltips or Hub status.
enum OriginalCopyStatus: Equatable {
    case disabled, unavailable
    case postedUnverified(UUID)

    var token: UUID? { if case .postedUnverified(let id) = self { return id }; return nil }
    var message: String {
        switch self {
        case .disabled: return "Original copy is off"
        case .unavailable: return "No fresh Original available"
        case .postedUnverified: return "Original available briefly — paste posted, acceptance unverified"
        }
    }
}

enum OriginalCopySecurity { case safe, secure, unavailable }

/// Main-thread RAM owner, independent of History and automation retrieval.
/// An insertion Bool means posted, never accepted. Timers retain only an epoch.
final class OriginalCopyController: ObservableObject {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    static let lifetime: TimeInterval = 30
    @Published private(set) var status: OriginalCopyStatus = .disabled
    private let configuration: () -> Settings?
    private let generation: () -> Int
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let security: () -> OriginalCopySecurity
    private let copy: (String) -> Void
    private var epoch = UUID()
    private var capture: (operation: UUID, generation: Int)?
    private struct Owner {
        let token: UUID
        let original: String
        let operation: PendingOperation
        let generation: Int
        let expires: TimeInterval
    }
    private var owner: Owner?
    private var cancelExpiry: (() -> Void)?

    /// Exists only during the synchronous production paste. Never captured by timers.
    final class Attempt {
        let token: UUID
        let context: OriginalDictationContext
        let operation: PendingOperation
        var dispatched: TimeInterval?
        init(token: UUID, context: OriginalDictationContext, operation: PendingOperation) {
            self.token = token; self.context = context; self.operation = operation
        }
    }

    init(configuration: @escaping () -> Settings?, generation: @escaping () -> Int,
         now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         schedule: @escaping Schedule = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return { item.cancel() }
         }, security: @escaping () -> OriginalCopySecurity, copy: @escaping (String) -> Void) {
        self.configuration = configuration; self.generation = generation; self.now = now
        self.schedule = schedule; self.security = security; self.copy = copy
    }

    static func currentSecurity() -> OriginalCopySecurity {
        switch Inserter.securityFocusTarget() {
        case .secure: return .secure
        case .none: return .unavailable
        case .editable, .unknown: return .safe
        }
    }

    func clear() {
        precondition(Thread.isMainThread)
        epoch = UUID(); capture = nil; owner = nil
        let cancel = cancelExpiry; cancelExpiry = nil; cancel?()
        status = .unavailable
    }

    /// Known security evidence from existing probes; no observer or new probe.
    func observe(_ event: DictationSession.Event) {
        switch event {
        case .focusSampled(_, .secure), .cleanReady(_, _, _, _, .secure, _): clear()
        case .transcribed(_, _, let probe) where probe.focus == .secure: clear()
        case .transformReady(_, _, let probe, _, _) where probe.focus == .secure: clear()
        default: break
        }
    }

    /// Called before interpreting any effect, preserving the existing drain order.
    func observe(_ effect: DictationSession.Effect) {
        switch effect {
        case .captureAccepted(let session): captureAccepted(session)
        case .abortOperation, .secureRefusal, .eraseTypedIfOurs, .replaceTailIfOurs: clear()
        default: break
        }
    }

    func captureAccepted(_ session: DictationSession.Session) {
        clear() // before recorder/model effects, including excluded capture kinds
        guard enabled(), session.permitsOriginalCopy, !session.operation.shouldAbort else { return }
        capture = (session.operation.id, session.gen)
    }

    @discardableResult func refresh() -> OriginalCopyStatus {
        precondition(Thread.isMainThread)
        guard enabled() else { return status }
        if let owner, (owner.operation.shouldAbort || owner.generation != generation() || now() >= owner.expires) { clear() }
        status = owner.map { .postedUnverified($0.token) } ?? .unavailable
        return status
    }

    /// Also invalidates a prior offer for failed, excluded or stale insertions.
    func beginInsertion(_ context: OriginalDictationContext?, operation: PendingOperation?) -> Attempt? {
        precondition(Thread.isMainThread)
        let accepted = capture
        clear()
        guard enabled(), let context, let operation, !operation.shouldAbort,
              context.raw.utf8.count <= OriginalDictationContext.maximumBytes,
              context.operationID == operation.id, context.generation == generation(),
              accepted?.operation == operation.id, accepted?.generation == context.generation else { return nil }
        return Attempt(token: epoch, context: context, operation: operation)
    }

    func willPost(_ attempt: Attempt?) {
        precondition(Thread.isMainThread)
        guard let attempt, valid(attempt) else { return }
        guard security() == .safe else { clear(); return }
        guard valid(attempt) else { return }
        attempt.dispatched = now()
    }

    /// Resolve configuration/security callbacks before a guarded native paste.
    /// The returned dispatch hook only checks in-memory ownership and records the
    /// actual post time; it cannot observe new settings after posting is admitted.
    func preparedWillPost(_ attempt: Attempt?) -> () -> Void {
        precondition(Thread.isMainThread)
        guard let attempt, valid(attempt) else { return {} }
        guard security() == .safe else { clear(); return {} }
        guard valid(attempt) else { return {} }
        return { [weak self, weak attempt] in
            guard let self, let attempt, self.epoch == attempt.token,
                  !attempt.operation.shouldAbort,
                  attempt.context.generation == self.generation() else { return }
            attempt.dispatched = self.now()
        }
    }

    func completed(_ attempt: Attempt?, posted: Bool) {
        precondition(Thread.isMainThread)
        guard let attempt, posted, valid(attempt), let dispatched = attempt.dispatched,
              now() < dispatched + Self.lifetime else { return }
        owner = Owner(token: attempt.token, original: attempt.context.raw, operation: attempt.operation,
                      generation: attempt.context.generation, expires: dispatched + Self.lifetime)
        let token = attempt.token
        cancelExpiry = schedule(max(0, dispatched + Self.lifetime - now())) { [weak self] in
            guard let self, self.epoch == token else { return }
            self.refresh()
        }
        refresh()
    }

    /// Shared menu/Hub action. Repeated deliberate clicks may copy until the
    /// original dispatch deadline; reading/copying never renews it.
    @discardableResult func copyOriginal(token: UUID) -> Bool {
        guard refresh().token == token else { return false }
        guard security() == .safe else { clear(); return false }
        guard refresh().token == token, let owner else { return false }
        copy(owner.original) // explicit copy changes changeCount, preserving clipboard restore ownership
        return true
    }

    private func enabled() -> Bool {
        guard configuration()?.keepLastOriginalEnabled == true else {
            clear(); status = .disabled; return false
        }
        return true
    }
    private func valid(_ attempt: Attempt) -> Bool {
        enabled() && epoch == attempt.token && !attempt.operation.shouldAbort
            && attempt.context.generation == generation()
    }
    deinit { cancelExpiry?() }
}

/// Actual ordinary insertion executor. Native poster and correction observer
/// are injectable; disabled retention adds no field reads, timer or copy.
final class DictationInsertionExecutor {
    typealias Poster = (String, DiagnosticOperation?, () -> Void) -> Bool
    private let originals: OriginalCopyController
    typealias PreparedPoster = (String, DiagnosticOperation?, () -> (() -> Void)?) -> Bool
    private let post: Poster
    private let preparedPost: PreparedPoster?
    private let didPost: (String) -> Void
    private let edits: DictationEditRecording?
    var beforeStoredInsertion: () -> Void = {}
    var disarmLearning: () -> Void = {}
    var isCurrentOriginal: (OriginalDictationContext) -> Bool = { _ in true }

    /// The app and fake-entry tests use the same fresh-valid-config factory.
    typealias ConfiguredPoster = (String, DiagnosticOperation?, ClipboardRestoreMode, () -> Void) -> Bool
    static func configuredPoster(configuration: @escaping () -> Settings?,
                                 native: @escaping ConfiguredPoster = { text, diagnostic, mode, dispatch in
                                     Inserter.insert(text, diagnostics: diagnostic, restoreMode: mode, willPost: dispatch)
                                 }) -> Poster {
        { text, diagnostic, dispatch in
            let mode: ClipboardRestoreMode = configuration()?.clipboardReceiptRestoreEnabled == true ? .observableRequests : .fixed
            return native(text, diagnostic, mode, dispatch)
        }
    }
    /// Configuration is consumed first. Preparation can then veto the native
    /// call, including clipboard publication, or provide a configuration-free hook.
    static func configuredPreparedPoster(configuration: @escaping () -> Settings?,
                                         native: @escaping ConfiguredPoster = { text, diagnostic, mode, dispatch in
                                             Inserter.insert(text, diagnostics: diagnostic, restoreMode: mode, willPost: dispatch)
                                         }) -> PreparedPoster {
        { text, diagnostic, prepare in
            let mode: ClipboardRestoreMode = configuration()?.clipboardReceiptRestoreEnabled == true ? .observableRequests : .fixed
            guard let dispatch = prepare() else { return false }
            return native(text, diagnostic, mode, dispatch)
        }
    }
    init(originals: OriginalCopyController,
         post: @escaping Poster = { text, diagnostic, dispatch in
             Inserter.insert(text, diagnostics: diagnostic, willPost: dispatch)
         }, preparedPost: PreparedPoster? = nil, edits: DictationEditRecording? = nil, didPost: @escaping (String) -> Void) {
        self.originals = originals; self.post = post; self.preparedPost = preparedPost; self.didPost = didPost
        self.edits = edits
    }

    /// Stored/history paste keeps its existing no-correction-learning behavior.
    func insertStored(_ text: String) -> Bool {
        beforeStoredInsertion()
        originals.clear()
        edits?.clear()
        return post(text, nil, {})
    }

    /// nil preserves the interpreter's existing silent unauthorized path.
    func insert(_ text: String, original: OriginalDictationContext?, operation: PendingOperation?, contextRun: SurroundingTextRun? = nil) -> Bool? {
        edits?.clear()
        let suppressLearning = contextRun?.participated == true
        if suppressLearning {
            disarmLearning()
            if let contextRun, contextRun.insertionRequiresAuthority {
                guard (try? contextRun.check()) != nil else { return nil }
            }
        }
        let attempt = originals.beginInsertion(original, operation: operation)
        func recordEdit() {
            guard let original, original.operationID == operation?.id,
                  operation?.shouldAbort == false, isCurrentOriginal(original) else { return }
            edits?.willPost(raw: original.raw, cleaned: text)
        }
        let posted: Bool
        if let contextRun, contextRun.insertionRequiresAuthority {
            var vetoed = false
            func prepare() -> (() -> Void)? {
                guard operation?.shouldAbort != true, (try? contextRun.check()) != nil else { vetoed = true; return nil }
                let dispatch = originals.preparedWillPost(attempt)
                guard (try? contextRun.check()) != nil,
                      operation?.authorizeDispatch() != false else { vetoed = true; return nil }
                return {
                    dispatch()
                    recordEdit()
                }
            }
            if let preparedPost { posted = preparedPost(text, operation?.diagnostics, prepare) }
            else {
                guard let dispatch = prepare() else { return nil }
                posted = post(text, operation?.diagnostics, dispatch)
            }
            if vetoed { return nil }
        } else {
            guard operation?.authorizeDispatch() != false else { return nil }
            posted = post(text, operation?.diagnostics) {
                originals.willPost(attempt)
                recordEdit()
            }
        }
        edits?.completed(posted: posted)
        originals.completed(attempt, posted: posted)
        if posted && !suppressLearning { didPost(text) }
        return posted
    }
}

/// Menu target is shared with tests without constructing AppDelegate's recorder.
final class OriginalCopyMenuActions: NSObject {
    private let controller: OriginalCopyController
    init(controller: OriginalCopyController) { self.controller = controller }
    var edit: (GuardedDictationEdits<Inserter.FieldIdentity>.Action, UUID) -> Void = { _, _ in }
    @objc func undoLastDictation(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? UUID else { return }
        edit(.undo, token)
    }
    @objc func restoreRawText(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? UUID else { return }
        edit(.restoreRaw, token)
    }
    @objc func copyOriginal(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? UUID else { return }
        controller.copyOriginal(token: token)
    }
}
