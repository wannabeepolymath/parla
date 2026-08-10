# Text Insertion & Injection

Everything learned about getting text from the transcript into the focused field, across 24 open-source dictation apps. Insertion is the single largest bug surface in this product category — more issues than ASR, latency, and packaging combined — and Parla has taken the rarest architectural position in the field (keystrokes, no clipboard, AX-verified erase), which buys real safety and costs real coverage.

This doc maps the field, then names precisely where Parla is ahead and where competitors land text that Parla silently drops.

---

## 1. What everyone actually ships

Insertion mechanism, macOS, by repo:

| Repo | Primary | Fallback | Post-insert verification |
|---|---|---|---|
| **Parla** | CGEvent Unicode keystrokes | **none** | AX substring-before-cursor (erase only) |
| zachlatta/freeflow | clipboard + ⌘V | clipboard-only | none |
| altic-dev/FluidVoice | AX `kAXSelectedText` splice | clipboard + ⌘V | 4-proof poll, 50 ms × 5 s |
| EpicenterHQ/epicenter | AX `kAXSelectedText`, value-diff verified | clipboard + ⌘V | before/after `kAXValue` compare |
| TypeWhisper/typewhisper | AX `kAXSelectedText`, value-diff verified | clipboard + ⌘V | before/after `kAXValue` compare |
| cjpais/Handy | clipboard + ⌘V | receipt-sequenced restore | pasteboard *read* receipt (not field) |
| Beingpax/VoiceInk | clipboard + ⌘V | manual paste toast | none |
| OpenWhispr/openwhispr | clipboard + native paste binary | manual | none |
| matthartman/ghost-pepper | clipboard + ⌘V | osascript System Events | none (AX read used for learning only) |
| moona3k/macparakeet | clipboard + ⌘V | none | none |
| FrigadeHQ/yap | AppleScript System Events ⌘V | CGEvent ⌘V | none |
| watzon/pindrop | clipboard + ⌘V | none | none |
| Muesli-HQ/muesli | clipboard + ⌘V | none | none |
| amicalhq/amical | clipboard + ⌘V (per-char typing **removed**) | none | none |
| voquill/voquill | clipboard + ⌘V | typing mode (opt-in, VDI) | none |
| digimata/parrot | CGEvent Unicode keystrokes | **none** | none |
| peteonrails/voxtype | CGEvent Unicode (chunk 20) | osascript → pbcopy | none |
| thewh1teagle/vibe | `enigo.text()` (Unicode CGEvent) | **none** | none |
| Open-Less/openless | CGEvent Unicode (streaming) / clipboard (final) | clipboard | none |

**Tally: 14 of 19 macOS apps paste. 5 type. 3 write via AX. Parla is the only one that types with no fallback tier at all.**

The three that removed a mechanism are the most informative:

- **amical** deleted per-character typing outright — `apps/desktop/src/helpers/clipboard.js:1148`: *"`inject_mode='wtype'/'ydotool_type'` is deprecated: direct typing drops characters at speed. Using clipboard+paste instead."* Their issue #147 measured it: `"This is atesttoseeifthespacingimproved"` — spaces dropped at ~40 chars.
- **Handy** removed Direct paste from the macOS UI entirely (commit `3cbbe58`, "drop 'direct' paste method from the ui for macOS (#1708)") after issue #692: text repeated and interleaved mid-sentence in terminal TUIs.
- **VoiceInk** never had one. `Utils/ClipboardUtil.swift` is the whole insertion layer.

---

## 2. The mechanism table: what each primitive actually does on macOS

| Primitive | Layout-safe | Unicode | Verifiable | Blocked by Secure Input | Works in Kitty-protocol TUIs | Touches clipboard |
|---|---|---|---|---|---|---|
| `CGEventKeyboardSetUnicodeString` + `virtualKey: 0` | ✅ | ✅ | ❌ | **✅ blocked** | ❌ **see §4** | ❌ |
| `CGEvent(virtualKey: kVK_ANSI_V, .maskCommand)` | ❌ needs `UCKeyTranslate` | n/a | ❌ | **✅ blocked** | ✅ | ✅ |
| `AXUIElementSetAttributeValue(kAXSelectedText)` | ✅ | ✅ | ✅ (read-back) | ❌ not blocked | ❌ no AX tree | ❌ |
| AppleScript `System Events` keystroke | ❌ | partial | ❌ | ✅ blocked | ✅ | ✅ |
| macOS IME / `NSTextInputClient` | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |

