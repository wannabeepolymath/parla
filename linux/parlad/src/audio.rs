use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::FromSample;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

pub const TARGET_RATE: u32 = 16_000;
/// Ring buffer span: 5 minutes. `Session::new` clamps the watchdog to this, so
/// a dictation longer than the ring can't happen and the buffer only ever holds
/// the tail of the idle audio before one. That premise used to be falsifiable
/// from config.toml — `watchdog_secs = 600` dropped the front of a long
/// dictation with nothing to show for it — which is why the clamp exists.
pub const RING_SECS: u64 = 300;
/// The watchdog only runs on a one-second tick, so a `stop` can land up to a
/// second after the watchdog has expired and still finish the recording. The
/// ring keeps that second too, or the dictation's opening words would go.
const WATCHDOG_TICK_SECS: u64 = 1;

/// Mono samples the ring keeps at the device rate: the longest recording the
/// watchdog allows (clamped like `Session::new`), plus one watchdog tick. Sized
/// by the watchdog rather than always `RING_SECS`, because device-rate audio is
/// 3x the old 16 kHz ring at 48 kHz.
fn capacity_for(rate: u32, max_recording: Duration) -> usize {
    let secs = max_recording.as_secs().clamp(1, RING_SECS) + WATCHDOG_TICK_SECS;
    rate as usize * secs as usize
}

/// What `take_since_mark` hands over: mono audio at the device's own rate.
/// Resampled once, off the audio thread, by `resample_to_16k`.
pub struct Recording {
    pub samples: Vec<f32>,
    pub rate: u32,
}

/// Average interleaved channels down to mono. A trailing partial frame is
/// dropped rather than averaged against silence.
///
/// The allocating form. It is the brief's declared interface and what the tests
/// and any non-realtime caller want; the audio thread uses the `_into` version
/// below, so this currently has no caller in the binary.
#[allow(dead_code)]
pub fn downmix_to_mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    let mut out = Vec::new();
    downmix_to_mono_into(interleaved, channels, &mut out);
    out
}

/// Resample a whole recording to 16 kHz once, after Stop. No device offers
/// 16 kHz directly — CoreAudio and WASAPI give 44.1/48 kHz, and cpal 0.18
/// prefers them. One pass over the whole buffer has no cross-callback phase or
/// filter state, so the result cannot depend on how the device chunked it.
///
/// Windowed sinc: low-pass at 0.95 × half the lower rate (a filter *before*
/// decimation; nothing after it can undo folded aliases), Hann window over 16
/// zero crossings each side, taps normalised so DC gain is 1. Samples outside
/// the buffer count as zero. Output `i` sits at input position `i·num/den`, so
/// there are only `den` distinct kernels (1 at 48 kHz, 160 at 44.1 kHz); they
/// are built once, keeping trigonometry out of the per-sample loop.
// ponytail: O(output × taps), ~100 taps at 48 kHz, fine for ≤ 300 s on the
// blocking thread. A rate coprime with 16 kHz needs 16 000 kernels (~13 MB,
// no real device). `rubato` if a measured need appears.
pub fn resample_to_16k(input: &[f32], from: u32) -> Vec<f32> {
    if from == TARGET_RATE || from == 0 {
        return input.to_vec();
    }
    let g = gcd(from as u64, TARGET_RATE as u64);
    let (num, den) = (from as u64 / g, TARGET_RATE as u64 / g); // input samples per output = num/den
    let out_len = (input.len() as f64 * den as f64 / num as f64).round() as usize;
    let cutoff = 0.95 * 0.5 * (den as f64 / num as f64).min(1.0); // cycles per input sample
    let half = 16.0 / (2.0 * cutoff); // 16 zero crossings, in input samples
    let reach = half.floor() as i64 + 1;
    let tap = |x: f64| {
        if x.abs() >= half {
            return 0.0;
        }
        let t = std::f64::consts::PI * 2.0 * cutoff * x;
        let sinc = if t == 0.0 { 1.0 } else { t.sin() / t };
        sinc * 0.5 * (1.0 + (std::f64::consts::PI * x / half).cos())
    };
    let kernels: Vec<Vec<f64>> = (0..den)
        .map(|phase| {
            let frac = phase as f64 / den as f64;
            let k: Vec<f64> = (-reach..=reach).map(|k| tap(k as f64 - frac)).collect();
            let sum: f64 = k.iter().sum();
            k.into_iter().map(|w| w / sum).collect()
        })
        .collect();
    (0..out_len as u64)
        .map(|i| {
            let (base, phase) = ((i * num / den) as i64, (i * num % den) as usize);
            let acc: f64 = kernels[phase]
                .iter()
                .zip(base - reach..)
                .filter_map(|(w, j)| Some(w * *input.get(usize::try_from(j).ok()?)? as f64))
                .sum();
            acc as f32
        })
        .collect()
}

