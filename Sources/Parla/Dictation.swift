import AppKit
import ParlaCore

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

/// The interpreter for `DictationSession`. The machine decides; this file is the
/// only place that touches AppKit, Accessibility, whisper and HTTP.
///
/// Two rules hold everything together:
///  - **Effect order is the contract.** Effects run in the order they arrive and
///    are never reordered — that is what puts the landing keystrokes on screen
///    before the polish POST goes out. An effect that dispatches another event
///    (recorder.start(), the focus probe) appends to the machine's drain queue
///    instead of running the nested list inside itself; see
///    `DictationSession.send(_:perform:)`.
///  - **The probe rule.** Anything the machine needs to know about the world is
///    sampled here, on main, in the same turn the event is dispatched. The
///    machine never queries anything — and nothing here queries the machine to
///    decide what to do next.
extension AppDelegate {

    /// One event in, its effects executed — always on main.
    func send(_ event: DictationSession.Event) {
        session.send(event) { [self] effect in
            // Refresh the off-main mirror before every effect: `state` is an enum
            // carrying Settings (arrays, dictionaries) and must never be read off
            // the main actor, but effects spawn threads that need to know whether
            // this dictation still holds the mic (.startStreamLoop's loop polls it
            // on its first line, whisper's shouldAbort callbacks on every chunk).
            capturingGen.withLock { $0 = session.isCapturing ? session.gen : 0 }
            perform(effect)
        }
    }