**Nobody in the corpus ships an IME on macOS.** openless is the only project that built one, and it's Windows TSF (`openless-all/app/windows-ime/OpenLessIme.vcxproj`) — and it produced the worst bug in that entire codebase: the DLL loads into `explorer.exe` and hung the taskbar (`openless` commit `2e3c0f5`, issues #665/#707). Not a path worth taking.

---

## 3. The canonical fallback ladder

Synthesized from FluidVoice `Services/TypingService.swift:389-486`, epicenter `src-tauri/src/delivery.rs`, typewhisper `TextInsertionService.swift:399-421`, and Handy `src-tauri/src/clipboard.rs`. Every mature implementation converges on roughly this shape:

```
0.  Capture target PID at HOTKEY-DOWN (before any of your own UI exists)
1.  Gate:  IsSecureEventInputEnabled()  → clipboard-only + toast, STOP
2.  Gate:  AXIsProcessTrusted()          → clipboard-only + toast, STOP
3.  Probe focused element → Editable | NotEditable | Unknown  (hard timeout ~500 ms)
       NotEditable → clipboard-only + toast, STOP  (never press keys)
4.  Re-activate captured PID if it is not frontmost; poll until confirmed
5.  Wait for user's physical modifiers to clear (poll, hard cap ~1 s)
6.  If Editable AND not a web area AND kAXSelectedText is settable:
        snapshot kAXValue → set kAXSelectedText → re-read kAXValue
        changed?  → DONE
        unchanged? → fall through (the API lied)
7.  Per-app override table → force clipboard for known-bad targets
8.  Clipboard path: snapshot ALL pasteboard types → write → settle → ⌘V
9.  Verify insertion (poll AX value / caret delta, ~50 ms × N)
10. Restore clipboard ONLY IF changeCount unchanged (else user copied — leave it)
```

Parla implements steps 0, 2 (partially), 3, and a stronger version of 6's verification — but for *erasure*, not insertion. It implements none of 1, 5 (except on ⌃⌘V), 7, 8, 9, 10.

### The two rules that make step 6 safe

**epicenter removed containment-based verification and documented why** (`SelectionReplacementService.swift`, corpus dissection):

> *"the earlier post-write `value.contains(text)` verification looked safer but actually false-positively reported success whenever the inserted text already appeared anywhere else in the field — masking a real AX-write failure and skipping the clipboard fallback that would have worked."*

**typewhisper** does it positionally instead — snapshot `kAXValue` before, write, read after, `before == after ⇒ Err`. Parla's `canEraseTyped` is already the positional form (`Sources/ParlaCore/Inserter.swift:176-182`), which is the correct one.

**Never write `AXEnhancedUserInterface`** — muesli PR #1116 is the cautionary tale, worth quoting in full because Parla does exactly this:

> *"after every paste, the auto-learn correction monitor ran AppleScript setting `AXEnhancedUserInterface=true` on the target app so Chromium would build its a11y tree. That attribute: flips the **entire target process** into screen-reader mode for its lifetime — outlives Muesli and survives restarts; triggers an a11y-tree rebuild whose focus churn **permanently blurs the composer** in some Chromium apps; and **cannot be undone** — setting it back to `false` does not restore focus; only restarting the target app does."*

Parla sets it at `Sources/ParlaCore/Inserter.swift:97` and never restores it. VoiceInk hit the identical bug and reverted (commit `ba0954a`, *"stop forcing AXEnhancedUserInterface on browsers"* — linked to a Chrome main-thread stall report). `AXManualAccessibility` alone (line 98) is the safe half.

---

## 4. The `virtualKey: 0` bug — Parla has it

**This is the highest-severity finding in this document.**

Parla's insertion primitive, `Sources/ParlaCore/Inserter.swift:44-54`:

```swift
if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
   let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
    ...
}
```

`virtualKey: 0` is `kVK_ANSI_A`. Apps that read the **keycode** rather than the **Unicode payload** see the letter "a".

Verified independently via `gh issue view 479 --repo altic-dev/FluidVoice` (OPEN, 11 comments, FluidVoice 1.6.1, macOS 26.5.1). Reporter: dictating a list into Claude Code under cmux inserts **only the character `a`**; Transcription History shows the full correct text. Maintainer/contributor diagnosis, verbatim from the thread:

