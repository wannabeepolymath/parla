import XCTest
@testable import ParlaCore

// Routing is verified by issuing a clean() against MockHTTP and inspecting the
// request the factory-built client produces — no network, no schema guessing.
final class CleanupFactoryTests: XCTestCase {
    let ctx = CleanupContext(dictionary: [], snippets: [:], appName: nil)

    private func mock() -> MockHTTP {
        let http = MockHTTP()
        http.body = Data(#"{"content":[{"type":"text","text":"ok"}],"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        return http
    }

    func testAnthropicDefaultUsesLegacyKeyAndModel() async throws {
        var s = Settings()
        s.anthropicApiKey = "legacy-key"
        s.cleanupModel = "claude-haiku-4-5"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)

        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "legacy-key")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
    }

    func testAnthropicEmptyModelUsesBuiltInDefault() async throws {
        var s = Settings()
        s.anthropicApiKey = "k"
        s.cleanupModel = ""
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)

        let json = try JSONSerialization.jsonObject(with: http.lastRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, Settings().cleanupModel)
    }

    func testAnthropicEnvKeyBeatsLegacy() async throws {
        var s = Settings()
        s.anthropicApiKey = "legacy-key"
        let http = mock()
        let client = try makeCleanupClient(
            settings: s, env: ["ANTHROPIC_API_KEY": "env-key"], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "env-key")
    }

    func testEnvVarKeyBeatsInlineApiKey() async throws {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://localhost:11434/v1"
        s.cleanup.model = "llama3"
        s.cleanup.apiKeyEnvVar = "MY_KEY"
        s.cleanup.apiKey = "inline-key"
        let http = mock()
        let client = try makeCleanupClient(
            settings: s, env: ["MY_KEY": "env-var-key"], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer env-var-key")
    }

    // Both providers' settings coexist; anthropic reads only its own fields.
    func testAnthropicIgnoresOpenAICompatFields() async throws {
        var s = Settings()
        s.anthropicApiKey = "anthropic-key"
        s.cleanupModel = "claude-haiku-4-5"
        s.cleanup.model = "llama3"
        s.cleanup.apiKey = "openai-key"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        let req = http.lastRequest!
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
    }

    func testAnthropicMissingKeyThrowsEvenWithOpenAICompatKey() {
        var s = Settings()
        s.cleanup.apiKey = "openai-key"  // wrong provider's key must not satisfy anthropic
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:]))
        XCTAssertNil(cleanupWarmURL(settings: s, env: [:]))
    }

    func testAnthropicMissingKeyThrows() {
        let s = Settings()  // no key anywhere
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:])) { error in
            XCTAssertTrue("\(error)".lowercased().contains("key"))
        }
    }

    func testCleanupWarmURLMatchesConfiguredProvider() {
        var s = Settings()
        XCTAssertNil(cleanupWarmURL(settings: s, env: [:]))
        XCTAssertEqual(cleanupWarmURL(settings: s, env: ["ANTHROPIC_API_KEY": "k"])?.absoluteString,
                       "https://api.anthropic.com")

        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://localhost:11434/v1"
        s.cleanup.model = "llama3"
        XCTAssertEqual(cleanupWarmURL(settings: s, env: [:])?.absoluteString,
                       "http://localhost:11434/v1")
        s.cleanup.model = nil // model optional — warm URL still valid
        XCTAssertEqual(cleanupWarmURL(settings: s, env: [:])?.absoluteString,
                       "http://localhost:11434/v1")
    }

    // Configured ≠ valid: "configured" means the user set cleanup up at all, so
    // callers can tell "cleanup off" (skip silently) from "cleanup broken"
    // (attempt and surface the failure). An invalid baseURL is configured.
    func testCleanupIsConfiguredDistinguishesOffFromBroken() {
        var s = Settings()
        XCTAssertFalse(cleanupIsConfigured(settings: s, env: [:]))                  // off
        XCTAssertTrue(cleanupIsConfigured(settings: s, env: ["ANTHROPIC_API_KEY": "k"]))
        s.anthropicApiKey = "k"
        XCTAssertTrue(cleanupIsConfigured(settings: s, env: [:]))

        s = Settings()
        s.cleanup.provider = "openai-compatible"
        XCTAssertFalse(cleanupIsConfigured(settings: s, env: [:]))                  // off
        s.cleanup.baseURL = ""
        XCTAssertFalse(cleanupIsConfigured(settings: s, env: [:]))                  // off
        s.cleanup.baseURL = "ollama"                                                // broken
        XCTAssertTrue(cleanupIsConfigured(settings: s, env: [:]))
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:]))          // still throws
        s.cleanup.baseURL = "http://localhost:11434/v1"
        XCTAssertTrue(cleanupIsConfigured(settings: s, env: [:]))
        // anthropic key does not leak across providers
        XCTAssertFalse(cleanupIsConfigured(
            settings: { var t = s; t.cleanup.baseURL = nil; return t }(),
            env: ["ANTHROPIC_API_KEY": "k"]))

        s.cleanup.provider = "some-future-thing"
        XCTAssertTrue(cleanupIsConfigured(settings: s, env: [:]))
    }

    func testUnknownProviderFailsClosed() {
        var s = Settings()
        s.cleanup.provider = "some-future-thing"
        s.anthropicApiKey = "k"
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:])) { error in
            let message = "\(error)"
            XCTAssertTrue(message.lowercased().contains("provider"))
            XCTAssertTrue(message.contains("anthropic"))
            XCTAssertTrue(message.contains("openai-compatible"))
        }
        XCTAssertNil(cleanupWarmURL(settings: s, env: [:]))
        XCTAssertTrue(cleanupIsConfigured(settings: s, env: [:]))
    }

    func testOpenAICompatUsesBearerAndEndpoint() async throws {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "https://api.groq.com/openai/v1"
        s.cleanup.model = "llama-3.3-70b-versatile"
        s.cleanup.apiKeyEnvVar = "GROQ_API_KEY"
        let http = mock()
        let client = try makeCleanupClient(
            settings: s, env: ["GROQ_API_KEY": "gk"], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)

        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer gk")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "llama-3.3-70b-versatile")
    }

    func testOpenAICompatKeyOptional() async throws {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://localhost:11434/v1"
        s.cleanup.model = "llama3"
        let http = mock()
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)
        XCTAssertNil(http.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatMissingBaseURLThrows() {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.model = "m"
        XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:])) { error in
            XCTAssertTrue("\(error)".lowercased().contains("base url"))
        }
    }

    // "http://local host:1234" makes URL(string:) return nil — this used to
    // crash the client's force unwrap instead of hitting the raw-text fallback.
    func testOpenAICompatInvalidBaseURLThrows() {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.model = "m"
        for bad in [
            "http://local host:1234", "ollama", "ftp://x/v1",
            "https://host/v1?tenant=x", "https://host/v1#frag",
        ] {
            s.cleanup.baseURL = bad
            XCTAssertThrowsError(try makeCleanupClient(settings: s, env: [:]), bad) { error in
                XCTAssertTrue("\(error)".lowercased().contains("base url"))
            }
            XCTAssertNil(cleanupWarmURL(settings: s, env: [:]), bad)
        }
    }

    // Model is optional for openai-compatible: empty ⇒ GET {base}/models and
    // use the first entry. The mock body serves both endpoints at once.
    func testOpenAICompatMissingModelUsesServersFirstModel() async throws {
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "http://localhost:11434/v1"
        s.cleanup.model = " \n\t "
        let http = MockHTTP()
        http.body = Data(
            #"{"data":[{"id":"llama3"},{"id":"other"}],"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        let client = try makeCleanupClient(settings: s, env: [:], http: http)
        _ = try await client.clean(transcript: "x", context: ctx)

        // Last request is the chat call — it must carry the server's first model.
        let req = http.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "llama3")
    }
}


