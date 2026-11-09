import AVFoundation
import Foundation
import ParlaCore

/// The actual queue entry used by AppDelegate. Tests inject only acquisition,
/// settings authorization and completion; file loading and final ASR stay real.
enum RecoveryTranscription {
    static func acquire(request: RecognitionRequest, operation: PendingOperation,
                        snapshot: () async -> (RecognitionClient?, String?),
                        verify: (String) throws -> Void,
                        load: (String) throws -> RecognitionClient) async throws -> RecognitionHandle {
        let (resident, path) = await snapshot()
        guard !operation.shouldAbort else { throw CancellationError() }
        return try RecognitionHandle(request: request, residentPath: path, resident: resident, diagnostics: operation.diagnostics) { path in
            try verify(path)
            guard !operation.shouldAbort else { throw CancellationError() }
            return try load(path)
        }
    }

    /// Shared production batch body. Only lease/audio IO is replaceable in native-free origin tests.
    static func batch(request: RecognitionRequest, operation: PendingOperation,
                      samples read: () throws -> [Float], validate: () throws -> Void, active: @escaping () -> Bool,
                      authorize: () -> Bool, enter: () async throws -> Void = {}, load: (RecognitionRequest) async throws -> RecognitionHandle) async throws -> String {
        try await FileRecognitionBatch.run(request: request, operation: operation, samples: read,
            validate: validate, active: active, authorize: authorize, enter: enter, load: load)
    }

    static func enqueue(previous: Task<Void, Never>?, recordings: RecordingStore,
                        lease: RecordingStore.Lease, request: RecognitionRequest,
                        authorize: @escaping () -> Bool,
                        enter: @escaping () async throws -> Void = {},
                        load: @escaping (RecognitionRequest) async throws -> RecognitionHandle,
                        done: @escaping (Result<String, Error>) -> Void) -> Task<Void, Never> {
        PendingOperationQueue.enqueue(previous: previous, operation: lease.operation, completes: true, work: {
            var text: String?
            let result: Result<String, Error>
            do {
                let raw = try await batch(request: request, operation: lease.operation,
                    samples: { try recordings.samples(lease) }, validate: { try recordings.validate(lease) },
                    active: { recordings.isActive(lease) }, authorize: authorize, enter: enter, load: load)
                text = raw // retain before disposal, independently of later text storage
                result = .success(raw)
            } catch {
                if let reason = error as? ParakeetInstallationRefusal { result = .failure(RecordingStore.Failure(reason.message)) }
                else if let reason = error as? PreparationRefusal { result = .failure(RecordingStore.Failure(reason.description)) }
                else { result = .failure((error as? RecordingStore.Failure) ?? RecordingStore.Failure("Transcription failed. The audio is still saved.")) }
            }
            // Complete and publish on the same main turn as Cancel. If Cancel
            // won, it has already released the lease, preserving the source.
            await MainActor.run { [text] in
                guard !lease.operation.shouldAbort else { return }
                recordings.complete(lease, transcript: text)
                done(result)
            }
        }, finished: { recordings.release(lease) })
    }
}

protocol RecoveryAudioPlaying: AnyObject {
    func play(url: URL, finished: @escaping (Bool) -> Void) throws
    func stop()
}

