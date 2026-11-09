import Combine
import Foundation
import ParlaCore

/// Eager saved ownership, independent of the lazy Hub and native preparation.
/// Main-thread projections; synchronous Store work runs in registered IO tasks.
final class SavedAudioImportOwner: ObservableObject {
    final class Authority: @unchecked Sendable {
        let id = UUID(), configuration: AudioImportOwner.Configuration
        let selectionEpoch: UUID, preparationEpoch: UUID?
        private let lock = NSLock(); private var revoked = false
        var current: Bool { lock.withLock { !revoked } }
        init(settings: Settings, selectionEpoch: UUID, preparationEpoch: UUID?) {
            configuration = .init(settings); self.selectionEpoch = selectionEpoch; self.preparationEpoch = preparationEpoch
        }
        func revoke() { lock.withLock { revoked = true } }
        func authorize(_ store: SettingsStore) -> Bool {
            guard current, let saved = try? store.savedRetrySnapshot(), !saved.recognitionConfigurationInvalid,
                  RecognitionRequest(settings: saved).selection.engine != .invalid,
                  AudioImportOwner.Configuration(saved) == configuration else { revoke(); return false }
            return true
        }
    }
    final class Job: @unchecked Sendable {
        let id: UUID, source: FileImportSource?, authority: Authority, operation: PendingOperation
        private let lock = NSLock(); private var tokenValue: SavedAudioImportStore.AttemptToken?
        let resultID = UUID()
        var token: SavedAudioImportStore.AttemptToken? { get { lock.withLock { tokenValue } } set { lock.withLock { tokenValue = newValue } } }
        var current: Bool { authority.current && !operation.shouldAbort }
        init(id: UUID = UUID(), source: FileImportSource?, authority: Authority, diagnostics: DiagnosticStore) {
            self.id = id; self.source = source; self.authority = authority
            operation = PendingOperation(name: "Saved audio import", origin: .fileImport, diagnostics: diagnostics)
            operation.diagnostics?.recognition(request: authority.configuration.request)
            operation.diagnostics?.disposition(.previewOnly, delivery: .notAttempted)
        }
        func revoke() { authority.revoke(); source?.cancel(); operation.revoke(); operation.requestAbort() }
    }
    struct Completed {
        let token: SavedAudioImportStore.AttemptToken, raw: Data, observed: SavedAudioImportStore.Provenance
        let accepted: SavedAudioImportStore.Accepted?, saveFailure: Error?, resultDate: Date
    }
    final class Review {
        let jobID: UUID, resultID: UUID, authority: Authority, bytes: Data, date: Date
        let token: SavedAudioImportStore.AttemptToken?, observed: SavedAudioImportStore.Provenance
        var accepted: SavedAudioImportStore.Accepted?
        var historySaved = false, historyFailed = false, recordFailed = false, associationUnknown = false
        init(jobID: UUID, resultID: UUID, authority: Authority, bytes: Data, date: Date,
             token: SavedAudioImportStore.AttemptToken?, observed: SavedAudioImportStore.Provenance, accepted: SavedAudioImportStore.Accepted?) {
            self.jobID = jobID; self.resultID = resultID; self.authority = authority; self.bytes = bytes; self.date = date
            self.token = token; self.observed = observed; self.accepted = accepted
            historySaved = accepted?.association == .saved
            associationUnknown = accepted?.association == .unknown || accepted?.association == .savingIntent
        }
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla", isDirectory: true).appendingPathComponent("saved-imports", isDirectory: true)
    }
    let store: SavedAudioImportStore
    @Published private(set) var rows: [SavedAudioImportStore.Row] = []
    @Published private(set) var review: Review?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var ioBusy = false
    private(set) var job: Job?
    private var execution: Task<Void,Never>?, ioTasks: [UUID:Task<Void,Never>] = [:]
    private var closedAdmission = false, restartReserved = false, shutdownReserved = false
    private var deletionRequests = Set<UUID>()
    private var outputIO = Set<UUID>()
    private var outputWaiters: [CheckedContinuation<Void,Never>] = []
    private var opening: Authority?
    private var observed: AudioImportOwner.Configuration?
    private(set) var storageConcern: String?
    var shutdownRefusal: String? {
        if let storageConcern {return storageConcern}
        guard !busy, !ioBusy else {return nil}
        return store.failure?.message
    }
    var currentEngine: RecognitionEngine? { (review?.authority ?? job?.authority ?? opening)?.configuration.request.selection.engine }
    enum MetadataReadiness: Equatable { case pending, ready, unavailable }
    @Published private(set) var metadataReadiness = MetadataReadiness.pending
    let clock: () -> Date
    var enqueue: (Job, @escaping (Result<Completed,Error>) -> Void) -> Task<Void,Never>? = { job, done in
        job.revoke(); job.operation.finish(); done(.failure(CancellationError())); return nil
    }
    init(root: URL, system: SavedAudioImportStorage.System = .init(), clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        store = SavedAudioImportStore(storage: .init(root: root, system: system))
        // Registered before work starts, including when the Hub never opens.
        refresh()
    }
    private func fail(_ error: Error) {
        let failure = error as? SavedAudioImportStorage.Failure
        message = failure?.message ?? AudioImportOwner.failure(error)
        if failure == .uncertain || failure == .unknown || failure == .changed || store.failure != nil {
            storageConcern = message
        }
    }
    private func perform<T>(_ work: @escaping () throws -> T, done: @escaping (Result<T,Error>) -> Void) {
        let id = UUID(); ioBusy = true
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached { () -> Result<T,Error> in
                do { return .success(try work()) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            done(result)
            self.ioTasks[id] = nil; self.ioBusy = !self.ioTasks.isEmpty || !self.outputIO.isEmpty
            self.rows = self.store.rows()
            if let review = self.review, !self.rows.contains(where:{$0.id == review.jobID && !$0.deleting && self.clock() < $0.expires}) {
                self.invalidate("This saved file has expired.")
            }
        }
        ioTasks[id] = task
    }
    func refresh() {
        guard !closedAdmission, !ioBusy, !busy else { return }
        metadataReadiness = .pending
        let store = store, now = clock()
        perform({
            _ = try store.bootstrap()
            try store.maintenance(now: now)
        }, done: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.metadataReadiness = .ready
            case .failure(let error): self.metadataReadiness = .unavailable; self.fail(error)
            }
        })
    }
    func protection() throws -> SavedAudioImportStore.Protection {
        guard metadataReadiness == .ready, !busy, !ioBusy else { throw SavedAudioImportStorage.Failure.unavailable }
        return try store.protection()
    }
    func observe(_ settings: Settings) {
        let value = AudioImportOwner.Configuration(settings)
        if let observed, observed != value { invalidate("Speech settings changed, so the transcript was closed.") }
        if let job, job.authority.configuration != value { invalidate("Transcription canceled because settings changed.") }
        observed = value
    }
    func preparationChanged(_ epoch: UUID?) {
        let authority = review?.authority ?? job?.authority ?? opening
        if let authority, authority.configuration.request.selection.engine == .whisper, authority.preparationEpoch != epoch {
            invalidate("Speech settings changed, so the transcript was closed.")
        }
    }
    func invalidate(_ text: String? = nil) {
        opening?.revoke(); opening = nil
        review?.authority.revoke(); review = nil; job?.revoke()
        if !busy { job = nil }
        if let text { message = text }
    }
    func notice(_ text: String) { message = text }
    func start(source: FileImportSource?, id: UUID? = nil, settings: Settings, epoch: UUID, preparation: UUID?, diagnostics: DiagnosticStore) {
        guard metadataReadiness == .ready, !closedAdmission, !busy, !ioBusy, source != nil || id != nil else { message = "Wait for the current transcription to finish."; return }
        invalidate()
        let authority = Authority(settings: settings,selectionEpoch:epoch,preparationEpoch:preparation)
        let job = Job(id:id ?? UUID(),source:source,authority:authority,diagnostics:diagnostics)
        self.job = job; busy = true; message = "Saving a copy…"
        execution = enqueue(job) { [weak self] result in self?.complete(job,result) }
    }
    private func complete(_ job: Job, _ result: Result<Completed,Error>) {
        guard self.job === job else { return }
        busy = false
        if job.current {
            switch result {
            case .success(let result):
                review = Review(jobID:job.id,resultID:job.resultID,authority:job.authority,bytes:result.raw,
                    date:result.resultDate, token:result.token,observed:result.observed,accepted:store.failure == nil ? result.accepted : nil)
                if let error = result.saveFailure ?? store.failure { fail(error); message = "Transcript not saved. Try again before closing it." }
                else { message = "File and transcript saved." }
            case .failure(let error): fail(error)
            }
        }
        rows = store.rows()
        if !closedAdmission { maintenance() }
    }
    private func maintenance() {
        guard !closedAdmission, !ioBusy, !busy else { return }
        let store = store, now = clock()
        perform({ try store.maintenance(now:now) },done:{ [weak self] result in if case .failure(let error) = result { self?.fail(error) } })
    }
    func isCurrent(_ review: Review, settings: SettingsStore, epoch: UUID, preparation: UUID?, allowIO: Bool = false) -> Bool {
        guard self.review === review, review.authority.current, !closedAdmission, (!ioBusy || allowIO),
              review.authority.selectionEpoch == epoch else { return false }
        preparationChanged(preparation)
        guard self.review === review, review.authority.authorize(settings),
              rows.contains(where:{$0.id == review.jobID && !$0.deleting}) else {
            invalidate("This transcript is out of date. Open it again."); return false
        }
        do {
            if review.accepted == nil, let token = review.token {try store.validateRAMReview(token,now:clock())}
            else {try store.validateReview(review.jobID,resultID:review.resultID,token:review.token,now:clock())}
        }
        catch { fail(error); invalidate("Couldn’t open this transcript. Try again in a moment."); return false }
        return true
    }
    func open(_ id: UUID, settings: Settings, epoch: UUID, preparation: UUID?) {
        invalidate()
        guard metadataReadiness == .ready, !closedAdmission, !busy, !ioBusy else { message = "Wait a moment, then open it again."; return }
        let authority = Authority(settings:settings,selectionEpoch:epoch,preparationEpoch:preparation), store = store, now = clock()
        opening = authority
        perform({ try store.openResult(id,now:now,authorized:{authority.current}) },done:{ [weak self] result in
            guard let self, self.opening === authority, authority.current, !self.closedAdmission else { return }
            self.opening = nil
            switch result {
            case .success(let (accepted,bytes)):
                self.review = Review(jobID:id,resultID:accepted.id,authority:authority,bytes:bytes,date:Date(timeIntervalSince1970:accepted.date),token:nil,observed:accepted.observed,accepted:accepted)
                if store.failure == nil {self.storageConcern = nil}
                self.message = "Saved transcript."
            case .failure(let error): self.fail(error)
            }
        })
    }
    func retrySaveResult(_ review: Review) {
        guard self.review === review, review.authority.current, review.accepted == nil, let token = review.token, !ioBusy, !closedAdmission else { return }
        let store = store, now = clock()
        perform({ try store.saveResult(token,resultID:review.resultID,bytes:review.bytes,observed:review.observed,now:now,resultDate:review.date,authorized:{ review.authority.current }) },done:{ [weak self] result in
            guard let self, self.review === review, review.authority.current else { return }
            switch result {
            case .success(let accepted): review.accepted = accepted; if store.failure == nil {self.storageConcern = nil}; self.message = "Transcript saved."; self.objectWillChange.send()
            case .failure(let error): self.fail(error)
            }
        })
    }
    func saveHistory(_ review: Review, settings: Settings, history: HistoryStore, currentSettings: @escaping () -> Settings?, authorized: @escaping () -> Bool) {
        guard self.review === review, review.authority.current, review.accepted != nil, !ioBusy, !closedAdmission else { return }
        guard settings.historyEnabled else { message = "History is off."; return }
        let store = store, now = clock()
        if review.historySaved {
            if review.recordFailed { recordHistorySaved(review,authorized:authorized) }; return
        }
        guard history.reload(countLimit:settings.historyTextCount), !history.loadBlocked else { review.historyFailed = true; message = "History couldn’t load. Try again from History."; return }
        let entry = HistoryEntry(id:review.resultID,date:review.date,raw:review.text)
        if review.associationUnknown {
            guard history.entries.contains(where:{$0.id == entry.id && $0.raw == entry.raw && $0.cleaned == nil && $0.date == entry.date && $0.appName == nil}) else {
                message = "Couldn’t tell whether this was saved to history. You can still copy or export it."; return
            }
            review.historySaved = true; recordHistorySaved(review,authorized:authorized); return
        }
        perform({ try store.association(review.jobID,resultID:review.resultID,state:.savingIntent,now:now,authorized:{review.authority.current}) },done:{ [weak self] result in
            guard let self, self.review === review, authorized() else { return }
            switch result {
            case .failure(let error): self.fail(error) // no History append without persisted intent
            case .success:
                guard let current = currentSettings(), current.historyEnabled, authorized(),
                      history.reload(countLimit:current.historyTextCount), !history.loadBlocked else {
                    review.associationUnknown = true
                    self.message = "History changed. Click Check history."; return
                }
                review.historySaved = history.appendReviewed(entry) // latch before any suspension
                review.historyFailed = !review.historySaved
                if review.historySaved { self.recordHistorySaved(review,authorized:authorized) }
                else {
                    self.message = "Couldn’t save to history. Try again."
                    self.perform({ try store.association(review.jobID,resultID:review.resultID,state:.notSaved,now:now,authorized:{review.authority.current}) },done:{ [weak self] result in
                        if case .failure(let error) = result { review.associationUnknown = true; self?.fail(error) }
                    })
                }
                self.objectWillChange.send()
            }
        })
    }
    private func recordHistorySaved(_ review: Review, authorized: @escaping () -> Bool) {
        let store = store, now = clock()
        review.recordFailed = true
        perform({ try store.association(review.jobID,resultID:review.resultID,state:.saved,now:now,authorized:{ review.authority.current }) },done:{ [weak self] result in
            guard let self, self.review === review else { return }
            switch result {
            case .success: review.recordFailed = false; review.associationUnknown = false; self.message = "Saved to history."
            case .failure(let error): self.fail(error); self.message = "Saved to history, but its status couldn’t be recorded. Try again."
            }
            self.objectWillChange.send()
        })
    }
    func delete(_ id: UUID) {
        guard !closedAdmission, deletionRequests.insert(id).inserted else { return }
        invalidate()
        let previousIO = Array(ioTasks.values)
        let store = store, execution = execution
        // Fence, persist intent, then join actual execution before owned unlink.
        perform({ try store.intentDelete(id) },done:{ [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deletionRequests.remove(id); self.fail(error)
                self.message = "Couldn’t delete the saved file. Try again."
                // Execution remains registered and joins even after the first intent failed.
                let wait = UUID()
                self.ioTasks[wait] = Task { @MainActor [weak self] in
                    await execution?.value; for task in previousIO { await task.value }
                    self?.ioTasks[wait] = nil
                }
            case .success:
                self.message = "Deleting…"
                let waitID = UUID()
                self.ioTasks[waitID] = Task { @MainActor [weak self] in
                    await execution?.value
                    for task in previousIO { await task.value }
                    await self?.waitForOutputIO()
                    guard let self else { return }
                    self.perform({ try store.finishDelete(id) },done:{ [weak self] result in
                        self?.deletionRequests.remove(id)
                        switch result {
                        case .success: if self?.store.failure == nil {self?.storageConcern = nil}; self?.message = "Deleted. History and exported files aren’t affected."
                        case .failure(let error): self?.fail(error)
                        }
                    })
                    self.ioTasks[waitID] = nil
                }
            }
        })
    }
    func beginOutputIO(_ review: Review) -> UUID? {
        guard self.review === review, review.authority.current, !closedAdmission else {return nil}
        let id = UUID(); outputIO.insert(id); ioBusy = true; return id
    }
    func endOutputIO(_ id: UUID) {
        outputIO.remove(id); ioBusy = !ioTasks.isEmpty || !outputIO.isEmpty
        if outputIO.isEmpty {let waiters = outputWaiters; outputWaiters = []; for waiter in waiters {waiter.resume()}}
    }
    @MainActor private func waitForOutputIO() async {
        await withCheckedContinuation {continuation in
            if outputIO.isEmpty {continuation.resume()} else {outputWaiters.append(continuation)}
        }
    }
    func reserveRestart() -> Bool {
        guard !closedAdmission else { return false }; restartReserved = true; closedAdmission = true; invalidate("Transcript closed."); return true
    }
    func releaseRestart() { restartReserved = false; if !shutdownReserved { closedAdmission = false } }
    func cancelShutdown() { shutdownReserved = false; if !restartReserved { closedAdmission = false } }
    @MainActor func drain() async {
        await execution?.value
        // New tasks can only be completion continuations of registered work.
        while !ioTasks.isEmpty { let tasks = Array(ioTasks.values); for task in tasks { await task.value } }
        await waitForOutputIO()
    }
    func restartReady() -> Bool { !busy && ioTasks.isEmpty && outputIO.isEmpty && storageConcern == nil && store.failure == nil }
    func beginShutdown(_ reply: @escaping (Bool) -> Void) {
        shutdownReserved = true; closedAdmission = true; invalidate("Transcript closed.")
        Task { @MainActor in await self.drain(); reply(self.restartReady()) }
    }
}

