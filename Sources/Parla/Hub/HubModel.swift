import AppKit
import AVFoundation
import Combine
import ParlaCore
import ServiceManagement

/// UI state for the Hub window, bridging the existing stores. Main-thread only
/// (same contract as HUD) — mutations come from SwiftUI or AppDelegate on main.
final class HubModel: ObservableObject {
    struct WordRow: Identifiable, Equatable {
        let id = UUID()
        var text = ""
    }
    struct SnippetRow: Identifiable, Equatable {
        let id = UUID()
        var trigger = ""
        var expansion = ""
    }

    let store: SettingsStore
    let history: HistoryStore
    // Wired by AppDelegate to its existing actions.
    var onDownloadModel: (ModelCatalog.Model) -> Void = { _ in }
    var onOpenSettingsFile: () -> Void = {}
    var onSaved: () -> Void = {}
    /// Onboarding's sandboxed tryout, wired straight to the recorder and whisper
    /// by AppDelegate — never through the dictation machine, so the transcript
    /// can only ever come back here. Start returns why it refused, nil = live.
    var onTryoutStart: () -> String? = { "Not available" }
    // @escaping: the completion outlives the call — transcription finishes well
    // after tryoutStop returns.
    var onTryoutStop: (@escaping (String) -> Void) -> Void = { $0("") }

    @Published var settings = Settings() { didSet { touch() } }
    @Published var words: [WordRow] = [] { didSet { touch() } }
    @Published var snippets: [SnippetRow] = [] { didSet { touch() } }
    /// settings.json decode error. Editing is disabled while non-nil so the hub
    /// never clobbers a file the user needs to hand-fix (same rule as the menu).
    @Published var loadError: String?
    @Published var saveError: String?
    @Published var modelLoaded = false
    @Published var downloadProgress: Double? // non-nil while downloading
    @Published var downloadingModel: ModelCatalog.Model?
    /// Why the last download failed, nil once another one starts.
    @Published var downloadError: String?
    @Published var historyEntries: [HistoryEntry] = []
    @Published var launchAtLogin = false
    @Published var micGranted = false
    @Published var axGranted = false
    /// Why the last recorded shortcut was refused, nil when nothing was.
    @Published var hotkeyError: String?

    private var loading = false
    private var saveItem: DispatchWorkItem?

    init(store: SettingsStore, history: HistoryStore) {
        self.store = store
        self.history = history
    }

    var modelPath: String {
        settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath()
    }

    func isSelected(_ model: ModelCatalog.Model) -> Bool {
        ModelCatalog.path(for: model) == modelPath
    }

    /// Point Parla at an already-downloaded model. The debounced save fires
    /// AppDelegate's onSaved, which reloads the context when the path changed.
    func selectModel(_ model: ModelCatalog.Model) {
        settings.whisperModelPath = ModelCatalog.path(for: model)
    }

    /// Re-read everything from disk — called when the window opens/becomes key
    /// so external edits (settings file, new dictations) show up.
    func refresh() {
        // Becoming key must not clobber a pending edit: flush any debounced
        // save before re-reading from disk, or the reload below discards it.
        flushPendingSave()
        loading = true
        defer { loading = false }
        settings = store.load()
        loadError = store.lastError
        words = settings.dictionary.map { WordRow(text: $0) }
        snippets = settings.snippets.sorted { $0.key < $1.key }
            .map { SnippetRow(trigger: $0.key, expansion: $0.value) }
        historyEntries = history.entries
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPermissions()
    }

    /// Write a debounced edit now, so whatever the caller does to
    /// settings.json next lands after it instead of underneath it.
    func flushPendingSave() {
        guard saveItem != nil else { return }
        saveItem?.cancel()
        saveItem = nil
        save()
    }

    /// A finished download switched models behind the Hub's back. Only the
    /// path is taken, not a full refresh(): that rebuilds the dictionary and
    /// snippet rows, which drops focus from a field being typed in.
    func adoptModelPath(_ path: String) {
        loading = true
        defer { loading = false }
        settings.whisperModelPath = path
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    /// The system prompt only ever appears once, so anything past `notDetermined`
    /// has to fall through to System Settings or the button does nothing.
    func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            openPrivacyPane("Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            DispatchQueue.main.async { self?.micGranted = ok }
        }
    }

    func toggleLaunchAtLogin() {
        // Same logic as the menu toggle; fails harmlessly outside a bundled app.
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { NSLog("%@", "Parla: launch-at-login toggle failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Take a recorded chord only if the whole set stays usable. Refusing here
    /// is the guard against binding Parla into a corner — a push-to-talk that
    /// can't be held, a chord the tap can never see, two bindings on one key.
    func setHotkey(_ path: WritableKeyPath<HotkeyBindings, KeyChord>, to chord: KeyChord) {
        var next = settings.hotkeys
        next[keyPath: path] = chord
        if let problem = next.problem() {
            hotkeyError = "\(chord.display) won't work — \(problem)."
            return
        }
        hotkeyError = nil
        settings.hotkeys = next
    }

    func clearHistory() {
        history.clear()
        historyEntries = []
    }

    /// The ONLY pasteboard write in the app — an explicit, user-initiated Copy.
    /// Parla itself never touches the clipboard anywhere else.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Debounced whole-file save — same style as the menu's Set API Key path.
    private func touch() {
        guard !loading, loadError == nil else { return }
        saveItem?.cancel()
        // Cleared as it fires: a non-nil saveItem has to mean "an edit is still
        // unsaved". Left set, the next flush replayed this save over anything
        // written to settings.json since.
        let item = DispatchWorkItem { [weak self] in
            self?.saveItem = nil
            self?.save()
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func save() {
        // A save scheduled while the file was valid must never fire after the
        // file has since been found invalid — never overwrite a file the user
        // is hand-fixing.
        guard loadError == nil else { return }
        var s = settings
        s.dictionary = words.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        s.snippets = Dictionary(
            snippets.map { ($0.trigger.trimmingCharacters(in: .whitespaces), $0.expansion) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { _, b in b })
        do {
            try store.save(s)
            saveError = nil
            onSaved()
        } catch {
            saveError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}
