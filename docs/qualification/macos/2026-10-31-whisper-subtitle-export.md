# macOS Whisper subtitle-export qualification

Observed 2026-10-31. This record supports B47's canonical preservation/export behavior on the original mono16kHz PCM-WAV Whisper path. It does not qualify acoustic boundary accuracy, complete speech coverage, native save panels, player rendering, other recognition engines/formats, Intel or the minimum supported OS.

The current arm64 host used the real production import queue, read-only catalog acquisition, Whisper native context, full-source recognition, transient review, export authority guards and atomic writer. Only the export destinations were injected. The model was base.en; dictionary hints were empty and cleanup was disabled. History writes, provider and credential callbacks, clipboard and recording writes stayed absent on the isolated application path. Insertion/corpus absence is by construction plus diagnostic disposition, not a system-wide OS measurement.

The 40-second input contains the licensed LibriSpeech 2277-149896-0000 PCM repeated six times followed by7360 zero frames. This is an explicit synthetic timing composition, not a new continuous human recording or representative quality corpus. Original speech: OpenSLR LibriSpeech, CC BY 4.0; Hugging Face openslr/librispeech_asr revision 71cacbfb7e2354c4226d01e70d77d5fca3d04ba1. Publisher reference text was frozen before inference and never used as a prompt.

Observed 640000 supplied samples and six native cues, in their original order, with a final end tick 3908 (39.080s). All ranges remained within the source; gaps, overlap policy and literal cue text were preserved without sorting, clamping, repair or timing invented from cleaned text. Missing diarization remains explicitly disclosed; no speakers are generated. UTF-8/RTL and overlap/gap behavior also have independent synthetic export oracles. Source review plus23 core and 10 connected tests support the deterministic criteria.

The actual loaded whisper_full image matched the official macOS v1.9.1 release framework, bound to upstream commit f049fff95a089aa9969deb009cdd4892b3e74916. This is release-byte correspondence, not a reproducible-build or universal interposition proof.

Pins:

- Model SHA256: a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
- Original PCM WAV SHA256: 20e10e583b4918e05cea91316f7bde65a345d2756e64abc7f7ee133e2a0547f5
- 40-second composition SHA256: 4c61638c57f68a33dfb44e93cca796acb541b47158872d1d5d6b3566cd0ab8fe
- Loaded framework SHA256: 50e9a18e22098bb673032ccb7205038de2cbd009fb67f969622bb939d0e89497
- Actual WebVTT: 908 bytes, SHA256 9078161e3279dd7e1911615ebd0c259c27643aa801c73bea09363d59e55da5ea
- Actual SRT: 900 bytes, SHA256 6187c1d3f40670eddae485840d42b13ea72ee942242780ee6b8d1777b7c745b9

The successful direct-XCTest child ran one application acquisition and ASR span, returned completed/uncanceled, and exited 0. Its process group and output settled. The runner verified source, binary, owned input and Git-stage preservation before/after. This does not measure internal C invocation count or bound native memory/GPU/OS caches.

An earlier attempt trapped in the test-only signal-state initializer before model acquisition. Its record was retained as incomplete. After independent assessment, the saved signal disposition became nullable with explicit error/refusal handling. Eight serial control-only children exercised default/ignored dispositions, attach timing and installation/restoration refusals. A separate root decision authorized the single corrected native attempt; the first plan was never reset. No native result is inferred from disabled-mode skips or helper-only markers.

Evidence location at observation: /private/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-owned-ocr-20261030-0av9ol73/. Key artifacts: whisper-native-run-02/{command.json,after.json,result.json,cues.json,exports/native.vtt,exports/native.srt,root-verified-result.json}, native-control-workbench-corrections/control-result-v2.json and b47-native-acceptance-audit-{report.md,evidence.json}. Temporary evidence is retained; the pins and bounded claims above survive its eventual removal. No commit, release or distribution is implied.
