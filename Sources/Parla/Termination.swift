import AppKit

/// Exactly one application reply, after the concrete owners settle. Cancelling
/// releases termination intent only; each owner retains its own safety state.
final class TerminationCoordinator {
    typealias Begin = (@escaping (Bool) -> Void) -> Void
    private let onIntent: () -> Void
    private let savedImports: Begin, cancelSavedImports: () -> Void
    private var savedImportsReady: Bool?
    private let meeting: Begin, cancelMeeting: () -> Void
    private var meetingReady: Bool?
    private let experimentalRetry: Begin
    private let cancelExperimentalRetry: () -> Void
    private var experimentalRetryReady: Bool?
    private let clipboard: Begin, updater: Begin, download: Begin, preparation: Begin, localCleanup: Begin, appleSpeech: Begin, parakeet: Begin
    private let cancelClipboard: () -> Void, cancelUpdater: () -> Void, cancelDownload: () -> Void
    private let reply: (Bool) -> Void, failure: () -> Void
    private let cancelAppleSpeech: () -> Void
    private let cancelParakeet: () -> Void
    private let cancelPreparation: () -> Void, cancelLocalCleanup: () -> Void
    private var intent: UUID?
    private var clipboardReady: Bool?, updaterReady: Bool?, downloadReady: Bool?, preparationReady: Bool?, localCleanupReady: Bool?, appleSpeechReady: Bool?, parakeetReady: Bool?
    private var requesting = false
    var isPending: Bool { intent != nil }
    init(clipboard: @escaping Begin, updater: @escaping Begin,
         download: @escaping Begin = { $0(true) }, cancelDownload: @escaping () -> Void = {},
         preparation: @escaping Begin = { $0(true) }, cancelPreparation: @escaping () -> Void = {},
         appleSpeech: @escaping Begin = { $0(true) }, cancelAppleSpeech: @escaping () -> Void = {},
         parakeet: @escaping Begin = { $0(true) }, cancelParakeet: @escaping () -> Void = {},
         localCleanup: @escaping Begin = { $0(true) }, cancelLocalCleanup: @escaping () -> Void = {},
         savedImports: @escaping Begin = { $0(true) }, cancelSavedImports: @escaping () -> Void = {},
         meeting: @escaping Begin = { $0(true) }, cancelMeeting: @escaping () -> Void = {},
         experimentalRetry: @escaping Begin = { $0(true) }, cancelExperimentalRetry: @escaping () -> Void = {},
         cancelClipboard: @escaping () -> Void, cancelUpdater: @escaping () -> Void,
         reply: @escaping (Bool) -> Void, failure: @escaping () -> Void, onIntent: @escaping () -> Void = {}) {
        self.onIntent = onIntent
        self.meeting = meeting; self.cancelMeeting = cancelMeeting
        self.savedImports = savedImports; self.cancelSavedImports = cancelSavedImports
        self.clipboard = clipboard; self.updater = updater; self.download = download; self.cancelDownload = cancelDownload
        self.cancelClipboard = cancelClipboard; self.cancelUpdater = cancelUpdater
        self.reply = reply; self.failure = failure
        self.preparation = preparation; self.cancelPreparation = cancelPreparation
        self.appleSpeech = appleSpeech; self.cancelAppleSpeech = cancelAppleSpeech
        self.parakeet = parakeet; self.cancelParakeet = cancelParakeet
        self.experimentalRetry = experimentalRetry; self.cancelExperimentalRetry = cancelExperimentalRetry
        self.localCleanup = localCleanup; self.cancelLocalCleanup = cancelLocalCleanup
    }
    func request() -> NSApplication.TerminateReply {
        guard intent == nil else { return .terminateLater }
        onIntent() // revoke review authority even when no execution remains to drain
        let token = UUID(); intent = token
        clipboardReady = nil; updaterReady = nil; downloadReady = nil; preparationReady = nil; localCleanupReady = nil; appleSpeechReady = nil; parakeetReady = nil; requesting = true
        meetingReady = nil
        meeting { [weak self] allowed in
            guard let self,self.intent == token else { return }; self.meetingReady = allowed; self.settle(token,allowed:allowed)
        }
        savedImportsReady = nil
        savedImports { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.savedImportsReady = allowed; self.settle(token, allowed: allowed)
        }
        experimentalRetryReady = nil
        experimentalRetry { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.experimentalRetryReady = allowed; self.settle(token, allowed: allowed)
        }
        parakeet { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.parakeetReady = allowed; self.settle(token, allowed: allowed)
        }
        appleSpeech { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.appleSpeechReady = allowed; self.settle(token, allowed: allowed)
        }
        localCleanup { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.localCleanupReady = allowed; self.settle(token, allowed: allowed)
        }
        preparation { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.preparationReady = allowed; self.settle(token, allowed: allowed)
        }
        clipboard { [weak self] in self?.completed(token, clipboard: true, allowed: $0) }
        updater { [weak self] in self?.completed(token, clipboard: false, allowed: $0) }
        download { [weak self] allowed in
            guard let self, self.intent == token else { return }
            self.downloadReady = allowed
            self.settle(token, allowed: allowed)
        }
        requesting = false
        if meetingReady == false || savedImportsReady == false || experimentalRetryReady == false || clipboardReady == false || updaterReady == false || downloadReady == false || preparationReady == false || localCleanupReady == false || appleSpeechReady == false || parakeetReady == false { cancel(); return .terminateCancel }
        if allReady { intent = nil; return .terminateNow }
        return .terminateLater
    }
    private func completed(_ token: UUID, clipboard: Bool, allowed: Bool) {
        guard intent == token else { return }
        if clipboard { clipboardReady = allowed } else { updaterReady = allowed }
        settle(token, allowed: allowed)
    }
    private func settle(_ token: UUID, allowed: Bool) {
        guard intent == token, !requesting else { return }
        if !allowed { cancel(); reply(false) }
        else if allReady { intent = nil; reply(true) }
    }
    private var allReady: Bool { meetingReady == true && savedImportsReady == true && experimentalRetryReady == true && clipboardReady == true && updaterReady == true && downloadReady == true && preparationReady == true && localCleanupReady == true && appleSpeechReady == true && parakeetReady == true }
    private func cancel() {
        intent = nil; cancelMeeting(); cancelSavedImports(); cancelExperimentalRetry(); cancelClipboard(); cancelUpdater(); cancelDownload(); cancelPreparation(); cancelLocalCleanup(); cancelAppleSpeech(); cancelParakeet(); failure()
    }
}

final class CanceledCaptureTermination {
    private let undo: CanceledCaptureUndoController
    private let coordinator: TerminationCoordinator
    init(undo: CanceledCaptureUndoController, coordinator: TerminationCoordinator) {
        self.undo = undo; self.coordinator = coordinator
    }
    func request() -> NSApplication.TerminateReply {
        undo.shutdown()
        return coordinator.request()
    }
    func restartFailed() {
        if !coordinator.isPending { undo.quitCanceled() }
    }
}

/// Updater cleanup owns the install barrier independently of a quit intent.
/// The controller's actual success/failure paths complete this same owner.
final class UpdateTerminationIntent {
    private var reply: ((Bool) -> Void)?
    var isPending: Bool { reply != nil }
    func request(waitingForInstall: Bool, committing: Bool, cancelInstall: () -> Void,
                 reply: @escaping (Bool) -> Void) {
        guard waitingForInstall else { reply(true); return }
        self.reply = reply
        if !committing { cancelInstall() }
    }
    func cancel() { reply = nil }
    func installFailed(releaseRestart: () -> Void) -> Bool {
        let pending = isPending
        releaseRestart()
        if pending { complete() }
        return pending
    }
    func complete() {
        let action = reply; reply = nil; action?(true)
    }
}
