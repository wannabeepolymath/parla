import AppKit
import Combine
import Foundation
import ParlaCore

/// App-only owner. Core factories used by eval/CLI never open this namespace.
final class NativePreparation: ObservableObject {
    let core: RecognitionPreparation
    @Published private(set) var snapshot = PreparationSnapshot(.off)
    private(set) var selection = UUID()
    private var target: RecognitionRequest?
    private let catalogSelection: (RecognitionRequest) -> Bool
    var enqueue: (PendingOperation, @escaping () async -> Void) -> Void = { _, _ in }
    var resident: () async -> RecognitionResident? = { nil }
    var publishResident: (RecognitionHandle) async -> Void = { _ in }
    var factory: () -> RecognitionFactory = { RecognitionFactory() }
    var onChange: (PreparationSnapshot) -> Void = { _ in }
    init(core: RecognitionPreparation, catalogSelection: @escaping (RecognitionRequest) -> Bool = {
        $0.selection.engine == .whisper && RecognitionFactory.ownedModel(path: $0.modelPath) != nil
    }) { self.core = core; self.catalogSelection = catalogSelection }
    static func application() -> NativePreparation {
        NativePreparation(core: RecognitionPreparation(storage: {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let parent = support.appendingPathComponent("Parla-preparation-health", isDirectory: true)
            // Only create our own new app namespace. Existing permissions are validated, never repaired.
            if mkdir(parent.path, 0o700) != 0, errno != EEXIST { throw PreparationRefusal.trackingUnavailable }
            return try PrivatePreparationStorage(root: parent.appendingPathComponent("v1", isDirectory: true))
        }))
    }
    func configure(_ settings: Settings, epoch: UUID) {
        selection = epoch; target = RecognitionRequest(settings: settings)
        core.configure(enabled: settings.nativePreparationSafeStartEnabled, consent: settings.nativePreparationConsent, selection: epoch)
        if settings.nativePreparationSafeStartEnabled, let target, !catalogSelection(target) { core.unsupportedSelection(target.selection) }
        refresh()
    }
    func changedSelection(_ epoch: UUID, request: RecognitionRequest) {
        selection = epoch; target = request; core.selectionChanged(epoch)
        if !catalogSelection(request) { core.unsupportedSelection(request.selection) }
        refresh()
    }
    func refresh() { snapshot = core.snapshot; onChange(snapshot) }
    func notice(_ reason: PreparationRefusal) {
        snapshot = PreparationSnapshot(core.snapshot.status, refusal: reason, token: core.snapshot.token)
        onChange(snapshot)
    }
    func revokeDraft() { core.revokeDraft(); refresh() }
    func prepareConsent(_ generation: UUID) throws { try core.prepareConsent(generation); refresh() }
    func beforeSave(_ value: Settings) throws {
        if !value.nativePreparationSafeStartEnabled, core.isEnabled, core.hasActiveEntry { throw PreparationRefusal.busy }
        if !value.nativePreparationSafeStartEnabled, core.isEnabled, core.persistenceFailed { throw PreparationRefusal.trackingUnavailable }
    }
    @MainActor func retainedResident(request: RecognitionRequest, resident: RecognitionResident?, factory: RecognitionFactory) async -> RecognitionResident? {
        guard let resident, cachedRefusal(for: request) == nil else { return nil }
        let epoch = selection, frozenTarget = target
        do {
            let handle = try await factory.acquire(request: request, resident: resident, policy: .readOnlyCatalog)
            guard selection == epoch, target == frozenTarget, handle.preparationIsCurrent else { return nil }
            return handle.resident
        } catch {
            guard selection == epoch, target == frozenTarget else { return nil }
            if let reason = error as? PreparationRefusal { notice(reason) }
            return nil
        }
    }
    var cachedRefusal: PreparationRefusal? {
        target.flatMap { cachedRefusal(for: $0) }
    }
    func cachedRefusal(for request: RecognitionRequest) -> PreparationRefusal? { request.selection.engine == .whisper ? core.cachedRefusal(for: request.selection) : nil }
    enum Action: String, CaseIterable { case keep = "Keep paused", retry = "Try loading once", reset = "Reset" }
    func act(_ action: Action, token: UUID) {
        guard snapshot.token == token else { return }
        switch action {
        case .keep: core.keep(token: token); refresh()
        case .reset:
            do { try core.reset(token: token) } catch { /* cached finite health is authoritative */ }
            refresh()
        case .retry:
            guard let target else { return }
            let epoch = selection, operation = PendingOperation(name: "Native preparation")
            do { try core.retryOnce(token: token, operation: operation, identity: factory().resolve(target)) }
            catch {
                if error as? PreparationRefusal == .unsupportedSelection, selection == epoch {
                    core.unsupportedSelection(target.selection)
                }
                refresh(); return
            }
            refresh() // invalidate the button token immediately; a double click cannot enqueue twice
            let preparationEpoch = core.admissionEpoch
            let factory = factory()
            enqueue(operation) { [self] in
                defer { core.finishRetry(operation) }
                guard !operation.shouldAbort else { return }
                do {
                    let resident = await resident()
                    let handle = try await RecognitionAcquisition.prepareOffMain(request: target, resident: resident, factory: factory,
                        operation: operation, selectionEpoch: epoch, preparationEpoch: preparationEpoch)
                    await MainActor.run { guard self.selection == epoch else { return }; self.refresh() }
                    await publishResident(handle)
                } catch { /* never resume an origin, recorder, source lease, provider or delivery */ }
                await MainActor.run { self.refresh() }
            }
        }
    }
    /// Actual coordinator participant waits the supplied stable native-exit chain. It never cancels it.
    func beginShutdown(chain: @escaping () -> Task<Void, Never>?, reply: @escaping (Bool) -> Void) {
        core.beginQuit(); refresh()
        guard core.isEnabled else { reply(true); return }
        let initial = chain()
        Task { [self] in
            var waiting = initial
            while true {
                await waiting?.value
                let next = await MainActor.run { chain() }
                if next == waiting { break }
                waiting = next
            }
            await MainActor.run { self.refresh(); reply(!self.core.hasActiveEntry && !self.core.persistenceFailed) }
        }
    }
    func cancelShutdown() { core.cancelQuit(); refresh() }
    /// Concrete updater gate, shared by the actual app and composition tests.
    /// Reservation closes preparation BEFORE awaiting; rejection releases only this reservation.
    @MainActor func claimRestart(chain: () -> Task<Void, Never>?, allowed: () -> Bool,
                                 claimOther: () -> Bool, rejected: () -> Void) async -> Bool {
        guard core.reserveRestart() else { rejected(); return false }
        let previous = chain()
        await previous?.value
        guard chain() == previous, !core.hasActiveEntry, !core.persistenceFailed, allowed(), claimOther() else {
            core.releaseRestart(); rejected(); return false
        }
        return true
    }
}

