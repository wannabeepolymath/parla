import Foundation

/// Where the instant raw finalize landed — decides how the cleaned swap applies.
/// `.history` = nothing safely finalized in a field; history may retain it.
public enum Landing: Equatable, Sendable { case field, history }

/// The dictation pill's states. Lives here rather than inside `HUD` so the flow
/// machine can name them without importing AppKit; `HUD.State` is a typealias to
/// this, so every rendering call site is unchanged.
public enum HUDState: Equatable, Sendable {
    case listening(command: Bool)  // command: transform-selection mode ("Command…")
    case handsFree      // fn+Space latched: still recording, fn can be released
    /// Mid-recording preview of the shadow stream's text. Transient UI in Parla's
    /// own pill: never inserted, never stored, never the transcript.
    case preview(String)
    case transcribing   // fn-up → raw text landing (fast, on-device)
    case polishing      // raw landed; LLM cleanup in flight — resolves to done/savedToHistory/cleanedInHistory
    case done
    case savedToHistory   // nothing landed in a field; transcript lives in history
    case cleanedInHistory // swap unverifiable; cleaned text only in history
    case rawFallback(String) // cleanup failed; raw transcript is final, with a safe reason
    case cancelled      // dictation aborted (key pressed while fn held)
    case error(String)
}

public enum MenuBarState: Equatable, Sendable { case idle, recording, busy, warning }

public enum SoundCue: Equatable, Sendable { case start, finish, cancel, latch }

/// What the world looked like when the raw transcript was ready to land.
///
/// The probe rule: an event that drives a decision requiring a look at the world
/// carries the answer, sampled by the interpreter on the main actor in the same
/// turn it dispatches the event. The reducer never queries anything — that is
/// what keeps every AX call in the shell and this file synchronous and testable.
public struct LandingProbe: Equatable, Sendable {
    public let focus: Inserter.FocusTarget   // Inserter.focusTarget(), re-checked at landing
    public let bundleID: String?             // frontmost app, sampled at landing, NOT at fn-down
    public let appName: String?
    public let typedIsOurs: Bool             // Inserter.canEraseTyped(typedLedger)
    public init(focus: Inserter.FocusTarget, bundleID: String? = nil, appName: String? = nil,
                typedIsOurs: Bool = false) {
        self.focus = focus; self.bundleID = bundleID; self.appName = appName
        self.typedIsOurs = typedIsOurs
    }
}

/// Same rule as `LandingProbe`, for the transform insert.
public struct TransformProbe: Equatable, Sendable {
    public let focus: Inserter.FocusTarget
    public let selectionStillMatches: Bool   // Inserter.selectedText() == the latched selection
    public let bundleID: String?
    public init(focus: Inserter.FocusTarget, selectionStillMatches: Bool, bundleID: String? = nil) {
        self.focus = focus; self.selectionStillMatches = selectionStillMatches
        self.bundleID = bundleID
    }
}

/// The dictation flow as a pure reducer: `(State, Event) -> (State, [Effect])`.
/// Foundation only — no AppKit, no AVFoundation, no whisper, no networking, no
/// clock. Every time-based decision (the 200 ms tap, the ~300 ms pass pacing,
/// the 10-minute cap, the 10 s unload tick) already lives outside it.
///
/// Same spirit as `HotkeyMonitor`'s machine, one ergonomic difference: `handle`
/// **returns** the effects instead of firing a callback, because the caller is
/// the app's own switch and wants a value it can loop over.
///
/// The load-bearing structural point: **the machine is stateless with respect to
/// work in flight.** A new fn-down is legal in every state and always wins, so
/// an old session's completion can arrive while the machine is already recording
/// a new one. `state` names only the *foreground* session; everything an
/// in-flight leg needs travels with it by value in `Session`.
public final class DictationSession {

    // MARK: - Session

    public enum Mode: Equatable, Sendable {
        case dictation
        case command(selection: String)   // ⇧+fn: transform the selection latched at fn-down
    }