private final class LocalRecoveryPlayer: NSObject, RecoveryAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: ((Bool) -> Void)?
    func play(url: URL, finished: @escaping (Bool) -> Void) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        self.player = player; self.finished = finished; player.delegate = self
        guard player.play() else { stop(); throw RecordingStore.Failure("Couldn’t play the audio.") }
    }
    func stop() { player?.stop(); player = nil; finished = nil }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { complete(flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { complete(false) }
    private func complete(_ success: Bool) { let callback = finished; stop(); callback?(success) }
}

/// One short-lived player. No player is constructed until explicit Play.
final class RecoveryPlayback {
    var factory: () -> RecoveryAudioPlaying = { LocalRecoveryPlayer() }
    private var player: RecoveryAudioPlaying?
    private var lease: RecordingStore.Lease?
    private var store: RecordingStore?
    var id: String? { lease?.url.lastPathComponent }
    func start(url: URL, store: RecordingStore, now: Date, finished: @escaping (Bool) -> Void) throws {
        stop()
        let lease = try store.acquire(url, now: now, onRevoke: { [weak self] in self?.stop() })
        self.lease = lease; self.store = store
        do {
            try store.validate(lease, now: now)
            let player = factory(); self.player = player
            try player.play(url: lease.url) { [weak self] success in self?.stop(); finished(success) }
        } catch { stop(); throw error }
    }
    func stop() {
        player?.stop(); player = nil
        let previous = lease; lease = nil
        if let previous { store?.release(previous) }
        store = nil
    }
    deinit { stop() }
}

struct RecoveryPreview {
    let request: RecognitionRequest
    let sourceID: String
    let date: Date
    let operation: PendingOperation
    var token: UUID { operation.id }
    var loading = true
    var entry: HistoryEntry?
    var saved = false
    var saveFailed = false
    var error: String?
}

extension HubModel {
    func refreshRecoveryProjection() {
        recoveryRows = recordings.descriptors(now: recoveryClock())
        recordingSummary = recordings.summary()
        recoveryPolicyStatus = recordings.policyStatus
        recoveryStoreError = recordings.lastError
        playingRecordingID = recoveryPlayback.id
    }
    func refreshRecovery() {
        flushPendingSave()
        let current = store.load()
        recordings.configure(settings: current, error: store.lastError, now: recoveryClock())
        if store.lastError != nil { loadError = store.lastError }
        refreshRecoveryProjection()
    }
    private func recoverySettings() -> Settings? {
        refreshRecovery()
        guard loadError == nil, saveError == nil, store.lastError == nil, recordings.policy != nil else {
            recoveryMessage = "Fix settings.json before transcribing or saving."
            return nil
        }
        return store.load()
    }
    func playRecovery(_ url: URL) {
        guard !microphoneTest.ownsSession else {
            recoveryMessage = "Stop the microphone test first."; return
        }
        refreshRecovery()
        do {
            try recoveryPlayback.start(url: url, store: recordings, now: recoveryClock()) { [weak self] success in
                self?.recoveryMessage = success ? "Playback finished." : "Couldn’t play the audio."
                self?.refreshRecoveryProjection()
            }
            recoveryMessage = "Playing…"
        } catch { recoveryMessage = (error as? RecordingStore.Failure)?.message ?? "Couldn’t play the audio." }
        refreshRecoveryProjection()
    }
    func stopRecoveryPlayback() { recoveryPlayback.stop(); refreshRecoveryProjection() }
    func deleteRecovery(_ url: URL) {
        if recoveryPlayback.id == url.lastPathComponent { stopRecoveryPlayback() }
        refreshRecovery()
        recoveryMessage = recordings.delete(url, now: recoveryClock()) ? "Audio deleted." : recordings.lastError
        refreshRecoveryProjection()
    }
    func clearRecovery() {
        stopRecoveryPlayback(); refreshRecovery()
        recoveryMessage = recordings.clear(now: recoveryClock()).message
        refreshRecoveryProjection()
    }
    func transcribeRecovery(_ url: URL) {
        guard recoveryPreview?.loading != true, recoveryOperation?.hasExited != false, let current = recoverySettings() else { return }
        if recoveryPlayback.id == url.lastPathComponent { stopRecoveryPlayback() }
        do {
            let lease = try recordings.acquire(url, now: recoveryClock())
            let request = RecognitionRequest(settings: current) // GLOBAL, historical context is unknown
            lease.operation.observe(in: diagnostics, origin: .recovery)
            lease.operation.diagnostics?.recognition(request: request)
            lease.operation.diagnostics?.disposition(.previewOnly, delivery: .notAttempted)
            let preview = RecoveryPreview(request: request, sourceID: url.lastPathComponent, date: recoveryClock(), operation: lease.operation)
            recoveryPreview = preview
            recoveryLease = lease
            recoveryOperation = lease.operation
            onRecoveryTranscribe(lease, request) { [weak self, recordings] result in
                // Default/unavailable callbacks also release ownership; production
                // already resolved success before delivering this completion.
                recordings.complete(lease, transcript: nil)
                lease.operation.finish()
                guard let self, self.recoveryPreview?.token == preview.token else { return }
                self.recoveryLease = nil
                var completed = preview; completed.loading = false
                switch result {
                case .success(let text):
                    var metrics = PipelineMetrics()
                    metrics.model = request.metricLabel
                    completed.entry = HistoryEntry(date: preview.date, raw: text, metrics: metrics)
                case .failure(let error): completed.error = (error as? RecordingStore.Failure)?.message ?? "Transcription failed."
                }
                self.recoveryPreview = completed
                self.refreshRecoveryProjection()
            }
            refreshRecoveryProjection()
        } catch { recoveryMessage = (error as? RecordingStore.Failure)?.message ?? "This audio is no longer available. Click Refresh." }
    }
    /// Cancel is not Delete. Revoke preview/save and release the original file
    /// before asking the queued/native request to stop.
    func discardRecovery() {
        let previous = recoveryPreview
        recoveryPreview = nil
        previous?.operation.revoke()
        if let lease = recoveryLease { recordings.release(lease) }
        recoveryLease = nil
        previous?.operation.requestAbort()
        recoveryMessage = "Transcript discarded. The audio is still saved."
        refreshRecoveryProjection()
    }
    func copyRecovery() { if let entry = recoveryPreview?.entry { copy(entry.raw) } }
    func saveRecovery() {
        guard let current = recoverySettings(), var preview = recoveryPreview,
              !preview.loading, !preview.saved, let entry = preview.entry else { return }
        guard current.historyEnabled else { recoveryMessage = "History is off. Turn it on to save, or copy the text."; return }
        // An external invalid history file must not be replaced from an old in-memory projection.
        history.reload(countLimit: current.historyTextCount)
        guard !history.loadBlocked else { recoveryMessage = "History couldn’t load. Try again from History."; return }
        preview.saved = history.append(entry)
        preview.saveFailed = !preview.saved
        recoveryPreview = preview
        recoveryMessage = preview.saved ? "Saved to history." : "Couldn’t save to history. Try again."
    }
}