extension AppDelegate {
    func scheduleGuardedPreparation() {
        let settings = store.load(), epoch = hubModel.modelSelectionEpoch
        let request = RecognitionRequest(settings: settings), operation = PendingOperation(name: "Setup preparation")
        let preparationEpoch = nativePreparation.core.admissionEpoch
        let factory = recognitionFactory
        processTask = PendingOperationQueue.enqueue(previous: processTask, operation: operation, completes: true, work: {
            let admitted = await MainActor.run {
                !self.session.isCapturing && !self.invocation.tryoutActive && self.recorder.admission.allowsKeyboard
                    && epoch == self.hubModel.modelSelectionEpoch && request == RecognitionRequest(settings: self.store.load())
            }
            guard admitted, !operation.shouldAbort else { return }
            do {
                let resident = await MainActor.run { self.residentRecognition }
                let handle = try await RecognitionAcquisition.prepareOffMain(request: request, resident: resident, factory: factory,
                    operation: operation, selectionEpoch: epoch, preparationEpoch: preparationEpoch)
                await MainActor.run {
                    guard epoch == self.hubModel.modelSelectionEpoch, !operation.shouldAbort else { return }
                    self.publishPrepared(handle)
                }
            } catch {
                await MainActor.run {
                    guard epoch == self.hubModel.modelSelectionEpoch else { return }
                    self.nativePreparation.refresh()
                    self.hud.show(.error((error as? PreparationRefusal)?.description ?? "The speech model couldn’t load."))
                }
            }
        }, finished: { await MainActor.run { self.nativePreparation.refresh() } })
    }
    func publishPrepared(_ handle: RecognitionHandle) {
        let current = RecognitionRequest(settings: store.load())
        guard RecognitionAcquisition.mayPromote(handle, global: handle.request, epoch: preparationSelectionEpoch,
            currentEpoch: hubModel.modelSelectionEpoch, current: current, factory: recognitionFactory) else { return }
        residentRecognition = handle.resident
        modelReady = true; lastGoodModelPath = handle.request.modelPath; lastModelUse = Date()
        hubModel.observedRecognition = (handle.request.selection, handle.client.capabilities)
        hubModel.modelLoaded = true; nativePreparation.refresh(); showIdle()
    }
}

/// Token captured by the painted menu row. No panel or native model needed to test routing.
final class NativePreparationMenuRoute: NSObject {
    let action: NativePreparation.Action, token: UUID
    init(_ action: NativePreparation.Action, _ token: UUID) { self.action = action; self.token = token }
}
final class NativePreparationMenuActions: NSObject {
    private let perform: (NativePreparation.Action, UUID) -> Void
    init(perform: @escaping (NativePreparation.Action, UUID) -> Void) { self.perform = perform }
    @objc func invoke(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? NativePreparationMenuRoute else { return }
        perform(route.action, route.token)
    }
}
