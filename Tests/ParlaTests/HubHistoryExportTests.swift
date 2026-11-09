import Darwin
import XCTest
import SwiftUI
@testable import ParlaCore
import UniformTypeIdentifiers
@testable import Parla

final class HubHistoryExportTests: XCTestCase {
    private var directory: URL!
    private var settings: SettingsStore!
    private var history: HistoryStore!
    private var recordings: RecordingStore!
    private var hub: HubModel!
    private var selectedURL: URL?
    private var panels: [HistoryExportSaveRequest] = []
    private var writes: [(Data, URL)] = []
    private var failHistoryWrite = false
    private var failExportWrite = false
    private var forbiddenCalls = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-export-2c3-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = SettingsStore(url: directory.appendingPathComponent("actual-settings.txt"), credentials: testCredentialStore())
        var config = Settings()
        config.anthropicApiKey = "SENTINEL_ANTHROPIC"; config.cleanup.apiKey = "SENTINEL_KEY"
        config.cleanup.apiKeyEnvVar = "SENTINEL_ENV"; config.cleanup.baseURL = "https://SENTINEL_ENDPOINT.test/private"
        config.cleanup.model = "SENTINEL_MODEL"
        try settings.saveTestSettings(config)
        history = HistoryStore(url: directory.appendingPathComponent("actual-history.txt"), persistence: .init(writeAtomically: { [unowned self] data, url in
            if self.failHistoryWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }))
        recordings = RecordingStore(directory: directory.appendingPathComponent("actual-recordings"), keepAll: false)
        try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
        hub = HubModel(store: settings, history: history, clipboard: { [unowned self] _ in self.forbiddenCalls += 1 }, recordings: recordings)
        hub.refresh()
        selectedURL = directory.appendingPathComponent("export.txt")
        hub.historyExportClock = { Date(timeIntervalSince1970: 0) }
        hub.historyExportPanel = { [unowned self] request in self.panels.append(request); return self.selectedURL }
        hub.historyExportWriter = { [unowned self] data, url in
            self.writes.append((data, url))
            if self.failExportWrite { throw NSError(domain: "SENTINEL_RAW_ERROR", code: 1) }
        }
        hub.retryEnvironment = { [unowned self] in self.forbiddenCalls += 1; return [:] }
        hub.retryFactory = { [unowned self] _, _, _, _ in self.forbiddenCalls += 1; throw CocoaError(.userCancelled) }
        hub.onTryoutStart = { [unowned self] in self.forbiddenCalls += 1; return "forbidden" }
        hub.onTryoutStop = { [unowned self] _ in self.forbiddenCalls += 1 }
        hub.onDownloadModel = { [unowned self] _ in self.forbiddenCalls += 1 }
        hub.onSaved = { [unowned self] in self.forbiddenCalls += 1 }
    }

    override func tearDownWithError() throws {
        XCTAssertEqual(forbiddenCalls, 0, "Export must not call providers, environment, capture, clipboard, model or settings-save callbacks")
        hub = nil; history = nil; settings = nil; recordings = nil
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult private func row(_ raw: String = "Original हिन्दी\nالعربية 👩🏽‍💻 e\u{301}", result: String? = "Result\n世界", app: String? = "Editor") -> HistoryEntry {
        let row = HistoryEntry(date: Date(timeIntervalSince1970: 0), raw: raw, cleaned: result, appName: app)
        XCTAssertTrue(history.append(row)); return row
    }
    private var output: String { String(decoding: writes.last!.0, as: UTF8.self) }

    func testPerRowOriginalAndResultAreExplicitRegardlessOfDictationModeAndDoNotMutate() throws {
        let entry = row()
        let settingsBytes = try Data(contentsOf: settings.url), historyBytes = try Data(contentsOf: history.url)
        // Mode edits are intentionally left unsaved. Export must not flush them.
        hub.loadError = "settings unavailable"
        for mode in DictationOutputMode.allCases {
            hub.settings.outputMode = mode
            for content in TranscriptExport.Content.allCases {
                hub.prepareHistoryExport(rowID: entry.id)
                XCTAssertEqual(hub.historyExport?.count, 1)
                hub.exportHistory(content: content, format: .text)
                XCTAssertTrue(output.contains(content == .original ? entry.raw : entry.best))
                XCTAssertTrue(hub.historyExportMessage!.contains("Exported 1 dictation."))
                XCTAssertNil(hub.historyExport)
            }
        }
        XCTAssertEqual(history.entries, [entry]); XCTAssertTrue(history.pendingEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: settings.url), settingsBytes)
        XCTAssertEqual(try Data(contentsOf: history.url), historyBytes)
    }

    func testFilteredScopeFreezesRowsOrderAndContentExcludesPendingAndProposed() throws {
        let first = row("match Original A", result: "saved Result A")
        let second = row("Original B", result: "match saved B")
        row("unmatched", result: "other", app: "Elsewhere")
        failHistoryWrite = true; history.append(.init(raw: "match PENDING")); failHistoryWrite = false
        let request = try HistoryRetryRequest(settings: settings.load(), environment: [:], source: first, applyPreset: false, credentials: settings.credentials)
        var preview = HistoryRetryPreview(original: first, version: try XCTUnwrap(history.version(of: first.id)), request: request)
        preview.proposed = "match UNSAVED_PROPOSED"; hub.historyRetries[first.id] = preview
        hub.prepareFilteredHistoryExport("match ")
        XCTAssertEqual(hub.historyExport?.count, 2)
        XCTAssertEqual(hub.historyExport?.result.entries.map(\.text), [second.best, first.best])
        _ = HistoryExportReview(model: hub, request: hub.historyExport!).body
        _ = HistoryPage(model: hub).body
        // Changes after review, including while the native panel is open, cannot
        // change the reviewed count, source text or saved membership.
        history.delete(second.id)
        hub.historyExportPanel = { [unowned self] request in
            self.panels.append(request); self.history.clear(); self.row("match LATE")
            return self.selectedURL
        }
        hub.exportHistory(content: .result, format: .text)
        XCTAssertTrue(output.contains(second.best)); XCTAssertTrue(output.contains(first.best))
        for excluded in ["unmatched", "PENDING", "UNSAVED_PROPOSED", "LATE"] { XCTAssertFalse(output.contains(excluded)) }
        XCTAssertTrue(hub.historyExportMessage!.contains("Exported 2 dictations."))
    }

    func testPerRowScopeFreezesOriginalAndResultEvenAfterDeletion() {
        let first = row("original picked", result: "result picked"), other = row("other")
        hub.prepareHistoryExport(rowID: first.id); history.delete(first.id)
        hub.exportHistory(content: .original, format: .text)
        XCTAssertTrue(output.contains(first.raw)); XCTAssertFalse(output.contains(other.raw))
        XCTAssertTrue(hub.historyExportMessage!.contains("Exported 1 dictation."))
    }

    func testEmptyFilterAndNonSavedIDsNeverOpenPanelOrWrite() {
        let entry = row()
        hub.prepareFilteredHistoryExport("missing"); hub.exportHistory(content: .result, format: .text)
        XCTAssertNil(hub.historyExport); XCTAssertTrue(hub.historyExportMessage!.contains("Nothing in History matches"))
        failHistoryWrite = true; let pending = HistoryEntry(raw: "pending"); history.append(pending)
        hub.prepareHistoryExport(rowID: pending.id); hub.exportHistory(content: .original, format: .text)
        history.delete(entry.id) // fails; still saved, but not the requested ID
        hub.prepareHistoryExport(rowID: UUID()); hub.exportHistory(content: .result, format: .text)
        XCTAssertTrue(panels.isEmpty); XCTAssertTrue(writes.isEmpty)
    }

    func testAllFilteredIncludesAppAndBothTextVersionsAndEmptyTextRows() {
        let original = row("needle-original", result: "one", app: "A")
        let result = row("two", result: "needle-result", app: "B")
        let empty = row("", result: "", app: "needle-app")
        hub.prepareFilteredHistoryExport("needle")
        XCTAssertEqual(hub.historyExport?.original.entries.map(\.text), [empty.raw, result.raw, original.raw])
        hub.exportHistory(content: .result, format: .text)
        XCTAssertTrue(output.contains("Entry 1")); XCTAssertTrue(output.contains("Entry 2")); XCTAssertTrue(output.contains("Entry 3"))
        XCTAssertTrue(output.contains("App: needle-app\n\n\n"))
        hub.prepareFilteredHistoryExport(""); XCTAssertEqual(hub.historyExport?.count, 3)
    }

    func testNilCleanedFallsBackButEmptyCleanedExportsEmptyResult() {
        row("fallback original", result: nil); row("must not replace empty result", result: "")
        hub.prepareFilteredHistoryExport(""); hub.exportHistory(content: .result, format: .text)
        XCTAssertTrue(output.contains("fallback original")); XCTAssertFalse(output.contains("must not replace"))
    }

    func testPanelUsesNeutralFilenameCorrectTypesAndRejectsMismatchedExtensionBeforeWriter() throws {
        let entry = row("filename-secret", app: "app-secret")
        for format in TranscriptExport.Format.allCases {
            hub.prepareHistoryExport(rowID: entry.id)
            selectedURL = directory.appendingPathComponent("chosen.\(format.fileExtension)")
            hub.exportHistory(content: .result, format: format)
            let panel = try XCTUnwrap(panels.last)
            XCTAssertEqual(panel.filename, "parla-transcripts-1970-01-01.\(format.fileExtension)")
            XCTAssertEqual(panel.contentType.preferredFilenameExtension, format.fileExtension)
            XCTAssertEqual(panel.format, format); XCTAssertEqual(writes.last?.1, selectedURL)
            XCTAssertEqual(output.hasPrefix("## "), format == .markdown)
        }
        let count = writes.count
        hub.prepareHistoryExport(rowID: entry.id); selectedURL = directory.appendingPathComponent("wrong.json")
        hub.exportHistory(content: .original, format: .text)
        XCTAssertEqual(writes.count, count); XCTAssertTrue(hub.historyExportMessage!.contains(".txt"))
    }

    func testCancelWritesNothingReportsNeitherSuccessNorFailureAndKeepsReview() {
        let entry = row(); hub.prepareHistoryExport(rowID: entry.id)
        selectedURL = nil; hub.historyExportMessage = "old status"
        hub.exportHistory(content: .original, format: .markdown)
        XCTAssertEqual(panels.count, 1); XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(hub.historyExportMessage); XCTAssertEqual(hub.historyExport?.count, 1)
    }

    func testWriteFailureRetainsReviewAndRetryUsesSameSnapshotWithSafeStatus() {
        let entry = row(); hub.prepareHistoryExport(rowID: entry.id)
        failExportWrite = true; hub.exportHistory(content: .original, format: .text)
        XCTAssertEqual(writes.count, 1); XCTAssertNotNil(hub.historyExport)
        XCTAssertTrue(hub.historyExportMessage!.contains("Couldn’t export."))
        XCTAssertFalse(hub.historyExportMessage!.contains("SENTINEL_RAW_ERROR"))
        failExportWrite = false; history.delete(entry.id)
        hub.exportHistory(content: .original, format: .text)
        XCTAssertEqual(writes.count, 2); XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertTrue(hub.historyExportMessage!.contains("Exported 1 dictation."))
    }

    func testProductionAtomicWriterWritesUTF8AndFailureLeavesExistingBytes() throws {
        let entry = row(); hub.prepareHistoryExport(rowID: entry.id)
        // Reuse the production default writer, while still using the fake panel.
        let production = HubModel(store: settings, history: history, clipboard: { _ in }, recordings: recordings)
        hub.historyExportWriter = production.historyExportWriter
        let url = try XCTUnwrap(selectedURL)
        try Data("old export".utf8).write(to: url)
        hub.exportHistory(content: .original, format: .text)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(entry.raw))
        hub.prepareHistoryExport(rowID: entry.id)
        selectedURL = url.appendingPathComponent("impossible.txt") // parent is a regular file
        let before = try Data(contentsOf: url)
        hub.exportHistory(content: .result, format: .text)
        XCTAssertTrue(hub.historyExportMessage!.contains("Couldn’t export"))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedURL!.path))
    }

    func testLiveInjectedFilesRecordingDirectoryAndSidecarsAreGuardedBeforeFakeWriter() throws {
        let entry = row()
        let audio = recordings.directory.appendingPathComponent("live.wav")
        let sidecar = recordings.directory.appendingPathComponent("live.hyp.txt")
        try Data("audio sentinel".utf8).write(to: audio); try Data("sidecar sentinel".utf8).write(to: sidecar)
        let settingsBefore = try Data(contentsOf: settings.url), historyBefore = try Data(contentsOf: history.url)
        for url in [settings.url, history.url, recordings.directory, audio, sidecar,
                    recordings.directory.appendingPathComponent("future.txt"), recordings.directory.appendingPathComponent("nested/future.md")] {
            hub.prepareHistoryExport(rowID: entry.id); selectedURL = url
            hub.exportHistory(content: .result, format: .text)
            XCTAssertTrue(writes.isEmpty, url.path)
            XCTAssertTrue(hub.historyExportMessage!.contains("Choose a different file name or folder"), url.path)
        }
        XCTAssertEqual(try Data(contentsOf: settings.url), settingsBefore)
        XCTAssertEqual(try Data(contentsOf: history.url), historyBefore)
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("sidecar sentinel".utf8))
    }

    func testSymlinkFileAliasesParentAliasesAndOutwardRecordingAliasesAreGuarded() throws {
        let entry = row()
        let sidecar = recordings.directory.appendingPathComponent("live.hyp.txt")
        try Data("sidecar".utf8).write(to: sidecar)
        var targets: [URL] = []
        for (index, live) in [settings.url, history.url, sidecar].enumerated() {
            let alias = directory.appendingPathComponent("alias-\(index).txt")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live); targets.append(alias)
        }
        let parent = directory.appendingPathComponent("recording-parent-alias")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: recordings.directory)
        targets += [parent.appendingPathComponent("new.txt"), parent.appendingPathComponent("live.hyp.txt")]
        let parentOfStores = directory.appendingPathComponent("store-parent-alias")
        try FileManager.default.createSymbolicLink(at: parentOfStores, withDestinationURL: directory)
        targets += [parentOfStores.appendingPathComponent(settings.url.lastPathComponent), parentOfStores.appendingPathComponent(history.url.lastPathComponent)]
        let outside = directory.appendingPathComponent("outside-live-sidecar.txt")
        try Data("outside sidecar".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: recordings.directory.appendingPathComponent("outward.hyp.txt"), withDestinationURL: outside)
        targets.append(outside)
        for url in targets {
            hub.prepareHistoryExport(rowID: entry.id); selectedURL = url
            hub.exportHistory(content: .original, format: .text)
            XCTAssertTrue(writes.isEmpty, url.path)
            XCTAssertTrue(hub.historyExportMessage!.contains("Choose a different file name or folder"), url.path)
        }
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("sidecar".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside sidecar".utf8))
    }

    func testInjectedLiveURLsThatAreThemselvesSymlinksProtectTheirRealTargets() throws {
        let entry = row()
        let linkedSettings = directory.appendingPathComponent("linked-settings.txt")
        let linkedHistory = directory.appendingPathComponent("linked-history.txt")
        let linkedRecordings = directory.appendingPathComponent("linked-recordings")
        try FileManager.default.createSymbolicLink(at: linkedSettings, withDestinationURL: settings.url)
        try FileManager.default.createSymbolicLink(at: linkedHistory, withDestinationURL: history.url)
        try FileManager.default.createSymbolicLink(at: linkedRecordings, withDestinationURL: recordings.directory)
        let linkedHub = HubModel(store: SettingsStore(url: linkedSettings, credentials: testCredentialStore()), history: HistoryStore(url: linkedHistory),
                                 clipboard: { _ in }, recordings: RecordingStore(directory: linkedRecordings))
        linkedHub.historyExportWriter = hub.historyExportWriter
        for url in [settings.url, history.url, recordings.directory.appendingPathComponent("new.txt")] {
            linkedHub.prepareHistoryExport(rowID: entry.id)
            linkedHub.historyExportPanel = { _ in url }
            linkedHub.exportHistory(content: .original, format: .text)
            XCTAssertTrue(writes.isEmpty, url.path)
            XCTAssertTrue(linkedHub.historyExportMessage!.contains("Choose a different file name or folder"), linkedHub.historyExportMessage ?? "no status")
        }
        linkedHub.prepareHistoryExport(rowID: entry.id)
        linkedHub.historyExportPanel = { [unowned self] _ in self.selectedURL }
        linkedHub.exportHistory(content: .original, format: .text)
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(linkedHub.historyExportMessage!.contains("Exported"))
    }

    func testDanglingRelativeAliasesCannotOverwriteFutureHistoryOrSidecars() throws {
        let entry = row()
        let alias = directory.appendingPathComponent("dangling-history.txt")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: history.url.lastPathComponent)
        let futureSidecar = recordings.directory.appendingPathComponent("future.hyp.txt")
        let sidecarAlias = directory.appendingPathComponent("dangling-sidecar.txt")
        try FileManager.default.createSymbolicLink(atPath: sidecarAlias.path, withDestinationPath: "actual-recordings/future.hyp.txt")
        let outward = directory.appendingPathComponent("future-outward.txt")
        try FileManager.default.createSymbolicLink(atPath: recordings.directory.appendingPathComponent("outward.hyp.txt").path,
                                                 withDestinationPath: "../future-outward.txt")
        hub.prepareHistoryExport(rowID: entry.id)
        try FileManager.default.removeItem(at: history.url)
        for url in [alias, sidecarAlias, futureSidecar, outward] {
            selectedURL = url; hub.exportHistory(content: .original, format: .text)
            XCTAssertTrue(writes.isEmpty, url.path)
            XCTAssertTrue(hub.historyExportMessage!.contains("Choose a different file name or folder"), hub.historyExportMessage ?? "no status")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: futureSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outward.path))
    }

    func testOrdinarySiblingPathAndMissingRecordingFolderAreAllowed() throws {
        let entry = row()
        try FileManager.default.removeItem(at: recordings.directory)
        selectedURL = directory.appendingPathComponent("actual-recordings-other.txt")
        hub.prepareHistoryExport(rowID: entry.id); hub.exportHistory(content: .result, format: .text)
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(hub.historyExportMessage!.contains("Exported"))
    }

    func testConfigSecretsRetryProvenanceUsageAndErrorsAreExcludedButDictatedTextIsPreserved() throws {
        var metrics = PipelineMetrics(); metrics.cleanupModel = "SENTINEL_USAGE"; metrics.promptTokens = 123456789
        let configuration = HistoryRetryConfiguration(provider: "SENTINEL_PROVIDER", endpointOrigin: "SENTINEL_ORIGIN", model: "SENTINEL_MODEL",
                                                       style: "SENTINEL_STYLE", language: "SENTINEL_LANGUAGE", kind: .cleanup,
                                                       presetName: "SENTINEL_PRESET", vocabularySummary: "SENTINEL_VOCAB", rulesDigest: "SENTINEL_DIGEST", localOnly: false)
        let retry = HistoryRetryProvenance(date: Date(), configuration: configuration, usage: metrics)
        let entry = HistoryEntry(raw: "dictated credential: allowed-verbatim", cleaned: "saved result", appName: "Displayed app",
                                 metrics: metrics, operation: .init(origin: .selection, outcome: .completed), retries: [retry])
        XCTAssertTrue(history.append(entry)); hub.historyError = "SENTINEL_RAW_ERROR"
        let settingsBytes = try Data(contentsOf: settings.url), historyBytes = try Data(contentsOf: history.url)
        for format in TranscriptExport.Format.allCases {
            selectedURL = directory.appendingPathComponent("export.\(format.fileExtension)")
            hub.prepareHistoryExport(rowID: entry.id); hub.exportHistory(content: .original, format: format)
            XCTAssertTrue(output.contains(entry.raw)); XCTAssertTrue(output.contains("Displayed app"))
            XCTAssertFalse(output.contains("SENTINEL")); XCTAssertFalse(output.contains("123456789"))
            XCTAssertFalse(output.contains(entry.id.uuidString)); XCTAssertFalse(output.contains("selection"))
        }
        XCTAssertEqual(try Data(contentsOf: settings.url), settingsBytes); XCTAssertEqual(try Data(contentsOf: history.url), historyBytes)
    }

    func testReadableHistoryExportsDuringActualSettingsLoadSaveErrorsAndHistoryOff() throws {
        let entry = row()
        var config = settings.load(); config.historyEnabled = false; try settings.saveTestSettings(config); hub.refresh()
        XCTAssertFalse(hub.settings.historyEnabled)
        hub.prepareHistoryExport(rowID: entry.id); hub.exportHistory(content: .result, format: .text)
        XCTAssertEqual(writes.count, 1)
        try Data("{malformed settings".utf8).write(to: settings.url); hub.refresh()
        XCTAssertNotNil(hub.loadError)
        hub.prepareFilteredHistoryExport(""); hub.exportHistory(content: .original, format: .text)
        XCTAssertEqual(writes.count, 2); XCTAssertEqual(history.entries, [entry])
        XCTAssertEqual(try Data(contentsOf: settings.url), Data("{malformed settings".utf8))
        let blocked = directory.appendingPathComponent("blocked"); try Data("file".utf8).write(to: blocked)
        let bad = HubModel(store: SettingsStore(url: blocked.appendingPathComponent("settings.json"), credentials: testCredentialStore()), history: history,
                           clipboard: { _ in }, recordings: recordings)
        bad.settings.historyEnabled = false; bad.flushPendingSave(); XCTAssertNotNil(bad.saveError)
        bad.historyExportPanel = hub.historyExportPanel; bad.historyExportWriter = hub.historyExportWriter
        bad.prepareFilteredHistoryExport(""); bad.exportHistory(content: .original, format: .text)
        XCTAssertEqual(writes.count, 3); XCTAssertEqual(history.entries, [entry])
        XCTAssertEqual(try Data(contentsOf: blocked), Data("file".utf8))
    }
}


extension HubHistoryExportTests {
    @MainActor func testSavedOriginalHardlinkGuardPrecedesActualInjectedWriter() async throws {
        let rig = try SavedImportRig(), original = try await rig.run()
        let alias = rig.root.appendingPathComponent("original-hardlink.txt")
        XCTAssertEqual(link(original.path,alias.path),0)
        rig.hub.saveSavedAudioImportHistory(); await rig.saved.drain()
        let entry = try XCTUnwrap(rig.history.entries.first)
        rig.hub.historyExportPanel = { _ in alias }
        rig.hub.prepareHistoryExport(rowID:entry.id); rig.hub.exportHistory(content:.original,format:.text)
        XCTAssertTrue(rig.written.isEmpty)
        rig.hub.historyExportPanel = { _ in rig.root.appendingPathComponent("safe.txt") }
        rig.hub.exportHistory(content:.original,format:.text); XCTAssertEqual(rig.written.count,1)
        XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
}
