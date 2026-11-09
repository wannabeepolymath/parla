import AppKit
import XCTest
import SwiftUI
import ParlaCore
@testable import Parla

final class HubHistoryTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!
    private var history: HistoryStore!
    private var hub: HubModel!
    private var failWrite = false
    private var copies: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-hub-history-2c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try recordWave4BFixture(directory, "created")
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        var s = Settings(); s.dictionary = ["Keep"]; s.anthropicApiKey = "fake-preserve"
        s.snippets = ["expand": "kept"]; s.replacements = [.init(source: "cat", replacement: "dog")]
        s.transformPresets = [.init(name: "Keep preset", instruction: "Keep instruction")]
        var profile = DictationProfile(); profile.name = "Keep profile"; profile.target = "com.test.Editor"
        s.profiles = [profile]
        try store.saveTestSettings(s)
        history = HistoryStore(url: directory.appendingPathComponent("history.json"), persistence: .init(writeAtomically: { [unowned self] data, url in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }))
        hub = HubModel(store: store, history: history, clipboard: { [unowned self] in self.copies.append($0) }, recordings: RecordingStore(directory: directory.appendingPathComponent("recordings")))
        hub.refresh()
    }
    override func tearDownWithError() throws {
        hub.flushPendingSave(); hub = nil; history = nil; store = nil
        try FileManager.default.removeItem(at: directory)
        try recordWave4BFixture(directory, "removed")
    }

    func testSharedStoreAppendDeleteFailureRetryAndClearPublishAccurateRows() throws {
        let a = HistoryEntry(raw: "same"), b = HistoryEntry(raw: "same")
        history.append(a); history.append(b)
        XCTAssertEqual(hub.historyEntries, [b, a]) // observer updates without a window refresh
        let bytes = try Data(contentsOf: history.url)
        failWrite = true; hub.deleteHistory(a.id)
        XCTAssertEqual(hub.historyEntries, [b, a]); XCTAssertNotNil(hub.historyError)
        XCTAssertEqual(try Data(contentsOf: history.url), bytes)
        hub.clearHistory(); XCTAssertEqual(hub.historyEntries, [b, a]); XCTAssertNotNil(hub.historyError)
        hub.refresh(); XCTAssertNotNil(hub.historyError) // opening Hub must retain a failed menu action
        failWrite = false; hub.deleteHistory(a.id); XCTAssertEqual(hub.historyEntries, [b])
        hub.clearHistory(); XCTAssertTrue(hub.historyEntries.isEmpty); XCTAssertNil(hub.historyError)
    }

    func testFailedResultCopyRetryDiscardAndClearNeverTouchProviderOrLiveClipboard() throws {
        let entry = HistoryEntry(raw: "Original\nहिन्दी", cleaned: "Result\n世界")
        failWrite = true; history.append(entry)
        XCTAssertTrue(hub.historyEntries.isEmpty); XCTAssertEqual(hub.pendingHistory, [entry]); XCTAssertNotNil(hub.historyError)
        hub.copyOriginal(entry); hub.copyResult(entry)
        XCTAssertEqual(copies, [entry.raw, entry.best])
        hub.retryHistorySave(entry.id); XCTAssertEqual(hub.pendingHistory, [entry])
        failWrite = false; hub.retryHistorySave(entry.id); hub.retryHistorySave(entry.id)
        XCTAssertEqual(hub.historyEntries, [entry]); XCTAssertTrue(hub.pendingHistory.isEmpty)
        hub.deleteHistory(entry.id); hub.retryHistorySave(entry.id); XCTAssertTrue(hub.historyEntries.isEmpty)
        failWrite = true; history.append(.init(raw: "discard me"))
        let discard = try XCTUnwrap(hub.pendingHistory.first)
        hub.discardHistory(discard.id); hub.retryHistorySave(discard.id); XCTAssertTrue(hub.pendingHistory.isEmpty)
        XCTAssertNil(hub.historyError); XCTAssertFalse(history.needsAttention)
        history.append(.init(raw: "clear me")); failWrite = false; hub.clearHistory()
        XCTAssertTrue(hub.historyEntries.isEmpty); XCTAssertTrue(hub.pendingHistory.isEmpty)
    }

    func testCountSettingPersistsAndTrimsOnlyAfterSettingsSaveKeepingUnrelatedSettings() throws {
        let original = store.load()
        for i in 0..<4 { history.append(.init(raw: "\(i)")) }
        hub.settings.historyTextCount = 2
        XCTAssertEqual(history.entries.count, 4) // debounced edit is not a persisted policy yet
        hub.flushPendingSave()
        XCTAssertEqual(store.load().historyTextCount, 2); XCTAssertEqual(hub.historyEntries.map(\.raw), ["3", "2"])
        var expected = original; expected.historyTextCount = 2
        XCTAssertEqual(store.load(), expected)
        hub.refresh(); XCTAssertEqual(hub.settings, expected)
        XCTAssertEqual(HistoryStore(url: history.url, countLimit: store.load().historyTextCount).entries, hub.historyEntries)
    }

    func testFailedTrimExposesUnappliedPolicyAndDoesNotClaimRowsRemoved() throws {
        for i in 0..<3 { history.append(.init(raw: "\(i)")) }
        let rows = hub.historyEntries, bytes = try Data(contentsOf: history.url)
        failWrite = true; hub.settings.historyTextCount = 1; hub.flushPendingSave()
        XCTAssertEqual(store.load().historyTextCount, 1); XCTAssertNil(hub.saveError)
        XCTAssertNotNil(hub.historyError); XCTAssertEqual(hub.historyEntries, rows)
        XCTAssertEqual(try Data(contentsOf: history.url), bytes)
        failWrite = false; hub.retryHistoryTrim()
        XCTAssertEqual(hub.historyEntries, [rows[0]]); XCTAssertNil(hub.historyError)
    }

    func testHistoryOffStillReadsCopiesAndDoesNotEraseSavedOrPendingText() throws {
        let entry = HistoryEntry(raw: "original", cleaned: "polished"); history.append(entry)
        failWrite = true; let pending = HistoryEntry(raw: "pending"); history.append(pending)
        hub.settings.historyEnabled = false; hub.flushPendingSave(); hub.refresh()
        XCTAssertFalse(store.load().historyEnabled); XCTAssertEqual(hub.historyEntries, [entry])
        XCTAssertEqual(hub.pendingHistory, [pending])
        hub.copyOriginal(entry); hub.copyResult(entry); XCTAssertEqual(copies, ["original", "polished"])
        failWrite = false; hub.retryHistorySave(pending.id)
        XCTAssertEqual(hub.historyEntries, [pending, entry]) // explicit retry of previously permitted result
    }

    func testSearchFindsBothVersionsAndExternalRefreshRetainsStableIdentity() throws {
        let entry = HistoryEntry(raw: "Original-only हिन्दी", cleaned: "Result-only 世界", appName: "Editor")
        history.append(entry)
        XCTAssertEqual(hub.filteredHistory("Original-only"), [entry]); XCTAssertEqual(hub.filteredHistory("Result-only"), [entry])
        XCTAssertEqual(hub.filteredHistory("editor"), [entry]); XCTAssertTrue(hub.filteredHistory("missing").isEmpty)
        let external = HistoryStore(url: history.url); let later = HistoryEntry(raw: "external"); external.append(later)
        hub.refresh(); XCTAssertEqual(hub.historyEntries, [later, entry])
    }

    func testHistoryLoadFailureBlocksMutationsButKeepsPendingCopyAndCanRecover() throws {
        let bytes = Data("{malformed history".utf8); try bytes.write(to: history.url)
        hub.refresh(); XCTAssertNotNil(hub.historyError); XCTAssertTrue(history.loadBlocked)
        let pending = HistoryEntry(raw: "new result"); history.append(pending)
        hub.clearHistory(); hub.retryHistorySave(pending.id)
        XCTAssertEqual(try Data(contentsOf: history.url), bytes); XCTAssertEqual(hub.pendingHistory, [pending])
        hub.copyOriginal(pending); XCTAssertEqual(copies, [pending.raw])
        try Data("[]".utf8).write(to: history.url); hub.reloadHistory()
        XCTAssertFalse(history.loadBlocked); hub.retryHistorySave(pending.id)
        XCTAssertEqual(hub.historyEntries, [pending]); XCTAssertNil(hub.historyError)
    }

    func testSettingsLoadAndSaveFailuresDoNotApplyNewRetention() throws {
        for i in 0..<3 { history.append(.init(raw: "\(i)")) }
        try Data("{invalid settings".utf8).write(to: store.url); hub.refresh()
        XCTAssertNotNil(hub.loadError); hub.settings.historyTextCount = 1; hub.flushPendingSave()
        XCTAssertEqual(history.entries.count, 3)
        let blocked = directory.appendingPathComponent("blocked"); try Data("file".utf8).write(to: blocked)
        let bad = HubModel(store: SettingsStore(url: blocked.appendingPathComponent("settings.json"), credentials: testCredentialStore()), history: history, clipboard: { _ in }, recordings: RecordingStore(directory: directory.appendingPathComponent("recordings")))
        bad.settings.historyTextCount = 1; bad.flushPendingSave()
        XCTAssertNotNil(bad.saveError); XCTAssertEqual(history.entries.count, 3); XCTAssertEqual(history.countLimit, 50)
    }

    func testHistoryViewsConstructAgainstActualPendingAndErrorState() {
        failWrite = true; history.append(.init(raw: "source", cleaned: "result"))
        // Exercise real SwiftUI bodies without creating a window or rendering host.
        _ = HistoryPage(model: hub).body; _ = PrivacyPage(model: hub).body; _ = HistoryStatus(model: hub).body
        XCTAssertEqual(hub.pendingHistory.count, 1); XCTAssertNotNil(hub.historyError)
    }
    func testActualStatusMenuCompositionSharesCommittedRowsAndSurfacesFailures() throws {
        let entry = HistoryEntry(raw: "original", cleaned: "result"); history.append(entry)
        failWrite = true; history.append(.init(raw: "unsaved"))
        let menu = NSMenu()
        AppDelegate.addHistoryItems(to: menu, history: history, target: nil)
        let warning = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(warning.action, #selector(AppDelegate.openHistory))
        let recent = try XCTUnwrap(menu.items.first(where: { $0.title == "Recent" })?.submenu)
        XCTAssertEqual(recent.items.first?.representedObject as? UUID, entry.id)
        XCTAssertEqual(recent.items.first?.title, "result")
        XCTAssertTrue(recent.items.last!.title.contains("1 not saved"))
        hub.clearHistory(); XCTAssertEqual(hub.historyEntries, [entry]); XCTAssertEqual(history.entries, [entry])
        failWrite = false; hub.clearHistory()
        let refreshed = NSMenu(); AppDelegate.addHistoryItems(to: refreshed, history: history, target: nil)
        XCTAssertEqual(hub.historyEntries, []); XCTAssertEqual(hub.pendingHistory, [])
        XCTAssertNil(refreshed.items.first(where: { $0.action == #selector(AppDelegate.openHistory) }))
        XCTAssertNil(refreshed.items.first(where: { $0.identifier?.rawValue == "paste-last" })?.action)
    }

    func testExplicitHistoryRecoveryUsesKnownCountWhenSettingsCannotLoad() throws {
        hub.settings.historyTextCount = 100; hub.flushPendingSave()
        for i in 0..<55 { history.append(.init(raw: "\(i)")) }
        let rows = history.entries
        try Data("{invalid settings".utf8).write(to: store.url); hub.refresh()
        XCTAssertNotNil(hub.loadError)
        hub.reloadHistory(); hub.retryHistoryTrim()
        XCTAssertEqual(history.countLimit, 100); XCTAssertEqual(hub.historyEntries, rows)
        hub.copyOriginal(rows[0]); XCTAssertEqual(copies, [rows[0].raw])
    }

    func testAutomaticRefreshPreservesBlockedDeleteAndClearWarnings() throws {
        for clearing in [false, true] {
            XCTAssertTrue(history.clear())
            let original = HistoryEntry(raw: "original"), external = HistoryEntry(raw: "external")
            XCTAssertTrue(history.append(original))
            try JSONEncoder().encode([original, external]).write(to: history.url)
            if clearing { hub.clearHistory() } else { hub.deleteHistory(original.id) }
            XCTAssertTrue(history.loadBlocked)
            XCTAssertNotNil(hub.historyError)
            hub.refresh()
            hub.reloadHistory() // the status-menu refresh path
            XCTAssertFalse(history.loadBlocked)
            XCTAssertTrue(hub.historyEntries.contains { $0.id == original.id })
            XCTAssertNotNil(hub.historyError)
            let menu = NSMenu()
            AppDelegate.addHistoryItems(to: menu, history: history, target: nil)
            XCTAssertNotNil(menu.items.first { $0.action == #selector(AppDelegate.openHistory) })
            if clearing { hub.clearHistory() } else { hub.deleteHistory(original.id) }
            XCTAssertNil(hub.historyError)
            XCTAssertFalse(hub.historyEntries.contains { $0.id == original.id })
        }
    }

}
