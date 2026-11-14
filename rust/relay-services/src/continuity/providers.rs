//! The continuity agent's provider sessions, as `continuity_agent.py`
//! configures them on the messenger backends of `services/messenger.py`:
//! `create_provider_session_factory`, `CodexContinuityBackend` and
//! `ClaudeContinuityBackend`.
//!
//! Both providers get the same authority: no tools, no MCP servers, no
//! workspace, an ephemeral session and a child environment holding only the
//! launched provider's own subscription login ([`continuity_agent_environment`]).
//! Codex runs `codex app-server --stdio` with every mutation feature off and
//! the continuity prompt as its base and developer instructions; Claude runs
//! `claude --print` in stream-json with `--tools ""`, `--safe-mode` and the
//! continuity prompt as its system prompt. A Claude launch must first pass
//! the subscription-only gate ([`ContinuityBackend::claude_subscription`]).
//!
//! This module decides *what* to launch. Driving the process (the Codex
//! JSON-RPC turn, the Claude stream-json turn) is a [`SessionLauncher`] the
//! daemon supplies; the result is an [`agent::ContinuityProviderSession`].

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use relay_intents::json::{Dict, Value, py_strip};

use super::agent::{
    CONTINUITY_SYSTEM_PROMPT, ContinuityProviderSession, SessionFactory,
    UnavailableContinuitySession, continuity_agent_environment,
};
use crate::Result;
use crate::providers::{catalog, subscription};

pub const CODEX_DEFAULT_EFFORT: &str = "low";
pub const CLAUDE_DEFAULT_MODEL: &str = "haiku";
pub const CLAUDE_DEFAULT_EFFORT: &str = "default";
/// `resolve_codex_family_from_cli(..., timeout=10.0)`.
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);

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

/// `MessengerConfig`.
#[derive(Clone, Debug, PartialEq)]
pub struct MessengerConfig {
    pub enabled: bool,
    pub provider: String,
    pub command: String,
    pub model: String,
    pub effort: String,
    pub cwd: String,
}

/// `str(d.get(key) or default).strip()`.
fn text_or(dict: &Dict, key: &str, default: &str) -> String {
    match dict.truthy(key) {
        Some(value) => py_strip(&value.py_str()).to_string(),
        None => py_strip(default).to_string(),
    }
}

impl MessengerConfig {
    /// `MessengerConfig.from_app_config(app_config, cwd=cwd)`, given the
    /// app config's `[general]` table.
    pub fn from_general(general: &Dict, cwd: &str) -> Self {
        let mut provider = text_or(general, "provider", "codex").to_lowercase();
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
        let raw_model = text_or(general, "messenger_model", "default").to_lowercase();
        let raw_effort = text_or(general, "messenger_effort", "default").to_lowercase();
        let (model, effort) =
            normalize_model_and_effort(&provider, &raw_model, &raw_effort, defaults);
        let mut command = text_or(general, "command", &provider);
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
    } else if CLAUDE_MODELS.contains(&raw_model) && raw_model != "default" {
        raw_model.to_string()
    } else {
        return (default_model.to_string(), default_effort.to_string());
    };
    let valid = if provider == "codex" {
        BASE_EFFORTS.contains(&raw_effort) || raw_effort == "max" || raw_effort == "ultra"
    } else if CLAUDE_EFFORT_MODELS.contains(&model.as_str()) {
        BASE_EFFORTS.contains(&raw_effort) || raw_effort == "max"
    } else {
        raw_effort == "default"
    };
    let effort = if raw_effort == "default" || !valid {
        default_effort
    } else {
        raw_effort
    };
    (model, effort.to_string())
}

/// `Path(cwd or Path.cwd()).expanduser().resolve()`.
fn resolve_cwd(cwd: &str) -> String {
    let current = || std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let path = if cwd.is_empty() {
        current()
    } else {
        PathBuf::from(expand_user(cwd))
    };
    let absolute = if path.is_absolute() {
        path
    } else {
        current().join(path)
    };
    std::fs::canonicalize(&absolute)
        .unwrap_or(absolute)
        .to_string_lossy()
        .into_owned()
}

/// `os.path.expanduser` for `~` and `~/…`.
fn expand_user(path: &str) -> String {
    if path != "~" && !path.starts_with("~/") {
        return path.to_string();
    }
    let Some(home) = std::env::var_os("HOME") else {
        return path.to_string();
    };
    let home = home.to_string_lossy();
    let expanded = format!("{}{}", home.trim_end_matches('/'), &path[1..]);
    if expanded.is_empty() {
        "/".to_string()
    } else {
        expanded
    }
}

