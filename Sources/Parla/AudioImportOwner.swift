import Combine
import Foundation
import ParlaCore

/// Main-thread review owner, created by the app before its lazy Hub. Execution
/// and publication have separate lifetimes; finishing an operation grants nothing.
final class AudioImportOwner: ObservableObject {
    var savedImports: SavedAudioImportOwner?
    enum Mode { case raw, experimentalTimed }
    struct Configuration: Equatable {
        let request: RecognitionRequest
        let safeStart: Bool
        let consent: UUID?
        init(_ settings: Settings) {
            request = RecognitionRequest(settings: settings)
            safeStart = settings.nativePreparationSafeStartEnabled; consent = settings.nativePreparationConsent
        }
    }
    final class Job: @unchecked Sendable {
        let operation: PendingOperation
        let source: FileImportSource
        let configuration: Configuration
        let mode: Mode
        let selectionEpoch: UUID, preparationEpoch: UUID?
        let resultID = UUID()
        private let lock = NSLock()
        private var revoked = false
        var current: Bool { lock.withLock { !revoked } }
        init(source: FileImportSource, settings: Settings, selectionEpoch: UUID, preparationEpoch: UUID?, diagnostics: DiagnosticStore, mode: Mode = .raw) {
            self.source = source; configuration = Configuration(settings)
            self.mode = mode
            self.selectionEpoch = selectionEpoch; self.preparationEpoch = preparationEpoch
            operation = PendingOperation(name: "Audio import", origin: .fileImport, diagnostics: diagnostics)
            operation.diagnostics?.recognition(request: configuration.request)
            operation.diagnostics?.disposition(.previewOnly, delivery: .notAttempted)
        }
        func revoke() {
            lock.withLock { revoked = true }
            source.cancel(); operation.revoke(); operation.requestAbort()
        }
        func authorize(_ store: SettingsStore) -> Bool {
            guard current, !operation.shouldAbort,
                  let saved = try? store.savedRetrySnapshot(), Configuration(saved) == configuration,
                  !saved.recognitionConfigurationInvalid, RecognitionRequest(settings: saved).selection.engine != .invalid else { revoke(); return false }
            return true
        }
    }
    struct Completed {
        let raw: String
        let sourceInfo: ImportedAudio.SourceInfo
        var segments: RecognitionSegments? = nil
    }
    struct Review {
        let job: Job
        let entry: HistoryEntry
        let sourceInfo: ImportedAudio.SourceInfo
        let segments: RecognitionSegments?
        var saved = false, saveFailed = false
    }
    @Published private(set) var source: FileImportSource?
    @Published private(set) var review: Review?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private(set) var job: Job?
    private var observed: Configuration?
    private var observer: NSObjectProtocol?
    var clock: () -> Date = Date.init
    var sourceAccess = FileImportSource.Access()
    var security: () -> Bool = { AppDelegate.automationSecureEvidence() }
    var publication: (@escaping () -> Void) -> Void = { $0() }

