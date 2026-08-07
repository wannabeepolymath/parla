# Parla Hub — Management UI Design

> **EXECUTED — kept as a record.** The Hub shipped as specified below, with
> three details superseded. The menu's `Set API Key…` item referenced under
> Architecture is gone — the key is edited on the Hub's AI Cleanup page
> (`Sources/Parla/Hub/HubPages.swift:190-194`). The General page's shortcut
> pills list six chords, not two: fn 🌐, fn 🌐 + Space, ⇧ fn, ⌃ ⌘ V, ⌃ ⌘ S,
> esc (`HubPages.swift:83-105`). And two things listed here as out of scope /
> dropped shipped anyway in the same 2026-07-10 batch: the Scratchpad
> (`Sources/Parla/Scratchpad.swift`) and the mic device picker, which lives on
> this window's General page (`HubPages.swift:68-73`). Current behavior is
> documented in README.md.

Scope: a SwiftUI dashboard window ("Hub") for Parla plus a restyle of the
existing HUD pill, both following the visual identity in `docs/plan.md`
(Parla Flow clone spec). Frontend only — no changes to ParlaCore behavior,
no new persistence, no accounts/teams/meetings/scratchpad/connectors (Parla
has no backing for those; they are explicitly out of scope).

## What ships

- **Hub window** — opened from a new **Open Parla…** tray-menu item (first
  item). ~900×620, custom sidebar + content pane, styled with the plan.md
  sand/lavender tokens, light + dark mode. Closing hides the window; the app
  stays menu-bar-only (no dock icon).
- **HUD restyle** — same states/API, redressed as the Flow-bar look: near-black
  capsule, soft purple glow, coral recording dot, white waveform bars.

## Architecture

- New files in `Sources/Parla/Hub/`; `ParlaCore` untouched.
  - `Theme.swift` — color/typography tokens from plan.md (§Visual Identity),
    light/dark via dynamic NSColor providers. System font (SF Pro); no bundled
    third-party fonts.
  - `HubModel.swift` — `@MainActor ObservableObject` bridging existing code:
    loads/saves `settings.json` via `SettingsStore` (debounced whole-file save,
    same as `Set API Key…` today), reads `HistoryStore`, checks the same
    mic/AX/permission and launch-at-login APIs the menu uses. Model download
    state (`modelLoaded`, `downloadProgress`) is pushed in by AppDelegate's
    existing download path.
  - `HubWindow.swift` — window controller (`NSWindow` + `NSHostingView`,
    `isReleasedWhenClosed = false`), sidebar, page routing.
  - `HubPages.swift` — shared row components (section, toggle row, text-field
    row, button row, danger row) and the six pages.
- `main.swift` — adds the menu item and the ~10 lines wiring HubModel to the
  existing download/model-load callbacks.
- Invalid `settings.json`: the hub shows the decode-error banner with an
  "Open file" button and disables all editing — same never-overwrite rule as
  the menu. Settings are re-read every time the window becomes key.

## Pages

1. **General** — permissions card (Microphone / Accessibility status, click
   to open System Settings); whisper model card (loaded state + path, or
   Download button with live progress); Launch at Login toggle; read-only
   shortcut pills (fn = dictate, ⇧+fn = command mode); Open settings file.
2. **AI Cleanup** — provider picker (Anthropic / OpenAI-compatible); model
   field; base URL field (OpenAI-compatible only); API key (secure field,
   placeholder dots when set); short key-resolution note. The key env-var field
   was dropped: `cleanup.apiKeyEnvVar` still works via settings.json but is
   deliberately not surfaced in the Hub.
3. **Dictionary** — add/remove/edit the `dictionary` spellings list.
4. **Snippets** — add/remove trigger → expansion pairs (`snippets`).
5. **History** — the local 50-entry log: search filter (frontend-only),
   rows with raw/cleaned text, app name, timestamp, per-row Copy,
   Clear History (danger). No per-row delete (HistoryStore has none; adding
   one is a backend change — out of scope).
6. **Data & Privacy** — `historyEnabled` toggle, Clear History, static privacy
   notes (on-device transcription, secure fields never sent to the cleanup LLM,
   history is local-only). No `restoreClipboard` toggle: the setting does not
   exist and there is nothing to restore — Parla types the transcript as
   keystrokes and never writes the clipboard.

## Dropped from plan.md

Account, Teams, Plans/Billing, Connectors, MCP, Notetaker/meetings,
Scratchpad, calendar reminders, context-menu palette, notification center,
onboarding tour, mic device picker, shortcut remapping, language pickers,
feature flags — no backing functionality in Parla.

## Testing

UI is presentational over existing tested stores; `swift build` +
existing `swift test` suite must stay green. No new core logic to test.
