use std::str::FromStr;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Start,
    Stop,
    Toggle,
    Cancel,
    Status,
}

impl FromStr for Command {
    type Err = ();
    fn from_str(s: &str) -> Result<Self, ()> {
        match s.trim() {
            "start" => Ok(Command::Start),
            "stop" => Ok(Command::Stop),
            "toggle" => Ok(Command::Toggle),
            "cancel" => Ok(Command::Cancel),
            "status" => Ok(Command::Status),
            _ => Err(()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Recording,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edge {
    /// Recording started — mark the ring buffer.
    Began,
    /// Recording ended — transcribe what was captured.
    Finished,
    /// Discard: too short, explicit cancel, or the watchdog fired.
    Cancelled,
    /// No state change.
    Ignored,
}

/// Taps shorter than this are a fumbled key, not dictation.
const SHORT_TAP: Duration = Duration::from_millis(200);

/// Floor for the watchdog. `watchdog_secs = 0` in config.toml reads as
/// "disabled" to anyone skimming the file, but taken literally it expires every
/// recording on the daemon's first tick — dictation would never work again.
const MIN_WATCHDOG: Duration = Duration::from_secs(1);

pub struct Session {
    state: State,
    started: Option<Instant>,
    watchdog: Duration,
}

impl Session {
    /// Clamped here, at the one point every caller routes through, rather than
    /// at each call site — see `MIN_WATCHDOG`.
    pub fn new(watchdog: Duration) -> Self {
        Self { state: State::Idle, started: None, watchdog: watchdog.max(MIN_WATCHDOG) }
    }

    pub fn state(&self) -> State {
        self.state
    }

    pub fn handle(&mut self, cmd: Command, now: Instant) -> Edge {
        // Every (Command, State) pair is spelled out rather than swept up by a
        // `_ => Ignored` arm. Tasks 6-9 keep extending this daemon, and a new
        // Command variant that silently means "do nothing" is exactly the class
        // of bug the watchdog exists to clean up after. Non-exhaustive here is a
        // compile error; a wildcard would have been a shipped no-op.
        match (cmd, self.state) {
            (Command::Start | Command::Toggle, State::Idle) => {
                self.state = State::Recording;
                self.started = Some(now);
                Edge::Began
            }
            (Command::Stop | Command::Toggle, State::Recording) => {
                let short = self.started.is_some_and(|t| now.duration_since(t) < SHORT_TAP);
                self.state = State::Idle;
                self.started = None;
                if short { Edge::Cancelled } else { Edge::Finished }
            }
            (Command::Cancel, State::Recording) => {
                self.state = State::Idle;
                self.started = None;
                Edge::Cancelled
            }
            // Start while already recording: sway autorepeat, not a restart.
            (Command::Start, State::Recording) => Edge::Ignored,
            // Stop/cancel with nothing running: a stray --release edge.
            (Command::Stop | Command::Cancel, State::Idle) => Edge::Ignored,
            // Status is a query; the caller answers it without a transition.
            (Command::Status, State::Idle | State::Recording) => Edge::Ignored,
        }
    }

    /// True when a recording has outlived the watchdog. Guards sway#6456: sway
    /// silently drops the --release edge if another key is pressed while the
    /// hotkey is held, so the stop command may never arrive.
    pub fn watchdog_expired(&self, now: Instant) -> bool {
        match self.started {
            Some(t) => now.duration_since(t) > self.watchdog,
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn session() -> Session {
        Session::new(Duration::from_secs(30))
    }

    #[test]
    fn start_then_stop_produces_a_finish_edge() {
        let mut s = session();
        let t0 = Instant::now();
        assert_eq!(s.handle(Command::Start, t0), Edge::Began);
        assert_eq!(s.state(), State::Recording);
        assert_eq!(s.handle(Command::Stop, t0 + Duration::from_secs(2)), Edge::Finished);
        assert_eq!(s.state(), State::Idle);
    }

    #[test]
    fn a_second_start_while_recording_is_ignored() {
        let mut s = session();
        let t0 = Instant::now();
        s.handle(Command::Start, t0);
        // sway re-runs a matched press binding on autorepeat if --no-repeat is
        // missing from the user's config; a restart would drop buffered audio.
        assert_eq!(s.handle(Command::Start, t0 + Duration::from_millis(40)), Edge::Ignored);
        assert_eq!(s.state(), State::Recording);
    }

    #[test]
    fn stop_while_idle_is_ignored() {
        let mut s = session();
        assert_eq!(s.handle(Command::Stop, Instant::now()), Edge::Ignored);
    }

    #[test]
    fn cancel_while_recording_discards() {
        let mut s = session();
        let t0 = Instant::now();
        s.handle(Command::Start, t0);
        assert_eq!(s.handle(Command::Cancel, t0 + Duration::from_secs(1)), Edge::Cancelled);
        assert_eq!(s.state(), State::Idle);
    }

    #[test]
    fn toggle_starts_then_stops() {
        let mut s = session();
        let t0 = Instant::now();
        assert_eq!(s.handle(Command::Toggle, t0), Edge::Began);
        assert_eq!(s.handle(Command::Toggle, t0 + Duration::from_secs(1)), Edge::Finished);
    }

    #[test]
    fn watchdog_fires_only_after_the_timeout_while_recording() {
        let mut s = session();
        let t0 = Instant::now();
        s.handle(Command::Start, t0);
        assert!(!s.watchdog_expired(t0 + Duration::from_secs(29)));
        assert!(s.watchdog_expired(t0 + Duration::from_secs(31)));
    }

    #[test]
    fn watchdog_never_fires_while_idle() {
        let s = session();
        assert!(!s.watchdog_expired(Instant::now() + Duration::from_secs(3600)));
    }

    #[test]
    fn the_watchdog_goes_quiet_again_after_a_stop_or_a_cancel() {
        // watchdog_expired reads `started`, not `state`. A transition back to
        // Idle that forgets to clear the timestamp leaves the watchdog firing
        // once a second forever against a session that is not recording.
        for end in [Command::Stop, Command::Cancel] {
            let mut s = session();
            let t0 = Instant::now();
            s.handle(Command::Start, t0);
            s.handle(end, t0 + Duration::from_secs(2));
            assert!(
                !s.watchdog_expired(t0 + Duration::from_secs(3600)),
                "{end:?} left the watchdog armed"
            );
        }
    }

    #[test]
    fn a_zero_watchdog_is_clamped_rather_than_cancelling_every_recording() {
        // `watchdog_secs = 0` looks like "off" in a config file. Unclamped it
        // expires on the daemon's first tick, so every dictation dies before
        // the user finishes the first word — and the daemon logs once a second
        // forever. Clamped, a surprising value is merely useless.
        let mut s = Session::new(Duration::from_secs(0));
        let t0 = Instant::now();
        s.handle(Command::Start, t0);
        assert!(!s.watchdog_expired(t0 + Duration::from_millis(900)));
        assert!(s.watchdog_expired(t0 + Duration::from_millis(1_100)));
    }

    #[test]
    fn short_taps_are_discarded_as_accidental() {
        let mut s = session();
        let t0 = Instant::now();
        s.handle(Command::Start, t0);
        // Under 200ms is a fumbled key, not dictation — same rule as macOS.
        assert_eq!(s.handle(Command::Stop, t0 + Duration::from_millis(120)), Edge::Cancelled);
    }

    #[test]
    fn commands_parse_from_the_wire_format() {
        assert_eq!("start".parse::<Command>().unwrap(), Command::Start);
        assert_eq!("stop\n".trim().parse::<Command>().unwrap(), Command::Stop);
        assert!("nonsense".parse::<Command>().is_err());
    }
}
