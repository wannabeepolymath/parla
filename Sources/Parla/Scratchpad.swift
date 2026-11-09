import AppKit
import ParlaCore

struct ScratchpadIdentity: Equatable {
    let document: UUID
    let view: UUID
    let storage: UUID
    let window: UUID
}
struct ScratchpadEditorState: Equatable {
    let identity: ScratchpadIdentity
    let length: Int
    let selection: NSRange
    let affinity: Int
}
struct ScratchpadEditCommand {
    let documentEpoch: UUID
    let identity: ScratchpadIdentity
    let range: NSRange
    let before: [UInt16]
    let after: [UInt16]
    let beforeSelection: NSRange
    let afterSelection: NSRange
    let beforeAffinity: Int
    let afterAffinity: Int
    var inverse: Self {
        Self(documentEpoch: documentEpoch, identity: identity, range: NSRange(location: range.location, length: after.count),
             before: after, after: before, beforeSelection: afterSelection, afterSelection: beforeSelection,
             beforeAffinity: afterAffinity, afterAffinity: beforeAffinity)
    }
}

/// Actual native owner below implements these primitives using its NSTextView's
/// UndoManager. Tests substitute primitives, never a second production undo stack.
@MainActor protocol ScratchpadEditor: AnyObject {
    var focusedAndEditable: Bool { get }
    var undoEnabled: Bool { get }
    var replayingUndo: Bool { get }
    var undoGroupingLevel: Int { get }
    var transactionOwnerStable: Bool { get }
    func state() -> ScratchpadEditorState?
    func rawUTF16() -> [UInt16]
    func currentText() -> String
    func breakCoalescing()
    func beginUndoGroup()
    func endUndoGroup()
    func suppressImplicitUndo()
    func restoreImplicitUndo()
    func shouldChange(_ command: ScratchpadEditCommand) -> Bool
    func replace(_ command: ScratchpadEditCommand)
    func select(_ range: NSRange, affinity: Int)
    func didChange()
    func registerInverse(_ command: ScratchpadEditCommand)
    func clearDocumentUndo()
}

@MainActor final class ScratchpadController: NSObject, NSUserInterfaceValidations {
    enum State { case disabled, idle, presenting, applying }
    struct Candidate { let id: UUID; let literal: String }
    struct Request {
        let id: UUID
        let candidateSet: UUID
        let owner: UUID
        let policy: Int
        let editor: ScratchpadEditorState
        let session: UInt64
        let editRevision: UInt64
        let selectionRevision: UInt64
        let configRevision: UInt64
        let signature: Data
        let range: NSRange
        let original: [UInt16]
        let candidates: [Candidate]
        let issued: Double
        let deadline: Double
        let more: Bool
    }
    struct Ports {
        var configuration: () throws -> ScratchpadDictionaryConfiguration
        var preference: (Bool, Bool) throws -> Bool
        var clock: () -> Double
        var loadText: () -> String
        var saveText: (String) -> Void
        var schedule: (Double, @escaping @MainActor () -> Void) -> (() -> Void)
        var showWindow: (ScratchpadController) -> Void
    }
    private let ports: Ports
    private let owner = UUID()
    private var documentEpoch = UUID()
    private(set) var state: State = .disabled
    private(set) var request: Request?
    private(set) var enabled = false
    private(set) var message = "Choose a single word of 3 to 64 characters."
    private var storedFlag = false
    private var localDisabled = false
    private var exhausted = false
    private var shown = false
    private var visible = false
    private var busy = false
    private var session: UInt64 = 0
    private var editRevision: UInt64 = 0
    private var selectionRevision: UInt64 = 0
    private var configRevision: UInt64 = 0
    private var cancelSave: (() -> Void)?
    private var cancelExpiry: (() -> Void)?
    private var authorizedChange: ScratchpadEditCommand?
    private var delegateAdmissionUsed = false
    private(set) var editor: ScratchpadEditor?
    fileprivate var native: NativeScratchpad?
    fileprivate var observers: [NSObjectProtocol] = []
    var projectionChanged: () -> Void = {}
    var dismissChoices: () -> Void = {}

    init(ports: Ports, editor: ScratchpadEditor?) {
        self.ports = ports; self.editor = editor
        super.init()
    }

