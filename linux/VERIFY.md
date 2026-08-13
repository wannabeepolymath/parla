# Linux verification checklist — M1

Everything in this milestone was written and tested on macOS. The Wayland
clipboard, D-Bus notifications, compositor keybindings, and cpal's
PipeWire/PulseAudio backends have **never run**. That is why M1 is not "done"
until this list passes on a real wlroots box.

Ordered by how likely each is to be wrong.

## 1. The clipboard actually receives the dictation

`wl-paste` returns your words, still returns them 30 seconds later, and still
returns them on a second and third paste. Nothing on macOS could tell us
anything about this path.

The selection is served by a background thread inside `parlad` with
`ServeRequests::Unlimited`, so repeated pastes over time are the thing to try.

## 2. The clipboard does NOT survive the daemon — and that is correct

`pkill parlad`, then `wl-paste`, comes back empty. The serving thread lives in
the `parlad` process, so the selection dies with it. This is expected
behaviour, not a bug.

Only worry if pastes fail *while the daemon is running*.

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

## 4. Cleanup failure still delivers

Unset the cleanup API key and dictate. Expect `Copied (raw — no API key): …`
and the raw transcript on the clipboard. Cleanup failing must never cost you
your words.

## 5. The build itself

cpal's `pipewire` and `pulseaudio` backends have never been compiled. Expect a
first Linux build to break here rather than in the pipeline. You need cmake, a
C/C++ toolchain, libclang, and your audio stack's development headers.

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

## 7. Microphone and device selection under PipeWire

`parlad: transcribing N.Ns of audio` in the log is the number to watch. It
should match how long you held the key.

- Much larger → the ring is not being marked.
- Never appears → the audio floor is rejecting your input as silence, and the
  input device is probably wrong.

Note: cpal's Linux `default_host()` ends in `AlsaHost::new().expect(...)`, so on
a box with no working audio backend `parlad` **panics** rather than reporting a
clean error. An abort at startup means the audio stack, not the app.

## 8. The model

Put one at `$XDG_DATA_HOME/parla/models/ggml-base.en.bin`, or set
`whisper_model` in `config.toml`. The daemon refuses to start without it, by
design, naming the path it looked in.

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
