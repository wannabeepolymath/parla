import XCTest
import ParlaCore
@testable import Parla

final class HubTransformTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!
    private var hub: HubModel!
    private var history: HistoryStore!

    private final class Client: CleanupProviding {
        var instruction: String?
        var source: String?
        func clean(transcript: String, context: CleanupContext) async throws -> String {
            instruction = transcript; source = context.selection
            return "translated result"
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-hub-transform-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try recordWave4BFixture(directory, "created")
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        history = HistoryStore(url: directory.appendingPathComponent("history.json"))
        var s = Settings(); s.dictionary = ["Keep"]; s.anthropicApiKey = "fake-preserve"
        s.replacements = [.init(source: "cat", replacement: "dog")]
        try store.saveTestSettings(s)
        hub = HubModel(store: store, history: history, recordings: RecordingStore(directory: directory.appendingPathComponent("recordings"))); hub.refresh()
    }

    override func tearDownWithError() throws {
        hub.flushPendingSave(); hub = nil
        HotkeyMonitor.suspended = false
        try FileManager.default.removeItem(at: directory)
        try recordWave4BFixture(directory, "removed")
    }

    func testReachablePresetCRUDSelectionRoundtripAndDeletedSelectionStaysMissing() throws {
        XCTAssertTrue(HubPage.allCases.contains(.transforms)); XCTAssertTrue(hub.settings.transformPresets.isEmpty)
        let first = TransformPreset(name: "Shorten", instruction: "Make concise")
        let second = TransformPreset(name: "Hindi", kind: .translation, targetLanguage: "Hindi")
        XCTAssertTrue(hub.savePreset(first)); XCTAssertTrue(hub.savePreset(second))
        hub.selectPreset(first.id); hub.settings.outputMode = .selectedPreset
        hub.flushPendingSave(); hub.refresh()
        XCTAssertEqual(store.load().transformPresets, [first, second]); XCTAssertEqual(store.load().selectedPresetID, first.id)
        XCTAssertEqual(store.load().outputMode, .selectedPreset)
        XCTAssertEqual(store.load().dictionary, ["Keep"]); XCTAssertNil(store.load().anthropicApiKey); XCTAssertEqual(testStoredKey(store.credentials, .anthropic), "fake-preserve")
        XCTAssertEqual(store.load().replacements, [.init(source: "cat", replacement: "dog")])
        var edit = first; edit.instruction = "Use bullets"; edit.name = "Bullets"
        XCTAssertTrue(hub.savePreset(edit, replacing: first.id))
        hub.flushPendingSave(); hub.refresh(); XCTAssertEqual(store.load().transformPresets[0], edit)
        hub.deletePreset(first.id); hub.flushPendingSave(); hub.refresh()
        XCTAssertEqual(store.load().selectedPresetID, first.id); XCTAssertNotNil(hub.selectedPresetError)
        XCTAssertEqual(store.load().transformPresets, [second])
        XCTAssertFalse(hub.savePreset(edit, replacing: first.id))
        hub.selectPreset(second.id); hub.flushPendingSave(); XCTAssertNil(hub.selectedPresetError)
        hub.selectPreset(nil); hub.flushPendingSave(); XCTAssertNil(store.load().selectedPresetID)
    }

    func testValidationLoadAndSaveGatesPreserveUnownedSettings() throws {
        XCTAssertFalse(hub.savePreset(TransformPreset(name: " ", instruction: "x")))
        XCTAssertFalse(hub.savePreset(TransformPreset(name: "Name", instruction: " ")))
        XCTAssertFalse(hub.savePreset(TransformPreset(name: "Name", kind: .translation, targetLanguage: "")))
        let p = TransformPreset(name: "Name", instruction: "x")
        XCTAssertTrue(hub.savePreset(p)); XCTAssertFalse(hub.savePreset(p))
        hub.selectPreset(p.id); let missing = UUID(); hub.selectPreset(missing)
        XCTAssertEqual(hub.settings.selectedPresetID, p.id); XCTAssertNotNil(hub.presetError)
        hub.flushPendingSave()
        let malformed = Data("{\"dictionary\":[\"Preserve\"],\"outputMode\":\"selectedPreset\",\"selectedPresetID\":\"\(p.id.uuidString)\",\"transformPresets\":[{}]}".utf8)
        try malformed.write(to: store.url); hub.refresh()
        XCTAssertNotNil(hub.loadError); XCTAssertEqual(hub.settings.dictionary, ["Preserve"])
        XCTAssertEqual(hub.settings.selectedPresetID, p.id); XCTAssertEqual(hub.settings.outputMode, .selectedPreset)
        XCTAssertThrowsError(try hub.settings.selectedTransformPreset())
        XCTAssertFalse(hub.savePreset(p)); hub.selectPreset(nil); hub.deletePreset(p.id)
        hub.setOptionalHotkey(\.runSelectedPreset, to: KeyChord(17, [.ctrl, .opt]))
        hub.settings.outputMode = .raw; hub.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: store.url), malformed)
    }

    func testSaveErrorRemainsVisibleAndDoesNotPersistPreset() throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let badStore = SettingsStore(url: blocked.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        let badHub = HubModel(store: badStore, history: history, recordings: RecordingStore(directory: directory.appendingPathComponent("recordings")))
        XCTAssertTrue(badHub.savePreset(.init(name: "Test", instruction: "Shorten")))
        badHub.flushPendingSave()
        XCTAssertNotNil(badHub.saveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: badStore.url.path))
    }

    func testHubSaveToPhysicalShortcutToFrozenSelectionRequestWithoutASR() async throws {
        let p = TransformPreset(name: "Hindi", kind: .translation, targetLanguage: "Hindi")
        XCTAssertTrue(hub.savePreset(p)); hub.selectPreset(p.id)
        hub.setOptionalHotkey(\.runSelectedPreset, to: KeyChord(17, [.ctrl, .opt]))
        hub.flushPendingSave(); hub.refresh()
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        XCTAssertEqual((encoded["hotkeys"] as? [String: Any])?["runSelectedPreset"] as? String, "ctrl+opt+t")
        let monitor = HotkeyMonitor(store: store), machine = DictationSession(), client = Client()
        var pending: DictationSession.Session?
        var effects: [DictationSession.Effect] = []
        monitor.onEdge = { [self] edge in
            guard edge == .runSelectedPreset else { return }
            effects = machine.handle(.startSavedPreset(settings: store.load(), cleanupConfigured: true, selection: "original source",
                target: .init(focus: .editable, bundleID: "destination", appName: "Editor")))
            pending = effects.compactMap { if case .runSavedPreset(let s) = $0 { return s }; return nil }.first
        }
        XCTAssertTrue(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], at: 1))
        let operation = try XCTUnwrap(pending)
        XCTAssertFalse(effects.contains(.ensureModelLoaded))
        XCTAssertFalse(effects.contains { if case .transcribeCommand = $0 { return true }; if case .applyPreferencesAndStartCapture = $0 { return true }; return false })
        hub.deletePreset(p.id); hub.flushPendingSave() // queued operation keeps its snapshot
        let text = try await operation.transform(instruction: operation.preset!.intent) { _ in client }
        XCTAssertEqual(client.source, "original source"); XCTAssertTrue(client.instruction!.contains("Hindi"))
        let done = machine.handle(.transformReady(operation, text: text, probe: .capture(for: operation, currentGeneration: machine.gen,
            focus: { .editable }, destinationStillMatches: { true }, selectedText: { "original source" })))
        for effect in done {
            if case let .appendTransformHistory(raw, cleaned, appName, provenance, metrics) = effect {
                history.append(.init(raw: raw, cleaned: cleaned, appName: appName, metrics: metrics, operation: provenance))
            }
        }
        let row = try XCTUnwrap(HistoryStore(url: history.url).entries.first)
        XCTAssertEqual(row.raw, "original source"); XCTAssertEqual(row.cleaned, "translated result")
        XCTAssertEqual(row.operation?.presetID, p.id); XCTAssertEqual(row.operation?.origin, .selection)
        XCTAssertTrue(done.contains(.insertText("translated result", historyEnabled: true)))
    }

    func testOptionalShortcutNilCollisionsReservedTriggerClearRepeatAndSuspension() {
        let chord = KeyChord(17, [.ctrl, .opt])
        XCTAssertNil(store.load().hotkeys.runSelectedPreset)
        for invalid in [hub.settings.hotkeys.pasteLast, hub.settings.hotkeys.openScratchpad,
                        hub.settings.hotkeys.handsFree, KeyChord(53, .cmd), KeyChord(17), KeyChord(17, .fn), KeyChord(55)] {
            hub.setOptionalHotkey(\.runSelectedPreset, to: invalid)
            XCTAssertNotNil(hub.hotkeyError); XCTAssertNil(hub.settings.hotkeys.runSelectedPreset)
        }
        hub.setOptionalHotkey(\.runSelectedPreset, to: chord); hub.flushPendingSave()
        let monitor = HotkeyMonitor(store: store); var edges: [HotkeyMonitor.Edge] = []
        monitor.onEdge = { edges.append($0) }
        XCTAssertTrue(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], at: 1))
        XCTAssertTrue(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], isRepeat: true, at: 2))
        XCTAssertEqual(edges, [.runSelectedPreset])
        HotkeyMonitor.suspended = true
        XCTAssertFalse(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], at: 3))
        XCTAssertEqual(edges, [.runSelectedPreset]); HotkeyMonitor.suspended = false
        monitor.handle(keyCode: 63, modifiers: .fn, at: 4)
        XCTAssertFalse(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], at: 5))
        XCTAssertEqual(edges, [.runSelectedPreset, .down(command: false), .cancel])
        hub.setOptionalHotkey(\.runSelectedPreset, to: nil); hub.flushPendingSave()
        XCTAssertFalse(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], at: 6))
        XCTAssertNil(store.load().hotkeys.runSelectedPreset)
        XCTAssertFalse(monitor.receiveKeyDown(keyCode: 17, modifiers: [.ctrl, .opt], isRepeat: true, at: 7))
    }

    func testVocabularyTransferExcludesModesPresetsAndHotkey() throws {
        let p = TransformPreset(name: "Private preset", instruction: "Private instruction")
        XCTAssertTrue(hub.savePreset(p)); hub.selectPreset(p.id); hub.settings.outputMode = .raw
        hub.setOptionalHotkey(\.runSelectedPreset, to: KeyChord(17, [.ctrl, .opt])); hub.flushPendingSave()
        let data = try VocabularyDocument(settings: store.load()).encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Private")); XCTAssertFalse(text.contains("outputMode")); XCTAssertFalse(text.contains("runSelectedPreset"))
        var imported = Settings(); imported.dictionary = ["Imported"]
        hub.previewVocabulary(try VocabularyDocument(settings: imported).encoded()); hub.applyVocabulary(.merge)
        XCTAssertEqual(store.load().transformPresets, [p]); XCTAssertEqual(store.load().outputMode, .raw)
        XCTAssertEqual(store.load().selectedPresetID, p.id); XCTAssertNotNil(store.load().hotkeys.runSelectedPreset)
    }
}
