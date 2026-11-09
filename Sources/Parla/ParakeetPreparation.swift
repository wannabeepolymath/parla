import Combine
import Foundation
import ParlaCore

/// Product-owned inputs. Release/terms remain closed. There is deliberately no
/// disk/settings decoder for any of these gates.
enum ParakeetHostEligibility {
    case supported, unsupported, unknown
    static var current: Self {
        #if arch(arm64)
        if #available(macOS 14, *) { return .supported }
        #endif
        return .unsupported
    }
}
struct ParakeetPreparationInputs {
    var release: () -> ParakeetDataRelease? = { nil }
    var terms: () -> ParakeetTermsApproval? = { nil }
    var product: () -> ParakeetProductIdentity? = { nil }
    var os: () -> String = { ProcessInfo.processInfo.operatingSystemVersionString }
    var host: ParakeetHostEligibility = .current
    static let closed = ParakeetPreparationInputs()
    static let application = ParakeetPreparationInputs(product: { ParakeetProductBuildInput.expected })
    func admitted() throws -> (ParakeetDataRelease, ParakeetProductIdentity, String, ParakeetTermsApproval) {
        guard host == .supported else { throw ParakeetInstallationRefusal.unsupportedHost }
        guard let release = release() else { throw ParakeetInstallationRefusal.releaseIntegrity }
        guard let terms = terms(), terms.releaseID == release.id else { throw ParakeetInstallationRefusal.terms }
        guard let product = product() else { throw ParakeetInstallationRefusal.trustedProduct }
        guard product.protocolVersion == 1, product.adapterRevision == 1, product.sdk == ParakeetWire.sdk,
              [product.helperSHA256, product.sourceSHA256].allSatisfy(ParakeetDataRelease.isSHA256),
              !product.resources.isEmpty, product.resources.count <= 512,
              product.resources.allSatisfy({ path, hash in
                  path.hasPrefix("Contents/Resources/") && path.utf8.count <= 1024 && !path.contains("\0")
                    && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
                    && ParakeetDataRelease.isSHA256(hash)
              }), !product.team.isEmpty, product.team.utf8.count <= 32,
              product.team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            throw ParakeetInstallationRefusal.trustedProduct
        }
        let os = os()
        try ParakeetWire.Identity(helperBuild: product.helperSHA256, osScope: os).validate()
        return (release, product, os, terms)
    }
}
struct ParakeetSnapshot: Equatable {
    enum Phase: String { case blocked, absent, waiting, downloading, verifying, committing, installed, loadChecking, ready, stopping, interrupted, failed, deleting }
    var phase: Phase = .blocked
    var refusal: ParakeetInstallationRefusal? = .releaseIntegrity
    var bytes: Int?
    var total: Int?
    var canInstall = false, canPrepare = false, canRecheck = false, canRetry = false, canDelete = false, canCancel = false
    var token = UUID()
    var message: String {
        if let refusal { return refusal.message }
        switch phase {
        case .ready: return "Parakeet is ready."
        case .installed: return "Parakeet is installed. Click Prepare to finish setup."
        case .downloading: return "Downloading Parakeet…"
        case .loadChecking: return "Preparing Parakeet…"
        case .stopping: return "Stopping…"
        case .blocked: return "Parakeet isn’t available."
        case .absent: return "Parakeet isn’t installed."
        case .waiting: return "Waiting…"
        case .verifying, .committing: return "Installing Parakeet…"
        case .interrupted: return "Parakeet setup was interrupted. Click Retry."
        case .failed: return "Parakeet setup failed. Click Retry."
        case .deleting: return "Deleting Parakeet…"
        }
    }
}

/// Runs on the generic executor, not the app actor. Tests replace only G1 trust
/// reads/signature/host and process IO bottoms, never a successful ready closure.
private func admitParakeetProduct(_ product: ParakeetProductIdentity, app: URL, trust: ParakeetTrustBottom) async throws -> ParakeetTrustedProduct {
    try ParakeetTrust.admit(expected: product, app: app, bottom: trust)
}

