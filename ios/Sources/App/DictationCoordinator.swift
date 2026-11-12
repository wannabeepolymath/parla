import Foundation
import UIKit
import Combine
import ActivityKit
import WidgetKit
import ParlaCore

@MainActor final class DictationCoordinator: ObservableObject {
    static let shared = DictationCoordinator()
    let library = LibraryStore()
    let settings: AppSettings
    let models = ModelDownloads()
    @Published private(set) var session: DictationSession?
    @Published private(set) var isStarting = false
    @Published var message: String?
    @Published var lastResult = ""
    @Published var route = "Home"
    @Published private var draft = NoteEditorDraft()
    var noteDraft: String { get { draft.text } set { draft.text = newValue } }
    var draftNoteID: UUID? { draft.id }
    var noteEditorOpen: Bool { draft.isOpen }
    @Published var isManagingSpeechAssets = false
    private var resultExpires: Date?
    private let capture = AudioCapture()
    @Published private var work: Task<Void, Never>?
    private var timer: Timer?
    private var started: Date?
    private var activity: Activity<RecordingActivity>?
    private var activityMonitor: Task<Void, Never>?
    private var maintenanceCounter = 0
    private var unretired: DictationSession?
    private let backgroundTime = ProcessingBackgroundTime()
    var recording: Bool { session?.phase == .recording }
    // Shared storage may still say processing after a failed publication; only local work is busy.
    var busy: Bool { isStarting || recording || work != nil }
    var inputName: String { capture.inputName }
    private init() {
        settings = AppSettings(root: library.root)
        do {
            try library.prepareDirectories(); try library.sweepAudio()
            if let stale = try SessionStore().read(), [.recording, .processing].contains(stale.phase) {
                try SessionStore().update(id: stale.id, generation: stale.generation) {
                    $0.phase = .failed; $0.error = "The previous dictation ended when Parla closed. Start a new dictation."; $0.result = nil
                }
            }
            session = try SessionStore().read()
        } catch { message = error.localizedDescription }
        let staleActivities = Activity<RecordingActivity>.activities
        Task { for activity in staleActivities { await activity.end(nil, dismissalPolicy: .immediate) } }
        capture.onInvalidated = { [weak self] in self?.cancel(reason: "Recording stopped because the microphone changed or another app interrupted it. Start again when ready.") }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func foreground() {
        settings.reload()
        do { try library.reload(); try library.sweepAudio() }
        catch { message = error.localizedDescription }
        tick()
    }
    func start(destination: DeliveryDestination = .app, pending: DictationSession? = nil, requiresActivity: Bool = false) {
        guard UIApplication.shared.applicationState == .active else { message = ParlaError.unavailable.localizedDescription; return }
        guard !busy, work == nil, !isManagingSpeechAssets else { return }
        do {
            if let issue = DictationEngine.recognitionIssue(settings.current) { route = "Models"; throw ParlaError.message(issue) }
            let store = try SessionStore()
            let request: DictationSession
            if let pending {
                guard let current = try store.read(), current.id == pending.id, current.generation == pending.generation,
                      current.phase == .requested else { throw ParlaError.message("This keyboard request has expired. Request dictation again from the keyboard.") }
                request = current
            } else { request = try store.request(destination: destination) }
            session = request; isStarting = true; message = nil; lastResult = ""
            work = Task {
                do {
                    // AudioRecordingIntent requires an active Live Activity before capture.
                    if requiresActivity { try beginActivity(request) }
                    try await capture.start(microphoneID: library.library.preferences.microphoneID, feedback: library.library.preferences.feedback)
                    try Task.checkCancellation()
                    let owned = try store.updateSnapshot(id: request.id, generation: request.generation) {
                        guard $0.phase == .requested else { throw CancellationError() }
                        $0.phase = .recording; $0.expires = Date().addingTimeInterval(330)
                    }
                    guard let owned else { throw CancellationError() }
                    started = Date(); isStarting = false; session = owned; work = nil
                    if !requiresActivity { try? beginActivity(request) }
                    if library.library.preferences.feedback { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    WidgetCenter.shared.reloadAllTimelines()
                } catch {
                    capture.stop(feedback: false)
                    isStarting = false; work = nil; endActivity()
                    fail(request, error: error)
                }
            }
        } catch { message = error.localizedDescription }
    }
    private func beginActivity(_ request: DictationSession) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw ParlaError.message("Enable Live Activities for Parla in iPhone Settings before using a recording shortcut. You can still record inside the app.") }
        let state = RecordingActivity.ContentState(phase: "Listening", started: Date(), words: 0)
        activity = try Activity.request(attributes: RecordingActivity(sessionID: request.id, generation: request.generation),
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(65)), pushType: nil)
        if let activity {
            activityMonitor?.cancel()
            activityMonitor = Task {
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    if state == .dismissed || state == .ended {
                        guard session?.id == request.id, session?.generation == request.generation else { return }
                        if recording || isStarting { cancel(reason: "The Live Activity ended. Open Parla to start a new recording.") }
                        return
                    }
                }
            }
        }
    }
    func stop() {
        guard recording, let request = session else { return }
        let samples = capture.stop(feedback: library.library.preferences.feedback)
        let duration = Date().timeIntervalSince(started ?? Date())
        do {
            guard let owned = try SessionStore().updateSnapshot(id: request.id, generation: request.generation, {
                guard $0.phase == .recording else { throw CancellationError() }
                $0.phase = .processing; $0.command = .none; $0.expires = Date().addingTimeInterval(600)
            }) else { cancel(); return }
            session = owned
            if let activity {
                Task { await activity.update(ActivityContent(state: .init(phase: "Processing", started: started ?? Date(), words: 0), staleDate: Date().addingTimeInterval(180))) }
            }
            process(request: request, samples: samples, duration: duration)
        } catch { cancel(reason: error.localizedDescription) }
    }
    func cancel(reason: String? = nil) {
        if let session { try? SessionStore().command(.cancel, id: session.id, generation: session.generation) }
        work?.cancel()
        capture.stop(feedback: false)
        started = nil; lastResult = ""
        // A permission request cannot be dismissed programmatically; keep its Task until it returns.
        // Keep the cancelled task until its cleanup returns; a new capture cannot overlap it.
        // Retain the old request identity until its cancelled Task has finished cleanup.
        // Otherwise the next poll could cancel a replacement request it does not own.
        if work == nil { session = try? SessionStore().read() }
        else { session?.phase = .cancelled; session?.result = nil }
        message = reason
        endActivity(); endBackgroundTask()
    }
    /// Retained audio re-runs recognition with today's settings; without audio, only cleanup runs on the raw text.
    func retry(_ transcript: Transcript) {
        guard !busy, work == nil, !isManagingSpeechAssets else { return }
        var created: DictationSession?
        do {
            var samples: [Float]?
            if let source = transcript.audioName.flatMap({ library.audioURL($0) }), FileManager.default.fileExists(atPath: source.path) {
                samples = try Eval.loadSamples(url: source)
                if let issue = DictationEngine.recognitionIssue(settings.current) { route = "Models"; throw ParlaError.message(issue) }
            }
            guard samples != nil || !transcript.raw.isEmpty else { throw ParlaError.message("No retained audio or raw text is available. Record again.") }
            let request = try SessionStore().request(destination: .app)
            created = request; session = request; lastResult = ""; resultExpires = nil; message = nil
            guard let owned = try SessionStore().updateSnapshot(id: request.id, generation: request.generation, {
                guard $0.phase == .requested else { throw CancellationError() }
                $0.phase = .processing; $0.expires = Date().addingTimeInterval(600)
            }) else { throw CancellationError() }
            session = owned
            process(request: request, samples: samples, duration: transcript.duration, existingRaw: samples == nil ? transcript.raw : nil)
        } catch { if let created { fail(created, error: error) }; message = error.localizedDescription }
    }
    private func process(request: DictationSession, samples: [Float]?, duration: TimeInterval, existingRaw: String? = nil) {
        backgroundTime.start { [weak self] in
            self?.cancel(reason: "iOS ended background processing. Return to Parla and try again.")
        }
        let snapshot = settings.current
        let pipeline = DictationEngine.pipeline(snapshot, credentials: settings.store.credentials)
        // Pipeline reports a missing key only as "cleanup failed"; name the configuration problem instead.
        let issue = cleanupConfigurationIssue(settings: snapshot, env: [:], credentials: settings.store.credentials)
        work = Task {
            var raw = existingRaw ?? ""
            var outcome: DictationEngine.Outcome?
            var failure: String?
            let operation = PendingOperation(name: "Parla dictation")
            do {
                if let samples {
                    raw = try await withTaskCancellationHandler {
                        try await DictationEngine.recognize(samples, pipeline: pipeline) { try await DictationEngine.localRecognizer(snapshot, operation: operation) }
                    } onCancel: { operation.revoke() }
                }
                try Task.checkCancellation()
                outcome = await DictationEngine.finish(raw: raw, pipeline: pipeline)
            } catch is CancellationError { cleanupOperation(); return }
            catch { failure = error.localizedDescription }
            let final = outcome?.final ?? ""
            let note = failure ?? outcome?.cleanupFailure.map { "Cleanup did not apply (\(($0 == "cleanup failed" ? issue : nil) ?? $0)). The raw transcript was kept." }
            var retained = false
            do {
                try Task.checkCancellation()
                // The ownership lock covers both the local save and publication.
                let owned = try SessionStore().complete(request, final: final, failure: failure, note: note, save: {
                    try library.reload()
                    var savedAudio: URL?
                    var transcript = Transcript(id: request.id, raw: raw, cleaned: outcome?.cleaned, final: outcome?.final, duration: duration, error: note)
                    do {
                        if library.library.preferences.retention != .never, let samples {
                            let target = library.audioDirectory.appendingPathComponent("\(request.id).wav")
                            // Also remove a partial WAV if the writer throws.
                            savedAudio = target
                            try RecordingStore.writeWAV(samples, to: target); transcript.audioName = target.lastPathComponent
                        }
                        try library.mutate { state in
                            if state.preferences.retention != .never { state.transcripts.insert(transcript, at: 0) }
                            if failure == nil, !final.isEmpty, request.destination == .note { state.notes.insert(Note(text: final), at: 0) }
                        }
                    } catch { if let savedAudio { try? FileManager.default.removeItem(at: savedAudio) }; throw error }
                }, retain: { current in
                    lastResult = final; resultExpires = current.expires; message = current.error; retained = true
                })
                if let owned {
                    session = owned
                    // Clipboard write is only the explicit clipboard shortcut's destination; never a keyboard fallback.
                    if failure == nil, !final.isEmpty, request.destination == .clipboard {
                        if UIApplication.shared.applicationState == .active {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: final]], options: [.localOnly: true, .expirationDate: owned.expires])
                            message = [message, "Copied to clipboard for two minutes."].compactMap { $0 }.joined(separator: " ")
                        } else { message = [message, "Text is ready. Return to Parla and tap Copy; iOS does not guarantee background clipboard access."].compactMap { $0 }.joined(separator: " ") }
                    }
                }
            } catch is CancellationError { }
            catch {
                if retained {
                    message = [message, "Couldn't share this result with the keyboard. Copy it from Parla."].compactMap { $0 }.joined(separator: " ")
                    retireShared(request)
                } else { fail(request, error: error) }
            }
            cleanupOperation()
        }
    }
    private func cleanupOperation() {
        started = nil; work = nil; session = try? SessionStore().read()
        endActivity(); endBackgroundTask()
    }
    /// A processing session left behind by a failed shared write would block Start until it expires; tick retries until storage recovers.
    private func retireShared(_ request: DictationSession) {
        do {
            try SessionStore().update(id: request.id, generation: request.generation) { $0.phase = .failed; $0.error = "Copy this result from Parla."; $0.result = nil }
            unretired = nil
        } catch { unretired = request }
    }
    private func fail(_ request: DictationSession, error: Error) {
        guard !(error is CancellationError) else { session = try? SessionStore().read(); return }
        message = error.localizedDescription
        _ = try? SessionStore().update(id: request.id, generation: request.generation) { $0.phase = .failed; $0.error = error.localizedDescription; $0.result = nil }
        session = try? SessionStore().read()
    }
    private func tick() {
        if let resultExpires, Date() >= resultExpires { lastResult = ""; self.resultExpires = nil }
        do {
            // Bound capture independently of shared-session identity or availability.
            if recording, capture.conversionFailed { cancel(reason: "Microphone audio could not be converted for recognition. Start again."); return }
            if recording, capture.limitReached || Date().timeIntervalSince(started ?? Date()) >= 300 { stop(); return }
            if !busy, let unretired { retireShared(unretired) }
            let current = try SessionStore().read()
            if busy {
                // session remains the local operation's identity until teardown completes.
                guard let own = session, let current, own.id == current.id,
                      own.generation == current.generation, current.active,
                      current.command != .cancel else { cancel(); return }
                if current.command == .stop && recording { stop(); return }
            }
            if !busy { session = current }
            maintenanceCounter += 1
            if maintenanceCounter >= 150 { maintenanceCounter = 0; try library.reload(); try library.sweepAudio() }
        } catch { if busy { cancel(reason: "Parla could not save this dictation. Recording was cancelled. Please try again.") } }
    }
    private func endActivity() {
        activityMonitor?.cancel(); activityMonitor = nil
        if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        activity = nil; WidgetCenter.shared.reloadAllTimelines()
    }
    private func endBackgroundTask() {
        backgroundTime.end()
    }
    func startFromIntent(destination: DeliveryDestination) async throws {
        guard UIApplication.shared.applicationState == .active, !busy, work == nil, !isManagingSpeechAssets else { throw ParlaError.unavailable }
        start(destination: destination, pending: destination == .app && session?.phase == .requested ? session : nil, requiresActivity: true)
        guard let operation = work else { throw ParlaError.message(message ?? "Could not begin recording.") }
        await withTaskCancellationHandler { await operation.value } onCancel: { Task { @MainActor in self.cancel() } }
        try Task.checkCancellation()
        guard recording else { throw ParlaError.message(message ?? "Recording did not start.") }
    }
    func openNoteEditor(_ note: Note) {
        draft.open(note)
    }
    func closeNoteEditor() { draft.close() }
    func saveDraft() throws {
        let note = try draft.noteToSave()
        try library.save(note); draft.text = ""; draft.id = nil
    }
}

