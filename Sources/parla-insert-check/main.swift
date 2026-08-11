import AppKit
import ParlaCore

// parla-insert-check: the automated half of the Tier 0 #8 insertion smoke test.
//
//   swift run parla-insert-check                 # TextEdit
//   swift run parla-insert-check com.apple.Terminal
//   swift run parla-insert-check com.tinyspeck.slackmacgap
//
// WHY THIS EXISTS. Raising the typing chunk from 20 to 200 UTF-16 units is the
// one change in the whole backlog whose failure mode unit tests cannot reach:
// `chunkUTF16` is pure and well covered, but whether a *real* app drops
// characters, reorders them, or frames each burst as a separate paste is a
// property of that app's event handling, not of our arithmetic. ISSUES.md 5-7 is
// a history of exactly those bugs. This replaces "dictate into three apps and
// eyeball it" with one command that types known strings and reads the field back.
//
// WHAT IT CANNOT DO. It needs Accessibility, same as Parla — synthetic CGEvents
// are silently discarded without it, which would make every case "fail" for the
// wrong reason. It checks that first and refuses rather than reporting nonsense.
// Apps with no AX text value (some Electron builds) can be typed into but not
// read back; those are reported as SKIP, not PASS. A skip is not a pass.
// It focuses the target's text field itself (AX, same grant), so a run needs
// nobody at the keyboard; only an app that exposes no text field at all still
// asks for a click.

let bundleID = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "com.apple.TextEdit"

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(code)
}

// Hard watchdog. Every AX element this tool touches gets a messaging timeout,
// but "bounded everywhere I know about" is not the same as "cannot hang" — an
// unresponsive target hung this for ten minutes, and per-element timeouts did
// not stop it. A diagnostic that hangs is strictly worse than one that fails:
// nobody can tell a wedged check from a slow one, and CI just sits there. This
// is the only guarantee that does not depend on having found every blocking
// call, so it exists even though the timeouts should make it unreachable.
let watchdog = Thread {
    Thread.sleep(forTimeInterval: 90)
    FileHandle.standardError.write(Data("""
        error: timed out after 90s — the target's AX bridge is not answering.
        Nothing was verified; do NOT read this as a pass.
        \n
        """.utf8))
    exit(4)
}
watchdog.stackSize = 1 << 16
watchdog.start()

guard AXIsProcessTrusted() else {
    die("""
        no Accessibility permission — every keystroke would be silently dropped
        and every case would fail for the wrong reason.

        `swift run` builds an unsigned binary in .build, and macOS grants
        Accessibility per binary, so you must add THIS path:
          System Settings > Privacy & Security > Accessibility > +
          \(Bundle.main.executablePath ?? ".build/debug/parla-insert-check")
        Re-run after granting. Rebuilding changes the binary, so a rebuild may
        require re-granting — that is the same stable-signing problem ISSUES.md #4
        describes for the app itself.
        """, 2)
}

/// Each case is a real hazard, not a random string.
let cases: [(name: String, text: String)] = [
    // The regression this whole item is about: at 20 units this was 30 bursts,
    // and terminals framed each one as its own paste.
    ("600-char single line", String(repeating: "the quick brown fox jumps over it. ", count: 18)),
    // Newlines are the dangerous payload in a terminal — each one submits.
    ("multi-line", "first line\nsecond line\nthird line"),
    // Surrogate pairs must never be split across a chunk boundary; at 200 units
    // this lands one emoji astride the seam.
    ("emoji astride the boundary", String(repeating: "x", count: 199) + "😀😀 tail"),
    // Combining marks and RTL: length in UTF-16 units is not length on screen.
    ("combining + RTL", "café naïve — العربية — e\u{0301}"),
    // Exactly one unit over a chunk, the classic off-by-one.
    ("201 units", String(repeating: "a", count: 201)),
]

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap({ url -> NSRunningApplication? in
            let cfg = NSWorkspace.OpenConfiguration()
            let sem = DispatchSemaphore(value: 0)
            var opened: NSRunningApplication?
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { a, _ in opened = a; sem.signal() }
            _ = sem.wait(timeout: .now() + 10)
            return opened
        }) else {
    die("\(bundleID) is not running and could not be launched", 2)
}
app.activate()
Thread.sleep(forTimeInterval: 1.5) // let it come forward and take focus

// Bound every AX call. The default is a 6-second per-message timeout that an
// unresponsive bridge can hit on EVERY node of a tree walk — this hung for ten
// minutes against an app whose AX layer was not answering. A diagnostic tool
// that hangs is worse than one that fails, because nobody can tell which.
AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(app.processIdentifier), 2.0)
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

print("parla-insert-check: \(bundleID) (pid \(app.processIdentifier))")

