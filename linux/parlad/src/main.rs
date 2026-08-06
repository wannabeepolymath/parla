mod session;
mod socket;

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
