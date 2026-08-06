# Parla on Linux (wlroots) — Design

Status: approved 2026-08-06, not yet planned or implemented.
Scope: a Linux dictation daemon for wlroots compositors (sway, Hyprland, river,
niri). Windows follows this; macOS is untouched.

## Why this is a rewrite, not a port

Parla is ~4,400 LOC of Swift, of which ~3,500 is macOS API surface:

| Piece | LOC | Portable |
|---|---|---|
| Menu bar + pill HUD + SwiftUI Hub | ~2,700 | no — AppKit/SwiftUI |
| `Inserter.swift` | 219 | no — CGEvent typing + Accessibility API |
| `AudioRecorder.swift` | 182 | no — AVAudioEngine + CoreAudio HAL |
| `Hotkey.swift` | 171 | no — CGEventTap; and fn/Globe does not exist on PC hardware |
| `Transcriber.swift` | 99 | partly — whisper.cpp is cross-platform, the `.xcframework` is not |
| Cleanup, prompts, HTTP, settings, history, streaming, text rules | ~900 | yes — pure Foundation |

The shell is the app. There is no version of this where we ship platform shells
around a shared core and call it a day.

The four things that make Parla *Parla* on macOS — fn/Globe hold, Accessibility
field classification, live-streamed corrections with synthetic backspaces, and
secure-field refusal — are exactly and only the four things that do not port.
Every cross-platform dictation app surveyed (Handy, Whispering, vibe, Wispr
Flow, superwhisper, Aqua) abandoned field inspection and blind-pastes via the
clipboard. The one app that reads the focused field the way we do is VoiceInk,
which is Swift and macOS-only. This design accepts that and picks a different
shape rather than pretending parity is reachable.

## The decision everything follows from

**The app never sends BackSpace.**

On macOS, `Inserter.canEraseTyped` reads the focused field through the
Accessibility API and proves the characters before the cursor are still the ones
we typed before erasing them. That oracle does not exist on Wayland where we
would need it: AT-SPI readback covers GTK/Qt/Firefox — precisely the surfaces
that expose `EditableText` and therefore need no keystrokes at all — while
terminals, Electron/Chromium and XWayland expose nothing. The set of surfaces
that *can* be verified and the set that *requires* synthetic backspaces are
disjoint.

Erasing blind is not a degraded feature, it is a destructive one. A focus
change, a stray click, or a compositor hiccup mid-utterance sends N backspaces
into someone else's buffer, with no undo in a terminal and no undo across apps.

Not erasing deletes, in one stroke: the diff typer, the AT-SPI layer, the
erase-verification layer, the keymap-thrash problem, the stuck-key runaway
hazard, and the wrong-window catastrophe class.

**What replaces it.** Live partial transcripts render in our own pill HUD while
the key is held. On release, cleanup runs and the cleaned text is typed into the
focused app **append-only**, streaming as LLM tokens arrive. The user still sees
text flowing in at roughly a word per second; we simply never take any back.

The macOS raw-then-cleaned swap is not ported. We stream the cleaned text
directly, and fall through to the raw transcript if cleanup is slow or fails.

## Three non-obvious constraints

These are load-bearing and each cost real research to find.

### 1. Chromium and Electron will eat text typed the obvious way

