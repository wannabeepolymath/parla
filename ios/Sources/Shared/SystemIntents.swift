import AppIntents
import Foundation

private enum IntentExecution {
    static func requireContainingApp() throws { throw ParlaError.unavailable }
}

struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Parla recording"
    static var description = IntentDescription("Stop the active Parla session and transcribe it. Open Parla if iOS has suspended processing.")
    @Parameter(title: "Session ID") var sessionID: String?
    @Parameter(title: "Generation") var generation: String?
    init() {}
    init(session: UUID, generation: UUID) { self.sessionID = session.uuidString; self.generation = generation.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        let store = try SessionStore()
        guard let session = try store.read(), session.phase == .recording else { throw ParlaError.message("There is no active recording.") }
        if let sessionID, session.id.uuidString != sessionID { throw ParlaError.message("That recording has ended.") }
        if let generation, session.generation.uuidString != generation { throw ParlaError.message("That recording has ended.") }
        try store.command(.stop, id: session.id, generation: session.generation)
        #if PARLA_APP
        DictationCoordinator.shared.foreground()
        if DictationCoordinator.shared.recording { DictationCoordinator.shared.stop() }
        #endif
        return .result()
    }
}
struct CancelRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel Parla recording"
    @Parameter(title: "Session ID") var sessionID: String
    @Parameter(title: "Generation") var generation: String
    init() { sessionID = ""; generation = "" }
    init(session: UUID, generation: UUID) { sessionID = session.uuidString; self.generation = generation.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        let store = try SessionStore()
        if let session = try store.read(), session.id.uuidString == sessionID, session.generation.uuidString == generation {
            try store.command(.cancel, id: session.id, generation: session.generation)
            #if PARLA_APP
            DictationCoordinator.shared.cancel()
            #endif
        }
        return .result()
    }
}
struct StartRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Start Parla recording"
    static var description = IntentDescription("Open Parla and start a foreground recording. Requires microphone permission, a downloaded speech model, and Live Activities.")
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        try await DictationCoordinator.shared.startFromIntent(destination: .app)
        #else
        try IntentExecution.requireContainingApp()
        #endif
        return .result()
    }
}
struct ToggleRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Toggle Parla recording"
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        let coordinator = DictationCoordinator.shared
        if coordinator.recording { coordinator.stop() }
        else { try await coordinator.startFromIntent(destination: .app) }
        #else
        try IntentExecution.requireContainingApp()
        #endif
        return .result()
    }
}
struct DictateToClipboardIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Quick dictation to clipboard"
    static var description = IntentDescription("Open Parla to record. Stop in Parla or its Live Activity. Text is copied while the app is foreground; otherwise open Parla and tap Copy.")
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        try await DictationCoordinator.shared.startFromIntent(destination: .clipboard)
        #else
        try IntentExecution.requireContainingApp()
        #endif
        return .result()
    }
}
struct DictateToNotesIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Quick dictation to Scratchpad"
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        DictationCoordinator.shared.route = "Scratchpad"
        try await DictationCoordinator.shared.startFromIntent(destination: .note)
        #else
        try IntentExecution.requireContainingApp()
        #endif
        return .result()
    }
}
struct OpenNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Parla Scratchpad"
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        DictationCoordinator.shared.route = "Scratchpad"
        #endif
        return .result()
    }
}
struct TextToNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Parla note from text"
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Text") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_000_000 else { throw ParlaError.message("Supply a nonempty note under 1 MB.") }
        try DictationCoordinator.shared.library.save(Note(text: text))
        DictationCoordinator.shared.route = "Scratchpad"
        #else
        try IntentExecution.requireContainingApp()
        #endif
        return .result()
    }
}
struct SaveNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Save current Parla note"
    static var description = IntentDescription("Save the current unsaved editor draft in Parla. A draft must already be open in this app process.")
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        #if PARLA_APP
        try DictationCoordinator.shared.saveDraft()
        #else
        try IntentExecution.requireContainingApp()
        #endif
        return .result()
    }
}
#if PARLA_APP
struct ParlaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Start recording with \(.applicationName)"], shortTitle: "Start recording", systemImageName: "mic")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["Stop recording with \(.applicationName)"], shortTitle: "Stop recording", systemImageName: "stop.fill")
        AppShortcut(intent: DictateToClipboardIntent(), phrases: ["Dictate to clipboard with \(.applicationName)"], shortTitle: "Dictate to clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: DictateToNotesIntent(), phrases: ["Dictate a note with \(.applicationName)"], shortTitle: "Dictate a note", systemImageName: "note.text")
        AppShortcut(intent: OpenNotesIntent(), phrases: ["Open \(.applicationName) notes"], shortTitle: "Open Scratchpad", systemImageName: "note.text")
    }
}
#endif
