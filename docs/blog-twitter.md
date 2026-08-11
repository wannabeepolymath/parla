# I built a dictation app. Recording audio was the easy 5%.

Parla is a macOS menu-bar app: hold the Globe key, ramble, release — clean text appears in whatever app you're in. Whisper runs on-device, an LLM polishes the transcript, and the result is typed into the focused field. ~3,000 lines of Swift, no Electron, no clipboard, audio never leaves the machine.

Here's what actually turned out to be hard.

## The architecture in one paragraph

Two-stage pipeline. Stage 1: whisper.cpp (vendored v1.9.1 xcframework, Metal + flash attention) transcribes on-device — a full 30s encode is ~130–200ms warm on Apple Silicon. Stage 2: an LLM (Anthropic by default, or any OpenAI-compatible endpoint — Groq, Gemini, local Ollama) fixes punctuation, strips fillers, applies self-corrections ("at 5… actually 6" → "at 6"). The raw transcript is typed *instantly* on release; the cleaned version swaps in behind it moments later via a diff. Latency you feel is stage 1 only.

## Hard problem #1: the hotkey is an adversarial input

Push-to-talk on fn/Globe sounds trivial. It isn't:

- NSEvent global monitors can observe keys but can't *swallow* them — fn+Space (hands-free latch) would leak a space into your document. So: a CGEventTap at `headInsertEventTap`, returning nil to consume events. macOS silently disables slow taps; you must catch `tapDisabledByTimeout` and re-enable yourself.
- The hotkey logic is a pure state machine (idle / push / hands-free) with injected timestamps, so it's unit-testable without sleeping. Shift arrives via `flagsChanged` with its own keycodes — an unguarded handler double-fires recording on shift press.
- Key autorepeat must be filtered, or holding Space latches-then-stops hands-free on its own repeats.
- The killer: Parla types text by posting synthetic keystrokes, and its own event tap sees them. Without tagging every posted event with a magic marker in `eventSourceUserData`, the app cancels its own dictation the moment it starts typing.

## Hard problem #2: typing into someone else's app

No clipboard — save/restore is racy and transcripts don't belong there. Text is posted as synthetic Unicode keystrokes (`CGEventKeyboardSetUnicodeString`), which:

- caps at ~20 UTF-16 units per event, so you chunk — and a chunk boundary must never split a surrogate pair or you corrupt emoji;
- inherits the user's *physically held* fn modifier. The events use virtualKey 0, which is the A key. fn+A is macOS's "Show the Dock" shortcut. Every chunk opened the Dock until the code explicitly cleared event flags. Same bug class on backspace: held fn turns Delete into forward-delete.

This is also why nothing is typed *while* you speak, even though transcription runs live: any keystroke posted while fn is held merges with the modifier. The field is untouched until release, by design.

## Hard problem #3: the Accessibility tree lies

Before typing anywhere, Parla classifies the focus target via the AX API: editable / unknown / none / secure.

- Password fields (`AXSecureTextField`) are refused *before recording starts* — nothing typed, stored, or sent to the LLM. The check runs before the editable heuristics, which would also match.
- Chromium/Electron apps (Chrome, VS Code, Slack) expose **no AX tree at all** until an assistive client flips `AXEnhancedUserInterface` — so on a non-editable answer, flip the flag, wait 50ms, retry once. Never wake the tree for a secure field.
- Erasing is gated on proof: before backspacing N characters, read the field's text and cursor via AX and verify the characters behind the cursor are *exactly* what Parla typed. Can't verify ⇒ don't erase. You never delete a user's own text on a bad diff.

And app-specific safety: a curated set of terminal and chat bundle IDs (Terminal, iTerm, Slack, WhatsApp…) where a newline *submits* — dictated multi-line text gets flattened to one line before insertion, or each line would execute as a command.

## Hard problem #4: streaming without O(n²)

Naive live transcription re-runs whisper on the whole buffer every pass — quadratic in dictation length, and release latency grows with how long you spoke. Parla's fix: **windowed re-transcription**. Once un-confirmed audio exceeds ~15s, freeze a confirmed prefix at the locally quietest 100ms window (a plain RMS scan — the cheapest proxy for a breath, no VAD) and feed its tail back as whisper's `initial_prompt`, which the model reads as prior context. Each pass then re-transcribes only the last few seconds. Release latency is constant regardless of dictation length, and an in-flight pass aborts cooperatively the moment you let go — via a boxed Swift closure smuggled through whisper's C `void*` user-data pointer, because C function pointers can't capture closures.

Concurrency is handled with one trick: every whisper/insert operation chains onto a single `processTask` (`Task { [prev] in await prev?.value … }`). The whisper context isn't reentrant; the chain *is* the lock.

## Hard problem #5: both models fail, constantly

The pipeline treats its own models as untrusted:

- Whisper hallucinates "Thank you." on silence — so audio below ~0.4s or near-digital-silence RMS is never transcribed. It emits "[BLANK_AUDIO]" / "(sigh)" markers — stripped, and a transcript that's *only* markers becomes empty. Greedy decoding falls into repetition loops ("same sentence × 28") — whisper's temperature fallback stays enabled as the guardrail.
- The LLM can go degenerate too: cleanup output longer than 2× the transcript (+ a computed allowance for expanded snippets) is discarded as a repetition loop. Wrapping quotes are sanitized off. A cleanup that returns empty must not become "erase everything, type nothing" — the swap planner refuses.
- Cleanup **never throws into the dictation path**. Network down, key expired, rate-limited, refusal — every failure lands the raw transcript plus a one-line reason in the HUD. The dictation always succeeds; only the polish is best-effort.

## Command mode, and the prompt injection you'd ship without noticing

Select text, hold ⇧+fn, say "make this more formal" — the selection is transformed in place. Two details matter:

1. The selection is captured at key-down and **re-verified at release**: if you clicked away or edited it mid-speech, the result goes to history instead of overwriting whatever is now selected.
2. The selected text is arbitrary untrusted input going into an LLM prompt. It lives in the *user message* behind a `<text>` delimiter with deliberately **no closing tag** — the text region runs to end-of-message, so a selection containing `</text>` (or "ignore previous instructions") can't escape into instruction space.

## Privacy as architecture, not settings

Audio never leaves the device — that's the pipeline shape, not a toggle. Only the text transcript goes to the cleanup API, and pointing `baseURL` at local Ollama makes the whole thing zero-network. The clipboard is written exactly once in the entire codebase: the explicit Copy button. History is 50 entries, local JSON, and secure-field or cancelled dictations never enter it.

## Measuring it

The north-star metric is **zero-edit rate**: the fraction of dictations needing no manual fix. A day-one eval harness runs recorded real speech (TTS is banned — the whole point is fillers and self-corrections) through the exact production pipeline and diffs against human-written goldens, reporting zero-edit rate and ASR/LLM latency p50/p95. It's a script, not a platform — regression evals should exist from week one and grow with the product.

## The lesson

"Press key, talk, text appears" is a deceptively simple product wrapping a brutal core: OS event-tap plumbing, Unicode keystroke injection, an Accessibility tree that lies, streaming ASR scheduling, and two ML models that must be treated as unreliable components. The moat isn't the speech model — everyone has Whisper. It's insertion reliability across every app on the system, and the discipline that every failure path ends with your words still on screen.
