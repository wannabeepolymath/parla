import XCTest
@testable import ParlaCore

/// The dictation flow, driven exactly like HotkeyTests drives HotkeyMonitor:
/// feed events, assert on the returned effect list. Nothing here touches AX, a
/// mic, whisper or the network — that is the whole point of the extraction.
final class DictationSessionTests: XCTestCase {
    typealias Event = DictationSession.Event
    typealias Effect = DictationSession.Effect
    typealias Session = DictationSession.Session
    typealias Landed = DictationSession.Landed

    let m = DictationSession()   // fresh per test method (XCTest builds a new instance)

    func settings(history: Bool = true, dictionary: [String] = []) -> Settings {
        var s = Settings()
        s.historyEnabled = history
        s.dictionary = dictionary
        return s
    }

    /// Effects of the last event in the sequence.
    @discardableResult
    func run(_ events: Event...) -> [Effect] {
        var last: [Effect] = []
        for e in events { last = m.handle(e) }
        return last
    }

    /// Every effect the sequence produced, in order.
    @discardableResult
    func runAll(_ events: Event...) -> [Effect] {
        events.flatMap { m.handle($0) }
    }

    /// Logs are free-form prose; assert on them only where the content is the point.
    func quiet(_ fx: [Effect]) -> [Effect] {
        fx.filter { if case .log = $0 { return false }; return true }
    }

    /// The session the machine currently has in the foreground.
    var session: Session {
        switch m.state {
        case .starting(let s), .recording(let s), .transcribing(let s): return s
        case .idle, .polishing:
            XCTFail("no foreground session: \(m.state)")
            return Session(gen: -1, mode: .dictation, settings: Settings(), cleanupConfigured: false)
        }
    }

    /// fn-down → mic live → focus sampled. Leaves the machine recording.
    @discardableResult
    func startDictation(_ s: Settings? = nil, cleanup: Bool = true, live: Bool = false,
                        focus: Inserter.FocusTarget = .editable) -> Session {
        let set = s ?? settings()
        _ = m.handle(.startDictation(settings: set, cleanupConfigured: cleanup, live: live))
        _ = m.handle(.recorderStarted(gen: m.gen))
        _ = m.handle(.focusSampled(gen: m.gen, focus: focus))
        return session
    }

    func probe(_ focus: Inserter.FocusTarget = .editable, bundleID: String? = "com.apple.TextEdit",
               appName: String? = "TextEdit", typedIsOurs: Bool = false) -> LandingProbe {
        LandingProbe(focus: focus, bundleID: bundleID, appName: appName, typedIsOurs: typedIsOurs)
    }

    // MARK: - Happy path