fn gcd(a: u64, b: u64) -> u64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// The real implementation writes into a caller-owned buffer, because the only
/// production caller is the realtime audio thread and it must not allocate. The
/// returning version above is a thin wrapper for everywhere else.
fn downmix_to_mono_into(interleaved: &[f32], channels: usize, out: &mut Vec<f32>) {
    out.clear();
    if channels <= 1 {
        out.extend_from_slice(interleaved);
        return;
    }
    out.extend(
        interleaved
            .chunks_exact(channels)
            .map(|frame| frame.iter().sum::<f32>() / channels as f32),
    );
}

/// Widen one device callback to `f32`, in the same shape as the two helpers
/// around it. A free function rather than two lines inside the stream closure
/// purely so the `clear()` is reachable from a test: the closure needs a
/// `cpal::Device` to exist, and forgetting this particular clear is the worst
/// failure this module has — the scratch grows without bound and the ring fills
/// with duplicated audio, which whisper then hallucinates over.
fn convert_into<T: cpal::SizedSample>(data: &[T], out: &mut Vec<f32>)
where
    f32: cpal::FromSample<T>,
{
    out.clear();
    out.extend(data.iter().map(|s| f32::from_sample_(*s)));
}

/// The capture ring, split out from `Capture` so that every behaviour below can
/// be tested without a sound card — `Capture`'s methods are a lock plus a
/// delegation and nothing else. Mono, at the device's own `rate`; the overflow
/// tests use a four-sample `capacity` instead of a real one.
struct Ring {
    /// `VecDeque`, not `Vec`. The trim below runs on the realtime audio thread
    /// on every callback once the ring is full — which is the daemon's resting
    /// state, since `take_since_mark` empties it and 300 s of idle refills it.
    /// `Vec::drain(..excess)` is O(len − excess), i.e. a 19 MB memmove per
    /// callback: measured at 485 µs mean / 4.28 ms worst on Apple silicon,
    /// against a 2.7 ms callback budget at 48 kHz/128. A front drain on a
    /// `VecDeque` is O(excess) instead.
    samples: VecDeque<f32>,
    /// Scratch, reused every callback so the audio thread never allocates.
    mono: Vec<f32>,
    mark: usize,
    level: f32,
    capacity: usize,
    rate: u32,
}

impl Ring {
    /// The headroom is one second at the device rate, so the `extend` in `push`
    /// never reallocates: the ring is trimmed *after* appending, so it
    /// transiently holds one callback more than its capacity. One second is
    /// ~60x the largest realistic callback; reallocating the ring on the
    /// realtime audio thread would be an xrun.
    fn new(capacity: usize, rate: u32) -> Self {
        Self {
            samples: VecDeque::with_capacity(capacity + rate as usize),
            mono: Vec::new(),
            mark: 0,
            level: 0.0,
            capacity,
            rate,
        }
    }

