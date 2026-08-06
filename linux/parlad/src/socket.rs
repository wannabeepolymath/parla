use std::ffi::OsStr;
use std::future::Future;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

/// Longest command line accepted. Every command is a single short word; an
/// unbounded `read_line` lets a client that never sends a newline grow the
/// daemon's heap until the OOM killer arrives.
const MAX_COMMAND_BYTES: u64 = 256;

/// Serve one command per connection: read a line, hand it to `handler`, write
/// the reply. `parlactl` connects, sends, reads, and exits on every key edge,
/// so connections are short-lived by design.
pub async fn serve<F, Fut>(path: &Path, handler: F) -> anyhow::Result<()>
where
    F: Fn(String) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = String> + Send + 'static,
{
    accept_loop(bind(path)?, handler).await
}

/// Split from `serve` so tests can bind synchronously and then connect without
/// racing the listener into existence.
fn bind(path: &Path) -> anyhow::Result<UnixListener> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // A stale socket from a crashed daemon would block bind; clear it first.
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    // bind() applies the umask, which usually leaves the socket group- and
    // world-connectable. In $XDG_RUNTIME_DIR (0700) that is moot, but the /tmp
    // fallback is world-writable, and anyone who can connect can start, stop or
    // cancel the user's dictation.
    // ponytail: chmod-after-bind leaves a sub-millisecond window open; wrapping
    // the bind in a umask guard is the upgrade if that window ever matters.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

async fn accept_loop<F, Fut>(listener: UnixListener, handler: F) -> anyhow::Result<()>
where
    F: Fn(String) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = String> + Send + 'static,
{
    loop {
        let (stream, _) = listener.accept().await?;
        let handler = handler.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_conn(stream, handler).await {
                eprintln!("parlad: connection error: {e}");
            }
        });
    }
}

async fn handle_conn<F, Fut>(stream: UnixStream, handler: F) -> anyhow::Result<()>
where
    F: Fn(String) -> Fut,
    Fut: Future<Output = String>,
{
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    BufReader::new(read.take(MAX_COMMAND_BYTES)).read_line(&mut line).await?;
    let reply = handler(line).await;
    write.write_all(reply.as_bytes()).await?;
    write.write_all(b"\n").await?;
    Ok(())
}

/// Split out from `socket_path` so the env-var precedence is testable without
/// `set_var`, which races cargo's threaded test harness. An exported-but-empty
/// `XDG_RUNTIME_DIR` counts as unset, per the XDG basedir spec — otherwise it
/// yields a *relative* path, and the daemon (CWD `/` under systemd) and
/// `parlactl` (CWD wherever the compositor left it) would bind and connect to
/// two different sockets.
pub fn socket_path_from(xdg_runtime_dir: Option<&OsStr>) -> PathBuf {
    xdg_runtime_dir
        .filter(|x| !x.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("parla.sock")
}

/// $XDG_RUNTIME_DIR/parla.sock, falling back to /tmp.
/// Kept byte-for-byte in step with `parlactl`'s copy — see the note there.
pub fn socket_path() -> PathBuf {
    socket_path_from(std::env::var_os("XDG_RUNTIME_DIR").as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PID- and name-scoped: concurrent worktrees share /tmp, and a fixed name
    /// lets one run's bind land inside another's. The directory is deliberately
    /// left missing — `bind` has to create its own parent, exactly as it must
    /// for an `$XDG_RUNTIME_DIR` that a fresh login has not populated yet.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("parla-sock-{}-{name}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        dir.join("parla.sock")
    }

    /// Round-trips one command and returns the daemon's raw reply.
    async fn ask(path: &Path, cmd: &str) -> String {
        let mut c = UnixStream::connect(path).await.unwrap();
        c.write_all(cmd.as_bytes()).await.unwrap();
        c.shutdown().await.unwrap();
        let mut reply = String::new();
        c.read_to_string(&mut reply).await.unwrap();
        reply
    }

    #[test]
    fn an_unset_or_empty_runtime_dir_falls_back_to_tmp() {
        let unset = socket_path_from(None);
        assert_eq!(unset, PathBuf::from("/tmp/parla.sock"));
        // Empty must behave as unset, not yield the relative path "parla.sock".
        assert_eq!(socket_path_from(Some(OsStr::new(""))), unset);
        assert_eq!(
            socket_path_from(Some(OsStr::new("/run/user/1000"))),
            PathBuf::from("/run/user/1000/parla.sock")
        );
    }

    #[tokio::test]
    async fn a_connection_gets_one_newline_terminated_reply() {
        let path = scratch("roundtrip");
        let listener = bind(&path).unwrap();
        tokio::spawn(accept_loop(listener, |line: String| async move {
            format!("saw {:?}", line.trim())
        }));

        assert_eq!(ask(&path, "start\n").await, "saw \"start\"\n");
        // A second connection is served too — the loop does not stop after one.
        assert_eq!(ask(&path, "status\n").await, "saw \"status\"\n");
    }

    #[tokio::test]
    async fn bind_replaces_the_socket_a_crashed_daemon_left_behind() {
        let path = scratch("stale");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"stale").unwrap();
        // Without the remove_file, this is EADDRINUSE and the daemon never
        // starts again until the user deletes the file by hand.
        let listener = bind(&path).unwrap();
        tokio::spawn(accept_loop(listener, |_: String| async { "ok".to_string() }));
        assert_eq!(ask(&path, "status\n").await, "ok\n");
    }

    #[tokio::test]
    async fn the_socket_is_not_readable_by_other_users() {
        let path = scratch("perms");
        let _listener = bind(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "socket mode was {:o}", mode & 0o777);
    }

    #[tokio::test]
    async fn an_oversized_line_is_truncated_rather_than_buffered_forever() {
        let path = scratch("bounded");
        let listener = bind(&path).unwrap();
        tokio::spawn(accept_loop(listener, |line: String| async move {
            line.len().to_string()
        }));

        // No newline anywhere: an unbounded reader would sit here until the
        // client hung up, having buffered the whole lot. Sized to fit the
        // socket's send buffer so the client never blocks on the undrained tail.
        let flood = "x".repeat(4096);
        assert_eq!(ask(&path, &flood).await, format!("{MAX_COMMAND_BYTES}\n"));
    }
}
