use std::ffi::OsStr;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

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

fn main() -> std::io::Result<()> {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "status".into());
    let path = socket_path_from(std::env::var_os("XDG_RUNTIME_DIR").as_deref());
    // Blocking std sockets on purpose: no async runtime to start up. This
    // process is spawned by the compositor on every key press and release.
    // Exits here rather than `?`-ing out, so the user gets this one line and not
    // this line followed by Termination's `Error: Os { code: 2, .. }`. The errno
    // is kept inline: ENOENT ("not running") and EACCES ("wrong $XDG_RUNTIME_DIR
    // / another user's socket") need very different fixes.
    let mut stream = UnixStream::connect(&path).unwrap_or_else(|e| {
        eprintln!("parlactl: cannot reach parlad at {} ({e}) — is parlad running?", path.display());
        std::process::exit(1);
    });
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
    // Wire contract with parlad's socket handler: an `error:`-prefixed reply is
    // a failure. The compositor throws stdout away, so a bad binding would look
    // like nothing happening at all unless it also shows up on stderr and in the
    // exit status.
    if let Some(msg) = reply.strip_prefix("error: ") {
        eprint!("parlactl: {msg}");
        std::process::exit(1);
    }
    print!("{reply}");
    Ok(())
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
