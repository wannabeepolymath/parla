# Lane 02 — Token-aware prompt selection in the Android JNI bridge

Wave 1 · Risk: Medium · Depends on: Wave 0 fixture block (vectors are mirrored, see below)

## Goal

Android builds its prompt in Kotlin before any model is loaded, by bytes only. Move the final
whole-term selection to the one place a tokenizer exists: inside `recognize`, after the context is
created.

## Files owned

- `android/native/bridge.cpp`
- `android/native/bridge_policy.h` (new, header-only, no JNI or whisper includes)
- `android/native/bridge_policy_test.cpp` (new, host self-check)
- `android/native/README.md`
- `android/app/src/main/java/dev/parla/android/TextRules.kt` (`VocabularyHints` only)
- `android/app/src/main/java/dev/parla/android/LocalSpeech.kt`
- `android/app/src/test/java/dev/parla/android/LocalSpeechModelTest.kt`, `ProductCoreTest.kt`

## Current code (anchors by symbol)

- `bridge.cpp` `Java_dev_parla_android_WhisperJni_recognize`: `const auto prompt = bytes(env, promptBytes, 2048);`
  then `p.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();` inside the `decode` lambda.
  The context is created per call under `inferenceMutex`.
- `TextRules.kt` `VocabularyHints.select(words, byteLimit)`, `asrPrompt(words)`.
- `LocalSpeech.transcribe`: passes `VocabularyHints.asrPrompt(words).toByteArray(Charsets.UTF_8)`.
- `LocalSpeechModelTest`: a fake `SpeechNative` asserts the prompt bytes (`"👋 नमस्ते"`).

## Design

1. **Wire format, no JNI signature change.** The fourth `recognize` argument becomes the
   byte-admitted candidate terms joined with `"\n"` (terms are whitespace-normalized, so they never
   contain a newline). The `"\n"`-joined form is never longer than the `", "`-joined one, so the
   existing 2048-byte guard in `bytes(...)` still holds.
   - Kotlin: add `fun asrTerms(words: List<String>) = select(words, 2048).joinToString("\n")`.
     Keep `asrPrompt` (existing tests use it). `LocalSpeech` sends `asrTerms`.

2. **Pure selection in `bridge_policy.h`** (so it can be checked on the host):

   ```cpp
   namespace parla {
   // terms: priority order. count: tokens for a UTF-8 string. Returns the ", "-joined prompt.
   template <class Count>
   std::string select_prompt(const std::vector<std::string>& terms, int capacity, Count count);
   std::vector<std::string> split_lines(const std::string& s);
   }
   ```

   Implements the README's shared contract from "used = 0" onward (byte admission already happened
   in Kotlin): per-term cost `count(first ? term : ", " + term)`, skip-and-continue, then the final
   "while joined count > capacity, drop last" guard.

3. **Bridge use.** After the context loads and before `decode` is defined:
   - `capacity = whisper_n_text_ctx(ctx.get()) / 2 - 1` (clamp at 0).
   - `count` = lambda calling `whisper_tokenize(ctx.get(), s.c_str(), buf.data(), buf.size())` with
     `buf` sized `max<size_t>(1, s.size())`; negative result → 0. Never `whisper_token_count`.
   - `const std::string prompt = parla::select_prompt(parla::split_lines(terms), capacity, count);`
   - The `decode` lambda keeps using `prompt` as today.

4. `android/native/README.md`: one paragraph on the wire format and why selection is native.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Check |
|---|---|
| Shared selection contract | `bridge_policy_test.cpp`: the five `promptBudget` vectors from `fixtures/desktop-android-v1.json`, mirrored verbatim with a comment naming the fixture, `count = byte length`, plain `assert`s in `main()` |
| Non-additive counter stays within capacity | Same file: a counter that adds 1 per `", "` never yields a joined count above capacity |
| Kotlin sends terms, not a joined prompt | `LocalSpeechModelTest`: the fake native receives `"👋 नमस्ते"` for one term and `"a\nb"` for two |
| Byte guard unchanged | `ProductCoreTest`: `asrTerms(words).toByteArray().size <= 2048` for the existing oversized list |
| Bridge still compiles for both ABIs | `python3 android/native/check-compile.py` (syntax-only against the existing configured CMake database) |

## Checks to run

- `c++ -std=c++17 -Wall -Wextra -o "$TMPDIR/bridge_policy_test" android/native/bridge_policy_test.cpp && "$TMPDIR/bridge_policy_test"`
  (a single-file host self-check, not an app build; delete the binary afterwards)
- `cd android && ./gradlew :app:testDebugUnitTest --tests 'dev.parla.android.LocalSpeechModelTest' --tests 'dev.parla.android.ProductCoreTest' --tests 'dev.parla.android.AudioRecoveryTest'`
- `python3 android/native/check-compile.py`

## Out of scope

- Keeping a native context alive across calls, a separate token-count JNI call, or any lifecycle or
  cancellation change in the bridge.
- An Android vocabulary retention count in the UI (none exists today).
- Language handling (lane 08).

## Needs a human

- [ ] On a device with `large-v3-turbo-q5_0`, dictate with a 200-term dictionary and confirm the
      first terms are honoured. No automated device run is specced.