@MainActor final class ParakeetPreparation: ObservableObject {
    enum Reconciliation { case unstarted, queued, inFlight, settled }
    enum TargetID: Hashable { case global, profile(UUID) }
    struct SavedTarget: Equatable {
        let id: TargetID
        let revision: UUID
        let selection: RecognitionSelection
        let admissionToken: UUID
    }
    private(set) var reconciliation = Reconciliation.unstarted
    private var savedSettings: Settings?
    private var savedRevision = UUID()
    private var targets: [TargetID: SavedTarget] = [:]
    private var acceptedTarget: SavedTarget?
    private var readyTerms: ParakeetTermsApproval?
    enum Action: String, CaseIterable { case install = "Install", prepare = "Prepare", recheck = "Recheck", retry = "Retry", delete = "Delete" }
    typealias Enqueue = (PendingOperation, @escaping () async -> Void, @escaping () async -> Void) -> Void
    @Published private(set) var snapshot = ParakeetSnapshot()
    var enqueue: Enqueue = { operation, _, _ in operation.revoke() }
    /// Must append retirement to the same processTask lane, never mutate queued
    /// recognitionHandles on MainActor while an existing queue job uses them.
    var retireHandles: () async -> Void = {}
    let inputs: ParakeetPreparationInputs
    let storage: ParakeetInstallationStorage
    let ownership = ParakeetInstallationOwnership()
    private let worker: ParakeetWorker, trust: ParakeetTrustBottom, app: URL, clock: ParakeetClock
    private var epoch = UUID(), settingsValid = false, referenced = true
    // Draft edits revoke work, but do not invalidate the saved base for prospective editor choices.
    private var savedSettingsValid = false
    private var target: RecognitionSelection?
    private var action: (operation: PendingOperation, action: Action)?
    private var permit: ParakeetActionPermit?
    private var pendingRecheck = false, reconciled = false
    private var installed: ParakeetStoredInstallation?
    private var ready: ParakeetPreparedScope?
    private var failedAction: Action?
    private var trustRefused = false
    private var trackingFailure: ParakeetInstallationRefusal?
    private var quit: UUID?, canceledQuit: UUID?, restart: UUID?
    private var drain: Task<Void, Never>?
    private var phaseAdmitted: UInt64 = 0
    var hasWork: Bool { action != nil || ownership.count > 0 || ownership.hasWriter }
    var admissionClosed: Bool { quit != nil || restart != nil }

