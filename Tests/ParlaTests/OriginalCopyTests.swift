import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

private final class OriginalCopyRig {
    final class Timer {
        let delay: TimeInterval
        let fire: () -> Void
        var canceled = false
        init(_ delay: TimeInterval, _ fire: @escaping () -> Void) { self.delay = delay; self.fire = fire }
    }
    var settings: Settings? = {
        var s = Settings(); s.keepLastOriginalEnabled = true; s.historyEnabled = false
        return s
    }()
    var loadConfiguration: (() -> Settings?)?
    let machine = DictationSession(diagnostics: nil)
    var time: TimeInterval = 100
    var security: OriginalCopySecurity = .safe
    var securityReads = 0
    var onSecurity: (() -> Void)?
    var timers: [Timer] = []
    var copies: [String] = []
    var onCopy: ((String) -> Void)?
    var posted = true
    var dispatch = true
    var beforeDispatch: (() -> Void)?
    var afterDispatch: (() -> Void)?
    var texts: [String] = []
    var corrections: [String] = []
    var effects: [DictationSession.Effect] = []
    var accepted: [DictationSession.Session] = []
    var statusBeforeCapture: [OriginalCopyStatus] = []
    var results: [DictationFinalResult] = []
    var onEffect: ((DictationSession.Effect) -> Void)?
    var history: [(String, String?)] = []
    lazy var controller = OriginalCopyController(configuration: { [unowned self] in
        if let loadConfiguration { return loadConfiguration() }; return settings
    },
        generation: { [unowned self] in machine.gen }, now: { [unowned self] in time },
        schedule: { [unowned self] delay, fire in
            let timer = Timer(delay, fire); timers.append(timer)
            return { timer.canceled = true }
        }, security: { [unowned self] in securityReads += 1; onSecurity?(); return security },
        copy: { [unowned self] in copies.append($0); onCopy?($0) })
    lazy var executor = DictationInsertionExecutor(originals: controller, post: { [unowned self] text, _, willPost in
        texts.append(text); beforeDispatch?()
        if dispatch { willPost() }
        afterDispatch?()
        return posted
    }, didPost: { [unowned self] in corrections.append($0) })

    func send(_ event: DictationSession.Event) {
        controller.observe(event)
        machine.send(event) { effect in
            controller.observe(effect)
            onEffect?(effect)
            effects.append(effect)
            switch effect {
            case .captureAccepted(let s): accepted.append(s)
            case .applyPreferencesAndStartCapture: statusBeforeCapture.append(controller.refresh())
            case .insertText(let text, _, let context):
                _ = executor.insert(text, original: context, operation: machine.effectOperation)
            case .finalResult(_, let result): results.append(result)
            case .appendHistory(let raw, let cleaned, _): history.append((raw, cleaned))
            default: break
            }
        }
    }
    @discardableResult func start(cleanup: Bool = false, live: Bool = false) -> DictationSession.Session {
        send(.startDictation(settings: settings ?? Settings(), cleanupConfigured: cleanup, live: live))
        send(.recorderStarted(gen: machine.gen))
        send(.focusSampled(gen: machine.gen, focus: .editable))
        let session = accepted.last!
        send(.stopRequested)
        return session
    }
    func transcribe(_ s: DictationSession.Session, _ raw: String = "original", singleLine: Bool = false) {
        send(.transcribed(s, raw: raw, probe: LandingProbe(focus: .editable, bundleID: "com.apple.TextEdit",
            deferInsertionUntilClean: true, singleLine: singleLine)))
    }
    func land(_ raw: String = "original") { transcribe(start(), raw) }
    func pending(_ s: DictationSession.Session, _ raw: String) -> DictationSession.Landed {
        transcribe(s, raw, singleLine: true)
        return effects.compactMap { if case .polish(_, let landed) = $0 { return landed }; return nil }.last!
    }
    func copy() -> Bool {
        guard let token = controller.refresh().token else { return false }
        return controller.copyOriginal(token: token)
    }
}

