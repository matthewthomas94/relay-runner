//! `POST /v1/orchestrator-actions`: `apply_orchestrator_actions` and the
//! legacy-board ticket authoring it commits (`_create_orchestrator_ticket`,
//! `_edit_orchestrator_ticket`, `_worker_creation_request`,
//! `_commit_ticket_authorship`), with the field cleaners the spike and
//! continuity follow-ups share and `_autonomous_ticket_action`, which the
//! voice command loop authors from.
//!
//! The ticket files, the `next_id` rewrite and the commits are the Python
//! daemon's, byte for byte: `relay_artifacts::tickets::render` writes the
//! file `tickets.write` does, and Git runs with the caller's environment as
//! `_git` runs it, so the commit carries the user's identity.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use relay_artifacts::tickets::{self, Fields, Ticket};
use relay_artifacts::{board_config, pystr};
use relay_intents::json::{Dict, Value, py_is_space, py_strip, str_repr};
use relay_intents::pattern::{self, Regex};
use relay_services::authorization::mark_mutations_canceled;
use relay_services::command_actions::{refined_command_summary, refined_ticket_title};
use relay_store::commands::CommandStatus;

use crate::daemon::{Daemon, guard, resolve_path};
use crate::failure::{Class, Failure, Outcome};
use crate::relay_command::{VoiceFields, mutation_metadata, validate_relay_command};
use crate::request::Request;
use crate::router::{Reply, reply};

/// `ORCHESTRATOR_ACTION_KINDS`.
const ACTION_KINDS: [&str; 4] = [
    "create_ticket",
    "edit_ticket",
    "update_dependencies",
    "request_worker",
];
/// `WORKER_SIZING_FIELDS`.
pub(crate) const WORKER_SIZING_FIELDS: [&str; 4] = [
    "worker_model",
    "worker_effort",
    "worker_sizing_rationale",
    "worker_provider_notes",
];
/// `CLAUDE_WORKER_EFFORTS`, sorted.
const CLAUDE_WORKER_EFFORTS: [&str; 5] = ["high", "low", "max", "medium", "xhigh"];
/// `CODEX_WORKER_EFFORTS`, sorted.
const CODEX_WORKER_EFFORTS: [&str; 4] = ["high", "low", "medium", "xhigh"];
const PRIORITIES: [&str; 4] = ["urgent", "high", "medium", "low"];

/// Whether a failure is one Python's `except ValueError` catches.
pub(crate) fn is_value_error(failure: &Failure) -> bool {
    matches!(failure.class, Class::Value | Class::Storage { .. })
}

/// `str(value or "")`.
fn text_or_empty(value: Option<&Value>) -> String {
    value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default()
}

/// `re.sub(r"\s+", " ", text).strip()`.
fn collapse_whitespace(text: &str) -> String {
    text.split(py_is_space)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// `_clean_required_text(value, field)`.
pub(crate) fn clean_required_text(value: Option<&Value>, field: &str) -> Outcome<String> {
    let text = collapse_whitespace(&text_or_empty(value));
    if text.is_empty() {
        return Err(Failure::value(format!("{field} is required")));
    }
    Ok(text)
}

/// `_clean_optional_text(value)`.
pub(crate) fn clean_optional_text(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => None,
        value => Some(collapse_whitespace(&text_or_empty(value))).filter(|text| !text.is_empty()),
    }
}

/// `_clean_optional_multiline_text(value)`.
fn clean_optional_multiline_text(value: Option<&Value>) -> Option<String> {
    if matches!(value, None | Some(Value::Null)) {
        return None;
    }
    let text = text_or_empty(value);
    let lines: Vec<String> = pystr::splitlines(&text)
        .into_iter()
        .map(collapse_whitespace)
        .filter(|line| !line.is_empty())
        .collect();
    Some(py_strip(&lines.join("\n")).to_string()).filter(|text| !text.is_empty())
}

/// `_clean_markdown(value, field)`.
fn clean_markdown(value: Option<&Value>, field: &str) -> Outcome<String> {
    let text = py_strip(&text_or_empty(value)).to_string();
    if text.is_empty() {
        return Err(Failure::value(format!("{field} is required")));
    }
    Ok(text)
}

/// `_string_list(value, field)`.
fn string_list(value: Option<&Value>, field: &str) -> Outcome<Vec<String>> {
    match value {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::List(items)) => Ok(items
            .iter()
            .map(|item| py_strip(&item.py_str()).to_string())
            .filter(|item| !item.is_empty())
            .collect()),
        Some(_) => Err(Failure::value(format!("{field} must be a list"))),
    }
}

/// `_ticket_id_list(value, field)`.
fn ticket_id_list(value: Option<&Value>, field: &str) -> Outcome<Vec<String>> {
    Ok(string_list(value, field)?
        .into_iter()
        .map(|item| item.to_uppercase())
        .collect())
}

/// Python's `repr()` of a list of strings.
fn list_repr(items: &[String]) -> String {
    let parts: Vec<String> = items.iter().map(|item| str_repr(item)).collect();
    format!("[{}]", parts.join(", "))
}

/// `_acceptance_criteria_lines(value)`.
fn acceptance_criteria_lines(value: Option<&Value>) -> Outcome<Vec<String>> {
    let criteria = string_list(value, "acceptance_criteria")?;
    if criteria.is_empty() {
        return Err(Failure::value("acceptance_criteria is required"));
    }
    Ok(criteria)
}

/// `_structured_ticket_body(description, acceptance_criteria)`.
pub(crate) fn structured_ticket_body(description: &str, criteria: &[String]) -> String {
    let checks: Vec<String> = criteria
        .iter()
        .map(|item| format!("- [ ] {item}"))
        .collect();
    format!(
        "## Description\n\n{description}\n\n## Acceptance criteria\n\n{}\n",
        checks.join("\n")
    )
}

/// `_action_worker_sizing(action)`: the four fields, in order.
fn action_worker_sizing(action: &Dict) -> Outcome<Vec<(&'static str, String)>> {
    let mut sizing = Vec::new();
    for field in WORKER_SIZING_FIELDS {
        sizing.push((field, clean_required_text(action.get(field), field)?));
    }
    let effort = sizing[1].1.to_lowercase();
    if !CLAUDE_WORKER_EFFORTS.contains(&effort.as_str()) {
        return Err(Failure::value(format!(
            "invalid worker_effort {}",
            str_repr(&sizing[1].1)
        )));
    }
    sizing[1].1 = effort;
    Ok(sizing)
}

/// `_execution_mode(value)`.
fn execution_mode(value: Option<&Value>) -> Outcome<String> {
    let raw = value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_else(|| "implementation".to_string());
    let mode = py_strip(&raw).to_lowercase();
    if !tickets::VALID_EXECUTION_MODES.contains(&mode.as_str()) {
        return Err(Failure::value(format!(
            "invalid execution_mode: {}",
            str_repr(&mode)
        )));
    }
    Ok(mode)
}

/// `str(action.get("priority") or default).strip().lower()`, checked.
fn priority(value: Option<&Value>, default: &str) -> Outcome<String> {
    let raw = value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_else(|| default.to_string());
    let priority = py_strip(&raw).to_lowercase();
    if !PRIORITIES.contains(&priority.as_str()) {
        return Err(Failure::value(format!(
            "invalid priority: {}",
            str_repr(&priority)
        )));
    }
    Ok(priority)
}