    func testHappyPathNoCleanupLandsRawAndStops() {
        let s = startDictation(cleanup: false)
        XCTAssertEqual(quiet(m.handle(.stopRequested)),
                       [.trace(.fnUp), .stopCapture(discard: false), .menuBar(.busy),
                        .hud(.transcribing), .transcribeFinal(s, typedLedger: "")])
        XCTAssertEqual(m.state, .transcribing(s))

        let fx = m.handle(.transcribed(s, raw: "hello world", probe: probe()))
        XCTAssertEqual(quiet(fx), [
            .insertText("hello world"),
            .hud(.done),                 // no polish coming ⇒ terminal state, no interstitial
            .trace(.landed),
            .playSound(.finish),
            .appendHistory(raw: "hello world", cleaned: nil, appName: "TextEdit"),
            .flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate,
        ])
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isCapturing)
    }

    func testStartDictationEffectsAndStates() {
        // The warm HEAD request goes out BEFORE the capture start: it exists to
        // finish the TLS handshake before the polish POST, and everything in
        // .applyPreferencesAndStartCapture (recorder.start, the AX focus probe
        // behind it, a possible model reload) is latency it would queue behind.
        XCTAssertEqual(m.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: false)),
                       [.trace(.fnDown), .warmCleanupEndpoint,
                        .applyPreferencesAndStartCapture(settings())])
        XCTAssertTrue(m.isCapturing)
        // The focus probe is an effect the machine emits after the cue, not
        // something the interpreter decides by looking at `state`.
        XCTAssertEqual(m.handle(.recorderStarted(gen: 1)),
                       [.menuBar(.recording), .hud(.listening(command: false)), .playSound(.start),
                        .sampleFocus(gen: 1)])
        XCTAssertEqual(m.handle(.focusSampled(gen: 1, focus: .editable)),
                       [.ensureModelLoaded, .startStreamLoop(gen: 1, dictionary: [], preview: false)])
        XCTAssertTrue(m.isCapturing)
    }

    // MARK: - Effect order under nested events

    /// The property itself: an effect that dispatches another event APPENDS that
    /// event's effects behind the ones still pending, instead of splicing a whole
    /// nested list into the middle of the list currently running.
    ///
    /// Today's fn-down list survives a recursive interpreter only by accident —
    /// the one effect that dispatches (`.applyPreferencesAndStartCapture`) is
    /// last. Put anything after it, as `.warmCleanupEndpoint` once was, and
    /// recursion silently runs it after the whole nested chain. So the dispatch
    /// here is deliberately hung off the FIRST effect, where the outer list still
    /// has entries to protect.
    func testNestedEventsAppendInsteadOfInterleaving() {
        var seen: [Effect] = []
        m.send(.startDictation(settings: settings(), cleanupConfigured: true, live: false)) { effect in
            seen.append(effect)
            if case .trace = effect { self.m.send(.recorderStarted(gen: 1)) { seen.append($0) } }
        }
        XCTAssertEqual(seen, [
            .trace(.fnDown),
            .warmCleanupEndpoint, .applyPreferencesAndStartCapture(settings()),  // still first
            .menuBar(.recording), .hud(.listening(command: false)), .playSound(.start),
            .sampleFocus(gen: 1),
        ])
    }

    /// And the seam as the shell actually wires it: recorder.start() reports
    /// `.recorderStarted`, the focus probe reports `.focusSampled`, and the whole
    /// fn-down sequence still comes out warm-request first, chime before the
    /// ~50 ms AX probe, model load and stream loop last.
    func testFnDownRunsWarmRequestFirstAndProbesFocusBehindTheChime() {
        drive(.startDictation(settings: settings(), cleanupConfigured: true, live: false))
        XCTAssertEqual(order, [
            .trace(.fnDown), .warmCleanupEndpoint, .applyPreferencesAndStartCapture(settings()),
            .menuBar(.recording), .hud(.listening(command: false)), .playSound(.start),
            .sampleFocus(gen: 1),                                 // AX probe behind the chime
            .ensureModelLoaded, .startStreamLoop(gen: 1, dictionary: [], preview: false),
        ])
        XCTAssertEqual(m.state, .recording(session))
    }

    var order: [Effect] = []

    /// The shell's dispatch loop, wired exactly as Dictation.swift wires it.
    func drive(_ event: Event) {
        m.send(event) { effect in
            self.order.append(effect)
            switch effect {
            case .applyPreferencesAndStartCapture: self.drive(.recorderStarted(gen: self.m.gen))
            case let .sampleFocus(gen): self.drive(.focusSampled(gen: gen, focus: .editable))
            default: break
            }
        }
    }

    func testMicFailureShowsWarningAndStillConsumesTheGeneration() {
        _ = m.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: false))
        XCTAssertEqual(m.handle(.recorderFailed(gen: 1, message: "noInputFormat")),
                       [.menuBar(.warning), .hud(.error("Mic failed")),
                        .log("Parla mic start failed: noInputFormat")])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.gen, 1)
    }

    // MARK: - Instant finalize, cleaned swap behind it (ISSUES #5)

    func testPolishIsIssuedAfterTheLandingKeystrokes() {
        let s = startDictation()
        _ = m.handle(.stopRequested)
        let fx = m.handle(.transcribed(s, raw: "hello world", probe: probe()))
        let landed = Landed(landing: .field, raw: "hello world", insertText: "hello world",
                            bundleID: "com.apple.TextEdit", appName: "TextEdit")
        XCTAssertEqual(quiet(fx), [.insertText("hello world"), .hud(.polishing), .trace(.landed),
                                   .polish(s, landed), .playSound(.finish)])
        // The contract is the ORDER: keystrokes on screen, then the POST.
        XCTAssertLessThan(fx.firstIndex(of: .insertText("hello world"))!,
                          fx.firstIndex(of: .polish(s, landed))!)
        XCTAssertEqual(m.state, .polishing(gen: 1))

        let plan = LiveTyper.swapPlan(raw: "hello world", cleaned: "Hello, world.")!
        XCTAssertEqual(quiet(m.handle(.cleanReady(s, landed, text: "Hello, world.",
                                                  failure: nil, focus: .editable))), [
            .replaceTailIfOurs(expect: "hello world", erase: plan.eraseTail.count,
                               append: plan.replacement, verifiedHUD: .done,
                               unverifiedHUD: .cleanedInHistory),
            .trace(.cleanedSwapped),
            .appendHistory(raw: "hello world", cleaned: "Hello, world.", appName: "TextEdit"),
            .flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate,
        ])
        XCTAssertEqual(m.state, .idle)
    }

    func testCleanupFailureKeepsRawAndShowsTheReason() {
        let s = startDictation()
        _ = m.handle(.stopRequested)
        _ = m.handle(.transcribed(s, raw: "hello world", probe: probe()))
        let landed = Landed(landing: .field, raw: "hello world", insertText: "hello world",
                            bundleID: "com.apple.TextEdit", appName: "TextEdit")
        // Pipeline's raw fallback returns the transcript unchanged ⇒ no swap plan.
        let fx = quiet(m.handle(.cleanReady(s, landed, text: "hello world",
                                            failure: "cleanup timed out", focus: .editable)))
        XCTAssertEqual(fx.first, .hud(.rawFallback("cleanup timed out")))
        XCTAssertFalse(fx.contains { if case .replaceTailIfOurs = $0 { return true }; return false })
        // A failed cleanup is never stored as the cleaned version — asserted on a
        // result that DIFFERS from the raw, because above the two are equal and
        // history would drop `cleaned` on the raw-match clause alone. Only this
        // delivery notices if the `failure == nil` half of that clause goes away.
        XCTAssertTrue(quiet(m.handle(.cleanReady(s, landed, text: "Hello, world.",
                                                 failure: "cleanup timed out", focus: .editable)))
            .contains(.appendHistory(raw: "hello world", cleaned: nil, appName: "TextEdit")))
    }

    func testTerminalFlatteningAppliesToBothSidesOfTheSwap() {
        let s = startDictation()
        _ = m.handle(.stopRequested)
        let fx = m.handle(.transcribed(s, raw: "ls -la\nthen exit",
                                       probe: probe(bundleID: "com.apple.Terminal", appName: "Terminal")))
        XCTAssertTrue(fx.contains(.insertText("ls -la then exit")))
        guard case .polish(_, let landed)? = fx.first(where: {
            if case .polish = $0 { return true }; return false
        }) else { return XCTFail("no polish") }
        XCTAssertEqual(landed.insertText, "ls -la then exit")
        XCTAssertEqual(landed.raw, "ls -la\nthen exit")   // history keeps the real transcript

        let swap = quiet(m.handle(.cleanReady(s, landed, text: "ls -la\nthen exit please",
                                              failure: nil, focus: .editable)))
        guard case .replaceTailIfOurs(let expect, _, let append, _, _)? = swap.first else {
            return XCTFail("no swap: \(swap)")
        }
        XCTAssertEqual(expect, "ls -la then exit")        // diffed flattened-vs-flattened
        XCTAssertFalse(append.contains("\n"))
    }

    // MARK: - Live-typed diff finalize (ISSUES #6, #7)

    func testVerifiedDiffFinalizeReplacesOnlyTheDivergingTail() {
        let s = startDictation(live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hello"))
        XCTAssertEqual(m.typedLedger, "hello")
        XCTAssertEqual(m.handle(.stopRequested).last, .transcribeFinal(s, typedLedger: "hello"))
        let fx = quiet(m.handle(.transcribed(s, raw: "hello world",
                                             probe: probe(typedIsOurs: true))))
        XCTAssertEqual(fx.first, .replaceTailIfOurs(expect: "hello", erase: 0, append: " world",
                                                    verifiedHUD: .polishing, unverifiedHUD: .polishing))
        XCTAssertTrue(fx.contains(.playSound(.finish)))
        XCTAssertEqual(m.typedLedger, "")   // cleared at landing, never at fn-down
    }

    func testUnverifiedDiffFinalizeDemotesToHistoryAndTypesNothing() {
        let s = startDictation(settings(history: true), cleanup: false, live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "helo"))
        _ = m.handle(.stopRequested)
        let fx = quiet(m.handle(.transcribed(s, raw: "hello world", probe: probe(typedIsOurs: false))))
        XCTAssertEqual(fx, [.hud(.savedToHistory), .trace(.landed), .playSound(.finish),
                            .appendHistory(raw: "hello world", cleaned: nil, appName: "TextEdit"),
                            .flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate])
        XCTAssertFalse(fx.contains { if case .replaceTailIfOurs = $0 { return true }; return false })
    }

    /// The same demotion with history off: no durable landing at all, so the
    /// "landed" sound must not play.
    func testUnverifiedDiffFinalizeWithHistoryOffIsSilent() {
        let s = startDictation(settings(history: false), cleanup: false, live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "helo"))
        _ = m.handle(.stopRequested)
        let fx = quiet(m.handle(.transcribed(s, raw: "hello world", probe: probe(typedIsOurs: false))))
        XCTAssertEqual(fx.first, .hud(.error("History off — text discarded")))
        XCTAssertFalse(fx.contains(.playSound(.finish)))
        XCTAssertFalse(fx.contains { if case .appendHistory = $0 { return true }; return false })
    }

    func testStreamedTextAlreadyFinalEmitsNoKeystrokes() {
        let s = startDictation(cleanup: false, live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hello world"))
        _ = m.handle(.stopRequested)
        let fx = quiet(m.handle(.transcribed(s, raw: "hello world", probe: probe(typedIsOurs: false))))
        XCTAssertEqual(fx.first, .hud(.done))   // landed in the field: nothing to do
        XCTAssertTrue(fx.contains(.playSound(.finish)))
        XCTAssertEqual(fx.filter { if case .insertText = $0 { return true }; return false }, [])
    }

    func testNoFocusNeverTypesIntoTheVoid() {
        let s = startDictation(cleanup: false, focus: .none)
        _ = m.handle(.stopRequested)
        let fx = quiet(m.handle(.transcribed(s, raw: "hello world", probe: probe(.none))))
        XCTAssertEqual(fx.first, .hud(.savedToHistory))
        XCTAssertEqual(fx.filter { if case .insertText = $0 { return true }; return false }, [])
    }

    func testOpaqueFieldStillGetsASingleInsert() {
        let s = startDictation(cleanup: false, focus: .unknown)
        _ = m.handle(.stopRequested)
        XCTAssertTrue(m.handle(.transcribed(s, raw: "hello world", probe: probe(.unknown)))
            .contains(.insertText("hello world")))
    }

    func testEmptyTranscriptUndoesTheStreamedTextAndHidesTheHUD() {
        let s = startDictation(live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hel"))
        _ = m.handle(.stopRequested)
        XCTAssertEqual(quiet(m.handle(.transcribed(s, raw: nil, probe: probe()))),
                       [.eraseTypedIfOurs(expect: "hel"), .hideHUD,
                        .flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate])
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - HUD streaming preview (Tier 2 #1)

    /// The preview is UI and nothing else: it shows in the pill, and it leaves no
    /// mark on the ledger, on history, or on the transcript that lands.
    func testStreamPreviewOnlyDrawsTheHUD() {
        let s = startDictation()
        XCTAssertEqual(m.handle(.streamPreview(gen: 1, text: "hello wor")), [.hud(.preview("hello wor"))])
        XCTAssertEqual(m.typedLedger, "")
        _ = m.handle(.stopRequested)
        // Preview text is not a transcript: an empty raw still finalizes as empty.
        XCTAssertEqual(quiet(m.handle(.transcribed(s, raw: nil, probe: probe()))),
                       [.hideHUD, .flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate])
    }

    func testStreamPreviewIsDroppedWhenStaleEmptyOrNotRecording() {
        startDictation()
        XCTAssertEqual(m.handle(.streamPreview(gen: 0, text: "old")), [])   // previous dictation
        XCTAssertEqual(m.handle(.streamPreview(gen: 1, text: "")), [])      // would blank the pill
        _ = m.handle(.stopRequested)                                        // no longer recording
        XCTAssertEqual(m.handle(.streamPreview(gen: 1, text: "late")), [])
    }

    /// The gate the shadow-stream fix depends on: the loop only learns to run its
    /// tail pass early when the user opted into previews.
    func testStreamLoopIsToldWhetherPreviewsAreOn() {
        XCTAssertFalse(Settings().streamPreviewEnabled)   // costs GPU every dictation: opt-in
        var set = settings()
        set.streamPreviewEnabled = true
        _ = m.handle(.startDictation(settings: set, cleanupConfigured: true, live: false))
        _ = m.handle(.recorderStarted(gen: 1))
        XCTAssertEqual(m.handle(.focusSampled(gen: 1, focus: .editable)),
                       [.ensureModelLoaded, .startStreamLoop(gen: 1, dictionary: [], preview: true)])
    }

    // MARK: - Cancel

    func testCancelMidRecordingStopsErasesAndClears() {
        startDictation(live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hello"))
        XCTAssertEqual(quiet(m.handle(.cancelRequested(silent: false))),
                       [.stopCapture(discard: true), .playSound(.cancel),
                        .eraseTypedIfOurs(expect: "hello"), .discardStreamWindow,
                        .hud(.cancelled), .menuBar(.idle)])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.typedLedger, "")
    }

    func testShortTapDiscardsSilentlyAndNeverTranscribes() {
        startDictation()
        let fx = m.handle(.cancelRequested(silent: true))
        XCTAssertEqual(quiet(fx), [.stopCapture(discard: true), .discardStreamWindow,
                                   .hideHUD, .menuBar(.idle)])
        XCTAssertFalse(fx.contains { if case .transcribeFinal = $0 { return true }; return false })
        XCTAssertFalse(fx.contains { if case .transcribeCommand = $0 { return true }; return false })
        XCTAssertFalse(fx.contains(.playSound(.cancel)))
        XCTAssertEqual(m.state, .idle)
    }

    /// Cancel consumes a generation, so a streaming pass that was already sitting
    /// on its MainActor hop cannot report back and re-fill the ledger with text
    /// the cancel just erased — which the next dictation's finalize would then
    /// try to erase a second time.
    func testLateStreamTypedAfterCancelCannotResurrectTheLedger() {
        startDictation(live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hello"))
        XCTAssertTrue(m.handle(.cancelRequested(silent: false))
            .contains(.eraseTypedIfOurs(expect: "hello")))
        XCTAssertEqual(m.handle(.streamTyped(gen: 1, text: "hello there")), [])
        XCTAssertEqual(m.typedLedger, "")

        // …and the next dictation's finalize has nothing of the cancelled one to
        // erase.
        let s = startDictation(cleanup: false)
        _ = m.handle(.stopRequested)
        let fx = m.handle(.transcribed(s, raw: "new text", probe: probe()))
        XCTAssertTrue(fx.contains(.insertText("new text")))
        XCTAssertFalse(fx.contains { if case .eraseTypedIfOurs = $0 { return true }; return false })
    }

    func testCancelWithNothingStreamedEmitsNoDelete() {
        startDictation()
        let fx = m.handle(.cancelRequested(silent: false))
        XCTAssertFalse(fx.contains { if case .eraseTypedIfOurs = $0 { return true }; return false })
    }

    /// Tightening over today's behaviour: an Esc after the capture already
    /// finalized used to play the cancel sound over a session that is finishing.
    func testCancelIsIgnoredOnceTheCaptureIsDone() {
        startDictation()
        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.handle(.cancelRequested(silent: false)), [])
        XCTAssertEqual(m.handle(.cancelRequested(silent: true)), [])
        XCTAssertEqual(m.handle(.handsFreeLatched), [])
        XCTAssertEqual(m.handle(.stopRequested), [])
    }

    // MARK: - Hands-free (ISSUES #8)

    func testHandsFreeLatchRelabelsAndKeepsRecording() {
        let s = startDictation()
        XCTAssertEqual(m.handle(.handsFreeLatched), [.hud(.handsFree), .playSound(.latch)])
        XCTAssertEqual(m.state, .recording(s))
        XCTAssertTrue(m.isCapturing)
    }

    /// All four hands-free exits are resolved inside HotkeyMonitor's own pure
    /// machine, so this drives the real monitor and checks the dictation machine
    /// ends up in the right state for each — fn press, Space, Return, Esc.
    func testEveryHandsFreeExitEndsTheDictation() {
        for (label, exit) in exits {
            let machine = DictationSession()
            let monitor = HotkeyMonitor()
            var fx: [Effect] = []
            monitor.onEdge = { edge in
                guard let event = self.event(for: edge) else { return }
                fx += machine.handle(event)
                if case .startDictation = event {
                    fx += machine.handle(.recorderStarted(gen: machine.gen))
                    fx += machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
                }
            }
            monitor.handle(keyCode: 63, modifiers: [.fn], at: 0)          // fn down
            _ = monitor.keyDown(keyCode: 49, modifiers: [.fn], at: 0.5)   // fn+Space: latch
            XCTAssertTrue(fx.contains(.hud(.handsFree)), label)
            exit(monitor)
            if label == "esc" {
                XCTAssertEqual(machine.state, .idle, label)
                XCTAssertTrue(fx.contains(.hud(.cancelled)), label)
            } else {
                XCTAssertTrue(fx.contains { if case .transcribeFinal = $0 { return true }; return false },
                              label)
                if case .transcribing = machine.state {} else { XCTFail("\(label): \(machine.state)") }
            }
        }
    }

    var exits: [(String, (HotkeyMonitor) -> Void)] {
        [("fn", { $0.handle(keyCode: 63, modifiers: [.fn], at: 2) }),
         ("space", { _ = $0.keyDown(keyCode: 49, at: 2) }),
         ("return", { _ = $0.keyDown(keyCode: 36, at: 2) }),
         ("esc", { _ = $0.keyDown(keyCode: 53, at: 2) })]
    }

    /// The shell's edge → event mapping, mirrored here so the integration test
    /// above exercises the same wiring main.swift will use.
    func event(for edge: HotkeyMonitor.Edge) -> Event? {
        switch edge {
        case .down(let command):
            return command
                ? .startCommand(settings: settings(), cleanupConfigured: true,
                                focus: .editable, selection: "the cat")
                : .startDictation(settings: settings(), cleanupConfigured: true, live: false)
        case .up(let short): return short ? .cancelRequested(silent: true) : .stopRequested
        case .cancel: return .cancelRequested(silent: false)
        case .handsFree: return .handsFreeLatched
        case .pasteLast, .openScratchpad, .dismiss: return nil   // never touch dictation state
        }
    }

    // MARK: - Capture ended by itself (10-minute cap, mic gone)

    func testCaptureEndedMatchesFnUpMinusTheFnUpStamp() {
        let a = DictationSession(), b = DictationSession()
        for machine in [a, b] {
            _ = machine.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: false))
            _ = machine.handle(.recorderStarted(gen: 1))
            _ = machine.handle(.focusSampled(gen: 1, focus: .editable))
        }
        let byFnUp = a.handle(.stopRequested)
        let byEnd = quiet(b.handle(.captureEnded(gen: 1, reason: .sampleLimit)))
        XCTAssertEqual(byEnd, byFnUp.filter { $0 != .trace(.fnUp) })
        XCTAssertEqual(a.state, b.state)
        XCTAssertTrue(b.handle(.captureEnded(gen: 1, reason: .sampleLimit)).isEmpty) // not twice
    }

    /// The shell reads the generation on the tap thread as the capture ends (out
    /// of the capture mirror), NOT at delivery time — so this guard is real: an
    /// fn-down that lands between the mic dying and the hop running must not let
    /// the dead capture finalize the dictation that just started.
    func testStaleCaptureEndCannotFinalizeANewerSession() {
        startDictation()
        _ = m.handle(.stopRequested)
        startDictation()                     // gen 2 is recording
        XCTAssertEqual(m.handle(.captureEnded(gen: 1, reason: .deviceLost)), [])
        // 0 is the mirror's "nobody holds the mic" sentinel — an end that arrives
        // after the capture already stopped finalizes nothing either.
        XCTAssertEqual(m.handle(.captureEnded(gen: 0, reason: .deviceLost)), [])
        XCTAssertEqual(m.state, .recording(session))
    }

    // MARK: - Secure fields

    func testSecureFocusRefusesAfterStartWithoutRoutingThroughCancel() {
        _ = m.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: false))
        _ = m.handle(.recorderStarted(gen: 1))
        let fx = m.handle(.focusSampled(gen: 1, focus: .secure))
        XCTAssertEqual(fx, [.stopCapture(discard: true),
                            .hud(.error("Not supported in password fields")), .menuBar(.idle)])
        XCTAssertFalse(fx.contains(.hideHUD))   // a queued hide would wipe the toast
        XCTAssertFalse(fx.contains { if case .startStreamLoop = $0 { return true }; return false })
        XCTAssertEqual(m.state, .idle)
    }

    func testSecureFocusRefusesCommandModeBeforeAnyRecording() {
        XCTAssertEqual(m.handle(.startCommand(settings: settings(), cleanupConfigured: true,
                                              focus: .secure, selection: "the cat")),
                       [.hud(.error("No transforms in password fields"))])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.gen, 0)
    }

    func testNoSelectionRefusesCommandMode() {
        XCTAssertEqual(m.handle(.startCommand(settings: settings(), cleanupConfigured: true,
                                              focus: .editable, selection: nil)),
                       [.hud(.error("Select text first"))])
        XCTAssertEqual(m.gen, 0)
    }

    /// The headline safety property: focus moved into a password field between
    /// fn-down and landing ⇒ the transcript reaches nothing, not even a log.
    func testSecureAtLandingLeaksTheTranscriptNowhere() {
        let secret = "hunter2 correct horse"
        let s = startDictation(live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hun"))
        _ = m.handle(.stopRequested)
        let fx = m.handle(.transcribed(s, raw: secret, probe: probe(.secure, typedIsOurs: true)))
        XCTAssertEqual(quiet(fx), [.hud(.error("Not supported in password fields")),
                                   .flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate])
        for effect in fx {
            switch effect {
            case .log(let line): XCTAssertFalse(line.contains(secret), line)
            case .insertText, .appendHistory, .polish, .replaceTailIfOurs:
                XCTFail("secure drop emitted \(effect)")
            default: break
            }
        }
        XCTAssertEqual(m.typedLedger, "")   // still cleared on the drop
    }

    func testSecureAtSwapNeverTypesTheCleanedText() {
        let s = startDictation()
        _ = m.handle(.stopRequested)
        _ = m.handle(.transcribed(s, raw: "hello world", probe: probe()))
        let landed = Landed(landing: .field, raw: "hello world", insertText: "hello world",
                            bundleID: "com.apple.TextEdit", appName: "TextEdit")
        let fx = quiet(m.handle(.cleanReady(s, landed, text: "Hello, world.",
                                            failure: nil, focus: .secure)))
        XCTAssertEqual(fx.first, .hud(.cleanedInHistory))
        XCTAssertFalse(fx.contains { if case .replaceTailIfOurs = $0 { return true }; return false })
    }

    // MARK: - Generation discipline

    /// The raw landing is deliberately NOT gen-gated — the user spoke that text,
    /// so it lands — but the menu bar and the model unload belong to whoever is
    /// recording now.
    func testStaleTranscriptStillLandsButNeverTouchesTheNewerSession() {
        let old = startDictation(cleanup: false)
        _ = m.handle(.stopRequested)
        startDictation()                                  // gen 2 takes over
        let fx = m.handle(.transcribed(old, raw: "old text", probe: probe()))
        XCTAssertTrue(fx.contains(.insertText("old text")))
        XCTAssertFalse(fx.contains(.menuBar(.idle)))
        XCTAssertFalse(fx.contains(.releaseModelIfPolicyImmediate))
        XCTAssertTrue(fx.contains(.flushTrace))
        XCTAssertEqual(m.state, .recording(session))      // untouched by the old session
        XCTAssertEqual(m.gen, 2)
    }

    func testStaleCleanReadyRecordsHistoryButFiresNoKeystrokesAndNoHUD() {
        let old = startDictation()
        _ = m.handle(.stopRequested)
        _ = m.handle(.transcribed(old, raw: "hello world", probe: probe()))
        let landed = Landed(landing: .field, raw: "hello world", insertText: "hello world",
                            bundleID: "com.apple.TextEdit", appName: "TextEdit")
        startDictation()                                  // gen 2 owns the field now
        let fx = m.handle(.cleanReady(old, landed, text: "Hello, world.", failure: nil, focus: .editable))
        XCTAssertEqual(quiet(fx), [.trace(.cleanedSwapped),
                                   .appendHistory(raw: "hello world", cleaned: "Hello, world.",
                                                  appName: "TextEdit"),
                                   .flushTrace])
        XCTAssertFalse(fx.contains { if case .hud = $0 { return true }; return false })
        XCTAssertFalse(fx.contains { if case .replaceTailIfOurs = $0 { return true }; return false })
        XCTAssertEqual(m.state, .recording(session))
    }

    /// A refused command must not consume a generation — doing so would silently
    /// invalidate the in-flight polish of the dictation before it.
    func testRefusedCommandDoesNotInvalidateAnInFlightPolish() {
        let s = startDictation()
        _ = m.handle(.stopRequested)
        _ = m.handle(.transcribed(s, raw: "hello world", probe: probe()))
        let landed = Landed(landing: .field, raw: "hello world", insertText: "hello world",
                            bundleID: "com.apple.TextEdit", appName: "TextEdit")
        _ = m.handle(.startCommand(settings: settings(), cleanupConfigured: true,
                                   focus: .secure, selection: "x"))
        _ = m.handle(.startCommand(settings: settings(), cleanupConfigured: true,
                                   focus: .editable, selection: nil))
        let fx = m.handle(.cleanReady(s, landed, text: "Hello, world.", failure: nil, focus: .editable))
        XCTAssertTrue(fx.contains { if case .replaceTailIfOurs = $0 { return true }; return false },
                      "the swap must still fire: \(fx)")
    }

    func testStreamTypedFromAStaleLoopIsIgnored() {
        startDictation(live: true)
        _ = m.handle(.streamTyped(gen: 1, text: "hello"))
        startDictation(live: true)                        // gen 2
        XCTAssertEqual(m.handle(.streamTyped(gen: 1, text: "hello from the past")), [])
        XCTAssertEqual(m.typedLedger, "hello")            // NOT reset at fn-down (I9)
    }

    func testANewDictationAlwaysWinsFromEveryState() {
        let reaches: [() -> Void] = [
            { _ = self.startDictation() },
            { _ = self.startDictation(); _ = self.m.handle(.stopRequested) },
        ]
        for reach in reaches {
            reach()
            let before = m.gen
            _ = m.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: false))
            XCTAssertEqual(m.gen, before + 1)
            if case .starting = m.state {} else { XCTFail("\(m.state)") }
        }
    }

    // MARK: - Command / transform mode

    func testCommandModeTransformsTheSelection() {
        let set = settings()
        XCTAssertEqual(m.handle(.startCommand(settings: set, cleanupConfigured: true,
                                              focus: .editable, selection: "teh cat")),
                       [.applyPreferencesAndStartCapture(set)])
        XCTAssertEqual(m.handle(.recorderStarted(gen: 1)),
                       [.ensureModelLoaded, .menuBar(.recording), .hud(.listening(command: true)),
                        .playSound(.start)])
        let s = session
        XCTAssertEqual(quiet(m.handle(.stopRequested)),
                       [.trace(.fnUp), .stopCapture(discard: false), .menuBar(.busy),
                        .hud(.transcribing), .transcribeCommand(s)])
        XCTAssertEqual(m.handle(.commandHeard(s, instruction: " fix the typo ")),
                       [.transform(s, instruction: "fix the typo")])
        // The sanitizer's quote-stripping is policy, so it runs here, not in the shell.
        let fx = quiet(m.handle(.transformReady(s, text: "\"the cat\"",
                                                probe: TransformProbe(focus: .editable,
                                                                      selectionStillMatches: true))))
        XCTAssertEqual(fx, [.insertText("the cat"), .playSound(.finish), .hud(.done),
                            .menuBar(.idle), .releaseModelIfPolicyImmediate])
        XCTAssertFalse(fx.contains(.flushTrace))   // transforms aren't in the latency trace
        XCTAssertEqual(m.state, .idle)
    }

    func testNoCommandHeardEndsTheTransform() {
        let s = command()
        XCTAssertEqual(quiet(m.handle(.commandHeard(s, instruction: "  \n "))),
                       [.hud(.error("No command heard")), .menuBar(.idle),
                        .releaseModelIfPolicyImmediate])
        XCTAssertEqual(m.state, .idle)
    }

    /// A transform never falls back to typing the spoken instruction.
    func testTransformFailuresTypeNothing() {
        for text in ["", "\"\"", String(repeating: "x", count: 2001)] {
            let s = command(selection: "teh cat")
            let fx = m.handle(.transformReady(s, text: text,
                                              probe: TransformProbe(focus: .editable,
                                                                    selectionStillMatches: true)))
            XCTAssertEqual(quiet(fx).first, .hud(.error("Transform failed")), text.prefix(8).description)
            XCTAssertFalse(fx.contains { if case .insertText = $0 { return true }; return false })
        }
    }

    func testTransformCeilingScalesWithTheSelection() {
        let long = String(repeating: "y", count: 2400)
        let s = command(selection: String(repeating: "a", count: 500))   // ceiling = 3000
        XCTAssertTrue(m.handle(.transformReady(s, text: long,
                                               probe: TransformProbe(focus: .editable,
                                                                     selectionStillMatches: true)))
            .contains(.insertText(long)))
    }

    func testTransformParksWhenTheSelectionChanged() {
        let s = command()
        let fx = quiet(m.handle(.transformReady(s, text: "the cat",
                                                probe: TransformProbe(focus: .editable,
                                                                      selectionStillMatches: false))))
        XCTAssertEqual(fx, [.appendHistory(raw: "the cat", cleaned: nil, appName: nil),
                            .hud(.savedToHistory), .menuBar(.idle), .releaseModelIfPolicyImmediate])
    }

    func testTransformParksWhenFocusMovedToASecureField() {
        let s = command()
        let fx = quiet(m.handle(.transformReady(s, text: "the cat",
                                                probe: TransformProbe(focus: .secure,
                                                                      selectionStillMatches: true))))
        XCTAssertEqual(fx.first, .appendHistory(raw: "the cat", cleaned: nil, appName: nil))
        XCTAssertFalse(fx.contains { if case .insertText = $0 { return true }; return false })
    }

    func testTransformWithHistoryOffDiscardsHonestly() {
        let s = command(history: false)
        let fx = quiet(m.handle(.transformReady(s, text: "the cat",
                                                probe: TransformProbe(focus: .secure,
                                                                      selectionStillMatches: true))))
        XCTAssertEqual(fx.first, .hud(.error("History off — text discarded")))
        XCTAssertFalse(fx.contains { if case .appendHistory = $0 { return true }; return false })
    }

    /// Stale transforms park to history but stay silent — the newer session owns
    /// the HUD. (Deliberately asymmetric with a stale cleaned swap, which shows
    /// nothing and stores nothing extra.)
    func testStaleTransformParksSilently() {
        let s = command()
        startDictation()                                   // gen 2
        let fx = quiet(m.handle(.transformReady(s, text: "the cat",
                                                probe: TransformProbe(focus: .editable,
                                                                      selectionStillMatches: true))))
        XCTAssertEqual(fx, [.appendHistory(raw: "the cat", cleaned: nil, appName: nil)])
        XCTAssertEqual(m.state, .recording(session))
    }

    /// fn-down → mic live, in command mode. Leaves the machine transcribing.
    @discardableResult
    func command(selection: String = "teh cat", history: Bool = true) -> Session {
        _ = m.handle(.startCommand(settings: settings(history: history), cleanupConfigured: true,
                                   focus: .editable, selection: selection))
        _ = m.handle(.recorderStarted(gen: m.gen))
        let s = session
        _ = m.handle(.stopRequested)
        return s
    }

    // MARK: - Legs that can't run

    func testMissingModelEndsEachLegWithItsOwnTail() {
        let s = startDictation()
        _ = m.handle(.stopRequested)
        XCTAssertEqual(m.handle(.legUnavailable(s, message: "No whisper model")),
                       [.hud(.error("No whisper model")), .flushTrace, .menuBar(.idle),
                        .releaseModelIfPolicyImmediate])
        let c = command()
        XCTAssertEqual(m.handle(.legUnavailable(c, message: "Cleanup not configured")),
                       [.hud(.error("Cleanup not configured")), .menuBar(.idle),
                        .releaseModelIfPolicyImmediate])
    }

    // MARK: - Structural invariant (ISSUES #6)

    /// No effect in the vocabulary deletes without naming what it expects to
    /// find, and nothing ever emits a delete with an empty expectation (which
    /// would be a blind delete of somebody else's text).
    func testNoEffectEverDeletesBlind() {
        var all: [Effect] = []
        for (live, ours, raw) in [(true, true, "hello world"), (true, false, "hello world"),
                                  (false, false, "hello world"), (true, true, nil as String?)] {
            let machine = DictationSession()
            _ = machine.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: live))
            _ = machine.handle(.recorderStarted(gen: 1))
            _ = machine.handle(.focusSampled(gen: 1, focus: .editable))
            all += machine.handle(.streamTyped(gen: 1, text: "helo"))
            let s: Session
            if case .recording(let r) = machine.state { s = r } else { return XCTFail("not recording") }
            all += machine.handle(.stopRequested)
            all += machine.handle(.transcribed(s, raw: raw, probe: probe(typedIsOurs: ours)))
            let cancelled = DictationSession()
            _ = cancelled.handle(.startDictation(settings: settings(), cleanupConfigured: true, live: live))
            _ = cancelled.handle(.recorderStarted(gen: 1))
            _ = cancelled.handle(.focusSampled(gen: 1, focus: .editable))
            all += cancelled.handle(.cancelRequested(silent: false))
            all += cancelled.handle(.cancelRequested(silent: true))
        }
        var deletes = 0
        for effect in all {
            switch effect {
            case .eraseTypedIfOurs(let expect):
                XCTAssertFalse(expect.isEmpty); deletes += 1
            case .replaceTailIfOurs(let expect, let erase, _, _, _):
                XCTAssertFalse(expect.isEmpty)
                XCTAssertLessThanOrEqual(erase, expect.count)   // never erase past what we typed
                deletes += 1
            default: break
            }
        }
        XCTAssertGreaterThan(deletes, 0)   // the corpus actually exercised the delete paths
    }

    // MARK: - Structural invariant (the clipboard)

    /// Parla types its text; it never pastes it. The user's clipboard is theirs,
    /// and a dictation that quietly overwrote it would destroy something they
    /// cannot get back — so the Hub's Copy button, which the user pressed on
    /// purpose, is allowed to write it and nothing else in the app is.
    ///
    /// Asserted over the source rather than by behaviour: the writes live in the
    /// AppKit shell, which the core's test target cannot drive, and a behavioural
    /// test could only ever cover the paths it thought to call — the risk here is
    /// exactly the path nobody thought of. The enclosing `func` line is the key,
    /// not a line number, so this survives edits above it.
    func testTheOnlyPasteboardWriteIsTheHubsCopyButton() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ParlaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: sources,
                                                                includingPropertiesForKeys: nil))
        var uses: Set<String> = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("NSPasteboard") {
                let owner = lines[...i].last { $0.contains("func ") }?
                    .trimmingCharacters(in: .whitespaces) ?? "top level"
                uses.insert("\(url.lastPathComponent): \(owner)")
            }
        }
        XCTAssertEqual(uses, ["HubModel.swift: func copy(_ text: String) {"])
    }
}
