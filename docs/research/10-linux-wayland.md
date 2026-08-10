# Linux & wlroots Port

Parla's macOS design rests on four APIs that Wayland does not have: a global event tap, layout-independent Unicode keystroke injection, an accessibility tree you can read, and a secure-field signal. This doc establishes what each one costs on sway/Hyprland, using the shipped code of eleven Linux dictation apps as evidence, and names the parts of the macOS architecture that cannot survive the port. It exists because the `worktree-linux-wlroots-port` branch already has a working M1 (dictate → clipboard) and the next milestone — typing into the focused window — is where every one of these projects bled.

---

## 0. Where Parla's Linux port already is

`worktree-linux-wlroots-port` is a Rust workspace under `linux/`, not a Swift port:

| Crate | What it is |
|---|---|
| `linux/parlad/` | daemon: `audio.rs` (cpal, always-open ring buffer), `whisper.rs` (whisper-rs), `session.rs`, `socket.rs`, `deliver.rs` |
| `linux/parlactl/` | CLI the compositor spawns by name — this *is* the hotkey mechanism |
| `linux/parla-core/` | shared `cleanup.rs`, `prompt.rs`, `config.rs`, `text.rs` |

M1 delivers via `wl-clipboard-rs` only (`linux/parlad/src/deliver.rs`) with a 5 s `HANDOVER_TIMEOUT`, plus `notify_rust` on a blocking thread. `linux/VERIFY.md` is explicit that **none of it has run on real hardware**: "The Wayland clipboard, D-Bus notifications, compositor keybindings, and cpal's PipeWire/PulseAudio backends have **never run**."

Everything below is about M2 and the shape of the ceiling.

---

## 1. API map: what carries, what doesn't

| macOS mechanism | Parla file | wlroots equivalent | Verdict |
|---|---|---|---|
| `CGEvent.tapCreate` global hotkey | `Sources/ParlaCore/Hotkey.swift:112` | **none** on wlroots | ✗ replace with compositor keybind → CLI |
| `CGEventKeyboardSetUnicodeString` | `Sources/ParlaCore/Inserter.swift:41` | `zwp_virtual_keyboard_v1` (wtype) / uinput | ~ partial, layout-dependent |
| `eventSourceUserData` self-marker | `Inserter.swift:7` (`0x50_41_52_4C_41`) | uinput device identity / `LLKHF_INJECTED` analogue | ~ different mechanism |
| `AXUIElementCopyAttributeValue` read-back | `Inserter.canEraseTyped:176` | AT-SPI2 — absent on wlroots | **✗ no equivalent** |
| `AXSecureTextField` detection | `Inserter.classifyFocus:120` | **none** | **✗ no equivalent** |
| `NSPanel` at `.statusBar` level | `Sources/Parla/HUD.swift:89` | `wlr-layer-shell` | ✓ 1:1 |
| `NSStatusItem` menu bar | `Sources/Parla/main.swift:21` | none — status bar module (Waybar) | ~ different shape |
| `SMAppService.mainApp` | `main.swift:1103` | systemd user unit | ✓ 1:1 |
| `AVAudioEngine` input tap | `Sources/ParlaCore/AudioRecorder.swift:134` | cpal → PipeWire | ✓ 1:1, with caveats |
| `AVCaptureDevice.requestAccess` | `main.swift:784` | none (PipeWire has no per-app mic gate) | ✓ simpler |

Two rows are load-bearing and both are ✗. §5 is about what that costs.

---

## 2. Global hotkey capture on wlroots

Wayland gives no client the ability to observe keys it doesn't have focus on. Three approaches exist; the corpus shows convergence on one.

**(a) evdev — read `/dev/input/event*` directly.** vocalinux switches to evdev on Wayland and always under Flatpak (`ui/keyboard_backends/__init__.py:83-170`) "because even with `--socket=x11`, XWayland only delivers keys to the focused X client." hyprwhspr's `lib/src/global_shortcuts.py` (1,374 lines) does the same with optional exclusive `grab()`.

