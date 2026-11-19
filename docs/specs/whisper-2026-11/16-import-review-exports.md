# Lane 16 — Import review UI: JSON export

Wave 5 · Risk: Medium · Depends on: lanes 13, 14, 15

## Goal

Expose the structured JSON export where a file transcription is already reviewed: the Hub's audio
import result, next to the existing literal VTT/SRT.

## Decision: JSON only, captions held

This lane ships the JSON export and nothing else. Held for a later change, once lane 14's human
word-time check is recorded: the readable-caption buttons and any app request for word timing.
Reason: word times are unqualified heuristic estimates, and requesting them would change the decode
behind today's experimental timed import.

## Files owned

- `Sources/Parla/Hub/HubAudioImport.swift`
- `Sources/Parla/Hub/HubAudioImportView.swift`
- `Sources/Parla/AudioImportOwner.swift`
- `Sources/ParlaCore/RecognitionExport.swift` (add the optional `words` field)
- `Tests/ParlaTests/AudioImportTests.swift`
- `Tests/ParlaCoreTests/RecognitionExportTests.swift`

## Current code (anchors by symbol)

- `HubModel.exportAudioImportVTT()`, `exportAudioImportSRT()`, the private
  `exportAudioImport(_ format: SubtitleExport.Format)` and `audioImportExportIsCurrent(job:resultID:)`
  (the "is this still the reviewed result" check every export must repeat).
- `HubModel.startTimedAudioImport()` → `AudioImportOwner.start(..., mode: .experimentalTimed)`.
- `AudioImportOwner.Completed`, `AudioImportOwner.Review`; in `complete(_:result:)` the
  `timing` condition (`mode == .experimentalTimed && profile == .wavPCM && origin == .strictPCM16k`).
- `FileRecognitionBatch.runResult` (calls `handle.timedFileResult`).
- `HubAudioImportView`: the existing export buttons.
- From earlier lanes: `RecognitionFinalResult.words`,
  `RecognitionExport.encoded(result:requestedLanguage:cleanedText:)`.

## Design

1. **Carry what the export needs.** `AudioImportOwner.Completed` / `Review` already hold the final
   result's segments for VTT/SRT. Additionally retain the `RecognitionFinalResult` itself for the
   reviewed result. Same lifetime and invalidation as the existing timing data: discarded on
   `invalidate`, on dictionary change, on leaving the page.
2. **No word-timing request.** Every import, timed or not, leaves `wordTiming` at its `false`
   default. The timed decode and the existing VTT/SRT exports are untouched.
3. **JSON export.** `exportAudioImportJSON()`: `RecognitionExport.encoded(result:requestedLanguage:)`
   through the same save-panel path (`.json`), reusing `exportAudioImport`'s save panel, currency
   check and failure handling rather than duplicating the function. Available for every completed
   import, timed or not (segments are simply `null` when untimed). `cleanedText` is not passed: the
   import review shows raw recognition.
4. **`RecognitionExport` words.** When the result has `words`, add
   `"words": {"clock": …, "estimate": true, "items": [{"text", "start", "end", "segment"}]}`;
   otherwise `"words": null`. The `estimate: true` flag is the machine-readable form of "heuristic".
   Because of item 2, JSON exported from the app always has `"words": null` in this lane; the
   populated form is reachable only through the core API.
5. **View.** Add one "JSON" button beside the existing export buttons, same style
   (`HubButtonStyle`), with footnote "Raw recognition with model and timing details." The existing
   "WebVTT" / "SRT" buttons are unchanged. This is user-facing copy and layout: have it reviewed
   for taste (opus-5.5 per the project's model table) before merge.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test (`AudioImportTests`, existing fake-native harness) |
|---|---|
| App imports carry no words | Timed and untimed imports → the review result has no words; exported JSON has `words: null` (and `segments: null` when untimed) |
| Export refuses a stale result | After `invalidate`, the JSON export produces nothing (same rule as VTT/SRT) |
| Words appear in JSON when present | `RecognitionExportTests`: a constructed result with words → `words.estimate == true`, items match |
| Existing VTT/SRT export unchanged | Existing export tests pass untouched |

## Checks to run

- `swift test --filter 'AudioImportTests|RecognitionExportTests|SubtitleExportTests|HubHistoryRetryTests'`
- Final: `swift test` once.

Do not launch the app or a browser to check the view. If visual verification is wanted, hand it to
gpt-6.1-sol through Codex computer use, per the project instructions.

## Out of scope

- Readable caption exports and any word-timing request from the app (held, see Decision).
- Saved-import review exports (`SavedAudioImportOwner`), history export, playback, word
  highlighting, click-to-seek, karaoke output, caption style settings.
- iOS and Android.

## Needs a human

- [ ] Open the JSON in an editor; confirm nothing private (paths, dictionary) is present.
