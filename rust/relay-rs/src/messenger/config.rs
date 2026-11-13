//! The messenger's configuration: `MessengerConfig.from_app_config`, the
//! model and effort normalisation, the provider command lookup and the
//! provider child environment, as `services/messenger.py` defines them.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::json::{Dict, Value, py_strip};

use super::catalog;

pub const CODEX_DEFAULT_EFFORT: &str = "low";
pub const CLAUDE_DEFAULT_MODEL: &str = "haiku";
pub const CLAUDE_DEFAULT_EFFORT: &str = "default";

const CODEX_CLI_CANDIDATES: [&str; 2] = [
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
];
const CLAUDE_CLI_CANDIDATES: [&str; 3] = [
    "~/.local/bin/claude",
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
];
const CLAUDE_MODELS: [&str; 7] = [
    "best",
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
    "haiku",
];
const CLAUDE_EFFORT_MODELS: [&str; 6] = [
    "best",
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
];
const BASE_EFFORTS: [&str; 5] = ["default", "low", "medium", "high", "xhigh"];

/// Variables only the foreground session may hold; the messenger never
/// inherits voice authority.
pub const FOREGROUND_ONLY_ENVIRONMENT_KEYS: [&str; 10] = [
    "RELAY_CONTEXT_COMPACTION_EVENTS",
    "RELAY_FOREGROUND_GATE_HANDLE",
    "RELAY_PROVIDER_SESSION_ID",
    "RELAY_RECOVERY_GENERATION",
    "RELAY_REPLY_HELPER",
    "RELAY_RUNNER_APP_SESSION",
    "RELAY_SESSION_EVENTS",
    "VOICE_COMMAND_CLAIM_FILE",
    "VOICE_COMMAND_STATE_FILE",
    "VOICE_PROVIDER_TURNS_FILE",
];

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub enabled: bool,
    pub provider: String,
    pub command: String,
    pub model: String,
    pub effort: String,
    pub cwd: String,
}

impl Config {
    /// `MessengerConfig.from_app_config`, from the app config's `[general]`
    /// table.
    pub fn from_general(general: &Dict, cwd: &str) -> Self {
        let mut provider = general.text_or("provider", "codex").to_lowercase();
        if provider != "codex" && provider != "claude" {
            provider = "codex".to_string();
        }
        let enabled = match general.get("messenger_enabled") {
            None => true,
            Some(Value::Bool(flag)) => *flag,
            Some(other) => matches!(
                py_strip(&other.py_str()).to_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            ),
        };
        let defaults = if provider == "codex" {
            (
                catalog::CODEX_MESSENGER_DEFAULT_FAMILY,
                CODEX_DEFAULT_EFFORT,
            )
        } else {
            (CLAUDE_DEFAULT_MODEL, CLAUDE_DEFAULT_EFFORT)
        };
        let raw_model = general.text_or("messenger_model", "default").to_lowercase();
        let raw_effort = general
            .text_or("messenger_effort", "default")
            .to_lowercase();
        let (model, effort) =
            normalize_model_and_effort(&provider, &raw_model, &raw_effort, defaults);
        let mut command = general.text_or("command", &provider);
        if command.is_empty() {
            command = provider.clone();
        }
        Self {
            enabled,
            provider,
            command,
            model,
            effort,
            cwd: resolve_cwd(cwd),
        }
    }
}

trait TextOr {
    fn text_or(&self, key: &str, default: &str) -> String;
}

impl TextOr for Dict {
    /// `str(d.get(key) or default).strip()`.
    fn text_or(&self, key: &str, default: &str) -> String {
        match self.truthy(key) {
            Some(value) => py_strip(&value.py_str()).to_string(),
            None => py_strip(default).to_string(),
        }
    }
}

fn normalize_model_and_effort(
    provider: &str,
    raw_model: &str,
    raw_effort: &str,
    defaults: (&str, &str),
) -> (String, String) {
    let (default_model, default_effort) = defaults;
    let mut raw_effort = raw_effort;
    let model = if provider == "codex" {
        let known = raw_model.is_empty()
            || raw_model == "default"
            || catalog::CODEX_FAMILIES.contains(&raw_model)
            || catalog::codex_family_for_model(raw_model).is_some()
            || raw_model.starts_with("gpt-");
        if !known {
            raw_effort = default_effort;
        }
        catalog::normalize_codex_family(raw_model, default_model)
    } else if raw_model == "default" {
        return (default_model.to_string(), default_effort.to_string());
    } else if CLAUDE_MODELS.contains(&raw_model) {
        raw_model.to_string()
    } else {
        return (default_model.to_string(), default_effort.to_string());
    };
    let effort = if raw_effort == "default" {
        default_effort
    } else if valid_effort(provider, &model, raw_effort) {
        raw_effort
    } else {
        default_effort
    };
    (model, effort.to_string())
}

