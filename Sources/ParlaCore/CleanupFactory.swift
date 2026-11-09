import Foundation

private func environmentKey(settings: Settings, env: [String: String]) -> String? {
    let name: String?
    switch settings.cleanup.provider {
    case "", "anthropic": name = "ANTHROPIC_API_KEY"
    case "openai-compatible": name = settings.cleanup.apiKeyEnvVar
    default: name = nil
    }
    guard let name, let value = env[name], !value.isEmpty else { return nil }
    return value
}

/// Private request material, never persisted in Settings or History.
public final class ResolvedCredential: CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let scope: CredentialScope
    fileprivate let key: String?
    public var description: String { "Resolved provider credential" }
    public var debugDescription: String { description }
    fileprivate init(scope: CredentialScope, key: String?) { self.scope = scope; self.key = key }
    func redacting(_ value: String) -> String {
        guard let key, !key.isEmpty else { return value }
        return value.replacingOccurrences(of: key, with: "[redacted]")
    }
}

/// Prepared access is request material, never a synthetic local credential scope.
public enum CleanupAccess {
    case network(ResolvedCredential)
    case onDevice(LocalCleanupConfiguration)
    func redacting(_ text: String) -> String {
        if case .network(let credential) = self { return credential.redacting(text) }
        return text
    }
}
public func prepareCleanupAccess(settings: Settings, env: @autoclosure () -> [String: String],
                                 credentials: @autoclosure () -> CredentialStore) throws -> CleanupAccess {
    if settings.usesAppleIntelligence { return .onDevice(LocalCleanupConfiguration(settings: settings)) }
    return .network(try resolveCleanupCredential(settings: settings, env: env(), credentials: credentials()))
}

/// Shared deliberate request boundary, also used by CLI and frozen retries.
public func resolveCleanupCredential(settings: Settings, env: [String: String],
                                     credentials: CredentialStore) throws -> ResolvedCredential {
    let scope = try CredentialScope.selected(settings)
    if let key = environmentKey(settings: settings, env: env) { return ResolvedCredential(scope: scope, key: key) }
    // Inline values are migration input only; they cannot drift to an edited endpoint.
    if (scope == .anthropic ? settings.anthropicApiKey : settings.cleanup.apiKey).map({ !$0.isEmpty }) == true {
        throw CredentialFailure("Your API key needs to move to Keychain. Open AI Cleanup and click Refresh.")
    }
    switch credentials.read(scope, interactive: true) {
    case .value(let key): return ResolvedCredential(scope: scope, key: key)
    case .missing:
        if scope == .anthropic { throw CredentialFailure("No API key. Add one in AI Cleanup.") }
        return ResolvedCredential(scope: scope, key: nil)
    case let result: throw CredentialFailure(result.status.message, status: result.status)
    }
}

/// Eligible B21 only: same precedence, with no interactive credential prompt.
func resolveOrdinaryFailoverPrimaryCredential(settings: Settings, env: [String: String],
                                     credentials: CredentialStore) throws -> ResolvedCredential {
    let scope = try CredentialScope.selected(settings)
    if let key = environmentKey(settings: settings, env: env) { return ResolvedCredential(scope: scope, key: key) }
    // Inline values are migration input only; they cannot drift to an edited endpoint.
    if (scope == .anthropic ? settings.anthropicApiKey : settings.cleanup.apiKey).map({ !$0.isEmpty }) == true {
        throw CredentialFailure("Your API key needs to move to Keychain. Open AI Cleanup and click Refresh.")
    }
    switch credentials.read(scope, interactive: false) {
    case .value(let key): return ResolvedCredential(scope: scope, key: key)
    case .missing:
        if scope == .anthropic { throw CredentialFailure("No API key. Add one in AI Cleanup.") }
        return ResolvedCredential(scope: scope, key: nil)
    case let result: throw CredentialFailure(result.status.message, status: result.status)
    }
}

/// No secret reads or interactive access. Broken/inaccessible remains configured.
public func cleanupIsConfigured(settings: Settings, env: @autoclosure () -> [String: String], credentials: @autoclosure () -> CredentialStore) -> Bool {
    if settings.usesAppleIntelligence { return settings.cleanupEnabled }
    guard settings.cleanupEnabled else { return false }
    switch settings.cleanup.provider {
    case "openai-compatible": return !(settings.cleanup.baseURL ?? "").isEmpty
    case "", "anthropic":
        return environmentKey(settings: settings, env: env()) != nil
            || !(settings.anthropicApiKey ?? "").isEmpty || credentials().status(.anthropic) != .missing
    default: return true
    }
}