extension CleanupFactoryTests {
    func testB21PinnedBackupSourcesNeverFallThroughOrPrompt() throws {
        let d = try B21SettingsDocument(B21SettingsDocument.primary)
        var row = CleanupBackup(baseURL:"https://backup.test/v1",model:"exact",source:.namedEnvironment,environmentName:"BACKUP_KEY")
        let s = try row.settings(preserving:B21SettingsDocument.primary)
        d.backend.values[try .compatible(row.baseURL)] = "must-not-fall-through"
        XCTAssertThrowsError(try resolveCleanupBackupCredential(row,settings:s,env:[:],credentials:d.store.credentials))
        _ = try resolveCleanupBackupCredential(row,settings:s,env:["BACKUP_KEY":"chosen"],credentials:d.store.credentials)
        XCTAssertEqual(d.backend.reads,0)
        row.source = .scopedKeychain; row.environmentName = nil
        _ = try resolveCleanupBackupCredential(row,settings:s,env:["BACKUP_KEY":"ignored"],credentials:d.store.credentials)
        XCTAssertEqual(d.backend.interactiveReads,[false])
        row.source = .keylessCompatible
        _ = try resolveCleanupBackupCredential(row,settings:s,env:[:],credentials:d.store.credentials)
        XCTAssertEqual(d.backend.reads,1)
        var legacy = s; legacy.cleanup.apiKey = "legacy"
        XCTAssertThrowsError(try resolveCleanupBackupCredential(row,settings:legacy,env:[:],credentials:d.store.credentials))
    }
}
