# Lane 15 — Structured recognition export (core only)

Wave 4 · Risk: Low · Depends on: nothing

## Goal

A machine-readable description of one recognition result, for editor integrations and reproducible
diagnosis. It is a separate, explicit export. The history export keeps its deliberately smaller
boundary (`TranscriptExport`: "no configuration, operation, retry provenance, usage or errors").

## Files owned

- `Sources/ParlaCore/RecognitionExport.swift` (new)
- `Tests/ParlaCoreTests/RecognitionExportTests.swift` (new)

No edits to existing files. (The file is macOS-only for now; do not add it to the iOS source list.)

## Inputs that already exist

- `RecognitionFinalResult` (`text`, `provenance`, `segments`), `RecognitionPassResult`
  (`identity`, `pass`, `native`), `RecognitionPayload` (`text`, `detectedLanguage`,
  `requestedLocale`, `resolvedLocale`, `segments`).
- `RecognitionIdentity` (`engine`, `artifact`, `runtime`), `RecognitionArtifact`
  (`admittedCatalog(id:expectedSHA256:expectedBytes:)`, `customRevisionUnknown`, …),
  `RecognitionRuntime.nativeVersion`.
- `RecognitionSegments` (`clock`, `sourceSampleCount`, `cues`).
- `SubtitleExport.maximumBytes` (8 MiB) as the size precedent.

## Design

`public enum RecognitionExport` with one entry point:

```swift
public static func encoded(result: RecognitionFinalResult, requestedLanguage: String?,
                           cleanedText: String? = nil) throws -> Data
```

Output: UTF-8 JSON, sorted keys, one object:

```json
{
  "schema": "parla.recognition.v1",
  "rawText": "…",
  "cleanedText": null,
  "engine": "whisper",
  "model": {"kind": "catalog", "id": "base.en", "expectedSHA256": "…"},
  "runtime": {"nativeVersion": "1.9.1"},
  "language": {"requested": null, "detected": "en"},
  "source": {"sampleRate": 16000, "sampleCount": 160000},
  "segments": {"clock": "whisper-1.9.1-pcm-10ms", "cues": [{"text": "…", "start": 0, "end": 250}]}
}
```

Rules:

- **Unknown stays `null`.** A custom model is `{"kind": "custom", "id": null, "expectedSHA256": null}`;
  no digest is computed or guessed. No segments → `"segments": null`. No detected language → `null`.
  Never synthesize timestamps, speakers or words.
- `expectedSHA256` is the catalog pin the admission policy accepted, labelled as *expected*; the
  export does not claim to have hashed the file.
- `rawText` is the recognized text of the result. `cleanedText` is included only when the caller
  passes it, under its own key; segment cues are always raw.
- Refuse (throw) rather than emit a misleading file: a canceled or skipped result, a result with
  `text == nil`, or an encoded size above 8 MiB.
- Never include: the model path, the process `buildScope`, operation or capture UUIDs, dictionary
  terms, prompts, settings, or anything from `Diagnostics`.
- Build with `JSONSerialization` or a small private `Encodable` struct with `.sortedKeys`. No schema
  library, no versioning framework: the `schema` string is the version.
- `public static func suggestedFilename(now: Date) -> String` → `parla-recognition-YYYY-MM-DD.json`
  (same date formatting as `TranscriptExport.Format.suggestedFilename`).

Lane 16 adds an optional `words` field once lane 14's type exists; leave no placeholder for it.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Catalog result with segments | Decoded JSON equals the expected dictionary, key for key |
| Custom model leaves identity null | `artifact: .customRevisionUnknown` → `kind == "custom"`, `id` and `expectedSHA256` are `NSNull` |
| No segments → null, not an empty list | Untimed result |
| Canceled / skipped / nil-text results are refused | Three throws |
| Private fields never appear | The encoded string does not contain the model path, the `buildScope` UUID or the instance UUID used in the fixture |
| Cleaned text is separate | Passing `cleanedText` adds only that key; `rawText` and cues are unchanged |
| Size limit | A result over the cap throws (use a small internal cap seam like `SubtitleExport.encode(_:format:maximumBytes:)`) |

## Checks to run

- `swift test --filter 'RecognitionExportTests|TranscriptExportTests|SubtitleExportTests'`

## Out of scope

- UI, file panels, history integration (lane 16). JSONL or TSV variants. Quality evidence
  (lane 12 keeps that in the eval process). Word timing. Import of this format.

## Needs a human

Nothing.
