# Lane 03 — Bounded, token-aware prompt in the Linux daemon

Wave 1 · Risk: Low · Depends on: Wave 0 fixture block

## Goal

`parlad` joins the whole dictionary into `initial_prompt` with no bound. Apply the same byte guards
as the other platforms and select whole terms against the loaded model's token budget.

Runtime: whisper-rs 0.16.0 over whisper.cpp **1.8.3**. The budget formula is the same as 1.9.1
(checked in the 1.8.3 source: `max_prompt_ctx` and the `n_take1` suffix insert).

## Files owned

- `linux/parla-core/src/text.rs`
- `linux/parlad/src/whisper.rs`
- `linux/parlad/src/main.rs` (the one call site in `App::dictate`)

## Current code (anchors by symbol)

- `whisper.rs` `pub fn initial_prompt(dictionary: &[String]) -> Option<String>` (`dictionary.join(", ")`),
  its test `initial_prompt_joins_dictionary_terms`, and `Transcriber::transcribe(&self, samples, initial_prompt)`.
- `main.rs` `App::dictate`: `let prompt = whisper::initial_prompt(&self.cfg.dictionary);` then
  `me.transcriber.transcribe(&samples, prompt.as_deref())` inside `spawn_blocking`.
- `parla-core/src/text.rs`: shared pure text helpers (`strip_non_speech`, `rms`, …). `parla-core`
  already depends on `serde_json`.

## Design

1. **Pure selection in `parla-core/src/text.rs`:**

   ```rust
   pub const MAX_HINT_BYTES: usize = 256;
   pub const ASR_PROMPT_BYTES: usize = 2_048;
   /// README "Shared prompt-selection contract". `count` is the model tokenizer.
   pub fn select_prompt_terms(words: &[String], capacity: usize, count: impl Fn(&str) -> usize) -> Vec<String>
   ```

   Byte admission mirrors Swift `VocabularyHints.select`: collapse whitespace runs to one space,
   skip empty, skip terms over 256 bytes, skip terms containing `'\0'`, case-insensitive dedup
   (`to_lowercase`), whole terms while the `", "`-joined text stays within 2048 bytes. Then token
   admission and the final joined guard.

2. **`Transcriber` owns the tokenizer** (`whisper.rs`):
   - `fn prompt_capacity(&self) -> usize { (self.ctx.n_text_ctx() / 2 - 1).max(0) as usize }`
   - `fn count_tokens(&self, text: &str) -> usize` → `self.ctx.tokenize(text, text.len().max(1))`,
     `map(|t| t.len()).unwrap_or(usize::MAX)`. The `text.len().max(1)` buffer is mandatory (see the
     README's whisper-rs trap). `usize::MAX` on error means an untokenizable term is never admitted.
     Use `saturating_add` when accumulating costs.
   - `pub fn initial_prompt(&self, dictionary: &[String]) -> Option<String>` → select, join with
     `", "`, `None` when empty. Remove the free function.
   - `transcribe(&self, samples: &[f32], dictionary: &[String])` builds the prompt itself, so
     tokenization runs on the blocking thread, not on a tokio worker.

3. **`main.rs`**: delete the `let prompt = …` line; pass `&me.cfg.dictionary` into `transcribe`
   inside the existing `spawn_blocking` closure. Nothing else in `main.rs` changes.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Shared selection contract | `parla-core` test: read `../../fixtures/desktop-android-v1.json` via `env!("CARGO_MANIFEST_DIR")`, loop `promptBudget` with `count = str::len` |
| Byte guards | `parla-core` test: a 300-byte term and a term with `'\0'` are dropped; 400 ten-byte terms stay within 2048 joined bytes |
| Overflow-safe on tokenizer failure | `parla-core` test: `count = \|_\| usize::MAX` selects nothing and does not panic |
| Empty dictionary → no prompt | `parlad` test replacing `initial_prompt_joins_dictionary_terms`: test the pure join wrapper with an injected counter (the real `Transcriber` needs a model) |

## Checks to run

- `cd linux && cargo test -p parla-core`
- `cd linux && cargo test -p parlad`
- `cd linux && cargo clippy --workspace --all-targets -- -D warnings`

`cargo test -p parlad` compiles whisper.cpp from source (cmake + libclang). That is the crate's
test build, not an app build, but it is slow. If it cannot run on this machine, run the `parla-core`
tests and clippy on `parla-core`, and report the `parlad` gap explicitly.

## Out of scope

- Language, cancellation, job ownership (lane 09). Resampling (lane 11).
- `carry_initial_prompt`: whisper-rs 0.16 has no safe setter for it.
- A model-gated native test: the Linux tree has no model-gated test tier yet.

## Needs a human

- [ ] On the Linux box from lane 06, set a 200-term `dictionary` in `config.toml` and confirm the
      daemon starts, dictation works, and the first terms are honoured.
