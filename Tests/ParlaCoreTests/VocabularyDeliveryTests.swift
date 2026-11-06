import XCTest
@testable import ParlaCore

final class VocabularyDeliveryTests: XCTestCase {
    private func start(_ machine: DictationSession, settings: Settings, cleanup: Bool) -> DictationSession.Session {
        _ = machine.handle(.startDictation(settings: settings, cleanupConfigured: cleanup, live: false))
        _ = machine.handle(.recorderStarted(gen: machine.gen))
        _ = machine.handle(.focusSampled(gen: machine.gen, focus: .editable))
        guard case .recording(let session) = machine.state else { fatalError("expected recording") }
        return session
    }

    private var settings: Settings {
        var s = Settings()
        s.replacements = [.init(source: "cat", replacement: "dog\nnext"), .init(source: "dog", replacement: "wolf")]
        s.snippets = ["shortcut": "cat\n$1\\literal"]
        return s
    }

    func testProviderOffProductionReducerUsesLocalRulesAndOriginalHistory() {
        let machine = DictationSession()
        let session = start(machine, settings: settings, cleanup: false)
        let effects = machine.handle(.transcribed(session, raw: "cat", probe: LandingProbe(
            focus: .editable, bundleID: "com.apple.TextEdit", appName: "Editor", deferInsertionUntilClean: true)))
        XCTAssertTrue(effects.contains(.insertText("dog\nnext", original: OriginalDictationContext(raw: "cat", generation: session.gen, operationID: session.operation.id))))
        XCTAssertTrue(effects.contains(.appendHistory(raw: "cat", cleaned: "dog\nnext", appName: "Editor")))
        XCTAssertFalse(effects.contains { if case .polish = $0 { return true }; return false })
    }

    func testProviderOffExactSnippetLockedAndDestinationFlatteningRetained() {
        for singleLine in [false, true] {
            let machine = DictationSession()
            let session = start(machine, settings: settings, cleanup: false)
            let effects = machine.handle(.transcribed(session, raw: "Shortcut!", probe: LandingProbe(
                focus: .unknown, bundleID: "com.apple.TextEdit", deferInsertionUntilClean: true, singleLine: singleLine)))
            XCTAssertTrue(effects.contains(.insertText(singleLine ? "cat $1\\literal" : "cat\n$1\\literal",
                original: OriginalDictationContext(raw: "Shortcut!", generation: session.gen, operationID: session.operation.id))))
        }
        let machine = DictationSession()
        let session = start(machine, settings: settings, cleanup: false)
        XCTAssertTrue(machine.handle(.transcribed(session, raw: "cat", probe: LandingProbe(
            focus: .editable, bundleID: "com.apple.Terminal"))).contains(.insertText("dog next", original: OriginalDictationContext(raw: "cat", generation: session.gen, operationID: session.operation.id))))
    }

    func testProviderFailureProductionHandoffKeepsLocalResultInHistoryAndSingleLineField() async {
        let machine = DictationSession()
        let s = settings
        let session = start(machine, settings: s, cleanup: true)
        let effects = machine.handle(.transcribed(session, raw: "cat", probe: LandingProbe(
            focus: .unknown, bundleID: "com.google.Chrome", deferInsertionUntilClean: true, singleLine: true)))
        guard case .polish(_, let landed)? = effects.first(where: { if case .polish = $0 { return true }; return false }) else {
            return XCTFail("production handoff must request polish")
        }
        let pipeline = Pipeline(transcribe: { _, _ in nil }, cleanup: { _, _ in throw URLError(.timedOut) },
                                settings: { s }, frontBundleID: { nil })
        let result = await pipeline.clean(transcript: landed.raw)
        let output = machine.handle(.cleanReady(session, landed, text: result.text, failure: result.failure, focus: .unknown))
        XCTAssertTrue(output.contains(.insertText("dog next", original: OriginalDictationContext(raw: "cat", generation: session.gen, operationID: session.operation.id))))
        XCTAssertTrue(output.contains(.appendHistory(raw: "cat", cleaned: "dog\nnext", appName: nil)))
        XCTAssertTrue(output.contains(.hud(.rawFallback("cleanup timed out"))))
    }

    func testCommandSelectionOutputDoesNotApplyDictationReplacements() {
        let machine = DictationSession()
        _ = machine.handle(.startCommand(settings: settings, cleanupConfigured: true, focus: .editable, selection: "selected cat"))
        _ = machine.handle(.recorderStarted(gen: machine.gen))
        guard case .recording(let session) = machine.state else { return XCTFail("expected command") }
        let effects = machine.handle(.transformReady(session, text: "cat", probe: TransformProbe(
            focus: .editable, selectionStillMatches: true, bundleID: "com.apple.TextEdit", destinationStillMatches: true)))
        XCTAssertTrue(effects.contains(.insertText("cat", historyEnabled: true)))
        XCTAssertFalse(effects.contains(.insertText("dog\nnext")))
    }

    func testSecureAndNewGenerationRemainProtectedWithLocalOutput() {
        let machine = DictationSession()
        let session = start(machine, settings: settings, cleanup: false)
        let effects = machine.handle(.transcribed(session, raw: "cat", probe: LandingProbe(focus: .secure)))
        XCTAssertFalse(effects.contains { if case .insertText = $0 { return true }; if case .appendHistory = $0 { return true }; return false })
        let old = start(machine, settings: settings, cleanup: true)
        let pending = machine.handle(.transcribed(old, raw: "cat", probe: LandingProbe(focus: .editable, deferInsertionUntilClean: true)))
        guard case .polish(_, let landed)? = pending.first(where: { if case .polish = $0 { return true }; return false }) else {
            return XCTFail("missing pending handoff")
        }
        _ = start(machine, settings: settings, cleanup: false)
        let stale = machine.handle(.cleanReady(old, landed, text: "dog\nnext", failure: "cleanup failed", focus: .editable))
        XCTAssertFalse(stale.contains { if case .insertText = $0 { return true }; if case .hud = $0 { return true }; return false })
        XCTAssertTrue(stale.contains(.appendHistory(raw: "cat", cleaned: "dog\nnext", appName: nil)))
    }
}
