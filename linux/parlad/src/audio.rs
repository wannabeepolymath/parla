use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::FromSample;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

pub const TARGET_RATE: u32 = 16_000;
/// Ring buffer span: 5 minutes. `Session::new` clamps the watchdog to this, so
/// a dictation longer than the ring can't happen and the buffer only ever holds
/// the tail of the idle audio before one. That premise used to be falsifiable
/// from config.toml — `watchdog_secs = 600` dropped the front of a long
/// dictation with nothing to show for it — which is why the clamp exists.
pub const RING_SECS: u64 = 300;
/// Ring buffer capacity at 16 kHz.
const CAPACITY: usize = TARGET_RATE as usize * RING_SECS as usize;
/// Slack above `capacity` so that the `extend` in `push` never reallocates: the
/// ring is trimmed *after* appending, so it transiently holds one callback more
/// than its capacity. One second is ~60x the largest realistic callback, and
/// costs 64 kB against the ring's 19 MB. Reallocating 19 MB on the realtime
/// audio thread would be an xrun.
const CALLBACK_HEADROOM: usize = TARGET_RATE as usize;

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

/// Linear resample. No device offers 16 kHz directly — CoreAudio and WASAPI
/// give 44.1/48 kHz, and cpal 0.18 explicitly prefers them.
// ponytail: linear interpolation, not a windowed-sinc — whisper's own frontend
// low-passes to a mel spectrogram, so the aliasing is inaudible to it. Swap in
// `rubato` if measured WER ever shows a difference.
//
// Allocating form, same rationale as `downmix_to_mono` above.
#[allow(dead_code)]
pub fn resample_linear(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    let mut out = Vec::new();
    resample_linear_into(input, from, to, &mut out);
    out
}

/// The real implementations write into a caller-owned buffer, because the only
/// production caller is the realtime audio thread and it must not allocate. The
/// returning versions above are thin wrappers for everywhere else.
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

fn resample_linear_into(input: &[f32], from: u32, to: u32, out: &mut Vec<f32>) {
    out.clear();
    // Both early-outs are behaviour-neutral — the general path below already
    // yields the same answer for an empty input (`out_len` is 0, so the loop
    // never runs) and for an equal rate (`frac` is always 0). They are kept as
    // an underflow guard on `input.len() - 1` and to skip a per-sample float
    // loop on the audio thread, not as behaviour, so no test can distinguish
    // them from their absence. Mutating either produces an equivalent mutant.
    if input.is_empty() {
        return;
    }
    if from == to {
        out.extend_from_slice(input);
        return;
    }
    let ratio = from as f64 / to as f64;
    let out_len = (input.len() as f64 / ratio).floor() as usize;
    out.extend((0..out_len).map(|i| {
        let pos = i as f64 * ratio;
        let a = pos.floor() as usize;
        let b = (a + 1).min(input.len() - 1);
        let frac = (pos - a as f64) as f32;
        input[a] * (1.0 - frac) + input[b] * frac
    }));
}

/// The capture ring, split out from `Capture` so that every behaviour below can
/// be tested without a sound card — `Capture`'s methods are a lock plus a
/// delegation and nothing else. `capacity` is a field rather than the `CAPACITY`
/// constant purely so the overflow tests can use a four-sample ring instead of a
/// five-minute one.
struct Ring {
    /// `VecDeque`, not `Vec`. The trim below runs on the realtime audio thread
    /// on every callback once the ring is full — which is the daemon's resting
    /// state, since `take_since_mark` empties it and 300 s of idle refills it.
    /// `Vec::drain(..excess)` is O(len − excess), i.e. a 19 MB memmove per
    /// callback: measured at 485 µs mean / 4.28 ms worst on Apple silicon,
    /// against a 2.7 ms callback budget at 48 kHz/128. A front drain on a
    /// `VecDeque` is O(excess) instead.
    samples: VecDeque<f32>,
    /// Scratch, reused every callback so the audio thread never allocates. Two
    /// buffers rather than one because the resampler reads the downmix while
    /// writing its own output.
    mono: Vec<f32>,
    resampled: Vec<f32>,
    mark: usize,
    level: f32,
    capacity: usize,
}

impl Ring {
    fn new(capacity: usize) -> Self {
        Self {
            samples: VecDeque::with_capacity(capacity + CALLBACK_HEADROOM),
            mono: Vec::new(),
            resampled: Vec::new(),
            mark: 0,
            level: 0.0,
            capacity,
        }
    }