    func perform(_ effect: DictationSession.Effect) {
        switch effect {

        // MARK: - Capture

        case let .applyPreferencesAndStartCapture(settings):
            hud.idleBarSize = HUD.idleSize(settings.hudIdleSize)
            hud.showAlways = settings.showHudAlways
            recorder.inputDeviceUID = settings.inputDeviceUID
            let gen = session.gen
            do { try recorder.start() } catch {
                send(.recorderFailed(gen: gen, message: "\(error)"))
                return
            }
            send(.recorderStarted(gen: gen))

        case let .sampleFocus(gen):
            // Emitted after the start cue on purpose: this AX read wakes Electron
            // accessibility (~50 ms) and must delay neither the chime nor speech
            // onset. Whether it is emitted at all is the machine's decision —
            // command mode sampled its focus at fn-down.
            send(.focusSampled(gen: gen, focus: Inserter.focusTarget()))

        case let .stopCapture(discard):
            let samples = recorder.stop()
            captured = discard ? [] : samples

        case .discardStreamWindow:
            // Queued on the chain: the in-flight streaming pass writes `window`
            // as it exits, so clearing it here and now would be undone.
            processTask = Task { [prev = processTask] in
                await prev?.value
                await MainActor.run { self.window = nil }
            }

        case let .startStreamLoop(gen, dictionary):
            // Shadow streaming runs on EVERY dictation so the finalize only ever
            // pays for the unconfirmed tail. Chained onto the previous work:
            // the whisper ctx isn't reentrant.
            guard let transcriber else { return }
            processTask = Task { [prev = processTask] in
                await prev?.value
                await self.stream(transcriber: transcriber, gen: gen, dictionary: dictionary)
            }

        // MARK: - Model

        case .ensureModelLoaded: activeTranscriber()
        case .releaseModelIfPolicyImmediate: unloadAfterTranscription()

        // MARK: - Legs (whisper / LLM), all on the processTask chain

        case let .transcribeFinal(s, ledger):
            let samples = takeCaptured()
            processTask = Task { [prev = processTask] in
                await prev?.value
                await self.finish(s, samples: samples, ledger: ledger)
            }

        case let .transcribeCommand(s):
            let samples = takeCaptured()
            processTask = Task { [prev = processTask] in
                await prev?.value
                await self.transform(s, samples: samples)
            }

        case .warmCleanupEndpoint:
            guard let url = cleanupWarmURL(settings: store.load(),
                                           env: ProcessInfo.processInfo.environment) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request).resume()

        // Both legs pick their request up from the MainActor hop that emitted it
        // and await it themselves — the chain must stay held until it resolves.
        case let .polish(_, landed): pendingPolish = landed
        case let .transform(_, instruction): pendingInstruction = instruction

        // MARK: - Insertion. Nothing here deletes without proving what it deletes.

        case let .insertText(text):
            Inserter.insert(text)

        case let .eraseTypedIfOurs(expect):
            guard Inserter.canEraseTyped(expect) else { return }
            Inserter.typeBackspaces(expect.count)

        case let .replaceTailIfOurs(expect, erase, append, verifiedHUD, unverifiedHUD):
            guard Inserter.canEraseTyped(expect) else {
                // AX can't prove the field still ends with our text — leave it
                // alone; history retains the result when enabled.
                NSLog("Parla replace: unverified, field left alone")
                hud.show(unverifiedHUD)
                return
            }
            NSLog("Parla replace: ax-verified tail swap (erase %d)", erase)
            Inserter.typeBackspaces(erase)
            Inserter.typeUnicode(append)
            hud.show(verifiedHUD)

        // MARK: - UI

        case let .hud(state): hud.show(state)
        case .hideHUD: hud.hide()
        case let .menuBar(state):
            switch state {
            case .idle: showIdle()
            case .recording: showRecording()
            case .busy: setStatus("…")
            case .warning: setStatus("⚠️")
            }
        case let .playSound(cue):
            switch cue {
            case .start: Sound.start()
            case .finish: Sound.finish()
            case .cancel: Sound.cancel()
            case .latch: Sound.latch()
            }

        // MARK: - Records

        case let .appendHistory(raw, cleaned, appName):
            history.append(HistoryEntry(raw: raw, cleaned: cleaned, appName: appName))
        case let .log(line): NSLog("%@", line)
        case let .trace(stamp): Trace.mark(stamp)
        case .flushTrace: Trace.flush()
        }
    }

    private func takeCaptured() -> [Float] {
        defer { captured = [] }
        return captured
    }

    // MARK: - Dictation leg

    /// Whisper over the captured audio, then hand the transcript to the machine
    /// and run what it decides. Runs off-main on the processTask chain; every
    /// look at the world happens inside the MainActor hops and travels as a probe.
    func finish(_ s: DictationSession.Session, samples: [Float], ledger: String) async {
        guard let transcriber else {
            NSLog("Parla: no whisper model loaded — run scripts/download-model.sh")
            await MainActor.run { self.send(.legUnavailable(s, message: "No whisper model")) }
            return
        }
        let settings = s.settings
        // var: frontAppName is rebound below to the app the text actually landed
        // in — it isn't known until the finalize insert.
        var pipeline = Pipeline(
            transcribe: { samples, prompt in transcriber.transcribe(samples, initialPrompt: prompt) },
            cleanup: { transcript, ctx in
                // A factory throw (misconfig / no key) lands in Pipeline's raw-transcript fallback.
                try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                    .clean(transcript: transcript, context: ctx)
            },
            settings: { settings },
            frontAppName: { nil })

        // Raw transcript — reuse the stream's confirmed prefix so the final pass
        // is O(tail), not O(whole utterance). self.window is ours to consume:
        // stream() (queued just before us) wrote it, the chain serializes access.
        let raw: String?
        if let win = window {
            window = nil
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

        Trace.mark(.finalPassDone)

        // The instant raw finalize, and — when a polish is coming — the values it
        // must hold across the await.
        let landed: DictationSession.Landed? = await MainActor.run {
            var probe = LandingProbe(focus: .none)
            if raw != nil {
                // Re-check focus: it may have moved into a password field since
                // fn-down. Sample the destination app HERE, not at fn-down —
                // dictation often starts before the user clicks into the app the
                // text is meant for.
                let focus = Inserter.focusTarget()
                let app = NSWorkspace.shared.frontmostApplication
                probe = LandingProbe(focus: focus, bundleID: app?.bundleIdentifier,
                                     appName: app?.localizedName,
                                     typedIsOurs: s.live && !ledger.isEmpty
                                         && Inserter.canEraseTyped(ledger))
            }
            self.send(.transcribed(s, raw: raw, probe: probe))
            defer { self.pendingPolish = nil }
            return self.pendingPolish
        }
        guard let landed else { return } // dropped, empty, or cleanup unconfigured

        // The POST goes out behind the landing keystrokes, and the chain stays
        // held until it resolves so a queued next dictation can't land text
        // before the swap.
        pipeline.frontAppName = { landed.appName }
        let result = await pipeline.clean(transcript: landed.raw)
        await MainActor.run {
            // Only the swap paths that can type consult this, so only they pay
            // for the AX read.
            let focus = landed.landing == .field && s.gen == self.session.gen
                ? Inserter.focusTarget() : Inserter.FocusTarget.none
            self.send(.cleanReady(s, landed, text: result.text, failure: result.failure, focus: focus))
        }
    }

    // MARK: - Command leg

    /// Command mode: transcribe the spoken instruction on-device, transform the
    /// selection latched at fn-down via the cleanup LLM, and let the machine
    /// decide whether it may replace the live selection.
    func transform(_ s: DictationSession.Session, samples: [Float]) async {
        guard let transcriber else {
            NSLog("Parla transform: no whisper model loaded")
            await MainActor.run { self.send(.legUnavailable(s, message: "No whisper model")) }
            return
        }
        // Transforms REQUIRE the cleanup LLM (no raw fallback) — fail fast with
        // the real reason before burning a whisper pass, instead of a misleading
        // "Transform failed" after it. A configured-but-broken setup still
        // proceeds and hard-fails so the misconfiguration surfaces.
        guard s.cleanupConfigured else {
            NSLog("Parla transform: cleanup not configured")
            await MainActor.run { self.send(.legUnavailable(s, message: "Cleanup not configured")) }
            return
        }
        let settings = s.settings
        // Same min-audio floor as dictation: too short/silent = no instruction.
        let heard = TextRules.audioWorthTranscribing(sampleCount: samples.count,
                                                     rms: AudioRecorder.rms(samples))
        if !heard { NSLog("Parla transform: audio below min-audio floor") }
        let prompt = settings.dictionary.isEmpty ? nil : settings.dictionary.joined(separator: ", ")
        let spoken = heard ? transcriber.transcribe(samples, initialPrompt: prompt) : ""
        let instruction: String? = await MainActor.run {
            self.send(.commandHeard(s, instruction: spoken))
            defer { self.pendingInstruction = nil }
            return self.pendingInstruction
        }
        guard let instruction else { return } // nothing usable was heard

        // Via the cleanup client DIRECTLY (not Pipeline.clean): its raw-transcript
        // fallback would return the spoken instruction on failure, which must
        // never be typed over the user's selection.
        let ctx = CleanupContext(dictionary: settings.dictionary, snippets: [:], appName: nil,
                                 selection: s.selection)
        let out: String
        do {
            out = try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                .clean(transcript: instruction, context: ctx)
        } catch {
            NSLog("%@", "Parla transform failed: \(error)")
            await MainActor.run { self.send(.legUnavailable(s, message: "Transform failed")) }
            return
        }
        await MainActor.run {
            // Probe only while this session still owns the field: a stale
            // transform parks without touching AX, as it did before.
            var probe = TransformProbe(focus: .none, selectionStillMatches: false)
            if s.gen == self.session.gen {
                let focus = Inserter.focusTarget()
                probe = TransformProbe(
                    focus: focus,
                    // Never query a password field's selection.
                    selectionStillMatches: focus != .secure && Inserter.selectedText() == s.selection,
                    bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
            self.send(.transformReady(s, text: out, probe: probe))
        }
    }

    // MARK: - Streaming pass loop

    /// While the mic is live, re-transcribe the unconfirmed tail of the buffer.
    /// Runs for EVERY dictation (shadow streaming) so the confirmed-prefix window
    /// is always built and finish() stays O(tail); the erase+append typing is
    /// additionally gated on liveTyping. Runs on the processTask chain
    /// (serialized with the final pass). Once the tail exceeds ~15s a confirmed
    /// prefix is frozen at a quiet spot (see StreamWindow) so each pass stays
    /// O(tail), not O(n²). In shadow mode the tail pass itself is skipped until
    /// the buffer crosses that threshold — nothing reads its output before the
    /// first cut.
    ///
    /// Passes abort cooperatively at fn-up (shouldAbort) and return "" — every
    /// transcribe here is followed by a `capturing` recheck that BREAKS before
    /// the result is used, so an aborted "" is never committed as a hypothesis
    /// or a confirmed head. The handoff below still runs after a break: it only
    /// carries state from completed passes.
    func stream(transcriber: WhisperTranscriber, gen: Int, dictionary dict: [String]) async {
        var confirmed = "" // frozen transcript of snap[0..<cut]
        var cut = 0
        var lastCount = 0
        while capturing(gen) {
            let snap = recorder.snapshot()
            guard snap.count - lastCount >= 8000 else { // <0.5s new audio, wait
                await pauseBetweenPasses(gen)
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
                    shouldAbort: { !self.capturing(gen) })
                // Aborted head pass returns "": committing the cut would silently
                // drop the head's text from confirmed. Only commit a completed pass.
                guard capturing(gen) else { break }
                confirmed = StreamWindow.join(confirmed, head)
                cut += rel
                tail = Array(tail[rel...])
                NSLog("Parla stream: cut at %.1fs, confirmed %d chars",
                      Double(cut) / 16_000, confirmed.count)
            }
            // Below the freeze threshold nothing consumes the tail pass: `confirmed`
            // only ever grows in the head cut above, and the typing block is gated on
            // liveTyping. Running it anyway burns GPU the final pass is waiting for,
            // so short dictations (nearly all of them) skip straight to finish().
            // Live typing is the one real consumer — if it's ever re-enabled it needs
            // a hypothesis from the first second, not from 15s in.
            guard liveTyping || snap.count > StreamWindow.threshold else {
                await pauseBetweenPasses(gen)
                continue
            }
            let tailText = transcriber.transcribe(
                tail,
                initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed),
                shouldAbort: { !self.capturing(gen) })
            // Aborted pass returns "": never treat it as a new hypothesis —
            // live typing would erase everything the user sees. finish() takes over.
            guard capturing(gen) else { break }
            let text = StreamWindow.join(confirmed, tailText)
            await MainActor.run {
                // Shadow mode: window-building only, never touch the field.
                // The capturing re-check is on THIS side of the hop deliberately:
                // a cancel can land on main between the check above and this
                // block, and typing after its erase would leave orphan text in
                // the field and re-fill the ledger the cancel just cleared.
                guard self.liveTyping, self.capturing(gen) else { return }
                let typed = self.session.typedLedger
                let d = LiveTyper.diff(typed: typed, new: text)
                NSLog("Parla stream: %.1fs audio -> \"%@\" (erase %d, append \"%@\")",
                      Double(snap.count) / 16_000, text, d.erase, d.append)
                if d.erase == 0 {
                    Inserter.typeUnicode(d.append) // pure append: can't harm foreign text
                } else if Inserter.canEraseTyped(typed) {
                    Inserter.typeBackspaces(d.erase)
                    Inserter.typeUnicode(d.append)
                } else {
                    // Can't prove the tail is ours — never risk foreign text.
                    NSLog("Parla stream: revision skipped, tail unverified (erase %d)", d.erase)
                    return
                }
                self.send(.streamTyped(gen: gen, text: text))
            }
            await pauseBetweenPasses(gen)
        }
        // Hand the window to this dictation's finish(), queued right after us on
        // the processTask chain — the chain is the synchronization, and it is the
        // only ordering guarantee needed: whoever runs next on the chain is this
        // dictation's own finish() (which consumes the window) or a newer
        // dictation's stream(), which overwrites it before anyone reads it.
        if !confirmed.isEmpty { window = StreamWindow(confirmedText: confirmed, cutSample: cut) }
    }

    /// This dictation still holds the mic — what `isRecording` used to answer,
    /// gen-checked as well, so a pass that outlived its dictation can never
    /// commit a hypothesis built from the next one's audio. Reads the mirror, not
    /// the machine: this runs off-main (streaming loop, whisper callbacks) and
    /// `session.state` is not safe to touch from there.
    func capturing(_ gen: Int) -> Bool { capturingGen.withLock { $0 == gen } }

    /// ~300ms between streaming passes, sliced so fn-up unblocks the queued
    /// finish() within ~50ms instead of sitting out the full sleep as dead time.
    private func pauseBetweenPasses(_ gen: Int) async {
        for _ in 0..<6 {
            guard capturing(gen) else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
