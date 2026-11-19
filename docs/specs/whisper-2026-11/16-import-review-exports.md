# Lane 16 — Import review UI: readable captions and JSON export

Wave 5 · Risk: Medium · Depends on: lanes 13, 14, 15

## Goal

Expose the two new exports where a file transcription is already reviewed: the Hub's audio import
result. Readable captions (wrapped, pause-split) next to the existing literal VTT/SRT, and the
structured JSON export.

## Gate

Do not start the readable-captions half until the human check in lane 14 ("compare word start times
with the audio") is recorded. If it is missing or poor, ship only the JSON export and say so. The
JSON half has no gate.

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
- From earlier lanes: `RecognitionFinalResult.words`, `CaptionLayout.cues(from:)`,
  `RecognitionExport.encoded(result:requestedLanguage:cleanedText:)`.

## Design

1. **Carry what the exports need.** `AudioImportOwner.Completed` / `Review` already hold the final
   result's segments for VTT/SRT. Additionally retain the `RecognitionFinalResult` itself (or the
   minimum: `words` and the pass identity) for the reviewed result. Same lifetime and invalidation
   as the existing timing data: discarded on `invalidate`, on dictionary change, on leaving the
   page.
2. **Word timing request.** The experimental timed import asks for word timing
   (`wordTiming: true` through `FileRecognitionBatch` / `timedFileResult`). Untimed imports and
   compressed sources never do.
3. **Readable captions.** `exportAudioImportReadableVTT()` / `…SRT()`:
   `CaptionLayout.cues(from: words)` → `SubtitleExport.encoded`. Reuse `exportAudioImport`'s save
   panel, currency check and failure handling by parameterising it with the cues to encode; do not
   duplicate the function. Available only when the reviewed result has `words`.
4. **JSON export.** `exportAudioImportJSON()`: `RecognitionExport.encoded(result:requestedLanguage:)`
   through the same save-panel path (`.json`). Available for every completed import, timed or not
   (segments are simply `null` when untimed). `cleanedText` is not passed: the import review shows
   raw recognition.
5. **`RecognitionExport` words.** When the result has `words`, add
   `"words": {"clock": …, "estimate": true, "items": [{"text", "start", "end", "segment"}]}`;
   otherwise `"words": null`. The `estimate: true` flag is the machine-readable form of "heuristic".
6. **View.** Add the buttons beside the existing export buttons, same style
   (`HubButtonStyle`). Labels: existing "WebVTT" / "SRT" keep their meaning (exact segments);
   new group "Readable captions" with "WebVTT" / "SRT", footnote "Line-wrapped. Word times are
   estimates."; and "JSON" with footnote "Raw recognition with model and timing details." Disabled
   states follow the availability rules above. This is user-facing copy and layout: have it
   reviewed for taste (opus-5.5 per the project's model table) before merge.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test (`AudioImportTests`, existing fake-native harness) |
|---|---|
| Timed import retains words | Fake native returning tokens → the review exposes words; untimed → none |
| Readable export uses the layout | Exported VTT equals `SubtitleExport.encoded(CaptionLayout.cues(from: words))` |
| Exports refuse a stale result | After `invalidate`, readable and JSON exports produce nothing (same rule as VTT/SRT) |
| JSON export works untimed | Untimed import → JSON with `segments: null`, `words: null` |
| Words appear in JSON when present | `RecognitionExportTests`: `words.estimate == true`, items match |
| Existing VTT/SRT export unchanged | Existing export tests pass untouched |

## Checks to run

- `swift test --filter 'AudioImportTests|RecognitionExportTests|SubtitleExportTests|CaptionLayoutTests|HubHistoryRetryTests'`
- Final: `swift test` once.

Do not launch the app or a browser to check the view. If visual verification is wanted, hand it to
gpt-6.1-sol through Codex computer use, per the project instructions.

## Out of scope

- Saved-import review exports (`SavedAudioImportOwner`), history export, playback, word
  highlighting, click-to-seek, karaoke output, caption style settings.
- iOS and Android.

## Needs a human

- [ ] Lane 14's word-time check recorded (gate above).
- [ ] Import a real two-minute WAV in experimental timed mode; open the readable VTT in a player
      and judge readability and sync.
- [ ] Open the JSON in an editor; confirm nothing private (paths, dictionary) is present.