/// `_body_section(ticket, heading)`: the stripped text under `## heading`
/// up to the next `## ` line, as the multiline, dot-all pattern
/// `^## {heading}\s*\n(.*?)(?=^## |\Z)` finds it.
pub(crate) fn body_section(body: &str, heading: &str) -> String {
    let marker = format!("## {heading}");
    let line_start = |index: usize| index == 0 || body.as_bytes()[index - 1] == b'\n';
    let mut search = 0;
    while let Some(offset) = body[search..].find(&marker) {
        let start = search + offset;
        search = start + 1;
        if !line_start(start) {
            continue;
        }
        // `\s*\n`: the whitespace run after the heading, ending at its
        // last newline.
        let after = start + marker.len();
        let run_end = body[after..]
            .char_indices()
            .find(|(_, character)| !py_is_space(*character))
            .map_or(body.len(), |(index, _)| after + index);
        let Some(newline) = body[after..run_end].rfind('\n') else {
            continue;
        };
        let content_start = after + newline + 1;
        let mut end = body.len();
        let mut position = content_start;
        loop {
            if body[position..].starts_with("## ") && line_start(position) {
                end = position;
                break;
            }
            match body[position..].find('\n') {
                Some(index) => position += index + 1,
                None => break,
            }
        }
        return py_strip(&body[content_start..end]).to_string();
    }
    String::new()
}

/// `_body_acceptance_criteria(ticket)`.
fn body_acceptance_criteria(body: &str) -> Outcome<Vec<String>> {
    let section = body_section(body, "Acceptance criteria");
    let mut criteria = Vec::new();
    for line in pystr::splitlines(&section) {
        let stripped = py_strip(line);
        for prefix in ["- [ ] ", "- [x] ", "- [X] "] {
            if let Some(rest) = stripped.strip_prefix(prefix) {
                criteria.push(py_strip(rest).to_string());
                break;
            }
        }
    }
    if criteria.is_empty() {
        return Err(Failure::value("acceptance_criteria is required"));
    }
    Ok(criteria)
}

/// Python's `str(OSError)` for a file the daemon could not read.
fn os_error_text(error: &std::io::Error, path: &Path) -> String {
    let description = error.to_string();
    let description = description
        .rsplit_once(" (os error ")
        .map_or(description.as_str(), |(text, _)| text);
    match error.raw_os_error() {
        Some(code) => format!(
            "[Errno {code}] {description}: {}",
            str_repr(&path.to_string_lossy())
        ),
        None => description.to_string(),
    }
}

/// `_ticket_config(config_path)`: the prefix, `next_id` and the file text.
pub(crate) fn ticket_config(config_path: &Path) -> Outcome<(String, i64, String)> {
    let content = std::fs::read(config_path).map_err(|error| {
        Failure::value(format!(
            "could not read {}: {}",
            config_path.display(),
            os_error_text(&error, config_path)
        ))
    })?;
    let text = pystr::universal_newlines(pystr::decode_utf8(&content)?);
    let (prefix, next_id) = board_config::ticket_config(&text)?;
    Ok((prefix, next_id, text))
}

/// `_write_ticket_config_next_id(config_path, config_text, next_id)`.
pub(crate) fn write_ticket_config_next_id(
    config_path: &Path,
    config_text: &str,
    next_id: i64,
) -> Outcome<()> {
    std::fs::write(
        config_path,
        board_config::with_next_id(config_text, next_id),
    )?;
    Ok(())
}

/// `_mint_ticket_id(repo)`.
fn mint_ticket_id(repo: &Path) -> Outcome<String> {
    let orch_dir = repo.join(".orchestrator");
    let config_path = orch_dir.join("config.toml");
    let (prefix, next_id, config_text) = ticket_config(&config_path)?;
    let mut number = next_id;
    while orch_dir.join(format!("{prefix}-{number}.md")).exists() {
        number += 1;
    }
    write_ticket_config_next_id(&config_path, &config_text, number + 1)?;
    Ok(format!("{prefix}-{number}"))
}

