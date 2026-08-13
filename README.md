# Parla

Parla is a macOS menu-bar dictation app: hold a hotkey, speak, release — your
speech is transcribed on-device with whisper.cpp, cleaned up by a Claude
model, and typed into whatever app you're using. Hold **⇧+fn** instead with
text selected to speak an edit instruction and transform the selection in
place (see Command mode below).

## Running it

Prerequisites: macOS 13.3+ and Xcode (or the Command Line Tools) with Swift
5.9+. There's no Homebrew formula/cask or prebuilt binary — clone and build
from source:

```sh
git clone https://github.com/wannabeepolymath/parla.git && cd parla
scripts/download-model.sh          # fetch a whisper model (default: base.en; also takes tiny.en / large-v3-turbo)
export ANTHROPIC_API_KEY=sk-ant-…  # optional; used for transcript cleanup (Groq/OpenAI/Ollama: see Cleanup providers)
scripts/make-app.sh                # swift build -c release + bundle Parla.app
open Parla.app
```

**Prefer Groq (or any OpenAI-compatible provider)?** Skip the Anthropic key,
add a `cleanup` block to `settings.json` (see [Cleanup providers](#cleanup-providers)),
and export that provider's key instead:

```sh
export GROQ_API_KEY=gsk_…            # instead of ANTHROPIC_API_KEY
```

```json
// ~/Library/Application Support/Parla/settings.json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "https://api.groq.com/openai/v1",
  "model": "openai/gpt-oss-120b",
  "apiKeyEnvVar": "GROQ_API_KEY"
}
```

Skipping the first step is fine — the menu bar offers a one-click
**Download model (base.en, ~148 MB)** on launch. After code changes, quit Parla (menu >
Quit), re-run `scripts/make-app.sh`, and `open Parla.app` again; permission
grants survive rebuilds (the bundle is signed with a stable identifier).

Transcription runs on a vendored whisper.cpp v1.9.1 xcframework with Metal GPU
active by default; `make-app.sh` bundles `whisper.framework` into
`Parla.app/Contents/Frameworks` (macOS 13.3+ required to match it).

On first launch Parla lives in the menu bar (no dock icon) and shows ⚠️ until
the model and both permissions are in place. macOS
will prompt for **Microphone** and **Accessibility** permission — grant both in
System Settings > Privacy & Security. Then hold **fn 🌐 (Globe)** and speak;
release to transcribe and type the text into the frontmost app instantly, with
a cleaned-up version swapped in moments later. For anything longer, press
**Space** while still holding fn to latch hands-free: recording continues
after you let go, until you press fn, Space or Return. Taps shorter than
200ms are treated as an accidental Globe press and discarded; pressing any
other key while fn is held cancels the dictation and undoes anything already
typed. Start/finish/cancel each play a soft system sound.

The menu-bar icon is the Parla logo glyph both when idle and while recording —
the pill is what shows the live recording state. It switches to text for the
rest: … processing · ⬇️ N% downloading the model · ⚠️ problem (no model,
mic/Accessibility permission missing, or a broken `settings.json`). Run
unbundled via `swift run` and there's no logo resource, so those two states
show 🎤 and 🔴 instead.

By default the dictation pill stays visible as a small idle capsule floating on
screen, morphing into the full pill while you dictate. Turn off **Show pill at
all times** in the Hub (or set `showHudAlways` to `false` in `settings.json`)
to make it appear only during dictation. The pill is draggable — drag it
anywhere and it snaps to the nearest screen edge (a vertical bar on the left
and right sides), remembering its spot across sessions.

**Open Parla…** (first menu item) opens the Hub — a settings window with
General (permissions, whisper model, launch at login, shortcuts), AI Cleanup
(provider/model/API key), Dictionary, Snippets, History (searchable, with
copy/clear), and Data & Privacy pages. Everything it edits lives in the same
`settings.json` described below; if that file is invalid the Hub shows the
error and disables editing rather than overwriting it.

The menu also shows live Microphone/Accessibility permission status
(click an unfulfilled one to jump to System Settings), a one-click
**Download model (base.en, ~148 MB)** item when no model is loaded, a
**⚠️ settings.json invalid** item when the config fails to parse, a
**Launch at Login** toggle, a **Microphone** picker, and **Paste Last
Dictation** / a **Recent**
submenu (last 8 dictations, backed by a local 50-entry history) with
**Clear History** — see `historyEnabled` below.

**Open Scratchpad** (second menu item, or **⌃⌘S**) opens the Scratchpad — one
persistent plain-text window that gives a dictation somewhere to go when no
other app is focused: focus it, hold fn, and the transcript types in like any
other field. It saves to
`~/Library/Application Support/Parla/scratchpad.txt` (debounced while you
type, flushed when the window closes and on quit). Closing the window hides
it; Parla stays menu-bar-only.

## Shortcuts

All of these are global and fixed in this version (the Hub lists them
read-only):

- **fn 🌐 (Globe), held** — dictate; release to transcribe and type.
- **⇧+fn, held** — command mode: transform the selected text (see below). The mode is latched at fn-down, so shift can be released while you speak.
- **fn+Space** — latch hands-free: recording survives releasing fn. The Space is swallowed, so nothing lands in the field.
- **Space, Return, or fn again (while hands-free)** — stop recording and transcribe. Also swallowed, so no space or newline precedes the transcript.
- **Esc (while dictating)** — cancel; anything already typed is undone. Swallowed, so the Esc never reaches the app.
- **any other key (while fn is held)** — also cancels, but the key still reaches the app.
- **Esc (while idle)** — dismiss a visible HUD toast, then pass through to the app. In-progress states ("Transcribing…", "✓ · polishing…") are not dismissible.
- **⌃⌘V** — type the last transcript into the focused field. Waits for you to release the physical modifiers first (up to ~1s, then "⚠️ Release keys, then retry").
- **⌃⌘S** — open the Scratchpad.

⌃⌘V and ⌃⌘S match exactly those modifiers, so ⌃⌥⌘V and ⌃⇧⌘V are left alone.

## Shadow streaming

Transcription runs *while* you speak, but the field is never touched until you
release the hotkey: keystrokes posted while fn is physically held merge with
the modifier (fn+A opens the Dock), so mid-speech typing is disabled. Instead, Parla
transcribes in the background as you talk — dictations longer than ~15s freeze
a confirmed prefix at the nearest quiet moment so each pass only
re-transcribes the recent tail — and on release only the last few seconds of
unheard audio need a whisper pass. Past that threshold release latency is
therefore constant: it's set by the length of the live tail, not by how long
you dictated. Below it nothing has been frozen yet, so the pass on release
transcribes the whole recording and latency still grows with the length of the
dictation — up to ~15s of audio, which is a few hundred ms of whisper. An
in-flight pass is aborted the moment you let go.

On release, the whole raw transcript is typed into the focused field as
synthetic keystrokes (HUD: "Transcribing…", then "✓ · polishing…"); with no
focused field nothing is typed — the transcript is only saved to history.
The clipboard is never touched: text lives in the field and in local history,
and reaches the clipboard only via the Hub's explicit Copy button. The
LLM-cleaned version swaps in behind the raw text moments later — one atomic
Accessibility write over the text Parla typed, falling back to backspaces and
retyping when the app won't accept the write — landing on one of:
"✓ Pasted", "✓ Saved to history", "✓ cleaned in history" (swap couldn't be
verified — the cleaned text is in history instead), or "✓ raw (cleanup
failed)". Cancelling — Esc, or any other keypress while fn is held — shows
"✕ Cancelled". If the mic goes away mid-dictation (AirPods disconnecting, a
hub unplugged) the pill says "⚠️ Mic disconnected"; audio captured before the
break still finalizes normally on release.

## Command mode

Select some text, hold **⇧+fn**, speak an instruction (e.g. "make this more
formal"), and release: the selection is transformed by the cleanup model and
typed over it. The selection is captured at fn-down and re-verified at
fn-up — if it's no longer intact (you clicked away or edited it), the result
is saved to history instead of overwriting new content. A failed transform
never types the spoken instruction itself; nothing is inserted. Password
fields and empty selections refuse before recording even starts.

## Permissions

Parla needs:

- **Microphone** — Parla holds it open between dictations so one starts instantly; only what you dictate is transcribed. The exceptions, and what reaches disk, are below.
- **Accessibility** — to listen for the global hotkey and type text into the frontmost app (System Settings > Privacy & Security > Accessibility).

Because Parla holds the mic open between dictations — that is what removes
240–700 ms of audio-engine start from every press — macOS's orange mic
indicator is lit while Parla sits idle, not only while you dictate. Bluetooth
mics are the exception: holding one open drags the headset down to 16 kHz call
quality and roughly halves its battery, so Parla opens and closes those per
dictation instead (no idle indicator, and the engine start is back on the
press). Idle audio goes into a 1-second in-memory ring that is continuously
overwritten; at each press the newest 0.45 s of it is prepended to the
dictation so your first word isn't clipped.

That dictation's audio — the prepended 0.45 s included — is written to
`~/Library/Application Support/Parla/recordings` before whisper runs, so a
crash mid-transcription can't take what you just said with it, and is deleted
the moment a transcript comes back. Only dictations that failed are left
behind, and those go at the first dictation after they turn 7 days old, or
whenever you open the Hub's **Data & Privacy** page — which also shows the
folder, its size, and a button to empty it now. (Setting
`PARLA_KEEP_RECORDINGS=1` keeps successful dictations too, to build an eval
corpus; the Hub shows a banner for as long as it is on.) Transcription itself
runs on this Mac, and the cleanup model is sent text, never audio.

Password fields (`AXSecureTextField`) are detected via Accessibility and
refused outright: dictation into one shows "⚠️ Not supported in password
fields" — nothing is typed, stored in history, or sent to the cleanup model.

## Configuration

Settings live at `~/Library/Application Support/Parla/settings.json` — use the
Hub's **General → Settings file → Open File** button to create and edit it. A file that fails
to parse is never silently overwritten; the menu shows the decode error until
you fix it. Fields:

- `dictionary` — array of exact spellings (names, jargon) to bias transcription and cleanup, e.g. `["Parla", "whisper.cpp"]`.
- `snippets` — object mapping a spoken trigger phrase to its expansion, e.g. `{"my address": "123 Main St"}`.
- `cleanupModel` — Anthropic model id for cleanup (default `claude-sonnet-5`).
- `anthropicApiKey` — API key for cleanup; the Hub's **AI Cleanup** page writes this field for you. The `ANTHROPIC_API_KEY` environment variable takes precedence; if neither is set, Parla inserts the raw transcript.
- `whisperModelPath` — absolute path to a ggml whisper model. Defaults to the model downloaded by `scripts/download-model.sh`.
- `showHudAlways` — keep the dictation pill floating on screen as a small idle capsule at all times, expanding into the full pill during dictation. Default `true`; set `false` for a transient pill shown only while dictating.
- `hudIdleSize` — size of that idle capsule: `"small"` (default), `"medium"`, or `"large"`. Unknown values fall back to small.
- `inputDeviceUID` — Core Audio UID of the input device to record from, as picked in the menu's **Microphone** submenu. Default `null` (system default); a UID that no longer resolves — device unplugged — also falls back to the system default.
- `historyEnabled` — keep a local log of the last 50 dictations (raw + cleaned + app name) at `~/Library/Application Support/Parla/history.json`, for the menu's Paste Last Dictation / Recent. Default `true`. Secure-field and cancelled dictations are never recorded regardless of this setting.
- `liveStreamingEnabled` — dead field: it is still parsed and written back, but nothing reads it, so setting it either way changes nothing. Default `true`. Mid-speech typing is hard-disabled in code (held-fn keystrokes merge with the modifier); transcription still runs while you speak, and the text lands as one insert on release.

## Cleanup providers

Cleanup defaults to **Anthropic** (the `cleanupModel` + `anthropicApiKey`/`ANTHROPIC_API_KEY` fields above); leave `cleanup` unset to keep that behavior. To use any OpenAI-compatible endpoint (Groq, Gemini, OpenAI, local Ollama/LM Studio), add a `cleanup` block:

- `cleanup.provider` — `"anthropic"` (default) or `"openai-compatible"`.
- `cleanup.baseURL` — required for `openai-compatible`; the API root (Parla POSTs to `{baseURL}/chat/completions`).
- `cleanup.model` — model id; empty uses the server's first model. The Hub suggests `openai/gpt-oss-120b`.
- `cleanup.apiKeyEnvVar` — name of the env var holding the key (takes precedence over `cleanup.apiKey`).
- `cleanup.apiKey` — inline key fallback. Omit both for keyless local servers (Ollama).

The `cleanup.model`/`cleanup.apiKeyEnvVar`/`cleanup.apiKey` fields apply to `openai-compatible` only; Anthropic always uses `cleanupModel` and `ANTHROPIC_API_KEY` → `anthropicApiKey`. The two providers' settings coexist, so switching back and forth loses nothing. Any misconfiguration falls back to inserting the raw transcript.

**Groq** (set `GROQ_API_KEY`):

```json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "https://api.groq.com/openai/v1",
  "model": "openai/gpt-oss-120b",
  "apiKeyEnvVar": "GROQ_API_KEY"
}
```

**Gemini** (set `GEMINI_API_KEY`):

```json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "https://generativelanguage.googleapis.com/v1beta/openai",
  "model": "gemini-2.5-flash",
  "apiKeyEnvVar": "GEMINI_API_KEY"
}
```

**Ollama** (local, no key):

```json
"cleanup": {
  "provider": "openai-compatible",
  "baseURL": "http://localhost:11434/v1",
  "model": "llama3.1"
}
```

## Build & test

```sh
swift build
swift test
```

## Developer tooling

### `swift run parla-eval` — regression harness

Scores the corpus in `eval/cases` on two legs: ASR (whisper against the
verbatim `NAME.raw.txt`) and cleanup (model output against `NAME.golden.txt`).

| Mode | What it does |
|---|---|
| `parla-eval [dir]` | full pipeline: wav → whisper → cleanup; writes `eval/results.json` |
| `--asr-only` | whisper leg only — no API key needed |
| `--cleanup-only` | cleanup leg only — no whisper model needed |
| `--model <id>` | cleanup model for THIS run; `settings.json` is never written |
| `--out <path>` | read/write fixtures elsewhere, so two runs can sit side by side |
| `--cleanup-cmd <exe>` | run the cleanup leg through an external command instead of an HTTP provider (see below) |
| `compare a b` | diff two results files: aggregates per leg and category, then the cases they disagree on most |
| `verify [dir]` | re-score the committed `eval/results.json` offline — no model, no key, no network |
| `--self-check` | assert the `compare` arithmetic offline, without a corpus |

Exit codes: **0** clean · **1** quality regression (a case scored WER > 20 %) ·
**2** misconfiguration (model or key missing, unusable `compare` arguments) ·
**3** infrastructure error — a network flake must never read as a quality
regression, which is why 3 exists. `compare` always exits 0: one model scoring
worse than another is the answer that mode produces, not a failure of it.

`verify` is the CI gate (`.github/workflows/ci.yml`), and it gates on **scorer
drift**, not on the 20 % threshold: it re-derives each committed hypothesis's
score and fails only when the same bytes produce a different number than the one
recorded in the fixture. The committed baseline legitimately contains failing
cases (base.en mangles "Kubernetes"), and re-judging those on every run would
peg CI red forever and teach everyone to ignore it.

#### `--cleanup-cmd` — A/B a model you have a CLI for but no API key

Routes the cleanup leg through an external command: **system prompt as `argv[1]`,
`--model`'s value as `argv[2]`, user message on stdin, cleaned text on stdout**,
non-zero exit treated as a cleanup failure carrying stderr. Both prompts still
come from Parla's own `PromptBuilder`, so what is measured stays Parla's prompt —
only the transport moves. Pass `--model` even though the command picks its own:
it is what lands in each fixture's `engine` field, and a run nobody can attribute
to a model is not much of an A/B.

`scripts/cleanup-via-claude.sh` is such a wrapper:

```
swift run parla-eval --cleanup-only --model claude-haiku-4-5 \
  --cleanup-cmd scripts/cleanup-via-claude.sh --out /tmp/haiku.json
```

Two caveats, both load-bearing:

- **Compare two `--cleanup-cmd` runs with each other, never with a
  real-provider baseline.** A CLI wraps its own harness around the model, so the
  absolute score is not comparable to `eval/results.json`; the relative A/B is.
- **Disable the tools.** The corpus has an `injection` category — instruction-
  shaped speech that must be transcribed and never obeyed. Feeding that to an
  agent that can run `Bash` in your repo is both a wrong measurement and a bad
  idea; run it tool-less in an empty directory.

### `scripts/make-asr-corpus.sh`

Regenerates the seven synthetic ASR cases (`eval/cases/syn-*`) with `say(1)`,
16 kHz mono — the same format `AudioRecorder` produces, so each case's reference
is the input text rather than a guess about what was said. The WAVs are
committed, so CI never needs `say`. Synthetic audio is for **regression
detection only**: TTS has no disfluency, room tone, accent or clipping, so its
absolute WER is far better than reality and must never be quoted as Parla's
accuracy. The human corpus `eval/README.md` asks for is still wanted.

### `swift run parla-insert-check [bundleID]`

Types five known strings into a live app (default `com.apple.TextEdit`) and
reads them back over Accessibility — the automated half of the insertion smoke
test. The cases are the real hazards: a 600-char single line, embedded newlines,
an emoji astride the 200-unit chunk boundary, combining marks + RTL, and 201
units.

`swift run` builds an unsigned binary under `.build`, and macOS grants
Accessibility per binary, so that path has to be added under System Settings >
Privacy & Security > Accessibility (a rebuild can require re-granting). A field
it can type into but not read back is **SKIP, never PASS**, and skips are never
folded into success: every case skipping exits 3, and so does a *partial* skip,
because a green line that stands for work nobody did is the failure mode this
tool exists to prevent. A 90s watchdog exits 4 rather than hanging. Otherwise:
0 all cases verified, 1 a case failed, 2 permission or target problem.

Three flags, each of which exists because some real app could not be checked
without it:

| Flag | Why |
|---|---|
| `--echo-file <path>` | Read the text back from a file the target echoes into instead of over AX. Required for **terminals**: their AX value is the visible screen (Ghostty: a fixed 52-line, 183-column buffer), so a 630-character payload scrolls the "before" off the top and the before/after diff is undefined rather than merely noisy. Also the only way to read an **editor** that publishes no AX value — see below. |
| `--field-role <AXRole>` | Aim the walk at one role. The first text input an app exposes is not always safe to type into: Slack's preferred `AXTextArea` is the message composer, where a newline **posts to a real channel**. `--field-role AXTextField` picks its conversation search box — same Chromium input path, reaching nobody. |
| `--field-index <N>` | Pick the Nth match (1-based). Cursor and VS Code expose their **AI chat box** as an `AXTextArea` *before* the editor, and a newline there sends a prompt. |

**Terminals** (byte-exact, no AX readback involved) — in a window you don't mind
losing, and note `stty -icanon`, or canonical mode holds the 630-character line
until Return and it reads back empty:

```
stty -icanon min 1 time 0; exec cat > /tmp/parla-echo.txt
swift run parla-insert-check com.mitchellh.ghostty --echo-file /tmp/parla-echo.txt
```

**VS Code / Cursor.** The editor reports an empty `AXValue` and says why in its
`AXDescription` ("The editor is not accessible at this time…"), so AX cannot
verify it at all. Give it a scratch workspace with autosave and read the file:

```
mkdir -p /tmp/parla-check/.vscode && : > /tmp/parla-check/scratch.txt
echo '{ "files.autoSave": "afterDelay", "files.autoSaveDelay": 200 }' > /tmp/parla-check/.vscode/settings.json
open -a Cursor /tmp/parla-check && open -a Cursor /tmp/parla-check/scratch.txt
swift run parla-insert-check <bundleID> --echo-file /tmp/parla-check/scratch.txt
```

A difference that is the host app's own text policy — TextEdit capitalizing the
first word of a sentence, a single-line field storing a space where it cannot
store a newline — is reported as a **PASS with the reason named**, because both
substitute a character in place: same UTF-16 count, same positions, nothing
dropped or split at a chunk seam. Calling those FAIL would send the next reader
to revert `max: 200` over a setting in the Edit menu.

### Environment switches

- `PARLA_TRACE=1` — one greppable `parla-trace …` line per dictation on stderr:
  the input device's transport (`builtin`/`usb`/`bluetooth`/…) and each stamp as
  a delta from the previous one — `fn_down`, `recorder_start_returned`,
  `first_pcm_callback`, `fn_up`, `final_pass_done`, `landed`,
  `cleaned_swapped`, then `total`. Off by default and cheap when off (one cached
  bool test), because one stamp is taken on the realtime audio thread.
- `PARLA_KEEP_RECORDINGS=1` — keeps successful dictations' audio for building an
  eval corpus; see [Permissions](#permissions).

## License

The app — everything outside `Sources/ParlaCore/` — is **AGPL-3.0-or-later**
(`LICENSE`). **`Sources/ParlaCore/` is MIT** (`Sources/ParlaCore/LICENSE`).

The split is deliberate: copyleft on the app is what stops it being
repackaged as a closed product, but ParlaCore is the reusable half — stream
windowing, the grapheme-diff typer, the text rules, the AX-verified inserter —
with no AppKit dependency and nothing product-specific in it, so it carries no
obligation for anyone who wants those primitives. The vendored whisper.cpp
xcframework is MIT and imposes nothing upward.

`LICENSE-COMMERCIAL.md` reserves the option of a separate commercial license.
It is a stub, not an offer — there is no paid build, and the AGPL grant above
is unconditional. It exists now because dual-licensing needs sole copyright,
so the option has to be reserved before the first external contribution, not
after.
