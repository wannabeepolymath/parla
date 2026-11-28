# Play Accessibility declaration — Android 1.3.2

Draft wording for the Play Console **Permissions declaration → Accessibility API** form. It matches 1.3.2 after four changes: selected-text changes (P0-16), guarded undo / restore original (P0-17), per-app nearby text (P1-02) and correction suggestions (P2-04). None of this has been checked on a device yet. Re-check the wording against the build before submitting. The in-app text quoted here must stay word-for-word identical to the app.

## Declared service

- `dev.parla.android.ParlaAccessibilityService` ([accessibility_service.xml](../app/src/main/res/xml/accessibility_service.xml)).
- `android:isAccessibilityTool="false"`. parla is not an assistive tool for people with disabilities. It's a dictation app that uses the Accessibility API to put text into other apps' fields.
- Flags: `flagReportViewIds`, `flagRetrieveInteractiveWindows`, `flagInputMethodEditor`. Events: view focused, text changed, text selection changed, window state changed, windows changed. `canRetrieveWindowContent="true"`. Unchanged from 1.3.1.
- The service does nothing until the user agrees to the in-app disclosure below **and** turns parla on in Android's Accessibility settings. If the user declines or withdraws consent, parla turns the service off.

## Core functionality — suggested declaration text

> parla is a voice-dictation app. The user keeps their own keyboard (for example Gboard). parla uses the Accessibility API to insert the words the user dictates into the text field they were typing in, and to place its floating voice control above the on-screen keyboard. It reads only the focused field the user is dictating into: its text, cursor or selection, app package and field type. That lets it write into the right place and refuse to write if the field has changed. Password fields, fields marked sensitive and non-text fields are skipped and never read. It reads the keyboard window's position, never its keys or contents. parla doesn't take screenshots, doesn't read other fields or the rest of the screen, and doesn't record what the user types.
>
> Related user-requested features use the same field:
> - **Undo / restore original.** For up to 10 minutes after inserting, parla keeps a copy of that field's text in memory only, so the user can tap Undo or Original to reverse the insertion. It makes the change only if the field is still exactly as parla left it.
> - **Selected-text changes.** When the user selects text and taps Command (speaks an instruction) or Preset, parla sends the selected text and the instruction to the AI provider the user configured. It then replaces exactly that selection, if the selection hasn't changed.
> - **Correction suggestions.** For one minute after inserting, parla checks whether the user corrected one word it wrote. If so, it saves a suggested dictionary word on the device, and the user adds or dismisses it. Private (incognito) fields are never watched.
> - **Nearby text (off by default).** For each app the user turns it on for, after reviewing exactly what will be sent, parla sends about 256 characters before the cursor with each dictation to the user's AI provider to improve cleanup. It's never saved. Password, private, email and web-address fields, browsers, terminals and password managers are excluded.
>
> Audio is transcribed on the device. Text goes to an AI provider only if the user sets up AI cleanup with their own API key.

## Data handling summary

| Data | Read when | Leaves the device | Stored |
|---|---|---|---|
| Focused field's text, cursor/selection, package, field type | User starts dictation or a selected-text change, and while that run lasts | No, except as in the rows below | Memory only, for that run |
| Same field after insertion (undo receipt) | Right after a verified insertion, then on changes to that field | No | Memory only, at most 10 minutes. Cleared when the field changes, focus moves or a new dictation starts |
| Same field after insertion (correction watch) | Up to 60 seconds after a verified insertion, non-private fields only, and never after a nearby-text dictation | No | Only a proposed word pair (for example "Shunade → Sinead"), on the device, until the user adds or dismisses it. At most 20 pending |
| Selected text | User taps Command or Preset | Yes, to the user's own AI provider, with the instruction | In parla's local history if History is on and the field isn't private |
| About 256 characters before the cursor | Each dictation in an app the user approved for nearby text | Yes, to the user's own AI provider, in a separate JSON field | Never. History and recovery keep only the original dictated words |
| App category (chat, email…) and single-line flag | AI cleanup | Yes, to the user's AI provider | No |
| Keyboard window position | Window changes | No | No |

## Prominent disclosure — exact in-app text

Shown before the user is sent to Android's Accessibility settings ([MainActivity.kt](../app/src/main/java/dev/parla/android/MainActivity.kt), "Allow text insertion?"). Buttons: **Agree** / **No thanks**.

