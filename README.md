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
a cleaned-up version swapped in moments later. Taps shorter than 200ms are
treated as an accidental Globe press and discarded; pressing any other key
while fn is held cancels the dictation and undoes anything already typed.
Start/finish/cancel each play a soft system sound.

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
unheard audio need a whisper pass. Release latency is therefore independent of
how long you dictated; an in-flight pass is aborted the moment you let go.

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

- **Microphone** — to record while you hold the hotkey.
- **Accessibility** — to listen for the global hotkey and type text into the frontmost app (System Settings > Privacy & Security > Accessibility).

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
