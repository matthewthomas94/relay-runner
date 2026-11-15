//! General tasks: the `/v1/general/tasks` routes over the General work
//! store, and the worker command line and subscription preflight
//! `Daemon.__init__` hands that store (`_general_worker_command`,
//! `_agent_command`, `_general_worker_preflight`).

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{Dict, Value};
use relay_services::continuity::providers::command_prefix;
use relay_services::general_work::{
    CommandFactory, GeneralWorkOptions, PersonalFiles, Preflight, general_worker_environment,
};
use relay_services::personal_storage::PersonalFileStorage;
use relay_services::providers::{catalog, subscription};

use crate::daemon::{
    Daemon, agent_kind, config_table, config_text, find_agent_bin, guard, load_config,
};
use crate::failure::{Class, Failure, Outcome};
use crate::relay_command::{VoiceFields, mutation_metadata, validate_relay_command};
use crate::request::Request;
use crate::router::Reply;

/// `fetch_codex_models_from_cli(timeout=10.0)`.
const CODEX_CATALOG_TIMEOUT: Duration = Duration::from_secs(10);
/// `_general_worker_preflight`'s `codex login status` timeout.
const CODEX_LOGIN_TIMEOUT: Duration = Duration::from_secs(15);

const CLAUDE_GENERAL_TOOLS: &str = "Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch";
const CLAUDE_GENERAL_ALLOWED: &str =
    "Read(./**),Edit(./**),Glob(./**),Grep,Bash,WebSearch,WebFetch";
/// `json.dumps({"sandbox": {...}})` with Python's default separators.
const CLAUDE_GENERAL_SETTINGS: &str = r#"{"sandbox": {"enabled": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false}}"#;

impl Daemon {
    /// `GET /v1/general/tasks?limit=100`.
    pub fn general_task_list(&self, request: &Request) -> Outcome<Reply> {
        let limit = request.query_int("limit", 100)?;
        crate::router::reply(200, self.general_work.list(limit)?)
    }

    /// `GET /v1/general/tasks/{task_id}`.
    pub fn general_task_get(&self, request: &Request) -> Outcome<Reply> {
        crate::router::reply(200, self.general_work.get(&request.unquoted(3))?)
    }

    /// `POST /v1/general/tasks[/{task_id}/{operation}]`.
    pub fn general_task_post(&self, request: &Request) -> Outcome<Reply> {
        let count = request.segments.len();
        let operation = match count {
            3 => "create",
            5 => request.segments[4].as_str(),
            _ => "",
        };
        let task_id = (count >= 4).then(|| request.unquoted(3));
        let mutation = match operation {
            "create" | "review" => Some(mutation_metadata(
                "orchestrator_action",
                task_id.as_deref(),
                Some(if operation == "create" {
                    "create_ticket"
                } else {
                    "edit_ticket"
                }),
                None,
                request.get("request_id"),
            )),
            "dispatch" => Some(mutation_metadata(
                "dispatch_ticket",
                task_id.as_deref(),
                None,
                None,
                None,
            )),
            _ => None,
        };
        validate_relay_command(
            &self.paths,
            &VoiceFields::from_body(&request.body),
            mutation.as_ref(),
        )?;
        let argument = |key: &str| request.get(key).unwrap_or(&Value::Null);
        let task_id = task_id.unwrap_or_default();
        let store = &self.general_work;
        let (status, answer) = match operation {
            "create" => (
                201,
                store.create(
                    argument("title"),
                    argument("description"),
                    argument("acceptance_criteria"),
                    argument("request_id"),
                )?,
            ),
            "dispatch" => {
                let provider = match argument("provider") {
                    Value::Null => None,
                    value => Some(value.py_str()),
                };
                (202, store.dispatch(&task_id, provider.as_deref())?)
            }
            "review" => (
                200,
                store.review(
                    &task_id,
                    argument("run_id"),
                    argument("approve"),
                    argument("summary"),
                )?,
            ),
            "cancel" => (200, store.cancel(&task_id, argument("run_id"))?),
            "artifact" => (
                200,
                store.artifact(&task_id, argument("run_id"), argument("artifact_id"))?,
            ),
            _ => return Err(Failure::value("Unsupported General task operation")),
        };
        crate::router::reply(status, answer)
    }
}

/// `_provider_from_general(general, fallback)`.
pub fn provider_from_general(general: &Dict, fallback: &str) -> String {
    let pick = |key: &str| {
        general
            .get(key)
            .filter(|value| value.truthy())
            .map(Value::py_str)
    };
    let raw = pick("provider")
        .or_else(|| pick("command"))
        .unwrap_or_else(|| {
            if fallback.is_empty() {
                "codex".to_string()
            } else {
                fallback.to_string()
            }
        });
    crate::daemon::agent_kind(Some(&raw)).to_string()
}