`wtype`'s approach — build an xkb keymap containing whatever codepoints you need
and upload it — breaks on Chromium-based apps. Chromium derives *characters*
from the uploaded keymap but derives `DomCode` from a **hardcoded evdev table**,
and Blink binds editing commands to `DomCode`. So the 14th unique character in an
utterance is placed on evdev keycode 14, which Chromium reads as
`KEY_BACKSPACE`, and it deletes the preceding character
([wtype#71](https://github.com/atx/wtype/issues/71); the fix PR was closed
unmerged and only moved the cliff from 14 to 13). Dictated English uses 60–90
unique codepoints, so this also reaches F5 (reload), F11 (fullscreen), F12
(devtools), Delete and the arrow keys.

**Design:** a single **static two-level keymap** on the 47 evdev codes that carry
no standard semantics — 2–13, 16–27, 30–41, 43–53 — giving 94 slots. That is an
exact fit for the 94 printable non-space ASCII characters (0x21–0x7E). Keycode 42
is declared as a real `modifier_map Shift` and pressed/released like a physical
key so the compositor's xkb state tracks shift naturally.

Space and newline are the exception to the safe-code rule, and safely so: they go
on their *standard* codes, `KEY_SPACE` (57) and `KEY_ENTER` (28). The hazard is
only ever a *disagreement* between our keymap and Chromium's hardcoded table —
where the two agree on what the key means, the standard code is correct. (This is
the same reasoning that would put BackSpace on 14, if we sent one.)

Any codepoint outside this set — curly quotes, em dash, accented characters —
routes the **entire** insert through the clipboard instead. Never a partial mix.

### 2. The virtual keyboard is created once and never destroyed

Destroying a `zwp_virtual_keyboard_v1` is what triggers
[niri#2314](https://github.com/YaLTeR/niri/issues/2314) (the real keyboard stops
working in the focused app until refocus; the Smithay fix was merged and then
reverted) and the XWayland race in
[wtype#62](https://github.com/atx/wtype/issues/62) (X11 clients decode the
keymap asynchronously *after* receiving keystrokes, so restoring the physical
keymap on destroy corrupts them). A persistent virtual keyboard sidesteps both.

Separately, a keymap upload on the seat's active keyboard is broadcast to **every
client on the seat**, each of which runs a full `xkb_keymap_new_from_string`.
Re-uploading at 1 Hz would force ~60 xkb recompiles in every running GTK, Qt and
Electron app on the desktop. With a static keymap a whole dictation session costs
exactly two broadcasts: one when we start typing, one when the user next touches
their real keyboard.

Every key press must be paired with a release under a guard that fires on panic,
drop and signal. If the process dies between press and release the compositor
believes the key is still held — and client-side key repeat then runs away.
wlroots does not lift keys held by an outgoing keyboard
(`seat_client_send_keymap` carries a `TODO` saying so); only Hyprland has a knob
for it (`input:virtualkeyboard:release_pressed_on_close`).

### 3. sway silently drops the release edge

[sway#6456](https://github.com/swaywm/sway/issues/6456), open since August 2021
and filed by someone building push-to-talk: with `bindsym --release Alt_R`, if
any other key is pressed while the bound key is held, the release command never
runs. sway matches the release binding on the *press* event and stores it as
`held_binding`; pressing a second key clears it, and the execute branch only runs
on a release event. The `--release-always` request ([#8803](https://github.com/swaywm/sway/issues/8803))
has no PR.

**Design:** a daemon-side watchdog is mandatory, not a nicety. No `stop` within N
seconds (default 30) → self-cancel, discard the audio, reset the pill. Without
it, a sway user's first accidental keypress leaves the daemon recording until
reboot.

## Architecture

Two binaries, one long-lived process.

```
compositor config                     parlad (long-lived)
  ├─ press  → parlactl start ──┐        ├─ PipeWire capture stream: ALWAYS OPEN
  └─ release → parlactl stop ──┤        │    ring buffer + RMS level
                               │        ├─ whisper.cpp: partials while held,
        unix socket @parla ────┘        │    final pass on stop
                                        ├─ cleanup LLM (streaming)
                                        ├─ virtual-keyboard: persistent, static keymap
                                        ├─ layer-shell pill: level + partials + state
                                        └─ watchdog
```

`parlactl start|stop|toggle|cancel|status|setup|config edit` speaks to `parlad`
over the abstract unix socket `@parla`.

**The capture stream is held open permanently.** `start` only stamps a timestamp
into an already-running ring buffer. Opening the mic on key-down clips the first
syllable; this is a correctness requirement, not an optimization.

The 3–8 ms process-spawn cost of `exec parlactl start` is irrelevant given the
warm ring buffer, and it buys us zero-permission operation — which is the whole
reason to prefer compositor config over evdev.

## Hotkey

**Default: compositor config snippets**, printed by `parlactl setup`.

```
# sway — --no-repeat is MANDATORY (sway re-runs matched press bindings ~25×/sec while held)
bindsym --no-repeat --inhibited Control_R exec parlactl start
bindsym --release   --inhibited Control_R exec parlactl stop
```

```lua
-- Hyprland 0.55+ (Lua). The mod field carries the TARGET modmask, per the wiki.
hl.bind("CTRL + Control_R", hl.dsp.exec_cmd("parlactl start"))
hl.bind("CTRL + Control_R", hl.dsp.exec_cmd("parlactl stop"), { release = true })
```

```sh
# river-classic — note the asymmetric modifier field, undocumented, derived from Mapping.zig
riverctl map          normal None    Control_R spawn 'parlactl start'
riverctl map -release normal Control Control_R spawn 'parlactl stop'
```

The asymmetry between the press and release lines is not a typo. wlroots updates
the xkb modifier state *after* emitting the key event, so on press the mask does
not yet contain the modifier and on release it still does. Each compositor
compensates differently. This is undocumented in all of them.

**Recommend an F13 remap in the docs** (one `keyd` line, or one xkb line). It
removes the press/release modmask asymmetry, unblocks niri's press bind, and —
the real reason — avoids the modifier-leak case where the compositor still
believes Ctrl is held while we inject text.

**evdev is opt-in**, behind `--features evdev`, off by default. Required for niri
(no release binds; [#2456](https://github.com/YaLTeR/niri/pull/2456) and
[#3621](https://github.com/YaLTeR/niri/pull/3621) both unmerged) and river ≥0.4
(`riverctl` removed; keybinding syntax now belongs to whichever window manager
the user runs). Documented bluntly: **the `input` group can read every keystroke
on the machine, including passwords.** Read-only listener, no `EVIOCGRAB`, using
`evdev` directly — not `handy-keys`, whose own tracker documents a runaway
feedback loop from reading back its own injected events.

**Cut: cancel-on-any-other-key, and swallow-Esc-while-recording.** Possible only
on Hyprland (via `catchall` + submaps), needs ~240 generated `bindcode` lines on
sway, impossible on niri. Once we never erase, an unwanted insert costs the user
one Ctrl+Z instead of a corrupted document.

## Text injection

One persistent `zwp_virtual_keyboard_v1`, static keymap as described above,
monotonically increasing millisecond timestamps on every `.key()` (wtype hardcodes
`time = 0`, which was flagged while debugging niri#2314).

Order of preference at commit time:

1. Every codepoint in the static keymap → type it.
2. Otherwise → clipboard + one synthetic Ctrl+V (Ctrl+Shift+V when the focused
   `app_id` is a known terminal), via `wl-clipboard-rs`.
3. Focus guard failed → clipboard only, plus a notification saying so. Never type.

All four target compositors implement `zwp_virtual_keyboard_manager_v1` and none
gate it behind consent.

## Safety rules (what replaces the Accessibility layer)

macOS refuses to erase when it cannot verify. The Linux equivalent is: **never
erase, and only append into a target whose identity we have confirmed did not
change.**

1. **Focus identity guard.** Record the focused toplevel via
   `wlr-foreign-toplevel-management-v1` at key-down; re-check immediately before
   typing. Different toplevel → do not type; put the text on the clipboard and
   notify. (`wlr-foreign-toplevel` is used rather than `swayipc`/`hyprctl`/`niri
   msg` because it is one code path across all four compositors.)
2. **No focus at all** (layer-shell surface focused, empty workspace) → refuse to
   record; pill shows "no target".
3. **Password protection** is an `app_id` denylist plus a `deny_titles` regex in
   config, seeded with 1Password, Bitwarden, KeePassXC. There is no reliable
   detector without AT-SPI and only a partial one with it. This covers the real
   risk for ~10 lines.
4. **Watchdog**: no `stop` within 30s → self-cancel, discard audio.
5. **Newline flattening** carries over from `TextRules`, keyed on `app_id`
   instead of macOS bundle IDs. Terminals must additionally never receive a
   newline, since it executes.

Note the asymmetry with macOS and accept it: a secure field on Linux is detected
by *name*, not by *role*. This is weaker. It is also what every other
cross-platform dictation app does, and it is honest about it in the UI.

## HUD

`wlr-layer-shell`, overlay layer, `keyboard_interactivity = None`,
`exclusive_zone = 0`, empty input region (click-through), anchored bottom-center.
States: recording (level meter + live partial text), thinking, no target, denied,
error.

**Fixed anchor, not caret-following.** AT-SPI `Component.GetExtents(SCREEN)`
returns `(0,0)` under GTK4 — Wayland clients do not know their own screen
position. On a tiling compositor a fixed anchor is better UX regardless.

## Configuration

`config.toml` + `parlactl config edit` (`$EDITOR`). No settings GUI. The Hub's
~1,000 LOC of SwiftUI forms has no counterpart here and this audience edits
config files.

Settings that carry over from `Settings.swift`: dictionary, snippets,
cleanup provider/model/key, history, whisper model path. Settings that do not:
`showHudAlways`, `hudIdleSize`, `liveStreamingEnabled`, `inputDeviceUID` (becomes
a PipeWire node name).

Tray is opt-in behind `--features tray` (`ksni`, consumed by waybar/yambar).
Notifications (`notify-rust` → mako) are the primary out-of-band channel.

## Error handling

Cleanup failure must never kill a dictation — same rule as `Pipeline.clean`,
which returns the raw transcript plus a user-facing reason. Port that behaviour
including the degenerate-output ceiling (LLM repetition loops) and the
`CleanupSanitizer` pass.

Whisper's non-speech markers (`[BLANK_AUDIO]`, `[MUSIC]`, `(silence)`) must be
stripped before anything is typed — port `stripNonSpeech`. Keep the min-audio
floor (`audioWorthTranscribing`) that guards against hallucination on sub-0.4s or
silent buffers.

Every failure path ends in either text landed in the app, text on the clipboard
with a notification, or an explicit refusal shown in the pill. Never a silent
no-op — that is the specific failure mode that made Epicenter's ADR-0040
necessary.

## The biggest risk, and it is not a bug

**The 1–3 second dead gap between key release and the first character
appearing.** On macOS the streaming typer hides this; here we have deliberately
removed it, leaving the user watching a cursor that is not moving. Everything
else in this document is a correctness bug that can be fixed. This one is the
product feeling slow, which is what makes people stop using a dictation app.

Mitigations, in priority order:

1. Type the LLM's tokens the instant they arrive rather than awaiting the full
   response.
2. If cleanup has not produced a first token within ~600 ms, type the raw
   transcript instead.
3. The pill must visibly enter a "thinking" state on key-up so the gap reads as
   working, not frozen.

Budget real time for this.

## Stack

| Component | Crate | Version |
|---|---|---|
| Audio capture | `cpal`, features `["pipewire", "pulseaudio"]` | 0.18.1 |
| Transcription | `whisper-rs` | 0.16 |
| Text injection | `wayland-client` + `wayland-protocols-misc` + `xkbcommon` | 0.31 / 0.3.12 / 0.8 |
| Pill HUD | `smithay-client-toolkit` + `tiny-skia` | 0.21.1 / 0.12 |
| Focus oracle | `wayland-client` (`wlr-foreign-toplevel-management-v1`) | — |
| Hotkey (opt-in) | `evdev`, feature `tokio`, read-only | 0.12 |
| Clipboard | `wl-clipboard-rs` | 0.9.3 |
| Notifications | `notify-rust` | 4.18 |
| Tray (opt-in) | `ksni` | 0.3.6 |
| Config | `toml` | 0.9 |

Deliberately unused: AT-SPI (`atspi`), `wtype`, `ydotool`, `enigo`, GTK, Tauri,
`handy-keys`, `global-hotkey`.

Packaging: AUR (`parla`, `parla-bin`) + Nix flake + systemd user unit.
**No Flatpak** — `security-context-v1` hides virtual-keyboard and layer-shell from
sandboxed clients on sway, river and niri, so a Flatpak build cannot function.

## Testing

Following the existing `Tests/ParlaCoreTests` pattern — pure logic is unit
tested, platform wiring is not.

- Port the existing golden-fixture eval (`eval/cases/*.wav` + `.golden.txt`) and
  run it against the Rust pipeline. This is the shared artifact that keeps the
  Mac and Linux apps from drifting.
- Unit: keymap builder (every printable ASCII codepoint maps to a safe keycode at
  a defined shift level; every non-ASCII input routes to clipboard), newline
  flattening, the min-audio floor, `stripNonSpeech`, the cleanup degenerate-output
  ceiling.
- Unit: the hotkey state machine, injected clock, as `HotkeyMonitor.handle`
  already does — including the watchdog timeout.
- Manual matrix, and this is where the 5 days of long-tail budget goes: foot,
  Alacritty, Firefox, Chromium, an Electron app, a GTK4 app, a Qt app, an
  XWayland app — across sway and Hyprland, single and multi-monitor.

## Effort

| Work | Days |
|---|---|
| Skeleton, config, daemon/CLI socket, systemd unit | 2 |
| cpal PipeWire warm ring buffer + level meter | 2 |
| whisper.cpp integration + model management | 2 |
| virtual-keyboard client: static keymap, safe keycodes, shift levels, clipboard fallback | 4 |
| Layer-shell pill + rendering + states | 3 |
| Hotkey: config snippets, evdev opt-in, watchdog | 2 |
| Focus oracle, denylist, clipboard fallback | 2 |
| LLM cleanup + append-only streaming type | 2 |
| Packaging (AUR, Nix, docs) | 2 |
| Cross-compositor long tail (Electron, XWayland, terminals, multi-monitor) | 5 |
| **Total** | **~26** |

Roughly 5–6 calendar weeks. The diff-typer variant adds ~20 days and would not
work on the surfaces that need it; that is the highest-leverage cut in this
design.

## Windows, afterwards

The Rust core built here — prompts, HTTP client, settings, streaming, focus-guard
logic, text rules — ports to Windows directly. Only the platform layer changes:
`WH_KEYBOARD_LL` for the hotkey (it can swallow, unlike `RegisterHotKey`),
`SendInput` with `KEYEVENTF_UNICODE`, WASAPI, `Shell_NotifyIcon`.

Known Windows hazards to carry into that design: UIPI silently disables the hook,
`SendInput` and UIA whenever an elevated window is foreground; the low-level hook
is silently unhooked after 300 ms in the callback and after lock/unlock and
sleep/resume, so it needs a watchdog; and shipping unsigned is not viable for an
app shaped like a keylogger (Smart App Control blocks it outright).

## What is shared with macOS, and what is not

**Shared, as data:**

- `PromptBuilder`'s prompts (`Cleanup.swift:19-89`) — pure string building, no
  platform dependencies.
- The settings schema and defaults.
- The golden-fixture file: raw transcript in → expected cleaned text out. This is
  the highest-value shared artifact; it keeps behaviour aligned without coupling
  the builds.

**Not shared, deliberately:**

- No Swift core package or FFI shim. The ~900 LOC is about a week to rewrite; the
  build coupling, CI matrix and "cannot change the Mac app without breaking
  Linux" tax all cost more than that week.
- No shared inserter abstraction. macOS streams verified Unicode into a
  classified field; Linux appends into an identity-guarded target. Those are two
  products, not two implementations of one interface.
- Two repos or two crates, two release cadences, one shared fixtures file.

## Open questions for v2

- **AT-SPI `EditableText`.** GTK4 (`gtkatspieditabletext.c`) and Qt
  (`atspiadaptor.cpp`) both fully implement `DeleteText`/`InsertText` at exact
  offsets — atomic in-place editing with no keystrokes at all, and no
  wrong-window risk. That is a strictly better in-place correction path than
  anything macOS has, for GTK/Qt/Firefox windows. It does not cover terminals or
  Electron, so it cannot be the v1 foundation, but it is the right way to add
  in-place correction if users ask for it. Never via synthetic backspaces.
- **`zwp_input_method_v2`** covers GTK/Qt/Firefox with atomic edits and free
  password detection, but conflicts with any running fcitx5/ibus (one IM per
  seat), does not cover terminals, and Chromium's text-input-v3 is still broken
  on sway. A v2 optimization for a feature we are not shipping.
- **GNOME and KDE Wayland** are explicitly out of scope. Their portal is
  chord-only (no bare held modifier), they have no virtual-keyboard protocol, and
  injection via libei is layout-limited. Supporting them means the evdev path and
  the `input` group for everyone.