fn valid_effort(provider: &str, model: &str, effort: &str) -> bool {
    if provider == "codex" {
        return BASE_EFFORTS.contains(&effort) || effort == "max" || effort == "ultra";
    }
    if CLAUDE_EFFORT_MODELS.contains(&model) {
        return BASE_EFFORTS.contains(&effort) || effort == "max";
    }
    effort == "default"
}

/// `Path(cwd or Path.cwd()).expanduser().resolve()`.
fn resolve_cwd(cwd: &str) -> String {
    let path = if cwd.is_empty() {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"))
    } else {
        PathBuf::from(expand_user(cwd))
    };
    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("/"))
            .join(path)
    };
    std::fs::canonicalize(&absolute)
        .unwrap_or(absolute)
        .to_string_lossy()
        .into_owned()
}

/// `os.path.expanduser` for `~` and `~/…`.
pub fn expand_user(path: &str) -> String {
    if path != "~" && !path.starts_with("~/") {
        return path.to_string();
    }
    let Some(home) = std::env::var_os("HOME") else {
        return path.to_string();
    };
    let home = home.to_string_lossy();
    let trimmed = home.trim_end_matches('/');
    let expanded = format!("{trimmed}{}", &path[1..]);
    if expanded.is_empty() {
        "/".to_string()
    } else {
        expanded
    }
}

/// `_command_prefix`: an existing path is the whole command; anything else is
/// split like a shell line. `None` where `shlex.split` would raise.
pub fn command_prefix(command: &str) -> Option<Vec<String>> {
    let expanded = expand_user(py_strip(command));
    if !expanded.is_empty() && Path::new(&expanded).exists() {
        return Some(vec![expanded]);
    }
    let parts = shlex_split(command)?;
    Some(if parts.is_empty() {
        vec![command.to_string()]
    } else {
        parts
    })
}

fn is_executable(path: &str) -> bool {
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// `shutil.which` over `$PATH`.
fn which(executable: &str) -> Option<String> {
    let path = std::env::var("PATH").unwrap_or_else(|_| "/bin:/usr/bin".to_string());
    path.split(':')
        .map(|folder| if folder.is_empty() { "." } else { folder })
        .map(|folder| format!("{folder}/{executable}"))
        .find(|candidate| is_executable(candidate))
}

/// `resolve_messenger_command`: the provider argv, or `None` when its
/// executable cannot be found.
pub fn resolve_command(provider: &str, command: &str) -> Option<Vec<String>> {
    let prefix = command_prefix(command)?;
    let executable = expand_user(&prefix[0]);
    let args = &prefix[1..];
    let with_args = |executable: String| {
        let mut argv = vec![executable];
        argv.extend_from_slice(args);
        argv
    };
    if executable.starts_with('/') || executable.contains('/') {
        return is_executable(&executable).then(|| with_args(executable));
    }
    let candidates: &[&str] = match (provider, executable.as_str()) {
        ("codex", "codex") => &CODEX_CLI_CANDIDATES,
        ("claude", "claude") => &CLAUDE_CLI_CANDIDATES,
        _ => &[],
    };
    for candidate in candidates {
        let expanded = expand_user(candidate);
        if is_executable(&expanded) {
            return Some(with_args(expanded));
        }
    }
    which(&executable).map(with_args)
}

/// `provider_child_environment(actor_role)`: this process's environment
/// without foreground voice authority.
pub fn child_environment(actor_role: &str) -> BTreeMap<OsString, OsString> {
    let mut environment: BTreeMap<OsString, OsString> = std::env::vars_os().collect();
    for key in FOREGROUND_ONLY_ENVIRONMENT_KEYS {
        environment.remove(&OsString::from(key));
    }
    environment.insert("RELAY_ACTOR_ROLE".into(), actor_role.into());
    environment
}

/// `shlex.split(text)`: POSIX rules, no comments.
pub fn shlex_split(text: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = text.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            ' ' | '\t' | '\r' | '\n' => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '\\' => {
                word.push(chars.next()?);
                in_word = true;
            }
            '\'' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '\'' => break,
                        other => word.push(other),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => {
                            let next = chars.next()?;
                            if next != '"' && next != '\\' {
                                word.push('\\');
                            }
                            word.push(next);
                        }
                        other => word.push(other),
                    }
                }
            }
            other => {
                word.push(other);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(word);
    }
    Some(words)
}