    /// One device callback's worth of interleaved samples, at the device's own
    /// rate. Runs on the audio thread: no allocation, no syscall, bounded work.
    fn push(&mut self, interleaved: &[f32], channels: usize, rate: u32) {
        downmix_to_mono_into(interleaved, channels, &mut self.mono);
        resample_linear_into(&self.mono, rate, TARGET_RATE, &mut self.resampled);
        self.level = parla_core::text::rms(&self.resampled);
        self.samples.extend(self.resampled.iter().copied());
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

    fn take_since_mark(&mut self) -> Vec<f32> {
        // `min` is belt-and-braces: `mark` is only ever set to a length, and the
        // overflow path decrements both together, so it cannot exceed `len`
        // today. Kept because returning too much audio is a better failure than
        // panicking the daemon on a slice out of range.
        let out = self
            .samples
            .range(self.mark.min(self.samples.len())..)
            .copied()
            .collect();
        // `clear` keeps the allocation, so the audio thread's next `extend`
        // still cannot reallocate.
        self.samples.clear();
        self.mark = 0;
        out
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
    pub fn start() -> anyhow::Result<Self> {
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

        let ring = Arc::new(Mutex::new(Ring::new(CAPACITY)));

        // cpal 0.18's default-config heuristic ranks F32 > F64 > descending
        // integer widths, so it can hand back I32 or I24 on high-precision
        // hardware. Every format with a sized Rust sample type is accepted; the
        // conversion is `FromSample`, not a hand-rolled divisor, so 24-bit —
        // which is stored in an i32 but only 24 bits wide — scales correctly.
        let stream = match format {
            cpal::SampleFormat::F32 => build::<f32>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::F64 => build::<f64>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::I8 => build::<i8>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::I16 => build::<i16>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::I24 => {
                build::<cpal::I24>(&device, config, &ring, channels, rate, format)
            }
            cpal::SampleFormat::I32 => build::<i32>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::I64 => build::<i64>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::U8 => build::<u8>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::U16 => build::<u16>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::U24 => {
                build::<cpal::U24>(&device, config, &ring, channels, rate, format)
            }
            cpal::SampleFormat::U32 => build::<u32>(&device, config, &ring, channels, rate, format),
            cpal::SampleFormat::U64 => build::<u64>(&device, config, &ring, channels, rate, format),
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

    /// Everything captured since the last `mark()`, as 16 kHz mono f32.
    pub fn take_since_mark(&self) -> Vec<f32> {
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
    rate: u32,
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
            lock(&sink).push(&conv, channels, rate);
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
    fn resample_halves_the_length_when_halving_the_rate() {
        let input: Vec<f32> = (0..100).map(|i| i as f32).collect();
        let out = resample_linear(&input, 32_000, 16_000);
        assert_eq!(out.len(), 50);
        assert_eq!(out[0], 0.0);
        assert_eq!(out[1], 2.0);
    }

    #[test]
    fn downmix_with_a_nonsense_channel_count_does_not_panic() {
        // `chunks_exact(0)` panics, and this runs on the audio thread. The
        // `<= 1` guard is what keeps a driver reporting zero channels off that
        // path, so it is a guard, not an optimisation.
        assert_eq!(downmix_to_mono(&[1.0, 2.0], 0), vec![1.0, 2.0]);
    }

    #[test]
    fn resample_from_44100_lands_on_the_right_length() {
        // 44.1 kHz is the one common device rate whose ratio is not a whole
        // number, so it is the only case that pins the floor in `out_len`.
        assert_eq!(resample_linear(&vec![0.0f32; 4410], 44_100, 16_000).len(), 1600);
        assert_eq!(resample_linear(&vec![0.0f32; 441], 44_100, 16_000).len(), 160);
        // A chunk that does not divide evenly must round DOWN — rounding up
        // invents a sample past the end of the input and reads it clamped.
        assert_eq!(resample_linear(&vec![0.0f32; 4411], 44_100, 16_000).len(), 1600);
    }

    #[test]
    fn resample_from_48k_to_16k_gives_a_third() {
        let input = vec![0.0f32; 4800]; // 100ms at 48kHz
        assert_eq!(resample_linear(&input, 48_000, 16_000).len(), 1600);
    }

    #[test]
    fn resample_is_a_passthrough_at_the_same_rate() {
        let input = vec![0.1, 0.2, 0.3];
        assert_eq!(resample_linear(&input, 16_000, 16_000), input);
    }

    #[test]
    fn resample_of_empty_input_is_empty() {
        assert!(resample_linear(&[], 48_000, 16_000).is_empty());
    }

    #[test]
    fn resample_interpolates_between_neighbours() {
        // Upsampling 2x should put a midpoint between each pair.
        let out = resample_linear(&[0.0, 10.0], 16_000, 32_000);
        assert_eq!(out.len(), 4);
        assert!((out[1] - 5.0).abs() < 0.01);
    }

    /// A ring at the real 16 kHz target rate, so `push` stores its input
    /// verbatim and the assertions are about the ring, not the resampler.
    fn ring(capacity: usize) -> Ring {
        Ring::new(capacity)
    }

    #[test]
    fn push_downmixes_and_resamples_before_storing() {
        let mut r = ring(CAPACITY);
        // 6 stereo frames at 48 kHz => 6 mono samples => 2 at 16 kHz.
        r.push(&[1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0], 2, 48_000);
        assert_eq!(r.take_since_mark(), vec![0.5, 0.5]);
    }

    #[test]
    fn take_since_mark_returns_only_audio_recorded_after_the_mark() {
        let mut r = ring(CAPACITY);
        r.push(&[1.0, 2.0], 1, TARGET_RATE);
        r.mark();
        r.push(&[3.0, 4.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![3.0, 4.0]);
    }

    #[test]
    fn take_since_mark_empties_the_ring() {
        let mut r = ring(CAPACITY);
        r.push(&[1.0, 2.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![1.0, 2.0]);
        // A second take with no fresh audio must be empty, not a repeat.
        assert!(r.take_since_mark().is_empty());
    }

    #[test]
    fn a_take_resets_the_mark_so_the_next_dictation_starts_clean() {
        // Without the reset the stale mark points past the end of a freshly
        // cleared ring, and the next dictation comes back truncated or empty.
        let mut r = ring(CAPACITY);
        r.push(&[1.0, 2.0], 1, TARGET_RATE);
        r.mark();
        r.push(&[3.0, 4.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![3.0, 4.0]);
        r.push(&[5.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![5.0]);
    }

    #[test]
    fn take_without_a_mark_returns_everything_captured() {
        let mut r = ring(CAPACITY);
        r.push(&[1.0, 2.0, 3.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn an_overflow_drops_the_oldest_audio_and_moves_the_mark_with_it() {
        // The whole point of the mark shift: audio recorded after `mark()`
        // must survive an overflow intact, however much older audio is dropped.
        let mut r = ring(4);
        r.push(&[1.0, 2.0, 3.0], 1, TARGET_RATE);
        r.mark();
        r.push(&[4.0, 5.0, 6.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![4.0, 5.0, 6.0]);
    }

    #[test]
    fn an_overflow_past_the_mark_keeps_what_is_left_rather_than_panicking() {
        // A dictation longer than the ring can't happen behind the watchdog,
        // but if it did, the tail must come back — not an underflow panic.
        let mut r = ring(4);
        r.push(&[1.0, 2.0], 1, TARGET_RATE);
        r.mark();
        r.push(&[3.0, 4.0, 5.0, 6.0, 7.0, 8.0], 1, TARGET_RATE);
        assert_eq!(r.take_since_mark(), vec![5.0, 6.0, 7.0, 8.0]);
    }

    #[test]
    fn level_is_the_most_recent_chunk_not_a_running_total() {
        let mut r = ring(CAPACITY);
        r.push(&[0.5; 32], 1, TARGET_RATE);
        assert!((r.level - 0.5).abs() < 1e-6, "level was {}", r.level);
        r.push(&[0.0; 32], 1, TARGET_RATE);
        assert!(r.level < 1e-6, "silence left level at {}", r.level);
    }

    #[test]
    fn level_measures_the_stored_mono_audio_not_the_raw_device_input() {
        // A mono mic in a stereo stream: one channel carries the signal, the
        // other is silent. The interleaved RMS is 1/sqrt(2) of the downmix's,
        // so a meter reading the raw callback under-reports by 30%.
        let mut r = ring(CAPACITY);
        let stereo: Vec<f32> = [1.0f32, 0.0].iter().cycle().take(96).copied().collect();
        r.push(&stereo, 2, 48_000);
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
        // One callback to size the two scratch buffers. They cannot be reserved
        // up front — the device's callback length is not known until the stream
        // exists — so the guarantee is steady-state, from the second callback on.
        r.push(&[0.5; 48], 2, 48_000);
        let (samples, mono, resampled) = (
            r.samples.capacity(),
            r.mono.capacity(),
            r.resampled.capacity(),
        );
        for i in 0..200 {
            r.push(&[0.5; 48], 2, 48_000);
            if i % 50 == 0 {
                r.mark();
                r.take_since_mark();
            }
        }
        assert!(r.samples.len() <= 64, "ring overran its capacity");
        assert_eq!(r.samples.capacity(), samples, "the ring reallocated");
        assert_eq!(r.mono.capacity(), mono, "the downmix scratch reallocated");
        assert_eq!(
            r.resampled.capacity(),
            resampled,
            "the resample scratch reallocated"
        );
    }

    #[test]
    fn a_poisoned_ring_still_yields_its_audio() {
        // `lock` recovers rather than propagating: a panic anywhere near the
        // ring must not turn every later dictation into a panicking daemon.
        let shared = Arc::new(Mutex::new(Ring::new(CAPACITY)));
        lock(&shared).push(&[1.0, 2.0], 1, TARGET_RATE);
        let poisoner = shared.clone();
        std::thread::spawn(move || {
            let _g = poisoner.lock().unwrap();
            panic!("poison the mutex");
        })
        .join()
        .unwrap_err();
        assert!(shared.is_poisoned());
        assert_eq!(lock(&shared).take_since_mark(), vec![1.0, 2.0]);
    }
}
