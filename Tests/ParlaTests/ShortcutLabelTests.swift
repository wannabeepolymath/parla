import AppKit
import Combine
import ParlaCore
import XCTest
@testable import Parla

final class ShortcutLabelTests: XCTestCase {
    private final class Center: NotificationCenter, @unchecked Sendable {
        var registrations = 0
        var removals = 0
        override func addObserver(_ observer: Any, selector: Selector, name: Notification.Name?, object: Any?) {
            registrations += 1
            super.addObserver(observer, selector: selector, name: name, object: object)
        }
        override func removeObserver(_ observer: Any, name: Notification.Name?, object: Any?) {
            removals += 1
            super.removeObserver(observer, name: name, object: object)
        }
    }

    private var directory: URL!
    private var store: SettingsStore!
    private var history: HistoryStore!
    private var hub: HubModel!
    private var labels: ShortcutLabels!
    private var center: Center!
    private var layout: [UInt16: String] = [0: "a", 9: "v", 12: "q", 16: "y"]
    private var snapshots = 0
    private var saves = 0
    private weak var observedHub: HubModel?
    private weak var observedLabels: ShortcutLabels?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-shortcut-display-2d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        var settings = Settings()
        settings.hotkeys.openScratchpad = KeyChord(0, [.ctrl, .cmd])
        settings.hotkeys.runSelectedPreset = KeyChord(16, [.ctrl, .cmd])
        try store.save(settings)
        history = HistoryStore(url: directory.appendingPathComponent("history.json"))
        center = Center()
        labels = ShortcutLabels(center: center) { [unowned self] in
            XCTAssertTrue(Thread.isMainThread)
            self.snapshots += 1
            let value = self.layout // value snapshot, not a live mutable lookup
            return ShortcutDisplayFormatter { value[$0] }
        }
        hub = HubModel(store: store, history: history,
                       recordings: RecordingStore(directory: directory.appendingPathComponent("recordings")),
                       shortcutLabels: labels)
        hub.onSaved = { [unowned self] in self.saves += 1 }
        hub.refresh()
    }

    override func tearDownWithError() throws {
        hub?.flushPendingSave()
        hub = nil; labels = nil; center = nil; history = nil; store = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func changeSource(to value: [UInt16: String]) {
        layout = value
        center.post(name: ShortcutLabels.inputSourceDidChange, object: nil)
    }

    func testExistingRecorderCommandAndOptionalPillsRefreshWithoutSavingOrRebinding() throws {
        let original = hub.settings.hotkeys
        let bytes = try Data(contentsOf: store.url)
        let recorder = ShortcutRecorder(model: hub, path: \.openScratchpad)
        let presetRecorder = ShortcutRecorder(model: hub, optionalPath: \.runSelectedPreset)
        XCTAssertEqual(recorder.label, "⌃ ⌘ a")
        XCTAssertEqual(presetRecorder.label, "⌃ ⌘ y")
        XCTAssertEqual(hub.commandShortcutDisplay, "⇧ fn")
        _ = recorder.body; _ = presetRecorder.body // actual production bodies, no window
        let before = labels.formatter
        changeSource(to: [0: "q", 9: "v", 12: "a", 16: "y"])
        XCTAssertEqual(recorder.label, "⌃ ⌘ q")
        XCTAssertEqual(before.display(original.openScratchpad), "⌃ ⌘ a") // immutable snapshot
        changeSource(to: [0: "a", 9: "v", 12: "q", 16: "z"])
        XCTAssertEqual(presetRecorder.label, "⌃ ⌘ z")
        XCTAssertEqual(hub.shortcutRevision, 2)
        XCTAssertEqual(snapshots, 3)
        // Also wait beyond the Hub save debounce: a source refresh must not queue a save.
        RunLoop.main.run(until: Date() + 0.6)
        XCTAssertEqual(hub.settings.hotkeys, original)
        XCTAssertEqual(store.load().hotkeys, original)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(saves, 0)
    }

    func testAttemptedChordValidationUsesLiveFormatterIncludingOptionalPreset() throws {
        let bindings = hub.settings.hotkeys
        let bytes = try Data(contentsOf: store.url)
        hub.setHotkey(\.pushToTalk, to: KeyChord(12))
        XCTAssertEqual(hub.hotkeyError, "q won't work — push to talk must be a modifier key held on its own — fn, control, option or command.")
        changeSource(to: [12: "a"])
        XCTAssertTrue(try XCTUnwrap(hub.hotkeyError).hasPrefix("a won't work"))
        hub.setOptionalHotkey(\.runSelectedPreset, to: KeyChord(12))
        XCTAssertTrue(try XCTUnwrap(hub.hotkeyError).hasPrefix("a won't work"))
        XCTAssertTrue(try XCTUnwrap(hub.hotkeyError).contains("needs at least one modifier"))
        changeSource(to: [:])
        XCTAssertTrue(try XCTUnwrap(hub.hotkeyError).hasPrefix("Q (physical key 12) won't work"))
        XCTAssertEqual(hub.settings.hotkeys, bindings)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(saves, 0)
        hub.hotkeyError = nil
        changeSource(to: [12: "q"])
        XCTAssertNil(hub.hotkeyError) // dismissed errors stay dismissed
    }

    func testRecorderCommitAndOptionalClearPersistCanonicalChordsAcrossLayouts() throws {
        changeSource(to: [9: "ж", 16: "z", 12: "a"])
        hub.setHotkey(\.pasteLast, to: KeyChord(9, [.ctrl, .cmd]))
        hub.setOptionalHotkey(\.runSelectedPreset, to: KeyChord(12, [.ctrl, .cmd]))
        XCTAssertEqual(ShortcutRecorder(model: hub, path: \.pasteLast).label, "⌃ ⌘ ж")
        XCTAssertEqual(ShortcutRecorder(model: hub, optionalPath: \.runSelectedPreset).label, "⌃ ⌘ a")
        hub.flushPendingSave()
        let bytes = try Data(contentsOf: store.url)
        let saved = try JSONDecoder().decode(Settings.self, from: bytes)
        XCTAssertEqual(saved.hotkeys.pasteLast, KeyChord(9, [.ctrl, .cmd]))
        XCTAssertEqual(saved.hotkeys.runSelectedPreset, KeyChord(12, [.ctrl, .cmd]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let hotkeys = try XCTUnwrap(json["hotkeys"] as? [String: String])
        XCTAssertEqual(hotkeys["pasteLast"], "ctrl+cmd+v")
        XCTAssertEqual(hotkeys["runSelectedPreset"], "ctrl+cmd+q")
        changeSource(to: [9: "v", 12: "q"])
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(saves, 1)
        hub.setOptionalHotkey(\.runSelectedPreset, to: nil)
        XCTAssertEqual(ShortcutRecorder(model: hub, optionalPath: \.runSelectedPreset).label, "Unbound")
        hub.flushPendingSave()
        XCTAssertNil(store.load().hotkeys.runSelectedPreset)
    }

    func testActualMenuHintsUseCurrentDiskBindingAndFormatterWithoutCharacterEquivalents() throws {
        history.append(.init(raw: "result"))
        let menu = NSMenu()
        AppDelegate.addScratchpadItem(to: menu, bindings: store.load().hotkeys, formatter: labels.formatter, target: nil)
        AppDelegate.addHistoryItems(to: menu, history: history, target: nil,
                                   bindings: store.load().hotkeys, formatter: labels.formatter)
        let observer = AppDelegate.observeShortcutHints(in: menu, labels: labels, store: store)
        defer { observer.cancel() }
        let scratch = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.openScratchpad) })
        let paste = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.pasteLastDictation) })
        XCTAssertEqual(scratch.title, "Open Scratchpad    ⌃ ⌘ a")
        XCTAssertEqual(paste.title, "Paste Last Dictation    ⌃ ⌘ v")
        var settings = store.load()
        settings.hotkeys.openScratchpad = KeyChord(12, [.opt, .cmd])
        settings.hotkeys.pasteLast = KeyChord(16, [.ctrl, .cmd])
        try store.save(settings)
        let bytes = try Data(contentsOf: store.url)
        changeSource(to: [12: "a", 16: "z"])
        XCTAssertEqual(scratch.title, "Open Scratchpad    ⌥ ⌘ a")
        XCTAssertEqual(paste.title, "Paste Last Dictation    ⌃ ⌘ z")
        XCTAssertEqual(scratch.action, #selector(AppDelegate.openScratchpad))
        XCTAssertEqual(paste.action, #selector(AppDelegate.pasteLastDictation))
        for item in [scratch, paste] {
            XCTAssertEqual(item.keyEquivalent, "")
            XCTAssertTrue(item.keyEquivalentModifierMask.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(saves, 0)
        observer.cancel()
        changeSource(to: [:])
        XCTAssertEqual(paste.title, "Paste Last Dictation    ⌃ ⌘ z") // subscription cleanup
    }

    func testEmptyHistoryMenuHintRefreshKeepsPasteDisabled() throws {
        let menu = NSMenu()
        AppDelegate.addHistoryItems(to: menu, history: history, target: nil,
                                   bindings: store.load().hotkeys, formatter: labels.formatter)
        let paste = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "paste-last" })
        XCTAssertNil(paste.action)
        changeSource(to: [:])
        AppDelegate.refreshShortcutHints(in: menu, bindings: store.load().hotkeys, formatter: labels.formatter)
        XCTAssertEqual(paste.title, "Paste Last Dictation    ⌃ ⌘ V (physical key 9)")
        XCTAssertNil(paste.action); XCTAssertEqual(paste.keyEquivalent, "")
    }

    func testNotificationRefreshDeliversOnMainAndIgnoresOtherNotifications() {
        center.post(name: Notification.Name("unrelated"), object: nil)
        XCTAssertEqual(snapshots, 1)
        let refreshed = expectation(description: "Source revision delivered on main")
        let observer = labels.$revision.dropFirst().sink { _ in
            XCTAssertTrue(Thread.isMainThread)
            refreshed.fulfill()
        }
        let localCenter = center!
        DispatchQueue.global().async { localCenter.post(name: ShortcutLabels.inputSourceDidChange, object: nil) }
        wait(for: [refreshed], timeout: 2)
        observer.cancel()
        XCTAssertEqual(hub.shortcutRevision, 1)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(saves, 0)
    }

    func testProductionLazyHubCompositionUsesOneLabelsOwnerAndCachesTapWithoutConstruction() throws {
        let state = HubBootstrapState(shortcutLabels: labels)
        var constructed = 0
        func construct() -> HubModel { state.resolve { constructed += 1; return hub } }
        state.updateTapStatus(.unavailable)
        changeSource(to: [0: "q"])
        XCTAssertNil(state.existingHub); XCTAssertEqual(constructed, 0)
        XCTAssertEqual(state.shortcutLabels.revision, 1)
        XCTAssertTrue(construct().shortcutLabels === state.shortcutLabels)
        XCTAssertTrue(state.existingHub === hub); XCTAssertEqual(constructed, 1)
        _ = construct(); XCTAssertEqual(constructed, 1)
        XCTAssertEqual(center.registrations, 1)
        state.updateTapStatus(.unavailable)
        XCTAssertEqual(hub.inputTapStatus, state.tapStatus)
    }

    func testRetainedObserverUnregistersWhenHubAndLabelOwnerAreReleased() {
        XCTAssertEqual(center.registrations, 1)
        observedHub = hub
        observedLabels = labels
        hub = nil
        XCTAssertNil(observedHub)
        XCTAssertNotNil(observedLabels) // explicitly retained source owner
        labels = nil
        XCTAssertNil(observedLabels)
        XCTAssertEqual(center.removals, 1)
        center.post(name: ShortcutLabels.inputSourceDidChange, object: nil)
        XCTAssertEqual(snapshots, 1)
    }
}