    /// One device callback's worth of interleaved samples. Runs on the audio
    /// thread: no allocation, no syscall, bounded work — downmix and store only.
    fn push(&mut self, interleaved: &[f32], channels: usize) {
        downmix_to_mono_into(interleaved, channels, &mut self.mono);
        self.level = parla_core::text::rms(&self.mono);
        self.samples.extend(self.mono.iter().copied());
        // Ring behaviour: drop the oldest audio rather than grow without bound,
        // and move the mark with it so the current dictation stays intact.
        if self.samples.len() > self.capacity {
            let excess = self.samples.len() - self.capacity;
            self.samples.drain(..excess);
            self.mark = self.mark.saturating_sub(excess);
        }
    }

    fn mark(&mut self) {
        self.mark = self.samples.len();
    }

    fn take_since_mark(&mut self) -> Recording {
        // `min` is belt-and-braces: `mark` is only ever set to a length, and the
        // overflow path decrements both together, so it cannot exceed `len`
        // today. Kept because returning too much audio is a better failure than
        // panicking the daemon on a slice out of range.
        let samples = self
            .samples
            .range(self.mark.min(self.samples.len())..)
            .copied()
            .collect();
        // `clear` keeps the allocation, so the audio thread's next `extend`
        // still cannot reallocate.
        self.samples.clear();
        self.mark = 0;
        Recording { samples, rate: self.rate }
    }
}

/// Recover from poisoning instead of propagating it. A panic anywhere near the
/// ring would otherwise either kill the audio thread's writes silently
/// (`if let Ok`) or panic every later dictation (`unwrap`); neither is a
/// failure mode worth having for a buffer whose invariants are restored by the
/// next `mark()`.
// ponytail: a plain mutex on the realtime audio thread. Deliberate, and bounded:
// the critical section is an amortised-O(1) `extend` into a pre-reserved buffer,
// an O(excess) front drain and one float store — no allocation and no syscall.
// The only other holders are `mark` (one store) and `take_since_mark` (one O(n)
// copy, once per dictation). The residual risk is priority inversion if the
// tokio thread is preempted mid-copy, which would stall capture for the length
// of that copy. Upgrade path if that ever shows up as an xrun: an SPSC ring
// (`ringbuf`, already in cpal's dev-deps) and no lock at all.
fn lock(ring: &Mutex<Ring>) -> MutexGuard<'_, Ring> {
    ring.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct Capture {
    ring: Arc<Mutex<Ring>>,
    // The stream must outlive the struct: dropping it stops capture.
    _stream: cpal::Stream,
}

// Task 8 shares `Capture` across tokio tasks inside an `Arc<App>`. cpal 0.18
// made `Stream` `Send + Sync` on every backend; this stops that being a
// discovery made two tasks later.
const _: () = {
    const fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Capture>();
};

