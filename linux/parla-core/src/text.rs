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

pub const MAX_HINT_BYTES: usize = 256;
pub const ASR_PROMPT_BYTES: usize = 2_048;

/// README "Shared prompt-selection contract" (docs/specs/whisper-2026-11).
/// Byte admission mirrors Swift `VocabularyHints.select`, plus a NUL guard
/// because whisper-rs `set_initial_prompt` panics on an interior NUL. Then
/// whole terms are admitted in saved (priority) order while their token cost
/// fits `capacity`. `count` is the model tokenizer; `usize::MAX` means
/// "untokenizable" and is never admitted.
pub fn select_prompt_terms(words: &[String], capacity: usize, count: impl Fn(&str) -> usize) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut bytes = 0;
    let candidates = words.iter().filter_map(|w| {
        let w = w.split_whitespace().collect::<Vec<_>>().join(" ");
        if w.is_empty() || w.len() > MAX_HINT_BYTES || w.contains('\0') || !seen.insert(w.to_lowercase()) {
            return None;
        }
        let cost = w.len() + if bytes == 0 { 0 } else { 2 };
        if bytes + cost > ASR_PROMPT_BYTES {
            return None;
        }
        bytes += cost;
        Some(w)
    });

    let mut used = 0usize;
    let mut selected: Vec<String> = Vec::new();
    for term in candidates {
        let cost = if selected.is_empty() { count(&term) } else { count(&format!(", {term}")) };
        if used.saturating_add(cost) <= capacity {
            used = used.saturating_add(cost);
            selected.push(term);
        }
    }
    // Tokens can merge across ", " boundaries, so re-check the real prompt.
    while !selected.is_empty() && count(&selected.join(", ")) > capacity {
        selected.pop();
    }
    selected
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_selection_matches_the_shared_fixture() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/desktop-android-v1.json");
        let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let cases = json["promptBudget"].as_array().expect("promptBudget fixture");
        assert!(!cases.is_empty());
        let strings = |v: &serde_json::Value| -> Vec<String> {
            v.as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect()
        };
        for c in cases {
            let capacity = c["capacity"].as_u64().unwrap() as usize;
            assert_eq!(select_prompt_terms(&strings(&c["words"]), capacity, str::len), strings(&c["expected"]), "{c}");
        }
    }

    #[test]
    fn prompt_selection_applies_the_byte_guards() {
        let words = vec!["x".repeat(300), "a\0b".into(), "ok".into()];
        assert_eq!(select_prompt_terms(&words, usize::MAX, str::len), vec!["ok".to_string()]);

        let many: Vec<String> = (0..400).map(|i| format!("term{i:06}")).collect();
        let selected = select_prompt_terms(&many, usize::MAX, str::len);
        assert!(!selected.is_empty());
        assert!(selected.join(", ").len() <= ASR_PROMPT_BYTES);
        assert_eq!(selected, many[..selected.len()]);
    }

    #[test]
    fn prompt_selection_admits_nothing_when_the_tokenizer_fails() {
        let words = vec!["alpha".to_string(), "beta".into()];
        assert!(select_prompt_terms(&words, 223, |_| usize::MAX).is_empty());
        assert!(select_prompt_terms(&words, usize::MAX - 1, |_| usize::MAX).is_empty());
    }

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