    /// One dictation's context, latched at fn-down and carried by value into
    /// every leg — a quick next fn-press must not rewrite what a queued
    /// completion sees.
    public struct Session: Equatable, Sendable {
        public let gen: Int
        public let mode: Mode
        public let settings: Settings
        public let cleanupConfigured: Bool   // cleanupIsConfigured(settings:env:), computed in the shell
        public var focus: Inserter.FocusTarget   // sampled post-start (dictation) / pre-start (command)
        public var live: Bool                    // live in-field typing; hard-false in the app today

        public init(gen: Int, mode: Mode, settings: Settings, cleanupConfigured: Bool,
                    focus: Inserter.FocusTarget = .none, live: Bool = false) {
            self.gen = gen; self.mode = mode; self.settings = settings
            self.cleanupConfigured = cleanupConfigured; self.focus = focus; self.live = live
        }

        public var isCommand: Bool { if case .command = mode { return true }; return false }
        public var selection: String { if case .command(let s) = mode { return s }; return "" }
    }

    /// The values the polish leg holds across its await. One `bundleID`, stored
    /// once, is what makes "both sides of the swap's diff agree" a property of
    /// the type rather than a comment.
    public struct Landed: Equatable, Sendable {
        public let landing: Landing
        public let raw: String
        public let insertText: String   // raw, already flattened for the landing bundle ID
        public let bundleID: String?
        public let appName: String?
        public init(landing: Landing, raw: String, insertText: String,
                    bundleID: String?, appName: String?) {
            self.landing = landing; self.raw = raw; self.insertText = insertText
            self.bundleID = bundleID; self.appName = appName
        }
    }

    // MARK: - State

    public enum State: Equatable {
        case idle
        case starting(Session)      // capture requested; focus not yet sampled
        case recording(Session)     // mic live (fn held or hands-free latched)
        case transcribing(Session)  // audio captured; ASR/LLM leg running, nothing landed
        case polishing(gen: Int)    // raw landed; cleanup POST in flight
    }

    // MARK: - Events

    public enum Event {
        // hotkey (from HotkeyMonitor.Edge)
        case startDictation(settings: Settings, cleanupConfigured: Bool, live: Bool)
        case startCommand(settings: Settings, cleanupConfigured: Bool,
                          focus: Inserter.FocusTarget, selection: String?)
        case stopRequested                       // .up(short: false)
        case cancelRequested(silent: Bool)       // .up(short: true) → silent · .cancel → loud
        case handsFreeLatched

        // recorder. `recorderStarted` and `focusSampled` are two events, not one,
        // because the start chime fires *before* the focus sample: that AX call
        // wakes Electron accessibility (~50 ms) and must not delay the cue.
        case recorderStarted(gen: Int)
        case focusSampled(gen: Int, focus: Inserter.FocusTarget)
        case recorderFailed(gen: Int, message: String)
        case captureEnded(gen: Int, reason: AudioRecorder.EndReason)

        // streaming: the loop's live-typed ledger. Machine-level, not
        // session-level — a queued finalize must erase *its own* dictation's text.
        case streamTyped(gen: Int, text: String)
        // streaming preview: the same text, headed for Parla's own pill instead
        // of the user's field. Carries no ledger — nothing here can be inserted.
        case streamPreview(gen: Int, text: String)

        // ASR / LLM completions. Each carries the session it belongs to, and the
        // probe sampled on main in the same turn it was dispatched.
        case transcribed(Session, raw: String?, probe: LandingProbe)
        case commandHeard(Session, instruction: String)   // "" ⇒ nothing usable
        case cleanReady(Session, Landed, text: String, failure: String?,
                        focus: Inserter.FocusTarget)
        case transformReady(Session, text: String, probe: TransformProbe)
        case legUnavailable(Session, message: String)     // no model / cleanup unconfigured / transform failed
    }

    // MARK: - Effects