    func notice(_ text: String) { message = text }
    func bind(_ store: SettingsStore) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observeSaved(store)
        observer = NotificationCenter.default.addObserver(forName: SettingsStore.configurationDidChange, object: store, queue: .main) { [weak self, weak store] _ in
            guard let store else { return }
            // Observe saved changes on the existing main UI executor.
            self?.observeSaved(store)
        }
    }
    func observeSaved(_ store: SettingsStore) {
        guard let saved = try? store.savedRetrySnapshot(), !saved.recognitionConfigurationInvalid, RecognitionRequest(settings: saved).selection.engine != .invalid else {
            invalidate("Repair saved settings before Start."); observed = nil; return
        }
        observe(saved)
    }
    func observe(_ settings: Settings) {
        savedImports?.observe(settings)
        guard !settings.recognitionConfigurationInvalid, RecognitionRequest(settings: settings).selection.engine != .invalid else {
            invalidate("Repair saved recognition settings before Start."); observed = nil; return
        }
        let current = Configuration(settings)
        if let observed, observed != current { invalidate("Recognition settings changed. Choose the file again.") }
        if let job, job.configuration != current { invalidate("Recognition settings changed. Choose the file again.") }
        observed = current
    }
    func select(_ url: URL) {
        guard !busy else { message = "Previous import is still stopping or running."; return }
        invalidate(nil)
        do { source = try FileImportSource(url: url, access: sourceAccess); message = "Selected. Start reads this file and runs the saved global recognition settings." }
        catch { message = Self.failure(error) }
    }
    func start(settings: Settings, selectionEpoch: UUID, preparationEpoch: UUID?, diagnostics: DiagnosticStore, mode: Mode = .raw) -> Job? {
        guard !busy, let source else { message = "Choose one WAV before Start."; return nil }
        let job = Job(source: source, settings: settings, selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch, diagnostics: diagnostics, mode: mode)
        self.source = nil; self.job = job; review = nil; busy = true
        message = "Import queued. Cancellation waits for the active reader or recognizer to exit."
        return job
    }
    func complete(_ job: Job, result: Result<Completed, Error>) {
        guard self.job === job else { return }
        busy = false
        let completedAt = clock()
        publication { [weak self] in
            guard let self, self.job === job, job.current, !job.operation.shouldAbort else { return }
            switch result {
            case .success(let completed):
                var metrics = PipelineMetrics(); metrics.model = job.configuration.request.metricLabel
                let timing = job.mode == .experimentalTimed && completed.sourceInfo.origin == .strictPCM16k
                    && completed.segments?.sourceSampleCount == completed.sourceInfo.sourceFrames ? completed.segments : nil
                self.review = Review(job: job, entry: HistoryEntry(id: job.resultID, date: completedAt, raw: completed.raw, metrics: metrics), sourceInfo: completed.sourceInfo, segments: timing)
                self.message = job.mode == .experimentalTimed && timing == nil
                    ? "Raw transcript ready. Native timing is unavailable; Copy and text Save remain available. No timing repair was run."
                    : "Raw transcript ready for review. Nothing has been copied or saved."
            case .failure(let error): self.message = Self.failure(error)
            }
        }
    }
    func takeSourceForSaved() -> FileImportSource? {
        guard !busy, let selected = source else { return nil }
        source = nil; invalidate(nil); return selected
    }
    func invalidate(_ message: String? = "Import discarded. Choose a file for a fresh job.") {
        savedImports?.invalidate(message)
        let previous = job
        review = nil; source?.cancel(); source = nil
        previous?.revoke()
        if !busy { job = nil }
        self.message = message
    }
    func preparationChanged(_ epoch: UUID?) {
        savedImports?.preparationChanged(epoch)
        if let job, job.configuration.request.selection.engine == .whisper, job.preparationEpoch != epoch {
            invalidate("Preparation authority changed. Choose the file again.")
        }
    }
    /// Existing probes only, before the interpreter rejects stale operations.
    func observe(_ event: DictationSession.Event) {
        switch event {
        case .focusSampled(_, .secure), .cleanReady(_, _, _, _, .secure, _), .resultUnavailable(_, .secure):
            invalidate("Import discarded after secure-input evidence.")
        case .transcribed(_, _, let probe) where probe.focus == .secure:
            invalidate("Import discarded after secure-input evidence.")
        case .transformReady(_, _, let probe, _, _) where probe.focus == .secure:
            invalidate("Import discarded after secure-input evidence.")
        default: break
        }
    }
    func boundaryIsSafe() -> Bool {
        if security() { invalidate("Import discarded after secure-input evidence."); return false }
        return true
    }
    func copy(using write: (String) -> Void) {
        guard let review, review.job.current else { return }; write(review.entry.raw)
    }
    func save(settings: Settings, history: HistoryStore) {
        guard var review, review.job.current, !review.saved else { return }
        guard settings.historyEnabled else { message = "History is off. Enable it and explicitly Save this current result."; return }
        guard history.reload(countLimit: settings.historyTextCount), !history.loadBlocked else {
            review.saveFailed = true; self.review = review; message = "Retry Load history, then Retry Save this same result."; return
        }
        review.saved = history.appendReviewed(review.entry); review.saveFailed = !review.saved
        self.review = review
        message = review.saved ? "Raw transcript saved." : "Couldn’t save. Retry Save stores this same result without recognition."
    }
    static func failure(_ error: Error) -> String {
        if let error = error as? ImportedAudio.Failure { return error.message }
        if let error = error as? ImportedWAV.Failure { return error.message }
        if let error = error as? FileImportSource.Failure { return error.message }
        if let error = error as? PreparationRefusal { return error.description }
        if let error = error as? ParakeetInstallationRefusal { return error.message }
        if let error = error as? AppleSpeechRefusal { return error.message }
        // RecordingStore.Failure is used by the shared batch, never raw OS errors.
        if let error = error as? RecordingStore.Failure { return error.message }
        return "Import could not finish. Choose the file again to retry."
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; source?.cancel(); job?.revoke() }
}

/// The same queue/admission bridge is used by AppDelegate and native-bottom tests.
@MainActor enum AudioImportExecution {
    private final class Completion { var result: Result<AudioImportOwner.Completed, Error> = .failure(CancellationError()) }
    nonisolated static func validateSource(_ info: ImportedAudio.SourceInfo, mode: AudioImportOwner.Mode) throws {
        guard mode != .experimentalTimed || info.origin == .strictPCM16k else {
            throw RecordingStore.Failure("Experimental timing requires an original mono 16 kHz PCM WAV. Converted input was not sent to recognition.")
        }
    }
    static func enqueue(previous: Task<Void, Never>?, admission: LocalCleanupAdmission,
                        job: AudioImportOwner.Job, store: SettingsStore,
                        enter: @escaping () async throws -> Void = {},
                        load: @escaping (RecognitionRequest) async throws -> RecognitionHandle,
                        done: @escaping (Result<AudioImportOwner.Completed, Error>) -> Void) -> Task<Void, Never>? {
        guard admission.admit(job.operation) else {
            job.revoke(); job.operation.finish(); done(.failure(CancellationError())); return nil
        }
        let completion = Completion()
        return PendingOperationQueue.enqueue(previous: previous, operation: job.operation, completes: true, work: {
            let result: Result<AudioImportOwner.Completed, Error>
            do {
                var sourceInfo: ImportedAudio.SourceInfo?
                let recognition = try await FileRecognitionBatch.runResult(request: job.configuration.request, operation: job.operation,
                    samples: {
                        let decoded = try job.source.samples(canceled: { !job.current || job.operation.shouldAbort })
                        try validateSource(decoded.transientSourceInfo, mode: job.mode)
                        sourceInfo = decoded.transientSourceInfo
                        return decoded.samples
                    },
                    validate: { guard job.current else { throw CancellationError() } }, active: { job.current },
                    authorize: { job.authorize(store) }, rawOnly: true, timed: job.mode == .experimentalTimed, enter: enter, load: load)
                guard let sourceInfo else { throw CancellationError() }
                result = .success(AudioImportOwner.Completed(raw: recognition.raw, sourceInfo: sourceInfo, segments: recognition.segments))
            } catch { result = .failure(error) }
            await MainActor.run { completion.result = result }
        }, finished: {
            // Includes cancel-before-dequeue and all throws. Never close a borrowed reader early.
            job.source.cancel()
            await MainActor.run {
                admission.exited(job.operation)
                done(job.current && !job.operation.shouldAbort ? completion.result : .failure(CancellationError()))
            }
        })
    }
}
