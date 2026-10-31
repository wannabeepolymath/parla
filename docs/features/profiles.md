# App and exact-site profiles

Hub → **App & Site Profiles** creates, edits, enables, deletes and orders local
profiles. Existing settings have no profiles and retain their global behavior.
A profile has a stable UUID, name, enabled state and exactly one target.

## Matching and inheritance

An exact HTTP(S) browser host wins over an exact app bundle ID; otherwise globals
win. **One profile wins.** An unset field inherits directly from globals, never
from another profile. Bundle IDs are case-sensitive. Hosts use ASCII DNS/IPv4
labels, fold case and ignore one trailing root dot. Enter international hosts in
ASCII punycode. No suffix, substring, wildcard or subdomain matching; IPv6 host
profiles are not supported. URL ports do not change the host match. Site rules
only run for browsers recognized by `TextRules.isBrowser` and a locally available
HTTP(S) URL. Missing/inaccessible URLs and other schemes fall back to the app or
globals. URLs, hosts, paths, queries, profile names and bundle IDs are never
interpolated into provider prompts; the existing fixed destination categories
still determine formatting constraints.

The editor rejects duplicate targets (including disabled duplicates) and IDs.
Hand-edited duplicates remain readable with Hub warnings: first saved **enabled**
matching profile wins. Reordering changes that priority. The resolver preview
uses only the explicitly entered bundle ID and optional URL; opening the Hub
does not pretend the Hub is the dictation destination.

## Controls and timing

- Cleanup: inherit / off / on. On requires the globally configured provider.
  Off skips provider creation, requests and warming, while preserving locked
  snippets, local literal replacements and original history.
- Style: inherit / standard / conversational / formal, using fixed prompt text.
  Terminal/chat and single-line constraints come afterwards and still win.
- Spoken language: inherit / explicit auto / a supported whisper language code.
  English-only models still ignore the language choice.
- Local ASR model: inherit or an existing local model file. No downloads and no
  changes to the global model preference. Missing/damaged models fail visibly;
  a different global model is never silently substituted.
- Cleanup model: inherit or an ID in the current global provider. Credentials,
  provider and endpoint stay global. Provider/model errors use existing fallback.
- Words: saved order, profile words before global words. The shared case-folded
  dedupe and UTF-8 limits still apply: 256 bytes per hint, 2,048 ASR dictionary
  bytes, 8,192 cleanup dictionary bytes. Streaming adds at most 800 bytes of
  confirmed context. Selection limits never delete saved words.

Recognition resolves at capture start. Its immutable request retains language,
model and dictionary through stream head/tail, windowed/full final and command
instruction ASR. Model acquisition, calls and release use the existing serialized
processing chain. Each session retains the correct client handle even if globals
or the next session change. The global resident model/unload policy is preserved;
profile-only handles are released after the session or queued cancellation.

Ordinary output resolves at landing, before the reducer decides to polish.
Command output resolves after instruction ASR, before transforming the captured
selection. Both use the separate original globals snapshot, then freeze the
chosen cleanup mode/model/style/words through the await. Command mode keeps its
existing selected-transform prompt and trim-only output: ordinary style, snippets
and replacements do not rewrite selected transforms. Cleanup-off refuses commands
without creating a client. Both recognition and output winner names are shown in
the Hub's last-session section, including when they differ.

Secure-field refusal, existing destination/selection checks, stale-generation
withholding, history policy and generic insertion into unknown apps remain in
force. A profile match is never insertion permission.

## Settings and reproducibility

`profiles` defaults to `[]`; overrides are optional/defaulted. Required record
identity/name/target, enum values, language codes and hint sizes are validated.
A malformed profile record rejects the entire profile block rather than guessing
at behavior. SettingsStore keeps independently decodable global settings usable,
reports **Profiles rejected; editing disabled**, and leaves the original file
unchanged. Hub saves/imports remain disabled until the file is repaired. General
JSON syntax errors retain the existing whole-file load-error policy. A model file
removed after saving is a runtime availability error, not a settings decode error.

Vocabulary JSON exports/imports contain only words/snippets/replacements and
preserve profiles and other settings. `parla-eval` explicitly clears live profiles
and resets cleanup-enabled/style controls before applying its pinned vocabulary
fixture. It does not resolve live destination profiles.

## Qualification

Fake-client tests cover exact matching, persistence/validation, Hub CRUD/preview,
shared vocabulary budgets, all recognition request seams, queued old/new clients,
output switching, provider-off/no factory/warm, local rules, prompt constraints,
commands and secure/stale completion. No real models/providers are used. Native
Accessibility URL extraction, actual destination transitions, custom-model health,
cold/warm switching, UI layout and live ASR/cleanup quality require separate manual
qualification. No speed or quality improvement is claimed by these unit tests.
