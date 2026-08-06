//! `parlactl setup` is what a user runs *because* parlad is not running yet, so
//! it has to answer before the socket is ever touched. Only spawning the real
//! binary proves that — a unit test on `setup_snippet_from` never reaches main.
//!
//! std only, deliberately: this crate has no dependencies and a dev-dependency
//! is still a crate the workspace has to resolve.

use std::process::Command;

fn setup(desktop: Option<&str>) -> std::process::Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_parlactl"));
    // A directory that holds no socket, which is exactly the "parlad is not
    // running" case this test is about.
    cmd.env("XDG_RUNTIME_DIR", std::env::temp_dir().join("pctl-setup-no-daemon"));
    match desktop {
        // Never inherited: this test binary may itself be running under sway.
        None => cmd.env_remove("XDG_CURRENT_DESKTOP"),
        Some(d) => cmd.env("XDG_CURRENT_DESKTOP", d),
    };
    cmd.arg("setup").output().unwrap()
}

#[test]
fn setup_answers_with_no_daemon_running() {
    let out = setup(None);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "exit {:?}, stderr {:?}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stderr), "");
    for needle in ["bindsym", "bindr =", "riverctl map"] {
        assert!(stdout.contains(needle), "no {needle} in\n{stdout}");
    }
}

#[test]
fn setup_narrows_to_the_compositor_in_the_environment() {
    let stdout = String::from_utf8_lossy(&setup(Some("wlroots:sway")).stdout).into_owned();
    assert!(stdout.contains("bindsym --no-repeat"), "{stdout}");
    assert!(!stdout.contains("riverctl"), "{stdout}");
}
