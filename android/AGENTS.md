# Android app work

- Work only in this repository. The neighboring `../wispr-flow` dossier is a read-only behavioral/design reference.
- Use only GPT models through the Paawan Codex profile (`codex-snabbit`). User instruction supersedes older model/taste preferences. No Claude, Opus or Fable.
- User explicitly requested building the Android app: targeted Gradle builds, tests and lint are authorized. Do not upgrade global tooling or dependencies just for setup. Reuse installed SDK/JDK and compatible caches.
- Native Kotlin/Android is preferred for the floating voice control, foreground audio capture and accessibility insertion. The latest user clarification requires Gboard to stay selected; replace the earlier selectable parla keyboard. Use Bun for any JS/TS helper; never npm/yarn. Avoid TypeScript `any`.
- Prefer concise, simple solutions. Make all controls functional; do not ship placeholder product flows.
- Verify before fixing: locate the relevant symbol and confirm behavior independently. Start a neutral root-cause investigation before fixes; for uncertain claims, use a refute-first GPT agent, one claim per agent. Do not mutate investigated files while investigators read them. Prompts must allow DOES-NOT-HOLD, seek disconfirming evidence, require source locations and strongest opposing argument, and distinguish deliberate behavior.
- Reviews must use GPT only per the user's latest instruction. Do not reuse a running review to perform a new review.
- Device/computer use must be GPT. Use T3 device_list then device_open and the exact returned agent-device launcher/target flags for every device command. Reuse a suitable existing emulator. adb is limited to builds, logs and ports. Preserve unrelated apps/accounts/sessions.
- Do not make paid API calls, access real accounts, use Wispr private endpoints, commit credentials, publish, commit or push. API keys are entered locally in the app; use mock responses for automated API tests.
- Track processes/emulator sessions and temporary artifacts. Verify ownership before cleanup. Keep final APK and screenshots in this repository and document limitations honestly.