    init(inputs: ParakeetPreparationInputs = .closed, storage: ParakeetInstallationStorage,
         trust: ParakeetTrustBottom = .system, app: URL = Bundle.main.bundleURL,
         worker: ParakeetWorker = ParakeetWorker(), clock: ParakeetClock = ParakeetClock()) {
        self.inputs = inputs; self.storage = storage; self.trust = trust; self.app = app; self.worker = worker; self.clock = clock
    }
    static func application() -> ParakeetPreparation {
        // Constructing the service is passive. No namespace IO until admitted work.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ParakeetPreparation(inputs: .application, storage: ParakeetInstallationStorage(root: support.appendingPathComponent("Parla-parakeet-v1", isDirectory: true)))
    }
    /// This is the exact composition hook used by main and the fake-bottom tests.
    func bindFactory(_ factory: inout RecognitionFactory) {
        factory.parakeetPreparedUse = { [weak self] selection, operation in
            guard let self else { throw ParakeetInstallationRefusal.closed }
            return try await self.preparedUse(selection, operation: operation)
        }
    }
    private var gate: ParakeetInstallationRefusal? {
        do { _ = try inputs.admitted(); return nil }
        catch { return error as? ParakeetInstallationRefusal ?? .trustedProduct }
    }
    /// Cheap per-effective-request projection. No namespace, trust or native ports.
    func cachedRefusal(for request: RecognitionRequest) -> ParakeetInstallationRefusal? {
        cachedRefusal(for: request.selection)
    }
    private func cachedRefusal(for selection: RecognitionSelection) -> ParakeetInstallationRefusal? {
        if selection.engine == .invalid { return .configuration }
        guard selection.engine == .parakeet else { return nil }
        guard settingsValid else { return .configuration }
        guard !admissionClosed else { return .closed }
        guard action == nil, !ownership.hasWriter else { return reconciliation == .queued || reconciliation == .inFlight ? .reconciling : .busy }
        if let gate { return gate }
        guard reconciliation == .settled else { return .reconciling }
        if trustRefused { return .trustedProduct }
        if let refusal = trackingRefusal { return refusal }
        guard installed?.installed == true else { return .absent }
        guard let admitted = try? inputs.admitted(), let ready,
              ready.releaseID == admitted.0.id, ready.product == admitted.1, ready.os == admitted.2,
              readyTerms == admitted.3 else { return .needsPreparation }
        return nil
    }
    /// Selection eligibility advertises a meaningful checked attempt, not readiness.
    var choiceRefusal: ParakeetInstallationRefusal? {
        choiceRefusal(configurationValid: settingsValid)
    }
    var profileChoiceRefusal: ParakeetInstallationRefusal? {
        choiceRefusal(configurationValid: savedSettingsValid)
    }
    private func choiceRefusal(configurationValid: Bool) -> ParakeetInstallationRefusal? {
        guard configurationValid else { return .configuration }
        guard !admissionClosed || canDeliberatelyEnter else { return .closed }
        guard action == nil, ownership.count == 0, !ownership.hasWriter else { return .busy }
        if let gate { return gate }
        guard reconciliation == .settled else { return .reconciling }
        if let trackingRefusal { return trackingRefusal }
        if trustRefused { return .trustedProduct }
        return nil
    }
    private var trackingRefusal: ParakeetInstallationRefusal? {
        if let trackingFailure { return trackingFailure }
        if let stage = installed?.record?.stage, [.installing, .publishing, .preparing, .deleting].contains(stage) { return .interrupted }
        return nil
    }
    func savedTarget(_ id: TargetID) -> SavedTarget? { targets[id] }
    /// Copy scalar state without minting a token or touching action currency.
    func controlSnapshot(for id: TargetID) -> ParakeetSnapshot {
        var state = snapshot
        if targets[id]?.selection.engine != .parakeet {
            state.canInstall = false; state.canPrepare = false; state.canRetry = false
        }
        if action == nil, let target = targets[id], target.selection.engine == .parakeet {
            state.refusal = cachedRefusal(for: target.selection)
        }
        if gate != nil || (!canDeliberatelyEnter && admissionClosed) {
            state.canInstall = false; state.canPrepare = false; state.canRetry = false
        }
        if trackingFailure != nil {
            state.canInstall = false; state.canPrepare = false
            // Retry's verifier can discard this owned partial and revalidate completed files.
            let knownPartial = trackingFailure == .integrity && failedAction == .install
                && installed?.record?.stage == .installing && installed?.record?.current != nil
            state.canRetry = state.canRetry && knownPartial
        }
        return state
    }
    private func rebuildTargets() {
        targets = [:]
        guard settingsValid, let savedSettings else { return }
        func bind(_ id: TargetID, _ selection: RecognitionSelection) {
            guard selection.engine != .invalid else { return }
            targets[id] = SavedTarget(id: id, revision: savedRevision, selection: selection, admissionToken: snapshot.token)
        }
        bind(.global, RecognitionRequest(settings: savedSettings).selection)
        for profile in savedSettings.profiles where profile.enabled && profile.validationError == nil {
            var globals = savedSettings; globals.profiles = [profile]
            let result = ProfileResolver.resolve(globals, at: ProfileDestination(
                bundleID: profile.targetKind == .app ? profile.target : "com.apple.Safari",
                browserURL: profile.targetKind == .host ? "https://" + profile.target : nil))
            if result.profile?.id == profile.id { bind(.profile(profile.id), RecognitionRequest(settings: result.settings).selection) }
        }
    }
    func act(_ requested: Action, target: SavedTarget) {
        guard target.admissionToken == snapshot.token, targets[target.id] == target else { return }
        if [.install, .prepare, .retry].contains(requested), target.selection.engine != .parakeet { return }
        if action != nil { act(requested, token: target.admissionToken); return }
        // The accepted action tracks saved revision, not subsequent progress tokens.
        acceptedTarget = requested == .delete ? nil : target
        act(requested, token: target.admissionToken)
        if action == nil { acceptedTarget = nil }
    }
    func configure(_ settings: Settings, valid: Bool = true) {
        let selection = RecognitionRequest(settings: settings).selection
        if savedSettings != settings || !valid {
            savedRevision = UUID()
            if acceptedTarget != nil { epoch = UUID(); cancel() }
        }
        savedSettings = settings
        settingsValid = valid && selection.engine != .invalid
        savedSettingsValid = settingsValid
        // Resolve each enabled profile through the existing effective-settings
        // policy. Invalid settings protect conservatively, including siblings.
        referenced = !settingsValid || selection.engine == .parakeet
        for profile in settings.profiles where profile.enabled {
            var globals = settings; globals.profiles = [profile]
            let resolved = ProfileResolver.resolve(globals, at: ProfileDestination(bundleID: profile.targetKind == .app ? profile.target : "com.apple.Safari", browserURL: profile.targetKind == .host ? "https://" + profile.target : nil))
            let effective = RecognitionRequest(settings: resolved.settings).selection
            if effective.engine == .parakeet || effective.engine == .invalid { referenced = true }
        }
        if referenced, action?.action == .delete { cancel() }
        if target != selection || !settingsValid {
            epoch = UUID(); ready = nil; cancel(); pendingRecheck = false
        }
        target = selection
        if action != nil { rebuildTargets() }
        if action == nil {
            let refusal: ParakeetInstallationRefusal? = !settingsValid ? .configuration : admissionClosed ? .closed : gate ?? trackingFailure
            let admitted = try? inputs.admitted()
            if let scope = ready, refusal != nil || admitted?.0.id != scope.releaseID || admitted?.1 != scope.product || admitted?.2 != scope.os || admitted?.3 != readyTerms { ready = nil }
            refresh(phase: ready != nil ? .ready : installed?.installed == true ? .installed : .blocked, refusal: refusal)
        }
    }
    func draftChanged() {
        epoch = UUID(); savedRevision = UUID(); targets = [:]; settingsValid = false; ready = nil; pendingRecheck = false; cancel()
        if action == nil { refresh(phase: .blocked, refusal: .configuration) }
        // Existing frozen recognition uses retain their own origin authority.
    }
    private func refresh(phase: ParakeetSnapshot.Phase, refusal: ParakeetInstallationRefusal? = nil, bytes: Int? = nil, total: Int? = nil) {
        if phase != snapshot.phase { phaseAdmitted = clock.now() }
        let reason = refusal ?? (trustRefused ? .trustedProduct : trackingFailure)
        var next = ParakeetSnapshot(phase: phase, refusal: reason, bytes: bytes, total: total)
        let available = settingsValid && !admissionClosed
        let mutable = settingsValid && (!admissionClosed || canDeliberatelyEnter)
        let idle = mutable && action == nil
        let hasRelease = inputs.release() != nil
        let interrupted = installed?.record.map { [.installing, .publishing, .preparing, .deleting].contains($0.stage) } ?? false
        next.canCancel = action != nil && phase != .stopping
        next.canRecheck = available && hasRelease
        let tracked = trackingFailure == nil && reason != .storage && reason != .integrity
        next.canInstall = idle && gate == nil && tracked && !trustRefused && installed?.installed != true && !interrupted && ownership.count == 0
        next.canPrepare = idle && gate == nil && tracked && !trustRefused && installed?.installed == true && ownership.count == 0
        next.canRetry = idle && gate == nil && failedAction != nil && ownership.count == 0
        next.canDelete = idle && hasRelease && installed?.record != nil && installed?.record?.stage != .absent && !referenced && ownership.count == 0
        snapshot = next
        rebuildTargets()
    }
    /// Only a deliberate mutating action may reopen a canceled quit, after its
    /// entire drain. Every new quit resets this entitlement before any await.
    var canDeliberatelyEnter: Bool {
        guard let quit else { return false }
        return canceledQuit == quit && drain == nil && !hasWork && restart == nil
    }
    func deliberateEntry() {
        guard canDeliberatelyEnter else { return }
        quit = nil; canceledQuit = nil; ownership.reopen()
        refresh(phase: installed?.installed == true ? .installed : .blocked, refusal: gate)
    }
    func reconcileOnce() {
        guard !reconciled else { return }; reconciled = true
        guard action == nil, settingsValid, !admissionClosed, gate == nil else {
            reconciliation = .settled
            refresh(phase: snapshot.phase, refusal: !settingsValid ? .configuration : admissionClosed ? .closed : gate)
            return
        }
        reconciliation = .queued
        start(.recheck, passive: true)
    }
    func act(_ requested: Action, token: UUID) {
        guard snapshot.token == token else { return }
        if requested != .recheck { deliberateEntry() }
        guard !admissionClosed, settingsValid else { refresh(phase: .blocked, refusal: admissionClosed ? .closed : .configuration); return }
        if action != nil {
            if requested == .recheck { pendingRecheck = true }
            return
        }
        let next = requested == .retry ? failedAction : requested
        guard let next else { return }
        if next == .install || next == .prepare {
            if let gate { refresh(phase: .blocked, refusal: gate); return }
        }
        guard inputs.release() != nil else { refresh(phase: .blocked, refusal: .releaseIntegrity); return }
        if next == .delete, referenced { refresh(phase: .blocked, refusal: .protectedInstallation); return }
        start(next, retry: requested == .retry)
    }
    private func start(_ requested: Action, retry: Bool = false, passive: Bool = false) {
        do { try ownership.acquireWriter() }
        catch { refresh(phase: .blocked, refusal: error as? ParakeetInstallationRefusal ?? .busy); return }
        let operation = PendingOperation(name: "Parakeet preparation"), generation = epoch
        action = (operation, requested)
        if requested != .recheck { ready = nil }
        refresh(phase: .waiting)
        enqueue(operation, { [self] in await run(requested, retry: retry, passive: passive, generation: generation, operation: operation) }, { [self] in
            exited(operation)
        })
    }
    private func exited(_ operation: PendingOperation) {
        guard action?.operation == operation else { return }
        action = nil; acceptedTarget = nil; permit = nil; ownership.releaseWriter()
        reconciliation = .settled
        if snapshot.phase == .stopping { refresh(phase: .interrupted, refusal: snapshot.refusal ?? .revoked) }
        else { refresh(phase: snapshot.phase, refusal: snapshot.refusal, bytes: snapshot.bytes, total: snapshot.total) }
        if pendingRecheck { pendingRecheck = false; act(.recheck, token: snapshot.token) }
    }
    func cancel(token: UUID) { guard snapshot.token == token else { return }; cancel() }
    private func cancel() {
        guard let action else { return }
        permit?.revoke(); action.operation.revoke(); action.operation.requestAbort()
        refresh(phase: .stopping, refusal: .revoked)
    }
    private func current(_ generation: UUID, _ permit: ParakeetActionPermit) throws {
        try permit.check()
        guard epoch == generation, settingsValid, !admissionClosed else { throw ParakeetInstallationRefusal.revoked }
        if let target = acceptedTarget {
            guard target.revision == savedRevision, targets[target.id]?.selection == target.selection else { throw ParakeetInstallationRefusal.revoked }
        }
    }
    private func adopt(_ value: ParakeetStoredInstallation, product: ParakeetProductIdentity?, os: String?) {
        installed = value; trackingFailure = nil
        if let stored = value.record, stored.stage == .ready, let scope = stored.prepared,
           product == scope.product, os == scope.os, scope == ParakeetPreparedScope(releaseID: stored.release, installation: stored.generation, product: scope.product, os: scope.os) {
            ready = scope; readyTerms = inputs.terms()
        } else { ready = nil; readyTerms = nil }
    }
    private func run(_ requested: Action, retry: Bool, passive: Bool, generation: UUID, operation: PendingOperation) async {
        // Total logical lifetime starts at actual work admission, after queue wait.
        let permit = ParakeetActionPermit(operation: operation, seconds: requested == .install ? 3600 : requested == .prepare ? 180 : 60, clock: clock)
        self.permit = permit
        if passive { reconciliation = .inFlight }
        lastProgress = nil
        let watchdog = Task { [self] in
            while !Task.isCancelled, permit.current {
                let now = clock.now()
                if snapshot.phase == .verifying, now < phaseAdmitted || now - phaseAdmitted >= 60_000_000_000 {
                    permit.revoke(); operation.revoke(); operation.requestAbort(); refresh(phase: .stopping, refusal: .deadline)
                    return
                }
                await clock.tick()
            }
            if !Task.isCancelled, permit.expired {
                permit.revoke(); operation.revoke(); operation.requestAbort(); refresh(phase: .stopping, refusal: .deadline)
            }
        }
        do {
            try current(generation, permit)
            guard let release = inputs.release() else { throw ParakeetInstallationRefusal.releaseIntegrity }
            var expectedProduct: ParakeetProductIdentity?, os: String?, expectedTerms: ParakeetTermsApproval?
            if requested == .install || requested == .prepare {
                let admitted = try inputs.admitted(); expectedProduct = admitted.1; os = admitted.2; expectedTerms = admitted.3
                refresh(phase: .verifying)
                _ = try await admitParakeetProduct(admitted.1, app: app, trust: trust)
                trustRefused = false
                try current(generation, permit)
            } else if let admitted = try? inputs.admitted() { expectedProduct = admitted.1; os = admitted.2 }
            switch requested {
            case .install:
                let value = try await storage.install(release, retry: retry, permit: permit, progress: { [weak self] bytes in
                    self?.measuredProgress(bytes, total: release.bytes, permit: permit)
                }, phase: { [weak self] phase in
                    self?.workPhase(phase, permit: permit)
                })
                trackingFailure = nil
                installed = value // commit may win cancellation; still never ready or selected
                try current(generation, permit)
                ready = nil; failedAction = nil; refresh(phase: .installed)
            case .prepare:
                guard let expectedProduct, let os, let expectedTerms else { throw ParakeetInstallationRefusal.trustedProduct }
                let authorize: @MainActor () throws -> Void = { [self] in
                    try current(generation, permit)
                    let admitted = try inputs.admitted()
                    guard admitted.0.id == release.id, admitted.1 == expectedProduct,
                          admitted.2 == os, admitted.3 == expectedTerms else { throw ParakeetInstallationRefusal.revoked }
                }
                try authorize()
                refresh(phase: .verifying)
                let value = try await storage.prepareIntent(release, permit: permit)
                installed = value; try authorize()
                guard let record = value.record else { throw ParakeetInstallationRefusal.storage }
                let product = try await admitParakeetProduct(expectedProduct, app: app, trust: trust)
                try authorize()
                refresh(phase: .loadChecking)
                let request = ParakeetWire.Record(identity: .init(helperBuild: product.identity.helperSHA256, osScope: os), mode: .prepareLoad, directory: value.directory.path, sampleCount: 0)
                let result = await worker.run(product: product, request: request, samples: [], shouldAbort: { !permit.current })
                try authorize()
                guard result.cleanExit, !result.forcedTerminationRequested, !result.expired, !result.deliveryRevoked,
                      result.terminal?.code == .completed, result.terminal?.text == "" else { throw ParakeetInstallationRefusal.loadCheck }
                let scope = ParakeetPreparedScope(releaseID: release.id, installation: record.generation, product: expectedProduct, os: os)
                let durable = try await storage.markPrepared(scope, release: release, permit: permit, authorize: authorize)
                try authorize()
                adopt(durable, product: expectedProduct, os: os); failedAction = nil; refresh(phase: .ready)
            case .recheck:
                refresh(phase: .verifying)
                let value: ParakeetStoredInstallation
                if passive { value = try await storage.reconcile(release) }
                else { value = try await storage.verifyInstalled(release, permit: permit) }
                try current(generation, permit)
                adopt(value, product: expectedProduct, os: os)
                if let record = value.record, [.installing, .publishing].contains(record.stage) { failedAction = .install }
                if value.record?.stage == .preparing { failedAction = .prepare }
                refresh(phase: ready != nil ? .ready : value.installed ? .installed : value.record == nil || value.record?.stage == .absent ? .absent : .interrupted,
                        refusal: gate ?? (value.installed ? nil : value.record == nil ? .absent : .interrupted))
            case .delete:
                guard !referenced, settingsValid else { throw ParakeetInstallationRefusal.protectedInstallation }
                refresh(phase: .deleting)
                try await storage.delete(release, permit: permit)
                try current(generation, permit)
                installed = nil; ready = nil; failedAction = nil; trackingFailure = nil; refresh(phase: .absent, refusal: gate)
            case .retry: throw ParakeetInstallationRefusal.configuration
            }
        } catch {
            ready = nil
            if requested != .recheck { failedAction = requested }
            // Bounded, read-only reconciliation is safe even after cancellation;
            // it neither repairs uncertain records nor promotes readiness.
            if let release = inputs.release() { installed = try? await storage.reconcile(release) }
            let reason: ParakeetInstallationRefusal = permit.expired || snapshot.refusal == .deadline ? .deadline
                : passive ? .storage : (error as? ParakeetInstallationRefusal ?? (error is ParakeetRefusal ? .trustedProduct : .storage))
            if reason == .storage || reason == .integrity { trackingFailure = reason }
            if reason == .trustedProduct, requested == .install || requested == .prepare { trustRefused = true }
            if reason == .deadline { permit.revoke(); operation.revoke(); operation.requestAbort() }
            refresh(phase: operation.shouldAbort ? .stopping : reason == .interrupted ? .interrupted : .failed, refusal: reason)
        }
        watchdog.cancel(); await watchdog.value // no action/claim release before this join
    }
    private var lastProgress: UInt64?
    private func measuredProgress(_ bytes: Int, total: Int, permit: ParakeetActionPermit) {
        guard permit.current else { return }
        let now = clock.now()
        guard lastProgress.map({ now >= $0 && now - $0 >= 250_000_000 }) ?? true else { return }
        lastProgress = now; refresh(phase: snapshot.phase, bytes: bytes, total: total)
    }
    private func workPhase(_ phase: ParakeetSnapshot.Phase, permit: ParakeetActionPermit) {
        guard permit.current, snapshot.phase != phase else { return }; refresh(phase: phase)
    }
    func preparedUse(_ selection: RecognitionSelection, operation supplied: PendingOperation?) async throws -> ParakeetInstallationLease {
        guard !admissionClosed, settingsValid else { throw admissionClosed ? ParakeetInstallationRefusal.closed : .configuration }
        guard case .parakeet(let model, let filter) = selection, model == ParakeetWire.model,
              filter.map({ ParakeetWire.filters.contains($0) }) ?? true else { throw ParakeetInstallationRefusal.configuration }
        let (release, product, os, terms) = try inputs.admitted()
        guard let scope = ready, scope.releaseID == release.id, scope.product == product, scope.os == os, readyTerms == terms else { throw ParakeetInstallationRefusal.needsPreparation }
        let operation = supplied ?? PendingOperation(name: "Parakeet recognition")
        let use = try ownership.pin(operation) // before the first await, not after verification
        do {
            let permit = ParakeetActionPermit(operation: operation, seconds: 60, clock: clock)
            let value = try await storage.verifyInstalled(release, permit: permit)
            let fresh = try inputs.admitted()
            guard use.current, !admissionClosed, ready == scope, value.record?.prepared == scope,
                  fresh.0.id == release.id, fresh.1 == product, fresh.2 == os, fresh.3 == terms,
                  value.record?.generation == scope.installation else { throw ParakeetInstallationRefusal.revoked }
            return ParakeetInstallationLease(directory: value.directory, product: product, osScope: os,
                scope: scope, isCurrent: { use.current }, release: { [ownership] in ownership.release(use) })
        } catch { ownership.release(use); throw error }
    }

