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

/// Printed above every snippet. The two facts here are the ones that make Parla
/// look broken when they are wrong, and neither is documented by any compositor.
const HEADER: &str = "\
# Parla push-to-talk. HOLD Right Ctrl to record, RELEASE it to transcribe.
#
# Right Ctrl, not Right Alt: on AltGr layouts (most of Europe, Latin America and
# the Nordics) Right Alt *is* AltGr, and binding it away breaks typing @ € { }
# \\ and every accented character.
#
# The press and release lines below carry different modifier fields, and that is
# not a typo. wlroots updates the xkb modifier state *after* it emits the key
# event, so the held modifier is missing from the mask on press and still
# present on release. Each compositor compensates for that differently.
#
# Paste this into your own compositor config and reload the compositor. parlactl
# must be on the PATH your compositor was started with.

";

const SWAY: &str = "\
# ~/.config/sway/config
#
# --no-repeat is MANDATORY on the press line: without it sway re-runs the
# matched binding ~25x/sec for as long as the key is held. Neither line takes a
# modifier prefix — sway already excludes the key's own modifier on release.
# --inhibited keeps the hotkey working inside windows that grab keyboard
# shortcuts (VM and remote-desktop clients).
bindsym --no-repeat --inhibited Control_R exec parlactl start
bindsym --release   --inhibited Control_R exec parlactl stop
";

const HYPRLAND: &str = "\
# ~/.config/hypr/hyprland.conf
#
# CTRL appears in the mod field of BOTH lines: the Hyprland wiki's rule is that
# the mod field carries the TARGET modmask, not the one held beforehand.
# Plain `bind` does not auto-repeat (that is `binde`), so there is no sway-style
# --no-repeat to add here.
bind  = CTRL, Control_R, exec, parlactl start
bindr = CTRL, Control_R, exec, parlactl stop
#
# Hyprland 0.55+ Lua config (~/.config/hypr/hyprland.lua) — the same two binds:
#   hl.bind(\"CTRL + Control_R\", hl.dsp.exec_cmd(\"parlactl start\"))
#   hl.bind(\"CTRL + Control_R\", hl.dsp.exec_cmd(\"parlactl stop\"), { release = true })
";

const RIVER: &str = "\
# ~/.config/river/init — river-classic 0.3.x only, see the note below.
#
# The asymmetric modifier field is the whole trick: None on press, Control on
# release.
riverctl map          normal None    Control_R spawn 'parlactl start'
riverctl map -release normal Control Control_R spawn 'parlactl stop'
";

/// Not a snippet, on purpose. Shipping lines that cannot work is worse than
/// saying so: the user would paste them, reload, and get silence with no error.
const NO_RELEASE_BINDING: &str = "\
# niri and river >= 0.4 cannot express a key-release binding at all, so
# push-to-talk on them needs the evdev backend, which is not in this milestone.
# `parlactl start` and `parlactl stop` still work from a terminal or any other
# launcher that can run two separate commands.
";