/// The `GeneralWorkStore` arguments `Daemon.__init__` passes: the worker
/// command factory, the subscription preflight and personal file storage.
pub fn general_work_options(
    config: &Dict,
    storage: Arc<PersonalFileStorage>,
) -> GeneralWorkOptions {
    let selection = WorkerSelection::new(config);
    let command_factory: CommandFactory = Box::new(move |requested| {
        general_worker_command(&selection, requested).map_err(service_error)
    });
    let preflight: Preflight = Box::new(|provider, command, workspace| {
        general_worker_preflight(provider, command, workspace).map_err(service_error)
    });
    GeneralWorkOptions {
        command_factory: Some(command_factory),
        preflight: Some(preflight),
        runner: None,
        personal_storage: Some(Arc::new(StorageFiles(storage))),
    }
}

/// `PersonalFileStorage` as the General work store calls it.
struct StorageFiles(Arc<PersonalFileStorage>);

impl PersonalFiles for StorageFiles {
    fn register_file(
        &self,
        path: &Path,
        artifact_id: &str,
        active: bool,
        approved: bool,
        adopt: bool,
    ) -> relay_services::Result<Dict> {
        self.0
            .register_file(path, Some(artifact_id), active, approved, adopt)
    }

    fn read(&self, artifact_id: &str, sha256: &str) -> relay_services::Result<Vec<u8>> {
        self.0.read(artifact_id, Some(sha256))
    }

    fn reference(&self, artifact_id: &str, sha256: &str) -> relay_services::Result<Dict> {
        self.0.reference(artifact_id, Some(sha256))
    }

    fn root(&self) -> PathBuf {
        self.0.root.clone()
    }
}

/// A route failure as the General work store reports it, keeping its class.
fn service_error(failure: Failure) -> relay_services::Error {
    let class = match failure.class {
        Class::Value => "ValueError",
        Class::Runtime => "RuntimeError",
        Class::Io => "OSError",
        Class::Validation => "ArtifactValidationError",
        _ => "TypeError",
    };
    relay_services::Error::new(class, failure.message)
}

/// `_effective_worker_agent` for the General store. The store is built
/// before the daemon, so it keeps the startup `[orchestrator]` table, the
/// `[general]` table it last reloaded and its own CLI lookup cache.
struct WorkerSelection {
    orchestrator: Dict,
    general: Mutex<Dict>,
    /// `self.agent_kind`: the startup worker provider.
    agent_kind: String,
    agent_bin: Mutex<String>,
}

impl WorkerSelection {
    fn new(config: &Dict) -> Self {
        let orchestrator = config_table(config, "orchestrator");
        let general = config_table(config, "general");
        let explicit = config_text(&orchestrator, "agent", "");
        let explicit = explicit.trim();
        let agent_kind = if explicit.is_empty() {
            provider_from_general(&general, "codex")
        } else {
            agent_kind(Some(explicit)).to_string()
        };
        Self {
            orchestrator,
            general: Mutex::new(general),
            agent_kind,
            agent_bin: Mutex::new(String::new()),
        }
    }

    /// `_effective_worker_agent()`: the provider, its CLI and `[general]`.
    fn effective(&self) -> Outcome<(String, String, Dict)> {
        let explicit = config_text(&self.orchestrator, "agent", "");
        let explicit = explicit.trim();
        let kind = if explicit.is_empty() {
            match load_config(None) {
                Ok(current) => {
                    if let Some(Value::Dict(table)) = current.get("general") {
                        *guard(&self.general) = table.clone();
                    }
                }
                Err(error) => {
                    eprintln!("[orchestrator] could not reload config for dispatch: {error}");
                }
            }
            provider_from_general(&guard(&self.general), &self.agent_kind)
        } else {
            agent_kind(Some(explicit)).to_string()
        };
        let general = guard(&self.general).clone();
        if kind == self.agent_kind {
            let mut binary = guard(&self.agent_bin);
            if binary.is_empty() {
                *binary = find_agent_bin(&kind, &config_text(&self.orchestrator, "command", ""))?;
            }
            return Ok((kind, binary.clone(), general));
        }
        let binary = find_agent_bin(&kind, "")?;
        Ok((kind, binary, general))
    }
}