    /// Data only — no closures, no Tasks, no AppKit. **The order of the list is
    /// part of the contract**: the interpreter executes in order and never
    /// reorders. That is what puts the landing keystrokes on screen before the
    /// polish POST goes out. `send(_:perform:)` is what makes the claim true even
    /// when an effect dispatches another event.
    public enum Effect: Equatable, Sendable {
        // capture
        case applyPreferencesAndStartCapture(Settings)  // HUD size/always, input device UID, recorder.start()
        /// Read the focus target and dispatch `.focusSampled`. A separate effect,
        /// emitted *after* the start cue, because that AX call wakes Electron
        /// accessibility (~50 ms) and must not delay the chime — and because
        /// deciding whether to sample at all is the machine's call, not the
        /// interpreter's (command mode already sampled at fn-down).
        case sampleFocus(gen: Int)
        case stopCapture(discard: Bool)
        case discardStreamWindow    // queued behind the in-flight pass, which writes it on exit
        /// `preview` is the loop's second consumer: with it off *and* live typing
        /// off, the tail pass is skipped below the freeze threshold (see stream()).
        case startStreamLoop(gen: Int, dictionary: [String], preview: Bool)
        // model
        case ensureModelLoaded              // activeTranscriber(): reload if the idle watcher freed it
        case releaseModelIfPolicyImmediate  // unloadAfterTranscription()
        // ASR
        case transcribeFinal(Session, typedLedger: String)
        case transcribeCommand(Session)
        // LLM
        case warmCleanupEndpoint
        case polish(Session, Landed)              // Landed round-trips untouched into .cleanReady
        case transform(Session, instruction: String)  // the selection rides in Session.mode
        // insertion — every delete names what it expects to find (never blind-delete)
        case insertText(String)
        case eraseTypedIfOurs(expect: String)
        /// `if canEraseTyped(expect) { typeBackspaces(erase); typeUnicode(append); hud(verifiedHUD) }
        ///  else { hud(unverifiedHUD) }`
        case replaceTailIfOurs(expect: String, erase: Int, append: String,
                               verifiedHUD: HUDState, unverifiedHUD: HUDState)
        // UI
        case hud(HUDState)
        case hideHUD
        case menuBar(MenuBarState)
        case playSound(SoundCue)
        // records. Fields, not a HistoryEntry: the entry stamps `Date()` and this
        // machine has no clock.
        case appendHistory(raw: String, cleaned: String?, appName: String?)
        case log(String)
        case trace(Trace.Stamp)
        case flushTrace
    }

    // MARK: - Machine

    public private(set) var state: State = .idle
    /// Bumped on every accepted fn-down, and on a cancel (which likewise ends the
    /// foreground session); a completion whose session carries an older value
    /// never changes `state`, and mostly never types either.
    public private(set) var gen = 0
    /// What the stream loop has typed into the field so far. Machine-level, NOT
    /// session-level, and deliberately never cleared at fn-down: a still-queued
    /// finalize from the previous dictation must see it to erase that
    /// dictation's live text.
    public private(set) var typedLedger = ""

    /// The drain queue behind `send(_:perform:)`, and whether a drain is running.
    private var queue: [Effect] = []
    private var draining = false

    public init() {}

    /// Drive the machine: handle the event, then run its effects **in order**.
    ///
    /// Effects are queued rather than recursed, which is the whole point: some
    /// effects dispatch further events from inside themselves (recorder.start()
    /// reports `.recorderStarted`, the focus probe reports `.focusSampled`), and
    /// a nested `send` from inside `perform` must APPEND that event's effects to
    /// the end of the queue, not splice a whole nested list into the middle of
    /// the list currently running. Without this, "effect order is the contract"
    /// is false exactly where it matters most — the fn-down list, where the warm
    /// HEAD request sits behind the capture start.
    ///
    /// Still pure: the only thing that happens here is the caller's own callback,
    /// in a defined order.
    public func send(_ event: Event, perform: (Effect) -> Void) {
        let effects = handle(event)
        queue.append(contentsOf: effects)
        guard !draining else { return }   // nested: the drain below will get to it
        draining = true
        defer { draining = false }
        while !queue.isEmpty { perform(queue.removeFirst()) }
    }

    /// Capture in flight — the app's old `isRecording`. Drives the stream loop's
    /// abort predicate, warmup preemption and the idle model-unload watcher.
    /// False while transcribing or polishing, exactly as `isRecording` was.
    public var isCapturing: Bool {
        switch state {
        case .starting, .recording: return true
        case .idle, .transcribing, .polishing: return false
        }
    }

