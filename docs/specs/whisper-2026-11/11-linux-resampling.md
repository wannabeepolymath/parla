# Lane 11 — Linux capture: keep device-rate audio, resample once after Stop

Wave 3 · Risk: High · Depends on: lane 09 (same file, `main.rs`)

## Goal

`parlad` resamples every cpal callback independently with linear interpolation: the position resets
each callback, the output length is floored, and nothing low-passes before decimation. The result
depends on how the device happens to chunk the audio. Fix it by removing per-callback resampling
altogether.

## Decision: no streaming resampler

The review asked to assess the simpler option. Adopted:

- The ring stores **mono audio at the device rate**. The realtime callback only converts and
  downmixes (less work than today).
- The recording is resampled to 16 kHz **once**, on the blocking thread, after Stop. A whole-buffer
  resampler has no cross-callback phase or filter state, so the defect class disappears.
- No new dependency: a windowed-sinc resampler over one buffer is about forty lines. (`rubato`
  remains the upgrade path if a measured need appears.)

### Memory cost (assessed)

Ring bytes = `rate × seconds × 4` (mono `f32`).

| Device rate | 30 s (default watchdog) | 300 s (maximum) |
|---|---|---|
| 16 kHz (today, always 300 s) | — | 19.2 MB |
| 44.1 kHz | 5.3 MB | 52.9 MB |
| 48 kHz | 5.8 MB | 57.6 MB |
| 96 kHz | 11.5 MB | 115.2 MB |
| 192 kHz | 23.0 MB | 230.4 MB |

Today the ring is always 300 s even though a recording cannot outlive the watchdog
(`Session::new` clamps it to `RING_SECS`). Sizing the ring to the **clamped watchdog** makes the
default configuration smaller than today (5.8 MB vs 19.2 MB at 48 kHz) and bounds the worst common
case at 57.6 MB. High-rate interfaces with a 300 s watchdog are the expensive corner; storing `i16`
would halve it and is noted as the next step, not built.

The copy handed to the job is the same size as the ring's recorded span and is freed after
resampling.

## Files owned

- `linux/parlad/src/audio.rs`
- `linux/parlad/src/main.rs`
- `linux/README.md`, `linux/VERIFY.md`

## Current code (anchors by symbol)

- `audio.rs`: `TARGET_RATE`, `RING_SECS`, `CAPACITY`, `CALLBACK_HEADROOM`, `resample_linear` /
  `resample_linear_into` (and its `// ponytail:` comment claiming whisper's mel frontend makes
  aliasing harmless — that claim is wrong: filtering after decimation cannot undo folding),
  `Ring { samples, mono, resampled, mark, level, capacity }`, `Ring::push(interleaved, channels, rate)`,
  `Ring::take_since_mark`, `Capture::start()`, `build::<T>`.
- `main.rs`: `audio::Capture::start()?`, the job enqueue from lane 09
  (`capture.take_since_mark()`), `worth_transcribing`, and the
  `transcribing {:.1}s of audio` log using `audio::TARGET_RATE`.
- `session.rs` `MAX_WATCHDOG` derives from `audio::RING_SECS`; keep that.

## Design

1. **Ring at device rate.**
   - `Ring::push` drops the resample step: downmix into `mono`, compute `level` on `mono`, extend
     `samples`. Remove the `resampled` scratch buffer.
   - `Capture::start(max_recording: Duration)`: capacity = `rate × clamp(max_recording, 1 s, RING_SECS)`,
     headroom = one second at the device rate. `main` passes the configured watchdog.
   - `take_since_mark` returns `Recording { samples: Vec<f32>, rate: u32 }`.
   - Log once at startup: device rate, channels, sample format, ring seconds and megabytes.