final class OriginalCopyTests: XCTestCase {
    @MainActor func testFlagDefaultMissingNullRoundTripAndMalformedFailClosed() throws {
        XCTAssertFalse(Settings().keepLastOriginalEnabled)
        for json in ["{}", "{\"keepLastOriginalEnabled\":null}"] {
            XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).keepLastOriginalEnabled)
        }
        var settings = Settings(); settings.keepLastOriginalEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).keepLastOriginalEnabled)
        for value in ["1", "\"true\"", "[]", "{}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data("{\"keepLastOriginalEnabled\":\(value)}".utf8)))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-original-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: root) }
        let backend = FakeCredentialBackend()
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        try Data("{\"keepLastOriginalEnabled\":\"yes\"}".utf8).write(to: store.url)
        XCTAssertFalse(store.load().keepLastOriginalEnabled); XCTAssertNotNil(store.lastError)
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds, 0)
    }

    @MainActor func testDisabledProductionPathAddsNoRetentionSecurityTimerOrCopy() {
        let rig = OriginalCopyRig(); rig.settings?.keepLastOriginalEnabled = false
        rig.land("private canary")
        XCTAssertEqual(rig.texts, ["private canary"]); XCTAssertEqual(rig.corrections, rig.texts)
        XCTAssertNil(rig.controller.refresh().token); XCTAssertFalse(rig.copy())
        XCTAssertEqual(rig.securityReads, 0); XCTAssertTrue(rig.timers.isEmpty); XCTAssertTrue(rig.copies.isEmpty)
        XCTAssertTrue(rig.effects.allSatisfy { if case .insertText(_, _, let context) = $0 { return context == nil }; return true })
    }

    @MainActor func testDirectReducerCopiesExactASRInsteadOfLocalRulesSnippetOrShapeWithHistoryOff() {
        for (raw, expected) in [("cat\nagain", "dog again"), ("Shortcut!", "locked value")] {
            let rig = OriginalCopyRig()
            rig.settings?.replacements = [.init(source: "cat", replacement: "dog")]
            rig.settings?.snippets = ["shortcut": "locked\nvalue"]
            rig.transcribe(rig.start(), raw, singleLine: true)
            XCTAssertEqual(rig.texts, [expected]); XCTAssertEqual(rig.corrections, [expected])
            XCTAssertTrue(rig.history.isEmpty); XCTAssertEqual(rig.results, [.text(expected, .final)])
            XCTAssertEqual(rig.controller.status.message, "Original available briefly — paste posted, acceptance unverified")
            XCTAssertTrue(rig.copies.isEmpty); XCTAssertTrue(rig.copy()); XCTAssertEqual(rig.copies, [raw])
            XCTAssertFalse(rig.controller.status.message.contains(raw))
        }
    }

    @MainActor func testDeferredProductionReducerAndRealPipelineFallbackPreserveOriginalAndHistory() async {
        for failure in [false, true] {
            let rig = OriginalCopyRig(); rig.settings?.historyEnabled = true
            rig.settings?.replacements = [.init(source: "cat", replacement: "dog\nnext")]
            let s = rig.start(cleanup: true)
            let landed = rig.pending(s, "cat")
            XCTAssertTrue(rig.texts.isEmpty); XCTAssertTrue(rig.timers.isEmpty)
            let settings = rig.settings!
            let pipeline = Pipeline(transcribe: { _, _ in nil }, cleanup: { _, _ in
                if failure { throw URLError(.timedOut) }; return "clean\nresult"
            }, settings: { settings }, frontBundleID: { nil })
            let output = await pipeline.clean(transcript: landed.raw)
            rig.send(.cleanReady(s, landed, text: output.text, failure: output.failure, focus: .unknown))
            XCTAssertEqual(rig.texts, [failure ? "dog next" : "clean result"])
            XCTAssertEqual(rig.corrections, rig.texts); XCTAssertEqual(rig.history.count, 1)
            XCTAssertEqual(rig.history.first?.0, "cat"); XCTAssertEqual(rig.history.first?.1, output.text)
            XCTAssertEqual(rig.results, [.text(rig.texts[0], failure ? .localFallback : .final)])
            XCTAssertTrue(rig.copy()); XCTAssertEqual(rig.copies, ["cat"])
        }
    }

    @MainActor func testRawModeKeepsASRAndRetainsExistingRawDeliveryContract() {
        let rig = OriginalCopyRig(); rig.settings?.outputMode = .raw
        rig.settings?.replacements = [.init(source: "cat", replacement: "dog")]
        let s = rig.start(); let landed = rig.pending(s, "cat\nnext")
        rig.send(.cleanReady(s, landed, text: landed.raw, failure: nil, focus: .editable))
        XCTAssertEqual(rig.texts, ["cat next"]); XCTAssertTrue(rig.copy()); XCTAssertEqual(rig.copies, ["cat\nnext"])
        guard case .insertText(_, let history, let original)? = rig.effects.first(where: { if case .insertText = $0 { return true }; return false }) else { return XCTFail() }
        XCTAssertEqual(history, false); XCTAssertEqual(original?.raw, "cat\nnext")
    }

    @MainActor func testFailedUnobservedRevokedOrNoCaptureAuthorityCannotPublish() {
        for kind in 0..<5 {
            let rig = OriginalCopyRig(); let s = rig.start()
            if kind == 0 { rig.posted = false }
            if kind == 1 { rig.dispatch = false }
            if kind == 2 { s.operation.revoke() }
            if kind == 3 { rig.controller.clear() }
            if kind == 4 { rig.security = .secure }
            rig.transcribe(s)
            XCTAssertNil(rig.controller.refresh().token); XCTAssertTrue(rig.copies.isEmpty)
            XCTAssertTrue(rig.timers.isEmpty)
            XCTAssertEqual(rig.corrections.count, kind == 0 || kind == 2 ? 0 : 1)
        }
    }

    @MainActor func testTTLStartsAtDispatchAndReadsRefreshCopiesNeverExtendIt() throws {
        let rig = OriginalCopyRig()
        rig.beforeDispatch = { rig.time = 120 }
        rig.afterDispatch = { rig.time = 125 }
        let s = rig.start(); rig.transcribe(s)
        XCTAssertEqual(rig.timers.first?.delay, 25)
        let token = try XCTUnwrap(rig.controller.refresh().token)
        s.operation.finish() // finished is deliberately different from revoked
        rig.time = 149.999
        XCTAssertTrue(rig.controller.copyOriginal(token: token)); XCTAssertTrue(rig.controller.copyOriginal(token: token))
        XCTAssertEqual(rig.copies, ["original", "original"]); XCTAssertEqual(rig.timers.count, 1)
        rig.time = 150
        XCTAssertFalse(rig.controller.copyOriginal(token: token)); XCTAssertNil(rig.controller.refresh().token)
        XCTAssertTrue(rig.timers[0].canceled)
        rig.time = 100; rig.timers[0].fire()
        XCTAssertNil(rig.controller.refresh().token)
    }

    @MainActor func testUTF8CapIncludingEmojiRefusesOverflowWithoutChangingPaste() {
        for raw in [String(repeating: "a", count: 65_536), String(repeating: "😀", count: 16_384),
                    String(repeating: "😀", count: 16_384) + "a"] {
            let rig = OriginalCopyRig(); rig.land(raw)
            XCTAssertEqual(rig.texts, [raw]); XCTAssertEqual(rig.corrections, [raw])
            XCTAssertEqual(rig.copy(), raw.utf8.count <= 65_536)
            XCTAssertEqual(rig.copies, raw.utf8.count <= 65_536 ? [raw] : [])
            XCTAssertEqual(rig.timers.count, raw.utf8.count <= 65_536 ? 1 : 0)
        }
    }

    @MainActor func testOptInIsLatchedAndStaleRawKeepsPastePolicyWithoutNewAuthority() {
        let rig = OriginalCopyRig(); rig.settings?.keepLastOriginalEnabled = false
        let beforeOptIn = rig.start(); rig.settings?.keepLastOriginalEnabled = true
        rig.transcribe(beforeOptIn, "before opt-in")
        XCTAssertEqual(rig.texts, ["before opt-in"]); XCTAssertFalse(rig.copy())
        let old = rig.start(); _ = rig.start()
        rig.transcribe(old, "deliberately late raw")
        XCTAssertEqual(rig.texts.last, "deliberately late raw"); XCTAssertFalse(rig.copy())
        XCTAssertEqual(rig.securityReads, 0)
    }

    @MainActor func testNewCaptureInvalidatesBeforeCaptureEffectsAndStaleTimersCannotClearNewOwner() throws {
        let rig = OriginalCopyRig(); rig.land("first")
        let first = try XCTUnwrap(rig.controller.status.token); let timer = rig.timers[0]
        let s = rig.start()
        XCTAssertNil(rig.statusBeforeCapture.last?.token); XCTAssertTrue(timer.canceled)
        XCTAssertFalse(rig.controller.copyOriginal(token: first))
        rig.transcribe(s, "second"); let second = try XCTUnwrap(rig.controller.status.token)
        timer.fire(); XCTAssertEqual(rig.controller.refresh().token, second)
        rig.time += 30; rig.timers.last?.fire(); XCTAssertNil(rig.controller.status.token)
    }

    @MainActor func testNestedDispatchCallbacksCannotReviveAfterCaptureDisableClearRevocationOrExpiry() {
        for kind in 0..<6 {
            let rig = OriginalCopyRig(); let s = rig.start()
            rig.afterDispatch = {
                switch kind {
                case 0: _ = rig.start()
                case 1: rig.settings?.keepLastOriginalEnabled = false; rig.controller.refresh(); rig.settings?.keepLastOriginalEnabled = true
                case 2: rig.controller.clear()
                case 3: s.operation.revoke()
                case 4: _ = rig.executor.insert("nested stored", original: nil, operation: nil)
                default: rig.time += 30
                }
            }
            // Avoid recursively invoking the injected hook for nested insertion.
            let action = rig.afterDispatch
            rig.afterDispatch = { rig.afterDispatch = nil; action?() }
            rig.transcribe(s)
            XCTAssertNil(rig.controller.refresh().token); XCTAssertTrue(rig.copies.isEmpty)
        }
    }

    @MainActor func testRevokeConfigInvalidSecureAndStaleUIAreRecheckedImmediatelyBeforeExplicitCopy() throws {
        for kind in 0..<7 {
            let rig = OriginalCopyRig(); let s = rig.start(); rig.transcribe(s)
            let token = try XCTUnwrap(rig.controller.status.token)
            switch kind {
            case 0: s.operation.revoke()
            case 1: rig.settings = nil
            case 2: rig.settings?.keepLastOriginalEnabled = false
            case 3: rig.security = .secure
            case 4: rig.security = .unavailable
            case 5: rig.controller.clear()
            default: rig.onSecurity = { rig.controller.clear() }
            }
            XCTAssertFalse(rig.controller.copyOriginal(token: token)); XCTAssertTrue(rig.copies.isEmpty)
            XCTAssertNil(rig.controller.refresh().token)
        }
    }

    @MainActor func testNewExcludedOrFailedInsertionEditsSecureRefusalAndQuitStyleClearInvalidate() {
        for effect in [DictationSession.Effect.eraseTypedIfOurs(expect: "x"),
                       .replaceTailIfOurs(expect: "x", erase: 1, append: "y", verifiedHUD: .done, unverifiedHUD: .done),
                       .secureRefusal("secure")] {
            let rig = OriginalCopyRig(); rig.land(); rig.controller.observe(effect)
            XCTAssertFalse(rig.copy())
        }
        let rig = OriginalCopyRig(); rig.land()
        rig.posted = false; _ = rig.executor.insertStored("stored text")
        XCTAssertFalse(rig.copy()); XCTAssertEqual(rig.texts, ["original", "stored text"])
        rig.posted = true; rig.land(); rig.controller.clear() // same quit/restart hook, no native lifecycle
        rig.timers.forEach { $0.fire() }; XCTAssertFalse(rig.copy())
    }

    @MainActor func testTransformResultOnlySelectedPresetAndLegacyLiveExclusionsUseRealReducer() {
        let live = OriginalCopyRig(); let s = live.start(live: true); live.transcribe(s)
        XCTAssertEqual(live.texts, ["original"]); XCTAssertFalse(live.copy()); XCTAssertEqual(live.securityReads, 0)

        let transform = OriginalCopyRig()
        transform.send(.startCommand(settings: transform.settings!, cleanupConfigured: true, focus: .editable, selection: "selection"))
        transform.send(.recorderStarted(gen: transform.machine.gen)); transform.send(.stopRequested)
        let command = transform.accepted.last!
        transform.send(.transformReady(command, text: "transformed", probe: TransformProbe(focus: .editable,
            selectionStillMatches: true, destinationStillMatches: true)))
        XCTAssertEqual(transform.texts, ["transformed"]); XCTAssertFalse(transform.copy()); XCTAssertEqual(transform.securityReads, 0)

        let automation = OriginalCopyRig()
        automation.send(.startAutomation(settings: automation.settings!, cleanupConfigured: false))
        automation.send(.recorderStarted(gen: automation.machine.gen)); automation.send(.stopRequested)
        let resultSession = automation.accepted.last!; let landed = automation.pending(resultSession, "result original")
        automation.send(.cleanReady(resultSession, landed, text: "result", failure: nil, focus: .unknown))
        XCTAssertEqual(automation.results, [.text("result", .final)])
        XCTAssertTrue(automation.texts.isEmpty); XCTAssertFalse(automation.copy()); XCTAssertEqual(automation.securityReads, 0)

        let preset = TransformPreset(name: "Short", instruction: "Shorten")
        for selection in [false, true] {
            let rig = OriginalCopyRig(); rig.settings?.outputMode = .selectedPreset
            rig.settings?.transformPresets = [preset]; rig.settings?.selectedPresetID = preset.id
            if selection {
                rig.send(.startSavedPreset(settings: rig.settings!, cleanupConfigured: true, selection: "selected",
                    target: LandingProbe(focus: .editable)))
                let selected = rig.accepted.last!
                rig.send(.transformReady(selected, text: "short", probe: TransformProbe(focus: .editable,
                    selectionStillMatches: true, destinationStillMatches: true)))
            } else {
                let s = rig.start(cleanup: true); let landed = rig.pending(s, "dictated original")
                rig.send(.cleanReady(s, landed, text: "short", failure: nil, focus: .editable))
            }
            XCTAssertEqual(rig.texts, ["short"]); XCTAssertFalse(rig.copy()); XCTAssertEqual(rig.securityReads, 0)
        }
    }

    @MainActor func testScalarMenuCallbackUsesFreshTokenAndNoShortcutTooltipOrAutomaticCopy() throws {
        let rig = OriginalCopyRig(); rig.land("menu secret canary")
        let actions = OriginalCopyMenuActions(controller: rig.controller); let menu = NSMenu()
        AppDelegate.addOriginalCopy(to: menu, status: rig.controller.refresh(), target: actions)
        let item = try XCTUnwrap(menu.items.first(where: { $0.title == "Copy Original" }))
        XCTAssertTrue(item.isEnabled); XCTAssertEqual(item.keyEquivalent, ""); XCTAssertNil(item.toolTip)
        XCTAssertEqual(item.action, #selector(OriginalCopyMenuActions.copyOriginal(_:)))
        XCTAssertTrue(menu.items.allSatisfy { !$0.title.contains("secret canary") && $0.toolTip == nil })
        XCTAssertTrue(rig.copies.isEmpty)
        actions.copyOriginal(item); XCTAssertEqual(rig.copies, ["menu secret canary"])
        let textCount = rig.texts.count, correctionCount = rig.corrections.count, effectCount = rig.effects.count
        rig.controller.clear(); actions.copyOriginal(item)
        XCTAssertEqual(rig.copies.count, 1); XCTAssertEqual(rig.texts.count, textCount)
        XCTAssertEqual(rig.corrections.count, correctionCount); XCTAssertEqual(rig.effects.count, effectCount)
        menu.removeAllItems(); AppDelegate.addOriginalCopy(to: menu, status: rig.controller.refresh(), target: actions)
        XCTAssertFalse(menu.items[1].isEnabled); XCTAssertNil(menu.items[1].action)
    }
}

