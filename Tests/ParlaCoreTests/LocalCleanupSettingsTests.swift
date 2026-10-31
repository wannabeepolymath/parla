import XCTest
@testable import ParlaCore

final class LocalCleanupSettingsTests: XCTestCase {
    private var root: URL!, store: SettingsStore!, backend: FakeCredentialBackend!
    private var failWrite = false
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wave4d1-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try record("created")
        backend = FakeCredentialBackend(); backend.readState = .denied; backend.statusState = .denied
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend), atomicWrite: { data, url in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root); try record("removed")
    }
    private func record(_ action: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
    }
    private func seed(base: String = "invalid inactive endpoint") throws -> Data {
        let object: [String: Any] = ["cleanup": ["provider": "apple-intelligence", "localSourceLocale": "en", "baseURL": base,
            "model": "retained-model", "apiKeyEnvVar": "RETAINED_ENV", "apiKey": "fixture-compatible"],
            "anthropicApiKey": "fixture-anthropic", "cleanupModel": "retained-anthropic", "unknown": ["untouched": true]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: store.url); return data
    }
    private func zeroBackend() {
        XCTAssertEqual(backend.statuses + backend.reads + backend.adds + backend.updates + backend.deletes, 0)
    }
    func testSelectedAutomaticMigrationLoadAndNoopSaveLeaveEntireOriginalBytes() throws {
        let original = try seed(); let settings = store.load()
        XCTAssertNil(store.lastError); XCTAssertNil(store.migrateSelectedCredentials())
        try store.save(settings)
        XCTAssertEqual(try Data(contentsOf: store.url), original); zeroBackend()
    }
    func testLocalEditAndVocabularyImportPreserveLegacyValuesAndBindingWithoutBackend() throws {
        _ = try seed(); var settings = store.load(); let old = settings
        settings.cleanup.localSourceLocale = "hi"; settings.historyEnabled = false
        try store.save(settings)
        let edited = store.load()
        XCTAssertEqual(edited.anthropicApiKey, old.anthropicApiKey); XCTAssertEqual(edited.cleanup.apiKey, old.cleanup.apiKey)
        XCTAssertEqual(edited.cleanup.baseURL, old.cleanup.baseURL); XCTAssertEqual(edited.cleanup.model, old.cleanup.model)
        XCTAssertEqual(edited.cleanup.apiKeyEnvVar, old.cleanup.apiKeyEnvVar); XCTAssertEqual(edited.cleanupModel, old.cleanupModel)
        var incoming = Settings(); incoming.dictionary = ["new phrase"]
        let preview = try VocabularyImportPreview(data: VocabularyDocument(settings: incoming).encoded(), settings: edited)
        try store.importVocabulary(preview, mode: .merge)
        let imported = store.load()
        XCTAssertEqual(imported.dictionary, ["new phrase"]); XCTAssertEqual(imported.cleanup.apiKey, old.cleanup.apiKey)
        XCTAssertEqual(imported.anthropicApiKey, old.anthropicApiKey); XCTAssertEqual(imported.cleanup.baseURL, old.cleanup.baseURL)
        let portable = String(decoding: try JSONEncoder().encode(imported), as: UTF8.self)
        XCTAssertFalse(portable.contains("fixture-compatible")); XCTAssertFalse(portable.contains("fixture-anthropic")); zeroBackend()
    }
    func testNewInlineRebindStaleCorruptRecoveredAndFailedWritePreserveOriginal() throws {
        let original = try seed(); let settings = store.load()
        var changed = settings; changed.cleanup.apiKey = "new-inline"
        XCTAssertThrowsError(try store.save(changed))
        changed = settings; changed.cleanup.baseURL = "https://new-endpoint/v1"
        XCTAssertThrowsError(try store.save(changed)); XCTAssertEqual(try Data(contentsOf: store.url), original)
        changed = settings; changed.historyEnabled.toggle(); failWrite = true
        XCTAssertThrowsError(try store.save(changed)); XCTAssertEqual(try Data(contentsOf: store.url), original); failWrite = false
        var external = try JSONSerialization.jsonObject(with: original) as! [String: Any]; external["historyEnabled"] = false
        let newer = try JSONSerialization.data(withJSONObject: external); try newer.write(to: store.url)
        XCTAssertThrowsError(try store.save(changed)); XCTAssertEqual(try Data(contentsOf: store.url), newer)
        try Data("invalid".utf8).write(to: store.url)
        _ = store.load(); XCTAssertThrowsError(try store.save(settings)); XCTAssertEqual(try Data(contentsOf: store.url), Data("invalid".utf8))
        external["profiles"] = ["not a profile"]
        let recovered = try JSONSerialization.data(withJSONObject: external); try recovered.write(to: store.url)
        _ = store.load(); XCTAssertNotNil(store.lastError); XCTAssertThrowsError(try store.save(settings))
        XCTAssertEqual(try Data(contentsOf: store.url), recovered); zeroBackend()
    }
    func testExplicitMigrationStillHandlesBothScopesAndSwitchingNetworkRetainsOldPolicy() throws {
        _ = try seed(base: "https://fixture.invalid/v1"); _ = store.load()
        backend.readState = nil; backend.statusState = nil
        XCTAssertNil(store.migrateCredentials())
        XCTAssertEqual(backend.adds, 2); XCTAssertEqual(backend.reads, 4) // initial read plus verified readback per scope
        var current = store.load(); XCTAssertNil(current.anthropicApiKey); XCTAssertNil(current.cleanup.apiKey)
        current.cleanup.provider = "openai-compatible"; try store.save(current)
        XCTAssertEqual(store.load().cleanup.baseURL, "https://fixture.invalid/v1")
        XCTAssertEqual(backend.values.count, 2)
    }
    func testLegacyPreserveContractDefaultsUnconfirmedAndProfilesCannotOverrideLocalModel() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Old","kind":"rewrite","instruction":"Please make this wording more concise for the reader","targetLanguage":""}"#.utf8)
        let preset = try JSONDecoder().decode(TransformPreset.self, from: data)
        XCTAssertNil(preset.localPreserveSourceLanguage)
        var settings = Settings(); settings.cleanup.provider = "apple-intelligence"; settings.cleanupModel = "remote"
        var profile = DictationProfile(); profile.name = "app"; profile.target = "test.app"; profile.cleanupModel = "override"; settings.profiles = [profile]
        let resolved = ProfileResolver.resolve(settings, at: .init(bundleID: "test.app")).settings
        XCTAssertEqual(resolved.cleanupModel, "remote"); XCTAssertEqual(resolved.cleanupModelLabel, "Apple Intelligence · on-device")
    }
}
