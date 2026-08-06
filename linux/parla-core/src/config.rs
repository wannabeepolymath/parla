use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    pub fn load(path: &Path) -> Self {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Self::default();
        };
        toml::from_str(&text).unwrap_or_default()
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

pub fn config_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        });
    base.join("parla/config.toml")
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
    fn unreadable_config_yields_defaults_not_panic() {
        let c = Config::load(std::path::Path::new("/nonexistent/parla/config.toml"));
        assert_eq!(c, Config::default());
    }

    #[test]
    fn garbage_config_yields_defaults() {
        let dir = std::env::temp_dir().join("parla-test-garbage");
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        std::fs::write(&p, "this is not valid toml {{{").unwrap();
        assert_eq!(Config::load(&p), Config::default());
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn roundtrips_through_save_and_load() {
        let dir = std::env::temp_dir().join("parla-test-roundtrip");
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
}
