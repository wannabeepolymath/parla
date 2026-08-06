use wl_clipboard_rs::copy::{MimeType, Options, Source};

pub fn to_clipboard(text: &str) -> anyhow::Result<()> {
    let mut opts = Options::new();
    // Serve the clipboard from a forked helper so the value survives after the
    // daemon moves on; without this the selection dies with the request.
    opts.foreground(false);
    opts.copy(
        Source::Bytes(text.as_bytes().to_vec().into_boxed_slice()),
        MimeType::Text,
    )?;
    Ok(())
}

/// Fire-and-forget. `notify_rust::show()` is a BLOCKING D-Bus round trip, so it
/// runs on a blocking thread rather than inline: a wedged notification daemon
/// must never stall the hotkey path or occupy a tokio worker. Handling that here
/// rather than at each call site means no caller can get it wrong.
/// Requires a tokio runtime context — both call sites are async.
pub fn notify(summary: &str, body: &str) {
    let (summary, body) = (summary.to_string(), body.to_string());
    tokio::task::spawn_blocking(move || {
        // A missing notification daemon must never take down a dictation.
        if let Err(e) = notify_rust::Notification::new()
            .summary(&summary)
            .body(&body)
            .appname("Parla")
            .timeout(notify_rust::Timeout::Milliseconds(4000))
            .show()
        {
            eprintln!("parlad: notify failed: {e}");
        }
    });
}
