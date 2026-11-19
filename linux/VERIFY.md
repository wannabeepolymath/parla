# Linux verification checklist — M1

Everything in this milestone was written and tested on macOS. The Wayland
clipboard, D-Bus notifications, compositor keybindings, and cpal's
PipeWire/PulseAudio backends have **never run**. That is why M1 is not "done"
until this list passes on a real wlroots box.

Checks 1–8 are ordered by how likely each is to be wrong. To execute them, do
5 (build) and 8 (model) first: every other check needs a built daemon with a
model. The baseline items B1–B5 record observations only; lanes 09 and 11 use
them as their "before" numbers.

How to fill this in: tick a box only after running it. On each `Result:` line
write `pass`, `fail` or `not run`. Put what you saw (log lines, clipboard text,
anything surprising) on the `Notes:` line. Leave nothing blank: an unrun item
is `not run`, not empty.

## Run record

One table per run. Copy it for a second machine or audio stack.

| Field | Value |
|---|---|
| Date | |
| Tester | |
| Distro and version | |
| Compositor and version (`swaymsg -t get_version` / `hyprctl version`) | |
| Audio server and version: PipeWire / PulseAudio / plain ALSA (`pactl info`, `pipewire --version`) | |
| Microphone model and connection (built-in / USB / analog / Bluetooth) | |
| `parlad` commit (`git rev-parse HEAD`) | |
| Model file path | |
| Model sha256 (`sha256sum <model>`) | |
| Notifier and version (mako / dunst / swaync) | |

---

## 1. The clipboard actually receives the dictation

`wl-paste` returns your words, still returns them 30 seconds later, and still
returns them on a second and third paste. Nothing on macOS could tell us
anything about this path.

The selection is served by a background thread inside `parlad` with
`ServeRequests::Unlimited`, so repeated pastes over time are the thing to try.

- [ ] **1. Clipboard receives the dictation and keeps serving it**

Command (`parlad` running in the session, speak during the sleep):

```sh
parlactl start; sleep 3; parlactl stop
wl-paste            # immediately
sleep 30; wl-paste  # 30 s later
wl-paste; wl-paste  # second and third paste
```

Expect: every `wl-paste` prints the dictated words.

Result:

Notes:

## 2. The clipboard does NOT survive the daemon — and that is correct

`pkill parlad`, then `wl-paste`, comes back empty. The serving thread lives in
the `parlad` process, so the selection dies with it. This is expected
behaviour, not a bug.

Only worry if pastes fail *while the daemon is running*.

- [ ] **2. Selection dies with the daemon**

Command (after a successful dictation from check 1):

```sh
pkill parlad
wl-paste
```

Expect: `wl-paste` comes back empty (or reports no selection).

Result:

Notes:

## 3. Notifications

A notification appears with the `Copied: …` preview under your notifier (mako,
dunst, swaync).

Then **kill the notifier and dictate again**: the text must still reach the
clipboard, with only a `parlad: notify failed` line in the log. A missing
notification daemon must never cost you a dictation.

If you can provoke a clipboard failure — running `parlad` with
`WAYLAND_DISPLAY` unset is the easiest way — check that **`Parla — clipboard
failed` does not auto-dismiss**. That toast carries your entire untruncated
dictation and is set to `Timeout::Never`, but some notifiers override that with
their own default. If yours does, the text is still in the log.

- [ ] **3a. `Copied: …` notification appears**

Command: dictate once (`parlactl start; sleep 3; parlactl stop`, speaking).

Expect: a `Parla` notification with `Copied: <preview>`, and the log line
`parlad: Parla — Copied: …`.

Result:

Notes:

- [ ] **3b. Dead notifier does not cost the dictation**

Command:

```sh
pkill mako   # or dunst / swaync
parlactl start; sleep 3; parlactl stop
wl-paste
```

Expect: `wl-paste` prints the words; the log shows `parlad: notify failed: …`
and nothing else goes wrong.

Result:

Notes:

- [ ] **3c. `Parla — clipboard failed` stays up**

Command (notifier running again):

```sh
pkill parlad
env -u WAYLAND_DISPLAY parlad &
parlactl start; sleep 3; parlactl stop
```