private final class OriginalHubFixture {
    let root: URL
    let store: SettingsStore
    let backend = FakeCredentialBackend()
    let hub: HubModel
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-original-hub-\(UUID())")
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        try store.save(Settings())
        hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")),
            clipboard: { _ in XCTFail("Original copy must use its own validated action") },
            recordings: RecordingStore(directory: root.appendingPathComponent("audio"), keepAll: false),
            shortcutLabels: ShortcutLabels(center: NotificationCenter(), snapshot: { ShortcutDisplayFormatter { _ in nil } }),
            diagnostics: DiagnosticStore())
        hub.settings = store.load()
        hub.flushPendingSave()
    }
    func close() throws { hub.flushPendingSave(); try FileManager.default.removeItem(at: root) }
}

extension OriginalCopyTests {
    @MainActor func testActualHubSaveOriginalOnlyCoalescedRevertMixedFlagsNetZeroAndGenuineGeneralChangeArePassive() throws {
        let fixture = try OriginalHubFixture(); defer { try! fixture.close() }
        let hub = fixture.hub
        let rig = OriginalCopyRig()
        rig.loadConfiguration = { let value = fixture.store.load(); return fixture.store.lastError == nil ? value : nil }
        hub.bindOriginalCopy(rig.controller)
        var general = 0, passive = 0
        hub.onSaved = { general += 1 }
        hub.onMouseBindingSaved = { passive += 1 }

        hub.settings.keepLastOriginalEnabled = true; hub.flushPendingSave()
        XCTAssertTrue(fixture.store.load().keepLastOriginalEnabled)
        XCTAssertEqual(passive, 1); XCTAssertEqual(general, 0)
        // Opt-in toggled away and back before a single actual save.
        hub.settings.keepLastOriginalEnabled = false; hub.settings.keepLastOriginalEnabled = true
        hub.flushPendingSave()
        XCTAssertEqual(passive, 2); XCTAssertEqual(general, 0)
        // Both passive preferences change together.
        hub.settings.mouseBinding = MouseButtonBinding(buttonNumber: 2)
        hub.settings.keepLastOriginalEnabled = false; hub.flushPendingSave()
        XCTAssertEqual(passive, 3); XCTAssertEqual(general, 0)
        XCTAssertEqual(fixture.store.load().mouseBinding?.buttonNumber, 2)
        XCTAssertFalse(fixture.store.load().keepLastOriginalEnabled)
        // Coalesced revert of both, plus a general preference that nets to zero.
        hub.settings.keepLastOriginalEnabled = true; hub.settings.keepLastOriginalEnabled = false
        hub.settings.mouseBinding = nil; hub.settings.mouseBinding = MouseButtonBinding(buttonNumber: 2)
        hub.settings.showHudAlways.toggle(); hub.settings.showHudAlways.toggle()
        hub.flushPendingSave()
        XCTAssertEqual(passive, 4); XCTAssertEqual(general, 0)
        // Genuine general change survives passive coalescing and invokes setup exactly once.
        hub.settings.keepLastOriginalEnabled = true; hub.settings.keepLastOriginalEnabled = false
        hub.settings.showHudAlways.toggle(); hub.flushPendingSave()
        XCTAssertEqual(passive, 4); XCTAssertEqual(general, 1)
        XCTAssertFalse(fixture.store.load().showHudAlways)
        XCTAssertEqual(rig.securityReads, 0); XCTAssertTrue(rig.timers.isEmpty); XCTAssertTrue(rig.copies.isEmpty)
        XCTAssertEqual(fixture.backend.reads + fixture.backend.statuses + fixture.backend.adds
            + fixture.backend.updates + fixture.backend.deletes, 0)
        XCTAssertTrue(rig.effects.isEmpty); XCTAssertNil(hub.saveError)
    }

