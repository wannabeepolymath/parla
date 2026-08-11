# Review findings

Every finding from the four adversarial review rounds run over the audit-
implementation branch. Each was raised by one agent and then handed to a second
told to REFUTE it by default; only findings that survived that are listed as
confirmed. Several were proved by executing a temporary test. The refuted column
is kept deliberately — a review process that never rejects anything is not
reviewing.

**63 raised · 49 confirmed · 14 refuted.** Convergence 25 → 11 → 9 → 4, zero majors by round 4.

---

## Round 1 — the whole branch

Six dimensions over `git diff main...HEAD`: correctness, concurrency, safety, tests, simplification, regressions.

25 confirmed, 7 refuted.

### [MAJOR] Warp is never classified as a terminal — its real bundle ID is `dev.warp.Warp-Stable`

`Sources/ParlaCore/TextRules.swift:21` · dimension: correctness

**Defect.** `appCategories` is matched EXACTLY (deliberately — the comment at line 16-17
forbids substring matching), and the table key is `"dev.warp.Warp"`. Warp's
actual `CFBundleIdentifier` is `dev.warp.Warp-Stable` (verified on this machine:
`/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier"
/Applications/Warp.app/Contents/Info.plist` → `dev.warp.Warp-Stable`; the
preview channel is `dev.warp.Warp-Preview`). So `TextRules.category(bundleID:)`
returns `.unknown` for Warp: no `.terminal` tone hint is added to the cleanup
prompt, and `flattensNewlines(bundleID:)` returns false, so
`DictationSession.transcribed` (line 464) and `cleanReady` (line 538) skip
`flattenForTerminal`. `docs/research/05-insertion.md:256` records
`dev.warp.Warp` as covered (✅), so the gap is invisible from the docs too. Every
other ID in the table that I could check against an installed app is correct —
this is the only wrong one.

**Failure.** In Warp, hold fn and dictate "the list is: install deps, run the tests, then
push". Cleanup formats it as a list (the list rule in PromptBuilder fires
because no terminal tone hint was appended), producing "- install deps\n- run
the tests\n- then push". `flattensNewlines("dev.warp.Warp-Stable")` is false, so
the raw and cleaned inserts keep their newlines and `Inserter.typeUnicode` posts
them into the shell. Each newline submits, so Warp runs `- install deps` and `-
run the tests` as commands.

**Verification.** CONFIRMED, and proven with a temporary reducer-level test that failed 3/3 (since
deleted; no implementation was modified).  1. The lookup is exact-then-prefix,
and no prefix covers Warp. TextRules.swift:50-57: ```swift public static func
category(bundleID: String?) -> AppCategory {     guard let bundleID else {
return .unknown }     if let exact = appCategories[bundleID] { return exact }
for (prefix, category) in appCategoryPrefixes where bundleID.hasPrefix(prefix) {
return category }     return .unknown } ``` `appCategoryPrefixes` is only
`("com.microsoft.VSCode", .code)` and `("com.jetbrains.", .code)`. The table key
at line 21 is `"dev.warp.Warp": .terminal`, while the shipped app is
`dev.warp.Warp-Stable` (PlistBuddy on /Applications/Warp.app). I cross-checked
every table ID against installed apps — Xcode, Pages, Mail, Notes, Terminal,
TextEdit, Word, Ghostty, Slack, Cursor, Obsi

### [MAJOR] `AudioRecorder.prepare()` has no call site — the warm engine and pre-roll ring never run

`Sources/ParlaCore/AudioRecorder.swift:275` · dimension: correctness

**Defect.** `prepare()` is the only thing that sets `warm = true`, and `grep -rn "prepare"
Sources/ Tests/` finds zero call sites outside its own definition. With `warm`
permanently false: (a) `warmUp()` returns at its first guard (line 282), so no
engine is ever built outside `start()`; (b) `stop()` line 462 evaluates `!warm`
as true and unconditionally calls `teardown()`, so the engine is destroyed after
every dictation; (c) `route()` only writes to `preRoll` when `!capturing`, which
now only happens while the engine is torn down and no tap is installed — so
`PreRollRing` is always empty and `preRoll.take()` at line 417 always returns
`[]`; (d) `AudioRecorder.mediaPlaying()` at line 415 is guarded by
`engine.isRunning`, which is always false at that point, so it never runs; (e)
the idle-rebuild branch of `observeConfigChanges` (lines 349-353) and all of
`scheduleRebuild()` are unreachable. The whole warm-engine/pre-roll subsystem
plus its unit tests is dead at runtime, and `start()` still pays the full cold
open (240–270 ms built-in, 650–700 ms USB per docs/research/03-latency.md §1) on
every keypress.

**Failure.** Launch Parla, press fn. `applyPreferencesAndStartCapture` → `recorder.start()`:
`engine.isRunning` is false, so `mediaPlaying = false` and `preRoll.take(...)`
returns `[]` (the ring was never written to); the cold `build(device:)` runs
inline and blocks until `engine.start()` returns. Only then does
`.recorderStarted` fire the start chime — the cue the pre-roll was designed to
make instant is still hundreds of ms late, and `PreRollRing.prependSamples` of
speech onset is never prepended. Release fn: `stop()` tears the engine down, and
the next press repeats the whole cold open.

**Verification.** `prepare()` is the only writer of `warm`, and a repo-wide grep for `prepare()`
across every .swift (excluding .build and .claude/worktrees) returns exactly ONE
hit — the definition itself:      // AudioRecorder.swift:275     public func
prepare() {         warm = true         warmUp()     }  With `warm` permanently
false, two guards kill the whole subsystem:      // :282  warmUp() — never
builds anything     guard warm, !engine.isRunning else { return }      // :462
stop() — !warm is always true, so teardown() is unconditional     if !warm ||
AudioRecorder.isBluetooth(boundDevice) { teardown() }  The two call sites
FEATURES-TO-ADD.md #7 specifies ("build and bind at launch and on device-
change") both set only the UID and stop:      // main.swift:116,
applicationDidFinishLaunching     recorder.inputDeviceUID =
launchSettings.inputDeviceUID     // StatusMenu.swift:188, selectMicrophone

### [MAJOR] Onboarding tryout leaks the open mic and a permanently suspended hotkey tap

`Sources/Parla/Hub/Onboarding.swift:82` · dimension: concurrency

