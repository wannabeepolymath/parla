import XCTest
import Security
import LocalAuthentication
@testable import ParlaCore

final class CredentialTests: XCTestCase {
    private var root: URL!
    private var backend: FakeCredentialBackend!
    private var credentials: CredentialStore!
    private var store: SettingsStore!
    private let original = Data(#"{ "anthropicApiKey":"ant-secret", "cleanup":{"provider":"anthropic","baseURL":"https://HOST:443/v1/","apiKey":"compat-secret"},"dictionary":["original"],"future":17 }"#.utf8)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave3a-core-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try recordTestFixture(root, "created")
        backend = FakeCredentialBackend(); credentials = CredentialStore(backend: backend)
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: credentials)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        try recordTestFixture(root, "removed")
    }
    private func seed(_ data: Data? = nil) throws { try (data ?? original).write(to: store.url) }
    private func persisted() throws -> String { try String(contentsOf: store.url, encoding: .utf8) }
    private func compatible(_ base: String = "https://host/v1") -> Settings {
        var s = Settings(); s.cleanup.provider = "openai-compatible"; s.cleanup.baseURL = base; s.cleanup.model = "model"; return s
    }
    private func http() -> MockHTTP {
        let h = MockHTTP(); h.body = Data(#"{"content":[{"type":"text","text":"polished"}],"choices":[{"message":{"content":"polished"}}]}"#.utf8); return h
    }

    func testCanonicalIdentityMatchesRequestsAndSeparatesAllScopeParts() async throws {
        let a = try CredentialScope.compatible("https://HOST:443/v1///")
        XCTAssertEqual(a, try .compatible("https://host/v1"))
        XCTAssertEqual(try CredentialScope.compatible("http://HOST:80/"), try .compatible("http://host"))
        backend.values[a] = "scope-a"
        let h = http()
        _ = try await ParlaCore.makeCleanupClient(settings: compatible("https://HOST:443/v1///"), env: [:], credentials: credentials, http: h)
            .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertEqual(h.lastRequest?.url?.absoluteString, "https://host/v1/chat/completions")
        XCTAssertEqual(h.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer scope-a")
        for other in ["https://host/v2", "https://host:444/v1", "http://host/v1", "https://elsewhere/v1"] {
            let h = http()
            _ = try await ParlaCore.makeCleanupClient(settings: compatible(other), env: [:], credentials: credentials, http: h)
                .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
            XCTAssertNil(h.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertThrowsError(try ParlaCore.makeCleanupClient(settings: Settings(), env: [:], credentials: credentials, http: http()))
        XCTAssertEqual(backend.values[a], "scope-a"); XCTAssertEqual(backend.deletes, 0); XCTAssertEqual(backend.updates, 0)
    }
    func testAmbiguousEndpointsNeverReadCredentialsOrEchoURL() {
        for raw in ["https://user:SECRET@host/v1", "https://host/v1?SECRET", "https://host/v1#SECRET", "file:///SECRET", "https://host:0", "https://host:65536"] {
            XCTAssertThrowsError(try ParlaCore.makeCleanupClient(settings: compatible(raw), env: [:], credentials: credentials)) {
                XCTAssertFalse(String(describing: $0).contains("SECRET"))
            }
        }
        XCTAssertEqual(backend.reads, 0)
    }
    func testBothLegacyKeysIncludingInactiveProviderMigrateAndReopen() throws {
        try seed(); XCTAssertEqual(store.load().anthropicApiKey, "ant-secret"); XCTAssertEqual(backend.reads, 0)
        XCTAssertNil(store.migrateCredentials())
        XCTAssertEqual(backend.values[.anthropic], "ant-secret")
        XCTAssertEqual(backend.values[try .compatible("https://host/v1")], "compat-secret")
        XCTAssertTrue(backend.interactiveReads.allSatisfy { !$0 })
        let json = try persisted(); XCTAssertFalse(json.contains("apiKey")); XCTAssertFalse(json.contains("ant-secret")); XCTAssertTrue(json.contains("future"))
        let reopened = SettingsStore(url: store.url, credentials: CredentialStore(backend: backend))
        XCTAssertNil(reopened.load().anthropicApiKey); XCTAssertNil(reopened.load().cleanup.apiKey)
        XCTAssertNil(reopened.migrateCredentials()); XCTAssertEqual(backend.adds, 2)
    }
    func testMissingOrInvalidSavedEndpointPreservesEveryByteAndBlocksOrdinaryWriters() throws {
        for endpoint in ["", "not-url", "https://user:pass@host/v1"] {
            let data = Data("{\"anthropicApiKey\":\"ant\",\"cleanup\":{\"apiKey\":\"compat\",\"baseURL\":\"\(endpoint)\"}}".utf8)
            try seed(data)
            XCTAssertNotNil(store.migrateCredentials())
            var edit = store.load(); edit.whisperModelPath = "menu-installed-path"; edit.inputDeviceUID = "menu-mic"; edit.dictionary = ["hub-edit"]
            XCTAssertThrowsError(try store.save(edit))
            XCTAssertEqual(try Data(contentsOf: store.url), data)
            var incoming = Settings(); incoming.dictionary = ["incoming"]
            let preview = try VocabularyImportPreview(data: VocabularyDocument(settings: incoming).encoded(), settings: store.load())
            XCTAssertThrowsError(try store.importVocabulary(preview, mode: .merge))
            XCTAssertEqual(try Data(contentsOf: store.url), data)
            // Separate loop's authoritative key must not conflict with the prior iteration.
            backend.values.removeAll()
        }
    }
    func testDeniedCanceledAndUnreadableNeverOverwriteOrLoseSource() throws {
        for state in [CredentialRead.denied, .canceled, .error] {
            try seed(); backend.readState = state
            XCTAssertNotNil(store.migrateCredentials())
            XCTAssertEqual(try Data(contentsOf: store.url), original)
            XCTAssertThrowsError(try store.save(Settings()))
            XCTAssertEqual(try Data(contentsOf: store.url), original)
            XCTAssertEqual(backend.adds, 0); XCTAssertEqual(backend.updates, 0)
        }
    }
    func testConflictRetainsBothUntilExplicitReplacement() throws {
        try seed(); backend.values[.anthropic] = "different"
        XCTAssertTrue(store.migrateCredentials()?.contains("conflict") == true)
        XCTAssertEqual(backend.values[.anthropic], "different"); XCTAssertEqual(try Data(contentsOf: store.url), original)
        try store.changeCredential(scope: .anthropic, replacement: "chosen")
        XCTAssertNil(store.migrateCredentials())
        XCTAssertEqual(backend.values[.anthropic], "chosen")
        XCTAssertFalse(try persisted().contains("apiKey"))
    }
    func testAddFailureAndVerificationFailurePreserveSourceAndRetry() throws {
        try seed(); backend.addResult = .denied
        XCTAssertNotNil(store.migrateCredentials()); XCTAssertEqual(try Data(contentsOf: store.url), original)
        backend.addResult = nil; backend.readState = .missing
        XCTAssertNotNil(store.migrateCredentials()); XCTAssertEqual(try Data(contentsOf: store.url), original)
        backend.readState = nil
        XCTAssertNil(store.migrateCredentials()); XCTAssertFalse(try persisted().contains("apiKey"))
    }
    func testDuplicateAddRaceVerifiesSameValueAndRefusesDifferentValue() throws {
        for same in [false, true] {
            backend.values.removeAll(); try seed()
            backend.onAdd = { [unowned self] in self.backend.values[.anthropic] = same ? "ant-secret" : "racing-secret" }
            backend.addResult = .duplicate
            if same {
                // Only Anthropic races; allow subsequent compatible add normally.
                backend.onRead = { [unowned self] in
                    if self.backend.values[.anthropic] != nil { self.backend.addResult = nil; self.backend.onAdd = nil }
                }
                XCTAssertNil(store.migrateCredentials())
            } else { XCTAssertTrue(store.migrateCredentials()?.contains("conflict") == true); XCTAssertEqual(try Data(contentsOf: store.url), original) }
            backend.onRead = nil
        }
    }
    func testAtomicSettingsFailureAfterVerifiedWritesIsIdempotent() throws {
        try seed(); var fail = true
        let failing = SettingsStore(url: store.url, credentials: credentials, atomicWrite: { data, url in
            if fail { throw CocoaError(.fileWriteUnknown) }; try data.write(to: url, options: .atomic)
        })
        XCTAssertNotNil(failing.migrateCredentials()); XCTAssertEqual(backend.values.count, 2)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertThrowsError(try failing.save(Settings())); XCTAssertEqual(try Data(contentsOf: store.url), original)
        fail = false; XCTAssertNil(failing.migrateCredentials()); XCTAssertEqual(backend.adds, 2)
        XCTAssertFalse(try persisted().contains("apiKey"))
    }
    func testExternalNewerSettingsSurviveLegacyStripAndOrdinarySave() throws {
        try seed(); let newer = Data(#"{"anthropicApiKey":"new-secret","dictionary":["newer"]}"#.utf8)
        backend.onAdd = { [unowned self] in try! newer.write(to: self.store.url); self.backend.onAdd = nil }
        XCTAssertNotNil(store.migrateCredentials()); XCTAssertEqual(try Data(contentsOf: store.url), newer)
        XCTAssertEqual(store.load().dictionary, ["newer"])
        XCTAssertThrowsError(try store.save(Settings())); XCTAssertEqual(try Data(contentsOf: store.url), newer)
    }
    func testInvalidAuthoritativeSettingsNeverMigrateRecoveredGlobals() throws {
        let invalid = Data(#"{"anthropicApiKey":"only-source","profiles":"invalid"}"#.utf8)
        try seed(invalid); _ = store.load(); XCTAssertNotNil(store.lastError)
        XCTAssertNotNil(store.migrateCredentials()); XCTAssertThrowsError(try store.save(Settings()))
        XCTAssertEqual(backend.reads, 0); XCTAssertEqual(try Data(contentsOf: store.url), invalid)
    }
    func testEncodeRedactsButStoreRefusesNewUnstoredInlineSource() throws {
        var s = Settings(); s.anthropicApiKey = "only-source"; s.cleanup.apiKey = "other-source"
        let encoded = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ApiKey")); XCTAssertFalse(encoded.contains("apiKey"))
        XCTAssertThrowsError(try store.save(s)); XCTAssertEqual(backend.adds, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }
    func testExplicitUpdateDeleteFailuresAndRetry() throws {
        backend.values[.anthropic] = "old"
        backend.updateResult = .canceled
        XCTAssertThrowsError(try store.changeCredential(scope: .anthropic, replacement: "new"))
        XCTAssertEqual(backend.values[.anthropic], "old")
        backend.updateResult = nil; try store.changeCredential(scope: .anthropic, replacement: "new")
        backend.deleteResult = .denied; XCTAssertThrowsError(try store.changeCredential(scope: .anthropic, replacement: nil))
        XCTAssertEqual(backend.values[.anthropic], "new")
        backend.deleteResult = nil; try store.changeCredential(scope: .anthropic, replacement: nil)
        XCTAssertNil(backend.values[.anthropic])
    }
    func testEnvironmentPriorityIsolationAndSkipsBackendIncludingMigrationInput() async throws {
        var s = compatible(); s.cleanup.apiKeyEnvVar = "COMPAT_KEY"; s.cleanup.apiKey = "legacy-not-yet-migrated"
        backend.readState = .denied; backend.statusState = .denied
        let h = http()
        _ = try await ParlaCore.makeCleanupClient(settings: s, env: ["COMPAT_KEY": "override", "ANTHROPIC_API_KEY": "wrong-provider"], credentials: credentials, http: h)
            .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertEqual(h.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer override")
        XCTAssertNil(cleanupConfigurationIssue(settings: s, env: ["COMPAT_KEY": "override"], credentials: credentials))
        XCTAssertEqual(backend.reads, 0); XCTAssertEqual(backend.statuses, 0)
        XCTAssertThrowsError(try ParlaCore.makeCleanupClient(settings: compatible(), env: ["ANTHROPIC_API_KEY": "wrong"], credentials: credentials, http: http()))
    }
    func testInaccessibleIsConfiguredButMakesNoHTTPAndWarmStatusDoesNotReadSecret() async throws {
        for state in [CredentialRead.denied, .canceled, .error] {
            backend.readState = state; backend.statusState = state.status
            let s = compatible(); let h = http()
            XCTAssertTrue(ParlaCore.cleanupIsConfigured(settings: s, env: [:], credentials: credentials))
            XCTAssertNotNil(ParlaCore.cleanupWarmURL(settings: s, env: [:], credentials: credentials))
            XCTAssertNotNil(cleanupConfigurationIssue(settings: s, env: [:], credentials: credentials))
            XCTAssertEqual(backend.reads, 0)
            XCTAssertThrowsError(try ParlaCore.makeCleanupClient(settings: s, env: [:], credentials: credentials, http: h))
            XCTAssertNil(h.lastRequest); backend.reads = 0
        }
        XCTAssertTrue(ParlaCore.cleanupIsConfigured(settings: Settings(), env: [:], credentials: credentials))
    }
    func testPipelineRawSnippetOffAvoidReadsAndDeniedUsesRawFallback() async throws {
        backend.readState = .denied; backend.statusState = .denied
        let h = http()
        for mode in [0, 1, 2, 3] {
            var s = compatible()
            if mode == 0 { s.outputMode = .raw }
            if mode == 1 { s.snippets = ["source": "snippet"] }
            if mode == 2 { s.cleanupEnabled = false }
            let pipeline = Pipeline(outputSettings: s, bundleID: nil) { [unowned self] in
                try ParlaCore.makeCleanupClient(settings: $0, env: [:], credentials: self.credentials, http: h)
            }
            let result = await pipeline.clean(transcript: "source")
            if mode < 3 { XCTAssertNil(result.failure); XCTAssertEqual(backend.reads, 0) }
            else { XCTAssertNotNil(result.failure); XCTAssertEqual(result.text, "source"); XCTAssertEqual(backend.reads, 1) }
        }
        XCTAssertNil(h.lastRequest)
    }
    func testIntentionalTransformAndProfileModelUseGlobalScope() async throws {
        var s = compatible(); let scope = try CredentialScope.selected(s); backend.values[scope] = "global-key"
        var profile = DictationProfile(); profile.name = "Editor"; profile.target = "com.test.Editor"
        profile.cleanupModel = "effective-profile-model"; s.profiles = [profile]
        s = ProfileResolver.resolve(s, at: .init(bundleID: "com.test.Editor")).settings
        let h = http()
        _ = try await IntentionalTransform(source: "source", instruction: "rewrite", settings: s).run { [unowned self] in
            try ParlaCore.makeCleanupClient(settings: $0, env: [:], credentials: self.credentials, http: h)
        }
        XCTAssertEqual(h.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer global-key")
        let body = try JSONSerialization.jsonObject(with: h.lastRequest!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "effective-profile-model")
    }
    func testFrozenRetryAndKeychainAwareProvenanceAfterStoreAndEndpointChanges() async throws {
        var s = compatible(); let scope = try CredentialScope.selected(s)
        backend.values[scope] = "secret-model"
        s.cleanup.model = "secret-model"
        let request = try HistoryRetryRequest(settings: s, environment: [:], source: .init(raw: "source"), applyPreset: false, credentials: credentials)
        let privateAccess = try resolveCleanupCredential(settings: s, env: [:], credentials: credentials)
        XCTAssertFalse(String(describing: privateAccess).contains("secret-model"))
        XCTAssertFalse(String(reflecting: privateAccess).contains("secret-model"))
        let preparedReads = backend.reads
        backend.values[scope] = "changed-key"; backend.readState = .denied
        s.cleanup.baseURL = "https://other/private"; s.cleanup.model = "changed-model"
        let h = http()
        let (_, provenance) = try await request.run(source: "source", factory: { [unowned self] frozen, env, access, usage in
            try ParlaCore.makeCleanupClient(settings: frozen, env: env, credentials: self.credentials, access: access, http: h, usage: usage)
        })
        XCTAssertEqual(backend.reads, preparedReads)
        XCTAssertEqual(h.lastRequest?.url?.absoluteString, "https://host/v1/chat/completions")
        XCTAssertEqual(h.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-model")
        let safe = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
        XCTAssertFalse(safe.contains("secret-model")); XCTAssertFalse(request.configuration.summary.contains("secret-model"))
        XCTAssertFalse(String(decoding: try VocabularyDocument(settings: s).encoded(), as: UTF8.self).contains("changed-key"))
    }
    func testLocalRetryPreparationDoesNotResolveSecret() throws {
        var s = compatible(); s.snippets = ["source": "local"]
        _ = try HistoryRetryRequest(settings: s, environment: [:], source: .init(raw: "source"), applyPreset: false, credentials: credentials)
        XCTAssertEqual(backend.reads, 0)
        s.snippets = [:]
        _ = try HistoryRetryRequest(settings: s, environment: [:], source: .init(raw: ""), applyPreset: false, credentials: credentials)
        XCTAssertEqual(backend.reads, 0)
    }
    func testProviderErrorsAndUsageCannotEchoResolvedKey() async throws {
        let s = compatible(); backend.values[try CredentialScope.selected(s)] = "secret-echo"
        let h = http(); h.status = 401
        h.body = Data(#"{"error":{"message":"secret-echo"}}"#.utf8)
        do {
            _ = try await ParlaCore.makeCleanupClient(settings: s, env: [:], credentials: credentials, http: h)
                .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("secret-echo"))
            XCTAssertEqual((error as? CleanupError)?.userMessage, "invalid API key")
        }
        h.status = 200
        h.body = Data(#"{"model":"secret-echo","choices":[{"message":{"content":"polished"}}],"usage":{"prompt_tokens":1,"completion_tokens":2}}"#.utf8)
        var reported: String?
        _ = try await ParlaCore.makeCleanupClient(settings: s, env: [:], credentials: credentials, http: h, usage: { model, _, _ in reported = model })
            .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertEqual(reported, "[redacted]")
    }
    func testEmptyEnvironmentUsesStoredKeyAndAnthropicOverrideSkipsBackend() async throws {
        backend.values[.anthropic] = "stored-ant"
        let h = http()
        _ = try await ParlaCore.makeCleanupClient(settings: Settings(), env: ["ANTHROPIC_API_KEY": ""], credentials: credentials, http: h)
            .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertEqual(h.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "stored-ant")
        backend.reads = 0; backend.statuses = 0; backend.readState = .denied
        _ = try await ParlaCore.makeCleanupClient(settings: Settings(), env: ["ANTHROPIC_API_KEY": "env-ant"], credentials: credentials, http: h)
            .clean(transcript: "source", context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertTrue(ParlaCore.cleanupIsConfigured(settings: Settings(), env: ["ANTHROPIC_API_KEY": "env-ant"], credentials: credentials))
        XCTAssertEqual(backend.reads, 0); XCTAssertEqual(backend.statuses, 0)
    }
    func testExplicitAddRaceReplacesOnlyChosenScopeAndDeleteFailurePreservesLegacy() throws {
        backend.onAdd = { [unowned self] in self.backend.values[.anthropic] = "racer" }
        backend.addResult = .duplicate
        try store.changeCredential(scope: .anthropic, replacement: "chosen")
        XCTAssertEqual(backend.values[.anthropic], "chosen"); XCTAssertEqual(backend.updates, 1)
        backend.onAdd = nil; try seed(); backend.deleteResult = .error
        XCTAssertThrowsError(try store.changeCredential(scope: .anthropic, replacement: nil))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    func testSecurityAdapterInjectedFunctionsUseLocalNamespaceAndNoninteractiveAttributes() throws {
        var queries: [[String: Any]] = []
        var copies: OSStatus = errSecInteractionNotAllowed
        let functions = SecurityCredentialBackend.Functions(copy: { query, result in
            let q = query as! [String: Any]; queries.append(q)
            if copies == errSecSuccess { result?.pointee = Data("fake".utf8) as CFData }
            return copies
        }, add: { query, _ in queries.append(query as! [String: Any]); return errSecDuplicateItem },
        update: { query, _ in queries.append(query as! [String: Any]); return errSecAuthFailed },
        delete: { query in queries.append(query as! [String: Any]); return errSecUserCanceled })
        let adapter = SecurityCredentialBackend(functions: functions)
        XCTAssertEqual(adapter.status(.anthropic), .denied)
        XCTAssertEqual(queries.last?[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(queries.last?[kSecReturnData as String])
        XCTAssertEqual((queries.last?[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        copies = errSecSuccess
        guard case .value("fake") = adapter.read(.anthropic, interactive: true) else { return XCTFail() }
        guard case .duplicate = adapter.add("fake", scope: .anthropic, interactive: false) else { return XCTFail() }
        XCTAssertEqual(queries.last?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        guard case .denied = adapter.update("fake", scope: .anthropic, interactive: true) else { return XCTFail() }
        guard case .canceled = adapter.delete(.anthropic) else { return XCTFail() }
        for q in queries {
            XCTAssertEqual(q[kSecAttrService as String] as? String, "com.parla.provider-credentials.v1")
            XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertNil(q[kSecAttrAccessGroup as String]); XCTAssertNil(q[kSecAttrAccess as String])
        }
    }
}