/// The number after a ticket id's last `-`, when it is all digits.
fn ticket_number(ticket_id: &str) -> Option<i64> {
    let (_, digits) = ticket_id.rsplit_once('-')?;
    if digits.is_empty() || !digits.chars().all(|character| character.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// `_advance_ticket_config_past(repo, ticket_id)`.
fn advance_ticket_config_past(repo: &Path, ticket_id: &str) -> Outcome<()> {
    let config_path = repo.join(".orchestrator").join("config.toml");
    let (prefix, next_id, config_text) = ticket_config(&config_path)?;
    let upper = ticket_id.to_uppercase();
    let Some(digits) = upper.strip_prefix(&format!("{prefix}-")) else {
        return Ok(());
    };
    if digits.is_empty() || !digits.chars().all(|character| character.is_ascii_digit()) {
        return Ok(());
    }
    let number: i64 = digits.parse().unwrap_or(i64::MAX - 1);
    if number >= next_id {
        write_ticket_config_next_id(&config_path, &config_text, number + 1)?;
    }
    Ok(())
}

/// A finished `git -C <repo> ...`, as `_git(..., check=False)` returns it.
pub(crate) struct GitOutput {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

impl GitOutput {
    /// `(stderr or stdout).strip()`.
    pub fn message(&self) -> String {
        let text = if self.stderr.is_empty() {
            &self.stdout
        } else {
            &self.stderr
        };
        py_strip(text).to_string()
    }
}

/// `_git(repo, *args, check=False)`: the caller's environment and identity.
pub(crate) fn git(repo: &Path, arguments: &[&str]) -> Outcome<GitOutput> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .output()?;
    Ok(GitOutput {
        status: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).replace("\r\n", "\n"),
        stderr: String::from_utf8_lossy(&output.stderr).replace("\r\n", "\n"),
    })
}

/// `_ticket_authoring_pathspecs(repo, paths)`: repository-relative, in
/// first-seen order.
fn authoring_pathspecs(repo: &Path, paths: &[PathBuf]) -> Outcome<Vec<String>> {
    let root = resolve_path(&repo.to_string_lossy());
    let mut seen = HashSet::new();
    let mut specs = Vec::new();
    for path in paths {
        let resolved = resolve_path(&path.to_string_lossy());
        let relative = resolved.strip_prefix(&root).map_err(|_| {
            Failure::value(format!(
                "{} is not in the subpath of {}",
                str_repr(&resolved.to_string_lossy()),
                str_repr(&root.to_string_lossy())
            ))
        })?;
        let spec = relative.to_string_lossy().into_owned();
        if seen.insert(spec.clone()) {
            specs.push(spec);
        }
    }
    Ok(specs)
}

/// `_ensure_ticket_authoring_paths_clean(repo, paths)`.
pub(crate) fn ensure_ticket_authoring_paths_clean(repo: &Path, paths: &[PathBuf]) -> Outcome<()> {
    let specs = authoring_pathspecs(repo, paths)?;
    let mut arguments = vec!["status", "--porcelain", "--untracked-files=all", "--"];
    arguments.extend(specs.iter().map(String::as_str));
    let status = git(repo, &arguments)?;
    if status.status != 0 {
        return Err(Failure::value(format!(
            "could not check ticket-authoring state: {}",
            py_strip(&status.stderr)
        )));
    }
    if !py_strip(&status.stdout).is_empty() {
        return Err(Failure::value(format!(
            "ticket authoring blocked by existing changes to {}",
            specs.join(", ")
        )));
    }
    Ok(())
}

/// `_commit_ticket_authorship(repo, paths, ticket_ids, message=...)`.
pub(crate) fn commit_ticket_authorship(
    repo: &Path,
    paths: &[PathBuf],
    ticket_ids: &[String],
    message: Option<&str>,
) -> Outcome<()> {
    let specs = authoring_pathspecs(repo, paths)?;
    let status = git(repo, &["status", "--porcelain", "--untracked-files=all"])?;
    if status.status != 0 {
        return Err(Failure::value(format!(
            "could not check repository status before ticket commit: {}",
            py_strip(&status.stderr)
        )));
    }
    let staged = git(repo, &["diff", "--cached", "--name-only"])?;
    if staged.status != 0 {
        return Err(Failure::value(format!(
            "could not inspect staged changes before ticket commit: {}",
            py_strip(&staged.stderr)
        )));
    }
    if !py_strip(&staged.stdout).is_empty() {
        return Err(Failure::value(
            "ticket authoring blocked by already-staged changes",
        ));
    }
    let with_specs = |head: &[&str]| -> Vec<String> {
        head.iter()
            .map(|part| part.to_string())
            .chain(specs.iter().cloned())
            .collect()
    };
    let add_arguments = with_specs(&["add", "--"]);
    let add = git(repo, &as_strs(&add_arguments))?;
    if add.status != 0 {
        return Err(Failure::value(format!(
            "could not stage ticket authorship: {}",
            add.message()
        )));
    }
    let default_message = format!(
        "chore: author {} ticket{}",
        ticket_ids.join(", "),
        if ticket_ids.len() == 1 { "" } else { "s" }
    );
    let message = message.unwrap_or(&default_message);
    let commit_arguments = with_specs(&["commit", "-m", message, "--"]);
    let commit = git(repo, &as_strs(&commit_arguments))?;
    if commit.status != 0 {
        let restore_arguments = with_specs(&["restore", "--staged", "--worktree", "--"]);
        git(repo, &as_strs(&restore_arguments))?;
        return Err(Failure::value(format!(
            "ticket authoring commit failed: {}",
            commit.message()
        )));
    }
    Ok(())
}

fn as_strs(items: &[String]) -> Vec<&str> {
    items.iter().map(String::as_str).collect()
}

/// `_required_sizing_value(ticket, field)`.
fn required_sizing_value(ticket: &Ticket, field: &str) -> String {
    py_strip(ticket.raw_fields.get(field).unwrap_or_default()).to_string()
}

/// `_resolve_worker_model(worker_model, agent_kind)`: refuses a tier or
/// scope the configured provider cannot run.
fn resolve_worker_model(worker_model: &str, agent_kind: &str) -> Outcome<String> {
    let value = py_strip(worker_model).to_lowercase();
    if let Some((provider, model)) = value.split_once(':') {
        let model = py_strip(model);
        if !["codex", "claude"].contains(&provider) || model.is_empty() {
            return Err(Failure::value(format!(
                "invalid worker_model {}",
                str_repr(worker_model)
            )));
        }
        if provider != agent_kind {
            return Err(Failure::value(format!(
                "worker_model {} is scoped to {provider}, but configured worker provider is {agent_kind}",
                str_repr(worker_model)
            )));
        }
        if agent_kind == "codex" {
            return Ok(relay_artifacts::codex::normalize_codex_family(
                model,
                relay_artifacts::codex::CODEX_DEFAULT_FAMILY,
            ));
        }
        return Ok(model.to_string());
    }
    let tier = match (agent_kind, value.as_str()) {
        ("codex", "fast") => Some("luna"),
        ("codex", "balanced") => Some("sol"),
        ("codex", "strong") => Some("astra"),
        ("claude", "fast") => Some("haiku"),
        ("claude", "balanced") => Some("sonnet"),
        ("claude", "strong") => Some("opus"),
        _ => None,
    };
    tier.map(str::to_string).ok_or_else(|| {
        let allowed = if ["codex", "claude"].contains(&agent_kind) {
            "balanced, fast, strong"
        } else {
            ""
        };
        Failure::value(format!(
            "invalid worker_model {} for {agent_kind}; expected one of {allowed} or {agent_kind}:<model>",
            str_repr(worker_model)
        ))
    })
}

/// `_validate_worker_effort(...)`.
fn validate_worker_effort(
    worker_effort: &str,
    worker_model: &str,
    agent_kind: &str,
    provider_notes: &str,
) -> Outcome<String> {
    let effort = py_strip(worker_effort).to_lowercase();
    let model = py_strip(worker_model).to_lowercase();
    let scoped_astra =
        agent_kind == "codex" && ["codex:astra", "codex:gpt-6-astra"].contains(&model.as_str());
    let allowed: Vec<&str> = if scoped_astra {
        vec!["high", "low", "max", "medium", "ultra", "xhigh"]
    } else if agent_kind == "claude" {
        CLAUDE_WORKER_EFFORTS.to_vec()
    } else {
        CODEX_WORKER_EFFORTS.to_vec()
    };
    if !allowed.contains(&effort.as_str()) {
        return Err(Failure::value(format!(
            "invalid worker_effort {} for {agent_kind}; expected one of {}",
            str_repr(worker_effort),
            allowed.join(", ")
        )));
    }
    if effort == "max" && !scoped_astra {
        let scoped_to_claude = model.starts_with("claude:");
        let notes = py_strip(provider_notes).to_lowercase();
        if !scoped_to_claude || notes.is_empty() || notes == "none" {
            return Err(Failure::value(
                "worker_effort 'max' requires a Claude-scoped worker_model and \
                 worker_provider_notes documenting the Codex limitation",
            ));
        }
    }
    Ok(effort)
}

/// `resolve_worker_sizing(ticket, agent_kind, general={})`: the ticket's
/// own sizing, checked against the provider.
fn resolve_worker_sizing(
    ticket: &Ticket,
    agent_kind: &str,
) -> Outcome<Vec<(&'static str, String)>> {
    let missing: Vec<&str> = WORKER_SIZING_FIELDS
        .iter()
        .copied()
        .filter(|field| required_sizing_value(ticket, field).is_empty())
        .collect();
    if !missing.is_empty() {
        return Err(Failure::value(format!(
            "missing worker sizing metadata: {}",
            missing.join(", ")
        )));
    }
    let worker_model = required_sizing_value(ticket, "worker_model");
    let provider_notes = required_sizing_value(ticket, "worker_provider_notes");
    resolve_worker_model(&worker_model, agent_kind)?;
    let effort = validate_worker_effort(
        &required_sizing_value(ticket, "worker_effort"),
        &worker_model,
        agent_kind,
        &provider_notes,
    )?;
    Ok(vec![
        ("worker_model", worker_model),
        ("worker_effort", effort),
        (
            "worker_sizing_rationale",
            required_sizing_value(ticket, "worker_sizing_rationale"),
        ),
        ("worker_provider_notes", provider_notes),
    ])
}

// -- _autonomous_ticket_action ------------------------------------------------

/// `_inherited_worker_sizing` through `_normalized_default_worker_sizing`:
/// the General Settings sizing when `subagent_sizing_policy` is
/// `user_default`.
fn normalized_default_worker_sizing(general: &Dict) -> Option<Vec<(&'static str, String)>> {
    let policy = py_strip(&general.string("subagent_sizing_policy")).to_lowercase();
    if policy != "user_default" {
        return None;
    }
    let agent = crate::general::provider_from_general(general, "codex");
    let requested = py_strip(&general.string("model")).to_lowercase();
    let model = if agent == "codex" {
        relay_artifacts::codex::normalize_codex_family(
            &requested,
            relay_artifacts::codex::CODEX_DEFAULT_FAMILY,
        )
    } else if [
        "claude-fable-5-2",
        "claude-fable-5-1",
        "fable",
        "opus",
        "sonnet",
        "haiku",
    ]
    .contains(&requested.as_str())
    {
        requested
    } else {
        "opus".to_string()
    };
    let options: Vec<&str> = if agent == "codex" {
        vec!["low", "medium", "high", "xhigh", "max", "ultra"]
    } else if [
        "claude-fable-5-2",
        "claude-fable-5-1",
        "fable",
        "opus",
        "sonnet",
    ]
    .contains(&model.as_str())
    {
        vec!["low", "medium", "high", "xhigh", "max"]
    } else {
        vec!["low"]
    };
    let raw_effort = general
        .truthy("orchestrator_effort")
        .or_else(|| general.truthy("codex_reasoning_effort"))
        .map(Value::py_str)
        .unwrap_or_default();
    let mut effort = py_strip(&raw_effort).to_lowercase();
    if effort == "default" {
        effort = "medium".to_string();
    }
    if !options.contains(&effort.as_str()) {
        effort = if options.contains(&"medium") {
            "medium".to_string()
        } else {
            "low".to_string()
        };
    }
    Some(vec![
        ("worker_model", format!("{agent}:{model}")),
        ("worker_effort", effort),
        (
            "worker_sizing_rationale",
            "Inherited provider, model, and effort from Relay Runner General Settings.".to_string(),
        ),
        (
            "worker_provider_notes",
            "Use my defaults preserves explicit stable provider selections; Codex resolves \
             Astra/Sol/Terra/Luna then uses model_reasoning_effort and Claude uses --effort."
                .to_string(),
        ),
    ])
}

/// `_autonomous_worker_sizing(general)`.
fn autonomous_worker_sizing(general: &Dict) -> Vec<(&'static str, String)> {
    normalized_default_worker_sizing(general).unwrap_or_else(|| {
        vec![
            ("worker_model", "balanced".to_string()),
            ("worker_effort", "medium".to_string()),
            (
                "worker_sizing_rationale",
                "Autonomous Relay command authoring used a conservative default because the PM \
                 did not supply explicit sizing."
                    .to_string(),
            ),
            (
                "worker_provider_notes",
                "Codex uses model_reasoning_effort and Claude uses --effort; the backstage \
                 authoring loop writes the same ticket schema for both providers."
                    .to_string(),
            ),
        ]
    })
}

/// `_GENERIC_TICKET_REQUEST_RE`.
static GENERIC_TICKET_REQUEST_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        concat!(
            r"\b(ticket|card|task|issue)\b.*\b(this|that|conversation|discussion|what\s+we\s+discussed|also)\b",
            r"|\b(write|create|make)\b.*\b(ticket|card|task|issue)\b",
        ),
        true,
    )
});
/// `_PRIVATE_CONTEXT_LINE_RE`.
static PRIVATE_CONTEXT_LINE_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        concat!(
            r"\b(raw\s+transcript|source_text|hidden\s+reasoning|tool\s+log|shell\s+output|scratchpad|prompt)\b",
            r"|(`|\$\(|&&|\|\||\s;\s|",
            r"\b(?:bash|cat|curl|git|grep|npm|pnpm|python|python3|sh|swift|xcodebuild|yarn|zsh)\s+)",
        ),
        true,
    )
});
static CONTEXT_TITLE_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^(?:title|ticket)\s*:\s*(.+)$", true));
static BULLET_PREFIX_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^[-*]\s*(?:\[[ xX]\]\s*)?", false));
static CRITERIA_HEADING_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^acceptance\s+criteria\s*:?\s*$", true));
static BULLET_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"^[-*]\s*(?:\[[ xX]\]\s*)?(.+)$", false));
static LABEL_RE: LazyLock<Regex> = LazyLock::new(|| pattern::compile(r"^[A-Za-z ]+:$", false));

