# Video container structural preflight

`VideoImportStructure.inspect(Data)` is a pure structural projection for a restricted,
nonfragmented MP4/QuickTime grammar. It performs no IO, asset construction, native
decode, acquisition, staging, storage, queueing or production routing. Existing WAV
entry points and behavior are unchanged. This addition does not complete video import
or B40.

Successful inspection binds immutable declarations and ordered sample byte ranges to
the exact value-semantic `sourceBytes`. It does not accept PCM, inspect compressed
audio/video payloads, assert speech coverage, create source alignment, or invent
timestamps. Mutation of a caller's Data value cannot change an existing projection.
Track media intervals use exact integer ticks and timescales read from the container.

Every exposed sample or `mdat` range is a zero-based file-byte range that directly
indexes `sourceBytes`. Nonzero-origin `Data` slices are accepted and copied into a
zero-origin snapshot; their numeric file offsets and exact bytes are preserved.
That normalization can temporarily add up to 20 MiB of payload storage. It is not a
process-memory bound. Zero-origin inputs retain their existing value-semantic path.

## Structural facts and native eligibility

The supported audio declaration is AAC-LC at 44,100 or 48,000 Hz, mono or stereo, one
sample description, self-contained data reference and 1024-frame packet timing.
The exact two-byte AudioSpecificConfig must agree with the sample entry; PCE,
SBR/PS/HE-AAC, 960 frames, dependent core, extensions, other rates and channel
configurations refuse. A subtype string alone cannot produce a projection.

An explicit version-zero, single, unit-rate edit is required. Its duration must equal
the movie duration and convert to a whole number of audio frames. If packet count is
P, the declared packet domain is U=P*1024. The edit's nonnegative media start is L,
its exact mapped duration is N, and T=U-L-N. Require L and T each <=16,384, N between
rate*2/5 and rate*600, and no negative/empty/repeated/scaled edit, rounding or
composition offsets. Video permits an absent edit or exactly one version-zero, flags-zero, unit-rate
identity edit with signed media start zero and duration equal to the movie and track
header durations. Its entire positive decode timeline must map exactly to that movie
duration. No clipping or composition offsets are admitted.

These are **container-declared** trims and frame counts. They are not verified encoder
delay, original recording length, accepted decoded presentation frames, or instructions
to discard samples. Even an explicit zero trim does not prove zero encoder delay.
All successful projections carry only
`notAdmittedAACDelayAndNativeTrimUnproven`; there is no eligible case or caller-supplied
metadata enum that can authorize native decoding. The selected reader's exact trim/count/timestamp and waveform equivalence remain
unproved, including for the explicit declaration below. Unsupported sample-group
variants refuse rather than being partially interpreted.

A future reader must separately establish that missing proof, agree with the raw
track/config/extent/timing declarations, validate the actual packets and all returned
formats/PCM, and verify full EOF/cardinality and native lifetime. Snapshot ownership,
storage migration, async admission and cancellation barriers require separate work.
This API has no downstream native hook and supplies no permission to construct one.

## Explicit constant-roll declarations

`audio.delayDeclaration` is a closed fact: `legacyUngrouped` when both group atoms
are absent, or `explicitConstantRollMinusOne` for the exact form below. Existing
`inspect(Data)` calls and byte/range conventions are unchanged. Legacy success
retains its existing L>=0 arithmetic; it does not infer zero priming or a missing
roll description. Presence of either group commits to the explicit form. A partial,
invalid, duplicate or unsupported pair refuses without falling back to legacy.

Only the audio `stbl` may contain singleton `sgpd` and `sbgp` atoms:

- `sgpd`: body exactly 18 bytes; version 1, flags 0; ASCII `roll`;
  default_length 2; entry_count 1; signed big-endian Int16 roll_distance -1.
- `sbgp`: body exactly 20 bytes; version 0, flags 0; ASCII `roll`;
  entry_count 1; one row `(sample_count=P, group_description_index=1)`.
  Version 0 has no grouping_type_parameter or default_length field.