> *"The issue occurs specifically when multi-line input is sent to the TUI (they are sent as a unicode payload in CGEvent). Single line text works well for me and I use Ghostty. Since its sent as a synthetic key event, at the end of the transcription just `a` is inserted since the event has `virtualKey: 0`. The fallback as @alvarosevilla95 mentioned is to use clipboard paste which doesn't rely on CGEvent."*

FluidVoice's shipped fix is a hard-coded bundle-ID escape hatch (`TypingService.swift:57`, `393-402`):

```swift
private static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
// …
if self.textInsertionMode == .standard,
   let ghosttyTargetPID = self.ghosttyTargetPID(preferredTargetPID: preferredTargetPID)
{ /* force Reliable Paste */ }
```

ghost-pepper independently reached the same conclusion for Ghostty (`Sources/GhostPepper/Input/TextPaster.swift:57`, the *only* app forced onto the paste path in Clipboard-Free mode).

**Why Parla is partially insulated and still exposed:**

- Parla flattens newlines for Ghostty/kitty/WezTerm/Warp/Alacritty (`Sources/ParlaCore/TextRules.swift:9-13`), so the multi-line trigger from #479 mostly doesn't fire.
- But it has **no clipboard tier at all** — when the payload *is* dropped, the text is gone from the field entirely. Every other affected project degrades to a paste. Parla degrades to nothing plus a `✓ Pasted` HUD that is false.
- The corpus's freeflow dissection reports the same mechanism in hypervisors — Parallels/VMware/VirtualBox/UTM read the raw virtualKey and produce `"AAAAA…"`, with a bundle-ID detector as the fix. (I could not verify freeflow's issue number via `gh`; the mechanism is the same one FluidVoice #479 confirms.)

**Second-order problem: chunk size.** Parla chunks at 20 UTF-16 units with a 5 ms sleep (`Inserter.swift:25`, `:56`). FluidVoice chunks at **200** with `interChunkDelayMs=0`. From the same #479 thread, a second reporter found long single-line dictations arrive as several separate `[Pasted text #N]` blocks in TUIs — because terminals frame each keyDown/keyUp burst as its own paste. At 20 units/chunk, Parla emits **10× more bursts than FluidVoice** for the same transcript: a 600-char transcript = 30 event pairs + 150 ms of `usleep` on the main actor.

| Repo | Chunk (UTF-16) | Inter-chunk delay | 600-char cost |
|---|---|---|---|
| **Parla** | 20 | 5 ms | 30 bursts, ~150 ms |
| FluidVoice | 200 | 0 ms | 3 bursts, ~0 ms |
| voxtype | 20 | 0 ms | 30 bursts, ~0 ms |
| ghost-pepper | n/a (paste) | 8 ms hold + 20 ms | 1 event |

The 20-unit cap is real (`CGEventKeyboardSetUnicodeString` truncates), but FluidVoice ships 200 in production against Slack/Discord/VS Code, so the practical ceiling is far above 20. Both the sleep and the chunk size are free wins.

---

## 5. Secure input — the gap that matters most for a keystroke-only app