public func cleanupConfigurationIssue(settings: Settings, env: @autoclosure () -> [String: String], credentials: @autoclosure () -> CredentialStore) -> String? {
    if settings.usesAppleIntelligence { return LocalCleanupConfiguration(settings: settings).validatedLocale == nil ? LocalCleanupReason.unknownLanguage.message : nil }
    do {
        let scope = try CredentialScope.selected(settings)
        if environmentKey(settings: settings, env: env()) != nil { return nil }
        if (scope == .anthropic ? settings.anthropicApiKey : settings.cleanup.apiKey).map({ !$0.isEmpty }) == true {
            return "Your API key needs to move to Keychain. Click Refresh or save the key again."
        }
        switch credentials().status(scope) {
        case .present: return nil
        case .missing: return scope == .anthropic ? "No API key is set." : nil
        case let state: return state.message
        }
    } catch { return "Check the cleanup service and base URL." }
}

public func cleanupCredentialSource(settings: Settings, env: @autoclosure () -> [String: String], credentials: @autoclosure () -> CredentialStore) -> String {
    if settings.usesAppleIntelligence { return "No API key needed." }
    if environmentKey(settings: settings, env: env()) != nil {
        return "Using the API key from an environment variable."
    }
    guard let scope = try? CredentialScope.selected(settings) else { return "Choose a cleanup service and base URL first." }
    return credentials().status(scope).message
}

/// Warm requests carry no credentials, and cannot authorize a Keychain prompt.
public func cleanupWarmURL(settings: Settings, env: @autoclosure () -> [String: String], credentials: @autoclosure () -> CredentialStore) -> URL? {
    if settings.usesAppleIntelligence { return nil }
    guard cleanupIsConfigured(settings: settings, env: env(), credentials: credentials()) else { return nil }
    return (try? CredentialScope.selected(settings)).flatMap { URL(string: $0.baseURL) }
}

public func makeCleanupClient(
    settings: Settings, env: @autoclosure () -> [String: String], credentials: @autoclosure () -> CredentialStore,
    access: CleanupAccess? = nil, http: @autoclosure () -> HTTPPosting = URLSessionPoster(),
    localRuntime: LocalCleanupRuntime = LocalCleanupRuntime(),
    executionPolicy: HistoryRetryExecutionPolicy? = nil,
    usage: @escaping CleanupUsageSink = recordCleanupUsage, redactUsage: Bool = true
) throws -> CleanupProviding {
    if settings.usesAppleIntelligence {
        let config = LocalCleanupConfiguration(settings: settings)
        if let access {
            guard case .onDevice(let frozen) = access, frozen == config else { throw LocalCleanupReason.unavailable.error }
        }
        return AppleIntelligenceCleanup(configuration: config, runtime: localRuntime, usage: usage, executionPolicy: executionPolicy)
    }
    let scope = try CredentialScope.selected(settings)
    let prepared = try access ?? prepareCleanupAccess(settings: settings, env: env(), credentials: credentials())
    guard case .network(let resolved) = prepared else { throw CredentialFailure("Cleanup settings changed. Try again.") }
    let safeUsage: CleanupUsageSink = { model, input, output in usage(redactUsage ? resolved.redacting(model) : model, input, output) }
    guard resolved.scope == scope else { throw CredentialFailure("Cleanup settings changed. Try again.") }
    let poster = http()
    guard executionPolicy == nil || poster is HistoryRetryHTTP else { throw SegmentedRetryFailure.configuration }
    switch settings.cleanup.provider {
    case "openai-compatible":
        let trimmed = settings.cleanup.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CredentialSafeProvider(base: OpenAICompatClient(baseURL: scope.baseURL, apiKey: resolved.key,
                                  model: (trimmed?.isEmpty ?? true) ? nil : trimmed, http: poster, usage: safeUsage, executionPolicy: executionPolicy), access: resolved)
    default:
        guard let key = resolved.key else { throw CredentialFailure("No API key is set.") }
        let model = settings.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Settings().cleanupModel : settings.cleanupModel
        return CredentialSafeProvider(base: CleanupClient(apiKey: key, model: model, http: poster, usage: safeUsage, executionPolicy: executionPolicy), access: resolved)
    }
}

/// Provider bodies and transport errors are untrusted and may echo Authorization.
/// Preserve fallback categories, but never pass the resolved key to logs/status.
private struct CredentialSafeProvider: CleanupProviding, DiagnosticModelObserving {
    let base: CleanupProviding
    let access: ResolvedCredential
    func observing(_ diagnostics: DiagnosticOperation) -> CleanupProviding {
        CredentialSafeProvider(base: (base as? DiagnosticModelObserving)?.observing(diagnostics) ?? base, access: access)
    }
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        do { return try await base.clean(transcript: transcript, context: context) }
        catch let error as CleanupError {
            throw CleanupError(description: access.redacting(error.description), userMessage: access.redacting(error.userMessage), statusCode: error.statusCode, stopReason: error.stopReason)
        } catch let error as URLError { throw URLError(error.code) }
        catch let error as SegmentedRetryFailure { throw error }
        catch let error as CleanupFailoverFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw CredentialFailure("Provider request failed.") }
    }
}

