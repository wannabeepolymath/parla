import AppKit
import Carbon.HIToolbox // IsSecureEventInputEnabled
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
    static func finish() { play("Glass") }  // final transcript delivered
    static func cancel() { play("Funk") }   // dictation aborted
    static func latch()  { play("Pop") }    // fn+Space: hands-free engaged
}

/// The interpreter for `DictationSession`. The machine decides; this file is the
/// only place that touches AppKit, Accessibility, whisper and HTTP.
///
/// Two rules hold everything together:
///  - **Effect order is the contract.** Effects run in the order they arrive and
///    are never reordered. An effect that dispatches another event
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
            // A failed paste the last session never surfaced must not leak into this one.
            insertionFailure = nil
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

        case let .startStreamLoop(gen, dictionary, preview):
            // Shadow streaming runs on EVERY dictation so the finalize only ever
            // pays for the unconfirmed tail. Chained onto the previous work:
            // the whisper ctx isn't reentrant.
            guard let transcriber else { return }
            processTask = Task { [prev = processTask] in
                await prev?.value
                await self.stream(transcriber: transcriber, gen: gen, dictionary: dictionary,
                                  preview: preview)
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
            if Inserter.insert(text) {
                insertionFailure = nil
                CorrectionWatcher.shared.arm(inserted: text, dictionary: store.load().dictionary)
            } else {
                insertionFailure = store.load().historyEnabled
                    ? "Paste failed — copy the transcript from History" : "Paste failed"
            }

        case let .eraseTypedIfOurs(expect):
            // Nothing of ours is left in the field — there is nothing to learn from.
            CorrectionWatcher.shared.disarm()
            guard Inserter.canEraseTyped(expect) else { return }
            Inserter.typeBackspaces(expect.count)

        case let .replaceTailIfOurs(expect, erase, append, verifiedHUD, unverifiedHUD):
            // Parla's own polish swap changes the field like any other edit:
            // stop watching before it types and re-arm on its result, or the
            // cleanup's rewrite gets learned as if the user had made it.
            CorrectionWatcher.shared.disarm()
            guard Inserter.canEraseTyped(expect) else {
                // AX can't prove the field still ends with our text — leave it
                // alone; history retains the result when enabled.
                NSLog("Parla replace: unverified, field left alone")
                hud.show(unverifiedHUD)
                return
            }
            // One atomic AX value write over the tail, read-back verified inside
            // — no visible char-by-char erase and no keystroke window for the
            // user's own typing to fall into. Fields that refuse the write (or
            // an erase of 0, which the helper declines) fall back to keystrokes.
            // An ISSUED write that never confirmed gets no fallback: Electron
            // applies AX sets async, and typing over one lands the edit twice.
            switch Inserter.replaceTypedTail(String(expect.suffix(erase)), with: append) {
            case .replaced:
                NSLog("Parla replace: atomic ax swap (erase %d)", erase)
            case .unverified:
                NSLog("Parla replace: ax write unconfirmed, field left alone (erase %d)", erase)
                hud.show(unverifiedHUD)
                return
            case .unavailable:
                NSLog("Parla replace: ax-verified tail swap (erase %d)", erase)
                Inserter.typeBackspaces(erase)
                Inserter.typeUnicode(append)
            }
            hud.show(verifiedHUD)
            CorrectionWatcher.shared.arm(inserted: String(expect.dropLast(erase)) + append,
                                         dictionary: store.load().dictionary)

        // MARK: - UI

        case let .hud(state):
            if let failure = insertionFailure, state == .done || {
                if case .rawFallback = state { return true }; return false
            }() {
                hud.show(.error(failure))
                insertionFailure = nil
            } else {
                hud.show(state)
            }
        case let .secureRefusal(passwordField): showSecureRefusal(passwordField)
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
            history.append(HistoryEntry(raw: raw, cleaned: cleaned, appName: appName,
                                        metrics: Metrics.shared.snapshot()))
        case let .log(line): NSLog("%@", line)
        case let .trace(s): stamp(s)
        case .flushTrace: Trace.flush()
        }
    }

    /// Both consumers of a stamp, so neither can be updated without the other:
    /// the env-gated line on stderr and the metrics that ride the history entry.
    func stamp(_ s: Trace.Stamp) {
        Trace.mark(s)
        Metrics.shared.mark(s)
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
        // Written BEFORE anything can fail, deleted once a transcript exists: a
        // crash inside the whisper pass otherwise takes the only copy of what
        // the user just said, which is Handy #1332. Every early return below is
        // a failure path and deliberately leaves the file behind — except when
        // focus is secure, which outranks the keep and so has to be sampled on
        // EVERY exit, not just the landing one.
        let recording = RecordingStore.shared.stash(samples)
        guard let transcriber else {
            NSLog("Parla: no whisper model loaded — run scripts/download-model.sh")
            await MainActor.run {
                self.send(.legUnavailable(s, message: "No whisper model"))
                // Behind the HUD for the same reason the landing path is behind
                // the keystrokes. transcript: nil keeps the file (Handy #1332);
                // the probe is what stops audio captured into a password field
                // from sitting on disk for the retention window just because no
                // model was loaded.
                RecordingStore.shared.resolve(recording, transcript: nil,
                                              secure: Inserter.focusTarget() == .secure)
            }
            return
        }
        let settings = s.settings
        // var: frontBundleID is rebound below to the app the text actually landed
        // in — it isn't known until the finalize insert.
        var pipeline = Pipeline(
            transcribe: { samples, prompt in transcriber.transcribe(samples, initialPrompt: prompt) },
            cleanup: { transcript, ctx in
                // A factory throw (misconfig / no key) lands in Pipeline's raw-transcript fallback.
                try await makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)
                    .clean(transcript: transcript, context: ctx)
            },
            settings: { settings },
            frontBundleID: { nil })

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
                // nil = the tail pass failed. That must not discard the confirmed
                // prefix the stream already earned — fall back to it, exactly as a
                // below-floor tail does.
                if tailText == nil { NSLog("Parla finish: tail pass failed, using confirmed prefix") }
                let joined = StreamWindow.join(win.confirmedText, tailText ?? "")
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

        stamp(.finalPassDone)
        // Whatever whisper actually ran against, which is not necessarily the
        // catalog default — the metric is worthless if it names the wrong model.
        Metrics.shared.update {
            $0.model = URL(fileURLWithPath: settings.whisperModelPath
                ?? WhisperTranscriber.defaultModelPath())
                .deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "ggml-", with: "")
        }

        // Resolve the destination before cleanup and hold its identity across
        // the await. The production path inserts only the final result.
        let delivery = await MainActor.run { () -> (DictationSession.Landed?, Inserter.Destination?) in
            // Re-check focus: it may have moved into a password field since
            // fn-down. Sampled on BOTH paths, not just the landing one: it is
            // also the signal that deletes the stashed WAV below, and the
            // no-transcript path is the only one that KEEPS that file — reading
            // focus only when there is a transcript is what made the secure
            // delete unreachable exactly where it matters. The reducer ignores
            // the probe entirely when `raw` is nil, so this changes no decision.
            let focus = Inserter.focusTarget()
            var probe = LandingProbe(focus: focus)
            if raw != nil {
                // Sample the destination app HERE, not at fn-down — dictation
                // often starts before the user clicks into the app the text is
                // meant for.
                let app = NSWorkspace.shared.frontmostApplication
                probe = LandingProbe(focus: focus, bundleID: app?.bundleIdentifier,
                                     appName: app?.localizedName,
                                     typedIsOurs: s.live && !ledger.isEmpty
                                         && Inserter.canEraseTyped(ledger),
                                     deferInsertionUntilClean: true,
                                     browserURL: focus == .secure ? nil : Inserter.focusedBrowserURL(bundleID: app?.bundleIdentifier),
                                     singleLine: focus == .secure ? false : Inserter.focusedFieldIsSingleLine())
            }
            let destination = focus == .secure ? nil : Inserter.Destination()
            self.send(.transcribed(s, raw: raw, probe: probe))
            // Behind the landing keystrokes on purpose — a file delete must not
            // sit between the transcript and the screen. `secure` is the same
            // pair of signals the reducer just refused on inside that send, so
            // audio that drifted into a password field cannot outlive the
            // transcript that was dropped for it.
            RecordingStore.shared.resolve(recording, transcript: raw,
                                          secure: probe.focus == .secure || s.focus == .secure)
            defer { self.pendingPolish = nil }
            return (self.pendingPolish, destination)
        }
        guard let landed = delivery.0 else { return } // dropped, empty, or cleanup unconfigured

        // The bundle ID the text actually landed in — the cleanup prompt's tone
        // hint is keyed on it, and it is the same one the swap's flatten uses,
        // so the prompt and the last mile can't disagree about the destination.
        pipeline.frontBundleID = { landed.bundleID }
        pipeline.frontBrowserURL = { landed.browserURL }
        pipeline.singleLine = landed.singleLine
        // Keep the processing chain serialized through cleanup. A newer session
        // invalidates this insertion; the result can still be retained in history.
        let result = await pipeline.clean(transcript: landed.raw)
        await MainActor.run {
            // Only the swap paths that can type consult this, so only they pay
            // for the AX read.
            var focus = (landed.landing == .field || landed.landing == .pending) && s.gen == self.session.gen
                ? Inserter.focusTarget() : Inserter.FocusTarget.none
            if landed.landing == .pending, focus != .secure, delivery.1?.isCurrent() != true {
                focus = .none
            }
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
        guard let spoken = heard ? transcriber.transcribe(samples, initialPrompt: prompt) : "" else {
            // nil = the pass errored, distinct from "nothing heard": say so
            // instead of blaming the user's diction.
            NSLog("Parla transform: transcription failed")
            await MainActor.run { self.send(.legUnavailable(s, message: "Transcription failed")) }
            return
        }
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
    /// O(tail), not O(n²). With no consumer — no live typing, no preview — the
    /// tail pass itself is skipped until the buffer crosses that threshold,
    /// because nothing reads its output before the first cut.
    ///
    /// Passes abort cooperatively at fn-up (shouldAbort) and return "" — every
    /// transcribe here is followed by a `capturing` recheck that BREAKS before
    /// the result is used, so an aborted "" is never committed as a hypothesis
    /// or a confirmed head. The handoff below still runs after a break: it only
    /// carries state from completed passes.
    func stream(transcriber: WhisperTranscriber, gen: Int, dictionary dict: [String],
                preview: Bool) async {
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
                // Aborted or errored head pass returns nil: committing the cut
                // would silently drop the head's audio from the transcript
                // forever. Only commit a completed pass; an errored one leaves
                // the window alone and finish()'s full pass still owns the audio.
                guard capturing(gen) else { break }
                guard let head else {
                    NSLog("Parla stream: head pass failed, not committing the cut")
                    await pauseBetweenPasses(gen)
                    continue
                }
                confirmed = StreamWindow.join(confirmed, head)
                cut += rel
                tail = Array(tail[rel...])
                NSLog("Parla stream: cut at %.1fs, confirmed %d chars",
                      Double(cut) / 16_000, confirmed.count)
            }
            // Below the freeze threshold the tail pass needs a consumer: `confirmed`
            // only ever grows in the head cut above. Running it anyway burns GPU the
            // final pass is waiting for, so with previews off (the default) short
            // dictations — nearly all of them — skip straight to finish().
            // The two consumers: live typing, and the HUD preview. `preview` implies
            // the pill is on screen; it is visible for the whole of every capture.
            guard liveTyping || preview || snap.count > StreamWindow.threshold else {
                await pauseBetweenPasses(gen)
                continue
            }
            let tailText = transcriber.transcribe(
                tail,
                initialPrompt: StreamWindow.tailPrompt(dictionary: dict, confirmed: confirmed),
                shouldAbort: { !self.capturing(gen) })
            // Aborted or errored pass returns nil: never treat it as a new
            // hypothesis — live typing would erase everything the user sees.
            // On abort finish() takes over; on error just try the next pass.
            guard capturing(gen) else { break }
            guard let tailText else {
                await pauseBetweenPasses(gen)
                continue
            }
            let text = StreamWindow.join(confirmed, tailText)
            await MainActor.run {
                // The capturing re-check is on THIS side of the hop deliberately:
                // a cancel can land on main between the check above and this
                // block, and typing after its erase would leave orphan text in
                // the field and re-fill the ledger the cancel just cleared.
                guard self.capturing(gen) else { return }
                // Preview goes to Parla's own pill and stops there — no ledger,
                // no insertion, no history.
                if preview { self.send(.streamPreview(gen: gen, text: text)) }
                // Shadow mode: window-building only, never touch the field.
                guard self.liveTyping else { return }
                let typed = self.session.typedLedger
                let d = LiveTyper.diff(typed: typed, new: text)
                NSLog("Parla stream: %.1fs audio -> %d chars (erase %d, append %d)",
                      Double(snap.count) / 16_000, text.count, d.erase, d.append.count)
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
        // the processTask chain — the chain is the synchronization: whoever runs
        // next on the chain is this dictation's own finish() (which consumes the
        // window) or a newer dictation's stream().
        //
        // Assigned unconditionally, nil included: "a newer stream() overwrites
        // it" only holds when that stream froze a head of its own. A dictation
        // the user interrupts with a new fn-down never reaches finish(), so its
        // window goes unconsumed, and the next dictation — almost always short,
        // confirmed empty — would inherit it and splice the previous utterance
        // in front of its own tail.
        window = confirmed.isEmpty ? nil : StreamWindow(confirmedText: confirmed, cutSample: cut)
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

// MARK: - Dictionary learning

/// The C-side of the AXObserver: notifications carry a refcon, nothing else.
private let correctionObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<CorrectionWatcher>.fromOpaque(refcon).takeUnretainedValue().fieldChanged()
}

/// Watches the field Parla just typed into and turns a one-word hand-correction
/// into a dictionary *proposal* — never an entry. The diff and every guard on it
/// live in `DictionaryLearner`; this class is only the AX plumbing around them.
///
/// muesli's constraints are the design: a 600 ms stability window so a half-typed
/// word is never read as the correction, and a 60 s give-up so Parla never sits
/// on an observer inside someone else's process. Main thread only, one watch at a
/// time — a new insertion always replaces the previous watch.
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    private var observer: AXObserver?
    private var element: AXUIElement?
    private var inserted = ""
    private var baseline = ""
    private var dictionary: [String] = []
    private var pendingArm: DispatchWorkItem?
    private var settle: Timer?
    private var giveUp: Timer?

    /// Begin watching after the keystrokes Parla just posted have landed.
    ///
    /// The delay is not cosmetic: CGEvents are delivered asynchronously, so
    /// reading the field on this turn of the run loop sees the text *before* our
    /// own insertion and would take a stale baseline.
    // ponytail: fixed 250 ms rather than polling for the text to appear — a slow
    // app just doesn't get learned from. Poll if that turns out to be common.
    func arm(inserted: String, dictionary: [String]) {
        disarm()
        guard !inserted.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.attach(inserted: inserted, dictionary: dictionary)
        }
        pendingArm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func attach(inserted: String, dictionary: [String]) {
        pendingArm = nil
        guard let (element, pid) = Self.focusedElement(), let value = Self.value(of: element) else { return }
        // Two different secure signals, same refusal — the field (a password
        // field's masked value must never be diffed or logged) and the keyboard
        // (some other process holds it, so nothing of ours landed anyway).
        guard !Self.isSecure(element), !IsSecureEventInputEnabled() else { return }
        // Same proof the erase paths require before they touch a field: the text
        // immediately before the cursor is exactly what we typed. Anything Parla
        // cannot verify it wrote, it does not learn from.
        guard Inserter.canEraseTyped(inserted) else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, correctionObserverCallback, &created) == .success,
              let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, element,
                                        kAXValueChangedNotification as CFString, refcon) == .success
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        self.element = element
        self.inserted = inserted
        self.dictionary = dictionary
        baseline = value
        giveUp = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.disarm()
        }
    }

    /// Coalesce the burst of notifications a person typing produces into one
    /// evaluation once they stop.
    fileprivate func fieldChanged() {
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func evaluate() {
        settle = nil
        guard let element, let after = Self.value(of: element) else { return }
        guard let proposal = DictionaryLearner.propose(inserted: inserted, before: baseline,
                                                       after: after, dictionary: dictionary) else {
            return // keep watching: the user may still be mid-correction
        }
        if DictionaryLearner.Store.shared.add(proposal) {
            // The words themselves stay out of the log file; the Hub shows them.
            NSLog("Parla learn: proposed a dictionary correction (Hub → Dictionary to confirm)")
        }
        disarm() // one proposal per insertion, never a chain of them
    }

    func disarm() {
        pendingArm?.cancel(); pendingArm = nil
        settle?.invalidate(); settle = nil
        giveUp?.invalidate(); giveUp = nil
        if let observer, let element {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        element = nil
        inserted = ""
        baseline = ""
    }

    /// The focused element and its owning process — the same lookup
    /// `Inserter.focusedElement` makes, app-level fallback included, because it
    /// is private to ParlaCore and this needs the pid too (AXObserverCreate
    /// takes one). Collapse into one call if that ever goes public.
    ///
    /// The fallback is load-bearing, not cosmetic: Electron/Chromium apps
    /// answer only the app-level query, and `Inserter.canEraseTyped` — the
    /// guard `attach` runs on this same field — resolves through it. Without it
    /// we ask about a different element than the one we verified, so learning
    /// simply never arms in Slack, VS Code or Cursor.
    private static func focusedElement() -> (AXUIElement, pid_t)? {
        // Inserter's lookup, not a copy of it: `attach` gates on
        // `Inserter.canEraseTyped`, so watching a different element than the one
        // that was verified is how this silently disarms.
        guard let element = Inserter.focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return (element, pid)
    }

    private static func value(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Same test Inserter's focus classification makes, on the element we would
    /// actually watch — and without its Electron accessibility wake, which must
    /// not run on the turn a dictation just landed.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
               ref as? String == "AXSecureTextField" { return true }
        }
        return false
    }
}