/// `_sanitize_refined_ticket_context(value)`.
fn sanitize_refined_ticket_context(value: &str) -> Option<String> {
    let text = clean_optional_multiline_text(Some(&Value::from(value)))?;
    let mut lines = Vec::new();
    for raw in pystr::splitlines(&text) {
        let line = collapse_whitespace(raw);
        if line.is_empty() || pattern::search(&PRIVATE_CONTEXT_LINE_RE, &line) {
            continue;
        }
        lines.push(line);
        if lines.len() >= 18 {
            break;
        }
    }
    let sanitized = py_strip(&lines.join("\n")).to_string();
    if sanitized.is_empty() {
        return None;
    }
    let clipped: String = sanitized.chars().take(2400).collect();
    Some(clipped.trim_end_matches(py_is_space).to_string())
}

/// `title[:73].rstrip() + "..."` past 76 characters.
fn clip_title(title: &str) -> String {
    if title.chars().count() > 76 {
        let kept: String = title.chars().take(73).collect();
        format!("{}...", kept.trim_end_matches(py_is_space))
    } else {
        title.to_string()
    }
}

/// `_context_title(context, source_text)`.
fn context_title(context: &str, source_text: &str) -> String {
    for line in pystr::splitlines(context) {
        let candidate = pattern::group(&CONTEXT_TITLE_RE, line, 1).unwrap_or(line);
        let candidate = pattern::sub(&BULLET_PREFIX_RE, candidate, 1);
        let candidate = py_strip(&candidate);
        if !candidate.is_empty() {
            return clip_title(candidate.trim_end_matches('.'));
        }
    }
    refined_ticket_title(source_text)
}

/// `_context_acceptance_criteria(context)`.
fn context_acceptance_criteria(context: &str) -> Vec<String> {
    let mut criteria = Vec::new();
    let mut in_section = false;
    for line in pystr::splitlines(context) {
        let stripped = py_strip(line);
        if pattern::search(&CRITERIA_HEADING_RE, stripped) {
            in_section = true;
            continue;
        }
        let bullet = pattern::group(&BULLET_RE, stripped, 1);
        if let Some(item) = bullet.filter(|_| in_section || criteria.len() < 4) {
            let item = py_strip(item).trim_end_matches('.');
            if !item.is_empty() {
                criteria.push(item.to_string());
            }
        } else if bullet.is_none()
            && in_section
            && !stripped.is_empty()
            && !pattern::search(&LABEL_RE, stripped)
        {
            criteria.push(stripped.trim_end_matches('.').to_string());
        }
        if criteria.len() >= 6 {
            break;
        }
    }
    criteria
}

/// `_generic_ticket_request_without_context(source_text)`.
fn generic_ticket_request_without_context(source_text: &str) -> bool {
    let summary = refined_command_summary(source_text).to_lowercase();
    let generic_summary = [
        "ticket also",
        "ticket conversation",
        "ticket discussion",
        "requested project change",
    ]
    .iter()
    .any(|phrase| summary.contains(phrase));
    pattern::search(&GENERIC_TICKET_REQUEST_RE, source_text) && generic_summary
}

/// `_autonomous_ticket_action(source_text, general, refined_context=...)`:
/// the `create_ticket` action the command loop authors for a work command.
pub(crate) fn autonomous_ticket_action(
    source_text: &str,
    general: &Dict,
    refined_context: &str,
) -> Outcome<Dict> {
    let context = sanitize_refined_ticket_context(refined_context);
    if context.is_none() && generic_ticket_request_without_context(source_text) {
        return Err(Failure::value(
            "Blocked generic ticket request: PM-refined conversation context is required \
             before creating a visible ticket.",
        ));
    }
    let summary = refined_command_summary(source_text);
    let mut title = refined_ticket_title(source_text);
    let mut description = format!(
        "Backstage orchestrator summary: {summary}\n\n\
         Use the repository context to identify the affected files and exact behavior. \
         The raw Relay transcript remains private orchestrator metadata and is not part \
         of this visible ticket."
    );
    let mut criteria: Vec<String> = vec![
        "The requested behavior summarized above is implemented in the active repo.".to_string(),
        "Focused verification covers the affected behavior or the run log explains why \
         verification was not practical."
            .to_string(),
        "The worker run log records what changed and any follow-up needed.".to_string(),
    ];
    if let Some(context) = &context {
        title = context_title(context, source_text);
        description = format!(
            "PM-refined context:\n\n{context}\n\n\
             Raw Relay transcripts, hidden reasoning, tool logs, and shell output remain \
             private orchestrator metadata and are not part of this visible ticket."
        );
        let context_criteria = context_acceptance_criteria(context);
        if !context_criteria.is_empty() {
            criteria = context_criteria;
        }
    }
    let mut action = Dict::new();
    action.insert("kind", "create_ticket");
    action.insert("title", title);
    action.insert("description", description);
    action.insert(
        "acceptance_criteria",
        Value::List(criteria.into_iter().map(Value::from).collect()),
    );
    action.insert("priority", "medium");
    action.insert("depends_on", Value::List(Vec::new()));
    for (field, value) in autonomous_worker_sizing(general) {
        action.insert(field, value);
    }
    Ok(action)
}