@MainActor enum SavedAudioImportExecution {
    private final class Completion { var value: Result<SavedAudioImportOwner.Completed,Error> = .failure(CancellationError()) }
    static func enqueue(previous:Task<Void,Never>?, admission:LocalCleanupAdmission, store:SavedAudioImportStore,
                        job:SavedAudioImportOwner.Job, settings:SettingsStore,
                        now:@escaping () -> Date = Date.init, enter:@escaping () async throws -> Void = {},
                        load:@escaping (RecognitionRequest) async throws -> RecognitionHandle,
                        done:@escaping (Result<SavedAudioImportOwner.Completed,Error>) -> Void) -> Task<Void,Never>? {
        guard admission.admit(job.operation) else { job.revoke(); job.operation.finish(); done(.failure(CancellationError())); return nil }
        let completion = Completion()
        return PendingOperationQueue.enqueue(previous:previous,operation:job.operation,completes:true,work:{
            let result = await recognize(store:store,job:job,settings:settings,now:now,enter:enter,load:load)
            await MainActor.run { completion.value = result }
        },finished:{
            job.source?.cancel()
            let result = await MainActor.run {completion.value}
            let final = await persist(result,store:store,job:job,settings:settings,now:now)
            await MainActor.run {admission.exited(job.operation); done(job.current ? final : .failure(CancellationError()))}
        })
    }
    // Leave the actor before the first synchronous read/commit. These functions
    // stay inside the existing processTask barrier; no second queue is created.
    nonisolated private static func recognize(store:SavedAudioImportStore,job:SavedAudioImportOwner.Job,settings:SettingsStore,
        now:@escaping () -> Date,enter:@escaping () async throws -> Void,
        load:@escaping (RecognitionRequest) async throws -> RecognitionHandle) async -> Result<SavedAudioImportOwner.Completed,Error> {
            do {
                let requested = try SavedAudioImportStore.Provenance(request:job.authority.configuration.request)
                let decoded: ImportedAudio.SourceDecoded
                var sourceBorrow: SavedAudioImportStore.Borrow?
                defer { sourceBorrow?.end() }
                let token: SavedAudioImportStore.AttemptToken
                let authorized = { job.current && job.authority.authorize(settings) }
                if let source = job.source {
                    let snapshot = try source.readValidated(retainEncoded:true,canceled:{!job.current})
                    guard let bytes = snapshot.encodedData, let original = snapshot.original, authorized() else { throw CancellationError() }
                    decoded = snapshot.decoded
                    try store.maintenance(now:now())
                    token = try store.admit(id:job.id,bytes:bytes,original:original,facts:.init(decoded.transientSourceInfo),label:source.displayName,requested:requested,now:now(),startedUptime:snapshot.startedUptime,priorWorkCredits:snapshot.workCredits,authorized:authorized)
                } else {
                    try store.maintenance(now:now())
                    token = try store.begin(job.id,requested:requested,now:now(),authorized:authorized)
                    job.token = token
                    sourceBorrow = try store.borrow(token,now:now())
                    let snapshot = try store.sourceSnapshot(token,now:now(),authorized:authorized)
                    let format: ImportedAudio.SourceFormat = snapshot.facts.profile == .wavPCM ? .wav : .mov
                    decoded = try ImportedAudio.decodeSource(snapshot.bytes,format:format,canceled:{!job.current})
                    if snapshot.facts.profile == .qtPCM16kV1 {
                        guard SavedAudioImportStore.Facts(decoded.transientSourceInfo) == snapshot.facts else { throw SavedAudioImportStorage.Failure.changed }
                    }
                }
                job.token = token
                if sourceBorrow == nil { sourceBorrow = try store.borrow(token,now:now()) }
                try store.running(token,now:now())
                let recognition = try await FileRecognitionBatch.runResult(request:job.authority.configuration.request,operation:job.operation,
                    samples:{decoded.samples},validate:{ guard authorized() else { throw CancellationError() }; try store.validateAttempt(token,now:now()) },active:{job.current},authorize:authorized,
                    rawOnly:true,enter:{ try store.validateAttempt(token,now:now()); try await enter(); try store.validateAttempt(token,now:now()) },
                    load:{ request in try store.validateAttempt(token,now:now()); return try await load(request) })
                guard authorized() else { throw CancellationError() }
                let bytes = Data(recognition.raw.utf8), observed = try SavedAudioImportStore.Provenance(observed:recognition.observedIdentity)
                let resultDate = Date(timeIntervalSince1970:now().timeIntervalSince1970)
                let completed = SavedAudioImportOwner.Completed(token:token,raw:bytes,observed:observed,accepted:nil,saveFailure:nil,resultDate:resultDate)
                return .success(completed)
            } catch {
                if let token = job.token { try? store.finish(token,canceled:!job.current) }
                return .failure(error)
            }
    }
    // Recognition/source borrows have actually exited before this function runs.
    nonisolated private static func persist(_ input:Result<SavedAudioImportOwner.Completed,Error>,
        store:SavedAudioImportStore,job:SavedAudioImportOwner.Job,settings:SettingsStore,
        now:@escaping () -> Date) async -> Result<SavedAudioImportOwner.Completed,Error> {
            var result = input
            if job.current, case .success(let native) = result {
                let accepted: SavedAudioImportStore.Accepted?, failure: Error?
                if let storageFailure = store.failure {accepted = nil; failure = storageFailure}
                else {
                    do {
                        accepted = try store.saveResult(native.token,resultID:job.resultID,bytes:native.raw,observed:native.observed,
                            now:now(),resultDate:native.resultDate,authorized:{job.current && job.authority.authorize(settings)})
                        failure = nil
                    } catch {
                        accepted = nil; failure = error
                        try? store.finish(native.token,canceled:!job.current)
                    }
                }
                result = .success(.init(token:native.token,raw:native.raw,observed:native.observed,accepted:accepted,saveFailure:failure,resultDate:native.resultDate))
            }
            return result
    }
}