/// `shlex.join(words)`.
pub fn shlex_join(words: &[String]) -> String {
    words
        .iter()
        .map(|word| shlex_quote(word))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shlex_quote(word: &str) -> String {
    if word.is_empty() {
        return "''".to_string();
    }
    let safe = word
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c));
    if safe {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    fn general(text: &str) -> Dict {
        parse(text).unwrap().as_dict().unwrap().clone()
    }

    fn config(text: &str) -> Config {
        Config::from_general(&general(text), "/")
    }

    #[test]
    fn defaults_follow_the_provider() {
        let codex = config("{}");
        assert_eq!(
            (
                codex.provider.as_str(),
                codex.model.as_str(),
                codex.effort.as_str()
            ),
            ("codex", "luna", "low")
        );
        assert_eq!(codex.command, "codex");
        assert!(codex.enabled);
        let claude = config(r#"{"provider": " Claude "}"#);
        assert_eq!(
            (
                claude.provider.as_str(),
                claude.model.as_str(),
                claude.effort.as_str()
            ),
            ("claude", "haiku", "default")
        );
        assert_eq!(config(r#"{"provider": "gemini"}"#).provider, "codex");
    }

    #[test]
    fn enabled_reads_booleans_and_their_spellings() {
        assert!(!config(r#"{"messenger_enabled": false}"#).enabled);
        assert!(config(r#"{"messenger_enabled": " YES "}"#).enabled);
        assert!(!config(r#"{"messenger_enabled": "off"}"#).enabled);
        assert!(!config(r#"{"messenger_enabled": null}"#).enabled);
        assert!(config(r#"{"messenger_enabled": 1}"#).enabled);
    }

    #[test]
    fn codex_model_and_effort_normalise_like_python() {
        let pick = |model: &str, effort: &str| {
            let c = config(&format!(
                r#"{{"messenger_model": "{model}", "messenger_effort": "{effort}"}}"#
            ));
            (c.model, c.effort)
        };
        assert_eq!(pick("Sol", "HIGH"), ("sol".into(), "high".into()));
        assert_eq!(
            pick("gpt-6-astra", "ultra"),
            ("astra".into(), "ultra".into())
        );
        assert_eq!(pick("gpt-7", "max"), ("luna".into(), "max".into()));
        // An unknown model resets the effort as well.
        assert_eq!(pick("mystery", "high"), ("luna".into(), "low".into()));
        assert_eq!(pick("default", "bogus"), ("luna".into(), "low".into()));
    }

    #[test]
    fn claude_model_and_effort_normalise_like_python() {
        let pick = |model: &str, effort: &str| {
            let c = config(&format!(
                r#"{{"provider": "claude", "messenger_model": "{model}", "messenger_effort": "{effort}"}}"#
            ));
            (c.model, c.effort)
        };
        assert_eq!(pick("sonnet", "max"), ("sonnet".into(), "max".into()));
        assert_eq!(pick("opus", "ultra"), ("opus".into(), "default".into()));
        assert_eq!(pick("haiku", "high"), ("haiku".into(), "default".into()));
        assert_eq!(
            pick("gpt-6-sol", "high"),
            ("haiku".into(), "default".into())
        );
        assert_eq!(pick("default", "high"), ("haiku".into(), "default".into()));
    }

    #[test]
    fn shlex_matches_python() {
        let split = |text: &str| shlex_split(text);
        assert_eq!(
            split("a 'b c' \"d\\\"e\" f\\ g"),
            Some(vec!["a".into(), "b c".into(), "d\"e".into(), "f g".into()])
        );
        assert_eq!(split("\"a\\b\" ''"), Some(vec!["a\\b".into(), "".into()]));
        assert_eq!(split("'open"), None);
        assert_eq!(split("trailing\\"), None);
        assert_eq!(split("   "), Some(vec![]));
        let words: Vec<String> = vec!["/a b/claude".into(), "--x".into(), "it's".into(), "".into()];
        assert_eq!(shlex_join(&words), "'/a b/claude' --x 'it'\"'\"'s' ''");
        assert_eq!(shlex_split(&shlex_join(&words)), Some(words));
    }

    #[test]
    fn an_absolute_command_must_be_executable() {
        assert_eq!(
            resolve_command("codex", "/bin/sh -c"),
            Some(vec!["/bin/sh".into(), "-c".into()])
        );
        assert_eq!(resolve_command("codex", "/nonexistent/codex"), None);
        assert_eq!(resolve_command("claude", "'unclosed"), None);
    }

    #[test]
    fn the_child_environment_drops_foreground_authority() {
        let environment = child_environment("messenger");
        assert_eq!(
            environment.get(&OsString::from("RELAY_ACTOR_ROLE")),
            Some(&OsString::from("messenger"))
        );
        for key in FOREGROUND_ONLY_ENVIRONMENT_KEYS {
            assert!(!environment.contains_key(&OsString::from(key)));
        }
    }
}
