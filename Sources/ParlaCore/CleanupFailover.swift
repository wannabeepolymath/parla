import Foundation
import CryptoKit

/// Explicit origins only. The single-provider factory never infers eligibility.
public enum CleanupFailoverOrigin: String, Sendable { case physicalOrdinary, shortcutsOrdinary }
public enum CleanupFailoverFailure: String, Error, Codable, Sendable {
    case configuration, changed, paused, revoked, credential, deadline, canceled, insufficientTime
}
public enum CleanupBackupSource: String, Codable, CaseIterable, Sendable {
    case namedEnvironment, scopedKeychain, keylessCompatible
}
public struct CleanupBackup: Codable, Equatable, Sendable {
    public var provider: String
    public var baseURL: String?
    public var model: String
    public var source: CleanupBackupSource
    public var environmentName: String?
    public init(provider: String = "openai-compatible", baseURL: String? = nil, model: String = "",
                source: CleanupBackupSource = .scopedKeychain, environmentName: String? = nil) {
        self.provider = provider; self.baseURL = baseURL; self.model = model
        self.source = source; self.environmentName = environmentName
    }
    public func settings(preserving original: Settings) throws -> Settings {
        try validate()
        var value = original
        value.cleanup.provider = provider; value.cleanup.baseURL = baseURL
        value.cleanup.model = model; value.cleanupModel = model
        // Retain legacy values: they must refuse, never be stripped to enable a request.
        value.cleanup.apiKeyEnvVar = environmentName
        return value
    }
    public func validate() throws {
        guard ["anthropic", "openai-compatible"].contains(provider), CleanupChainIdentity.validModel(model),
              (baseURL?.utf8.count ?? 0) <= 4096 else { throw CleanupFailoverFailure.configuration }
        if provider == "anthropic" {
            guard baseURL == nil, source != .keylessCompatible else { throw CleanupFailoverFailure.configuration }
        } else { _ = try CredentialScope.compatible(baseURL) }
        if source == .namedEnvironment {
            guard let environmentName, !environmentName.isEmpty, environmentName.utf8.count <= 128,
                  environmentName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                  !(environmentName.utf8.first.map { (48...57).contains($0) } ?? true) else { throw CleanupFailoverFailure.configuration }
        } else if environmentName != nil { throw CleanupFailoverFailure.configuration }
    }
    public func identity() throws -> CleanupChainIdentity {
        try validate()
        let scope = provider == "anthropic" ? CredentialScope.anthropic : try CredentialScope.compatible(baseURL)
        return .init(provider: provider, endpoint: scope.baseURL, model: model,
                     source: source.rawValue + (environmentName.map { ":" + $0 } ?? "") + ":" + scope.account,
                     access: CleanupChainIdentity.accessClass(scope.baseURL))
    }
}
/// Names and canonical destinations, never credential values. Precedence is the
/// primary's complete unchanged resolution policy, not a guessed winning source.
public struct CleanupChainIdentity: Codable, Equatable, Sendable {
    public let provider: String, endpoint: String, model: String, source: String, access: String
    public static func primary(_ settings: Settings) throws -> Self {
        let scope = try CredentialScope.selected(settings)
        guard scope.baseURL.utf8.count <= 4096 else { throw CleanupFailoverFailure.configuration }
        let compatible = settings.cleanup.provider == "openai-compatible"
        let model = compatible ? (settings.cleanup.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : settings.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Settings().cleanupModel : settings.cleanupModel
        guard validModel(model) else { throw CleanupFailoverFailure.configuration }
        let environment = compatible ? settings.cleanup.apiKeyEnvVar : "ANTHROPIC_API_KEY"
        if let environment { guard !environment.isEmpty, environment.utf8.count <= 128,
            environment.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw CleanupFailoverFailure.configuration } }
        return .init(provider: compatible ? "openai-compatible" : "anthropic", endpoint: scope.baseURL, model: model,
                     source: "precedence:" + (environment.map { "environment:" + $0 + ">" } ?? "") + "legacy-refusal>scopedKeychain:" + scope.account + (compatible ? ">keyless" : ">missing-stop"),
                     access: accessClass(scope.baseURL))
    }
    static func validModel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,47,58,95].contains($0)
        }
    }
    static func accessClass(_ base: String) -> String {
        let host = URLComponents(string: base)?.host?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? "loopback-network" : "network"
    }
    var destination: String { provider + "\n" + endpoint + "\n" + model }
}
public struct CleanupFailoverPolicy: Codable, Equatable, Sendable {
    public let version: Int
    public var backups: [CleanupBackup]
    public var review: Review?
    public struct Review: Codable, Equatable, Sendable {
        public let primary: CleanupChainIdentity
        public let digest: String
        public let revision: UUID
    }
    public init(backups: [CleanupBackup] = []) { version = 1; self.backups = backups; review = nil }
    public func validate() throws {
        guard version == 1, backups.count <= 2 else { throw CleanupFailoverFailure.configuration }
        for backup in backups { try backup.validate() }
        let identities = try backups.map { try $0.identity().destination }
        guard Set(identities).count == identities.count else { throw CleanupFailoverFailure.configuration }
        if let review {
            guard review.digest.utf8.count == 64, review.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  CleanupChainIdentity.validModel(review.primary.model), review.primary.endpoint.utf8.count <= 4096,
                  review.primary.source.utf8.count <= 8192,
                  ["network", "loopback-network"].contains(review.primary.access),
                  ["anthropic", "openai-compatible"].contains(review.primary.provider) else { throw CleanupFailoverFailure.configuration }
        }
    }
    public func digest(primary: CleanupChainIdentity) throws -> String {
        try validate()
        let identities = [primary] + (try backups.map { try $0.identity() })
        guard !backups.isEmpty, Set(identities.map(\.destination)).count == identities.count else { throw CleanupFailoverFailure.configuration }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        struct Contract: Encodable { let contract: String; let identities: [CleanupChainIdentity] }
        return SHA256.hash(data: try encoder.encode(Contract(contract: "ordinary-bounded-result-owned-drain-v2", identities: identities))).map { String(format: "%02x", $0) }.joined()
    }
    public func isReviewed(for settings: Settings) -> Bool {
        guard let review, let primary = try? CleanupChainIdentity.primary(settings), primary == review.primary else { return false }
        return (try? digest(primary: primary)) == review.digest
    }
    public mutating func confirm(primary: CleanupChainIdentity) throws {
        review = Review(primary: primary, digest: try digest(primary: primary), revision: UUID())
    }
}
public struct CleanupFailoverGrant: Equatable, Sendable {
    let epoch: UInt64, revision: UUID, digest: String
    public private(set) var operationID: UUID?
    public func bound(to id: UUID) -> Self {
        precondition(operationID == nil || operationID == id)
        var value = self; value.operationID = id; return value
    }
}
/// Review owns exact original bytes; a confirmation cannot flush or rebase them.
public struct CleanupFailoverReview {
    let original: Data
    public let policy: CleanupFailoverPolicy
    public let primary: CleanupChainIdentity
}
public struct CleanupFailoverEvidence: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case preparing, returned, transient, stopped, canceled, deadline, revoked, invalidResult }
    public struct Attempt: Codable, Equatable, Sendable {
        public var provider: DiagnosticProvider
        public var requested: DiagnosticProviderModel = .unavailable
        public var resolved: DiagnosticProviderModel = .unavailable
        public var requestStarted = false
        public var outcome: Outcome = .preparing
        public var inputTokens: Int?, outputTokens: Int?
    }
    public var attempts: [Attempt] = []
    public var candidateOrdinal: Int?, acceptedProducerOrdinal: Int?
    public var remoteBillingUnknown = true
}
/// Per-operation metrics. Even an empty result is owned, never a global slot.
public final class CleanupFailoverRun: @unchecked Sendable {
    private let lock = NSLock()
    private var evidence = CleanupFailoverEvidence()
    private var diagnostic: DiagnosticOperation?
    private var acceptance: (() throws -> Void)?
    private let publication = NSLock()
    private let admit: () async -> Bool
    private var worker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var active = false, frozen = false, sealed = false
    private var failure: Error?
    private var deadline: TimeInterval = .infinity
    private var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public init(admit: @escaping () async -> Bool = { true }) { self.admit = admit }