    static func application(store: SettingsStore) -> ScratchpadController {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/scratchpad.txt")
        let controller = ScratchpadController(ports: Ports(
            configuration: { try store.scratchpadDictionaryConfiguration() },
            preference: { try store.setScratchpadDictionaryAlternativesEnabled($0, expected: $1) },
            clock: { ProcessInfo.processInfo.systemUptime },
            loadText: { (try? String(contentsOf: file, encoding: .utf8)) ?? "" },
            saveText: { text in
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }, schedule: { delay, action in
                let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            }, showWindow: { owner in
                if owner.native == nil {
                    owner.native = NativeScratchpad(owner: owner, text: owner.ports.loadText())
                    owner.editor = owner.native
                }
                owner.native?.show()
            }), editor: nil)
        for name in [SettingsStore.configurationDidChange, SettingsStore.scratchpadPreferenceDidChange] {
            controller.observers.append(NotificationCenter.default.addObserver(forName: name, object: store, queue: .main) { [weak controller] note in
                let flag = note.userInfo?["enabled"] as? Bool
                MainActor.assumeIsolated { controller?.configurationChanged(savedFlag: flag) }
            })
        }
        controller.observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.lifecycleLost() }
        })
        return controller
    }

    func show() {
        guard !busy else { return }
        invalidate(); advance(&session)
        shown = true; visible = true
        // Explicit show is the only native construction / initial document load boundary.
        ports.showWindow(self)
        refreshPreference()
    }
    func attachEditor(_ value: ScratchpadEditor?) {
        invalidate(); documentEpoch = UUID(); editor = value; advance(&session)
    }
    func documentReloaded() {
        invalidate(); documentEpoch = UUID(); advance(&session); advance(&editRevision)
        editor?.clearDocumentUndo()
    }
    func refreshPreference() {
        invalidate()
        do {
            let configuration = try ports.configuration()
            storedFlag = configuration.enabled
            enabled = storedFlag && !localDisabled
        } catch { enabled = false; localDisabled = true; message = "Dictionary spelling isn’t available. Fix settings.json and try again." }
        settle()
    }
    func setDictionarySpellingEnabled(_ value: Bool) {
        invalidate(); advance(&configRevision)
        if !value { enabled = false; localDisabled = true; settle() }
        do {
            // Fresh read permits explicit recovery, never a stale refresh resurrection.
            let current = try ports.configuration().enabled
            storedFlag = try ports.preference(value, current)
            enabled = storedFlag; localDisabled = !storedFlag
            message = "Choose a single word of 3 to 64 characters."
        } catch {
            enabled = false; localDisabled = true
            message = "Couldn’t save this setting. Fix settings.json and try again."
        }
        settle()
    }
    func configurationChanged(savedFlag: Bool? = nil) {
        invalidate(); advance(&configRevision)
        if let savedFlag { storedFlag = savedFlag; enabled = savedFlag && !localDisabled }
        settle()
    }
    func selectionChanged() { advance(&selectionRevision); invalidate() }
    func charactersChanged() { advance(&editRevision); invalidate() }
    func textDidChange() {
        charactersChanged()
        cancelSave?()
        cancelSave = ports.schedule(0.5) { [weak self] in self?.save() }
    }
    func lifecycleLost() { visible = false; invalidate(); advance(&session) }
    func becameVisible() {
        guard shown, !visible else { return }
        visible = true; advance(&session); invalidate()
    }
    func focusLost() { invalidate(); advance(&session) }
    func quitIntent() { invalidate(); advance(&session) }
    func close() { lifecycleLost(); save() }
    func save() {
        cancelSave?(); cancelSave = nil
        guard shown, let editor else { return }
        ports.saveText(editor.currentText())
    }
    func cancelDictionarySpelling() { invalidate() }
    func expireDictionarySpelling() {
        guard let request, ports.clock() >= request.deadline else { return }
        invalidate()
    }
    private func advance(_ revision: inout UInt64) {
        let next = revision.addingReportingOverflow(1)
        if next.overflow { exhausted = true; enabled = false; request = nil }
        else { revision = next.partialValue }
    }
    private func settle() {
        if !busy { state = enabled && !exhausted ? .idle : .disabled }
        projectionChanged()
    }
    private func invalidate() {
        request = nil; cancelExpiry?(); cancelExpiry = nil
        dismissChoices()
        settle()
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(dictionarySpelling(_:)) && enabled && visible && !busy && !exhausted
    }
    @objc func dictionarySpelling(_ sender: Any?) {
        if let request = beginDictionarySpelling() { native?.present(request) }
    }

    @discardableResult func beginDictionarySpelling() -> Request? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false; if request == nil { settle() } }
        invalidate()
        guard enabled, !localDisabled, !exhausted, visible else { return nil }
        do {
            let configuration: ScratchpadDictionaryConfiguration
            do { configuration = try ports.configuration() }
            catch { enabled = false; localDisabled = true; throw error }
            guard configuration.enabled else { enabled = false; throw ScratchpadPreferenceFailure() }
            guard let editor, editor.focusedAndEditable, editor.undoEnabled, !editor.replayingUndo,
                  let snapshot = editor.state(), ScratchpadSpellingPolicy.snapshotFitsBudget(snapshot.length) else {
                throw ScratchpadSpellingPolicy.Refusal(message: "Click into a word in the Scratchpad first.")
            }
            let edit = editRevision, selection = selectionRevision, config = configRevision, visibleSession = session
            let raw = editor.rawUTF16()
            guard raw.count == snapshot.length else { throw ScratchpadPreferenceFailure() }
            let token = try ScratchpadSpellingPolicy.token(raw, selection: snapshot.selection)
            let choices = try ScratchpadSpellingPolicy.candidates(original: token.units, words: configuration.words, now: ports.clock)
            guard !choices.outputs.isEmpty else { message = "No dictionary spelling matches this word."; return nil }
            let issued = ports.clock()
            guard issued.isFinite, issued >= 0, edit == editRevision, selection == selectionRevision,
                  config == configRevision, visibleSession == session, editor.focusedAndEditable,
                  editor.state() == snapshot else { throw ScratchpadPreferenceFailure() }
            let pending = Request(id: UUID(), candidateSet: UUID(), owner: owner, policy: ScratchpadSpellingPolicy.version,
                editor: snapshot, session: session, editRevision: edit, selectionRevision: selection,
                configRevision: config, signature: configuration.signature, range: token.range,
                original: token.units, candidates: choices.outputs.map { Candidate(id: UUID(), literal: $0) },
                issued: issued, deadline: issued + ScratchpadSpellingPolicy.lifetime, more: choices.more)
            request = pending; state = .presenting
            message = choices.more ? "Dictionary spellings (first 5). Choose one." : "Choose a dictionary spelling."
            cancelExpiry = ports.schedule(ScratchpadSpellingPolicy.lifetime) { [weak self] in self?.expireDictionarySpelling() }
            projectionChanged()
            return pending
        } catch {
            message = (error as? ScratchpadSpellingPolicy.Refusal)?.message ?? "Your dictionary changed. Try again."
            return nil
        }
    }

    private func fresh(_ pending: Request, editor: ScratchpadEditor) -> Bool {
        let now = ports.clock()
        guard pending.owner == owner, pending.policy == ScratchpadSpellingPolicy.version,
              now.isFinite, now >= pending.issued, now < pending.deadline,
              enabled, !localDisabled, !exhausted, visible, pending.session == session,
              pending.editRevision == editRevision, pending.selectionRevision == selectionRevision,
              pending.configRevision == configRevision, editor.focusedAndEditable,
              editor.state() == pending.editor else { return false }
        guard let configuration = try? ports.configuration(), configuration.enabled,
              configuration.signature == pending.signature else { return false }
        let raw = editor.rawUTF16()
        guard raw.count == pending.editor.length, let token = try? ScratchpadSpellingPolicy.token(raw, selection: pending.editor.selection),
              token.range == pending.range, token.units == pending.original else { return false }
        guard pending.editRevision == editRevision, pending.selectionRevision == selectionRevision,
              pending.configRevision == configRevision, pending.session == session,
              editor.focusedAndEditable, editor.state() == pending.editor else { return false }
        // Configuration I/O and occurrence proof can cross the deadline while
        // the main-thread expiry timer is delayed by menu tracking.
        let admittedAt = ports.clock()
        return admittedAt.isFinite && admittedAt >= now && admittedAt < pending.deadline
    }

    @discardableResult func chooseDictionarySpelling(request id: UUID, candidate candidateID: UUID) -> Bool {
        guard !busy, let pending = request, pending.id == id,
              let candidate = pending.candidates.first(where: { $0.id == candidateID }) else { return false }
        // Consume BEFORE dismissal/permission/any other callback, including reentry.
        request = nil; busy = true; state = .applying
        cancelExpiry?(); cancelExpiry = nil; dismissChoices()
        defer { authorizedChange = nil; busy = false; settle() }
        guard let editor, fresh(pending, editor: editor) else { return false }
        let after = Array(candidate.literal.utf16)
        guard after != pending.original else { return false }
        let afterRange = NSRange(location: pending.range.location, length: after.count)
        let post = pending.editor.selection.length == 0 ? NSRange(location: NSMaxRange(afterRange), length: 0) : afterRange
        let command = ScratchpadEditCommand(documentEpoch: documentEpoch, identity: pending.editor.identity, range: pending.range,
            before: pending.original, after: after, beforeSelection: pending.editor.selection, afterSelection: post,
            beforeAffinity: pending.editor.affinity, afterAffinity: pending.editor.affinity)
        return execute(command, replay: false, recheck: { self.fresh(pending, editor: editor) })
    }

    /// Called by the native UndoManager's handler target, independent of the flag/TTL.
    @discardableResult func applyInverse(_ command: ScratchpadEditCommand) -> Bool {
        guard !busy else { return false }
        busy = true; invalidate(); state = .applying
        defer { authorizedChange = nil; busy = false; settle() }
        guard let editor, editor.replayingUndo else { return false }
        let edit = editRevision, selection = selectionRevision, config = configRevision, generation = session
        return execute(command, replay: true, recheck: {
            edit == self.editRevision && selection == self.selectionRevision && config == self.configRevision && generation == self.session
        })
    }

    /// Shared production transaction sequence. Fake primitives qualify only this
    /// protocol, not native coalescing/focus or atomicity of separate text/caret APIs.
    private func execute(_ command: ScratchpadEditCommand, replay: Bool, recheck: () -> Bool) -> Bool {
        guard let editor, command.documentEpoch == documentEpoch, editor.undoEnabled, replay == editor.replayingUndo,
              replay || editor.undoGroupingLevel == 0, command.before != command.after,
              command.before.count <= ScratchpadSpellingPolicy.tokenUnits,
              command.after.count <= ScratchpadSpellingPolicy.tokenUnits,
              ScratchpadSpellingPolicy.validUTF16(command.before), ScratchpadSpellingPolicy.validUTF16(command.after) else { return false }
        func spanMatches() -> Bool {
            guard let current = editor.state(), current.identity == command.identity,
                  ScratchpadSpellingPolicy.snapshotFitsBudget(current.length),
                  ScratchpadSpellingPolicy.fits(command.range, in: current.length),
                  command.range.length == command.before.count else { return false }
            let raw = editor.rawUTF16()
            return raw.count == current.length && ScratchpadSpellingPolicy.validUTF16(raw)
                && Array(raw[command.range.location..<NSMaxRange(command.range)]) == command.before
        }
        guard let beforeState = editor.state(), spanMatches(), recheck() else { return false }
        let resultingLength = (beforeState.length - command.before.count).addingReportingOverflow(command.after.count)
        guard !resultingLength.overflow, ScratchpadSpellingPolicy.snapshotFitsBudget(resultingLength.partialValue),
              ScratchpadSpellingPolicy.fits(command.afterSelection, in: resultingLength.partialValue) else { return false }
        let generation = session, configuration = configRevision, epoch = documentEpoch
        editor.breakCoalescing(); editor.beginUndoGroup()
        defer { editor.endUndoGroup(); editor.breakCoalescing() }
        editor.suppressImplicitUndo()
        var suppressed = true
        defer { if suppressed { editor.restoreImplicitUndo() } }
        authorizedChange = command; delegateAdmissionUsed = false
        guard editor.shouldChange(command), editor.transactionOwnerStable, spanMatches(), recheck() else { return false }
        authorizedChange = nil
        editor.replace(command)
        editor.select(command.afterSelection, affinity: command.afterAffinity)
        // Observers may intervene; never perform a second repair replacement.
        guard editor.transactionOwnerStable, session == generation, configRevision == configuration, documentEpoch == epoch,
              let after = editor.state(), after.identity == command.identity,
              after.length == resultingLength.partialValue,
              after.selection == command.afterSelection, after.affinity == command.afterAffinity else {
            message = "Couldn’t change the spelling. Try again."; return false
        }
        let raw = editor.rawUTF16()
        let changedRange = NSRange(location: command.range.location, length: command.after.count)
        guard ScratchpadSpellingPolicy.fits(changedRange, in: raw.count),
              Array(raw[changedRange.location..<NSMaxRange(changedRange)]) == command.after else {
            message = "Couldn’t change the spelling. Try again."; return false
        }
        editor.didChange()
        guard editor.transactionOwnerStable, session == generation, configRevision == configuration, documentEpoch == epoch,
              let completed = editor.state(), completed.identity == command.identity,
              completed.selection == command.afterSelection, completed.affinity == command.afterAffinity,
              completed.length == after.length else {
            message = "Couldn’t change the spelling. Try again."; return false
        }
        let completedRaw = editor.rawUTF16()
        guard completedRaw.count == completed.length, ScratchpadSpellingPolicy.validUTF16(completedRaw),
              ScratchpadSpellingPolicy.fits(changedRange, in: completedRaw.count),
              Array(completedRaw[changedRange.location..<NSMaxRange(changedRange)]) == command.after else {
            message = "Couldn’t change the spelling. Try again."; return false
        }
        editor.restoreImplicitUndo(); suppressed = false
        editor.registerInverse(command.inverse)
        return true
    }
    func admitNativeChange(range: NSRange, replacement: String?) -> Bool {
        guard busy else { return true }
        guard !delegateAdmissionUsed, let command = authorizedChange,
              range == command.range, let replacement, replacement.utf16.elementsEqual(command.after) else { return false }
        delegateAdmissionUsed = true
        return true
    }
}