/// `_general_worker_command(requested_provider)`.
fn general_worker_command(
    selection: &WorkerSelection,
    requested: Option<&str>,
) -> Outcome<(String, Vec<String>)> {
    let (mut provider, mut binary, mut general) = selection.effective()?;
    if let Some(requested) = requested {
        if requested != "codex" && requested != "claude" {
            return Err(Failure::value("provider must be codex or claude"));
        }
        if requested != provider {
            provider = requested.to_string();
            binary = find_agent_bin(requested, "")?;
            general = Dict::new();
        }
    }
    let model = general.string("model");
    let effort = general.string("orchestrator_effort");
    let command = agent_command(&provider, &binary, &model, &effort, resolve_codex_family)?;
    let command = general_command(&provider, command);
    Ok((provider, command))
}

/// The General-specific confinement `_general_worker_command` applies to
/// `_agent_command`'s line.
fn general_command(provider: &str, mut command: Vec<String>) -> Vec<String> {
    let extend = |command: &mut Vec<String>, args: &[&str]| {
        command.extend(args.iter().map(|arg| arg.to_string()));
    };
    if provider == "codex" {
        command.retain(|arg| {
            arg != "--dangerously-bypass-approvals-and-sandbox"
                && arg != "--dangerously-bypass-hook-trust"
        });
        extend(
            &mut command,
            &[
                "--sandbox",
                "workspace-write",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--ignore-rules",
                "--config",
                "approval_policy=\"never\"",
                "--config",
                "sandbox_workspace_write.writable_roots=[]",
                "--config",
                "forced_login_method=\"chatgpt\"",
            ],
        );
    } else {
        if let Some(index) = command
            .iter()
            .position(|arg| arg == "--dangerously-skip-permissions")
        {
            command.remove(index);
        }
        extend(
            &mut command,
            &[
                "--permission-mode",
                "dontAsk",
                "--tools",
                CLAUDE_GENERAL_TOOLS,
                "--allowedTools",
                CLAUDE_GENERAL_ALLOWED,
                "--restricted",
                "--safe-mode",
                "--no-chrome",
                "--no-session-persistence",
                "--disable-slash-commands",
                "--setting-sources",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
                "--settings",
                CLAUDE_GENERAL_SETTINGS,
            ],
        );
    }
    command
}

/// `resolve_codex_family_from_cli(family, command=agent_bin)`.
pub(crate) fn resolve_codex_family(
    family: &str,
    binary: &str,
) -> Result<catalog::CodexModel, String> {
    let prefix = command_prefix(binary).unwrap_or_else(|| vec![binary.to_string()]);
    let models = catalog::fetch_models(&prefix, CODEX_CATALOG_TIMEOUT)?;
    catalog::resolve_family(family, &models)
}

/// `_agent_command(agent_kind=, agent_bin=, run=)` for an implementation or
/// General run (`run` carries only `model_alias` and `worker_effort`); the
/// spike and review lines share [`crate::worker::launch_line`].
pub fn agent_command(
    kind: &str,
    binary: &str,
    model_alias: &str,
    worker_effort: &str,
    resolve: impl Fn(&str, &str) -> Result<catalog::CodexModel, String>,
) -> Outcome<Vec<String>> {
    crate::worker::launch_line(kind, binary, model_alias, worker_effort, None, resolve)
        .map(|line| line.command)
}

/// `_general_worker_preflight(provider, command, workspace)`: refuses a run
/// that would not use the user's ChatGPT or Claude subscription.
fn general_worker_preflight(provider: &str, command: &[String], workspace: &Path) -> Outcome<()> {
    let environment: BTreeMap<OsString, OsString> =
        general_worker_environment(None).into_iter().collect();
    if provider == "codex" {
        let Some((success, output)) = codex_login_status(&command[0], workspace, &environment)
        else {
            return Err(Failure::value(
                "Relay Runner could not verify your ChatGPT subscription. Sign in to Codex and retry.",
            ));
        };
        if !success || !output.contains("Logged in using ChatGPT") {
            return Err(Failure::value(
                "Sign in to Codex with your ChatGPT subscription before starting this General task.",
            ));
        }
        return Ok(());
    }
    if provider != "claude" {
        return Ok(());
    }
    let readiness = subscription::check(&command[..1], &workspace.to_string_lossy(), &environment);
    if readiness.ready() {
        Ok(())
    } else {
        Err(Failure::value(readiness.message))
    }
}

