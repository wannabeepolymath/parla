import Foundation
import ParlaCore

final class FakeCredentialBackend: CredentialBackend {
    var values: [CredentialScope: String] = [:]
    var readState: CredentialRead?
    var statusState: CredentialStatus?
    var addResult: CredentialMutation?
    var updateResult: CredentialMutation?
    var deleteResult: CredentialMutation?
    var onAdd: (() -> Void)?
    var onRead: (() -> Void)?
    var reads = 0
    var statuses = 0
    var adds = 0
    var updates = 0
    var deletes = 0
    var interactiveReads: [Bool] = []
    func status(_ scope: CredentialScope) -> CredentialStatus {
        statuses += 1
        return statusState ?? (values[scope] == nil ? .missing : .present)
    }
    func read(_ scope: CredentialScope, interactive: Bool) -> CredentialRead {
        reads += 1; interactiveReads.append(interactive); onRead?()
        return readState ?? values[scope].map(CredentialRead.value) ?? .missing
    }
    func add(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation {
        adds += 1; onAdd?()
        if let addResult { return addResult }
        if values[scope] != nil { return .duplicate }
        values[scope] = value; return .success
    }
    func update(_ value: String, scope: CredentialScope, interactive: Bool) -> CredentialMutation {
        updates += 1
        if let updateResult { return updateResult }
        values[scope] = value; return .success
    }
    func delete(_ scope: CredentialScope) -> CredentialMutation {
        deletes += 1
        if let deleteResult { return deleteResult }
        values.removeValue(forKey: scope); return .success
    }
}

func testCredentialStore(_ settings: Settings = Settings()) -> CredentialStore {
    let backend = FakeCredentialBackend()
    backend.values[.anthropic] = settings.anthropicApiKey
    if let scope = try? CredentialScope.compatible(settings.cleanup.baseURL) { backend.values[scope] = settings.cleanup.apiKey }
    return CredentialStore(backend: backend)
}

func withoutLegacy(_ settings: Settings) -> Settings {
    var clean = settings; clean.anthropicApiKey = nil; clean.cleanup.apiKey = nil; return clean
}

// Compatibility tests still exercise the real factory; legacy fixtures supply
// an isolated fake backend instead of using a user's Keychain implicitly.
func makeCleanupClient(settings: Settings, env: [String: String], http: HTTPPosting = URLSessionPoster(),
                       usage: @escaping CleanupUsageSink = recordCleanupUsage) throws -> CleanupProviding {
    try ParlaCore.makeCleanupClient(settings: withoutLegacy(settings), env: env,
                                    credentials: testCredentialStore(settings), http: http, usage: usage)
}
func cleanupIsConfigured(settings: Settings, env: [String: String]) -> Bool {
    ParlaCore.cleanupIsConfigured(settings: withoutLegacy(settings), env: env, credentials: testCredentialStore(settings))
}
func cleanupWarmURL(settings: Settings, env: [String: String]) -> URL? {
    ParlaCore.cleanupWarmURL(settings: withoutLegacy(settings), env: env, credentials: testCredentialStore(settings))
}

extension HistoryRetryRequest {
    init(settings: Settings, environment: [String: String], source: HistoryEntry, applyPreset: Bool) throws {
        try self.init(settings: withoutLegacy(settings), environment: environment, source: source,
                      applyPreset: applyPreset, credentials: testCredentialStore(settings))
    }
}
extension SettingsStore {
    func saveTestSettings(_ settings: Settings) throws {
        if let key = settings.anthropicApiKey { try credentials.replace(key, scope: .anthropic) }
        if let key = settings.cleanup.apiKey { try credentials.replace(key, scope: .compatible(settings.cleanup.baseURL)) }
        try save(withoutLegacy(settings))
    }
}

func testStoredKey(_ credentials: CredentialStore, _ scope: CredentialScope) -> String? {
    if case .value(let key) = credentials.read(scope, interactive: false) { return key }
    return nil
}
