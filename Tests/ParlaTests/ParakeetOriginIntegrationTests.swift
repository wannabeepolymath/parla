import Combine
import Foundation
import XCTest
@testable import ParlaCore
@testable import Parla

/// Uses the G2a physical store and trust/process/transport bottoms. Initial ready
/// always comes from actual saved controls → Install → joined Prepare → receipt.
@MainActor final class ParakeetOriginIntegrationTests: XCTestCase {
    private let audio = (0..<8000).map { Float(sin(Double($0) * 0.05)) * 0.5 }

    func testSavedControlsRetryKnownPartialHashFailureWithoutEnablingPrepareOrInstall() async throws {
        for profile in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }; r.settings.recognitionEngine = .whisper
            let hub = try r.hub(); ParakeetAudioEntry.reconcile(r.settings, valid: true, owner: r.owner); await r.wait()
            let id: ParakeetPreparation.TargetID
            if profile {
                var value = DictationProfile(); value.name = "retry profile"; value.target = "com.g2b.retry"; value.recognitionEngine = .parakeet
                XCTAssertTrue(hub.saveProfile(value)); id = .profile(value.id)
            } else { hub.settings.recognitionEngine = .parakeet; id = .global }
            hub.flushPendingSave()
            await r.transport.configure(corrupt: 2)
            hub.parakeetAction(.install, target: try XCTUnwrap(hub.parakeetTarget(id))); await r.wait()
            let interrupted = try r.record(), state = hub.parakeetControlSnapshot(id)
            XCTAssertEqual(interrupted.stage, .installing); XCTAssertEqual(interrupted.completed.count, 1)
            XCTAssertEqual(state.refusal, .integrity); XCTAssertTrue(r.owner.snapshot.canRetry)
            XCTAssertFalse(state.canInstall); XCTAssertFalse(state.canPrepare)
            XCTAssertTrue(state.canRetry, "Known transaction must expose its safe explicit Retry")
            guard state.canRetry else { continue } // The actual disabled button cannot invoke its callback.
            await r.transport.configure()
            hub.parakeetAction(.retry, target: try XCTUnwrap(hub.parakeetTarget(id))); await r.wait()
            XCTAssertEqual(r.owner.snapshot.phase, .installed); XCTAssertNil(try r.record().prepared)
            XCTAssertEqual(try r.record().generation, interrupted.generation)
            XCTAssertEqual(try r.record().completed.count, 21)
            g2bEqual(await r.transport.requests.count, 22) // One completed file reused; interrupted file fetched again.
            XCTAssertEqual(r.bottoms.count, 0)
        }
    }

    func testProfileDraftKeepsProspectiveChoiceButRevokesSavedActionAuthority() async throws {
        for existing in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }; r.settings.recognitionEngine = .whisper
            let hub = try r.hub(); ParakeetAudioEntry.reconcile(r.settings, valid: true, owner: r.owner); await r.wait()
            var draft = DictationProfile(); draft.name = "initial"; draft.target = "com.g2b.initial"
            if existing { XCTAssertTrue(hub.saveProfile(draft)); hub.flushPendingSave() }
            XCTAssertNil(hub.parakeetProfileChoiceRefusal)
            let stale = try XCTUnwrap(hub.parakeetTarget(.global)), before = await r.hooks.visited
            draft.name = "edited name"; hub.onParakeetDraftChanged() // ProfileEditor's actual onChange callback.
            XCTAssertNil(hub.parakeetProfileChoiceRefusal)
            draft.target = "com.g2b.edited"; hub.onParakeetDraftChanged()
            XCTAssertNil(hub.parakeetProfileChoiceRefusal)
            XCTAssertEqual(hub.parakeetChoiceRefusal, .configuration)
            XCTAssertNil(hub.parakeetTarget(.global))
            draft.recognitionEngine = .parakeet; hub.onParakeetDraftChanged()
            hub.parakeetAction(.install, target: stale); await r.wait()
            g2bEqual(await r.transport.requests.count, 0); g2bEqual(await r.hooks.visited, before)
            XCTAssertEqual(r.bottoms.count, 0)
            r.releasePresent = false
            XCTAssertEqual(hub.parakeetProfileChoiceRefusal, .releaseIntegrity)
            r.releasePresent = true; hub.saveError = "synthetic save failure"
            XCTAssertEqual(hub.parakeetProfileChoiceRefusal, .configuration)
            hub.saveError = nil
            XCTAssertTrue(hub.saveProfile(draft, replacing: existing ? 0 : nil)); hub.flushPendingSave()
            XCTAssertEqual(hub.parakeetTarget(.profile(draft.id))?.selection.engine, .parakeet)
        }
    }

    private func savedControls(_ r: G2aRig, profile: Bool = false) async throws -> (HubModel, ParakeetPreparation.TargetID) {
        r.settings.recognitionEngine = .whisper
        let hub = try r.hub()
        ParakeetAudioEntry.reconcile(r.settings, valid: true, owner: r.owner)
        await r.wait()
        XCTAssertNil(hub.parakeetChoiceRefusal, "A real Install attempt is meaningful before ready")
        let id: ParakeetPreparation.TargetID
        if profile {
            var value = DictationProfile(); value.name = "PRIVATE_PROFILE"; value.target = "com.g2b.editor"
            value.recognitionEngine = .parakeet; value.parakeetLanguageFilter = "none"
            XCTAssertTrue(hub.saveProfile(value))
            id = .profile(value.id)
            XCTAssertNil(hub.parakeetTarget(id), "Draft/saveProfile Bool is not authority")
        } else {
            hub.settings.recognitionEngine = .parakeet; id = .global
            XCTAssertNil(hub.parakeetTarget(id))
        }
        hub.flushPendingSave()
        let target = try XCTUnwrap(hub.parakeetTarget(id))
        XCTAssertEqual(target.selection.engine, .parakeet)
        var effective = hub.store.load()
        if case .profile(let profileID) = id, let profile = effective.profiles.first(where: { $0.id == profileID }) {
            effective = ProfileResolver.resolve(effective, at: .init(bundleID: profile.target)).settings
        }
        XCTAssertEqual(r.owner.cachedRefusal(for: .init(settings: effective)), .absent)
        hub.parakeetAction(.install, target: target); await r.wait()
        XCTAssertEqual(r.owner.cachedRefusal(for: .init(settings: effective)), .needsPreparation)
        XCTAssertEqual(r.owner.snapshot.phase, .installed)
        XCTAssertEqual(try r.record().completed.count, 21); XCTAssertNil(try r.record().prepared)
        let child = G2aChild(); r.bottoms.append(child)
        hub.parakeetAction(.prepare, target: try XCTUnwrap(hub.parakeetTarget(id))); await r.wait()
        XCTAssertEqual(r.owner.snapshot.phase, .ready, r.owner.snapshot.message)
        XCTAssertEqual(try r.record().stage, .ready)
        g2bEqual(await child.native.samples, [])
        return (hub, id)
    }

    func testActualSavedGlobalAndProfileControlsRealInstallPrepareAndAllFiltersShareScope() async throws {
        for profile in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }
            let (hub, id) = try await savedControls(r, profile: profile)
            XCTAssertEqual(hub.store.load().recognitionEngine, profile ? .whisper : .parakeet)
            let scope = try XCTUnwrap(try r.record().prepared)
            let factory = r.factory()
            for filter in [Optional<String>.none] + ParakeetWire.filters.map(Optional.some) {
                var effective = hub.store.load(); effective.recognitionEngine = .parakeet; effective.parakeetLanguageFilter = filter
                let request = RecognitionRequest(settings: effective)
                XCTAssertNil(r.owner.cachedRefusal(for: request))
                var handle: RecognitionHandle? = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory)
                XCTAssertEqual(handle?.request.selection, .parakeet(model: ParakeetWire.model, filter: filter))
                XCTAssertEqual(try r.record().prepared, scope)
                XCTAssertFalse(RecognitionAcquisition.mayPromote(try XCTUnwrap(handle), global: request,
                    epoch: id == .global ? scope.installation : UUID(), currentEpoch: UUID(), current: request, factory: factory))
                handle = nil
                XCTAssertEqual(r.owner.ownership.count, 0)
            }
            XCTAssertEqual(r.bottoms.count, 1, "No filter acquisition starts a load or prepares")
            let before = await r.hooks.visited, network = await r.transport.requests.count
            let token = hub.parakeetTarget(id), cachedRequest = RecognitionRequest(settings: hub.store.load())
            let trustCount = r.bottoms.trustCount
            for _ in 0..<50 {
                _ = r.owner.choiceRefusal; _ = r.owner.cachedRefusal(for: cachedRequest)
                _ = hub.parakeetSnapshot.message; _ = hub.parakeetTarget(id)
            }
            XCTAssertEqual(r.bottoms.trustCount, trustCount)
            _ = ParakeetControls(model: hub, targetID: id).body
            XCTAssertEqual(token, hub.parakeetTarget(id), "Rendering does not mint targets")
            g2bEqual(await r.hooks.visited, before); g2bEqual(await r.transport.requests.count, network)
            XCTAssertEqual(r.bottoms.count, 1)
            // Maintenance stays reachable after removing all saved references.
            hub.settings.recognitionEngine = .whisper
            if profile { hub.settings.profiles[0].enabled = false }
            hub.flushPendingSave()
            let maintenance = hub.parakeetControlSnapshot(.global)
            XCTAssertTrue(maintenance.canDelete); XCTAssertFalse(maintenance.canPrepare); XCTAssertFalse(maintenance.canInstall)
            hub.parakeetAction(.delete, target: try XCTUnwrap(hub.parakeetTarget(.global))); await r.wait()
            XCTAssertEqual(try r.record().stage, .absent)
        }
    }

    func testQueuedActualBootstrapRestoresOnlyDurableSuccessWithoutHubHashNativeOrReplay() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        let (hub, _) = try await savedControls(r)
        r.settings = hub.store.load()
        let fresh = r.makeOwner(), held = G2aLatch(), entered = G2aLatch()
        let predecessor = PendingOperation(name: "owned predecessor")
        r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: predecessor, completes: true) {
            await entered.signal(); await held.wait()
        }
        await entered.wait()
        let hashes = await r.hooks.visited, calls = await r.transport.requests.count, launches = r.bottoms.count, trusts = r.bottoms.trustCount
        let labels = ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } })
        let composition = HubBootstrapState(shortcutLabels: labels)
        var order: [String] = [], entries = 0
        let startup = ApplicationStartupCoordinator(configure: { order.append("configure") }, reconcileSpeech: {
            order.append("reconcile"); ParakeetAudioEntry.reconcile(r.settings, valid: true, owner: fresh)
        }, register: { order.append("register") }, services: { order.append("services"); composition.updateTapStatus(.unavailable) },
            migrate: { entries += 1 }, setup: { XCTFail("no setup") }, warmMic: { XCTFail("no mic") })
        startup.bootstrap(); startup.bootstrap()
        XCTAssertEqual(order, ["configure", "reconcile", "register", "services"])
        XCTAssertEqual(fresh.reconciliation, .queued)
        let request = RecognitionRequest(settings: r.settings)
        XCTAssertEqual(ParakeetAudioEntry.capabilities(request, owner: fresh, microphone: { XCTFail(); return true }, otherEngine: { XCTFail(); return nil }), .modelUnavailable)
        XCTAssertEqual(fresh.cachedRefusal(for: request), .reconciling)
        XCTAssertNil(composition.existingHub)
        await held.signal(); await r.wait()
        XCTAssertEqual(fresh.reconciliation, .settled); XCTAssertNil(fresh.cachedRefusal(for: request))
        g2bEqual(await r.hooks.visited, hashes, "Passive reconciliation does no payload hashing")
        g2bEqual(await r.transport.requests.count, calls); XCTAssertEqual(r.bottoms.count, launches); XCTAssertEqual(entries, 0)
        XCTAssertNil(composition.existingHub); XCTAssertEqual(r.bottoms.trustCount, trusts)
        var factory = r.factory(); fresh.bindFactory(&factory)
        var handle: RecognitionHandle? = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory)
        XCTAssertNotNil(handle); handle = nil; XCTAssertEqual(fresh.ownership.count, 0)
    }

    func testClosedHostAuthorityAndInvalidRequestAreFiniteAndNeverEnterOtherEngine() async throws {
        for host in [ParakeetHostEligibility.unknown, .unsupported, .supported] {
            let r = try G2aRig(); defer { r.cleanup() }; r.hostEligibility = host
            let owner = r.makeOwner(closed: host == .supported)
            ParakeetAudioEntry.reconcile(r.settings, valid: true, owner: owner); await r.wait()
            let expected: ParakeetInstallationRefusal = host == .supported ? .releaseIntegrity : .unsupportedHost
            XCTAssertEqual(owner.cachedRefusal(for: .init(settings: r.settings)), expected)
            XCTAssertEqual(owner.choiceRefusal, expected)
            XCTAssertEqual(ParakeetAudioEntry.tryout(.init(settings: r.settings), owner: owner, otherEngine: { XCTFail(); return nil }), expected.message)
            g2bTrue(await r.transport.requests.isEmpty); g2bTrue(await r.hooks.visited.isEmpty)
            XCTAssertEqual(r.bottoms.count, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: r.namespace.path))
            var invalid = r.settings; invalid.parakeetLanguageFilter = "PRIVATE_INVALID_FILTER"
            XCTAssertEqual(owner.cachedRefusal(for: .init(settings: invalid)), .configuration)
            XCTAssertFalse(owner.snapshot.message.contains("PRIVATE_INVALID_FILTER"))
            var whisper = r.settings; whisper.recognitionEngine = .whisper
            XCTAssertNil(owner.cachedRefusal(for: .init(settings: whisper)))
        }
    }

    func testSavedTargetHeldPrepareRevokesOnDraftRemovalReorderInheritanceAndSaveError() async throws {
        for change in ["unchanged", "draft", "remove", "disable", "reorder", "filter", "inherit", "saveError"] {
            let r = try G2aRig(); defer { r.cleanup() }
            r.settings.recognitionEngine = .whisper
            var profile = DictationProfile(); profile.name = "PRIVATE"; profile.target = "com.g2b.target"; profile.recognitionEngine = .parakeet
            var other = profile; other.id = UUID(); other.target = "com.g2b.other"
            r.settings.profiles = [profile, other]
            let hub = try r.hub(), id = ParakeetPreparation.TargetID.profile(profile.id)
            hub.parakeetAction(.install, target: try XCTUnwrap(hub.parakeetTarget(id))); await r.wait()
            let child = G2aChild()
            await r.hooks.arm(.receipt); r.bottoms.append(child)
            let target = try XCTUnwrap(hub.parakeetTarget(id))
            hub.parakeetAction(.prepare, target: target); await r.hooks.entered.wait()
            XCTAssertNotEqual(hub.parakeetSnapshot.token, target.admissionToken)
            switch change {
            case "draft": hub.onParakeetDraftChanged()
            case "saveError": hub.saveError = "PRIVATE_SAVE_FAILURE"
            case "unchanged": r.owner.configure(hub.store.load())
            default:
                var saved = hub.store.load()
                switch change {
                case "remove": saved.profiles.removeFirst()
                case "disable": saved.profiles[0].enabled = false
                case "reorder": saved.profiles.swapAt(0, 1)
                case "filter": saved.profiles[0].parakeetLanguageFilter = "fr"
                default: saved.profiles[0].recognitionEngine = nil
                }
                try hub.store.save(saved); hub.refreshPreparationConfiguration()
            }
            await r.hooks.released.signal(); await r.wait()
            XCTAssertEqual(try r.record().prepared != nil, change == "unchanged", change)
            XCTAssertEqual(r.owner.snapshot.phase == .ready, change == "unchanged", change)
            if change == "unchanged" { XCTAssertNil(r.owner.cachedRefusal(for: .init(settings: ProfileResolver.resolve(r.settings, at: .init(bundleID: profile.target)).settings))) }
            else { hub.parakeetAction(.prepare, target: target); await r.wait(); XCTAssertEqual(r.bottoms.count, 1) }
        }
    }

    func testProfileInheritanceNoneFixedFiltersAndHostWinnerRemainFrozen() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        let (hub, _) = try await savedControls(r, profile: true)
        var settings = hub.store.load(); settings.parakeetLanguageFilter = "pl"
        var app = try XCTUnwrap(settings.profiles.first); app.target = "com.apple.Safari"
        var host = app; host.id = UUID(); host.name = "host"; host.targetKind = .host; host.target = "example.test"; host.parakeetLanguageFilter = "fr"
        settings.profiles = [app, host]
        let destination = ProfileDestination(bundleID: "com.apple.Safari", browserURL: "https://example.test/private")
        XCTAssertNil(ParakeetAudioEntry.physical(settings, destination: destination, owner: r.owner))
        let machine = DictationSession()
        _ = machine.handle(.startDictation(settings: settings, cleanupConfigured: false, live: false, recognitionDestination: destination))
        guard case .starting(let session) = machine.state else { return XCTFail() }
        XCTAssertEqual(session.recognition.selection, .parakeet(model: ParakeetWire.model, filter: "fr"))
        for filter in [Optional<String>.none, "none"] + ParakeetWire.filters.map(Optional.some) {
            settings.profiles = [app]; settings.profiles[0].parakeetLanguageFilter = filter
            let effective = ProfileResolver.resolve(settings, at: .init(bundleID: app.target)).settings
            XCTAssertEqual(effective.parakeetLanguageFilter, filter == "none" ? nil : filter ?? "pl")
            XCTAssertEqual(effective.parakeetModelID, ParakeetWire.model)
        }
        settings.recognitionEngine = .parakeet; settings.profiles[0].recognitionEngine = nil; settings.profiles[0].language = "en"
        XCTAssertEqual(RecognitionRequest(settings: ProfileResolver.resolve(settings, at: .init(bundleID: app.target)).settings).selection, .invalid)
        settings.recognitionEngine = .whisper
        XCTAssertEqual(session.recognition.selection, .parakeet(model: ParakeetWire.model, filter: "fr"), "Later output settings cannot change ASR")
    }

    func testAllPhysicalAudioModesUseRealFinalizerFactoryWorkerAndOriginalPCM() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, _) = try await savedControls(r)
        for mode in 0..<4 { // raw, cleanup, spoken command, dictated preset
            var saved = hub.store.load(); saved.cleanupEnabled = mode != 0; saved.recoveryAudioEnabled = false; saved.outputMode = mode == 3 ? .selectedPreset : mode == 0 ? .raw : .cleanup
            try hub.store.save(saved)
            let preset = TransformPreset(name: "PRIVATE_PRESET", instruction: "Rewrite")
            saved.transformPresets = [preset]; saved.selectedPresetID = preset.id
            let destination = ProfileDestination(bundleID: "com.g2b.editor")
            XCTAssertNil(ParakeetAudioEntry.physical(saved, destination: destination, owner: r.owner))
            let machine = DictationSession(), provider = AutomationProvider()
            _ = machine.handle(mode == 2 ? .startCommand(settings: saved, cleanupConfigured: true, focus: .editable, selection: "PRIVATE_SELECTION")
                : .startDictation(settings: saved, cleanupConfigured: mode != 0, live: false, recognitionDestination: destination))
            guard case .starting(let session) = machine.state else { return XCTFail() }
            let child = G2aChild(text: "PRIVATE_AUDIO_TEXT"); r.bottoms.append(child)
            let factory = ParakeetAudioEntry.factory(owner: r.owner, bottom: r.factory())
            let previewController = CanceledCaptureUndoController(configuration: { saved }, generation: { 1 }, security: { .safe }, now: { 100 }, schedule: { _, _ in {} }, copy: { _ in XCTFail() })
            let dispatcher = DictationExecutionDispatcher(makePreview: { CanceledCaptureRecognition(controller: previewController,
                factory: { XCTFail("Ordinary audio must not construct B57/Whisper factory"); return RecognitionFactory() }()) }, ordinary: { _, _, _ in
                do {
            if mode == 2 {
                let handle = try await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: factory, operation: session.operation)
                let text = await DictationProcessing.command(operation: session.operation, handle: handle, samples: self.audio)
                XCTAssertEqual(text, "PRIVATE_AUDIO_TEXT")
                g2bEqual(try await session.transform(instruction: XCTUnwrap(text)) { _ in provider }, provider.text)
            } else {
                let recordings = RecordingStore(directory: r.root.appendingPathComponent("audio-\(mode)"), writer: { _, _ in XCTFail("Audio storage disabled") })
                let finalizer = OrdinaryDictationFinalization(recordings: recordings, settings: hub.store)
                var completed = false
                await finalizer.run(operation: session.operation, samples: self.audio, window: nil, prepare: { _, _ in
                    try! await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: factory, operation: session.operation)
                }, recognized: { handle, raw in
                    XCTAssertEqual(handle.request, session.recognition); finalizer.resolve(transcript: raw, secure: false); return raw
                }, clean: { raw in
                    await Pipeline(outputSettings: session.effectiveSettings, bundleID: nil) { _ in provider }.clean(transcript: raw)
                }, completed: { _, text, failure in
                    XCTAssertNil(failure); XCTAssertEqual(text, mode == 0 ? "PRIVATE_AUDIO_TEXT" : provider.text); completed = true
                })
                XCTAssertTrue(completed)
            }
                } catch { XCTFail("Actual ordinary origin refused: \(type(of: error))") }
            })
            r.chain = dispatcher.enqueue(.ordinary(session, samples: audio, ledger: ""), previous: r.chain)
            await r.wait()
            g2bEqual(await child.native.samples, audio)
            XCTAssertEqual(r.owner.ownership.count, 0)
            XCTAssertEqual(provider.calls, mode == 0 ? 0 : 1)
        }
        XCTAssertEqual(r.bottoms.count, 5, "One explicit load check and one fresh helper per origin")
    }

    func testAutomationBrokerActualCapabilitiesFrozenGlobalsResultOnlyAndFactoryRace() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, _) = try await savedControls(r)
        for race in [false, true] {
            let rig = AutomationRig(); rig.settings = hub.store.load(); rig.settings.automationEnabled = true; rig.settings.outputMode = .raw
            var override = DictationProfile(); override.name = "excluded"; override.target = "com.unrelated.app"; override.recognitionEngine = .whisper
            rig.settings.profiles = [override]
            rig.recognitionEntry = { ParakeetAudioEntry.deliberate($0, owner: r.owner) }
            rig.recognitionCapability = { ParakeetAudioEntry.capabilities($0, owner: r.owner, microphone: { true }, otherEngine: { XCTFail("other engine"); return nil }) }
            rig.foundationFactory = r.factory(); rig.register()
            let started = try await rig.start(), session = try XCTUnwrap(rig.accepted)
            XCTAssertTrue(session.settings.profiles.isEmpty); XCTAssertFalse(session.settings.streamPreviewEnabled)
            XCTAssertEqual(session.recognition.selection.engine, .parakeet)
            rig.send(.stopRequested)
            if race {
                r.productPresent = false
                do { _ = try await RecognitionAcquisition.acquire(request: session.recognition, resident: nil, factory: r.factory(), operation: session.operation); XCTFail() }
                catch { rig.send(.legUnavailable(session, message: (error as? ParakeetInstallationRefusal)?.message ?? "unavailable")) }
                rig.send(.operationFinished(session.operation)); r.productPresent = true
                let result = await rig.broker.stop(sessionID: started.sessionID)
                XCTAssertEqual(result, .failure(.unavailable)); XCTAssertNil(rig.results.read())
            } else {
                r.bottoms.append(G2aChild(text: "PRIVATE_AUTOMATION")); await rig.run(session).value
                let result = try await rig.broker.stop(sessionID: started.sessionID).get()
                XCTAssertEqual(result.text, "PRIVATE_AUTOMATION"); XCTAssertEqual(rig.results.read()?.text, "PRIVATE_AUTOMATION")
            }
            XCTAssertTrue(rig.insertions.isEmpty); XCTAssertEqual(rig.broker.waiterCount, 0)
        }
    }

    func testAutomationRefusalHasNoMigrationMicCaptureAndOutputGuardsPrecedeReopening() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let rig = AutomationRig()
        rig.settings = r.settings; rig.settings.automationEnabled = true
        var entries = 0
        rig.recognitionEntry = { request in entries += 1; ParakeetAudioEntry.deliberate(request, owner: r.owner) }
        rig.recognitionCapability = { ParakeetAudioEntry.capabilities($0, owner: r.owner, microphone: { XCTFail(); return true }, otherEngine: { XCTFail(); return nil }) }
        rig.register()
        rig.settings.outputMode = .selectedPreset
        g2bEqual(await rig.broker.start(requestID: rig.request()), .failure(.unsupportedOutputMode)); XCTAssertEqual(entries, 0)
        rig.settings.outputMode = .raw; rig.secure = true
        g2bEqual(await rig.broker.start(requestID: rig.request()), .failure(.secure)); XCTAssertEqual(entries, 0)
        rig.secure = false
        g2bEqual(await rig.broker.start(requestID: rig.request()), .failure(.modelUnavailable)); XCTAssertEqual(entries, 1)
        XCTAssertEqual(rig.captures, 0); XCTAssertEqual(rig.entries, 0); XCTAssertEqual(r.bottoms.count, 0)
        g2bTrue(await r.transport.requests.isEmpty)
    }

    func testTryoutSuppliedAndNilOperationsActualQueueHeldAllIOAndNoLateDisplay() async throws {
        for cancel in [false, true] {
            let r = try G2aRig(); defer { r.cleanup() }; let (hub, _) = try await savedControls(r)
            let request = RecognitionRequest(settings: hub.store.load()), operation = PendingOperation(name: "tryout")
            XCTAssertNil(ParakeetAudioEntry.tryout(request, owner: r.owner, otherEngine: { XCTFail(); return nil }))
            let joined = G2aLatch(), release = G2aLatch(), child = G2aChild(join: release, joined: joined, text: "PRIVATE_TRYOUT")
            r.bottoms.append(child)
            var displayed: [String] = [], exited = false
            r.chain = RecognitionAcquisition.enqueueTryout(previous: r.chain, operation: operation, work: {
                await RecognitionAcquisition.tryout(samples: self.audio, request: request, resident: nil, factory: r.factory(), operation: operation)
            }, current: { !cancel || !operation.shouldAbort }, done: { displayed.append($0) }, finished: { exited = true })
            await joined.wait()
            XCTAssertFalse(exited); XCTAssertTrue(displayed.isEmpty); XCTAssertEqual(r.owner.ownership.count, 1)
            if cancel { operation.revoke(); operation.requestAbort() }
            await release.signal(); await r.wait()
            XCTAssertTrue(exited); XCTAssertTrue(operation.hasExited)
            XCTAssertEqual(displayed, cancel ? [] : ["PRIVATE_TRYOUT"]); XCTAssertEqual(r.owner.ownership.count, 0)
            // Existing compatibility: nil operation is still a counted/revocable real use.
            let native = G2aChild(text: "nil operation"); r.bottoms.append(native)
            g2bEqual(await RecognitionAcquisition.tryout(samples: audio, request: request, resident: nil, factory: r.factory()), "nil operation")
            let before = r.bottoms.count, hashes = await r.hooks.visited.count
            g2bEqual(await RecognitionAcquisition.tryout(samples: [0.2], request: request, resident: nil, factory: r.factory(), operation: PendingOperation(name: "short")), "")
            XCTAssertEqual(r.bottoms.count, before)
            g2bGreater(await r.hooks.visited.count, hashes, "Existing acquisition-before-floor policy")
        }
    }

    func testRecoveryActualHubCallbackGlobalSourceLeaseFloorAndExplicitPreviewSave() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        var writerEntered = false, writerError = false
        r.audioWriter = { samples, url in
            writerEntered = true
            do { try RecordingStore.writeWAV(samples, to: url) } catch { writerError = true; throw error }
        }
        let (hub, _) = try await savedControls(r)
        var settings = hub.store.load(); settings.recoveryAudioEnabled = true; settings.historyEnabled = true
        try hub.store.save(settings)
        let recordings = hub.recordings
        let source = try XCTUnwrap(recordings.stash(audio, settings: hub.store), "writer entered: \(writerEntered), threw: \(writerError); " + (recordings.lastError ?? "No audio error"))
        recordings.resolve(source, transcript: nil, secure: false)
        let request = RecognitionRequest(settings: settings), child = G2aChild(text: "PRIVATE_RECOVERY")
        r.bottoms.append(child)
        var entries = 0
        var sourceLease: RecordingStore.Lease?
        var sourcePCM: [Float] = []
        hub.onRecoveryTranscribe = { lease, frozen, done in
            sourceLease = lease
            sourcePCM = (try? recordings.samples(lease)) ?? []
            r.chain = RecoveryTranscription.enqueue(previous: r.chain, recordings: recordings, lease: lease, request: frozen,
                authorize: { recordings.refreshPolicy(from: hub.store) }, enter: {
                    try await MainActor.run {
                        entries += 1; try ParakeetAudioEntry.recovery(frozen, owner: r.owner)
                    }
                }, load: { try await RecognitionAcquisition.acquire(request: $0, resident: nil, factory: r.factory(), operation: lease.operation) }, done: done)
        }
        hub.transcribeRecovery(source); await r.wait()
        XCTAssertEqual(hub.recoveryPreview?.request, request); XCTAssertEqual(hub.recoveryPreview?.entry?.raw, "PRIVATE_RECOVERY")
        XCTAssertFalse(hub.recoveryPreview?.saved ?? true); XCTAssertTrue(hub.history.entries.isEmpty)
        XCTAssertEqual(entries, 1)
        let received = await child.native.samples
        XCTAssertEqual(received.count, sourcePCM.count)
        XCTAssertTrue(zip(received, sourcePCM).allSatisfy { $0.bitPattern == $1.bitPattern })
        hub.saveRecovery(); XCTAssertEqual(hub.history.entries.first?.raw, "PRIVATE_RECOVERY")
        let operation = PendingOperation(name: "short recovery")
        do {
            _ = try await RecoveryTranscription.batch(request: request, operation: operation, samples: { [0.2] }, validate: {}, active: { true }, authorize: { true }, enter: { XCTFail("floor first") }, load: { _ in XCTFail("floor first"); throw CancellationError() })
            XCTFail()
        } catch { XCTAssertTrue(error is RecordingStore.Failure) }
        XCTAssertEqual(entries, 1); hub.discardRecovery()
        let second = try XCTUnwrap(recordings.stash(audio, settings: hub.store))
        recordings.resolve(second, transcript: nil, secure: false)
        let joined = G2aLatch(), released = G2aLatch()
        r.bottoms.append(G2aChild(join: released, joined: joined, text: "PRIVATE_LATE_RECOVERY"))
        hub.transcribeRecovery(second); await joined.wait()
        let retained = try XCTUnwrap(sourceLease)
        XCTAssertTrue(recordings.isActive(retained)); XCTAssertEqual(r.owner.ownership.count, 1)
        hub.discardRecovery()
        XCTAssertFalse(recordings.isActive(retained)); XCTAssertNil(hub.recoveryPreview)
        XCTAssertEqual(r.owner.ownership.count, 1, "Source lease and installation pin are independent")
        await released.signal(); await r.wait()
        XCTAssertNil(hub.recoveryPreview); XCTAssertEqual(r.owner.ownership.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "Canceled recovery preserves the original")
    }

    func testCanceledQuitPureQueriesCannotReopenAndNewQuitDefeatsOldTarget() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, id) = try await savedControls(r)
        let request = RecognitionRequest(settings: hub.store.load())
        let drained = expectation(description: "quit A")
        r.owner.beginShutdown(chain: { r.chain }) { _ in drained.fulfill() }
        r.owner.cancelShutdown(); await fulfillment(of: [drained], timeout: 3)
        XCTAssertTrue(r.owner.canDeliberatelyEnter); XCTAssertTrue(r.owner.snapshot.canPrepare)
        for _ in 0..<10 { _ = r.owner.cachedRefusal(for: request); _ = r.owner.choiceRefusal }
        r.owner.reconcileOnce(); r.owner.configure(hub.store.load())
        r.owner.act(.recheck, token: r.owner.snapshot.token); await r.wait()
        XCTAssertTrue(r.owner.admissionClosed)
        ParakeetAudioEntry.deliberate(request, owner: r.owner)
        XCTAssertFalse(r.owner.admissionClosed); XCTAssertEqual(r.owner.cachedRefusal(for: request), .needsPreparation)
        // No implicit Recheck or Prepare restored readiness.
        let old = try XCTUnwrap(hub.parakeetTarget(id))
        let second = expectation(description: "quit B")
        r.owner.beginShutdown(chain: { r.chain }) { _ in second.fulfill() }
        hub.parakeetAction(.prepare, target: old)
        ParakeetAudioEntry.deliberate(request, owner: r.owner)
        await fulfillment(of: [second], timeout: 3)
        XCTAssertTrue(r.owner.admissionClosed); XCTAssertFalse(r.owner.canDeliberatelyEnter); XCTAssertEqual(r.bottoms.count, 1)
    }

    func testActualSaveFailureCannotGrantDraftTargetOrPublishHeldReceipt() async throws {
        let r = try G2aRig(); defer { r.cleanup() }
        var failWrite = false
        let hub = try r.hub(atomicWrite: { data, url in
            if failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        hub.parakeetAction(.install, target: try XCTUnwrap(hub.parakeetTarget(.global))); await r.wait()
        let before = try Data(contentsOf: hub.store.url), target = try XCTUnwrap(hub.parakeetTarget(.global))
        await r.hooks.arm(.receipt); r.bottoms.append(G2aChild())
        hub.parakeetAction(.prepare, target: target); await r.hooks.entered.wait()
        failWrite = true; hub.settings.parakeetLanguageFilter = "fr"; hub.flushPendingSave()
        XCTAssertNotNil(hub.saveError); XCTAssertNil(hub.parakeetTarget(.global))
        XCTAssertEqual(try Data(contentsOf: hub.store.url), before)
        await r.hooks.released.signal(); await r.wait()
        XCTAssertNil(try r.record().prepared); XCTAssertNotEqual(r.owner.snapshot.phase, .ready)
        hub.parakeetAction(.prepare, target: target); await r.wait(); XCTAssertEqual(r.bottoms.count, 1)
    }

    func testTryoutActualQuitClipboardFailureWaitsForAllIOAndPreservesIndependentRestartLeaves() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, _) = try await savedControls(r)
        let operation = PendingOperation(name: "held actual tryout"), request = RecognitionRequest(settings: hub.store.load())
        let entered = G2aLatch(), released = G2aLatch(), child = G2aChild(join: released, joined: entered, text: "PRIVATE_LATE")
        r.bottoms.append(child)
        var displayed = false
        r.chain = RecognitionAcquisition.enqueueTryout(previous: r.chain, operation: operation, work: {
            await RecognitionAcquisition.tryout(samples: self.audio, request: request, resident: nil, factory: r.factory(), operation: operation)
        }, current: { true }, done: { _ in displayed = true }, finished: {})
        await entered.wait()
        var clipboard: ((Bool) -> Void)?, replies: [Bool] = [], failures = 0
        let replied = expectation(description: "one composed reply"), drained = expectation(description: "actual leaf drain")
        let coordinator = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: { $0(true) },
            parakeet: { reply in r.owner.beginShutdown(chain: { r.chain }) { reply($0); drained.fulfill() } }, cancelParakeet: { r.owner.cancelShutdown() },
            cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); replied.fulfill() }, failure: { failures += 1 })
        XCTAssertEqual(coordinator.request(), .terminateLater)
        XCTAssertTrue(replies.isEmpty); XCTAssertEqual(r.owner.ownership.count, 1)
        XCTAssertFalse(r.owner.reserveRestart()); XCTAssertFalse(r.owner.canDeliberatelyEnter)
        operation.revoke(); operation.requestAbort()
        await released.signal(); await r.wait()
        XCTAssertFalse(displayed); XCTAssertEqual(r.owner.ownership.count, 0); XCTAssertTrue(replies.isEmpty)
        clipboard?(false); await fulfillment(of: [replied, drained], timeout: 3)
        XCTAssertEqual(replies, [false]); XCTAssertEqual(failures, 1); XCTAssertTrue(r.owner.admissionClosed)
        XCTAssertFalse(r.owner.reserveRestart(), "An independent quit leaf stays closed")
        ParakeetAudioEntry.deliberate(request, owner: r.owner)
        XCTAssertFalse(r.owner.admissionClosed); XCTAssertEqual(r.owner.cachedRefusal(for: request), .needsPreparation)
        XCTAssertTrue(r.owner.reserveRestart()); r.owner.releaseRestart(); XCTAssertFalse(r.owner.admissionClosed)
        XCTAssertEqual(r.bottoms.count, 2)
    }

    func testQueuedReconciliationQuitAThenBHasNoReplayOrStaleReopening() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, _) = try await savedControls(r)
        let saved = hub.store.load(), fresh = r.makeOwner(), held = G2aLatch(), entered = G2aLatch()
        r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: PendingOperation(name: "startup predecessor"), completes: true) {
            await entered.signal(); await held.wait()
        }
        await entered.wait()
        let hashes = await r.hooks.visited, trusts = r.bottoms.trustCount, launches = r.bottoms.count
        ParakeetAudioEntry.reconcile(saved, valid: true, owner: fresh)
        XCTAssertEqual(fresh.reconciliation, .queued)
        let first = expectation(description: "old quit leaf"), second = expectation(description: "new quit leaf")
        fresh.beginShutdown(chain: { r.chain }) { allowed in XCTAssertFalse(allowed); first.fulfill() }
        fresh.cancelShutdown()
        ParakeetAudioEntry.deliberate(.init(settings: saved), owner: fresh)
        XCTAssertTrue(fresh.admissionClosed); XCTAssertFalse(fresh.canDeliberatelyEnter)
        fresh.beginShutdown(chain: { r.chain }) { allowed in XCTAssertTrue(allowed); second.fulfill() }
        await held.signal(); await r.wait(); await fulfillment(of: [first, second], timeout: 3)
        ParakeetAudioEntry.deliberate(.init(settings: saved), owner: fresh)
        XCTAssertTrue(fresh.admissionClosed); XCTAssertEqual(fresh.reconciliation, .settled)
        XCTAssertEqual(fresh.cachedRefusal(for: .init(settings: saved)), .closed)
        g2bEqual(await r.hooks.visited, hashes); XCTAssertEqual(r.bottoms.trustCount, trusts); XCTAssertEqual(r.bottoms.count, launches)
        XCTAssertEqual(try r.record().stage, .ready, "Closing cache does not rewrite genuine durable evidence")
    }

    func testActualHubSavedGlobalAndProfileFixedDomainRoundtripsWithoutASR() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; r.settings.recognitionEngine = .whisper
        let hub = try r.hub(); ParakeetAudioEntry.reconcile(r.settings, valid: true, owner: r.owner); await r.wait()
        hub.settings.recognitionEngine = .parakeet; hub.flushPendingSave()
        for filter in [Optional<String>.none] + ParakeetWire.filters.sorted().map(Optional.some) {
            hub.settings.parakeetLanguageFilter = filter; hub.flushPendingSave()
            XCTAssertEqual(hub.store.load().parakeetLanguageFilter, filter)
            XCTAssertEqual(hub.parakeetTarget(.global)?.selection, .parakeet(model: ParakeetWire.model, filter: filter))
        }
        hub.settings.parakeetLanguageFilter = "pl"; hub.flushPendingSave()
        var profile = DictationProfile(); profile.name = "PRIVATE_FIXED_DOMAIN"; profile.target = "com.g2b.saved"
        XCTAssertTrue(hub.saveProfile(profile)); hub.flushPendingSave()
        for model in [Optional<String>.none, ParakeetWire.model] {
            for filter in [Optional<String>.none, "none"] + ParakeetWire.filters.sorted().map(Optional.some) {
                profile.parakeetModelID = model; profile.parakeetLanguageFilter = filter
                XCTAssertTrue(hub.saveProfile(profile, replacing: 0)); hub.flushPendingSave()
                let saved = try XCTUnwrap(hub.store.load().profiles.first)
                XCTAssertEqual(saved.parakeetModelID, model); XCTAssertEqual(saved.parakeetLanguageFilter, filter)
                XCTAssertEqual(hub.parakeetTarget(.profile(profile.id))?.selection,
                    .parakeet(model: ParakeetWire.model, filter: filter == "none" ? nil : filter ?? "pl"))
            }
        }
        XCTAssertEqual(r.bottoms.count, 0); g2bTrue(await r.transport.requests.isEmpty)
    }

    func testUnknownTrackingSurvivesCachedRefreshAndChangedAuthorityNeverAdvertisesReady() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, id) = try await savedControls(r)
        let token = try XCTUnwrap(hub.parakeetTarget(id)), before = r.bottoms.trustCount
        r.productPresent = false
        let state = hub.parakeetControlSnapshot(id)
        XCTAssertEqual(state.refusal, .trustedProduct); XCTAssertFalse(state.canPrepare)
        XCTAssertEqual(hub.parakeetTarget(id), token); XCTAssertEqual(r.bottoms.trustCount, before)
        r.productPresent = true
        let corrupt = Data("PRIVATE_CORRUPT_TRACKING".utf8), path = r.namespace.appendingPathComponent("record.json")
        try corrupt.write(to: path)
        let fresh = r.makeOwner(); ParakeetAudioEntry.reconcile(hub.store.load(), valid: true, owner: fresh); await r.wait()
        for _ in 0..<3 { fresh.configure(hub.store.load()) }
        XCTAssertEqual(fresh.choiceRefusal, .storage)
        XCTAssertEqual(fresh.cachedRefusal(for: .init(settings: hub.store.load())), .storage)
        XCTAssertFalse(fresh.snapshot.canInstall); XCTAssertFalse(fresh.snapshot.canPrepare)
        XCTAssertFalse(fresh.controlSnapshot(for: .global).canRetry)
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
    }

    func testTextOnlyAndB57ReadOnlyCatalogNeverReachPreparationLeaseOrReopen() async throws {
        let r = try G2aRig(); defer { r.cleanup() }; let (hub, _) = try await savedControls(r)
        var settings = hub.store.load(); settings.outputMode = .raw; settings.cleanupEnabled = false; settings.canceledCaptureUndoEnabled = true
        let request = RecognitionRequest(settings: settings), before = await r.hooks.visited
        let controller = CanceledCaptureUndoController(configuration: { settings }, generation: { 1 }, security: { .safe }, now: { 100 }, schedule: { _, _ in {} }, copy: { _ in XCTFail() })
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: false, live: false)
        controller.accepted(session, physical: true)
        XCTAssertEqual(controller.view, .empty)
        do { _ = try await r.factory().acquire(request: request, policy: .readOnlyCatalog); XCTFail() }
        catch { XCTAssertEqual(error as? ParakeetRefusal, .configuration) }
        let eval = EvalRecognition()
        try await eval.acquire(needsASR: false, request: { XCTFail("No-ASR must not request settings"); return request }, factory: r.factory())
        do { try await EvalRecognition().acquire(needsASR: true, request: { request }); XCTFail() }
        catch { XCTAssertEqual(error as? ParakeetRefusal, .needsPreparation) }
        let provider = AutomationProvider()
        let result = await Pipeline(outputSettings: settings, bundleID: nil) { _ in provider }.clean(transcript: "PRIVATE_TEXT_ONLY")
        XCTAssertEqual(result.text, "PRIVATE_TEXT_ONLY")
        // Existing selected-text preset reducer/transform path has no ASR effect.
        settings.cleanupEnabled = true
        let preset = TransformPreset(name: "PRIVATE_TEXT_PRESET", instruction: "Rewrite")
        settings.transformPresets = [preset]; settings.selectedPresetID = preset.id
        let machine = DictationSession()
        let effects = machine.handle(.startSavedPreset(settings: settings, cleanupConfigured: true, selection: "PRIVATE_SELECTION", target: .init(focus: .editable)))
        let selected = try XCTUnwrap(effects.compactMap { effect -> DictationSession.Session? in
            if case .runSavedPreset(let value) = effect { return value }; return nil
        }.first)
        XCTAssertFalse(effects.contains { if case .ensureModelLoaded = $0 { return true }; return false })
        let transformed = await DictationProcessing.transform(operation: selected.operation) {
            try await selected.transform(instruction: selected.preset?.intent ?? "") { _ in provider }
        }
        XCTAssertEqual(transformed?.text, provider.text)
        // Actual Hub history retry remains deterministic and text-only.
        settings.outputMode = .raw; settings.cleanupEnabled = false
        try hub.store.save(settings)
        let entry = HistoryEntry(raw: "PRIVATE_HISTORY_TEXT")
        XCTAssertTrue(hub.history.append(entry))
        hub.prepareHistoryRetry(entry.id); await hub.startHistoryRetry(entry.id)
        XCTAssertEqual(hub.historyRetries[entry.id]?.proposed, entry.raw)
        hub.discardHistoryRetry(entry.id)
        XCTAssertEqual(r.owner.ownership.count, 0); g2bEqual(await r.hooks.visited, before); XCTAssertEqual(r.bottoms.count, 1)
    }
}

private func g2bEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs, rhs, message, file: file, line: line)
}
private func g2bTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, message, file: file, line: line)
}
private func g2bGreater<T: Comparable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(lhs, rhs, message, file: file, line: line)
}
