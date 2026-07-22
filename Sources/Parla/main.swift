import AppKit
import AVFoundation
import ParlaCore
import ServiceManagement

/// Subtle system-sound cues. NSSound(named:) uses the bundled ~/Library sounds —
/// no audio framework. ponytail: fire-and-forget; a nil name just no-ops.
enum Sound {
    private static func play(_ name: String) {
        guard let s = NSSound(named: name) else { return }
        s.volume = 0.25
        s.play()
    }
    static func start()  { play("Tink") }   // record-start
    static func finish() { play("Glass") }  // raw transcript landed
    static func cancel() { play("Funk") }   // dictation aborted
    static func latch()  { play("Pop") }    // fn+Space: hands-free engaged
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = SettingsStore()
    let history = HistoryStore()
    let hotkey = HotkeyMonitor()
    let recorder = AudioRecorder()
    let hud = HUD()
    var transcriber: WhisperTranscriber?
    var processTask: Task<Void, Never>?
    var isRecording = false
    // Live streaming: whether the focused field accepts typed text, and what
    // we've already streamed into it (grapheme-accurate, so backspace counts match).
    var liveTyping = false
    var focus = Inserter.FocusTarget.none
    var typed = ""
    // Cleanup context is latched at fn-down and read at fn-up like liveTyping/focus.
    var appName: String?
    var settings = Settings()
    // Command mode (⇧+fn): transform the selection captured at fn-down instead of
    // dictating. Latched at fn-down, read at fn-up like liveTyping/focus.
    var commandMode = false
    var commandCapture: Inserter.CapturedSelection?
    // Bumped on every fn-down; a pending cleaned-swap compares its captured
    // value on the main actor and never fires keystrokes into a newer session.
    var generation = 0
    // Confirmed-prefix window for long dictations: written by stream(), consumed
    // by the finish() queued right after it — the processTask chain serializes.
    var window: StreamWindow?
    // Model download-in-progress state (feature 4): non-nil task means the menu
    // shows a disabled "Downloading…" item instead of the download action.
    var downloadTask: URLSessionDownloadTask?
    var downloadObservation: NSKeyValueObservation?
    // Set by the once-a-day GitHub Releases check; nil until a newer release is
    // found, then menuNeedsUpdate surfaces an "Update available" item.
    var availableUpdate: UpdateCheck.Update?

    // Hub: hubModel is cheap and touched at every launch (loadModel() sets
    // its modelLoaded below) — hubController, the window, is what's built
    // lazily on first open.
    lazy var hubModel: HubModel = {
        let m = HubModel(store: store, history: history)
        m.onDownloadModel = { [weak self] in self?.downloadModel() }
        m.onOpenSettingsFile = { [weak self] in self?.openSettings() }
        m.onSaved = { [weak self] in
            guard let self else { return }
            let s = self.store.load()
            self.hud.idleBarSize = HUD.idleSize(s.hudIdleSize)
            self.hud.showAlways = s.showHudAlways
            self.recorder.inputDeviceUID = s.inputDeviceUID
        }
        m.modelLoaded = transcriber != nil
        return m
    }()
    lazy var hubController = HubWindowController(model: hubModel)
    let scratchpad = ScratchpadController()

    @objc func openHub() { hubController.show() }
    @objc func openScratchpad() { scratchpad.show() }

    func applicationWillTerminate(_ notification: Notification) {
        scratchpad.save() // flush a pending debounced edit
    }