**Defect.** `tryoutStart()` (Onboarding.swift:251) takes two pieces of global state that
only `tryoutStop()` releases: it sets the process-wide `HotkeyMonitor.suspended
= true` (line 256, which makes the CGEventTap `return pass` on every event, i.e.
push-to-talk is dead app-wide) and it opens `AudioRecorder` outside the
dictation machine (line 258, so `capturingGen` stays 0 and no reducer path can
ever finalize it). The only teardown hooks are `advance()` (Skip/Continue) and
`.onDisappear(perform: endTryout)` at line 51. The `Back` button at line 82
mutates `step` directly with no teardown, and `onDisappear` cannot fire on a
window close either: `HubWindowController` sets `isReleasedWhenClosed = false`
(HubWindow.swift:69), keeps its `window` reference, and — unlike
`ScratchpadController`, which does implement `windowWillClose`
(Scratchpad.swift:53) — implements no close hook at all, so the `NSHostingView`
and its SwiftUI tree survive `orderOut` and `OnboardingView` is never removed
from the hierarchy. The comment at Onboarding.swift:230 ("The window can close
mid-recording; the mic must not stay open for it") states an invariant the code
does not hold.

**Failure.** Fresh install, onboarding step 3. Click Start (`recording = true`,
`HotkeyMonitor.suspended = true`, `recorder.start()` opens the mic). Click Back
— `step` goes to 1, `stepView` swaps to `modelStep`, `endTryout()` is never
called, `recording` stays true, and there is no longer a Stop control on screen.
Close the Hub window. The mic stays live and accumulating into
`AudioRecorder.samples` until the 10-minute `maxSamples` cap, and
`HotkeyMonitor.suspended` stays true for the rest of the process:
`HotkeyMonitor.process` hits `case _ where Self.suspended: return pass`
(Hotkey.swift:379) on every fn press, so holding fn never produces a `.down`
edge and dictation is dead until the app is relaunched.

**Verification.** Confirmed by reading and by a runnable probe. tryoutStart() takes two pieces of
global state — `HotkeyMonitor.suspended = true` (Onboarding.swift:256) and `try
recorder.start()` (258) — and only tryoutStop() releases them. The two teardown
hooks both miss:  (1) Back has no teardown: `Button("Back") { step -= 1 }`
(Onboarding.swift:82), no `.disabled` while recording. `.onDisappear(perform:
endTryout)` (Onboarding.swift:51) is attached to the ROOT VStack, not to
`tryout`, so the step 2→1 swap of `stepView` never fires it; `recording`/`step`
are @State on a view that is never re-created.  (2) Window close does not fire
onDisappear: `w.isReleasedWhenClosed = false` (HubWindow.swift:69),
HubWindowController retains `window`, and its NSWindowDelegate implements only
`windowDidBecomeKey` — no `windowWillClose` (contrast ScratchpadController,
Scratchpad.swift:53). I built a structural replica o

### [MAJOR] canEraseTyped verifies the text before the selection start but ignores selection length, so the first typeBackspaces deletes a live selection Parla did not write

`Sources/ParlaCore/Inserter.swift:196` · dimension: safety

**Defect.** focusedFieldState() (line 179) returns only `range.location` from
kAXSelectedTextRangeAttribute and throws `range.length` away. canEraseTyped
therefore proves "the UTF-16 immediately before offset P equals what we typed" —
which is satisfied whether P is a bare caret or the *start of a non-empty
selection*. Every consumer then posts raw Delete keystrokes
(Dictation.swift:138, 153, 459), and in any standard AppKit/Chromium text field
the first Delete with a non-empty selection deletes the whole selection, not one
character. So the erase run consumes foreign text first and then stops one
character short of removing Parla's own, breaking the headline invariant from
ISSUES.md #6. This is the live cleaned-swap path, not the disabled live-typing
path: `cleanReady` emits `.replaceTailIfOurs(expect: landed.insertText, erase:
plan.eraseTail.count, …)` (DictationSession.swift:561) on every ordinary
dictation that has cleanup configured, and the window between the raw landing
and the swap is the whole cleanup POST (up to the 15 s timeout in
Cleanup.swift:289). Note this code is unchanged from `main`, but the review
asked whether typeBackspaces can run without an adequate verify, and here the
verify does not cover the case it needs to.

**Failure.** User dictates "hello world" into a Notes/TextEdit field with cleanup configured.
`.insertText` types `hello world` and the polish POST goes out. While it is in
flight (~1-3 s) the user types " and more" and selects it with shift+Left ×9. AX
now reports value="hello world and more", selection range = (location: 11,
length: 9). Cleanup returns "Hello, world."; swapPlan gives eraseTail="hello
world" (11), replacement="Hello, world.". canEraseTyped("hello world") checks
text[0..<11] == "hello world" -> true, so the swap proceeds. typeBackspaces(11):
backspace #1 deletes the selected " and more" (the user's own text), backspaces
#2-11 delete "hello worl", leaving "h". typeUnicode then appends, and the field
ends as "hHello, world." — the user's nine characters are gone. The same shape
fires unattended in fields with inline autocompletion (Safari/Chrome omnibox,
NSSearchField), which park a selected completion starting exactly at the end of
what was typed.

**Verification.** Proved end-to-end with a temporary test against a real TextEdit document holding
a live 9-char user selection " and more" starting at offset 11 (selection set
via AX only, no keystrokes): `PROBE real focusedFieldState = "hello world and
more" cursor=11` / `PROBE real canEraseTyped("hello world") = 1`. The real
function approves the erase. Second half, on NSTextView and on an NSTextField
field editor at that same state: 11 `deleteBackward(nil)` calls (what Delete
routes to in AppKit) left `"h"` — the user's 9 characters destroyed, one of
Parla's own left behind. Both halves confirmed; test deleted.  Cited code says
exactly what the finding claims. Inserter.swift:179 `return (text as NSString,
range.location)` — `range.length` is read into the CFRange and dropped.
Inserter.swift:196-202: `guard cursor >= len, cursor <= text.length else {
return false }; return text.substring(with: NSRange(

### [MAJOR] Cleanup prompt no longer receives any app/tone context — category is always .unknown

`Sources/ParlaCore/Pipeline.swift:57` · dimension: regressions

**Defect.** On main, PromptBuilder.system appended "The text will be inserted into <app>.
Match the tone typical for that app (casual for chat, formal for email, plain
for code/terminals)." whenever context.appName was set, and main.swift always
set it (Pipeline(frontAppName: { appName })). The branch replaced that block
with a category-driven toneHint (Cleanup.swift:88 / :94) whose only input is
CleanupContext.category, computed solely from bundleID (Cleanup.swift:19,
default nil). Pipeline.clean — the only production caller — constructs
CleanupContext with dictionary/snippets/appName and no bundleID, and Pipeline
has no bundleID field at all, so category is permanently .unknown and toneHint
returns nil. context.appName is now stored (Cleanup.swift:18) and never read
anywhere. Net effect: the cleanup system prompt lost the destination hint it had
on main, and the new terminal/code/chat/prose hints are dead in the app. The
interpreter has the landing bundle ID in hand (DictationSession.Landed.bundleID)
and passes only the display name: Sources/Parla/Dictation.swift:301 does
`pipeline.frontAppName = { landed.appName }`. Unit tests pass because
CleanupTests builds CleanupContext directly with bundleID:; parla-eval also
routes through Pipeline.clean, so its `# bundle:` golden headers never reach the
prompt either.

**Failure.** Dictate "run git status and then git log dash dash one line" with Ghostty
(com.mitchellh.ghostty) frontmost, cleanup configured. On main the system prompt
contained "The text will be inserted into Ghostty. Match the tone typical for
that app ... plain for code/terminals." On the branch, Pipeline.clean builds
CleanupContext(bundleID: nil) -> category == .unknown -> PromptBuilder.system
emits neither that sentence nor the branch's new "literal command line ... never
a line break ... no Markdown or code fences" hint. The model gets zero signal
that the target is a terminal, so it is free to return prose/Markdown/a trailing
period; only TextRules.flattenForTerminal (the backstop, not the instruction)
still runs. Same for Slack (com.tinyspeck.slackmacgap): the "keep it casual,
output ONE line, Return sends the message" hint never reaches the model.
eval/cases/terminal-command.golden.txt and terminal-chat-newlines.golden.txt
carry `# bundle:` headers for exactly these hints and are scored without them.

**Verification.** Every link in the chain checks out, and a temp test on the real path failed with
`("unknown") is not equal to ("terminal")`.  1. Pipeline.swift:57-58 — the only
production dictation caller, no `bundleID:` argument:    `let ctx =
CleanupContext(dictionary: s.dictionary, snippets: s.snippets,\n
appName: frontAppName())`    Pipeline has no bundleID field at all
(Pipeline.swift:4-7: transcribe / cleanup / settings / frontAppName).  2.
Cleanup.swift:15,19 — the omitted parameter defaults to nil and is the ONLY
input to category:    `bundleID: String? = nil, selection: String? = nil) {` …
`self.category = TextRules.category(bundleID: bundleID)`    TextRules.swift:51:
`guard let bundleID else { return .unknown }`  3. Cleanup.swift:88 + 122-123 —
`.unknown` emits nothing:    `if let hint = toneHint(context.category) { p +=
"\n\n" + hint }` … `case .unknown: return

### [MAJOR] Exact-modifier chord matching makes the hands-free latch unreachable in command mode and leaks a Space keystroke

`Sources/ParlaCore/Hotkey.swift:295` · dimension: regressions

**Defect.** main matched hands-free with a superset test — `if keyCode == 49, fnActive` — so
any extra modifier held alongside fn still latched. The branch routes it through
KeyChord.matches, which is exact modifier equality (introduced deliberately so
⌃⌘⇧V stops stealing ⌃⌘V). Command mode is entered by holding shift at push-to-
talk time (handle() -> onEdge?(.down(command: modifiers.contains(.shift))), and
the Hub still labels it "⇧ " + pushToTalk.display), so shift being held during a
command-mode capture is the documented state, not an unusual one. With shift
held, a Space keyDown carries modifiers [.fn, .shift], which does not equal the
default handsFree chord KeyChord(49, .fn). The hands-free branch is skipped and
control falls to Hotkey.swift:313 (`if session == .push`), which cancels the
dictation and returns false, letting the Space through to the front app instead
of swallowing it.

**Failure.** Hold ⇧ and fn to start command mode over a text selection, keep both held, then
press Space to latch hands-free (what the Hub's "Hands-free mode: Start while
holding push to talk" row tells the user to do). On main this fired .handsFree,
played the latch pop and kept recording. On the branch,
bindings.handsFree.matches(49, [.fn, .shift]) is false, so keyDown falls to the
session == .push arm at Hotkey.swift:313: the monitor emits .cancel (aborting
the command dictation, playing the cancel sound) and returns false, so a literal
space character is typed into the frontmost app on top of the user's selection.

**Verification.** Hotkey.swift:54 `matches` is exact equality (`self.modifiers == modifiers`), and
Hotkey.swift:295 routes the latch through it: `if
bindings.handsFree.matches(keyCode, modifiers)`. Default handsFree is
`KeyChord(49, .fn)` (Hotkey.swift:153), so a Space keyDown carrying [.fn,
.shift] does not match, and control falls to Hotkey.swift:313 `if session ==
.push { session = .idle; onEdge?(.cancel); return false }` — cancel plus pass-
through. Shift-held is a documented state: Hotkey.swift:280
`onEdge?(.down(command: modifiers.contains(.shift)))` and HubPages.swift:86
`ShortcutPill(text: "⇧ " + model.settings.hotkeys.pushToTalk.display)`, with the
hands-free row (HubPages.swift:81-83) telling users to "Start while holding push
to talk" and never to release shift. main used a superset test (`if keyCode ==
49, fnActive`), so this is a regression. Proven with a temporary test (since
deleted): `m.han

### [MINOR] A second fn-down while a polish is in flight resets the Metrics singleton, corrupting the first dictation's history entry

`Sources/ParlaCore/History.swift:105` · dimension: correctness

**Defect.** `Metrics.mark` clears `stamps` and `pending` on every `.fnDown`, justified by
the comment at lines 88-90 ("no per-dictation identity. The processTask chain
serializes the legs, so only one dictation is ever between fn-down and its
history write"). That premise is false: `.trace(.fnDown)` is executed on main by
`perform` (Dictation.swift:184 → `stamp` → `Metrics.shared.mark`) the instant fn
goes down, entirely off the processTask chain, and `DictationSession` explicitly
allows it — "a new fn-down is legal in every state and always wins, so an old
session's completion can arrive while the machine is already recording a new
one" (DictationSession.swift:69-72). The first dictation's `.appendHistory` then
reads `Metrics.shared.snapshot()` built from the *second* dictation's stamp
table.

**Failure.** Dictate A; the raw text lands and the cleanup POST goes out (typ. 0.5–1.5 s). At
+300 ms press fn to start dictation B: `Metrics.mark(.fnDown)` wipes A's stamps
and `pending`. B stamps `.fnUp`/`.finalPassDone`/`.landed`. A's cleanup returns,
`.cleanReady` fires `.trace(.cleanedSwapped)` then `.appendHistory` →
`snapshot()` returns `captureMs = fnUp_B − fnDown_B` (B's speaking time),
`insertMs = landed_B − finalPassDone_B`, `cleanupMs = cleanedSwapped_A −
landed_B`, `totalMs` measured from B's fn-down — all written onto A's history
entry. If B's own cleanup then throws before `CleanupClient.clean` reaches its
`Metrics.shared.update` (e.g. a URLError), B's entry inherits A's
`cleanupModel`/`promptTokens`/`completionTokens`, and `CleanupCostEstimate.over`
counts A's spend twice.

**Verification.** History.swift:105-108 wipes unconditionally — `if stamp == .fnDown {
stamps.removeAll(keepingCapacity: true); pending = PipelineMetrics() }` — and
its justifying comment ("The processTask chain serializes the legs, so only one
dictation is ever between fn-down and its history write") does not cover the fn-
down stamp itself. main.swift:160 dispatches `.startDictation` straight out of
`hotkey.onEdge` with no state guard; the reducer's first effect is
`.trace(.fnDown)` (DictationSession.swift:283), run synchronously on main by
`case let .trace(s): stamp(s)` → `Metrics.shared.mark(s)` (Dictation.swift:184,
191-194). Nothing on the chain is involved, and DictationSession.swift:69-72
plus `if s.gen == gen { state = .polishing(gen: s.gen) }` (line 526) confirm a
new fn-down is legal while a polish is outstanding. Proven with a temporary test
driving the real machine (fn-down A → fn-up A → `.tra

### [MINOR] Onboarding tryout leaves the HUD pill on screen indefinitely with the recording dot lit

`Sources/Parla/Hub/Onboarding.swift:281` · dimension: correctness

**Defect.** `tryoutStop` finishes by showing `.preview(text)`. `HUD.show`'s `.preview` case
(HUD.swift:247-252) is built for the mid-recording live preview: it sets
`dot.isHidden = false` (the coral recording dot) and deliberately does not call
`scheduleHide()` — the comment at line 248 says so ("Mid-recording, like
.handsFree: no waveform clear, no scheduleHide"). Every terminal state (`.done`,
`.savedToHistory`, `.error`, `.cancelled`) schedules a hide; `.preview` is not a
terminal state and is being used as one here. Nothing else in the tryout path
calls `hud.hide()` on the non-empty branch.

**Failure.** Fresh install → onboarding step 3 → Start → say a sentence → Stop. The
transcript appears in the pill and stays there permanently: the panel is never
ordered out, and with `showHudAlways` the pill never collapses back to the idle
bar either. The red recording dot stays lit the whole time even though
`recorder.stop()` has already run, so Parla's own UI claims it is recording when
it isn't. Only pressing Esc (routing to `HUD.dismiss`) or starting a real
dictation clears it.

**Verification.** CONFIRMED, including at runtime. The cited code says exactly what the finding
claims.  Onboarding.swift:281 (last HUD call on the tryout's success path):
if text.isEmpty { self.hud.hide() } else { self.hud.show(.preview(text)) }
HUD.swift:247-252 — `.preview` lights the coral dot, orders the panel front, and
(per its own comment) never schedules a hide:     case .preview(let text):
// Mid-recording, like .handsFree: no waveform clear, no scheduleHide.
dot.isHidden = false         waveform.isHidden = true         label.stringValue
= text         panel.orderFrontRegardless() Every genuinely terminal case
(.done/.savedToHistory/.cleanedInHistory/.rawFallback/.cancelled/.error) ends
with `scheduleHide()`. The only other case without one is `.polishing`, whose
comment says "no scheduleHide — a terminal state follows".  `.preview` is a mid-
recording state by construction e

### [MINOR] `snippetExpansion` tie-break is non-deterministic when two triggers normalize alike and have equal length

`Sources/ParlaCore/Pipeline.swift:43` · dimension: correctness

**Defect.** The doc comment (lines 35-37) claims "Longest trigger wins so two triggers that
fold alike resolve identically every run — a Dictionary has no order to fall
back on." `max(by:)` only breaks the tie when the raw key lengths differ. For
equal lengths it keeps the first maximal element in iteration order, and
`Dictionary` iteration order depends on Swift's per-process hash seed, so it
differs between launches. `SnippetsPage.duplicateTriggers`
(HubPages.swift:418-424) only flags byte-identical trimmed triggers, so the Hub
shows no warning for this case either.

**Failure.** Settings contain `snippets = ["thanks": "thx", "Thanks": "Thanks so much!"]`
(both legal, distinct dictionary keys). Both fold to "thanks" under
`Eval.normalizeForWER` and both have `count == 6`. Dictating "Thanks." expands
to "thx" on one launch of Parla and "Thanks so much!" on the next, with no
setting changed in between.

**Verification.** Pipeline.swift:42-43 — `return snippets.filter { Eval.normalizeForWER($0.key) ==
key }.max { $0.key.count < $1.key.count }?.value`. `Dictionary.filter` returns a
`[String: String]`, and `Sequence.max(by:)` keeps the FIRST maximal element (`if
areInIncreasingOrder(result, e) { result = e }` — strict, so ties never
replace), so with equal `key.count` the winner is whichever Dictionary iteration
yields first — hash-seed randomized per process. Proven, not argued: a temporary
test calling `Pipeline.snippetExpansion(transcript: "Thanks.", snippets:
["thanks": "thx", "Thanks": "Thanks so much!"])`, run in 30 separate launches of
the built xctest bundle, returned `thx` 20 times and `Thanks so much!` 10 times
(assertion failed on 10/30), with the printed Dictionary order flipping in
lockstep (`ITER_ORDER=thanks,Thanks` 20x vs `Thanks,thanks` 10x). Test deleted
afterward; implementation untouched

### [MINOR] Metrics singleton is reset by the next fn-down while the previous dictation's polish is still in flight

`Sources/ParlaCore/History.swift:105` · dimension: concurrency

**Defect.** `Metrics.shared` has no per-dictation identity; the ponytail note at
History.swift:88-90 justifies that with "The processTask chain serializes the
legs, so only one dictation is ever between fn-down and its history write". That
is false for the polish path. `.trace(.fnDown)` is executed synchronously on
main inside `perform` (Dictation.swift:184 -> `stamp` -> `Metrics.shared.mark`),
*not* on the processTask chain, while the previous dictation's history write
happens much later, in `cleanReady`'s `.appendHistory`
(DictationSession.swift:574) after `pipeline.clean` returns
(Dictation.swift:302). So a new fn-down lands inside the old dictation's window
and executes `stamps.removeAll(); pending = PipelineMetrics()` on the shared
instance.

**Failure.** Dictation A finishes; raw text lands; the cleanup POST is in flight (typically
1-3 s, `timeoutInterval = 15`). Within that window the user presses fn for
dictation B. B's `.trace(.fnDown)` wipes `stamps` (A's
fnDown/fnUp/finalPassDone/landed) and `pending` (A's `model`, set at
Dictation.swift:262). A's POST then returns and `CleanupClient.clean` writes
`cleanupModel`/`promptTokens`/`completionTokens` into what is now B's `pending`
(Cleanup.swift:319). A's `cleanReady` stamps `.cleanedSwapped` and calls
`Metrics.shared.snapshot()` for its history entry:
`captureMs`/`asrMs`/`insertMs`/`cleanupMs`/`model` are all nil, and `totalMs` is
computed as `cleanedSwapped - fnDown` where `fnDown` is *B's* timestamp — a
number that measures nothing. B's own entry then carries A's token counts until
B's cleanup overwrites them. `Trace.shared` (Trace.swift:48) is clobbered the
same way, so `PARLA_TRACE=1` prints a merged line for two dictations.

**Verification.** Confirmed by reading every caller and by a temporary failing test (deleted;
suite back to 358/358, implementation untouched).  The ponytail note at
History.swift:88-90 claims "The processTask chain serializes the legs, so only
one dictation is ever between fn-down and its history write". False for the
polish path:  1. DictationSession.swift:272-283 accepts fn-down in EVERY state,
.polishing included, and its first effect is the fnDown stamp:    `case let
.startDictation(settings, cleanupConfigured, live):` ... "// Always wins, in
every state: an in-flight leg's completion will find itself stale." ... `return
[.trace(.fnDown), .warmCleanupEndpoint,
.applyPreferencesAndStartCapture(settings)]` 2. Effects run synchronously on
main inside `send`, NOT on the processTask chain — Dictation.swift:184 `case let
.trace(s): stamp(s)` -> Dictation.swift:191-194 `func stamp(_ s: Trace.Stamp) {
Trace.

### [MINOR] A StreamWindow that finish() never consumes is spliced into a later dictation's transcript

`Sources/Parla/Dictation.swift:475` · dimension: concurrency

**Defect.** The handoff comment at Dictation.swift:470-474 claims the window is safe because
"whoever runs next on the chain is this dictation's own finish() (which consumes
the window) or a newer dictation's stream(), which overwrites it before anyone
reads it." Both halves can fail. `stream()` only writes the window under `if
!confirmed.isEmpty` (line 475), so a newer *short* dictation overwrites nothing;
and `finish()` has an early return at line 212 (`guard let transcriber else`)
that fires before the consume site at lines 235-237, leaving a populated
`self.window` on the shared AppDelegate. `.discardStreamWindow` is only emitted
by `cancelRequested` (DictationSession.swift:366), so nothing clears it on this
path.

**Failure.** Dictation A runs past `StreamWindow.threshold` (>15 s), so `stream()` freezes a
head cut and writes `window = StreamWindow(confirmedText: "...long confirmed
prefix...", cutSample: N)` at line 475. While A's chained `finish()` is
queued/running, the Hub's General page "Use" button selects a model whose file
on disk fails `ModelCatalog.verifyInstalled` (or
`WhisperTranscriber(modelPath:)` throws): the debounced save fires `onSaved` ->
`loadModel()` on main (main.swift:88-91), which sets `transcriber = nil`
(main.swift:243). A's `finish()` bails at line 212 with `window` still set. The
user re-selects a good model. The next dictation is short, so its `stream()`
leaves `confirmed` empty and does not touch `window`. Its `finish()` takes the
`if let win = window` branch at line 236 with A's window: it computes `cut =
min(A.cutSample, samples.count)`, transcribes only the tail past that cut, and
`StreamWindow.join(win.confirmedText, tailText)` types A's minutes-old speech in
front of the new utterance.

**Verification.** Both halves of the handoff comment's safety argument fail, and each is settled
by quoted code. (1) The consume site sits BEHIND an early return: `finish()`
opens with `guard let transcriber else { ... send(.legUnavailable ...); return
}` (Dictation.swift:212-216) and only reaches `if let win = window { window =
nil; ...` at 234-235 afterwards, so a nil transcriber leaves `self.window`
populated on the shared AppDelegate. Nothing else clears it —
`.discardStreamWindow` has exactly one emit site,
`fx.append(.discardStreamWindow)` under `case let .cancelRequested(silent)`
(DictationSession.swift:366); the failure exit is `case let .legUnavailable(s,
message): return [.hud(.error(message))] + (s.isCommand ? transformTail(s) :
finishTail(s))` (405-406) and `finishTail` is only `[.flushTrace,
.menuBar(.idle), .releaseModelIfPolicyImmediate]` (422-426). (2) The overwrite
is conditional: `if !co

### [MINOR] RecordingStore's secure-deletion guard is unreachable on the only path that retains the WAV, so audio captured while focus moved into a password field can survive on disk

`Sources/Parla/Dictation.swift:291` · dimension: safety

**Defect.** `finish()` writes the capture to disk before the whisper pass (line 211) and
relies on `RecordingStore.resolve` to clean up. But the landing probe — the only
source of the secure signal — is computed only inside `if raw != nil` (line
273); when `raw` is nil the probe stays `LandingProbe(focus: .none)`, and
`s.focus` can never be `.secure` here because `.focusSampled` already refuses
secure fields (DictationSession.swift:310). So the `secure:` argument at line
291-292 is unconditionally `false` exactly when `raw == nil`. In
RecordingStore.resolve, `guard !secure else { return remove(url) }` (line 85) is
evaluated first, and the retain branch is `guard let transcript,
!transcript.isEmpty else { return }` (line 86) — i.e. the file is kept if and
only if the transcript is nil/empty, which is precisely the case where secure
was never sampled. The two conditions are complementary: the secure delete can
never apply to a retained file. The WAV then sits in ~/Library/Application
Support/Parla/recordings for the full 7-day retention window
(RecordingStore.swift:32), violating the "never persisted to disk" half of the
secure-context invariant. RecordingStore is new in this branch, so this is a new
persistence surface.

**Failure.** User holds fn in a normal text field (focus sampled as .editable, capture
allowed), then clicks into a login form's password field or a sudo prompt while
still holding fn and speaks the password. finish() stashes the audio as a 16 kHz
WAV at line 211. whisper returns "" (or the tail falls under the min-audio floor
at line 251), so raw == nil. The probe is skipped, resolve is called with
secure: false and transcript: nil, hits the `keep` branch, and the recording of
the spoken password stays on disk for 7 days. The same happens on the `guard let
transcriber` early return at line 212-216, which returns before resolve is
called at all.

**Verification.** Confirmed by a temp test that failed and was deleted. The path is a straight
line, no guard in between.  Dictation.swift:211 stashes the WAV before anything
can fail: `let recording = RecordingStore.shared.stash(samples)`.
Dictation.swift:272-284 — the probe, the only live secure signal, is inside `if
raw != nil`: ```swift var probe = LandingProbe(focus: .none) if raw != nil {
let focus = Inserter.focusTarget()     ...     probe = LandingProbe(focus:
focus, ...) } self.send(.transcribed(s, raw: raw, probe: probe))
RecordingStore.shared.resolve(recording, transcript: raw,
secure: probe.focus == .secure || s.focus == .secure) ``` The second disjunct is
dead: DictationSession.swift:310 `guard focus != .secure else { state = .idle;
return [.stopCapture(discard: true), ...] }` means a dictation Session never
carries `.secure` (command mode is refused at :289

### [MINOR] testResamplerRebuildsOnInputFormatChange's ±200 tolerance passes with the converter cache removed

`Tests/ParlaCoreTests/AudioTests.swift:79` · dimension: tests

**Defect.** The comment calls this "the assertion that matters here: 4410 frames at 44.1k
yield a full 1600 at 16k only if the converter was cached across the two calls
rather than rebuilt — a rebuild would re-prime and come up short." Measured on
this machine by replaying Resampler verbatim: cached gives 1616, a converter
rebuilt on every call gives 1480. |1480-1600| = 120, inside the accuracy of 200,
so the assertion holds either way. The test's other assertions (at48k.count >
1000 → 1360, at44k.count > 1000 → 1480, amplitude > 0.5) also hold under per-
call rebuild, so the whole test is green with the caching gone.

**Failure.** Change AudioRecorder.swift:529 from `if inputFormat != buffer.format` to `if
true` (rebuild every call). testResamplerRebuildsOnInputFormatChange passes
unchanged. (The regression is caught, but only by
testChunkedConversionMatchesOneShot — measured chunked=7973 vs whole=8000 and
maxStep 0.907 — so this test contributes nothing to the property it names.)

**Verification.** AudioTests.swift:76-79 claims "Steady state is the assertion that matters here:
4410 frames at 44.1k yield a full 1600 at 16k only if the converter was cached
across the two calls rather than rebuilt — a rebuild would re-prime and come up
short. / XCTAssertEqual(at44kSteady.count, 1_600, accuracy: 200)". Measured
against the real ParlaCore Resampler via a temporary test (now deleted): "PROOF
cachedSteady=1616 rebuiltSteady=1480 cachedErr=16 rebuiltErr=120". A rebuild in
convert() sets `converter = AVAudioConverter(from: buffer.format, to: target);
inputFormat = buffer.format; out = nil` — identical state to a fresh Resampler's
first call, so a fresh instance is an exact stand-in. Both 1616 and 1480 are
inside accuracy 200, so the assertion holds either way. A verbatim replay of
Resampler with `if inputFormat != buffer.format` switched to `if true` confirms
the whole test stays green (at4

### [MINOR] testSaveInvalidatesEvenWhenStampCouldNotChange cannot fail — a same-length atomic rewrite does change mtime

`Tests/ParlaCoreTests/SettingsTests.swift:140` · dimension: tests

**Defect.** The test's premise ("Identical length, written immediately: mtime and size may
both be unchanged, so save() must drop the cache itself") does not hold on APFS.
Measured with the same call Settings.swift:131 uses: two
`Data.write(to:options:.atomic)` of 4 bytes each, back to back, gave
modificationDate 1786412804.3159535 then 1786412804.3256512 — different mtimes
at nanosecond resolution. So `currentStamp()` differs, the cache misses on its
own, and load() re-reads from disk regardless of what save() did.

**Failure.** Delete `lock.withLock { cached = nil }` at Settings.swift:162 — 356/356 still
pass. The guard is real on coarse-timestamp filesystems (HFS+/SMB, 1-second
mtime): the Hub saves settings, the cached stamp still matches, and the next fn-
down runs against the pre-save settings (stale dictionary, stale hotkeys) until
some other write moves the clock.

**Verification.** The test's comment claims "mtime and size may both be unchanged, so save() must
drop the cache itself" — but nothing in the test forces that. Settings.swift:159
writes with `try enc.encode(settings).write(to: url, options: .atomic)`, which
renames a fresh temp file into place, so the mtime that Settings.swift:131 reads
back (`FileManager.default.attributesOfItem(atPath: url.path)` →
`.modificationDate`) always advances. Measured in-repo with the real encoder and
the real `Stamp` fields: mtime1=808106595.9664842 size1=473,
mtime2=808106595.9669347 size2=473 — Δ450 µs, and `Date`'s Double resolution at
that epoch is ~120 ns, so the difference is never lost. I then built a byte-
faithful replica of `SettingsStore` with only `lock.withLock { cached = nil }`
(Settings.swift:162) removed and ran the test's exact sequence (save "aaaa" →
load → save "bbbb" → load) 500 times: 0/500 stale. `load()`

### [MINOR] Rebindable-hotkeys loading path (refreshBindings) is untested — every rebinding test writes m.bindings directly

`Sources/ParlaCore/Hotkey.swift:345` · dimension: tests

**Defect.** refreshBindings() is new on this branch and is the only bridge from
settings.json to live bindings, including the safety rule `bindings =
next.problem() == nil ? next : HotkeyBindings()` — "a hand-edited settings.json
that would leave Parla unreachable is ignored in favour of the defaults". It is
private and called only from the private process(type:event:) tap callback
(Hotkey.swift:382, :394), which no test drives. The 274 new lines of HotkeyTests
cover the two halves either side of it — decode (HotkeyTests.swift:316) and
problem() (HotkeyTests.swift:328-382) — but every rebinding test assigns
`m.bindings` in-process (HotkeyTests.swift:240, :251, :264), so the wiring
itself, and the short-circuit `guard next != loadedBindings` at
Hotkey.swift:343, are never executed.

**Failure.** Change Hotkey.swift:345 to `bindings = next` (drop the validity fallback) —
356/356 still pass. A settings.json with `"pushToTalk": "v"` then makes holding
V start dictation and autorepeat "vvvv…" into the focused field, with no path
back except editing the file, which is precisely what problem() exists to
prevent.

**Verification.** CONFIRMED by llvm-cov, not by argument. `swift test --enable-code-coverage` on a
clean copy of HEAD, then `llvm-cov show`, gives an execution count of **0** for
every line of the function (`problem()` next to it runs 14 times):
$s9ParlaCore13HotkeyMonitorC15refreshBindings...LLyyF:       341|      0|
private func refreshBindings() {       342|      0|        let next =
store.load().hotkeys       343|      0|        guard next != loadedBindings else
{ return }       344|      0|        loadedBindings = next       345|      0|
bindings = next.problem() == nil ? next : HotkeyBindings()       346|      0|
}     ...process(type:event:)  →  lines 373-402 all |0|  The reachability claim
holds exactly as stated: `refreshBindings` is `private`, called only from
`private process(type:event:)` (Hotkey.swift:382, :394), called only from the
CGEventTap C callback in `start()` (:356-

### [MINOR] testDistanceRatioBoundary guards maxDistanceRatio only in the safe direction; the accept window can widen 0.65 → 0.87 with the suite green

`Tests/ParlaCoreTests/DictionaryLearnerTests.swift:83` · dimension: tests

**Defect.** The test says "Guard the constant itself", but its assertion is
`XCTAssertLessThanOrEqual(Double(4), maxDistanceRatio * 7)`, which holds for
every ratio ≥ 0.572 — i.e. it can only fail if the constant is *lowered*, the
direction that merely misses corrections. The dangerous direction (a wider
window learns wrong entries, which the file header calls permanent damage to
every future dictation) is bounded only by the two rejection cases, and both sit
far away: computed edit distances are shunade→bourbons = 7/8 = 0.875 and
shunade→everyone = 7/8 = 0.875.

**Failure.** Change DictionaryLearner.swift:40 to `maxDistanceRatio = 0.85` — 356/356 still
pass, including this test. "Shunade" → "Michelle" (distance 7 of 8 = 0.875,
still rejected) survives, but e.g. "platform" → "planning" (5 of 8 = 0.625) and
any pair up to 0.85 is now proposed as a dictionary entry and, once accepted,
injected into whisper's initial_prompt for every dictation.

**Verification.** The assertion is arithmetically one-directional.
DictionaryLearnerTests.swift:87-88 pins `d` then asserts
`XCTAssertLessThanOrEqual(Double(d), DictionaryLearner.maxDistanceRatio * 7)`
with `d == 4` — true for every ratio >= 4/7 = 0.5714, so only a *lowered*
constant can fail it, despite the comment "Guard the constant itself".  Proved
by mutation in an isolated scratch package (Eval.swift + DictionaryLearner.swift
+ the unmodified test file; the real repo was never edited — `git diff` empty,
constant still 0.65): - scratch constant 0.85 → 30/30 pass,
`testDistanceRatioBoundary` included. - scratch constant 0.55 →
`testDistanceRatioBoundary` fails: `XCTAssertLessThanOrEqual failed: ("4.0") is
greater than ("3.8500000000000005")` — the direction that merely misses
corrections, and one already covered by the three accept tests.  Nothing else
bounds it from above. `grep -rl DictionaryLearner

### [MINOR] No test pins the "pasteboard is only ever written by the Hub's Copy button" invariant

`Sources/Parla/Hub/HubModel.swift:146` · dimension: tests

**Defect.** This is one of the four invariants the branch must never break, and the comment
above it asserts "The ONLY pasteboard write in the app." Nothing checks that
claim: the Tests target covers ParlaCore only, HubModel lives in the Parla
executable target, and grep over Tests/ for NSPasteboard returns nothing. The
property is a whole-source-tree statement, so it is checkable without a test
target.

**Failure.** Add `NSPasteboard.general.setString(text, forType: .string)` next to
`Inserter.insert(text)` in Dictation.swift:131 (the shape of the paste-based
insertion this app deliberately moved away from) — 356/356 still pass, and every
dictation silently overwrites the user's clipboard.

**Verification.** Every claim checks out, and I reproduced the failure scenario verbatim.  1. The
comment says exactly what the finding quotes —
/Users/daksh/mySpace/code/wisper/Sources/Parla/Hub/HubModel.swift:143: ```swift
/// The ONLY pasteboard write in the app — an explicit, user-initiated Copy. ///
Parla itself never touches the clipboard anywhere else. func copy(_ text:
String) {     NSPasteboard.general.clearContents()
NSPasteboard.general.setString(text, forType: .string) } ``` It restates
ISSUES.md:77 ("The only remaining pasteboard write is the Hub's explicit Copy
button").  2. The invariant is TRUE today but structurally unenforceable from
the test target. Package.swift: ```swift .executableTarget(name: "Parla",
dependencies: ["ParlaCore"]), .testTarget(name: "ParlaCoreTests", dependencies:
["ParlaCore"]), ``` Both HubModel.swift and Dictation.swift live in `Parla`,
which is outside the te

### [MINOR] CorrectionWatcher re-implements Inserter's focused-element lookup and drops its Electron fallback

`Sources/Parla/Dictation.swift:610` · dimension: simplification

**Defect.** `CorrectionWatcher.focusedElement()` is a second implementation of
`Inserter.focusedElement()` (Sources/ParlaCore/Inserter.swift:128) written only
to also return the pid. The copy queries `AXUIElementCreateSystemWide()` and
stops there; the original falls back to
`AXUIElementCreateApplication(frontmostApplication.pid)` with the comment
"Electron/Chromium apps often answer only the app-level query".
`Self.value(of:)` (line 622) likewise duplicates the value read inside
`Inserter.focusedFieldState()` (Inserter.swift:169), and `Self.isSecure` (line
632) duplicates the AXSecureTextField test in `Inserter.classifyFocus()`
(Inserter.swift:150). Three copies to avoid making one private helper internal.

**Failure.** Dictate into Slack / VS Code / Cursor (Electron), where the system-wide focused-
element query commonly fails and only the app-level query answers.
`Inserter.canEraseTyped` resolves the element via its fallback, so the insert
and the cleaned tail-swap both verify and land, and `perform(.insertText:)`
calls `CorrectionWatcher.shared.arm(...)` (Dictation.swift:132). 250 ms later
`attach` runs, `Self.focusedElement()` returns nil at line 615, and it returns
at line 542 — no observer, no baseline. The user hand-corrects the misheard
word, nothing is diffed, and no proposal ever reaches the Dictionary page.
Dictionary learning is silently dead in exactly the apps Parla is used in, while
every other AX path in the same dictation worked.

**Verification.** Sources/Parla/Dictation.swift:610 stops at the system-wide query — `guard
AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused
else { return nil }` — while Sources/ParlaCore/Inserter.swift:133 falls through
to `let appEl = AXUIElementCreateApplication(app.processIdentifier)` under the
comment "Electron/Chromium apps often answer only the app-level query". The path
is reachable: DictationSession.swift:500 `case .unknown, .editable:` (the
classification an Electron field gets) emits `.insertText`, Dictation.swift:132
`CorrectionWatcher.shared.arm(inserted: text, ...)` arms off it, and when only
the app-level query answers, `classifyFocus` already returns .editable via the
fallback so the AX wake at Inserter.swift:111 never runs — leaving `attach`'s
`guard let (element, pid) = Self.focusedElement()` (Dictat

### [NIT] testCleanupFailureKeepsRawAndShowsTheReason's history assertion is trivially true — its setup passes text == raw

`Tests/ParlaCoreTests/DictationSessionTests.swift:212` · dimension: tests

**Defect.** The comment says "A failed cleanup is never stored as the cleaned version", but
the test calls .cleanReady with text: "hello world", which is exactly
landed.raw. The implementation at DictationSession.swift:573 is `(failure == nil
&& text != landed.raw) ? text : nil`; with text == raw the second clause already
yields nil, so the `failure == nil` guard is never exercised. It is the only
test in the file that passes a non-nil `failure` (the other three cleanReady
tests at :188, :227, :554 all pass failure: nil), so nothing pins the coupling
to Pipeline.clean, which today returns `(transcript, reason)` on every failure
branch (Pipeline.swift:63, :85, :90, :94, :97).

**Failure.** Delete `failure == nil &&` from DictationSession.swift:573 — 356/356 still pass.
The guard then only matters the day a provider returns partial text plus a
failure reason (e.g. a truncated streamed response reported as `cleanup timed
out`), at which point the failed output is written to history as the `cleaned`
version and served by HistoryEntry.best to paste-last.

**Verification.** Accurate as a test-coverage claim, wrong as a bug. The setup at
DictationSessionTests.swift:204/207 is `Landed(landing: .field, raw: "hello
world", ...)` and `.cleanReady(s, landed, text: "hello world", failure: "cleanup
timed out", ...)`, fed to DictationSession.swift:573 `let cleanedForHistory =
(failure == nil && text != landed.raw) ? text : nil` — with text == raw the
second conjunct is already false, so the assertion at :212 is satisfied for
either value of `failure`. Proved empirically with a temporary test (since the
implementation may not be mutated): building the effect list twice with the
existing inputs, once `failure: "cleanup timed out"` and once `failure: nil`,
and asserting the two `.appendHistory` effects are EQUAL — it passed, so the
assertion provably cannot observe the guard. A second temp test (`text: "Hello,
wor"`, `failure: "cleanup timed out"`) confirmed the guard

### [NIT] testTwoStashesInQuickSuccessionDoNotCollide exercises the collision path in only ~40% of runs

`Tests/ParlaCoreTests/RecordingStoreTests.swift:42` · dimension: tests

**Defect.** RecordingStore.name() takes a Date but stash() always calls it with Date()
(RecordingStore.swift:62), so the test has no way to force two identical
millisecond names — it just hopes. Measured by replaying stash()'s exact
sequence (directory listing → createDirectory → name(Date()) → writeWAV of 1600
samples) 30 times: the two calls produced the same name in 12/30 runs. In the
other 18 the names differ and `uniqueURL`'s dedup loop is never entered, yet the
test passes and claims the collision is handled.

**Failure.** Replace RecordingStore.swift:144-152 with `directory.appendingPathComponent(base
+ ".wav")` (no dedup loop): the test fails in ~40% of runs and passes in ~60%,
so it lands as a flake rather than a failure, and in CI it is more likely to go
green than red.

**Verification.** The mechanism is exactly as described. `stash()` has no time seam —
RecordingStore.swift:62 `let url = uniqueURL(base: Self.name(Date()))` — while
`name` is `static func name(_ date: Date) -> String` (line 166), so the test
cannot pin the millisecond. Its only assertion, RecordingStoreTests.swift:46
`XCTAssertEqual(s.recordings().count, 2)`, is satisfied on BOTH branches: names
differ (loop body at 147-150 never runs) or names collide (loop renames).
Nothing distinguishes them, so a green run proves nothing.  The claimed NUMBERS
are wrong by >10x, and that inverts the practical conclusion. I measured two
ways, without touching Sources. (a) Detecting a dedup suffix on the second file
returned by the real `stash()` (base "yyyy-MM-dd-HHmmss-SSS" is 21 chars; longer
== the loop body ran): 6/200, 1/200, 0/200. (b) Replaying the finding's own
proposed regression — same sequence but naming with

### [NIT] VerifiedCache test changes size as well as bytes, so it cannot catch an identity that drops mtime

`Tests/ParlaCoreTests/ModelCatalogTests.swift:169` · dimension: tests

**Defect.** VerifiedCache.identity is `"<size>-<mtime>"` (ModelCatalog.swift:212) and the
doc comment names the exact hazard it guards: "macparakeet's disk-identity rule:
a re-download at the same path changes mtime, so the stale verdict is dropped
instead of blessing different bytes", citing pindrop #785 where comparing sizes
bricked installs. The test rewrites "model" (5 bytes) as "different model" (15
bytes), changing size AND mtime, so a size-only identity, an mtime-only identity
and the real one are indistinguishable — exactly the same-length case
SettingsTests deliberately constructs for its own stamp, and the one omitted
here.

**Failure.** Change ModelCatalog.swift:212 to `return "\(size)"` — 356/356 still pass. A
HuggingFace re-upload of ggml-base.en.bin at the same byte count then re-
downloads over the old path, keeps the cached "verified" verdict, skips the
SHA-256 check at ModelCatalog.swift:182, and hands unpinned bytes to whisper.

**Verification.** The coverage claim is CONFIRMED; the attached real-app failure chain is REFUTED.
CONFIRMED — the code says what the finding says. ModelCatalog.swift:210-212:
guard let attrs = ..., let size = attrs[.size] as? Int64,           let mtime =
attrs[.modificationDate] as? Date else { return nil }     return
"\(size)-\(mtime.timeIntervalSince1970)" and the doc comment at :195-199 names
the hazard verbatim: "Identity, not path, is the key — macparakeet's disk-
identity rule: a re-download at the same path changes mtime, so the stale
verdict is dropped instead of blessing different bytes."  The test at
ModelCatalogTests.swift:160-171 writes Data("model") then Data("different
model") — 5 bytes vs 15. I ran a temporary probe (now deleted): "PROBE shipped
payload sizes: 5 -> 15". Size alone already fails the comparison, so the mtime
half is never exercised.  Nothing else covers it. `grep -rn "Ve

### [NIT] ModelUnloadPolicy is a 3-case policy for a compile-time constant; its `.immediately` branch makes a whole Effect a permanent no-op

`Sources/Parla/main.swift:60` · dimension: simplification

**Defect.** `let unloadPolicy = ModelUnloadPolicy.default` is a `let` initialised from
`ModelUnloadPolicy.default = .afterIdle(seconds: 300)`
(Sources/ParlaCore/Transcriber.swift:135). It is never read from `Settings`,
never re-assigned, and there is no Hub control for it. So
`unloadsAfterTranscription` (Transcriber.swift:154) is `false` forever, `.never`
is unreachable, and `shouldUnloadOnTick` collapses to `idle >= 300 &&
!recording`. The `.immediately` case pulls a whole layer behind it:
`DictationSession.Effect.releaseModelIfPolicyImmediate`
(DictationSession.swift:188), emitted on every dictation and transform exit
(DictationSession.swift:425 and 433), executed at Dictation.swift:97, guarded
away at main.swift:316 — plus roughly a dozen test expectations that assert the
no-op effect is present.

**Failure.** Any dictation: `finishTail` appends `.releaseModelIfPolicyImmediate`, the
interpreter calls `unloadAfterTranscription()`, which hits `guard
unloadPolicy.unloadsAfterTranscription else { return }` at main.swift:316 and
returns immediately. The effect can never do anything for any input, yet every
future change to the effect list must keep it in place because
DictationSessionTests asserts on exact effect arrays containing it.

**Verification.** Every code fact checks out; the exact inert path is DictationSession.swift:425
`return [.flushTrace, .menuBar(.idle), .releaseModelIfPolicyImmediate]` ->
Dictation.swift:97 `case .releaseModelIfPolicyImmediate:
unloadAfterTranscription()` -> main.swift:316 `guard
unloadPolicy.unloadsAfterTranscription else { return }`, where main.swift:60
`let unloadPolicy = ModelUnloadPolicy.default` is a `let` bound to
Transcriber.swift:135 `public static let `default` =
ModelUnloadPolicy.afterIdle(seconds: 300)` and Transcriber.swift:150 `public var
unloadsAfterTranscription: Bool { self == .immediately }` is therefore false
forever. An exhaustive grep for `unloadPolicy|ModelUnloadPolicy` across all of
Sources/ returns exactly three hits (the declaration plus the two reads) — no
Settings key, no Hub control; the only `unload` string under Sources/Parla/Hub/
is an unrelated comment about "unloaded sett

### [NIT] AudioRecorder.conversionFailures() has no production reader

`Sources/ParlaCore/AudioRecorder.swift:235` · dimension: simplification

**Defect.** `failedBuffers` (declared line 31, incremented line 259, reset line 419) and the
public `conversionFailures()` accessor are new on this branch. Grepping Sources
finds no caller — the only readers are AudioRecorderTests:23/29/57. The doc
comment claims "Without a count, a total conversion failure is indistinguishable
from a silent mic", but nothing ever reads the count to make that distinction:
`finish()` treats a silent buffer purely through
`TextRules.audioWorthTranscribing` (Dictation.swift:251).

**Failure.** A dictation where the resampler drops every tap buffer produces `raw = nil` and
the generic "audio below min-audio floor" log at Dictation.swift:255 — exactly
the same output as a silent mic, which is the case this counter was added to
disambiguate. The counter is incremented and then never consulted by anything
but its own test.

**Verification.** Confirmed on all counts. AudioRecorder.swift:259 is the only write — `if let
chunk { samples.append(contentsOf: chunk) } else { failedBuffers += 1 }` — and
AudioRecorder.swift:235 `public func conversionFailures() -> Int` is the only
read path, doc-commented "Without a count, a total conversion failure is
indistinguishable from a silent mic." Grepping both identifiers across the WHOLE
repo (not just Sources) returns only the four implementation lines plus
Tests/ParlaCoreTests/AudioRecorderTests.swift:23,29,57 and a progress.md note;
Swift offers no dynamic path here (no #selector, no key paths, no KVC), so name
grep is exhaustive. PROOF: I rsynced the tree to scratchpad, deleted
`failedBuffers` and `conversionFailures()` entirely, ran `swift build` → "Build
complete! (23.16s)", linking both `Parla` and `parla-eval`; only the test target
references them. (Scratchpad copy deleted, repo nev

### [NIT] ModelCatalog.model(id:) is dead API kept alive by one test assertion

`Sources/ParlaCore/ModelCatalog.swift:63` · dimension: simplification

**Defect.** `public static func model(id: String) -> Model?` has no caller in Sources. The
only reference in the repo is `XCTAssertNil(ModelCatalog.model(id: "nope"))` at
Tests/ParlaCoreTests/ModelCatalogTests.swift:60 — a test that exists solely
because the function does. Settings stores a path, not an id, so every real
lookup goes through `model(atPath:)` (line 68).

**Failure.** There is no input for which this function affects the app: no code path can
reach it. It is public API surface, so it is also a compatibility obligation for
a lookup key (`id`) the app never persists.

**Verification.** CONFIRMED, with two minor overstatements in the finding's rationale.  The quoted
code is exact — Sources/ParlaCore/ModelCatalog.swift:63:     public static func
model(id: String) -> Model? { all.first { $0.id == id } }  Exhaustive grep
across the entire repo for `model(id:`, `.model(`, and bare `model(` yields
exactly two hits: that definition, and
Tests/ParlaCoreTests/ModelCatalogTests.swift:60:
XCTAssertNil(ModelCatalog.model(id: "nope"))  Grep is proof rather than
heuristic here: a static func on a Swift `enum` has no dynamic dispatch path
(enums cannot be @objc, no #selector, no @dynamicMemberLookup), so a call site
grep misses cannot exist.  The "Settings stores a path, not an id" premise
checks out. Sources/ParlaCore/Settings.swift:32:     public var
whisperModelPath: String? = nil Every writer stores a path (HubModel.swift:70
and ModelInstaller.swift:70 both write `ModelCatalo

### [NIT] Settings.liveStreamingEnabled is a persisted, decoded, tested knob that nothing reads

`Sources/ParlaCore/Settings.swift:45` · dimension: simplification

**Defect.** The only reader of live-typing state is `AppDelegate.liveTyping`, a hard-coded
`let liveTyping = false` (main.swift:37), passed as `live:` into
`.startDictation` (main.swift:161). `liveStreamingEnabled` is never read
anywhere in Sources — it only round-trips through the tolerant decoder
(Settings.swift:77) and four SettingsTests assertions. This predates the branch,
but the branch rewrote exactly this plumbing (introducing
`DictationSession.Session.live` and wiring the sibling knob
`streamPreviewEnabled` through to `.startStreamLoop`) and left the orphan
behind.

**Failure.** A user hand-edits settings.json to `"liveStreamingEnabled": false` (or true) to
change live retyping. The value is decoded, saved back out, shown to be
persisted — and changes nothing, because the flag the machine consumes is a
compile-time `false`.

**Verification.** Confirmed, and proved by compiler. The identifier appears exactly twice in all
of Sources/: the declaration at Sources/ParlaCore/Settings.swift:45 `public var
liveStreamingEnabled: Bool = true` and the round-trip at :77
`liveStreamingEnabled = try c.decodeIfPresent(Bool.self, forKey:
.liveStreamingEnabled) ?? liveStreamingEnabled`. Nothing else. The only live-
typing input the machine gets is Sources/Parla/main.swift:37 `let liveTyping =
false` fed to :161 `self.send(.startDictation(settings: settings,
cleanupConfigured: configured, live: self.liveTyping))`, and
DictationSession.swift:91 documents it: `public var live: Bool // live in-field
typing; hard-false in the app today`. There is no dynamic escape hatch —
`Settings` is a plain struct (no `@dynamicMemberLookup`), and `grep -rn
"Mirror(\|dynamicMemberLookup"` over Sources/ returns nothing, so Codable is the
only other access and it o

### Refuted this round

- **stripNonSpeech now drops any parenthesized/bracketed/asterisked token, silently deleting real dictated words from every transcript** — The mechanism is described correctly — Sources/ParlaCore/Transcriber.swift:114
  is `return word.hasSuffix(close) && word.count > 3`, per-token filtered at line
  119, and I reproduced all four claimed losses exactly in a temporary test (since
  deleted). What fails is reachability. `stripNonSpeech` has exactly one non-test
  caller, Sources/ParlaCore/Transcriber.swift:98: `return Self.stripNonSpeech(text

- **Invariant #1's enforcement point (canEraseTyped) has no test at all — only the effects that route through it are tested** — Two of the finding's load-bearing claims are wrong. (a) "the branch's new swap
  effect" — canEraseTyped is byte-identical on main (`git show
  main:Sources/ParlaCore/Inserter.swift` L176-181 == branch L196-202; `git diff
  main...HEAD -- Sources/ParlaCore/Inserter.swift` touches only chunkUTF16's
  default, typeUnicode's sleep/comment, `FocusTarget: Sendable`, and
  `focusTarget(secureInput:)`), and main a

- **testConvertPassthroughAt16kMono asserts a count over an all-zero buffer — the passthrough could return anything** — The description of the one test is accurate, but its consequence is not — two
  other existing tests already cover that exact branch with signal assertions, so
  the prescribed mutation does not survive the suite.  I applied the finding's own
  mutation to a scratchpad COPY of the package (repo untouched) —
  /Users/daksh/mySpace/code/wisper/Sources/ParlaCore/AudioRecorder.swift:524-528:
  func convert

- **Catalog well-formedness assertions restate the implementation** — The finding's core claim is factually wrong. ModelCatalogTests.swift:44 is
  `XCTAssertEqual(m.filename, "ggml-\(m.id).bin")` — only `m.id` is interpolated;
  the `ggml-` prefix and `.bin` suffix are golden literals in the TEST file, not
  derived from ModelCatalog.swift:27 `public var filename: String {
  "ggml-\(id).bin" }`. So the stated failure scenario is inverted: renaming the
  template to `whisper-\

- **Metrics duplicates Trace's stamp store, lock and first-stamp-wins rule** — The three facts are right; the conclusion is backwards. The asymmetric fan-out
  IS the reason two stores exist.  1) The "missing" stamp is on the realtime audio
  thread.
  /Users/daksh/mySpace/code/wisper/Sources/ParlaCore/AudioRecorder.swift:305-315,
  inside the AVAudioEngine input tap block:     input.installTap(onBus: 0,
  bufferSize: 4096, format: format) { [weak self] buf, _ in         ...         T

- **scripts/download-model.sh is a second, unverified download path with a model list that no longer matches the catalog** — The "unverified" premise is wrong: verification is at LOAD, not at download, and
  it gates whatever put the file there. `Sources/Parla/main.swift:234-241`: `let
  path = store.load().whisperModelPath ?? WhisperTranscriber.defaultModelPath()` …
  `if let bad = ModelCatalog.verifyInstalled(path: path)` → refuse.
  `verifyInstalled` (ModelCatalog.swift:175-191) keys only on location + filename
  — `url.deleti

- **Test hand-rolls a 16 kHz mono WAV writer that RecordingStore already provides** — The finding's load-bearing claim — "in the same branch, a second AVAudioFile-
  based writer inline in this test" — is false. That writer is pre-existing code
  on main, untouched by this branch. `git show
  main:Tests/ParlaCoreTests/EvalNormalizeTests.swift` returns it byte-identical,
  lines 8-36: "let file = try AVAudioFile(forWriting: url, settings: settings)".
  `git diff main...HEAD -- Tests/ParlaCoreT

---

## Round 2 — round 1's fixes

Fixes are unreviewed code. Reviewing commit `de20782` itself.

11 confirmed, 1 refuted.

### [MAJOR] warm=true latch keeps an input unit built without mic permission, so a later TCC grant never takes effect until relaunch

`Sources/ParlaCore/AudioRecorder.swift:484` · dimension: regression

**Defect.** prepare() now runs at launch (Sources/Parla/main.swift:128) and latches `warm =
true` unconditionally — before any permission check, and it is never cleared
(only assignment in the file is line 282). The new authorization guard is inside
warmUp() (line 296) and therefore only gates the *warm* build; start()'s cold
path (lines 438-445) has no such check and builds the engine whatever TCC says.
With `warm` true, stop()'s teardown condition `!warm ||
isBluetooth(boundDevice)` is false, so that unit is kept running forever, and
the next start() will not rebuild it either (engine.isRunning is true and
boundDevice == device, line 425/438). By the commit's own premise, added at
lines 291-295 — "An input unit started before TCC grants the mic runs happily
and delivers zeros; the later grant never reaches a unit that is already going"
— the cold start() path reproduces exactly the permanently-silent latch the
guard was added to prevent. At 927bb8f prepare() had no call site, `warm` was
always false, so stop() always tore down and the next press rebuilt against the
fresh grant.

**Failure.** Fresh install. The user dismisses or denies the mic prompt (or presses fn while
it is still unanswered); the first dictation's start() builds an input unit that
yields zeros; stop() keeps it because warm is true. The user then grants
Microphone in System Settings. Every subsequent dictation still records silence
("Parla heard nothing") until Parla is relaunched — start() reuses the same
running, pre-grant unit. Onboarding reproduces it directly: "Skip this step"
past the permission page, press Start on the tryout, then go grant the mic and
try again.

**Verification.** Cited code matches exactly. main.swift:128 calls prepare() at launch, right
after requestPermissions() (line 115), whose AVCaptureDevice.requestAccess is
async — so on a fresh install the status is still .notDetermined when prepare()
runs. prepare() (AudioRecorder.swift:281-284) sets warm = true BEFORE calling
warmUp(), and the new authorization guard is inside warmUp() at line 296, so it
gates only the warm build, never the latch. warm is declared at line 44,
assigned only at line 282, and never cleared.  The cold path is unguarded and
reachable. The only authorizationStatus/requestAccess reads in Sources/ are
main.swift:336/345 (log + menu glyph), HubModel.swift:96/103/107 (Hub display +
Allow button), and warmUp() itself. Both production callers of recorder.start()
— Dictation.swift:58 (.applyPreferencesAndStartCapture) and Onboarding.swift:269
(tryoutStart(), which gates only on sess

### [MAJOR] Warm latch defeats the new mic-permission gate: an engine opened before TCC grant never gets rebuilt, so every later dictation is silent

`Sources/ParlaCore/AudioRecorder.swift:484` · dimension: newbugs

**Defect.** `prepare()` (AudioRecorder.swift:281-284) sets `warm = true` unconditionally,
*before* the new authorization guard at line 296 decides whether to build.
`warm` is never set back to false anywhere in the file (grep: only line 44 `=
false` and line 282 `= true`), and `main.swift:128` calls `prepare()` during
`applicationDidFinishLaunching`, before `hotkey.start()` at line 205.
`start()`'s cold path (line 441) has no authorization guard at all — by design,
per the comment at 293-295 ("start()'s cold path is unaffected, and the stop()
after the first dictation re-warms for real"). But that claim only held while
`warm` was always false. Now `stop()`'s teardown at line 484 is `if !warm ||
isBluetooth(boundDevice)`, and `warm` is true from launch, so the engine built
by the unauthorized cold `start()` is *not* torn down. `warmUp()` at 485 then
no-ops on `!engine.isRunning`.  The result is the exact failure the guard at 296
was added to prevent, just reached through `start()` instead of `warmUp()`: a
permanently running input unit that was started without the grant. Per the
commit's own stated premise ("the later grant never reaches a unit that is
already going"), it delivers zeros forever. Before this commit `warm` was always
false, so `stop()` always tore down and the next `start()` rebuilt with the
grant in effect — this is newly introduced.

**Failure.** Fresh install. `applicationDidFinishLaunching` fires `requestPermissions()`
(async TCC prompt) then `recorder.prepare()` → `warm = true`, `warmUp()` bails
at line 296 (`.notDetermined`). The user grants Accessibility first and
defers/dismisses the mic prompt, then presses fn to test. `start()` →
`engine.isRunning == false` → `build(device:)` at line 441 succeeds
(AVAudioEngine starts and delivers silence without the grant). fn-up → `stop()`
→ `!warm` is false and `boundDevice` is not Bluetooth → **no teardown** →
`warmUp()` no-ops because the engine is still running. The user then grants
Microphone in System Settings. Every subsequent dictation reuses that same
already-running unit (line 438 `if !engine.isRunning` is false) and transcribes
silence — "Parla heard nothing" forever, until the app is relaunched.

**Verification.** Verified line-by-line against the committed blob; every citation is exact and
the path is reachable.  1. `prepare()` (AudioRecorder.swift:281-283) sets `warm
= true` unconditionally and only then calls `warmUp()`, whose new authorization
guard sits at line 296 — the latch is set on the far side of the gate. 2. `warm`
is write-once. Exhaustive grep of the file yields exactly two assignments: line
44 `private var warm = false` (initializer) and line 282 `warm = true`. Nothing
resets it, and `AppDelegate.recorder` is a single stored `let`, never recreated.
3. `main.swift:128` calls `recorder.prepare()` inside
`applicationDidFinishLaunching`; `hotkey.start()` is line 205. So `warm` is true
before the first fn edge can ever be delivered. 4. `start()`'s cold path
(438-441) has no authorization check, and nothing upstream supplies one —
`Dictation.swift:58` is a bare `try recorder.start()`. `mi

### [MAJOR] Hands-free superset match swallows front-app chords when the fn bit is synthetic (no dictation in flight)

`Sources/ParlaCore/Hotkey.swift:302` · dimension: safety

**Defect.** The comment justifying the relaxation claims the branch "can only fire while
that trigger is physically held — it can never steal a chord from the front
app". That premise is false for any hands-free key macOS auto-decorates with the
fn flag, as this very file states at Hotkey.swift:19-21 ("macOS also sets this
on arrows, Home/End/Page and the F-keys with no fn physically held").
HotkeyBindings.problem() (line 193) only requires that handsFree.modifiers
*contains* the trigger — a chord bound to an arrow/Home/End/Page/F-key satisfies
that with the synthetic bit and never requires the physical key. Exact matching
used to bound the damage to that one bare key; the superset now matches the key
with ANY additional modifiers, and the `.idle` arm (line 310) falls through to
`return true`, so process() returns nil and the event is destroyed without
emitting an edge, without a log line, and without any HUD.

**Failure.** In the Hub, record hands-free by pressing the Right arrow: ShortcutRecorder
(HubPages.swift:196) stores KeyChord(124, [.fn]) because NSEvent sets .function
on arrows, and problem() accepts it silently. Parla is idle, no key is held. In
any app the user presses ⇧→ / ⌥→ / ⌘→: keyDown(124, [.fn,.shift]) → [.fn,.shift]
⊇ [.fn] → session == .idle → break → return true. Shift-selection and word/line
navigation stop working system-wide with no dictation running. Second reachable
case with no exotic key at all: pushToTalk rebound to control (a rebind
problem() explicitly advertises) plus handsFree = ctrl+Space — ⌃⌘Space (Emoji &
Symbols) now latches hands-free and swallows the Space instead of cancelling and
passing through, which is exactly what the deleted
testExtraModifierDoesNotLatchHandsFree asserted.

**Verification.** Confirmed by reading the commit and proved with a temporary test (deleted after
the run).  CODE IS AS DESCRIBED. Hotkey.swift:301-302 replaced the exact
`bindings.handsFree.matches(keyCode, modifiers)` with `keyCode ==
bindings.handsFree.keyCode, modifiers.isSuperset(of:
bindings.handsFree.modifiers)`. `KeyChord.matches` (line 54) is untouched and
still exact, so this is a real widening, not a refactor. The new comment does
assert the branch "can only fire while that trigger is physically held — it can
never steal a chord from the front app", and lines 19-21 of the same file
contradict it verbatim: "macOS also sets this on arrows, Home/End/Page and the
F-keys with no fn physically held". `HotkeyBindings.problem()` line 193 is only
`!handsFree.modifiers.contains(trigger)`, which a synthetic .fn satisfies. The
`.idle` arm is `break` -> `return true`, emitting no edge, no NSLog, no HUD; `pr

### [MINOR] Hands-free superset match now swallows ⌘/⌃/⌥+Space while push-to-talk is held

`Sources/ParlaCore/Hotkey.swift:302` · dimension: regression

**Defect.** The only extra modifier the latch has to tolerate is `.shift` (command mode
holds it by definition, per the comment at lines 299-300). `isSuperset`
tolerates every modifier, so any `trigger + X + latchKey` chord now latches and
returns true (swallowed). The justification written at lines 297-298 — "it can
never steal a chord from the front app" — does not hold: while the trigger is
held, the pre-existing design explicitly forwarded such chords, cancelling the
dictation and returning false (lines 320-324, "any other key while the trigger
is held cancels (and passes through)"). The deleted test
testExtraModifierDoesNotLatchHandsFree asserted precisely that fn+⌘+Space must
cancel and pass through, and it was replaced rather than re-derived.

**Failure.** User holds fn to dictate and presses ⌘Space (Spotlight) or ⌃Space (previous
input source). Before: the dictation cancelled and the chord reached the system,
so Spotlight opened. Now: keyCode 49 with [.fn, .cmd] is a superset of [.fn], so
keyDown returns true, the event is swallowed, Spotlight never opens, and the
dictation silently latches into hands-free and keeps recording after fn is
released.

**Verification.** Confirmed by reproduction at HEAD (de20782). Hotkey.swift:301-302 matches the
hands-free chord with `modifiers.isSuperset(of:)`, so with the defaults
(pushToTalk=fn, handsFree=fn+Space) a keyDown of keyCode 49 with [.fn, .cmd]
matches. Reachable path: user holds fn (handle(63,[.fn]) -> session == .push,
.down fired), presses ⌘Space; process() only filters `suspended`,
Inserter.syntheticMarker and autorepeat, none of which apply to a first real
press, and KeyChord.Modifiers(event.flags) yields [.fn,.cmd] since fn is
physically held. A temporary test (written, run, deleted) shows
keyDown(49,[.fn,.cmd]) now returns true and emits .handsFree; before the commit
`matches` required exact equality, [.fn,.cmd] != [.fn], so it fell to line 320
and returned false with .cancel. Same for .ctrl and .opt. Downstream
(Sources/Parla/main.swift:192) .handsFree -> .handsFreeLatched keeps the mic
recording

### [MINOR] Metrics.snapshot() hands the parked bucket to whichever dictation writes history next and never marks the live one snapshotted, locking the collector into a permanent off-by-one

`Sources/ParlaCore/History.swift:194` · dimension: newbugs

**Defect.** `snapshot()` returns `parked` whenever it is non-nil, with no check that the
caller is the parked dictation — and on that branch it returns early, so
`current.snapshotted = true` (line 198) never runs. `awaitingHistory` is
`stamps[.landed] != nil && !snapshotted` (line 110), so a bucket that was
skipped this way stays "awaiting" and gets parked at the *next* fn-down, which
makes the next write return the wrong bucket again. The state is self-sustaining
once entered.  The entry point is a dictation that stamps `.landed` but never
writes history. `.trace(.landed)` is emitted unconditionally at
DictationSession.swift:510, but `.appendHistory` is gated on
`s.settings.historyEnabled` at both 516 and 571. So any dictation taken while
history is off leaves `current.awaitingHistory == true` permanently, and because
it also never stamps `.cleanedSwapped` when cleanup is unconfigured,
`polishResolved` stays false — so line 158 (`if parked?.polishResolved == true {
parked = nil }`) can never retire it, and `update()` at line 179 starts routing
the *new* dictation's values into it as well.  The two new tests cover the
intended park/retire cycle but both keep history effectively on, so neither
exercises a `.landed` that is never snapshotted.

**Failure.** User turns History off in the Hub, dictates once (cleanup unconfigured, so
`willPolish == false`): `.landed` is stamped at DictationSession.swift:510, the
`if s.settings.historyEnabled` at 516 skips `.appendHistory`, so `snapshot()` is
never called and d1's bucket has `awaitingHistory == true, polishResolved ==
false`. User turns History back on and dictates again (d2). At d2's fn-down,
line 158 does not clear the park (d1 is unresolved) and line 159 parks d1. d2's
`Metrics.shared.update { $0.model = ... }` (Dictation.swift:262) hits line 179
and writes d2's whisper model into d1's bucket. d2's `.appendHistory` calls
`snapshot()`, which takes the `if let p = parked` branch at 194 and returns
**d1's** timings — so d2's history row shows d1's captureMs/asrMs — while
leaving `current(d2).snapshotted == false`. At d3's fn-down d2 is parked, and
d3's row gets d2's numbers. Every history entry from then on carries the
previous dictation's metrics, for the life of the process.

**Verification.** Confirmed by running the real reducer end-to-end. Code is exactly as cited:
History.swift:194 returns `parked` whenever it is non-nil with no check that the
caller is the parked dictation, and returns early so `current.snapshotted =
true` (line 198) never runs; `awaitingHistory` (line 110) is `stamps[.landed] !=
nil && !snapshotted`. The whole park mechanism is new in de20782 (before it,
`mark(.fnDown)` just cleared the dict), so this is a fix-introduced bug.  Entry
point is reachable: DictationSession.swift:510 appends `.trace(.landed)`
unconditionally, while `.appendHistory` is gated on `s.settings.historyEnabled`
at 517 and 571. The existing test
`testUnverifiedDiffFinalizeWithHistoryOffIsSilent`
(DictationSessionTests.swift:269) already sets up exactly this state (asserts no
`.appendHistory` with history off) but never inspects the trace stamp. The
toggle is user-facing at Sources/Pa

### [MINOR] Hands-free superset match swallows fn+cmd/ctrl/opt+Space and silently latches the dictation instead of cancelling it

`Sources/ParlaCore/Hotkey.swift:302` · dimension: newbugs

**Defect.** The fix replaced the exact `bindings.handsFree.matches(keyCode, modifiers)` with
`keyCode == bindings.handsFree.keyCode && modifiers.isSuperset(of:
bindings.handsFree.modifiers)`. Command mode needed the `.shift` case, but a
superset test admits `.cmd`, `.ctrl` and `.opt` too. `HotkeyBindings.problem()`
only guarantees that `handsFree.modifiers` *contains* the push-to-talk trigger
(line ~200); it puts no ceiling on the extra bits an event may carry.  So with
the default bindings (pushToTalk = fn, handsFree = fn+Space), any `fn +
<cmd|ctrl|opt> + Space` keyDown now enters this branch. In `.push` it takes the
`.handsFree` case and `return true` — it converts the session and swallows the
event — where the previous exact match fell through to line 320 (`if session ==
.push` → `.cancel`, `return false`), which cancelled the dictation and let the
chord reach the front app. The comment at 294-297 ("it can never steal a chord
from the front app") is only true for chords that lack the trigger; a chord that
includes it is exactly what is being stolen here.

**Failure.** User holds fn to dictate, then presses ⌘Space to open Spotlight. The keyDown
arrives with `keyCode == 49` and `modifiers == [.fn, .cmd]`, which is a superset
of `[.fn]`, so line 302 matches: the session flips `.push → .handsFree`,
`onEdge?(.handsFree)` fires and the event returns `true` (swallowed). Spotlight
never opens, the dictation is not cancelled, and the recording now survives fn
release — the HUD reads "hands-free" for a dictation the user believed they were
abandoning. The mic stays hot until the 10-minute cap or until the user types a
Space or Return, at which point line 325 swallows that keystroke and finalizes,
inserting the stray transcript into whatever has focus.

**Verification.** Confirmed by reading the commit and by a temporary failing test (written, run,
deleted).  Code is as cited. de20782 replaced the exact
`bindings.handsFree.matches(keyCode, modifiers)` with `keyCode ==
bindings.handsFree.keyCode, modifiers.isSuperset(of:
bindings.handsFree.modifiers)` at Sources/ParlaCore/Hotkey.swift:302.
`KeyChord.matches` is `self.modifiers == modifiers`, so the pre-fix test was
exact and `[.fn] != [.fn,.cmd]` fell through to the `session == .push` arm →
`.cancel`, `return false`.  The claimed ceiling really is absent:
`HotkeyBindings.problem()` asserts only `handsFree.modifiers.contains(trigger)`
(plus "needs a real key" / "can't be Esc"). Nothing bounds the extra bits an
event carries.  Reachable — no guard anywhere on the path: - `process()` case
`.keyDown` filters only `Self.suspended`, `Inserter.syntheticMarker` and
autorepeat, then hands `KeyChord.Modifiers(event

### [MINOR] finish()'s no-model early return keeps the stashed WAV without ever consulting the secure signal

`Sources/Parla/Dictation.swift:212` · dimension: safety

**Defect.** The commit correctly hoisted `Inserter.focusTarget()` out of the `raw != nil`
block so `RecordingStore.resolve(..., secure:)` also runs on the no-transcript
path — the one path that KEEPS the file. But `stash()` runs at line 211, one
line above the `guard let transcriber`, and that return path never reaches
resolve at all. RecordingStore.resolve's own doc says `secure` "outranks both"
and exists to stop audio outliving a landing that turned secure; on this path it
outlives it and sits on disk for RecordingStore.retentionDays (7). It is the
same class of gap the commit set out to close, on the sibling early return.

**Failure.** Model file missing or damaged, so loadModel() refused it (transcriber nil,
modelReady false). The user presses fn in an ordinary field, speaks, and clicks
into a password field — or 1Password/sudo takes secure keyboard input — before
releasing. finish() writes the WAV, logs "no whisper model loaded", and returns.
No focus sample is taken, so the recording of that utterance stays in
~/Library/Application Support/Parla/recordings for a week, while every other
secure-drift path deletes it.

**Verification.** CONFIRMED — the cited code is exactly as described and the path is reachable end
to end.  Cited code (Sources/Parla/Dictation.swift): `let recording =
RecordingStore.shared.stash(samples)` at :211, `guard let transcriber else { …
return }` at :212–216 with the `return` at :215, and the only
`RecordingStore.shared.resolve(…)` at :297. That is the sole `return` between
the stash and the resolve — I proved it with a temporary source-scan test that
failed with `("[215]") is not equal to ("[]")`, then deleted the file.
Reachability, checked against every caller: 1. The reducer has no model input
whatsoever. `DictationSession.Event` / `Session` carry no model state;
`.startDictation → .applyPreferencesAndStartCapture → .recorderStarted →
.focusSampled → .stopRequested → finalize()` emits `.stopCapture(discard:
false)` + `.transcribeFinal` unconditionally (DictationSession.swift:414–418). A
te

### [MINOR] Warm engine holds the mic open from launch while the shipped copy still promises Parla listens only while a key is held

`Sources/Parla/main.swift:128` · dimension: safety

**Defect.** prepare() now latches warm = true at launch and builds a running input tap that
writes every converted buffer into PreRollRing whenever no capture is live
(AudioRecorder.swift:347), and stop() no longer tears it down because `!warm` is
false (AudioRecorder.swift:484). The mic is therefore open continuously and
macOS keeps the orange indicator lit for the whole session. The behavior is
deliberate and documented in code, but two user-facing strings still promise the
opposite: Onboarding.swift:22 "Parla listens only while you hold a key" and
HubPages.swift:16 "Records while you hold fn". The only signal the user has —
the always-on indicator — now contradicts what the app told them during setup,
and 0.45 s of pre-key speech is additionally transcribed and (with cleanup
configured) POSTed to the cleanup API, i.e. audio spoken before the user decided
to dictate.

**Failure.** Fresh install, grant mic, finish one dictation. From then on the orange
recording indicator never goes out — Hub closed, no dictation, app idle in the
menu bar. A user comparing the Control Center indicator against the onboarding
sentence they were shown concludes Parla records continuously, which it does: a
rolling 1 s in-memory ring, 0.45 s of which is spliced into the next dictation
and sent for cleanup.

**Verification.** Every cited line checks out at de20782. main.swift:128 calls recorder.prepare()
unconditionally in applicationDidFinishLaunching; prepare() latches warm = true
and warmUp() builds a running engine gated only on TCC authorization and a non-
Bluetooth transport — there is no user setting for it (Settings.swift has no
warm/pre-roll knob). AudioRecorder.swift:347 writes every converted tap buffer
into PreRollRing whenever no capture is live, and stop() at
AudioRecorder.swift:484 (`if !warm || isBluetooth(boundDevice) { teardown() }`)
never tears down once warm is true, with the trailing warmUp() a no-op on a
running engine. No other idle path stops it: scheduleRebuild() tears down only
to re-warm, start() only on a device mismatch. The scenario is reachable as
written — fresh install bails at the TCC guard, the first dictation takes
start()'s cold path, and its stop() leaves the engine runnin

### [MINOR] Pasteboard-invariant test attributes writes to the nearest preceding `func ` line, so an unsanctioned write next to copy() passes

`Tests/ParlaCoreTests/DictationSessionTests.swift:823` · dimension: tests

**Defect.** This is the only test certifying ISSUES.md's "the pasteboard is never written
except by the Hub's explicit Copy button". Its owner heuristic is
`lines[...i].last { $0.contains("func ") }` — it only requires that *some*
`func` line precede the write, never that the write is inside that function's
body. `init`, `deinit`, computed and stored properties, `subscript` and nested
types contain no `func `, so any of them placed after `copy`'s closing brace and
before the next `func ` line in HubModel.swift is folded into the key
`"HubModel.swift: func copy(_ text: String) {"` — the exact string the test
expects — and the set comparison still matches. That region is precisely where a
developer would add a clipboard helper.

**Failure.** Verified in the scratch copy: inserting `var sneak: Bool {
NSPasteboard.general.setString("every dictation", forType: .string) }` into
Sources/Parla/Hub/HubModel.swift between the end of `copy(_:)` (line 149) and
`func openPrivacyPane` (line 151) is a real, unsanctioned pasteboard write, and
`swift test --filter testTheOnlyPasteboardWriteIsTheHubsCopyButton` still
reports `passed (0.033 seconds)`. The same write placed in StatusMenu.swift does
fail the test, so the hole is specifically the sanctioned function's own file.

**Verification.** Confirmed by running the real test, not just by reading. The cited code at
DictationSessionTests.swift:823 is verbatim as claimed: `lines[...i].last {
$0.contains("func ") }` walks backwards for the nearest preceding `func ` line
and never verifies the write is inside that function's body. The test was
introduced by de20782 (`git log -S` returns only that commit), and it is the
only clipboard guard in the suite (grep over Tests/ for pasteboard|clipboard
hits nothing else), certifying ISSUES.md:78 "The only remaining pasteboard write
is the Hub's explicit Copy button."  HubModel.swift: `func copy` at 145, writes
at 146-147, `}` at 148, blank 149, `func openPrivacyPane` at 150 — so the
unguarded region is everything between line 145 and the next `func ` line.
Proof in an isolated clone (repo never modified; `git status` clean and `git
diff --stat` empty afterwards), three real `swift test

### [MINOR] Stash-dodge test spends most of its own timing budget on setup, and its comment misattributes the resulting flake to the product

`Tests/ParlaCoreTests/RecordingStoreTests.swift:49` · dimension: tests

**Defect.** The test claims every millisecond name for `floor(now)` and `floor(now)+1`, so
`stash()` must compute `Self.name(Date())` before wall-clock `floor(now)+2` — a
budget of 2.0 s minus the fractional part of `now`, i.e. as little as 1.0 s.
Writing the 2000 files plus `stash()`'s own `prune()` (which lists and stats all
2000) measures 0.60-0.70 s per run here, so the worst-case margin is ~0.3 s of
setup cost the test inflicts on itself. On a loaded or slower machine at ~2x,
elapsed reaches ~1.3 s and the test fails whenever `now`'s fractional part
exceeds ~0.6 — roughly 40% of runs, non-deterministically. The in-test comment
on lines 55-56 ("A failure here means the stash took more than a second, which
is its own bug report") is factually wrong about the cause: the budget is
consumed by the test's own 2000-file claim loop, not by `stash()`, so the flake
would be triaged as a product bug.

**Failure.** Three consecutive baseline runs of `swift test --filter
RecordingStoreTests/testStashDodges` took 0.608 s, 0.700 s and 0.595 s. Under
any ~2x slowdown (CI, contended disk, Rosetta, a machine under load),
`RecordingStore.name(Date())` inside `stash()` lands in second `floor(now)+2`,
whose names were never claimed; `uniqueURL` finds the base name free and returns
`…-HHmmss-SSS.wav`, so
`XCTAssertTrue(url.lastPathComponent.hasSuffix("-1.wav"))` on line 58 fails even
though the dodge is working correctly.

**Verification.** CONFIRMED with a real failing run of the shipped test. Mechanism is as
described: the test claims every millisecond name for floor(now) and
floor(now)+1, so the dodge fires only if Self.name(Date()) inside stash()
(RecordingStore.swift:62) still lands in those two seconds — budget = 2.0 -
frac(now), as low as ~1.0s. stash() calls prune() BEFORE computing the name, and
prune() -> recordings() lists, sorts and stats all 2000 files the test just
wrote, so the setup cost is charged twice inside the window. Measured in-budget
elapsed on a 10-core M4: 0.39-0.65s unloaded (setup loop 0.23-0.33s; stash
0.16-0.20s, nearly all prune); 0.72-0.90s under light load (6 CPU hogs + 1 fs
churner) leaving only 0.11s of margin at frac=0.99; 1.59-2.04s under ~3x load,
where the dodge missed at EVERY fraction tested including frac=0.05. Running the
actual shipped test under that load reproduced the failure:

### [NIT] Focus probe on the empty-transcript path wakes Electron accessibility and sleeps 50 ms on the main thread

`Sources/Parla/Dictation.swift:279` · dimension: regression

**Defect.** Inserter.focusTarget() was hoisted out of the `if raw != nil` block so the
secure signal reaches RecordingStore.resolve on the WAV-retaining path. But
focusTarget() is not a cheap read: when the classification is not
.editable/.secure it writes AXManualAccessibility into the frontmost app and
calls usleep(50_000) on the main thread before re-classifying
(Sources/ParlaCore/Inserter.swift:111-121). `.none` and `.unknown` — the usual
answers when a dictation produced nothing — both take that branch. Before this
commit a no-transcript dictation did no AX work at all. Only the `.secure` bit
is needed here, and that bit never needs the wake retry; the codebase already
treats this wake as something to avoid on turns that don't need it (see the
comment on CorrectionWatcher.isSecure, Dictation.swift:650-652).

**Failure.** A short or silent dictation with nothing focused (accidental fn press longer
than the short-tap threshold): after the whisper pass the main thread now blocks
~50 ms before the HUD hides, and Parla flips a persistent accessibility flag on
an app it is not going to type into.

**Verification.** The timing defect is real and reachable, but the finding's causal story and its
proposed remedy are both wrong.  CONFIRMED. Dictation.swift:279 `let focus =
Inserter.focusTarget()` was genuinely hoisted out of `if raw != nil` (diff vs
927bb8f). Inserter.swift:111-121 is cited verbatim at the exact line numbers:
`if result != .editable, result != .secure, let app = ...frontmostApplication`
-> AXManualAccessibility write -> `usleep(50_000)` -> re-classify. `.none` and
`.unknown` both enter it. Measured in-process: focusTarget() returning
`.unknown` cost 86.8-96.5 ms; the `secureInput: true` short-circuit cost 0.000
ms.  REACHABLE, unguarded. fn press past the short-tap threshold ->
`.stopRequested` -> `finalize()` -> `.transcribeFinal` -> `finish()` -> min-
audio floor fails (Dictation.swift:251-257) -> `raw = nil` -> line 279 probe ->
~50 ms of main-thread block before `send(.transcribed)`

### Refuted this round

- **A route change that lands during a capture (or during the rebuild debounce) is dropped and never rescheduled — the warm engine stays bound to a dead device forever** — The cited code is quoted correctly (endCapture at 378, `guard !live` at 393,
  teardown at 394/425/484, `boundDevice = device` at 338, `warm` set only by
  prepare(), which had no call site before this commit; and `boundDevice !=
  device` is genuinely a permanent no-op when inputDeviceUID == nil). But the
  wedge requires the warm engine to still be running after the route change, and
  it never is. The ma

---

## Round 3 — the twice-wrong subsystems

`AudioRecorder` and `Hotkey` had each been wrong twice. Reviewers were told to assume they still were.

9 confirmed, 4 refuted.

### [MAJOR] Hands-free stop matcher ignores modifiers entirely — ⌘Space/⌃Space/⌘Return/⇧Return are swallowed and never reach the front app

`Sources/ParlaCore/Hotkey.swift:333` · dimension: hotkey

**Defect.** The commit fixed the LATCH (line 305-308) to stop over-matching modifiers, but
the STOP check two lines below it still matches on keyCode alone: `if session ==
.handsFree, keyCode == bindings.handsFree.keyCode || keyCode == 36`. Its own
comment claims the opposite of what it does — "bare this time: the trigger has
been released, so no chord can match" — but nothing in the condition looks at
`modifiers`, so every chord built on Space or Return matches. A full sweep of
the real logic (keycodes 0...130 x all 32 modifier sets) shows `.handsFree`
swallows key 49 and key 36 for ALL 32 modifier sets, while the `.push` branch
three lines above deliberately passes the same chords through. This is the exact
defect progress.md records as a round-2 major ("fn+⌘+Space got swallowed —
Spotlight stopped opening"), unfixed in the sibling session state, and it
violates the rule KeyChord's own type doc states: never steal a chord that
belongs to the front app. The swallow's stated rationale — "a space/newline must
not land in the field before the transcript" — only applies to chords that
actually produce whitespace (bare and shift), not to ⌘/⌃/⌥ variants.

**Failure.** Default bindings. Hold fn, press Space, release fn — hands-free is latched and
recording. Now press ⌘Space: keyDown(49, [.cmd]) falls past the latch
(latch=false), past Esc, past `session == .push`, and hits line 333, which
returns true. Spotlight/Alfred/Raycast never opens — the event is killed at the
tap — and the dictation silently stops. Same for ⌃Space (input source never
switches), ⌥Space (no non-breaking space), and in Slack/Mail ⇧Return (newline
eaten) and ⌘Return (send eaten). Reproduces on every hands-free dictation with
no rebinding.

**Verification.** CONFIRMED, with two corrections to the finding.  CODE IS AS CITED.
Sources/ParlaCore/Hotkey.swift:333 reads `if session == .handsFree, keyCode ==
bindings.handsFree.keyCode || keyCode == 36` — no `modifiers` term anywhere in
the condition, while its own comment (331-332) claims "bare this time". Defaults
are pushToTalk=KeyChord(63), handsFree=KeyChord(49, .fn) (Hotkey.swift:196-197).
PROVED BY EXECUTION, not by reading. I added a temporary XCTest that drives the
real shipped sequence — handle(63,[.fn]) -> keyDown(49,[.fn]) -> handle(63,[]) —
to reach the latched state, then swept all 32 modifier sets x {49, 36}. Result:
64 swallowed, 0 passed through, and every one of the 64 also fired `.up(short:
false)`. Control case: the identical chord with fn still held (session == .push)
returns false and passes, so the commit's latch fix at 305-307 does work and
only the sibling branch was missed

### [MAJOR] Idle latch branch swallows the chord with no edge, so a twin modifier key silently eats the keystroke forever

`Sources/ParlaCore/Hotkey.swift:305` · dimension: hotkey

**Defect.** The `case .idle: break` + `return true` path (lines 316-319) swallows the hands-
free chord and fires no edge at all. Its justification — "the trigger press just
stopped the session" — assumes the trigger modifier bit can only be set while
the trigger's own key is physically held from that stop. `problem()` guarantees
handsFree.modifiers contains the trigger, but the modifier BIT is set by either
key of a left/right pair (CGEventFlags has no left/right distinction), while
`handle()` only ever sees the one keyCode it is bound to. So the premise is
false whenever the trigger is a modifier with a twin, and the branch degrades
into an unconditional keystroke black hole.

**Failure.** Configure the exact binding the repo's own test uses (HotkeyTests.swift:306):
pushToTalk = rightoption (keyCode 61), handsFree = opt+space. problem() returns
nil, so it is accepted. Press LEFT option + Space at idle: keyCode 61 never
fires so session stays .idle, but `modifiers == bindings.handsFree.modifiers`
([.opt] == [.opt]) is true, so keyDown returns true with an empty edge list.
⌥Space — Alfred's default hotkey and a common Raycast binding, and the non-
breaking space on macOS — is eaten globally with no dictation started and no
feedback. Verified against a verbatim copy of the matcher.

**Verification.** CONFIRMED, and the report understates it.  CODE IS AS DESCRIBED.
Hotkey.swift:316-319 — `case .idle: break` followed by `return true`: swallow,
no edge, no feedback.  THE JUSTIFYING PREMISE IS FALSE. The comment assumes
idle+trigger-bit means the bound key is still physically held. But `handle()`
(line 274) guards on `keyCode == bindings.pushToTalk.keyCode` — ONE keycode —
while `KeyChord.Modifiers(CGEventFlags)` (lines 34-42) maps only
`.maskAlternate/.maskControl/.maskCommand/.maskShift/.maskSecondaryFn`, all
side-agnostic (the device-dependent L/R bits macOS also sets are never read).
The file's own `modifierKey` table (lines 60-69) lists both twins per pair:
58/61 opt, 59/62 ctrl, 54/55 cmd. So the twin sets the bit while the state
machine never sees the key, session stays `.idle` forever, and the branch
becomes an unconditional black hole.  REACHABLE — TWO INDEPENDENT PATHS, BOTH PR

### [MAJOR] Pressing the twin of a rebound push-to-talk trigger leaves the session stuck in .push with the mic still recording

`Sources/ParlaCore/Hotkey.swift:284` · dimension: hotkey

**Defect.** `handle()` guards on `keyCode == bindings.pushToTalk.keyCode`, so flagsChanged
from the twin modifier key is dropped, but `active` is computed from the shared
modifier BIT, which either key sets. When the bound key is released while its
twin is still held, `active` is still true and session is .push, so none of the
three branches match (the only .push branch requires `!active`) and the state
machine silently keeps the session open. No .up is ever emitted for that press.

**Failure.** pushToTalk = rightoption (61). Hold right option (session .push, recording
starts) → also press left option (keyCode 58, dropped by the guard) → release
right option: flagsChanged(61, [.opt]) because left is still down, so
active=true, session stays .push → release left option (58, dropped). The
recording never ends: the mic stays open and the HUD stays up until Esc, the
10-minute cap, or a full press+release of the right option key with no other
option key held. Verified: after the sequence the machine reports session=push
with edges [down] only.

**Verification.** CONFIRMED, and worse than filed. Hotkey.swift:271-288 is exactly as described:
the guard at 274 is side-SPECIFIC (`keyCode == bindings.pushToTalk.keyCode`)
while `active` at 276 reads the side-AGNOSTIC modifier bit
(`modifiers.contains(trigger)`). The three branches have no `active && session
== .push` arm, so that combination is a silent no-op.  PROVED with a temporary
probe (ZZTwinModifierProbeTests, 4/4 pass, deleted afterwards; no implementation
file touched, `git diff HEAD` empty). With
pushToTalk=KeyChord(61)/handsFree=KeyChord(49,.opt): handle(61,[.opt]) ->
handle(58,[.opt]) -> handle(61,[.opt]) -> handle(58,[]) emits only [.down] and
no .up. The session is observably still .push: the next ordinary keyDown routes
to .cancel (line 326) instead of the idle chords. Same hole on control (59/62)
and command (54/55). The default fn (63) has no twin, which is why 373/373
stayed green.  R

### [MAJOR] Metrics park is destroyed mid-flight by a dictation that never lands, re-creating the permanent off-by-one

`Sources/ParlaCore/History.swift:161` · dimension: rest

**Defect.** The rework replaced a two-step retire (`if parked?.polishResolved == true {
parked = nil }; if current.awaitingHistory { parked = current }`) with an
unconditional overwrite: `parked = current.awaitingHistory ? current : nil`. The
`else nil` branch now evicts a park whose POST is still outstanding whenever
`current` is a dictation that never landed. `.trace(.fnDown)` is emitted
unconditionally by `.startDictation` (DictationSession.swift:283), before any
focus check, so every stray tap, Esc-cancel, silent/short press, and password-
field refusal (`.focusSampled` secure at DictationSession.swift:294,
`.cancelRequested` at 341, `transcribed` with `raw == nil` at 445) produces a
`current` with `awaitingHistory == false` — and each one of those wipes the
previous dictation's park. Contrary to the new comment at History.swift:196-202,
an orphan park is close to unreachable in-process: `Pipeline.clean` has a raw-
transcript fallback, so `.cleanReady` (and therefore `.trace(.cleanedSwapped)`)
is delivered on every failure. The rework trades a near-unreachable orphan for a
common eviction. Confirmed with a throwaway XCTest against the real `Metrics`
class (three probes, all failed; file since deleted).

**Failure.** Dictation 1 lands with its cleanup POST in flight (parked). The user taps fn
accidentally / hits Esc / speaks nothing — dictation 2 stamps `.fnDown` but
never lands. The user presses fn for dictation 3: `current(2).awaitingHistory`
is false, so `parked = nil` and dictation 1's bucket is gone. Dictation 1's POST
then returns: `update{promptTokens, cleanupModel}` and `.trace(.cleanedSwapped)`
are routed to dictation 3's live bucket, and dictation 1's `.appendHistory`
calls `snapshot()`, which now returns dictation 3's bucket. Measured: dictation
1's row loses captureMs/cleanupMs entirely; dictation 3's row is billed
dictation 1's promptTokens=400 — and since `snapshot()` does not clear
`current.pending`, those same tokens are emitted in BOTH rows, so
`CleanupCostEstimate.over` (Cleanup.swift:225-240) double-charges that dictation
in the Hub's USD figure. Worse, that `snapshot()` sets `current(3).snapshotted =
true` before dictation 3 has even landed, so at dictation 4's fn-down
`current(3).awaitingHistory` is false and dictation 3 is never parked either —
the misattribution then repeats for every subsequent dictation whose polish is
still out at the next fn-down. Probe: dictation 3's row came back with
`captureMs == nil` instead of 1000.

**Verification.** Cited code is exactly as described, and the path is reachable in the shipped
app.  CODE (verified verbatim): `Sources/ParlaCore/History.swift:161` `parked =
current.awaitingHistory ? current : nil`. The `else nil` arm fires whenever the
dictation that just ended never reached `.landed`, and it drops a park whose
POST is still outstanding.  REACHABILITY (each link checked, no blocker found):
- `DictationSession.swift:283` — `.startDictation` returns `[.trace(.fnDown),
…]` unconditionally, before any focus/permission check. `Hotkey.swift:280` emits
`.down` on the fn press regardless of duration (main.swift:172 forwards it), so
an accidental Globe tap stamps `.fnDown`. `Dictation.swift:184/191-194` routes
`.trace` → `Metrics.shared.mark`. - The tap then releases as `.up(short: true)`
→ `.cancelRequested(silent: true)` (main.swift:188, DictationSession.swift:341),
whose effect list contains

### [MAJOR] README's "idle audio ... never written to disk" is false for the 0.45 s pre-roll, which is stashed as WAV on every dictation

`README.md:133` · dimension: rest

**Defect.** The new paragraph states "Idle audio goes into a 1-second in-memory buffer that
is continuously overwritten and never written to disk; only what you say while
holding the hotkey is transcribed, plus the 0.45 s before the press". The two
halves contradict each other against the code: `PreRollRing.take()` returns the
newest 7,200 samples (0.45 s) and `AudioRecorder.start()` assigns them straight
into `samples` (AudioRecorder.swift:410), `stop()` returns that same array, and
`finish()` writes it to disk verbatim via `RecordingStore.shared.stash(samples)`
(Dictation.swift:212) before whisper runs. So the newest 0.45 s of the ring
reaches disk on literally every dictation. It is deleted when a transcript
exists, but every failure path deliberately keeps it for `retentionDays = 7`
(RecordingStore.swift:38, 84-86), and `PARLA_KEEP_RECORDINGS=1` keeps successful
ones too. The README never mentions the recordings directory anywhere (grep for
"recordings" hits only the `cleanup.*` config lines), so this sentence is a
reader's only statement about audio persistence — and it is the sentence the
commit message itself advertises as the accurate replacement.

**Failure.** A user reads "never written to disk", dictates in a meeting, and the dictation
fails (no whisper model loaded, empty transcript below the min-audio floor, or a
crash in the whisper pass — the exact case RecordingStore exists for). A 16 kHz
WAV containing 0.45 s of room audio captured *before* they pressed the hotkey,
plus the whole utterance, now sits in ~/Library/Application
Support/Parla/recordings for 7 days, a persistence the README told them could
not happen.

**Verification.** Confirmed, code as described (one citation off: the assignment is
AudioRecorder.swift:455, not :410). Chain: PreRollRing.prependSamples = 7_200
(0.45 s @16 kHz) and take() returns Array(samples.suffix(7_200))
(AudioRecorder.swift:520-548); start() does `samples = preRoll.take(...)`
(:454-455); stop() returns that array plus live capture (:480-513);
Dictation.perform(.stopCapture) stores it in `captured` (:72-73),
.transcribeFinal hands it to finish() (:102-105), and finish() calls
RecordingStore.shared.stash(samples) unconditionally at Dictation.swift:213,
before whisper — no setting gates it. resolve() keeps the file whenever
transcript is nil/empty and focus is not secure (RecordingStore.swift:87-89),
and prune only deletes past retentionDays = 7. The warm engine that feeds the
ring is the default: recorder.prepare() runs at launch (main.swift:128,
StatusMenu.swift:195). I replayed exa

### [MINOR] Idle latch has no shift tolerance while the live latch does, so the command-mode stop gesture leaks a Space into the front app

`Sources/ParlaCore/Hotkey.swift:306` · dimension: hotkey

**Defect.** The two arms of the ternary disagree about shift: the live arm unions .shift
both ways precisely because command mode holds shift, but the idle arm is a bare
`==`. The idle arm's job is to swallow the chord's key after a trigger-press
stop — and in command mode shift can still be held at that moment, which is the
same premise the live arm was written for.

**Failure.** Command mode hands-free: hold fn+shift (.down(command: true)), press Space
(latch), release fn but keep shift held, press fn again to stop (.up fires,
session .idle), then press Space as part of the same fn+Space stop gesture.
modifiers is [.fn, .shift] != [.fn], so the latch branch is skipped and keyDown
returns false — the Space reaches the front app. In command mode the user's
selection is still live at that instant, so the leaked space replaces the
selected text right before the transform is applied. Verified: edges [down(cmd),
handsFree, up] and the trailing Space swallowed=false.

**Verification.** CONFIRMED, and the cited code is exactly as described.
Sources/ParlaCore/Hotkey.swift:305-307:      let latch = session == .idle
? modifiers == bindings.handsFree.modifiers         : modifiers.union(.shift) ==
bindings.handsFree.modifiers.union(.shift)  Reproduced with a temporary test
(written, run, deleted; tree verified clean, 44/44 HotkeyTests still green). The
failing probe:      handle(63, [.fn, .shift], 0)          -> .down(command:
true)     keyDown(49, [.fn, .shift], 0.1)       -> true  (latch, swallowed)
handle(63, [.shift], 0.3)             -> fn released, shift still held, no edge
handle(63, [.fn, .shift], 5)          -> .up(short: false), session = .idle
keyDown(49, [.fn, .shift], 5.05)      -> FALSE  <-- Space reaches the front app
The control with shift released at the same point returns true (swallowed), so
shift is the only difference.  Why it is rea

### [MINOR] Hand-written arrow / Home / End / Page / F-key chords in settings.json can never match, because macOS adds the fn bit at runtime

`Sources/ParlaCore/Hotkey.swift:20` · dimension: hotkey

**Defect.** The Modifiers.fn doc claims the synthetic bit is "Harmless: recording and
matching read the same bit from the same OS, so such a chord still round-trips."
That holds for the Hub recorder, but not for the hand-edited path the Codable
doc advertises two screens down ("settings.json stores \"ctrl+cmd+v\", not a
keycode: hand-editable"). A hand-written chord omits fn, `matches` is exact, and
the live event always carries it.

**Failure.** Write {"hotkeys": {"pasteLast": "ctrl+cmd+left"}} into settings.json. It decodes
cleanly to KeyChord(123, [.ctrl, .cmd]), problem() returns nil so
refreshBindings accepts it and no banner appears, but the real ⌃⌘← event arrives
as [.ctrl, .cmd, .fn] and never matches. The binding is silently dead and the
Hub shows it as active.

**Verification.** CONFIRMED, and it is slightly worse than the finding states. I tried to refute
it on three fronts and failed on all three.  1. Cited code is exactly as
described. `matches` is strict equality (Hotkey.swift:54-56). The decoder builds
`codes` from `names`, which contains 115/116/117/119/121/123-126 and F1-F20
(Hotkey.swift:80-86), so "ctrl+cmd+left" decodes cleanly to KeyChord(123,
[.ctrl, .cmd]). `problem()` has no rule that touches it, so `refreshBindings`
(Hotkey.swift:355-360) installs it.  2. The OS premise is this repo's own, and
it is the same physical bit on both paths. Hotkey.swift:19-21,
Hotkey.swift:302-304 (that second comment was ADDED by the target commit
442ba4e), and shipped test HotkeyTests.swift:243-253 all assert macOS sets fn on
arrows/Home/End/Page/F-keys. The tap cannot be reading a different bit than the
recorder: NSEventModifierFlagFunction = 1 << 23 (SDK AppKit/NSE

### [MINOR] "Keeps the mic open from launch" / "orange indicator for as long as Parla is running" is stated unconditionally, but warmUp() refuses Bluetooth inputs

`README.md:131` · dimension: rest

**Defect.** `warmUp()` bails on two gates before building anything: `guard
AudioRecorder.micAuthorized()` and `guard !AudioRecorder.isBluetooth(device)`
(AudioRecorder.swift:296-303). The Bluetooth gate is deliberate and documented
in the code (holding a BT input open drags the link to 16 kHz HFP/SCO). For
anyone whose input is AirPods or any BT headset — a large share of users — the
engine is never warm: the indicator is lit only during dictation, and every
press still pays the 240-700 ms the paragraph claims has been removed.
README.md:127, HubPages.swift:16, Onboarding.swift:25 and Onboarding.swift:128
all make the same unconditional promise. The old copy was false in one
direction; this is false in the other for a whole class of users.

**Failure.** User with AirPods as the default input reads "Parla keeps it open from launch so
dictation starts instantly" and "macOS shows its orange mic indicator for as
long as Parla is running". Neither is true on their machine: no indicator while
idle, and full cold-open latency on every press. The one place the Bluetooth
exception is explained is a comment in AudioRecorder.swift.

**Verification.** Cited code verified exactly as described. warmUp()
(Sources/ParlaCore/AudioRecorder.swift:293-307) guards on `warm,
!engine.isRunning`, then `guard AudioRecorder.micAuthorized()` (301), then
`guard !AudioRecorder.isBluetooth(device)` (303). The Bluetooth gate is not
bypassable: isBluetooth(nil) is not a no-op because transportRaw(of:) (157)
falls back to defaultDevice(kAudioHardwarePropertyDefaultInputDevice), so an
unset inputDeviceUID still resolves to the system default input — AirPods as
system default trips the gate just as an explicitly-picked headset does.
warmUp() is private and is the ONLY path to a running idle engine. All three
callers route through the same gate: prepare() (288), scheduleRebuild() (417),
stop() (511). The single un-gated build() is start()'s per-press cold path
(464), whose own comment reads "Also the Bluetooth path: the gate refuses to
*hold* a headset open

### [MINOR] "Transcribes only while you hold <key>" contradicts the shipped fn+Space hands-free latch — including the TCC dialog string

`scripts/make-app.sh:29` · dimension: rest

**Defect.** NSMicrophoneUsageDescription now reads "Your speech is only transcribed while
you hold it" — the rewrite newly added "only" (the old string had no such
claim). Hands-free is an always-available built-in chord: `handsFree =
KeyChord(49, .fn)` (Hotkey.swift:153), and `handle()` fires `.up` only from
`session == .push` (Hotkey.swift:283-285), so releasing fn after a latch does
NOT stop the capture — main.swift:193 even says "a pop confirms fn can be
released". Recording and transcription continue until Space, Return, or another
fn press. The same newly strengthened claim appears in HubPages.swift:16
("transcribes only while you hold fn", "only" added by this commit),
Onboarding.swift:128, and Onboarding.swift:25. This is the string macOS shows in
the microphone permission dialog, where over-claiming is least appropriate; the
README does not document hands-free at all, so nothing corrects it.

**Failure.** User presses fn+Space, releases every key, and keeps talking for a minute. The
mic is recording and whisper is transcribing the whole time with nothing held —
exactly what the permission dialog told them cannot happen.

**Verification.** CONFIRMED — cited code is exactly as described, and the scenario is reachable
end to end.  1. The string is as quoted and the exclusivity is NEW.
scripts/make-app.sh:29 went from "Parla records while you hold the hotkey to
transcribe your speech on-device." to "...Your speech is only transcribed while
you hold it, and never leaves this Mac." The old string carried no "only".  2.
Hands-free is an always-available built-in, not opt-in. HotkeyBindings.handsFree
= KeyChord(49, .fn) (Hotkey.swift:153) is a default field with no enable toggle,
and problem() (Hotkey.swift:193) actively REQUIRES handsFree to contain the
push-to-talk trigger, so no rebinding can remove it.  3. Reachability proved
with a temporary failing test (run, then deleted; no implementation file
touched). Driving the exact user sequence through the pure machines:    -
HotkeyMonitor: handle(63,[.fn],0) -> keyDown(49,[.fn],0.

### Refuted this round

- **Warm engine never rebinds after the system default input changes — boundDevice stores the request, not the device actually opened** — The mechanics are described accurately, but the consequence is refuted by the OS
  contract the scenario itself invokes, and the scenario is internally
  contradictory.  WHAT IS TRUE (verified in
  /Users/daksh/mySpace/code/wisper/Sources/ParlaCore/AudioRecorder.swift): -
  build() line 359 `boundDevice = device` records the *request*. In the default
  configuration it is nil: Settings.swift:50 `public var

- **build()'s failure exits leave boundDevice/builtAuthorized describing an engine that no longer exists** — The code facts are exactly as cited and I confirmed them, including empirically
  that NotificationCenter does not retain the `object` filter, so the replaced
  engine really is released. But no reader can ever observe the stale pair, so
  there is no reachable path to wrong behavior.  Verified in
  /Users/daksh/mySpace/code/wisper/Sources/ParlaCore/AudioRecorder.swift: -
  Writes: 359-360 (build success on

- **problem() accepts idle chords that shadow system/app shortcuts, killing them globally** — The mechanics are exactly as described and I confirmed all three links of the
  chain with a temporary test (written, run, deleted; tree clean, no
  implementation files touched):  1. Hotkey.swift:196 — the `named.dropFirst()`
  loop rejects only empty-modifier chords and chords containing the push-to-talk
  trigger. `problem()` returned nil for pasteLast = KeyChord(12,[.cmd]) ⌘Q,
  (13,[.cmd]) ⌘W, (49,[.cm

- **update() bills the live dictation's whisper model to the previous dictation's park (predates 442ba4e)** — The mechanism is real code but the scenario is unreachable, and the finding
  itself concedes update() is byte-identical to de20782.  CODE IS AS DESCRIBED.
  History.swift:178-187 prefers an unresolved park, and Dictation.swift:273 is
  indeed a live-dictation caller (three callers total: Dictation.swift:273,
  Cleanup.swift:319, OpenAICompatClient.swift:114). I reproduced the finder's
  probe: feeding upda

---

## Round 4 — the rebuild

Confirming the rebuilt matcher and metrics park. A clean result was named as the expected outcome.

4 confirmed, 2 refuted.

### [NIT] Esc with any modifiers is swallowed during a live session, so ⌘⌥Esc (Force Quit) dies at the tap

`Sources/ParlaCore/Hotkey.swift:353` · dimension: matcher

**Defect.** The Esc branch tests only `keyCode == 53, session != .idle` — it never looks at
`modifiers`, so all 32 modifier sets on Esc are swallowed while push-to-talk or
hands-free is live. That contradicts the standard the same function sets two
blocks above, where ⌘Space (Spotlight) and ⌃Space (input source) are
deliberately let through because they are not Parla's. ⌘⌥Esc is the system Force
Quit chord and is not Parla's either. Pre-existing: `git log -L 353,353` puts
this line in the original hands-free feature commit (1c74a33); 904483d did not
touch it, so it is not a regression from the rebuild. Executed, not inferred —
from `.push` and from `.handsFree`, `keyDown(53, [.cmd,.opt])` returns
swallowed=true with edges=[.cancel].

**Failure.** User is dictating (hands-free latched) and an unrelated app hangs. They press
⌘⌥Esc. Parla cancels the dictation and returns true, so the event never reaches
the front app and the Force Quit window does not open. Self-healing: the session
is now .idle, so a second ⌘⌥Esc falls to the bottom branch, emits .dismiss and
returns false — the window opens on the second try. Cost is one lost keypress,
which is why this is a nit and not a defect worth a code change.

**Verification.** CONFIRMED at the code level, by execution, with one caveat on the headline
scenario.  Executed: compiled an unmodified copy of Hotkey.swift standalone
(stubbed only SettingsStore/Inserter) and swept all 32 modifier sets on keyCode
53. - From latched hands-free: 32 swallowed, 0 passed. From `.push`: 32
swallowed, 0 passed. `keyDown(53, [.cmd,.opt])` -> true, edges [.down,
.handsFree, .cancel]. - Control, same latched state: `keyDown(49, [.cmd])` and
`keyDown(49, [.ctrl])` both return false and emit no edge. So the asymmetry the
finding names is real — Sources/ParlaCore/Hotkey.swift:368-374 deliberately lets
Cmd/Ctrl/Opt variants through ("the key is somebody else's"), and
Sources/ParlaCore/Hotkey.swift:353 has no modifier term at all. - Self-healing
confirmed: the second cmd+opt+Esc returns false and emits .dismiss.  Reachable
path in the shipped app: Sources/ParlaCore/Hotkey.swift:437-44

### [NIT] A park is created for a dictation that is owed nothing, so its numbers are stolen by the next dictation's history row — permanently

`Sources/ParlaCore/History.swift:191` · dimension: rest

**Defect.** The eviction table states the park's whole purpose: "a cleanup POST that
outlives the dictation that issued it". The eviction half now tests that
(`polishResolved`), but the creation half was left as `current.awaitingHistory`,
i.e. "landed and no row written". Those are the same predicate only while
history is enabled. With `historyEnabled == false` no `.appendHistory` is ever
emitted, so `snapshotted` stays false and a bucket whose `.cleanedSwapped`
already came back — owed nothing by test (1) of the table — is still parked.
`snapshot()` then hands that resolved park to whatever row is written next ("a
resolved park is the row being written right now" is only true for a park that
resolved in this dictation), leaves `current` unsnapshotted, and re-parks it at
the following fn-down — the permanent off-by-one `snapshot()`'s own comment
warns about. Note this behaves identically under the pre-904483d rule, so it is
pre-existing, not introduced here; but it is the invariant this rework asserts,
and the new test `testResolvedParkIsNotClaimedByALaterDictationsRow` claims
exactly the property that is violated (it only covers the variant where an extra
fn-down intervenes and evicts the park first).

**Failure.** Turn off "Keep local history" in Data & Privacy (cleanup configured). Dictate
once: it lands, the polish returns, no row is written, `current` holds `.landed`
+ `.cleanedSwapped` and `snapshotted == false`. Turn history back on. Dictate
again: at fn-down `current.hasLanded` drops nothing and `awaitingHistory` parks
the already-resolved D1; D2's own stamps route to `current` correctly, but D2's
`.appendHistory` → `snapshot()` sees `parked.polishResolved` and returns D1's
blob. Verified with an extracted harness driving the real `Metrics`: D2's row
gets captureMs 2000 (D1's, not its own 1000), model "d1-model", promptTokens 111
(D1's, not 222); D3's row then gets D2's numbers, D4 gets D3's, and so on
forever. Feeds the Hub's cleanup cost estimate via `CleanupCostEstimate.over`.

**Verification.** The mechanism is real and reachable, but the finding overstates it on two counts
and it is not attributable to this commit.  CONFIRMED BY EXECUTION.
Sources/Parla/Dictation.swift:182 is the only caller of Metrics.snapshot(),
reached only via .appendHistory, which DictationSession.swift:571 (cleanReady)
and :516 (transcribed) emit only under s.settings.historyEnabled.
Sources/Parla/main.swift:165 does store.load() at every fn-down and
HubPages.swift:597 saves the toggle, so the setting flips for the very next
dictation. Driving the real Metrics through the reducer's exact effect order
(fnDown, fnUp, finalPassDone, update{model}, landed,
update{cleanupModel,tokens}, cleanedSwapped, appendHistory) with history off for
D1 and on afterwards reproduces the reported numbers exactly: row D2 gets
captureMs=2000 (D1's, not its own 1000), model=d1-model,
cleanupModel=d1-cleanup, promptTokens=111. C

### [NIT] README says failed recordings "go after 7 days"; the sweep only runs when the next dictation is stashed

`README.md:146` · dimension: rest

**Defect.** `RecordingStore.prune` is called only from `stash`, which is called only from
`finish()` for a new dictation (and after `guard !samples.isEmpty`). There is no
timer and no launch sweep, so nothing is deleted at the 7-day mark itself —
deletion happens at the first dictation after a file has aged out. The design is
deliberate and documented in the store, but this is a retention promise in the
privacy section, and the Hub row ("Deleted after 7 days") reads the same way.

**Failure.** A dictation fails (whisper produced nothing), leaving a WAV behind. The user
stops using Parla — or only uses command mode, which never calls `stash`. Eight,
thirty, ninety days later the file is still in ~/Library/Application
Support/Parla/recordings, contrary to the sentence.

**Verification.** Every factual claim in the finding checks out, and the reachable path is
nameable in the shipped app.  Call graph (grep over the whole repo, `prune(` —
Swift, no reflection, so this is exhaustive): - `prune` has exactly ONE
production caller: `Sources/ParlaCore/RecordingStore.swift:63`, inside `stash`,
after `guard !samples.isEmpty`. The only other hits are
`RecordingStore.swift:108` (the definition) and two direct calls in
`Tests/ParlaCoreTests/RecordingStoreTests.swift:128,142`. - `stash` has exactly
ONE caller: `Sources/Parla/Dictation.swift:213`, the first statement of
`finish()`. - No timer, no launch sweep, no Hub-side sweep. `RecordingStore`
appears in only two app files (`Dictation.swift`, `Hub/HubPages.swift`);
`Sources/Parla/main.swift` never mentions it. `PrivacyPage.onAppear`
(`HubPages.swift:666`) calls `summary()` only — it displays the folder without
pruning it.  Both halv

### [NIT] Onboarding still promises "Nothing you say leaves it", which cloud cleanup contradicts

`Sources/Parla/Hub/Onboarding.swift:29` · dimension: rest

**Defect.** The commit rewrote element 0 of this `subtitles` array for exactly this class of
over-claim and left element 1 untouched. Once an Anthropic key is set — which
the README and the menu-bar **Set API Key…** item actively steer the user toward
— `Pipeline.clean` POSTs the transcript to the cleanup provider, so what you
said does leave the Mac, as text. The app states this correctly everywhere else
(README "the cleanup model is sent text, never audio"; PrivacyPage "Cleanup
sends text only"). Weaker than the three claims this commit fixed: the sentence
is scoped by its predecessor ("Speech recognition runs on this Mac") and is
literally true on a fresh install where onboarding is shown, which is why this
is a nit rather than a defect.

**Failure.** User reads onboarding step 2 and takes "Nothing you say leaves it" as the app's
privacy posture, then pastes an API key from the menu bar. Every subsequent
transcript is sent to Anthropic, with no correction to the promise they were
shown.

**Verification.** CONFIRMED, with a stronger path than the one claimed.
Sources/Parla/Hub/Onboarding.swift:29 shows "Speech recognition runs on this
Mac. Nothing you say leaves it." while Pipeline's cleanup leg POSTs the
transcript — literally what you said — to https://api.anthropic.com/v1/messages
(Sources/ParlaCore/Cleanup.swift:284, built at
Sources/Parla/Dictation.swift:235, gated by cleanupConfigured stamped at
Sources/Parla/main.swift:167). The app scopes this correctly everywhere else:
PrivacyPage says "Transcription is on-device — Audio never leaves this Mac" and
"Cleanup sends text only" (Sources/Parla/Hub/HubPages.swift:653,662), the README
says "the cleanup model is sent text, never audio", and this very commit removed
"never leaves this Mac" from NSMicrophoneUsageDescription in scripts/make-
app.sh. subtitles[1] is the one survivor of the class of over-claim the commit
set out to fix.  The fin

### Refuted this round

- **progress.md records ⇧Return as one of the chords the rebuild un-swallowed; it is still swallowed** — Refuted: the finding misreads a bug-description sentence as a fix-scope claim,
  and the misreading depends on adjacency that does not exist at the cited
  location.  1. Behavior is as the finding says, and is intended.
  Hotkey.swift:368-369 swallows the latch key or Return from .handsFree when
  `modifiers.subtracting(.shift).isEmpty`, so ⇧Return (mods [.shift] -> []) stops
  and is swallowed. HotkeyTests

- **Keeping an unresolved park across non-landing dictations makes an unresolvable park immortal; it then swallows a later dictation's swap and token updates** — The mechanism reproduces, but it is not a defect this commit introduces, and the
  finding's own framing ("regression introduced by the rework", "immortal") is
  refuted by execution.  VERIFIED TRUE: DictationSession.swift:510 stamps
  `.trace(.landed)` unconditionally, and :512-519 emits `.appendHistory` only
  under `s.settings.historyEnabled`. So `willPolish == false` + history off leaves
  a landed, nev

---
