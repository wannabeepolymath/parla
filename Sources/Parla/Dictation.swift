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

    static func automationSecureEvidence() -> Bool {
        IsSecureEventInputEnabled() || (AXIsProcessTrusted() && Inserter.focusTarget() == .secure)
    }

    static func observeTransientSecurity(_ event: DictationSession.Event, templates: GuidedTemplateOwner, imports: AudioImportOwner) {
        templates.observe(event); imports.observe(event)
    }

    /// One event in, its effects executed — always on main.
    func send(_ event: DictationSession.Event) {
        // Secure evidence precedes the stale-operation guard below.
        Self.observeTransientSecurity(event, templates: templates, imports: audioImport)

        switch event {
        case .startDictation, .startCommand, .startSavedPreset, .startAutomation,
             .discardPending, .discardOwnedOperation:
            canceledCaptureUndo.invalidate()
        case .cancelRequested:
            switch session.state {
            case .starting(let s), .recording(let s):
                canceledCaptureDeadlines[s.operation.id] = canceledCaptureUndo.cancellationDeadline()
            default: break
            }
        case .focusSampled(_, .secure): canceledCaptureUndo.invalidate()
        default: break
        }
        canceledCaptureUndo.observe(event)
        originalCopy.observe(event)
        guardedEdits.observe(event)
        guard event.operation?.shouldAbort != true else { return }
        if case .discardPending(let token) = event { MainActor.assumeIsolated { invocation.discarded(token) } }
        if case .operationFinished(let operation) = event { MainActor.assumeIsolated { invocation.finished(operation) } }
        historySink.beginEvent(for: event, currentGeneration: session.gen)
        session.send(event) { [self] effect in
            // Refresh the off-main mirror before every effect: `state` is an enum
            // carrying Settings (arrays, dictionaries) and must never be read off
            // the main actor, but effects spawn threads that need to know whether
            // this dictation still holds the mic (.startStreamLoop's loop polls it
            // on its first line, whisper's shouldAbort callbacks on every chunk).
            capturingGen.withLock { $0 = session.isCapturing ? session.gen : 0 }
            perform(effect)
        }
        canceledCaptureDeadlines.removeAll()
        MainActor.assumeIsolated { invocation.synchronizeInput() }
    }

    func perform(_ effect: DictationSession.Effect) {
        originalCopy.observe(effect)
        guardedEdits.observe(effect)
        switch effect {

        case .captureAccepted(let s): MainActor.assumeIsolated { invocation.accepted(s) }
        case .captureAcknowledged(let s):
            canceledCaptureUndo.acknowledged(s)
            MainActor.assumeIsolated { invocation.acknowledged(s) }
        case .captureFinalizing(let s): MainActor.assumeIsolated { invocation.finalizing(s) }
        case .finalResult(let s, let result): MainActor.assumeIsolated { invocation.completed(s, result: result) }

        // MARK: - Capture

        case let .applyPreferencesAndStartCapture(settings):
            hud.idleBarSize = HUD.idleSize(settings.hudIdleSize)
            hud.showAlways = settings.showHudAlways
            recorder.inputDeviceUID = settings.inputDeviceUID
            // A failed paste the last session never surfaced must not leak into this one.
            insertionFailure = nil
            let gen = session.gen
            selectionDestinations = selectionDestinations.filter { $0.key == gen }
            let operation: PendingOperation?
            switch session.state {
            case .starting(let value), .recording(let value): operation = value.operation
            default: operation = nil
            }
            recorderGeneration = gen
            do { try captureDiagnostics.start(operation: operation) { try recorder.start(diagnosticOperation: $0) } } catch {
                recorderGeneration = 0
                selectionDestinations[gen] = nil
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

        case .cancelCapture(let context):
            let deadline = canceledCaptureDeadlines.removeValue(forKey: context.operation.id) ?? 0
            canceledCaptureExecutor.execute(context, deadline: deadline)
        case .presentCanceledCapture(let generation): canceledCaptureUndo.present(generation: generation)

        case let .stopOwnedCapture(generation, discard):
            guard recorderGeneration == generation else { return }
            recorderGeneration = 0
            let samples = captureDiagnostics.stop(discard: discard) { recorder.stop() }
            captured = discard ? [] : samples
            capturedGeneration = discard ? nil : generation

        case let .stopCapture(discard):
            let generation = recorderGeneration
            recorderGeneration = 0
            let samples = captureDiagnostics.stop(discard: discard) { recorder.stop() }
            captured = discard ? [] : samples
            capturedGeneration = discard ? nil : generation

        case let .abortOperation(operation):
            if activePreviewCapture?.operation == operation {
                MainActor.assumeIsolated { activePreviewCapture?.revoke() }
            }
            // The reducer has revoked both delivery and the native mirror already.
            if let ownership = operationAudio.removeValue(forKey: operation.id), !recordings.discard(ownership) {
                send(.operationDisposalFailed(operation, message: recordings.lastError ?? "Audio disposal failed"))
            }
            operation.requestAbort()

        case let .releaseOwnedRecognition(generation):
            processTask = Task { [previous = processTask] in
                await previous?.value
                self.recognitionHandles[generation] = nil
                self.previewCaptures[generation] = nil
                self.recognitionErrors[generation] = nil
                if self.windowGeneration == generation { self.window = nil; self.windowGeneration = nil }
                await MainActor.run { self.selectionDestinations[generation] = nil }
            }

        case .discardStreamWindow:
            selectionDestinations.removeAll()
            // Queued on the chain: the in-flight streaming pass writes `window`
            // as it exits, so clearing it here and now would be undone.
            processTask = Task { [prev = processTask] in
                await prev?.value
                self.recognitionHandles.removeAll()
                self.previewCaptures.removeAll()
                self.recognitionErrors.removeAll()
                await MainActor.run { self.window = nil }
            }

        case let .startStreamLoop(gen, _, preview):
            guard case .recording(let s) = session.state, s.recognition.selection.engine == .whisper else { return }
            if let plan = s.previewPlan, plan.refusal(directory: recognitionFactory.directory, catalog: recognitionFactory.catalog) == nil { return }
            // Shadow streaming runs on EVERY dictation so the finalize only ever
            // pays for the unconfirmed tail. Chained onto the previous work:
            // the whisper ctx isn't reentrant.
            processTask = PendingOperationQueue.enqueue(previous: processTask, operation: s.operation) {
                guard let handle = self.recognitionHandles[gen], handle.client.capabilities.shadowWindows else { return }
                await self.stream(handle: handle, gen: gen, preview: preview && s.previewPlan == nil, operation: s.operation)
            }

        // MARK: - Model

        case .ensureModelLoaded:
            let s: DictationSession.Session
            switch session.state {
            case .starting(let value), .recording(let value): s = value
            default: return
            }
            lastModelUse = Date()
            let selectionEpoch = preparationSelectionEpoch
            let preparationEpoch: UUID? = s.recognition.selection.engine == .whisper ? nativePreparation.core.admissionEpoch : nil
            let factory = recognitionFactory(for: s.recognition)
            if let plan = s.previewPlan {
                if let refusal = plan.refusal(directory: factory.directory, catalog: factory.catalog) {
                    send(.recognitionPreview(gen: s.gen, operationID: s.operation.id, phase: plan.phase, update: .status(refusal)))
                } else {
                    let capture = RecognitionPreviewCapture(plan: plan, operation: s.operation, factory: factory,
                        selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch,
                        capturing: { self.capturing(s.gen) }, suffix: { self.recorder.previewSuffix(operationID: $0) },
                        secure: RecognitionPreviewCapture.secureEvidence({ Self.automationSecureEvidence() }, shadow: s.activityShadowPermission),
                        publish: { update in
                            self.send(.recognitionPreview(gen: s.gen, operationID: s.operation.id, phase: plan.phase, update: update))
                        }, clear: {
                            self.send(.recognitionPreviewRevoked(gen: s.gen, operationID: s.operation.id, phase: plan.phase))
                        }, releaseAliases: {
                            self.recognitionHandles.removeAll(); self.recognitionErrors.removeAll()
                            self.window = nil; self.windowGeneration = nil
                            await MainActor.run {
                                self.residentRecognition = nil; self.lastGoodModelPath = nil
                                self.modelReady = false; self.hubModel.modelLoaded = false
                            }
                        })
                    activePreviewCapture = capture
                    processTask = PendingOperationQueue.enqueue(previous: processTask, operation: s.operation) {
                        self.previewCaptures.removeAll()
                        self.previewCaptures[s.gen] = capture
                        await capture.run()
                    }
                    return
                }
            }
            processTask = PendingOperationQueue.enqueue(previous: processTask, operation: s.operation) {
                s.operation.advance(.acquiring)
                // Every older final/cancel has drained. An overridden capture may
                // have no final at all, so release its handle here too.
                self.recognitionHandles.removeAll()
                self.previewCaptures.removeAll()
                self.recognitionErrors.removeAll()
                let resident = await MainActor.run { self.residentRecognition }
                guard !s.operation.shouldAbort else { return }
                do {
                    let handle = try await RecognitionAcquisition.acquire(request: s.recognition,
                        resident: resident, factory: factory, operation: s.operation, capture: s.operation.id,
                        selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch)
                    guard !s.operation.shouldAbort else { return }
                    self.recognitionHandles[s.gen] = handle
                    // Preserve the global resident/unload policy after an idle reload.
                    // Profile-only models are retained just by their session handle.
                    await MainActor.run {
                        guard s.recognition.selection.engine == .whisper, !s.operation.shouldAbort,
                              RecognitionAcquisition.mayPromote(handle, global: RecognitionRequest(settings: s.settings),
                                epoch: selectionEpoch, currentEpoch: self.hubModel.modelSelectionEpoch,
                                current: RecognitionRequest(settings: self.store.load()), factory: self.recognitionFactory) else { return }
                        self.residentRecognition = handle.resident
                        self.lastGoodModelPath = handle.request.modelPath
                        self.modelReady = true; self.hubModel.modelLoaded = true
                        self.hubModel.observedRecognition = (handle.request.selection, handle.client.capabilities)
                    }
                } catch {
                    guard !s.operation.shouldAbort else { return }
                    let message = (error as? ParakeetInstallationRefusal)?.message ?? (error as? AppleSpeechRefusal)?.message ?? (error as? PreparationRefusal)?.description ?? "Local model unavailable — check the selected model"
                    self.recognitionErrors[s.gen] = message
                    await MainActor.run {
                        if s.recognition.selection.engine == .whisper { self.nativePreparation.refresh() }
                        if !s.operation.shouldAbort, s.gen == self.session.gen { self.hud.show(.error(message)) }
                    }
                }
            }
        case .releaseModelIfPolicyImmediate: unloadAfterTranscription()

        // MARK: - Legs (whisper / LLM), all on the processTask chain

        case let .transcribeFinal(s, ledger):
            admitLocalCleanup(s)
            if MainActor.assumeIsolated({ localCleanupAdmission.hasOrdinaryFailover }), s.gen == session.gen {
                hud.show(.notice("Recording saved for processing. Waiting for prior cleanup to stop; you can discard it."))
            }
            let samples = takeCaptured()
            processTask = executionDispatcher.enqueue(.ordinary(s, samples: samples, ledger: ledger), previous: processTask,
                finished: {
                    self.recognitionHandles[s.gen] = nil; self.previewCaptures[s.gen] = nil; self.recognitionErrors[s.gen] = nil
                    if self.windowGeneration == s.gen { self.window = nil; self.windowGeneration = nil }
                    await MainActor.run { self.localCleanupAdmission.exited(s.operation); self.operationAudio[s.operation.id] = nil; self.send(.operationFinished(s.operation)) }
                })

        case let .transcribeCommand(s):
            let destination = selectionDestinations.removeValue(forKey: s.gen)
            let samples = takeCaptured()
            processTask = enqueueOperation(s) {
                await self.transform(s, samples: samples, destination: destination)
            }

        case let .runSavedPreset(s):
            let destination = selectionDestinations.removeValue(forKey: s.gen)
            hubModel.recordProfileWinners(s)
            processTask = enqueueOperation(s) {
                await self.runSelectionTransform(s, instruction: s.preset?.intent ?? "", destination: destination)
            }

        case .warmCleanupEndpoint:
            guard let url = cleanupWarmURL(settings: store.load(),
                                           env: ProcessInfo.processInfo.environment, credentials: self.store.credentials) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request).resume()

        // Both legs pick their request up from the MainActor hop that emitted it
        // and await it themselves — the chain must stay held until it resolves.
        case let .polish(s, landed):
            pendingPolish = (s, landed)
            hubModel.recordProfileWinners(s)
            // With profiles, the start destination does not decide whether to warm.
            if s.effectiveSettings.outputMode == .cleanup, !s.settings.profiles.isEmpty,
               let url = cleanupWarmURL(settings: s.effectiveSettings, env: ProcessInfo.processInfo.environment, credentials: self.store.credentials) {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 5
                URLSession.shared.dataTask(with: request).resume()
            }
        case let .transform(_, instruction): pendingInstruction = instruction

        // MARK: - Insertion. Nothing here deletes without proving what it deletes.

        case let .insertText(text, historyEnabled, original):
            guard let posted = insertionExecutor.insert(text, original: original, operation: session.effectOperation, contextRun: session.effectSurroundingTextRun) else { return }
            if posted {
                insertionFailure = nil
            } else {
                insertionFailure = (historyEnabled ?? store.load().historyEnabled)
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
                session.effectOperation?.diagnostics?.disposition(.destinationChanged)
                // AX can't prove the field still ends with our text — leave it
                // alone; history retains the result when enabled.
                NSLog("Parla replace: unverified, field left alone")
                if let state = historySink.feedback(unverifiedHUD) { hud.show(state) }
                return
            }
            // One atomic AX value write over the tail, read-back verified inside
            // — no visible char-by-char erase and no keystroke window for the
            // user's own typing to fall into. Fields that refuse the write (or
            // an erase of 0, which the helper declines) fall back to keystrokes.
            // An ISSUED write that never confirmed gets no fallback: Electron
            // applies AX sets async, and typing over one lands the edit twice.
            guard session.effectOperation?.authorizeDispatch() != false else { return }
            let diagnostic = session.effectOperation?.diagnostics
            let delivery = diagnostic?.begin(.delivery); defer { delivery?.end() }
            let result = Inserter.replaceTypedTail(String(expect.suffix(erase)), with: append)
            DiagnosticDispatch.replacement(result, diagnostics: diagnostic)
            switch result {
            case .replaced:
                NSLog("Parla replace: atomic ax swap (erase %d)", erase)
            case .unverified:
                NSLog("Parla replace: ax write unconfirmed, field left alone (erase %d)", erase)
                if let state = historySink.feedback(unverifiedHUD) { hud.show(state) }
                return
            case .unavailable:
                NSLog("Parla replace: ax-verified tail swap (erase %d)", erase)
                Inserter.typeBackspaces(erase, diagnostics: diagnostic)
                Inserter.typeUnicode(append, diagnostics: diagnostic)
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
                if let state = historySink.feedback(state) { hud.show(state) }
            }
        case let .secureRefusal(passwordField):
            canceledCaptureUndo.invalidate()
            showSecureRefusal(passwordField)
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

        case .appendTransformHistory, .appendHistory:
            if let feedback = historySink.record(effect, insertionFailed: insertionFailure != nil) { hud.show(feedback) }
        case let .log(line): NSLog("%@", line)
        case let .trace(s): stamp(s)
        case .flushTrace: Trace.flush()
        }
    }

    /// This barrier owns the child through actual exit, even after discard.
    private func enqueueOperation(_ s: DictationSession.Session, work: @escaping () async -> Void) -> Task<Void, Never> {
        admitLocalCleanup(s)
        return PendingOperationQueue.enqueue(previous: processTask, operation: s.operation, completes: true, work: work) {
            self.recognitionHandles[s.gen] = nil
            self.recognitionErrors[s.gen] = nil
            await MainActor.run {
                self.localCleanupAdmission.exited(s.operation)
                self.operationAudio[s.operation.id] = nil
                self.send(.operationFinished(s.operation))
            }
        }
    }

    private func admitLocalCleanup(_ s: DictationSession.Session) {
        guard s.settings.usesAppleIntelligence else { return }
        if s.mode == .dictation && s.settings.outputMode == .raw { return }
        MainActor.assumeIsolated {
            if !localCleanupAdmission.admit(s.operation) { s.operation.revoke(); s.operation.requestAbort() }
        }
    }

    /// Both consumers of a stamp, so neither can be updated without the other:
    /// the env-gated line on stderr and the metrics that ride the history entry.
    func stamp(_ s: Trace.Stamp) {
        Trace.mark(s)
        Metrics.shared.mark(s)
    }

    private func takeCaptured() -> [Float] {
        defer { captured = []; capturedGeneration = nil }
        return captured
    }

    // MARK: - Dictation leg

    /// Whisper over the captured audio, then hand the transcript to the machine
    /// and run what it decides. Runs off-main on the processTask chain; every
    /// look at the world happens inside the MainActor hops and travels as a probe.
    func finish(_ s: DictationSession.Session, samples: [Float], ledger: String) async {
        defer { s.surroundingTextRun.finish() }
        let finalization = OrdinaryDictationFinalization(recordings: recordings, settings: store)
        let cleanupUsage = TransformUsage()
        let failoverRun = CleanupFailoverRun(admit: {
            await MainActor.run {
                guard self.localCleanupAdmission.admitOrdinaryFailover(s.operation) else {
                    s.operation.revoke(); s.operation.requestAbort(); return false
                }
                return true
            }
        })
        defer { recognitionHandles[s.gen] = nil; previewCaptures[s.gen] = nil; recognitionErrors[s.gen] = nil; window = nil }
        if s.delivery == .resultOnly, samples.count < 6400 {
            await MainActor.run { self.send(.resultUnavailable(s, .minimumDuration)) }
            return
        }
        await finalization.run(operation: s.operation, samples: samples, window: previewCaptures[s.gen] == nil ? window : nil,
            shadow: s.activityShadowPermission, separatePreview: previewCaptures[s.gen] != nil,
            shadowCurrent: { s.gen == self.session.gen && self.session.activityShadowPermission == s.activityShadowPermission }, prepare: { recording, ownership in
            guard !s.operation.shouldAbort else { return nil }
            let proceed = await MainActor.run { () -> Bool in
                guard !s.operation.shouldAbort else {
                    if let ownership, !recordings.discard(ownership) {
                        self.send(.operationDisposalFailed(s.operation, message: recordings.lastError ?? "Audio disposal failed"))
                    }
                    return false
                }
                self.operationAudio[s.operation.id] = ownership
                return true
            }
            guard proceed else { return nil }
            guard !s.operation.shouldAbort else { return nil }
            if let preview = previewCaptures[s.gen] {
                do {
                    let handle = try await preview.acquireFinal()
                    guard !s.operation.shouldAbort else { return nil }
                    recognitionHandles[s.gen] = handle
                    await MainActor.run {
                        guard !s.operation.shouldAbort,
                              RecognitionAcquisition.mayPromote(handle, global: RecognitionRequest(settings: s.settings),
                                epoch: preview.selectionEpoch, currentEpoch: self.hubModel.modelSelectionEpoch,
                                current: RecognitionRequest(settings: self.store.load()), factory: self.recognitionFactory) else { return }
                        self.residentRecognition = handle.resident
                        self.lastGoodModelPath = handle.request.modelPath
                        self.modelReady = true; self.hubModel.modelLoaded = true
                        self.hubModel.observedRecognition = (handle.request.selection, handle.client.capabilities)
                    }
                } catch {
                    recognitionErrors[s.gen] = (error as? PreparationRefusal)?.description ?? "Local model unavailable — check the selected model"
                }
            }
            guard let handle = recognitionHandles[s.gen] else {
                NSLog("Parla: requested local model unavailable")
                await MainActor.run {
                    guard !s.operation.shouldAbort else { return }
                    self.send(.legUnavailable(s, message: self.recognitionErrors[s.gen] ?? "Local model unavailable"))
                    // Behind the HUD for the same reason the landing path is behind
                    // the keystrokes. transcript: nil keeps the file (Handy #1332);
                    // the probe is what stops audio captured into a password field
                    // from sitting on disk for the retention window just because no
                    // model was loaded.
                    finalization.resolve(transcript: nil,
                                                  secure: s.focus == .secure || (s.delivery == .resultOnly ? Self.automationSecureEvidence() : Inserter.focusTarget() == .secure))
                }
                return nil
            }
            return handle
        }, recognized: { handle, raw in
            stamp(.finalPassDone)
            // Whatever whisper actually ran against, which is not necessarily the
            // catalog default — the metric is worthless if it names the wrong model.
            if s.settings.usesAppleIntelligence {
                cleanupUsage.recordRecognition(model: handle.request.metricLabel.replacingOccurrences(of: "ggml-", with: ""))
            }
            Metrics.shared.update {
                $0.model = handle.request.metricLabel
                    .replacingOccurrences(of: "ggml-", with: "")
            }

            // Resolve the destination before cleanup and hold its identity across
            // the await. The production path inserts only the final result.
            let delivery = await MainActor.run { () -> ((DictationSession.Session, DictationSession.Landed)?, Inserter.Destination?) in
                // Re-check focus: it may have moved into a password field since
                // fn-down. Sampled on BOTH paths, not just the landing one: it is
                // also the signal that deletes the stashed WAV below, and the
                // no-transcript path is the only one that KEEPS that file — reading
                // focus only when there is a transcript is what made the secure
                // delete unreachable exactly where it matters. The reducer ignores
                // the probe entirely when `raw` is nil, so this changes no decision.
                guard !s.operation.shouldAbort else { return (nil, nil) }
                let focus = s.delivery == .resultOnly
                    ? (Self.automationSecureEvidence() ? Inserter.FocusTarget.secure : .unknown) : Inserter.focusTarget()
                var probe = LandingProbe(focus: focus)
                if raw != nil, s.delivery == .keyboard {
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
                let destination = s.delivery == .resultOnly || focus == .secure ? nil : Inserter.Destination()
                if raw != nil, focus != .secure, s.delivery == .keyboard {
                    self.hubModel.recordProfileWinners(s.resolvingOutput(at: ProfileDestination(
                        bundleID: probe.bundleID, browserURL: probe.browserURL)))
                }
                self.send(.transcribed(s, raw: raw, probe: probe))
                // Behind the landing keystrokes on purpose — a file delete must not
                // sit between the transcript and the screen. `secure` is the same
                // pair of signals the reducer just refused on inside that send, so
                // audio that drifted into a password field cannot outlive the
                // transcript that was dropped for it.
                finalization.resolve(transcript: raw,
                                              secure: probe.focus == .secure || s.focus == .secure)
                defer { self.pendingPolish = nil }
                return (self.pendingPolish, destination)
            }
            guard let (outputSession, landed) = delivery.0 else { return nil }
            return (outputSession, landed, delivery.1)

        }, clean: { (context: (DictationSession.Session, DictationSession.Landed, Inserter.Destination?)) in
            let (outputSession, landed, _) = context
            return await DictationCleanupOutput.clean(session: outputSession, landed: landed,
                store: self.store, environment: ProcessInfo.processInfo.environment,
                run: failoverRun, usage: cleanupUsage.record)
        }, completed: { context, text, failure in
            let (outputSession, landed, destination) = context
            await MainActor.run {
                guard !s.operation.shouldAbort else { return }
                // Only the swap paths that can type consult this, so only they pay
                // for the AX read.
                var focus = s.delivery == .resultOnly ? (Self.automationSecureEvidence() ? .secure : .unknown) : (landed.landing == .field || landed.landing == .pending) && s.gen == self.session.gen
                    ? Inserter.focusTarget() : Inserter.FocusTarget.none
                if landed.landing == .pending, focus != .secure, destination?.isCurrent() != true {
                    NSLog("Parla delivery: destination or selection changed, or identity unavailable; insertion withheld")
                    s.operation.diagnostics?.disposition(.destinationChanged)
                    focus = .none
                }
                finalization.observeSecurity(secure: s.focus == .secure || focus == .secure)
                self.send(.cleanReady(outputSession, landed, text: text, failure: failure, focus: focus,
                                      metrics: outputSession.surroundingTextRun.metrics ?? (failoverRun.participated ? failoverRun.metrics
                                        : outputSession.effectiveSettings.usesAppleIntelligence || outputSession.effectiveSettings.outputMode == .selectedPreset ? cleanupUsage.snapshot() : nil)))
            }
        }, drain: { await failoverRun.drain() })
    }

    // MARK: - Command leg

    /// Command mode: transcribe the spoken instruction on-device, transform the
    /// selection latched at fn-down via the cleanup LLM, and let the machine
    /// decide whether it may replace the live selection.
    func transform(_ s: DictationSession.Session, samples: [Float], destination: Inserter.Destination?) async {
        defer { recognitionHandles[s.gen] = nil; recognitionErrors[s.gen] = nil }
        guard !s.operation.shouldAbort else { return }
        guard let handle = recognitionHandles[s.gen] else {
            NSLog("Parla transform: no whisper model loaded")
            let message = recognitionErrors[s.gen] ?? "No whisper model"
            await MainActor.run { self.send(.legUnavailable(s, message: message)) }
            return
        }
        // No profile can supply a missing global provider or credential.
        guard s.cleanupConfigured else {
            s.operation.diagnostics?.update { $0.providerOutcome = .refused }
            await MainActor.run { self.send(.legUnavailable(s, message: "Cleanup not configured")) }
            return
        }
        guard let spoken = await DictationProcessing.command(operation: s.operation, handle: handle, samples: samples) else {
            await MainActor.run { self.send(.legUnavailable(s, message: "Transcription failed")) }
            return
        }
        guard !s.operation.shouldAbort else { return }
        // Recognition is frozen; resolve output only after ASR, just before cleanup.
        let s = await MainActor.run { () -> DictationSession.Session in
            guard !s.operation.shouldAbort else { return s }
            let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let resolved = s.resolvingOutput(at: ProfileDestination(bundleID: id,
                browserURL: Inserter.focusTarget() == .secure ? nil : Inserter.focusedBrowserURL(bundleID: id)))
            self.hubModel.recordProfileWinners(resolved)
            return resolved
        }
        guard s.effectiveSettings.cleanupEnabled && s.cleanupConfigured else {
            s.operation.diagnostics?.update { $0.providerOutcome = .refused }
            await MainActor.run { self.send(.legUnavailable(s, message: "Cleanup off or not configured")) }
            return
        }
        let instruction: String? = await MainActor.run {
            self.send(.commandHeard(s, instruction: spoken))
            defer { self.pendingInstruction = nil }
            return self.pendingInstruction
        }
        guard let instruction else { return } // nothing usable was heard

        await runSelectionTransform(s, instruction: instruction, destination: destination)
    }

    /// Both selected-text entry points hold their original native destination.
    /// The serial chain remains owned until request and guarded completion finish.
    func runSelectionTransform(_ s: DictationSession.Session, instruction: String,
                               destination: Inserter.Destination?) async {
        guard !s.operation.shouldAbort else { return }
        s.operation.advance(.cleaning)
        let usage = TransformUsage()
        guard let result = await DictationProcessing.transform(operation: s.operation, request: {
            try await s.transform(instruction: instruction) {
                guard !s.operation.shouldAbort else { throw CancellationError() }
                return try makeCleanupClient(settings: $0, env: ProcessInfo.processInfo.environment, credentials: self.store.credentials, usage: usage.record)
            }
        }) else { return }
        // An optional idle shortcut can finish while its modifiers are still
        // held. Wait without blocking main; timeout parks rather than typing a
        // modified keystroke into the destination. Identity is checked afterwards.
        for _ in 0..<20 {
            guard !s.operation.shouldAbort else { return }
            let ready = await MainActor.run {
                s.gen != self.session.gen || Self.transformModifiersClear
            }
            if ready { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await MainActor.run {
            guard !s.operation.shouldAbort else { return }
            let probe = TransformProbe.capture(for: s, currentGeneration: self.session.gen,
                focus: { Inserter.focusTarget() }, modifiersClear: Self.transformModifiersClear,
                destinationStillMatches: { destination?.isCurrentSelection() == true },
                selectedText: { Inserter.selectedText() })
            if !Self.transformModifiersClear { s.operation.diagnostics?.disposition(.modifiersHeld) }
            self.send(.transformReady(s, text: result.text, probe: probe, failure: result.failure, metrics: usage.snapshot()))
        }
    }

    private static var transformModifiersClear: Bool {
        NSEvent.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty
    }

    /// Global shortcut only: capture while the destination app is frontmost,
    /// before queueing work. No Hub button and no ASR/model path.
    func runSelectedPreset() {
        guard !updater.committing, axGranted else {
            hud.show(.error("Transforms unavailable — check Accessibility or finish updating")); return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            hud.show(.error("Select text in the destination app first")); return
        }
        _ = store.migrateSelectedCredentials()
        let settings = store.load()
        guard store.lastError == nil else { hud.show(.error("Repair settings before running a preset")); return }
        let focus = Inserter.focusTarget()
        let app = NSWorkspace.shared.frontmostApplication
        let source = focus == .secure ? nil : Inserter.selectedText()
        let token = focus == .secure ? nil : Inserter.Destination()
        let target = LandingProbe(focus: focus, bundleID: app?.bundleIdentifier, appName: app?.localizedName,
            browserURL: focus == .secure ? nil : Inserter.focusedBrowserURL(bundleID: app?.bundleIdentifier),
            singleLine: focus == .secure ? false : Inserter.focusedFieldIsSingleLine())
        var providerSettings = settings; providerSettings.cleanupEnabled = true
        let configured = cleanupIsConfigured(settings: providerSettings, env: ProcessInfo.processInfo.environment, credentials: self.store.credentials)
        let nextGen = session.gen + 1
        selectionDestinations[nextGen] = token
        _ = MainActor.assumeIsolated { invocation.keyboard(.startSavedPreset(settings: settings, cleanupConfigured: configured, selection: source, target: target)) }
        if session.gen != nextGen { selectionDestinations[nextGen] = nil }
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
    func stream(handle: RecognitionHandle, gen: Int, preview: Bool, operation: PendingOperation) async {
        guard handle.client.capabilities.shadowWindows else { return }
        var confirmed = "" // frozen transcript of snap[0..<cut]
        var cut = 0
        var lastCount = 0
        while capturing(gen) && !operation.shouldAbort {
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
                let head = await DictationProcessing.stream(operation: operation, handle: handle,
                    samples: Array(tail[..<rel]), pass: .streamHead(confirmed), sampleRange: cut..<(cut + rel),
                    capturing: { self.capturing(gen) })
                // Aborted or errored head pass returns nil: committing the cut
                // would silently drop the head's audio from the transcript
                // forever. Only commit a completed pass; an errored one leaves
                // the window alone and finish()'s full pass still owns the audio.
                guard capturing(gen), !operation.shouldAbort else { break }
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
            let tailText = await DictationProcessing.stream(operation: operation, handle: handle,
                samples: tail, pass: .streamTail(confirmed), sampleRange: cut..<snap.count, capturing: { self.capturing(gen) })
            // Aborted or errored pass returns nil: never treat it as a new
            // hypothesis — live typing would erase everything the user sees.
            // On abort finish() takes over; on error just try the next pass.
            guard capturing(gen), !operation.shouldAbort else { break }
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
                guard self.capturing(gen), !operation.shouldAbort else { return }
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
        window = operation.shouldAbort || confirmed.isEmpty ? nil : handle.window(confirmedText: confirmed, cutSample: cut)
        windowGeneration = window == nil ? nil : gen
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


/// The production ordinary output seam, also exercised with explicit fake bottoms.
/// All other origins keep the single-provider primitive and Pipeline semantics.
enum DictationCleanupOutput {
    static func clean(session: DictationSession.Session, landed: DictationSession.Landed,
        store: SettingsStore, environment: [String: String],
        primaryHTTP: HTTPPosting = URLSessionPoster(),
        primaryDriver: @escaping HistoryRetryHTTP.Driver = HistoryRetryURLSession.init,
        backupDriver: @escaping HistoryRetryHTTP.Driver = HistoryRetryURLSession.init,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: ((TimeInterval) async throws -> Void)? = nil,
        localRuntime: LocalCleanupRuntime = LocalCleanupRuntime(),
        run: CleanupFailoverRun, usage: @escaping CleanupUsageSink,
        primitiveUsage: @escaping CleanupUsageSink = recordCleanupUsage,
        contextPort: SurroundingTextPort = .native, contextDriver: @escaping HistoryRetryHTTP.Driver = HistoryRetryURLSession.init,
        disarmLearning: @escaping @MainActor () -> Void = { CorrectionWatcher.shared.disarm() },
        contextLog: @escaping (String) -> Void = { NSLog("%@", $0) }) async -> (text: String, failure: String?) {
        let settings = session.effectiveSettings
        let ordinaryUsage: CleanupUsageSink = { model, input, output in
            if !session.surroundingTextRun.participated { primitiveUsage(model, input, output) }
        }
        var pipeline = Pipeline(outputSettings: settings, bundleID: landed.bundleID,
            browserURL: landed.browserURL, singleLine: landed.singleLine, diagnostics: session.operation.diagnostics,
            failureLogging: session.delivery == .resultOnly ? .contentFree : .details) { selected in
            guard !session.operation.shouldAbort else { throw CancellationError() }
            if let origin = session.cleanupFailoverOrigin, !selected.usesAppleIntelligence {
                return try makeOrdinaryCleanupClient(settings: selected, origin: origin,
                    grant: session.cleanupFailoverGrant, operationID: session.operation.id, store: store,
                    env: environment, credentials: store.credentials, http: primaryHTTP,
                    primaryDriver: primaryDriver, backupDriver: backupDriver, now: now, sleep: sleep, run: run,
                    shouldContinue: { !session.operation.shouldAbort }, usage: ordinaryUsage)
            }
            return try makeCleanupClient(settings: selected, env: environment, credentials: store.credentials,
                http: primaryHTTP, localRuntime: localRuntime,
                usage: selected.usesAppleIntelligence || selected.outputMode == .selectedPreset ? usage : ordinaryUsage)
        }
        pipeline.failoverRun = run
        if session.surroundingTextGrant != nil {
            pipeline.failureLogging = .contentFree
            pipeline.log = contextLog
            pipeline.surroundingText = { transcript, context in
                try await SurroundingTextCapture.clean(session: session, landed: landed, transcript: transcript, context: context,
                    store: store, environment: environment, port: contextPort, driver: contextDriver, now: now, sleep: sleep, disarmLearning: disarmLearning, localRuntime: localRuntime)
            }
        }
        return await pipeline.clean(transcript: landed.raw)
    }
}
