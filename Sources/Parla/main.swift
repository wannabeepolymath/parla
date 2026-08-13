import AppKit
import AVFoundation
import ParlaCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = SettingsStore()
    let history = HistoryStore()
    let hotkey = HotkeyMonitor()
    let recorder = AudioRecorder()
    let hud = HUD()
    /// The dictation flow itself. Every fn edge and every leg completion becomes
    /// an Event; the [Effect] it returns is what Dictation.swift executes. It
    /// owns what used to be a handful of correlated fields here — the generation
    /// counter, the per-dictation latch (settings, focus, command selection) and
    /// the live-typed ledger — so nothing can drift out of step with anything else.
    let session = DictationSession()
    /// Which generation holds the mic, mirrored out of `session` on main before
    /// every effect (see `send`). 0 = nobody; generations count from 1.
    ///
    /// The machine's own `state` is an enum carrying a `Session`, which carries
    /// `Settings` — Swift arrays and dictionaries. Reading that concurrently with
    /// a main-thread write is a real data race, so the off-main readers (the
    /// streaming loop, whisper's shouldAbort callbacks, the recorder's onEnd tap
    /// thread) read this Int under a lock instead.
    let capturingGen = OSAllocatedUnfairLock(initialState: 0)
    var transcriber: WhisperTranscriber?
    var processTask: Task<Void, Never>?

    /// Live in-field typing is hard-disabled: keystrokes posted while the user
    /// physically holds fn merge with the modifier (fn+A opens the Dock, ⇧←
    /// becomes select-to-Home) — revisions stall on the first wrong hypothesis
    /// and the finalize demotes to history-only. Shadow streaming keeps the speed
    /// win; the transcript lands as ONE insert at fn-up, after the modifier is
    /// released. Re-enable only with a verified fix for the fn-merge.
    let liveTyping = false

    // Hand-offs from an effect to the async leg that consumes it — the same
    // three values the old inline flow passed from hand to hand.
    var captured: [Float] = []                   // .stopCapture(discard: false)
    var pendingPolish: DictationSession.Landed?  // .polish
    var pendingInstruction: String?              // .transform
    /// Confirmed-prefix window for long dictations: written by stream(), consumed
    /// by the finish() queued right after it — the processTask chain serializes.
    var window: StreamWindow?

    // Model download-in-progress state (feature 4): non-nil task means the menu
    // shows a disabled "Downloading…" item instead of the download action.
    var downloadTask: URLSessionDownloadTask?
    var downloadObservation: NSKeyValueObservation?
    // Idle model-unload. `transcriber` is the *resident* context, which the
    // watcher may free; `modelReady` is "a model file loaded successfully at
    // least once" and survives an unload — every health check reads that one,
    // so an unloaded model doesn't put ⚠️ in the menu bar.
    var modelReady = false
    var loadedModelPath: String?
    var lastModelUse = Date()
    var unloadTimer: Timer?
    let unloadPolicy = ModelUnloadPolicy.default
    // Set by the once-a-day GitHub Releases check; nil until a newer release is
    // found, then menuNeedsUpdate surfaces an "Update available" item.
    var availableUpdate: UpdateCheck.Update?

    // Hub: hubModel is cheap and touched at every launch (loadModel() sets
    // its modelLoaded below) — hubController, the window, is what's built
    // lazily on first open.
    lazy var hubModel: HubModel = {
        let m = HubModel(store: store, history: history)
        m.onDownloadModel = { [weak self] model in self?.download(model) }
        m.onOpenSettingsFile = { [weak self] in self?.openSettings() }
        // nil means "recording" here, so weak-self can't collapse into `??`.
        m.onTryoutStart = { [weak self] in
            guard let self else { return "Parla is shutting down" }
            return self.tryoutStart()
        }
        m.onTryoutStop = { [weak self] done in
            guard let self else { return done("") }
            self.tryoutStop(done)
        }
        m.onSaved = { [weak self] in
            guard let self else { return }
            let s = self.store.load()
            self.hud.idleBarSize = HUD.idleSize(s.hudIdleSize)
            self.hud.showAlways = s.showHudAlways
            self.recorder.inputDeviceUID = s.inputDeviceUID
            // Warm the new mic. A warm engine still running on the OLD one is left
            // alone (see prepare()); start() rebinds it, so the first press after a
            // mic switch is cold but correct — accepted over a rebind here, which
            // would tear the tap down mid-capture when hands-free is latched.
            self.recorder.prepare()
            // The Hub's model picker writes whisperModelPath through this same
            // save, so a changed path is the signal to swap the loaded context.
            if (s.whisperModelPath ?? WhisperTranscriber.defaultModelPath()) != self.loadedModelPath {
                self.loadModel()
            }
        }
        m.modelLoaded = modelReady
        return m
    }()
    lazy var hubController = HubWindowController(model: hubModel)
    let scratchpad = ScratchpadController()

    @objc func openHub() { hubController.show() }
    @objc func openScratchpad() { scratchpad.show() }

    func applicationWillTerminate(_ notification: Notification) {
        scratchpad.save() // flush a pending debounced edit
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setStatus("🎤")
        installMainMenu()
        buildMenu()
        requestPermissions()
        loadModel()
        startUnloadWatcher()
        let launchSettings = store.load()
        hud.idleBarSize = HUD.idleSize(launchSettings.hudIdleSize)
        hud.showAlways = launchSettings.showHudAlways
        recorder.inputDeviceUID = launchSettings.inputDeviceUID
        // Turn the warm engine + pre-roll ring on. This is what moves the 240–700 ms
        // device open off the fn-down press and lets start() prepend the 0.45 s
        // spoken before the key went down. Costs that open here at launch instead,
        // and keeps the mic indicator lit while Parla is idle — deliberate.
        // No-op until the mic permission lands, so a fresh install stays cold until
        // its first dictation ends (see AudioRecorder.warmUp).
        recorder.prepare()
        // Fresh install: open the setup flow instead of leaving a ⚠️ glyph in the
        // menu bar for the user to find and decode. A broken settings.json is a
        // different problem with its own banner — don't onboard over it.
        if !launchSettings.onboardingCompleted, store.lastError == nil {
            hubController.show()
        }

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.push(level: level) }
        }

        // Capture ended without an fn-up: the 10-minute cap (which is also the
        // ceiling on a forgotten hands-free latch) or a mic that disappeared.
        // The machine finalizes it exactly as fn-up does, minus the fn-up stamp.
        // The hotkey monitor is still latched, so the next fn press resyncs it
        // (a no-op) and the one after starts a new dictation.
        recorder.onEnd = { [weak self] reason in
            guard let self else { return }
            // The generation is read HERE, on the tap thread as the capture ends,
            // not inside the hop: reading it at delivery time would make the
            // machine's `s.gen == g` check a tautology, and an fn-down landing in
            // between would rename this stale end as the new dictation's and
            // finalize a session that just started recording.
            let gen = self.capturingGen.withLock { $0 }
            DispatchQueue.main.async { self.send(.captureEnded(gen: gen, reason: reason)) }
        }

        hotkey.onEdge = { [weak self] edge in
            guard let self else { return }
            NSLog("Parla: fn edge %@", "\(edge)")
            switch edge {
            case .down(let command):
                // Latch the settings for the whole dictation: the streaming loop
                // and both legs read the latched value instead of stat()ing the
                // file every ~300ms pass. The re-read-only-if-changed cache lives
                // in SettingsStore.load() so all ten call sites get it.
                let settings = self.store.load()
                let configured = cleanupIsConfigured(
                    settings: settings, env: ProcessInfo.processInfo.environment)
                guard command else {
                    // The frontmost app is NOT sampled here: users routinely start
                    // dictating and then click into the destination, so the target
                    // is whatever is frontmost at finalize (see finish()).
                    self.send(.startDictation(settings: settings, cleanupConfigured: configured,
                                              live: self.liveTyping))
                    return
                }
                // Command mode: capture the selection NOW, before any recording —
                // the machine refuses (with no generation burned) when there is
                // nothing safe to transform. Never query a password field's
                // selection.
                let focus = Inserter.focusTarget()
                self.send(.startCommand(settings: settings, cleanupConfigured: configured,
                                        focus: focus,
                                        selection: focus == .secure ? nil : Inserter.selectedText()))
            case .up(let short):
                // Short tap = accidental Globe press (emoji/input switch): abort
                // silently, never run whisper. Recording still STARTED on fn-down
                // so we don't clip speech onset; we just discard it here.
                self.send(short ? .cancelRequested(silent: true) : .stopRequested)
            case .cancel:
                // Esc, or a real key pressed while fn was held (fn+arrow): abort.
                self.send(.cancelRequested(silent: false))
            case .handsFree:
                // fn+Space latched: same recording, but tell the user Space took —
                // the pill relabels and a pop confirms fn can be released.
                self.send(.handsFreeLatched)
            case .pasteLast:
                guard let text = self.history.entries.first?.best else { return }
                self.pasteWhenModifiersClear(text)
            case .openScratchpad:
                self.scratchpad.show()
            case .dismiss:
                self.hud.dismiss()
            }
        }
        hotkey.start()

        // Convenience update check: once a day, off the main thread. nil version
        // under `swift run` skips it. Never nags — just lights up a menu item.
        Task {
            if let update = await UpdateCheck.check(currentVersion: Self.appVersion) {
                await MainActor.run { self.availableUpdate = update }
            }
        }
    }

    /// App version from the bundle's Info.plist (CFBundleShortVersionString).
    /// nil under `swift run` (no bundle) so the update check skips.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }


    /// ⌃⌘V is still physically held when the pasteLast edge fires; typing while
    /// real modifiers are down risks the app reading them alongside our events.
    /// Wait for release (max ~1s), then insert; give up with a toast — the text
    /// stays in history for another try.
    func pasteWhenModifiersClear(_ text: String, tries: Int = 20) {
        if NSEvent.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty {
            insertStoredText(text)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.pasteWhenModifiersClear(text, tries: tries - 1)
            }
        } else {
            hud.show(.error("Release keys, then retry"))
        }
    }

    /// History can outlive its source app. Resolve the target at the keystroke,
    /// then flatten newlines where Return would fire: terminals run commands,
    /// chat apps (Slack, Discord, etc.) send the message.
    func insertStoredText(_ text: String) {
        // The ONE insertion path with no secure-field check otherwise: ⌃⌘V and
        // the history menu would type a stored transcript straight into a
        // password field — the single invariant the rest of the app never
        // breaks. The text stays in history for a retry somewhere sane.
        guard Inserter.focusTarget() != .secure else {
            NSLog("Parla paste-last: focus is a secure field, refused")
            hud.show(.error("Not supported in password fields"))
            return
        }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Inserter.insert(TextRules.flattensNewlines(bundleID: bundleID) ? TextRules.flattenForTerminal(text) : text)
    }

    func loadModel() {
        let path = store.load().whisperModelPath ?? WhisperTranscriber.defaultModelPath()
        // Re-check what we downloaded before handing it to whisper: the corrupt
        // payload can predate the validator (vibe #353), and the verdict is
        // cached on (size, mtime) so the 574 MB hash happens once, not per
        // launch. A model outside Parla's own models dir is the user's and is
        // never checked — see ModelCatalog.verifyInstalled.
        if let bad = ModelCatalog.verifyInstalled(path: path) {
            NSLog("%@", "Parla: refusing model — \(bad.description)")
            transcriber = nil
            modelReady = false
            loadedModelPath = nil
            hubModel.modelLoaded = false
            hud.show(.error("Model file is damaged — download it again"))
            showIdle()
            return
        }
        transcriber = try? WhisperTranscriber(modelPath: path)
        modelReady = transcriber != nil
        loadedModelPath = modelReady ? path : nil
        lastModelUse = Date()
        hubModel.modelLoaded = modelReady
        showIdle()
        if let transcriber {
            // First whisper inference pays Metal shader/graph setup (hundreds of ms) —
            // warm it now on throwaway silence so the user's first real dictation
            // isn't the one paying it. Queued on processTask like every other
            // transcribe call: the whisper ctx isn't reentrant, and loadModel() can
            // also fire post-download while the app is already live.
            processTask = Task { [prev = processTask] in
                await prev?.value
                // Preemptible: a dictation started before warmup finishes takes
                // priority — it eats the cold start instead of queueing behind it.
                _ = transcriber.transcribe([Float](repeating: 0, count: 16_000), initialPrompt: nil,
                                           shouldAbort: { self.capturingGen.withLock { $0 != 0 } })
                NSLog("Parla: whisper warmup done")
            }
        }
    }

    /// The resident context, reloading it if the idle watcher freed it, and the
    /// one place the activity stamp is touched. Called on main at fn-down —
    /// after `recorder.start()`, so the reload never costs captured speech.
    /// ponytail: the reload is synchronous, so a cold 574 MB model stalls the
    /// UI for a few hundred ms once per idle period. Move it onto processTask
    /// if that ever shows up in a trace.
    @discardableResult
    func activeTranscriber() -> WhisperTranscriber? {
        lastModelUse = Date()
        if transcriber == nil, modelReady { loadModel() }
        return transcriber
    }

    /// 10 s idle watcher. It refuses to unload while recording and touches the
    /// activity stamp instead (Handy's shape), and the free itself is queued on
    /// the processTask chain so it can never race a whisper pass — the ctx
    /// isn't reentrant and freeing it mid-pass is a crash, not a leak.
    func startUnloadWatcher() {
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.transcriber != nil else { return }
            if self.session.isCapturing { self.lastModelUse = Date(); return }
            let idle = Date().timeIntervalSince(self.lastModelUse)
            guard self.unloadPolicy.shouldUnloadOnTick(idle: idle, recording: false) else { return }
            self.unloadModel(reason: "idle \(Int(idle))s")
        }
    }

    func unloadModel(reason: String) {
        processTask = Task { [prev = processTask] in
            await prev?.value
            await MainActor.run {
                // A dictation may have started while we waited in the queue.
                guard !self.session.isCapturing, self.transcriber != nil else { return }
                self.transcriber = nil
                NSLog("%@", "Parla: whisper model unloaded (\(reason))")
            }
        }
    }

    /// The `.immediately` policy, handled here rather than on the tick so it
    /// can only ever fire between dictations.
    func unloadAfterTranscription() {
        guard unloadPolicy.unloadsAfterTranscription else { return }
        DispatchQueue.main.async { [self] in
            guard !session.isCapturing else { return }
            unloadModel(reason: "policy: immediately")
        }
    }

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            if !ok { NSLog("Parla: microphone permission denied") }
        }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("Parla: grant Accessibility permission in System Settings")
        }
    }

    var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var axGranted: Bool { AXIsProcessTrusted() }

    /// Menu-bar glyph rendered from the app logo (waveform). isTemplate lets macOS
    /// tint it for the light/dark menu bar. nil under `swift run` (no bundle) → we
    /// fall back to the 🎤 emoji. Sized to ~18pt tall, keeping the logo's aspect.
    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        let h = 18.0
        img.size = NSSize(width: h * img.size.width / img.size.height, height: h)
        return img
    }()

    /// Idle menu-bar state: the logo glyph when healthy, ⚠️ if anything needs the
    /// user's attention (no model, broken settings.json, missing permission).
    /// store.lastError reflects the most recent load() — refreshed at launch, and on
    /// any dictation or menu open that finds settings.json changed.
    func showIdle() {
        // modelReady, not `transcriber != nil`: an idle unload is not a problem
        // the user needs to see a ⚠️ about.
        let healthy = modelReady && store.lastError == nil && micGranted && axGranted
        if healthy, let icon = Self.menuBarIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = icon
        } else {
            setStatus(healthy ? "🎤" : "⚠️")
        }
    }

    /// Recording state: keep the logo glyph (the HUD pill already shows the live
    /// recording state); 🔴 only as the unbundled `swift run` fallback.
    func showRecording() {
        if let icon = Self.menuBarIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = icon
        } else {
            setStatus("🔴")
        }
    }

    // Text/emoji states (… transcribing, ⚠️ error, ⬇️% download) clear
    // any logo image first so they don't render side by side.
    func setStatus(_ s: String) {
        statusItem.button?.image = nil
        statusItem.button?.title = s
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // LSUIElement apps get no main menu by default, and macOS dispatches
    // ⌘C/⌘V/⌘X/⌘A through the main menu's Edit items — without this, paste
    // doesn't work in any hub/scratchpad text field.
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(
            title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main

        // Belt-and-suspenders: menu key equivalents can still miss in
        // LSUIElement apps, so handle the standard edit shortcuts directly,
        // sending to the first responder. Falls through when unhandled.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let action: Selector?
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: nil) { return nil }
            return event
        }
    }

    @objc func openSettings() {
        // Only seed defaults when there's no file yet — never overwrite a
        // broken settings.json the user is about to fix (that's their typo'd
        // API key / dictionary, don't discard it).
        if !FileManager.default.fileExists(atPath: store.url.path) {
            try? store.save(store.load())
        }
        NSWorkspace.shared.open(store.url)
    }

    @objc func openUpdate() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.url)
    }

    @objc func reportIssue() {
        NSWorkspace.shared.open(URL(string: "https://github.com/wannabeepolymath/parla/issues/new")!)
    }

    @objc func openPrivacyPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Single-instance lock. A second launch would install a second CGEventTap and
/// a second status item, and both would fire on every fn press. flock is
/// released by the kernel when the holder dies, so a crash leaves nothing to
/// clean up — no stale PID file to reason about. The fd is deliberately never
/// closed: it must hold for the process lifetime. false ⇒ someone else has it.
func claimSingleInstanceLock() -> Bool {
    let path = NSTemporaryDirectory() + "parla.lock"
    let fd = open(path, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { return true } // can't lock ⇒ never block a legitimate launch
    return flock(fd, LOCK_EX | LOCK_NB) == 0
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard claimSingleInstanceLock() else {
    // Menu-bar app with no windows: dying silently here looks like a failed
    // launch, so say why before exiting.
    app.activate(ignoringOtherApps: true) // accessory app: the alert would open behind
    let alert = NSAlert()
    alert.messageText = "Parla is already running"
    alert.informativeText = "Look for the microphone icon in the menu bar."
    alert.runModal()
    exit(1)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
