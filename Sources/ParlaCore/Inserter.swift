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
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &sel) == .success {
            return .editable
        }
        return .unknown
    }

    /// The focused field's full text, cursor position and selection length (both
    /// UTF-16), when AX exposes them. nil means "can't see inside the field".
    /// The length matters: a non-empty selection makes the position a selection
    /// anchor, not a caret — see `canErase`.
    static func focusedFieldState() -> (text: NSString, cursor: Int, selLength: Int)? {
        guard let element = focusedElement() else { return nil }
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
