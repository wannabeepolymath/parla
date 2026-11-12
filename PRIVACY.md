# Parla for Android — Privacy Policy

Effective date: November 13, 2026

Parla is an Android dictation app developed by Daksh Jain. No Parla account is required. The app has no advertising or analytics SDKs. The developer does not receive your recordings, transcripts, history or API keys, and does not sell your data.

## Microphone and on-device speech recognition

Parla records audio when you explicitly start dictation with its floating control. Speech recognition runs on your device using a model you choose and download. Audio is never uploaded by Parla, including when you enable AI cleanup or retranscribe recovery audio.

Models are downloaded over HTTPS from huggingface.co and its model-delivery hosts. Downloads start at your request. These services receive normal connection information, including your IP address and the requested model file; Parla does not send them your recordings, transcripts or provider credentials. Their own privacy policies apply to their handling of connection information.

## Optional AI text processing

You can use local transcription without configuring an AI provider. If you enable AI cleanup or a rewrite/translation preset and configure a provider, Parla sends transcript text directly over HTTPS to Anthropic or the OpenAI-compatible endpoint you choose. It authenticates using the API key you configure, where required. The developer does not proxy these requests.

The request can also include your dictionary words, snippet triggers and expansions, selected style, rewrite/translation instructions, and formatting instructions for the type of destination field. It does not include recorded audio, the existing text in another app's field, or that app's package identifier. Local dictionary and snippet features can also work without a provider request.

Your chosen provider receives the submitted text and normal connection information and handles them under its own terms and privacy policy, including its retention and processing practices. Choose a provider and endpoint you trust. Turning off AI cleanup and using local output avoids these text-processing requests; previously submitted data remains subject to the provider's policies.

## API keys and local storage

Saved API keys are encrypted on your device using AES-GCM with a key held in Android Keystore. Each saved credential is bound to the provider and endpoint you authorize. You can remove the saved key in API connection settings. Parla does not send it to the developer or include it in model downloads.

Settings, dictionary, snippets, profiles and text history are stored in the app's private storage on your device. Text history can be disabled, and individual entries or all saved history can be deleted in the app. Disabling new history does not delete existing entries. If you explicitly copy, share or export text, the clipboard, receiving app or chosen file destination receives that text at your direction.

Recovery audio is separate from text history. On new installations, Parla defaults to retaining failed or interrupted completed recordings locally for seven days, with controls to disable retention or choose 1–30 days. Successful ordinary dictation disposes of its audio even if later text cleanup fails. Canceled and private-session recordings are discarded after active readers finish. Recovery audio can be played, retranscribed on the device, deleted individually, or cleared in Settings → Recovery audio. Retranscription keeps the source recording until deletion or expiry. Retention cleanup runs when the app handles its recording storage; it may not run while the app is inactive.

Recovery audio and provider-key files are stored in Android's no-backup directory. The app also disables Android cloud backup and excludes its private data from Android backup and device transfer rules. Removing the app removes its app-private data; files you explicitly exported or shared remain in their chosen destinations. You control deletion of those copies separately. Short-lived original/result text may also be retained in memory for up to five minutes and is lost when the process ends.

## Accessibility service and floating control

Parla's accessibility service is an optional text-insertion feature, not an accessibility tool intended primarily for people with disabilities. You enable it yourself in Android settings. It accesses the focused editable field and relevant window/keyboard metadata to insert the text you dictate into the field you chose and to guard against writing into a different or changed field. It checks sensitive/password-field metadata before reading field text. Existing field text is used locally for safe insertion and is not sent to an AI provider. The service does not browse or upload screen contents.

The display-over-other-apps permission shows the floating dictation control. A foreground service keeps that user-enabled control available and records microphone audio only when you start dictation. These permissions are not used for advertising or tracking.

## Accounts, children and contact

Parla has no account system, ads, analytics, data brokerage or sale of personal data. It is intended for adults aged 18 and older and is not directed to children. You do not need to contact the developer to delete local history or recovery audio.

If you contact the developer by email, the email service receives your message and address, and the developer uses them to respond. Do not include recordings, API keys or other sensitive content unless you choose to share it.

Questions about this policy: **dakshjainn2004@gmail.com**.

Changes to this policy will be published here with an updated effective date.
