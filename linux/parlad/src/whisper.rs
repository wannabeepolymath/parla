use parla_core::config::Config;
use parla_core::text::strip_non_speech;
use std::path::{Path, PathBuf};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// Whisper's own default (`whisper.cpp:5953`), re-asserted explicitly rather
/// than left to omission so that changing it is a visible diff instead of an
/// invisible addition. Temperature fallback is the only guardrail against
/// greedy decoding falling into a repetition loop; the macOS build produced
/// "same sentence × 28" in the wild the one time it was disabled. Zero here
/// turns it off.
const TEMPERATURE_INC: f32 = 0.2;

/// Zero means "use the model's full encoder window" (`whisper.cpp:921`).
/// Restricting it to the clip length collapses one-word clips into garbage and
/// triggers multi-second retry storms, so it is pinned rather than tuned.
const AUDIO_CTX_FULL_WINDOW: i32 = 0;

// `FullParams` exposes no getters, so neither setting can be read back and
// asserted at runtime. Pinning them as constants and checking them here makes
// the regression `error: evaluation of constant value failed` at build time
// rather than a test that someone could delete alongside the setter.
const _: () = {
    assert!(
        TEMPERATURE_INC > 0.0,
        "temperature_inc of 0 disables whisper's only guardrail against greedy-decode repetition loops"
    );
    assert!(
        AUDIO_CTX_FULL_WINDOW == 0,
        "a non-zero audio_ctx restricts whisper's encoder window to the clip length"
    );
};

/// Pure, so it can be tested without mutating process env (cargo runs tests on
/// parallel threads, where set_var races every other test). An exported-but-empty
/// XDG_DATA_HOME counts as unset, per the XDG basedir spec — otherwise it yields
/// a *relative* model path and a daemon whose CWD is `/` looks in the wrong
/// place. Deliberately the same shape as `config::config_path_from`; keep them
/// consistent.
pub fn default_model_path(xdg_data_home: Option<&std::ffi::OsStr>, home: &std::ffi::OsStr) -> PathBuf {
    let base = match xdg_data_home.filter(|x| !x.is_empty()) {
        Some(x) => PathBuf::from(x),
        None => PathBuf::from(home).join(".local/share"),
    };
    base.join("parla/models/ggml-base.en.bin")
}

pub fn model_path(cfg: &Config) -> PathBuf {
    if let Some(p) = &cfg.whisper_model {
        return p.clone();
    }
    default_model_path(
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        &std::env::var_os("HOME").unwrap_or_default(),
    )
}

/// Dictionary terms become whisper's initial_prompt, which biases decoding
/// toward those spellings.
pub fn initial_prompt(dictionary: &[String]) -> Option<String> {
    if dictionary.is_empty() {
        None
    } else {
        Some(dictionary.join(", "))
    }
}

/// Leave headroom for the rest of the daemon, same as the macOS build: never
/// fewer than 4 (whisper is unusably slow below that) and never more than 8
/// (past which base.en stops scaling and just starves the tokio runtime).
fn threads(available: usize) -> i32 {
    available.saturating_sub(2).clamp(4, 8) as i32
}

/// Whisper returns one string per segment, each already carrying its own
/// leading space, so they concatenate with no separator. The trim is what makes
/// `strip_non_speech` see `"[BLANK_AUDIO]"` rather than `" [BLANK_AUDIO]"`, and
/// an empty return is Task 8's "Nothing heard" signal — so this is the function
/// that decides whether silence reaches the clipboard.
fn assemble(segments: &[String]) -> String {
    strip_non_speech(segments.concat().trim())
}

pub struct Transcriber {
    ctx: WhisperContext,
}

// Task 8 shares `Transcriber` across tokio tasks inside an `Arc<App>`.
const _: () = {
    const fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Transcriber>();
};

impl Transcriber {
    pub fn new(model: &Path) -> anyhow::Result<Self> {
        if !model.exists() {
            anyhow::bail!("whisper model not found at {}", model.display());
        }
        // `new_with_params` takes `AsRef<Path>`, so the path goes through as
        // bytes — no `to_string_lossy` to mangle a non-UTF-8 model path.
        let ctx = WhisperContext::new_with_params(model, WhisperContextParameters::default())?;
        Ok(Self { ctx })
    }

    pub fn transcribe(&self, samples: &[f32], initial_prompt: Option<&str>) -> String {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_special(false);
        params.set_no_timestamps(true);
        params.set_n_threads(threads(
            std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4),
        ));
        params.set_temperature_inc(TEMPERATURE_INC);
        params.set_audio_ctx(AUDIO_CTX_FULL_WINDOW);
        if let Some(p) = initial_prompt {
            params.set_initial_prompt(p);
        }

