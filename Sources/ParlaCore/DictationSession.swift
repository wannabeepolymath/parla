import Foundation

/// Delivery status before cleanup finishes. `.pending` inserts once afterwards.
/// `.history` = nothing safely finalized in a field; history may retain it.
public enum Landing: Equatable, Sendable { case field, history, pending, resultOnly }

/// The dictation pill's states. Lives here rather than inside `HUD` so the flow
/// machine can name them without importing AppKit; `HUD.State` is a typealias to
/// this, so every rendering call site is unchanged.
public enum HUDState: Equatable, Sendable {
    case listening(command: Bool)  // command: transform-selection mode ("Command…")
    case handsFree      // fn+Space latched: still recording, fn can be released
    /// Mid-recording preview of the shadow stream's text. Transient UI in Parla's
    /// own pill: never inserted, never stored, never the transcript.
    case preview(String)
    case speculativePreview(RecognitionPreviewUpdate)
    case transcribing   // fn-up → raw text landing (fast, on-device)
    case polishing      // LLM cleanup in flight; final text has not necessarily landed
    case done
    case savedToHistory   // nothing landed in a field; transcript lives in history
    case cleanedInHistory // swap unverifiable; cleaned text only in history
    case rawFallback(String) // cleanup failed; raw transcript is final, with a safe reason
    case cancelled      // dictation aborted (key pressed while fn held)
    case error(String)
    case notice(String) // informational, no ⚠️ ("You're up to date")
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
    /// App delivery waits for cleanup, then inserts once. The older streaming
    /// consumer can still finalize raw and perform a verified tail replacement.
    public let deferInsertionUntilClean: Bool
    public let browserURL: String?
    public let singleLine: Bool
    public init(focus: Inserter.FocusTarget, bundleID: String? = nil, appName: String? = nil,
                typedIsOurs: Bool = false, deferInsertionUntilClean: Bool = false,
                browserURL: String? = nil, singleLine: Bool = false) {
        self.focus = focus; self.bundleID = bundleID; self.appName = appName
        self.typedIsOurs = typedIsOurs
        self.deferInsertionUntilClean = deferInsertionUntilClean
        self.browserURL = browserURL; self.singleLine = singleLine
    }
}

/// Same rule as `LandingProbe`, for the transform insert.
public struct TransformProbe: Equatable, Sendable {
    public let focus: Inserter.FocusTarget
    public let selectionStillMatches: Bool   // Inserter.selectedText() == the latched selection
    public let bundleID: String?
    public let destinationStillMatches: Bool
    public let browserURL: String?
    public let singleLine: Bool
    public init(focus: Inserter.FocusTarget, selectionStillMatches: Bool, bundleID: String? = nil,
                destinationStillMatches: Bool = false, browserURL: String? = nil, singleLine: Bool = false) {
        self.focus = focus; self.selectionStillMatches = selectionStillMatches
        self.bundleID = bundleID; self.destinationStillMatches = destinationStillMatches
        self.browserURL = browserURL; self.singleLine = singleLine
    }

