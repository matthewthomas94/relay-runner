//! The artifact board, retention, history and storage routes
//! (`artifact_board_*`, `artifact_retention_*`, `artifact_history_*`,
//! `artifact_dependency_summary`, `artifact_storage_metrics`,
//! `artifact_rollout_status`), the startup lease recovery and the automatic
//! retention loop of `services/orchestrator.py`.
//!
//! Every write is one commit on `refs/heads/relay/artifacts` through the
//! project's `ArtifactStore`, made with the same mutation (event id, actor,
//! device, operations, summary) the Python daemon makes, so the commits are
//! byte for byte the ones in `tests/contract/golden/orchestrator/board/`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant as Monotonic};

use relay_artifacts::automatic_retention::{
    automatic_confirmation, prepare_project_retention, retention_registry_revision,
    sweep_automatic_retention,
};
use relay_artifacts::lifecycle::ArtifactLifecycleCoordinator;
use relay_artifacts::retention::{
    self, ArchiveRemoteConfirmation, ArchiveResult, ArtifactRetentionManager, EventArgs,
    HistoricalCard, HistoryAccess, HistoryAvailability, RetentionOptions, StoragePaths,
    confirm_github_remote,
};
use relay_artifacts::store::{self, Mutation, Operation};
use relay_artifacts::sync::{ArtifactSyncEngine, SyncMode, SyncOptions};
use relay_artifacts::{ErrorKind, pystr, tickets, toml};
use relay_intents::json::{self, Dict, Value};
use relay_intents::pattern::Regex;
use relay_services::notes::util::{b64decode_strict, b64encode, utc_now_isoformat, uuid4_hex};

use crate::daemon::{Daemon, guard, read_json, registered_project_repo_paths};
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::{Reply, reply};

/// `ARTIFACT_BOARD_WRITE_ATTEMPTS`: a base moved by another writer is re-read
/// and the write retried this many times.
const ARTIFACT_BOARD_WRITE_ATTEMPTS: usize = 5;
const CONFIG_PATH: &str = ".orchestrator/config.toml";

/// `_artifact_board_event_id(kind, request_id)`.
pub fn board_event_id(kind: &str, request_id: Option<&Value>) -> String {
    let raw = match request_id {
        Some(value) if value.truthy() => value.py_str(),
        _ => uuid4_hex(),
    };
    let raw = pystr::strip(&raw);
    let replaced: String = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || "_.:-".contains(character) {
                character
            } else {
                '-'
            }
        })
        .take(120)
        .collect();
    let safe = replaced.trim_matches('-');
    let safe = if safe.is_empty() {
        uuid4_hex()
    } else {
        safe.to_string()
    };
    format!("board-{kind}:{safe}")
}

/// `_upsert_ticket_frontmatter_fields(markdown, fields)`: set daemon-owned
/// fields without rewriting ticket prose.
pub fn upsert_frontmatter_fields(markdown: &[u8], fields: &[(&str, &str)]) -> Outcome<Vec<u8>> {
    let text = std::str::from_utf8(markdown)
        .map_err(|_| Failure::value("ticket markdown must be UTF-8"))?;
    let mut lines: Vec<String> = pystr::splitlines(text)
        .into_iter()
        .map(str::to_string)
        .collect();
    if lines.is_empty() || pystr::strip(&lines[0]) != "---" {
        return Err(Failure::value("ticket markdown has no frontmatter"));
    }
    let closing = (1..lines.len())
        .find(|index| pystr::strip(&lines[*index]) == "---")
        .ok_or_else(|| Failure::value("ticket markdown frontmatter is not closed"))?;
    let mut positions: HashMap<String, usize> = HashMap::new();
    for (index, line) in lines.iter().enumerate().take(closing).skip(1) {
        let (key, found, _) = pystr::partition(line, ":");
        if found {
            positions.insert(pystr::strip(key).to_string(), index);
        }
    }
    let mut insertion = positions.get("id").copied().unwrap_or(0) + 1;
    for (key, value) in fields {
        let rendered = format!("{key}: {value}");
        if let Some(position) = positions.get(*key) {
            lines[*position] = rendered;
        } else {
            lines.insert(insertion, rendered);
            insertion += 1;
            for position in positions.values_mut() {
                if *position >= insertion - 1 {
                    *position += 1;
                }
            }
        }
    }
    let joined = lines.join("\n");
    Ok(format!("{}\n", joined.trim_end_matches('\n')).into_bytes())
}

/// `datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")`.
fn utc_now_z() -> String {
    utc_now_isoformat().replace("+00:00", "Z")
}

/// `isinstance(error, ArtifactConcurrentUpdate)`.
fn is_concurrent(error: &relay_artifacts::Error) -> bool {
    error.kind == ErrorKind::ConcurrentUpdate
}

/// `body.get("project_scope_token")` as the scope check reads it.
fn body_token(request: &Request) -> Option<String> {
    request.optional_text("project_scope_token")
}

/// `(query.get("project_scope_token") or [None])[0]`.
fn query_token(request: &Request) -> Option<String> {
    request.query_first("project_scope_token")
}

/// `snapshot.files[".orchestrator/config.toml"]`, which raises `KeyError`
/// when the config is missing.
fn config_bytes(snapshot: &store::Snapshot) -> Outcome<&[u8]> {
    snapshot
        .file(CONFIG_PATH)
        .ok_or_else(|| Failure::escape(pystr::repr(CONFIG_PATH)))
}

/// The retention manager, its synchronizer and the resolved confirmation for
/// one project, as `_artifact_retention_components` builds them.
pub struct RetentionContext<'s> {
    pub lifecycle: &'s ArtifactLifecycleCoordinator,
    pub manager: ArtifactRetentionManager<'s>,
    pub synchronizer: Option<&'s ArtifactSyncEngine<'s>>,
    pub confirmation: Option<ArchiveRemoteConfirmation>,
}