`IsSecureEventInputEnabled()` is the OS signal that some process (1Password, Terminal's Secure Keyboard Entry, `sudo`, a password field) has grabbed the keyboard. **While it is on, synthetic CGEvents are silently discarded — no error, no exception, no return code.**

| Repo | Detects secure event input? | How |
|---|---|---|
| cjpais/Handy | ✅ | `src-tauri/src/secure_input.rs` (660 L), polls 1 s, `SUSTAIN_THRESHOLD = 3s`, shadow-registers Carbon hotkeys |
| zachlatta/freeflow | ✅ | `SecureInput.swift` + IORegistry to name the culprit |
| epicenter | ✅ (adjacent) | CGEventTap liveness as a stale-grant oracle |
| **Parla** | ❌ | grep `IsSecureEventInput` over `Sources/` → 0 hits |
| FluidVoice | ❌ | corpus: *"no secure-input handling anywhere"* |
| VoiceInk, ghost-pepper, macparakeet, pindrop, muesli | ❌ | not found |

Parla detects `AXSecureTextField` by role/subrole (`Inserter.swift:130`) at three checkpoints, which is genuinely more than most. But that is an *AX* signal about a *field*. Secure event input is a *system* signal about the *keyboard*, and they are different failure modes:

- Password field with an AX tree → Parla catches it. ✅
- Terminal with Secure Keyboard Entry on, ordinary shell prompt → Parla types into the void. ❌
- 1Password window in front, non-secure field focused → same. ❌
- Chromium password field whose AX tree never woke → classifies `.unknown`, and Parla **types into it** (`main.swift:459`, `case (false, .unknown)`). ❌

freeflow's IORegistry lookup is the one non-obvious piece, and its comment corrects the common blog-post error:

```swift
// The property lives on the registry root — not under IOResources, as
// most write-ups claim.
let root = IORegistryGetRootEntry(kIOMainPortDefault)
// … IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" …)
// … session["kCGSSessionSecureInputPID"]
```

with the honest caveat: *"The reported pid can be wrong when secure input was enabled by a background process, so treat the name as a hint."*

---

## 6. Held modifiers — the bug that only bites push-to-talk apps

Parla is push-to-talk on fn. Transcription of a short utterance completes in ~130–200 ms warm. **The user is still physically holding fn when insertion fires.**

Parla already found and fixed half of this — `Inserter.swift:48-52`:

```swift
// Clear inherited modifiers: the user is physically holding fn
// (push-to-talk), and virtualKey 0 is the A key — without this,
// every chunk lands as fn+A, macOS's "Show the Dock" shortcut.
down.flags = []
up.flags = []
```

And again for backspace (`:69`, *"held fn would turn this into forward-delete"*). That's correct and most projects don't do it.

The other half is unfixed. `event.flags = []` clears what *your event* carries; it does not change what the *target app* believes about global modifier state. Apps that poll `NSEvent.modifierFlags` or rebuild state from the raw event stream (Chromium in particular — see below) still see fn/⇧ down.

**vocalinux PR #494** is the best write-up of this class:

> *"PTT shortcut *is* a modifier; transcription finishes in tens of ms; the Ctrl+V paste fires while Alt is still down → compositor sees Ctrl+Alt+V → **nothing pastes**. Symptom users report: 'the text is on my clipboard but nothing pasted.' Intermittent by construction — fast transcriptions fail, slow ones work."*

Their fix polls held modifiers every **15 ms**, capped at **1.0 s**, and returns immediately when nothing is held — so the common case costs one scan.

Parla has exactly this machinery, but only on the ⌃⌘V paste-last path (`main.swift:274-284`, 20 tries × 50 ms). The **dictation** path — the one where a modifier is guaranteed held — does not wait.

Related, from freeflow's synthetic-paste code: Chromium/Electron **rebuilds modifier state from the raw event stream** and needs a genuine modifier keyDown, plus `NX_DEVICELCMDKEYMASK` (`0x8`) OR'd into the flags for Qt/Java/Carbon-era apps that read the device-dependent bits. Parla clearing flags to `[]` is right for its own events; it means Parla can never synthesize a chord correctly if it ever needs to (⇧↵ for chat apps — see §8).

---

## 7. Undo / erase behaviour

Parla's `canEraseTyped` (`Inserter.swift:176-182`) is the strongest erase guard in the corpus. Nothing else comes close:

```swift
public static func canEraseTyped(_ typed: String) -> Bool {
    guard !typed.isEmpty else { return true }
    guard let (text, cursor) = focusedFieldState() else { return false }
    let len = (typed as NSString).length
    guard cursor >= len, cursor <= text.length else { return false }
    return text.substring(with: NSRange(location: cursor - len, length: len)) == typed
}
```

Fails closed on AX opacity. Used at four sites: cancel-undo, empty-transcript undo, live finalize, cleaned swap. Combined with `LiveTyper.diff` counting **graphemes** (`Sources/ParlaCore/LiveTyper.swift`) so one backspace = one deleted grapheme — tested against emoji and combining marks.

Contrast — how the rest of the field does undo/erase:

- **vocalinux** `action_handler._handle_delete_last` sends `"\b" * n` as literal backspace **characters** through the text-injection path. In most fields that types garbage rather than deleting.
- **hyprwhspr, VoiceInk, macparakeet, pindrop** — no erase primitive at all; the transcript is inserted once and never revised.
- **openless** streaming does `typed_partial` LCP → `Replace{backspace, text}` (`src/transcribe/soniox.rs:427-445`) with the right rule Parla should note: **count Unicode scalars, not bytes** (test `typed_chars_counts_unicode_scalars_not_bytes`, 你好世 = 3 scalars / 9 bytes).
- **voxtype** counts `typed_chars` in scalars and explicitly no-ops the rewind on clipboard backends.

Two subtleties Parla is missing:

1. **`focusedFieldState()` ignores `range.length`** (`Inserter.swift:157-159` reads only `range.location`). If a selection is active at swap time, `canEraseTyped` compares text ending at the *selection start*, while the first synthetic Delete deletes the *selection*. Off-by-a-selection destructive edit. Unguarded, untested.
2. **No Unicode normalization before comparison.** Some apps return NFD from AX where Parla typed NFC. The compare silently fails → cleaned swap skipped → user is told "saved to history" with no reason. This is the most likely cause of "the polish didn't apply and I don't know why."

**openless's rule for when the backspace can't be emitted** is worth adopting verbatim (`src/output/streaming.rs:213-224`): if the erase can't be sent, **do not update your bookkeeping** — accept the visual artifact rather than let the typed-length counter drift and leave stray characters on the next rewind.

---

## 8. Per-app quirk table

Union of every hard-coded list in the corpus, annotated with what Parla has.

### Terminals (need paste, not keystrokes — §4)

| Bundle ID | Parla `terminalBundleIDs` | Notes |
|---|---|---|
| `com.apple.Terminal` | ✅ | |
| `com.googlecode.iterm2` | ✅ | Handy #692: interleaved/duplicated text on direct typing |
| `dev.warp.Warp` | ✅ | |
| `com.github.wez.wezterm` | ✅ | Kitty keyboard protocol |
| `net.kovidgoyal.kitty` | ✅ | Kitty keyboard protocol |
| `com.mitchellh.ghostty` | ✅ | **FluidVoice #479, ghost-pepper: forced to paste** |
| `org.alacritty` | ✅ | |
| `co.zeit.hyper` | ✅ | |
| Tabby, Rio, WaveTerm, Contour | ❌ **missing** | in vocalinux/voxtype/openless lists |
| cmux | ❌ **missing** | FluidVoice #479's actual repro environment |
| VS Code / Cursor / Zed **integrated terminal** | ❌ **unfixable by bundle ID** | bundle = editor; dictated newlines execute commands |

### Newline-submits (Return sends the message)

| Bundle ID | Parla `newlineSubmitBundleIDs` |
|---|---|
| `com.tinyspeck.slackmacgap` | ✅ |
| `com.hnc.Discord` | ✅ |
| `com.apple.MobileSMS` | ✅ |
| `net.whatsapp.WhatsApp` | ✅ |
| `ru.keepcoder.Telegram` / `org.telegram.desktop` | ✅ |
| Teams, Signal, Element, Zoom chat, Messenger, Mattermost | ❌ missing |
| Linear, Notion | ❌ missing |
| **any browser-hosted chat** (Gmail, Slack web, ChatGPT) | ❌ **unfixable by bundle ID** — bundle is Chrome/Safari |

Parla flattens; **openless offers the better fix** — `WindowsSendInputNewlineMode` converts `\n` to Shift+Enter, which Slack/Discord/ChatGPT all accept as a soft newline. That preserves the list formatting the cleanup prompt worked to produce (`Sources/ParlaCore/Cleanup.swift:52-59`) instead of collapsing it back into one line with inline `- ` markers.

### Chromium / Electron (no AX tree until woken)

Parla's wake-up (`Inserter.swift:95-101`) is single-shot with a fixed 50 ms sleep. FluidVoice does the same thing but the corpus notes the first dictation in such an app still classifies as `.unknown`. openless's `AppContextAdapter` carries the non-obvious bundle IDs worth having:

- Cursor: `com.todesktop.230313mzl4w4u92`
- Windsurf: `com.exafunction.windsurf`
- Codex: `com.openai.codex`
- Antigravity: `com.antigravity.app` / `com.google.antigravity`

### Hypervisors (raw virtualKey readers — §4)

`com.vmware.fusion`, `com.vmware.vmware-vmx`, `com.parallels.desktop.console`, `org.virtualbox.app.virtualbox`, `org.virtualbox.app.virtualboxvm`, `codes.rambo.virtualbuddy` — freeflow's list, with prefix matching for vendor helper processes. Parla has none of these and its primitive is the one they break.

### The general lesson

FluidVoice's own retrospective on its Ghostty allowlist, from the corpus:

> *"the per-app allowlist doesn't scale — cmux, WezTerm, kitty, tmux still fall through. Detect the *class* of app (does the focused AX element expose `kAXValue`/`kAXSelectedTextRange`?) rather than enumerating bundle IDs."*

---

## 9. Verification strategies

Only three projects verify anything after insertion.

**FluidVoice** (`TypingService.swift:1103-1166`) — poll every **50 ms**, budget **5 s**, accept any of four proofs, tolerance `max(2, expectedLength / 5)` (20% slack, because apps autocorrect and smart-quote):

1. AppleScript-read value now contains the text and changed
2. AppleScript caret moved by ~`expectedLength`
3. AX `kAXValue` contains the text and changed
4. AX `kAXSelectedTextRange.location` moved by ~`expectedLength`, `length == 0`

It returns a typed result so you can log **which** proof fired — which tells you empirically which apps need special handling, from real users, without guessing.

Plus per-app AppleScript escape hatches where AX lies: Xcode (`text of source document 1` + `selected character range of source document 1`, with 1-based→0-based conversion) and Notes (`plaintext of note id noteId`).

**Handy** verifies the *clipboard was read*, not that the field changed — `paste_tx/` publishes a lazy pasteboard promise (`declareTypes:owner:`) and treats `pasteboard:provideDataForType:` firing as the receipt. Three rules worth copying if Parla ever adds a clipboard tier: only receipts after `injected_at` count (earlier reads are clipboard managers); restore only while `changeCount` is unchanged; `QUIET_PERIOD = 200 ms` after the *last* receipt because *"some applications read the clipboard several times per paste (Chromium probes, then reads)"*. Hard cap `RESTORE_TIMEOUT = 8s`, `FAILED_INJECTION_TIMEOUT = 500ms`.

**Parla** verifies before erasing, never after inserting. `Inserter.canVerifyFocusedField()` exists (`:187-189`) and has **zero callers**.

The asymmetry is worth stating plainly: Parla can prove it is safe to *delete*, but cannot tell whether the user got any text at all. `hud.show(.done)` → `"✓ Pasted"` fires unconditionally on the `.field` path.

---

## 10. Wayland / X11 / Windows equivalents

Not directly actionable for macOS, but `MEMORY.md` records a wlroots daily-driver and a Linux port on a branch, so this is the map.

| Platform | Mechanism | Gotcha |
|---|---|---|
| X11 | `xdotool type` / XTest | Konsole silently drops XTest ⌃⇧V (voxtype `skipFastPasteForKonsole`) |
| Wayland, wlroots (sway/Hyprland) | `wtype` (virtual-keyboard protocol) | **not available on GNOME/Mutter or KDE** |
| Wayland, GNOME/KDE | `ydotool` (uinput) or libei `eitype` | needs `/dev/uinput` + udev rule; ydotool 0.x vs 1.x CLI differ — passing 1.x keycodes to 0.x **types the literal string "2442"** (vocalinux `text_injector.py:1405`) |
| Wayland, any | clipboard + `wl-copy` | `wl-copy` forks a daemon inheriting your pipes — piping stderr **deadlocks `wait()` forever**; use `Stdio::null()` (Handy, vocalinux both hit this) |
| Windows | `SendInput` with `KEYEVENTF_UNICODE` | must batch Ctrl+V as **one** `SendInput` call (4 INPUT records) — separate calls let V land before Ctrl registers (Voquill `SimulateCtrlChord`) |

Two Linux findings that generalize:

- **Layout-dependence is the single largest Linux insertion complaint** — 13 issues in vocalinux alone. `ydotool`/`xdotool` emit positional evdev keycodes remapped through the user's layout: AZERTY gets `"Iù, tqlking in English"`. **Only clipboard-paste or IME-commit is layout-independent.** macOS `CGEventKeyboardSetUnicodeString` sidesteps this — one of the few places macOS is strictly easier.
- **`ModifierGuard` via `EVIOCGKEY`** (vocalinux `modifier_guard.py`) reads the pressed-key bitmap passively without consuming events, bypassing the display server entirely. Works on X11 and every Wayland compositor. The macOS analogue is `CGEventSource.flagsState(.combinedSessionState)`.

---

## 11. Parla vs the field: honest scoring

### Where Parla is genuinely better

| Property | Parla | Field |
|---|---|---|
| Clipboard never touched | ✅ | 14/19 clobber it every dictation |
| Erase provably safe | ✅ positional AX substring, fails closed | nobody else verifies erasure |
| Secure *field* refused at 3 checkpoints | ✅ + transcript redacted from `NSLog` | FluidVoice/VoiceInk/ghost-pepper/macparakeet: none |
| Grapheme-accurate backspace counts | ✅ tested vs emoji + combining marks | openless counts scalars; most don't erase at all |
| Modifier flags cleared on synthetic events | ✅ both keyDown and keyUp | most set `.maskCommand` and inherit the rest |
| Surrogate-safe chunk boundaries | ✅ tested | FluidVoice ✅; others split emoji |
| Self-recognition of own events | ✅ `eventSourceUserData` marker | Voquill (`0x5654_5950`), Handy; several don't and self-cancel |
| Stale-result invalidation | ✅ `generation` counter | epicenter ✅; most have this bug latent |

The clipboard decision alone eliminates an entire bug family the rest of the field is still fighting: VoiceInk #415/#722 (old clipboard pasted back), VoiceInk #834 (images destroyed), yap #124, Handy #921/#502, epicenter #1172 (first paste fails on Chromium+Wayland). Handy's mitigation is a 283-line receipt-sequenced transaction module. Parla has zero lines of that problem.

### Where competitors land text Parla drops

| Situation | Competitor outcome | Parla outcome |
|---|---|---|
| Secure event input active (Terminal SKE, 1Password, sudo) | text on clipboard + toast | **typed into void, HUD says "✓ Pasted"** |
| Ghostty/cmux/Kitty-protocol TUI, payload dropped | forced clipboard paste (FluidVoice, ghost-pepper) | **`a` or nothing** |
| Hypervisor guest (Parallels/VMware/VirtualBox) | VM detector → clipboard (freeflow) | **`AAAAA…`** |
| No focused element (`.none`) | clipboard + "press ⌘V" toast | history only, nothing in field |
| AX-opaque field, cleaned swap | AX write or paste both land the polish | raw stays, polish → history only |
| Chromium password field with dormant AX tree | (nobody handles this) | classifies `.unknown` → **types into it** |
| Any app that ignores synthetic events | clipboard fallback | silent loss, no signal |

**The pattern: Parla's failure mode is silent and total; the field's failure mode is "text is on your clipboard."** Every competitor that removed direct typing did so after users reported dropped/garbled characters, and every one of them kept the clipboard as the reliable tier.

The fix is not to adopt the clipboard as the *default* — Parla's default is better. It is to have a tier below "type" that isn't "nothing." Note that Parla already has a clipboard write path in the codebase (`HubModel.copy(_:)`, documented as *"The ONLY pasteboard write in the app"*), so a fallback tier is a policy change, not new plumbing.

---

## What Parla should do

Ordered by (severity × cheapness). Every item names the file.

1. **Detect secure event input before typing. (S)**
   `Sources/ParlaCore/Inserter.swift` — add `IsSecureEventInputEnabled()` (Carbon, already linked via AppKit) as the first check in `focusTarget()`, returning `.secure`. This is ~5 lines and closes the one case where Parla types into the void with a false success HUD. Optionally add freeflow's IORegistry lookup to name the culprit in the toast (`IORegistryGetRootEntry(kIOMainPortDefault)` → `IOConsoleUsers` → `kCGSSessionSecureInputPID`) — that's another ~30 lines and turns "nothing happened" into "1Password is blocking input."

2. **Add a clipboard-fallback tier, gated on refusal — not on failure. (S)**
   `Sources/Parla/main.swift:427-469` (`finish()` switch). Today `case (false, .none)` and every secure/unverifiable refusal end in history-only. Add: write to `NSPasteboard`, show `"✓ Copied — press ⌘V"`. This preserves the no-clipboard-by-default invariant (nothing is written on the happy path) while removing the silent-total-loss failure mode. Reuse `HubModel.copy`'s pasteboard code.

3. **Raise the chunk size to 200 and delete the inter-chunk sleep. (S)**
   `Sources/ParlaCore/Inserter.swift:25` (`max: Int = 20`) and `:56` (`usleep(5_000)`). FluidVoice ships 200/0ms in production. This removes ~150 ms of main-actor blocking per 600-char transcript and cuts TUI paste-framing artifacts 10×. Keep the surrogate guard. Verify against Slack + Ghostty before landing.

4. **Wait for physical modifiers to clear before dictation insertion. (S)**
   `Sources/Parla/main.swift:400` — Parla already has `pasteWhenModifiersClear` (`:274-284`) for ⌃⌘V. The dictation path is where a modifier is *guaranteed* held (fn push-to-talk) and it doesn't wait. Reuse the same helper, or poll `CGEventSource.flagsState(.combinedSessionState)` at 15 ms / 1 s cap per vocalinux PR #494. Returns immediately when nothing is held, so the hands-free path costs one check.

5. **Stop writing `AXEnhancedUserInterface`. (S)**
   `Sources/ParlaCore/Inserter.swift:97` — delete that line, keep `AXManualAccessibility` on line 98. Per muesli PR #1116 and VoiceInk commit `ba0954a`, this attribute puts the target process into screen-reader mode permanently, cannot be reverted, and blurs the composer in some Chromium apps. Parla sets it on every non-editable classification and never restores it.

6. **Fix `focusedFieldState()` to reject a non-empty selection. (S)**
   `Sources/ParlaCore/Inserter.swift:157-159` reads `range.location` and ignores `range.length`. Return `nil` when `range.length > 0` so `canEraseTyped` fails closed — otherwise the first synthetic Delete deletes the user's selection instead of Parla's tail, after verification already passed.

7. **Normalize before comparing in `canEraseTyped`. (S)**
   `Sources/ParlaCore/Inserter.swift:181` — compare `precomposedStringWithCanonicalMapping` on both sides. Apps returning NFD from AX currently fail verification silently, which reads to the user as "the polish randomly didn't apply."

8. **Route Ghostty/kitty/WezTerm/cmux + hypervisors to the clipboard tier. (M)**
   `Sources/ParlaCore/TextRules.swift` — add `pasteOnlyBundleIDs` alongside the two existing sets, seeded from FluidVoice's and ghost-pepper's tables plus freeflow's hypervisor list. Depends on item 2. This is the empirically-established fix for `virtualKey: 0`; both projects that hit it landed here. Add Tabby / Rio / WaveTerm / Contour to `terminalBundleIDs` while in the file.

9. **Verify insertion after the fact, and stop lying in the HUD. (M)**
   `Sources/ParlaCore/Inserter.swift` — `canVerifyFocusedField()` already exists with zero callers. Port FluidVoice's four-proof poll (50 ms × 5 s, tolerance `max(2, len/5)`) and return which proof fired so `NSLog` accumulates a real per-app compatibility map from actual usage. `main.swift:459` currently shows `.done` unconditionally on the `.field` path.

10. **Send Shift+Enter instead of flattening in chat apps. (M)**
    `Sources/ParlaCore/TextRules.swift:35-38` — `flattenForTerminal` currently collapses the lists the cleanup prompt (`Sources/ParlaCore/Cleanup.swift:52-59`) works to produce. Slack/Discord/ChatGPT all accept ⇧↵ as a soft newline (openless `WindowsSendInputNewlineMode`). Keep flattening for genuine terminals; split the two bundle-ID sets' behaviour. Note this requires synthesizing a real chord, which conflicts with the `flags = []` rule — post ⇧ down/up explicitly around `kVK_Return`.

11. **Treat `.unknown` as paste-only, not type-into. (M)**
    `Sources/Parla/main.swift:459` — `case (false, .unknown)` currently types. A Chromium password field with a dormant AX tree classifies `.unknown`, so the secure guard fails open. Once item 2 lands, route `.unknown` to the clipboard tier and let the user decide. FluidVoice's conclusion applies: detect the *class* (does the element expose `kAXValue`/`kAXSelectedTextRange`?) rather than enumerating bundles.

12. **Re-enable live streaming with the openless bookkeeping rule. (L)**
    `Sources/Parla/main.swift:179` (`self.liveTyping = false`) makes the entire `(true, _)` arm, the cancel-undo, and `stream()`'s typing block unreachable — the shadow-stream pass runs every ~300 ms and discards its result. The stated blocker (fn-merge) is already solved by `flags = []` for the payload; what remains is the *target app's* modifier belief, which item 4 addresses. Land items 4 and 9 first, then the rule from openless `src/output/streaming.rs:213-224`: **if the backspace can't be emitted, do not update `typed`** — accept the visual artifact rather than let the counter drift.