// -- apply_orchestrator_actions -----------------------------------------------

/// The arguments of `apply_orchestrator_actions`.
pub(crate) struct ActionBatch {
    pub repo_path: String,
    /// `body.get("actions") or []`.
    pub actions: Value,
    pub request_id: Option<Value>,
    pub voice: VoiceFields,
}

/// One `request_worker` action, waiting for the commit.
struct WorkerRequest {
    public: Dict,
    ticket_id: String,
    action_index: i64,
    dispatcher_context: Option<String>,
}

/// `_orchestrator_action_mutation(raw_action, action_index=, request_id=)`.
fn action_mutation(action: &Dict, index: i64, request_id: Option<&str>) -> Dict {
    let ticket_id = py_strip(&action.string("ticket_id")).to_uppercase();
    let kind = py_strip(&action.string("kind")).to_lowercase();
    let request_id = request_id.map(Value::from);
    mutation_metadata(
        "orchestrator_action",
        Some(ticket_id.as_str()).filter(|id| !id.is_empty()),
        Some(kind.as_str()),
        Some(index),
        request_id.as_ref(),
    )
}

/// `_relay_canceled_entry(mutation, reason)`.
fn canceled_entry(mutation: &Dict, reason: &str) -> Value {
    let mut entry = Dict::new();
    entry.insert(
        "action",
        mutation
            .truthy("action_kind")
            .or_else(|| mutation.get("kind"))
            .cloned()
            .unwrap_or(Value::Null),
    );
    entry.insert("reason", reason);
    if let Some(ticket_id) = mutation.truthy("ticket_id") {
        entry.insert("ticket_id", ticket_id.clone());
    }
    Value::Dict(entry)
}

fn entry(pairs: &[(&str, Value)]) -> Value {
    let mut dict = Dict::new();
    for (key, value) in pairs {
        dict.insert(key, value.clone());
    }
    Value::Dict(dict)
}

/// The state one `apply_orchestrator_actions` call accumulates.
struct Applied {
    repo: PathBuf,
    request_id: Option<String>,
    tickets_written: Vec<Value>,
    dispatch_requests: Vec<WorkerRequest>,
    dispatches: Vec<Value>,
    skipped: Vec<Value>,
    canceled: Vec<Value>,
}

impl Applied {
    fn started_anything(&self) -> bool {
        !(self.tickets_written.is_empty() && self.dispatches.is_empty() && self.skipped.is_empty())
    }

    fn result(&self) -> Dict {
        let mut result = Dict::new();
        result.insert("repo_path", self.repo.to_string_lossy().into_owned());
        result.insert("request_id", self.request_id.clone());
        result.insert("tickets_written", Value::List(self.tickets_written.clone()));
        result.insert(
            "dispatch_requests",
            Value::List(
                self.dispatch_requests
                    .iter()
                    .map(|request| Value::Dict(request.public.clone()))
                    .collect(),
            ),
        );
        result.insert("dispatches", Value::List(self.dispatches.clone()));
        result.insert("skipped", Value::List(self.skipped.clone()));
        result.insert("canceled", Value::List(self.canceled.clone()));
        result
    }
}

/// How a mutation check ended.
enum Checked {
    Allowed,
    Canceled(Dict),
}

impl Daemon {
    pub fn apply_orchestrator_actions_route(&self, request: &Request) -> Outcome<Reply> {
        let actions = request
            .get("actions")
            .filter(|value| value.truthy())
            .cloned()
            .unwrap_or(Value::List(Vec::new()));
        let result = self.apply_orchestrator_actions(&ActionBatch {
            repo_path: request.text("repo_path"),
            actions,
            request_id: request.get("request_id").cloned(),
            voice: VoiceFields::from_body(&request.body),
        })?;
        reply(202, result)
    }

