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

let bundleID = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "com.apple.TextEdit"

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(code)
}

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

print("parla-insert-check: \(bundleID) (pid \(app.processIdentifier))")
print("Click into an empty text field in that app now — typing starts in 3s.")
Thread.sleep(forTimeInterval: 3)

var failed = false, skipped = 0
for c in cases {
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
