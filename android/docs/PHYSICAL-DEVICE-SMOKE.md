> Historical build evidence. Current parla1.2.0 floating-control status is documented in [Gboard control](GBOARD-CONTROL.md); no device testing was resumed.

# Current physical-device smoke status

**Installed and opened on Motorola Edge 50, Android16.** After the normal Android Studio connection refresh and the user approving USB debugging, T3 exposed the physical phone. Existing Gradle wrapper deployment succeeded. Onboarding without sign-in, all four main tabs, Settings/API connection, and actual on-screen-keyboard practice input/cleanup passed. Phone remains on Home; emulator stays off.

Full current report: [physical-phone recovery](../evidence/parla-android-studio-usb-20261028/root-recovery/REPORT.md). Source/resources/build settings are unchanged. No microphone, accessibility/overlay grants, API key or paid request was used. Automatic insertion, live dictation and browser-sideload Play Protect acceptance remain unverified.

## Historical attempts before the successful connection

# Physical-device smoke status

2026-10-28 Android Studio USB attempt: **BLOCKED before IDE access; physical installation and launch NOT TESTED.** The required native computer-use tool was absent from the current tool catalog. Attempting `tools.cua_repl` with initialization code `cua.getApp("Android Studio")` returned exactly `TypeError: tools.cua_repl is not a function`. No app documentation or IDE UI was returned. The device selector, connection assistant and Run action were not reached; Motorola debugging authorization and Android Studio device readiness remain UNKNOWN. This is a tool-availability boundary, not evidence that Android Studio cannot deploy to the phone.

No build/deployment, direct adb operation, phone UI test, source/configuration change or emulator start occurred. The final read-only T3 inventory showed all listed virtual devices off, `parla-test.booted=false`, and `open=[]`. That inventory was used only to confirm emulator state. No screenshot or device session was created. Evidence: [Android Studio USB attempt](../evidence/parla-android-studio-usb-20261028/REPORT.md) and [structured results](../evidence/parla-android-studio-usb-20261028/results.json). A session exposing native `cua_repl` is required to perform the still-pending USB Run attempt.

## Earlier USB retry

2026-10-28 USB retry: **BLOCKED; installation and physical UI tests NOT TESTED.**

macOS currently sees a Motorola edge 50 over USB. T3 lists no physical targets; Android is available and the only Android entry, `parla-test`, is off. USB detection alone does not establish debug authorization, which remains UNKNOWN.

Upstream installed `agent-device 0.21.31` documents physical Android support and an Android `--serial` selector. T3's exposed `device_open` documents simulator/emulator opening; no supported mapping from the confirmed physical USB serial to its `deviceId` was found in the tool metadata or installed help/docs examined. No physical-open call was attempted, so no rejection or phone-authorization error is claimed. No session guard was bypassed and the emulator stayed off.

The approved `releases/parla-android-1.0.0-debug.apk` SHA-256 matches `5e9ded813445c37e234910183900c371447db6bb836a32e8da54263de9a8648c`. Installation, launch branding, four tabs, Settings, and practice synthetic-text/clear behavior remain NOT TESTED on the physical phone. No phone permissions/data or security settings were changed.

Manual alternative: open the project in Android Studio, select only the connected Motorola, and choose Run. If it is absent from that selector, Tools > Troubleshoot Device Connections can establish its actual connection state. The [official hardware-device guide](https://developer.android.com/studio/run/device) documents USB deployment. This alternative was not executed here; Run may build/deploy a different development APK.

Evidence: [USB retry report](../evidence/parla-usb-retry-20261028/REPORT.md) and [structured results](../evidence/parla-usb-retry-20261028/results.json). No phone serial is retained in these files. Final T3 check confirmed `parla-test.booted=false`, no physical entries, and `open=[]`.
