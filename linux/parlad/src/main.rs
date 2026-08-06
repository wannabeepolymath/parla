mod audio;
mod session;
mod socket;
mod whisper;

use parla_core::config::{config_path, Config};
use session::{Command, Edge, Session};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

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
    eprintln!("parlad: capture started");

    // ponytail: Tasks 6 and 7's manual verification, behind a flag so it costs
    // the daemon nothing. `--check` transcribes three seconds of microphone;
    // `--check --stdin` transcribes 16 kHz mono f32 read from stdin, which is
    // how the eval/cases goldens are replayed without pulling in a WAV parser.
    // Task 8 replaces this file wholesale and deletes all of it.
    if std::env::args().any(|a| a == "--check") {
        let transcriber = whisper::Transcriber::new(&whisper::model_path(&cfg))?;
        let samples: Vec<f32> = if std::env::args().any(|a| a == "--stdin") {
            let mut buf = Vec::new();
            std::io::Read::read_to_end(&mut std::io::stdin(), &mut buf)?;
            buf.chunks_exact(4)
                .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect()
        } else {
            capture.mark();
            std::thread::sleep(Duration::from_secs(3));
            capture.take_since_mark()
        };
        eprintln!(
            "parlad: {} samples ({:.2}s at {} Hz), mic level {:.4}",
            samples.len(),
            samples.len() as f32 / audio::TARGET_RATE as f32,
            audio::TARGET_RATE,
            capture.level()
        );
        let prompt = whisper::initial_prompt(&cfg.dictionary);
        eprintln!(
            "parlad: transcript {:?}",
            transcriber.transcribe(&samples, prompt.as_deref())?
        );
        return Ok(());
    }

    let sess = Arc::new(Mutex::new(Session::new(Duration::from_secs(cfg.watchdog_secs))));

    // Watchdog: sway drops the --release edge if another key is pressed while
    // the hotkey is held (sway#6456), so a stop may never arrive.
    let watch = sess.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            let fired = {
                let mut s = watch.lock().await;
                let fired = s.watchdog_expired(Instant::now());
                if fired {
                    s.handle(Command::Cancel, Instant::now());
                }
                fired
            };
            // Logged after the guard is dropped: a blocking write to a wedged
            // journald would otherwise stall the one lock every hotkey press
            // needs. Same defect shape as holding it across a D-Bus notify.
            if fired {
                eprintln!("parlad: watchdog fired, discarding recording");
            }
        }
    });

    let path = socket::socket_path();
    eprintln!("parlad: listening on {}", path.display());
    socket::serve(&path, move |line| {
        let sess = sess.clone();
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
            match s.handle(cmd, Instant::now()) {
                Edge::Began => "recording".into(),
                Edge::Finished => "processing".into(),
                Edge::Cancelled => "cancelled".into(),
                Edge::Ignored => "ignored".into(),
            }
        }
    })
    .await
}