Cost, all from shipped scar tissue:
- Needs the user in the `input` group — vocalinux returns `None` with a permission hint rather than pretending to work.
- Exclusive grab collides with every other input tool. hyprwhspr #45: user's **keyboard was completely dead after login** because keyd already held the grab and hyprwhspr's failed with `[Errno 16] Device or resource busy`. `grab_keys` now defaults to **false**, with backoff `min(0.1 * 2**retry, 2.0)` over 10 retries.
- Mice with many buttons look like keyboards. hyprwhspr #40: an MX Master got grabbed and **the mouse died** the instant the service started.
- `SYN_DROPPED` under load (whisper decoding *is* the load) can lose a key **release** → push-to-talk sticks on forever. hyprwhspr #338 fixes it by discarding events until the next `SYN_REPORT` and resetting combo state.
- Devices hot-plug. hyprwhspr #241: unplug a USB keyboard, `select()` keeps reporting the fd readable, `read()` returns `ENODEV`, dead fd never removed → **100% CPU busy loop**. #431: a Bluetooth keyboard paired 34 s after start was invisible until restart; fixed with a 2.0 s rescan.

**(b) XDG portal `org.freedesktop.portal.GlobalShortcuts`.** murmure shipped it (PR #315) then **removed it entirely** (PR #356), leaving a hardcoded allowlist that documents why (`src-tauri/src/utils/platform.rs:191-195`, verified):

```rust
// Whitelist of desktop environments where the XDG Portal … path is known to be
// reliable. Anything outside this list (GNOME/Mutter, Cinnamon, MATE, XFCE-Wayland,
// unknown DEs) defaults to CLI because there is no robust runtime probe for portal capability.
const PORTAL_RELIABLE_DESKTOPS: &[&str] = &["KDE", "Hyprland", "sway"];
```

**(c) CLI trigger — the compositor owns the keybind.** hyprwhspr #420 (17 comments) is the canonical thread: Wayland forbids listening for unfocused windows, so they stopped fighting it and shipped `openless --toggle-dictation` style commands bound in the user's own config. murmure went further and *generates* the config: gsettings dconf paths for GNOME, `~/.config/sway/voquill-hotkeys`, `~/.config/hypr/voquill-hotkeys.conf` + reload, COSMIC custom shortcuts (`docs/wayland-hotkeys-wlroots.md` in voxtype documents the same pattern).

**Parla already picked (c).** `linux/README.md`: "your compositor spawns `parlactl` by name." That is correct and matches every project that tried the alternatives.

The one thing (c) loses: **push-to-talk key-release**. A compositor `bind` fires once. Hyprland has `bindr` (release) and sway can bind `--release`, so PTT is expressible on wlroots — but it is two separate compositor bindings calling `parlactl start` / `parlactl stop`, not one edge stream. GNOME's custom-shortcut system has no release event at all, which is why murmure **forces ToggleToTalk on Wayland** rather than offering PTT it can't deliver.

---

## 3. Text injection on Wayland

### 3.1 The ladder everyone converges on

voxtype's default (verified in `src/output/mod.rs:251-258`):

```rust
const DEFAULT_DRIVER_ORDER: &[OutputDriver] = &[
    OutputDriver::Wtype,      // zwp_virtual_keyboard_v1 — no daemon, best Unicode
    OutputDriver::Eitype,     // libei — the only thing that works on GNOME/KDE
    OutputDriver::Dotool,     // uinput, XKB-aware
    OutputDriver::Ydotool,    // uinput, needs ydotoold
    OutputDriver::Clipboard,  // wl-copy
    OutputDriver::Xclip,      // X11
];
```

vocalinux's is IBus-first then ydotool → wtype → xdotool-via-XWayland → clipboard. hyprwhspr's is ydotool (if `ydotoold` reachable) → ydotool bare → wtype → xdotool → clipboard.

| Backend | Protocol | Works on wlroots | Works on GNOME | Unicode | Daemon |
|---|---|---|---|---|---|
| wtype | `zwp_virtual_keyboard_v1` | ✓ | ✗ (Mutter doesn't implement it) | ✓ full | no |
| eitype | libei / `zwp_input_method_v2` | ~ | ✓ | ✓ | portal |
| dotool / ydotool | `/dev/uinput` | ✓ | ✓ | ✗ keycodes only | yes |
| IBus commit | IBus IM | ✗ on wlroots† | ✓ | ✓ | ibus-daemon |
| wl-copy + Ctrl+V | clipboard | ✓ | ✓ | ✓ | no |

† vocalinux's denylist, verified in `src/vocalinux/text_injection/text_injector.py:236-245`:

```python
_IBUS_UNBRIDGED_COMPOSITORS = (
    "cosmic", "sway", "hyprland", "wayfire",
    "river", "niri", "labwc", "weston",
)
```

Re-admitted only if `pgrep -x ibus-wayland` succeeds — IBus ≥1.5.32 ships the `zwp_input_method_v2` relay those compositors lack.

### 3.2 The keycode problem is the whole game

uinput injects **positional evdev keycodes**, re-mapped by the compositor through the user's active layout. This is vocalinux's single deepest scar — thirteen issues over eight months:

- #199: AZERTY user dictating English gets `"I'm talking in English"` → **`"Iù, tqlking in English"`**
- #164: German QWERTZ, y/z swapped, ä/ö dropped: `"message"` → `"​,essqge"`, `"avec"` → `"qvec"`
- #362/#266: accented chars and umlauts vanish entirely

A partial fix that routed only *non-ASCII* through the clipboard (PR #376) was **wrong** — ASCII is layout-dependent too. The real fix, PR #480, routes **all** ydotool injection through clipboard+Ctrl+V. Shipped code now says:

```python
logger.info("Using clipboard paste for ydotool (instant, layout-independent)")
```

And still not closed: vocalinux #657 (0.15.0 AppImage regressed for Russian), #664 (Brazilian ABNT2 — layout permanently flipped to `us` **and stayed flipped after quitting**).

wtype does not have this problem — it sends keysyms over the virtual-keyboard protocol. That is the entire argument for wtype-first on wlroots.

### 3.3 Measured uinput timing (murmure, verified in `src-tauri/src/utils/wayland_inject.rs:23-33`)

```rust
const ENUMERATION_DELAY: Duration = Duration::from_millis(500);  // after UI_DEV_CREATE
const INTER_KEY_DELAY:  Duration = Duration::from_millis(16);
const CHORD_HOLD_DELAY: Duration = Duration::from_millis(16);
// "Below this hold, repeated keys (notably space and doubled letters) are
//  intermittently dropped on some Wayland compositors."
const SPACE_HOLD_DELAY: Duration = Duration::from_millis(24);
```

**~16 ms/char ⇒ a ~60 chars/s ceiling.** A 300-character dictation takes 5 seconds to type. vocalinux measured the same wall (#482): ydotool's default `--key-delay 20 --key-hold 20` ≈ 40 ms/char meant a 100-char transcription took **~4 s** of visible typing; they cut to `--key-delay 8` but deliberately **not 0** — zero causes a Shift leak, `"Can you"` → `"CAN YOu"`.

Also from that file: `release_modifiers()` on any mid-sequence write failure — "A write dying mid-sequence would otherwise leave Shift or AltGr held down on the virtual device, shifting everything the user types next."

### 3.4 Daemon startup cost

voxtype `src/output/dotool.rs:9-20`: "The ~700ms uinput device setup is paid once at daemon startup, not on every typed segment. **Sub-10ms per call.** Strongly recommended for streaming backends … without the daemon, the first call alone stalls for nearly a second."

Detection must be a real connect, not a stat. voxtype opens the FIFO `O_WRONLY | O_NONBLOCK` because a crashed daemon leaves a stale FIFO and the kernel returns `ENXIO`. vocalinux's `_is_ydotoold_running()` tries `SOCK_DGRAM` then `SOCK_STREAM` (ydotool 1.x changed) and treats `EPROTOTYPE (91)` as "wrong type, do NOT unlink" so it never deletes a live daemon's socket.

hyprwhspr spawns its **own private** `ydotoold` (`lib/src/ydotoold_session.py`) at `$XDG_RUNTIME_DIR/hyprwhspr-ydotool.sock` rather than managing the system unit — the unique path doubles as a safe `pkill -f` pattern.

### 3.5 The version trap

vocalinux `text_injector.py:1405`: ydotool 0.1.x wants `key ctrl+v`; 1.x wants raw scancodes `29:1 47:1 47:0 29:0`. Passing 1.x codes to 0.1.x doesn't error — **it types the literal string `"2442"`** into your document. Detection parses `ydotool key --help`; unknown ⇒ default to the legacy form *because it fails loudly instead of typing digits*.

### 3.6 Held-modifier collision — two independent implementations agree

The dictation hotkey is held while the transcript lands. Synthesized letters then merge with the modifier.

- vocalinux PR #494: PTT modifier still down ⇒ Ctrl+V becomes Ctrl+Alt+V ⇒ **nothing pastes**. Symptom users report: "the text is on my clipboard but nothing pasted." Intermittent *by construction* — fast transcriptions fail, slow ones work. Fix polls evdev across all keyboards for `{29,97,56,100,42,54,125,126}` at 15 ms, bounded 1.0 s, returns immediately when nothing is held.
- voxtype `src/output/modifier_guard.rs` (186 lines) does the same with `EVIOCGKEY` (`Device::get_key_state`) — a *passive* snapshot, no event consumption — over the same 8 keys, `modifier_release_timeout_ms = 750`, `wait_for_modifier_release = true` by default. On timeout it does not proceed: it drops keystroke methods, falls to clipboard-only, **and fires a notification** — "Silent clipboard fallback leaves users staring at an empty cursor wondering why nothing was typed."

Parla already has the macOS version of this bug documented at `Sources/Parla/main.swift:179`: live typing is hard-disabled because "keystrokes posted while fn is physically held merge with the modifier." Same bug, two platforms.

### 3.7 Never send Escape, never send literal `\b`

- vocalinux #549: the xdotool path ran `xdotool key --clearmodifiers Escape` after typing. **Telegram treats Escape as "leave the input field"** — every dictation kicked the user out of the composer. Replaced with an explicit `keyup` of eight named modifiers.
- vocalinux `action_handler._handle_delete_last` sends `"\b" * n` — literal backspace **characters**, not key events. That types garbage. parrot has the same defect.

This is the empirical basis for Parla's never-send-BackSpace rule on Linux.

---

## 4. Clipboard on Wayland — and why it's often unavoidable

**It is the only layout-independent, Unicode-complete, daemon-free path that reaches native Wayland clients.** That is why vocalinux, having tried everything else, made it the *preferred* ydotool path rather than a fallback.

The costs are real and every project paid them:

**Data loss.** vocalinux PR #588: Arabic users hit the clipboard path on *every* dictation, so a copied URL was destroyed every time. The original code shipped with the comment "There is no attempt to restore it afterward, as there is no safe race-free way to do so on Wayland."

**The restore protocol that actually works** (vocalinux `text_injector.py:1311-1400`, ~90 lines): save → paste → `sleep(0.3)` → re-read → **restore only if the clipboard still equals what we wrote**; overlapping pastes share one `_clipboard_restore_target` (pre-*first*-injection content) plus a `_clipboard_restore_generation` counter so stale restorers exit; distinguish `""` (wl-paste's "nothing is copied") from `None` (image/file — restoring `""` over an image is also data loss).

**Subprocess deadlock.** vocalinux measured in PR #480: `wl-copy` forks a child that **owns the selection** and inherits your pipes, so `subprocess.run(..., stderr=PIPE)` blocks until the clipboard is next overwritten — possibly never. `PIPE` → 2.5 s timeout and a false "copy failed"; `DEVNULL` → **~0.06 s**. Parla's `deliver.rs` avoids this entirely by using `wl-clipboard-rs` in-process, which is better — but has its own version of the same hazard, correctly documented in the existing code: `foreground(false)` is pinned explicitly because the other setting blocks until someone else takes the selection.

**Silent no-op on the wrong session.** vocalinux #346: `wl-copy` under X11 **exits 0 and copies nothing**. They shipped for months copying into the void. Availability probing must be session-aware, not `which`-based.

**It still leaks.** vocalinux #663 (open): clipboard managers (Klipper) keep the dictated text in history regardless of restore. Unavoidable; document, don't fix.

---

## 5. What cannot carry over from macOS

This is the section that matters most for Parla specifically.

### 5.1 `canEraseTyped` has no Wayland equivalent — the raw-then-cleaned swap is dead

Parla's central latency trick (`Sources/Parla/main.swift:400-548`) is: type the raw transcript instantly, then swap in the cleaned version with a minimal grapheme-tail diff, gated on `Inserter.canEraseTyped` (`Sources/ParlaCore/Inserter.swift:176-182`) proving the exact UTF-16 units immediately before the cursor are still ours.

On wlroots there is **no AT-SPI**, no `kAXValue`, no cursor offset. vocalinux's entire Linux accessibility layer is stubs — `get_text_field_info`, `get_focused_field_info`, `check_focused_paste_target` all return `None`/`Unknown`. voxtype's `check_focused_paste_target` returns `Unknown` unconditionally on Linux.

So the proof `canEraseTyped` provides is unobtainable, and Parla's own rule says: cannot prove ⇒ do not delete. Three consequences:

1. **No swap.** The Linux port must decide raw-vs-cleaned *before* it types anything.
2. **LLM latency returns to the critical path.** On macOS, cleanup is free (it happens after the text has landed). On Linux, cleaned output means the user waits for the round-trip. Parla's existing `HANDOVER_TIMEOUT` shape in `deliver.rs` is the right instinct; the cleanup timeout (`Sources/ParlaCore/Cleanup.swift:177`, 15 s) is far too long to sit in front of insertion.
3. **The whole `LiveTyper` module** (`Sources/ParlaCore/LiveTyper.swift`) is macOS-only. `swapPlan`'s `erase = max(d.erase, 1)` invariant exists to guarantee a verifiable tail — with nothing to verify against, it's not portable.

### 5.2 Secure-field refusal has no equivalent

Parla refuses password fields at three checkpoints (`main.swift:165`, `:407`, `:515`) via `AXSecureTextField`. On Wayland: **not found in any of the eleven projects.** `rg -i 'password|secure input'` over vocalinux returns nothing. There is no protocol that tells a client the focused surface is a password box.

Two mitigations exist in the corpus, both weak: vocalinux's per-app `auto_paste: false` opt-out (manual allowlist, explicitly motivated by "avoid leaking dictated text into a password field") and murmure's insertion-mode `None`. Neither is detection.

Parla's posture should be: **on Linux, the secure-field guarantee does not hold, and the docs must say so.** The clipboard path makes it worse — a transcript dictated near a password prompt lands in the clipboard manager's history.

### 5.3 The synthetic-event self-marker has no direct analogue

`Inserter.syntheticMarker = 0x50_41_52_4C_41` stamped into `eventSourceUserData` (`Inserter.swift:7`) is what stops Parla's event tap cancelling on its own typing (`Hotkey.swift:152`). On Linux, if Parla ever reads evdev *and* writes uinput, the same loop exists — hyprwhspr's `global_shortcuts.py:276` names it: "Never grab our own UInput virtual keyboard. Doing so creates a feedback loop (physical key -> virtual -> re-grab) that locks out all input." The CLI-trigger model sidesteps this entirely, which is another point in its favour.

### 5.4 Per-app newline flattening degrades

`TextRules.flattensNewlines` (`Sources/ParlaCore/TextRules.swift:26`) keys off 14 bundle IDs. Wayland has no bundle ID — you get `app_id` from `hyprctl activewindow -j` / `niri msg --json focused-window` / `swaymsg`, all compositor-specific, and vocalinux's `_get_active_window_info()` needs a four-tier ladder for it. hyprwhspr's terminal set (`lib/src/text_injector.py:587-601`, verified) matches on both short and reverse-DNS forms of the same app:

```python
terminals = {
    'ghostty', 'com.mitchellh.ghostty',
    'kitty',
    'wezterm', 'org.wezfurlong.wezterm',
    'alacritty', 'org.alacritty.alacritty',
    'foot',
    'konsole', 'org.kde.konsole',
    'gnome-terminal', 'org.gnome.terminal',
    'ptyxis', 'org.gnome.ptyxis', 'io.gitlab.ptyxis.ptyxis',
    ...
}
```

Note it also strips `'.' in window_class` down to the last segment — because Konsole on X11 intermittently reports no WM_CLASS at all, so vocalinux additionally reads `/proc/<pid>/comm`.

---

## 6. Portal permissions

Only three portals matter here, and Parla needs at most one.

| Portal | Purpose | Needed? |
|---|---|---|
| `org.freedesktop.portal.GlobalShortcuts` | hotkeys | **no** — CLI-trigger avoids it (§2) |
| `org.freedesktop.portal.RemoteDesktop` (`NotifyKeyboardKeycode`) | input injection | only as a GNOME/KDE fallback |
| `org.freedesktop.impl.portal.Access` | mic | **no** — PipeWire has no per-app mic gate outside Flatpak |

openwhispr's Linux paste ladder shows the one non-obvious ordering rule (`src/helpers/clipboard.js`): **KDE Wayland → portal first, then uinput** ("clipboard and input are both on X11; uinput causes clipboard desync"); **GNOME Wayland → uinput first, then portal** ("the portal often times out or shows a confusing permission dialog, causing a 10s+ delay"). Portal permission tokens are persisted so the dialog appears once; a denial latches for the session.

The mic story is the one place Linux is *simpler* than macOS: no TCC, no `AVCaptureDevice.requestAccess`, no permission-invalidated-by-rebuild problem. Parla's `main.swift:784-792` request path has no Linux counterpart. Flatpak is the exception (`--device=input` for evdev, plus a mic socket).

---

## 7. PipeWire audio capture

cpal targets ALSA and routes through PipeWire's ALSA compat by default; murmure uses cpal 0.15, voxtype cpal 0.15, Handy cpal 0.16. Parla's `linux/parlad/src/audio.rs` already uses cpal with an always-open ring buffer, which matches the best practice below.

**Don't force 16 kHz on the device.** Handy PR #1084: "instead of forcing the microphone to open at 16kHz (which can cause issues with bluetooth codecs, some ALSA drivers, and other devices that advertise 16kHz support but produce suboptimal audio), use the device's native/default sample rate and let the existing FrameResampler downsample." Same finding in vocalinux #340/#262: a Focusrite Vocaster fails hard with `[Errno -9998] Invalid number of channels` / `-9997 Invalid sample rate` on a hardcoded 16 kHz mono probe. Their fix orders candidates `[device_default] + [48000, 44100, 32000, 22050, 16000, 8000]`, mono before stereo. Parla's macOS `AudioRecorder.swift:150` already does the right thing (`input.outputFormat(forBus: 0)` then convert).

**Anti-aliasing matters.** vocalinux's downsample is bare `np.interp` with **no lowpass** — 48k→16k is 3:1 decimation, so everything 8–24 kHz folds into the speech band. voxtype uses `soxr` at quality `HQ` and its resampler *raises* rather than returning unconverted audio: "returning the input after a failed conversion would make its samples carry an incorrect rate label." Parla's macOS path has the mirror-image bug — a fresh `AVAudioConverter` per tap buffer (`AudioRecorder.swift:115`) restarts the filter at every boundary.

**Keep the device warm.** hyprwhspr #153 (32 comments): first recording after ~10 s idle fails with `Expression 'paTimedOut' failed … [PaErrorCode -9987]`; second press works. Root cause is PipeWire/ALSA node suspend (`session.suspend-timeout-seconds`) powering the USB mic down. Their fix holds a silent stream open — but gated on `_is_multiplexed_audio_server()`, which checks for `/run/user/$UID/pipewire-0` or `pulse/native` sockets, because on raw ALSA a keepalive holds an exclusive lock and blocks every other app. Corollary from the same file: **release the keepalive *after* the real stream starts** — "closing it first was the cause of the cold-start timeout."

**Bluetooth.** vocalinux #70: BT headsets sit in A2DP (no mic); the profile switch is WirePlumber's job, and it will land in your issue tracker as an app bug regardless.

---

## 8. systemd user services

The whole unit reduces to one file. hyprwhspr's (`config/systemd/hyprwhspr.service`) is the pattern worth copying:

- `WantedBy=graphical-session.target` (not `default.target` — the session must exist)
- `ExecStartPre` bash loop polling up to **60 × 0.25 s** for a Wayland socket or `$DISPLAY` before starting. hyprwhspr #12: the service ran before the session existed, and "checking status appears to fix it" was a red herring; the durable fix was detecting Wayland via the **socket file, not the env var**.
- `ExecStopPost` `pkill -f` the private ydotoold socket path.

Two adjacent scars: hyprwhspr #43 — the Waybar health probe requested recovery, which restarted capture, which failed the next probe: **an infinite restart loop caused by the status indicator itself**. And #77 added a restart limit. Also #305: a PID-file lock in `$XDG_RUNTIME_DIR` survived a hard reboot → 51 restarts, "another instance is already running" with no such process. Validate the PID is alive *and is you*.

hyprwhspr #200 is the cheapest lesson here: the tray health probe used `timeout 0.2s bash -lc "$*"`, so a **login shell** sourced `/etc/profile` + `~/.bash_profile` on every 200 ms poll. The actual `pactl` calls take 15–20 ms.

---

## 9. Status bar integration

Two shapes in the corpus:

**File-based (hyprwhspr).** Writes `recording_status`, `audio_level`, `visualizer_state`, `transcript_preview` into `$XDG_RUNTIME_DIR/hyprwhspr/`; Waybar/Noctalia modules poll at 1 Hz. Also a named FIFO `recording_control` and a Unix socket for commands.

**JSON emitter (voxtype).** `status_json.rs` emits Waybar format `{text, tooltip, class, backend}` with themed icon sets — emoji / nerdfont / codicons / dots / arrows / text — plus a dedicated `docs/WAYBAR.md`. `voxtype status --follow` uses `notify` to tail the state file rather than polling.

The follow variant is strictly better: `notify`/inotify beats a 1 Hz poll, and it's what removes hyprwhspr's #200-class \"probe is more expensive than the work\" problem.

**Overlay (layer-shell).** `wlr-layer-shell` is the 1:1 replacement for Parla's `NSPanel` at `.statusBar`. Three implementations in the corpus: voxtype ships all three behind cargo features (`osd-native` = smithay-client-toolkit + wgpu + egui; `osd-gtk4` = gtk4-layer-shell 0.8; quickshell QML). hyprwhspr runs GTK4 + `gtk4-layer-shell` as a **separate daemon process**, LD_PRELOAD'd with the resolved `libgtk4-layer-shell.so`, shown/hidden with SIGUSR1/SIGUSR2 — "eliminates subprocess spawn latency on each recording."

Two GNOME caveats: Mutter has no layer-shell, so hyprwhspr **disables the overlay entirely** there ("would steal keyboard focus and swallow the paste keystroke"), and murmure PR #470 re-execs the pill process with `GDK_BACKEND=x11` to get XWayland, using its own `x11` value as the already-re-exec'd marker so there's no exec loop.

---

## 10. Packaging

| Format | Who ships it | Notes from the corpus |
|---|---|---|
| AUR | hyprwhspr (`hyprwhspr`, `hyprwhspr-git`), vocalinux, voxtype | cheapest for an Arch/wlroots audience |
| `.deb`/`.rpm` | voxtype, vocalinux | voxtype ships **every** binary variant under `/usr/lib/voxtype/` + a wrapper that dispatches by detected CPU/GPU |
| AppImage | voxtype (×3), vocalinux, hyprwhspr | **cannot install udev rules** — needs a copy-paste `sudo tee` fallback |
| Flatpak | vocalinux (#167, **10 reactions — highest open issue in that repo**) | needs `--device=input` for evdev |
| Nix flake + NixOS + home-manager | voxtype | |
| `curl \| sh` | hyprwhspr, voxtype | hyprwhspr #315: piped installs consume stdin so every prompt auto-answers. Fix: `if [ -e /dev/tty ] && [ -r /dev/tty ]; then exec < /dev/tty; fi` |

**GLIBC is the release-killer.** murmure #87: built on a modern runner ⇒ `GLIBC_2.38` required ⇒ dead on Ubuntu 22.04 (glibc 2.35, supported to 2027). Fix: build on Ubuntu 22.04, permanently.

**The udev rule is the one packaging artifact worth copying verbatim.** murmure's `packaging/linux/60-murmure-uinput.rules` (read in full):

```
# systemd-logind applies an ACL tagged `uaccess` to the currently-active
# seat on login, so the rule only grants access to the local interactive
# user — not to SSH sessions or background services.
#
# Security scope: this grants *write* access to uinput (input injection),
# NOT read access to /dev/input/event* (keylogging). A malicious local
# program could synthesise keystrokes but cannot observe them. Precedent:
# LizardByte Sunshine, RustDesk, Wooting, Solaar, Steam Input all ship a
# functionally identical rule.
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", GROUP="input", MODE="0660", TAG+="uaccess"
```

`TAG+="uaccess"` is the part most projects miss — it scopes access to the active seat instead of the whole `input` group. The `.deb` postinst runs `udevadm control --reload-rules` + `udevadm trigger --property-match=DEVNAME=/dev/uinput` so no reboot is needed.

---

## 11. Recommended stack for Parla on sway/Hyprland

| Concern | Choice | Why |
|---|---|---|
| Hotkey | compositor keybind → `parlactl` (already shipped) | §2; PTT via `bindr`/`--release` as two bindings |
| Capture | cpal at device-native rate → soxr HQ → 16 kHz | §7; already in `linux/parlad/src/audio.rs` |
| Keepalive | silent stream, gated on PipeWire/Pulse socket presence | hyprwhspr #153 |
| Injection tier 1 | **wtype** (`zwp_virtual_keyboard_v1`) | layout-independent, no daemon, native Wayland |
| Injection tier 2 | wl-copy + Ctrl+V via wtype, with changeCount-guarded restore | §4 |
| Injection tier 3 | clipboard-only + notification, never silent | voxtype's rule |
| uinput/ydotool | **skip for v1** | 60 chars/s, layout garbling, daemon, udev rule, version trap |
| Modifier guard | `EVIOCGKEY` passive scan, 15 ms poll, 750 ms bound, notify on timeout | §3.6 |
| Overlay | `gtk4-layer-shell` or smithay layer-shell, separate process | §9 |
| Status | state file + `--follow` via inotify, Waybar JSON | §9 |
| Service | systemd user unit, `WantedBy=graphical-session.target`, socket-poll `ExecStartPre` | §8 |
| Packaging | AUR first, then `.deb` built on 22.04 | §10 |

Skipping uinput costs GNOME/KDE support (no `zwp_virtual_keyboard_v1` there). That is the correct trade for a wlroots-first port and matches the corpus's own conclusion that the two families need different backends.

---

## What Parla should do

Ordered. Effort in parens.

1. **Write down that the swap is dead on Linux, and pick the replacement.** (S) `canEraseTyped` (`Sources/ParlaCore/Inserter.swift:176`) has no Wayland equivalent (§5.1), so `linux/` must choose raw-vs-cleaned *before* typing. Cheapest correct answer: keep M1's clipboard model for cleaned text, and add a `--raw` mode that skips the LLM entirely. Add this as a section to `linux/README.md` next to the existing M1/M2 note.

2. **Cut the cleanup timeout on the Linux path.** (S) `Sources/ParlaCore/Cleanup.swift:177` uses 15 s, which is fine on macOS because insertion already happened. On Linux the user is staring at nothing for that whole window. Mirror `deliver.rs`'s `HANDOVER_TIMEOUT` reasoning: bound it at ~4 s in `linux/parla-core/src/cleanup.rs` and fall through to raw, which the existing notification copy (`Copied (raw — no API key)`) already handles.

3. **Ship the wtype tier before any uinput work.** (M) One new backend in `linux/parlad/src/deliver.rs` alongside `to_clipboard`: probe non-destructively with `wtype ""` and scan stderr for `"compositor does not support"` (voxtype `_probe_wtype_support`) — **never** probe by typing a word, which is what voxtype PR #627 had to fix after it typed `"test"` into users' documents. Fall back to the existing clipboard path on any failure.

4. **Add the modifier guard before the first keystroke lands.** (M) `EVIOCGKEY` passive scan over `{29,97,56,100,42,54,125,126}`, 15 ms poll, 750 ms ceiling, and on timeout drop to clipboard **plus a notification** (§3.6). This is the exact bug already documented at `Sources/Parla/main.swift:179` on macOS; do not ship Linux injection without it.

5. **State the secure-field gap in the docs.** (S) `Sources/ParlaCore/Inserter.classifyFocus` guarantees password-field refusal on macOS; Linux has no equivalent (§5.2). `linux/README.md` should say so plainly, and the clipboard path should say it too — the transcript reaches the clipboard manager's history regardless.

6. **Fix the resampler on both platforms while it's fresh.** (M) macOS `Sources/ParlaCore/AudioRecorder.swift:115` builds a new `AVAudioConverter` per tap buffer, restarting the filter at every ~85 ms boundary; Linux should use soxr HQ, not linear interp (§7). One shared decision, two implementations.

7. **Add the mic keepalive, gated.** (M) `linux/parlad/src/audio.rs` already keeps the stream open, which is right — add the `_is_multiplexed_audio_server()` gate (PipeWire/Pulse socket present) so raw-ALSA users don't get the device locked, and release the keepalive *after* the real stream starts.

8. **systemd unit + AUR PKGBUILD.** (M) `WantedBy=graphical-session.target`, socket-polling `ExecStartPre`, PID-liveness check on the lock. AUR before `.deb`; if `.deb` happens, build on Ubuntu 22.04 (§10).

9. **Layer-shell overlay as a separate process.** (L) Only after 3–4 land. Parla's `Sources/Parla/HUD.swift` maps cleanly onto `wlr-layer-shell`, but the corpus is unanimous that it belongs in its own process signalled by SIGUSR1/SIGUSR2, not inline.

10. **Do not build a uinput backend for v1.** (—) 60 chars/s ceiling, layout garbling that took vocalinux thirteen issues and is still open, a daemon to supervise, a udev rule to ship, and a 0.1.x-vs-1.x version trap that types `"2442"` into documents. Revisit only if GNOME/KDE support becomes a requirement — and if it does, copy murmure's udev rule verbatim, including the `TAG+="uaccess"` and the security-scope comment.
