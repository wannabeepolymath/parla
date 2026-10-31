import XCTest
@testable import ParlaCore

final class SettingsTests: XCTestCase {
    func tempStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsStore(url: dir.appendingPathComponent("settings.json"), credentials: testCredentialStore())
    }

    func testDefaultsWhenFileMissing() {
        let store = tempStore()
        let s = store.load()
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")
        XCTAssertTrue(s.dictionary.isEmpty)
        XCTAssertTrue(s.snippets.isEmpty)
        XCTAssertNil(store.lastError) // missing file is fine, not an error
    }

    func testRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.dictionary = ["Kubernetes", "Daksh"]
        s.snippets = ["insert my calendar link": "https://cal.com/daksh"]
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        XCTAssertNil(store.lastError)
    }

    func testCorruptFileFallsBackToDefaultsAndReportsError() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.lastError!.contains("\n")) // trimmed to one line for menu display
    }

    func testDirectoryFallsBackToDefaultsAndReportsError() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
    }

    func testErrorClearsOnNextGoodLoad() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        _ = store.load()
        XCTAssertNotNil(store.lastError)
        XCTAssertThrowsError(try store.save(Settings())) // unreadable authoritative state cannot authorize a whole-file overwrite
        try Data("{}".utf8).write(to: store.url) // explicit external repair
        _ = store.load()
        XCTAssertNil(store.lastError)
    }

    func testPartialFileDecodesWithDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"dictionary":["Kubernetes"]}"#.utf8).write(to: store.url)
        let s = store.load()
        XCTAssertEqual(s.dictionary, ["Kubernetes"])
        XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")  // default survives
        XCTAssertEqual(s.cleanup, CleanupSettings())          // default block
    }

    func testUnknownKeysIgnored() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `liveStreamingEnabled` is a *retired* key, not a hypothetical one: it
        // sits in every settings.json written before it was deleted, and those
        // files must keep decoding.
        try Data(#"{"futureField":true,"liveStreamingEnabled":false,"cleanupModel":"m"}"#.utf8)
            .write(to: store.url)
        XCTAssertEqual(store.load().cleanupModel, "m")
    }

    func testPartialCleanupBlockDecodesWithDefaults() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"cleanup":{"model":"m"},"dictionary":["X"]}"#.utf8).write(to: store.url)
        let s = store.load()
        XCTAssertEqual(s.cleanup.provider, "anthropic")
        XCTAssertEqual(s.cleanup.model, "m")
        XCTAssertEqual(s.dictionary, ["X"])
    }

    func testInputDeviceUIDDefaultNil() {
        XCTAssertNil(Settings().inputDeviceUID)
    }

    func testInputDeviceUIDTolerantDecodeAndRoundTrip() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data(#"{"dictionary":["X"]}"#.utf8))
        XCTAssertNil(missing.inputDeviceUID)
        let store = tempStore()
        var s = Settings()
        s.inputDeviceUID = "AppleUSBAudioEngine:Blue:Yeti:1"
        try store.save(s)
        XCTAssertEqual(store.load().inputDeviceUID, s.inputDeviceUID)
    }

    /// The whole point of the setting: nobody gets a lit mic indicator they did
    /// not ask for. A fresh install and every existing settings.json (which has no
    /// `warmMic` key) must both come back cold.
    func testWarmMicDefaultsOffAndTolerantDecodeStaysOff() throws {
        XCTAssertFalse(Settings().warmMic)
        let existing = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"showHudAlways":true,"hudIdleSize":"large"}"#.utf8))
        XCTAssertFalse(existing.warmMic)
    }

    func testWarmMicRoundTrips() throws {
        let store = tempStore()
        var s = Settings()
        s.warmMic = true
        try store.save(s)
        XCTAssertTrue(store.load().warmMic)
    }

    func testCleanupBlockRoundTrip() throws {
        let store = tempStore()
        var s = Settings()
        s.cleanup.provider = "openai-compatible"
        s.cleanup.baseURL = "https://api.groq.com/openai/v1"
        s.cleanup.model = "llama-3.3-70b-versatile"
        s.cleanup.apiKeyEnvVar = "GROQ_API_KEY"
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    // load() is on the fn-down keypress path, so it caches. These cover the
    // three ways that cache has to stay honest.

    func testLoadPicksUpAnExternalEdit() throws {
        let store = tempStore()
        var s = Settings()
        s.dictionary = ["Kubernetes"]
        try store.save(s)
        XCTAssertEqual(store.load().dictionary, ["Kubernetes"])

        // Same length, so a size-only check would miss it; the editor case.
        try Data(#"{"dictionary":["Kubernetes!"]}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load().dictionary, ["Kubernetes!"])
    }

    func testSaveInvalidatesEvenWhenStampCouldNotChange() throws {
        let store = tempStore()
        // An atomic rewrite of the same length does move the mtime in practice, so
        // simply saving twice never reaches save()'s own invalidation — the stamp
        // check gets there first. Pin the mtime to a whole second (which survives
        // the filesystem round-trip exactly) on both sides instead, so the stamp
        // is provably identical and only save() dropping the cache can save us.
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        var s = Settings()
        s.dictionary = ["aaaa"]
        try store.save(s)
        try FileManager.default.setAttributes([.modificationDate: frozen],
                                              ofItemAtPath: store.url.path)
        let before = try FileManager.default.attributesOfItem(atPath: store.url.path)
        _ = store.load() // prime the cache against that stamp

        s.dictionary = ["bbbb"] // identical length
        try store.save(s)
        try FileManager.default.setAttributes([.modificationDate: frozen],
                                              ofItemAtPath: store.url.path)
        let after = try FileManager.default.attributesOfItem(atPath: store.url.path)
        // If either half of the stamp moved, this test is back to proving nothing,
        // so fail loudly rather than pass for the wrong reason.
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
        XCTAssertEqual(after[.size] as? Int, before[.size] as? Int)
        XCTAssertEqual(store.load().dictionary, ["bbbb"])
    }

    func testLastErrorSurvivesACacheHit() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
        // Second call is a cache hit — the ⚠️ menu state must not clear itself.
        XCTAssertEqual(store.load(), Settings())
        XCTAssertNotNil(store.lastError)
    }

    func testAppearingFileInvalidatesTheNoFileCache() throws {
        let store = tempStore()
        try? FileManager.default.removeItem(at: store.url)
        XCTAssertEqual(store.load(), Settings()) // caches "no file"
        var s = Settings()
        s.dictionary = ["later"]
        try store.save(s)
        XCTAssertEqual(store.load().dictionary, ["later"])
    }
}