/// Pinned lazy backup access. No status lookup, interactive read or source fallback.
func resolveCleanupBackupCredential(_ backup: CleanupBackup, settings: Settings, env: [String: String], credentials: CredentialStore) throws -> ResolvedCredential {
    try backup.validate()
    let scope = try CredentialScope.selected(settings)
    guard !(settings.anthropicApiKey.map { !$0.isEmpty } ?? false), !(settings.cleanup.apiKey.map { !$0.isEmpty } ?? false) else {
        throw CredentialFailure("Your API key needs to move to Keychain. Open AI Cleanup and click Refresh.")
    }
    let key: String?
    switch backup.source {
    case .namedEnvironment:
        guard let name = backup.environmentName, let value = env[name], !value.isEmpty else { throw CleanupFailoverFailure.credential }
        key = value
    case .scopedKeychain:
        guard case .value(let value) = credentials.read(scope, interactive: false), !value.isEmpty else { throw CleanupFailoverFailure.credential }
        key = value
    case .keylessCompatible:
        guard backup.provider == "openai-compatible" else { throw CleanupFailoverFailure.configuration }; key = nil
    }
    return ResolvedCredential(scope: scope, key: key)
}

/// Only actual ordinary capture callers may supply this explicit origin and grant.
/// Ineligible/off/paused routes retain the primitive and its original defaults.
public func makeOrdinaryCleanupClient(settings: Settings, origin: CleanupFailoverOrigin,
    grant: CleanupFailoverGrant?, operationID: UUID, store: SettingsStore,
    env: [String: String], credentials: CredentialStore, http: HTTPPosting = URLSessionPoster(),
    primaryDriver: @escaping HistoryRetryHTTP.Driver = HistoryRetryURLSession.init,
    backupDriver: @escaping HistoryRetryHTTP.Driver = HistoryRetryURLSession.init,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: ((TimeInterval) async throws -> Void)? = nil,
    run: CleanupFailoverRun, shouldContinue: @escaping () -> Bool,
    usage: @escaping CleanupUsageSink = recordCleanupUsage) throws -> CleanupProviding {
    guard settings.outputMode == .cleanup, settings.cleanupEnabled, !settings.usesAppleIntelligence,
          let policy = settings.cleanupFailover, policy.isReviewed(for: settings), let grant,
          grant.operationID == operationID, grant.revision == policy.review?.revision, grant.digest == policy.review?.digest else {
        return try makeCleanupClient(settings: settings, env: env, credentials: credentials, http: http, usage: usage)
    }
    let budget = HistoryRetryExecutionPolicy(planned: 1 + policy.backups.count, budget: 15, now: now,
        sleep: sleep ?? HistoryRetryExecutionPolicy.defaultSleep)
    return OrdinaryFailoverProvider(settings: settings, environment: env, credentials: credentials, store: store,
        grant: grant, operationID: operationID, policy: budget, primaryDriver: primaryDriver, backupDriver: backupDriver,
        run: run, shouldContinue: shouldContinue)
}

/// An independently admitted context PRIMARY. B21's admission type is only a
/// mechanical carrier; no backup grant or primary-survival semantics are used.
public func makeSurroundingTextCleanupClient(settings: Settings, access: CleanupAccess,
    grant: SurroundingTextGrant, operationID: UUID, store: SettingsStore,
    run: SurroundingTextRun, policy: HistoryRetryExecutionPolicy,
    driver: @escaping HistoryRetryHTTP.Driver, localRuntime: LocalCleanupRuntime = LocalCleanupRuntime(),
    shouldContinue: @escaping () -> Bool) throws -> CleanupProviding {
    func check() throws {
        try policy.check(); try run.check()
        guard shouldContinue(), try SurroundingTextAuthority.primary(settings) == grant.policy.primary else { throw SurroundingTextFailure.refused }
    }
    if settings.usesAppleIntelligence {
        return try store.withSurroundingTextGrant(grant, operationID: operationID) {
            try check()
            return try makeCleanupClient(settings: settings, env: [:], credentials: store.credentials, access: access, localRuntime: localRuntime,
                executionPolicy: policy, usage: { _, _, _ in }, redactUsage: false)
        }
    }
    // Refuse an oversized borrowed credential before constructing header copies.
    // HistoryRetryHTTP still checks the exact aggregate serialized header budget.
    guard case .network(let credential) = access,
          (credential.key?.utf8.count ?? 0) <= 16 * 1024 else { throw SurroundingTextFailure.refused }
    let admission = CleanupFailoverHTTPAdmission(enter: { action in
        try store.withSurroundingTextGrant(grant, operationID: operationID) { try check(); try action() }
    }, subscribe: { cancel in
        try store.subscribeSurroundingText(grant, operationID: operationID) { run.revoke(); cancel() }
    }, started: {})
    return try store.withSurroundingTextGrant(grant, operationID: operationID) {
        try check()
        return try makeCleanupClient(settings: settings, env: [:], credentials: store.credentials, access: access,
            http: HistoryRetryHTTP(policy: policy, driver: driver, failoverAdmission: admission), executionPolicy: policy,
            usage: { model, _, _ in run.observeModel(model, requested: grant.policy.primary.model) }, redactUsage: false)
    }
}
