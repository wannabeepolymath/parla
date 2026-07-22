import AppKit

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
    static func chunkUTF16(_ units: [UInt16], max: Int = 20) -> [[UInt16]] {
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
    /// Chunked because CGEventKeyboardSetUnicodeString caps around 20 UTF-16 units.
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
            usleep(5_000)
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
    public enum FocusTarget {
        case editable   // confirmed text field: safe to live-type into
        case unknown    // something is focused but AX can't confirm it's a field: paste, don't stream
        case none       // no focused element at all: history only, nothing typed
        case secure     // password field (AXSecureTextField): refuse the dictation entirely
    }

    /// Best-effort focus classification. Chromium/Electron apps (Chrome, VS Code,
    /// Slack…) expose no AX tree until an assistive client flips their
    /// accessibility flags, so on a non-editable answer we flip them and retry
    /// once. First dictation in such an app may still classify as .unknown
    /// (paste fallback); subsequent ones see the real field.
    public static func focusTarget() -> FocusTarget {
        var result = classifyFocus()
        // Never wake Electron's AX tree for a secure field — the whole point is
        // to touch it as little as possible (never stream, never type, never cloud).
        if result != .editable, result != .secure, let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(50_000) // give the app a beat to build its AX tree
            result = classifyFocus()
        }
        return result
    }

    /// Focused element via the system-wide query, falling back to asking the
    /// frontmost app directly — Electron/Chromium apps often answer only the
    /// app-level query. Parla's own UI is never a target: if the system query
    /// lands on us (the pill panel can hold system focus after a click), fall
    /// through to the frontmost app, where the user's field still lives.
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused {
            let element = focused as! AXUIElement
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) != .success || pid != getpid() {
                return element
            }
        }
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

    /// The focused field's full text and cursor position (UTF-16 offset), when
    /// AX exposes both. nil means "can't see inside the field".
    static func focusedFieldState() -> (text: NSString, cursor: Int)? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return (text as NSString, range.location)
    }

    /// A selection captured for a transform/polish: the text plus the AX
    /// element it came from, so insert-time verification can require the SAME
    /// field — two fields can hold identical text, and textual equality alone
    /// would type into the wrong one.
    public struct CapturedSelection {
        public let text: String
        let element: AXUIElement
        /// Selection range at capture (UTF-16), when the field exposes it —
        /// nil for AX-opaque fields. Distinguishes the selected occurrence
        /// when identical text appears elsewhere in the same field.
        let range: CFRange?
    }

    /// The focused element's current selection via AX, with the element it
    /// came from. nil when there's no selection, it's empty, or the field is
    /// AX-opaque — the caller treats all three the same (refuse to transform).
    /// Read once at trigger time (command fn-down / polish click).
    public static func captureSelection() -> CapturedSelection? {
        guard let element = focusedElement() else {
            NSLog("Parla captureSelection: no focused element (front=%@)",
                  NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")
            return nil
        }
        guard let text = selectedText(of: element) else {
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            NSLog("Parla captureSelection: empty (role=%@ front=%@)",
                  (roleRef as? String) ?? "?",
                  NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")
            return nil
        }
        return CapturedSelection(text: text, element: element, range: selectedRange(of: element))
    }

    /// True when the SAME element is still focused and the SAME occurrence is
    /// still selected (text and, where exposed, range) — required before
    /// typing over it. AXUIElement equality (CFEqual) compares pid + element
    /// token, not pointer identity.
    public static func selectionIntact(_ captured: CapturedSelection) -> Bool {
        guard let element = focusedElement(), CFEqual(element, captured.element) else { return false }
        guard selectedText(of: element) == captured.text else { return false }
        // Same text at a DIFFERENT range means the user reselected an identical
        // occurrence elsewhere — not the one the edit was made for. A field
        // that stopped (or never started) exposing the range compares nil==nil.
        let range = selectedRange(of: element)
        return range?.location == captured.range?.location
            && range?.length == captured.range?.length
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// True when the characters immediately before the cursor are exactly
    /// `typed` — i.e. erasing that many keystrokes removes only our own text.
    /// False when the field is opaque to AX (can't verify ⇒ don't erase).
    public static func canEraseTyped(_ typed: String) -> Bool {
        guard !typed.isEmpty else { return true }
        guard let (text, cursor) = focusedFieldState() else { return false }
        let len = (typed as NSString).length
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