    @MainActor func testActualHubCopyAfterPassiveRefreshAndDisableDraftInvalidatesStaleStatus() throws {
        let fixture = try OriginalHubFixture(); defer { try! fixture.close() }
        let hub = fixture.hub; let rig = OriginalCopyRig()
        rig.loadConfiguration = { let value = fixture.store.load(); return fixture.store.lastError == nil ? value : nil }
        hub.bindOriginalCopy(rig.controller)
        hub.settings.keepLastOriginalEnabled = true; hub.flushPendingSave()
        rig.land("Hub original")
        XCTAssertNotNil(hub.originalCopyStatus.token); XCTAssertTrue(rig.copies.isEmpty)
        // Hub activation/refresh itself is passive with respect to Original: no
        // target identity is needed for copying. All focus evidence is injected.
        let reads = rig.securityReads
        hub.refreshOriginalCopy(); XCTAssertEqual(rig.securityReads, reads)
        hub.copyLastOriginal(); XCTAssertEqual(rig.copies, ["Hub original"])
        XCTAssertEqual(rig.texts, ["Hub original"]); XCTAssertTrue(rig.history.isEmpty)
        hub.settings.keepLastOriginalEnabled = false // clears before debounce fires
        XCTAssertNil(hub.originalCopyStatus.token)
        hub.copyLastOriginal(); XCTAssertEqual(rig.copies.count, 1)
        hub.settings.keepLastOriginalEnabled = true; hub.flushPendingSave()
        XCTAssertNil(hub.originalCopyStatus.token, "turning back on cannot revive")
        rig.land("second")
        try Data("{\"keepLastOriginalEnabled\":\"malformed\"}".utf8).write(to: fixture.store.url)
        hub.copyLastOriginal()
        XCTAssertEqual(rig.copies.count, 1); XCTAssertNil(hub.originalCopyStatus.token)
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertEqual(fixture.backend.reads + fixture.backend.statuses, 0)
    }

