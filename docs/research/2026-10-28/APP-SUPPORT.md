# App and platform support: source policy versus qualification

No third-party application was run during this research. Names below are **existing code classifications or proposed test targets**, not a certified compatibility list. Unknown macOS destinations can already receive generic native paste. A new bundle/domain classification changes cleanup style; it does not by itself make insertion work.

The current implementation has three distinct layers:

1. `TextRules.category` selects a cleanup hint from app bundle or browser host; browser URL stays local.
2. `InsertionDestination` and the session reducer validate destination continuity and decide whether to deliver. Secure fields/input are refused.
3. `Inserter.insert` posts native paste with a temporary clipboard lease. Posting it is not proof an opaque third-party app accepted it.

Source: [TextRules](../../../Sources/ParlaCore/TextRules.swift), [InsertionDestination](../../../Sources/ParlaCore/InsertionDestination.swift), [Inserter](../../../Sources/ParlaCore/Inserter.swift), [session reducer](../../../Sources/ParlaCore/DictationSession.swift).

## macOS: existing categories to qualify

| Destination family | Code policy today | Qualification and useful improvement |
|---|---|---|
| Terminal, iTerm2, WezTerm, Kitty, Ghostty, Alacritty, Hyper; Warp family | Terminal category; preserve symbols and flatten multiline output | Verify shell/TUI paste, bracketed-paste behavior, long Unicode and non-US layouts; no submitted commands |
| VS Code family, JetBrains family, Xcode, Zed, Sublime, Nova, Cursor | Code hint | Test editor, search, commit-message field and integrated terminal separately. App identity cannot identify the active pane. Add explicit profile override before claiming IDE-terminal safety |
| Slack, Discord, Messages, WhatsApp, Telegram | Chat hint and single-line output policy | Test rich composer, draft selection, accessibility activation, long text, emoji and no Send action. A profile may offer a reviewed alternate style; blanket multiline changes need field-level evidence |
| Apple Mail, Outlook, Spark, Superhuman | Email hint | Qualify subject/recipient/body separately; verify greeting/body/sign-off blank lines and existing draft preservation |
| Notes, TextEdit, Pages, Word, Notion, Obsidian, native ChatGPT IDs | Prose hint | Rich editor and plain-text modes, list interpretation, selected text, paragraph fidelity and command transforms |
| Windows App/RDC, Citrix, Horizon, AnyDesk, TeamViewer IDs | Remote-client list uses 5-second clipboard lease rather than 0.8 seconds | Clipboard sync on/off, slow remote session, local clipboard changes, multiple reads; preserve text for manual recovery. Do not automatically repeat an uncertain paste |
| Other apps | Unknown category; generic paste when destination rules permit | Add qualification before a support claim. Add a profile when cleanup style is the gap; investigate delivery only for reproducible insertion outcomes |

The maps use exact bundle IDs and tightly scoped prefixes; they intentionally avoid arbitrary app-name substring matching. A newly branded app or release channel needs actual bundle/field evidence, not a guessed identifier.

## Browsers and web applications

Recognized browser identities include Safari/Technology Preview, Chrome channels, Edge channels, Brave channels, Arc, Dia, Firefox/Nightly, Vivaldi and Opera. Presence in this list only permits browser-host classification; obtaining the current URL and pasting into a web editor still require real qualification.

| Website family | Existing host policy | Next qualification / profile targets |
|---|---|---|
| Gmail; Outlook Live/Office/Office365; Proton; Superhuman; Yahoo; Fastmail; iCloud Mail path | Email | Subject versus body, reply composer, multiple drafts/tabs, signature and selection changes |
| Slack, Discord, WhatsApp, Telegram, Google Chat, Teams | Chat | Textarea/contenteditable, thread versus channel, browser/desktop parity, focus switch and no Send |
| ChatGPT, Claude, Gemini | Prose | Preserve literal questions/instructions as dictated text; no answering by cleanup, no Send, cancel and draft selection |
| Google Docs, Notion web, Word web | No dedicated domain category in inspected map | Proposed prose/editor profiles and real editor qualification; some use canvas or opaque accessibility surfaces |
| GitHub/GitLab issues and PRs, Linear, Jira, Confluence | No dedicated domain category in inspected map | Proposed issue/task profiles: titles single-line, body preserves checklists/code identifiers; no automatic submit |
| CRM/support tools such as Salesforce, HubSpot, Intercom and Zendesk | No dedicated domain category in inspected map | Demand-led profile packs and editor qualification, including customer names and existing signatures; not claims these apps are currently blocked |
| Browser terminals, IDE remote sessions and SSH web consoles | No generic host policy can identify all terminal fields | Explicit terminal profile/field policy and no newline submission; qualify independently from browser prose |

Start with profile import/export and transparent rule precedence. Browser extensions are a later integration option if a specific editor cannot provide adequate local field/URL metadata; this audit did not establish that an extension is required. Do not send full URLs, clipboard contents or screen text to the cleanup provider as a side effect of adding app rules.

## Android: qualify the implementation already present

The current working tree already provides a voice IME and an Android 13+ floating route through accessibility input connection. Android 12 has IME/copy routes. It reviews results before insertion, preserves drafts/cursor when identity is valid, refuses restricted/secure editors, and does not send Enter. English tiny.en, two-minute microphone capture, explicit clean/message/email/original modes, cleanup retry and one-hour undelivered-output recovery are present.