    /// `apply_orchestrator_actions(...)`.
    pub(crate) fn apply_orchestrator_actions(&self, batch: &ActionBatch) -> Outcome<Dict> {
        if batch.repo_path.is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let actions = match &batch.actions {
            Value::List(items) if !items.is_empty() => items,
            _ => return Err(Failure::value("actions must be a non-empty list")),
        };
        let repo = resolve_path(&batch.repo_path);
        let orch_dir = repo.join(".orchestrator");
        if !repo.is_dir() || !repo.join(".git").exists() {
            return Err(Failure::value(format!(
                "repo_path {} is not a git repository",
                repo.display()
            )));
        }
        if !orch_dir.is_dir() {
            return Err(Failure::value(format!(
                "repo_path {} has no .orchestrator directory",
                repo.display()
            )));
        }
        let request_id = clean_optional_text(batch.request_id.as_ref());
        let _authoring = guard(&self.authoring_lock);
        if let Some(id) = &request_id
            && guard(&self.action_request_ids).contains(id)
        {
            return Err(Failure::value(format!(
                "duplicate orchestrator action request: {id}"
            )));
        }
        let mut applied = Applied {
            repo: repo.clone(),
            request_id: request_id.clone(),
            tickets_written: Vec::new(),
            dispatch_requests: Vec::new(),
            dispatches: Vec::new(),
            skipped: Vec::new(),
            canceled: Vec::new(),
        };
        let command_id =
            py_strip(&text_or_empty(batch.voice.relay_command_id.as_ref())).to_string();
        let command_intent_id = request_id
            .as_deref()
            .and_then(|id| id.strip_prefix("relay-command:"))
            .map(str::to_string);
        self.update_action_command(
            &command_id,
            command_intent_id.as_deref(),
            CommandStatus {
                status: "mutation_authorized".to_string(),
                outcome: Some("mutation-authorized".to_string()),
                ..CommandStatus::default()
            },
        )?;
        let mut voice = batch.voice.clone();
        if !voice.relay_intent_id.as_ref().is_some_and(Value::truthy) {
            voice.relay_intent_id = command_intent_id.clone().map(Value::from);
        }
        let check = |mutation: &Dict, started: bool| -> Outcome<Checked> {
            match validate_relay_command(&self.paths, &voice, Some(mutation)) {
                Ok(()) => Ok(Checked::Allowed),
                Err(failure) if started && is_value_error(&failure) => {
                    Ok(Checked::Canceled(single_reason(failure)))
                }
                Err(failure) => Err(failure),
            }
        };

        let mut authored_paths: Vec<PathBuf> = Vec::new();
        let mut authored_ticket_ids: Vec<String> = Vec::new();
        for (index, raw) in actions.iter().enumerate() {
            let index = index as i64;
            let Some(action) = raw.as_dict() else {
                return Err(Failure::value("each action must be an object"));
            };
            let kind = py_strip(&action.string("kind")).to_lowercase();
            if !ACTION_KINDS.contains(&kind.as_str()) {
                return Err(Failure::value(format!(
                    "invalid orchestrator action kind: {}",
                    str_repr(&kind)
                )));
            }
            if kind == "request_worker" {
                let request = self.worker_creation_request(&repo, action)?;
                applied.dispatch_requests.push(WorkerRequest {
                    action_index: index,
                    ..request
                });
                continue;
            }
            let mutation = action_mutation(action, index, request_id.as_deref());
            if let Checked::Canceled(reason) = check(&mutation, applied.started_anything())? {
                let remaining: Vec<Dict> = actions
                    .iter()
                    .enumerate()
                    .skip(index as usize)
                    .filter_map(|(position, action)| {
                        action.as_dict().map(|action| {
                            action_mutation(action, position as i64, request_id.as_deref())
                        })
                    })
                    .collect();
                return self.cancel_and_return(
                    &mut applied,
                    &batch.voice,
                    &command_id,
                    command_intent_id.as_deref(),
                    &remaining,
                    &reason.string("reason"),
                );
            }
            if kind == "create_ticket" {
                let config_path = orch_dir.join("config.toml");
                if !authored_paths.contains(&config_path) {
                    ensure_ticket_authoring_paths_clean(&repo, std::slice::from_ref(&config_path))?;
                }
                let ticket_id = self.create_orchestrator_ticket(&repo, action)?;
                applied.tickets_written.push(entry(&[
                    ("ticket_id", Value::from(ticket_id.as_str())),
                    ("action", Value::from(kind.as_str())),
                ]));
                authored_paths.push(config_path);
                authored_paths.push(orch_dir.join(format!("{ticket_id}.md")));
                authored_ticket_ids.push(ticket_id);
            } else {
                let ticket_id =
                    clean_required_text(action.get("ticket_id"), "ticket_id")?.to_uppercase();
                let ticket_path = orch_dir.join(format!("{ticket_id}.md"));
                if !authored_paths.contains(&ticket_path) {
                    ensure_ticket_authoring_paths_clean(&repo, std::slice::from_ref(&ticket_path))?;
                }
                let ticket_id =
                    self.edit_orchestrator_ticket(&repo, action, kind == "update_dependencies")?;
                applied.tickets_written.push(entry(&[
                    ("ticket_id", Value::from(ticket_id.as_str())),
                    ("action", Value::from(kind.as_str())),
                ]));
                authored_paths.push(ticket_path);
                authored_ticket_ids.push(ticket_id);
            }
        }

        if !authored_paths.is_empty() {
            commit_ticket_authorship(&repo, &authored_paths, &authored_ticket_ids, None)?;
        }

        let mut all_tickets = scan_tickets(&repo)?;
        let requests: Vec<(String, i64, Option<String>)> = applied
            .dispatch_requests
            .iter()
            .map(|request| {
                (
                    request.ticket_id.clone(),
                    request.action_index,
                    request.dispatcher_context.clone(),
                )
            })
            .collect();
        for (position, (ticket_id, action_index, dispatcher_context)) in requests.iter().enumerate()
        {
            let request_value = request_id.as_deref().map(Value::from);
            let mutation = mutation_metadata(
                "orchestrator_action",
                Some(ticket_id),
                Some("request_worker"),
                Some(*action_index),
                request_value.as_ref(),
            );
            if let Checked::Canceled(reason) = check(&mutation, applied.started_anything())? {
                let remaining: Vec<Dict> = requests[position..]
                    .iter()
                    .map(|(ticket_id, action_index, _)| {
                        mutation_metadata(
                            "orchestrator_action",
                            Some(ticket_id),
                            Some("request_worker"),
                            Some(*action_index),
                            request_value.as_ref(),
                        )
                    })
                    .collect();
                return self.cancel_and_return(
                    &mut applied,
                    &batch.voice,
                    &command_id,
                    command_intent_id.as_deref(),
                    &remaining,
                    &reason.string("reason"),
                );
            }
            let ticket_path = orch_dir.join(format!("{ticket_id}.md"));
            let mut ticket = tickets::read(&ticket_path)?;
            let skip = |applied: &mut Applied, reason: String| {
                applied.skipped.push(entry(&[
                    ("ticket_id", Value::from(ticket_id.as_str())),
                    ("reason", Value::from(reason)),
                ]));
            };
            if ticket.canceled {
                skip(&mut applied, "canceled".to_string());
                continue;
            }
            if ticket.draft {
                skip(&mut applied, "draft".to_string());
                continue;
            }
            if !["backlog", "ready"].contains(&ticket.status.as_str()) {
                skip(&mut applied, format!("status:{}", ticket.status));
                continue;
            }
            if ticket.status == "backlog" {
                ticket.status = "ready".to_string();
                tickets::write(&ticket_path, &ticket)?;
                applied.tickets_written.push(entry(&[
                    ("ticket_id", Value::from(ticket_id.as_str())),
                    ("action", Value::from("mark_ready")),
                ]));
                all_tickets = scan_tickets(&repo)?;
            }
            if !self.all_dependencies_done(&repo, &ticket.depends_on, &all_tickets, None)? {
                skip(&mut applied, "dependencies_not_done".to_string());
                continue;
            }
            let dispatched = self.dispatch_ticket_internal(&DispatchCall {
                ticket_id,
                repo_path: &repo.to_string_lossy(),
                context: dispatcher_context.as_deref(),
                source: "orchestrator-action",
                relay_command_seq: batch.voice.relay_command_seq.as_ref(),
                relay_command_id: batch.voice.relay_command_id.as_ref(),
                relay_intent_id: command_intent_id.as_deref(),
            });
            let result = match dispatched {
                Ok(result) => result,
                Err(failure) if applied.started_anything() && is_value_error(&failure) => {
                    let remaining: Vec<Dict> = requests[position..]
                        .iter()
                        .map(|(ticket_id, _, _)| {
                            mutation_metadata(
                                "dispatch_ticket",
                                Some(ticket_id),
                                None,
                                None,
                                request_value.as_ref(),
                            )
                        })
                        .collect();
                    return self.cancel_and_return(
                        &mut applied,
                        &batch.voice,
                        &command_id,
                        command_intent_id.as_deref(),
                        &remaining,
                        &failure.message,
                    );
                }
                Err(failure) => return Err(failure),
            };
            let run_id = result
                .get("run")
                .and_then(Value::as_dict)
                .and_then(|run| run.get("id"))
                .cloned()
                .unwrap_or(Value::Null);
            applied.dispatches.push(entry(&[
                ("ticket_id", Value::from(ticket_id.as_str())),
                ("run_id", run_id),
                (
                    "already_active",
                    Value::Bool(result.get("already_active").is_some_and(Value::truthy)),
                ),
            ]));
        }

        if let Some(id) = &request_id {
            guard(&self.action_request_ids).insert(id.clone());
        }
        if !command_id.is_empty() {
            let kinds: HashSet<String> = actions
                .iter()
                .filter_map(Value::as_dict)
                .map(|action| py_strip(&action.string("kind")).to_lowercase())
                .collect();
            let first_id = |list: &[Value]| {
                list.first()
                    .and_then(Value::as_dict)
                    .and_then(|item| item.get("ticket_id"))
                    .filter(|value| value.truthy())
                    .map(Value::py_str)
            };
            let ticket_id = if applied.dispatches.is_empty() {
                first_id(&applied.tickets_written)
            } else {
                first_id(&applied.dispatches)
            };
            let named = |with: &str, without: &str| match &ticket_id {
                Some(id) => format!("{with} {id}."),
                None => without.to_string(),
            };
            let (status, outcome, message) = if !applied.dispatches.is_empty() {
                (
                    "dispatched",
                    "ticket-dispatched",
                    named("Dispatched", "Ticket dispatched."),
                )
            } else if kinds.contains("create_ticket") && !applied.tickets_written.is_empty() {
                (
                    "created",
                    "ticket-created",
                    named("Created ticket", "Ticket created."),
                )
            } else if (kinds.contains("edit_ticket") || kinds.contains("update_dependencies"))
                && !applied.tickets_written.is_empty()
            {
                (
                    "updated",
                    "ticket-updated",
                    named("Updated", "Ticket updated."),
                )
            } else {
                (
                    "rejected",
                    "mutation-rejected",
                    "No requested ticket mutation was applied.".to_string(),
                )
            };
            self.update_action_command(
                &command_id,
                command_intent_id.as_deref(),
                CommandStatus {
                    status: status.to_string(),
                    outcome: Some(outcome.to_string()),
                    ticket_id,
                    status_message: Some(message),
                    ..CommandStatus::default()
                },
            )?;
        }
        Ok(applied.result())
    }

