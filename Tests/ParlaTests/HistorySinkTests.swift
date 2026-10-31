import XCTest
import ParlaCore
@testable import Parla

final class HistorySinkTests: XCTestCase {
    private var directory: URL!
    private var settings: SettingsStore!
    private var history: HistoryStore!
    private var sink: HistoryPersistenceSink!
    private var failWrite = false

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parla-history-sink-2c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try recordWave4BFixture(directory, "created")
        settings = SettingsStore(url: directory.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        try settings.save(Settings())
        history = HistoryStore(url: directory.appendingPathComponent("history.json"), persistence: .init(writeAtomically: { [unowned self] data, url in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }))
        sink = HistoryPersistenceSink(history: history, settings: settings)
    }
    override func tearDownWithError() throws {
        sink = nil; history = nil; settings = nil
        try FileManager.default.removeItem(at: directory)
        try recordWave4BFixture(directory, "removed")
    }

    private func drive(_ effects: [DictationSession.Effect]) -> [HUDState] {
        sink.beginEvent()
        return effects.compactMap { effect in
            if case .hud(let state) = effect { return sink.feedback(state) }
            return sink.record(effect, metrics: { nil })
        }
    }

    private func ordinary(_ machine: DictationSession, _ s: Settings) throws -> DictationSession.Session {
        _ = machine.handle(.startDictation(settings: s, cleanupConfigured: false, live: false))
        _ = machine.handle(.recorderStarted(gen: machine.gen))
        _ = machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
        guard case .recording(let session) = machine.state else { throw TransformError(description: "No capture") }
        _ = machine.handle(.stopRequested)
        return session
    }

    func testOrdinaryProductionEffectKeepsMetricsAndSavedHUDWaitsForSuccessfulDiskWrite() throws {
        let machine = DictationSession(), session = try ordinary(machine, settings.load())
        let effects = machine.handle(.transcribed(session, raw: "original", probe: .init(focus: .none)))
        failWrite = true
        let feedback = drive(effects)
        XCTAssertFalse(feedback.contains(.savedToHistory)); XCTAssertTrue(feedback.contains { if case .error = $0 { return true }; return false })
        XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(history.pendingEntries.first?.raw, "original")
        let pending = try XCTUnwrap(history.pendingEntries.first)
        failWrite = false; XCTAssertTrue(history.retrySave(pending.id)); XCTAssertFalse(history.retrySave(pending.id))
        XCTAssertEqual(history.entries.count, 1)
        let usage = { var m = PipelineMetrics(); m.captureMs = 10; m.cleanupModel = "test"; return m }()
        sink.beginEvent(); XCTAssertNil(sink.feedback(.savedToHistory))
        XCTAssertEqual(sink.record(.appendHistory(raw: "second", cleaned: "result", appName: "Editor"), metrics: { usage }), .savedToHistory)
        XCTAssertEqual(history.entries.first?.metrics, usage)
    }

    func testAppendBeforeHUDNeverShowsStorageSuccessOnFailureAndPasteFeedbackStaysSeparate() {
        failWrite = true; sink.beginEvent()
        XCTAssertNil(sink.record(.appendHistory(raw: "raw", cleaned: "clean", appName: nil), metrics: { nil }))
        XCTAssertEqual(sink.feedback(.done), .done) // insertion succeeded even though history failed
        let feedback = sink.feedback(.cleanedInHistory)
        XCTAssertNotEqual(feedback, .cleanedInHistory)
        guard case .error = feedback else { return XCTFail("Expected explicit unsaved feedback") }
    }

    func testStaleCompletionSavesPendingWithoutOverwritingNewSessionHUD() throws {
        let machine = DictationSession(), old = try ordinary(machine, settings.load())
        _ = machine.handle(.startDictation(settings: settings.load(), cleanupConfigured: false, live: false))
        let landed = DictationSession.Landed(landing: .history, raw: "old source", insertText: "", bundleID: nil, appName: nil)
        failWrite = true
        let effects = machine.handle(.cleanReady(old, landed, text: "old result", failure: nil, focus: .none))
        XCTAssertTrue(drive(effects).isEmpty); XCTAssertEqual(history.pendingEntries.first?.cleaned, "old result")
        XCTAssertNotNil(history.lastError)
    }