extension SettingsTests {
    func testClipboardReceiptPreferenceDefaultMissingNullRoundTripAndMalformed() throws {
        XCTAssertFalse(Settings().clipboardReceiptRestoreEnabled)
        for json in ["{}", #"{"clipboardReceiptRestoreEnabled":null}"#] {
            XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).clipboardReceiptRestoreEnabled)
        }
        var settings = Settings(); settings.clipboardReceiptRestoreEnabled = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
        for value in ["1", "\"true\"", "[]", "{}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data("{\"clipboardReceiptRestoreEnabled\":\(value)}".utf8)))
        }
    }
}


final class B21SettingsDocument {
    var bytes: Data?
    let backend = FakeCredentialBackend()
    var failWrite = false
    var failRead = false
    var onRead: (() -> Void)?
    init(_ settings: Settings = Settings()) throws { bytes = try JSONEncoder().encode(settings) }
    lazy var store = SettingsStore(url: URL(fileURLWithPath: "/synthetic-b21-memory/settings.json"),
        credentials: CredentialStore(backend: backend), scratchpadIO: .init(read: { _ in self.bytes }, write: { data, _ in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }; self.bytes = data
        }), documentIO: .init(read: {
            self.onRead?()
            if self.failRead { throw CocoaError(.fileReadNoPermission) }
            return self.bytes
        }), atomicWrite: { data, _ in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }; self.bytes = data
        })
    func enable(_ backups: [CleanupBackup] = [.init(baseURL: "https://backup.test/v1", model: "backup", source: .keylessCompatible)]) throws -> Settings {
        _ = try store.confirmCleanupFailover(store.reviewCleanupFailover(backups: backups)); return store.load()
    }
    static var primary: Settings {
        var s = Settings(); s.cleanup.provider = "openai-compatible"; s.cleanup.baseURL = "https://primary.test/v1"; s.cleanup.model = "primary"; return s
    }
}
extension SettingsTests {
    func testB21NarrowWritersPreservePolicyUnknownSiblingsAndCredentialRotation() throws {
        let d = try B21SettingsDocument(B21SettingsDocument.primary), s = try d.enable(), original = s.cleanupFailover
        var object = try JSONSerialization.jsonObject(with: d.bytes!) as! [String: Any]
        object["futureSibling"] = ["keep": 71]; d.bytes = try JSONSerialization.data(withJSONObject: object)
        let scope = try CredentialScope.compatible("https://backup.test/v1")
        try d.store.changeCredential(scope: scope, replacement: "rotated"); try d.store.changeCredential(scope: scope, replacement: nil)
        XCTAssertNil(d.store.migrateCredentials())
        _ = try d.store.setScratchpadDictionaryAlternativesEnabled(true, expected: false)
        let template = GuidedTemplateDefinition(name: "Note", body: "{{body}}", fields: [.init(key: "body", label: "Body")])
        let saved = try d.store.saveTemplateDefinition(template, expectedRevision: nil)
        let revision = try XCTUnwrap(saved.definitions.first?.revision)
        _ = try d.store.deleteTemplateDefinition(template.id, expectedRevision: revision)
        var words = d.store.load(); words.dictionary = ["new word"]
        let preview = try VocabularyImportPreview(data: VocabularyDocument(settings: words).encoded(), settings: d.store.load())
        _ = try d.store.importVocabulary(preview, mode: .merge)
        XCTAssertEqual(d.store.load().dictionary, ["new word"])
        XCTAssertEqual(d.store.load().cleanupFailover, original)
        XCTAssertFalse(d.store.cleanupFailoverIsPaused)
        let after = try JSONSerialization.jsonObject(with: d.bytes!) as! [String: Any]
        // Existing full vocabulary semantics may replace unknown siblings; narrow policy actions must preserve them.
        var narrow = after; narrow["futureSibling"] = ["keep": 71]; d.bytes = try JSONSerialization.data(withJSONObject: narrow)
        _ = try d.store.disableCleanupFailover(expected: original)
        let disabled = try JSONSerialization.jsonObject(with: d.bytes!) as! [String: Any]
        XCTAssertEqual((disabled["futureSibling"] as? [String: Int])?["keep"], 71)
    }
    func testB21ObservedAwayBackInvalidityAndFailedDisableIrreversiblyRevoke() throws {
        for kind in 0..<4 {
            let d = try B21SettingsDocument(B21SettingsDocument.primary), s = try d.enable(), id = UUID()
            let g = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary)).bound(to: id)
            let original = d.bytes
            if kind == 0 { var changed = s; changed.cleanup.model = "other"; d.bytes = try JSONEncoder().encode(changed); _ = d.store.load() }
            if kind == 1 { d.bytes = Data("{broken".utf8); _ = d.store.load() }
            if kind == 2 { var changed = s; changed.cleanupEnabled = false; d.store.observeCleanupFailoverDraft(from: s, to: changed); d.store.observeCleanupFailoverDraft(from: changed, to: s) }
            if kind == 3 { d.failWrite = true; XCTAssertThrowsError(try d.store.disableCleanupFailover(expected: s.cleanupFailover)); d.failWrite = false }
            d.bytes = original
            XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(g, operationID: id, {}))
            let fresh = try d.enable(); let newID = UUID()
            let freshGrant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: fresh, origin: .shortcutsOrdinary)).bound(to: newID)
            try d.store.withCleanupFailoverGrant(freshGrant, operationID: newID, {})
        }
    }
    func testB21StrictMalformedRecoveryAndAllSensitiveWritersRefuseCombinedBlocks() throws {
        for other in ["guidedTemplates", "transformPresets", "profiles"] {
            var s = B21SettingsDocument.primary; s.historyEnabled = false; s.recoveryAudioEnabled = false; s.language = "hi"
            let d = try B21SettingsDocument(s)
            var object = try JSONSerialization.jsonObject(with: d.bytes!) as! [String: Any]
            object["cleanupFailover"] = NSNull(); object[other] = "malformed"
            d.bytes = try JSONSerialization.data(withJSONObject: object); let before = d.bytes
            XCTAssertFalse(d.store.load().historyEnabled); XCTAssertFalse(d.store.load().recoveryAudioEnabled)
            XCTAssertEqual(d.store.load().language, "hi")
            XCTAssertThrowsError(try d.store.reviewCleanupFailover(backups: []))
            XCTAssertThrowsError(try d.store.changeCredential(scope: .anthropic, replacement: "must-not-save"))
            XCTAssertThrowsError(try d.store.setScratchpadDictionaryAlternativesEnabled(true, expected: false))
            XCTAssertThrowsError(try d.store.save(s)); XCTAssertNotNil(d.store.migrateCredentials())
            XCTAssertEqual(d.bytes, before); XCTAssertEqual(d.backend.reads + d.backend.adds, 0)
        }
    }
    func testB21FullWriterCASAndNarrowCapDoesNotCapOrdinarySave() throws {
        let d = try B21SettingsDocument(B21SettingsDocument.primary), stale = try d.enable()
        let rows = [CleanupBackup(baseURL: "https://new.test/v1", model: "new", source: .keylessCompatible)]
        let fresh = try d.enable(rows)
        var edit = stale; edit.showHudAlways.toggle()
        XCTAssertEqual(try d.store.savePreservingTemplates(edit).cleanupFailover, fresh.cleanupFailover)
        var changed = d.store.load(); changed.cleanup.model = "changed"
        _ = try d.store.savePreservingTemplates(changed, replacing: d.store.load())
        XCTAssertThrowsError(try d.store.savePreservingTemplates(stale))
        var large = d.store.load(); large.dictionary = [String(repeating: "x", count: 1024 * 1024)]
        _ = try d.store.savePreservingTemplates(large)
        XCTAssertThrowsError(try d.store.reviewCleanupFailover(backups: rows))
        large.showHudAlways.toggle(); _ = try d.store.savePreservingTemplates(large)
        XCTAssertGreaterThan(d.bytes!.count, 1024 * 1024)
    }
}