/// Split from the env lookup so the detection is testable without `set_var`,
/// which races cargo's threaded harness — same shape as `socket_path_from`
/// above and `parla_core::config::config_path_from`.
///
/// sway and Hyprland both set `XDG_CURRENT_DESKTOP` (often colon-separated, and
/// with inconsistent case); river-classic does not do so reliably. An
/// unrecognised or absent value therefore prints everything rather than
/// guessing wrong or printing nothing.
fn setup_snippet_from(xdg_current_desktop: Option<&OsStr>) -> String {
    let desktop = xdg_current_desktop
        .map(|d| d.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    // Checked first and answered alone: a niri user handed three snippets would
    // paste one and wonder why nothing happens.
    if desktop.contains("niri") {
        return NO_RELEASE_BINDING.to_string();
    }
    let body = if desktop.contains("hyprland") {
        HYPRLAND.to_string()
    } else if desktop.contains("sway") {
        SWAY.to_string()
    } else {
        format!("{SWAY}\n{HYPRLAND}\n{RIVER}\n{NO_RELEASE_BINDING}")
    };
    format!("{HEADER}{body}")
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

    // Short-circuits before the socket on purpose: `parlactl setup` is what a
    // user runs *because* parlad is not running yet.
    if cmd == "setup" {
        print!("{}", setup_snippet_from(std::env::var_os("XDG_CURRENT_DESKTOP").as_deref()));
        return;
    }

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

    fn snippet(desktop: &str) -> String {
        setup_snippet_from(Some(OsStr::new(desktop)))
    }

    #[test]
    fn a_detected_compositor_gets_its_snippet_and_only_its_snippet() {
        let sway = snippet("sway");
        assert!(sway.contains("bindsym"), "{sway}");
        assert!(!sway.contains("bindr =") && !sway.contains("riverctl"), "{sway}");

        let hypr = snippet("Hyprland");
        assert!(hypr.contains("bindr ="), "{hypr}");
        assert!(!hypr.contains("bindsym") && !hypr.contains("riverctl"), "{hypr}");

        // As the compositors actually set it: colon-separated, mixed case.
        assert_eq!(snippet("wlroots:Sway"), sway);
        assert_eq!(snippet("Hyprland:wlroots"), hypr);
    }

    #[test]
    fn an_unknown_desktop_prints_every_snippet_rather_than_nothing() {
        // river-classic does not set XDG_CURRENT_DESKTOP reliably, and guessing
        // wrong is worse than printing three blocks the user picks from.
        let all = setup_snippet_from(None);
        for needle in ["bindsym", "bindr =", "riverctl map"] {
            assert!(all.contains(needle), "no {needle} in\n{all}");
        }
        assert_eq!(snippet(""), all, "an exported-but-empty value is not a compositor");
        assert_eq!(snippet("GNOME"), all);
        // main uses print!, so a missing trailing newline eats the shell prompt.
        assert!(all.ends_with('\n'), "{all:?}");
    }

    #[test]
    fn every_pasteable_line_binds_right_ctrl_and_nothing_else() {
        let all = setup_snippet_from(None);
        let bindings: Vec<&str> = all
            .lines()
            .filter(|l| !l.trim_start().starts_with('#') && !l.trim().is_empty())
            .collect();
        assert_eq!(bindings.len(), 6, "expected 3 compositors x 2 lines: {bindings:#?}");
        for line in bindings {
            assert!(line.contains("Control_R"), "not bound to Right Ctrl: {line}");
            // Right Alt is AltGr on most non-US layouts; swallowing it breaks
            // typing @ € { } \ and every accented character.
            assert!(!line.contains("Alt"), "binds Alt: {line}");
        }
    }

    #[test]
    fn the_asymmetric_modifier_fields_and_no_repeat_survive_editing() {
        // The reason these look like typos is undocumented in every compositor:
        // wlroots updates the xkb modifier state *after* emitting the key event.
        // Getting one of them wrong makes Parla look broken rather than
        // misconfigured, so they are pinned character for character.
        let all = setup_snippet_from(None);
        for line in [
            // sway: no modifier prefix on either line, and the press MUST NOT
            // repeat — sway re-runs a matched press binding ~25x/sec while held.
            "bindsym --no-repeat --inhibited Control_R exec parlactl start",
            "bindsym --release   --inhibited Control_R exec parlactl stop",
            // Hyprland: CTRL on BOTH, because its mod field is the target modmask.
            "bind  = CTRL, Control_R, exec, parlactl start",
            "bindr = CTRL, Control_R, exec, parlactl stop",
            // river-classic: None on press, Control on release.
            "riverctl map          normal None    Control_R spawn 'parlactl start'",
            "riverctl map -release normal Control Control_R spawn 'parlactl stop'",
        ] {
            assert!(all.contains(line), "missing verbatim:\n{line}\nfrom\n{all}");
        }
    }

    #[test]
    fn compositors_without_release_bindings_are_told_so_instead_of_handed_a_snippet() {
        let niri = snippet("niri");
        assert!(niri.contains("cannot express a key-release binding"), "{niri}");
        assert!(niri.contains("evdev"), "{niri}");
        // Nothing pasteable: a niri user given a binding would paste it, reload,
        // and get silence with no error anywhere.
        assert!(
            niri.lines().all(|l| l.trim().is_empty() || l.trim_start().starts_with('#')),
            "{niri}"
        );
        // river's version split cannot be detected, so the caveat has to travel
        // with the river snippet.
        assert!(setup_snippet_from(None).contains("river >= 0.4"));
    }
}