Expect: a `Parla — clipboard failed` notification with the whole dictation and
`(also in the log)`, which does not auto-dismiss; the log shows
`parlad: clipboard failed: …`. If your notifier dismisses it anyway, note the
notifier and its timeout setting.

Result:

Notes:

## 4. Cleanup failure still delivers

Unset the cleanup API key and dictate. Expect `Copied (raw — no API key): …`
and the raw transcript on the clipboard. Cleanup failing must never cost you
your words.

- [ ] **4. Missing API key delivers the raw transcript**

Command (with a `[cleanup]` provider other than `"none"` in `config.toml`):

```sh
pkill parlad
env -u ANTHROPIC_API_KEY parlad &   # the variable your api_key_env names
parlactl start; sleep 3; parlactl stop
wl-paste
```

Expect: notification `Copied (raw — no API key): …`; `wl-paste` prints the raw
transcript.

Result:

Notes:

## 5. The build itself

cpal's `pipewire` and `pulseaudio` backends have never been compiled. Expect a
first Linux build to break here rather than in the pipeline. You need cmake, a
C/C++ toolchain, libclang, and your audio stack's development headers.

- [ ] **5. Release build succeeds**

Command:

```sh
cd linux && cargo build --release
install -Dm755 target/release/parlad target/release/parlactl -t ~/.local/bin/
```

Expect: both binaries build and install. On failure, record the first error
and the packages you had to add (with distro package names).

Result:

Notes:

## 6. A real hotkey, through the compositor

Not `parlactl` from a shell — an actual keybinding from `parlactl setup`,
pasted into your config and reloaded. Hold Right Ctrl, speak, release.

