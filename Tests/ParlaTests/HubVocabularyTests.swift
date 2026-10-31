import Darwin
import XCTest
import ParlaCore
@testable import Parla

final class HubVocabularyTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!
    private var hub: HubModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-hub-vocabulary-tests-\(UUID().uuidString)")
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        try store.save(Settings())
        hub = HubModel(store: store, history: HistoryStore(url: directory.appendingPathComponent("history.json")), recordings: RecordingStore(directory: directory.appendingPathComponent("recordings")))
        hub.refresh()
    }

    override func tearDownWithError() throws {
        hub.flushPendingSave()
        hub = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testManualPriorityReplacementSaveAndStalePreview() throws {
        hub.words = [.init(text: "first"), .init(text: "second")]
        hub.moveWord(hub.words[1].id, by: -1)
        hub.replacements = [.init(source: "cat", replacement: "$1\\line\nnext")]
        hub.flushPendingSave()
        XCTAssertEqual(store.load().dictionary, ["second", "first"])
        XCTAssertEqual(store.load().replacements, [.init(source: "cat", replacement: "$1\\line\nnext")])
        var incoming = Settings()
        incoming.dictionary = ["imported"]
        hub.previewVocabulary(try VocabularyDocument(settings: incoming).encoded())
        XCTAssertNotNil(hub.importPreview)
        hub.words.append(.init(text: "newer edit"))
        XCTAssertNil(hub.importPreview)
        hub.applyVocabulary(.replace)
        hub.flushPendingSave()
        XCTAssertEqual(store.load().dictionary, ["second", "first", "newer edit"])
    }

    func testOversizedNewHintIsRejectedAndExistingLargeHintIsKept() throws {
        let huge = String(repeating: "界", count: 100)
        hub.words.append(.init(text: huge))
        hub.flushPendingSave()
        XCTAssertNotNil(hub.saveError)
        XCTAssertTrue(store.load().dictionary.isEmpty)
        var legacy = Settings()
        legacy.dictionary = [huge, "keep"]
        try store.save(legacy)
        hub.refresh()
        hub.settings.historyEnabled = false
        hub.flushPendingSave()
        XCTAssertNil(hub.saveError)
        XCTAssertEqual(store.load().dictionary, legacy.dictionary)
    }

    func testFileBecomingInvalidAfterPreviewDisablesHubWithoutEdits() throws {
        var incoming = Settings()
        incoming.dictionary = ["imported"]
        hub.previewVocabulary(try VocabularyDocument(settings: incoming).encoded())
        XCTAssertNotNil(hub.importPreview)
        try Data("new invalid settings".utf8).write(to: store.url)
        hub.applyVocabulary(.merge)
        XCTAssertNotNil(hub.loadError)
        XCTAssertEqual(try Data(contentsOf: store.url), Data("new invalid settings".utf8))
    }

    func testLoadErrorBlocksImportAndSaveErrorBlocksPreview() throws {
        let data = try VocabularyDocument(settings: Settings()).encoded()
        try Data("bad settings".utf8).write(to: store.url)
        hub.refresh()
        XCTAssertNotNil(hub.loadError)
        hub.previewVocabulary(data)
        XCTAssertNil(hub.importPreview)
        hub.applyVocabulary(.merge)
        XCTAssertEqual(try Data(contentsOf: store.url), Data("bad settings".utf8))
        hub.loadError = nil
        hub.saveError = "save failed"
        hub.previewVocabulary(data)
        XCTAssertNil(hub.importPreview)
    }
}


extension HubVocabularyTests {
    @MainActor func testSavedOriginalHardlinkGuardPrecedesActualInjectedWriter() async throws {
        let rig = try SavedImportRig(), original = try await rig.run()
        let alias = rig.root.appendingPathComponent("original-hardlink.json")
        XCTAssertEqual(link(original.path,alias.path),0)
        rig.hub.vocabularyExportWriter = { bytes,_ in rig.written.append(bytes) }
        rig.hub.vocabularyExportPanel = { alias }; rig.hub.exportVocabulary(); XCTAssertTrue(rig.written.isEmpty)
        rig.hub.vocabularyExportPanel = { rig.root.appendingPathComponent("safe.json") }
        rig.hub.exportVocabulary(); XCTAssertEqual(rig.written.count,1)
        XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
}