    @MainActor func testActualHubMicrophoneTestEntryClearsWithoutRecorderOrModelSetup() throws {
        let fixture = try OriginalHubFixture(); defer { try! fixture.close() }
        let rig = OriginalCopyRig(); fixture.hub.bindOriginalCopy(rig.controller)
        rig.land(); fixture.hub.startMicrophoneTest() // default controller has no capture adapter
        XCTAssertFalse(rig.copy()); XCTAssertNil(fixture.hub.originalCopyStatus.token)
        XCTAssertFalse(fixture.hub.microphoneTest.ownsSession)
        XCTAssertEqual(fixture.backend.reads + fixture.backend.statuses, 0)
    }

    @MainActor func testInvocationTryoutShortcutSecureAndDiscardBoundariesClearWithoutSetup() throws {
        let rig = OriginalCopyRig()
        let runtime = AutomationRuntime(clock: OriginalAutomationClock(), enabled: { false })
        var entries = 0
        let host = DictationInvocationHost(machine: rig.machine, broker: runtime.broker, results: runtime.results,
            settings: { rig.settings }, configured: { _ in false }, capabilities: { _ in nil },
            secure: { false }, keyboardAllowed: { true }, automationAllowed: { false },
            explicitEntry: { entries += 1 }, send: { rig.send($0) }, invalidateOriginal: { rig.controller.clear() })
        rig.land(); XCTAssertTrue(host.beginTryout()); XCTAssertFalse(rig.copy()); host.endTryout()
        rig.land(); let lease = try XCTUnwrap(host.beginShortcutRecording()); XCTAssertFalse(rig.copy())
        host.endShortcutRecording(lease)
        rig.land(); host.secureRefusal {}; XCTAssertFalse(rig.copy())
        rig.land(); host.discarded(rig.accepted.last!.operation.id); XCTAssertFalse(rig.copy())
        XCTAssertEqual(entries, 0, "these passive clearing hooks do not enter setup")
    }
}