/// `codex --config forced_login_method="chatgpt" login status` in
/// `workspace`: whether it exited 0 and its stdout + stderr, or `None` when
/// it could not start or outlived the timeout.
fn codex_login_status(
    binary: &str,
    workspace: &Path,
    environment: &BTreeMap<OsString, OsString>,
) -> Option<(bool, String)> {
    let mut child = Command::new(binary)
        .args([
            "--config",
            "forced_login_method=\"chatgpt\"",
            "login",
            "status",
        ])
        .current_dir(workspace)
        .env_clear()
        .envs(environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let reader = |stream: Option<Box<dyn Read + Send>>| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut stream) = stream {
                let _ = stream.read_to_end(&mut bytes);
            }
            String::from_utf8_lossy(&bytes).into_owned()
        })
    };
    let stdout = reader(
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    );
    let stderr = reader(
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    );
    let deadline = Instant::now() + CODEX_LOGIN_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let output = stdout.join().unwrap_or_default() + &stderr.join().unwrap_or_default();
    Some((status.success(), output))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(command: &[String]) -> Vec<&str> {
        command.iter().map(String::as_str).collect()
    }

    fn no_catalog(_: &str, _: &str) -> Result<catalog::CodexModel, String> {
        Err("no catalog in this test".to_string())
    }

    #[test]
    fn claude_general_line_matches_python() {
        let base = agent_command("claude", "/bin/claude", " Default ", "HIGH", no_catalog).unwrap();
        assert_eq!(
            line(&base),
            [
                "/bin/claude",
                "-p",
                "--dangerously-skip-permissions",
                "--verbose",
                "--output-format",
                "stream-json",
                "--effort",
                "high",
            ]
        );
        let general = general_command("claude", base);
        assert_eq!(
            line(&general),
            [
                "/bin/claude",
                "-p",
                "--verbose",
                "--output-format",
                "stream-json",
                "--effort",
                "high",
                "--permission-mode",
                "dontAsk",
                "--tools",
                "Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch",
                "--allowedTools",
                "Read(./**),Edit(./**),Glob(./**),Grep,Bash,WebSearch,WebFetch",
                "--restricted",
                "--safe-mode",
                "--no-chrome",
                "--no-session-persistence",
                "--disable-slash-commands",
                "--setting-sources",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
                "--settings",
                "{\"sandbox\": {\"enabled\": true, \"autoAllowBashIfSandboxed\": true, \
                 \"allowUnsandboxedCommands\": false}}",
            ]
        );
    }

    #[test]
    fn claude_line_keeps_a_model() {
        let command = agent_command("claude", "claude", "Opus", "default", no_catalog).unwrap();
        assert_eq!(line(&command)[5..], ["stream-json", "--model", "opus"]);
    }

    #[test]
    fn codex_general_line_matches_python() {
        let base = agent_command("codex", "/bin/codex", "", "medium", no_catalog).unwrap();
        assert_eq!(
            line(&base),
            [
                "/bin/codex",
                "--search",
                "exec",
                "--json",
                "--ephemeral",
                "--dangerously-bypass-approvals-and-sandbox",
                "--dangerously-bypass-hook-trust",
                "--config",
                "model_reasoning_effort=medium",
            ]
        );
        let general = general_command("codex", base);
        assert_eq!(
            line(&general),
            [
                "/bin/codex",
                "--search",
                "exec",
                "--json",
                "--ephemeral",
                "--config",
                "model_reasoning_effort=medium",
                "--sandbox",
                "workspace-write",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--ignore-rules",
                "--config",
                "approval_policy=\"never\"",
                "--config",
                "sandbox_workspace_write.writable_roots=[]",
                "--config",
                "forced_login_method=\"chatgpt\"",
            ]
        );
    }

    #[test]
    fn codex_default_effort_is_dropped() {
        let command = agent_command("codex", "codex", "", "Default", no_catalog).unwrap();
        assert_eq!(command.len(), 7);
    }

    #[test]
    fn codex_model_resolution_failure_names_the_alias() {
        let error = agent_command("codex", "codex", " Sol ", "", no_catalog).unwrap_err();
        assert_eq!(error.class, Class::Runtime);
        assert_eq!(
            error.message,
            "could not resolve Codex worker model 'sol': no catalog in this test"
        );
    }

    #[test]
    fn requested_provider_must_be_codex_or_claude() {
        let selection = WorkerSelection {
            orchestrator: Dict::new(),
            general: Mutex::new(Dict::new()),
            agent_kind: "claude".into(),
            agent_bin: Mutex::new("/bin/claude".into()),
        };
        let mut orchestrator = Dict::new();
        orchestrator.insert("agent", "claude");
        let selection = WorkerSelection {
            orchestrator,
            ..selection
        };
        let error = general_worker_command(&selection, Some("gemini")).unwrap_err();
        assert_eq!(error.message, "provider must be codex or claude");
        let (provider, command) = general_worker_command(&selection, None).unwrap();
        assert_eq!(provider, "claude");
        assert_eq!(command[0], "/bin/claude");
        assert!(
            !command
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions")
        );
    }

    #[test]
    fn service_errors_keep_their_class() {
        assert_eq!(service_error(Failure::value("x")).class, "ValueError");
        assert_eq!(service_error(Failure::runtime("x")).class, "RuntimeError");
    }
}
