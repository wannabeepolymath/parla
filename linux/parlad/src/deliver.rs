use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use wl_clipboard_rs::copy::{MimeType, Options, Source};

/// Re-exported so the pipeline can say how long a notification stays up without
/// taking a direct dependency on the notification crate.
pub use notify_rust::Timeout;

/// Longest the pipeline waits for the compositor to take the selection. An
/// *absent* compositor errors in microseconds; a *wedged* one never answers at
/// all, and an unbounded wait there means `dictate` never returns, no
/// notification ever fires, and the transcript is lost in silence — the one
/// outcome this pipeline exists to prevent. Generous, because it is not a
/// latency budget: anything under it is invisible, and past it the desktop has
/// bigger problems than this dictation.
const HANDOVER_TIMEOUT: Duration = Duration::from_secs(5);

/// Hands the text to the Wayland clipboard.
///
/// Async because the Wayland handshake is not: opening the connection, binding
/// the globals and the roundtrip are sub-millisecond against a healthy
/// compositor and unbounded against a wedged one, which is the same defect
/// already fixed for whisper and for `notify`. So it runs on a thread of its
/// own, behind `HANDOVER_TIMEOUT`, and a helper that panics comes back as an
/// ordinary clipboard failure rather than taking the dictation with it.
///
/// `foreground(true)` + `prepare_copy` rather than `copy`: `copy` publishes on
/// a helper thread that outlives a timeout and lands the text whenever the
/// compositor wakes — over the next dictation, or over whatever the user
/// copied since. `prepare_copy` only *queues* `set_selection`; nothing reaches
/// the compositor until `serve` flushes it, and `handoff` decides first.
///
/// The selection is served by that thread for as long as **this process**
/// lives — it is not a fork, and it does not outlive the daemon.
pub async fn to_clipboard(text: &str) -> anyhow::Result<()> {
    let text = text.to_string();
    let prepare = move || {
        let mut opts = Options::new();
        opts.foreground(true);
        Ok(opts.prepare_copy(
            Source::Bytes(text.into_bytes().into_boxed_slice()),
            MimeType::Text,
        )?)
    };
    // Nobody listens for errors once serving; the selection is ours until taken.
    handoff(HANDOVER_TIMEOUT, prepare, |copy| drop(copy.serve())).await
}

/// Runs `prepare` on its own thread, then `publish` — unless the caller gave
/// up first. Exactly one side flips `live`: the thread (publish, answer Ok) or
/// the timeout (abandon, answer Err). An abandoned handoff is dropped
/// unpublished, so a late compositor never sees it.
async fn handoff<P>(
    timeout: Duration,
    prepare: impl FnOnce() -> anyhow::Result<P> + Send + 'static,
    publish: impl FnOnce(P) + Send + 'static,
) -> anyhow::Result<()> {
    let live = Arc::new(AtomicBool::new(true));
    let (tx, mut rx) = tokio::sync::oneshot::channel();
    let mine = live.clone();
    std::thread::spawn(move || match prepare() {
        Err(e) => drop(tx.send(Err(e))),
        Ok(p) if mine.swap(false, Ordering::SeqCst) => {
            drop(tx.send(Ok(())));
            publish(p);
        }
        Ok(_) => {} // abandoned
    });
    let died = |_| anyhow::anyhow!("the clipboard helper died");
    match tokio::time::timeout(timeout, &mut rx).await {
        Ok(answer) => answer.unwrap_or_else(|e| Err(died(e))),
        Err(_) if live.swap(false, Ordering::SeqCst) => {
            Err(anyhow::anyhow!("the compositor did not take the clipboard within {timeout:?}"))
        }
        // The thread won the race and is publishing; its Ok is already sent.
        Err(_) => rx.await.unwrap_or_else(|e| Err(died(e))),
    }
}

/// Fire-and-forget. `notify_rust::show()` is a BLOCKING D-Bus round trip, so it
/// runs on a blocking thread rather than inline: a wedged notification daemon
/// must never stall the hotkey path or occupy a tokio worker. Handling that here
/// rather than at each call site means no caller can get it wrong.
/// Requires a tokio runtime context — both call sites are async.
pub fn notify(summary: &str, body: &str, timeout: Timeout) {
    let (summary, body) = (summary.to_string(), body.to_string());
    tokio::task::spawn_blocking(move || {
        // A missing notification daemon must never take down a dictation.
        if let Err(e) = notify_rust::Notification::new()
            .summary(&summary)
            .body(&body)
            .appname("Parla")
            .timeout(timeout)
            .show()
        {
            eprintln!("parlad: notify failed: {e}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[tokio::test]
    async fn an_abandoned_handoff_never_publishes() {
        let (release, wait) = mpsc::channel::<()>();
        let (published, saw) = mpsc::channel::<()>();
        let prepare = move || {
            wait.recv().ok(); // a wedged compositor that wakes after the timeout
            anyhow::Ok(())
        };
        let r = handoff(Duration::from_millis(20), prepare, move |()| published.send(()).unwrap()).await;
        assert!(r.is_err(), "timed out");
        release.send(()).unwrap();
        assert!(saw.recv_timeout(Duration::from_millis(500)).is_err(), "published after the caller gave up");
    }

    #[tokio::test]
    async fn a_prompt_handoff_publishes_and_reports_ok() {
        let (published, saw) = mpsc::channel::<()>();
        let r = handoff(Duration::from_secs(5), || anyhow::Ok(()), move |()| published.send(()).unwrap()).await;
        assert!(r.is_ok());
        saw.recv_timeout(Duration::from_secs(1)).unwrap();
    }
}
