use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::FromSample;
use std::sync::{Arc, Mutex, MutexGuard};

pub const TARGET_RATE: u32 = 16_000;
/// Ring buffer capacity: 5 minutes at 16 kHz. A dictation longer than the
/// watchdog can't happen, so this only ever holds the tail.
const CAPACITY: usize = TARGET_RATE as usize * 300;

/// Average interleaved channels down to mono. A trailing partial frame is
/// dropped rather than averaged against silence.
pub fn downmix_to_mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks_exact(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

/// Linear resample. No device offers 16 kHz directly — CoreAudio and WASAPI
/// give 44.1/48 kHz, and cpal 0.18 explicitly prefers them.
// ponytail: linear interpolation, not a windowed-sinc — whisper's own frontend
// low-passes to a mel spectrogram, so the aliasing is inaudible to it. Swap in
// `rubato` if measured WER ever shows a difference.
pub fn resample_linear(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    // Both early-outs are behaviour-neutral — the general path below already
    // yields the same answer for an empty input (`out_len` is 0, so the loop
    // never runs) and for an equal rate (`frac` is always 0). They are kept as
    // an underflow guard on `input.len() - 1` and to skip a per-sample float
    // loop on the audio thread, not as behaviour, so no test can distinguish
    // them from their absence. Mutating either produces an equivalent mutant.
    if input.is_empty() {
        return Vec::new();
    }
    if from == to {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let out_len = (input.len() as f64 / ratio).floor() as usize;
    (0..out_len)
        .map(|i| {
            let pos = i as f64 * ratio;
            let a = pos.floor() as usize;
            let b = (a + 1).min(input.len() - 1);
            let frac = (pos - a as f64) as f32;
            input[a] * (1.0 - frac) + input[b] * frac
        })
        .collect()
}

/// The capture ring, split out from `Capture` so that every behaviour below can
/// be tested without a sound card — `Capture`'s methods are a lock plus a
/// delegation and nothing else. `capacity` is a field rather than the `CAPACITY`
/// constant purely so the overflow tests can use a four-sample ring instead of a
/// five-minute one.
struct Ring {
    samples: Vec<f32>,
    mark: usize,
    level: f32,
    capacity: usize,
}

impl Ring {
    fn new(capacity: usize) -> Self {
        Self {
            samples: Vec::with_capacity(capacity),
            mark: 0,
            level: 0.0,
            capacity,
        }
    }

    /// One device callback's worth of interleaved samples, at the device's own
    /// rate. Runs on the audio thread.
    fn push(&mut self, interleaved: &[f32], channels: usize, rate: u32) {
        let mono = downmix_to_mono(interleaved, channels);
        let resampled = resample_linear(&mono, rate, TARGET_RATE);
        self.level = parla_core::text::rms(&resampled);
        self.samples.extend_from_slice(&resampled);
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
        let out = self.samples[self.mark.min(self.samples.len())..].to_vec();
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
            cpal::SampleFormat::F32 => build::<f32>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::F64 => build::<f64>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::I8 => build::<i8>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::I16 => build::<i16>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::I24 => build::<cpal::I24>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::I32 => build::<i32>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::I64 => build::<i64>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::U8 => build::<u8>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::U16 => build::<u16>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::U24 => build::<cpal::U24>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::U32 => build::<u32>(&device, config, &ring, channels, rate),
            cpal::SampleFormat::U64 => build::<u64>(&device, config, &ring, channels, rate),
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
) -> anyhow::Result<cpal::Stream>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    let sink = ring.clone();
    Ok(device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            let f: Vec<f32> = data.iter().map(|s| f32::from_sample_(*s)).collect();
            lock(&sink).push(&f, channels, rate);
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
