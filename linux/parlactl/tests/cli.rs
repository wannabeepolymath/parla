//! Drives the real `parlactl` binary against a canned one-shot socket.
//!
//! The daemon is not involved: these assert the *client* half of the wire
//! protocol — connect, send, half-close, read, and translate the reply into an
//! exit status. That last step is what the compositor sees, and it is invisible
//! to a unit test on `socket_path_from`.
//!
//! std only, deliberately. Adding a dev-dependency here would still be a crate
//! this workspace has to resolve and vendor for a binary whose whole point is
//! having none.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

/// How the fake daemon behaves once it has read the command.
enum Behaviour {
    /// Reply, then hang up. The normal case.
    Reply(&'static str),
    /// Hang up without replying — parlad hitting an error before it answers.
    CloseWithoutReplying,
    /// Accept, read, and then never say anything. A wedged daemon.
    GoQuiet,
}

/// Serves exactly one connection, and hands back the command line the client
/// sent. Runs on a thread so the client can run in parallel.
fn one_shot_daemon(name: &str, behaviour: Behaviour) -> (PathBuf, std::thread::JoinHandle<String>) {
    // Short base path on purpose: a unix socket path over SUN_LEN (~104 bytes
    // on macOS) fails at bind with a confusing InvalidInput.
    let dir = std::env::temp_dir().join(format!("pctl-{}-{name}", std::process::id()));
    std::fs::remove_dir_all(&dir).ok();
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("parla.sock");

    let listener = UnixListener::bind(&path).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line).unwrap();
        match behaviour {
            Behaviour::Reply(r) => (&stream).write_all(r.as_bytes()).unwrap(),
            Behaviour::CloseWithoutReplying => {}
            // Outlives parlactl's 5s IO_TIMEOUT. The thread is detached and the
            // harness does not join it, so it dies with the test process.
            Behaviour::GoQuiet => std::thread::sleep(Duration::from_secs(60)),
        }
        line
    });
    (dir, handle)
}

fn parlactl(runtime_dir: &PathBuf, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_parlactl"))
        // Set on the child, never via std::env::set_var — that races every
        // other test in the binary.
        .env("XDG_RUNTIME_DIR", runtime_dir)
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn a_normal_reply_goes_to_stdout_with_a_zero_exit() {
    let (dir, daemon) = one_shot_daemon("ok", Behaviour::Reply("Recording\n"));
    let out = parlactl(&dir, &["status"]);

    assert_eq!(daemon.join().unwrap(), "status\n", "wrong command on the wire");
    assert!(out.status.success(), "exit was {:?}", out.status.code());
    assert_eq!(String::from_utf8_lossy(&out.stdout), "Recording\n");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "");
}

#[test]
fn an_error_reply_goes_to_stderr_with_a_nonzero_exit() {
    // The compositor throws stdout away. If a mistyped binding only ever showed
    // up on stdout with exit 0, `parlactl statsu` in a keybinding would look
    // exactly like a working one that does nothing.
    let (dir, daemon) = one_shot_daemon("err", Behaviour::Reply("error: unknown command \"statsu\"\n"));
    let out = parlactl(&dir, &["statsu"]);

    daemon.join().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        String::from_utf8_lossy(&out.stderr),
        "parlactl: unknown command \"statsu\"\n"
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
}

#[test]
fn no_argument_defaults_to_status() {
    let (dir, daemon) = one_shot_daemon("default", Behaviour::Reply("Idle\n"));
    let out = parlactl(&dir, &[]);

    assert_eq!(daemon.join().unwrap(), "status\n");
    assert_eq!(String::from_utf8_lossy(&out.stdout), "Idle\n");
}

#[test]
fn a_wedged_daemon_times_out_instead_of_hanging_forever() {
    // The compositor spawns parlactl on every key edge. Without the socket
    // timeouts this call never returns, so a wedged parlad leaks a process and
    // a descriptor per keypress until the user runs out of both.
    let (dir, _daemon) = one_shot_daemon("wedged", Behaviour::GoQuiet);

    let started = std::time::Instant::now();
    let out = parlactl(&dir, &["start"]);
    let elapsed = started.elapsed();

    assert_eq!(out.status.code(), Some(1));
    assert!(elapsed < Duration::from_secs(15), "took {elapsed:?} — did it hang?");
    let stderr = String::from_utf8_lossy(&out.stderr);
    // A distinct diagnostic: "wedged" and "not running" need different fixes.
    assert!(stderr.contains("went quiet"), "stderr was {stderr:?}");
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
}

#[test]
fn a_reply_that_never_arrives_is_a_failure_not_a_silent_success() {
    // parlad writes nothing when it fails before it can answer — a malformed
    // line, or a crash mid-connection. Exiting 0 with empty stdout would make
    // that indistinguishable from a command that worked.
    let (dir, daemon) = one_shot_daemon("empty", Behaviour::CloseWithoutReplying);
    let out = parlactl(&dir, &["start"]);

    assert_eq!(daemon.join().unwrap(), "start\n");
    assert_eq!(out.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("without replying"),
        "stderr was {:?}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
}

#[test]
fn a_missing_daemon_is_reported_rather_than_exiting_zero() {
    let dir = std::env::temp_dir().join(format!("pctl-{}-absent", std::process::id()));
    std::fs::remove_dir_all(&dir).ok();
    std::fs::create_dir_all(&dir).unwrap();

    let out = parlactl(&dir, &["start"]);
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("is parlad running?"), "stderr was {stderr:?}");
    // The path is named, so a $XDG_RUNTIME_DIR mismatch is diagnosable.
    assert!(stderr.contains("parla.sock"), "stderr was {stderr:?}");
}