    private func close(restarting: Bool) {
        if restarting { restart = UUID() } else { quit = UUID(); canceledQuit = nil }
        epoch = UUID(); pendingRecheck = false; ready = nil; ownership.close(); cancel()
        if action == nil { refresh(phase: .blocked, refusal: .closed) }
    }
    func beginShutdown(chain: @escaping () -> Task<Void, Never>?, reply: @escaping (Bool) -> Void) {
        close(restarting: false) // admission closes before constructing/awaiting a task
        let intent = quit
        let joined = beginDrain(chain: chain)
        Task { [self] in await joined.value; reply(quit == intent && !hasWork) }
    }
    private func beginDrain(chain: @escaping () -> Task<Void, Never>?) -> Task<Void, Never> {
        if let drain { return drain }
        let task = Task { [self] in
            var retired = false
            while true {
                let previous = chain()
                await previous?.value
                guard chain() == previous else { continue }
                if !retired { await retireHandles(); retired = true; continue }
                await ownership.joinUses()
                // An external retained pin may outlive the previous stable
                // chain. Recheck the chain and concrete claims in this same
                // actor turn before granting termination/restart authority.
                if chain() == previous, !hasWork { break }
            }
            drain = nil
            refresh(phase: snapshot.phase, refusal: snapshot.refusal)
        }
        drain = task; return task
    }
    func cancelShutdown() {
        if let quit { canceledQuit = quit }
        refresh(phase: snapshot.phase, refusal: snapshot.refusal)
    }
    func reserveRestart() -> Bool {
        guard !admissionClosed else { return false }; close(restarting: true); return true
    }
    func drainRestart(chain: @escaping () -> Task<Void, Never>?) async -> Bool {
        guard let reservation = restart else { return false }
        await beginDrain(chain: chain).value
        return restart == reservation && quit == nil && !hasWork
    }
    func restartReady() -> Bool { restart != nil && quit == nil && !hasWork }
    func releaseRestart() {
        restart = nil
        if quit == nil { ownership.reopen() }
        refresh(phase: snapshot.phase, refusal: quit == nil ? gate : .closed)
    }
}