@MainActor private final class OriginalAutomationClock: AutomationClock {
    var now: TimeInterval = 100
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void { {} }
}

extension OriginalCopyTests {
    @MainActor func testKnownSecureProbeInvalidatesEvenWhenItsCompletionIsRevoked() {
        let rig = OriginalCopyRig(); let old = rig.start(); old.operation.revoke()
        rig.land()
        rig.send(.transcribed(old, raw: nil, probe: LandingProbe(focus: .secure)))
        XCTAssertFalse(rig.copy())
    }
    @MainActor func testStoredProductionExecutorDoesNotArmCorrectionOrRetainEvenOnSuccessfulPosting() {
        let rig = OriginalCopyRig(); rig.land()
        let reads = rig.securityReads, timers = rig.timers.count
        XCTAssertTrue(rig.executor.insertStored("stored"))
        XCTAssertEqual(rig.texts, ["original", "stored"])
        XCTAssertEqual(rig.corrections, ["original"])
        XCTAssertEqual(rig.securityReads, reads); XCTAssertEqual(rig.timers.count, timers)
        XCTAssertFalse(rig.copy()); XCTAssertTrue(rig.copies.isEmpty)
    }
}

extension OriginalCopyTests {
    @MainActor func testDeferredExactSnippetUsesOriginalWhileProviderAndHistoryStayUnused() async {
        let rig = OriginalCopyRig(); rig.settings?.snippets = ["shortcut": "locked\nvalue"]
        let s = rig.start(cleanup: true); let landed = rig.pending(s, "Shortcut!")
        let settings = rig.settings!
        let pipeline = Pipeline(transcribe: { _, _ in nil }, cleanup: { _, _ in
            XCTFail("exact snippet must bypass provider"); return "unused"
        }, settings: { settings }, frontBundleID: { nil })
        let output = await pipeline.clean(transcript: landed.raw)
        rig.send(.cleanReady(s, landed, text: output.text, failure: output.failure, focus: .editable))
        XCTAssertEqual(rig.texts, ["locked value"]); XCTAssertTrue(rig.history.isEmpty)
        XCTAssertTrue(rig.copy()); XCTAssertEqual(rig.copies, ["Shortcut!"])
    }