> parla uses Android’s Accessibility service to insert dictated words into the text field where you started.
>
> It reads that field’s text and cursor or selection to place your words safely. It also checks the app and field type. Password fields and fields marked as sensitive are skipped.
>
> It checks whether your keyboard is open and where it is on screen, so the voice control appears above your keyboard whenever you're typing.
>
> For up to 10 minutes after inserting, parla keeps that field’s text in memory so you can undo or restore your original words. For one minute it also watches whether you correct a word it wrote, and may suggest adding the correction to your dictionary. Suggestions stay on your phone until you add or dismiss them. Private (incognito) fields are never watched.
>
> parla does not take screenshots, and it doesn't use or keep text from other fields or the rest of your screen. The field’s text and cursor or selection stay on your phone and are not shared, except as described below.
>
> If you enable AI cleanup, your chosen provider may also receive the type of app (such as chat or email) and whether the field is single-line, to format your dictated words.
>
> If you tap Command or Preset on text you’ve selected, that selected text is sent to your chosen provider to be changed.
>
> Nearby text is off. Only if you turn it on for an app in Profiles, after reviewing what’s sent, does parla send about 256 characters before the cursor with each dictation in that app to your provider.
>
> You can turn this service off at any time in Android’s Accessibility settings.

Accessibility settings description ([styles.xml](../app/src/main/res/values/styles.xml), `accessibility_description`):

> parla inserts dictation into the text field where you started, while keeping your keyboard selected. It checks the field and cursor, skips sensitive fields, and stops if you edit or change fields. After inserting, it briefly keeps that field's text in memory for undo and may suggest a dictionary word you corrected. Text you select is sent to your AI provider only when you tap Command or Preset; nearby text is sent only for apps you turn it on for. No screenshots or general screen text are collected. Audio stays on your device. If text insertion is unconfirmed, check the field before copying your result from parla.

## Nearby text — exact per-app disclosure

Shown in **Settings → Profiles → Nearby text → Turn on…** for one app profile ([NearbyText.kt](../app/src/main/java/dev/parla/android/NearbyText.kt), `NearbyText.disclosure`). The app fills in the bracketed values from the settings being reviewed. Buttons: **Send nearby text for this app** / **Cancel**.

> With each dictation in [package], parla will send about 256 characters of text before the cursor — text you didn’t dictate — to [provider] ([API address], model [model]). Text after the cursor is never sent, and parla doesn’t save nearby text. Password, private, email and web-address fields are skipped. Uses the API key saved in parla. Each request may be billed by [provider]. Changing this profile, your cleanup settings or your dictionary turns this off until you turn it on again.

Section text above the per-app rows:

> Off unless you turn it on for an app. About 256 characters before the cursor are then sent to your AI provider with each dictation, to help get names and sentences right. It’s never saved. Needs AI cleanup on, Clean up speech output, a model ID and no backup providers. Browsers, terminals and password managers can’t use it.

The grant is tied to the exact provider, address, model, app profile, dictionary, snippets, replacements and style the user reviewed. Any change removes it permanently, and the user has to review and turn it on again. Turning it off takes effect immediately in the running app, even if saving fails.

## Existing users

Users who agreed to the 1.3.1 disclosure **are asked again**. Consent is saved with the version of the disclosure it covers (`Settings.accessibilityConsentVersion`; this build's is `CURRENT_A11Y_CONSENT = 2` in [Models.kt](../app/src/main/java/dev/parla/android/Models.kt)). Data saved by 1.3.1 has no version, so it reads as version 1. That doesn't count as consent.

After the upgrade, parla does nothing through the Accessibility service: no reading, insertion, undo, suggestions or floating control. That lasts until the user sees the new "Allow text insertion?" dialog and taps **Agree**, which saves the consent with version 2. The dialog appears through the existing setup flow: opening parla shows setup as incomplete, and tapping the control sends the user to setup. **No thanks** works as before: consent stays withdrawn and parla turns its service off.

Any later change to what the disclosure covers must raise `CURRENT_A11Y_CONSENT`, which re-prompts everyone again. A saved version newer than the app's still loads, but doesn't count as consent.

## Demo video checklist

1. Fresh install: open parla, finish setup, show the full "Allow text insertion?" disclosure, tap Agree, and enable the service in Accessibility settings.
2. In a notes app, dictate a sentence. Show **Undo** and **Original** beside the control, then tap Undo: the sentence is removed. Dictate again, type one character, and show the buttons disappear.
3. Dictate a name, correct one word by hand and wait a second. Open parla → Dictionary and show the suggestion with Add / Dismiss.
4. Select some text, tap **Command**, say "make this formal" and finish: the selection is replaced. Repeat with **Preset**.
5. In Settings → Profiles, add a profile for the notes app. Open Nearby text → Turn on…, show the full disclosure and confirm. Change the cleanup model and show the app going back to Off.
6. In a password field, show that the control offers no actions and that nothing is watched or sent.
7. Upgrade: install 1.3.1, agree to its disclosure, then install this build. Show that the control does nothing and that setup shows text insertion as incomplete. Open the new disclosure and tap Agree, then show dictation working again.
