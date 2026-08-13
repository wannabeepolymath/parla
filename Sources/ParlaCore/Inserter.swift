import AppKit
import Carbon.HIToolbox // IsSecureEventInputEnabled

public enum Inserter {
    /// Stamped on every CGEvent Parla posts (eventSourceUserData), so the hotkey
    /// keyDown monitor can tell our own synthetic keystrokes from a real user
    /// keypress and not self-cancel a live-streaming dictation. Arbitrary magic.
    public static let syntheticMarker: Int64 = 0x50_41_52_4C_41 // "PARLA"

    /// Post an event after tagging it as ours. All Parla keystrokes go through here.
    static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Land text at the cursor as synthetic Unicode keystrokes; typing into a
    /// live selection replaces it, same as paste did. The pasteboard is never
    /// touched — transcripts live only in the app (history), and the sole
    /// clipboard write left anywhere is the user-initiated Copy in the Hub.
    public static func insert(_ text: String) {
        typeUnicode(text)
    }

    /// Split UTF-16 units into chunks of at most `max`, never ending a chunk on an
    /// unpaired high surrogate (which would corrupt emoji/supplementary characters).
    static func chunkUTF16(_ units: [UInt16], max: Int = 200) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var i = 0
        while i < units.count {
            var end = Swift.min(i + max, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1 // keep the surrogate pair together in the next chunk
            }
            chunks.append(Array(units[i ..< end]))
            i = end
        }
        return chunks
    }

    /// Type the text as Unicode keystrokes (layout-independent).
    ///
    /// Chunked because CGEventKeyboardSetUnicodeString truncates long strings.
    /// 200 units, not the 20 this used to use: terminals frame each keyDown/keyUp
    /// burst as a separate paste, so a 600-char transcript arrived as 30 separate
    /// "[Pasted text #N]" blocks and blocked the main actor for ~150ms. FluidVoice
    /// ships 200 against Slack/Discord/VS Code, so the practical ceiling is far
    /// above 20. The 1ms sleep stays rather than going to zero — openless and
    /// OpenWhispr both document literal 0ms dropping characters in Chromium apps.
    public static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for chunk in chunkUTF16(Array(text.utf16)) {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                // Clear inherited modifiers: the user is physically holding fn
                // (push-to-talk), and virtualKey 0 is the A key — without this,
                // every chunk lands as fn+A, macOS's "Show the Dock" shortcut.
                down.flags = []
                up.flags = []
                post(down)
                post(up)
            }
            usleep(1_000)
        }
    }

    /// Post `n` Delete (backspace) keystrokes — used by live streaming to erase a
    /// diverging tail before retyping. Same event-posting style as typeUnicode.
    public static func typeBackspaces(_ n: Int) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let delKey: CGKeyCode = 51 // kVK_Delete
        for _ in 0..<n {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: delKey, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: delKey, keyDown: false) {
                down.flags = [] // held fn would turn this into forward-delete
                up.flags = []
                post(down)
                post(up)
            }
            usleep(5_000)
        }
    }

    /// What Parla can do with the current keyboard focus.
    public enum FocusTarget: Sendable {
        case editable   // confirmed text field: safe to live-type into
        case unknown    // something is focused but AX can't confirm it's a field: paste, don't stream
        case none       // no focused element at all: history only, nothing typed
        case secure     // password field (AXSecureTextField) or secure event input: refuse the dictation entirely
    }

    /// Best-effort focus classification. Chromium/Electron apps (Chrome, VS Code,
    /// Slack…) expose no AX tree until an assistive client flips their
    /// accessibility flag, so on a non-editable answer we flip it and retry
    /// once. First dictation in such an app may still classify as .unknown
    /// (paste fallback); subsequent ones see the real field.
    ///
    /// `secureInput` is a parameter only so tests can force the branch.
    public static func focusTarget(secureInput: Bool = IsSecureEventInputEnabled()) -> FocusTarget {
        // Some process holds the keyboard (1Password, a sudo prompt, Terminal's
        // Secure Keyboard Entry): the window server silently discards every
        // synthetic CGEvent — no error, no return code — so typing would land
        // nothing under a green done HUD. Different signal from AXSecureTextField
        // (that's the field, this is the keyboard), same refusal path.
        if secureInput { return .secure }
        var result = classifyFocus()
        // Never wake Electron's AX tree for a secure field — the whole point is
        // to touch it as little as possible (never stream, never type, never cloud).
        if result != .editable, result != .secure, let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            // Only AXManualAccessibility. AXEnhancedUserInterface puts the *target*
            // process into screen-reader mode for the rest of its lifetime — it
            // outlives Parla, survives a restart, permanently blurs the composer in
            // some Chromium/Electron apps, and can't be undone from outside
            // (muesli PR #1116; VoiceInk reverted it in ba0954a). Don't re-add it.
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(50_000) // give the app a beat to build its AX tree
            result = classifyFocus()
        }
        return result
    }

    /// Focused element via the system-wide query, falling back to asking the
    /// frontmost app directly — Electron/Chromium apps often answer only the
    /// app-level query.
    /// Public so the dictionary-learning watcher observes the *same* element
    /// `canEraseTyped` verified — a second copy of this lookup drifted from it
    /// once already and lost the Electron fallback, which silently disarmed
    /// learning in exactly the apps that need it most.
    public static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // Bound it. The AX default is a 6-second per-message timeout, and this
        // runs on the main thread on every fn-down — a wedged or unresponsive
        // target would freeze the app mid-keypress with no way out. Found the
        // hard way: parla-insert-check hung for ten minutes against an app whose
        // AX bridge had stopped answering. 1s is far longer than a healthy
        // reply and short enough that a stall reads as a dropped dictation
        // rather than a hang.
        AXUIElementSetMessagingTimeout(system, 1)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused { return (focused as! AXUIElement) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused { return (focused as! AXUIElement) }
        return nil
    }

    private static func classifyFocus() -> FocusTarget {
        guard let element = focusedElement() else { return .none }
        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
            ? roleRef as? String : nil
        var subroleRef: CFTypeRef?
        let subrole = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success
            ? subroleRef as? String : nil
        // Password field: standards report role AXTextField + subrole
        // AXSecureTextField; bail BEFORE editable heuristics, which also match.
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return .secure }
        if let role, ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
            return .editable
        }
        // A settable value or a selectable text range both mean editable text.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }
        // The range must actually BE a range. Copy-success alone is not proof of
        // editability — read-only elements answer this attribute too — and
        // focusedFieldState() performs this identical read WITH validation, so
        // without the check classifyFocus was strictly more permissive than the
        // verifier it feeds: it could promise "editable" for a field the swap
        // could then never verify.
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &sel) == .success,
           let sel, CFGetTypeID(sel) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(sel as! AXValue, .cfRange, &range) { return .editable }
        }
        return .unknown
    }

    // MARK: - Taking focus without a human (parla-insert-check only)

    /// Outcome of `focusFirstTextInput`. Three cases because each needs a
    /// different response from the caller: type, ask a human to click, or type
    /// nothing at all.
    public enum FocusGrab: Sendable {
        case focused      // the app confirms our element is the focused one
        case noTextInput  // no text area/field anywhere in the app's windows
        case refused      // found one, but focus did not take
    }

    /// Roles worth aiming a smoke test at, best first: a document body before a
    /// single-line field, so an open Find bar doesn't win over the text the check
    /// means to type into. Narrower than `classifyFocus`'s editable set — a combo
    /// box or search field is editable but not somewhere to put 600 characters.
    static let textInputRoles = ["AXTextArea", "AXTextField"]

    /// Nodes a single `firstMatch` may visit. Depth alone stopped being a
    /// sufficient bound once the limit had to rise past an Electron tree: a
    /// self-referencing node with two children is 2^depth, so the depth that
    /// makes Slack reachable also makes a cycle unwalkable. A reference type so
    /// one budget spans the whole recursion, and defaulted so the pure-logic
    /// tests keep calling `firstMatch(in:maxDepth:children:matches:)` unchanged.
    final class NodeBudget {
        var left: Int
        init(_ n: Int) { left = n }
    }

    /// First node `matches` accepts, depth-first, left to right. `maxDepth`
    /// counts the roots as level 1 and bounds the descent; `budget` bounds the
    /// breadth, so a deep — or self-referencing — tree can't spin the walk
    /// forever. Generic over the node type only so tests can drive it with a
    /// synthetic tree; an AXUIElement cannot be constructed in-process.
    static func firstMatch<Node>(in roots: [Node], maxDepth: Int,
                                 budget: NodeBudget = NodeBudget(20_000),
                                 children: (Node) -> [Node],
                                 matches: (Node) -> Bool) -> Node? {
        guard maxDepth > 0 else { return nil }
        for node in roots {
            guard budget.left > 0 else { return nil }
            budget.left -= 1
            if matches(node) { return node }
            if let hit = firstMatch(in: children(node), maxDepth: maxDepth - 1,
                                    budget: budget,
                                    children: children, matches: matches) { return hit }
        }
        return nil
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }
        return children
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Whether `element` is what `appEl`'s process considers focused. Two ways of
    /// asking because apps answer one or the other: the app names it as its
    /// focused element, or the element itself reports AXFocused.
    private static func isFocused(_ element: AXUIElement, of appEl: AXUIElement) -> Bool {
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef, CFEqual(focused, element) { return true }
        var flag: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &flag) == .success
            && (flag as? Bool) == true
    }

    /// Walk `pid`'s windows for the first text area/field, focus it, and park the
    /// caret at the end of whatever it already holds.
    ///
    /// Both halves exist for `parla-insert-check`, which has to run with nobody
    /// at the keyboard: focus, because run from a shell the focused element stays
    /// the calling terminal and every case skips; caret, because a reopened
    /// document restores its old selection, and typing into a live selection
    /// replaces it — the user's text, not ours. Setting focus is exactly the
    /// capability the Accessibility grant confers, and the same one this file
    /// already uses to read fields. Parla itself never calls this: dictation
    /// types where the user already is.
    ///
    /// `.refused` is not `.focused` with a warning — on it the caller must type
    /// nothing, because unverified focus means the keystrokes land in whatever
    /// happens to be frontmost.
    ///
    /// `roles` narrows what counts as a target, best-first, and defaults to
    /// `textInputRoles`. It exists because the first text input in an app is not
    /// always a safe one to type 600 characters into: in Slack the preferred
    /// AXTextArea is the message composer, where a newline posts to a real
    /// channel, while the AXTextField beside it is the conversation search box —
    /// same Chromium input path, no side effect on anyone else.
    ///
    /// `index` (1-based) picks a later match of the same role when the first is
    /// the wrong one — Cursor and VS Code expose their AI chat box as an
    /// AXTextArea ahead of the editor, and a newline there sends a prompt.
    public static func focusFirstTextInput(pid: pid_t, roles: [String]? = nil,
                                           index: Int = 1) -> FocusGrab {
        let roles = roles ?? textInputRoles
        let appEl = AXUIElementCreateApplication(pid)
        // Bound each AX message to this app — set on the application element it
        // covers the reads below it too. Without it a wedged target blocks every
        // read for the system default, and the walk makes many of them.
        AXUIElementSetMessagingTimeout(appEl, 1)
        // Chromium/Electron apps ship no AX tree until an assistive client asks
        // for one, and the walk below is the ask. Same flag, same reasoning as
        // `focusTarget()` — and emphatically NOT AXEnhancedUserInterface, which
        // outlives us and blurs the composer (see the note there).
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(50_000) // give the app a beat to build its AX tree
        var windowsRef: CFTypeRef?
        // Windows, not the app element, so the menu bar's large subtree is never
        // walked. Depth 40 because 12 was measured wrong on the apps that matter
        // most: Slack's message composer sits at depth 24 and Cursor's editor at
        // 18, both under an AXWebArea at depth 8, so a 12-level walk returned
        // .noTextInput for every Electron app — the whole Slack/VS Code half of
        // ISSUES.md 5-7 — and fell back to asking a human to click. A real tree
        // costs a few hundred nodes (Slack: 459 to depth 26), and `NodeBudget`
        // keeps a cyclic one from turning the extra depth into a hang.
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              // One walk per role rather than one walk matching either, so the
              // preferred role wins wherever it sits in the tree.
              let field = roles.lazy.compactMap({ role -> AXUIElement? in
                  // The counter rides in `matches` so the nth hit needs no
                  // second kind of walk: it accepts only when the running count
                  // reaches `index`, and `firstMatch` stops there as usual.
                  var seen = 0
                  return firstMatch(in: windows, maxDepth: 40, children: axChildren,
                                    matches: {
                                        guard axRole($0) == role else { return false }
                                        seen += 1
                                        return seen == index
                                    })
              }).first
        else { return .noTextInput }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Best effort: a field that won't report its value or take a range still
        // gets typed into, it just leaves the caller's before/after diff to cope.
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &valueRef) == .success,
           let existing = valueRef as? String {
            var end = CFRange(location: (existing as NSString).length, length: 0)
            if let range = AXValueCreate(.cfRange, &end) {
                AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, range)
            }
        }
        // Poll, don't ask once. Setting AXFocused on a Chromium node hands the
        // request to the renderer process and returns success immediately, so a
        // read on the next line still says false and a perfectly good field is
        // reported `.refused` — measured against Cursor, where the set succeeds,
        // and app- and system-level focus both agree a beat later. AppKit apps
        // answer on the first poll, so this costs them nothing.
        for _ in 0..<20 {
            if isFocused(field, of: appEl) { return .focused }
            usleep(50_000)
        }
        return .refused
    }

    /// The focused field's full text, cursor position and selection length (both
    /// UTF-16), when AX exposes them. nil means "can't see inside the field".
    /// The length matters: a non-empty selection makes the position a selection
    /// anchor, not a caret — see `canErase`.
    static func focusedFieldState() -> (text: NSString, cursor: Int, selLength: Int)? {
        guard let element = focusedElement() else { return nil }
        return fieldState(of: element)
    }

    /// Same read against an element the caller already resolved — so a sequence
    /// of reads and a write all act on ONE element rather than re-querying focus
    /// between them and possibly landing on a different one.
    static func fieldState(of element: AXUIElement) -> (text: NSString, cursor: Int, selLength: Int)? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return (text as NSString, range.location, range.length)
    }

    /// The focused element's current selection via AX. nil when there's no
    /// selection, it's empty, or the field is AX-opaque — the caller treats all
    /// three the same (refuse to transform). Read once at command fn-down.
    /// Full text of the focused field, or nil when AX won't say. Public for
    /// `parla-insert-check`, which types a known string and reads it back —
    /// the one property of the 200-unit chunk that no unit test can reach,
    /// because dropped characters are the target app's behaviour, not ours.
    public static func focusedFieldText() -> String? {
        focusedFieldState().map { $0.text as String }
    }

    public static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    /// True when the characters immediately before the cursor are exactly
    /// `typed` — i.e. erasing that many keystrokes removes only our own text.
    /// False when the field is opaque to AX, or a live selection would swallow
    /// the first Delete (can't verify ⇒ don't erase).
    public static func canEraseTyped(_ typed: String) -> Bool {
        guard !typed.isEmpty else { return true } // nothing to erase, no AX call needed
        guard let (text, cursor, selLength) = focusedFieldState() else { return false }
        return canErase(text: text, cursor: cursor, selLength: selLength, typed: typed)
    }

    /// Pure decision behind `canEraseTyped`, split out for testability.
    static func canErase(text: NSString, cursor: Int, selLength: Int, typed: String) -> Bool {
        let len = (typed as NSString).length
        guard len > 0 else { return true }
        // With a live selection, `cursor` is the selection's anchor, not a caret:
        // the first Delete wipes the whole selection — text the user made, not
        // ours — and the run then stops a character short of our own. Can't
        // verify what the keystroke will hit ⇒ don't erase.
        guard selLength == 0 else { return false }
        guard cursor >= len, cursor <= text.length else { return false }
        return text.substring(with: NSRange(location: cursor - len, length: len)) == typed
    }

    /// Swap the tail of the focused field in ONE atomic AX write: verify the
    /// field still ends with `current`, set the whole value to
    /// prefix + `replacement` + whatever followed the cursor, and put the caret
    /// back after the replacement.
    ///
    /// This exists to replace "post N backspaces, then type the new text", which
    /// was both slow and unsound. Slow: the raw→cleaned diff is prefix-only, so
    /// any change to the first word — a dropped leading filler, a capitalisation
    /// — makes N the entire transcript, and a 600-character dictation was erased
    /// one character at a time over ~3 seconds before being retyped. Unsound:
    /// canEraseTyped is a single point-in-time check, so a character the user
    /// physically typed during that burst was eaten by the remaining
    /// backspaces, breaking the "Parla cannot delete text it didn't write"
    /// guarantee. One atomic write has no window to race and nothing to watch.
    ///
    /// Returns false when AX cannot see the field, cannot prove our text is
    /// still at the cursor, cannot set the value, or when the write did not
    /// actually take — so the caller can fall back rather than report a success
    /// that never happened.
    public static func replaceTypedTail(_ current: String, with replacement: String) -> Bool {
        guard let element = focusedElement(),
              let (text, cursor, _) = fieldState(of: element) else { return false }
        let len = (current as NSString).length
        guard len > 0, cursor >= len, cursor <= text.length,
              text.substring(with: NSRange(location: cursor - len, length: len)) == current
        else { return false }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }

        let head = text.substring(to: cursor - len)
        let rest = text.substring(from: cursor)
        let updated = head + replacement + rest
        guard AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, updated as CFString) == .success else { return false }

        // Read back. An app may accept the write and ignore it — controlled
        // inputs in web and Electron views do exactly that — and reporting
        // success then would leave the raw text sitting under a "✓ Pasted".
        guard let after = fieldState(of: element), after.text.isEqual(to: updated) else { return false }

        var caret = CFRange(location: (head as NSString).length + (replacement as NSString).length, length: 0)
        if let pos = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, pos)
        }
        return true
    }

    /// True when final replacement can be verified via AX. Fields that merely
    /// look editable but hide text/cursor state should get one final insert, not
    /// live streaming that later can't be verified.
    public static func canVerifyFocusedField() -> Bool {
        focusedFieldState() != nil
    }

    /// Center of the focused AX element, converted to AppKit's bottom-left-origin
    /// screen space — for picking which NSScreen to show UI on. nil when AX can't
    /// report position/size (no focus, opaque element, permission denied).
    public static func focusedElementScreenPoint() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return axCenterToAppKit(origin: pos, size: size, primaryScreenHeight: primaryHeight)
    }

    /// Pure coordinate math, split out for testability: AX reports top-left-origin
    /// global coordinates anchored to the primary (menu-bar) screen; AppKit wants
    /// bottom-left-origin — flip through that screen's height.
    static func axCenterToAppKit(origin: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> NSPoint {
        NSPoint(x: origin.x + size.width / 2, y: primaryScreenHeight - (origin.y + size.height / 2))
    }

}