    @MainActor func testPhysicalKeyboardAndMouseShareAcceptedCaptureAndActualInsertionExecutor() {
        for mouse in [false, true] {
            let rig = OriginalCopyRig(); rig.land("old")
            let admission = CaptureAdmission(), input = PhysicalInputAuthority()
            let runtime = AutomationRuntime(clock: OriginalAutomationClock(), enabled: { false })
            let host = DictationInvocationHost(machine: rig.machine, inputAuthority: input, captureAdmission: admission,
                broker: runtime.broker, results: runtime.results, settings: { rig.settings }, configured: { _ in false },
                capabilities: { _ in nil }, secure: { false }, keyboardAllowed: { true }, automationAllowed: { false },
                explicitEntry: {}, send: { rig.send($0) }, invalidateOriginal: { rig.controller.clear() })
            rig.onEffect = { effect in
                switch effect {
                case .captureAccepted(let s): host.accepted(s)
                case .captureAcknowledged(let s): host.acknowledged(s)
                case .captureFinalizing(let s): host.finalizing(s)
                default: break
                }
            }
            let start = DictationSession.Event.startDictation(settings: rig.settings!, cleanupConfigured: false, live: false)
            let press = MousePress(button: 2, at: 100, tracksPhysicalState: false, inputEpoch: input.snapshot.epoch,
                admissionRevision: admission.revision, suspensionRevision: HotkeyMonitor.suspensionRevision)
            let router = DictationInputRouter(host: host, prepare: { start }, secureRefused: { XCTFail() })
            if mouse { router.mouse(.down(press)) } else { XCTAssertTrue(host.keyboard(start)) }
            XCTAssertNil(rig.controller.refresh().token)
            let s = rig.accepted.last!
            rig.send(.recorderStarted(gen: s.gen)); rig.send(.focusSampled(gen: s.gen, focus: .editable))
            if mouse { router.mouse(.up(press, short: false)) } else { XCTAssertTrue(host.keyboard(.stopRequested)) }
            rig.transcribe(s, mouse ? "mouse original" : "keyboard original")
            XCTAssertTrue(rig.copy()); XCTAssertEqual(rig.copies, [mouse ? "mouse original" : "keyboard original"])
            XCTAssertEqual(rig.texts.count, 2); XCTAssertEqual(rig.corrections, rig.texts)
            rig.onEffect = nil // release test closure/host before the fixture
        }
    }
}

