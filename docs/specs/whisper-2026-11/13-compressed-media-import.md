# Lane 13 — Compressed media import (M4A / MP3)

Wave 4 · Risk: High · Depends on: nothing (macOS only)

## Goal

The Hub's file import accepts only strict PCM WAV and a narrow PCM-in-MOV profile. Let people
transcribe ordinary compressed audio without converting it first, using AVFoundation (no FFmpeg),
without weakening the importer's identity checks and without promising timestamps the source
cannot support.

## Files owned

- `Sources/ParlaCore/ImportedAudio.swift`
- `Sources/ParlaCore/ImportedCompressedAudio.swift` (new)
- `Sources/Parla/FileImportSource.swift`
- `Sources/Parla/AudioImportOwner.swift`
- `Sources/Parla/Hub/HubAudioImport.swift` (open-panel content types only)
- `Tests/ParlaCoreTests/ImportedCompressedAudioTests.swift` (new), `ImportedAudioTests.swift`
- `Tests/ParlaTests/AudioImportTests.swift`

`ImportedAudio.swift` is not in the iOS shared-source list (`ios/Scripts/parlacore.py`), so this is
desktop-only.

## Current code (anchors by symbol)

- `ImportedAudio.SourceFormat { wav, mov }` — "Closed, extension-selected source routing. No
  sniffing." `SourceProfile { wavPCM, qtPCM16kV1 }` (`String`, `Codable`). `SourceFacts` with
  `Origin { strictPCM16k, systemPCMConversion, directMOVPCM16k }`.
- `ImportedAudio.decodeSource(_ bytes: Data, format:canceled:makeNative:)` — the decoder receives
  validated **bytes**, never a path.
- `ImportedAudio.Failure { format, structure, duration, native, output }` and its messages
  ("Use a file under 10 minutes and 20 MB.").
- `FileImportSource.init`: `switch url.pathExtension.lowercased()` mapping to a `SourceFormat`;
  `readValidated(retainEncoded:canceled:)` reads through a file descriptor with identity checks.
- `AudioImportOwner.start`, `AudioImportExecution.validateSource(_:mode:)`: timed mode
  (`.experimentalTimed`) requires `profile == .wavPCM && origin == .strictPCM16k`.
- `HubModel.chooseAudioImport` (in `HubAudioImport.swift`): `panel.allowedContentTypes = [.wav, .quickTimeMovie]`.
- Saved imports: `SavedAudioImportOwner`, `SavedAudioImportStore`, `SavedAudioImportStorage`,
  `VideoImportStructure`.

**Read before designing the edit:** `FileImportSource.swift`, `AudioImportOwner.swift`,
`SavedAudioImportStorage.swift` and `VideoImportStructure.swift` end to end. This spec was written
from their outlines, not a full trace of the saved-import path.

## Design

1. **Formats (decided): M4A and MP3 only; no MP4; the 20 MB / 10 minute caps are unchanged.**
   Reason: the byte cap bounds the importer's whole-file in-memory read and would refuse most MP4
   video, so MP4 would mostly add refusals. `SourceFormat` gains `.m4a`, `.mp3` (extensions `m4a`,
   `mp3`; still extension-selected, no sniffing). `SourceProfile` gains `compressedAVFoundationV1`.
   `SourceFacts` gains `.compressed(ImportedCompressedAudio.Facts)` with origin
   `.systemCompressedConversion`.