P must independently agree with `stsz`, expanded `stts` and `stsc`/extent totals.
Coverage includes all stored packets, even those before the presentation start.
For this explicit form require 1024<=L<=16384, 0<=T<=16384 and
rate*2/5<=N<=rate*600, with U=P*1024, U=L+N+T and exact reduced rational mapping
from the movie duration to N. Signed negative edit times refuse before range checks.
The first selected one-based packet is floor(L/1024)+1; L>=1024 supplies its stored
predecessor. L may lie inside a packet. Roll is a dependency measured in packets,
not a PCM trim, a proof of encoder delay, or an instruction to drop a packet.

This deliberately restricted representation draws on Apple's
[explicit encoder-delay description](https://developer.apple.com/documentation/quicktime-file-format/using_track_structures_to_represent_encode_delay_explictly),
[sample-group description](https://developer.apple.com/documentation/quicktime-file-format/sample_group_description_atom),
[sample-to-group atom](https://developer.apple.com/documentation/quicktime-file-format/sample-to-group_atom)
and [complete roll/edit summary](https://developer.apple.com/documentation/quicktime-file-format/summary_using_track_structures_to_represent_encoder_delay).
The retained design review also pins the version-zero membership layout against the
[FFmpeg 7 writer](https://github.com/FFmpeg/FFmpeg/blob/n7.0/libavformat/movenc.c#L2798);
the general membership documentation's default-length row is not used to insert an
extra field. These are retained design inputs, not a new normative review or decoder
qualification. L>=1024 and the finite trim/duration bounds are product constraints.

Only Q1–Q4 of the adopted design are represented here. Q5 is expressly excluded:
flags 1, sample-entry/ASC channel mismatch, ES_ID 0, decoder stream byte 0x14,
extra descriptors and `fiel`/`pasp`/`chrm`/`sdtp` remain refused. Other unknown atoms,
versions, flags, grouping types/distances, split membership and configurations still
refuse. The retained observed public file remains outside the whole-file grammar.
The canonical synthetic P49/L2112/N48000/T64 test does not admit that real file or
establish decoder-safe audio, MOV support, or native eligibility.

## Closed grammar

Every unlisted box or variant refuses. Boxes have explicit finite 32-bit or extended
64-bit sizes; size zero/to-EOF and UUID boxes refuse. Opaque top-level `free`/`skip`
padding is the only skipped box body. Handler names and the fixed visual compressor
name are inert leaf fields, never references. Accepted nesting is:

```text
file: ftyp, moov, one or more nonempty mdat, optional free/skip
moov: mvhd, exactly two trak (one soun, one vide)
trak: tkhd, mdia, required audio edts/elst, optional identity-only video edts/elst
mdia: mdhd, hdlr, minf
minf: smhd or vmhd, dinf/dref/url , stbl
stbl: stsd, stts, stsc, stsz, exactly one stco or co64, video-only optional stss
      audio-only optional exact paired sgpd/sbgp (both or neither)
stsd: exactly one mp4a/esds (audio) or avc1/avcC (video)
```

Singletons cannot be duplicated or omitted. Track IDs are positive and distinct.
Both tracks must be enabled/in-movie (`tkhd` flags exactly 3), with no alternate
groups, transforms or nonzero layer. Header full-box versions are zero, unit movie
rate/volume and identity matrices only; video dimensions must be nonzero. No
QuickTime versioned sound sample entries or `wave` wrappers are accepted. `dref`
contains exactly one self-contained `url ` entry, flags 1, no extra URL bytes, and
every sample entry references that entry. Fragmentation, external references,
playlists/reference movies, compressed metadata, encryption/protection and unknown
structural indirections refuse before any potential native use.

`ftyp` major/compatible brands are exclusively `isom`/`iso2`/`mp41`/`mp42`, or
exclusively `qt  `. Minor version is inert. The AVC configuration supports only
baseline/main/extended profile IDs 66/77/88, finite length-prefixed SPS/PPS lists,
valid reserved bits and 1/2/4-byte NAL lengths. Configuration NAL envelopes and exact
parent consumption are checked; compressed SPS/PPS and video samples are opaque.
High-profile extensions, other video descriptions, composition offsets and all
unlisted configuration child boxes refuse. This is a declared video track with
validated byte tables, not a visual decoder or conformance certificate.

`esds` has an exact ES -> DecoderConfig -> DecoderSpecificInfo hierarchy followed by
one predefined SL descriptor. Descriptor lengths are bounded to four bytes and their
parent ranges. Optional ES dependencies/URLs, extra descriptors, trailing bytes and
configuration disagreement refuse. MPEG-4 audio object type/stream type and the exact
LC configuration are checked. No LPCM fallback is substituted.

## Work and byte limits

| Dimension | Limit |
| --- | ---: |
| Complete encoded Data | 20 MiB, nonempty |
| Boxes, including sample-entry/config/reference envelopes | 4096 |
| Box nesting | 12 absolute; the closed grammar currently reaches only 8 |
| All non-mdat-payload bytes, including padding and headers | 2 MiB |
| Each audio/video configuration box body | 4096 bytes |
| Declared samples summed across both tracks | 131,072 |
| Table rows plus logical timing/sample extent/group membership expansion | 131,072 |
| AAC packets | 32,768 |

The work charge is raw `stts`/`stsc`/offset/optional `stss` rows, variable `stsz`
entries, logical `stts` repetitions and one operation per expanded sample extent.
The explicit group form adds one `sgpd` entry, one `sbgp` row and P logical membership
units, even though coverage uses a scalar comparison. All new group/edit boxes and
bytes count toward the same box/metadata/encoded limits. No cap is relaxed.
Thus another limit can refuse before a nominal sample/packet ceiling is reached.
The 600-second/trim rules make the AAC packet ceiling conservative. Closed nesting
refuses unknown deep containers at their first unrecognized level; it need not reach
depth 13 to refuse them.

Exact table byte lengths and entry budgets precede row traversal. Compact counts and
chunk-run products are checked before sample allocation/expansion. Positive sample
sizes and timing deltas, exact sample/chunk totals, one description index, complete
time sums and media durations must agree. Integer addition/multiplication is checked;
rational scaling reduces before multiplication and requires exact divisibility.
No floating point time tolerance is used.

Both audio and video tables expand into bounded ranges. Each entire chunk stays in a
single admitted `mdat` payload, found by bounded binary search; no box header or
unauthorized gap can become sample bytes. A final sorted check refuses every overlap,
alias or reused sample range within or across tracks. Unreferenced payload bytes may
remain opaque; their existence is not a decoded-media completeness assertion.

## Authored checks and current qualification

`VideoImportStructureTests` constructs tiny containers and sample tables in memory,
with independent byte-offset and rational cardinality oracles. Synthetic payloads are
explicitly not playable AAC/AVC fixtures. Tests cover supported structural projection
with native refusal, indexed mono/stereo rates, MOV, exact byte binding, finite
extended sizes/co64/variable sample sizes, multiple mdats, zero progress, malformed
lengths and large compact repetitions, encoded/metadata/box/work boundaries, declared
sample/packet caps, trim/duration boundaries, unknown/deep structures, references,
encryption, disabled/extra tracks, nested configs, edit ambiguity and video/audio
alias/extent failures. Refusal checks count a downstream structural handoff as zero;
they do not assert any production routing or native reader has been integrated.

The declaration extension passed **31 focused package tests** after independent
source review and a one-line test compiler correction. The process exited normally,
and checkout preservation checks passed. These pure checks cover eight container/rate/channel cells, the canonical scalar tuple with
split chunks and identity video, nonzero Data origins and reordered IDs, extended
group headers, unsupported signed/group/version/membership forms, pair completeness,
wrong parents, exact trim/presentation/rational boundaries, identity-only edits,
scalar work and box caps, contradictory tables and continued Q5 refusal. Old range,
extent, unknown-form and legacy tests remain, including empty/partial group refusal;
unsupported complete group forms are checked separately from the newly known pair.

Earlier qualification applied to the predecessor component only: the prior isolated
harness reported 19 checks and the package reported 32 focused tests (18 structural,
4 ImportedWAV, 10 ImportedAudio). Those historical results do not validate this
extension. The current focused run covers the 31 structural tests only; it does not
repeat those earlier WAV/audio checks or establish a full-package pass. No media or
native decoding ran. Native delay/trim/waveform proof, reader ownership, staging,
storage migration and
real file-import integration remain open. B40 and canonical status 23/43 are unchanged.

## Separate restricted PCM MOV reader

`ImportedPCMMOV` is a separate pure reader for the deliberately narrow
`qtPCM16kV1` profile. It does not relax the AAC grammar or authorize a native
reader. The profile requires a nonfragmented, self-contained QuickTime MOV with
exactly one audio and one video track. Audio is version-zero `sowt`, mono signed
16-bit little-endian PCM at 16 kHz, with fixed two-byte samples, one-tick timing,
and no edit or a single identity edit. Audio chunks must advance in physical
file order. Both track durations must map exactly to the movie duration.

The reader makes a deep, zero-origin source copy and binds validated audio chunk
ranges to that copy. `Inspection.decode()` accepts no replacement bytes. It
maps literal little-endian samples directly to Float values using division by
32768, preserves chunk order, and publishes only a complete result. Cancellation
is checked around the source copy and allocation, during structural work, at
most every 4096 extracted frames, and before returning. Those checkpoints are
cooperative; they do not establish a wall-clock cancellation deadline.

The complete source is capped at 20 MiB, audio at 6400–9,600,000 frames, combined
chunks at 4096, video samples and explicit table rows at 32,768 each, metadata at
2 MiB, boxes at 4096, nesting at 12, and structural work at 131,072 logical
credits. PCM scalar extraction has its separate frame cap. These are logical
bounds, not a process-memory or CPU-time guarantee. There is no per-audio-frame
extent allocation, resampler, media framework, path reader, or format fallback.

The visual description and video payload remain opaque after the restricted
fixed-field, reference, timing and extent checks. They cannot choose or rewrite
audio samples; overlap can only cause refusal. This is no video playback or
bitstream conformance claim, and these bytes must not be passed to a native
visual consumer on the strength of this reader.

The reviewed component passed **18 PCM MOV tests**, alongside **4 existing WAV
and 31 AAC structural tests**, in one serial package invocation with zero
failures. The tests use authored in-memory containers, including literal sample
oracles, compact tables, nonzero Data origins, external backing mutation,
limits, rational clocks, aliases and cancellation checkpoints. Actual exporter
compatibility remains unobserved.

The reader is now connected to explicit file selection, ordinary raw transcription,
private-copy admission and owned-source Retry through the closed `qtPCM16kV1`
profile. MOV uses literal PCM extraction; the WAV converter remains lazy and is
never constructed for MOV. Timed import remains strict WAV-only and refuses MOV
before decoding. Retained MOV copies contain the entire original container,
including video, under the existing seven-day private-import policy.

First MOV admission migrates saved metadata from schema 1 to schema 2 before
granting work, preserving old jobs and payloads. Publication uncertainty refuses
MOV work and freezes storage; physical schema-1 rollback after a successful rename
is not promised. Retry checks its verified owned bytes and redecoded MOV facts,
without reopening the original. See [saved private imports](audio-file-import.md#saved-private-imports).

The connected slice passed 103 distinct focused methods across four staged
test-only correction snapshots (57 + 20 + 17 + 9), including all 34 new methods.
Source review and corrected test-oracle review found no remaining blockers.
This is neither a full-package pass nor exporter, installed-backend or native-UI
qualification. General MOV/MP4 import, AAC native eligibility and B40 remain
incomplete; the macOS completion count stays 23/43.
