import AppKit

// MARK: - Bindings

/// A physical key plus the EXACT set of modifiers that must be held.
///
/// Exact is the whole point. The old test was `keyCode == 9, cmd, ctrl` — a
/// superset match, so ⌃⌘V also fired (and was swallowed) on ⌃⌘⇧V, stealing a
/// chord that belonged to the front app. Keys are physical keycodes, so a
/// binding follows the key's position rather than the current layout.
public struct KeyChord: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let cmd = Modifiers(rawValue: 1 << 0)
        public static let ctrl = Modifiers(rawValue: 1 << 1)
        public static let opt = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
        /// macOS also sets this on arrows, Home/End/Page and the F-keys with no
        /// fn physically held — `KeyChord.normalized` drops it on exactly those
        /// keys so a hand-written chord can still equal a recorded one.
        public static let fn = Modifiers(rawValue: 1 << 4)

        public init(_ flags: NSEvent.ModifierFlags) {
            var m: Modifiers = []
            if flags.contains(.command) { m.insert(.cmd) }
            if flags.contains(.control) { m.insert(.ctrl) }
            if flags.contains(.option) { m.insert(.opt) }
            if flags.contains(.shift) { m.insert(.shift) }
            if flags.contains(.function) { m.insert(.fn) }
            self = m
        }

        public init(_ flags: CGEventFlags) {
            var m: Modifiers = []
            if flags.contains(.maskCommand) { m.insert(.cmd) }
            if flags.contains(.maskControl) { m.insert(.ctrl) }
            if flags.contains(.maskAlternate) { m.insert(.opt) }
            if flags.contains(.maskShift) { m.insert(.shift) }
            if flags.contains(.maskSecondaryFn) { m.insert(.fn) }
            self = m
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(_ keyCode: UInt16, _ modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = Self.normalized(keyCode, modifiers)
    }

    /// Exact modifier equality — see the type doc. Both sides must be normalized
    /// (chords are, at init; `HotkeyMonitor.keyDown` normalizes the event once).
    public func matches(_ keyCode: UInt16, _ modifiers: Modifiers) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }

    /// Keycodes macOS decorates with the fn bit on its own, nothing held.
    /// Deliberately NOT 63: there fn is the key, not a decoration.
    static let fnDecorated: Set<UInt16> = [
        115, 116, 117, 119, 121, 123, 124, 125, 126,             // Home/Page/FwdDel/End/arrows
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                      // F13–F20
    ]

    /// Drops the fn bit macOS adds by itself. Without it a hand-written
    /// "ctrl+cmd+down" (no fn) and the key event (fn set) never converge, so
    /// every arrow / Home / End / Page / F-key chord in settings.json is dead.
    public static func normalized(_ keyCode: UInt16, _ modifiers: Modifiers) -> Modifiers {
        fnDecorated.contains(keyCode) ? modifiers.subtracting(.fn) : modifiers
    }

    /// The modifier a modifier key carries, nil for ordinary keys. Caps lock is
    /// deliberately absent: it latches instead of being held.
    public static func modifierKey(_ keyCode: UInt16) -> Modifiers? {
        switch keyCode {
        case 63: return .fn
        case 56, 60: return .shift
        case 59, 62: return .ctrl
        case 58, 61: return .opt
        case 54, 55: return .cmd
        default: return nil
        }
    }

    /// US-ANSI labels for the physical positions, used for the Hub pill and for
    /// settings.json. Display only — matching never looks at a character.
    static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        115: "Home", 116: "PageUp", 117: "FwdDelete", 119: "End", 121: "PageDown",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        54: "RightCmd", 55: "Cmd", 56: "Shift", 58: "Option", 59: "Control",
        60: "RightShift", 61: "RightOption", 62: "RightControl", 63: "fn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let codes: [String: UInt16] = Dictionary(
        names.map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

    /// Modifiers in Apple's order, then the key: "⌃ ⌘ V".
    public var display: String {
        (symbols(fn: "fn", ctrl: "⌃", opt: "⌥", shift: "⇧", cmd: "⌘")
            + [Self.names[keyCode] ?? "key \(keyCode)"]).joined(separator: " ")
    }

    private func symbols(fn: String, ctrl: String, opt: String, shift: String,
                         cmd: String) -> [String] {
        var out: [String] = []
        if modifiers.contains(.fn) { out.append(fn) }
        if modifiers.contains(.ctrl) { out.append(ctrl) }
        if modifiers.contains(.opt) { out.append(opt) }
        if modifiers.contains(.shift) { out.append(shift) }
        if modifiers.contains(.cmd) { out.append(cmd) }
        return out
    }
}