    func testTransformProductionEffectKeepsSourceProvenanceAndOperationOwnedUsageOnFailureRetry() throws {
        var s = settings.load(); let preset = TransformPreset(name: "Translate", kind: .translation, targetLanguage: "Hindi")
        s.transformPresets = [preset]; s.selectedPresetID = preset.id
        let machine = DictationSession()
        let start = machine.handle(.startSavedPreset(settings: s, cleanupConfigured: true, selection: "original source", target: .init(focus: .editable)))
        let session = try XCTUnwrap(start.compactMap { if case .runSavedPreset(let s) = $0 { return s }; return nil }.first)
        var usage = PipelineMetrics(); usage.cleanupModel = "fake"; usage.promptTokens = 42; usage.completionTokens = 7
        let effects = machine.handle(.transformReady(session, text: "translated result", probe: .init(focus: .none, selectionStillMatches: false), metrics: usage))
        failWrite = true; let feedback = drive(effects)
        XCTAssertFalse(feedback.contains(.savedToHistory))
        let pending = try XCTUnwrap(history.pendingEntries.first)
        XCTAssertEqual(pending.raw, "original source"); XCTAssertEqual(pending.best, "translated result")
        XCTAssertEqual(pending.metrics, usage); XCTAssertEqual(pending.operation?.presetID, preset.id)
        XCTAssertEqual(pending.operation?.origin, .selection); XCTAssertEqual(pending.operation?.outcome, .parked)
        failWrite = false; XCTAssertTrue(history.retrySave(pending.id)); XCTAssertEqual(history.entries, [pending])
    }

    func testRejectedTransformInsertionParksProvenanceAndDoesNotCollectGlobalMetrics() throws {
        sink.beginEvent()
        var usage = PipelineMetrics(); usage.promptTokens = 9
        let operation = TransformProvenance(origin: .spoken, outcome: .completed)
        sink.record(.appendTransformHistory(raw: "source", cleaned: "result", appName: nil, operation: operation, metrics: usage),
                    insertionFailed: true, metrics: { XCTFail("Global metrics must not be consumed"); return nil })
        XCTAssertEqual(history.entries.first?.operation?.outcome, .parked); XCTAssertEqual(history.entries.first?.metrics, usage)
    }

    func testLatchedHistoryPermissionAndCurrentCountAreIndependentOfToggle() throws {
        let machine = DictationSession(), old = try ordinary(machine, settings.load())
        var current = settings.load(); current.historyEnabled = false; current.historyTextCount = 1; try settings.save(current)
        let effects = machine.handle(.transcribed(old, raw: "permitted old session", probe: .init(focus: .none)))
        XCTAssertTrue(drive(effects).contains(.savedToHistory)); XCTAssertEqual(history.entries.count, 1)
        let next = try ordinary(machine, current)
        let off = machine.handle(.transcribed(next, raw: "new session off", probe: .init(focus: .none)))
        _ = drive(off); XCTAssertEqual(history.entries.first?.raw, "permitted old session")
        let offOld = try ordinary(machine, current)
        current.historyEnabled = true; try settings.save(current)
        _ = drive(machine.handle(.transcribed(offOld, raw: "started off", probe: .init(focus: .none))))
        XCTAssertEqual(history.entries.first?.raw, "permitted old session")
        let on = try ordinary(machine, current)
        _ = drive(machine.handle(.transcribed(on, raw: "newly permitted", probe: .init(focus: .none))))
        XCTAssertEqual(history.entries.map(\.raw), ["newly permitted"])
    }