extension SettingsTests {
    func testB21SnapshotAndFailedFullSaveObserveInvalidityBeforeRestoration() throws {
        for snapshot in [false,true] {
            let d=try B21SettingsDocument(B21SettingsDocument.primary),s=try d.enable(),id=UUID()
            let grant=try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)).bound(to:id),before=d.bytes
            d.bytes=Data("{invalid".utf8)
            if snapshot{XCTAssertThrowsError(try d.store.savedRetrySnapshot())}else{XCTAssertThrowsError(try d.store.save(s))}
            d.bytes=before;XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant,operationID:id,{}))
        }
    }
    func testB21CredentialInterleavingPreservesChangedPolicyAndRejectsStaleNarrowWrites() throws {
        let d=try B21SettingsDocument(B21SettingsDocument.primary),s=try d.enable()
        d.backend.onAdd={var changed=s;changed.cleanup.model="changed-during-key";d.bytes=try! JSONEncoder().encode(changed)}
        XCTAssertThrowsError(try d.store.changeCredential(scope:.anthropic,replacement:"new-key"))
        XCTAssertEqual(d.store.load().cleanup.model,"changed-during-key")
        XCTAssertEqual(d.store.load().cleanupFailover,s.cleanupFailover)
        let review=try d.store.reviewCleanupFailover(backups:s.cleanupFailover!.backups)
        var fresh=d.store.load();fresh.historyEnabled=false;d.bytes=try JSONEncoder().encode(fresh);let before=d.bytes
        XCTAssertThrowsError(try d.store.confirmCleanupFailover(review));XCTAssertEqual(d.bytes,before)
    }
}