        let mut state = match self.ctx.create_state() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("parlad: whisper state failed: {e}");
                return String::new();
            }
        };
        if let Err(e) = state.full(params, samples) {
            eprintln!("parlad: whisper failed: {e}");
            return String::new();
        }

        let mut segments = Vec::new();
        for seg in state.as_iter() {
            // `to_str_lossy`, not `to_str`: one bad byte would otherwise drop
            // the whole segment, losing a sentence of the user's dictation with
            // nothing to show for it. A null pointer is still reported.
            match seg.to_str_lossy() {
                Ok(s) => segments.push(s.into_owned()),
                Err(e) => eprintln!("parlad: whisper segment {} unreadable: {e}", seg.segment_index()),
            }
        }
        assemble(&segments)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parla_core::config::Config;

    #[test]
    fn model_path_prefers_the_configured_value() {
        let cfg = Config {
            whisper_model: Some("/models/custom.bin".into()),
            ..Default::default()
        };
        assert_eq!(model_path(&cfg), std::path::PathBuf::from("/models/custom.bin"));
    }

    #[test]
    fn model_path_defaults_under_xdg_data_home() {
        // Takes the env values as arguments rather than calling set_var: cargo
        // runs tests on parallel threads, and mutating process env from one of
        // them races every other test that reads it.
        let p = default_model_path(Some("/tmp/xdgdata".as_ref()), "/home/u".as_ref());
        assert_eq!(p, std::path::PathBuf::from("/tmp/xdgdata/parla/models/ggml-base.en.bin"));
    }

    #[test]
    fn model_path_falls_back_to_home_local_share() {
        let p = default_model_path(None, "/home/u".as_ref());
        assert_eq!(p, std::path::PathBuf::from("/home/u/.local/share/parla/models/ggml-base.en.bin"));
    }

    #[test]
    fn empty_xdg_data_home_falls_back_like_an_unset_one() {
        // Same rule as config::config_path_from — an exported-but-empty var is
        // unset per the XDG spec, and treating it as set yields a relative path.
        assert_eq!(
            default_model_path(Some("".as_ref()), "/home/u".as_ref()),
            default_model_path(None, "/home/u".as_ref())
        );
    }

    #[test]
    fn missing_model_is_an_error_naming_the_path_it_looked_in() {
        // whisper-rs already errors on a missing file, so the guard exists only
        // for the message: "Failed to create WhisperContext" leaves a user with
        // no idea *where* to put the model, and this is a daemon that refuses
        // to start. Asserting the path is what makes the guard load-bearing.
        // `.err()` rather than `.unwrap_err()`: the latter needs
        // `Transcriber: Debug`, which would mean deriving Debug on a live
        // whisper context just to write this assertion.
        let err = Transcriber::new(std::path::Path::new("/nonexistent/model.bin"))
            .err()
            .expect("a missing model must fail, not load")
            .to_string();
        assert!(err.contains("/nonexistent/model.bin"), "unhelpful error: {err}");
    }

    #[test]
    fn initial_prompt_joins_dictionary_terms() {
        assert_eq!(initial_prompt(&["Parla".into(), "wlroots".into()]), Some("Parla, wlroots".to_string()));
        assert_eq!(initial_prompt(&[]), None);
    }

    #[test]
    fn thread_count_leaves_headroom_but_stays_inside_its_floor_and_ceiling() {
        assert_eq!(threads(16), 8); // 14 clamped down to the ceiling
        assert_eq!(threads(10), 8); // exactly at the ceiling
        assert_eq!(threads(9), 7); // inside the band, headroom applied
        assert_eq!(threads(6), 4); // exactly at the floor
        assert_eq!(threads(2), 4); // a dual-core still gets the floor
        assert_eq!(threads(0), 4); // and so does an unknown core count
    }

    #[test]
    fn segments_concatenate_with_no_separator_and_are_trimmed() {
        // Whisper pads each segment with its own leading space; inserting one
        // here would double it, and joining without the trim leaves the
        // transcript starting with whitespace.
        assert_eq!(
            assemble(&[" Hello there.".into(), " Second sentence.".into()]),
            "Hello there. Second sentence."
        );
    }

    #[test]
    fn a_transcript_of_nothing_but_markers_becomes_empty() {
        // Task 8 keys "Nothing heard" off the empty string, so this is the
        // guard that stops "[BLANK_AUDIO]" reaching the clipboard.
        assert_eq!(assemble(&[" [BLANK_AUDIO]".into()]), "");
        assert_eq!(assemble(&["  ".into()]), "");
        assert_eq!(assemble(&[]), "");
        // ...but a marker embedded in real speech is left alone.
        assert_eq!(assemble(&[" hello [MUSIC] world".into()]), "hello [MUSIC] world");
    }
}