    /// Where the instant raw finalize landed — decides how the cleaned swap applies.
    /// .history = nothing safely finalized in a field; history may retain it.
    enum Landing: Sendable { case field, history }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setStatus("🎤")
        installMainMenu()
        buildMenu()
        requestPermissions()
        loadModel()
        let launchSettings = store.load()
        hud.idleBarSize = HUD.idleSize(launchSettings.hudIdleSize)
        hud.showAlways = launchSettings.showHudAlways
        recorder.inputDeviceUID = launchSettings.inputDeviceUID

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.push(level: level) }
        }

        hud.onPolish = { [weak self] in self?.polishSelection() }
        hud.onScratchpad = { [weak self] in self?.scratchpad.show() }

        hotkey.onEdge = { [weak self] edge in
            guard let self else { return }
            NSLog("Parla: fn edge %@", "\(edge)")
            switch edge {
            case .down(let command):
                if command {
                    // Command mode: capture the selection NOW; refuse early (no
                    // recording) when there's nothing safe to transform.
                    let focus = Inserter.focusTarget()
                    guard focus != .secure else {
                        self.hud.show(.error("No transforms in password fields")); return
                    }
                    guard let capture = Inserter.captureSelection() else {
                        self.hud.show(.error("Select text first")); return
                    }
                    self.generation += 1 // invalidates any pending cleaned-swap
                    self.commandMode = true
                    self.commandCapture = capture
                    self.focus = focus
                    self.liveTyping = false // never stream a transform
                    do { try self.recorder.start() }
                    catch {
                        self.setStatus("⚠️"); self.hud.show(.error("Mic failed"))
                        NSLog("%@", "Parla mic start failed: \(error)"); return
                    }
                    self.isRecording = true
                    self.showRecording(); self.hud.show(.listening(command: true)); Sound.start()
                    return
                }
                self.commandMode = false
                let frontApp = NSWorkspace.shared.frontmostApplication
                self.appName = frontApp?.localizedName
                let settings = self.store.load()
                self.settings = settings
                self.hud.idleBarSize = HUD.idleSize(settings.hudIdleSize)
                self.hud.showAlways = settings.showHudAlways
                self.recorder.inputDeviceUID = settings.inputDeviceUID
                if let url = cleanupWarmURL(
                    settings: settings, env: ProcessInfo.processInfo.environment) {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 5
                    URLSession.shared.dataTask(with: request).resume()
                }
                self.generation += 1 // invalidates any pending cleaned-swap
                self.isRecording = true
                // typed is NOT reset here: a still-queued finish from the previous
                // dictation must see it to erase that dictation's live text.
                do { try self.recorder.start(); self.showRecording(); self.hud.show(.listening(command: false)); Sound.start() }
                catch {
                    self.isRecording = false
                    self.setStatus("⚠️"); self.hud.show(.error("Mic failed"))
                    NSLog("%@", "Parla mic start failed: \(error)")
                    return
                }
                // Focused field gets the final insert at fn-up; no focus never
                // types into the void (see finish).
                self.focus = Inserter.focusTarget()
                // Password field: with no clipboard hand-off there is nothing
                // safe to do with the transcript (never type into a secure
                // field, never store a plausible password) — refuse up front.
                // Inline cancel, not cancelDictation(): its queued hud.hide()
                // would immediately wipe the error toast. Nothing streamed yet.
                guard self.focus != .secure else {
                    self.isRecording = false
                    _ = self.recorder.stop() // discard the captured audio
                    self.hud.show(.error("Not supported in password fields"))
                    self.showIdle()
                    return
                }
                // Live in-field typing is hard-disabled: keystrokes posted while
                // the user physically holds fn merge with the modifier (fn+A
                // opens the Dock, ⇧← becomes select-to-Home) — revisions stall
                // on the first wrong hypothesis and the finalize demotes to
                // history-only. Shadow streaming below keeps the speed win; the
                // transcript lands as ONE insert at fn-up, after the modifier is
                // released. Re-enable only with a verified fix for the fn-merge.
                self.liveTyping = false
                // Shadow streaming: run the pass loop on EVERY dictation, not just
                // live-typing ones, so finish() only ever pays for the unconfirmed
                // tail. Actual typing inside the loop is gated on liveTyping.
                if let transcriber = self.transcriber {
                    // Chain onto the previous finish so partial passes never run
                    // concurrently with the final pass (whisper ctx isn't reentrant).
                    self.processTask = Task { [prev = self.processTask] in
                        await prev?.value
                        await self.stream(transcriber: transcriber)
                    }
                }
            case .up(let short):
                // A command down that refused (bad focus/selection) never started
                // recording; the paired fn-up has nothing to finish.
                guard self.isRecording else { return }
                // Short tap = accidental Globe press (emoji/input switch): abort
                // silently, never run whisper. Recording still STARTED on fn-down
                // so we don't clip speech onset; we just discard it here.
                if short {
                    NSLog("Parla: short tap, discarding")
                    self.cancelDictation(silent: true)
                    return
                }
                self.isRecording = false
                let samples = self.recorder.stop()
                if self.commandMode {
                    // Transform path: instruction → LLM → replace selection. Runs
                    // on the processTask chain (whisper ctx not reentrant).
                    guard let capture = self.commandCapture else { return }
                    let gen = self.generation
                    self.setStatus("…"); self.hud.show(.transcribing)
                    self.processTask = Task { [prev = self.processTask] in
                        await prev?.value
                        await self.transform(samples: samples, capture: capture, gen: gen)
                    }
                    return
                }
                // Capture this dictation's context now: a quick next fn-press
                // rewrites the latched state before finish runs.
                let live = self.liveTyping
                let focus = self.focus
                let gen = self.generation
                let appName = self.appName
                let settings = self.settings
                self.setStatus("…")
                self.hud.show(.transcribing)
                // Chain onto the previous work (any in-flight streaming pass):
                // whisper ctx is not reentrant, and insertions must land in
                // dictation order.
                self.processTask = Task { [prev = self.processTask] in
                    await prev?.value
                    await self.finish(samples: samples, live: live, focus: focus, gen: gen,
                                      appName: appName, settings: settings)
                }
            case .cancel:
                // Esc, or a real key pressed while fn was held (fn+arrow): abort.
                NSLog("Parla: cancelled by keypress")
                self.cancelDictation(silent: false)
            case .handsFree:
                // fn+Space latched: same recording, but tell the user Space took —
                // the pill relabels and a pop confirms fn can be released.
                guard self.isRecording else { return }
                self.hud.show(.handsFree)
                Sound.latch()
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
    private func insertStoredText(_ text: String) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Inserter.insert(TextRules.flattensNewlines(bundleID: bundleID) ? TextRules.flattenForTerminal(text) : text)
    }

    /// Abort the in-flight dictation: stop the stream loop + recorder (discard
    /// audio, never call whisper), then queue the undo of any live-typed text on
    /// the processTask chain so it serializes behind a still-running streaming
    /// pass and reads the final `typed` value. `silent` = accidental short tap
    /// (no sound, HUD just hides); otherwise a real cancel (sound + ✕ HUD).
    func cancelDictation(silent: Bool) {
        isRecording = false          // stops the stream loop
        _ = recorder.stop()          // discard captured audio
        if !silent { Sound.cancel() }
        let hud = self.hud
        processTask = Task { [prev = self.processTask] in
            await prev?.value        // wait out any in-flight streaming pass
            await MainActor.run {
                // Undo live-typed text only if still provably ours (same
                // invariant as finish's empty-transcript path — never blind-delete).
                let typedCount = self.typed.count
                if typedCount > 0, Inserter.canEraseTyped(self.typed) {
                    Inserter.typeBackspaces(typedCount)
                }
                self.typed = ""
                self.window = nil    // discard any confirmed-prefix the stream handed off
                if silent { hud.hide() } else { hud.show(.cancelled) }
            }
        }
        showIdle()
    }

    func finish(samples: [Float], live: Bool, focus: Inserter.FocusTarget, gen: Int,
                appName: String?, settings: Settings) async {
        let hud = self.hud // bind so main-queue hops don't capture non-Sendable self
        defer {
            DispatchQueue.main.async {
                // Don't stamp over an active recording, and keep ⚠️ visible
                // while there's no model / settings are broken / permissions missing.
                guard !self.isRecording else { return }
                self.showIdle()
            }
        }
        guard let transcriber else {
            NSLog("Parla: no whisper model loaded — run scripts/download-model.sh")
            DispatchQueue.main.async { hud.show(.error("No whisper model")) }
            return
        }
        let pipeline = Pipeline(
            transcribe: { samples, prompt in transcriber.transcribe(samples, initialPrompt: prompt) },
            cleanup: { transcript, ctx in
                // A factory throw (misconfig / no key) lands in Pipeline's raw-transcript fallback.
                try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                    .clean(transcript: transcript, context: ctx)
            },
            settings: { settings },
            frontAppName: { appName })

        // Raw transcript — reuse the stream's confirmed prefix so the final pass
        // is O(tail), not O(whole utterance). self.window is ours to consume:
        // stream() (queued just before us) wrote it, the chain serializes access.
        let raw: String?
        if let win = self.window {
            self.window = nil
            let cut = min(win.cutSample, samples.count)
            let tail = Array(samples[cut...])
            // Min-audio guard on the TAIL only: a long dictation trailing off into
            // silence still finalizes its confirmed prefix — we just skip the tail
            // whisper pass (which would hallucinate) and use the confirmed text raw.
            if TextRules.audioWorthTranscribing(sampleCount: tail.count, rms: AudioRecorder.rms(tail)) {
                let tailText = transcriber.transcribe(
                    tail,
                    initialPrompt: StreamWindow.tailPrompt(dictionary: settings.dictionary,
                                                           confirmed: win.confirmedText))
                let joined = StreamWindow.join(win.confirmedText, tailText)
                raw = joined.isEmpty ? nil : joined
            } else {
                raw = win.confirmedText.isEmpty ? nil : win.confirmedText
            }
        } else if TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: AudioRecorder.rms(samples)) {
            raw = pipeline.transcript(samples: samples)
        } else {
            // Too short or silent — whisper hallucinates here. Treat as empty.
            NSLog("Parla finish: audio below min-audio floor, skipping whisper")
            raw = nil
        }

        guard let raw else {
            await MainActor.run {
                // Empty transcript: undo anything we streamed — only if verified ours.
                let typedCount = self.typed.count
                NSLog("Parla finish: empty transcript, typed=%d", typedCount)
                if typedCount > 0, Inserter.canEraseTyped(self.typed) {
                    Inserter.typeBackspaces(typedCount)
                }
                self.typed = ""
                hud.hide()
            }
            return
        }

        // Cleanup intent, decided once from the latched settings. Configured
        // means the user set a key (anthropic) or a baseURL (openai-compatible)
        // even if it's invalid — a broken config must still attempt and surface
        // raw-fallback, while keyless (a supported config) skips the polish leg
        // instead of flashing "polishing…" into a guaranteed "failed" toast.
        let willPolish = cleanupIsConfigured(
            settings: settings, env: ProcessInfo.processInfo.environment)

        // Instant finalize: land the raw transcript NOW; the LLM polish swaps in
        // behind it without blocking the user. nil = dropped (secure field).
        let landingResult: (landing: Landing, insertText: String, bundleID: String?)? = await MainActor.run {
            let typedCount = self.typed.count // graphemes streamed live so far
            defer { self.typed = "" }
            // `focus` was latched at fn-down; re-check BEFORE the transcript is
            // logged so a password dictated into a moved-into secure field never
            // reaches unified logging. Same semantics as the (_, .secure) arm
            // below: never type, never log, never store — drop it.
            if Inserter.focusTarget() == .secure {
                NSLog("Parla finish path: focus moved to secure field, dropped")
                hud.show(.error("Not supported in password fields"))
                return nil
            }
            let landingBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            // Flatten against the actual keystroke target. The cleaned swap must
            // use this same bundle ID so both sides of its diff agree.
            let insertText = TextRules.flattensNewlines(bundleID: landingBundleID)
                ? TextRules.flattenForTerminal(raw) : raw
            // Never log the transcript for a secure field — it's plausibly a
            // password, and unified logging is readable in Console.
            NSLog("Parla finish: raw=%@ live=%d focus=%d typed=%d",
                  focus == .secure ? "<secure>" : insertText, live ? 1 : 0, focus == .none ? 0 : 1, typedCount)
            // Show "polishing…" only when a polish is actually coming; without
            // polish the raw transcript IS final — land the terminal HUD
            // state directly, no interstitial that nothing will ever resolve.
            let fieldHUD: HUD.State = willPolish ? .polishing : .done
            let historyHUD: HUD.State = willPolish ? .polishing
                : settings.historyEnabled ? .savedToHistory : .error("History off — text discarded")
            switch (live, focus) {
            case (_, .secure):
                // Defensive: secure fields are refused at fn-down. Never type,
                // never store — drop the transcript entirely.
                NSLog("Parla finish path: secure field, dropped")
                hud.show(.error("Not supported in password fields"))
                return nil
            case (true, _):
                // Diff-based finalize: fix only the diverging tail of the
                // live-typed text instead of erasing and retyping all of it —
                // the streamed text usually already equals the final text.
                let d = LiveTyper.diff(typed: self.typed, new: insertText)
                if typedCount == 0 {
                    // Nothing streamed (short utterance): single insert.
                    NSLog("Parla finish path: nothing typed, focused insert")
                    Inserter.insert(insertText)
                } else if Inserter.canEraseTyped(self.typed) {
                    NSLog("Parla finish path: ax-verified diff finalize (erase %d)", d.erase)
                    Inserter.typeBackspaces(d.erase)
                    Inserter.typeUnicode(d.append)
                } else if d.erase == 0, d.append.isEmpty {
                    // Streamed text already IS the final text — no keystrokes.
                    NSLog("Parla finish path: streamed text already final")
                } else {
                    // Can't prove the field still ends with our streamed text —
                    // leave it in place; history retains the final when enabled.
                    NSLog("Parla finish path: unverified, no safe finalize")
                    hud.show(historyHUD)
                    return (.history, insertText, landingBundleID)
                }
                hud.show(fieldHUD)
                return (.field, insertText, landingBundleID)
            case (false, .unknown), (false, .editable):
                NSLog("Parla finish path: focused insert")
                Inserter.insert(insertText) // insert at cursor
                hud.show(fieldHUD)
                return (.field, insertText, landingBundleID)
            case (false, .none):
                // Nothing focused: never type into the void; history may retain it.
                NSLog("Parla finish path: no focus, no insertion")
                hud.show(historyHUD)
                return (.history, insertText, landingBundleID)
            }
        }
        guard let landingResult else { return } // dropped: no sound, no polish, no history
        let landing = landingResult.landing
        let insertText = landingResult.insertText

        // The POST starts after landing keystrokes; polish is async anyway.
        let cleanTask: Task<(text: String, failure: String?), Never>? = willPolish
            ? Task { await pipeline.clean(transcript: raw) } : nil
        switch landing {
        case .field:
            Sound.finish()
        case .history where settings.historyEnabled:
            Sound.finish()
        case .history:
            break
        }

        // With cleanup unconfigured, the raw transcript is final; retain it when
        // history is enabled, then stop — no polish, no swap.
        guard let cleanTask else {
            if settings.historyEnabled {
                let entry = HistoryEntry(raw: raw, cleaned: nil, appName: appName)
                await MainActor.run { self.history.append(entry) }
            }
            return
        }

        // Async polish: cleanup, then swap raw → cleaned with the same
        // verification machinery. Still on the processTask chain, so a queued
        // next dictation starts only after this resolves (insertion order holds).
        let cleanResult = await cleanTask.value
        // Same terminal guard on the cleaned text — it replaces insertText in the
        // field, so it must be flattened too, and the plan must diff flattened vs
        // flattened (insertText) or the erase/verify counts won't match the field.
        let cleaned = TextRules.flattensNewlines(bundleID: landingResult.bundleID)
            ? TextRules.flattenForTerminal(cleanResult.text) : cleanResult.text
        await MainActor.run {
            let plan = LiveTyper.swapPlan(raw: insertText, cleaned: cleaned)
            let failureHUD = cleanResult.failure.map(HUD.State.rawFallback)
            guard gen == self.generation else {
                // A newer dictation owns the field and HUD — no keystrokes, no
                // HUD. History still records the result below when enabled.
                NSLog("Parla swap: stale generation, no swap")
                return
            }
            if case .field = landing, Inserter.focusTarget() == .secure {
                // Same never-type-into-secure invariant as landing.
                NSLog("Parla swap path: focus moved to secure field, no cleaned swap")
                let secureHUD: HUD.State = failureHUD ?? (plan == nil ? .done
                    : settings.historyEnabled ? .cleanedInHistory
                    : .error("History off — cleanup discarded"))
                hud.show(secureHUD)
                return
            }
            switch landing {
            case .history:
                // Nothing of ours in a field — history is the only durable landing.
                hud.show(settings.historyEnabled
                    ? (failureHUD ?? .savedToHistory)
                    : .error("History off — text discarded"))
            case .field:
                guard let plan else { // polish was a no-op: either cleanup failed, or the LLM agreed raw was fine
                    hud.show(failureHUD ?? .done)
                    return
                }
                if Inserter.canEraseTyped(insertText) {
                    NSLog("Parla swap path: ax-verified tail swap (erase %d)", plan.eraseTail.count)
                    Inserter.typeBackspaces(plan.eraseTail.count)
                    Inserter.typeUnicode(plan.replacement)
                    hud.show(.done)
                } else {
                    // AX can't prove the field still ends with our text — leave
                    // the raw alone; history retains the cleaned version when enabled.
                    NSLog("Parla swap path: unverified, no cleaned swap")
                    hud.show(settings.historyEnabled ? .cleanedInHistory
                        : .error("History off — cleanup discarded"))
                }
            }
        }

        // Record once per dictation (secure fields returned above; raw is
        // non-nil past the guard). cleaned is dropped when cleanup failed or
        // matched raw. Append on main to serialize with menu reads/Clear.
        if settings.historyEnabled {
            let cleanedForHistory = (cleanResult.failure == nil && cleanResult.text != raw) ? cleanResult.text : nil
            let entry = HistoryEntry(raw: raw, cleaned: cleanedForHistory, appName: appName)
            DispatchQueue.main.async { self.history.append(entry) }
        }
    }

    /// Command mode: transcribe the spoken instruction on-device, transform the
    /// selection captured at fn-down via the cleanup LLM, and replace the live
    /// selection if it's still intact — else park it when history is enabled.
    /// Runs on the processTask chain like finish().
    func transform(samples: [Float], capture: Inserter.CapturedSelection, gen: Int) async {
        let hud = self.hud
        defer {
            DispatchQueue.main.async {
                guard !self.isRecording else { return }
                self.showIdle()
            }
        }
        guard let transcriber else {
            NSLog("Parla transform: no whisper model loaded")
            DispatchQueue.main.async { hud.show(.error("No whisper model")) }
            return
        }
        let settings = store.load()
        // Transforms REQUIRE the cleanup LLM (no raw fallback here) — fail fast
        // with the real reason before burning a whisper pass, instead of a
        // misleading "Transform failed" after it. A configured-but-broken setup
        // still proceeds and hard-fails so the misconfiguration surfaces.
        guard cleanupIsConfigured(settings: settings, env: ProcessInfo.processInfo.environment) else {
            NSLog("Parla transform: cleanup not configured")
            DispatchQueue.main.async { hud.show(.error("Cleanup not configured")) }
            return
        }
        // Same min-audio floor as dictation: too short/silent = no instruction.
        guard TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: AudioRecorder.rms(samples)) else {
            NSLog("Parla transform: audio below min-audio floor")
            DispatchQueue.main.async { hud.show(.error("No command heard")) }
            return
        }
        let prompt = settings.dictionary.isEmpty ? nil : settings.dictionary.joined(separator: ", ")
        let instruction = transcriber.transcribe(samples, initialPrompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            NSLog("Parla transform: empty instruction")
            DispatchQueue.main.async { hud.show(.error("No command heard")) }
            return
        }

        guard let transformed = await editSelection(instruction: instruction, selection: capture.text,
                                                    settings: settings, label: "transform", gen: gen) else { return }
        await MainActor.run {
            self.applySelectionEdit(transformed, capture: capture, gen: gen, settings: settings)
        }
        // ponytail: transforms only attempt history on the fallback paths above —
        // a landed transform isn't a dictation, and the source text is the user's.
    }

    /// Pill "✦ Polish" button: command mode's capture and refusals, minus the
    /// recording. Explicit click only — polish is never gesture-triggered.
    /// The click didn't activate us (non-activating panel), so the front app's
    /// focus and selection are still live.
    func polishSelection() {
        NSLog("Parla polish: click (front=%@)",
              NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")
        let focus = Inserter.focusTarget()
        guard focus != .secure else {
            hud.show(.error("No transforms in password fields")); return
        }
        guard let capture = Inserter.captureSelection() else {
            NSLog("Parla polish: refused, no selection (focus=%@)", "\(focus)")
            hud.show(.error("Select text first")); return
        }
        generation += 1 // invalidates any pending cleaned-swap
        let gen = generation
        setStatus("…"); hud.show(.polishingSelection)
        processTask = Task { [prev = self.processTask] in
            await prev?.value
            await self.polish(capture: capture, gen: gen)
        }
    }

    /// Polish body: run the built-in proofread instruction over the selection —
    /// command mode without the spoken command. No whisper pass, so it works
    /// with no model downloaded. Runs on the processTask chain like transform()
    /// so insertions land in order.
    func polish(capture: Inserter.CapturedSelection, gen: Int) async {
        let hud = self.hud
        defer {
            DispatchQueue.main.async {
                guard !self.isRecording else { return }
                self.showIdle()
            }
        }
        let settings = store.load()
        // Same hard requirement as transforms: no raw fallback over a selection.
        guard cleanupIsConfigured(settings: settings, env: ProcessInfo.processInfo.environment) else {
            NSLog("Parla polish: cleanup not configured")
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                hud.show(.error("Cleanup not configured"))
            }
            return
        }
        guard let polished = await editSelection(instruction: Polish.instruction, selection: capture.text,
                                                 settings: settings, label: "polish", gen: gen) else { return }
        await MainActor.run {
            self.applySelectionEdit(polished, capture: capture, gen: gen, settings: settings)
        }
    }

    /// LLM half shared by transform() and polish(), via the cleanup client
    /// DIRECTLY (not Pipeline.clean): its raw-transcript fallback would return
    /// the instruction on failure, which must never be typed over the user's
    /// selection. Any failure here is hard — shows a toast, returns nil,
    /// nothing inserted, nothing stored.
    func editSelection(instruction: String, selection: String, settings: Settings,
                       label: String, gen: Int) async -> String? {
        let hud = self.hud
        let toast = label.capitalized + " failed"
        // Failure toasts land asynchronously — by then a newer session may own
        // the HUD; never stomp its state with a stale error.
        let fail = {
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                hud.show(.error(toast))
            }
        }
        let ctx = CleanupContext(dictionary: settings.dictionary, snippets: [:], appName: nil, selection: selection)
        let edited: String
        do {
            let out = try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                .clean(transcript: instruction, context: ctx)
            // Selection-aware sanitize: the user's own quotes/whitespace are
            // content — only wrappers the selection didn't have get stripped.
            edited = CleanupSanitizer.sanitizeEdit(out, original: selection)
        } catch {
            NSLog("%@", "Parla \(label) failed: \(error)")
            fail()
            return nil
        }
        // Whitespace-only output would ERASE the selection, not edit it —
        // hard failure. (An unchanged whitespace-only selection is fine: the
        // no-change check upstream types nothing.)
        guard edited == selection ||
              !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSLog("Parla %@: empty/whitespace-only result", label)
            fail()
            return nil
        }
        // ponytail: generous expansion ceiling; add repeated-substring detection
        // if legitimate transforms ever need more than 6× the source.
        let lengthCeiling = max(2000, 6 * selection.count)
        guard edited.count <= lengthCeiling else {
            NSLog("Parla %@: result over ceiling (%d > %d)", label, edited.count, lengthCeiling)
            fail()
            return nil
        }
        return edited
    }

    /// Insert half shared by transform() and polish(): verify the SAME element
    /// still holds the same selection and replace it, else park in history.
    /// Main thread only.
    func applySelectionEdit(_ edited: String, capture: Inserter.CapturedSelection, gen: Int,
                            settings: Settings, tries: Int = 20) {
        let hud = self.hud
        // Identical result: nothing to type, and retyping would only churn the
        // field (and the user's undo stack). Checked before everything else —
        // an unchanged result must never be parked in history as noise. The
        // toast only shows if this session still owns the HUD.
        guard edited != capture.text else {
            NSLog("Parla edit: no changes")
            if gen == self.generation { hud.show(.noChange) }
            return
        }
        // Park when we can't safely type; without history, discard honestly.
        let park = { (why: String) -> HUD.State in
            if settings.historyEnabled {
                NSLog("Parla edit: %@, saved to history", why)
                self.history.append(HistoryEntry(raw: edited, cleaned: nil, appName: nil))
                return .savedToHistory
            }
            NSLog("Parla edit: %@, discarded (history off)", why)
            return .error("History off — text discarded")
        }
        guard gen == self.generation else {
            // A newer dictation owns the field/HUD — no keystrokes.
            _ = park("stale generation")
            return
        }
        // Modifiers (⇧+fn's shift after a transform, or any key held across a
        // fast LLM round-trip) may still be physically down; typing with real
        // modifiers held risks the app reading them alongside our events.
        // Wait for release like paste-last, then verify.
        guard NSEvent.modifierFlags
            .intersection([.command, .control, .option, .shift, .function]).isEmpty else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.applySelectionEdit(edited, capture: capture, gen: gen,
                                            settings: settings, tries: tries - 1)
                }
            } else {
                hud.show(park("modifiers held"))
            }
            return
        }
        // Same insert-time re-check as finish(): focus may have moved into
        // a password field since capture — never type there, and don't even
        // query its selection. The result derives from the user's own
        // (non-secure) selection, so parking it in history is safe.
        guard Inserter.focusTarget() != .secure else {
            hud.show(park("focus moved to secure field"))
            return
        }
        // Only replace if the SAME element still holds the same selection —
        // identical text in a different field must never be typed over.
        if Inserter.selectionIntact(capture) {
            NSLog("Parla edit: selection intact, replacing")
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            // Resolve terminal safety only for text actually being typed.
            let result = TextRules.flattensNewlines(bundleID: bundleID)
                ? TextRules.flattenForTerminal(edited) : edited
            Inserter.insert(result) // typing replaces the live selection
            Sound.finish()
            hud.show(.done)
        } else {
            hud.show(park("selection changed"))
        }
    }

    /// ~300ms between streaming passes, sliced so fn-up (isRecording flipping
    /// false) unblocks the queued finish() within ~50ms instead of sitting out
    /// the full sleep as dead time.
    private func pauseBetweenPasses() async {
        for _ in 0..<6 {
            guard isRecording else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Streaming pass loop: while fn is held, re-transcribe the unconfirmed
    /// tail of the buffer. Runs for EVERY dictation (shadow streaming) so the
    /// confirmed-prefix window is always built and finish() stays O(tail);
    /// the erase+append typing is additionally gated on liveTyping. Runs on
    /// the processTask chain (serialized with the final pass). Once the tail
    /// exceeds ~15s a confirmed prefix is frozen at a quiet spot (see
    /// StreamWindow) so each pass stays O(tail), not O(n²).
    ///
    /// Passes abort cooperatively at fn-up (shouldAbort) and return "" — every
    /// transcribe here is followed by an isRecording recheck that BREAKS before
    /// the result is used, so an aborted "" is never committed as a hypothesis
    /// or a confirmed head. The handoff below still runs after a break: it only
    /// carries state from completed passes.
    func stream(transcriber: WhisperTranscriber) async {
        let dict = store.load().dictionary
        var confirmed = "" // frozen transcript of snap[0..<cut]
        var cut = 0
        var lastCount = 0
        // ponytail: isRecording is written on main, read here — benign stop-flag race.
        while self.isRecording {
            let snap = self.recorder.snapshot()
            guard snap.count - lastCount >= 8000 else { // <0.5s new audio, wait
                await pauseBetweenPasses()
                continue
            }
            lastCount = snap.count
            var tail = Array(snap[cut...])
            if tail.count > StreamWindow.threshold {
                // Freeze the head up to the quietest spot near cutTarget: one
                // final pass over it, then it's never re-transcribed.
                let rel = StreamWindow.quietestCut(samples: tail, near: StreamWindow.cutTarget)
                let head = transcriber.transcribe(
                    Array(tail[..<rel]),
                    initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed),
                    shouldAbort: { !self.isRecording })
                // Aborted head pass returns "": committing the cut would silently
                // drop the head's text from confirmed. Only commit a completed pass.
                guard self.isRecording else { break }
                confirmed = StreamWindow.join(confirmed, head)
                cut += rel
                tail = Array(tail[rel...])
                NSLog("Parla stream: cut at %.1fs, confirmed %d chars",
                      Double(cut) / 16_000, confirmed.count)
            }
            let tailText = transcriber.transcribe(
                tail,
                initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed),
                shouldAbort: { !self.isRecording })
            // Aborted pass returns "": never treat it as a new hypothesis —
            // live typing would erase everything the user sees. finish() takes over.
            guard self.isRecording else { break }
            let text = StreamWindow.join(confirmed, tailText)
            await MainActor.run {
                // Shadow mode: window-building only, never touch the field.
                guard self.liveTyping else { return }
                let d = LiveTyper.diff(typed: self.typed, new: text)
                NSLog("Parla stream: %.1fs audio -> \"%@\" (erase %d, append \"%@\")",
                      Double(snap.count) / 16_000, text, d.erase, d.append)
                if d.erase == 0 {
                    Inserter.typeUnicode(d.append) // pure append: can't harm foreign text
                } else if Inserter.canEraseTyped(self.typed) {
                    Inserter.typeBackspaces(d.erase)
                    Inserter.typeUnicode(d.append)
                } else {
                    // Can't prove the tail is ours — never risk foreign text.
                    NSLog("Parla stream: revision skipped, tail unverified (erase %d)", d.erase)
                    return
                }
                self.typed = text
            }
            await pauseBetweenPasses()
        }
        // Hand the window to this dictation's finish(), queued right after us on
        // the processTask chain — the chain is the synchronization.
        if !confirmed.isEmpty {
            self.window = StreamWindow(confirmedText: confirmed, cutSample: cut)
        }
    }

    func loadModel() {
        let path = store.load().whisperModelPath ?? WhisperTranscriber.defaultModelPath()
        transcriber = try? WhisperTranscriber(modelPath: path)
        hubModel.modelLoaded = transcriber != nil
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
                                           shouldAbort: { self.isRecording })
                NSLog("Parla: whisper warmup done")
            }
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
    /// store.lastError reflects the most recent load() — refreshed at launch and on
    /// every dictation (finish() reloads settings each time).
    func showIdle() {
        let healthy = transcriber != nil && store.lastError == nil && micGranted && axGranted
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

    /// Kicks off the base.en download; menuNeedsUpdate hides this action while
    /// downloadTask is non-nil so a second click can't start a duplicate.
    @objc func downloadModel() {
        guard downloadTask == nil,
              let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")
        else { return }
        setStatus("⬇️ 0%")
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            // The tmp file is deleted the moment this handler returns — move it
            // to its destination NOW, before hopping to main for the UI.
            let moveError: Error? = error ?? tmp.flatMap { Self.installModel(from: $0) }
            DispatchQueue.main.async { self?.finishDownload(error: moveError ?? (tmp == nil ? CleanupError(description: "no file") : nil)) }
        }
        // KVO on the task's own Progress — least code for a live percentage,
        // no delegate class needed.
        downloadObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.setStatus("⬇️ \(Int(progress.fractionCompleted * 100))%")
                self?.hubModel.downloadProgress = progress.fractionCompleted
            }
        }
        downloadTask = task
        hubModel.downloadProgress = 0
        task.resume()
    }

    /// Move the downloaded model into place. Runs on the URLSession callback
    /// queue (must complete before the completion handler returns). nil = ok.
    private static func installModel(from tmp: URL) -> Error? {
        do {
            let dest = URL(fileURLWithPath: WhisperTranscriber.defaultModelPath())
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: tmp, to: dest)
            return nil
        } catch { return error }
    }

    private func finishDownload(error: Error?) {
        downloadObservation = nil
        downloadTask = nil
        hubModel.downloadProgress = nil
        if let error {
            NSLog("%@", "Parla model download failed: \(error)")
            hud.show(.error("Model download failed"))
            showIdle()
            return
        }
        loadModel() // clears the ⚠️ when it succeeds (showIdle() inside)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt from scratch right before the menu shows, so permission/model/
    /// settings status is always current — cheaper than tracking diffs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let openHubItem = NSMenuItem(title: "Open Parla…", action: #selector(openHub), keyEquivalent: "")
        openHubItem.target = self
        menu.addItem(openHubItem)
        let scratchItem = NSMenuItem(title: "Open Scratchpad", action: #selector(openScratchpad), keyEquivalent: "s")
        // Display only — the global ⌃⌘S lives in HotkeyMonitor (swallowed there).
        scratchItem.keyEquivalentModifierMask = [.control, .command]
        scratchItem.target = self
        menu.addItem(scratchItem)
        menu.addItem(.separator())

        if let update = availableUpdate {
            let item = NSMenuItem(title: "Update available (\(update.version))…",
                                   action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if transcriber == nil {
            if downloadTask != nil {
                let item = NSMenuItem(title: "Downloading base.en…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: "Download model (base.en, ~148 MB)",
                                       action: #selector(downloadModel), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        if let error = store.lastError {
            let item = NSMenuItem(title: "⚠️ settings.json invalid — click to open",
                                   action: #selector(openSettings), keyEquivalent: "")
            item.target = self
            item.toolTip = error
            menu.addItem(item)
            menu.addItem(.separator())
        }

        addHistoryItems(to: menu)

        // Permissions surface only when missing — a granted app needs no reminder.
        if !micGranted { menu.addItem(permissionItem(name: "Microphone", pane: "Privacy_Microphone")) }
        if !axGranted { menu.addItem(permissionItem(name: "Accessibility", pane: "Privacy_Accessibility")) }
        if !micGranted || !axGranted { menu.addItem(.separator()) }

        addMicrophoneItem(to: menu)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        let report = NSMenuItem(title: "Report a Bug or Feature…", action: #selector(reportIssue), keyEquivalent: "")
        report.target = self
        menu.addItem(report)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        showIdle() // menu open is a free moment to reconcile the icon too
    }

    /// "Paste Last Dictation" + a "Recent" submenu (up to 8, newest first) with
    /// a "Clear History" action. Nil action ⇒ auto-disabled when empty.
    private func addHistoryItems(to menu: NSMenu) {
        let entries = history.entries
        let pasteLast = NSMenuItem(title: "Paste Last Dictation",
                                    action: entries.isEmpty ? nil : #selector(pasteLastDictation),
                                    keyEquivalent: "v")
        // Display only — the global ⌃⌘V lives in HotkeyMonitor (and is swallowed
        // there before any menu could see it).
        pasteLast.keyEquivalentModifierMask = [.control, .command]
        pasteLast.target = self
        menu.addItem(pasteLast)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if entries.isEmpty {
            let none = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for entry in entries.prefix(8) {
                let item = NSMenuItem(title: Self.menuTitle(entry.best),
                                       action: #selector(pasteRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.best
                item.toolTip = entry.appName
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
    }

    /// First non-empty line of `text`, capped ~40 chars with an ellipsis.
    static func menuTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    @objc func pasteLastDictation() {
        guard let best = history.entries.first?.best else { return }
        insertFromMenu(best)
    }

    @objc func pasteRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        insertFromMenu(text)
    }

    @objc func clearHistory() { history.clear() }

    /// SMAppService registration only works from the installed .app bundle
    /// (Info.plist + code signature). ponytail: running via `swift run` still
    /// shows the toggle, it'll just log-and-HUD the thrown error instead of
    /// crashing — fine for dev, real usage is always the bundled app.
    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("%@", "Parla: launch-at-login toggle failed: \(error)")
            hud.show(.error("Launch at Login failed"))
        }
    }

    /// Menu actions fire once the menu has dismissed, but focus handoff back to
    /// the previous app can lag the click — typing too early hits nothing.
    /// Delay a beat; worst case the text is still in history to retry.
    private func insertFromMenu(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.insertStoredText(text) }
    }

    /// "Microphone" submenu: "System Default" + each input device, a checkmark
    /// on the current selection. Empty representedObject ⇒ clear to default.
    private func addMicrophoneItem(to menu: NSMenu) {
        let selected = store.load().inputDeviceUID
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let def = NSMenuItem(title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        def.target = self
        def.representedObject = ""
        def.state = selected == nil ? .on : .off
        sub.addItem(def)
        sub.addItem(.separator())

        for device in AudioRecorder.availableInputs() {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == selected ? .on : .off
            sub.addItem(item)
        }
        mic.submenu = sub
        menu.addItem(mic)
    }

    @objc func selectMicrophone(_ sender: NSMenuItem) {
        guard store.lastError == nil else { return } // never clobber a file being hand-fixed
        let uid = sender.representedObject as? String
        var s = store.load()
        s.inputDeviceUID = (uid?.isEmpty ?? true) ? nil : uid
        try? store.save(s)
        recorder.inputDeviceUID = s.inputDeviceUID
    }

    private func permissionItem(name: String, pane: String) -> NSMenuItem {
        let item = NSMenuItem(title: "⚠️ \(name): not granted — click to open settings",
                               action: #selector(openPrivacyPane(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pane
        return item
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
