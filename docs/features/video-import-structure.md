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
composition offsets. Video has no edit, and its entire positive decode timeline must
map exactly to the same movie duration. Track header durations must agree too.

These are **container-declared** trims and frame counts. They are not verified encoder
delay, original recording length, accepted decoded presentation frames, or instructions
to discard samples. Even an explicit zero trim does not prove zero encoder delay.
All successful projections carry only
`notAdmittedAACDelayAndNativeTrimUnproven`; there is no eligible case or caller-supplied
metadata enum that can authorize native decoding. Complete explicit AAC encoder-delay
sample groups and the selected reader's exact trim/count/timestamp equivalence remain
unproved. Sample-group variants refuse rather than being partially interpreted.

A future reader must separately establish that missing proof, agree with the raw
track/config/extent/timing declarations, validate the actual packets and all returned
formats/PCM, and verify full EOF/cardinality and native lifetime. Snapshot ownership,
storage migration, async admission and cancellation barriers require separate work.
This API has no downstream native hook and supplies no permission to construct one.

## Closed grammar

Every unlisted box or variant refuses. Boxes have explicit finite 32-bit or extended
64-bit sizes; size zero/to-EOF and UUID boxes refuse. Opaque top-level `free`/`skip`
padding is the only skipped box body. Handler names and the fixed visual compressor
name are inert leaf fields, never references. Accepted nesting is:

```text
file: ftyp, moov, one or more nonempty mdat, optional free/skip
moov: mvhd, exactly two trak (one soun, one vide)
trak: tkhd, mdia, audio-only edts/elst
mdia: mdhd, hdlr, minf
minf: smhd or vmhd, dinf/dref/url , stbl
stbl: stsd, stts, stsc, stsz, exactly one stco or co64, video-only optional stss
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
| Table rows plus logical timing/sample extent expansion | 131,072 |
| AAC packets | 32,768 |

The work charge is raw `stts`/`stsc`/offset/optional `stss` rows, variable `stsz`
entries, logical `stts` repetitions and one operation per expanded sample extent.
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

The pure component has completed source review and the range-contract correction
review. An isolated component harness passed 19 checks, including a root slice
control. The actual package then passed 32 focused tests: 18
`VideoImportStructureTests`, 4 `ImportedWAVTests` and 10 `ImportedAudioTests`, with
zero failures. These overlapping runs establish the stated component and compatibility
checks, not native video decoding or complete import. Native AAC delay/trim proof,
reader ownership, staging, storage migration and real file-import integration remain
open. No tracker or completion count is changed.
