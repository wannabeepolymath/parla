# Lane 09 — Linux processing/delivery ownership and explicit language

Wave 2 · Risk: High · Depends on: lane 03 (same files); lane 06 baseline run recommended first

## Goal

1. After Stop, a recording becomes a **job** with an identity. Jobs deliver in recording order,
   `cancel` revokes pending jobs, and nothing reaches the clipboard without a last ownership check.
2. The daemon gets an explicit recognition-language setting. Omitted, it keeps today's `"en"`.

## Files owned

- `linux/parlad/src/main.rs`, `linux/parlad/src/session.rs`, `linux/parlad/src/whisper.rs`
- `linux/parla-core/src/config.rs`
- `linux/README.md`, `linux/VERIFY.md`

## Current code (anchors by symbol)

- `main.rs` socket handler: `Edge::Finished => { tokio::spawn(app.finish(capture.take_since_mark())); "processing" }`.
  One detached task per Stop; two can run and deliver in either order.
- `App::dictate`: `spawn_blocking(transcribe)` → `cleanup::clean` → `deliver::to_clipboard`, with no
  check in between. `App::finish` shows the single notification.
- `session.rs` `Session::handle`: `(Command::Stop | Command::Cancel, State::Idle) => Edge::Ignored`.
  Every `(Command, State)` pair is spelled out on purpose; keep that.
- `whisper.rs` `Transcriber::transcribe`: builds `FullParams`, never sets language or an abort
  callback.
- `config.rs` `Config` (`#[serde(default)]`): `dictionary`, `snippets`, `cleanup`, `whisper_model`,
  `watchdog_secs`.
- whisper-rs 0.16: `FullParams::set_language(Option<&str>)`, `set_abort_callback_safe(F: FnMut() -> bool + 'static)`,
  `WhisperContext::{is_multilingual, token_sot, token_translate}`, `whisper_rs::get_lang_id`.

## Design

### A. Job ownership

**Policy (decided): queue, never supersede.** Jobs run one at a time in the order their recordings
ended, so the clipboard always ends with the newest finished dictation and two whisper passes never
compete for the CPU. `cancel` while nothing is recording revokes every pending job. Reason:
superseding would silently drop dictation A when B is recorded before A finishes; with
clipboard-only delivery A's text would survive only in its notification.

1. `struct Job { epoch: u64, samples: Vec<f32> }` and, on `App`,
   `cancel_epoch: Arc<AtomicU64>` and `pending: AtomicUsize`.
2. A single worker replaces the per-Stop spawn. In `main`, create
   `tokio::sync::mpsc::unbounded_channel::<Job>()` and one long-lived task:
   `while let Some(job) = rx.recv().await { app.clone().finish(job).await; }`.
   - `Edge::Finished`: under the session lock, as today, take the samples, read the current epoch,
     `pending += 1`, `tx.send(job)`. `send` on an unbounded channel does not await, so the
     "nothing below awaits" invariant in that handler still holds.
   - The worker awaits the whole pipeline, including the blocking whisper call, before taking the
     next job. That is what "keep ownership until native processing returns" means here.
3. Staleness: `let stale = { let e = cancel_epoch.clone(); let mine = job.epoch; move || e.load(Ordering::Relaxed) != mine };`
   - Before whisper: stale → skip the pass.
   - Native abort: `params.set_abort_callback_safe(stale.clone())`. `Transcriber::transcribe` gains a
     `should_abort: impl FnMut() -> bool + 'static` parameter. After `state.full` returns — `Ok` or
     `Err` — check stale **first**; an aborted pass must never be reported as
     `TRANSCRIPTION_FAILED`.
   - After cleanup and **immediately before** `deliver::to_clipboard`: stale → no clipboard write.
   - A stale job returns `("Parla", "Cancelled — nothing copied".into(), TOAST)` from `dictate`
     (the function must still return a message; that compile-time guard stays).
   - `pending -= 1` when `finish` returns, on every path.
4. Cancel with nothing recording. Keep `Session` pure and exhaustive: leave
   `(Command::Cancel, State::Idle) => Edge::Ignored`. In the socket handler, for
   `cmd == Command::Cancel` and `Edge::Ignored`: if `pending > 0`, bump `cancel_epoch` and reply
   `"cancelled"`; otherwise reply `"ignored"` as today. Cancel **while recording** discards only the
   recording, as today; pending jobs need a second cancel. Document both in `README.md`.
5. The watchdog path is unchanged (it cancels a recording, not jobs).