    /// Production completion probe, with native reads injected. Stale and secure
    /// completions never query destination identity or selected text.
    public static func capture(for session: DictationSession.Session, currentGeneration: Int,
                               focus: () -> Inserter.FocusTarget, modifiersClear: Bool = true,
                               destinationStillMatches: () -> Bool,
                               selectedText: () -> String?) -> Self {
        guard session.gen == currentGeneration, modifiersClear else {
            return Self(focus: .none, selectionStillMatches: false, destinationStillMatches: false)
        }
        let currentFocus = focus()
        guard currentFocus == .editable || currentFocus == .unknown else {
            return Self(focus: currentFocus, selectionStillMatches: false, destinationStillMatches: false)
        }
        let matches = destinationStillMatches()
        return Self(focus: currentFocus, selectionStillMatches: matches && selectedText() == session.selection,
                    bundleID: session.transformTarget?.bundleID, destinationStillMatches: matches,
                    browserURL: session.transformTarget?.browserURL, singleLine: session.transformTarget?.singleLine ?? false)
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

    public enum CaptureCancelReason: Equatable, Sendable {
        case unspecified, explicitCancel, shortRelease, internalCancellation
        public var permitsUndo: Bool { self == .explicitCancel || self == .shortRelease }
    }
    public struct CanceledCapture: Equatable, Sendable {
        public let generation: Int
        public let operation: PendingOperation
        public let request: RecognitionRequest
        public let reason: CaptureCancelReason
    }

    public enum Delivery: Equatable, Sendable { case keyboard, resultOnly }

    // MARK: - Session

    public enum Mode: Equatable, Sendable {
        case dictation
        case savedPreset(selection: String, preset: TransformPreset)
        case command(selection: String)   // ⇧+fn: transform the selection latched at fn-down
    }

    /// One dictation's context, latched at fn-down and carried by value into
    /// every leg — a quick next fn-press must not rewrite what a queued
    /// completion sees.
    public struct Session: Equatable, Sendable {
        public let surroundingTextGrant: SurroundingTextGrant?
        public let surroundingTextRun: SurroundingTextRun
        public let cleanupFailoverGrant: CleanupFailoverGrant?
        public var cleanupFailoverOrigin: CleanupFailoverOrigin? {
            guard mode == .dictation, !live, settings.outputMode != .selectedPreset else { return nil }
            return delivery == .resultOnly ? .shortcutsOrdinary : .physicalOrdinary
        }
        public let delivery: Delivery
        public let gen: Int
        public let operation: PendingOperation
        public let mode: Mode
        public let settings: Settings // global snapshot; never recognition-composed
        public let transformTarget: LandingProbe?
        public let recognition: RecognitionRequest
        public let previewPlan: RecognitionPreviewPlan?
        public let activityShadowPermission: ActivityShadowPermission?
        public let recognitionProfileName: String
        public private(set) var output: ProfileResolution?
        public var effectiveSettings: Settings { output?.settings ?? settings }
        public let cleanupConfigured: Bool   // cleanupIsConfigured(settings:env:), computed in the shell
        public var focus: Inserter.FocusTarget   // sampled post-start (dictation) / pre-start (command)
        public var live: Bool                    // live in-field typing; hard-false in the app today

        public init(gen: Int, mode: Mode, settings: Settings, cleanupConfigured: Bool,
                    focus: Inserter.FocusTarget = .none, live: Bool = false,
                    recognitionDestination: ProfileDestination = .init(), transformTarget: LandingProbe? = nil,
                    diagnostics: DiagnosticStore? = .shared, delivery: Delivery = .keyboard,
                    cleanupFailoverGrant: CleanupFailoverGrant? = nil) {
            self.delivery = delivery
            let resolved = ProfileResolver.resolve(settings, at: delivery == .resultOnly ? .init() : recognitionDestination)
            recognition = RecognitionRequest(settings: resolved.settings)
            recognitionProfileName = resolved.name
            self.transformTarget = transformTarget
            self.gen = gen; self.mode = mode
            var global = settings; global.physicalSurroundingTextGrant = nil; self.settings = global
            operation = PendingOperation(name: {
                switch mode {
                case .dictation: return "Dictation"
                case .command: return "Spoken transform"
                case .savedPreset(_, let preset): return "Transform: " + preset.name
                }
            }(), origin: {
                switch mode {
                case .dictation: return settings.outputMode == .selectedPreset ? .dictatedPreset : .dictation
                case .command: return .spokenTransform
                case .savedPreset: return .savedTransform
                }
            }(), diagnostics: diagnostics)
            surroundingTextRun = SurroundingTextRun()
            surroundingTextGrant = mode == .dictation && !live && delivery == .keyboard && settings.outputMode == .cleanup
                ? settings.physicalSurroundingTextGrant?.bound(to: operation.id) : nil
            self.cleanupFailoverGrant = mode == .dictation && !live && settings.outputMode == .cleanup
                ? cleanupFailoverGrant?.bound(to: operation.id) : nil
            activityShadowPermission = settings.energyActivityShadowEnabled && delivery == .keyboard && mode == .dictation
                && !live && settings.outputMode != .selectedPreset && focus != .secure
                ? ActivityShadowPermission(generation: gen, operationID: operation.id) : nil
            previewPlan = RecognitionPreviewPlan(settings: settings, final: recognition, generation: gen,
                operationID: operation.id, ordinaryPhysical: delivery == .keyboard && mode == .dictation
                    && !live && settings.outputMode != .selectedPreset)
            operation.diagnostics?.recognition(request: recognition)
            self.cleanupConfigured = cleanupConfigured; self.focus = focus; self.live = live
        }

        public func resolvingOutput(at destination: ProfileDestination) -> Session {
            guard delivery == .keyboard, !settings.profiles.isEmpty else { return self }
            var copy = self
            copy.output = ProfileResolver.resolve(settings, at: destination)
            return copy
        }

        /// Command cleanup shares the resolved policy but keeps the existing
        /// selected-text prompt and never applies dictation snippets/replacements/style.
        public func transform(instruction: String,
                              makeClient: (Settings) throws -> CleanupProviding) async throws -> String {
            guard effectiveSettings.cleanupEnabled && cleanupConfigured else {
                operation.diagnostics?.update { $0.providerOutcome = .refused }
                throw CleanupError(description: "Cleanup off or not configured")
            }
            do {
                return try await IntentionalTransform(source: selection, instruction: instruction, settings: effectiveSettings, preset: preset)
                    .run { settings in
                        if let diagnostic = operation.diagnostics { return try diagnostic.makeProvider(settings: settings) { try makeClient(settings) } }
                        return try makeClient(settings)
                    }
            } catch {
                if effectiveSettings.usesAppleIntelligence { operation.diagnostics?.update { $0.localCleanupReason = LocalCleanupReason.from(error) } }
                operation.diagnostics?.update { if $0.providerOutcome == .returned { $0.providerOutcome = .invalidResult } }
                throw error
            }
        }

        /// Capture-time opt-in, never composed from an output profile or later settings.
        public var permitsOriginalCopy: Bool {
            settings.keepLastOriginalEnabled && delivery == .keyboard && !live
                && mode == .dictation && settings.outputMode != .selectedPreset
        }

        fileprivate func originalCopy(_ raw: String) -> OriginalDictationContext? {
            // Guarded receipts are default-on, independent of the legacy Copy
            // Original preference. Carry provenance on the actual effect.
            guard delivery == .keyboard, !live, mode == .dictation,
                  settings.outputMode != .selectedPreset, effectiveSettings.outputMode != .selectedPreset else { return nil }
            return OriginalDictationContext(raw: raw, generation: gen, operationID: operation.id, maximumBytes: .max)
        }

        public var willPolish: Bool { effectiveSettings.outputMode != .raw && effectiveSettings.cleanupEnabled && cleanupConfigured }
        public var isCommand: Bool { if case .dictation = mode { return false }; return true }
        public var preset: TransformPreset? { if case .savedPreset(_, let p) = mode { return p }; return nil }
        public var selection: String {
            switch mode { case .command(let text), .savedPreset(let text, _): return text; case .dictation: return "" }
        }
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
        public let browserURL: String?
        public let singleLine: Bool
        public init(landing: Landing, raw: String, insertText: String,
                    bundleID: String?, appName: String?, browserURL: String? = nil,
                    singleLine: Bool = false) {
            self.landing = landing; self.raw = raw; self.insertText = insertText
            self.bundleID = bundleID; self.appName = appName
            self.browserURL = browserURL; self.singleLine = singleLine
        }
    }

    // MARK: - State

    public enum State: Equatable {
        case idle
        case starting(Session)      // capture requested; focus not yet sampled
        case recording(Session)     // mic live (fn held or hands-free latched)
        case transcribing(Session)  // audio captured; ASR/LLM leg running, nothing landed
        case polishing(gen: Int)    // cleanup POST in flight
    }

    // MARK: - Events

    public enum Event {
        case startAutomation(settings: Settings, cleanupConfigured: Bool, cleanupFailoverGrant: CleanupFailoverGrant? = nil)
        // hotkey (from HotkeyMonitor.Edge)
        case startDictation(settings: Settings, cleanupConfigured: Bool, live: Bool,
                            recognitionDestination: ProfileDestination = .init(), cleanupFailoverGrant: CleanupFailoverGrant? = nil)
        case startSavedPreset(settings: Settings, cleanupConfigured: Bool, selection: String?, target: LandingProbe)
        case startCommand(settings: Settings, cleanupConfigured: Bool,
                          focus: Inserter.FocusTarget, selection: String?,
                          recognitionDestination: ProfileDestination = .init(), transformTarget: LandingProbe? = nil)
        case stopRequested                       // .up(short: false)
        case cancelRequested(silent: Bool, reason: CaptureCancelReason = .unspecified)       // .up(short: true) → silent · .cancel → loud
        case handsFreeLatched
        case discardPending(token: UUID)
        case discardOwnedOperation(PendingOperation, generation: Int)
        case resultUnavailable(Session, DictationResultFailure)
        case operationFinished(PendingOperation)
        case operationDisposalFailed(PendingOperation, message: String)

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
        case recognitionPreview(gen: Int, operationID: UUID, phase: RecognitionPreviewPhase, update: RecognitionPreviewUpdate)
        case recognitionPreviewRevoked(gen: Int, operationID: UUID, phase: RecognitionPreviewPhase)

        // ASR / LLM completions. Each carries the session it belongs to, and the
        // probe sampled on main in the same turn it was dispatched.
        case transcribed(Session, raw: String?, probe: LandingProbe)
        case commandHeard(Session, instruction: String)   // "" ⇒ nothing usable
        case cleanReady(Session, Landed, text: String, failure: String?,
                        focus: Inserter.FocusTarget, metrics: PipelineMetrics? = nil)
        case transformReady(Session, text: String, probe: TransformProbe, failure: String? = nil, metrics: PipelineMetrics? = nil)
        case legUnavailable(Session, message: String)     // no model / cleanup unconfigured / transform failed
    }

    // MARK: - Effects

    /// Data only — no closures, no Tasks, no AppKit. **The order of the list is
    /// part of the contract**: the interpreter executes in order and never
    /// reorders. Delivery, cleanup and record effects run in the specified order.
    /// `send(_:perform:)` is what makes the claim true even
    /// when an effect dispatches another event.
    public enum Effect: Equatable, Sendable {
        case captureAccepted(Session)
        case captureAcknowledged(Session)
        case captureFinalizing(Session)
        case finalResult(Session, DictationFinalResult)
        // capture
        case applyPreferencesAndStartCapture(Settings)  // HUD size/always, input device UID, recorder.start()
        /// Read the focus target and dispatch `.focusSampled`. A separate effect,
        /// emitted *after* the start cue, because that AX call wakes Electron
        /// accessibility (~50 ms) and must not delay the chime — and because
        /// deciding whether to sample at all is the machine's call, not the
        /// interpreter's (command mode already sampled at fn-down).
        case sampleFocus(gen: Int)
        case stopCapture(discard: Bool)
        case stopOwnedCapture(generation: Int, discard: Bool)
        case cancelCapture(CanceledCapture)
        case presentCanceledCapture(generation: Int)
        case abortOperation(PendingOperation)
        case releaseOwnedRecognition(generation: Int)
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
        case insertText(String, historyEnabled: Bool? = nil, original: OriginalDictationContext? = nil)
        case eraseTypedIfOurs(expect: String)
        /// `if canEraseTyped(expect) { typeBackspaces(erase); typeUnicode(append); hud(verifiedHUD) }
        ///  else { hud(unverifiedHUD) }`
        case replaceTailIfOurs(expect: String, erase: Int, append: String,
                               verifiedHUD: HUDState, unverifiedHUD: HUDState)
        // UI
        case hud(HUDState)
        /// The toast for a `.secure` refusal, carrying the password-field wording.
        /// Its own effect because `.secure` is two signals — a password field, or
        /// secure input held somewhere on the Mac — and telling them apart is a
        /// read of the world, which is the interpreter's job.
        case secureRefusal(String)
        case hideHUD
        case menuBar(MenuBarState)
        case playSound(SoundCue)
        case runSavedPreset(Session)
        case appendTransformHistory(raw: String, cleaned: String?, appName: String?, operation: TransformProvenance, metrics: PipelineMetrics?)
        // records. Fields, not a HistoryEntry: the entry stamps `Date()` and this
        // machine has no clock.
        case appendHistory(raw: String, cleaned: String?, appName: String?)
        case log(String)
        case trace(Trace.Stamp)
        case flushTrace
    }

    // MARK: - Machine

    public private(set) var state: State = .idle {
        didSet {
            switch state {
            case .starting(let s), .recording(let s): activityShadowPermission = s.activityShadowPermission
            default: break // STOP preserves after-stop authority; gen/revocation owns its end.
            }
            let old: Session
            switch oldValue { case .starting(let s), .recording(let s): old = s; default: return }
            switch state {
            case .starting(let s), .recording(let s):
                if s.operation == old.operation { return }
                old.previewPlan?.phase.revoke()
            default: old.previewPlan?.phase.revoke()
            }
        }
    }
    public private(set) var pendingOperation: PendingOperation?
    private var pendingGeneration = 0
    /// Bumped on every accepted fn-down, and on a cancel (which likewise ends the
    /// foreground session); a completion whose session carries an older value
    /// never changes `state`, and mostly never types either.
    public private(set) var activityShadowPermission: ActivityShadowPermission?
    public func revokeActivityShadow() { activityShadowPermission?.revoke() }
    public private(set) var gen = 0 { didSet { revokeActivityShadow(); activityShadowPermission = nil } }
    /// What the stream loop has typed into the field so far. Machine-level, NOT
    /// session-level, and deliberately never cleared at fn-down: a still-queued
    /// finalize from the previous dictation must see it to erase that
    /// dictation's live text.
    public private(set) var typedLedger = ""

    /// The drain queue behind `send(_:perform:)`, and whether a drain is running.
    private var queue: [(PendingOperation?, Int?, SurroundingTextRun?, Effect)] = []
    private var draining = false
    public private(set) var effectOperation: PendingOperation?
    public private(set) var effectSurroundingTextRun: SurroundingTextRun?

    private let diagnostics: DiagnosticStore?
    public init(diagnostics: DiagnosticStore? = .shared) { self.diagnostics = diagnostics }

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
        let contextRun: SurroundingTextRun?
        if case .cleanReady(let s, _, _, _, _, _) = event { contextRun = s.surroundingTextRun } else { contextRun = nil }
        let accepted = effects.compactMap { effect -> PendingOperation? in
            switch effect {
            case .captureAccepted(let s), .captureAcknowledged(let s), .captureFinalizing(let s),
                 .transcribeFinal(let s, _), .transcribeCommand(let s), .finalResult(let s, _): return s.operation
            default: return nil
            }
        }.first
        let canceledGeneration: Int? = effects.contains { if case .cancelCapture = $0 { return true }; return false } ? gen : nil
        queue.append(contentsOf: effects.map { (event.operation ?? accepted, canceledGeneration, contextRun, $0) })
        guard !draining else { return }   // nested: the drain below will get to it
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            let (operation, cancellationGeneration, contextRun, effect) = queue.removeFirst()
            if let cancellationGeneration, cancellationGeneration != gen {
                switch effect {
                case .abortOperation, .cancelCapture, .releaseOwnedRecognition: break
                default: continue // newer foreground owns presentation and typed state
                }
            }
            effectOperation = operation
            effectSurroundingTextRun = contextRun
            if operation?.shouldAbort != true { perform(effect) }
            effectOperation = nil
            effectSurroundingTextRun = nil
        }
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
        guard event.operation?.shouldAbort != true else { return [] }
        switch event {
        case .cancelRequested, .discardPending, .discardOwnedOperation, .focusSampled(_, .secure): revokeActivityShadow()
        default: break
        }
        switch event {
        case let .resultUnavailable(s, failure):
            return terminal(s, .failure(failure)) + finishTail(s)
        case let .discardOwnedOperation(operation, generation):
            operation.revoke()
            if generation == gen, !isCapturing {
                state = .idle
                return [.abortOperation(operation), .menuBar(.idle), .hud(.notice("Discarded"))]
            }
            return [.abortOperation(operation)]
        case let .discardPending(token):
            guard let operation = pendingOperation, operation.id == token else { return [] }
            let outcome = operation.revoke() // synchronous delivery + thread-safe native mirror
            guard outcome != .unchanged else { return [] }
            var effects: [Effect] = [.abortOperation(operation)]
            if pendingGeneration == gen, !isCapturing {
                state = .idle
                effects += [.menuBar(.idle), .hud(.notice(outcome == .deliveryAttempted
                    ? "Already typed — the rest was discarded"
                    : "Discarded"))]
            }
            return effects
        case let .operationDisposalFailed(operation, message):
            guard pendingOperation == operation, pendingGeneration == gen, !isCapturing else { return [] }
            return [.hud(.error(message))]
        case let .operationFinished(operation):
            if pendingOperation == operation { pendingOperation = nil }
            return []

        // MARK: fn-down

        case let .startAutomation(settings, configured, grant):
            guard !isCapturing else { return [] }
            gen += 1
            // The host strips application profiles and validates this frozen request.
            let s = Session(gen: gen, mode: .dictation, settings: settings,
                            cleanupConfigured: configured, diagnostics: diagnostics, delivery: .resultOnly, cleanupFailoverGrant: grant)
            state = .starting(s)
            return [.captureAccepted(s), .trace(.fnDown), .applyPreferencesAndStartCapture(settings)]

        case let .startDictation(settings, cleanupConfigured, live, destination, grant):
            // Always wins, in every state: an in-flight leg's completion will
            // find itself stale. typedLedger is deliberately NOT reset.
            gen += 1
            state = .starting(Session(gen: gen, mode: .dictation, settings: settings,
                                      cleanupConfigured: cleanupConfigured, live: live, recognitionDestination: destination, diagnostics: diagnostics, cleanupFailoverGrant: grant))
            // The warm HEAD request goes out FIRST: its whole job is to finish the
            // TLS handshake before the polish POST, and everything in
            // .applyPreferencesAndStartCapture — recorder.start(), the ~50 ms AX
            // focus probe behind it, a possible 574 MB model reload — is latency
            // it would otherwise queue behind.
            guard case .starting(let accepted) = state else { return [] }
            return [.captureAccepted(accepted), .trace(.fnDown)]
                + (settings.outputMode == .cleanup && settings.profiles.isEmpty && settings.cleanupEnabled && cleanupConfigured ? [.warmCleanupEndpoint] : [])
                + [.applyPreferencesAndStartCapture(settings)]

        case let .startCommand(settings, cleanupConfigured, focus, selection, destination, target):
            // Refuse early — before any recording, and without consuming a
            // generation: a refused command must not silently invalidate an
            // in-flight polish.
            guard focus != .secure else { return [.secureRefusal("Not available in password fields")] }
            guard let selection else { return [.hud(.error("Select text first"))] }
            gen += 1
            state = .starting(Session(gen: gen, mode: .command(selection: selection), settings: settings,
                                      cleanupConfigured: cleanupConfigured, focus: focus, live: false, recognitionDestination: destination, transformTarget: target, diagnostics: diagnostics))
            guard case .starting(let accepted) = state else { return [] }
            return [.captureAccepted(accepted), .applyPreferencesAndStartCapture(settings)]

        case let .startSavedPreset(settings, configured, selection, target):
            guard !isCapturing else { return [.hud(.error("Finish recording first"))] }
            guard target.focus != .secure else { return [.secureRefusal("Not available in password fields")] }
            guard target.focus == .editable || target.focus == .unknown,
                  let selection, !selection.isEmpty else { return [.hud(.error("Select text first"))] }
            let preset: TransformPreset
            do { preset = try settings.selectedTransformPreset() }
            catch { return [.hud(.error(String(describing: error)))] }
            let next = Session(gen: gen + 1, mode: .savedPreset(selection: selection, preset: preset),
                               settings: settings, cleanupConfigured: configured, focus: target.focus,
                               transformTarget: target, diagnostics: diagnostics)
                .resolvingOutput(at: ProfileDestination(bundleID: target.bundleID, browserURL: target.browserURL))
            guard next.effectiveSettings.cleanupEnabled, configured else {
                return [.hud(.error("Turn on cleanup to use presets"))]
            }
            gen += 1
            state = .polishing(gen: gen)
            pendingOperation = next.operation
            pendingGeneration = next.gen
            return [.captureAccepted(next), .menuBar(.busy), .hud(.polishing), .runSavedPreset(next)]

        case let .recorderStarted(g):
            guard case .starting(let s) = state, s.gen == g else { return [] }
            let cues: [Effect] = [.menuBar(.recording), .hud(.listening(command: s.isCommand)),
                                  .playSound(.start)]
            if s.delivery == .resultOnly {
                state = .recording(s)
                return [.ensureModelLoaded, .captureAcknowledged(s)] + cues
            }
            // Dictation samples focus behind the cue and waits for .focusSampled.
            guard s.isCommand else { return cues + [.sampleFocus(gen: g)] }
            state = .recording(s)                  // command mode sampled its focus at fn-down
            return [.ensureModelLoaded, .captureAcknowledged(s)] + cues

        case let .focusSampled(g, focus):
            guard case .starting(var s) = state, s.gen == g else { return [] }
            // Password field: never record, store, or deliver its transcript.
            // Refuse up front. Not the cancel path: its
            // queued HUD hide would wipe this toast.
            guard focus != .secure else {
                s.operation.diagnostics?.disposition(.secure, delivery: .refused)
                state = .idle
                return terminal(s, .failure(.secure)) + [.stopCapture(discard: true), .secureRefusal("Not supported in password fields"),
                        .menuBar(.idle)]
            }
            s.focus = focus
            state = .recording(s)
            // Shadow streaming runs on every dictation so the finalize only ever
            // pays for the unconfirmed tail; typing inside the loop is gated on live.
            return [.captureAcknowledged(s), .ensureModelLoaded,
                    .startStreamLoop(gen: g, dictionary: s.recognition.dictionary,
                                     preview: s.settings.streamPreviewEnabled)]

        case let .recorderFailed(g, message):
            guard case .starting(let s) = state, s.gen == g else { return [] }
            s.operation.diagnostics?.update { $0.capture = .captureFailure }
            state = .idle   // the generation stays consumed, as it does today
            return terminal(s, .failure(.unavailable)) + [.menuBar(.warning), .hud(.error("Mic failed")), .log("Parla mic start failed: \(message)")]

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

        case let .cancelRequested(silent, reason):
            // Guarded on an actual capture. Today's cancel has no such guard, so
            // an Esc after a secure refusal — or after the 10-minute cap already
            // finalized — plays the cancel sound over a session that is already
            // finishing. See the PR note.
            guard isCapturing else { return [] }
            let cancelledSession: Session
            switch state {
            case .starting(let s), .recording(let s): cancelledSession = s
            default: return []
            }
            let cancelledOperation = cancelledSession.operation
            cancelledOperation.revoke(reason: .captureCanceled)
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
            let undoTransfer = cancelledSession.settings.canceledCaptureUndoEnabled
                && cancelledSession.delivery == .keyboard && !cancelledSession.live
                && cancelledSession.mode == .dictation && cancelledSession.settings.outputMode != .selectedPreset
            var fx: [Effect] = [
                .abortOperation(cancelledOperation),
                .log(silent ? "Parla: short tap, discarding" : "Parla: cancelled by keypress"),
                undoTransfer ? .cancelCapture(CanceledCapture(generation: cancelledSession.gen,
                    operation: cancelledOperation, request: cancelledSession.recognition, reason: reason))
                    : cancelledSession.delivery == .resultOnly
                        ? .stopOwnedCapture(generation: cancelledSession.gen, discard: true) : .stopCapture(discard: true),
            ]
            if !silent { fx.append(.playSound(.cancel)) }
            if cancelledSession.delivery == .resultOnly {
                return fx + [.releaseOwnedRecognition(generation: cancelledSession.gen), .hideHUD, .menuBar(.idle)]
            }
            // Undo live-typed text only if still provably ours.
            if !typedLedger.isEmpty { fx.append(.eraseTypedIfOurs(expect: typedLedger)) }
            typedLedger = ""
            fx.append(undoTransfer ? .releaseOwnedRecognition(generation: cancelledSession.gen) : .discardStreamWindow)
            fx.append(silent ? .hideHUD : .hud(.cancelled))
            fx.append(.menuBar(.idle))
            if undoTransfer { fx.append(.presentCanceledCapture(generation: cancelledSession.gen)) }
            return fx

        case .handsFreeLatched:
            guard case .recording = state else { return [] }
            return [.hud(.handsFree), .playSound(.latch)]

        case let .streamTyped(g, text):
            guard g == gen else { return [] }   // a newer session owns the field
            typedLedger = text
            return []

        case let .recognitionPreview(g, operationID, phase, update):
            guard g == gen, case .recording(let s) = state, s.operation.id == operationID,
                  !s.operation.shouldAbort, let plan = s.previewPlan,
                  plan.phase == phase, phase.isCurrent else { return [] }
            let bounded: RecognitionPreviewUpdate
            switch update {
            case .draft(let text, let englishOnly): bounded = .draft(RecognitionPreviewLimits.displaySuffix(text), englishOnly: englishOnly)
            case .status: bounded = update
            }
            return [.hud(.speculativePreview(bounded))]

        case let .recognitionPreviewRevoked(g, operationID, phase):
            guard g == gen, case .recording(let s) = state, s.operation.id == operationID,
                  s.previewPlan?.phase == phase, !phase.isCurrent else { return [] }
            return [.hud(.listening(command: false))]

        case let .streamPreview(g, text):
            // Pill only: no ledger, no history, no landing. Empty text keeps the
            // current label ("Listening…") rather than blanking the pill.
            guard g == gen, case .recording = state, !text.isEmpty else { return [] }
            return [.hud(.preview(text))]

        // MARK: completions

        case let .transcribed(s, raw, probe):
            return transcribed(s, raw: raw, probe: probe)

        case let .cleanReady(s, landed, text, failure, focus, metrics):
            return cleanReady(s, landed, text: text, failure: failure, focus: focus, metrics: metrics)

        case let .commandHeard(s, instruction):
            let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return [.log("Parla transform: no command heard")]
                    + (s.gen == gen ? [.hud(.error("No command heard"))] : [])
                    + transformTail(s)
            }
            return [.transform(s, instruction: trimmed)]