Include the [sway#6456](https://github.com/swaywm/sway/issues/6456) case the
watchdog exists for: **hold the hotkey, press another key, then release.** sway
silently drops the `--release` binding in that situation, so the `stop` never
arrives. The watchdog should fire within 30 s and you should see
`Recording timed out — discarded`.

If you check `parlactl` by hand instead, put a `sleep 0.4` between `start` and
`stop` — two back-to-back spawns take about 4 ms, inside the 200 ms
accidental-tap guard, so `stop` correctly answers `cancelled`.

- [ ] **6a. Compositor keybinding dictates**

Command: `parlactl setup`, paste the snippet into your compositor config,
reload (`swaymsg reload` / `hyprctl reload` / re-run `~/.config/river/init`).
Hold Right Ctrl, speak, release, then `wl-paste`.

Expect: the words on the clipboard and a `Copied: …` notification.

Result:

Notes:

- [ ] **6b. Watchdog covers a dropped release (sway#6456)**

Command: hold Right Ctrl, press and release another key, then release Right
Ctrl. Wait up to `watchdog_secs` (default 30 s).

Expect: log line `parlad: watchdog fired, discarding recording` and the
notification `Recording timed out — discarded`. If the release was *not*
dropped on your compositor, record that instead.

Result:

Notes:

## 7. Microphone and device selection under PipeWire

`parlad: transcribing N.Ns of audio` in the log is the number to watch. It
should match how long you held the key.

- Much larger → the ring is not being marked.
- Never appears → the audio floor is rejecting your input as silence, and the
  input device is probably wrong.

Note: cpal's Linux `default_host()` ends in `AlsaHost::new().expect(...)`, so on
a box with no working audio backend `parlad` **panics** rather than reporting a
clean error. An abort at startup means the audio stack, not the app.

- [ ] **7. Captured length matches the hold**

Command: start `parlad` in a terminal, hold the hotkey about 5 s while
speaking, release. Read the `parlad: transcribing N.Ns of audio` line.

Expect: N close to the hold time — not much larger, and the line present.
If `parlad` aborts at startup, record the panic message and your audio stack.

Result:

Notes:

## 8. The model

Put one at `$XDG_DATA_HOME/parla/models/ggml-base.en.bin`, or set
`whisper_model` in `config.toml`. The daemon refuses to start without it, by
design, naming the path it looked in.

- [ ] **8a. Missing model refuses to start, naming the path**

Command (no file at the default path, no `whisper_model` set): `parlad`

Expect: `parlad` exits with an error naming the path it looked in.

Result:

Notes:

- [ ] **8b. Model at the default path loads**

Command: place the model at
`$XDG_DATA_HOME/parla/models/ggml-base.en.bin` (default
`~/.local/share/parla/models/`), then `parlad`.

Expect: `parlad: listening on …` and no model error. Record the model's sha256
in the run record.

Result:

Notes:

---

## Baseline observations (before lanes 09 and 11)

Observations only, no pass/fail threshold. Record the exact values asked for;
lanes 09 and 11 compare their "after" checks against them. `Result:` here means
`recorded` or `not run`.

- [ ] **B1. Device default configuration**

The daemon opens the device's default input configuration and does not log it.
Record the sample rate, channel count and sample format it opened from the
audio server instead, **while a recording is in progress**:

```sh
parlactl start         # leave it recording
pw-top                 # PipeWire: the parlad row's RATE / FORMAT
pactl list sources     # PulseAudio / pipewire-pulse: Sample Specification of the default source
cat /proc/asound/card*/pcm*c/sub0/hw_params   # plain ALSA: rate, channels, format
parlactl cancel
```

Record: sample rate (Hz), channel count, sample format, and which command the
values came from (paste its relevant output in Notes). Lane 11 adds a startup
log line for this.

Result:

Sample rate / channels / format:

Notes:

- [ ] **B2. Duration fidelity**

Dictate a timed 10.0 s clip, speaking continuously for the whole interval:

```sh
parlactl start; sleep 10; parlactl stop
```

Record: the daemon's `parlad: transcribing N.Ns of audio` value, and the
difference `10.0 − N`. (Callback-local resampling can shorten it; this is the
"before" number for lane 11.)

Result:

N / difference:

Notes:

- [ ] **B3. Two quick dictations**

Dictate A, and start B before A's notification appears. Say a different,
recognisable phrase in each (for example "alpha one" then "bravo two"):

```sh
parlactl start; sleep 2; parlactl stop; parlactl start; sleep 2; parlactl stop
sleep 15; wl-paste
```

Record: which text is on the clipboard at the end (A, B, or something else),
whether both notifications appeared and in which order, and the order of the
two `parlad: Parla — …` log lines. ("Before" for lane 09.)

Result:

Clipboard / notifications / log order:

Notes:

- [ ] **B4. Cancel after release**

Release the key, then immediately cancel:

```sh
parlactl start; sleep 2; parlactl stop; parlactl cancel
sleep 15; wl-paste
```

Record: the reply `parlactl cancel` printed, whether the dictated text still
reached the clipboard, and whether a `Copied: …` notification appeared.
("Before" for lane 09.)

Result:

Cancel reply / clipboard / notification:

Notes:

- [ ] **B5. Multilingual model**

With a multilingual ggml model configured (`whisper_model` pointing at a model
without the `.en` suffix, for example `ggml-base.bin`), restart `parlad` and
speak one non-English sentence.

Record: the model file and its sha256, the language and the sentence you said,
and the clipboard output verbatim (`wl-paste`). ("Before" for lane 09's
language setting.)

Result:

Model / language / sentence spoken / output:

Notes:

---

## After checks — added by lane 09

(Placeholder. Lane 09 appends its checks here.)

## After checks — added by lane 11

(Placeholder. Lane 11 appends its checks here.)

---

## Sign-off

| Field | Value |
|---|---|
| Run by | |
| Date | |
| Run record used (date + machine) | |
| Items failed (by number) | |
| Items not run (by number, with reason) | |
| Lanes 09 and 11 may proceed (yes / no, and why) | |

---

## Known and accepted

- **A silent hold in a quiet room puts `"."` on the clipboard.** The macOS app
  behaves identically. The real fix is raising the RMS floor — currently `1e-4`,
  essentially digital silence, against a measured quiet-room level of `0.009` —
  which needs eval data from a later milestone. Fixing the symptom now would
  make that measurement harder to read.
- **niri and river ≥ 0.4** cannot express a key-release binding and need the
  evdev backend, which is M4.
- **Five behaviours are review-backed rather than test-backed**, because they
  live inside functions that need a real audio device or a real compositor to
  construct: the watchdog holding the session guard across a notification,
  whisper running on a tokio worker instead of `spawn_blocking`, `finish`
  losing its notify call, and two clipboard failure modes (stall/panic, and
  hang against a wedged compositor). Each carries a comment at its site. If you
  refactor near them, the compiler will not stop you.