Put the decision logic in small free functions (`is_stale(job_epoch, current)`, the cancel-reply
choice) so they are testable without a microphone, matching how `transcript` and `delivered` are
already factored.

### B. Language

**Default (decided): omitted `language` stays `"en"` on every model; auto-detect is opt-in with
`language = "auto"`.** Reason: no existing config changes behaviour or pays the extra encoder pass
without asking for it.

1. `Config.language: Option<String>` (serde default `None`). Documented values: omitted → `"en"`
   (today's behaviour); `"auto"` → follow the speaker; a whisper code such as `"en"` or `"hi"` →
   pin.
2. Resolved once at startup in `Transcriber::new(model, language)` and stored:
   - English-only model (`!ctx.is_multilingual()`) → `"en"`. If the config asked for anything else,
     say so on stderr.
   - Multilingual + omitted → `"en"`.
   - Multilingual + `"auto"` → `"auto"`.
   - Multilingual + code → valid when the code has no NUL, `get_lang_id(code)` is `Some(id)` and
     `id < ctx.token_translate() - ctx.token_sot() - 1`. Invalid → stderr complaint naming the
     value, then `"en"`, the default. (Degrade loudly, like `Config::load` and the watchdog clamp
     do.)
   - Pure helper `resolve_language(multilingual, requested, lang_id, language_count) -> String` so
     the table is unit-testable.
3. `transcribe` always calls `params.set_language(Some(&self.language))` and
   `params.set_translate(false)`. Never `set_detect_language(true)` (detect-only returns without
   transcribing).
4. No behaviour change for existing configs. State in `README.md`: a multilingual custom model
   still decodes as English until `language` is set; `language = "auto"` detects the spoken
   language and costs one extra encoder pass per dictation.
5. Known limit of `"auto"`, documented, not fixed: whisper.cpp 1.8.3's own auto-detect scans the
   global language list, so on a 51865-vocabulary model it considers one non-language token.

### C. Docs

- `README.md`: the `language` key, the queue-and-cancel behaviour.
- `VERIFY.md`: fill the "added by lane 09" placeholders from lane 06 with checkbox items —
  A-then-B ordering, cancel after release (nothing copied, "Cancelled" toast), cancel mid-whisper on
  a long clip returns promptly, multilingual model with no `language` key still decodes as English,
  `language = "auto"`, pinned language, invalid `language` value logs and falls back to English. No
  results filled in.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Stale check | `is_stale` unit test: equal epoch → false, bumped → true |
| Cancel-when-idle reply | Unit test of the reply choice: pending 0 → `"ignored"`, pending 2 → `"cancelled"` and epoch bumped once |
| FIFO delivery | `#[tokio::test]`: feed two jobs to the worker loop with an injected pipeline closure that records order; second never starts before the first returns |
| Stale job never delivers | Same harness: bump the epoch while job 1 is "in whisper"; injected deliver closure is never called for it; job 2 (enqueued after the bump) delivers |
| Aborted pass is not "Transcription failed" | Unit test on the outcome fold: stale + `Err` → cancelled message |
| Session table unchanged | Existing `session.rs` tests pass untouched |
| Language resolution table | `resolve_language` unit test: english-only+any → `en`; multi+None → `en`; multi+`auto` → `auto`; multi+`hi` valid → `hi`; multi+`yue` with count 99 → `en`; multi+`zz` → `en` |
| Config round-trip | `config.rs` test: `language = "hi"` parses; absent key → `None`; existing files still load |

To make the worker testable, give it its pipeline as a parameter (a closure or a small trait object
used only by `main` and the tests). That is the one seam this lane adds.

## Checks to run

- `cd linux && cargo test -p parla-core`
- `cd linux && cargo test -p parlad`
- `cd linux && cargo clippy --workspace --all-targets -- -D warnings`

Same caveat as lane 03 about `parlad` compiling whisper.cpp; report any part that could not run.

## Out of scope

- A `Processing` state in `status`, per-job cancel, job persistence, a translate task.
- Resampling and ring changes (lane 11). Our own language probe for old vocabularies.
- Typing into the focused window (M2).

## Needs a human

- [ ] Lane 06 baseline run signed off before this merges.
- [ ] Run the lane 09 section of `linux/VERIFY.md` on real hardware and record results.
- [ ] Whether whisper-rs frees the boxed abort closure was not verified. If it leaks, the leak is
      one small allocation per dictation; note it in the report rather than working around it.
