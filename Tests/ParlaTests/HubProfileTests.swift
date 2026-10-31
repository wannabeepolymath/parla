import XCTest
import ParlaCore
@testable import Parla

final class HubProfileTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!
    private var hub: HubModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-hub-profile-tests-\(UUID().uuidString)")
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        var s = Settings(); s.dictionary = ["Global"]; s.anthropicApiKey = "preserve-key"
        s.replacements = [.init(source: "cat", replacement: "dog")]
        try store.saveTestSettings(s)
        hub = HubModel(store: store, history: HistoryStore(url: directory.appendingPathComponent("history.json")), recordings: RecordingStore(directory: directory.appendingPathComponent("recordings")))
        hub.refresh()
    }

    override func tearDownWithError() throws {
        hub.flushPendingSave(); hub = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func profile(_ target: String) -> DictationProfile {
        var p = DictationProfile(); p.name = target; p.target = target
        p.dictionary = ["Priority"]
        return p
    }

    func testReachablePageProfileCRUDOrderPersistenceAndExplicitPreview() {
        XCTAssertTrue(HubPage.allCases.contains(.profiles))
        let first = profile("com.example.First"), second = profile("com.example.Second")
        XCTAssertTrue(hub.saveProfile(first)); XCTAssertTrue(hub.saveProfile(second))
        hub.moveProfile(at: 1, by: -1)
        hub.flushPendingSave(); hub.refresh()
        XCTAssertEqual(store.load().profiles.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.load().dictionary, ["Global"])
        XCTAssertNil(store.load().anthropicApiKey); XCTAssertEqual(testStoredKey(store.credentials, .anthropic), "preserve-key")
        XCTAssertEqual(store.load().replacements, [.init(source: "cat", replacement: "dog")])
        var edit = second; edit.enabled = false; edit.style = .formal; edit.language = "auto"
        XCTAssertTrue(hub.saveProfile(edit, replacing: 0))
        hub.flushPendingSave(); hub.refresh()
        XCTAssertEqual(store.load().profiles[0], edit)
        XCTAssertEqual(hub.profilePreview(bundleID: second.target, browserURL: "").name, "Global settings")
        XCTAssertEqual(hub.profilePreview(bundleID: first.target, browserURL: "").settings.dictionary, ["Priority", "Global"])
        hub.deleteProfile(at: 0); hub.flushPendingSave()
        XCTAssertEqual(store.load().profiles, [first])
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: store.load(), cleanupConfigured: true,
                                              recognitionDestination: .init(bundleID: first.target))
            .resolvingOutput(at: .init(bundleID: "unknown"))
        hub.recordProfileWinners(session)
        XCTAssertEqual(hub.lastRecognitionProfile, first.name)
        XCTAssertEqual(hub.lastOutputProfile, "Global settings")
    }

    func testValidationRejectsDuplicateNormalizedTargetsOversizedWordsMissingModelsAndInvalidLanguage() {
        var p = profile("EXAMPLE.COM."); p.targetKind = .host
        XCTAssertTrue(hub.saveProfile(p))
        var duplicate = profile("example.com"); duplicate.targetKind = .host
        XCTAssertFalse(hub.saveProfile(duplicate))
        XCTAssertTrue(hub.profileError!.contains("Duplicate target"))
        var invalid = profile("app"); invalid.dictionary = [String(repeating: "界", count: 100)]
        XCTAssertFalse(hub.saveProfile(invalid))
        invalid.dictionary = []; invalid.language = "not-a-language"
        XCTAssertFalse(hub.saveProfile(invalid))
        invalid.language = nil; invalid.whisperModelPath = directory.appendingPathComponent("missing.bin").path
        XCTAssertFalse(hub.saveProfile(invalid))
        hub.flushPendingSave()
        XCTAssertEqual(store.load().profiles, [p])
        invalid.whisperModelPath = nil; invalid.name = " "
        XCTAssertFalse(hub.saveProfile(invalid))
    }

    func testMalformedProfileBlockIsRejectedVisiblyWithoutOverwritingUnrelatedDiskSettings() throws {
        let data = Data("{\"dictionary\":[\"keep\"],\"anthropicApiKey\":\"preserve\",\"profiles\":[{}]}".utf8)
        try data.write(to: store.url)
        hub.refresh()
        XCTAssertNotNil(hub.loadError)
        XCTAssertTrue(hub.loadError!.contains("Profiles rejected"))
        XCTAssertEqual(hub.settings.dictionary, ["keep"])
        XCTAssertEqual(hub.settings.anthropicApiKey, "preserve")
        XCTAssertTrue(hub.settings.profiles.isEmpty)
        XCTAssertFalse(hub.saveProfile(profile("app")))
        hub.settings.historyEnabled = false
        hub.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: store.url), data)
    }

    func testHandEditedDuplicatesWarnAndVocabularyImportPreservesProfiles() throws {
        var s = store.load()
        var first = profile("app"), second = profile("app")
        first.name = "First"; second.name = "Second"
        s.profiles = [first, second]
        try store.saveTestSettings(s); hub.refresh()
        XCTAssertNil(hub.loadError)
        XCTAssertEqual(ProfileResolver.warnings(hub.settings.profiles).count, 1)
        XCTAssertEqual(hub.profilePreview(bundleID: "app", browserURL: "").name, "First")
        var incoming = Settings(); incoming.dictionary = ["Imported"]
        hub.previewVocabulary(try VocabularyDocument(settings: incoming).encoded())
        hub.applyVocabulary(.merge)
        XCTAssertEqual(store.load().profiles, [first, second])
        let data = try VocabularyDocument(settings: store.load()).encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("profiles"))
    }
}