impl Capture {
    /// Opens the input device and starts capturing immediately. Called once at
    /// daemon startup; the stream stays open for the process lifetime so that
    /// `mark()` has warm audio and the first syllable is never clipped.
    ///
    /// `max_recording` is the configured watchdog; the ring holds that much.
    pub fn start(max_recording: Duration) -> anyhow::Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| anyhow::anyhow!("no input device"))?;
        let supported = device.default_input_config()?;
        // cpal 0.18: `SampleRate` is a plain `u32` alias, and `build_*_stream`
        // takes `StreamConfig` by value.
        let rate = supported.sample_rate();
        let channels = supported.channels() as usize;
        let format = supported.sample_format();
        let config: cpal::StreamConfig = supported.into();

        let capacity = capacity_for(rate, max_recording);
        eprintln!(
            "parlad: capturing {rate} Hz, {channels} ch, {format:?}; ring {:.0} s, {:.1} MB",
            capacity as f64 / rate as f64,
            (capacity * std::mem::size_of::<f32>()) as f64 / 1e6
        );
        let ring = Arc::new(Mutex::new(Ring::new(capacity, rate)));

        // cpal 0.18's default-config heuristic ranks F32 > F64 > descending
        // integer widths, so it can hand back I32 or I24 on high-precision
        // hardware. Every format with a sized Rust sample type is accepted; the
        // conversion is `FromSample`, not a hand-rolled divisor, so 24-bit —
        // which is stored in an i32 but only 24 bits wide — scales correctly.
        let stream = match format {
            cpal::SampleFormat::F32 => build::<f32>(&device, config, &ring, channels, format),
            cpal::SampleFormat::F64 => build::<f64>(&device, config, &ring, channels, format),
            cpal::SampleFormat::I8 => build::<i8>(&device, config, &ring, channels, format),
            cpal::SampleFormat::I16 => build::<i16>(&device, config, &ring, channels, format),
            cpal::SampleFormat::I24 => build::<cpal::I24>(&device, config, &ring, channels, format),
            cpal::SampleFormat::I32 => build::<i32>(&device, config, &ring, channels, format),
            cpal::SampleFormat::I64 => build::<i64>(&device, config, &ring, channels, format),
            cpal::SampleFormat::U8 => build::<u8>(&device, config, &ring, channels, format),
            cpal::SampleFormat::U16 => build::<u16>(&device, config, &ring, channels, format),
            cpal::SampleFormat::U24 => build::<cpal::U24>(&device, config, &ring, channels, format),
            cpal::SampleFormat::U32 => build::<u32>(&device, config, &ring, channels, format),
            cpal::SampleFormat::U64 => build::<u64>(&device, config, &ring, channels, format),
            // `SampleFormat` is `#[non_exhaustive]`, so this arm cannot be
            // replaced with explicit ones. The DSD variants land here: they are
            // 1-bit bitstreams with no sized sample type, so there is nothing to
            // convert. Refusing to start is the explicit failure; silently
            // capturing nothing is not.
            other => anyhow::bail!("unsupported sample format {other:?}"),
        }?;
        // cpal 0.18 no longer auto-starts streams.
        stream.play()?;
        Ok(Self {
            ring,
            _stream: stream,
        })
    }

    /// Stamp the current buffer position as the start of a dictation.
    pub fn mark(&self) {
        lock(&self.ring).mark();
    }

    /// Everything captured since the last `mark()`, mono at the device rate.
    pub fn take_since_mark(&self) -> Recording {
        lock(&self.ring).take_since_mark()
    }

    /// Most recent RMS level. Its only consumer is M3's pill meter — Task 8's
    /// pipeline never reads it — so it has no caller in the binary yet.
    #[allow(dead_code)]
    pub fn level(&self) -> f32 {
        lock(&self.ring).level
    }
}

