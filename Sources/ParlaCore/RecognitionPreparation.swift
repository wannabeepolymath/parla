import Foundation

public enum PreparationPhase: String, Codable, Sendable { case nativeConstruction, explicitSyntheticWarmup, firstRealAudioRequest }
public enum PreparationRole: String, Codable, Sendable { case primaryBatchRecognizer }
public enum PreparationRefusal: String, Error, Sendable, CustomStringConvertible {
    case paused, trackingUnavailable, unsupportedSelection, consentRequired, busy, revoked, preparedResidentRequired
    public var description: String {
        switch self {
        case .paused: return "The speech model didn’t finish loading twice, so Safe Start paused it. Open Safe Start."
        case .trackingUnavailable: return "Safe Start can’t save its records. Open Safe Start."
        case .unsupportedSelection: return "Safe Start works only with Whisper models from the list."
        case .consentRequired: return "Turn Safe Start off and on again to continue."
        case .busy: return "Wait for the speech model to finish loading."
        case .revoked: return "Settings changed. Try again."
        case .preparedResidentRequired: return "Undo isn’t available until the speech model has loaded once."
        }
    }
}
public enum PreparationStatus: String, Sendable { case off, ready, preparing, paused, trackingUnavailable, unsupportedSelection }
public struct PreparationSnapshot: Equatable, Sendable {
    public let status: PreparationStatus
    public let refusal: PreparationRefusal?
    public let token: UUID
    public init(_ status: PreparationStatus, refusal: PreparationRefusal? = nil, token: UUID = UUID()) {
        self.status = status; self.refusal = refusal; self.token = token
    }
    public var message: String {
        if let refusal { return refusal.description }
        switch status {
        case .off: return "Safe Start is off."
        case .ready: return "Safe Start is on."
        case .preparing: return "Loading the speech model…"
        case .paused: return "The speech model didn’t finish loading twice, so Safe Start paused it."
        case .trackingUnavailable: return "Safe Start can’t save its records."
        case .unsupportedSelection: return "Safe Start works only with Whisper models from the list."
        }
    }
}
public struct PreparationBuild: Codable, Hashable, Sendable {
    public let app: UUID, native: UUID
    public let architecture: String
    public init(app: UUID, native: UUID, architecture: String) { self.app = app; self.native = native; self.architecture = architecture }
}
/// Compact, bounded metadata key. Expected pins and stat generations are evidence, not byte attestation.
/// No path (or path digest), process UUID, language, prompt, audio, provider or error belongs here.
public struct PreparationKey: Codable, Hashable, Sendable {
    let m: String, s: String
    let b: Int64, t: Double, c: Double?, i: UInt64?
    let a: UUID, n: UUID, h: String, v: String
    let d: Int, x: Int
    let r: PreparationRole
    public let p: PreparationPhase
    public init(identity: RecognitionIdentity, build: PreparationBuild, phase: PreparationPhase) throws {
        guard case .admittedCatalog(let id, let sha, let bytes) = identity.artifact,
              let g = identity.generation, g.bytes == bytes, bytes > 0,
              g.modified.isFinite, g.modified >= 0, g.changed.map({ $0.isFinite && $0 >= 0 }) ?? true,
              id.utf8.count <= 32, !id.isEmpty, id.utf8.allSatisfy({ (32...126).contains($0) }),
              sha.utf8.count == 64, sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ["arm64", "x86_64"].contains(build.architecture),
              let runtime = identity.runtime, !runtime.nativeVersion.isEmpty, runtime.nativeVersion.utf8.count <= 64,
              runtime.nativeVersion.utf8.allSatisfy({ (32...126).contains($0) }),
              runtime.adapterRevision == 1, runtime.compute == .nativeDefaults else {
            throw PreparationRefusal.unsupportedSelection
        }
        m = id; s = sha; b = bytes; t = g.modified; c = g.changed; i = g.fileNumber
        a = build.app; n = build.native; h = build.architecture; v = runtime.nativeVersion
        d = runtime.adapterRevision; x = runtime.compute.defaultsRevision
        r = .primaryBatchRecognizer; p = phase
        try validate()
    }
    func validate() throws {
        guard m.utf8.count <= 32, !m.isEmpty, m.utf8.allSatisfy({ (32...126).contains($0) }),
              s.utf8.count == 64, s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              b > 0, t.isFinite, t >= 0, c.map({ $0.isFinite && $0 >= 0 }) ?? true,
              ["arm64", "x86_64"].contains(h), d == 1, x == 1,
              !v.isEmpty, v.utf8.count <= 64, v.utf8.allSatisfy({ (32...126).contains($0) }),
              try JSONEncoder().encode(self).count <= 512 else { throw PreparationRefusal.trackingUnavailable }
    }
}
struct PreparationPending: Codable, Equatable {
    let attempt: UUID, launch: UUID, operation: UUID, selection: UUID
}
struct PreparationEntry: Codable {
    let key: PreparationKey
    var unresolved = 0
    var consumed: UUID?
    var pending: PreparationPending?
    var outcome: PreparationDisposition?
}
enum PreparationDisposition: String, Codable { case completed, returnedFailure, canceled, disabled, superseded, cleanQuit, cleanRestart }
struct PreparationLedger: Codable {
    let schema: Int
    let consent: UUID
    var generation = UUID()
    var entries: [PreparationEntry]
    var poisoned = false
    init(consent: UUID, schema: Int = 2) { self.schema = schema; self.consent = consent; entries = [] }
    func validate() throws {
        guard [1, 2].contains(schema), entries.count <= (schema == 1 ? 8 : 12),
              try JSONEncoder().encode(self).count <= 16_384, Set(entries.map(\.key)).count == entries.count,
              entries.compactMap(\.pending).count <= 1 else { throw PreparationRefusal.trackingUnavailable }
        for entry in entries {
            try entry.key.validate()
            guard schema != 1 || [.nativeConstruction, .explicitSyntheticWarmup].contains(entry.key.p) else {
                throw PreparationRefusal.trackingUnavailable
            }
            guard (0...2).contains(entry.unresolved), entry.pending?.attempt != entry.consumed || entry.pending == nil else {
                throw PreparationRefusal.trackingUnavailable
            }
        }
    }
}
/// Storage owns a nonblocking interprocess lock for its lifetime. The owner reserves IO, then releases its lock for storage calls.
public protocol PreparationStorage: AnyObject {
    func read() throws -> Data?
    func replace(_ data: Data, authorized: () -> Bool) throws
    func quarantine() throws
    func reset(_ data: Data) throws
}
/// Shared by every handle of the same actual native instance. Never re-stamped after Reset.
/// Owner → readiness is the only nested lock order; these methods never enter the owner or IO.
public final class PreparationReadiness: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private struct Scope: Equatable {
        let consent: UUID, selection: UUID, recovery: UUID
        let key: PreparationKey
    }
    private enum FirstUse { case unattempted, inFlight(UUID), completed, refused }
    private var scope: Scope?
    private var warmed = false
    private var first = FirstUse.unattempted
    private func scopeMatches(_ permit: PreparationPermit) -> Bool {
        scope == Scope(consent: permit.consent, selection: permit.selection, recovery: permit.recovery, key: permit.construction)
    }
    fileprivate func constructed(_ permit: PreparationPermit) throws {
        try lock.withLock {
            guard scope == nil else { throw PreparationRefusal.revoked }
            scope = Scope(consent: permit.consent, selection: permit.selection, recovery: permit.recovery, key: permit.construction)
        }
    }
    fileprivate func matches(_ permit: PreparationPermit, prepared: Bool) -> Bool {
        lock.withLock {
            guard scopeMatches(permit) else { return false }
            switch first {
            case .refused, .inFlight: return false
            case .unattempted: return !prepared
            case .completed: return !prepared || warmed
            }
        }
    }
    fileprivate func warmedFor(_ permit: PreparationPermit) -> Bool {
        lock.withLock { scopeMatches(permit) && warmed }
    }
    fileprivate func completeWarmup(_ permit: PreparationPermit) {
        lock.withLock { if scopeMatches(permit) { warmed = true } }
    }
    /// nil means a completed resident; concurrent/refused/read-only first claims never wait or write.
    fileprivate func claim(_ permit: PreparationPermit) throws -> UUID? {
        try lock.withLock {
            guard scopeMatches(permit) else { throw PreparationRefusal.revoked }
            switch first {
            case .completed:
                guard !permit.readOnly || warmed else { throw PreparationRefusal.preparedResidentRequired }
                return nil
            case .unattempted:
                guard !permit.readOnly else { throw PreparationRefusal.preparedResidentRequired }
                let attempt = UUID(); first = .inFlight(attempt); return attempt
            case .inFlight: throw PreparationRefusal.busy
            case .refused: throw PreparationRefusal.revoked
            }
        }
    }
    fileprivate func finish(_ permit: PreparationPermit, attempt: UUID, completed: Bool) {
        lock.withLock {
            guard scopeMatches(permit), case .inFlight(let current) = first, current == attempt else { return }
            first = completed ? .completed : .refused
        }
    }
}

