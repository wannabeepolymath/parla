# Lane 08 — Model-derived language range in the Android JNI bridge

Wave 2 · Risk: Low · Depends on: lane 02 (same files)

## Goal

The bridge validates a pinned language and runs its language probe against whisper.cpp's global
language registry. On an older multilingual vocabulary (51865 tokens, 99 languages) id 99 (`yue`)
is the model's translate token. Bound both by the loaded model.

## Files owned

- `android/native/bridge.cpp`
- `android/native/bridge_policy.h`
- `android/native/bridge_policy_test.cpp`

## Current code (anchors by symbol, in `Java_dev_parla_android_WhisperJni_recognize`)

- `const bool pinned = chosen != "auto" && whisper_lang_id(chosen.c_str()) >= 0;`
- The probe loop: `for (int i = 1; i <= whisper_lang_max_id(); ++i)` comparing
  `logits[whisper_token_lang(ctx.get(), i)]`.
- Kotlin `SpeechLanguagePolicy.language` passes any code in `SpeechLanguages.codes` (100 entries,
  including `yue`) or `"auto"`.

## Design

1. `bridge_policy.h`: `inline int language_count(int sot, int translate) { return std::max(0, translate - sot - 1); }`
2. `bridge.cpp`, after the context loads:
   `const int languages = parla::language_count(whisper_token_sot(ctx.get()), whisper_token_translate(ctx.get()));`
   - `pinned` additionally requires `whisper_lang_id(chosen.c_str()) < languages`. An unsupported
     pin therefore behaves like `"auto"`, the same fallback the bridge already applies to an
     unknown code.
   - Probe loop bound: `i < languages && i <= whisper_lang_max_id()`. Skip the probe entirely when
     `languages <= 0`.
3. No Kotlin change. `SpeechLanguages` stays the v1.9.1 registry list; the catalog's only
   multilingual model has all 100 languages.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Check |
|---|---|
| Arithmetic for both vocabulary layouts | `bridge_policy_test.cpp`: `language_count(50258, 50358) == 99`, `language_count(50258, 50359) == 100`, and a degenerate input returns 0 |
| Bridge compiles for both ABIs | `python3 android/native/check-compile.py` |
| Kotlin policy unchanged | `./gradlew :app:testDebugUnitTest --tests 'dev.parla.android.LocalSpeechModelTest'` |

## Checks to run

- `c++ -std=c++17 -Wall -Wextra -o "$TMPDIR/bridge_policy_test" android/native/bridge_policy_test.cpp && "$TMPDIR/bridge_policy_test"`
- `python3 android/native/check-compile.py`
- `cd android && ./gradlew :app:testDebugUnitTest --tests 'dev.parla.android.LocalSpeechModelTest'`

## Out of scope

- Filtering the language picker by model. Reporting "unsupported language" to the UI.
- The `lastLanguage` / `lastModel` hint (already model-scoped).

## Needs a human

- [ ] Only if an older 51865-vocabulary multilingual model is side-loaded: pin Cantonese and confirm
      the result is ordinary auto-detected transcription, not an English translation.
