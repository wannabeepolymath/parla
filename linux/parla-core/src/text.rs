/// Root mean square of a sample buffer. Empty buffer is 0.0, not NaN.
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f32 = samples.iter().map(|s| s * s).sum();
    (sum / samples.len() as f32).sqrt()
}

/// Whisper hallucinates ("Thank you.", "you") on sub-half-second or silent
/// buffers. Gate transcription on a floor of duration AND loudness.
/// 6400 samples is ~0.4s at 16 kHz; RMS 1e-4 is orders of magnitude below real
/// speech, so this only rejects near-digital-silence.
// ponytail: fixed thresholds, no VAD — bump if quiet speech gets dropped.
pub fn audio_worth_transcribing(sample_count: usize, rms: f32) -> bool {
    sample_count >= 6400 && rms >= 1e-4
}

/// Whisper emits bracketed markers on non-speech audio — "[BLANK_AUDIO]",
/// "[MUSIC]", "(silence)", "*sigh*" — which must never be typed or pasted.
/// A transcript that is nothing but such markers becomes "".
pub fn strip_non_speech(text: &str) -> String {
    let is_marker = |w: &str| {
        let close = match w.chars().next() {
            Some('[') => ']',
            Some('(') => ')',
            Some('*') => '*',
            _ => return false,
        };
        w.chars().count() > 1 && w.ends_with(close)
    };
    let words: Vec<&str> = text.split(' ').filter(|w| !w.is_empty()).collect();
    if !words.is_empty() && words.iter().all(|w| is_marker(w)) {
        return String::new();
    }
    text.to_string()
}

/// Collapse every whitespace run that CONTAINS a newline into a single space,
/// then trim. Runs without a newline (aligned spaces) are left alone. Used for
/// terminals and chat apps, where a bare newline submits.
pub fn flatten_newlines(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if !c.is_whitespace() {
            out.push(c);
            continue;
        }
        // Consume the whole whitespace run, noting whether it held a newline.
        let mut run = String::from(c);
        while let Some(&n) = chars.peek() {
            if !n.is_whitespace() {
                break;
            }
            run.push(n);
            chars.next();
        }
        if run.contains('\n') {
            out.push(' ');
        } else {
            out.push_str(&run);
        }
    }
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rms_of_silence_is_zero() {
        assert_eq!(rms(&[0.0; 100]), 0.0);
        assert_eq!(rms(&[]), 0.0);
    }

    #[test]
    fn rms_of_constant_signal_is_its_magnitude() {
        assert!((rms(&[0.5; 100]) - 0.5).abs() < 1e-6);
        assert!((rms(&[-0.5; 100]) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn audio_floor_rejects_short_or_silent_buffers() {
        // Whisper hallucinates ("Thank you.") on these — never send them.
        assert!(!audio_worth_transcribing(1000, 0.2));   // too short
        assert!(!audio_worth_transcribing(64000, 1e-6)); // near-digital-silence
        assert!(audio_worth_transcribing(64000, 0.2));   // real speech
        assert!(audio_worth_transcribing(6400, 1e-4));   // exactly at both floors
    }

    #[test]
    fn strips_transcripts_that_are_only_non_speech_markers() {
        assert_eq!(strip_non_speech("[BLANK_AUDIO]"), "");
        assert_eq!(strip_non_speech("(silence)"), "");
        assert_eq!(strip_non_speech("*sigh*"), "");
        assert_eq!(strip_non_speech("[MUSIC] [BLANK_AUDIO]"), "");
    }

    #[test]
    fn keeps_real_speech_containing_a_marker() {
        assert_eq!(strip_non_speech("hello [MUSIC] world"), "hello [MUSIC] world");
        assert_eq!(strip_non_speech("hello world"), "hello world");
    }

    #[test]
    fn single_character_wrappers_are_not_markers() {
        // "*" alone is one char — the Swift rule requires count > 1.
        assert_eq!(strip_non_speech("*"), "*");
    }

    #[test]
    fn flattens_only_whitespace_runs_containing_a_newline() {
        assert_eq!(flatten_newlines("one\ntwo"), "one two");
        assert_eq!(flatten_newlines("one\n\n  two"), "one two");
        assert_eq!(flatten_newlines("  padded  \n  x  "), "padded x");
        // A run of spaces with no newline is left alone.
        assert_eq!(flatten_newlines("a    b"), "a    b");
    }
}
