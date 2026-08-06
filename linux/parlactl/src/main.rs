use std::ffi::OsStr;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// A wedged parlad must never pin this process. The compositor spawns one
/// parlactl per key edge, so an unbounded wait leaks a process and a descriptor
/// on *every* keypress until the user runs out of both.
///
/// Generous next to any legitimate reply: parlad answers on the socket before
/// it starts transcribing, so nothing on this path is ever slow by design.
const IO_TIMEOUT: Duration = Duration::from_secs(5);

/// Deliberately duplicated from `parlad::socket::socket_path_from` rather than
/// shared: this crate takes no dependencies at all, because the compositor
/// spawns it twice per dictation and startup cost is on the critical path. The
/// two copies must agree byte for byte — if you change one, change the other.
/// An exported-but-empty `XDG_RUNTIME_DIR` counts as unset, per the XDG basedir
/// spec; treating it as set yields the *relative* path `parla.sock`, which
/// resolves against whatever CWD the compositor happened to leave behind.
fn socket_path_from(xdg_runtime_dir: Option<&OsStr>) -> PathBuf {
    xdg_runtime_dir
        .filter(|x| !x.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("parla.sock")
}

/// One command, one reply, every step bounded in time.
///
/// Blocking std sockets on purpose: no async runtime to start up.
fn ask(path: &Path, cmd: &str) -> std::io::Result<String> {
    let mut stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;
    stream.write_all(cmd.as_bytes())?;
    stream.write_all(b"\n")?;
    // Half-close. parlad reads one line and so never waits on this EOF, which
    // means no test can catch its removal — but it is what keeps the client
    // correct against a peer that reads to EOF instead, and Tasks 6-9 all edit
    // `handle_conn`. Deleting it trades one syscall for a hotkey path that
    // deadlocks the moment the daemon's reader stops being line-oriented.
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply)?;
    Ok(reply)
}

/// Every failure ends here: one line on stderr, exit 1. The compositor discards
/// stdout, so a diagnostic that lands only there is indistinguishable from a
/// keybinding that works and does nothing.
fn die(msg: String) -> ! {
    eprintln!("parlactl: {msg}");
    std::process::exit(1)
}

fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "status".into());
    let path = socket_path_from(std::env::var_os("XDG_RUNTIME_DIR").as_deref());

    let reply = ask(&path, &cmd).unwrap_or_else(|e| {
        die(match e.kind() {
            ErrorKind::NotFound | ErrorKind::ConnectionRefused => {
                format!("cannot reach parlad at {} ({e}) — is parlad running?", path.display())
            }
            // SO_RCVTIMEO/SO_SNDTIMEO surface as WouldBlock on Linux and
            // TimedOut on some other unices; both mean the same thing here.
            ErrorKind::WouldBlock | ErrorKind::TimedOut => format!(
                "parlad accepted the connection but went quiet for {IO_TIMEOUT:?} — wedged? ({})",
                path.display()
            ),
            _ => format!("talking to parlad at {} failed ({e})", path.display()),
        })
    });

    // Wire contract with parlad's socket handler: an `error:`-prefixed reply is
    // a failure.
    if let Some(msg) = reply.strip_prefix("error: ") {
        die(msg.trim_end().to_string());
    }
    // parlad always answers. Nothing at all means it hit an error before it
    // could reply — a malformed line, or a crash mid-connection. Printing
    // nothing and exiting 0 would make that indistinguishable from success.
    if reply.trim().is_empty() {
        die(format!("parlad closed the connection without replying ({})", path.display()));
    }
    print!("{reply}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unset_or_empty_runtime_dir_falls_back_to_tmp() {
        // Must match parlad's socket_path_from exactly, or the CLI talks to a
        // socket the daemon never bound.
        let unset = socket_path_from(None);
        assert_eq!(unset, PathBuf::from("/tmp/parla.sock"));
        assert_eq!(socket_path_from(Some(OsStr::new(""))), unset);
        assert_eq!(
            socket_path_from(Some(OsStr::new("/run/user/1000"))),
            PathBuf::from("/run/user/1000/parla.sock")
        );
    }
}