// Take focus the way an assistive client may: find the app's first text area and
// focus it. Waiting for a human to click was the reason this check never ran —
// from a shell the focused element stays the calling terminal, so every case
// reported "focused, but AX exposes no text value" and skipped.
var grab = Inserter.focusFirstTextInput(pid: app.processIdentifier)
if grab == .noTextInput, bundleID == "com.apple.TextEdit" {
    // TextEdit with no open document has no text area in any window. Hand it a
    // scratch file — the reference target has to work with no setup at all.
    // Unique per run so the document opens empty: reusing a path we typed into
    // before would reopen it with the old content and a restored caret.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("parla-insert-check-\(Int(Date().timeIntervalSince1970)).txt")
    if (try? Data().write(to: scratch)) != nil,
       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([scratch], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        Thread.sleep(forTimeInterval: 1.5) // the window has to exist before the walk can see it
        grab = Inserter.focusFirstTextInput(pid: app.processIdentifier)
    }
}

/// Set when a field was found but would not take focus: every case then skips.
var focusRefusal: String?
switch grab {
case .focused:
    print("Focused a text field in \(bundleID) via AX — no clicking needed.")
case .noTextInput:
    // Distinguish "this app genuinely exposes nothing typeable" from "the AX
    // bridge isn't answering for this process at all" — they look identical from
    // the walk and need completely different responses. CoreGraphics can see
    // on-screen windows without Accessibility, so if CG sees windows and AX sees
    // none, the tree is not empty, it is unreachable.
    let cgWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
        }.count
    var axWindows: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                  kAXWindowsAttribute as CFString, &axWindows)
    let axRoles = Set(((axWindows as? [AXUIElement]) ?? []).map { el -> String in
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        return r as? String ?? "?"
    })
    if cgWindows > 0, !axRoles.contains(kAXWindowRole as String) {
        die("""
            AX cannot reach \(bundleID)'s windows from this process.
            CoreGraphics sees \(cgWindows) on-screen window(s); AX returns \
            \(axRoles.isEmpty ? "none" : "elements with role(s) \(axRoles.sorted())") \
            instead of AXWindow, which is what a degenerate/unreachable tree looks like.
            AXIsProcessTrusted() is true, so the grant is recorded — but the bridge is
            not answering. That happens when the running binary is not the one actually
            granted (a rebuild changes it), or under a non-interactive/remote session.
            Run this from a normal Terminal in a logged-in GUI session, granting
            Accessibility to the exact binary path printed above.
            """, 2)
    }
    // Genuinely nothing typeable — Electron apps expose none until an assistive
    // client wakes them, and some never do. Fall back and ask for the one thing
    // only a human can do.
    print("No AX text field found in \(bundleID). Click into an empty text field there now — typing starts in 3s.")
    Thread.sleep(forTimeInterval: 3)
case .refused:
    // Found the field, focus did not take. Typing now would land in whatever is
    // frontmost — possibly the user's real work — so type nothing.
    focusRefusal = "a text field in \(bundleID) refused focus; typing would land somewhere unverified"
}

var failed = false, skipped = 0
for c in cases {
    if let focusRefusal {
        print("SKIP \(c.name) — \(focusRefusal)")
        skipped += 1
        continue
    }
    guard Inserter.focusTarget() != .secure else {
        die("focus is a secure field or secure input is held — nothing can be typed", 2)
    }
    // Read the field before and after so pre-existing content doesn't count
    // against us; that is also how Inserter itself verifies before erasing.
    let before = Inserter.focusedFieldText() ?? ""
    Inserter.typeUnicode(c.text)
    Thread.sleep(forTimeInterval: 0.6) // let the app's event queue drain
    guard let after = Inserter.focusedFieldText() else {
        // Distinguish the two very different reasons, because they need
        // different actions: nothing focused (click into a field) versus a
        // focused field AX won't read (point at a different app).
        let why = Inserter.focusTarget() == .none
            ? "nothing is focused — click into a text field in \(bundleID) first"
            : "focused, but AX exposes no text value for this field"
        print("SKIP \(c.name) — \(why)")
        skipped += 1
        continue
    }
    let landed = String(after.dropFirst(before.count))
    if landed == c.text {
        print("PASS \(c.name) (\(c.text.utf16.count) units)")
    } else {
        failed = true
        print("FAIL \(c.name)")
        print("  expected \(c.text.utf16.count) units: \(c.text.prefix(60))…")
        print("  landed   \(landed.utf16.count) units: \(landed.prefix(60))…")
        if landed.count < c.text.count { print("  -> characters were DROPPED") }
    }
    Inserter.typeUnicode("\n\n")
}

if skipped == cases.count {
    print("\nAll cases skipped: nothing was verified. Point this at an app whose "
        + "field exposes an AX value (TextEdit, Terminal, Notes) to get a real result.")
    exit(3)
}
print(failed ? "\nFAILED — do not ship the 200-unit chunk against \(bundleID)"
             : "\nOK — \(cases.count - skipped)/\(cases.count) verified against \(bundleID)")
exit(failed ? 1 : 0)
