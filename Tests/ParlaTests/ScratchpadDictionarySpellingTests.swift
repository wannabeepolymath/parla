import XCTest
import AppKit
import ParlaCore
@testable import Parla

private final class SpellingValidationItem: NSObject, NSValidatedUserInterfaceItem {
    var action: Selector? { NSSelectorFromString("dictionarySpelling:") }
    var tag: Int { 0 }
}

@MainActor private final class SpellingEditor: ScratchpadEditor {
    weak var owner: ScratchpadController?
    var text: [UInt16] = Array("openai openai".utf16)
    var selection = NSRange(location: 10, length: 0)
    var affinity = 1
    var identity = ScratchpadIdentity(document: UUID(), view: UUID(), storage: UUID(), window: UUID())
    var focusedAndEditable = true
    var undoEnabled = true
    var replayingUndo = false
    var undoGroupingLevel = 0
    var transactionOwnerStable = true
    var reads = 0, snapshots = 0, mutations = 0, changes = 0
    var permission = true
    var callback: (() -> Void)?
    var afterReplace: (() -> Void)?
    var events: [String] = []
    var inverses: [ScratchpadEditCommand] = []
    func state() -> ScratchpadEditorState? {
        reads += 1
        return ScratchpadEditorState(identity: identity, length: text.count, selection: selection, affinity: affinity)
    }
    func rawUTF16() -> [UInt16] { snapshots += 1; return text }
    func currentText() -> String { String(decoding: text, as: UTF16.self) }
    func breakCoalescing() { events.append("break") }
    func beginUndoGroup() { events.append("begin"); undoGroupingLevel += 1 }
    func endUndoGroup() { events.append("end"); undoGroupingLevel -= 1 }
    func suppressImplicitUndo() { events.append("suppress"); undoEnabled = false }
    func restoreImplicitUndo() { events.append("restore"); undoEnabled = true }
    func shouldChange(_ command: ScratchpadEditCommand) -> Bool {
        events.append("permission")
        let admitted = owner!.admitNativeChange(range: command.range, replacement: String(decoding: command.after, as: UTF16.self))
        callback?()
        return permission && admitted
    }
    func replace(_ command: ScratchpadEditCommand) {
        events.append("replace"); mutations += 1
        text.replaceSubrange(command.range.location..<NSMaxRange(command.range), with: command.after)
        owner?.charactersChanged(); afterReplace?()
    }
    func select(_ range: NSRange, affinity: Int) {
        events.append("selection"); selection = range; self.affinity = affinity; owner?.selectionChanged()
    }
    func didChange() { events.append("didChange"); changes += 1; owner?.textDidChange() }
    func registerInverse(_ command: ScratchpadEditCommand) { events.append("inverse"); inverses.append(command) }
    func clearDocumentUndo() { events.append("clear"); inverses.removeAll() }
    func undo() -> Bool {
        let command = inverses.removeLast()
        replayingUndo = true; defer { replayingUndo = false }
        return owner!.applyInverse(command)
    }
}
@MainActor private final class SpellingRig {
    struct Timer { let delay: Double; let fire: @MainActor () -> Void; var canceled = false }
    let editor = SpellingEditor()
    var settings = Settings()
    var now = 1.0
    var configReads = 0, preferenceWrites = 0, loads = 0, shows = 0
    var failRead = false, failWrite = false
    var onConfiguration: (() -> Void)?
    var saved: [String] = []
    var timers: [Timer] = []
    lazy var owner: ScratchpadController = {
        let value = ScratchpadController(ports: .init(configuration: {
            self.configReads += 1
            self.onConfiguration?()
            if self.failRead { throw ScratchpadPreferenceFailure() }
            return ScratchpadDictionaryConfiguration(settings: self.settings)
        }, preference: { enabled, expected in
            self.preferenceWrites += 1
            guard !self.failWrite, expected == self.settings.scratchpadDictionaryAlternativesEnabled else { throw ScratchpadPreferenceFailure() }
            self.settings.scratchpadDictionaryAlternativesEnabled = enabled
            return enabled
        }, clock: { self.now }, loadText: { self.loads += 1; return "" }, saveText: { self.saved.append($0) },
           schedule: { delay, action in
            let id = self.timers.count; self.timers.append(Timer(delay: delay, fire: action))
            return { self.timers[id].canceled = true }
        }, showWindow: { _ in self.shows += 1 }), editor: editor)
        editor.owner = value
        return value
    }()
    init() { settings.dictionary = ["OpenAI"] }
    func start() { owner.show(); owner.setDictionarySpellingEnabled(true) }
    func choose(_ request: ScratchpadController.Request) -> Bool {
        owner.chooseDictionarySpelling(request: request.id, candidate: request.candidates[0].id)
    }
    func fireSaves() { for timer in timers where timer.delay == 0.5 && !timer.canceled { timer.fire() } }
}