extension SettingsTests {
    func testB21EveryObservedNarrowFailureRevokesRestoredJob() throws {
        for kind in 0..<4 {
            let d=try B21SettingsDocument(B21SettingsDocument.primary),s=try d.enable(),id=UUID()
            let grant=try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)).bound(to:id),before=d.bytes
            d.bytes=Data("{invalid".utf8)
            switch kind {
            case 0:XCTAssertThrowsError(try d.store.scratchpadDictionaryConfiguration())
            case 1:XCTAssertThrowsError(try d.store.templateDocument())
            case 2:XCTAssertThrowsError(try d.store.setScratchpadDictionaryAlternativesEnabled(true,expected:false))
            default:
                let t=GuidedTemplateDefinition(name:"Note",body:"{{body}}",fields:[.init(key:"body",label:"Body")])
                XCTAssertThrowsError(try d.store.saveTemplateDefinition(t,expectedRevision:nil))
            }
            d.bytes=before;XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant,operationID:id,{}))
        }
    }
    func testB21LocalFullWriterPreservesFreshPolicyAndPrivacyBase() throws {
        let d=try B21SettingsDocument(B21SettingsDocument.primary),network=try d.enable()
        var local=network;local.cleanup.provider="apple-intelligence";local.cleanup.localSourceLocale="en"
        local=try d.store.savePreservingTemplates(local,replacing:network)
        let changed=[CleanupBackup(baseURL:"https://changed-backup.test/v1",model:"changed",source:.keylessCompatible)]
        _=try d.store.editCleanupFailover(backups:changed,expected:local.cleanupFailover)
        var stale=local;stale.showHudAlways.toggle()
        let saved=try d.store.savePreservingTemplates(stale,replacing:local)
        XCTAssertEqual(saved.cleanupFailover?.backups,changed);XCTAssertNil(saved.cleanupFailover?.review)
        XCTAssertEqual(d.backend.reads+d.backend.adds,0)
        var newer=saved;newer.historyEnabled=false;d.bytes=try JSONEncoder().encode(newer)
        stale=saved;stale.showHudAlways.toggle()
        XCTAssertThrowsError(try d.store.savePreservingTemplates(stale,replacing:saved));XCTAssertFalse(d.store.load().historyEnabled)
    }
    func testB21MigrationInterleavingCannotOverwriteNarrowDisabledConsent() throws {
        let d=try B21SettingsDocument(B21SettingsDocument.primary),s=try d.enable()
        var object=try JSONSerialization.jsonObject(with:d.bytes!) as! [String:Any];object["anthropicApiKey"]="legacy";d.bytes=try JSONSerialization.data(withJSONObject:object)
        d.backend.onAdd={_ = try! d.store.disableCleanupFailover(expected:s.cleanupFailover)}
        XCTAssertNotNil(d.store.migrateCredentials());XCTAssertNil(d.store.load().cleanupFailover?.review)
        let after=try JSONSerialization.jsonObject(with:d.bytes!) as! [String:Any]
        XCTAssertEqual(after["anthropicApiKey"] as? String,"legacy")
    }
}