extension KeyChord: Codable {
    /// settings.json stores "ctrl+cmd+v", not a keycode: hand-editable, and it
    /// round-trips through the same table the Hub shows. The LAST token is the
    /// key, which is what disambiguates "fn" (push-to-talk) from "fn+space".
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let parts = text.lowercased().split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let keyCode = Self.codes[key] ?? UInt16(key) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown key in \"\(text)\"")
        }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.cmd)
            case "ctrl", "control": mods.insert(.ctrl)
            case "opt", "option", "alt": mods.insert(.opt)
            case "shift": mods.insert(.shift)
            case "fn", "globe": mods.insert(.fn)
            default:
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unknown modifier \"\(part)\" in \"\(text)\"")
            }
        }
        self.init(keyCode, mods)
    }

    public func encode(to encoder: Encoder) throws {
        let parts = symbols(fn: "fn", ctrl: "ctrl", opt: "opt", shift: "shift", cmd: "cmd")
            + [Self.names[keyCode]?.lowercased() ?? "\(keyCode)"]
        var c = encoder.singleValueContainer()
        try c.encode(parts.joined(separator: "+"))
    }
}

/// The rebindable set. Esc (cancel/dismiss) and shift (command mode) are not in
/// here: both are pressed *with* another binding, so rebinding them only buys
/// collisions.
public struct HotkeyBindings: Codable, Equatable, Sendable {
    /// Held. Must be a modifier key — an ordinary key held down autorepeats
    /// characters into whatever has focus.
    public var pushToTalk = KeyChord(63)                        // fn
    public var handsFree = KeyChord(49, .fn)                    // fn+Space
    public var pasteLast = KeyChord(9, [.ctrl, .cmd])           // ⌃⌘V
    public var openScratchpad = KeyChord(1, [.ctrl, .cmd])      // ⌃⌘S
    public init() {}

    // Tolerant decode, same rule as CleanupSettings: one unparseable chord must
    // not throw and reset all of Settings. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func chord(_ key: CodingKeys, _ fallback: KeyChord) -> KeyChord {
            ((try? c.decodeIfPresent(KeyChord.self, forKey: key)) ?? nil) ?? fallback
        }
        pushToTalk = chord(.pushToTalk, pushToTalk)
        handsFree = chord(.handsFree, handsFree)
        pasteLast = chord(.pasteLast, pasteLast)
        openScratchpad = chord(.openScratchpad, openScratchpad)
    }

    private var named: [(String, KeyChord)] {
        [("hands-free", handsFree), ("paste last", pasteLast), ("open Scratchpad", openScratchpad)]
    }

    /// nil when the set is usable, else why it isn't — a sentence fragment for
    /// the Hub banner. Every rule here is a way to make Parla unreachable from
    /// the keyboard, so the Hub refuses the binding and a hand-edited
    /// settings.json falls back to the defaults instead of bricking dictation.
    public func problem() -> String? {
        guard let trigger = KeyChord.modifierKey(pushToTalk.keyCode), pushToTalk.modifiers.isEmpty else {
            return "push to talk must be a modifier key held on its own — fn, control, option or command"
        }
        if trigger == .shift {
            return "shift is reserved — holding it at push-to-talk starts command mode"
        }
        for (name, chord) in named {
            if KeyChord.modifierKey(chord.keyCode) != nil {
                return "\(name) needs a real key: a modifier on its own never sends a key press"
            }
            if chord.keyCode == 53 { return "\(name) can't be Esc — Esc always cancels" }
        }
        // An fn-decorated key carries fn without spelling it (`KeyChord.normalized`
        // strips the bit), so it reaches an fn trigger anyway.
        if !handsFree.modifiers.contains(trigger),
           !(trigger == .fn && KeyChord.fnDecorated.contains(handsFree.keyCode)) {
            return "hands-free is pressed while holding push to talk, so it must include \(pushToTalk.display)"
        }
        for (name, chord) in named.dropFirst() {  // the two idle chords
            if chord.modifiers.isEmpty {
                return "\(name) needs at least one modifier, or it fires while you type"
            }
            if chord.modifiers.contains(trigger) {
                return "\(name) can't use \(pushToTalk.display) — holding it starts dictation"
            }
        }
        for (i, a) in named.enumerated() {
            for b in named.dropFirst(i + 1) where a.1 == b.1 {
                return "\(a.0) and \(b.0) are the same shortcut"
            }
        }
        return nil
    }
}