/// The config values `_artifact_retention_components` reads.
struct RetentionConfig {
    table: toml::Table,
    mode: SyncMode,
    remote_name: Option<String>,
}

fn retention_config(lifecycle: &ArtifactLifecycleCoordinator) -> Outcome<RetentionConfig> {
    let invalid = |message: String| {
        Failure::value(format!("artifact retention config is invalid: {message}"))
    };
    let snapshot = lifecycle.store.snapshot()?;
    let content = snapshot
        .file(CONFIG_PATH)
        .ok_or_else(|| invalid(pystr::repr(CONFIG_PATH)))?;
    let text = pystr::decode_utf8(content).map_err(|error| invalid(error.message))?;
    let table = toml::loads(text).map_err(|error| invalid(error.message))?;
    let raw_mode = match table.get("remote_sync") {
        Some(value) if value.truthy() => crate::daemon::toml_to_json(value).py_str(),
        _ => "local_only".to_string(),
    };
    let mode = SyncMode::from_value(&raw_mode).ok_or_else(|| {
        invalid(format!(
            "{} is not a valid ArtifactSyncMode",
            pystr::repr(&raw_mode)
        ))
    })?;
    let remote_name = match table.get("remote_name") {
        Some(value) if value.truthy() => {
            let text = crate::daemon::toml_to_json(value).py_str();
            let text = pystr::strip(&text).to_string();
            (!text.is_empty()).then_some(text)
        }
        _ => None,
    };
    if mode == SyncMode::Enabled && remote_name.is_none() {
        return Err(Failure::value(
            "remote-enabled retention has no explicitly selected remote_name",
        ));
    }
    Ok(RetentionConfig {
        table,
        mode,
        remote_name,
    })
}

/// A synchronizer for the configured mode, `None` for Local only.
fn synchronizer<'s>(
    lifecycle: &'s ArtifactLifecycleCoordinator,
    config: &RetentionConfig,
) -> Outcome<Option<ArtifactSyncEngine<'s>>> {
    if config.mode == SyncMode::LocalOnly {
        return Ok(None);
    }
    Ok(Some(ArtifactSyncEngine::new(
        &lifecycle.store,
        SyncOptions::new(config.mode, config.remote_name.as_deref()),
    )?))
}