    /// `command_store.update_status(...)` when the command is on record.
    fn update_action_command(
        &self,
        command_id: &str,
        intent_id: Option<&str>,
        status: CommandStatus,
    ) -> Outcome<()> {
        if command_id.is_empty()
            || self
                .orchestrator_commands
                .get_private(command_id, intent_id)?
                .is_none()
        {
            return Ok(());
        }
        self.orchestrator_commands
            .update_status(command_id, intent_id, &status)?;
        Ok(())
    }

    /// `_cancel_and_return(mutations, reason)`.
    fn cancel_and_return(
        &self,
        applied: &mut Applied,
        voice: &VoiceFields,
        command_id: &str,
        intent_id: Option<&str>,
        mutations: &[Dict],
        reason: &str,
    ) -> Outcome<Dict> {
        applied.canceled.extend(
            mutations
                .iter()
                .map(|mutation| canceled_entry(mutation, reason)),
        );
        mark_mutations_canceled(
            &self.paths.authorization_file,
            voice.relay_command_seq.as_ref().unwrap_or(&Value::Null),
            voice.relay_command_id.as_ref().unwrap_or(&Value::Null),
            mutations,
            reason,
            None,
        )?;
        if let Some(id) = &applied.request_id {
            guard(&self.action_request_ids).insert(id.clone());
        }
        self.update_action_command(
            command_id,
            intent_id,
            CommandStatus {
                status: "superseded".to_string(),
                outcome: Some("superseded".to_string()),
                status_message: Some(
                    "The authorized action was superseded before all mutations completed."
                        .to_string(),
                ),
                ..CommandStatus::default()
            },
        )?;
        let mut result = applied.result();
        result.insert("partial", true);
        result.insert("superseded", true);
        result.insert("status_message", reason);
        Ok(result)
    }

    /// `_create_orchestrator_ticket(repo, action)`.
    fn create_orchestrator_ticket(&self, repo: &Path, action: &Dict) -> Outcome<String> {
        let mut ticket_id = py_strip(&action.string("ticket_id")).to_uppercase();
        let title = clean_required_text(action.get("title"), "title")?;
        let priority = priority(action.get("priority"), "medium")?;
        let description = clean_markdown(action.get("description"), "description")?;
        let criteria = acceptance_criteria_lines(action.get("acceptance_criteria"))?;
        let sizing = action_worker_sizing(action)?;
        let depends_on = ticket_id_list(action.get("depends_on"), "depends_on")?;
        if ticket_id.is_empty() {
            ticket_id = mint_ticket_id(repo)?;
        }
        let ticket_path = repo.join(".orchestrator").join(format!("{ticket_id}.md"));
        if ticket_path.exists() {
            return Err(Failure::value(format!("ticket {ticket_id} already exists")));
        }
        advance_ticket_config_past(repo, &ticket_id)?;
        let mut raw_fields = Fields::default();
        for (field, value) in &sizing {
            raw_fields.insert(field, value);
        }
        let ticket = Ticket {
            id: ticket_id.clone(),
            title,
            status: "backlog".to_string(),
            priority,
            execution_mode: execution_mode(action.get("execution_mode"))?,
            depends_on,
            run_id: None,
            canceled: false,
            draft: false,
            verification_blocker: None,
            verification_resume: None,
            verification_origin: None,
            order: ticket_number(&ticket_id).unwrap_or(0),
            body: structured_ticket_body(&description, &criteria),
            raw_fields,
        };
        tickets::write(&ticket_path, &ticket)?;
        self.notify_orchestration_trace("ticket-created", Some(&ticket_id), None, None, None);
        Ok(ticket_id)
    }

    /// `_edit_orchestrator_ticket(repo, action, dependencies_only=...)`.
    fn edit_orchestrator_ticket(
        &self,
        repo: &Path,
        action: &Dict,
        dependencies_only: bool,
    ) -> Outcome<String> {
        let ticket_id = clean_required_text(action.get("ticket_id"), "ticket_id")?.to_uppercase();
        let ticket_path = repo.join(".orchestrator").join(format!("{ticket_id}.md"));
        if !ticket_path.is_file() {
            return Err(Failure::value(format!("ticket {ticket_id} not found")));
        }
        let mut ticket = tickets::read(&ticket_path)?;
        if dependencies_only {
            ticket.depends_on = ticket_id_list(action.get("depends_on"), "depends_on")?;
        } else {
            apply_ticket_action_fields(&mut ticket, action)?;
        }
        if ticket.status == "ready" {
            ticket.status = "backlog".to_string();
        }
        tickets::write(&ticket_path, &ticket)?;
        self.notify_orchestration_trace("board-change", Some(&ticket_id), None, None, None);
        Ok(ticket_id)
    }

    /// `_worker_creation_request(repo, action)`.
    fn worker_creation_request(&self, repo: &Path, action: &Dict) -> Outcome<WorkerRequest> {
        let ticket_id = clean_required_text(action.get("ticket_id"), "ticket_id")?.to_uppercase();
        let ticket_path = repo.join(".orchestrator").join(format!("{ticket_id}.md"));
        if !ticket_path.is_file() {
            return Err(Failure::value(format!("ticket {ticket_id} not found")));
        }
        let ticket = tickets::read(&ticket_path)?;
        let assumptions = match action.get("dependency_assumptions") {
            Some(value) => ticket_id_list(Some(value), "dependency_assumptions")?,
            None => ticket
                .depends_on
                .iter()
                .map(|id| id.to_uppercase())
                .collect(),
        };
        if assumptions != ticket.depends_on {
            return Err(Failure::value(format!(
                "worker request for {ticket_id} has dependency_assumptions {}, but ticket \
                 depends_on is {}",
                list_repr(&assumptions),
                list_repr(&ticket.depends_on)
            )));
        }
        for field in WORKER_SIZING_FIELDS {
            let actual = required_sizing_value(&ticket, field);
            if let Some(requested) = clean_optional_text(action.get(field))
                && requested != actual
            {
                return Err(Failure::value(format!(
                    "worker request for {ticket_id} has {field}={}, but ticket has {}",
                    str_repr(&requested),
                    str_repr(&actual)
                )));
            }
        }
        let sizing = resolve_worker_sizing(&ticket, &self.agent_kind)?;
        let dispatcher_context = clean_optional_text(action.get("dispatcher_context"));
        let mut public = Dict::new();
        public.insert("ticket_id", ticket_id.as_str());
        public.insert("repo_path", repo.to_string_lossy().into_owned());
        public.insert(
            "dependency_assumptions",
            Value::List(assumptions.into_iter().map(Value::from).collect()),
        );
        for (field, value) in sizing {
            public.insert(field, value);
        }
        public.insert("dispatcher_context", dispatcher_context.clone());
        Ok(WorkerRequest {
            public,
            ticket_id,
            action_index: 0,
            dispatcher_context,
        })
    }