// MARK: - Monitor

/// Global dictation hotkeys, all rebindable (`HotkeyBindings`). By default the
/// fn/Globe key held is push-to-talk; fn+Space latches hands-free (the trigger,
/// Space, or Return stops it); Esc cancels a dictation or dismisses the HUD
/// toast; ⌃⌘V pastes the last transcript and ⌃⌘S opens the scratchpad.
///
/// A CGEventTap (same Accessibility permission) replaced the old NSEvent
/// global monitors: fn+Space / Esc / ⌃⌘V must be swallowed, not leak a space
/// or an Esc into the front app. Other cancelling keys still pass through.
public final class HotkeyMonitor {
    public enum Edge: Equatable {
        /// Recording starts. command is true when shift was held at fn-down:
        /// that dictation is a transform-selection instruction, not plain
        /// dictation. The mode is latched here, so shift may be released
        /// while speaking.
        case down(command: Bool)
        /// Recording ends → transcribe. short is true when the session lasted
        /// under `shortTapThreshold` (an accidental Globe tap, not dictation).
        case up(short: Bool)
        /// Dictation aborted: Esc, or any real key while fn was held.
        case cancel
        /// fn+Space latched hands-free: recording continues past fn release.
        case handsFree
        /// ⌃⌘V while idle: paste the last transcript.
        case pasteLast
        /// ⌃⌘S while idle: open the scratchpad.
        case openScratchpad
        /// Esc while idle: dismiss the HUD toast.
        case dismiss
    }
    /// Called on the main thread once `start()` has run (see `emit`).
    public var onEdge: ((Edge) -> Void)?
    /// Sessions shorter than this are treated as accidental (see Edge.up).
    public var shortTapThreshold: TimeInterval = 0.2
    /// Live bindings. Re-read from settings.json per event rather than pushed in
    /// from main: `SettingsStore.load()` is one stat() in the steady state, and
    /// this way a rebind in the Hub takes effect without a restart.
    public var bindings = HotkeyBindings()
    /// Raised by the Hub while it records a new binding — without it the tap
    /// swallows the very chords being re-recorded (⌃⌘V, fn+Space) and they
    /// never reach the Hub window. Written on main, read on the tap thread.
    public static var suspended: Bool {
        get { suspendedLock.lock(); defer { suspendedLock.unlock() }; return suspendedFlag }
        set { suspendedLock.lock(); suspendedFlag = newValue; suspendedLock.unlock() }
    }
    private static let suspendedLock = NSLock()
    private static var suspendedFlag = false

    /// Guards everything below. The machine runs on the tap thread; the
    /// watchdog and `endSession` reach it from main. Recursive because
    /// `ensureAlive` re-enters through `start()`. Never held across `onEdge`.
    private let lock = NSRecursiveLock()
    /// Edges decided on the tap thread that main has not run yet.
    private var undelivered = 0
    /// Set by `start()`. Off, edges fire synchronously — which is what lets the
    /// tests drive the machine without a run loop.
    var deliversOnMain = false