2. **Whole-buffer resampler** `pub fn resample_to_16k(input: &[f32], from: u32) -> Vec<f32>` in
   `audio.rs`:
   - `from == TARGET_RATE` → return the input unchanged.
   - Output length = `round(input.len() × 16000 / from)`.
   - Windowed-sinc interpolation: cutoff `0.5 × min(from, 16000)` scaled by 0.95, Hann (or Kaiser)
     window, half-width 16 input-rate zero crossings of the low-pass. Normalise the tap sum per
     output sample so DC gain is 1. Treat samples outside the buffer as zero.
   - Upsampling (`from < 16000`) uses the same code with cutoff at `from / 2`.
   - `// ponytail:` comment naming the ceiling: O(output × taps), fine for ≤ 300 s; `rubato` if a
     measured need appears.
   - Delete `resample_linear`, `resample_linear_into` and their tests.
3. **`main.rs`.** The job carries the `Recording`. Inside the existing blocking section (before
   whisper, off the tokio workers and outside the session lock) call `resample_to_16k`. The duration
   log and `worth_transcribing` use the resampled buffer. `take_since_mark` under the session lock
   stays a plain copy.
4. **No format-change handling.** The stream is opened once at startup with a fixed configuration
   and stream errors are only logged today. Unchanged; note it in `README.md`.

## Acceptance criteria and checks (one per behaviour)

All in `audio.rs` tests, no sound card needed.

| Behaviour | Test |
|---|---|
| Duration is exact | 48 000 → 16 000 on 10 s of samples gives exactly 160 000 samples; 44 100 → 16 000 on 441 000 gives 160 000 |
| Callback partitioning no longer matters | Push the same 1 s signal into two rings, one in 128-frame callbacks and one in 1024-frame callbacks; the taken recordings are sample-identical |
| Pass-band is preserved | 1 kHz sine at 48 kHz → RMS of the output within 1 % of the input RMS (ignoring the first and last 20 ms) |
| Aliasing is suppressed | 10 kHz sine at 48 kHz (above the 8 kHz Nyquist of the output) → output RMS below 1 % of input RMS. The old linear path would fold it to 6 kHz at near full level |
| 16 kHz device is a no-op | `resample_to_16k(x, 16000) == x` |
| Ring is sized by the watchdog | `Ring::new` capacity for (48 000, 30 s) is 1 440 000; clamps at `RING_SECS` |
| Overflow keeps the mark valid | Existing ring overflow tests, adapted to device-rate samples |

## Checks to run

- `cd linux && cargo test -p parlad`
- `cd linux && cargo clippy --workspace --all-targets -- -D warnings`

Same caveat as lane 03 about `parlad` compiling whisper.cpp; report any part that could not run.

## Out of scope

- Asking the sound server for 16 kHz directly (it may be the best fix on PipeWire, but it is
  device-dependent and belongs behind the hardware checklist; see open question).
- `i16` ring storage, a lock-free ring, device hot-plug or rate-change handling, a level meter.

## Needs a human

Append to `linux/VERIFY.md` under the lane 11 placeholder, as unticked checkbox items:

- [ ] Startup log shows the device rate and ring size; record them.
- [ ] Duration fidelity: a timed 10.0 s dictation logs 10.0 s ± 0.1 s. Compare with the lane 06
      baseline number.
- [ ] Repeat on a 44.1 kHz and a 48 kHz device (or change the PipeWire clock rate) and on one USB
      microphone.
- [ ] Recognition sanity: the same sentence dictated before and after this lane is at least as
      accurate. No WER number may be claimed without the corpus from lane 04.
- [ ] `ps`/`smem` resident size of `parlad` idle for 5 minutes, default watchdog and
      `watchdog_secs = 300`; record both.
- [ ] A 5-minute dictation finishes; record how long the resample step took.

## Open question

On PipeWire/PulseAudio the sound server can deliver 16 kHz mono itself with a good resampler. If the
hardware run shows cpal offers it on your devices, requesting it would shrink the ring back to
16 kHz and make `resample_to_16k` a no-op. Worth a follow-up after the checklist, not before.