        case let .transformReady(s, text, probe, failure, metrics):
            return transformReady(s, text: text, probe: probe, failure: failure, metrics: metrics)

        case let .legUnavailable(s, message):
            if s.delivery == .resultOnly, s.operation.hasFinalResult { return [] }
            return terminal(s, .failure(.unavailable)) + (s.gen == gen ? [.hud(.error(message))] : [])
                + (s.isCommand ? transformTail(s) : finishTail(s))
        }
    }

    // MARK: - Finalize

    /// Both finalize paths (fn-up and a capture that ended by itself) share this
    /// one builder so neither can drift into its own version.
    private func finalize(_ s: Session) -> [Effect] {
        state = .transcribing(s)
        pendingOperation = s.operation
        pendingGeneration = s.gen
        let stop: Effect = s.delivery == .resultOnly ? .stopOwnedCapture(generation: s.gen, discard: false) : .stopCapture(discard: false)
        let head: [Effect] = (s.delivery == .resultOnly ? [.captureFinalizing(s)] : []) + [stop, .menuBar(.busy), .hud(.transcribing)]
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

    private func terminal(_ s: Session, _ result: DictationFinalResult) -> [Effect] {
        guard !s.isCommand, s.gen == gen, s.operation.claimFinalResult() else { return [] }
        return [.finalResult(s, result)]
    }

    // MARK: - Landing

    /// The instant raw finalize. Deliberately **not** generation-gated: the user
    /// spoke that text, so it lands even if a newer dictation is already
    /// recording. The gen check starts at the swap, where a newer session may own
    /// the field.
    private func transcribed(_ s: Session, raw: String?, probe: LandingProbe) -> [Effect] {
        if s.gen != gen { s.operation.diagnostics?.update { $0.staleCompletion = true } }
        if s.delivery == .resultOnly {
            guard !s.operation.hasFinalResult, s.gen == gen else { return [] }
            guard probe.focus != .secure, s.focus != .secure else {
                return terminal(s, .failure(.secure)) + [.secureRefusal("Not supported in password fields")] + finishTail(s)
            }
            guard let raw else { return terminal(s, .failure(.unavailable)) + [.hideHUD] + finishTail(s) }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return terminal(s, .failure(.empty)) + [.hideHUD] + finishTail(s)
            }
            state = .polishing(gen: s.gen)
            return [.hud(.polishing), .polish(s, Landed(landing: .resultOnly, raw: raw, insertText: "",
                                                       bundleID: nil, appName: nil))]
        }
        let ledger = typedLedger
        typedLedger = ""   // cleared on every branch, including both drops

        guard let raw else {
            var fx: [Effect] = [.log("Parla finish: empty transcript, typed=\(ledger.count)")]
            if !ledger.isEmpty { fx.append(.eraseTypedIfOurs(expect: ledger)) }
            // A newer capture owns the HUD even when this leg has no text.
            if s.gen == gen { fx.append(.hideHUD) }
            return terminal(s, .failure(.empty)) + fx + finishTail(s)
        }

        // Secure re-check FIRST, before the transcript reaches any log: focus may
        // have moved into a password field since fn-down, and the text is
        // plausibly a password. Never type it, never log it, never store it.
        guard probe.focus != .secure, s.focus != .secure else {
            s.operation.diagnostics?.disposition(.secure, delivery: .refused)
            return terminal(s, .failure(.secure)) + [.log("Parla finish path: focus moved to secure field, dropped"),
                    .secureRefusal("Not supported in password fields")] + finishTail(s)
        }

        let s = s.resolvingOutput(at: ProfileDestination(bundleID: probe.bundleID, browserURL: probe.browserURL))
        let willPolish = s.willPolish
        if !willPolish {
            s.operation.diagnostics?.providerSettings(s.effectiveSettings)
            s.operation.diagnostics?.update {
                $0.providerOutcome = s.effectiveSettings.outputMode == .raw ? .off
                    : Pipeline.snippetExpansion(transcript: raw, snippets: s.effectiveSettings.snippets) != nil ? .localSnippet
                    : s.effectiveSettings.cleanupEnabled && !s.cleanupConfigured ? .refused : .off
            }
        }
        if s.effectiveSettings.outputMode != .cleanup || (willPolish && !s.live && probe.deferInsertionUntilClean) {
            if probe.focus == .none { s.operation.diagnostics?.disposition(.noDestination) }
            let pending = Landed(landing: probe.focus == .none ? .history : .pending,
                                 raw: raw, insertText: "", bundleID: probe.bundleID,
                                 appName: probe.appName, browserURL: probe.browserURL,
                                 singleLine: probe.singleLine)
            if s.gen == gen { state = .polishing(gen: s.gen) }
            return (s.gen == gen ? [.hud(s.effectiveSettings.outputMode == .raw ? .transcribing : .polishing)] : []) + [.polish(s, pending)]
        }
        // Flatten against the app the keystrokes actually land in. The cleaned
        // swap reuses this same bundle ID so both sides of its diff agree.
        let category = TextRules.category(bundleID: probe.bundleID, browserURL: probe.browserURL)
        let localText = willPolish || s.effectiveSettings.outputMode == .raw ? raw : LocalVocabulary.finalize(raw, settings: s.effectiveSettings)
        let insertText = probe.singleLine || category == .terminal || category == .chat
            ? TextRules.flattenForTerminal(localText) : localText
        // "polishing…" only when a polish is actually coming; without one the raw
        // transcript IS final, so land the terminal state directly.
        let fieldHUD: HUDState = willPolish ? .polishing : .done
        let historyHUD: HUDState = willPolish ? .polishing
            : s.settings.historyEnabled ? .savedToHistory : .error("No text field to type into — text discarded")

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
                fx += [.log("Parla finish path: focused insert"), .insertText(insertText, original: s.originalCopy(raw)), .hud(fieldHUD)]
                landing = .field
            case .none, .secure:
                s.operation.diagnostics?.disposition(.noDestination)
                // Nothing focused: never type into the void; history may retain it.
                fx += [.log("Parla finish path: no focus, no insertion"), .hud(historyHUD)]
                landing = .history
            }
        }

        fx.append(.trace(.landed))
        let sound: [Effect] = (landing == .field || s.settings.historyEnabled) ? [.playSound(.finish)] : []
        guard willPolish else {
            // Local output is final: retain it when history is enabled, then stop — no
            // polish, no swap, no interstitial that nothing would ever resolve.
            fx += terminal(s, .text(insertText, .final)) + sound
            if s.settings.historyEnabled {
                fx.append(.appendHistory(raw: raw, cleaned: localText != raw ? localText : nil, appName: probe.appName))
            }
            return fx + finishTail(s)
        }
        // The POST is issued after the landing keystrokes, which is the whole
        // point of the effect list being ordered.
        fx.append(.polish(s, Landed(landing: landing, raw: raw, insertText: insertText,
                                    bundleID: probe.bundleID, appName: probe.appName,
                                    browserURL: probe.browserURL, singleLine: probe.singleLine)))
        fx += sound
        if s.gen == gen { state = .polishing(gen: s.gen) }
        return fx
    }

    // MARK: - Cleaned swap

    private func cleanReady(_ s: Session, _ landed: Landed, text: String, failure: String?,
                            focus: Inserter.FocusTarget, metrics: PipelineMetrics?) -> [Effect] {
        let contextRevoked = s.surroundingTextRun.insertionOnly && (try? s.surroundingTextRun.check()) == nil
        let text = contextRevoked ? LiteralReplacement.apply(s.effectiveSettings.replacements, to: landed.raw) : text
        let failure = contextRevoked ? "cleanup failed" : failure
        if contextRevoked { s.surroundingTextRun.discardAcceptedOutput() } // Only the proven raw fallback remains.
        if s.gen != gen { s.operation.diagnostics?.update { $0.staleCompletion = true } }
        if s.delivery == .resultOnly {
            guard !s.operation.hasFinalResult, s.gen == gen else { return [] }
            guard focus != .secure, s.focus != .secure else {
                return terminal(s, .failure(.secure)) + [.secureRefusal("Not supported in password fields")] + finishTail(s)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return terminal(s, .failure(.empty)) + [.hud(.error("No text recognized"))] + finishTail(s)
            }
            var fx = terminal(s, .text(text, failure == nil ? .final : .localFallback))
            // Retrieval is independent of the ordinary, latched history/audio policy.
            if s.settings.historyEnabled {
                fx.append(.appendHistory(raw: landed.raw, cleaned: text != landed.raw ? text : nil, appName: nil))
            }
            fx += [.hud(.notice(failure == nil ? "Result ready" : "Result ready (without cleanup)")), .playSound(.finish)]
            return fx + finishTail(s)
        }
        if s.effectiveSettings.outputMode == .selectedPreset {
            return dictatedPresetReady(s, landed, text: text, failure: failure, focus: focus, metrics: metrics)
        }
        let historyEnabled = s.settings.historyEnabled
        // On provider failure Pipeline returns raw plus any explicitly configured
        // local rules. Keep that local result without retaining failed model output.
        let retainFinal = !s.surroundingTextRun.insertionOnly && (failure == nil || !s.settings.replacements.isEmpty)
        if landed.landing == .pending {
            // Nothing has been written yet. Never send late text into a newer
            // session or a changed target. A secure destination drops the result
            // entirely, including history, just like the initial landing check.
            if s.gen == gen, focus == .secure {
                s.operation.diagnostics?.disposition(.secure, delivery: .refused)
                return terminal(s, .failure(.secure)) + [.secureRefusal("Not supported in password fields")] + finishTail(s)
            }
            let category = TextRules.category(bundleID: landed.bundleID, browserURL: landed.browserURL)
            let finalText = landed.singleLine || category == .terminal || category == .chat
                ? TextRules.flattenForTerminal(text) : text
            var fx: [Effect] = []
            if s.gen == gen {
                if focus == .editable || focus == .unknown {
                    fx += [.insertText(finalText, historyEnabled: s.effectiveSettings.outputMode == .raw ? historyEnabled : nil, original: s.originalCopy(landed.raw)), .trace(.landed), .playSound(.finish),
                           .hud(failure.map(HUDState.rawFallback) ?? .done)]
                } else {
                    s.operation.diagnostics?.disposition(.noDestination)
                    fx.append(.log("Parla delivery: no current destination, insertion withheld"))
                    fx.append(.hud(s.surroundingTextRun.insertionOnly
                        ? .notice(historyEnabled ? "No text field to type into — saved in History" : "No text field to type into")
                        : historyEnabled ? .savedToHistory : .error("No text field to type into — text discarded")))
                }
            } else {
                s.operation.diagnostics?.disposition(.staleGeneration)
                fx.append(.log("Parla delivery: newer dictation started, insertion withheld"))
            }
            if historyEnabled {
                fx.append(.appendHistory(raw: landed.raw,
                                         cleaned: retainFinal && text != landed.raw ? text : nil,
                                         appName: landed.appName))
            }
            fx += terminal(s, .text(finalText, failure == nil ? .final : .localFallback))
            fx.append(.trace(.cleanedSwapped))
            return fx + finishTail(s)
        }
        if s.surroundingTextRun.insertionOnly {
            return terminal(s, .failure(.unavailable)) + (historyEnabled ? [.appendHistory(raw: landed.raw, cleaned: nil, appName: landed.appName)] : []) + finishTail(s)
        }
        // The cleaned text replaces insertText in the field, so it must be
        // flattened too — and diffed flattened-vs-flattened or the erase counts
        // won't match what's on screen.
        let category = TextRules.category(bundleID: landed.bundleID, browserURL: landed.browserURL)
        let cleaned = landed.singleLine || category == .terminal || category == .chat
            ? TextRules.flattenForTerminal(text) : text
        let plan = LiveTyper.swapPlan(raw: landed.insertText, cleaned: cleaned)
        let failureHUD = failure.map(HUDState.rawFallback)
        let unverifiedHUD: HUDState = historyEnabled ? .cleanedInHistory
            : .error("Couldn’t apply cleanup — kept your original text")

        var fx: [Effect] = []
        if s.gen != gen {
            s.operation.diagnostics?.disposition(.staleGeneration)
            // A newer dictation owns the field and the HUD — no keystrokes, no
            // HUD. History still records the result below.
            fx.append(.log("Parla swap: stale generation, no swap"))
        } else if landed.landing == .field, focus == .secure {
            s.operation.diagnostics?.disposition(.secure, delivery: .refused)
            fx.append(.log("Parla swap path: focus moved to secure field, no cleaned swap"))
            fx.append(.hud(failureHUD ?? (plan == nil ? .done : unverifiedHUD)))
        } else {
            switch landed.landing {
            case .pending, .resultOnly:
                break // handled above
            case .history:
                // Nothing of ours in a field — history is the only durable landing.
                fx.append(.hud(historyEnabled ? (failureHUD ?? .savedToHistory)
                                              : .error("No text field to type into — text discarded")))
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
        fx += terminal(s, .text(cleaned, failure == nil ? .final : .localFallback))
        fx.append(.trace(.cleanedSwapped))
        if historyEnabled {
            // Retain local replacements even when the provider failed; raw stays original.
            let cleanedForHistory = retainFinal && text != landed.raw ? text : nil
            fx.append(.appendHistory(raw: landed.raw, cleaned: cleanedForHistory, appName: landed.appName))
        }
        return fx + finishTail(s)
    }

    // MARK: - Transform

    private func transformReady(_ s: Session, text: String, probe: TransformProbe,
                                failure: String?, metrics: PipelineMetrics?) -> [Effect] {
        if s.gen != gen { s.operation.diagnostics?.update { $0.staleCompletion = true } }
        let transformed = failure == nil ? try? IntentionalTransform.result(text, source: s.selection) : nil
        let safe = s.gen == gen && probe.focus != .secure
            && (probe.focus == .editable || probe.focus == .unknown)
            && probe.destinationStillMatches && probe.selectionStillMatches
        if !safe { s.operation.diagnostics?.disposition(s.gen != gen ? .staleGeneration : probe.focus == .secure ? .secure : !probe.destinationStillMatches ? .destinationChanged : .selectionChanged) }
        if transformed == nil { s.operation.diagnostics?.disposition(.resultUnavailable) }
        var fx: [Effect] = []
        if let transformed, safe {
            let target = s.transformTarget
            let category = TextRules.category(bundleID: target?.bundleID ?? probe.bundleID,
                                              browserURL: target?.browserURL ?? probe.browserURL)
            let flatten = (target?.singleLine ?? probe.singleLine) || category == .terminal || category == .chat
            fx += [.insertText(flatten ? TextRules.flattenForTerminal(transformed) : transformed, historyEnabled: s.settings.historyEnabled),
                   .playSound(.finish), .hud(.done)]
        } else if s.gen == gen {
            let message: HUDState = transformed == nil ? .error(failure ?? "Transform failed")
                : s.settings.historyEnabled ? .savedToHistory : .error("No text field to type into — text discarded")
            fx.append(.hud(message))
        }
        if s.settings.historyEnabled {
            let record = Effect.appendTransformHistory(raw: s.selection, cleaned: transformed,
                appName: s.transformTarget?.appName,
                operation: TransformProvenance(origin: s.preset == nil ? .spoken : .selection, preset: s.preset,
                                               outcome: transformed == nil ? .failed : safe ? .completed : .parked),
                metrics: metrics)
            fx.insert(record, at: transformed != nil && safe ? 1 : fx.count)
        }
        return fx + transformTail(s)
    }

    private func dictatedPresetReady(_ s: Session, _ landed: Landed, text: String, failure: String?,
                                     focus: Inserter.FocusTarget, metrics: PipelineMetrics?) -> [Effect] {
        // Native secure capture exclusion applies to dictated source/results too.
        if s.gen == gen, focus == .secure {
            s.operation.diagnostics?.disposition(.secure, delivery: .refused)
            return terminal(s, .failure(.secure)) + [.secureRefusal("Not supported in password fields")] + finishTail(s)
        }
        let result = failure == nil ? try? IntentionalTransform.result(text, source: landed.raw) : nil
        let safe = s.gen == gen && landed.landing == .pending && (focus == .editable || focus == .unknown)
        if !safe { s.operation.diagnostics?.disposition(s.gen != gen ? .staleGeneration : .noDestination) }
        if result == nil { s.operation.diagnostics?.disposition(.resultUnavailable) }
        var fx: [Effect] = []
        if let result, safe {
            let category = TextRules.category(bundleID: landed.bundleID, browserURL: landed.browserURL)
            let flatten = landed.singleLine || category == .terminal || category == .chat
            fx += [.insertText(flatten ? TextRules.flattenForTerminal(result) : result, historyEnabled: s.settings.historyEnabled), .playSound(.finish), .hud(.done)]
        } else if s.gen == gen {
            fx.append(.hud(result == nil ? .error(failure ?? "Transform failed")
                : s.settings.historyEnabled ? .savedToHistory : .error("No text field to type into — text discarded")))
        }
        if s.settings.historyEnabled {
            let record = Effect.appendTransformHistory(raw: landed.raw, cleaned: result, appName: landed.appName,
                operation: TransformProvenance(origin: .dictation, preset: try? s.settings.selectedTransformPreset(),
                                              outcome: result == nil ? .failed : safe ? .completed : .parked), metrics: metrics)
            fx.insert(record, at: result != nil && safe ? 1 : fx.count)
        }
        fx += terminal(s, result.map { .text($0, .final) } ?? .failure(.unavailable))
        return fx + finishTail(s)
    }
}

// A rejected token stays attached to old completions after queue ownership ends;
// no permanent generation/tombstone registry is needed.
extension DictationSession.Event {
    public var operation: PendingOperation? {
        switch self {
        case .transcribed(let s, _, _), .commandHeard(let s, _), .cleanReady(let s, _, _, _, _, _),
             .transformReady(let s, _, _, _, _), .legUnavailable(let s, _), .resultUnavailable(let s, _): return s.operation
        default: return nil
        }
    }
}
