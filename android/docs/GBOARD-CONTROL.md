# Floating parla control alongside Gboard

The latest user clarification authorizes the original-style floating control so Gboard remains the active keyboard. This supersedes the separate parla1.1.0 InputMethodService implementation. The native keyboard service, XML registration, keyboard-only editing helpers/view and their tests were removed. No native Gboard toolbar plugin is claimed.

## Reference and implementation

The original read-only REA dossier records `com.wispr.flowapp`2.8.3(182), base APK SHA256 `5075ec7997bde7d696e246d62ba8ac0c34046b616606a2c17219c818a0467264`. Original manifest services are FlowService and FlowAccessibilityService. REA evidence `ev_bc80ebbb2dde85e18cf2fd49b98d5498ad567c2e065fa3f58dab67bf50176ac1` and `../wispr-flow/evidence/rea/plain/com.wispr.ui.accessibility.InputAccessibilityService.onCreateInputMethod.txt` establish an accessibility InputMethod, not a selectable keyboard. Original recovered overlay classes/assets and Figtree/Garamond/ColorKt tokens provide the control styling. Private server behavior and exact original runtime fidelity remain outside the available evidence.

The retained pre-keyboard source in `evidence/parla-keyboard/baseline/source` was inspected before selective restoration. ApiClient, ApiSettings, TextRules and ReferenceDesign were verified unchanged before restoration and kept intact. New work adds cancellation through InsertionLease, best-effort keyboard-window docking and safe placement clamping. No device/browser actions or live API calls occurred during investigation or implementation.

## Setup and lifetime

Leave Gboard or your usual keyboard selected. Enable overlay, accessibility text insertion and microphone through the visible parla Activity, then press Show parla control. The service is armed as a microphone foreground service from that Activity; AudioRecord is only created on an explicit tap/hold after safe-editor/key/permission checks. Arming may be denied by Android/OEM policy; errors stop the service and require returning to the app. No automatic background microphone restart is attempted. It is START_NOT_STICKY. Android13 uses the microphone service type; Android14+ additionally declares special-use overlay hosting.

Notifications offer Finish/Cancel and Stop parla. Hiding/stopping/destroying the service cancels work, removes the control, and clears transient output. A fresh session waits for prior cancellation/cleanup to finish. Microphone revocation/process death may leave private audio until the next service creation; both legacy `audio` and prior `keyboard-audio` caches are cleaned then. User API keys are never collected in chat or embedded in artifacts.

The service does not select a keyboard. Upgrading from1.1.0 removes the parla IME; Android decides its fallback. Setup offers the system picker so users can explicitly restore Gboard. No forced Gboard selection, package dependency or settings write is used.

## Placement

The accessibility service observes TYPE_INPUT_METHOD window rectangles on window events, before any active-anchor early return. It does not traverse keyboard nodes, read keyboard text, take screenshots or poll. BubbleWindow converts screen bounds to its window origin, opts out of automatic fit insets, applies system-bar/cutout safe insets, docks above reported keyboard bounds and clamps position after restore/expansion/configuration changes. Expanded controls scale down if the usable display is narrow. Dragging disables Follow keyboard and saves manual coordinates. Settings provides a Follow keyboard switch and reset.

This is best-effort for missing, floating, split, animated or OEM-specific keyboard bounds. The control stays visible when enabled even if the keyboard closes, so an input can be focused again. Application overlays are not a means of inserting UI into Gboard’s own toolbar. Manual placement can be occluded by the IME; Settings reset restores automatic docking. No runtime layout/rotation/gesture verification was performed.

## Insertion, cancellation and privacy

Capture requires an actual connected accessibility service, a valid focused visible editable original node, bounded text/selection, and a non-sensitive text input type. Password, visible/web-password, numeric/phone, unknown/nontext and accessibility-sensitive targets are excluded before editor text is read or recording begins. Context is opt-in, capped at1,500 characters and excluded for URL/email fields. No-personalized-learning or unavailable/mismatched privacy metadata suppresses outgoing context and saved history for the session. A transient result remains available in the companion app until the next session or Stop; it is not persisted when history is suppressed.

An InsertionLease cancels pending recorder/provider work once when the captured field’s focus/text/selection/window/input generation changes or the accessibility service disconnects, when Android delivers these observations. Selection away and back invalidates the capability; missing/unobserved callbacks cannot provide an atomic edit guarantee. Consumption occurs before insertion so callbacks from our own write cannot cancel verification/history. Release/cleanup does not affect later sessions.

Insertion rechecks original node, service session, input generation, text, input type and selection. It prefers the accessibility input connection, which can coexist with Gboard; when unavailable, the retained ACTION_SET_TEXT path applies the validated full-field replacement. Once a commit is attempted it never retries using another method. Verification cannot retract an issued write or guarantee atomicity against arbitrary editor IPC races. Unconfirmed results offer explicit Copy in parla; check the field before pasting. No automatic clipboard copy occurs on cancellation or failure.

## Storage and checks

Version1.2.0(3) preserves `dev.parla.android`, `parla-data.json`, `provider-key.enc`, encryption version1 and `parla-provider-key-v1`. Both prior settings schemas decode; absent overlay fields default safely and existing dictionary/snippets/history/preferences remain. A1.1.0 rewrite may already have dropped old overlay positions, so those cannot be recovered. No uninstall/reset or migration from the different `dev.flow.android` sandbox occurs.

Focused local coverage includes codec fixtures for both versions, original-editor selection replacement/sensitive exclusions, one-use leases/cancellation/self-write callbacks, and docking/clamping. Existing mocked API, history retry, snippets, settings cancellation and WAV tests remain. DeviceSafetyTest retains only encrypted-key and stopped-recorder checks; keyboard-only synthetic editing tests were removed. Old accessibility instrumentation failures were precondition failures, not proof of a production defect. No device instrumentation was run.

Current local results: all44 unit tests pass, no failures/errors/skips; lint0errors/15warnings; debug assembly and androidTest Kotlin compilation pass. APK v2 debug signature verifies. Deliverable `releases/parla-android-1.2.0-debug.apk`, SHA256 `4aa1e4711e27fed141bbc99c2bc14a8764e27189cfefa2613277ec231aa74ebf`, 29608493 bytes. Packaged manifest confirms overlay/accessibility services and no selectable IME registration.

Local reports, APK metadata, frozen before/after source and Sol ledger are under `evidence/parla-gboard-control`. This repo has no HEAD/remotes. From that directory, all review rounds use `git diff --no-index --binary --find-renames -- baseline/source current/source`. Evidence/releases and generated/local-machine files are excluded consistently. Final review outcome is recorded in `evidence/parla-gboard-control/REVIEW.md`.

Phone/emulator testing remains STOPPED. Current Gboard coexistence, editor insertion, microphone eligibility, notification actions, gestures, runtime visual parity and live APIs are unverified. No Play Protect resolution is claimed. No commit/push/publication or new browser/device sessions.

## Primary platform references

- [Foreground microphone service restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Accessibility InputMethod](https://developer.android.com/reference/android/accessibilityservice/InputMethod)
- [Accessibility window geometry](https://developer.android.com/reference/android/view/accessibility/AccessibilityWindowInfo)
- [Window inset positioning](https://developer.android.com/reference/android/view/WindowManager.LayoutParams#setFitInsetsTypes(int))