The existing [Android README](../../../android/README.md) records emulator/harness checks and explicitly leaves physical-device and target-app compatibility open. This research did not rerun those checks.

| Qualification target | Required checks |
|---|---|
| WhatsApp, Telegram, Signal, Messages | New message, reply, draft/selection, emoji, multiline handling, no Send, field switch before Insert |
| Gmail, Outlook | Recipients/subject/body, composing/replying, signatures, IME action state and existing draft |
| Chrome and Firefox editors; Docs/Notion mobile | InputConnection support, contenteditable/canvas differences, focus continuity and reviewed fallback |
| Gboard, Samsung Keyboard, HeliBoard, FlorisBoard | Floating route retains current keyboard; IME picker and return work. Standard recognition APIs and voice subtype are separate candidate integrations; no promise every mic button can invoke Parla |
| Pixel, Samsung and at least one other OEM physical device | Microphone quality, screen/background restrictions, foreground service behavior, call/headset interruptions, rotation/process recreation, battery/thermal/low-memory behavior |
| Standard recognition callers | Separately test activity intent, RecognitionService and voice-IME handoff. Caller language, permission attribution, cancellation and final-once behavior matter |

Priority: physical qualification first, then multilingual verified models and standard caller APIs. Larger ASR families and audio-file sharing are separate, memory-sensitive initiatives. Do not label Android “missing” or “production qualified” from either source existence or emulator tests alone.

## Linux: current milestone first

The current daemon is a deliberate clipboard-only wlroots milestone. [VERIFY.md](../../../linux/VERIFY.md) states its Wayland clipboard, D-Bus, audio backends and compositor bindings have not run on real Linux hardware. This is the strongest immediate qualification gap; adding six backends before testing the first one would compound uncertainty.

| Target | Current boundary / next test |
|---|---|
| Sway/Hyprland or other suitable wlroots setup | Execute the existing checklist: repeated clipboard use while daemon lives, audio, notifier failure, hold/release/watchdog and model setup |
| niri / river configurations without key-release binding | Current docs defer evdev hotkeys; investigate explicitly rather than assume hold-to-talk works |
| GNOME/KDE | Portal/EI output and global-shortcut sessions are candidate expansions, requiring real desktop/version consent tests |
| X11 | Candidate backend and clipboard route; not established by current wlroots-only milestone |
| Terminal/TUI and IDE integrated terminal | Backend/chord, newline and modifier qualification after native output is implemented |

Any native output ladder must distinguish **not attempted**, **known failure**, **partial delivery** and **unknown after dispatch**. Fallback after the last two can duplicate user text. Input-device permissions, layout and compositor policy must be visible requirements.

## iOS and Windows

No iOS or Windows implementation was found in the current project. iOS has a source-backed architecture candidate: host-app audio/transcription plus a lightweight keyboard and generation-safe cross-process delivery (Dictus). It remains an XL feasibility project with physical lifecycle tests. Windows competitors offer useful delivery/platform references, but this research does not contain a qualified Parla Windows design; treat Windows as a separate platform decision rather than a small “app support” ticket.

## One reusable acceptance recipe

For each chosen app/version/OS/input route, record an existing draft and caret/selection; dictate short, long, multiline, identifiers and Unicode; repeat with a target switch and user edit while cleanup runs; test cancellation and provider failure; check no send/submit and no duplicated paste; verify clipboard restoration without overwriting a new user copy; verify password/Secure Input refusal. Mark **passed**, **failed**, **attempted/unverified** or **not tested** with actual observations. Never infer success from the paste function returning true.

## Additional qualification from the web expansion

The [13 added source trees](05-web-expansion.md) establish no new certified Parla app compatibility. They add useful test dimensions:

| Candidate | Qualification additions |
|---|---|
| Mouse-button trigger (B52) | Middle/side buttons, browser Back/Forward suppression, remapping software, lost release, device unplug and permission reconfiguration. Keyboard cancellation must remain usable |
| Guided templates (B51) | Long multi-field sequence in a GitHub/Linear issue composer or mail body; original field/window/selection retained; switch apps midway and require copy/review instead of a late paste |
| Shortcut labels (B54) | AZERTY/QWERTZ and layout switches, ISO/JIS fallback; distinguish display from physical binding and stable serialized names |
| Microphone diagnostics/calibration (B55) | Desktop listening without an ASR model; Android actual routed input versus requested route, ignored preferences, Bluetooth/USB and device-ID changes; no automatic accuracy ranking from SNR alone |
| Alternate/Indic models (B12/B16) | Hindi/English code-switching, proper names and chosen Indic cohorts; genuine Urdu/Arabic/other-language negatives; no silent script dropping or forced Hindi as global auto mode |
| Android alternatives and file import (B29/B41) | Cursor-word selection and stale async suggestions; same word repeated in different contexts; file input/output EOS, output-format changes, cancel and bounded decode memory |
| Cancellation/feedback (B49/B50) | Older nil/error result arriving during new capture; B keeps listening HUD. Deliberate post-capture discard must invalidate delivery before asynchronous abort returns |

Do not substitute upstream text-only clipboard restoration, full-field Accessibility replacement, or append-after-uncertain-alignment fallbacks for Parla's current destination and ownership rules. The evidence documents identify these as rejected patterns, not improvements to app support.
