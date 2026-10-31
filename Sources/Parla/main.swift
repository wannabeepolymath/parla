import AppKit
import AVFoundation
import Combine
import ParlaCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = SettingsStore()
    let templates = GuidedTemplateOwner()
    let audioImport = AudioImportOwner()
    let savedImports = SavedAudioImportOwner(root: SavedAudioImportOwner.defaultRoot)
    override init() {
        super.init()
        configureGuidedTemplates()
        audioImport.savedImports = savedImports
        savedImports.enqueue = { [weak self] job, done in
            guard let self else { job.revoke(); job.operation.finish(); done(.failure(CancellationError())); return nil }
            let request = job.authority.configuration.request
            return MainActor.assumeIsolated {
                let next = SavedAudioImportExecution.enqueue(previous:self.processTask,admission:self.localCleanupAdmission,store:self.savedImports.store,
                    job:job,settings:self.store,enter:{ [weak self] in
                        guard let self else { throw CancellationError() }
                        try await MainActor.run {
                            if request.selection.engine == .appleSpeech { self.appleSpeechPreparation.deliberateEntry() }
                            try ParakeetAudioEntry.recovery(request,owner:self.parakeetPreparation)
                        }
                    },load:{ [weak self] request in
                        guard let self else { throw CancellationError() }
                        let (resident, factory) = await MainActor.run { (self.residentRecognition, self.recognitionFactory(for: request)) }
                        return try await RecognitionAcquisition.acquire(request:request,resident:resident,factory:factory,operation:job.operation,
                            selectionEpoch:job.authority.selectionEpoch,preparationEpoch:job.authority.preparationEpoch)
                    },done:done)
                if let next { self.processTask = next }
                return next
            }
        }
    }

    /// Resource-free owner is created eagerly; all execution uses this app's existing owners.
    private func configureGuidedTemplates() {
        templates.bind(store: store, capture: RecorderGuidedTemplateCapture(recorder: recorder), admission: recorder.admission,
                       local: MainActor.assumeIsolated { localCleanupAdmission })
        templates.permission = { [weak self] in self?.micGranted == true }
        templates.draftReady = { [weak self] in self?.hubBootstrap.existingHub?.templateDraftReady() == true }
        templates.allowed = { [weak self] in
            guard let self else { return false }
            return !self.updater.committing && !self.session.isCapturing && self.session.pendingOperation == nil
                && self.recorderGeneration == 0 && self.activeMicrophoneTest?.ownsSession != true
                && self.hubBootstrap.existingHub?.recoveryPlayback.id == nil
                && MainActor.assumeIsolated { !self.invocation.tryoutActive }
        }
        templates.selectionEpoch = { [weak self] in self?.preparationSelectionEpoch ?? UUID() }
        templates.preparationEpoch = { [weak self] in
            guard let self else { return nil }
            let engine = self.templates.frozenEngine ?? (try? self.store.savedRetrySnapshot().recognitionEngine)
            if engine == .appleSpeech { return MainActor.assumeIsolated { self.appleSpeechPreparation.snapshot.token } }
            if engine == .parakeet { return MainActor.assumeIsolated { self.parakeetPreparation.snapshot.token } }
            return self.nativePreparation.core.admissionEpoch
        }
        templates.preparationRefusal = { [weak self] request in
            guard let self else { return "Parla is stopping." }
            if request.selection.engine == .parakeet { return MainActor.assumeIsolated { self.parakeetPreparation.cachedRefusal(for: request)?.message } }
            if request.selection.engine == .appleSpeech { return MainActor.assumeIsolated { self.appleSpeechPreparation.cachedRefusal(for: request, deliberate: true)?.message } }
            return self.nativePreparation.cachedRefusal(for: request)?.description
        }
        templates.operationPreparationRefusal = { [weak self] request, operation, selection, preparation in
            guard let self else { return "Parla is stopping." }
            guard request.selection.engine == .whisper else { return self.templates.preparationRefusal(request) }
            return self.nativePreparation.core.cachedRefusal(for: request.selection, operation: operation,
                selectionEpoch: selection, preparationEpoch: preparation)?.description
        }
        templates.discardedPreparationAuthority = { [weak self] request, operation, selection, preparation in
            guard let self else { return "Parla is stopping." }
            guard request.selection.engine == .whisper else { return self.templates.preparationRefusal(request) }
            return self.nativePreparation.core.cachedFormAuthority(for: request.selection, discarding: operation,
                selectionEpoch: selection, preparationEpoch: preparation)?.description
        }
        templates.invalidatePriorAuthority = { [weak self] in
            guard let self else { return }
            self.canceledCaptureUndo.invalidate(); self.originalCopy.clear(); self.physicalInput.invalidateQueuedMouseStarts()
            MainActor.assumeIsolated { self.invocation.clearResult() }
        }
        templates.enqueue = { [weak self] operation, work, finished in
            guard let self else { operation.revoke(); operation.finish(); Task { await finished() }; return }
            self.processTask = PendingOperationQueue.enqueue(previous: self.processTask, operation: operation, completes: true, work: work, finished: finished)
        }
        templates.factory = { [weak self] request in self?.recognitionFactory(for: request) ?? RecognitionFactory() }
        templates.resident = { [weak self] in self?.residentRecognition }
        recorder.onGuidedEnd = { [weak self] session, capture, _ in
            DispatchQueue.main.async { self?.templates.captureEnded(session: session, capture: capture) }
        }
    }
    static func cleanupFailoverIntent(_ store: SettingsStore) { store.revokeCleanupFailover(); store.revokeSurroundingTextContext() }

    static func guidedQuitIntent(_ templates: GuidedTemplateOwner, imports: AudioImportOwner) {
        templates.cancel("Form discarded for quit."); imports.invalidate("Import discarded for quit.")
    }

    lazy var history = HistoryStore(settings: store)
    lazy var historySink = HistoryPersistenceSink(history: history, settings: store)
    lazy var originalCopy = OriginalCopyController(configuration: { [weak self] in
        guard let self else { return nil }
        let value = self.store.load(); return self.store.lastError == nil ? value : nil
    }, generation: { [weak self] in self?.session.gen ?? -1 },
       security: OriginalCopyController.currentSecurity, copy: HubModel.writeExplicitCopy)
    lazy var canceledCaptureUndo: CanceledCaptureUndoController = {
        let controller = CanceledCaptureUndoController(configuration: { [weak self] in
            guard let self, !self.canceledCaptureConfigurationInvalid else { return nil }
            let settings = self.store.load(); return self.store.lastError == nil ? settings : nil
        }, generation: { [weak self] in self?.session.gen ?? -1 },
           security: OriginalCopyController.currentSecurity, copy: HubModel.writeExplicitCopy)
        controller.render = { [weak self] in self?.hud.showCanceledCapture($0) }
        controller.enqueue = { [weak self] job in
            guard let self else { job.operation.revoke(); job.releaseAudio(); return }
            self.processTask = self.executionDispatcher.enqueue(.canceledCaptureUndo(job), previous: self.processTask)
        }
        hud.canceledCaptureActions = CanceledCaptureHUDActions(controller)
        hud.onCanceledCaptureDismiss = { [weak controller] in controller?.invalidate() }
        return controller
    }()
    var canceledCaptureConfigurationInvalid = false
    var canceledCaptureDeadlines: [UUID: TimeInterval] = [:]
    lazy var canceledCaptureExecutor = CanceledCaptureCancellationExecutor(controller: canceledCaptureUndo,
        ownedGeneration: { [weak self] in self?.recorderGeneration ?? 0 }, transfer: { [weak self] operation, retain in
            guard let self else { return nil }
            // Clear only this generation's ordinary handoff; Undo never enters it.
            if self.capturedGeneration == self.recorderGeneration {
                self.captured = []; self.capturedGeneration = nil
            }
            // Clear native mirror before stop callbacks can reenter with a new capture.
            self.recorderGeneration = 0
            var transferred: [Float]?
            _ = self.captureDiagnostics.stop(discard: true) {
                transferred = self.recorder.stopCanceledCapture(operationID: operation, retain: retain)
                return []
            }
            return transferred
        })
    lazy var executionDispatcher = DictationExecutionDispatcher(makePreview: { [unowned self] in CanceledCaptureRecognition(controller: self.canceledCaptureUndo,
        typedResident: { [weak self] in
            guard let self else { return nil }
            return await MainActor.run { self.residentRecognition }
        }, factory: self.recognitionFactory, preparationRefused: { [weak self] in self?.nativePreparation.notice($0) }) },
        ordinary: { [weak self] session, samples, ledger in await self?.finish(session, samples: samples, ledger: ledger) })
    lazy var originalCopyMenu = OriginalCopyMenuActions(controller: originalCopy)
    lazy var insertionExecutor: DictationInsertionExecutor = {
        let configuration: () -> Settings? = { [weak self] in
            guard let self else { return nil }
            let value = self.store.load(); return self.store.lastError == nil ? value : nil
        }
        let executor = DictationInsertionExecutor(originals: originalCopy,
            post: DictationInsertionExecutor.configuredPoster(configuration: configuration),
            preparedPost: DictationInsertionExecutor.configuredPreparedPoster(configuration: configuration),
            didPost: { [weak self] text in
                guard let self else { return }
                CorrectionWatcher.shared.arm(inserted: text, dictionary: self.store.load().dictionary)
            })
        executor.disarmLearning = { CorrectionWatcher.shared.disarm() }
        executor.beforeStoredInsertion = { [weak self] in self?.canceledCaptureUndo.invalidate() }
        return executor
    }()
    let physicalInput = PhysicalInputAuthority()
    lazy var hotkey = HotkeyMonitor(store: store, inputAuthority: physicalInput, captureAdmission: recorder.admission)
    let hubBootstrap = HubBootstrapState()
    private var shortcutMenuObserver: AnyCancellable?
    var recordings = RecordingStore.shared
    let recorder = AudioRecorder()
    let hud = HUD()
    /// The dictation flow itself. Every fn edge and every leg completion becomes
    /// an Event; the [Effect] it returns is what Dictation.swift executes. It
    /// owns what used to be a handful of correlated fields here — the generation
    /// counter, the per-dictation latch (settings, focus, command selection) and
    /// the live-typed ledger — so nothing can drift out of step with anything else.
    let session = DictationSession()
    lazy var captureDiagnostics = CaptureDiagnosticCoordinator(snapshot: { [recorder] in recorder.diagnosticSnapshot(for: $0) })
    /// Which generation holds the mic, mirrored out of `session` on main before
    /// every effect (see `send`). 0 = nobody; generations count from 1.
    ///
    /// The machine's own `state` is an enum carrying a `Session`, which carries
    /// `Settings` — Swift arrays and dictionaries. Reading that concurrently with
    /// a main-thread write is a real data race, so the off-main readers (the
    /// streaming loop, whisper's shouldAbort callbacks, the recorder's onEnd tap
    /// thread) read this Int under a lock instead.
    let capturingGen = OSAllocatedUnfairLock(initialState: 0)
    var preparationSelectionEpoch = UUID()
    lazy var nativePreparation: NativePreparation = {
        let owner = NativePreparation.application()
        owner.core.changed = { [weak owner] in DispatchQueue.main.async { owner?.refresh() } }
        owner.configure(store.load(), epoch: preparationSelectionEpoch)
        if store.lastError != nil { owner.revokeDraft() }
        owner.onChange = { [weak self, weak owner] snapshot in
            self?.hubBootstrap.existingHub?.preparationSnapshot = snapshot
            self?.audioImport.preparationChanged(owner?.core.admissionEpoch)
            self?.templates.preparationChanged()
            MainActor.assumeIsolated { self?.activePreviewCapture?.preparationChanged(owner?.core.admissionEpoch) }
        }
        owner.factory = { [weak self] in self?.recognitionFactory ?? RecognitionFactory() }
        owner.resident = { [weak self] in
            guard let self else { return nil }; return await MainActor.run { self.residentRecognition }
        }
        owner.publishResident = { [weak self] handle in
            guard let self else { return }; await MainActor.run { self.publishPrepared(handle) }
        }
        owner.enqueue = { [weak self] operation, work in
            guard let self else { operation.revoke(); return }
            self.processTask = PendingOperationQueue.enqueue(previous: self.processTask, operation: operation, completes: true,
                work: work, finished: { [weak owner] in
                    guard let owner else { return }; await MainActor.run { owner.refresh() }
                })
        }
        return owner
    }()
    lazy var appleSpeechPreparation = MainActor.assumeIsolated { () -> AppleSpeechPreparation in
        let owner = AppleSpeechPreparation.application()
        owner.retireHandles = { [weak self] in
            await self?.retireRecognitionHandles(engine: .appleSpeech)
        }
        owner.enqueue = { [weak self] operation, work, finished in
            guard let self else { operation.revoke(); return }
            self.processTask = PendingOperationQueue.enqueue(previous: self.processTask, operation: operation, completes: true, work: work, finished: finished)
        }
        return owner
    }
    lazy var parakeetPreparation = MainActor.assumeIsolated { () -> ParakeetPreparation in
        let owner = ParakeetPreparation.application()
        owner.enqueue = { [weak self] operation, work, finished in
            guard let self else { operation.revoke(); return }
            self.processTask = PendingOperationQueue.enqueue(previous: self.processTask, operation: operation, completes: true, work: work, finished: finished)
        }
        owner.retireHandles = { [weak self] in
            await self?.retireRecognitionHandles(engine: .parakeet)
        }
        return owner
    }
    lazy var recognitionFactory: RecognitionFactory = {
        var factory = RecognitionFactory(appleInstalledUse: { [weak self] locale, operation in
        guard let self else { throw AppleSpeechRefusal.closed }
        return try await self.appleSpeechPreparation.installedUse(locale, operation: operation)
    }, preparation: nativePreparation.core, preparationPermission: { [weak self] in
        guard let self else { return false }
        let settings = self.store.load()
        return self.store.lastError == nil && self.nativePreparation.core.matchesSavedPermission(settings)
        })
        MainActor.assumeIsolated { parakeetPreparation.bindFactory(&factory) }
        return factory
    }()
    func recognitionFactory(for request: RecognitionRequest) -> RecognitionFactory {
        if request.selection.engine == .parakeet {
            return MainActor.assumeIsolated { ParakeetAudioEntry.factory(owner: parakeetPreparation) }
        }
        return recognitionFactory
    }
    lazy var nativePreparationMenu = NativePreparationMenuActions { [weak self] action, token in
        self?.templates.cancel("Form discarded for preparation action."); self?.audioImport.invalidate("Preparation action changed import authority.")
        self?.nativePreparation.act(action, token: token)
    }
    var residentRecognition: RecognitionResident?
    var processTask: Task<Void, Never>?
    var operationAudio: [UUID: RecordingStore.CaptureDisposal] = [:] // main only; pruned at actual exit
    // Accessed only on processTask. Removed at finalization or queued cancellation.
    var recognitionHandles: [Int: RecognitionHandle] = [:]
    var recognitionErrors: [Int: String] = [:]
    // Helper retains policy/ports only; native owners are local to its queued run.
    var previewCaptures: [Int: RecognitionPreviewCapture] = [:] // processTask only
    var activePreviewCapture: RecognitionPreviewCapture? // main only
    @MainActor func revokeActivityShadow() { session.revokeActivityShadow() }
    @MainActor func revokeRecognitionPreview() { activePreviewCapture?.revoke() }
    @MainActor func retireRecognitionHandles(engine: RecognitionEngine) async {
        let operation = PendingOperation(name: "Recognition handle retirement")
        let retirement = PendingOperationQueue.enqueue(previous: processTask, operation: operation, completes: true, work: { [weak self] in
            guard let self else { return }
            self.recognitionHandles = self.recognitionHandles.filter { $0.value.request.selection.engine != engine }
        })
        processTask = retirement; await retirement.value
    }
    var activeMicrophoneTest: MicrophoneTestController?
    var tryoutRecognition: RecognitionRequest?
    var tryoutOperation: PendingOperation?
    var recorderGeneration = 0 // main-only native capture owner, also after reducer cancel

    /// Live in-field typing is hard-disabled: keystrokes posted while the user
    /// physically holds fn merge with the modifier (fn+A opens the Dock, ⇧←
    /// becomes select-to-Home) — revisions stall on the first wrong hypothesis
    /// and the finalize demotes to history-only. Shadow streaming keeps the speed
    /// win; the transcript lands as ONE insert at fn-up, after the modifier is
    /// released. Re-enable only with a verified fix for the fn-merge.
    let liveTyping = false

    // Hand-offs from an effect to the async leg that consumes it — the same
    // three values the old inline flow passed from hand to hand.
    var capturedGeneration: Int?
    var captured: [Float] = []                   // .stopCapture(discard: false)
    var pendingPolish: (DictationSession.Session, DictationSession.Landed)?  // .polish
    var selectionDestinations: [Int: Inserter.Destination] = [:] // main only; token captured before async work
    var pendingInstruction: String?              // .transform
    var insertionFailure: String?
    /// Confirmed-prefix window for long dictations: written by stream(), consumed
    /// by the finish() queued right after it — the processTask chain serializes.
    var windowGeneration: Int?
    var window: StreamWindow?

    // Model download-in-progress state (feature 4): non-nil task means a
    // download is running and a second one is refused.
    lazy var catalogDownloads = MainActor.assumeIsolated { CatalogDownloadOwner(root: ModelCatalog.directory.appendingPathComponent("downloads")) }
    // Idle model-unload. `transcriber` is the *resident* context, which the
    // watcher may free; `modelReady` is "a model file loaded successfully at
    // least once" and survives an unload — every health check reads that one,
    // so an unloaded model doesn't put ⚠️ in the menu bar.
    var modelReady = false
    /// The model path that last loaded successfully. A key press retries a
    /// failed load only for this one — a model that has never loaded (missing,
    /// damaged, a broken file of the user's own) would otherwise be re-read, or
    /// re-hashed, on the main thread at every press.
    var lastGoodModelPath: String?
    var lastModelUse = Date()
    var unloadTimer: Timer?
    let unloadPolicy = ModelUnloadPolicy.default
    // Discovery, the menu's update line and the install transaction.
    let experimentalRetryOwner = ExperimentalHistoryRetryOwner()
    lazy var localCleanupAdmission = MainActor.assumeIsolated { LocalCleanupAdmission() }
    lazy var importRestartReservation = MainActor.assumeIsolated { ImportRestartReservation() }
    lazy var updater: UpdateController = UpdateController(hud: hud, claimRestart: { [weak self] in
        await self?.claimRestartIfSafe() ?? false
    }, releaseRestart: { [weak self] in
        MainActor.assumeIsolated {
            self?.importRestartReservation.release()
        }
    })

    lazy var automationResults = MainActor.assumeIsolated { AutomationRuntime.shared.results }
    lazy var automationBroker = MainActor.assumeIsolated { AutomationRuntime.shared.broker }
    lazy var invocation: DictationInvocationHost = MainActor.assumeIsolated { DictationInvocationHost(machine: session, inputAuthority: physicalInput, captureAdmission: recorder.admission, broker: automationBroker, results: automationResults,
        settings: { [weak self] in
            guard let self else { return nil }
            let value = self.store.load(); return self.store.lastError == nil ? value : nil
        }, captureCleanupGrant: { [weak self] settings, origin in
            self?.store.captureCleanupFailoverGrant(settings: settings, origin: origin)
        }, configured: { [weak self] settings in
            guard let self else { return false }
            return cleanupIsConfigured(settings: settings, env: ProcessInfo.processInfo.environment, credentials: self.store.credentials)
        }, capabilities: { [weak self] request in
            guard let self, !self.updater.committing else { return .unavailable }
            return ParakeetAudioEntry.capabilities(request, owner: self.parakeetPreparation,
                microphone: { self.micGranted }, otherEngine: {
            guard request.selection.engine == .whisper || request.selection.engine == .appleSpeech else { return .modelUnavailable }
            guard self.nativePreparation.cachedRefusal(for: request) == nil else { return .modelUnavailable }
            guard MainActor.assumeIsolated({ self.appleSpeechPreparation.cachedRefusal(for: request, deliberate: true) }) == nil else { return .modelUnavailable }
            if request.selection.engine == .appleSpeech { return self.micGranted ? nil : .microphoneUnavailable }
            guard self.micGranted else { return .microphoneUnavailable }
            let url = URL(fileURLWithPath: request.modelPath)
            // Cached installed verification only. No hash/download/model construction here.
            guard FileManager.default.fileExists(atPath: request.modelPath),
                  url.deletingLastPathComponent().standardizedFileURL == ModelCatalog.directory.standardizedFileURL,
                  ModelCatalog.model(atPath: request.modelPath) != nil,
                  VerifiedCache().isVerified(url) else { return .modelUnavailable }
            return nil
            })
        }, secure: { [weak self] in
            let secure = Self.automationSecureEvidence()
            if secure { self?.templates.cancel("Form discarded after secure-input evidence."); self?.audioImport.invalidate("Import discarded after secure-input evidence.") }
            return secure
        },
        keyboardAllowed: { [weak self] in self.map { !$0.updater.committing && $0.axGranted } ?? false },
        automationAllowed: { [weak self] in self?.store.load().automationEnabled == true },
        explicitEntry: { [weak self] in self?.appleSpeechPreparation.deliberateEntry(); self?.startup.enterDictation() },
        send: { [weak self] in self?.send($0) },
        deliberateASREntry: { [weak self] request in
            guard let self else { return }; ParakeetAudioEntry.deliberate(request, owner: self.parakeetPreparation)
        },
        invalidateOriginal: { [weak self] in self?.originalCopy.clear() },
        invalidateCanceledCapture: { [weak self] in self?.canceledCaptureUndo.deliberateEntry() },
        captureAccepted: { [weak self] session, physical in self?.canceledCaptureUndo.accepted(session, physical: physical) },
        ordinaryBusyReason: { [weak self] in self?.localCleanupAdmission.ordinaryBusyReason },
        busyFeedback: { [weak self] reason in self?.hud.show(.notice(reason)) }) }
    lazy var inputRouter = MainActor.assumeIsolated { DictationInputRouter(host: invocation,
        prepare: { [weak self] in self?.preparePhysicalStart(command: false) },
        secureRefused: { [weak self] in self?.showSecureRefusal("No dictation in password fields") }) }
    lazy var startup: ApplicationStartupCoordinator = MainActor.assumeIsolated { ApplicationStartupCoordinator(configure: { [weak self] in
        guard let self else { return }
        let settings = self.store.load()
        self.recordings.configure(settings: settings, error: self.store.lastError)
        self.hud.idleBarSize = HUD.idleSize(settings.hudIdleSize)
        self.hud.showAlways = settings.showHudAlways
        self.recorder.inputDeviceUID = settings.inputDeviceUID
    }, reconcileSpeech: { [weak self] in
        guard let self else { return }
        let settings = self.store.load()
        self.appleSpeechPreparation.configure(settings, valid: self.store.lastError == nil)
        ParakeetAudioEntry.reconcile(settings, valid: self.store.lastError == nil, owner: self.parakeetPreparation)
    }, register: { [weak self] in
        guard let self else { return }; self.automationBroker.register(self.invocation)
    }, services: { [weak self] in
        self?.startUnloadWatcher(); self?.hotkey.start(); self?.updater.start()
    }, migrate: { [weak self] in _ = self?.store.migrateSelectedCredentials() }, setup: { [weak self] in
        guard let self, !self.session.isCapturing, !self.invocation.tryoutActive else { return }
        self.scheduleModelSetup()
    }, warmMic: { [weak self] in
        guard let self else { return }; self.recorder.setWarm(self.store.load().warmMic); self.recorder.resumeWarmthOnExplicitEntry()
    }) }

    // Hub and its window remain lazy until explicit user entry.
    var hubModel: HubModel { hubBootstrap.resolve {
        let test = MicrophoneTestController(capture: RecorderMicrophoneCapture(recorder: recorder), admission: recorder.admission,
            allowed: { [weak self] in
                guard let self else { return false }
                return !self.updater.committing && !self.session.isCapturing && self.recorderGeneration == 0
                    && !MainActor.assumeIsolated { self.invocation.tryoutActive }
            }, permission: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            playbackAllowed: { [weak self] in self?.hubModel.recoveryPlayback.id == nil })
        activeMicrophoneTest = test
        let m = HubModel(store: store, history: history, recordings: recordings,
            shortcutLabels: hubBootstrap.shortcutLabels, microphoneTest: test, experimentalRetryOwner: experimentalRetryOwner, audioImport: audioImport, templates: templates)
        hubBootstrap.attach(m)
        m.onRetryInput = { [weak self] in self?.hotkey.retryInput() }
        m.localRetryScheduler = { [weak self] operation, work in
            guard let self else { return .failure(LocalCleanupReason.schedulerUnavailable.error) }
            return await self.enqueueLocalHistoryRetry(operation: operation, work: work)
        }
        MainActor.assumeIsolated { m.bindAppleSpeech(appleSpeechPreparation) }
        MainActor.assumeIsolated { m.bindParakeet(parakeetPreparation) }
        m.modelSelectionEpoch = preparationSelectionEpoch
        m.preparationSnapshot = nativePreparation.snapshot
        m.onRecognitionPreviewRevoked = { [weak self] in MainActor.assumeIsolated { self?.revokeRecognitionPreview() } }
        m.onPreparationDraftDisabled = { [weak self] in
            MainActor.assumeIsolated { self?.revokeRecognitionPreview() }
            self?.nativePreparation.revokeDraft()
        }
        m.onPreparationConsent = { [weak self] in guard let self else { throw PreparationRefusal.trackingUnavailable }; try self.nativePreparation.prepareConsent($0) }
        m.onPreparationBeforeSave = { [weak self] in try self?.nativePreparation.beforeSave($0) }
        m.onPreparationSaved = { [weak self, weak m] settings in
            guard let self, let m else { return }
            MainActor.assumeIsolated { self.revokeRecognitionPreview() }
            self.preparationSelectionEpoch = m.modelSelectionEpoch
            self.nativePreparation.configure(settings, epoch: m.modelSelectionEpoch)
            MainActor.assumeIsolated { self.appleSpeechPreparation.configure(settings) }
        }
        m.onPreparationSaveFailed = { [weak self] in
            MainActor.assumeIsolated { self?.appleSpeechPreparation.draftChanged() }
            MainActor.assumeIsolated { self?.parakeetPreparation.draftChanged() }
            guard let self, self.nativePreparation.core.isEnabled else { return }; self.nativePreparation.revokeDraft()
        }
        m.onPreparationSaveDeferred = { [weak self, weak m] in
            guard let self, let m else { return }
            Task { [chain = self.processTask] in
                await chain?.value
                await MainActor.run {
                    guard !m.settings.nativePreparationSafeStartEnabled else { return }; m.savePreparationDraft()
                }
            }
        }
        m.onPreparationSelection = { [weak self] epoch, request in
            self?.preparationSelectionEpoch = epoch; self?.nativePreparation.changedSelection(epoch, request: request)
        }
        m.onPreparationAction = { [weak self] action, token in
            self?.templates.cancel("Form discarded for preparation action."); self?.audioImport.invalidate("Preparation action changed import authority.")
            self?.nativePreparation.act(action, token: token)
        }
        m.bindOriginalCopy(originalCopy)
        m.onActivityShadowRevoked = { [weak self] in MainActor.assumeIsolated { self?.revokeActivityShadow() } }
        m.onCanceledCaptureConfigurationChanged = { [weak self] valid in
            self?.canceledCaptureConfigurationInvalid = !valid
            self?.canceledCaptureUndo.configurationChanged(valid: valid)
        }
        m.onCanceledCaptureInvalidate = { [weak self] in self?.canceledCaptureUndo.invalidate() }
        test.beforeStart = { [weak self] in self?.canceledCaptureUndo.invalidate() }
        m.onShortcutBegin = { [weak self] in
            MainActor.assumeIsolated { self?.invocation.beginShortcutRecording() }
        }
        m.onShortcutEnd = { [weak self] lease in MainActor.assumeIsolated { self?.invocation.endShortcutRecording(lease) } }
        MainActor.assumeIsolated { m.bindCatalogDownloads(catalogDownloads, setup: { [weak self] in self?.scheduleModelSetup() }) }
        m.onClearAutomationResult = { [weak self] in MainActor.assumeIsolated { self?.invocation.clearResult() } }
        m.onAutomationEnabledChanged = { [weak self] enabled in MainActor.assumeIsolated { self?.automationBroker.configurationChanged(enabled: enabled) } }
        m.onHistoryCleared = { [weak self] in MainActor.assumeIsolated { self?.invocation.clearResult() } }
        m.onOpenSettingsFile = { [weak self] in self?.openSettings() }
        // nil means "recording" here, so weak-self can't collapse into `??`.
        m.onTryoutStart = { [weak self] in
            guard let self else { return "Parla is shutting down" }
            return self.tryoutStart()
        }
        m.onTryoutCancel = { [weak self] in self?.cancelTryout() }
        m.onTryoutStop = { [weak self] done in
            guard let self else { return done("") }
            self.tryoutStop(done)
        }
        m.audioImportPreparationEpoch = { [weak self] in self?.nativePreparation.core.admissionEpoch }
        m.onAudioImport = { [weak self] job, done in
            guard let self else { job.revoke(); job.operation.finish(); done(.failure(CancellationError())); return }
            let request = job.configuration.request
            let factory = self.recognitionFactory(for: request)
            MainActor.assumeIsolated {
                if let next = AudioImportExecution.enqueue(previous: self.processTask, admission: self.localCleanupAdmission,
                    job: job, store: self.store, enter: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await MainActor.run {
                            if request.selection.engine == .appleSpeech { self.appleSpeechPreparation.deliberateEntry() }
                            try ParakeetAudioEntry.recovery(request, owner: self.parakeetPreparation)
                        }
                    }, load: { [weak self] request in
                        guard let self else { throw CancellationError() }
                        let resident = await MainActor.run { self.residentRecognition }
                        return try await RecognitionAcquisition.acquire(request: request, resident: resident, factory: factory,
                            operation: job.operation, selectionEpoch: job.selectionEpoch, preparationEpoch: job.preparationEpoch)
                    }, done: done) { self.processTask = next }
            }
        }
        m.onRecoveryTranscribe = { [weak self] lease, request, done in
            guard let self else { return done(.failure(RecordingStore.Failure("Parla is shutting down."))) }
            let epoch = self.preparationSelectionEpoch
            let preparationEpoch: UUID? = request.selection.engine == .whisper ? self.nativePreparation.core.admissionEpoch : nil
            let factory = self.recognitionFactory(for: request)
            self.processTask = RecoveryTranscription.enqueue(previous: self.processTask,
                recordings: self.recordings, lease: lease, request: request,
                authorize: { [weak self] in
                    guard let self else { return false }
                    return self.recordings.refreshPolicy(from: self.store)
                }, enter: { [weak self] in
                    guard let self else { throw ParakeetInstallationRefusal.closed }
                    try await MainActor.run {
                        try ParakeetAudioEntry.recovery(request, owner: self.parakeetPreparation)
                    }
                }, load: { [weak self] request in
                    guard let self else { throw RecordingStore.Failure("Parla is shutting down.") }
                    let resident = await MainActor.run { self.residentRecognition }
                    return try await RecognitionAcquisition.acquire(request: request, resident: resident,
                        factory: factory, operation: lease.operation, selectionEpoch: epoch, preparationEpoch: preparationEpoch)
                }, done: done)
        }
        m.onScratchpadDictionaryDraftChanged = { [weak self] in MainActor.assumeIsolated { self?.scratchpad.configurationChanged() } }
        m.onMouseBindingSaved = { [weak self] in self?.hotkey.reloadMouseConfiguration() }
        m.onSaved = { [weak self] in
            guard let self else { return }
            let s = self.store.load()
            MainActor.assumeIsolated { self.automationBroker.configurationChanged(enabled: s.automationEnabled) }
            self.hud.idleBarSize = HUD.idleSize(s.hudIdleSize)
            self.hud.showAlways = s.showHudAlways
            self.recorder.inputDeviceUID = s.inputDeviceUID
            // Apply the warm-mic setting and warm the new mic in one call. A warm
            // engine still running on the OLD one is left alone (see setWarm());
            // start() rebinds it, so the first press after a mic switch is cold but
            // correct — accepted over a rebind here, which would tear the tap down
            // mid-capture when hands-free is latched. Turning the setting off here
            // is what puts the mic indicator out without a relaunch.
            self.recorder.setWarm(s.warmMic)
            // The Hub's model picker writes whisperModelPath through this same
            // save, so a changed path is the signal to swap the loaded context.
            if (s.whisperModelPath ?? WhisperTranscriber.defaultModelPath()) != self.lastGoodModelPath {
                self.scheduleModelSetup()
            }
        }
        m.modelLoaded = modelReady
        return m
    } }
    lazy var hubController = HubWindowController(model: hubModel)
    lazy var scratchpad = MainActor.assumeIsolated { ScratchpadController.application(store: store) }

    @objc func openHub() {
        templates.cancel("Form discarded for settings entry.")
        hubController.show()
        if nativePreparation.cachedRefusal == nil { MainActor.assumeIsolated { startup.enterSetup() } }
    }
    @objc func openTemplates() {
        hubModel.requestedPage = .templates; hubModel.templatesPageActive = true
        hubController.show(templatesOnly: true)
    }
    @objc func openAudioImport() {
        templates.cancel("Form discarded for audio import.")
        hubModel.requestedPage = .audioImport
        hubModel.audioImportPageActive = true
        hubController.show(audioImportOnly: true)
    }
    @objc func openNativePreparation() { templates.cancel("Form discarded for preparation."); hubModel.requestedPage = .safeStart; hubController.show(preparationOnly: true) }
    @objc func openScratchpad() { MainActor.assumeIsolated { scratchpad.show() } }

    // Opening Parla again from Finder/Spotlight while it runs lands here, not on
    // the single-instance alert. Show the Hub: macOS can hide the menu-bar icon
    // (notch overflow, Menu Bar settings), and then this is the only way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub()
        return false
    }

    lazy var termination = TerminationCoordinator(clipboard: Inserter.beginClipboardShutdown,
        updater: { [weak self] reply in self?.updater.shouldTerminate(reply) },
        download: { [weak self] reply in MainActor.assumeIsolated { self?.catalogDownloads.beginShutdown(reply) } },
        cancelDownload: { [weak self] in MainActor.assumeIsolated { self?.catalogDownloads.cancelShutdown() } },
        preparation: { [weak self] reply in
            guard let self else { reply(false); return }
            self.nativePreparation.beginShutdown(chain: { [weak self] in self?.processTask }, reply: reply)
        }, cancelPreparation: { [weak self] in self?.nativePreparation.cancelShutdown() },
        appleSpeech: { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self else { reply(false); return }
                self.appleSpeechPreparation.beginShutdown(chain: { self.processTask }, reply: reply)
            }
        }, cancelAppleSpeech: { [weak self] in MainActor.assumeIsolated { self?.appleSpeechPreparation.cancelShutdown() } },
        parakeet: { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self else { reply(false); return }
                self.parakeetPreparation.beginShutdown(chain: { self.processTask }, reply: reply)
            }
        }, cancelParakeet: { [weak self] in MainActor.assumeIsolated { self?.parakeetPreparation.cancelShutdown() } },
        localCleanup: { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self else { reply(false); return }
                self.localCleanupAdmission.beginShutdown(chain: { self.processTask }, reply: reply)
            }
        }, cancelLocalCleanup: { [weak self] in MainActor.assumeIsolated { self?.localCleanupAdmission.cancelShutdown() } },
        savedImports: { [weak self] reply in
            guard let self else { reply(false); return }; self.savedImports.beginShutdown(reply)
        }, cancelSavedImports: { [weak self] in self?.savedImports.cancelShutdown() },
        experimentalRetry: { [weak self] reply in
            MainActor.assumeIsolated {
                guard let owner = self?.experimentalRetryOwner else { reply(true); return }
                owner.beginShutdown(reply)
            }
        }, cancelExperimentalRetry: { [weak self] in
            MainActor.assumeIsolated { self?.experimentalRetryOwner.cancelShutdown() }
        },
        cancelClipboard: Inserter.cancelClipboardShutdown,
        cancelUpdater: { [weak self] in self?.updater.cancelTerminationIntent() },
        reply: { NSApp.reply(toApplicationShouldTerminate: $0) },
        failure: { [weak self] in
            self?.canceledCaptureUndo.quitCanceled()
            let message = self?.savedImports.shutdownRefusal.map { "Quit canceled: " + $0 } ?? (self?.nativePreparation.core.persistenceFailed == true
                ? "Quit canceled: native preparation tracking could not be persisted. Open Safe Start."
                : "Quit canceled: clipboard restoration is unresolved. The original remains in memory.")
            self?.hud.show(.error(message))
        }, onIntent: { [weak self] in guard let self else { return }; Self.cleanupFailoverIntent(self.store); Self.guidedQuitIntent(self.templates, imports: self.audioImport) })

    lazy var canceledCaptureTermination = CanceledCaptureTermination(undo: canceledCaptureUndo, coordinator: termination)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ localCleanupAdmission.hasOrdinaryFailover }), session.isCapturing {
            hud.show(.notice("Finish or cancel the current recording before quitting. Prior cleanup is still stopping."))
            return .terminateCancel
        }
        MainActor.assumeIsolated { revokeRecognitionPreview(); revokeActivityShadow() }
        cancelTryout()
        scratchpad.quitIntent()
        return canceledCaptureTermination.request()
    }

    func applicationDidResignActive(_ notification: Notification) { templates.cancel("Form discarded when the app resigned."); activeMicrophoneTest?.lifecycle(.resign); scratchpad.focusLost() }

    func applicationWillTerminate(_ notification: Notification) {
        templates.cancel("Form discarded for quit.")
        audioImport.invalidate("Import discarded for quit.")
        MainActor.assumeIsolated { revokeRecognitionPreview(); revokeActivityShadow() }
        canceledCaptureUndo.shutdown()
        originalCopy.clear()
        activeMicrophoneTest?.lifecycle(.quit)
        MainActor.assumeIsolated { automationBroker.quit() }
        captureDiagnostics.clear()
        hubModel.clearDiagnostics()
        hubModel.stopRecoveryPlayback()
        scratchpad.quitIntent()
        scratchpad.save() // flush a pending debounced edit
        hubModel.flushPendingSave() // and a Hub edit still inside its debounce
    }

    /// Safe-to-restart, decided and claimed in one main-actor turn: no session,
    /// the processTask chain drained (transcription, polish, delivery), and no
    /// clipboard restore still owed. `isCapturing` alone is false through all
    /// of those. On true, new dictations are refused until the relaunch.
    @MainActor func claimRestartIfSafe() async -> Bool {
        if localCleanupAdmission.hasOrdinaryFailover, session.isCapturing {
            hud.show(.notice("Finish or cancel the current recording before restarting. Prior cleanup is still stopping."))
            return false
        }
        Self.cleanupFailoverIntent(store)
        audioImport.invalidate("Import discarded for restart.")
        revokeActivityShadow()
        revokeRecognitionPreview()
        cancelTryout()
        let claimed = await Self.withSavedImportRestart(savedImports, parakeet: parakeetPreparation,
            apple: appleSpeechPreparation, local: localCleanupAdmission, experimental: experimentalRetryOwner, guided: templates,
            chain: { self.processTask }, reservation: importRestartReservation, releaseClaim: { [self] in
                catalogDownloads.releaseRestartReservation(); nativePreparation.core.releaseRestart()
            }) { [self] in
                canceledCaptureUndo.shutdown()
                let allowed = await nativePreparation.claimRestart(chain: { self.processTask }, allowed: {
                    self.session.state == .idle && !Inserter.clipboardRestorePending && !self.catalogDownloads.isActive
                        && self.savedImports.restartReady() && self.activeMicrophoneTest?.ownsSession != true && self.templates.readyForRestart
                        && self.appleSpeechPreparation.restartReady() && self.parakeetPreparation.restartReady()
                }, claimOther: { self.catalogDownloads.claimRestartIfIdle() }, rejected: {})
                guard allowed else { return false }
                originalCopy.clear()
                updater.committing = true
                return true
            }
        if !claimed { canceledCaptureTermination.restartFailed() }
        return claimed
    }

    /// Shipping app/updater composition. Reserve every concrete participant in
    /// one actor turn, then drain. A rejection unwinds only acquired reservations.
    @MainActor static func withSavedImportRestart(_ saved: SavedAudioImportOwner,
        parakeet: ParakeetPreparation, apple: AppleSpeechPreparation, local: LocalCleanupAdmission,
        experimental: ExperimentalHistoryRetryOwner, guided: GuidedTemplateOwner? = nil, chain: @escaping () -> Task<Void,Never>?,
        reservation: ImportRestartReservation? = nil, releaseClaim: @escaping () -> Void = {},
        claim: () async -> Bool) async -> Bool {
        guided?.cancel("Form discarded for restart.")
        guard reservation?.isHeld != true else { return false }
        var releases: [() -> Void] = []
        var claimed = false
        defer { if !claimed { for release in releases.reversed() { release() } } }
        guard parakeet.reserveRestart() else { return false }; releases.append { parakeet.releaseRestart() }
        guard apple.reserveRestart() else { return false }; releases.append { apple.releaseRestart() }
        guard local.reserveRestart() else { return false }; releases.append { local.releaseRestart() }
        guard experimental.reserveRestart() else { return false }; releases.append { experimental.releaseRestart() }
        guard saved.reserveRestart() else { return false }; releases.append { saved.releaseRestart() }
        await saved.drain()
        guard saved.restartReady() else {
            saved.notice(saved.shutdownRefusal ?? "Saved IO has not settled. Restart is unavailable.")
            return false
        }
        await experimental.drainRestart()
        guard await parakeet.drainRestart(chain: chain) else { return false }
        await apple.retireForRestart()
        guard guided?.readyForRestart != false else { return false }
        claimed = await claim()
        if claimed { reservation?.retain(releases + [releaseClaim]) }
        return claimed
    }

    @MainActor func enqueueLocalHistoryRetry(operation: PendingOperation, work: @escaping () async -> LocalHistoryRetryResult) async -> LocalHistoryRetryResult {
        guard localCleanupAdmission.admit(operation) else { return .failure(LocalCleanupReason.schedulerUnavailable.error) }
        return await withCheckedContinuation { continuation in
            processTask = LocalHistoryRetryQueue.enqueue(previous: processTask, operation: operation, work: work) { result in
                self.localCleanupAdmission.exited(operation)
                continuation.resume(returning: result)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setStatus("🎤")
        installMainMenu()
        buildMenu()
        // No proven intent-specific launch discriminator exists. All launches
        // register passively; setup/model+mic warmup starts at explicit user entry.
        // The Hub remains reachable from the menu and Finder reopen.

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.push(level: level) }
        }

        // Capture ended without an fn-up: the 10-minute cap (which is also the
        // ceiling on a forgotten hands-free latch) or a mic that disappeared.
        // The machine finalizes it exactly as fn-up does, minus the fn-up stamp.
        recorder.onEnd = { [weak self] reason in
            guard let self else { return }
            // The generation is read HERE, on the tap thread as the capture ends,
            // not inside the hop: reading it at delivery time would make the
            // machine's `s.gen == g` check a tautology, and an fn-down landing in
            // between would rename this stale end as the new dictation's and
            // finalize a session that just started recording.
            let gen = self.capturingGen.withLock { $0 }
            DispatchQueue.main.async {
                // Unlatch the hotkey monitor with it, or it swallows the user's
                // next Space/Return/Esc as the stop of a session that is gone.
                // Only for the capture still in the foreground: a stale end must
                // not unlatch the press that superseded it.
                if gen != 0, self.capturingGen.withLock({ $0 }) == gen { self.hotkey.endSession() }
                MainActor.assumeIsolated { self.inputRouter.captureEnded(generation: gen, reason: reason) }
            }
        }

        hotkey.onEdge = { [weak self] edge in
            guard let self else { return }
            NSLog("Parla: fn edge %@", "\(edge)")
            switch edge {
            case .down(let command):
                let nextGen = self.session.gen + 1
                if let event = self.preparePhysicalStart(command: command) {
                    _ = MainActor.assumeIsolated { self.invocation.keyboard(event) }
                }
                if self.session.gen != nextGen { self.selectionDestinations[nextGen] = nil }
            case .up(let short):
                // Short tap = accidental Globe press (emoji/input switch): abort
                // silently, never run whisper. Recording still STARTED on fn-down
                // so we don't clip speech onset; we just discard it here.
                _ = MainActor.assumeIsolated { self.invocation.keyboard(short ? .cancelRequested(silent: true, reason: .shortRelease) : .stopRequested) }
            case .cancel:
                // Esc, or a real key pressed while fn was held (fn+arrow): abort.
                _ = MainActor.assumeIsolated { self.invocation.keyboard(.cancelRequested(silent: false, reason: .explicitCancel)) }
            case .handsFree:
                // fn+Space latched: same recording, but tell the user Space took —
                // the pill relabels and a pop confirms fn can be released.
                _ = MainActor.assumeIsolated { self.invocation.keyboard(.handsFreeLatched) }
            case .runSelectedPreset:
                self.runSelectedPreset()
            case .pasteLast:
                guard let text = self.history.entries.first?.best else { return }
                self.pasteWhenModifiersClear(text)
            case .openScratchpad:
                MainActor.assumeIsolated { self.scratchpad.show() }
            case .dismiss:
                self.hud.dismiss()
            }
        }
        hotkey.onMouseEdge = { [weak self] edge in
            MainActor.assumeIsolated { self?.inputRouter.mouse(edge) }
        }
        hotkey.onTapStatus = { [weak self] status in self?.hubBootstrap.updateTapStatus(status) }
        MainActor.assumeIsolated { startup.bootstrap() }
    }

    /// Shared guarded physical start preparation; mouse chooses ordinary hold
    /// dictation, keyboard retains shift/selection command semantics.
    func preparePhysicalStart(command: Bool) -> DictationSession.Event? {
        if !command, let reason = MainActor.assumeIsolated({ localCleanupAdmission.ordinaryBusyReason }) {
            hud.show(.notice(reason)); return nil
        }
        guard recorder.admission.allowsKeyboard else { return nil }
        // The app is being swapped out: the relaunch would cut this off.
        guard !updater.committing else {
            hud.show(.notice("Updating Parla…"))
            return nil
        }
        guard axGranted else {
            hud.show(.error("Enable Parla in System Settings → Privacy & Security → Accessibility"))
            return nil
        }
        // Latch the settings for the whole dictation: the streaming loop
        // and both legs read the latched value instead of stat()ing the
        // file every ~300ms pass. The re-read-only-if-changed cache lives
        // in SettingsStore.load() so all ten call sites get it.
        var settings = store.load()
        guard store.lastError == nil else { session.revokeActivityShadow(); hud.show(.error("Repair settings before dictating")); return nil }
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let destination = ProfileDestination(bundleID: appID,
            browserURL: settings.profiles.isEmpty ? nil : Inserter.focusedBrowserURL(bundleID: appID))
        let focus = Inserter.focusTarget()
        guard focus != .secure else { showSecureRefusal("No dictation in password fields"); return nil }
        let selection = command ? Inserter.selectedText() : nil
        if command, selection == nil { hud.show(.error("Select text first")); return nil }
        if !command, settings.outputMode == .selectedPreset {
            do { _ = try settings.selectedTransformPreset() }
            catch { hud.show(.error("Choose a valid saved preset first")); return nil }
        }
        let refusal = MainActor.assumeIsolated {
            ParakeetAudioEntry.physical(settings, destination: destination, owner: parakeetPreparation)
        }
        if let refusal { hud.show(.error(refusal.message)); return nil }
        // Keep recognition and profile values frozen while carrying migration's
        // credential fields. A refused ASR entry never reaches this boundary.
        MainActor.assumeIsolated { appleSpeechPreparation.deliberateEntry() }
        _ = store.migrateSelectedCredentials()
        let migrated = store.load()
        settings.anthropicApiKey = migrated.anthropicApiKey; settings.cleanup.apiKey = migrated.cleanup.apiKey
        var providerSettings = settings; providerSettings.cleanupEnabled = true
        let configured = cleanupIsConfigured(settings: providerSettings,
            env: ProcessInfo.processInfo.environment, credentials: store.credentials)
        guard command else {
            settings = store.preparingPhysicalSurroundingText(settings, destination: destination, live: liveTyping)
            return .startDictation(settings: settings, cleanupConfigured: configured,
                live: liveTyping, recognitionDestination: destination,
                cleanupFailoverGrant: store.captureCleanupFailoverGrant(settings: settings, origin: .physicalOrdinary))
        }
        let token = Inserter.Destination()
        let nextGen = session.gen + 1
        selectionDestinations[nextGen] = token
        let target = LandingProbe(focus: focus, bundleID: appID, appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            browserURL: focus == .secure ? nil : Inserter.focusedBrowserURL(bundleID: appID),
            singleLine: focus == .secure ? false : Inserter.focusedFieldIsSingleLine())
        return .startCommand(settings: settings, cleanupConfigured: configured,
                             focus: focus, selection: selection,
                             recognitionDestination: destination, transformTarget: target)
    }

    /// The launch Apple event marks an SMAppService login-item start. Only
    /// meaningful during applicationDidFinishLaunching, while that event is current.
    static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// App version from the bundle's Info.plist (CFBundleShortVersionString).
    /// nil under `swift run` (no bundle), which the update check reads as a failure.
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

    /// Every `.secure` refusal's toast, and its only log line: the refusal at
    /// fn-down logged nothing, so "it said password field in a plain text box"
    /// left no trace to diagnose. The frontmost app is the one lead there is.
    func showSecureRefusal(_ passwordField: String) {
        templates.cancel("Form discarded after secure-input evidence.")
        audioImport.invalidate("Import discarded after secure-input evidence.")
        originalCopy.clear()
        MainActor.assumeIsolated {
            invocation.secureRefusal {
                let message = Inserter.secureRefusalMessage(passwordField)
                NSLog("Parla secure refusal: %@ (frontmost: %@)", message,
                      NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
                hud.show(.error(message))
            }
        }
    }

    /// History can outlive its source app. Resolve the target at the keystroke,
    /// then flatten newlines where Return would fire: terminals run commands,
    /// chat apps (Slack, Discord, etc.) send the message.
    func insertStoredText(_ text: String) {
        originalCopy.clear()
        // Mid-swap: the relaunch would exit before this paste's clipboard restore.
        guard !updater.committing else { return hud.show(.notice("Updating Parla…")) }
        // The ONE insertion path with no secure-field check otherwise: ⌃⌘V and
        // the history menu would type a stored transcript straight into a
        // password field — the single invariant the rest of the app never
        // breaks. The text stays in history for a retry somewhere sane.
        guard Inserter.focusTarget() != .secure else {
            showSecureRefusal("Not supported in password fields")
            return
        }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let category = TextRules.category(bundleID: bundleID,
                                          browserURL: Inserter.focusedBrowserURL(bundleID: bundleID))
        let flattened = category == .terminal || category == .chat || Inserter.focusedFieldIsSingleLine()
        if !insertionExecutor.insertStored(flattened ? TextRules.flattenForTerminal(text) : text) {
            hud.show(.error(axGranted ? "Paste failed — copy the transcript from History" : "Enable Accessibility for Parla"))
        }
    }

    /// Explicit setup and warmup remain one owned child of the existing native-exit barrier.
    func scheduleModelSetup() {
        let selectedSettings = store.load()
        let selectedRequest = RecognitionRequest(settings: selectedSettings)
        if selectedRequest.selection.engine != .whisper {
            MainActor.assumeIsolated {
                if selectedRequest.selection.engine == .parakeet {
                    parakeetPreparation.configure(selectedSettings, valid: store.lastError == nil)
                } else { appleSpeechPreparation.configure(selectedSettings, valid: store.lastError == nil) }
            }
            residentRecognition = nil; lastGoodModelPath = nil; modelReady = false
            hubModel.observedRecognition = nil; hubModel.modelLoaded = false
            return
        }
        if nativePreparation.core.isEnabled { scheduleGuardedPreparation(); return }
        let request = RecognitionRequest(settings: store.load()), epoch = hubModel.modelSelectionEpoch
        let operation = PendingOperation(name: "Setup model"), factory = recognitionFactory
        processTask = PendingOperationQueue.enqueue(previous: processTask, operation: operation, completes: true, work: {
            let admitted = await MainActor.run {
                !self.session.isCapturing && !self.invocation.tryoutActive && self.recorder.admission.allowsKeyboard
                    && epoch == self.hubModel.modelSelectionEpoch && request == RecognitionRequest(settings: self.store.load())
            }
            guard admitted else { return }
            do {
                let handle = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory, operation: operation)
                _ = await handle.recognize([Float](repeating: 0, count: 16_000), pass: .warmup,
                    shouldAbort: { operation.shouldAbort || self.capturingGen.withLock { $0 != 0 } })
                NSLog("Parla: whisper warmup done")
                await MainActor.run {
                    guard !operation.shouldAbort, !self.session.isCapturing, !self.invocation.tryoutActive,
                          RecognitionAcquisition.mayPromote(handle, global: request, epoch: epoch,
                            currentEpoch: self.hubModel.modelSelectionEpoch,
                            current: RecognitionRequest(settings: self.store.load()), factory: factory) else { return }
                    self.residentRecognition = handle.resident
                    self.modelReady = true; self.lastGoodModelPath = request.modelPath
                    self.hubModel.observedRecognition = (handle.request.selection, handle.client.capabilities)
                    self.lastModelUse = Date(); self.hubModel.modelLoaded = true; self.showIdle()
                }
            } catch {
                await MainActor.run {
                    guard !operation.shouldAbort, !self.session.isCapturing, !self.invocation.tryoutActive,
                          epoch == self.hubModel.modelSelectionEpoch, request == RecognitionRequest(settings: self.store.load()) else { return }
                    self.lastGoodModelPath = nil; self.residentRecognition = nil; self.modelReady = false
                    self.hubModel.observedRecognition = nil; self.hubModel.modelLoaded = false
                    self.hud.show(.error("Local model unavailable — check the selected model")); self.showIdle()
                }
            }
        })
    }

    /// 10 s idle watcher. It refuses to unload while recording and touches the
    /// activity stamp instead (Handy's shape), and the free itself is queued on
    /// the processTask chain so it can never race a whisper pass — the ctx
    /// isn't reentrant and freeing it mid-pass is a crash, not a leak.
    func startUnloadWatcher() {
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.residentRecognition != nil else { return }
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
                guard !self.session.isCapturing, self.residentRecognition != nil else { return }
                self.residentRecognition = nil
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
        let request = RecognitionRequest(settings: store.load())
        let ready: Bool
        switch request.selection.engine {
        case .whisper: ready = modelReady
        case .appleSpeech: ready = MainActor.assumeIsolated { appleSpeechPreparation.cachedRefusal(for: request) == nil }
        case .parakeet: ready = MainActor.assumeIsolated { parakeetPreparation.cachedRefusal(for: request) == nil }
        case .invalid: ready = false
        }
        let healthy = ready && store.lastError == nil && !history.needsAttention && micGranted && axGranted
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

    // Text/emoji states (… transcribing, ⚠️ error) clear any logo image
    // first so they don't render side by side.
    func setStatus(_ s: String) {
        statusItem.button?.image = nil
        statusItem.button?.title = s
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        shortcutMenuObserver = Self.observeShortcutHints(in: menu, labels: hubBootstrap.shortcutLabels, store: store)
    }

    // LSUIElement apps get no main menu by default, and macOS dispatches
    // ⌘C/⌘V/⌘X/⌘A through the main menu's Edit items — without this, paste
    // doesn't work in any hub/scratchpad text field.
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Voice Templates…", action: #selector(openTemplates), keyEquivalent: ""))
        appItem.submenu?.addItem(NSMenuItem(title: "Import Audio…", action: #selector(openAudioImport), keyEquivalent: ""))
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
        edit.addItem(.separator())
        let spelling = NSMenuItem(title: "Dictionary spelling…", action: #selector(ScratchpadController.dictionarySpelling(_:)), keyEquivalent: "")
        spelling.target = scratchpad
        edit.addItem(spelling)
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
        templates.cancel("Form discarded for settings file editing.")
        // Only seed defaults when there's no file yet — never overwrite a
        // broken settings.json the user is about to fix (that's their typo'd
        // API key / dictionary, don't discard it).
        if !FileManager.default.fileExists(atPath: store.url.path) {
            try? store.save(store.load())
        }
        NSWorkspace.shared.open(store.url)
    }

    @objc func updateClicked() { updater.menuItemClicked() }
    @objc func checkForUpdates() { updater.check(manual: true) }

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

/// Send NSLog to ~/Library/Logs/Parla.log. NSLog is the app's only diagnostics,
/// and the unified log stores every line of it as `<private>` — so "it stopped
/// working overnight" left nothing behind to read. NSLog also writes to stderr
/// whenever stderr is a file, which makes this one redirect the whole feature:
/// every existing call site lands in the file, timestamped, with no new API.
/// Under `swift run` stderr is the terminal and is left alone.
func logToFile() {
    guard isatty(STDERR_FILENO) == 0 else { return }
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Parla.log")
    // ponytail: one previous file, checked at launch only. whisper prints a
    // page per model load, so this is weeks, not years; size it if that bites.
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
    // open + dup2, not freopen: a failed freopen has already closed stderr, and
    // the next file the app opens would inherit fd 2 and collect NSLog's output.
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { return }
    dup2(fd, STDERR_FILENO)
    close(fd)
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
logToFile()
let delegate = AppDelegate()
app.delegate = delegate
app.run()

/// Only an actually successful restart owns a release receipt. An updater
/// failure before claim cannot release somebody else's reservation; repeated
/// failure notifications retire this same acquired set at most once.
@MainActor final class ImportRestartReservation {
    private var releases:[() -> Void] = []
    var isHeld:Bool {!releases.isEmpty}
    func retain(_ acquired:[() -> Void]) {precondition(!isHeld); releases = acquired}
    func release() {
        let acquired = releases; releases = []
        for release in acquired.reversed() {release()}
    }
}
