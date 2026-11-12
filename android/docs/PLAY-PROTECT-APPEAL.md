# Play Protect review draft — not submitted

App name: parla. Package: dev.parla.android. Current build: 1.0.0 (1), Android debug signer. Current APK SHA256: 5e9ded813445c37e234910183900c371447db6bb836a32e8da54263de9a8648c. Artifact: releases/parla-android-1.0.0-debug.apk. The historical screenshot shows the former Flow product; it does not identify the attempted APK's version/hash.

Reported warning: App blocked to protect your device. The body states that the app can request sensitive data and increase identity-theft or financial-fraud risk.

Please review the classification of this independent dictation application. Its accessibility service is used to insert user-requested dictated text into the originally selected editor. The user enables that service separately in Android settings. The service declares isAccessibilityTool=false. Dictation starts through the user's explicit tap or hold; a foreground service provides microphone capture and a floating control. The app does not declare SMS-reading, SMS-receiving or notification-listener capabilities.

Audio is sent to the HTTPS API endpoint configured by the user for transcription. Cleanup sends the transcript and configured vocabulary/style data. Editor text context is optional and disabled by default. API keys are stored with AndroidKeyStore encryption. This is an independent development build, not an official Wispr application.

Before submission, the developer must verify the actual attempted APK/hash, complete Google's permission/privacy/consent review, provide the required developer contact and distribution details, and attach the relevant artifact/evidence. Local tests and a code review do not establish policy compliance or Google approval. No submission or external upload has occurred.

The product rename is a user decision and is not claimed to resolve classification. The historical warning has not been reproduced for this new package, and this draft has not been submitted.
