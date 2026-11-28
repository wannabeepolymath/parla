# Play foreground-service declaration — Android 1.3.2

Draft wording for the Play Console "Foreground service permissions" declaration, matching the 1.3.2 behaviour where the floating control follows the keyboard and has no Show/Hide switch. Device verification of this behaviour has not been done yet. Re-check this wording against the build before submitting.

## Declared service

- `dev.parla.android.ParlaService`, `android:foregroundServiceType="microphone|specialUse"` ([AndroidManifest.xml](../app/src/main/AndroidManifest.xml)).
- Permissions: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `RECORD_AUDIO`, `SYSTEM_ALERT_WINDOW`.
- Special-use subtype property: "Floating dictation control shown above the on-screen keyboard after user setup; microphone capture only on explicit tap or hold".

## When the service starts and stops

- **Starts** only from the visible parla app, and only after the user has finished setup: microphone permission, "display over other apps", and the Accessibility consent screen followed by enabling the service in Android's Accessibility settings. Each time the parla app comes to the foreground with setup complete, it starts the service if it isn't already running. There is no boot receiver and no start from the background or from an Accessibility event. The service is `START_NOT_STICKY`.
- **While running**, an ongoing notification ("parla dictation") is always shown, with Cancel/Finish and **Stop parla** actions.
- **The floating control** appears only while an on-screen keyboard is open and every setup requirement still holds. It is removed when the keyboard closes. Opening the service does not open the microphone.
- **The microphone** is opened only when the user taps or holds the floating control in a text field. It is released when the user finishes or cancels, when the keyboard closes mid-recording, or when Android silences the recording because another app took the microphone. Recordings are capped at 10 minutes.
- **Stops** when the user taps **Stop parla** in the notification, or declines or revokes Accessibility consent in parla. After Stop parla, the service stays off until the user next opens the parla app. If the microphone permission is revoked, Android ends the app process. If "display over other apps" or the Accessibility service is turned off, the control stays hidden until it is turned back on.

## Microphone type — suggested declaration text

> parla is a voice-dictation tool for any text field. The user keeps their usual keyboard (for example Gboard). When they type, a small parla control appears above the keyboard. Tapping or holding it records their voice, which is transcribed on the device and inserted into the field where they started. Recording happens while the user is inside another app, so parla's own activity is not in the foreground at that time. A microphone foreground service, started while parla's activity is visible, is the supported way to capture audio for this user-initiated task. The microphone is opened only on an explicit tap or hold, is shown by the ongoing notification and the on-screen control, and is released as soon as dictation finishes or is cancelled. The user can stop the service at any time from the notification.

## Special-use type — suggested declaration text

> The service hosts parla's floating dictation control (a `TYPE_APPLICATION_OVERLAY` window). It shows the control above the on-screen keyboard only while the keyboard is open, after the user has explicitly set parla up, so the user can start dictation from any app without switching keyboards. No other foreground-service type covers keeping a user-requested overlay control available across apps. The service does no background processing besides showing this control and running a dictation the user started. It is user-visible through the ongoing notification, which also lets the user stop it.

## Demo video checklist

1. Fresh install: the app is open with setup incomplete, and no notification appears.
2. Finish setup (microphone, overlay, Accessibility disclosure → Accessibility settings). Return to parla: the ongoing notification appears and no control is shown.
3. Open another app and tap a text field: the control appears above Gboard. Close the keyboard: the control disappears.
4. Tap the control, speak, then tap the check mark: the text is inserted, and the notification shows "parla is listening" only during capture.
5. Start a recording, then close the keyboard: the recording is cancelled.
6. Tap **Stop parla** in the notification: the notification goes away, and no control appears when typing until parla is opened again.
