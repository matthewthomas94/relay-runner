//! `services/automatic_retention.py`: automatic GitHub retention setup and
//! the daemon's periodic retention sweep, through the verified archive
//! transaction in `retention`.
//!
//! Setup leaves the Python module's own state: the same `config.toml`
//! rewrite (one commit per change, with the same event ID), the same
//! migration when a legacy board needs one, and the same archive commits, so
//! either daemon can run the next sweep.

use std::fs;
use std::path::{Path, PathBuf};

use fancy_regex::Regex;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256::hex_digest;

use crate::migration::{ArtifactMigrationCoordinator, MigrationOptions, legacy_ticket_content};
use crate::retention::{
    ArchiveRemoteConfirmation, ArtifactRetentionManager, EventArgs, RetentionOptions,
    SnapshotLeaseStore, confirm_github_remote,
};
use crate::rollout::ArtifactRolloutStore;
use crate::store::{ArtifactStore, Mutation, Operation, StoreOptions};
use crate::sync::{ArtifactSyncEngine, SyncMode, SyncOptions, SyncState};
use crate::{Error, ErrorKind, Result, paths, pystr, tickets, toml};

const CONFIG_PATH: &str = ".orchestrator/config.toml";

fn validation(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::Validation, message)
}

fn read_text(path: &Path) -> Result<String> {
    let bytes = fs::read(path).map_err(|error| {
        let message = error.to_string();
        let message = message
            .rfind(" (os error ")
            .map_or(message.clone(), |index| message[..index].to_string());
        Error::new(
            ErrorKind::Io,
            match error.raw_os_error() {
                Some(code) => format!(
                    "[Errno {code}] {message}: {}",
                    pystr::repr(&path.to_string_lossy())
                ),
                None => message,
            },
        )
    })?;
    Ok(pystr::universal_newlines(pystr::decode_utf8(&bytes)?))
}

/// `json.loads(path.read_text())` for an object.
fn read_json(path: &Path) -> Result<Dict> {
    match json::parse(&read_text(path)?) {
        Some(Value::Dict(dict)) => Ok(dict),
        Some(_) => Err(Error::new(
            ErrorKind::Attribute,
            "'list' object has no attribute 'get'",
        )),
        None => Err(Error::value("Expecting value")),
    }
}

/// `config.get(key)` when it is a non-empty string.
fn toml_text(config: &toml::Table, key: &str) -> Option<String> {
    match config.get(key) {
        Some(toml::Value::String(text)) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

fn toml_bool(config: &toml::Table, key: &str) -> Option<bool> {
    match config.get(key) {
        Some(toml::Value::Boolean(flag)) => Some(*flag),
        _ => None,
    }
}

fn resolved(text: &str) -> Result<PathBuf> {
    Ok(PathBuf::from(paths::resolve(&paths::expanduser(text)?)))
}

/// The registered projects that are available at `repo`.
pub(crate) fn available_records(registry: &Dict, repo: &Path) -> Result<Vec<Dict>> {
    let mut records = Vec::new();
    for record in registry
        .get("projects")
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
    {
        if !record
            .get("availability")
            .is_some_and(|value| value.is_str("available"))
        {
            continue;
        }
        let location = record
            .get("last_resolved_path")
            .map(Value::py_str)
            .unwrap_or_default();
        if PathBuf::from(paths::resolve(&location)) == repo {
            records.push(record.clone());
        }
    }
    Ok(records)
}

/// `retention_registry_revision`: watch project selections and
/// registrations, ignoring routine access timestamps.
pub fn retention_registry_revision(registry_path: &Path) -> Option<String> {
    let document = read_json(registry_path).ok()?;
    let mut projects = Vec::new();
    for record in document
        .get("projects")
        .and_then(Value::as_list)
        .unwrap_or_default()
    {
        let record = record.as_dict()?;
        let mut picked = Dict::new();
        for key in ["project_id", "last_resolved_path", "availability", "remote"] {
            picked.insert(key, record.get(key).cloned().unwrap_or(Value::Null));
        }
        projects.push(Value::Dict(picked));
    }
    Some(json::dumps_sorted(&Value::List(vec![
        document
            .get("active_project_id")
            .cloned()
            .unwrap_or(Value::Null),
        Value::List(projects),
    ])))
}

fn state(name: &str) -> Dict {
    let mut result = Dict::new();
    result.insert("state", name);
    result.insert("ticket_ids", Value::List(Vec::new()));
    result
}

fn ticket_paths(root: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = fs::read_dir(root)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|suffix| suffix == "md"))
                .collect()
        })
        .unwrap_or_default();
    paths.sort();
    paths
}