/// `_command_prefix(command)`: an existing path is the whole command;
/// anything else is split like a shell line. `None` where `shlex.split`
/// would raise.
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

/// `resolve_messenger_command(provider, command)`: the provider argv, or
/// `None` when its executable cannot be found.
pub fn resolve_messenger_command(provider: &str, command: &str) -> Option<Vec<String>> {
    let prefix = command_prefix(command)?;
    let executable = expand_user(&prefix[0]);
    let with_args = |executable: String| {
        let mut argv = vec![executable];
        argv.extend_from_slice(&prefix[1..]);
        argv
    };
    if executable.contains('/') {
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

/// `shlex.split(text)`: POSIX rules, no comments.
pub fn shlex_split(text: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = text.chars();
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
        .map(|word| {
            if word.is_empty() {
                "''".to_string()
            } else if word
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c))
            {
                word.clone()
            } else {
                format!("'{}'", word.replace('\'', "'\"'\"'"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// `resolve_messenger_catalog_selection(config)`: a Codex family resolved to
/// the newest advertised model and an effort it supports; Claude unchanged.
pub fn resolve_messenger_catalog_selection(
    config: &MessengerConfig,
) -> std::result::Result<MessengerConfig, String> {
    if config.provider != "codex" {
        return Ok(config.clone());
    }
    let family =
        catalog::normalize_codex_family(&config.model, catalog::CODEX_MESSENGER_DEFAULT_FAMILY);
    let prefix = command_prefix(&config.command).ok_or("invalid Codex command")?;
    let models = catalog::fetch_models(&prefix, CATALOG_TIMEOUT)?;
    let resolved = catalog::resolve_family(&family, &models)?;
    let effort = catalog::resolve_effort(&config.effort, &resolved)?;
    Ok(MessengerConfig {
        model: resolved.launch_model().to_string(),
        effort,
        ..config.clone()
    })
}

/// A catalogue resolver: [`resolve_messenger_catalog_selection`] unless a
/// test injects another.
pub type CatalogResolver =
    Arc<dyn Fn(&MessengerConfig) -> std::result::Result<MessengerConfig, String> + Send + Sync>;

/// What `create_provider_session_factory` resolved: a launchable
/// configuration, or the provider and the sanitized reason it cannot launch.
#[derive(Clone, Debug, PartialEq)]
pub enum ContinuityProviderPlan {
    Unavailable {
        provider: String,
        reason_code: String,
    },
    Ready(MessengerConfig),
}

fn table(value: Option<&Value>) -> Dict {
    value.and_then(Value::as_dict).cloned().unwrap_or_default()
}

/// The resolving half of `create_provider_session_factory(app_config,
/// cwd=cwd)`: the configured provider, or only an explicitly complete
/// fallback policy, never a silent fallback.
pub fn plan_provider_session(
    app_config: &Dict,
    cwd: &str,
    resolve_catalog: &CatalogResolver,
) -> ContinuityProviderPlan {
    let mut general = table(app_config.get("general"));
    let continuity = table(app_config.get("continuity"));
    let first = |items: [Option<&Value>; 2]| -> Value {
        items
            .into_iter()
            .flatten()
            .find(|value| value.truthy())
            .cloned()
            .unwrap_or_else(|| Value::from("default"))
    };
    let model = first([continuity.get("model"), general.get("model")]);
    let effort = first([continuity.get("effort"), general.get("orchestrator_effort")]);
    general.insert("messenger_model", model);
    general.insert("messenger_effort", effort);
    let mut config = MessengerConfig::from_general(&general, cwd);
    let mut resolved = resolve_messenger_command(&config.provider, &config.command);
    if resolved.is_none() && continuity.truthy("fallback_provider").is_some() {
        let fields = [
            "fallback_provider",
            "fallback_command",
            "fallback_model",
            "fallback_effort",
        ];
        if fields
            .iter()
            .all(|field| !text_or(&continuity, field, "").is_empty())
        {
            let fallback_provider = text_or(&continuity, "fallback_provider", "").to_lowercase();
            if ["codex", "claude"].contains(&fallback_provider.as_str())
                && fallback_provider != config.provider
            {
                let mut fallback_general = general.clone();
                let field = |key: &str| continuity.get(key).cloned().unwrap_or(Value::Null);
                fallback_general.insert("provider", fallback_provider);
                fallback_general.insert("command", field("fallback_command"));
                fallback_general.insert("messenger_model", field("fallback_model"));
                fallback_general.insert("messenger_effort", field("fallback_effort"));
                let fallback = MessengerConfig::from_general(&fallback_general, cwd);
                if let Some(command) =
                    resolve_messenger_command(&fallback.provider, &fallback.command)
                {
                    config = fallback;
                    resolved = Some(command);
                }
            }
        }
    }
    let Some(resolved) = resolved else {
        return ContinuityProviderPlan::Unavailable {
            provider: config.provider,
            reason_code: "configured_provider_unavailable".to_string(),
        };
    };
    let config = MessengerConfig {
        enabled: true,
        command: shlex_join(&resolved),
        ..config
    };
    match resolve_catalog(&config) {
        Ok(config) => ContinuityProviderPlan::Ready(config),
        Err(_) => ContinuityProviderPlan::Unavailable {
            provider: config.provider,
            reason_code: "configured_model_unavailable".to_string(),
        },
    }
}

/// `CodexContinuityBackend` / `ClaudeContinuityBackend`: one continuity
/// process's launch line, Codex thread parameters and child environment.
#[derive(Clone, Debug, PartialEq)]
pub struct ContinuityBackend {
    pub config: MessengerConfig,
    pub process_identity: String,
    pub incident_id: String,
    pub recovery_generation: String,
    environment: BTreeMap<String, String>,
}

impl ContinuityBackend {
    /// The backend for `config.provider`. `parent` is `os.environ` when
    /// `None`; an invalid recovery generation is a `ValueError`.
    pub fn new(
        config: MessengerConfig,
        process_identity: &str,
        incident_id: &str,
        recovery_generation: &str,
        parent: Option<&BTreeMap<String, String>>,
    ) -> Result<Self> {
        let environment = continuity_agent_environment(
            process_identity,
            incident_id,
            recovery_generation,
            parent,
            Some(if config.provider == "claude" {
                "claude"
            } else {
                "codex"
            }),
        )?;
        Ok(Self {
            config,
            process_identity: process_identity.to_string(),
            incident_id: incident_id.to_string(),
            recovery_generation: recovery_generation.to_string(),
            environment,
        })
    }

    pub fn provider(&self) -> &str {
        &self.config.provider
    }

    /// `spawn_command()`: the provider argv.
    pub fn spawn_command(&self) -> Vec<String> {
        let mut command = command_prefix(&self.config.command)
            .unwrap_or_else(|| vec![self.config.command.clone()]);
        let arguments: Vec<&str> = if self.config.provider == "claude" {
            let mut arguments = vec![
                "--print",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--model",
                &self.config.model,
                "--tools",
                "",
                "--permission-mode",
                "dontAsk",
                "--safe-mode",
                "--no-chrome",
                "--no-session-persistence",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--mcp-config",
                r#"{"mcpServers":{}}"#,
                "--system-prompt",
                CONTINUITY_SYSTEM_PROMPT,
            ];
            if self.config.effort != "default" {
                arguments.extend(["--effort", &self.config.effort]);
            }
            arguments
        } else {
            vec![
                "app-server",
                "--stdio",
                "-c",
                "features.shell_tool=false",
                "-c",
                "features.unified_exec=false",
                "-c",
                "features.apps=false",
                "-c",
                "features.multi_agent=false",
                "-c",
                "features.hooks=false",
                "-c",
                "tools.web_search=false",
                "-c",
                "mcp_servers={}",
            ]
        };
        command.extend(arguments.into_iter().map(str::to_string));
        command
    }

    /// `thread_start_params()`: the Codex `thread/start` parameters.
    pub fn thread_start_params(&self) -> Dict {
        let mut params = Dict::new();
        params.insert("model", self.config.model.as_str());
        params.insert("cwd", self.config.cwd.as_str());
        params.insert("approvalPolicy", "never");
        params.insert("sandbox", "read-only");
        params.insert("baseInstructions", CONTINUITY_SYSTEM_PROMPT);
        params.insert("dynamicTools", Value::List(Vec::new()));
        params.insert("environments", Value::List(Vec::new()));
        params.insert("runtimeWorkspaceRoots", Value::List(Vec::new()));
        params.insert("selectedCapabilityRoots", Value::List(Vec::new()));
        params.insert("ephemeral", true);
        params.insert("developerInstructions", CONTINUITY_SYSTEM_PROMPT);
        params
    }

    /// `child_environment()`: the whole environment of the child process.
    pub fn child_environment(&self) -> &BTreeMap<String, String> {
        &self.environment
    }

    /// The subscription-only gate a Claude launch must pass first, as
    /// `ClaudeMessengerBackend.start` checks it; `None` for Codex.
    pub fn claude_subscription(&self) -> Option<subscription::Readiness> {
        if self.config.provider != "claude" {
            return None;
        }
        let prefix = command_prefix(&self.config.command)?;
        let environment: BTreeMap<OsString, OsString> = self
            .environment
            .iter()
            .map(|(key, value)| (OsString::from(key), OsString::from(value)))
            .collect();
        Some(subscription::check(&prefix, &self.config.cwd, &environment))
    }
}

/// Starts a continuity provider process for a backend and returns the
/// session that drives it (`ProviderContinuitySession` over the messenger
/// backend in Python).
pub trait SessionLauncher: Send + Sync {
    fn launch(&self, backend: ContinuityBackend) -> Result<Arc<dyn ContinuityProviderSession>>;
}

/// `create_provider_session_factory(app_config, cwd=cwd)` as the daemon
/// uses it: resolved on the first incident and reused after, as
/// `Orchestrator.__init__`'s lazy `create_continuity_session` does.
pub fn create_provider_session_factory(
    app_config: Dict,
    cwd: String,
    resolve_catalog: CatalogResolver,
    launcher: Arc<dyn SessionLauncher>,
) -> SessionFactory {
    let plan: Mutex<Option<ContinuityProviderPlan>> = Mutex::new(None);
    Arc::new(move |process_identity, incident_id, generation| {
        let plan = {
            let mut cached = plan.lock().unwrap_or_else(|poison| poison.into_inner());
            cached
                .get_or_insert_with(|| plan_provider_session(&app_config, &cwd, &resolve_catalog))
                .clone()
        };
        match plan {
            ContinuityProviderPlan::Unavailable {
                provider,
                reason_code,
            } => Ok(Arc::new(UnavailableContinuitySession {
                provider,
                reason_code,
            }) as Arc<dyn ContinuityProviderSession>),
            ContinuityProviderPlan::Ready(config) => launcher.launch(ContinuityBackend::new(
                config,
                process_identity,
                incident_id,
                generation,
                None,
            )?),
        }
    })
}

/// The default [`CatalogResolver`].
pub fn default_catalog_resolver() -> CatalogResolver {
    Arc::new(resolve_messenger_catalog_selection)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn general(pairs: &[(&str, &str)]) -> Dict {
        let mut dict = Dict::new();
        for (key, value) in pairs {
            dict.insert(key, *value);
        }
        dict
    }

    #[test]
    fn models_and_efforts_normalise_like_python() {
        let codex = MessengerConfig::from_general(
            &general(&[
                ("messenger_model", "gpt-6.1-terra"),
                ("messenger_effort", "ultra"),
            ]),
            "/",
        );
        assert_eq!(
            (codex.model.as_str(), codex.effort.as_str()),
            ("terra", "ultra")
        );
        let unknown = MessengerConfig::from_general(
            &general(&[("messenger_model", "mystery"), ("messenger_effort", "high")]),
            "/",
        );
        assert_eq!(
            (unknown.model.as_str(), unknown.effort.as_str()),
            ("luna", "low")
        );
        let claude = MessengerConfig::from_general(
            &general(&[
                ("provider", "claude"),
                ("messenger_model", "opus"),
                ("messenger_effort", "max"),
            ]),
            "/",
        );
        assert_eq!(
            (claude.model.as_str(), claude.effort.as_str()),
            ("opus", "max")
        );
        let haiku = MessengerConfig::from_general(
            &general(&[("provider", "claude"), ("messenger_effort", "high")]),
            "/",
        );
        assert_eq!(
            (haiku.model.as_str(), haiku.effort.as_str()),
            ("haiku", "default")
        );
    }

    #[test]
    fn shlex_round_trips() {
        let words = vec!["/a b/claude".to_string(), "it's".to_string(), String::new()];
        assert_eq!(shlex_split(&shlex_join(&words)).unwrap(), words);
        assert!(shlex_split("'open").is_none());
    }
}
