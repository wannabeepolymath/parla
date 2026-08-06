use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Cleanup {
    /// "anthropic" | "openai-compatible" | "none"
    pub provider: String,
    /// Required for openai-compatible.
    pub base_url: Option<String>,
    /// None => the server's default model.
    pub model: Option<String>,
    /// Name of the env var holding the key. Preferred over `api_key`.
    pub api_key_env: Option<String>,
    /// Inline fallback when no env var is set.
    pub api_key: Option<String>,
}

/// Hand-written so `api_key` can never reach a log. The daemon in Tasks 5-9
/// logs to stderr and the journal, and one `{:?}` of a `Config` — which derives
/// `Debug` and picks this up — would publish the user's key. `Serialize` is
/// deliberately left alone: `Config::save` must round-trip the real value.
impl std::fmt::Debug for Cleanup {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cleanup")
            .field("provider", &self.provider)
            .field("base_url", &self.base_url)
            .field("model", &self.model)
            .field("api_key_env", &self.api_key_env)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

impl Default for Cleanup {
    fn default() -> Self {
        Self {
            provider: "anthropic".into(),
            base_url: None,
            // Deliberately None: an unset model means "let the provider pick".
            // A concrete default here would be sent verbatim to whatever
            // base_url is configured, breaking every non-Anthropic endpoint.
            model: None,
            api_key_env: Some("ANTHROPIC_API_KEY".into()),
            api_key: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub dictionary: Vec<String>,
    pub snippets: BTreeMap<String, String>,
    pub cleanup: Cleanup,
    /// None => $XDG_DATA_HOME/parla/models/ggml-base.en.bin
    pub whisper_model: Option<PathBuf>,
    pub history_enabled: bool,
    /// No `stop` within this many seconds => self-cancel. Guards sway#6456,
    /// which drops the --release edge if another key is pressed while held.
    pub watchdog_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            dictionary: Vec::new(),
            snippets: BTreeMap::new(),
            cleanup: Cleanup::default(),
            whisper_model: None,
            history_enabled: true,
            watchdog_secs: 30,
        }
    }
}

impl Config {
    /// Never fails: a missing or malformed file yields defaults, so a typo in
    /// config.toml degrades to stock behaviour instead of bricking the daemon.
    /// A malformed file is still reported on stderr — degrading is fine, doing
    /// it silently would leave the user with no way to see why their settings
    /// stopped applying.
    pub fn load(path: &Path) -> Self {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Self::default();
        };
        match toml::from_str(&text) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("parla: ignoring {}: {e}", path.display());
                Self::default()
            }
        }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let text = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        std::fs::write(path, text)
    }
}

/// Split out from `config_path` so the env-var precedence is testable without
/// `set_var`, which races cargo's threaded test harness. An exported-but-empty
/// `XDG_CONFIG_HOME` counts as unset, per the XDG basedir spec — otherwise it
/// yields a *relative* path, and a daemon whose CWD is `/` reads the wrong file.
pub fn config_path_from(xdg_config_home: Option<&OsStr>, home: &OsStr) -> PathBuf {
    let base = match xdg_config_home.filter(|x| !x.is_empty()) {
        Some(x) => PathBuf::from(x),
        None => PathBuf::from(home).join(".config"),
    };
    base.join("parla/config.toml")
}

pub fn config_path() -> PathBuf {
    config_path_from(
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        &std::env::var_os("HOME").unwrap_or_default(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_config_keeps_defaults_for_missing_keys() {
        let toml = r#"
            dictionary = ["Kubernetes", "whisper.cpp"]
            [cleanup]
            provider = "openai-compatible"
            base_url = "https://api.groq.com/openai/v1"
        "#;
        let c: Config = toml::from_str(toml).unwrap();
        assert_eq!(c.dictionary, vec!["Kubernetes", "whisper.cpp"]);
        assert_eq!(c.cleanup.provider, "openai-compatible");
        // Untouched keys must keep their defaults, not reset the struct.
        assert_eq!(c.watchdog_secs, 30);
        assert!(c.history_enabled);
        assert_eq!(c.cleanup.model, None);
    }

    #[test]
    fn missing_config_yields_defaults_not_panic() {
        let c = Config::load(std::path::Path::new("/nonexistent/parla/config.toml"));
        assert_eq!(c, Config::default());
    }

    #[test]
    fn garbage_config_yields_defaults() {
        // PID-scoped: concurrent worktrees share /tmp, and a fixed name lets one
        // run's remove_file land inside another's save/load window.
        let dir = std::env::temp_dir().join(format!("parla-test-garbage-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        std::fs::write(&p, "this is not valid toml {{{").unwrap();
        assert_eq!(Config::load(&p), Config::default());
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn roundtrips_through_save_and_load() {
        let dir = std::env::temp_dir().join(format!("parla-test-roundtrip-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        let c = Config {
            dictionary: vec!["Parla".into()],
            cleanup: Cleanup {
                api_key_env: Some("GROQ_API_KEY".into()),
                ..Default::default()
            },
            ..Default::default()
        };
        c.save(&p).unwrap();
        assert_eq!(Config::load(&p), c);
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn debug_never_prints_the_api_key() {
        let secret = "sk-ant-SECRET-VALUE";
        let c = Cleanup {
            provider: "openai-compatible".into(),
            base_url: Some("https://api.groq.com/openai/v1".into()),
            model: Some("llama-3.3-70b".into()),
            api_key_env: Some("GROQ_API_KEY".into()),
            api_key: Some(secret.into()),
        };
        let shown = format!("{c:?}");
        assert!(!shown.contains(secret), "api_key leaked into Debug: {shown}");
        assert!(shown.contains(r#"api_key: Some("<redacted>")"#));
        // Every other field still passes through — redaction, not blanking.
        assert!(shown.contains("openai-compatible"));
        assert!(shown.contains("https://api.groq.com/openai/v1"));
        assert!(shown.contains("llama-3.3-70b"));
        assert!(shown.contains("GROQ_API_KEY"));
        // An absent key reads as absent, not as a redacted one.
        assert!(format!("{:?}", Cleanup { api_key: None, ..c }).contains("api_key: None"));
    }

    #[test]
    fn config_debug_inherits_the_redaction() {
        // Config derives Debug, so the daemon logging a whole Config is covered
        // by Cleanup's impl rather than needing its own.
        let secret = "sk-ant-SECRET-VALUE";
        let c = Config {
            cleanup: Cleanup { api_key: Some(secret.into()), ..Default::default() },
            ..Default::default()
        };
        assert!(!format!("{c:?}").contains(secret));
    }

    #[test]
    fn empty_xdg_config_home_falls_back_to_home_like_an_unset_one() {
        let unset = config_path_from(None, "/home/u".as_ref());
        assert_eq!(unset, PathBuf::from("/home/u/.config/parla/config.toml"));
        assert_eq!(config_path_from(Some("".as_ref()), "/home/u".as_ref()), unset);
        assert_eq!(
            config_path_from(Some("/xdg".as_ref()), "/home/u".as_ref()),
            PathBuf::from("/xdg/parla/config.toml")
        );
    }
}