/// One `build_input_stream` per sample type. Generic so the sample-format match
/// above is a table rather than a dozen copies of the same closure, each with
/// its own chance of a wrong divisor.
fn build<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    ring: &Arc<Mutex<Ring>>,
    channels: usize,
    format: cpal::SampleFormat,
) -> anyhow::Result<cpal::Stream>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    // `build_input_stream::<T>` sends `T::FORMAT` to the driver, so an arm whose
    // type disagrees with the pattern it was matched on asks the device for a
    // different format than the caller believes — `I24 => build::<i32>` compiles
    // and produces silent 256x-scaled garbage. Threading the matched format
    // through makes that a startup error with a legible message instead.
    anyhow::ensure!(
        T::FORMAT == format,
        "sample-format table bug: the {format:?} arm builds {:?}",
        T::FORMAT
    );
    let sink = ring.clone();
    // Owned by this closure alone, so it needs no lock. It grows to the device's
    // callback size within the first few callbacks and is reused thereafter, so
    // steady-state capture allocates nothing.
    let mut conv: Vec<f32> = Vec::new();
    Ok(device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            convert_into(data, &mut conv);
            lock(&sink).push(&conv, channels);
        },
        |e| eprintln!("parlad: audio stream error: {e}"),
        None,
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_interleaved_channels() {
        // Stereo: L=1.0 R=0.0 => 0.5, then L=0.0 R=1.0 => 0.5
        assert_eq!(downmix_to_mono(&[1.0, 0.0, 0.0, 1.0], 2), vec![0.5, 0.5]);
    }

    #[test]
    fn downmix_is_a_passthrough_for_mono() {
        assert_eq!(downmix_to_mono(&[0.1, 0.2, 0.3], 1), vec![0.1, 0.2, 0.3]);
    }

    #[test]
    fn downmix_ignores_a_trailing_partial_frame() {
        // Three samples across two channels is one frame plus a stray sample.
        assert_eq!(downmix_to_mono(&[1.0, 0.0, 1.0], 2), vec![0.5]);
    }

    #[test]
    fn downmix_with_a_nonsense_channel_count_does_not_panic() {
        // `chunks_exact(0)` panics, and this runs on the audio thread. The
        // `<= 1` guard is what keeps a driver reporting zero channels off that
        // path, so it is a guard, not an optimisation.
        assert_eq!(downmix_to_mono(&[1.0, 2.0], 0), vec![1.0, 2.0]);
    }

    const BIG: usize = 1 << 17;

    fn ring(capacity: usize) -> Ring {
        Ring::new(capacity, TARGET_RATE)
    }

    #[test]
    fn push_downmixes_and_stores_at_the_device_rate() {
        let mut r = Ring::new(BIG, 48_000);
        // 3 stereo frames at 48 kHz => 3 mono samples, not resampled.
        r.push(&[1.0, 0.0, 1.0, 0.0, 1.0, 0.0], 2);
        let rec = r.take_since_mark();
        assert_eq!(rec.samples, vec![0.5, 0.5, 0.5]);
        assert_eq!(rec.rate, 48_000);
    }

    #[test]
    fn take_since_mark_returns_only_audio_recorded_after_the_mark() {
        let mut r = ring(BIG);
        r.push(&[1.0, 2.0], 1);
        r.mark();
        r.push(&[3.0, 4.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![3.0, 4.0]);
    }

    #[test]
    fn take_since_mark_empties_the_ring() {
        let mut r = ring(BIG);
        r.push(&[1.0, 2.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![1.0, 2.0]);
        // A second take with no fresh audio must be empty, not a repeat.
        assert!(r.take_since_mark().samples.is_empty());
    }

    #[test]
    fn a_take_resets_the_mark_so_the_next_dictation_starts_clean() {
        // Without the reset the stale mark points past the end of a freshly
        // cleared ring, and the next dictation comes back truncated or empty.
        let mut r = ring(BIG);
        r.push(&[1.0, 2.0], 1);
        r.mark();
        r.push(&[3.0, 4.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![3.0, 4.0]);
        r.push(&[5.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![5.0]);
    }

    #[test]
    fn take_without_a_mark_returns_everything_captured() {
        let mut r = ring(BIG);
        r.push(&[1.0, 2.0, 3.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn an_overflow_drops_the_oldest_audio_and_moves_the_mark_with_it() {
        // The whole point of the mark shift: audio recorded after `mark()`
        // must survive an overflow intact, however much older audio is dropped.
        let mut r = ring(4);
        r.push(&[1.0, 2.0, 3.0], 1);
        r.mark();
        r.push(&[4.0, 5.0, 6.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![4.0, 5.0, 6.0]);
    }

    #[test]
    fn an_overflow_past_the_mark_keeps_what_is_left_rather_than_panicking() {
        // A dictation longer than the ring can't happen behind the watchdog,
        // but if it did, the tail must come back — not an underflow panic.
        let mut r = ring(4);
        r.push(&[1.0, 2.0], 1);
        r.mark();
        r.push(&[3.0, 4.0, 5.0, 6.0, 7.0, 8.0], 1);
        assert_eq!(r.take_since_mark().samples, vec![5.0, 6.0, 7.0, 8.0]);
    }

    #[test]
    fn level_is_the_most_recent_chunk_not_a_running_total() {
        let mut r = ring(BIG);
        r.push(&[0.5; 32], 1);
        assert!((r.level - 0.5).abs() < 1e-6, "level was {}", r.level);
        r.push(&[0.0; 32], 1);
        assert!(r.level < 1e-6, "silence left level at {}", r.level);
    }

    #[test]
    fn level_measures_the_stored_mono_audio_not_the_raw_device_input() {
        // A mono mic in a stereo stream: one channel carries the signal, the
        // other is silent. The interleaved RMS is 1/sqrt(2) of the downmix's,
        // so a meter reading the raw callback under-reports by 30%.
        let mut r = ring(BIG);
        let stereo: Vec<f32> = [1.0f32, 0.0].iter().cycle().take(96).copied().collect();
        r.push(&stereo, 2);
        assert!((r.level - 0.5).abs() < 1e-6, "level was {}", r.level);
    }

    #[test]
    fn the_conversion_scratch_carries_nothing_from_the_previous_callback() {
        // The stream closure reuses one buffer for the process lifetime. Without
        // the clear it grows without bound and every callback re-pushes all the
        // audio before it — measured on hardware as 3 s of speech filling the
        // whole 300 s ring, which whisper then hallucinated over. This is the
        // regression guard for that; the other two scratch clears are pinned by
        // the capacity test below.
        let mut out = Vec::new();
        convert_into(&[i16::MAX, 0, i16::MIN, 0, i16::MAX], &mut out);
        assert_eq!(out.len(), 5);
        assert!((out[0] - 1.0).abs() < 1e-4, "conversion is wrong: {out:?}");
        convert_into(&[0i16, 0], &mut out);
        assert_eq!(out, vec![0.0, 0.0], "the previous callback's tail survived");
    }

    #[test]
    fn every_format_arm_uses_the_type_that_matches_its_pattern() {
        // `build_input_stream::<T>` passes `T::FORMAT` to the raw builder, so a
        // transposed arm (`I24 => build::<i32>`) compiles and silently asks the
        // device for the wrong format. This mirrors the table in `start` and is
        // the only defect class in it that a machine with no sound card can
        // catch — `build`'s own `ensure!` catches the rest, but only at startup.
        fn pins<T: cpal::SizedSample>(f: cpal::SampleFormat) {
            assert_eq!(T::FORMAT, f);
        }
        use cpal::SampleFormat as F;
        pins::<f32>(F::F32);
        pins::<f64>(F::F64);
        pins::<i8>(F::I8);
        pins::<i16>(F::I16);
        pins::<cpal::I24>(F::I24);
        pins::<i32>(F::I32);
        pins::<i64>(F::I64);
        pins::<u8>(F::U8);
        pins::<u16>(F::U16);
        pins::<cpal::U24>(F::U24);
        pins::<u32>(F::U32);
        pins::<u64>(F::U64);
    }

    #[test]
    fn a_full_ring_never_reallocates_on_the_audio_thread() {
        // The realtime half of the VecDeque fix. Reallocating 19 MB inside a
        // 2.7 ms callback is an xrun; `clear()` on take must keep the
        // allocation, and the headroom must cover the append-then-trim window.
        // Deterministic, unlike anything that would time the drain itself.
        let mut r = ring(64);
        // One callback to size the scratch buffer. It cannot be reserved up
        // front — the device's callback length is not known until the stream
        // exists — so the guarantee is steady-state, from the second callback on.
        r.push(&[0.5; 48], 2);
        let (samples, mono) = (r.samples.capacity(), r.mono.capacity());
        for i in 0..200 {
            r.push(&[0.5; 48], 2);
            if i % 50 == 0 {
                r.mark();
                r.take_since_mark();
            }
        }
        assert!(r.samples.len() <= 64, "ring overran its capacity");
        assert_eq!(r.samples.capacity(), samples, "the ring reallocated");
        assert_eq!(r.mono.capacity(), mono, "the downmix scratch reallocated");
    }

    #[test]
    fn a_poisoned_ring_still_yields_its_audio() {
        // `lock` recovers rather than propagating: a panic anywhere near the
        // ring must not turn every later dictation into a panicking daemon.
        let shared = Arc::new(Mutex::new(Ring::new(BIG, TARGET_RATE)));
        lock(&shared).push(&[1.0, 2.0], 1);
        let poisoner = shared.clone();
        std::thread::spawn(move || {
            let _g = poisoner.lock().unwrap();
            panic!("poison the mutex");
        })
        .join()
        .unwrap_err();
        assert!(shared.is_poisoned());
        assert_eq!(lock(&shared).take_since_mark().samples, vec![1.0, 2.0]);
    }

    fn sine(hz: f64, rate: u32, secs: f64) -> Vec<f32> {
        let n = (rate as f64 * secs) as usize;
        (0..n)
            .map(|i| (0.5 * (2.0 * std::f64::consts::PI * hz * i as f64 / rate as f64).sin()) as f32)
            .collect()
    }

    /// RMS ignoring the first and last 20 ms, where the zero padding fades in.
    fn inner_rms(x: &[f32], rate: u32) -> f32 {
        let edge = rate as usize / 50;
        parla_core::text::rms(&x[edge..x.len() - edge])
    }

    fn level_ratio(hz: f64, from: u32) -> f32 {
        let x = sine(hz, from, 1.0);
        inner_rms(&resample_to_16k(&x, from), TARGET_RATE) / inner_rms(&x, from)
    }

    #[test]
    fn resampled_duration_is_exact() {
        assert_eq!(resample_to_16k(&vec![0.0; 480_000], 48_000).len(), 160_000);
        assert_eq!(resample_to_16k(&vec![0.0; 441_000], 44_100).len(), 160_000);
        assert_eq!(resample_to_16k(&vec![0.0; 8_000], 8_000).len(), 16_000);
        // 101 / 3 = 33.67: the length rounds, it does not truncate.
        assert_eq!(resample_to_16k(&[0.0; 101], 48_000).len(), 34);
    }

    #[test]
    fn a_16k_device_is_not_resampled() {
        let x = sine(440.0, TARGET_RATE, 0.1);
        assert_eq!(resample_to_16k(&x, TARGET_RATE), x);
    }

    #[test]
    fn the_pass_band_keeps_its_level() {
        for from in [48_000, 44_100, 8_000] {
            let r = level_ratio(1_000.0, from);
            assert!((r - 1.0).abs() < 0.01, "{from} Hz: ratio {r}");
        }
    }

    #[test]
    fn a_44100_recording_lands_on_the_16k_sample_grid() {
        // 44.1 kHz has 160 sub-sample phases; RMS cannot see a wrong one, the
        // waveform can. The filter is symmetric, so there is no delay.
        let y = resample_to_16k(&sine(1_000.0, 44_100, 1.0), 44_100);
        let ideal = sine(1_000.0, TARGET_RATE, 1.0);
        let edge = TARGET_RATE as usize / 50;
        let worst = (edge..y.len() - edge).map(|i| (y[i] - ideal[i]).abs()).fold(0.0, f32::max);
        assert!(worst < 0.005, "worst error {worst}");
    }

    #[test]
    fn content_above_8k_does_not_alias_into_the_output() {
        // Linear interpolation folded a 10 kHz tone to 6 kHz at near full level.
        let r = level_ratio(10_000.0, 48_000);
        assert!(r < 0.01, "ratio {r}");
    }

    #[test]
    fn callback_size_no_longer_changes_the_recording() {
        let x = sine(1_000.0, 48_000, 1.0);
        let take = |chunk: usize| {
            let mut r = Ring::new(BIG, 48_000);
            for c in x.chunks(chunk) {
                r.push(c, 1);
            }
            let rec = r.take_since_mark();
            resample_to_16k(&rec.samples, rec.rate)
        };
        assert_eq!(take(128), take(1024));
    }

    #[test]
    fn the_ring_is_sized_by_the_watchdog_plus_one_tick() {
        assert_eq!(capacity_for(48_000, Duration::from_secs(30)), 48_000 * 31);
        let max = 48_000 * (RING_SECS as usize + WATCHDOG_TICK_SECS as usize);
        assert_eq!(capacity_for(48_000, Duration::from_secs(10_000)), max);
        assert_eq!(capacity_for(48_000, Duration::ZERO), 48_000 * 2);
    }
}
