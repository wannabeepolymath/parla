import XCTest
import ParlaCore
@testable import Parla

final class ScratchpadHubPreferenceTests: XCTestCase {
    @MainActor private func fixture(initial: Settings = Settings()) throws -> (URL, SettingsStore, HubModel, FakeCredentialBackend) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wave4e1-hub-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data("created\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
        let backend = FakeCredentialBackend()
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        var settings = initial; settings.cleanup.provider = "apple-intelligence"; settings.historyEnabled = false
        // Seed authoritative disk state; full saves intentionally preserve an
        // existing flag rather than setting it from the supplied draft.
        try JSONEncoder().encode(settings).write(to: store.url, options: .atomic)
        let hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")),
            clipboard: { _ in XCTFail("No clipboard") }, recordings: RecordingStore(directory: root.appendingPathComponent("audio"), keepAll: false),
            shortcutLabels: ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } }), diagnostics: DiagnosticStore())
        // No refresh(): that existing operation reads native permission status.
        hub.refreshPreparationConfiguration() // Existing settings-only fixture load; no native status calls.
        return (root, store, hub, backend)
    }
    @MainActor func testPassiveCheckboxDoesNotFlushPendingDraftOrRunGeneralMouseCallbacks() throws {
        let (_, store, hub, backend) = try fixture()
        var general = 0, mouse = 0, draft = 0
        hub.onSaved = { general += 1 }; hub.onMouseBindingSaved = { mouse += 1 }
        hub.onScratchpadDictionaryDraftChanged = { draft += 1 }
        hub.words = [.init(text: "OpenAI")]
        XCTAssertEqual(draft, 1); XCTAssertTrue(hub.hasPendingSettingsSave)
        try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false)
        XCTAssertTrue(hub.settings.scratchpadDictionaryAlternativesEnabled)
        XCTAssertTrue(hub.hasPendingSettingsSave); XCTAssertEqual(general + mouse, 0)
        hub.flushPendingSave()
        XCTAssertNil(hub.saveError); XCTAssertTrue(store.load().scratchpadDictionaryAlternativesEnabled)
        XCTAssertFalse(store.load().historyEnabled); XCTAssertEqual(store.load().dictionary, ["OpenAI"])
        XCTAssertEqual(general, 1) // Existing vocabulary general callback retained.
        let before = draft
        hub.snippets = [.init(trigger: "hello", expansion: "there")]
        hub.replacements = [.init(source: "foo", replacement: "bar")]
        XCTAssertEqual(draft, before + 2)
        hub.settings.showHudAlways.toggle(); hub.flushPendingSave()
        XCTAssertEqual(general, 2)
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0)
    }
    @MainActor func testPassiveRevertsAndMixedGeneralSavePreserveNewerPrivacyGuard() throws {
        let (_, store, hub, _) = try fixture()
        var general = 0, mouse = 0
        hub.onSaved = { general += 1 }; hub.onMouseBindingSaved = { mouse += 1 }
        try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false)
        try store.setScratchpadDictionaryAlternativesEnabled(false, expected: true)
        try store.setScratchpadDictionaryAlternativesEnabled(true, expected: false)
        XCTAssertEqual(general + mouse, 0)
        hub.settings.showHudAlways.toggle(); hub.settings.showHudAlways.toggle()
        hub.flushPendingSave(); XCTAssertEqual(general, 0); XCTAssertEqual(mouse, 1) // Existing net-zero callback.
        hub.settings.showHudAlways.toggle()
        var newer = store.load(); newer.historyEnabled = true
        try store.save(newer)
        try store.setScratchpadDictionaryAlternativesEnabled(false, expected: true)
        hub.flushPendingSave()
        XCTAssertNotNil(hub.saveError) // Adopted only the flag; did not silently refresh privacy base.
        XCTAssertTrue(store.load().historyEnabled)
        XCTAssertFalse(store.load().scratchpadDictionaryAlternativesEnabled)
        XCTAssertFalse(hub.settings.scratchpadDictionaryAlternativesEnabled)
    }
    @MainActor func testOrdinaryHubSavesAndShrinkingVocabularyIgnoreSpellingInputCap() throws {
        for enabled in [false, true] {
            var initial = Settings()
            initial.scratchpadDictionaryAlternativesEnabled = enabled
            initial.dictionary = (0..<6_000).map { String(repeating: "字", count: 64) + String($0) }
            let (_, store, hub, backend) = try fixture(initial: initial)
            XCTAssertGreaterThan(try Data(contentsOf: store.url).count, ScratchpadPreferenceIO.maxBytes)
            XCTAssertThrowsError(try store.scratchpadDictionaryConfiguration())
            hub.settings.showHudAlways.toggle(); hub.flushPendingSave()
            XCTAssertNil(hub.saveError)
            XCTAssertEqual(store.load().showHudAlways, hub.settings.showHudAlways)
            XCTAssertEqual(store.load().dictionary.count, 6_000)
            XCTAssertEqual(hub.settings.scratchpadDictionaryAlternativesEnabled, enabled)
            hub.words = Array(hub.words.prefix(1)); hub.flushPendingSave()
            XCTAssertNil(hub.saveError); XCTAssertEqual(store.load().dictionary.count, 1)
            XCTAssertEqual(try store.scratchpadDictionaryConfiguration().enabled, enabled)
            XCTAssertFalse(store.load().historyEnabled)
            XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0)
        }
    }
}