/// `prepare_project_retention`: enable housekeeping for a registered
/// project only when cleanup is due. `None` means the canonical lifecycle
/// is ready for the normal archive sweep.
pub fn prepare_project_retention(
    repo: &Path,
    state_root: &Path,
    registry_path: &Path,
    rollout: &ArtifactRolloutStore,
) -> Result<Option<Dict>> {
    let repo = resolved(&repo.to_string_lossy())?;
    let registry = read_json(registry_path)?;
    let records = available_records(&registry, &repo)?;
    if !registry
        .get("schema_version")
        .is_some_and(|version| json::py_eq(version, &Value::Int(2)))
        || records.len() != 1
    {
        return Err(validation(
            "Automatic archival requires one available registered project.",
        ));
    }
    let record = &records[0];
    let project_id = record
        .get("project_id")
        .map(Value::py_str)
        .ok_or_else(|| Error::new(ErrorKind::Runtime, "KeyError: 'project_id'"))?;
    let root = repo.join(".orchestrator");
    let config_path = root.join("config.toml");
    let config = if config_path.exists() {
        toml::loads(&read_text(&config_path)?)?
    } else {
        toml::Table::new()
    };
    if config
        .get("project_id")
        .is_some_and(|value| !matches!(value, toml::Value::String(text) if *text == project_id))
    {
        return Err(validation(
            "The archive belongs to another registered project.",
        ));
    }
    let remote = record
        .get("remote")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default();
    if toml_bool(&config, "automatic_retention") == Some(false)
        || toml_text(&config, "remote_sync").as_deref() == Some("paused")
        || remote.get("mode").is_some_and(|mode| mode.is_str("paused"))
    {
        return Ok(Some(state("disabled")));
    }
    // Automatic housekeeping is the product default; project opt-outs and
    // the write/sync kill switches still take precedence.
    let decision = rollout.decision(&project_id, "existing", true)?;
    if !decision.artifact_writes_enabled || !decision.artifact_sync_enabled {
        let mut result = state("disabled");
        result.insert("recovery", decision.reason_code.as_str());
        return Ok(Some(result));
    }

    let store = ArtifactStore::open(
        &repo,
        &project_id,
        state_root,
        StoreOptions {
            enabled: true,
            ..StoreOptions::default()
        },
    )?;
    let mut migration = ArtifactMigrationCoordinator::new(
        &repo,
        &project_id,
        state_root,
        registry_path,
        MigrationOptions {
            runs_db_path: Some(state_root.join("orchestrator/runs.db")),
            graphify_path: Some(state_root.join("orchestrator/graphify.db")),
            ..MigrationOptions::default()
        },
    )?;
    let journal = if migration.journal_path.exists() {
        read_json(&migration.journal_path)?
    } else {
        Dict::new()
    };
    if journal
        .get("stage")
        .is_some_and(|stage| stage.is_str("rolled_back"))
    {
        let mut result = state("disabled");
        result.insert("recovery", "migration_rolled_back");
        return Ok(Some(result));
    }
    if !journal.is_empty()
        && !journal
            .get("stage")
            .is_some_and(|stage| stage.is_str("complete"))
    {
        // Resume from the recorded destination and manifest before reading
        // a possibly displaced or partly migrated projection.
        let destination = journal
            .get("remote_preflight")
            .and_then(Value::as_dict)
            .and_then(|remote| remote.truthy("name"))
            .map(Value::py_str);
        if let Some(destination) = destination {
            confirm_github_remote(&store, &destination, true)?;
        }
        migration.migrate(true, true)?;
    }
    if store.journal_path.exists() {
        store.recover()?;
    }
    if !config_path.exists() && ticket_paths(&root).is_empty() {
        let mut result = state("clean");
        result.insert("retained", 0_i64);
        return Ok(Some(result));
    }
    let config = toml::loads(&read_text(&config_path)?)?;
    if toml_bool(&config, "automatic_retention") == Some(true) {
        return Ok(None);
    }

    let mut terminal_count = 0_i64;
    for path in ticket_paths(&root) {
        let content = fs::read(&path)?;
        let legacy = legacy_ticket_content(&content)?;
        let ticket = tickets::parse(pystr::decode_utf8(&legacy)?)?;
        terminal_count += i64::from(ticket.status == "done" || ticket.canceled);
    }
    if terminal_count <= 25 {
        let mut result = state("clean");
        result.insert("retained", terminal_count);
        return Ok(Some(result));
    }

    let mut selected = toml_text(&config, "remote_name")
        .or_else(|| remote.truthy("remoteName").map(Value::py_str))
        .or_else(|| remote.truthy("remote_name").map(Value::py_str));
    let names: Vec<String> = pystr::splitlines(&store.git(&["remote"], &[], None, &[0])?.text())
        .into_iter()
        .map(str::to_string)
        .collect();
    if selected.is_none() && names.iter().any(|name| name == "origin") {
        selected = Some("origin".to_string());
    }
    if selected.is_none() {
        let mut candidates = Vec::new();
        for name in &names {
            match confirm_github_remote(&store, name, true) {
                Ok(_) => candidates.push(name.clone()),
                Err(error) if error.kind.is_validation() => continue,
                Err(error) => return Err(error),
            }
        }
        match candidates.len() {
            1 => selected = candidates.pop(),
            0 => {}
            _ => {
                return Err(validation(
                    "Choose a GitHub backup remote; multiple destinations are available.",
                ));
            }
        }
    }
    let Some(selected) = selected else {
        let mut result = state("waiting_for_remote");
        result.insert(
            "recovery",
            "Completed tickets are waiting for an existing GitHub backup remote.",
        );
        return Ok(Some(result));
    };
    confirm_github_remote(&store, &selected, true)?;
    if matches!(config.get("schema_version"), Some(toml::Value::Integer(2))) {
        // A canonical project needs its writer enabled, not another legacy
        // import that could conflict with its artifact history.
        if toml_text(&config, "artifact_lifecycle").as_deref() != Some("enabled") {
            configure(&store, &[("artifact_lifecycle", Value::from("enabled"))])?;
        }
    } else {
        migration.remote_name = Some(selected.clone());
        migration.migrate(true, true)?;
    }
    enable_automatic_retention(&store, &selected)?;
    Ok(None)
}