    /// `self.dispatch(...)` for an orchestrator action or voice command.
    pub(crate) fn dispatch_ticket_internal(&self, call: &DispatchCall<'_>) -> Outcome<Dict> {
        let mut request =
            crate::dispatch::DispatchRequest::new(call.ticket_id, call.repo_path, call.source);
        request.context = call.context.map(str::to_string);
        request.voice = crate::relay_command::VoiceFields {
            relay_command_seq: call.relay_command_seq.cloned(),
            relay_command_id: call.relay_command_id.cloned(),
            relay_intent_id: call.relay_intent_id.map(Value::from),
            relay_session_key: None,
        };
        self.dispatch(&request)
    }
}

/// One `self.dispatch(...)` call.
pub(crate) struct DispatchCall<'a> {
    pub ticket_id: &'a str,
    pub repo_path: &'a str,
    pub context: Option<&'a str>,
    pub source: &'a str,
    pub relay_command_seq: Option<&'a Value>,
    pub relay_command_id: Option<&'a Value>,
    pub relay_intent_id: Option<&'a str>,
}

/// The reason a canceled mutation records: the refusal's message.
fn single_reason(failure: Failure) -> Dict {
    let mut reason = Dict::new();
    reason.insert("reason", failure.message);
    reason
}

/// `scan_repo(repo)`'s tickets.
pub(crate) fn scan_tickets(repo: &Path) -> Outcome<Vec<Ticket>> {
    Ok(tickets::scan_repo(repo)?
        .into_iter()
        .map(|(_, ticket)| ticket)
        .collect())
}

/// `_apply_ticket_action_fields(ticket, action)`.
fn apply_ticket_action_fields(ticket: &mut Ticket, action: &Dict) -> Outcome<()> {
    if action.get("title").is_some() {
        ticket.title = clean_required_text(action.get("title"), "title")?;
    }
    if action.get("priority").is_some() {
        let raw = text_or_empty(action.get("priority"));
        let priority = py_strip(&raw).to_lowercase();
        if !PRIORITIES.contains(&priority.as_str()) {
            return Err(Failure::value(format!(
                "invalid priority: {}",
                str_repr(&priority)
            )));
        }
        ticket.priority = priority;
    }
    if action.get("depends_on").is_some() {
        ticket.depends_on = ticket_id_list(action.get("depends_on"), "depends_on")?;
    }
    if action.get("execution_mode").is_some() {
        ticket.execution_mode = execution_mode(action.get("execution_mode"))?;
    }
    if action.get("description").is_some() || action.get("acceptance_criteria").is_some() {
        let description = match action.get("description") {
            Some(value) => clean_markdown(Some(value), "description")?,
            None => clean_markdown(
                Some(&Value::from(body_section(&ticket.body, "Description"))),
                "description",
            )?,
        };
        let criteria = match action.get("acceptance_criteria") {
            Some(value) => acceptance_criteria_lines(Some(value))?,
            None => body_acceptance_criteria(&ticket.body)?,
        };
        ticket.body = structured_ticket_body(&description, &criteria);
    }
    if WORKER_SIZING_FIELDS
        .iter()
        .any(|field| action.get(field).is_some())
    {
        for (field, value) in action_worker_sizing(action)? {
            ticket.raw_fields.insert(field, &value);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_sections_read_as_the_python_pattern_does() {
        let body = "## Description\n\nDo it.\n\n## Acceptance criteria\n\n- [ ] One.\n- [x] Two\n";
        assert_eq!(body_section(body, "Description"), "Do it.");
        assert_eq!(
            body_acceptance_criteria(body).unwrap(),
            ["One.".to_string(), "Two".to_string()]
        );
        assert_eq!(body_section("## Descriptions\n\nx\n", "Description"), "");
        assert_eq!(body_section("intro ## Spike report\nx", "Spike report"), "");
        assert_eq!(body_section("## Spike report", "Spike report"), "");
        assert_eq!(
            body_section(
                "x\n## Spike report  \n\n  Found it.\n### Sub\nmore\n## Next\n",
                "Spike report"
            ),
            "Found it.\n### Sub\nmore"
        );
    }

    #[test]
    fn fields_clean_like_python() {
        assert_eq!(
            clean_required_text(Some(&Value::from("  a \n b ")), "title").unwrap(),
            "a b"
        );
        assert_eq!(
            clean_required_text(Some(&Value::Int(0)), "title")
                .unwrap_err()
                .message,
            "title is required"
        );
        assert_eq!(clean_optional_text(Some(&Value::from("  "))), None);
        assert_eq!(
            string_list(Some(&Value::from("x")), "depends_on")
                .unwrap_err()
                .message,
            "depends_on must be a list"
        );
        assert_eq!(
            ticket_id_list(
                Some(&Value::List(vec![Value::from(" ct-1 "), Value::from("")])),
                "depends_on"
            )
            .unwrap(),
            ["CT-1".to_string()]
        );
        assert_eq!(
            execution_mode(Some(&Value::from("Bogus")))
                .unwrap_err()
                .message,
            "invalid execution_mode: 'bogus'"
        );
        assert_eq!(ticket_number("CT-12"), Some(12));
        assert_eq!(ticket_number("CT-1a"), None);
        assert_eq!(list_repr(&["CT-1".to_string()]), "['CT-1']");
    }

    #[test]
    fn worker_sizing_is_checked_against_the_provider() {
        assert_eq!(
            resolve_worker_model("balanced", "claude").unwrap(),
            "sonnet"
        );
        assert_eq!(
            resolve_worker_model("codex:Astra", "codex").unwrap(),
            "astra"
        );
        assert_eq!(
            resolve_worker_model("claude:opus", "codex")
                .unwrap_err()
                .message,
            "worker_model 'claude:opus' is scoped to claude, but configured worker provider is codex"
        );
        assert_eq!(
            resolve_worker_model("huge", "claude").unwrap_err().message,
            "invalid worker_model 'huge' for claude; expected one of balanced, fast, strong or claude:<model>"
        );
        assert_eq!(
            validate_worker_effort("ultra", "codex:astra", "codex", "none").unwrap(),
            "ultra"
        );
        assert_eq!(
            validate_worker_effort("max", "balanced", "claude", "none")
                .unwrap_err()
                .message,
            "worker_effort 'max' requires a Claude-scoped worker_model and worker_provider_notes \
             documenting the Codex limitation"
        );
        assert_eq!(
            validate_worker_effort("max", "codex:sol", "codex", "x")
                .unwrap_err()
                .message,
            "invalid worker_effort 'max' for codex; expected one of high, low, medium, xhigh"
        );
    }

    #[test]
    fn autonomous_actions_use_refined_context() {
        let general = Dict::new();
        let action = autonomous_ticket_action(
            "Add dark mode to settings",
            &general,
            "Title: Dark mode toggle.\n- Toggle persists\n- Toggle reads system default\nrun `git log`",
        )
        .unwrap();
        assert_eq!(action.string("title"), "Dark mode toggle");
        let criteria: Vec<String> = action
            .get("acceptance_criteria")
            .and_then(Value::as_list)
            .unwrap()
            .iter()
            .map(Value::py_str)
            .collect();
        assert_eq!(criteria, ["Toggle persists", "Toggle reads system default"]);
        assert!(!action.string("description").contains("git log"));
        assert_eq!(action.string("worker_model"), "balanced");

        let mut defaults = Dict::new();
        defaults.insert("subagent_sizing_policy", "user_default");
        defaults.insert("provider", "claude");
        defaults.insert("model", "sonnet");
        defaults.insert("orchestrator_effort", "default");
        let sizing = normalized_default_worker_sizing(&defaults).unwrap();
        assert_eq!(sizing[0].1, "claude:sonnet");
        assert_eq!(sizing[1].1, "medium");
    }

    #[test]
    fn a_generic_request_needs_refined_context() {
        let error =
            autonomous_ticket_action("Make a ticket for this conversation", &Dict::new(), "")
                .unwrap_err();
        assert!(error.message.starts_with("Blocked generic ticket request"));
    }
}
