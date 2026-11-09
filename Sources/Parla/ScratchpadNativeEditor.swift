import AppKit

private final class ScratchpadActionButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
}
private final class ScratchpadChoice: NSObject {
    let request: UUID
    let candidate: UUID
    init(request: UUID, candidate: UUID) { self.request = request; self.candidate = candidate }
}

/// Lazy owned UI. No NSTextView/NSWindow/UndoManager is created by the controller
/// constructor, preference notifications, menu validation, or quit metadata.
@MainActor final class NativeScratchpad: NSObject, ScratchpadEditor, NSWindowDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    private weak var owner: ScratchpadController?
    private let window: NSWindow
    private let textView: NSTextView
    private let identity: ScratchpadIdentity
    private let storageIdentity: ObjectIdentifier
    private let checkbox = NSButton(checkboxWithTitle: "Dictionary spelling in Scratchpad", target: nil, action: nil)
    private let button = ScratchpadActionButton(title: "Dictionary spelling…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var menu: NSMenu?
    private var manager: UndoManager? { textView.undoManager }
    private var transactionManager: UndoManager?

    init(owner: ScratchpadController, text: String) {
        self.owner = owner
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        identity = ScratchpadIdentity(document: UUID(), view: UUID(), storage: UUID(), window: UUID())
        storageIdentity = ObjectIdentifier(textView.textStorage!)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.allowsUndo = true
        textView.string = text
        textView.delegate = self
        textView.textStorage?.delegate = self
        checkbox.target = self; checkbox.action = #selector(toggle(_:))
        button.target = owner; button.action = #selector(ScratchpadController.dictionarySpelling(_:))
        let controls = NSStackView(views: [checkbox, button])
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 5
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let disclosure = NSTextField(wrappingLabelWithString: "Scratchpad text is saved on this Mac. Click a word to choose a spelling from your dictionary.")
        disclosure.font = .systemFont(ofSize: 11); disclosure.textColor = .secondaryLabelColor
        let container = NSView()
        for view in [controls, status, scroll, disclosure] {
            view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            disclosure.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            disclosure.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            disclosure.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            disclosure.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        window.title = "Scratchpad"; window.minSize = NSSize(width: 350, height: 330)
        window.isReleasedWhenClosed = false; window.delegate = self; window.contentView = container
        window.setFrameAutosaveName("ParlaScratchpad")
        if !window.setFrameUsingName("ParlaScratchpad") { window.center() }
        owner.projectionChanged = { [weak self] in self?.render() }
        owner.dismissChoices = { [weak self] in self?.dismiss() }
        render()
    }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }
    private func render() {
        guard let owner else { return }
        checkbox.state = owner.enabled ? .on : .off
        button.isEnabled = owner.enabled && owner.state != .applying
        status.stringValue = owner.message
    }
    @objc private func toggle(_ sender: NSButton) { owner?.setDictionarySpellingEnabled(sender.state == .on) }
    func present(_ request: ScratchpadController.Request) {
        guard owner?.request?.id == request.id else { return }
        let picker = NSMenu(title: "Dictionary spelling")
        picker.autoenablesItems = false
        let label = NSMenuItem(title: request.more ? "Dictionary spellings (first 5)" : "Dictionary spellings", action: nil, keyEquivalent: "")
        label.isEnabled = false; picker.addItem(label)
        for (index, candidate) in request.candidates.enumerated() {
            let item = NSMenuItem(title: "\(candidate.literal)  (\(index + 1))", action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ScratchpadChoice(request: request.id, candidate: candidate.id)
            picker.addItem(item)
        }
        menu = picker
        // No initial/default item or key equivalent. Native focus/keyboard behavior
        // remains a qualification gate: strict choice checks never restore focus.
        picker.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
        if menu === picker { menu = nil; owner?.cancelDictionarySpelling() }
    }
    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ScratchpadChoice,
              let menu, sender.menu === menu else { return }
        owner?.chooseDictionarySpelling(request: choice.request, candidate: choice.candidate)
    }
    private func dismiss() { let old = menu; menu = nil; old?.cancelTracking() }
    // popUp tracks synchronously. Cancel on return, after a selected item's
    // action has had its chance; menuDidClose can precede that action in AppKit.
    var focusedAndEditable: Bool {
        NSApp.isActive && window.isVisible && !window.isMiniaturized && window.isKeyWindow
            && NSApp.keyWindow === window && window.firstResponder === textView
            && textView.window === window && textView.isEditable && !textView.hasMarkedText()
            && textView.textStorage.map { ObjectIdentifier($0) == storageIdentity } == true
    }
    var undoEnabled: Bool { textView.allowsUndo && manager?.isUndoRegistrationEnabled == true }
    var replayingUndo: Bool { manager.map { $0.isUndoing || $0.isRedoing } ?? false }
    var undoGroupingLevel: Int { manager?.groupingLevel ?? -1 }
    func state() -> ScratchpadEditorState? {
        guard let storage = textView.textStorage, ObjectIdentifier(storage) == storageIdentity,
              textView.selectedRanges.count == 1, !textView.hasMarkedText(), textView.window === window else { return nil }
        return ScratchpadEditorState(identity: identity, length: storage.length, selection: textView.selectedRange(), affinity: Int(textView.selectionAffinity.rawValue))
    }
    func rawUTF16() -> [UInt16] {
        guard let string = textView.textStorage?.mutableString, string.length <= ScratchpadSpellingPolicy.documentUnits else { return [] }
        var raw = [UInt16](repeating: 0, count: string.length)
        if !raw.isEmpty { string.getCharacters(&raw, range: NSRange(location: 0, length: raw.count)) }
        return raw
    }
    func currentText() -> String { textView.string }
    func breakCoalescing() { textView.breakUndoCoalescing() }
    var transactionOwnerStable: Bool {
        guard let transactionManager else { return false }
        return manager === transactionManager
    }
    func beginUndoGroup() { transactionManager = manager; transactionManager?.beginUndoGrouping() }
    func endUndoGroup() { transactionManager?.endUndoGrouping(); transactionManager = nil }
    func suppressImplicitUndo() { transactionManager?.disableUndoRegistration() }
    func restoreImplicitUndo() { transactionManager?.enableUndoRegistration() }
    func shouldChange(_ command: ScratchpadEditCommand) -> Bool {
        textView.shouldChangeText(in: command.range, replacementString: String(decoding: command.after, as: UTF16.self))
    }
    func replace(_ command: ScratchpadEditCommand) {
        textView.replaceCharacters(in: command.range, with: String(decoding: command.after, as: UTF16.self))
    }
    func select(_ range: NSRange, affinity: Int) {
        textView.setSelectedRange(range, affinity: NSSelectionAffinity(rawValue: UInt(affinity)) ?? .downstream, stillSelecting: false)
    }
    func didChange() { textView.didChangeText() }
    func registerInverse(_ command: ScratchpadEditCommand) {
        transactionManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { _ = target.owner?.applyInverse(command) }
        }
        transactionManager?.setActionName("Dictionary Spelling")
    }
    func clearDocumentUndo() { manager?.removeAllActions() }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        owner?.admitNativeChange(range: affectedCharRange, replacement: replacementString) ?? false
    }
    func textDidChange(_ notification: Notification) { owner?.textDidChange() }
    func textViewDidChangeSelection(_ notification: Notification) { owner?.selectionChanged() }
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // This owned plain-text storage is edited only on main. Make that
        // boundary explicit rather than satisfying a nonisolated delegate unsafely.
        MainActor.assumeIsolated { owner?.charactersChanged() }
    }
    func windowWillClose(_ notification: Notification) { owner?.close() }
    func windowDidBecomeKey(_ notification: Notification) { owner?.becameVisible() }
    func windowDidResignKey(_ notification: Notification) { owner?.focusLost() }
    func windowDidMiniaturize(_ notification: Notification) { owner?.lifecycleLost() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if !window.isVisible { owner?.lifecycleLost() }
    }
}