extension OriginalCopyTests {
    @MainActor func testClipboardExperimentFlagAloneMixedMouseOriginalNetZeroAndGeneralSaves() throws {
        let fixture = try OriginalHubFixture(); defer { try! fixture.close() }
        let hub = fixture.hub; var general = 0, passive = 0
        hub.onSaved = { general += 1 }; hub.onMouseBindingSaved = { passive += 1 }
        hub.settings.clipboardReceiptRestoreEnabled = true; hub.flushPendingSave()
        XCTAssertTrue(fixture.store.load().clipboardReceiptRestoreEnabled)
        XCTAssertEqual(passive, 1); XCTAssertEqual(general, 0)
        hub.settings.clipboardReceiptRestoreEnabled = false; hub.settings.clipboardReceiptRestoreEnabled = true
        hub.settings.mouseBinding = .init(buttonNumber: 2); hub.settings.keepLastOriginalEnabled = true
        hub.flushPendingSave(); XCTAssertEqual(passive, 2); XCTAssertEqual(general, 0)
        hub.settings.clipboardReceiptRestoreEnabled = false; hub.settings.clipboardReceiptRestoreEnabled = true
        hub.settings.mouseBinding = nil; hub.settings.mouseBinding = .init(buttonNumber: 2)
        hub.settings.keepLastOriginalEnabled = false; hub.settings.keepLastOriginalEnabled = true
        hub.settings.warmMic.toggle(); hub.settings.warmMic.toggle()
        hub.flushPendingSave(); XCTAssertEqual(passive, 3); XCTAssertEqual(general, 0)
        hub.settings.clipboardReceiptRestoreEnabled = false; hub.settings.warmMic = true
        hub.flushPendingSave(); XCTAssertEqual(passive, 3); XCTAssertEqual(general, 1)
        XCTAssertEqual(fixture.backend.reads + fixture.backend.statuses + fixture.backend.adds
            + fixture.backend.updates + fixture.backend.deletes, 0)
        try Data(#"{"clipboardReceiptRestoreEnabled":"invalid"}"#.utf8).write(to: fixture.store.url)
        hub.refresh(); hub.settings.clipboardReceiptRestoreEnabled = true; hub.flushPendingSave()
        XCTAssertNotNil(hub.loadError); XCTAssertEqual(general, 1); XCTAssertEqual(passive, 3)
    }

    @MainActor func testActualReducerExecutorProviderPreservesOriginalHookOnceAndNoLateRevival() {
        let rig = OriginalCopyRig(), clipboard = ExperimentRig()
        rig.settings?.clipboardReceiptRestoreEnabled = true
        var hooks = 0
        rig.executor = DictationInsertionExecutor(originals: rig.controller,
            post: DictationInsertionExecutor.configuredPoster(configuration: { rig.settings }, native: { text, diagnostics, mode, hook in
                clipboard.delivery.paste(text, mode: mode, diagnostics: diagnostics) {
                    XCTAssertNotNil(clipboard.current.provider)
                    hooks += 1; hook()
                    XCTAssertNil(rig.controller.status.token, "offer only after synchronous pair returns")
                    clipboard.current.request() // posting phase, not evidence
                }
            }), didPost: { rig.corrections.append($0) })
        let session = rig.start(cleanup: true)
        let landed = rig.pending(session, "exact Original 😀")
        rig.send(.cleanReady(session, landed, text: "cleaned output", failure: nil, focus: .editable))
        XCTAssertEqual(hooks, 1); XCTAssertNotNil(rig.controller.status.token)
        XCTAssertTrue(rig.copies.isEmpty); XCTAssertEqual(rig.corrections, ["cleaned output"])
        rig.controller.clear(); session.operation.finish(); clipboard.diagnostics.clear()
        clipboard.current.request(); clipboard.current.provider?.finished(); clipboard.flush()
        clipboard.fire(clipboard.timers.last!)
        XCTAssertEqual(hooks, 1); XCTAssertNil(rig.controller.refresh().token)
        XCTAssertTrue(rig.copies.isEmpty); XCTAssertFalse(clipboard.delivery.isRestorePending)
    }

    @MainActor func testFailedExperimentalPublicationNeverHooksOffersLearnsOrAutomaticallyCopies() {
        let rig = OriginalCopyRig(), clipboard = ExperimentRig(); var hooks = 0
        rig.settings?.clipboardReceiptRestoreEnabled = true
        clipboard.board.writeResults = [false, true]
        rig.executor = DictationInsertionExecutor(originals: rig.controller,
            post: DictationInsertionExecutor.configuredPoster(configuration: { rig.settings }, native: { text, diagnostic, mode, hook in
                clipboard.delivery.paste(text, mode: mode, diagnostics: diagnostic) { hooks += 1; hook() }
            }), didPost: { _ in XCTFail("failed paste learning") })
        rig.land("raw original")
        XCTAssertEqual(hooks, 0); XCTAssertNil(rig.controller.refresh().token); XCTAssertTrue(rig.copies.isEmpty)
        XCTAssertFalse(clipboard.delivery.isRestorePending)
    }

    @MainActor func testResultOnlyAutomationWithExperimentOnAndOffConstructsNoClipboard() {
        for enabled in [false, true] {
            let rig = OriginalCopyRig(); rig.settings?.clipboardReceiptRestoreEnabled = enabled
            var nativeEntries = 0
            rig.executor = DictationInsertionExecutor(originals: rig.controller,
                post: DictationInsertionExecutor.configuredPoster(configuration: { rig.settings }, native: { _, _, _, _ in
                    nativeEntries += 1
                    _ = ExperimentBoard() // construction itself must never happen
                    return false
                }), didPost: { _ in XCTFail("result-only learning") })
            rig.send(.startAutomation(settings: rig.settings!, cleanupConfigured: false))
            rig.send(.recorderStarted(gen: rig.machine.gen)); rig.send(.stopRequested)
            let session = rig.accepted.last!, landed = rig.pending(rig.accepted.last!, "raw")
            rig.send(.cleanReady(session, landed, text: "result", failure: nil, focus: .unknown))
            XCTAssertEqual(nativeEntries, 0); XCTAssertEqual(rig.results, [.text("result", .final)])
        }
    }
}

extension OriginalCopyTests {
    @MainActor func testExplicitOriginalActionChangesOwnershipAndSurvivesRestoreAndNextStoredPaste() {
        let rig = OriginalCopyRig(), clipboard = ExperimentRig()
        rig.settings?.clipboardReceiptRestoreEnabled = true
        rig.onCopy = clipboard.board.copy
        rig.executor = DictationInsertionExecutor(originals: rig.controller,
            post: DictationInsertionExecutor.configuredPoster(configuration: { rig.settings }, native: { text, diagnostic, mode, hook in
                clipboard.delivery.paste(text, mode: mode, diagnostics: diagnostic, postPaste: hook)
            }), didPost: { rig.corrections.append($0) })
        let session = rig.start(cleanup: true), landed = rig.pending(rig.accepted.last!, "exact raw Original 😀")
        rig.send(.cleanReady(session, landed, text: "cleaned", failure: nil, focus: .editable))
        XCTAssertTrue(rig.copies.isEmpty); XCTAssertTrue(rig.copy())
        XCTAssertEqual(rig.copies, ["exact raw Original 😀"])
        XCTAssertTrue(rig.executor.insertStored("history"))
        clipboard.fire(clipboard.timers.last!)
        XCTAssertEqual(clipboard.current.values[.string], Data("exact raw Original 😀".utf8))
        XCTAssertEqual(rig.corrections, ["cleaned"]); XCTAssertNil(rig.controller.status.token)
    }
}