extension SettingsTests {
    func testB21S1CredentialAndMigrationCASRememberAuthorityBeforeRestoration() throws {
        for migration in [false, true] {
            for kind in 0..<5 {
                let d = try B21SettingsDocument(B21SettingsDocument.primary)
                let s = try d.enable([.init(baseURL: "https://backup.test/v1", model: "backup", source: .scopedKeychain)])
                let original = d.bytes, id = UUID()
                let grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary)).bound(to: id)
                var cancellations = 0
                let unregister = try d.store.registerCleanupFailoverCancellation(grant, operationID: id) { cancellations += 1 }
                var changed = s; changed.cleanupEnabled = false
                let changedBytes = try JSONEncoder().encode(changed)
                var malformed = try JSONSerialization.jsonObject(with: original!) as! [String: Any]
                malformed["cleanupFailover"] = NSNull()
                let malformedBytes = try JSONSerialization.data(withJSONObject: malformed)
                if migration {
                    var legacy = try JSONSerialization.jsonObject(with: original!) as! [String: Any]
                    legacy["anthropicApiKey"] = "synthetic-legacy"
                    d.bytes = try JSONSerialization.data(withJSONObject: legacy)
                }
                var entered = false
                d.backend.onAdd = {
                    entered = true
                    switch kind {
                    case 0: d.bytes = changedBytes
                    case 1: d.bytes = malformedBytes
                    case 2: d.bytes = Data("{invalid".utf8)
                    case 3: d.bytes = nil
                    default: d.failRead = true
                    }
                }
                if migration { XCTAssertNotNil(d.store.migrateCredentials()) }
                else { XCTAssertThrowsError(try d.store.changeCredential(scope: .compatible("https://backup.test/v1"), replacement: "synthetic-new")) }
                XCTAssertTrue(entered)
                if kind == 0 { XCTAssertEqual(d.bytes, changedBytes) }
                if kind == 1 { XCTAssertEqual(d.bytes, malformedBytes) }
                if kind == 2 { XCTAssertEqual(d.bytes, Data("{invalid".utf8)) }
                if kind == 3 { XCTAssertNil(d.bytes) }
                // No intervening load/snapshot may supply the missing observation.
                XCTAssertEqual(cancellations, 1, "migration=\(migration), kind=\(kind)")
                d.failRead = false; d.bytes = original
                var admitted = 0
                XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted += 1 })
                XCTAssertEqual(admitted, 0)
                unregister()
                let fresh = try d.enable(), freshID = UUID()
                let freshGrant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: fresh, origin: .shortcutsOrdinary)).bound(to: freshID)
                try d.store.withCleanupFailoverGrant(freshGrant, operationID: freshID) { admitted += 1 }
                XCTAssertEqual(admitted, 1)
                XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant, operationID: id, {}))
            }
        }
    }

    func testB21S1EveryActuallyReadWriteBoundaryRemembersAuthority() throws {
        // Inject an external change at each real document-read boundary, including
        // reads after initial validation and the final successful full-save reads.
        func exercise(_ action: String, changeAt target: Int?) throws -> Int {
            let d = try B21SettingsDocument(B21SettingsDocument.primary), s = try d.enable(), original = d.bytes, id = UUID()
            let grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary)).bound(to: id)
            var cancellations = 0
            let unregister = try d.store.registerCleanupFailoverCancellation(grant, operationID: id) { cancellations += 1 }
            var changed = s; changed.cleanupEnabled = false
            let changedBytes = try JSONEncoder().encode(changed)
            var words = s; words.dictionary = ["observed-boundary"]
            let preview = try VocabularyImportPreview(data: VocabularyDocument(settings: words).encoded(), settings: s)
            let review = try d.store.reviewCleanupFailover(backups: s.cleanupFailover!.backups)
            if action == "migration" {
                var legacy = try JSONSerialization.jsonObject(with: original!) as! [String: Any]
                legacy["anthropicApiKey"] = "synthetic-legacy"
                d.bytes = try JSONSerialization.data(withJSONObject: legacy)
            }
            var reads = 0, observed = false
            d.onRead = {
                reads += 1
                if reads == target { d.bytes = changedBytes; observed = true }
            }
            var failure: Error?
            do {
                switch action {
                case "full": var draft = s; draft.showHudAlways.toggle(); _ = try d.store.savePreservingTemplates(draft, replacing: s)
                case "local": var draft = s; draft.cleanup.provider = "apple-intelligence"; _ = try d.store.savePreservingTemplates(draft, replacing: s)
                case "vocabulary": _ = try d.store.importVocabulary(preview, mode: .merge)
                case "confirm": _ = try d.store.confirmCleanupFailover(review)
                case "credential": try d.store.changeCredential(scope: .compatible("https://backup.test/v1"), replacement: "synthetic-new")
                default: if let message = d.store.migrateCredentials() { throw CredentialFailure(message) }
                }
            } catch { failure = error }
            d.onRead = nil
            if target != nil {
                XCTAssertTrue(observed, "\(action), read=\(target!)")
                XCTAssertEqual(cancellations, 1, "\(action), read=\(target!)")
                d.bytes = original
                var admitted = false
                XCTAssertThrowsError(try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted = true }, "\(action), read=\(target!)")
                XCTAssertFalse(admitted)
            } else { XCTAssertNil(failure, "positive control: \(action)") }
            unregister()
            return reads
        }
        for action in ["full", "local", "vocabulary", "confirm", "credential", "migration"] {
            let reads = try exercise(action, changeAt: nil)
            XCTAssertGreaterThan(reads, 0)
            for boundary in 1...reads { _ = try exercise(action, changeAt: boundary) }
        }
    }

    func testB21S1UnchangedAuthorityCredentialAndWriteFailuresKeepGrant() throws {
        let d = try B21SettingsDocument(B21SettingsDocument.primary), s = try d.enable(), id = UUID()
        let grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary)).bound(to: id)
        var cancellations = 0, admitted = 0
        let unregister = try d.store.registerCleanupFailoverCancellation(grant, operationID: id) { cancellations += 1 }
        let scope = try CredentialScope.compatible("https://backup.test/v1")
        try d.store.changeCredential(scope: scope, replacement: "rotated")
        try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted += 1 }
        try d.store.changeCredential(scope: scope, replacement: nil)
        try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted += 1 }
        d.backend.addResult = .denied
        XCTAssertThrowsError(try d.store.changeCredential(scope: .anthropic, replacement: "denied"))
        try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted += 1 }
        var draft = s; draft.showHudAlways.toggle(); d.failWrite = true
        XCTAssertThrowsError(try d.store.savePreservingTemplates(draft, replacing: s))
        try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted += 1 }
        d.failWrite = false
        _ = try d.store.savePreservingTemplates(draft, replacing: s)
        try d.store.withCleanupFailoverGrant(grant, operationID: id) { admitted += 1 }
        XCTAssertEqual(admitted, 5); XCTAssertEqual(cancellations, 0)
        unregister()
    }
}
