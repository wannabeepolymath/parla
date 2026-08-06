mod audio;
mod deliver;
mod session;
mod socket;
mod whisper;

use parla_core::cleanup::{self, Outcome};
use parla_core::config::{config_path, Config};
use parla_core::prompt::Context;
use parla_core::text::{audio_worth_transcribing, flatten_newlines, rms};
use session::{Command, Edge, Session};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::task::JoinError;

/// The two refusals the pipeline can hand back instead of text. Named because
/// each is produced from two places and the *difference* between them is the
/// point: one sends the user to look at their microphone, the other at the log.
const NOTHING_HEARD: &str = "Nothing heard";
const TRANSCRIPTION_FAILED: &str = "Transcription failed";

/// How much of the result a notification body shows. A dictation is often a
/// paragraph; a toast is one line.
const PREVIEW_CHARS: usize = 60;

struct App {
    cfg: Config,
    capture: audio::Capture,
    transcriber: whisper::Transcriber,
}

impl App {
    /// Runs after the key is released. The whole pipeline's single notification
    /// is sent from here, and it is the only `notify` on this path.
    async fn finish(self: Arc<Self>) {
        let (summary, body) = self.dictate().await;
        // Journalled as well as shown. A notification the user looked away from
        // — or that a dead notification daemon swallowed — is otherwise the only
        // record that the dictation happened at all.
        eprintln!("parlad: {summary} — {body}");
        deliver::notify(summary, &body);
    }

    /// Transcribe, clean, deliver — and *return* what the user should be told
    /// rather than showing it. That return type is what makes "every failure
    /// path ends in clipboard text or an explicit refusal, never a silent
    /// no-op" a property of the compiler rather than of review: a new early
    /// return with nothing to say is `error[E0308]`, not a dictation that
    /// quietly evaporates.
    ///
    /// Takes `Arc<Self>` rather than `&self` so the whisper pass can be moved
    /// onto a blocking thread. `transcribe` is CPU-bound C code that runs for
    /// hundreds of milliseconds to seconds; calling it directly inside a
    /// `tokio::spawn` occupies a runtime worker for its whole duration and
    /// starves everything sharing that runtime — including the once-a-second
    /// watchdog tick, which is the one thing guaranteed to be needed if a
    /// dictation goes wrong.
    async fn dictate(self: Arc<Self>) -> (&'static str, String) {
        let samples = match worth_transcribing(self.capture.take_since_mark()) {
            Ok(s) => s,
            Err(refusal) => return ("Parla", refusal.into()),
        };

        // The one number that says whether the ring was marked on key-down:
        // an unmarked ring hands back everything since the last dictation, so a
        // three-second phrase arriving as thirty seconds is the symptom.
        eprintln!(
            "parlad: transcribing {:.1}s of audio",
            samples.len() as f32 / audio::TARGET_RATE as f32
        );

        let prompt = whisper::initial_prompt(&self.cfg.dictionary);
        let me = self.clone();
        let pass = move || me.transcriber.transcribe(&samples, prompt.as_deref());
        let raw = match transcript(tokio::task::spawn_blocking(pass).await) {
            Ok(t) => t,
            Err(refusal) => return ("Parla", refusal.into()),
        };

        let ctx = Context {
            dictionary: self.cfg.dictionary.clone(),
            snippets: self.cfg.snippets.clone(),
            app_name: None, // focus oracle arrives in M2
            selection: None,
        };
        // `clean` never returns Err: on any failure it hands back the raw
        // transcript plus a reason, so the user always gets their words.
        let out = cleanup::clean(&raw, &ctx, &self.cfg.cleanup).await;

        delivered(deliver::to_clipboard(&out.text), out)
    }
}

/// The audio the whisper pass is allowed to see, or the refusal to show
/// instead. Whisper hallucinates ("Thank you.", "you") on sub-0.4s or silent
/// buffers, so this is a guard, not a shortcut — and it sits on the data path
/// rather than beside it so that skipping it means rewiring `dictate`, not
/// deleting an `if`.
fn worth_transcribing(samples: Vec<f32>) -> Result<Vec<f32>, &'static str> {
    if audio_worth_transcribing(samples.len(), rms(&samples)) {
        Ok(samples)
    } else {
        Err(NOTHING_HEARD)
    }
}

/// Fold the whisper pass's three outcomes into either a transcript to clean or
/// the refusal to show. Separate from `dictate` because it is the part of the
/// pipeline that can be asserted without a microphone and a model, and the part
/// where a wrong answer costs the most: reporting a broken whisper as "Nothing
/// heard" sends the user to check a microphone that was working fine.
fn transcript(done: Result<anyhow::Result<String>, JoinError>) -> Result<String, &'static str> {
    match done {
        // Empty is the genuine "no speech in the audio" case — the only one.
        Ok(Ok(t)) if t.is_empty() => Err(NOTHING_HEARD),
        Ok(Ok(t)) => Ok(t),
        Ok(Err(e)) => {
            eprintln!("parlad: transcription failed: {e}");
            Err(TRANSCRIPTION_FAILED)
        }
        // The blocking task panicked. Same user-facing message, different log
        // line, and never silence.
        Err(e) => {
            eprintln!("parlad: transcription task panicked: {e}");
            Err(TRANSCRIPTION_FAILED)
        }
    }
}