impl Daemon {
    /// `_artifact_retention_components(repo_path, token,
    /// confirm_github_exposure=...)`, handing the parts to `work`.
    pub fn with_retention<T>(
        &self,
        repo_path: &str,
        project_scope_token: Option<&str>,
        confirm_github_exposure: bool,
        work: impl FnOnce(&RetentionContext<'_>) -> Outcome<T>,
    ) -> Outcome<T> {
        let lifecycle = self.artifact_board_lifecycle(repo_path, project_scope_token)?;
        let config = retention_config(&lifecycle)?;
        let engine = synchronizer(&lifecycle, &config)?;
        let mut confirmation = automatic_confirmation(&lifecycle.store, &config.table)?;
        if confirm_github_exposure {
            let remote = match (&config.mode, &config.remote_name) {
                (SyncMode::Enabled, Some(remote)) => remote,
                _ => {
                    return Err(Failure::value(
                        "GitHub exposure confirmation requires enabled remote sync",
                    ));
                }
            };
            confirmation = Some(confirm_github_remote(&lifecycle.store, remote, true)?);
        }
        let manager = ArtifactRetentionManager::new(
            &lifecycle.store,
            RetentionOptions {
                lease_store: Some(lifecycle.leases.clone()),
                remote_mode: config.mode.value().to_string(),
                remote_confirmation: confirmation.clone(),
                synchronizer: engine.as_ref(),
                enabled: true,
                ..RetentionOptions::default()
            },
        )?;
        work(&RetentionContext {
            lifecycle: &lifecycle,
            manager,
            synchronizer: engine.as_ref(),
            confirmation,
        })
    }

    /// `artifact_retention_status`'s body.
    fn retention_status_value(&self, repo_path: &str, token: Option<&str>) -> Outcome<Value> {
        self.with_retention(repo_path, token, false, |context| {
            Ok(retention::status_payload(
                &context.manager,
                context.synchronizer,
                context.confirmation.as_ref(),
            )?)
        })
    }

    pub fn artifact_rollout_status(&self, _request: &Request) -> Outcome<Reply> {
        let mut body = Dict::new();
        match self.lifecycles.rollout.diagnostics(None) {
            Ok(rollout) => {
                body.insert("status", "available");
                body.insert("rollout", rollout);
            }
            Err(error) if matches!(error.kind, ErrorKind::Rollout | ErrorKind::RolloutBlocked) => {
                body.insert("status", "verification_blocked");
                body.insert("error_code", error.code);
                body.insert("recovery", error.recovery);
            }
            Err(error) => return Err(error.into()),
        }
        reply(200, body)
    }

    pub fn artifact_retention_preview(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        let plan = self.with_retention(&repo_path, token.as_deref(), false, |context| {
            Ok(retention::plan_payload(&context.manager)?)
        })?;
        Ok((200, plan))
    }

    pub fn artifact_retention_status(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        Ok((
            200,
            self.retention_status_value(&repo_path, token.as_deref())?,
        ))
    }

    pub fn artifact_storage_metrics(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        let data = &self.paths.data_root;
        let database_paths: Vec<PathBuf> = [
            "runs.db",
            "queue_drains.db",
            "orchestrator_sessions.db",
            "orchestrator_commands.db",
            "messenger_outcomes.db",
            "followup_proposals.db",
        ]
        .iter()
        .map(|name| data.join(name))
        .collect();
        let run_log_paths: Vec<PathBuf> = self
            .runs
            .list(None, 10_000)?
            .iter()
            .filter_map(|run| run.get("log_path").filter(|value| value.truthy()))
            .map(|value| PathBuf::from(value.py_str()))
            .collect();
        let paths = StoragePaths {
            database_paths,
            run_log_paths,
            index_paths: vec![self.graphify_path.clone(), data.join("runs.json")],
            ..StoragePaths::default()
        };
        let metrics = self.with_retention(&repo_path, token.as_deref(), false, |context| {
            Ok(context.manager.storage_metrics(&paths)?)
        })?;
        let counts = |bytes: i64, files: i64| {
            let mut value = Dict::new();
            value.insert("bytes", bytes);
            value.insert("files", files);
            value
        };
        let mut materialized = counts(
            metrics.materialized_worktree_bytes,
            metrics.materialized_file_count,
        );
        materialized.insert(
            "tickets",
            counts(
                metrics.materialized_ticket_bytes,
                metrics.materialized_ticket_count,
            ),
        );
        materialized.insert(
            "attachments",
            counts(
                metrics.materialized_attachment_bytes,
                metrics.materialized_attachment_count,
            ),
        );
        let mut retained = Dict::new();
        retained.insert("retained_terminal_count", metrics.retained_terminal_count);
        retained.insert("nonterminal_count", metrics.nonterminal_count);
        retained.insert("temporary_overage_count", metrics.temporary_overage_count);
        retained.insert(
            "remotely_backed_history_count",
            metrics.remotely_backed_history_count,
        );
        let mut body = Dict::new();
        body.insert("materialized", materialized);
        body.insert("retention", retained);
        body.insert(
            "reachable_git_objects_bytes",
            metrics.reachable_git_object_bytes,
        );
        body.insert("databases_bytes", metrics.database_bytes);
        body.insert("run_logs_bytes", metrics.run_log_bytes);
        body.insert("indexes_bytes", metrics.index_bytes);
        body.insert("caches_bytes", metrics.cache_bytes);
        body.insert(
            "reclaimable_estimate_bytes",
            metrics.reclaimable_estimate_bytes,
        );
        reply(200, body)
    }

    pub fn artifact_history_search(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        let query = request.query_or("query", "");
        if self.artifact_lifecycle(&repo_path)?.is_none() {
            let mut body = Dict::new();
            body.insert("history", Value::List(Vec::new()));
            body.insert(
                "recovery",
                "Older completed tickets will appear here after automatic GitHub backup.",
            );
            return reply(200, body);
        }
        let body = self.with_retention(&repo_path, token.as_deref(), false, |context| {
            Ok(retention::history_search_payload(&context.manager, &query)?)
        })?;
        Ok((200, body))
    }

    /// `_artifact_history_detail_components`, handing the manager and the
    /// history access (with `deepen` when online) to `work`.
    fn with_history<T>(
        &self,
        repo_path: &str,
        token: Option<&str>,
        online: bool,
        confirm_github_exposure: bool,
        work: impl FnOnce(&RetentionContext<'_>, HistoryAccess<'_>) -> Outcome<T>,
    ) -> Outcome<T> {
        self.with_retention(repo_path, token, confirm_github_exposure, |context| {
            if !online {
                return work(context, HistoryAccess::default());
            }
            let (Some(engine), Some(confirmation)) =
                (context.synchronizer, context.confirmation.as_ref())
            else {
                return Err(Failure::value(
                    "online history retrieval requires confirmed GitHub artifact access",
                ));
            };
            let digest = confirmation.remote_url_sha256.clone();
            let deepen = move |commit_id: &str| engine.fetch_historical_object(commit_id, &digest);
            work(
                context,
                HistoryAccess {
                    online: true,
                    deepen: Some(&deepen),
                },
            )
        })
    }

    pub fn artifact_history_detail(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        let artifact_id = request.unquoted(3);
        let online = request.query_flag("online");
        let confirmed = request.query_flag("confirm_github_exposure");
        self.with_history(
            &repo_path,
            token.as_deref(),
            online,
            confirmed,
            |context, access| {
                let detail = context.manager.historical_detail(&artifact_id, access)?;
                let mut body = Dict::new();
                body.insert("availability", detail.availability.value());
                body.insert(
                    "card",
                    detail.card.as_ref().map_or(Value::Null, detail_card),
                );
                body.insert(
                    "markdown_base64",
                    detail
                        .ticket_bytes
                        .as_deref()
                        .map_or(Value::Null, |bytes| Value::Str(b64encode(bytes))),
                );
                body.insert(
                    "attachments",
                    Value::List(detail.attachments.into_iter().map(Value::Dict).collect()),
                );
                body.insert("recovery", detail.recovery);
                body.insert("materialized", false);
                reply(200, body)
            },
        )
    }

    pub fn artifact_history_attachment(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        let artifact_id = request.unquoted(3);
        let filename = request.unquoted(5);
        let online = request.query_flag("online");
        let confirmed = request.query_flag("confirm_github_exposure");
        self.with_history(
            &repo_path,
            token.as_deref(),
            online,
            confirmed,
            |context, access| {
                let attachment =
                    context
                        .manager
                        .historical_attachment(&artifact_id, &filename, access)?;
                let mut body = Dict::new();
                body.insert("artifact_id", attachment.artifact_id);
                body.insert("ticket_id", attachment.ticket_id);
                body.insert("filename", attachment.filename);
                body.insert("mime_type", attachment.mime_type);
                body.insert("blob_id", attachment.blob_id);
                body.insert("size", attachment.content.len() as i64);
                body.insert("content_base64", b64encode(&attachment.content));
                body.insert("materialized", false);
                reply(200, body)
            },
        )
    }

    pub fn artifact_dependency_summary(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = query_token(request);
        let ticket_id = request.unquoted(3);
        self.with_retention(&repo_path, token.as_deref(), false, |context| {
            let manager = &context.manager;
            let snapshot = manager.store.snapshot()?;
            let path = format!(".orchestrator/{ticket_id}.md");
            let dependencies = match snapshot.file(&path) {
                Some(content) => {
                    let text = pystr::decode_utf8(content)?;
                    Some(tickets::parse(text)?.depends_on)
                }
                None => catalog_entry(manager, &snapshot.commit_id, &ticket_id)?.map(|entry| {
                    entry
                        .get("dependencies")
                        .filter(|value| value.truthy())
                        .and_then(Value::as_list)
                        .unwrap_or_default()
                        .iter()
                        .map(Value::py_str)
                        .collect()
                }),
            };
            let Some(dependencies) = dependencies else {
                return Err(Failure::value(format!(
                    "ticket {} was not found",
                    pystr::repr(&ticket_id)
                )));
            };
            let mut summaries = Vec::new();
            for dependency_id in &dependencies {
                summaries.push(dependency_summary(manager, dependency_id)?);
            }
            let satisfied = summaries
                .iter()
                .all(|item| item.get("satisfied").is_some_and(Value::truthy));
            let mut body = Dict::new();
            body.insert("ticket_id", ticket_id.as_str());
            body.insert("satisfied", satisfied);
            body.insert(
                "dependencies",
                Value::List(summaries.into_iter().map(Value::Dict).collect()),
            );
            reply(200, body)
        })
    }

    pub fn artifact_retention_apply(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let request_id = request.text("request_id");
        if pystr::strip(&request_id).is_empty() {
            return Err(Failure::value(
                "retention apply requires a stable request_id",
            ));
        }
        let provider = request.optional_text("provider");
        let confirmed = request.is_true("confirm_github_exposure");
        let mut body = self.with_retention(&repo_path, token.as_deref(), confirmed, |context| {
            let plan = context.manager.preview(None)?;
            let result = context.manager.archive(
                &plan,
                &EventArgs {
                    event_id: format!("retention:apply:{request_id}"),
                    device_id: self.device_id.clone(),
                    provider: provider.clone(),
                    ..EventArgs::default()
                },
                context.synchronizer,
            )?;
            let idempotent = match &result.write {
                Some(write) => write.idempotent,
                None => result.ticket_ids.is_empty(),
            };
            Ok(archive_body(&result, Some(idempotent), true))
        })?;
        body.insert(
            "status",
            self.retention_status_value(&repo_path, token.as_deref())?,
        );
        reply(200, body)
    }

    pub fn artifact_retention_retry(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let confirmed = request.is_true("confirm_github_exposure");
        self.with_retention(
            &repo_path,
            token.as_deref(),
            confirmed,
            |context| match context.manager.recover_archive(context.synchronizer)? {
                None => {
                    let mut body = Dict::new();
                    body.insert("state", "idle");
                    body.insert("ticket_ids", Value::List(Vec::new()));
                    body.insert("recovery", Value::Null);
                    reply(200, body)
                }
                Some(result) => reply(200, archive_body(&result, None, true)),
            },
        )
    }

    pub fn artifact_history_restore(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let artifact_id = request.unquoted(3);
        let request_id = request.text("request_id");
        let reopen = request.segments[4] == "reopen";
        if pystr::strip(&request_id).is_empty() {
            return Err(Failure::value(
                "history restore/reopen requires a stable request_id",
            ));
        }
        let provider = request.optional_text("provider");
        let online = request.is_true("online");
        let confirmed = request.is_true("confirm_github_exposure");
        self.with_history(
            &repo_path,
            token.as_deref(),
            online,
            confirmed,
            |context, access| {
                let event = EventArgs {
                    event_id: format!(
                        "history:{}:{request_id}",
                        if reopen { "reopen" } else { "restore" }
                    ),
                    device_id: self.device_id.clone(),
                    provider: provider.clone(),
                    ..EventArgs::default()
                };
                let result = if reopen {
                    context.manager.reopen(&artifact_id, &event, access)?
                } else {
                    context.manager.restore(&artifact_id, &event, access)?
                };
                let mut body = Dict::new();
                body.insert("state", result.state.value());
                body.insert("ticket_ids", strings(&result.ticket_ids));
                body.insert(
                    "artifact_commit",
                    result
                        .write
                        .as_ref()
                        .map_or(Value::Null, |write| Value::from(write.commit_id.as_str())),
                );
                body.insert(
                    "idempotent",
                    result.write.as_ref().is_some_and(|write| write.idempotent),
                );
                body.insert("recovery", result.recovery.clone());
                body.insert("retention", retention::plan_payload(&context.manager)?);
                reply(200, body)
            },
        )
    }

    pub fn artifact_board_claim_next_id(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let lifecycle = self.artifact_board_lifecycle(&repo_path, token.as_deref())?;
        let event_id = board_event_id("claim", request.get("request_id"));
        let _board = guard(&self.board_lock);
        reply(201, self.claim_artifact_board_id(&lifecycle, &event_id)?)
    }

    /// `_claim_artifact_board_id`.
    fn claim_artifact_board_id(
        &self,
        lifecycle: &ArtifactLifecycleCoordinator,
        event_id: &str,
    ) -> Outcome<Dict> {
        let mut attempt = 0;
        loop {
            attempt += 1;
            let snapshot = lifecycle.store.snapshot()?;
            let content = config_bytes(&snapshot)?;
            let (rendered, prefix, next_id) = claim_config(content)?;
            let mut mutation = Mutation::new(
                event_id,
                "user",
                &self.device_id,
                vec![Operation::ConfigWrite {
                    content: rendered.into_bytes(),
                }],
            );
            mutation.expected_base = Some(snapshot.commit_id.clone());
            mutation.summary = format!("Claim Relay ticket ID {prefix}-{next_id}");
            match lifecycle.store.mutate(&mutation) {
                Ok(write) => {
                    let mut body = Dict::new();
                    body.insert("prefix", prefix.as_str());
                    body.insert("id", next_id);
                    body.insert("ticket_id", format!("{prefix}-{next_id}"));
                    body.insert("artifact_commit", write.commit_id);
                    body.insert("idempotent", write.idempotent);
                    return Ok(body);
                }
                Err(error) if is_concurrent(&error) && attempt < ARTIFACT_BOARD_WRITE_ATTEMPTS => {}
                Err(error) => return Err(error.into()),
            }
        }
    }

    pub fn artifact_board_write_ticket(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let ticket_id = request.text("ticket_id");
        let markdown_base64 = request.text("markdown_base64");
        let lifecycle = self.artifact_board_lifecycle(&repo_path, token.as_deref())?;
        let invalid =
            |message: String| Failure::value(format!("ticket write payload is invalid: {message}"));
        let markdown = b64decode_strict(&markdown_base64)
            .ok_or_else(|| invalid("Only base64 data is allowed".to_string()))?;
        let text = pystr::decode_utf8(&markdown).map_err(|error| invalid(error.message))?;
        let parsed = tickets::parse(text).map_err(|error| invalid(error.message))?;
        if parsed.id != ticket_id {
            return Err(Failure::value(
                "ticket write ID does not match markdown frontmatter",
            ));
        }
        let event_id = board_event_id("ticket", request.get("request_id"));
        let _board = guard(&self.board_lock);
        reply(
            200,
            self.write_artifact_board_ticket(&lifecycle, &event_id, &ticket_id, &markdown)?,
        )
    }

    /// `_write_artifact_board_ticket`.
    fn write_artifact_board_ticket(
        &self,
        lifecycle: &ArtifactLifecycleCoordinator,
        event_id: &str,
        ticket_id: &str,
        markdown: &[u8],
    ) -> Outcome<Dict> {
        let path = format!(".orchestrator/{ticket_id}.md");
        let mut attempt = 0;
        loop {
            attempt += 1;
            let snapshot = lifecycle.store.snapshot()?;
            let artifact_id = snapshot
                .file(&path)
                .and_then(|existing| store::ticket_front_matter_value(existing, "artifact_id"))
                .unwrap_or_else(|| default_artifact_id(&lifecycle.store.project_id, ticket_id));
            let edited = upsert_frontmatter_fields(markdown, &[("user_edited_at", &utc_now_z())])?;
            let mut mutation = Mutation::new(
                event_id,
                "user",
                &self.device_id,
                vec![Operation::TicketWrite {
                    ticket_id: ticket_id.to_string(),
                    artifact_id,
                    markdown: edited,
                }],
            );
            mutation.expected_base = Some(snapshot.commit_id.clone());
            mutation.summary = format!("Save Relay ticket {ticket_id}");
            match lifecycle.store.mutate(&mutation) {
                Ok(write) => {
                    let stored = lifecycle.store.snapshot()?;
                    let stored = stored
                        .file(&path)
                        .ok_or_else(|| Failure::escape(pystr::repr(&path)))?;
                    let mut body = Dict::new();
                    body.insert("ticket_id", ticket_id);
                    body.insert("markdown_base64", b64encode(stored));
                    body.insert("artifact_commit", write.commit_id);
                    body.insert("idempotent", write.idempotent);
                    return Ok(body);
                }
                Err(error) if is_concurrent(&error) && attempt < ARTIFACT_BOARD_WRITE_ATTEMPTS => {}
                Err(error) => return Err(error.into()),
            }
        }
    }

    pub fn artifact_board_delete_ticket(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let ticket_id = request.text("ticket_id");
        self.with_retention(&repo_path, token.as_deref(), false, |context| {
            let snapshot = context.manager.store.snapshot()?;
            let path = format!(".orchestrator/{ticket_id}.md");
            let mut body = Dict::new();
            body.insert("ticket_id", ticket_id.as_str());
            if snapshot.file(&path).is_none() {
                body.insert("artifact_commit", snapshot.commit_id.as_str());
                body.insert("idempotent", true);
                body.insert("warnings", Value::List(Vec::new()));
                return reply(200, body);
            }
            let result = context.manager.delete(
                &ticket_id,
                &EventArgs {
                    event_id: board_event_id("delete", request.get("request_id")),
                    device_id: self.device_id.clone(),
                    ..EventArgs::default()
                },
            )?;
            match &result.write {
                Some(write) => {
                    body.insert("artifact_commit", write.commit_id.as_str());
                    body.insert("idempotent", write.idempotent);
                }
                None => {
                    body.insert("artifact_commit", snapshot.commit_id.as_str());
                    body.insert("idempotent", true);
                }
            }
            body.insert("warnings", strings(&result.warnings));
            reply(200, body)
        })
    }

    pub fn artifact_board_write_attachment(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        let token = body_token(request);
        let ticket_id = request.text("ticket_id");
        let filename = request.text("filename");
        let mime_type = request.text("mime_type");
        let content_base64 = request.text("content_base64");
        let lifecycle = self.artifact_board_lifecycle(&repo_path, token.as_deref())?;
        let content = b64decode_strict(&content_base64)
            .ok_or_else(|| Failure::value("attachment content is not valid base64"))?;
        let snapshot = lifecycle.store.snapshot()?;
        if snapshot
            .file(&format!(".orchestrator/{ticket_id}.md"))
            .is_none()
        {
            return Err(Failure::value(format!(
                "attachment owner ticket does not exist: {ticket_id}"
            )));
        }
        let mut mutation = Mutation::new(
            &board_event_id("attachment", request.get("request_id")),
            "user",
            &self.device_id,
            vec![Operation::AttachmentWrite {
                ticket_id: ticket_id.clone(),
                filename: filename.clone(),
                mime_type,
                content,
            }],
        );
        mutation.expected_base = Some(snapshot.commit_id.clone());
        mutation.summary = format!("Attach {filename} to Relay ticket {ticket_id}");
        let write = lifecycle.store.mutate(&mutation)?;
        let mut body = Dict::new();
        body.insert("ticket_id", ticket_id);
        body.insert("filename", filename);
        body.insert("artifact_commit", write.commit_id);
        body.insert("idempotent", write.idempotent);
        reply(200, body)
    }

    /// `sweep_artifact_retention()`: maintain every available registered
    /// project; a blocked project never stops the others.
    pub fn sweep_artifact_retention(&self) -> Vec<Dict> {
        let mut results = Vec::new();
        for repo_path in registered_project_repo_paths(&self.paths.registry_v2) {
            match self.sweep_project_retention(&repo_path) {
                Ok(None) => {}
                Ok(Some(result)) => {
                    let mut entry = Dict::new();
                    entry.insert("repo_path", repo_path.as_str());
                    entry.update(&result);
                    results.push(entry);
                }
                Err(failure) => {
                    let mut entry = Dict::new();
                    entry.insert("repo_path", repo_path.as_str());
                    entry.insert("state", "blocked");
                    entry.insert("recovery", failure.message);
                    results.push(entry);
                }
            }
        }
        results
    }

    fn sweep_project_retention(&self, repo_path: &str) -> Outcome<Option<Dict>> {
        let preparation = prepare_project_retention(
            std::path::Path::new(repo_path),
            &self.paths.state_root,
            &self.paths.registry_v2,
            &self.lifecycles.rollout,
        )?;
        if preparation.is_some() {
            return Ok(preparation);
        }
        let Some(lifecycle) = self.artifact_lifecycle(repo_path)? else {
            return Ok(None);
        };
        let project_id = lifecycle.store.project_id.clone();
        let decision = self
            .lifecycles
            .rollout
            .decision(&project_id, "existing", true)?;
        if !decision.artifact_sync_enabled {
            return Ok(None);
        }
        lifecycle.validate_scope(None, Some(&project_id))?;
        Ok(Some(sweep_automatic_retention(
            &lifecycle.store,
            Some(lifecycle.leases.clone()),
        )?))
    }
}

/// The `.orchestrator/config.toml` bump of a claim: the rendered config, the
/// prefix and the claimed number.
fn claim_config(content: &[u8]) -> Outcome<(String, String, i64)> {
    let invalid =
        |message: String| Failure::value(format!("artifact config is invalid: {message}"));
    let text = pystr::decode_utf8(content).map_err(|error| invalid(error.message))?;
    let config = toml::loads(text).map_err(|error| invalid(error.message))?;
    let prefix = match config.get("prefix") {
        Some(value) if value.truthy() => crate::daemon::toml_to_json(value).py_str(),
        _ => String::new(),
    };
    let prefix = pystr::strip(&prefix).to_string();
    let next_id = match config.get("next_id") {
        Some(toml::Value::Integer(number)) => Some(*number),
        _ => None,
    };
    let valid_prefix = !prefix.is_empty() && prefix.chars().all(char::is_alphanumeric);
    let next_id = match next_id {
        Some(number) if valid_prefix && number > 0 => number,
        _ => {
            return Err(Failure::value(
                "artifact config has no valid prefix/next_id",
            ));
        }
    };
    let pattern = Regex::new(r"(?m)^next_id[\s\x1c-\x1f]*=[\s\x1c-\x1f]*[^\n]+$")
        .map_err(|error| Failure::runtime(error.to_string()))?;
    let found = pattern
        .find(text)
        .map_err(|error| Failure::runtime(error.to_string()))?;
    let Some(found) = found else {
        return Err(Failure::value("artifact config next_id is ambiguous"));
    };
    let rendered = format!(
        "{}next_id = {}{}",
        &text[..found.start()],
        next_id + 1,
        &text[found.end()..]
    );
    Ok((rendered, prefix, next_id))
}

/// `"ticket-" + sha256(f"{project_id}:{ticket_id}")[:40]`.
pub fn default_artifact_id(project_id: &str, ticket_id: &str) -> String {
    let digest = relay_intents::sha256::hex_digest(format!("{project_id}:{ticket_id}").as_bytes());
    format!("ticket-{}", &digest[..40])
}

fn strings(values: &[String]) -> Value {
    Value::List(
        values
            .iter()
            .map(|value| Value::from(value.as_str()))
            .collect(),
    )
}

/// The body of an archive result: `state`, `ticket_ids`, `artifact_commit`,
/// `idempotent` (when given), `warnings` and `recovery`.
fn archive_body(result: &ArchiveResult, idempotent: Option<bool>, warnings: bool) -> Dict {
    let mut body = Dict::new();
    body.insert("state", result.state.value());
    body.insert("ticket_ids", strings(&result.ticket_ids));
    body.insert(
        "artifact_commit",
        result
            .write
            .as_ref()
            .map_or(Value::Null, |write| Value::from(write.commit_id.as_str())),
    );
    if let Some(idempotent) = idempotent {
        body.insert("idempotent", idempotent);
    }
    if warnings {
        body.insert("warnings", strings(&result.warnings));
    }
    body.insert("recovery", result.recovery.clone());
    body
}

/// The card of `artifact_history_detail`, in its key order.
fn detail_card(card: &HistoricalCard) -> Value {
    let mut value = Dict::new();
    value.insert("artifact_id", card.artifact_id.as_str());
    value.insert("ticket_id", card.ticket_id.as_str());
    value.insert("title", card.title.as_str());
    value.insert("status", card.status.as_str());
    value.insert("state", card.state.value());
    value.insert("activity_at", card.activity_at.isoformat_z());
    Value::Dict(value)
}

/// The archive catalog entry naming `ticket_id`, as `manager._catalog(head)`
/// lists it.
fn catalog_entry(
    manager: &ArtifactRetentionManager<'_>,
    head: &str,
    ticket_id: &str,
) -> Outcome<Option<Dict>> {
    let catalog = manager.catalog(head)?;
    Ok(catalog
        .iter()
        .filter_map(|(_, entry)| entry.as_dict())
        .find(|entry| {
            entry
                .get("ticket_id")
                .is_some_and(|value| value.is_str(ticket_id))
        })
        .cloned())
}

/// One dependency of `artifact_dependency_summary`.
fn dependency_summary(
    manager: &ArtifactRetentionManager<'_>,
    dependency_id: &str,
) -> Outcome<Dict> {
    let mut summary = Dict::new();
    summary.insert("ticket_id", dependency_id);
    match manager.dependency_satisfied(dependency_id, None) {
        Ok(satisfied) => {
            summary.insert("satisfied", satisfied);
            summary.insert(
                "availability",
                if satisfied {
                    "available"
                } else {
                    "unsatisfied"
                },
            );
            summary.insert("recovery", Value::Null);
        }
        Err(error) if error.kind == ErrorKind::DependencyHistoryUnavailable => {
            // `error.detail`: the archived dependency's history, read again.
            let snapshot = manager.store.snapshot()?;
            let detail = catalog_entry(manager, &snapshot.commit_id, dependency_id)?
                .map(|entry| {
                    manager.historical_detail(
                        &entry
                            .get("artifact_id")
                            .map(Value::py_str)
                            .unwrap_or_default(),
                        HistoryAccess::default(),
                    )
                })
                .transpose()?;
            summary.insert("satisfied", false);
            summary.insert(
                "availability",
                detail
                    .as_ref()
                    .map_or(HistoryAvailability::NotFound.value(), |detail| {
                        detail.availability.value()
                    }),
            );
            summary.insert(
                "recovery",
                detail
                    .and_then(|detail| detail.recovery)
                    .map_or(Value::Null, Value::Str),
            );
        }
        Err(error) if error.kind.is_validation() => {
            summary.insert("satisfied", false);
            summary.insert("availability", "unavailable");
            summary.insert("recovery", error.message);
        }
        Err(error) => return Err(error.into()),
    }
    Ok(summary)
}

/// `_recover_artifact_lifecycle_leases()`: at startup, release the snapshot
/// leases of runs that are no longer live and retry an unfinished retention
/// publication, for every available registered project.
pub fn recover_artifact_lifecycle_leases(daemon: &Daemon) {
    let Some(document) = read_json(&daemon.paths.registry_v2) else {
        return;
    };
    for record in crate::daemon::projects(&document) {
        if !record
            .get("availability")
            .is_some_and(|value| value.is_str("available"))
        {
            continue;
        }
        let repo_path = record
            .get("last_resolved_path")
            .filter(|value| value.truthy())
            .map(Value::py_str)
            .unwrap_or_default();
        let repo_path = pystr::strip(&repo_path).to_string();
        if repo_path.is_empty() {
            continue;
        }
        if let Err(error) = recover_project_leases(daemon, &repo_path) {
            eprintln!("[orchestrator] artifact lifecycle recovery failed for {repo_path}: {error}");
        }
    }
}

fn recover_project_leases(daemon: &Daemon, repo_path: &str) -> Outcome<()> {
    let Some(lifecycle) = daemon.artifact_lifecycle(repo_path)? else {
        return Ok(());
    };
    // A failed or canceled spike's lease is released only by publishing its
    // canonical result, which spike execution (RR-498) owns; keep it.
    let mut pending_spikes = Vec::new();
    for lease in lifecycle.leases.active()? {
        let Some(run_id) = pystr::int(&lease.run_id) else {
            continue;
        };
        if let Some(run) = daemon.runs.get(run_id)?
            && run
                .get("execution_mode")
                .is_some_and(|mode| mode.is_str(relay_store::runs::SPIKE_EXECUTION_MODE))
            && run
                .get("state")
                .is_some_and(|state| state.is_str("Failed") || state.is_str("Canceled"))
        {
            pending_spikes.push(run_id);
        }
    }
    let run_state = |run_id: i64| -> Option<String> {
        daemon
            .runs
            .get(run_id)
            .ok()
            .flatten()
            .and_then(|run| run.get("state").filter(|state| state.truthy()).cloned())
            .map(|state| state.py_str())
    };
    lifecycle.recover_leases(&run_state, &pending_spikes)?;
    let snapshot = lifecycle.store.snapshot()?;
    let text = pystr::decode_utf8(config_bytes(&snapshot)?)?;
    let config = toml::loads(text)?;
    let text_of = |key: &str| match config.get(key) {
        Some(value) if value.truthy() => Some(crate::daemon::toml_to_json(value).py_str()),
        _ => None,
    };
    let raw_mode = text_of("remote_sync").unwrap_or_else(|| "local_only".to_string());
    let mode = SyncMode::from_value(&raw_mode).ok_or_else(|| {
        Failure::value(format!(
            "{} is not a valid ArtifactSyncMode",
            pystr::repr(&raw_mode)
        ))
    })?;
    let remote_name = text_of("remote_name")
        .map(|name| pystr::strip(&name).to_string())
        .filter(|name| !name.is_empty());
    let engine = if mode == SyncMode::LocalOnly {
        None
    } else {
        Some(ArtifactSyncEngine::new(
            &lifecycle.store,
            SyncOptions::new(mode, remote_name.as_deref()),
        )?)
    };
    let manager = ArtifactRetentionManager::new(
        &lifecycle.store,
        RetentionOptions {
            lease_store: Some(lifecycle.leases.clone()),
            remote_mode: mode.value().to_string(),
            synchronizer: engine.as_ref(),
            enabled: true,
            ..RetentionOptions::default()
        },
    )?;
    if manager
        .transaction_status()?
        .get("retry_available")
        .is_some_and(Value::truthy)
    {
        manager.recover_archive(engine.as_ref())?;
    }
    Ok(())
}

/// The `ticket-retention` loop of `serve`: sweep when the registry changes
/// and at least every minute; `wait(seconds)` is false once the daemon stops.
pub fn retention_loop(daemon: &Daemon, wait: &dyn Fn(f64) -> bool) {
    let mut previous: HashMap<String, Dict> = HashMap::new();
    let mut registry_revision: Option<Option<String>> = None;
    let mut next_sweep = Monotonic::now();
    loop {
        let revision = retention_registry_revision(&daemon.paths.registry_v2);
        if registry_revision.as_ref() == Some(&revision) && Monotonic::now() < next_sweep {
            if !wait(2.0) {
                return;
            }
            continue;
        }
        registry_revision = Some(revision);
        for result in daemon.sweep_artifact_retention() {
            let repo = result.string("repo_path");
            let state = result.string("state");
            let changed = previous.get(&repo).is_none_or(|earlier| {
                !json::py_eq(&Value::Dict(earlier.clone()), &Value::Dict(result.clone()))
            });
            if state != "clean" && state != "disabled" && changed {
                eprintln!(
                    "[orchestrator] automatic retention: {}",
                    python_dict_repr(&result)
                );
            }
            previous.insert(repo, result);
        }
        next_sweep = Monotonic::now() + Duration::from_secs(60);
        if !wait(2.0) {
            return;
        }
    }
}

/// A short `repr` of a result dict for the log line.
fn python_dict_repr(value: &Dict) -> String {
    json::dumps(&Value::Dict(value.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::failure::Class;

    #[test]
    fn event_ids_keep_safe_characters_only() {
        assert_eq!(
            board_event_id("claim", Some(&Value::from("claim-1"))),
            "board-claim:claim-1"
        );
        assert_eq!(
            board_event_id("ticket", Some(&Value::from(" a b/c\u{e9} "))),
            "board-ticket:a-b-c"
        );
        assert_eq!(
            board_event_id("delete", Some(&Value::Int(7))),
            "board-delete:7"
        );
        let generated = board_event_id("attachment", None);
        assert!(generated.starts_with("board-attachment:"));
        assert_eq!(generated.len(), "board-attachment:".len() + 32);
        let long = "x".repeat(200);
        assert_eq!(
            board_event_id("claim", Some(&Value::from(long.as_str()))).len(),
            "board-claim:".len() + 120
        );
    }

    #[test]
    fn upsert_inserts_after_the_id_and_replaces_existing_fields() {
        let markdown = b"---\nid: CT-1\ntitle: \"T\"\n---\n\nBody\n";
        let edited = upsert_frontmatter_fields(markdown, &[("user_edited_at", "now")]).unwrap();
        assert_eq!(
            String::from_utf8(edited.clone()).unwrap(),
            "---\nid: CT-1\nuser_edited_at: now\ntitle: \"T\"\n---\n\nBody\n"
        );
        let again = upsert_frontmatter_fields(&edited, &[("user_edited_at", "later")]).unwrap();
        assert_eq!(
            String::from_utf8(again).unwrap(),
            "---\nid: CT-1\nuser_edited_at: later\ntitle: \"T\"\n---\n\nBody\n"
        );
        assert_eq!(
            upsert_frontmatter_fields(b"no front", &[])
                .unwrap_err()
                .message,
            "ticket markdown has no frontmatter"
        );
        assert_eq!(
            upsert_frontmatter_fields(b"---\nid: x\n", &[])
                .unwrap_err()
                .message,
            "ticket markdown frontmatter is not closed"
        );
    }

    #[test]
    fn claims_bump_the_first_next_id_line() {
        let (rendered, prefix, next_id) =
            claim_config(b"prefix = \"CT\"\nnext_id = 2\nproject_id = \"p\"\n").unwrap();
        assert_eq!(prefix, "CT");
        assert_eq!(next_id, 2);
        assert_eq!(
            rendered,
            "prefix = \"CT\"\nnext_id = 3\nproject_id = \"p\"\n"
        );
        assert_eq!(
            claim_config(b"prefix = \"C-T\"\nnext_id = 2\n")
                .unwrap_err()
                .message,
            "artifact config has no valid prefix/next_id"
        );
        assert_eq!(
            claim_config(b"prefix = \"CT\"\nnext_id = 0\n")
                .unwrap_err()
                .message,
            "artifact config has no valid prefix/next_id"
        );
        assert!(
            claim_config(b"prefix = [")
                .unwrap_err()
                .message
                .starts_with("artifact config is invalid: ")
        );
    }

    #[test]
    fn default_artifact_ids_hash_the_project_and_ticket() {
        let id = default_artifact_id("contract-board", "CT-2");
        assert!(id.starts_with("ticket-"));
        assert_eq!(id.len(), "ticket-".len() + 40);
    }

    #[test]
    fn concurrent_updates_are_recognised() {
        let error = relay_artifacts::Error::new(ErrorKind::ConcurrentUpdate, "moved");
        assert!(is_concurrent(&error));
        assert_eq!(Failure::from(error).class, Class::Concurrent);
    }
}
