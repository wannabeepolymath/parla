> Historical parla1.1.0 selectable-keyboard implementation. Current1.2.0 uses a floating control alongside Gboard; see [Gboard control](GBOARD-CONTROL.md).

# parla voice keyboard

The current implementation replaces the bubble and accessibility services with `ParlaInputMethodService`, a system-selectable Android voice keyboard. It uses the existing native Kotlin code, Store, WAV recorder, GPT transcription/cleanup API contract, dictionary, snippets, style profiles and local history. The app package `dev.parla.android`, storage filename and encrypted-key alias are preserved. Legacy bubble JSON keys are ignored without resetting data.

## Setup and controls

In parla, open Keyboard setup; enable parla in Android’s input-method settings, select it using the picker, allow microphone permission in the Activity, and save your API settings/key. Focus a field, select parla and tap Tap to speak. Tap Finish dictation to transcribe, clean up and insert. Cancel stops recording and provider requests. Keyboards opens the system picker; Space, Delete and Enter/editor action are functional editing controls. Use another keyboard for QWERTY typing. Selecting or showing parla never starts recording automatically. Returning from permission/API setup requires a fresh microphone tap.

The IME owns capture only while visible; no persistent microphone foreground service, overlay, notification or accessibility permission is requested. The requested platform permissions are INTERNET and RECORD_AUDIO; AndroidX also contributes an app-scoped dynamic-receiver permission. Android still shows its normal notice when enabling a keyboard. This architecture change does not establish resolution of the historical Play Protect warning.

## Editor and data boundaries

A session captures the current InputConnection and a one-use guard for editor identity, input lifecycle generation, selection/composition revision, absolute range and a bounded surrounding-text slice. Restart, finish, unbind, hide and changed selection/composition cancel work. The final insertion checks the same connection, guard and fresh text slice and consumes the capability before commitText. An uncertain commit is never retried. If insertion is unconfirmed, the result can be copied explicitly; check the field before pasting because a false return is not proof nothing was inserted. No automatic clipboard fallback remains.

Password, visible-password, web-password, numeric, phone, unknown and unsupported targets cannot start dictation. No editor text is read for dictation in these targets. Missing/invalid surrounding-text support, unknown offsets or selections larger than 1,500 characters conservatively refuse dictation. Ordinary IME metadata cannot expose all accessibility data-sensitive flags; no equivalence with that removed API is claimed. Text can change in arbitrary editors between IPCs; this is conservative validation, not an atomic compare-and-write guarantee.

Context stays off by default and is capped at 1,500 characters when opted in; email/URL fields never supply context. Editors requesting no personalized learning receive no saved history or outgoing editor context for the session. Audio is temporary in private `cache/keyboard-audio`, deleted on completion/failure/cancellation; leftovers are removed when the IME service is created. Orphaned `cache/audio` files from the removed service are also deleted on IME creation. No paid/live API was called, and no credentials were added.

## Original APK evidence and design

The read-only REA dossier at `../wispr-flow` identifies original base APK SHA256 `5075ec7997bde7d696e246d62ba8ac0c34046b616606a2c17219c818a0467264`. Its `evidence/AndroidManifest.xml:203` registers FlowService and FlowAccessibilityService, with no BIND_INPUT_METHOD service/action/metadata. `artifacts/smali/com/wispr/ui/accessibility/WisprInputMethod.smali:3` extends android.accessibilityservice.InputMethod. The onboarding keyboard image is an illustration, not an executable keyboard layout. REA evidence IDs: `ev_6f367d0844cc15701f17fda51ee515629b031fa84652047c30003f198c3e7735` and `ev_bc80ebbb2dde85e18cf2fd49b98d5498ad567c2e065fa3f58dab67bf50176ac1`.

Parla reuses the recovered Figtree/Garamond fonts, neutral page colors, lilac and purple from ReferenceDesign.kt; the native keyboard arrangement is a new adaptation because this supplied original has no selectable keyboard. Existing dashboard, dictionary, style, snippets and history layouts are retained. No exact runtime/pixel parity is claimed; the original still has no usable product runtime frames in the retained evidence.

Primary Android references consulted: [IME registration and lifecycle](https://developer.android.com/develop/ui/views/touch-and-input/creating-input-method), [InputMethodService](https://developer.android.com/reference/android/inputmethodservice/InputMethodService), [InputConnection](https://developer.android.com/reference/android/view/inputmethod/InputConnection), [permission requests](https://developer.android.com/training/permissions/requesting), [background microphone restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start). Visible-IME capability evidence from Android 16 AOSP informed the lifetime boundary; OEM recording behavior remains untested.

## Verification and review

Deliverable: `releases/parla-android-1.1.0-debug.apk`, version 1.1.0 (2), SHA256 `7a63ee7822de538f028a4e0ea99c7aded42fdbb14ce8d24ecb49885eee8bd54b`. All 43 unit tests pass; lint has zero errors and 13 warnings; debug assembly and androidTest Kotlin compilation pass. The APK v2 debug signature verifies.

Local Gradle checks and APK evidence: `evidence/parla-keyboard/`. Unit coverage includes one-use insertion, input restart, editor switch/return, hide/show, selection away/back, composition/text invalidation, changed text/range/offset, sensitive/unknown fields, bounded snapshots, context exclusion and data compatibility. Instrumentation source now exercises synthetic InputConnection commit/delete/enter behavior instead of the removed accessibility service. Instrumentation compilation does not establish actual IME/OEM operation.

Phone/emulator testing remains STOPPED. This keyboard has not been installed on a device; microphone, live provider, OEM lifecycle, runtime layout and end-to-end insertion are unverified. The earlier physical/emulator evidence describes the historical bubble build. Sol-loop review and final local check results are recorded separately in `evidence/parla-keyboard/REVIEW.md` after completion.

The repository has no HEAD or remotes. The same source selection is frozen before/after under `evidence/parla-keyboard/{baseline,current}/source`, with ZIP archives and SHA256 manifests. Review diff: `git diff --no-index --binary --find-renames -- baseline/source current/source` from that evidence directory. Historical evidence/releases are excluded and preserved. No commit, push, publication, browser, phone session or emulator session is created by this change.