struct NoteEditorDraft {
    var text = ""
    var id: UUID?
    private(set) var isOpen = false
    mutating func open(_ note: Note) { text = note.text; id = note.id; isOpen = true }
    mutating func close() { text = ""; id = nil; isOpen = false }
    func noteToSave() throws -> Note {
        guard isOpen else { throw ParlaError.message("Open a note in Scratchpad before saving the current note.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParlaError.message("Write a note first.") }
        return Note(id: id ?? UUID(), text: text)
    }
}

@MainActor final class ProcessingBackgroundTime {
    typealias Begin = (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    private let begin: Begin
    private let finish: (UIBackgroundTaskIdentifier) -> Void
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation = UUID()
    init(begin: @escaping Begin, finish: @escaping (UIBackgroundTaskIdentifier) -> Void) {
        self.begin = begin; self.finish = finish
    }
    convenience init() {
        self.init(begin: { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { Task { @MainActor in expiration() } }
        }, finish: { UIApplication.shared.endBackgroundTask($0) })
    }
    func start(onExpiration: @escaping @MainActor () -> Void) {
        end()
        let token = UUID(); generation = token
        identifier = begin { [weak self] in
            guard let self, generation == token, identifier != .invalid else { return }
            onExpiration(); end()
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        let owned = identifier; identifier = .invalid; generation = UUID(); finish(owned)
    }
}