    /// Logical completion is separate from actual exit. The finalizer MUST drain.
    func start(policy: HistoryRetryExecutionPolicy, check: @escaping () throws -> Void,
               work: @escaping () async throws -> String) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            lock.withLock { precondition(!active); active = true; deadline = policy.deadline; now = policy.now }
            do {
                try check()
                guard await admit() else { throw CleanupFailoverFailure.canceled }
                try check()
                // Install under the lock: immediate completion/cancel cannot lose
                // a handle. No external work is invoked while this lock is held.
                lock.withLock {
                    guard !sealed else { return }
                    worker = Task {
                        do { try self.handoff(.success(try await work())) }
                        catch { self.close(error) }
                    }
                    watchdog = Task {
                        do {
                            try await policy.sleep(max(0, policy.deadline - policy.now()))
                            if !Task.isCancelled, policy.now() >= policy.deadline {
                                self.close(CleanupFailoverFailure.deadline)
                                policy.stop(.deadline)
                            }
                        } catch { /* owned and joined by drain */ }
                    }
                }
            } catch { close(error) }
            return try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<String, Error>? in
                    if let result { return result }
                    waiter = continuation; return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }, onCancel: { self.close(CleanupFailoverFailure.canceled); policy.stop(.canceled) })
    }
    private func handoff(_ value: Result<String, Error>) throws {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard result == nil, !sealed else { return nil }
            result = value; frozen = true
            defer { waiter = nil }; return waiter
        }
        publish()
        continuation?.resume(with: value)
    }
    /// Closes candidate authority BEFORE releasing the caller or canceling work.
    private func close(_ error: Error) {
        let state = lock.withLock { () -> (CheckedContinuation<String, Error>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !sealed else { return (nil, nil, nil) }
            sealed = true; frozen = true; failure = error; acceptance = nil
            evidence.acceptedProducerOrdinal = nil
            if !evidence.attempts.isEmpty { evidence.attempts[evidence.attempts.count - 1].outcome = Self.terminal(error) }
            var continuation: CheckedContinuation<String, Error>?
            if result == nil { result = .failure(error); continuation = waiter; waiter = nil }
            return (continuation, worker, watchdog)
        }
        publish()
        state.0?.resume(throwing: error)
        state.1?.cancel(); state.2?.cancel()
    }
    public func drain() async {
        let handles = lock.withLock { (worker, watchdog) }
        await handles.0?.value
        await handles.1?.value
        lock.withLock { worker = nil; watchdog = nil; waiter = nil; acceptance = nil }
    }
    func observe(_ diagnostic: DiagnosticOperation) { lock.withLock { self.diagnostic = diagnostic }; publish() }
    private func publish() {
        // Serial snapshot + update prevents a pre-seal publication overtaking it.
        publication.withLock {
            let (value, diagnostic) = lock.withLock { (evidence, self.diagnostic) }
            diagnostic?.update { $0.cleanupFailover = value }
        }
    }
    func begin(_ settings: Settings) -> Int {
        let index = lock.withLock { () -> Int in
            guard !frozen else { return -1 }
            let index = evidence.attempts.count; precondition(index < 3)
            evidence.attempts.append(.init(provider: settings.cleanup.provider == "openai-compatible" ? .openAICompatible : .anthropic,
                requested: DiagnosticProviderModel(rawValue: (try? CleanupChainIdentity.primary(settings).model) ?? "") ?? .unavailable))
            return index
        }; publish(); return index
    }
    func started(_ index: Int) { lock.withLock { if !frozen, evidence.attempts.indices.contains(index) { evidence.attempts[index].requestStarted = true } }; publish() }
    func outcome(_ index: Int, _ outcome: CleanupFailoverEvidence.Outcome) { lock.withLock { if !frozen, evidence.attempts.indices.contains(index) { evidence.attempts[index].outcome = outcome } }; publish() }
    func usage(_ index: Int, model: String, input: Int?, output: Int?) {
        lock.withLock {
            guard !frozen, evidence.attempts.indices.contains(index) else { return }
            evidence.attempts[index].resolved = DiagnosticProviderModel(rawValue: model) ?? .unavailable
            evidence.attempts[index].inputTokens = input.flatMap { $0 >= 0 ? $0 : nil }
            evidence.attempts[index].outputTokens = output.flatMap { $0 >= 0 ? $0 : nil }
        }; publish()
    }
    func candidate(_ index: Int, acceptance: @escaping () throws -> Void) {
        lock.withLock { if !frozen { evidence.candidateOrdinal = index; self.acceptance = acceptance } }; publish()
    }
    public func adjudicate(accepted: Bool) throws {
        let state = lock.withLock { (active, sealed, failure, acceptance) }
        // Evidence-only callers can adjudicate a populated candidate without
        // starting owned work. Untouched bypass runs remain a no-op.
        guard state.0 || state.3 != nil else { return }
        if let error = state.2 { throw error }
        if state.1 { return }
        if accepted {
            do { try state.3?() }
            catch { close(error); throw error }
        }
        let watch: Task<Void, Never>?
        do {
            watch = try lock.withLock { () throws -> Task<Void, Never>? in
                if let failure { throw failure }
                guard !sealed else { return nil }
                // External grant checks above may take time or race cancellation.
                // Recheck the local clock and latch atomically at the final seal.
                // Never call SettingsStore or policy.stop while holding this lock.
                guard now() < deadline else { throw CleanupFailoverFailure.deadline }
                guard !Task.isCancelled else { throw CleanupFailoverFailure.canceled }
                sealed = true; frozen = true; acceptance = nil
                evidence.acceptedProducerOrdinal = accepted ? evidence.candidateOrdinal : nil
                if !accepted, let i = evidence.candidateOrdinal { evidence.attempts[i].outcome = .invalidResult }
                return watchdog
            }
        } catch { close(error); throw error }
        publish(); watch?.cancel()
    }
    static func terminal(_ error: Error) -> CleanupFailoverEvidence.Outcome {
        if error is CancellationError { return .canceled }
        if let failure = error as? SegmentedRetryFailure {
            if failure == .deadline { return .deadline }
            if failure == .canceled { return .canceled }
        }
        if let failure = error as? CleanupFailoverFailure {
            if failure == .revoked || failure == .changed || failure == .paused { return .revoked }
            if failure == .deadline || failure == .insufficientTime { return .deadline }
            if failure == .canceled { return .canceled }
        }
        return cleanupFailoverMayProceed(error) ? .transient : .stopped
    }
    public var metrics: PipelineMetrics {
        lock.withLock {
            var metrics = PipelineMetrics()
            guard let i = evidence.acceptedProducerOrdinal else { return metrics }
            let attempt = evidence.attempts[i]
            metrics.cleanupModel = i == 0 ? "Experimental primary; model identity unverified; unpriced"
                : attempt.provider == .anthropic ? "Anthropic backup; model identity unverified; unpriced" : "Compatible backup; model identity unverified; unpriced"
            metrics.promptTokens = attempt.inputTokens; metrics.completionTokens = attempt.outputTokens
            return metrics
        }
    }
    public var participated: Bool { lock.withLock { active } }
    public var snapshot: CleanupFailoverEvidence { lock.withLock { evidence } }
}
public func cleanupFailoverMayProceed(_ error: Error) -> Bool {
    if error is CancellationError || error is CredentialFailure || error is SegmentedRetryFailure || error is CleanupFailoverFailure { return false }
    if let error = error as? CleanupError {
        guard error.stopReason == nil, let status = error.statusCode else { return false }
        return status == 408 || status == 429 || (500...599).contains(status)
    }
    guard let error = error as? URLError else { return false }
    return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
}
/// Synchronous app check-and-initiate boundary. The store serializes observed
/// revocation with the action, never an await or arbitrary external editors.
public struct CleanupFailoverHTTPAdmission {
    let enter: (() throws -> Void) throws -> Void
    let subscribe: (@escaping () -> Void) throws -> (() -> Void)
    let started: () -> Void
}
struct OrdinaryFailoverProvider: CleanupProviding, DiagnosticModelObserving {
    let settings: Settings, environment: [String: String], credentials: CredentialStore, store: SettingsStore
    let grant: CleanupFailoverGrant, operationID: UUID, policy: HistoryRetryExecutionPolicy
    let primaryDriver: HistoryRetryHTTP.Driver, backupDriver: HistoryRetryHTTP.Driver, run: CleanupFailoverRun
    let shouldContinue: () -> Bool
    var diagnostic: DiagnosticOperation?
    func observing(_ diagnostics: DiagnosticOperation) -> CleanupProviding { var copy = self; copy.diagnostic = diagnostics; run.observe(diagnostics); return copy }
    func check() throws { try policy.check(); guard shouldContinue() else { throw CleanupFailoverFailure.canceled } }
    func backupAuthority(_ action: () throws -> Void = {}) throws {
        try check()
        try store.withCleanupFailoverGrant(grant, operationID: operationID, action)
    }
    func backupBoundary(_ action: () throws -> Void = {}) throws {
        guard try policy.remaining() >= 3 else { throw CleanupFailoverFailure.insufficientTime }
        try backupAuthority(action)
    }
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        guard context.selection == nil else { throw CleanupFailoverFailure.configuration }
        return try await run.start(policy: policy, check: check) {
            let primaryIndex = run.begin(settings)
            var last: Error
            do {
                try check()
                let access = CleanupAccess.network(try resolveOrdinaryFailoverPrimaryCredential(settings: settings, env: environment, credentials: credentials))
                try check()
                let admission = CleanupFailoverHTTPAdmission(enter: { action in try check(); try action() },
                    subscribe: { _ in {} }, started: { run.started(primaryIndex) })
                let client = try makeCleanupClient(settings: settings, env: environment, credentials: credentials, access: access,
                    http: HistoryRetryHTTP(policy: policy, driver: primaryDriver, failoverAdmission: admission), executionPolicy: policy,
                    usage: { model, input, output in run.usage(primaryIndex, model: model, input: input, output: output) })
                let text = try await client.clean(transcript: transcript, context: context)
                try check(); run.outcome(primaryIndex, .returned)
                run.candidate(primaryIndex, acceptance: { try check() }); return text
            } catch {
                last = error; run.outcome(primaryIndex, CleanupFailoverRun.terminal(error))
            }
            for backup in settings.cleanupFailover!.backups {
                // Authority/cancel/deadline outrank classification, before any source read.
                try backupBoundary()
                guard cleanupFailoverMayProceed(last) else { throw last }
                let selected = try backup.settings(preserving: settings)
                let index = run.begin(selected)
                do {
                    var access: CleanupAccess?
                    try backupBoundary()
                    access = .network(try resolveCleanupBackupCredential(backup, settings: selected, env: environment, credentials: credentials))
                    try backupBoundary()
                    let admission = CleanupFailoverHTTPAdmission(enter: { action in try backupBoundary(action) }, subscribe: { cancel in
                        try store.registerCleanupFailoverCancellation(grant, operationID: operationID, cancel: cancel)
                    }, started: { run.started(index) })
                    var client: CleanupProviding?
                    try backupBoundary {
                        client = try makeCleanupClient(settings: selected, env: environment, credentials: credentials, access: access,
                            http: HistoryRetryHTTP(policy: policy, driver: backupDriver, failoverAdmission: admission), executionPolicy: policy,
                            usage: { model, input, output in run.usage(index, model: model, input: input, output: output) })
                    }
                    let text = try await client!.clean(transcript: transcript, context: context)
                    try backupAuthority(); run.outcome(index, .returned)
                    run.candidate(index, acceptance: { try backupAuthority() }); return text
                } catch {
                    last = error; run.outcome(index, CleanupFailoverRun.terminal(error))
                }
            }
            throw last
        }
    }
}
