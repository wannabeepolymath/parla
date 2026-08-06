# Parla for Linux (wlroots)

Push-to-talk dictation for sway, Hyprland and river. Hold a key, speak, release —
your speech is transcribed on-device with whisper.cpp, cleaned up by an LLM, and
placed on your clipboard.

**Milestone 1**: the result lands on the clipboard, and you paste it. Typing
straight into the focused window arrives in M2.

## Build

whisper.cpp is compiled from source and its bindings are generated at build
time, so this needs cmake, a C/C++ toolchain, libclang, and the development
headers for your audio stack — ALSA, plus PipeWire and PulseAudio. That is what
the build links against, derived from the crates rather than from an install
anyone has run here, so expect to translate it into your distro's package names.

    cd linux && cargo build --release

Binaries land in `linux/target/release/{parlad,parlactl}`. Put both somewhere on
your PATH — your compositor spawns `parlactl` by name, and it inherits the PATH
the compositor itself was started with (a display manager's PATH is often
minimal, so `~/.local/bin` may not be on it):

    install -Dm755 target/release/parlad target/release/parlactl -t ~/.local/bin/

## Model

    mkdir -p ~/.local/share/parla/models
    curl -L -o ~/.local/share/parla/models/ggml-base.en.bin \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

That path is the default. Point `whisper_model` at another file to use a
different one.

## Configure

`~/.config/parla/config.toml` — every key is optional and falls back to a
default, and a malformed file degrades to stock behaviour with a complaint on
stderr rather than refusing to start.

    dictionary = ["Kubernetes", "wlroots"]   # names whisper keeps mangling
    watchdog_secs = 30                       # see "If a recording never stops"
    # whisper_model = "/path/to/ggml-medium.en.bin"

    [cleanup]
    provider = "anthropic"          # or "openai-compatible", or "none"
    model = "claude-sonnet-5"
    api_key_env = "ANTHROPIC_API_KEY"

For Groq or any OpenAI-compatible endpoint:

    [cleanup]
    provider = "openai-compatible"
    base_url = "https://api.groq.com/openai/v1"
    model = "openai/gpt-oss-120b"
    api_key_env = "GROQ_API_KEY"

Spoken shorthand is expanded by the same cleanup pass, so it needs a provider:

    [snippets]
    "my work email" = "daksh@example.com"

Set `provider = "none"` to skip cleanup entirely and get the raw transcript.
Cleanup failing is never fatal: if the LLM errors out or the key is missing, the
raw transcript goes to the clipboard and the notification says so.

`api_key_env` names an environment variable — the key is read from `parlad`'s
own environment, so it has to be exported in the session that starts the daemon.
An inline `api_key` works too, at the cost of putting the key in a file.

## Hotkey

    parlactl setup

This prints a config snippet. **Paste it into your own compositor config**
(`~/.config/sway/config`, `~/.config/hypr/hyprland.conf`,
`~/.config/river/init`) and reload the compositor — `swaymsg reload`,
`hyprctl reload`, or re-running `~/.config/river/init`. `parlactl setup` does
not edit anything for you, and it works whether or not `parlad` is running.

The default hotkey is **Right Ctrl, held down**. Hold it for as long as you are
speaking and release when you are done — a tap does nothing useful, because it
records for the few milliseconds the key was down.

Right Ctrl rather than Right Alt on purpose: on AltGr layouts Right Alt *is*
AltGr, and binding it away breaks typing `@ € { } \` and every accented
character.

This uses your compositor's own keybinding system, so Parla needs **no special
permissions** — no `input` group, no udev rule, no root.

niri and river ≥0.4 cannot express a key-release binding at all and need the
evdev backend, which is not in this milestone. `parlactl setup` says so instead
of printing a snippet that would silently do nothing.

## Run

    parlad

It logs to stderr and must run inside your Wayland session — it needs
`WAYLAND_DISPLAY` to reach the clipboard. A notification daemon (mako, dunst, …)
is optional: without one you lose the "copied" and "nothing heard" toasts, but
dictation still works and the failure is logged rather than fatal. Then hold
your hotkey, speak, release, and paste.

`parlactl status` reports what the daemon is doing; `parlactl start` and
`parlactl stop` are the same commands the keybinding runs, useful for testing
without a hotkey.

## If a recording never stops

sway [#6456](https://github.com/swaywm/sway/issues/6456): pressing another key
while the hotkey is held can make sway drop the release edge, so the `stop`
never arrives. `watchdog_secs` bounds that — the recording self-cancels and
notifies rather than capturing until the disk fills. Raise it if you dictate in
long stretches — up to 300 seconds, the length of the capture buffer. Anything
higher is clamped to that (and says so on stderr), because a recording that
outlives the buffer loses its opening words.

## Known limitations in M1

- Output goes to the clipboard, not the focused window. You paste it yourself,
  and it overwrites whatever was on the clipboard before.
- No password-field protection. Parla cannot tell what is focused, so nothing
  stops you dictating into a password prompt — don't dictate secrets.
- No pill overlay and no live partial transcript; notifications are the only
  feedback while it works.
- Unless `provider = "none"`, the transcript is sent to whichever LLM endpoint
  you configured. Transcription itself is always on-device.