/// What the user is told once the clipboard has been attempted. Takes the
/// clipboard's own `Result` as an argument so both halves can be asserted here
/// — including the half that only happens when there is no Wayland clipboard to
/// write to, which is the one path where the user's words exist nowhere else.
fn delivered(copied: anyhow::Result<()>, out: Outcome) -> (&'static str, String) {
    match copied {
        // `Outcome.failure` is surfaced rather than dropped: cleanup failing
        // means what landed on the clipboard is the raw transcript, and a user
        // who is not told will not know why their text reads like speech.
        Ok(()) => match out.failure {
            Some(why) => (
                "Parla",
                format!("Copied (raw — {why}): {}", preview(&out.text)),
            ),
            None => ("Parla", format!("Copied: {}", preview(&out.text))),
        },
        Err(e) => {
            eprintln!("parlad: clipboard failed: {e}");
            // Nothing landed anywhere. The body is the whole text, not a
            // preview — it is the only copy of the dictation left.
            ("Parla — clipboard failed", out.text)
        }
    }
}

/// One line, length-capped. Counted in `char`s, not bytes: a byte-indexed
/// truncation panics in the middle of any multibyte character, which for a
/// dictation daemon means the notification kills the task that produced it.
fn preview(text: &str) -> String {
    // `flatten_newlines` is already this codebase's answer to "make it one
    // line", and it collapses a whole whitespace run rather than turning each
    // newline into its own space.
    let one_line = flatten_newlines(text);
    if one_line.chars().count() <= PREVIEW_CHARS {
        return one_line;
    }
    format!(
        "{}…",
        one_line.chars().take(PREVIEW_CHARS - 1).collect::<String>()
    )
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cfg = Config::load(&config_path());
    if cfg.watchdog_secs == 0 {
        // Session::new clamps it. Say so rather than silently rewriting the
        // user's config — that is the same silent degradation Config::load
        // refuses to do for a malformed file.
        eprintln!("parlad: watchdog_secs = 0 does not disable the watchdog; using 1s");
    }
    // Opened once, here, and never closed: `mark()` only stamps a position in
    // an already-running ring, because opening the mic on key-down clips the
    // first syllable.
    let capture = audio::Capture::start()?;
    let transcriber = whisper::Transcriber::new(&whisper::model_path(&cfg))?;
    let watchdog = Duration::from_secs(cfg.watchdog_secs);

    let app = Arc::new(App {
        cfg,
        capture,
        transcriber,
    });
    let sess = Arc::new(Mutex::new(Session::new(watchdog)));

    // Watchdog: sway drops the --release edge if another key is pressed while
    // the hotkey is held (sway#6456), so a stop may never arrive.
    let watch = sess.clone();
    let watch_app = app.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            // Scoped so the guard is DROPPED before anything slow runs below.
            // Holding the session lock across a notification would let a wedged
            // D-Bus daemon stall every hotkey press, since the socket handler
            // needs this same lock.
            let expired = {
                let mut s = watch.lock().await;
                let e = s.watchdog_expired(Instant::now());
                if e {
                    s.handle(Command::Cancel, Instant::now());
                }
                e
            };
            if expired {
                eprintln!("parlad: watchdog fired, discarding recording");
                watch_app.capture.take_since_mark(); // drop the abandoned audio
                deliver::notify("Parla", "Recording timed out — discarded");
            }
        }
    });

    let path = socket::socket_path();
    eprintln!("parlad: listening on {}", path.display());
    socket::serve(&path, move |line| {
        let sess = sess.clone();
        let app = app.clone();
        async move {
            // The `error:` prefix is the wire contract parlactl keys off to exit
            // non-zero; keep the two in step.
            let Ok(cmd) = line.trim().parse::<Command>() else {
                return format!("error: unknown command {:?}", line.trim());
            };
            let mut s = sess.lock().await;
            if cmd == Command::Status {
                return format!("{:?}", s.state());
            }
            let edge = s.handle(cmd, Instant::now());
            drop(s); // release before the slow path

            match edge {
                Edge::Began => {
                    app.capture.mark();
                    "recording".into()
                }
                Edge::Finished => {
                    // Reply immediately so parlactl (and the compositor) never
                    // block on whisper; do the work behind it.
                    tokio::spawn(app.clone().finish());
                    "processing".into()
                }
                Edge::Cancelled => {
                    app.capture.take_since_mark(); // discard
                    "cancelled".into()
                }
                Edge::Ignored => "ignored".into(),
            }
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outcome(text: &str, failure: Option<&str>) -> Outcome {
        Outcome {
            text: text.to_string(),
            failure: failure.map(str::to_string),
        }
    }

    #[test]
    fn a_transcript_with_speech_in_it_is_passed_through() {
        assert_eq!(transcript(Ok(Ok("hello there".into()))), Ok("hello there".into()));
    }

    #[test]
    fn an_empty_transcript_is_the_only_nothing_heard() {
        assert_eq!(transcript(Ok(Ok(String::new()))), Err("Nothing heard"));
    }

    #[test]
    fn a_broken_whisper_is_never_reported_as_silence() {
        // The whole reason `transcribe` returns Result. "Nothing heard" tells
        // the user their microphone was silent; if the model actually errored,
        // they would spend the evening in their audio settings.
        let e = transcript(Ok(Err(anyhow::anyhow!("failed to decode the recording"))));
        assert_eq!(e, Err("Transcription failed"));
        assert_ne!(e, Err("Nothing heard"));
    }

    #[tokio::test]
    async fn a_panicking_whisper_task_still_tells_the_user_something() {
        // A JoinError cannot be constructed by hand, so this makes a real one.
        // Silence here would be the worst outcome in the pipeline: the key was
        // released, the audio is gone, and nothing at all happened.
        let panicked = tokio::task::spawn_blocking(|| -> anyhow::Result<String> {
            panic!("whisper segfaulted in spirit")
        })
        .await;
        assert!(panicked.is_err(), "the test needs a genuine JoinError");
        assert_eq!(transcript(panicked), Err("Transcription failed"));
    }

    #[test]
    fn a_clean_result_is_announced_as_copied() {
        assert_eq!(
            delivered(Ok(()), outcome("Ship it on Friday.", None)),
            ("Parla", "Copied: Ship it on Friday.".to_string())
        );
    }

    #[test]
    fn a_cleanup_failure_is_named_in_the_notification_rather_than_swallowed() {
        // `clean` never returns Err — it hands back the raw transcript plus a
        // reason. Dropping the reason leaves the user with unpunctuated speech
        // on the clipboard and no idea that cleanup is misconfigured.
        assert_eq!(
            delivered(Ok(()), outcome("ship it friday", Some("no API key"))),
            ("Parla", "Copied (raw — no API key): ship it friday".to_string())
        );
    }

    #[test]
    fn a_failed_clipboard_is_loud_and_hands_back_the_whole_text() {
        // The worst case in the pipeline: the words exist nowhere else, so the
        // notification is the last copy. A preview here would truncate the
        // user's dictation into oblivion, and silence would lose it outright.
        let long = "one two three four five six seven eight nine ten eleven twelve";
        assert!(long.chars().count() > PREVIEW_CHARS);
        let (summary, body) = delivered(
            Err(anyhow::anyhow!("no wayland display")),
            outcome(long, None),
        );
        assert_eq!(summary, "Parla — clipboard failed");
        assert_eq!(body, long, "the untruncated text is the only copy left");
    }

    #[test]
    fn silence_and_clipped_taps_never_reach_whisper() {
        // Whisper hallucinates "Thank you." on both. 6400 samples is the 0.4s
        // floor; 1e-4 RMS is the loudness floor.
        assert_eq!(worth_transcribing(vec![0.0; 16_000]), Err("Nothing heard"));
        assert_eq!(worth_transcribing(vec![0.5; 6_399]), Err("Nothing heard"));
        assert_eq!(worth_transcribing(Vec::new()), Err("Nothing heard"));
        // ...and a real second of speech goes straight through, untouched.
        assert_eq!(worth_transcribing(vec![0.5; 16_000]), Ok(vec![0.5; 16_000]));
    }

    #[test]
    fn a_preview_short_enough_to_fit_is_left_alone() {
        assert_eq!(preview("short one"), "short one");
        // Exactly at the limit still fits — no ellipsis for a text that is whole.
        let exact = "x".repeat(PREVIEW_CHARS);
        assert_eq!(preview(&exact), exact);
    }

    #[test]
    fn a_long_preview_is_cut_to_the_limit_including_the_ellipsis() {
        let long = "y".repeat(PREVIEW_CHARS + 40);
        let p = preview(&long);
        assert_eq!(p.chars().count(), PREVIEW_CHARS);
        assert!(p.ends_with('…'), "{p}");
        assert!(long.starts_with(p.trim_end_matches('…')));
    }

    #[test]
    fn a_multi_line_dictation_previews_as_one_line() {
        // A notification body that keeps its newlines is a wall of text in a
        // toast; two paragraphs must not become a blank line either.
        assert_eq!(preview("first item\n\nsecond item"), "first item second item");
    }

    #[test]
    fn a_multibyte_preview_is_cut_between_characters_not_inside_one() {
        // Byte-indexed truncation panics here, inside the dictation task — the
        // notification would kill the thing that produced it.
        let long = "é".repeat(PREVIEW_CHARS + 10);
        assert_eq!(preview(&long).chars().count(), PREVIEW_CHARS);
    }
}