    private enum Session { case idle, push, handsFree }
    private var session = Session.idle
    /// The keyCode whose press started the current session. The flag bit alone
    /// can't say which physical key moved (twins share it); this is what lets a
    /// later down of the SAME key read as proof its release was missed.
    private var downKeyCode: UInt16 = 0
    /// Key-level HID state (`CGEventSource.keyState`) — per physical key, unlike
    /// the shared flag bit. Injectable so the tests can play both twins.
    var keyIsPhysicallyDown: (UInt16) -> Bool = {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0))
    }
    /// The trigger's flag bit as of the last flagsChanged on one of its keys.
    /// `session` alone can't tell a latch chord that is the tail of the press
    /// which just stopped a session from the front app's own chord.
    private var triggerHeld = false
    /// Whether the HID flags agreed with the trigger-down that began the current
    /// press. Only then are they trusted to report its release — re-sampled per
    /// press, because a trigger can also arrive from a source the HID state
    /// never sees (Screen Sharing, a remapper).
    private var hidTracksTrigger = false
    private var downAt: TimeInterval = 0
    private var tap: CFMachPort?
    /// The tap thread's run loop, so a dead port's thread can be told to exit.
    private var tapRunLoop: CFRunLoop?
    private let store: SettingsStore
    private var loadedBindings: HotkeyBindings?
    /// keyCode of the last keyDown we swallowed, so its autorepeats can be
    /// swallowed too. nil once a keyDown passes through.
    private var lastSwallowedKeyCode: UInt16?
    /// Liveness poll for the tap — see ensureAlive().
    private var watchdog: Timer?
    /// App Nap opt-out, held for the process lifetime. Releasing it ends it.
    private var activity: NSObjectProtocol?
    /// How often to check that the tap is still alive. Read at the first
    /// startWatchdog() only; a test hook, not a live setting.
    public var watchdogInterval: TimeInterval = 5

    public init(store: SettingsStore = SettingsStore()) { self.store = store }

    // MARK: - Pure state machine (exercised by tests; `time` injected so tests never sleep)

    /// flagsChanged: a trigger press starts push-to-talk, its release finishes.
    /// During hands-free, any trigger press stops and transcribes — the
    /// guaranteed exit: it can't depend on the Space keyDown carrying the fn
    /// flag, and the release after latching must not finish early (session ≠ .push).
    public func handle(keyCode: UInt16, modifiers: KeyChord.Modifiers, at time: TimeInterval) {
        // Other modifiers arrive via flagsChanged too (shift is keyCode 56/60),
        // so this guard drops them — they can never double-fire .down. It
        // compares the modifier, not the keyCode: CGEventFlags has no left/right,
        // so the TWIN of the bound key sets the very bit `active` reads, and a
        // keyCode guard would watch for a release whose event never comes.
        guard let trigger = KeyChord.modifierKey(bindings.pushToTalk.keyCode),
              KeyChord.modifierKey(keyCode) == trigger else { return }
        let active = modifiers.contains(trigger)
        triggerHeld = active
        // The bound key DOWN again while its own session is live: the release
        // never reached us (tap disabled or deaf when it happened), and this
        // press is a new dictation — without a split the two finalize as one
        // transcript. This is reconcile's gap: its watchdog ticks every ~5 s,
        // and a re-press inside that window re-arms `triggerHeld`, so the tick
        // sees a held key and ends nothing. Twins can't land here — a twin's
        // press carries its own keyCode, and the bound key's release under a
        // twin-held bit reports physically up.
        if active, session == .push, keyCode == downKeyCode, keyIsPhysicallyDown(keyCode) {
            NSLog("Parla: trigger pressed again with no release seen, splitting the capture")
            session = .idle
            emit(.up(short: time - downAt < shortTapThreshold))
        }
        if active, session == .idle {
            session = .push
            downAt = time
            downKeyCode = keyCode
            emit(.down(command: modifiers.contains(.shift)))
        } else if active, session == .handsFree {
            session = .idle
            emit(.up(short: time - downAt < shortTapThreshold))
        } else if !active, session == .push {
            session = .idle
            emit(.up(short: time - downAt < shortTapThreshold))
        }
    }

    /// A release the tap never saw. The tap can be off at the moment the trigger
    /// comes up — disabled by macOS for a slow callback, deaf under secure input
    /// — and a push-to-talk session then has nothing left to end it: the mic
    /// stays open and the room is recorded until the next keystroke or the
    /// 10-minute cap. Called with the trigger's *physical* state whenever the
    /// tap is revived and on every watchdog tick; a held trigger is left alone.
    /// The missed release is replayed through `handle`, so hands-free — which is
    /// meant to outlive the release — only has its stale `triggerHeld` cleared.
    func reconcile(triggerDown: Bool, at time: TimeInterval) {
        guard triggerHeld, !triggerDown else { return }
        if session == .push { NSLog("Parla: missed the trigger release, ending the capture") }
        handle(keyCode: bindings.pushToTalk.keyCode, modifiers: [], at: time)
    }

    /// The capture ended without us: the 10-minute cap or a lost mic finalized
    /// it. Left latched, the monitor swallows the user's next Space, Return or
    /// Esc as the "stop" of a session that no longer exists, and the next
    /// trigger press is a no-op. `triggerHeld` is physical state and stays.
    ///
    /// Skipped while an edge is still queued for main: that edge is a press or a
    /// stop the app has not seen yet, and unlatching under it would leave the
    /// monitor idle beneath a session that is about to start recording.
    public func endSession() {
        lock.lock(); defer { lock.unlock() }
        guard undelivered == 0 else { return }
        session = .idle
    }

    /// Hand an edge to the app. From the tap thread that means a hop to main —
    /// `onEdge` runs the capture start, the AX probe and sometimes a model
    /// reload, none of which may run inside the tap callback. Order is the
    /// order of decision: main's queue is FIFO.
    private func emit(_ edge: Edge) {
        guard deliversOnMain else { onEdge?(edge); return }
        undelivered += 1
        DispatchQueue.main.async { [self] in
            onEdge?(edge)
            lock.lock(); undelivered -= 1; lock.unlock()
        }
    }

    /// keyDown. Returns true when the event must be swallowed (never reach the
    /// front app). `modifiers` are the key event's own flags; every chord matches
    /// them EXACTLY (see `KeyChord`) — hands-free tolerates shift, see below.
    public func keyDown(keyCode: UInt16, modifiers rawModifiers: KeyChord.Modifiers = [],
                        at time: TimeInterval) -> Bool {
        // Chords are stored normalized (`KeyChord.init`), so the event has to be
        // too or no arrow / Home / End / Page / F-key chord can ever match.
        let modifiers = KeyChord.normalized(keyCode, rawModifiers)
        // Hands-free is exact too, with ONE tolerance: SHIFT. Command mode is
        // entered by holding shift at push-to-talk, so the latch key arrives as
        // fn+shift+Space and exact would make the latch unreachable there; the
        // union runs both ways so a binding that itself contains shift still
        // matches without it. Anything wider steals chords that are not ours —
        // fn+⌘+Space (Spotlight) and fn+⌃+Space (input source) must cancel and
        // PASS THROUGH, not latch.
        if keyCode == bindings.handsFree.keyCode,
           modifiers.union(.shift) == bindings.handsFree.modifiers.union(.shift) {
            switch session {
            case .push: // convert the held push-to-talk: recording survives the trigger release
                session = .handsFree
                emit(.handsFree)
                return true
            case .handsFree: // trigger held since the latch, so the stop below never fired
                session = .idle
                emit(.up(short: time - downAt < shortTapThreshold))
                return true
            case .idle where triggerHeld:
                return true // the trigger press just stopped the session — swallow, no restart
            case .idle:
                // Nothing is recording and the trigger is not down, so this is
                // the front app's chord: fall through. The flags alone can't say
                // otherwise — the trigger's twin sets the same bit, and macOS
                // sets fn on arrows/Home/End/Page by itself.
                break
            }
        }
        // Modifier-blind on purpose, unlike the stop below: "Esc always cancels"
        // is the rule problem() enforces at :207, and an abort you have to press
        // bare is not an abort. The cost is that ⌘⌥Esc (Force Quit) and ⌥Esc are
        // swallowed once mid-dictation; the session is .idle afterwards, so the
        // second press goes through. Deliberate trade, not an oversight.
        if keyCode == 53, session != .idle { // Esc: cancel the dictation
            session = .idle
            emit(.cancel)
            return true
        }
        if session == .push { // any other key while the trigger is held cancels (and passes through)
            session = .idle
            emit(.cancel)
            return false
        }
        // The latch key or Return also stop hands-free once the trigger is
        // released — bare or shifted only, the sets that type whitespace, which
        // is the whole reason to swallow. With ⌘/⌃/⌥ the key is somebody else's
        // (⌘Space Spotlight, ⌃Space input source, ⌘Return send) and must reach
        // the front app while we keep recording.
        if session == .handsFree, keyCode == bindings.handsFree.keyCode || keyCode == 36,
           modifiers.subtracting(.shift).isEmpty {
            session = .idle
            emit(.up(short: time - downAt < shortTapThreshold))
            return true // swallow — a space/newline must not land in the field before the transcript
        }
        if session == .handsFree { return false } // other typing while hands-free is fine
        if bindings.pasteLast.matches(keyCode, modifiers) {
            emit(.pasteLast)
            return true
        }
        if bindings.openScratchpad.matches(keyCode, modifiers) {
            emit(.openScratchpad)
            return true
        }
        if keyCode == 53 { emit(.dismiss) } // Esc while idle: dismiss HUD toast, pass through
        return false
    }

    /// Pick up Hub rebinds. A hand-edited settings.json that would leave Parla
    /// unreachable is ignored in favour of the defaults — the Hub refuses the
    /// same sets up front, this is the file-edited path.
    /// Internal, not private: the tests drive this loading path directly.
    func refreshBindings() {
        let next = store.load().hotkeys
        guard next != loadedBindings else { return }
        loadedBindings = next
        bindings = next.problem() == nil ? next : HotkeyBindings()
    }

    // MARK: - Event tap

    public func start() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                // A bare thread's run loop drains no pool, and refreshBindings
                // makes Foundation objects on every key.
                autoreleasepool {
                    Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                        .process(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // No Accessibility permission yet (fresh install): keep retrying so
            // a grant starts working without an app restart.
            NSLog("Parla: keyboard event tap unavailable (Accessibility not granted?), retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            return
        }
        lock.lock()
        self.tap = tap
        deliversOnMain = true
        lock.unlock()
        // The tap gets a thread of its own. On the main run loop it held every
        // key the user typed, in any app, behind whatever main was doing — and a
        // trigger-down does the whole capture start there (device open, AX
        // probe, sometimes a model reload): long enough for macOS to disable the
        // tap and for the release to slip past it. Here the callback runs the
        // state machine and nothing else; `emit` carries the edges to main.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            if let self {
                self.lock.lock(); self.tapRunLoop = runLoop; self.lock.unlock()
            }
            CFRunLoopRun() // until ensureAlive stops it to replace a dead port
        }
        thread.name = "parla.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        // Parla is LSUIElement with no windows, which makes it a prime App Nap
        // target. A napped process gets its run loop throttled, the tap callback
        // misses its deadline, and macOS disables the tap for being slow — the
        // very thing the watchdog below then has to undo. Opt out.
        // AllowingIdleSystemSleep matters: plain .userInitiated would also keep
        // the Mac from sleeping, which a dictation app has no business doing.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "global dictation hotkey")
        }
        startWatchdog()
    }

    /// The tap's only other recovery path lives INSIDE the tap callback, so it
    /// can only run if macOS still delivers events to us — which is exactly what
    /// stops happening when the tap dies. Screen lock and secure input silence a
    /// session keyboard tap outright, and sleep/wake can leave it disabled with
    /// no notification we ever see. Without an external check the hotkey stays
    /// dead until the app is relaunched, which is the "left it alone for a while
    /// and fn stopped working" report.
    ///
    /// ponytail: a 5s poll of one WindowServer bool, not a set of wake/unlock/
    /// session observers — same recovery, a fraction of the surface. Add the
    /// notifications only if a 5s worst-case recovery ever feels slow.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.ensureAlive()
        }
        // .common so it keeps firing while a menu is open or a drag loop runs.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Re-enable a tap macOS turned off behind our back; recreate it if the port
    /// itself died. No-op in the normal case (one bool check).
    private func ensureAlive() {
        lock.lock(); defer { lock.unlock() }
        guard let tap else { return } // never created: start()'s own retry owns that
        // Every tick, not only after a revive: secure input deafens the tap
        // without ever disabling it, so "enabled" proves nothing about a release.
        defer { reconcileWithKeyboard() }
        guard CFMachPortIsValid(tap) else {
            NSLog("Parla: hotkey tap port went invalid, recreating")
            CFMachPortInvalidate(tap) // also drops the dead port's run-loop source
            self.tap = nil
            // Dropping its only source does not wake a run loop asleep in
            // mach_msg — stop it, or each dead port strands a thread.
            if let tapRunLoop { CFRunLoopStop(tapRunLoop) }
            tapRunLoop = nil
            start()
            return
        }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        NSLog("Parla: hotkey tap was found disabled, re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The trigger as the keyboard reports it, not as our bookkeeping remembers
    /// it — the bookkeeping is the thing under suspicion.
    private func triggerPhysicallyDown() -> Bool {
        guard let trigger = KeyChord.modifierKey(bindings.pushToTalk.keyCode) else { return false }
        return KeyChord.Modifiers(CGEventSource.flagsState(.hidSystemState)).contains(trigger)
    }

    /// `reconcile` against the real keyboard. Gated on `hidTracksTrigger`: a
    /// trigger that never shows up in the HID flags would otherwise have its
    /// dictation cut short at the next watchdog tick.
    private func reconcileWithKeyboard() {
        guard hidTracksTrigger else { return }
        // Nobody saw this release, so it has no honest timestamp. Far future
        // makes it never "short": the audio is transcribed, not thrown away.
        reconcile(triggerDown: triggerPhysicallyDown(), at: .greatestFiniteMagnitude)
    }

    /// The tap callback, on the tap thread. Everything here is bookkeeping —
    /// no I/O beyond one stat() and the HID flags, so it returns in microseconds.
    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Logged so a "the hotkey died" report can be traced to which
            // mechanism disabled it — this path, or the silent kind the
            // watchdog catches (see ensureAlive).
            NSLog("Parla: hotkey tap disabled by %@, re-enabling",
                  type == .tapDisabledByTimeout ? "timeout" : "user input")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) } // macOS disables slow taps; revive
            reconcileWithKeyboard() // a release during the outage went straight past us
            return pass
        case _ where Self.suspended: // the Hub is recording a binding — see `suspended`
            return pass
        case .flagsChanged:
            refreshBindings()
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = KeyChord.Modifiers(event.flags)
            // Sampled here, at the event: by the time main gets round to the
            // edge the key may already be up, and a release that then goes
            // missing is exactly the one reconcile needs this trust for.
            if let trigger = KeyChord.modifierKey(bindings.pushToTalk.keyCode),
               KeyChord.modifierKey(code) == trigger, modifiers.contains(trigger) {
                hidTracksTrigger = triggerPhysicallyDown()
            }
            handle(keyCode: code, modifiers: modifiers,
                   at: Double(event.timestamp) / 1_000_000_000)
            return pass
        case .keyDown:
            // Skip Parla's OWN synthetic keystrokes (typing/erasing while
            // streaming carries our marker — without this the tap would
            // self-cancel).
            guard event.getIntegerValueField(.eventSourceUserData) != Inserter.syntheticMarker
            else { return pass }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Autorepeat must not re-drive the state machine (a held space would
            // latch-then-stop hands-free on its repeats) — but it must still be
            // SWALLOWED when we swallowed the keystroke that began it. macOS
            // synthesizes repeats upstream of this tap regardless of whether the
            // initiating keyDown was consumed, so passing them through leaked the
            // very Return/Space we intercepted into the front app: holding Return
            // to stop hands-free sent whatever draft was already in the composer.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return code == lastSwallowedKeyCode ? nil : pass
            }
            refreshBindings()
            let swallow = keyDown(keyCode: code,
                                  modifiers: KeyChord.Modifiers(event.flags),
                                  at: Double(event.timestamp) / 1_000_000_000)
            lastSwallowedKeyCode = swallow ? code : nil
            return swallow ? nil : pass
        default:
            return pass
        }
    }

    deinit {
        watchdog?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap) // also invalidates the run-loop source
        }
    }
}
