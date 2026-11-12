# Play Protect installation report

Current product is parla (`dev.parla.android`); this product rename does not establish or change a Play Protect classification. The current appeal draft identifies the new artifact, and has not been submitted.

The historical supplied screenshot confirms the title “App blocked to protect your device” for the former Flow app, with this body: “This app can request access to sensitive data. This can increase the risk of identity theft or financial fraud.” It shows only Learn more and OK. This matches Google's documented sensitive-permission warning. Phone model, Android version and installation source are not visible. The screenshot does not identify which APK version was attempted or reveal Google's classifier internals. No fix for the block is claimed.

The historical independent Sol review confirmed the supplied Flow APK's SHA256 and valid v2 signature under its Android Debug signer, package `dev.flow.android`, minSdk33 (Android13), targetSdk36, and four native architectures. The packaged accessibility configuration declares `isAccessibilityTool=false`. These facts do not establish safety or Play Protect approval.

[Google's warning guidance](https://developers.google.com/android/play-protect/warning-dev-guidance) associates this exact warning with internet-sideloaded apps declaring sensitive capabilities, including accessibility, in applicable markets. Both the historical app and current parla declare accessibility for original-editor insertion, and does not declare SMS reading/receiving or a notification-listener service. The screenshot establishes the warning category; it does not independently establish that the code is harmful or safe. It is not the documented scan prompt or old-target warning.

Google's documented path is to review intended permission use, minimum access, privacy and user consent, then appeal if the classification is erroneous. A review draft is retained in PLAY-PROTECT-APPEAL.md; it has not been submitted. Do not label a new certificate, repackaging, changed identity, or removed permission as a Play Protect fix. Release signing is required for Google Play distribution but does not guarantee acceptance. Removing accessibility changes automatic editor insertion to manual paste and requires an explicit product decision.

No Play Protect setting was changed, protection bypass attempted, APK submitted to a third party, or external account accessed. The local correctness fixes from Sol round1 are separate from this unresolved installation report.