    public func handle(_ event: Event) -> [Effect] {
        switch event {

        // MARK: fn-down

        case let .startDictation(settings, cleanupConfigured, live):
            // Always wins, in every state: an in-flight leg's completion will
            // find itself stale. typedLedger is deliberately NOT reset.
            gen += 1
            state = .starting(Session(gen: gen, mode: .dictation, settings: settings,
                                      cleanupConfigured: cleanupConfigured, live: live))
            // The warm HEAD request goes out FIRST: its whole job is to finish the
            // TLS handshake before the polish POST, and everything in
            // .applyPreferencesAndStartCapture — recorder.start(), the ~50 ms AX
            // focus probe behind it, a possible 574 MB model reload — is latency
            // it would otherwise queue behind.
            return [.trace(.fnDown), .warmCleanupEndpoint, .applyPreferencesAndStartCapture(settings)]

        case let .startCommand(settings, cleanupConfigured, focus, selection):
            // Refuse early — before any recording, and without consuming a
            // generation: a refused command must not silently invalidate an
            // in-flight polish.
            guard focus != .secure else { return [.hud(.error("No transforms in password fields"))] }
            guard let selection else { return [.hud(.error("Select text first"))] }
            gen += 1
            state = .starting(Session(gen: gen, mode: .command(selection: selection), settings: settings,
                                      cleanupConfigured: cleanupConfigured, focus: focus, live: false))
            return [.applyPreferencesAndStartCapture(settings)]

        case let .recorderStarted(g):
            guard case .starting(let s) = state, s.gen == g else { return [] }
            let cues: [Effect] = [.menuBar(.recording), .hud(.listening(command: s.isCommand)),
                                  .playSound(.start)]
            // Dictation samples focus behind the cue and waits for .focusSampled.
            guard s.isCommand else { return cues + [.sampleFocus(gen: g)] }
            state = .recording(s)                  // command mode sampled its focus at fn-down
            return [.ensureModelLoaded] + cues

        case let .focusSampled(g, focus):
            guard case .starting(var s) = state, s.gen == g else { return [] }
            // Password field: with no clipboard hand-off there is nothing safe to
            // do with the transcript — refuse up front. Not the cancel path: its
            // queued HUD hide would wipe this toast.
            guard focus != .secure else {
                state = .idle
                return [.stopCapture(discard: true), .hud(.error("Not supported in password fields")),
                        .menuBar(.idle)]
            }
            s.focus = focus
            state = .recording(s)
            // Shadow streaming runs on every dictation so the finalize only ever
            // pays for the unconfirmed tail; typing inside the loop is gated on live.
            return [.ensureModelLoaded,
                    .startStreamLoop(gen: g, dictionary: s.settings.dictionary,
                                     preview: s.settings.streamPreviewEnabled)]

        case let .recorderFailed(g, message):
            guard case .starting(let s) = state, s.gen == g else { return [] }
            state = .idle   // the generation stays consumed, as it does today
            return [.menuBar(.warning), .hud(.error("Mic failed")), .log("Parla mic start failed: \(message)")]

        // MARK: fn-up / abort

        case .stopRequested:
            guard case .recording(let s) = state else { return [] }
            return [.trace(.fnUp)] + finalize(s)

        case let .captureEnded(g, reason):
            // The 10-minute cap or a mic that disappeared: finalize identically
            // to fn-up, minus the fn-up stamp. No toast — the .transcribing HUD
            // that finalize shows would immediately replace it.
            guard case .recording(let s) = state, s.gen == g else { return [] }
            return [.log("Parla: capture ended early (\(reason))")] + finalize(s)

        case let .cancelRequested(silent):
            // Guarded on an actual capture. Today's cancel has no such guard, so
            // an Esc after a secure refusal — or after the 10-minute cap already
            // finalized — plays the cancel sound over a session that is already
            // finishing. See the PR note.
            guard isCapturing else { return [] }
            state = .idle
            // Cancel consumes a generation like an fn-down does. HAZARD, for
            // whoever re-enables live typing: a streaming pass can already be
            // sitting on its MainActor hop when this runs, and that hop types
            // first and reports `.streamTyped` after. Without the bump the report
            // passes the gen check and re-fills `typedLedger` with text this
            // cancel just erased — which the *next* dictation's finalize would
            // then try to erase again. The interpreter's hop carries the matching
            // half of the guard (it re-checks `capturing(gen)` on main before
            // touching the field), so the keystrokes never land either.
            gen += 1
            var fx: [Effect] = [
                .log(silent ? "Parla: short tap, discarding" : "Parla: cancelled by keypress"),
                .stopCapture(discard: true),
            ]
            if !silent { fx.append(.playSound(.cancel)) }
            // Undo live-typed text only if still provably ours.
            if !typedLedger.isEmpty { fx.append(.eraseTypedIfOurs(expect: typedLedger)) }
            typedLedger = ""
            fx.append(.discardStreamWindow)
            fx.append(silent ? .hideHUD : .hud(.cancelled))
            fx.append(.menuBar(.idle))
            return fx

        case .handsFreeLatched:
            guard case .recording = state else { return [] }
            return [.hud(.handsFree), .playSound(.latch)]

        case let .streamTyped(g, text):
            guard g == gen else { return [] }   // a newer session owns the field
            typedLedger = text
            return []

        case let .streamPreview(g, text):
            // Pill only: no ledger, no history, no landing. Empty text keeps the
            // current label ("Listening…") rather than blanking the pill.
            guard g == gen, case .recording = state, !text.isEmpty else { return [] }
            return [.hud(.preview(text))]

        // MARK: completions

        case let .transcribed(s, raw, probe):
            return transcribed(s, raw: raw, probe: probe)

        case let .cleanReady(s, landed, text, failure, focus):
            return cleanReady(s, landed, text: text, failure: failure, focus: focus)

        case let .commandHeard(s, instruction):
            let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return [.log("Parla transform: no command heard"), .hud(.error("No command heard"))]
                    + transformTail(s)
            }
            return [.transform(s, instruction: trimmed)]

        case let .transformReady(s, text, probe):
            return transformReady(s, text: text, probe: probe)

        case let .legUnavailable(s, message):
            return [.hud(.error(message))] + (s.isCommand ? transformTail(s) : finishTail(s))
        }
    }

    // MARK: - Finalize

    /// Both finalize paths (fn-up and a capture that ended by itself) share this
    /// one builder so neither can drift into its own version.
    private func finalize(_ s: Session) -> [Effect] {
        state = .transcribing(s)
        let head: [Effect] = [.stopCapture(discard: false), .menuBar(.busy), .hud(.transcribing)]
        return head + [s.isCommand ? .transcribeCommand(s) : .transcribeFinal(s, typedLedger: typedLedger)]
    }

    /// The dictation leg's two exit defers: the trace flush always, the menu-bar
    /// reset and the idle unload only when no newer session owns them.
    private func finishTail(_ s: Session) -> [Effect] {
        guard s.gen == gen else { return [.flushTrace] }
        state = .idle
        return [.flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate]
    }

    /// The transform leg's exit defer. Same rule, no trace flush (transforms
    /// aren't part of the dictation latency trace).
    private func transformTail(_ s: Session) -> [Effect] {
        guard s.gen == gen else { return [] }
        state = .idle
        return [.menuBar(.idle), .releaseModelIfPolicyImmediate]
    }

    // MARK: - Landing

    /// The instant raw finalize. Deliberately **not** generation-gated: the user
    /// spoke that text, so it lands even if a newer dictation is already
    /// recording. The gen check starts at the swap, where a newer session may own
    /// the field.
    private func transcribed(_ s: Session, raw: String?, probe: LandingProbe) -> [Effect] {
        let ledger = typedLedger
        typedLedger = ""   // cleared on every branch, including both drops

        guard let raw else {
            var fx: [Effect] = [.log("Parla finish: empty transcript, typed=\(ledger.count)")]
            if !ledger.isEmpty { fx.append(.eraseTypedIfOurs(expect: ledger)) }
            fx.append(.hideHUD)
            return fx + finishTail(s)
        }

        // Secure re-check FIRST, before the transcript reaches any log: focus may
        // have moved into a password field since fn-down, and the text is
        // plausibly a password. Never type it, never log it, never store it.
        guard probe.focus != .secure, s.focus != .secure else {
            return [.log("Parla finish path: focus moved to secure field, dropped"),
                    .hud(.error("Not supported in password fields"))] + finishTail(s)
        }

        let willPolish = s.cleanupConfigured
        // Flatten against the app the keystrokes actually land in. The cleaned
        // swap reuses this same bundle ID so both sides of its diff agree.
        let insertText = TextRules.flattensNewlines(bundleID: probe.bundleID)
            ? TextRules.flattenForTerminal(raw) : raw
        // "polishing…" only when a polish is actually coming; without one the raw
        // transcript IS final, so land the terminal state directly.
        let fieldHUD: HUDState = willPolish ? .polishing : .done
        let historyHUD: HUDState = willPolish ? .polishing
            : s.settings.historyEnabled ? .savedToHistory : .error("History off — text discarded")

        // Length, never the text: logs land in a plain file that outlives "history off".
        var fx: [Effect] = [.log("Parla finish: chars=\(insertText.count) live=\(s.live ? 1 : 0) "
                                 + "focus=\(s.focus == .none ? 0 : 1) typed=\(ledger.count)")]
        let landing: Landing

        if s.live {
            // Diff-based finalize: fix only the diverging tail of the live-typed
            // text instead of erasing and retyping all of it.
            let d = LiveTyper.diff(typed: ledger, new: insertText)
            if ledger.isEmpty {
                fx += [.log("Parla finish path: nothing typed, focused insert"),
                       .insertText(insertText), .hud(fieldHUD)]
                landing = .field
            } else if probe.typedIsOurs {
                fx += [.log("Parla finish path: ax-verified diff finalize (erase \(d.erase))"),
                       .replaceTailIfOurs(expect: ledger, erase: d.erase, append: d.append,
                                          verifiedHUD: fieldHUD, unverifiedHUD: fieldHUD)]
                landing = .field
            } else if d.erase == 0, d.append.isEmpty {
                fx += [.log("Parla finish path: streamed text already final"), .hud(fieldHUD)]
                landing = .field   // streamed text already IS the final text — no keystrokes
            } else {
                // Can't prove the field still ends with our streamed text — leave
                // it in place; history retains the final when enabled.
                fx += [.log("Parla finish path: unverified, no safe finalize"), .hud(historyHUD)]
                landing = .history
            }
        } else {
            // The focus resolved AT LANDING, not the fn-down latch: a click never
            // cancels a dictation (the tap sees no mouse events) and hands-free
            // exists precisely so the user can move around while speaking.
            // Branching on the stale latch could fire a whole transcript as
            // keystrokes into a web page or file list (single letters are
            // shortcuts there), or withhold it from the field the user is
            // looking at. The latch remains the mid-capture prediction only.
            switch probe.focus {
            case .unknown, .editable:
                fx += [.log("Parla finish path: focused insert"), .insertText(insertText), .hud(fieldHUD)]
                landing = .field
            case .none, .secure:
                // Nothing focused: never type into the void; history may retain it.
                fx += [.log("Parla finish path: no focus, no insertion"), .hud(historyHUD)]
                landing = .history
            }
        }

        fx.append(.trace(.landed))
        let sound: [Effect] = (landing == .field || s.settings.historyEnabled) ? [.playSound(.finish)] : []
        guard willPolish else {
            // Raw is final: retain it when history is enabled, then stop — no
            // polish, no swap, no interstitial that nothing would ever resolve.
            fx += sound
            if s.settings.historyEnabled {
                fx.append(.appendHistory(raw: raw, cleaned: nil, appName: probe.appName))
            }
            return fx + finishTail(s)
        }
        // The POST is issued after the landing keystrokes, which is the whole
        // point of the effect list being ordered.
        fx.append(.polish(s, Landed(landing: landing, raw: raw, insertText: insertText,
                                    bundleID: probe.bundleID, appName: probe.appName)))
        fx += sound
        if s.gen == gen { state = .polishing(gen: s.gen) }
        return fx
    }

    // MARK: - Cleaned swap

    private func cleanReady(_ s: Session, _ landed: Landed, text: String, failure: String?,
                            focus: Inserter.FocusTarget) -> [Effect] {
        let historyEnabled = s.settings.historyEnabled
        // The cleaned text replaces insertText in the field, so it must be
        // flattened too — and diffed flattened-vs-flattened or the erase counts
        // won't match what's on screen.
        let cleaned = TextRules.flattensNewlines(bundleID: landed.bundleID)
            ? TextRules.flattenForTerminal(text) : text
        let plan = LiveTyper.swapPlan(raw: landed.insertText, cleaned: cleaned)
        let failureHUD = failure.map(HUDState.rawFallback)
        let unverifiedHUD: HUDState = historyEnabled ? .cleanedInHistory
            : .error("History off — cleanup discarded")

        var fx: [Effect] = []
        if s.gen != gen {
            // A newer dictation owns the field and the HUD — no keystrokes, no
            // HUD. History still records the result below.
            fx.append(.log("Parla swap: stale generation, no swap"))
        } else if landed.landing == .field, focus == .secure {
            fx.append(.log("Parla swap path: focus moved to secure field, no cleaned swap"))
            fx.append(.hud(failureHUD ?? (plan == nil ? .done : unverifiedHUD)))
        } else {
            switch landed.landing {
            case .history:
                // Nothing of ours in a field — history is the only durable landing.
                fx.append(.hud(historyEnabled ? (failureHUD ?? .savedToHistory)
                                              : .error("History off — text discarded")))
            case .field:
                if let plan {
                    fx.append(.replaceTailIfOurs(expect: landed.insertText, erase: plan.eraseTail.count,
                                                 append: plan.replacement, verifiedHUD: .done,
                                                 unverifiedHUD: unverifiedHUD))
                } else {
                    // Polish was a no-op: cleanup failed, or the LLM agreed raw was fine.
                    fx.append(.hud(failureHUD ?? .done))
                }
            }
        }
        fx.append(.trace(.cleanedSwapped))
        if historyEnabled {
            // cleaned is dropped when cleanup failed or matched raw.
            let cleanedForHistory = (failure == nil && text != landed.raw) ? text : nil
            fx.append(.appendHistory(raw: landed.raw, cleaned: cleanedForHistory, appName: landed.appName))
        }
        return fx + finishTail(s)
    }

    // MARK: - Transform

    private func transformReady(_ s: Session, text: String, probe: TransformProbe) -> [Effect] {
        // Safety policy, all of it here so all of it is testable. A transform has
        // no raw fallback: a failure must never type the spoken instruction over
        // the user's selection.
        // Trim only, never CleanupSanitizer: "put this in quotes" returns a
        // quoted string, and the sanitizer's quote-strip would hand the
        // selection back unchanged under a "✓ Pasted".
        let transformed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transformed.isEmpty else {
            return [.log("Parla transform: empty result"), .hud(.error("Transform failed"))]
                + transformTail(s)
        }
        // ponytail: generous expansion ceiling; add repeated-substring detection
        // if legitimate transforms ever need more than 6× the source.
        let ceiling = max(2000, 6 * s.selection.count)
        guard transformed.count <= ceiling else {
            return [.log("Parla transform: result over ceiling (\(transformed.count) > \(ceiling))"),
                    .hud(.error("Transform failed"))] + transformTail(s)
        }

        /// Park when we can't safely type; without history, discard honestly.
        /// A stale generation parks *silently* — the newer session owns the HUD.
        func park(_ why: String, showHUD: Bool) -> [Effect] {
            guard s.settings.historyEnabled else {
                return [.log("Parla transform: \(why), discarded (history off)")]
                    + (showHUD ? [.hud(.error("History off — text discarded"))] : [])
            }
            return [.log("Parla transform: \(why), saved to history"),
                    .appendHistory(raw: transformed, cleaned: nil, appName: nil)]
                + (showHUD ? [.hud(.savedToHistory)] : [])
        }

        guard s.gen == gen else { return park("stale generation", showHUD: false) + transformTail(s) }
        // Never type into a password field, and don't even query its selection.
        // The result derives from the user's own selection, so parking it is safe.
        guard probe.focus != .secure else {
            return park("focus moved to secure field", showHUD: true) + transformTail(s)
        }
        // Only replace a textually unchanged selection; never type over new context.
        guard probe.selectionStillMatches else {
            return park("selection changed", showHUD: true) + transformTail(s)
        }
        let result = TextRules.flattensNewlines(bundleID: probe.bundleID)
            ? TextRules.flattenForTerminal(transformed) : transformed
        return [.log("Parla transform: selection intact, replacing"), .insertText(result),
                .playSound(.finish), .hud(.done)] + transformTail(s)
    }
}