    func testSecureAndCancelledCapturesNeverReachHistorySink() throws {
        let machine = DictationSession(), session = try ordinary(machine, settings.load())
        let secure = machine.handle(.transcribed(session, raw: "private", probe: .init(focus: .secure)))
        _ = drive(secure); XCTAssertTrue(history.entries.isEmpty); XCTAssertTrue(history.pendingEntries.isEmpty)
        _ = machine.handle(.startDictation(settings: settings.load(), cleanupConfigured: false, live: false))
        _ = drive(machine.handle(.cancelRequested(silent: true)))
        XCTAssertTrue(history.entries.isEmpty); XCTAssertTrue(history.pendingEntries.isEmpty)
    }
    func testProviderResponseIsRequestedOnceAndSaveRetriesNeverReenterIt() async throws {
        final class Client: CleanupProviding {
            var calls = 0
            func clean(transcript: String, context: CleanupContext) async throws -> String {
                calls += 1; return "returned result"
            }
        }
        var s = settings.load()
        let preset = TransformPreset(name: "Test", instruction: "Rewrite")
        s.transformPresets = [preset]; s.selectedPresetID = preset.id
        let machine = DictationSession(), client = Client()
        let start = machine.handle(.startSavedPreset(settings: s, cleanupConfigured: true, selection: "source", target: .init(focus: .editable)))
        let session = try XCTUnwrap(start.compactMap { if case .runSavedPreset(let s) = $0 { return s }; return nil }.first)
        var factories = 0
        let result = try await session.transform(instruction: preset.intent) { _ in factories += 1; return client }
        failWrite = true
        _ = drive(machine.handle(.transformReady(session, text: result, probe: .init(focus: .none, selectionStillMatches: false))))
        let pending = try XCTUnwrap(history.pendingEntries.first)
        XCTAssertFalse(history.retrySave(pending.id)); failWrite = false
        XCTAssertTrue(history.retrySave(pending.id)); XCTAssertFalse(history.retrySave(pending.id))
        XCTAssertEqual(factories, 1); XCTAssertEqual(client.calls, 1); XCTAssertEqual(history.entries, [pending])
    }

    func testStaleOrdinaryCompletionCannotPublishNewHistoryFailureHUD() throws {
        let machine = DictationSession(), old = try ordinary(machine, settings.load())
        _ = machine.handle(.startDictation(settings: settings.load(), cleanupConfigured: false, live: false))
        let event = DictationSession.Event.transcribed(old, raw: "old result", probe: .init(focus: .none))
        let effects = machine.handle(event)
        sink.beginEvent(for: event, currentGeneration: machine.gen)
        failWrite = true
        let feedback = effects.compactMap { effect -> HUDState? in
            if case .hud(let state) = effect { return sink.feedback(state) }
            return sink.record(effect, metrics: { nil })
        }
        XCTAssertTrue(feedback.isEmpty); XCTAssertEqual(history.pendingEntries.first?.raw, "old result")
        XCTAssertNotNil(history.lastError)
    }

}


final class B21HistorySinkTests: XCTestCase {
    func testB21ExplicitEmptyMetricsNeverBorrowNewerGlobalUsage() throws {
        let d=try B21AppDocument(),s=try d.enable(),machine=DictationSession(diagnostics:nil)
        let start=machine.handle(.startDictation(settings:s,cleanupConfigured:true,live:false,cleanupFailoverGrant:d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)))
        let session=try XCTUnwrap(start.compactMap{if case .captureAccepted(let s)=$0{return s};return nil}.first)
        let sink=HistoryPersistenceSink(history:d.history,settings:d.store)
        let landed=DictationSession.Landed(landing:.history,raw:"old",insertText:"",bundleID:nil,appName:nil)
        sink.beginEvent(for:.cleanReady(session,landed,text:"old",failure:"failed",focus:.none,metrics:PipelineMetrics()),currentGeneration:session.gen+1)
        var borrowed=0
        _=sink.record(.appendHistory(raw:"old",cleaned:nil,appName:nil),metrics:{borrowed += 1;var m=PipelineMetrics();m.promptTokens=999;return m})
        XCTAssertEqual(borrowed,0);XCTAssertTrue(d.history.entries.first?.metrics?.isEmpty == true)
    }
}