/// Returned native evidence is independent of delivery/readiness authorization.
struct PreparationFirstRequestReceipt {
    let native: RecognitionNativeOutcome
    let deliveryAuthorized: Bool
}

/// One in-process transition owner. No lock is held over native work, waits, observers or UI callbacks.
/// Unresolved records are UNKNOWN outcomes; they can include an unpersisted terminal return.
public final class RecognitionPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: () throws -> PreparationStorage
    private let build: () throws -> PreparationBuild
    public let launch: UUID
    private var store: PreparationStorage?
    private var ledger: PreparationLedger?
    private var enabled = false, fault = false, draftRevoked = false, quit = false, restart = false
    private var consent: UUID?
    private var selection = UUID()
    private var grantEpoch = UUID()
    private var recovery = UUID()
    private var expandedConsent = false, resetAllowed = false, ioInFlight = false
    /// Observation only: never an admission permit, and cleared before the reserved IO returns.
    private struct FormIO {
        let operation: PendingOperation
        let target: RecognitionSelection
        let consent: UUID, selection: UUID, grant: UUID, recovery: UUID
        let phase: PreparationPhase?, attempt: UUID?
    }
    private var formIO: FormIO?
    // fault blocks admission; only known failed terminal retirement is a saved-opt-out debt.
    private var retirementDebt = false
    private var evidence: PreparationBuild?
    private var active: PreparationEntryToken?
    private var retry: (operation: UUID, selection: UUID, consent: UUID, construction: PreparationKey, warmup: PreparationKey)?
    private var lastTarget: PreparationTarget?
    private var observedSelection: RecognitionSelection?
    private var snapshotValue = PreparationSnapshot(.off)
    public var changed: (() -> Void)?
    public var snapshot: PreparationSnapshot { lock.withLock { snapshotValue } }
    public var isEnabled: Bool { lock.withLock { enabled || draftRevoked } }
    public var hasActiveEntry: Bool { lock.withLock { active != nil || ioInFlight } }
    public var persistenceFailed: Bool { lock.withLock { retirementDebt } }
    public var admissionEpoch: UUID? { lock.withLock { enabled || draftRevoked ? grantEpoch : nil } }
    public func matchesSavedPermission(_ settings: Settings) -> Bool {
        lock.withLock {
            !draftRevoked && enabled == settings.nativePreparationSafeStartEnabled
                && (!enabled || consent == settings.nativePreparationConsent)
        }
    }
    public func cachedRefusal(for selection: RecognitionSelection) -> PreparationRefusal? {
        lock.withLock { cachedRefusalLocked(for: selection) }
    }
    private func cachedRefusalLocked(for selection: RecognitionSelection) -> PreparationRefusal? {
        if active != nil || ioInFlight { return .busy }
        if quit || restart { return .revoked }
        if snapshotValue.status == .preparing { return .busy }
        if snapshotValue.status == .paused || snapshotValue.status == .unsupportedSelection {
            return observedSelection == selection ? snapshotValue.refusal : nil
        }
        return snapshotValue.refusal
    }

    /// Read-only, atomic form check for the exact operation owning construction or its first real request.
    /// Terminal bookkeeping can retire its record before actual native exit releases ownership.
    public func cachedRefusal(for target: RecognitionSelection, operation: PendingOperation,
                              selectionEpoch: UUID?, preparationEpoch: UUID?) -> PreparationRefusal? {
        lock.withLock {
            if fault { return .trackingUnavailable }
            if quit || restart || draftRevoked || operation.shouldAbort || operation.hasExited { return .revoked }
            if enabled, selectionEpoch != selection || preparationEpoch != grantEpoch { return .revoked }
            if let reason = snapshotValue.refusal, reason != .busy { return reason }
            if ioInFlight { return ownsFormIO(operation, target: target) ? nil : .busy }
            guard let entry = active else { return cachedRefusalLocked(for: target) }
            guard entry.permit.operation === operation, entry.pending.operation == operation.id,
                  entry.pending.selection == selection, observedSelection == target,
                  [.nativeConstruction, .firstRealAudioRequest].contains(entry.key.p),
                  snapshotValue.status == .preparing else { return .busy }
            do { try check(entry.permit) }
            catch let reason as PreparationRefusal { return reason }
            catch { return .revoked }
            return nil
        }
    }
    /// Observes form authority while its exact discarded take drains; grants no entry or publication.
    /// Operation validation remains fail-closed in check/begin/validate and both cachedRefusal APIs.
    public func cachedFormAuthority(for target: RecognitionSelection, discarding operation: PendingOperation,
                                    selectionEpoch: UUID?, preparationEpoch: UUID?) -> PreparationRefusal? {
        lock.withLock {
            if fault { return .trackingUnavailable }
            if quit || restart || draftRevoked { return .revoked }
            if enabled, selectionEpoch != selection || preparationEpoch != grantEpoch { return .revoked }
            if let reason = snapshotValue.refusal, reason != .busy { return reason }
            if ioInFlight {
                guard !operation.hasExited else { return .revoked }
                return ownsFormIO(operation, target: target) ? nil : .busy
            }
            guard let entry = active else { return cachedRefusalLocked(for: target) }
            guard !operation.hasExited else { return .revoked }
            guard entry.permit.operation === operation, entry.pending.operation == operation.id,
                  entry.pending.selection == selection, observedSelection == target,
                  [.nativeConstruction, .firstRealAudioRequest].contains(entry.key.p),
                  snapshotValue.status == .preparing else { return .busy }
            let permit = entry.permit
            guard enabled, consent == permit.consent, selection == permit.selection,
                  grantEpoch == permit.grantEpoch, recovery == permit.recovery else { return .revoked }
            // Only this attempt's deliberate abort is irrelevant to its form's unchanged grant.
            return nil
        }
    }
    public init(launch: UUID = UUID(), storage: @escaping () throws -> PreparationStorage,
                build: @escaping () throws -> PreparationBuild = PreparationBuildReader.loaded) {
        self.launch = launch; self.storage = storage; self.build = build
    }
    private func publish(_ state: PreparationStatus, _ reason: PreparationRefusal? = nil) {
        snapshotValue = PreparationSnapshot(state, refusal: reason)
    }
    private func unavailable(retirement: Bool = false) {
        fault = true; retirementDebt = retirementDebt || retirement
        retry = nil; publish(.trackingUnavailable, .trackingUnavailable)
    }
    private func observation(operation: PendingOperation?, target: RecognitionSelection,
                             phase: PreparationPhase? = nil, attempt: UUID? = nil) -> FormIO? {
        guard let operation, let consent, phase != .explicitSyntheticWarmup else { return nil }
        return FormIO(operation: operation, target: target, consent: consent, selection: selection,
                      grant: grantEpoch, recovery: recovery, phase: phase, attempt: attempt)
    }
    private func observation(_ permit: PreparationPermit, phase: PreparationPhase, attempt: UUID) -> FormIO? {
        guard let operation = permit.operation, phase != .explicitSyntheticWarmup else { return nil }
        return FormIO(operation: operation, target: permit.observedTarget, consent: permit.consent,
                      selection: permit.selection, grant: permit.grantEpoch, recovery: permit.recovery,
                      phase: phase, attempt: attempt)
    }
    private func ownsFormIO(_ operation: PendingOperation, target: RecognitionSelection) -> Bool {
        guard let scope = formIO, scope.operation === operation, scope.target == target,
              observedSelection == target, enabled, expandedConsent, consent == scope.consent,
              selection == scope.selection, grantEpoch == scope.grant, recovery == scope.recovery else { return false }
        if let entry = active {
            guard entry.permit.operation === operation, scope.phase == entry.key.p,
                  scope.attempt == entry.pending.attempt else { return false }
        }
        return true
    }
    /// Called with owner held. Reserve the transaction, then release it for all storage/build IO.
    /// Other admission/IO mutations refuse while reserved; revocation remains immediate.
    private func outsideLock<T>(observing scope: FormIO? = nil, _ body: () throws -> T) throws -> T {
        guard !ioInFlight else { throw PreparationRefusal.busy }
        ioInFlight = true; formIO = scope; lock.unlock()
        let result = Result { try body() }
        lock.lock(); ioInFlight = false; formIO = nil
        return try result.get()
    }
    private func readBuild(observing scope: FormIO? = nil) throws -> PreparationBuild {
        let epoch = grantEpoch, generation = recovery, selected = selection, permission = consent
        let value = try outsideLock(observing: scope, build)
        guard epoch == grantEpoch, generation == recovery, selected == selection, permission == consent,
              enabled, expandedConsent, !draftRevoked, !quit, !restart, !fault else { throw PreparationRefusal.revoked }
        return value
    }
    private func readStore() throws -> Data? {
        guard let store else { throw PreparationRefusal.trackingUnavailable }
        return try outsideLock { try store.read() }
    }
    private func quarantine() { if let store { try? outsideLock { try store.quarantine() } } }
    private func resetStore(_ value: PreparationLedger) throws {
        guard let store else { throw PreparationRefusal.trackingUnavailable }
        let bytes = try JSONEncoder().encode(value)
        try outsideLock { try store.reset(bytes) }
    }
    private struct SchemaHeader: Decodable { let schema: Int }
    private func acceptsExplicitReplacement(_ bytes: Data) throws {
        // Bounded corrupt owned bytes retain the existing explicit Reset policy. Unknown schemas do not.
        if let header = try? JSONDecoder().decode(SchemaHeader.self, from: bytes), ![1, 2].contains(header.schema) {
            throw PreparationRefusal.trackingUnavailable
        }
    }
    public func unsupportedSelection(_ target: RecognitionSelection) {
        defer { changed?() }
        lock.withLock {
            guard enabled, !fault, !draftRevoked else { return }
            observedSelection = target; publish(.unsupportedSelection, .unsupportedSelection)
        }
    }
    private func resting() {
        if active != nil || ioInFlight { publish(.preparing); return }
        if fault { publish(.trackingUnavailable, .trackingUnavailable); return }
        if enabled && !expandedConsent { publish(.trackingUnavailable, .consentRequired); return }
        if draftRevoked { publish(.trackingUnavailable, .revoked); return }
        let held = lastTarget.map { target in ledger?.entries.contains { target.keys.contains($0.key) && $0.unresolved >= 2 } == true } ?? false
        publish(held ? .paused : .ready, held ? .paused : nil)
    }
    private func commit(_ next: PreparationLedger, observing scope: FormIO? = nil,
                        authorized: () -> Bool = { true }) throws {
        try next.validate()
        let data = try JSONEncoder().encode(next)
        guard data.count <= 16_384, let store else { throw PreparationRefusal.trackingUnavailable }
        try outsideLock(observing: scope) { try store.replace(data, authorized: authorized) }
        ledger = next // Never publish a transaction that failed sync/rename/directory sync.
    }
    private func open() throws {
        if store == nil { store = try outsideLock(storage) }
    }
    /// Explicit enable: clean owned ledger BEFORE the caller saves the enabled flag and consent.
    public func prepareConsent(_ generation: UUID) throws {
        defer { changed?() }
        try lock.withLock {
            guard active == nil, !ioInFlight, !quit, !restart else { throw PreparationRefusal.busy }
            guard !retirementDebt else { throw PreparationRefusal.trackingUnavailable }
            do {
                try open()
                if let bytes = try? readStore() { try acceptsExplicitReplacement(bytes) }
                let clean = PreparationLedger(consent: generation)
                try resetStore(clean)
                ledger = clean; evidence = nil; retry = nil; lastTarget = nil; grantEpoch = UUID(); recovery = UUID()
                fault = false; retirementDebt = false; expandedConsent = false; resetAllowed = true
                // This is not a permission grant. configure runs only after successful settings persistence.
                draftRevoked = true; publish(.trackingUnavailable, .consentRequired)
            } catch { unavailable(); throw PreparationRefusal.trackingUnavailable }
        }
    }
    public func configure(enabled newEnabled: Bool, consent newConsent: UUID?, selection newSelection: UUID) {
        defer { changed?() }
        lock.withLock {
            if ioInFlight {
                if !newEnabled || newSelection != selection || newConsent != consent {
                    draftRevoked = true; grantEpoch = UUID()
                }
                publish(.trackingUnavailable, .busy); return
            }
            if newSelection != selection {
                retireActive(.superseded); grantEpoch = UUID(); retry = nil; lastTarget = nil
                publish(snapshotValue.status, snapshotValue.refusal)
            }
            selection = newSelection
            if !newEnabled {
                retireActive(.disabled); retry = nil; grantEpoch = UUID()
                if active != nil { draftRevoked = true; publish(.trackingUnavailable, .busy); return }
                guard !retirementDebt else { draftRevoked = true; publish(.trackingUnavailable, .trackingUnavailable); return }
                enabled = false; consent = nil; draftRevoked = false; ledger = nil; store = nil; evidence = nil; fault = false
                expandedConsent = false; resetAllowed = false
                publish(.off); return
            }
            if enabled, consent == newConsent, !draftRevoked { return }
            if draftRevoked, newConsent == consent { publish(.trackingUnavailable, .consentRequired); return }
            guard active == nil else { draftRevoked = true; retireActive(); publish(.trackingUnavailable, .busy); return }
            enabled = true; consent = newConsent; draftRevoked = false; retry = nil; expandedConsent = false; resetAllowed = false
            grantEpoch = UUID()
            guard let newConsent else { publish(.trackingUnavailable, .consentRequired); return }
            do {
                try open()
                guard let bytes = try readStore() else { throw PreparationRefusal.consentRequired }
                try acceptsExplicitReplacement(bytes)
                resetAllowed = (try? JSONDecoder().decode(SchemaHeader.self, from: bytes).schema) != 1
                var loaded = try JSONDecoder().decode(PreparationLedger.self, from: bytes)
                try loaded.validate()
                guard loaded.schema == 2 else {
                    ledger = nil; resetAllowed = false; fault = false
                    publish(.trackingUnavailable, .consentRequired); return
                }
                guard loaded.consent == newConsent, !loaded.poisoned else { throw PreparationRefusal.trackingUnavailable }
                // Atomically consume previous-launch records, never same-launch pending records.
                var changed = false
                for index in loaded.entries.indices {
                    if let pending = loaded.entries[index].pending, pending.launch != launch {
                        loaded.entries[index].unresolved = min(2, loaded.entries[index].unresolved + 1)
                        loaded.entries[index].consumed = pending.attempt
                        loaded.entries[index].pending = nil; changed = true
                    }
                }
                if changed {
                    do { try commit(loaded) }
                    catch { quarantine(); throw error }
                } else { ledger = loaded }
                guard !draftRevoked, consent == newConsent, selection == newSelection else { throw PreparationRefusal.revoked }
                expandedConsent = true; recovery = UUID(); fault = false; publish(.ready)
            } catch let refusal as PreparationRefusal {
                unavailable(); if refusal == .consentRequired { publish(.trackingUnavailable, .consentRequired) }
            } catch { unavailable() }
        }
    }
    /// Draft opt-out revokes immediately, while old-consent writes are still permitted.
    public func revokeDraft() { defer { changed?() }; lock.withLock { draftRevoked = true; retry = nil; grantEpoch = UUID(); retireActive(); publish(.trackingUnavailable, .revoked) } }
    private func retireActive(_ disposition: PreparationDisposition = .canceled) { if let active { terminalLocked(active, disposition: disposition) } }
    public func selectionChanged(_ value: UUID) {
        defer { changed?() }
        lock.withLock {
            guard value != selection else { return }
            retireActive(.superseded); selection = value; grantEpoch = UUID(); retry = nil; lastTarget = nil
            if enabled || draftRevoked { resting() } else { publish(.off) }
        }
    }
    public func keep(token: UUID) {
        defer { changed?() }
        lock.withLock {
            guard snapshotValue.token == token else { return }
            retry = nil; grantEpoch = UUID(); retireActive()
            if !fault, !draftRevoked { resting() }
        }
    }
    public func reset(token: UUID) throws {
        defer { changed?() }
        try lock.withLock {
            guard enabled, snapshotValue.token == token, active == nil, !ioInFlight, resetAllowed, let consent else { throw PreparationRefusal.revoked }
            do {
                try open(); let clean = PreparationLedger(consent: consent, schema: expandedConsent ? 2 : 1); try resetStore(clean)
                ledger = clean; fault = false; retirementDebt = false; retry = nil; grantEpoch = UUID(); recovery = UUID()
                if !expandedConsent { publish(.trackingUnavailable, .consentRequired) }
                else if draftRevoked { publish(.trackingUnavailable, .revoked) } else { publish(.ready) }
            }
            catch { unavailable(); throw PreparationRefusal.trackingUnavailable }
        }
    }
    public func retryOnce(token: UUID, operation: PendingOperation, identity: RecognitionIdentity) throws {
        defer { changed?() }
        try lock.withLock {
            guard enabled, expandedConsent, !draftRevoked, !fault, !quit, !restart, active == nil, !ioInFlight, let consent,
                  snapshotValue.token == token, !operation.shouldAbort else { throw PreparationRefusal.revoked }
            if evidence == nil { evidence = try readBuild() }
            let construction = try PreparationKey(identity: identity, build: evidence!, phase: .nativeConstruction)
            let warmup = try PreparationKey(identity: identity, build: evidence!, phase: .explicitSyntheticWarmup)
            let target = try PreparationTarget(identity: identity, build: evidence!)
            if let lastTarget, lastTarget != target { throw PreparationRefusal.revoked }
            guard ledger?.entries.contains(where: { $0.key == target.first && $0.unresolved >= 2 }) != true else {
                publish(.paused, .paused); throw PreparationRefusal.paused
            }
            retry = (operation.id, selection, consent, construction, warmup)
            grantEpoch = UUID()
            publish(.ready)
        }
    }
    public func finishRetry(_ operation: PendingOperation) { lock.withLock { if retry?.operation == operation.id { retry = nil } } }
    public func reserveRestart() -> Bool {
        lock.withLock {
            guard !restart, !quit, !fault, !ioInFlight else { return false }
            restart = true; grantEpoch = UUID(); retry = nil; retireActive(.cleanRestart)
            if fault { restart = false; return false }
            return true
        }
    }
    public func releaseRestart() { lock.withLock { restart = false } }
    public func beginQuit() { lock.withLock { quit = true; grantEpoch = UUID(); retry = nil; retireActive(.cleanQuit) } }
    public func cancelQuit() { lock.withLock { quit = false } }
    /// A per-acquisition frozen capability. Build evidence is read lazily, only with persisted consent.
    public func authorize(identity: RecognitionIdentity, policy: RecognitionAdmission,
                          resident: RecognitionResident?, operation: PendingOperation?, selectionEpoch: UUID? = nil,
                          preparationEpoch: UUID? = nil) throws -> PreparationPermit? {
        defer { changed?() }
        return try lock.withLock {
            if let preparationEpoch, preparationEpoch != grantEpoch { throw PreparationRefusal.revoked }
            guard enabled || draftRevoked else { return nil }
            guard enabled, expandedConsent, !draftRevoked, !quit, !restart, !fault, !ioInFlight, let consent, ledger?.consent == consent else {
                throw fault ? PreparationRefusal.trackingUnavailable : (snapshotValue.refusal ?? .revoked)
            }
            guard operation?.shouldAbort != true, operation?.hasExited != true else { throw CancellationError() }
            if let selectionEpoch, selectionEpoch != selection { throw PreparationRefusal.revoked }
            guard active == nil else { throw PreparationRefusal.busy }
            observedSelection = identity.selection
            do {
                if evidence == nil { evidence = try readBuild(observing: observation(operation: operation, target: identity.selection)) }
                let construction = try PreparationKey(identity: identity, build: evidence!, phase: .nativeConstruction)
                let warmup = try PreparationKey(identity: identity, build: evidence!, phase: .explicitSyntheticWarmup)
                let bypass = retry?.operation == operation?.id && retry?.selection == selection && retry?.consent == consent
                if bypass, retry?.construction != construction || retry?.warmup != warmup { throw PreparationRefusal.revoked }
                let target = try PreparationTarget(identity: identity, build: evidence!)
                lastTarget = target
                if ledger!.entries.contains(where: { target.keys.contains($0.key) && $0.unresolved >= 2 && (!bypass || $0.key.p == .firstRealAudioRequest) }) {
                    publish(.paused, .paused); throw PreparationRefusal.paused
                }
                guard !ledger!.entries.contains(where: { $0.pending != nil }) || active != nil else { throw PreparationRefusal.busy }
                let permit = PreparationPermit(owner: self, target: target, consent: consent,
                    selection: selection, operation: operation, retry: bypass, grantEpoch: grantEpoch,
                    recovery: recovery, readOnly: policy == .readOnlyCatalog, observedTarget: identity.selection)
                try check(permit)
                if policy == .readOnlyCatalog {
                    guard let resident, resident.identity == identity,
                          resident.preparation.matches(permit, prepared: true) else {
                        throw PreparationRefusal.preparedResidentRequired
                    }
                }
                if active == nil { publish(.ready) }
                return permit
            } catch let reason as PreparationRefusal {
                if reason == .unsupportedSelection { publish(.unsupportedSelection, reason) }
                throw reason
            } catch { publish(.unsupportedSelection, .unsupportedSelection); throw PreparationRefusal.unsupportedSelection }
        }
    }
    fileprivate func check(_ permit: PreparationPermit) throws {
        guard !ioInFlight else { throw PreparationRefusal.busy }
        guard enabled, expandedConsent, !draftRevoked, !quit, !restart, !fault, consent == permit.consent, selection == permit.selection,
              permit.grantEpoch == grantEpoch, permit.recovery == recovery,
              permit.operation?.shouldAbort != true, permit.operation?.hasExited != true else { throw fault ? PreparationRefusal.trackingUnavailable : PreparationRefusal.revoked }
    }
    fileprivate func begin(_ permit: PreparationPermit, phase: PreparationPhase, attempt: UUID = UUID()) throws -> PreparationEntryToken {
        defer { changed?() }
        return try lock.withLock {
            try check(permit)
            guard !permit.used.contains(phase) else { throw PreparationRefusal.revoked }
            guard active == nil, var next = ledger else { throw PreparationRefusal.busy }
            guard !permit.readOnly else { throw PreparationRefusal.preparedResidentRequired }
            let key = permit.target.key(for: phase)
            if next.entries.contains(where: { permit.target.keys.contains($0.key) && $0.unresolved >= 2 && (!permit.retry || $0.key.p == .firstRealAudioRequest) }) {
                publish(.paused, .paused); throw PreparationRefusal.paused
            }
            if !next.entries.contains(where: { $0.key == key }) {
                guard next.entries.count < 12 else { unavailable(); throw PreparationRefusal.trackingUnavailable }
                next.entries.append(PreparationEntry(key: key))
            }
            guard let index = next.entries.firstIndex(where: { $0.key == key }), next.entries[index].pending == nil else { throw PreparationRefusal.busy }
            let pending = PreparationPending(attempt: attempt, launch: launch, operation: permit.operation?.id ?? permit.id, selection: selection)
            next.entries[index].pending = pending
            do { try commit(next, observing: observation(permit, phase: phase, attempt: attempt),
                            authorized: { permit.operation?.shouldAbort != true }) }
            catch { quarantine(); unavailable(); throw PreparationRefusal.trackingUnavailable }
            permit.used.insert(phase)
            if permit.retry { retry = nil }
            let token = PreparationEntryToken(owner: self, permit: permit, key: key, pending: pending)
            active = token; publish(.preparing)
            return token
        }
    }
    fileprivate func terminal(_ token: PreparationEntryToken, disposition: PreparationDisposition) throws {
        defer { changed?() }
        try lock.withLock { terminalLocked(token, disposition: disposition); if fault { throw PreparationRefusal.trackingUnavailable } }
    }
    private func terminalLocked(_ token: PreparationEntryToken, disposition: PreparationDisposition) {
        guard active === token, !token.retired else { return }
        token.retired = true
        guard var next = ledger, next.consent == token.permit.consent,
              let index = next.entries.firstIndex(where: { $0.key == token.key && $0.pending == token.pending }) else { unavailable(retirement: true); return }
        next.entries[index].pending = nil; next.entries[index].unresolved = 0
        next.entries[index].outcome = disposition
        next.entries[index].consumed = token.pending.attempt
        do { try commit(next, observing: observation(token.permit, phase: token.key.p, attempt: token.pending.attempt)); if !draftRevoked { resting() } }
        catch {
            // ONE bounded durable poison fallback. If it too fails and we die, pending is UNKNOWN and may count.
            quarantine()
            unavailable(retirement: true)
        }
    }
    fileprivate func exit(_ token: PreparationEntryToken) {
        defer { changed?() }
        lock.withLock {
            if active === token {
                active = nil
                if snapshotValue.status == .preparing { resting() }
            }
        }
    }
    fileprivate func constructed(_ permit: PreparationPermit, readiness: PreparationReadiness) throws {
        try lock.withLock { try check(permit); try readiness.constructed(permit) }
    }
    fileprivate func canBorrow(_ permit: PreparationPermit, readiness: PreparationReadiness) -> Bool {
        lock.withLock { (try? check(permit)) != nil && readiness.matches(permit, prepared: permit.readOnly) }
    }
    fileprivate func claimFirst(_ permit: PreparationPermit, readiness: PreparationReadiness) throws -> UUID? {
        try lock.withLock {
            try check(permit)
            guard active == nil, !permit.retry else { throw PreparationRefusal.busy }
            return try readiness.claim(permit)
        }
    }
    fileprivate func refuseFirst(_ permit: PreparationPermit, readiness: PreparationReadiness, attempt: UUID) {
        lock.withLock { readiness.finish(permit, attempt: attempt, completed: false) }
    }
    fileprivate func finishFirst(_ token: PreparationEntryToken, readiness: PreparationReadiness,
                                 native: RecognitionNativeOutcome, canceled: Bool) -> Bool {
        defer { changed?() }
        return lock.withLock {
            let authorized = !canceled && (try? check(token.permit)) != nil && !token.retired
            let disposition: PreparationDisposition
            if !authorized || native == .canceled { disposition = .canceled }
            else { switch native { case .completed: disposition = .completed; case .failed: disposition = .returnedFailure; case .canceled: disposition = .canceled } }
            terminalLocked(token, disposition: disposition)
            let delivery = authorized && !fault && (try? check(token.permit)) != nil
            let completed: Bool
            if case .completed = native { completed = delivery } else { completed = false }
            readiness.finish(token.permit, attempt: token.pending.attempt, completed: completed)
            return delivery
        }
    }
    fileprivate func completeWarmup(_ permit: PreparationPermit, readiness: PreparationReadiness) throws {
        try lock.withLock { try check(permit); readiness.completeWarmup(permit) }
    }
    fileprivate func validate(_ permit: PreparationPermit) throws { try lock.withLock { try check(permit) } }
}

