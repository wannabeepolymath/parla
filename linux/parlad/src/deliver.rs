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
/// Async because the call underneath is not: with `foreground` unset — the
/// default — `copy` spawns a helper *thread inside this process* and then
/// blocks on a channel until that thread has opened the Wayland connection,
/// bound the globals and completed a roundtrip. Sub-millisecond against a
/// healthy compositor, unbounded against a wedged one, which is the same defect
/// already fixed for whisper and for `notify`. It also `unwrap()`s that
/// channel (`copy.rs:988`), so a helper thread that dies takes the calling task
/// with it — on a tokio worker that would abort the dictation before it could
/// report anything. On a blocking thread the panic comes back as a `JoinError`,
/// which the caller renders as an ordinary clipboard failure.
///
/// The selection is served by that helper thread for as long as **this process**
/// lives — it is not a fork, and it does not outlive the daemon.
pub async fn to_clipboard(text: &str) -> anyhow::Result<()> {
    let text = text.to_string();
    let handover = tokio::task::spawn_blocking(move || {
        let mut opts = Options::new();
        // Already the default; pinned explicitly because the other setting makes
        // `copy` block until someone else takes the selection — in a daemon,
        // that is forever. Inside `spawn_blocking` that would hang a pool
        // thread silently, so it is pinned rather than left to the default.
        opts.foreground(false);
        opts.copy(
            Source::Bytes(text.into_bytes().into_boxed_slice()),
            MimeType::Text,
        )?;
        anyhow::Ok(())
    });
    // On timeout the blocking thread is NOT cancelled — it keeps waiting and may
    // still land the text later, which is harmless. What matters is that the
    // caller gets an answer it can show the user rather than waiting forever.
    tokio::time::timeout(HANDOVER_TIMEOUT, handover)
        .await
        .map_err(|_| anyhow::anyhow!("the compositor did not take the clipboard within {HANDOVER_TIMEOUT:?}"))??
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