/// `automatic_confirmation`: the project's durable authorization, bound to
/// both remote URLs.
pub fn automatic_confirmation(
    store: &ArtifactStore,
    config: &toml::Table,
) -> Result<Option<ArchiveRemoteConfirmation>> {
    if toml_bool(config, "automatic_retention") != Some(true)
        || toml_text(config, "remote_sync").as_deref() != Some("enabled")
    {
        return Ok(None);
    }
    let remote_name = match config.get("remote_name") {
        Some(toml::Value::String(text)) => text.clone(),
        _ => String::new(),
    };
    let confirmation = confirm_github_remote(store, &remote_name, true)?;
    let recorded = |key: &str| toml_text(config, key);
    if recorded("archive_remote_url_sha256").as_deref()
        != Some(confirmation.remote_url_sha256.as_str())
        || recorded("archive_push_url_sha256").as_deref()
            != Some(confirmation.push_url_sha256.as_str())
    {
        return Err(validation(
            "Automatic archival paused because the GitHub destination changed. \
             Run relay-ticket-history enable with the intended remote to resume.",
        ));
    }
    Ok(Some(confirmation))
}

/// `_configure`: rewrite (or append) each `key = value` line of the
/// artifact config in one commit.
fn configure(store: &ArtifactStore, values: &[(&str, Value)]) -> Result<()> {
    let snapshot = store.snapshot()?;
    let original = pystr::decode_utf8(snapshot.file(CONFIG_PATH).ok_or_else(|| {
        Error::new(
            ErrorKind::Runtime,
            format!("KeyError: {}", pystr::repr(CONFIG_PATH)),
        )
    })?)?
    .to_string();
    let mut content = original.clone();
    for (key, value) in values {
        let line = format!("{key} = {}", json::dumps(value));
        let pattern = Regex::new(&format!(r"(?m)^{key}\s*=[^\n]*"))
            .map_err(|error| Error::value(error.to_string()))?;
        let found = pattern
            .is_match(&content)
            .map_err(|error| Error::value(error.to_string()))?;
        if found {
            content = pattern.replace_all(&content, line.as_str()).into_owned();
        } else {
            content = format!("{}\n{line}\n", content.trim_end());
        }
    }
    if content != original {
        let digest = hex_digest(format!("{}{content}", snapshot.commit_id).as_bytes());
        let mut mutation = Mutation::new(
            &format!("automatic-retention:enable:{}", &digest[..32]),
            "user",
            "retention-setup",
            vec![Operation::ConfigWrite {
                content: content.into_bytes(),
            }],
        );
        mutation.expected_base = Some(snapshot.commit_id);
        mutation.summary = "Enable automatic archival of older completed tickets".to_string();
        store.mutate(&mutation)?;
    }
    Ok(())
}