fileprivate struct PreparationTarget: Equatable {
    let construction: PreparationKey, warmup: PreparationKey, first: PreparationKey
    init(identity: RecognitionIdentity, build: PreparationBuild) throws {
        construction = try PreparationKey(identity: identity, build: build, phase: .nativeConstruction)
        warmup = try PreparationKey(identity: identity, build: build, phase: .explicitSyntheticWarmup)
        first = try PreparationKey(identity: identity, build: build, phase: .firstRealAudioRequest)
    }
    var keys: [PreparationKey] { [construction, warmup, first] }
    func key(for phase: PreparationPhase) -> PreparationKey {
        switch phase {
        case .nativeConstruction: return construction
        case .explicitSyntheticWarmup: return warmup
        case .firstRealAudioRequest: return first
        }
    }
}

public final class PreparationPermit {
    fileprivate let owner: RecognitionPreparation, target: PreparationTarget
    fileprivate var construction: PreparationKey { target.construction }
    fileprivate let consent: UUID, selection: UUID, recovery: UUID, id = UUID()
    fileprivate let operation: PendingOperation?
    fileprivate let observedTarget: RecognitionSelection
    fileprivate let retry: Bool, readOnly: Bool
    fileprivate let grantEpoch: UUID
    fileprivate var used = Set<PreparationPhase>() // health-owner lock only
    public var preparationOnly: Bool { retry }
    fileprivate init(owner: RecognitionPreparation, target: PreparationTarget, consent: UUID,
                     selection: UUID, operation: PendingOperation?, retry: Bool, grantEpoch: UUID,
                     recovery: UUID, readOnly: Bool, observedTarget: RecognitionSelection) {
        self.owner = owner; self.target = target; self.consent = consent
        self.selection = selection; self.operation = operation; self.retry = retry
        self.grantEpoch = grantEpoch; self.recovery = recovery; self.readOnly = readOnly
        self.observedTarget = observedTarget
    }
    public func validate() throws { try owner.validate(self) }
    public func constructed(_ readiness: PreparationReadiness) throws { try owner.constructed(self, readiness: readiness) }
    public func canBorrow(_ readiness: PreparationReadiness) -> Bool { owner.canBorrow(self, readiness: readiness) }
    func firstRequest(readiness: PreparationReadiness, canceled: () -> Bool,
                      call: () async -> RecognitionNativeOutcome) async -> PreparationFirstRequestReceipt {
        // Arbitrary phase/client predicates may themselves read owner state. Always sample outside locks.
        guard !canceled() else { return .init(native: .canceled, deliveryAuthorized: false) }
        let attempt: UUID?
        do { attempt = try owner.claimFirst(self, readiness: readiness) }
        catch { return .init(native: .failed(.preparationUnavailable), deliveryAuthorized: false) }
        guard let attempt else {
            guard !canceled(), (try? validate()) != nil else { return .init(native: .canceled, deliveryAuthorized: false) }
            let result = await call()
            let stopped = canceled()
            return .init(native: result, deliveryAuthorized: !stopped && (try? validate()) != nil)
        }
        let token: PreparationEntryToken
        do { token = try owner.begin(self, phase: .firstRealAudioRequest, attempt: attempt) }
        catch {
            owner.refuseFirst(self, readiness: readiness, attempt: attempt)
            return .init(native: .failed(.preparationUnavailable), deliveryAuthorized: false)
        }
        let observation = operation?.observePreparationRevocation { [weak owner, weak token] in
            if let token { try? owner?.terminal(token, disposition: .canceled) }
        }
        defer { if let observation { operation?.removePreparationRevocation(observation) }; owner.exit(token) }
        guard !canceled(), (try? validate()) != nil else {
            _ = owner.finishFirst(token, readiness: readiness, native: .canceled, canceled: true)
            return .init(native: .canceled, deliveryAuthorized: false)
        }
        let result = await call()
        let stopped = canceled() // finalization observation wins readiness; later cancellation only suppresses delivery
        let delivery = owner.finishFirst(token, readiness: readiness, native: result, canceled: stopped)
        return .init(native: result, deliveryAuthorized: delivery)
    }
    /// This exact hook is invoked by the C initializer AFTER parameter validation, or fake bottom native.
    public func nativeEntry<T>(_ call: () throws -> T) throws -> T { try entry(.nativeConstruction, call: call, outcome: { _ in .completed }) }
    public func warmup(readiness: PreparationReadiness, call: () async -> RecognitionNativeOutcome) async throws -> RecognitionNativeOutcome {
        try validate()
        guard canBorrow(readiness) else { throw PreparationRefusal.revoked }
        if readiness.warmedFor(self) { return .completed(.init(text: "")) }
        let token = try owner.begin(self, phase: .explicitSyntheticWarmup)
        let observation = operation?.observePreparationRevocation { [weak owner, weak token] in
            if let token { try? owner?.terminal(token, disposition: .canceled) }
        }
        defer { if let observation { operation?.removePreparationRevocation(observation) }; owner.exit(token) }
        let result: RecognitionNativeOutcome
        do {
            try validate()
            result = await call()
            let disposition: PreparationDisposition
            switch result { case .completed: disposition = .completed; case .failed: disposition = .returnedFailure; case .canceled: disposition = .canceled }
            try owner.terminal(token, disposition: disposition)
        } catch {
            try owner.terminal(token, disposition: .returnedFailure)
            throw error
        }
        try validate()
        if case .completed = result { try owner.completeWarmup(self, readiness: readiness) }
        return result
    }
    private func entry<T>(_ phase: PreparationPhase, call: () throws -> T, outcome: (T) -> PreparationDisposition) throws -> T {
        let token = try owner.begin(self, phase: phase)
        let observation = operation?.observePreparationRevocation { [weak owner, weak token] in
            if let token { try? owner?.terminal(token, disposition: .canceled) }
        }
        defer { if let observation { operation?.removePreparationRevocation(observation) }; owner.exit(token) }
        do {
            try validate() // cancellation before entry retires without entering C
            let result = try call()
            try owner.terminal(token, disposition: outcome(result)) // before any adapter/post-acquisition bookkeeping
            return result
        } catch {
            try owner.terminal(token, disposition: .returnedFailure)
            throw error
        }
    }
}
fileprivate final class PreparationEntryToken {
    unowned let owner: RecognitionPreparation
    let permit: PreparationPermit, key: PreparationKey, pending: PreparationPending
    var retired = false // health-owner lock only; real-exit ownership remains until exit
    init(owner: RecognitionPreparation, permit: PreparationPermit, key: PreparationKey, pending: PreparationPending) {
        self.owner = owner; self.permit = permit; self.key = key; self.pending = pending
    }
}
