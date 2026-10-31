# Transcript export (B42 / wave 2C.3)

In **History**, choose a saved row’s **Export…** or **Export Filtered (count)…**
for all saved entries matching the search. Search includes original text, saved
result and displayed app name. An empty search includes all saved rows; zero
matches disables the button. Pending unsaved results and proposed retry results
are excluded. A missing/deleted row cannot start a new export.

The review shows the scope and saved entry count. Choose **Original** or
**Result** explicitly, independently of dictation’s output mode. Result means
the saved result when present, otherwise original; a saved empty result stays
empty. Choose **Plain text** (`.txt`) or **Markdown** (`.md`), then **Choose File…**.
Opening export freezes both text versions, dates and displayed app labels. Later
search, deletion, retention, new dictation or saved retry changes do not change
that reviewed export. Cancel review and reopen to capture updated saved text.

The native save panel suggests `parla-transcripts-YYYY-MM-DD` with the chosen
extension (UTC date). Transcript, app and provider strings never supply suggested
filenames. You choose the destination. Cancelling the file panel writes nothing,
shows no success/error, and keeps review available. Successful atomic UTF-8 writes
show the count, content choice and format. A write failure retains the same
snapshot for another attempt and shows a plain error without private error data.
The chosen filename must have the format’s extension.

Each entry has a date, Original/Result label and optional displayed app label.
Multiple entries have explicit separators. Text remains Unicode and multiline,
including empty text and combining characters. Markdown places source inside a
code fence longer than every source backtick run, so headings and embedded code
cannot become export structure. Metadata escapes Markdown punctuation and
renders newlines as visible escapes. Plain text metadata also escapes newlines.
Wrapper line breaks are added around source; source text itself is not trimmed,
normalized or rewritten. There are no invented word, timing or speaker fields.

The export whitelist contains transcript text, date and optional displayed app
label only. Settings, provider configuration/credentials/endpoints, environment,
headers, usage, retry/operation provenance and raw errors are excluded. This is
not a detector or redactor for secrets someone deliberately dictated into their
transcript: the chosen text is preserved verbatim.

Export never invokes a provider, recognition, capture, model download, insertion,
clipboard write, or settings/history mutation. Existing readable saved history
can be exported while history saving is off or settings cannot load/save. It
does not flush pending settings edits or reload/trim history.

Before the writer runs, the destination guard rejects the actual injected live
settings/history URLs and anything in the injected recording directory (audio,
sidecars and future paths). It checks lexical and resolved symlink paths,
including parent-directory aliases and outward aliases already in the recording
folder. Missing recording folders are supported. An unreadable recording folder
fails conservatively. Sibling paths with a similar name remain allowed. This is
a local destination guard, not an interprocess filesystem locking protocol;
concurrent hostile symlink replacement between checking and writing is not
qualified.

## Qualification

Model-free tests use temporary stores, fake panels/writers, the real Hub
prepare/export methods, actual destination validation and the production atomic
writer. They cover choice/scope freezing, Unicode/multiline/empty rows,
Markdown/metadata boundaries, filenames/types/extensions, cancellation, failure,
protected paths and symlink parents, secret exclusion, and settings/history-off
read-only behavior. SwiftUI bodies are constructed without a window.

Native save-panel interaction, rendered History controls/layout and visible
success/failure presentation still need manual macOS qualification. Tests do not
launch an app/window, use the live clipboard, run models or make provider calls.
