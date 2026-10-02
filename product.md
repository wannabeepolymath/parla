# Parla — Product Spec

Voice-to-text app that turns natural, messy speech into polished text in any
app. Speak instead of type: ~45 wpm typing vs ~220 wpm speaking.

Not raw transcription. The differentiator is the **post-processing layer**:
filler removal, self-correction handling, formatting, personal vocabulary,
multilingual support, style adaptation — and unlike cloud-only competitors,
**transcription runs on-device**.

## Problem

Built-in dictation gives a messy, unpunctuated blob full of "um"s and false
starts. Parla does the cleanup automatically: you ramble, it hands back the
sentence you meant.

## Core UX flow

1. **Trigger** — hold a global hotkey. Background menu-bar app, system-wide.
2. **Speak naturally** — fillers, self-corrections, rambling all fine.
3. **AI auto-edit** — transcribe, then rewrite: punctuation, grammar,
   formatting, strip fillers. This edit step is the product.
4. **Insert** — finished text drops straight into the focused field.

## Feature surface

- **Universal dictation** — any text field: mail, Slack, Notion, Cursor,
  VS Code, WhatsApp, Google Docs, ChatGPT, Linear, Jira, GitHub, terminals.
- **AI cleanup / auto-edits** — rambling → clean writing with punctuation,
  formatting, corrections, filler removal.
- **Backtrack / self-correction** — "Let's meet at 5… actually 6" →
  "Let's meet at 6."
- **Personal dictionary** — learns names, jargon, uncommon spellings, dev terms.
- **Snippets** — voice shortcuts expanding into canned text (scheduling links,
  support replies, intros, FAQs).
- **Styles** — tone adapts to context: formal docs, casual messages.
- **Command mode** — transform highlighted text by voice: translate, rewrite,
  polish, inline questions.
- **Transforms** — rewrite selected text anywhere; built-in + custom.
- **Scratchpad** — plain-text notes window (⌃⌘S), saved locally;
  a safe place to dictate into when nothing else is focused.
- **Insights** — words dictated, WPM, cleaned-up words, app breakdown (later).
- **Team features** — shared dictionary/snippets, central billing/admin (later).
- **Enterprise** — SSO/SAML, SCIM, enforced privacy policies (much later).
- **Dev-specific** — file tagging, syntax awareness, camelCase/snake_case,
  CLI/dev jargon.

## Positioning

Built-in dictation, ChatGPT voice mode, and IDE voice inputs are app-specific
and return raw transcripts. Parla is one consistent, personalized voice layer
across every app — with a privacy story the cloud-only incumbents structurally
can't match: **audio never leaves the device**.

AI-prompting angle: people type short prompts but *speak* rich prompts —
voice gives AI tools more context.

North-star quality metric: **zero-edit rate** (dictations needing no manual
fix). Incumbent benchmark to beat: ~90%.

## Personas

Developers first (dogfooding), then leaders, writers/creators, customer
support, students, lawyers, sales, accessibility users, teams.

## Pricing (draft)

| Tier | Price | Notes |
|---|---|---|
| **Basic** | Free | Weekly word limit, dictionary/snippets, privacy-first by default |
| **Pro** | ~$12–15/user/mo | Unlimited words, command mode, custom transforms |
| **Teams/Enterprise** | Later | Shared vocab, admin, SSO/SCIM, enforced policies |

## Privacy model (our differentiator)

Incumbents transcribe **cloud-only** — audio always leaves the device, and on
default settings is retained for model training, passing through multiple
third-party AI subprocessors (hosted ASR, external LLMs, cloud storage).
Their "zero data retention" is an opt-in combination of settings.

Parla inverts this:

- **ASR always on-device** — audio never leaves the machine. Not a mode; the
  architecture.
- **Cleanup LLM**: a cloud call by default (transcript, selection, dictionary,
  snippets and the frontmost app's name — never audio), or point it at a local
  OpenAI-compatible server (Ollama) for true zero-network mode.
- **No text leaves the machine but that one call** — no sync, no server, no
  account. The only other network traffic is a once-a-day GitHub release check
  and the one-click whisper model download; neither carries your text. The
  local history log (last 50 dictations) is on by default and can be turned
  off; secure-field and cancelled dictations are never recorded either way.
- TLS for any network call; local state stays local.

## System-wide text insertion (desktop mechanics)

Three standard OS mechanisms exist:

1. **Simulated keystrokes** (retained for streaming helpers) — macOS
   `CGEventCreateKeyboardEvent`/`CGEventKeyboardSetUnicodeString`; Windows
   `SendInput`. Works everywhere; char-by-char, layout-sensitive. Every
   transcript now lands through paste instead.
2. **Paste injection** (final delivery) — save all clipboard representations →
   set temporary text → synthetic Cmd+V → conditionally restore. Cleanup finishes
   before delivery, so opaque editors such as ChatGPT need no text readback or
   replacement. A clipboard change made by the user takes precedence over restoration.
3. **Accessibility APIs** (macOS AX API — the Privacy & Security →
   Accessibility grant; Windows UI Automation) — Parla reads focus, the
   focused field's text and cursor, and the current selection through AX, and
   verifies destination identity across cleanup. The older streaming helpers retain
   an atomic AX value write for tail replacement.
   Nothing is erased unless AX first proves the text at the cursor is Parla's
   own. Cleanest; not all apps expose fields.

The macOS Accessibility permission enables both observing global focus and
injecting into other apps. Global hotkey rides the same event-tap capability.

## Summary

Deceptively simple product with a brutal engineering core. Visible product:
"press key, talk, text appears." Real system: native OS integration +
on-device speech + LLM cleanup + personalization. The moat is universal
insertion reliability, latency, self-correction handling, personalization,
and the on-device privacy story — not the ASR itself.

See `architecture.md` for the implementation architecture and build plan.