/// `enable_automatic_retention`: bind future background batches to this
/// project's existing destination.
pub fn enable_automatic_retention(store: &ArtifactStore, remote_name: &str) -> Result<Dict> {
    let confirmation = confirm_github_remote(store, remote_name, true)?;
    configure(
        store,
        &[
            ("remote_sync", Value::from("enabled")),
            ("remote_name", Value::from(remote_name)),
            (
                "archive_remote_url_sha256",
                Value::from(confirmation.remote_url_sha256.as_str()),
            ),
            (
                "archive_push_url_sha256",
                Value::from(confirmation.push_url_sha256.as_str()),
            ),
        ],
    )?;
    let engine = ArtifactSyncEngine::new(
        store,
        SyncOptions::new(SyncMode::Enabled, Some(remote_name)),
    )?;
    // Setup is complete only after publication, so an offline first attempt
    // repeats setup automatically, including creating a missing ref.
    let result = engine.publish_initial(true)?;
    if result.state != SyncState::Clean {
        return Err(validation(
            result
                .recovery
                .filter(|text| !text.is_empty())
                .unwrap_or_else(|| format!("Archive setup is {}", result.state.value())),
        ));
    }
    configure(store, &[("automatic_retention", Value::Bool(true))])?;
    let mut answer = Dict::new();
    answer.insert("enabled", true);
    answer.insert("remote_name", remote_name);
    answer.insert("limit", 25_i64);
    Ok(answer)
}

/// `sweep_automatic_retention`: run on startup and periodically; every
/// phase is safe to retry.
pub fn sweep_automatic_retention(
    store: &ArtifactStore,
    lease_store: Option<SnapshotLeaseStore>,
) -> Result<Dict> {
    let snapshot = store.snapshot()?;
    let config = toml::loads(pystr::decode_utf8(snapshot.file(CONFIG_PATH).ok_or_else(
        || {
            Error::new(
                ErrorKind::Runtime,
                format!("KeyError: {}", pystr::repr(CONFIG_PATH)),
            )
        },
    )?)?)?;
    let Some(confirmation) = automatic_confirmation(store, &config)? else {
        return Ok(state("disabled"));
    };
    let engine = ArtifactSyncEngine::new(
        store,
        SyncOptions::new(SyncMode::Enabled, Some(&confirmation.remote_name)),
    )?;
    let manager = ArtifactRetentionManager::new(
        store,
        RetentionOptions {
            lease_store,
            remote_mode: "enabled".to_string(),
            remote_confirmation: Some(confirmation.clone()),
            synchronizer: Some(&engine),
            enabled: true,
            ..RetentionOptions::default()
        },
    )?;
    let retry = manager
        .transaction_status()?
        .get("retry_available")
        .is_some_and(Value::truthy);
    let result = if retry {
        match manager.recover_archive(Some(&engine))? {
            Some(result) => result,
            // Another confirmed caller finished recovery first.
            None => return Ok(state("clean")),
        }
    } else {
        let synced = engine.sync_confirmed(
            &confirmation.remote_url_sha256,
            &confirmation.push_url_sha256,
        )?;
        if synced.state != SyncState::Clean {
            let mut answer = state(synced.state.value());
            answer.insert("recovery", synced.recovery);
            return Ok(answer);
        }
        let plan = manager.preview(None)?;
        if plan.candidates.is_empty() && plan.materialize.is_empty() {
            let mut answer = state("clean");
            answer.insert("retained", plan.retained_terminal.len() as i64);
            return Ok(answer);
        }
        manager.archive(
            &plan,
            &EventArgs {
                event_id: format!("automatic-retention:{}", plan.artifact_head),
                device_id: "retention-daemon".to_string(),
                ..EventArgs::default()
            },
            Some(&engine),
        )?
    };
    let mut answer = Dict::new();
    answer.insert("state", result.state.value());
    answer.insert(
        "ticket_ids",
        Value::List(result.ticket_ids.iter().cloned().map(Value::Str).collect()),
    );
    answer.insert("recovery", result.recovery);
    Ok(answer)
}