2. **Decoder** `ImportedCompressedAudio.decode(_ bytes: Data, format:, canceled:) throws -> Decoded`:
   - AVFoundation needs a URL. Write the already-validated bytes to a private temporary file
     (app temporary directory, mode `0600`, unique name, correct extension), and remove it in a
     `defer` on every path. The original file is never handed to AVFoundation.
   - `AVURLAsset` → first audio track (none → `Failure.format`) → `AVAssetReader` with an
     `AVAssetReaderTrackOutput` requesting linear PCM, 16 000 Hz, 1 channel, 32-bit float,
     non-interleaved. AVFoundation performs decode, downmix and sample-rate conversion.
   - Loop `copyNextSampleBuffer()`; check `canceled()` between buffers and call `cancelReading()`.
   - Bounds: stop with `Failure.duration` as soon as the output exceeds the existing 10-minute
     sample cap (reuse the constant the WAV path uses; do not introduce a second number).
   - Reader status `.failed` → `Failure.native`; zero samples → `Failure.output`.
   - `Facts`: container/extension, codec FourCC as reported by the track's format description,
     source rate and channel count, source duration in frames **as reported** (labelled as reported,
     not verified), output frames, output rate.
   - Use the synchronous asset/track loading APIs only if they are not deprecated on the package's
     deployment target (`macOS 13.3`); otherwise bridge the async `load` calls. The decode already
     runs off the main thread.

3. **Timing stays conservative.** Compressed sources carry encoder delay and priming that this
   lane does not map. `validateSource` already refuses timed mode for anything but strict PCM WAV;
   add the new origin to that refusal explicitly and keep the user-facing reason. No subtitle
   export for compressed sources.

4. **Routing.** `FileImportSource` maps the two extensions. `decodeSource` dispatches to the new
   decoder. The open panel adds `.mpeg4Audio`, `.mp3`.

5. **Saved imports.** If `SavedAudioImportStorage` validates container structure when it stores or
   reopens encoded bytes, do **not** extend that machinery in this lane: compressed sources are
   transcribe-only in v1 ("Keep and transcribe" unavailable for them, with a short reason). If it
   stores opaque bytes plus the format tag, extend the tag and keep the feature. State which case
   applied in the report.

6. **Copy.** `Failure.message` for compressed sources: `.format` → "This file has no audio track
   Parla can read."; `.native`/`.output` → "This file couldn't be decoded. Try exporting it as M4A
   or WAV."; `.duration` unchanged.

## Acceptance criteria and checks (one per behaviour)

Fixtures are generated inside the tests with AVFoundation (`AVAudioFile` writing AAC into `.m4a`
from a synthesized sine); nothing is committed and no third-party audio is used. MP3 cannot be
encoded by AVFoundation, so MP3 decode is covered by the human check only.

| Behaviour | Test |
|---|---|
| M4A decodes to 16 kHz mono | 2 s 440 Hz stereo 44.1 kHz AAC → sample count within ±5 % of 32 000, RMS non-zero, facts report rate 44 100 and 2 channels |
| Output cap is enforced | Decode with a lowered test cap → `Failure.duration`, no partial result |
| Cancellation stops decoding | `canceled` true after the first buffer → throws, temp file removed |
| Temp file never survives | After success, failure and cancel, the temp directory holds no leftover |
| No audio track → format failure | A video-only or empty container |
| Timed mode refuses compressed | `AudioImportExecution.validateSource(.compressed(...), mode: .experimentalTimed)` throws |
| Routing is extension-closed | `.m4a/.mp3` map; `.mp4`, `.aac`, `.ogg`, no extension still refuse |
| Existing WAV/MOV behaviour unchanged | Existing `ImportedAudioTests`, `ImportedWAVTests`, `ImportedPCMMOVTests`, `AudioImportTests` pass untouched |

## Checks to run

- `swift test --filter 'ImportedCompressedAudioTests|ImportedAudioTests|ImportedWAVTests|ImportedPCMMOVTests|AudioImportTests|SavedAudioImportStoreTests|SavedAudioImportStorageTests'`
- Final: `swift test` once.

## Out of scope

- FFmpeg or any new dependency. MP4 and any format beyond the two. iOS and Android import.
- Raising the 20 MB / 10 minute caps. Source-time mapping, subtitles or word timing for compressed
  sources. Drag-and-drop or batch import.

## Needs a human

- [ ] Import a real MP3 and a real M4A voice memo; confirm each transcribes and that cancel works
      mid-decode.
- [ ] Confirm a DRM-protected or corrupt file fails with the decode message, not a crash.