final class ScratchpadDictionarySpellingTests: XCTestCase {
    @MainActor func testColdOffAndPassiveCallbacksDoNotReadEditorOrDefaultPorts() {
        let rig = SpellingRig(); let owner = rig.owner
        XCTAssertEqual(rig.configReads + rig.loads + rig.shows, 0)
        XCTAssertNil(owner.beginDictionarySpelling())
        XCTAssertFalse(owner.validateUserInterfaceItem(SpellingValidationItem()))
        owner.dictionarySpelling(nil) // Exact native selector, without constructing native UI.
        owner.configurationChanged(); owner.selectionChanged(); owner.charactersChanged(); owner.quitIntent(); owner.save()
        XCTAssertEqual(rig.editor.reads + rig.editor.snapshots + rig.configReads, 0)
        XCTAssertEqual(rig.saved, [])
        owner.setDictionarySpellingEnabled(true)
        XCTAssertEqual(rig.editor.reads + rig.editor.snapshots + rig.loads + rig.shows, 0)
        XCTAssertNil(owner.beginDictionarySpelling()) // Never visible.
        owner.show(); owner.setDictionarySpellingEnabled(false)
        let reads = rig.configReads
        XCTAssertNil(owner.beginDictionarySpelling())
        XCTAssertEqual(rig.configReads, reads)
        XCTAssertEqual(rig.editor.reads + rig.editor.snapshots, 0)
    }
    @MainActor func testExplicitSecondOccurrenceUndoRedoLiteralAndCurrentValueSave() throws {
        let rig = SpellingRig(); rig.start()
        XCTAssertTrue(rig.owner.validateUserInterfaceItem(SpellingValidationItem()))
        XCTAssertEqual(rig.editor.reads + rig.editor.snapshots, 0)
        rig.owner.dictionarySpelling(nil)
        let request = try XCTUnwrap(rig.owner.request)
        XCTAssertEqual(request.range, NSRange(location: 7, length: 6))
        XCTAssertEqual(request.candidates.map(\.literal), ["OpenAI"])
        XCTAssertEqual(rig.editor.mutations, 0); XCTAssertTrue(rig.saved.isEmpty)
        XCTAssertTrue(rig.choose(request)); XCTAssertEqual(rig.editor.currentText(), "openai OpenAI")
        XCTAssertEqual(rig.editor.selection, NSRange(location: 13, length: 0))
        XCTAssertEqual(rig.editor.events, ["break", "begin", "suppress", "permission", "replace", "selection", "didChange", "restore", "inverse", "end", "break"])
        XCTAssertEqual(rig.editor.changes, 1); XCTAssertEqual(rig.editor.inverses.count, 1)
        XCTAssertFalse(rig.choose(request)); XCTAssertEqual(rig.editor.mutations, 1)
        rig.owner.setDictionarySpellingEnabled(false)
        XCTAssertTrue(rig.editor.undo()); XCTAssertEqual(rig.editor.currentText(), "openai openai")
        XCTAssertEqual(rig.editor.selection, NSRange(location: 10, length: 0)); XCTAssertEqual(rig.editor.affinity, 1)
        XCTAssertTrue(rig.editor.undo()); XCTAssertEqual(rig.editor.currentText(), "openai OpenAI")
        XCTAssertEqual(rig.editor.undoGroupingLevel, 0); XCTAssertTrue(rig.editor.undoEnabled)
        rig.editor.text += Array(" later".utf16); rig.owner.textDidChange()
        rig.fireSaves(); XCTAssertEqual(rig.saved, ["openai OpenAI later"])
    }
    @MainActor func testSelectedCanonicalFormRestoresExactUnitsAndSelection() throws {
        let rig = SpellingRig(); rig.editor.text = Array("cafe\u{301}!".utf16)
        rig.editor.selection = NSRange(location: 0, length: 5); rig.settings.dictionary = ["Café"]
        rig.start(); let request = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        XCTAssertTrue(rig.choose(request)); XCTAssertEqual(rig.editor.text, Array("Café!".utf16))
        XCTAssertEqual(rig.editor.selection, NSRange(location: 0, length: 4))
        XCTAssertTrue(rig.editor.undo()); XCTAssertEqual(rig.editor.text, Array("cafe\u{301}!".utf16))
        XCTAssertEqual(rig.editor.selection, NSRange(location: 0, length: 5))
    }
    @MainActor func testLongerCanonicalOutputCannotCrossDocumentCapBeforeMutation() throws {
        let rig = SpellingRig()
        rig.editor.text = Array(("café" + String(repeating: " ", count: 65_532)).utf16)
        rig.editor.selection = NSRange(location: 2, length: 0)
        rig.settings.dictionary = ["cafe\u{301}"]
        rig.start(); let request = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        XCTAssertFalse(rig.choose(request)); XCTAssertEqual(rig.editor.text.count, 65_536)
        XCTAssertEqual(rig.editor.mutations + rig.editor.changes, 0)
        XCTAssertTrue(rig.editor.events.isEmpty); XCTAssertTrue(rig.editor.inverses.isEmpty)
    }
    @MainActor func testCancelNoopAndRefusalLeaveOlderTypingSaveIntact() throws {
        let rig = SpellingRig(); rig.start(); rig.owner.textDidChange()
        let request = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        rig.owner.cancelDictionarySpelling(); XCTAssertFalse(rig.choose(request))
        rig.settings.dictionary = ["openai"]; XCTAssertNil(rig.owner.beginDictionarySpelling())
        XCTAssertEqual(rig.editor.changes + rig.editor.mutations, 0); XCTAssertTrue(rig.editor.inverses.isEmpty)
        rig.fireSaves(); XCTAssertEqual(rig.saved, ["openai openai"])
    }
    @MainActor func testEachMetadataEventRevokesWithoutRescanningAndNoAutoRegeneration() throws {
        let events: [(ScratchpadController) -> Void] = [
            { $0.charactersChanged() }, { $0.selectionChanged(); $0.selectionChanged() },
            { $0.configurationChanged() }, { $0.documentReloaded() }, { $0.attachEditor(nil) },
            { $0.close() }, { $0.lifecycleLost() }, { $0.focusLost() }, { $0.quitIntent() },
            { $0.setDictionarySpellingEnabled(false); $0.setDictionarySpellingEnabled(true) }
        ]
        for event in events {
            let rig = SpellingRig(); rig.start(); let request = try XCTUnwrap(rig.owner.beginDictionarySpelling())
            let reads = rig.editor.reads + rig.editor.snapshots
            event(rig.owner)
            XCTAssertEqual(rig.editor.reads + rig.editor.snapshots, reads)
            XCTAssertNil(rig.owner.request); XCTAssertFalse(rig.choose(request)); XCTAssertEqual(rig.editor.mutations, 0)
        }
    }
    @MainActor func testFreshConfigSignatureRejectsSameLengthVocabularyOrderRulesAndSnippets() throws {
        for change: (inout Settings) -> Void in [
            { $0.dictionary = ["OPENAI"] }, { $0.dictionary = ["other", "OpenAI"] },
            { $0.snippets = ["hello": "text"] }, { $0.replacements = [.init(source: "abc", replacement: "xyz")] },
            { $0.scratchpadDictionaryAlternativesEnabled = false }
        ] {
            let rig = SpellingRig(); rig.start(); let pending = try XCTUnwrap(rig.owner.beginDictionarySpelling())
            change(&rig.settings); XCTAssertFalse(rig.choose(pending)); XCTAssertEqual(rig.editor.mutations, 0)
        }
    }
    @MainActor func testExactTTLAndDelayedTimerAndNewRequest() throws {
        let rig = SpellingRig(); rig.start(); let old = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        let newer = try XCTUnwrap(rig.owner.beginDictionarySpelling()); XCTAssertFalse(rig.choose(old))
        rig.now = newer.deadline // Timer intentionally not fired (native menu tracking).
        XCTAssertFalse(rig.choose(newer)); XCTAssertEqual(rig.editor.mutations, 0)
        rig.now += 1; let final = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        rig.now = final.deadline; rig.owner.expireDictionarySpelling(); XCTAssertNil(rig.owner.request)
    }
    @MainActor func testExpiryDuringFinalConfigurationReadRefusesMutation() throws {
        let rig = SpellingRig(); rig.start(); rig.owner.textDidChange()
        let pending = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        rig.now = pending.deadline - 0.01
        rig.editor.callback = {
            rig.onConfiguration = { rig.now = pending.deadline }
        }
        XCTAssertFalse(rig.choose(pending))
        XCTAssertEqual(rig.now, pending.deadline)
        XCTAssertEqual(rig.editor.mutations + rig.editor.changes, 0)
        XCTAssertTrue(rig.editor.inverses.isEmpty)
        XCTAssertTrue(rig.editor.undoEnabled); XCTAssertEqual(rig.editor.undoGroupingLevel, 0)
        rig.fireSaves(); XCTAssertEqual(rig.saved, ["openai openai"])
    }
    @MainActor func testWrongFocusIdentitySelectionAffinityDocumentCapAndMalformedUTF16() throws {
        let rig = SpellingRig(); rig.start()
        rig.editor.focusedAndEditable = false; XCTAssertNil(rig.owner.beginDictionarySpelling())
        rig.editor.focusedAndEditable = true
        for mutate: (SpellingEditor) -> Void in [
            { $0.focusedAndEditable = false }, { $0.selection.location += 1 }, { $0.affinity = 0 },
            { $0.text.append(32) },
            { $0.identity = ScratchpadIdentity(document: UUID(), view: UUID(), storage: UUID(), window: UUID()) }
        ] {
            let next = SpellingRig(); next.start(); let request = try XCTUnwrap(next.owner.beginDictionarySpelling())
            mutate(next.editor); XCTAssertFalse(next.choose(request)); XCTAssertEqual(next.editor.mutations, 0)
        }
        rig.editor.text = [UInt16](repeating: 97, count: 65_537)
        let snapshots = rig.editor.snapshots
        XCTAssertNil(rig.owner.beginDictionarySpelling()); XCTAssertEqual(rig.editor.snapshots, snapshots)
        rig.editor.text = [0xD800, 97, 98, 99]; XCTAssertNil(rig.owner.beginDictionarySpelling())
    }
    @MainActor func testPermissionFalseAndReentrantTextSelectionConfigAndNestedOnce() throws {
        let changes: [(SpellingRig) -> Void] = [
            { $0.editor.permission = false },
            { $0.editor.text += [32]; $0.owner.charactersChanged() },
            { $0.editor.selection.location += 1; $0.owner.selectionChanged() },
            { $0.settings.dictionary = ["OPENAI"] },
            { $0.owner.configurationChanged() },
            { $0.owner.focusLost() },
            { $0.editor.transactionOwnerStable = false }
        ]
        for change in changes {
            let rig = SpellingRig(); rig.start(); let request = try XCTUnwrap(rig.owner.beginDictionarySpelling())
            rig.editor.callback = { change(rig) }
            XCTAssertFalse(rig.choose(request)); XCTAssertEqual(rig.editor.mutations + rig.editor.changes, 0)
            XCTAssertTrue(rig.editor.inverses.isEmpty); XCTAssertTrue(rig.editor.undoEnabled); XCTAssertEqual(rig.editor.undoGroupingLevel, 0)
        }
        let rig = SpellingRig(); rig.start(); let pending = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        rig.editor.callback = {
            XCTAssertNil(rig.owner.beginDictionarySpelling()); XCTAssertFalse(rig.choose(pending))
            XCTAssertFalse(rig.owner.admitNativeChange(range: pending.range, replacement: "OpenAI"))
            XCTAssertFalse(rig.owner.admitNativeChange(range: NSRange(location: 0, length: 0), replacement: "nested"))
        }
        XCTAssertTrue(rig.choose(pending)); XCTAssertEqual(rig.editor.mutations, 1)
    }
    @MainActor func testDisableFailureCannotResurrectAndExplicitRecoveryOnly() throws {
        let rig = SpellingRig(); rig.start(); let pending = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        rig.failWrite = true; rig.owner.setDictionarySpellingEnabled(false)
        XCTAssertFalse(rig.owner.enabled); XCTAssertTrue(rig.settings.scratchpadDictionaryAlternativesEnabled)
        rig.owner.configurationChanged(savedFlag: true); rig.owner.refreshPreference()
        XCTAssertFalse(rig.owner.enabled); XCTAssertFalse(rig.choose(pending))
        rig.failWrite = false; rig.owner.setDictionarySpellingEnabled(true); XCTAssertTrue(rig.owner.enabled)
    }
    @MainActor func testUndoRejectsReloadOrWrongExpectedSpanWithoutSecondMutation() throws {
        let rig = SpellingRig(); rig.start(); let request = try XCTUnwrap(rig.owner.beginDictionarySpelling())
        XCTAssertTrue(rig.choose(request)); rig.editor.text[7] = 88
        XCTAssertFalse(rig.editor.undo()); XCTAssertEqual(rig.editor.mutations, 1)
        let other = SpellingRig(); other.start(); let pending = try XCTUnwrap(other.owner.beginDictionarySpelling())
        XCTAssertTrue(other.choose(pending))
        let staleInverse = other.editor.inverses.last!
        other.owner.documentReloaded(); XCTAssertTrue(other.editor.inverses.isEmpty)
        other.editor.replayingUndo = true
        XCTAssertFalse(other.owner.applyInverse(staleInverse))
    }
    @MainActor func testCloseFlushAndNeverShownQuitNoIOAndUnexpectedObserverNoRollback() throws {
        let cold = SpellingRig(); cold.owner.quitIntent(); cold.owner.save(); XCTAssertEqual(cold.saved, []); XCTAssertEqual(cold.loads, 0)
        let rig = SpellingRig(); rig.start(); rig.owner.textDidChange(); rig.editor.text += Array(" newer".utf16)
        rig.owner.close(); rig.fireSaves(); XCTAssertEqual(rig.saved, ["openai openai newer"])
        let reads = rig.editor.reads + rig.editor.snapshots
        rig.owner.becameVisible()
        XCTAssertNil(rig.owner.request); XCTAssertEqual(rig.editor.reads + rig.editor.snapshots, reads)
        XCTAssertNotNil(rig.owner.beginDictionarySpelling()) // New explicit action after restoring a hidden window.
        let next = SpellingRig(); next.start(); let request = try XCTUnwrap(next.owner.beginDictionarySpelling())
        next.editor.afterReplace = { next.editor.text[7] = 88 }
        XCTAssertFalse(next.choose(request)); XCTAssertEqual(next.editor.mutations, 1)
        XCTAssertEqual(next.editor.changes, 0); XCTAssertTrue(next.editor.inverses.isEmpty)
        XCTAssertEqual(next.editor.undoGroupingLevel, 0); XCTAssertTrue(next.editor.undoEnabled)
    }
}
