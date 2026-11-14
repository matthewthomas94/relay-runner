//! Orchestrator sessions, the voice command ledger, messenger outcomes and
//! the continuity lane: `ensure_orchestrator_session`, `heartbeat_...`,
//! `stop_...`, `record_orchestrator_command`, `process_orchestrator_commands`,
//! `reconcile_orchestrator_command_states`, the messenger outcome routes,
//! `observe_continuity_event`, `sample_continuity` and the continuity report
//! review.
//!
//! The continuity agent lane (`continuity_agents`) and its recovery broker
//! need a provider session launcher, which is worker execution (RR-498), so
//! an incident is recorded to `continuity_incidents.jsonl` and not yet
//! submitted to an agent.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use relay_intents::json::{self, Dict, Value, py_strip};
use relay_services::authorization::authorization_exists;
use relay_services::command_actions::resolve_command_action;
use relay_services::continuity::incidents::Classification;
use relay_services::continuity::lifecycle::ContinuityLifecycleAdapter;
use relay_services::continuity::reports::sanitize_proposal;
use relay_store::commands::{CommandRecord, CommandStatus, TERMINAL_STATUSES};
use relay_store::messenger::PendingQuery;
use relay_store::sessions::{EnsureSession, session_key};

use crate::actions::{
    ActionBatch, DispatchCall, autonomous_ticket_action, is_value_error, scan_tickets,
};
use crate::daemon::{Daemon, registered_project_repo_paths, resolve_path};
use crate::failure::{Failure, Outcome};
use crate::relay_command::{
    VoiceFields, mutation_metadata, optional_relay_session_key, relay_command_current,
    validate_relay_command,
};
use crate::request::{Request, parse_int};
use crate::router::{Reply, reply, single};
use crate::trace::{PMStatusEvent, RelayCommandMetadata};

/// A session id that matches no row: SQLite compares a non-numeric value
/// with the integer key and finds nothing.
const NO_ROW: i64 = i64::MIN;

/// `session_id` as SQLite binds the body's value against `id = ?`.
fn session_id_param(value: Option<&Value>) -> Option<i64> {
    match value {
        None | Some(Value::Null) => None,
        Some(Value::Bool(flag)) => Some(i64::from(*flag)),
        Some(Value::Int(number)) => Some(*number),
        Some(Value::Float(number)) if number.fract() == 0.0 && number.is_finite() => {
            Some(*number as i64)
        }
        Some(Value::Str(text)) => Some(py_strip(text).parse().unwrap_or(NO_ROW)),
        Some(_) => Some(NO_ROW),
    }
}

/// `int(value)` when Python's `int()` takes it.
fn int_of(value: Option<&Value>) -> Option<i64> {
    value.and_then(Value::py_int)
}

/// `str(value)` when truthy, as the stores take their optional text.
fn truthy_text(value: Option<&Value>) -> Option<String> {
    value.filter(|value| value.truthy()).map(Value::py_str)
}

fn list(items: Vec<Dict>) -> Value {
    Value::List(items.into_iter().map(Value::Dict).collect())
}

/// One classification as the observation route answers it.
fn classification_dict(result: &Classification) -> Dict {
    let mut value = Dict::new();
    value.insert("state", result.state.as_str());
    value.insert("fingerprint", result.fingerprint.clone());
    value.insert("suppression_reason", result.suppression_reason.clone());
    value.insert(
        "incident",
        result.envelope.as_ref().map(|envelope| envelope.as_dict()),
    );
    value
}

impl Daemon {
    pub fn list_orchestrator_sessions_route(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_first("repo_path");
        let limit = request.query_int("limit", 100)?;
        let sessions = self
            .orchestrator_sessions
            .list(repo_path.as_deref(), limit)?;
        reply(200, single("orchestrator_sessions", list(sessions)))
    }

    pub fn pending_messenger_outcomes_route(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_first("repo_path");
        let limit = request.query_int("limit", 20)?;
        let session_key = request.query_first("session_key").map(Value::from);
        let live_session_keys = request
            .query_or("live_session_keys", "")
            .split(',')
            .filter(|key| !key.is_empty())
            .filter_map(|key| optional_relay_session_key(Some(&Value::from(key))))
            .collect();
        // `provider` is accepted and, as in Python, does not filter.
        let outcomes = self.messenger_outcomes.pending(&PendingQuery {
            repo_path,
            limit,
            session_key: optional_relay_session_key(session_key.as_ref()),
            live_session_keys,
        })?;
        reply(200, single("outcomes", list(outcomes)))
    }

    pub fn mark_messenger_outcome_delivered_route(&self, request: &Request) -> Outcome<Reply> {
        let outcome_id = parse_int(&request.segments[3])?;
        let outcome = self.messenger_outcomes.mark_delivered(outcome_id)?;
        let status = if outcome.as_ref().is_some_and(|row| !row.is_empty()) {
            200
        } else {
            404
        };
        reply(status, single("outcome", outcome))
    }

    pub fn record_messenger_outcome_attempt_route(&self, request: &Request) -> Outcome<Reply> {
        let outcome_id = parse_int(&request.segments[3])?;
        self.messenger_outcomes.record_attempt(outcome_id)?;
        reply(202, single("ok", true))
    }

    pub fn ensure_orchestrator_session_route(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        if repo_path.is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let repo = resolve_path(&repo_path);
        if !repo.is_dir() {
            return Err(Failure::value(format!(
                "repo_path {} is not a directory",
                repo.display()
            )));
        }
        let repo_text = repo.to_string_lossy().into_owned();
        let general = self.config_table("general");
        let provider_key = truthy_text(request.get("provider"))
            .or_else(|| truthy_text(general.get("provider")))
            .unwrap_or_else(|| self.agent_kind.clone());
        let session = self.orchestrator_sessions.ensure(&EnsureSession {
            repo_path: repo_text.clone(),
            provider_key: Some(provider_key),
            model_alias: truthy_text(request.get("model"))
                .or_else(|| truthy_text(general.get("model"))),
            effort: truthy_text(request.get("effort"))
                .or_else(|| truthy_text(general.get("orchestrator_effort"))),
            source: Some(
                truthy_text(request.get("source")).unwrap_or_else(|| "direct".to_string()),
            ),
            pid: int_of(request.get("pid")),
            state: Some(truthy_text(request.get("state")).unwrap_or_else(|| "idle".to_string())),
        })?;
        self.observe_session_event(&session, "session", "started", "updated_at")?;
        let states = match request.get("command_action_states") {
            Some(Value::List(items)) => items.clone(),
            _ => Vec::new(),
        };
        let reconciliation = self.reconcile_orchestrator_command_states(&repo_text, &states)?;
        if let Err(error) = self.process_commands(Some(&repo_text), 10) {
            eprintln!("[orchestrator] command resume failed for {repo_text}: {error}");
        }
        let recoverable = self
            .orchestrator_commands
            .recoverable(Some(&repo_text), 10)?;
        let created = session.get("created").is_some_and(Value::truthy);
        let mut result = Dict::new();
        result.insert("orchestrator_session", session);
        result.insert("command_action_reconciliation", reconciliation);
        result.insert("recoverable_commands", list(recoverable));
        reply(if created { 201 } else { 200 }, result)
    }

    pub fn heartbeat_orchestrator_session_route(&self, request: &Request) -> Outcome<Reply> {
        let session = self
            .orchestrator_sessions
            .heartbeat(
                session_id_param(request.get("session_id")),
                request.optional_text("repo_path").as_deref(),
                request.optional_text("provider").as_deref(),
                request.optional_text("state").as_deref(),
            )?
            .ok_or_else(|| Failure::value("orchestrator session not found"))?;
        self.observe_session_event(&session, "daemon", "heartbeat", "heartbeat_at")?;
        reply(200, single("orchestrator_session", session))
    }

    pub fn observe_continuity_event_route(&self, request: &Request) -> Outcome<Reply> {
        reply(202, self.observe_continuity_event(&request.body)?)
    }

    pub fn stop_orchestrator_session_route(&self, request: &Request) -> Outcome<Reply> {
        let session = self
            .orchestrator_sessions
            .stop(
                session_id_param(request.get("session_id")),
                request.optional_text("repo_path").as_deref(),
                request.optional_text("reason").as_deref(),
            )?
            .ok_or_else(|| Failure::value("orchestrator session not found"))?;
        self.observe_session_event(&session, "session", "explicit_stop", "updated_at")?;
        reply(200, single("orchestrator_session", session))
    }

    pub fn record_orchestrator_command_route(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.text("repo_path");
        if repo_path.is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let seq = request
            .get("relay_command_seq")
            .cloned()
            .unwrap_or(Value::Null);
        let command_id = truthy_text(request.get("relay_command_id")).unwrap_or_default();
        let intent_id = truthy_text(request.get("intent_id"));
        let request_id = Value::from(intent_id.clone().unwrap_or_else(|| command_id.clone()));
        validate_relay_command(
            &self.paths,
            &VoiceFields {
                relay_command_seq: Some(seq.clone()),
                relay_command_id: request.get("relay_command_id").cloned(),
                relay_intent_id: request.get("intent_id").cloned(),
                relay_session_key: None,
            },
            Some(&mutation_metadata(
                "orchestrator_command",
                None,
                None,
                None,
                Some(&request_id),
            )),
        )?;
        let status = truthy_text(request.get("status")).unwrap_or_else(|| "received".to_string());
        let mut requested_status = py_strip(&status).to_lowercase();
        let mut outcome = truthy_text(request.get("outcome"));
        let action = truthy_text(request.get("action"));
        let defer = request.truthy_or("defer_processing", false);
        let repo = resolve_path(&repo_path);
        let work_action = action.as_deref().is_some_and(|action| {
            ["create_ticket", "update_ticket", "dispatch_ticket"]
                .contains(&py_strip(action).to_lowercase().as_str())
        });
        let has_child_repos = repo.is_dir()
            && std::fs::read_dir(&repo).is_ok_and(|entries| {
                entries
                    .filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .any(|child| child.is_dir() && child.join(".git").exists())
            });
        let concrete_project = repo.join(".git").exists() && !has_child_repos;
        let mut status_message = None;
        if defer && work_action && !concrete_project {
            requested_status = "clarification_required".to_string();
            outcome = Some("waiting-for-project-choice".to_string());
            status_message = Some(
                "Waiting for a target project; the active route is a workspace root, so no \
                 parent ticket was created."
                    .to_string(),
            );
        } else if defer && ["received", "classified"].contains(&requested_status.as_str()) {
            requested_status = "queued".to_string();
        }
        let mut result = self.orchestrator_commands.record(&CommandRecord {
            repo_path: repo_path.clone(),
            source_text: request.text("source_text"),
            relay_command_seq: seq,
            relay_command_id: command_id.clone(),
            intent_id: intent_id.clone(),
            within_turn_order: request.get("within_turn_order").cloned(),
            session_id: int_of(request.get("session_id")),
            provider_key: truthy_text(request.get("provider")),
            recovery_generation: request
                .get("recovery_generation")
                .filter(|value| value.truthy())
                .cloned()
                .unwrap_or_else(|| Value::from("0")),
            context: truthy_text(request.get("context")),
            action,
            outcome: outcome.clone(),
            target: truthy_text(request.get("target")),
            disposition: truthy_text(request.get("disposition")),
            cancellation_scope: truthy_text(request.get("cancellation_scope")),
            lifecycle_state: truthy_text(request.get("lifecycle_state")),
            received_at: request.get("received_at").and_then(Value::py_float),
            status: Some(requested_status.clone()),
        })?;
        self.observe_command_continuity(&result, "accepted");
        if let Some(message) = status_message
            && let Some(updated) = self.orchestrator_commands.update_status(
                &command_id,
                intent_id.as_deref(),
                &CommandStatus {
                    status: requested_status,
                    outcome,
                    status_message: Some(message),
                    ..CommandStatus::default()
                },
            )?
        {
            result = updated;
        }
        if TERMINAL_STATUSES.contains(&result.string("status").as_str()) {
            self.observe_command_continuity(&result, "completed");
        }
        let mut body = Dict::new();
        if defer {
            body.insert("orchestrator_command", result);
            body.insert("processing", single("processed", Value::List(Vec::new())));
            return reply(202, body);
        }
        let processing = self.process_commands(Some(&repo_path), 10)?;
        let latest = self
            .orchestrator_commands
            .get_public(&command_id, intent_id.as_deref())?
            .unwrap_or(result);
        body.insert("orchestrator_command", latest);
        body.insert("processing", processing);
        reply(202, body)
    }

    pub fn get_continuity_report_route(&self, request: &Request) -> Outcome<Reply> {
        reply(200, self.get_continuity_report(&request.segments[2])?)
    }

    pub fn review_continuity_proposal_route(&self, request: &Request) -> Outcome<Reply> {
        let report_id = &request.segments[2];
        let proposal_id = &request.segments[4];
        let decision = py_strip(&request.text("decision")).to_lowercase();
        if !["edit", "accept", "reject"].contains(&decision.as_str()) {
            return Err(Failure::value(
                "decision must be 'edit', 'accept', or 'reject'",
            ));
        }
        let updates = request
            .get("updates")
            .filter(|value| !matches!(value, Value::Null));
        let report = match updates {
            Some(Value::Dict(updates)) => {
                let mut proposal_updates = updates.clone();
                proposal_updates.remove("target_repo_path");
                self.continuity_reports.update_draft(
                    report_id,
                    proposal_id,
                    &proposal_updates,
                    |merged| {
                        sanitize_proposal(&Value::Dict(merged.clone()))
                            .map_err(|error| relay_store::Error::Invalid(error.message))
                    },
                )?
            }
            Some(_) => return Err(Failure::value("updates must be an object")),
            None => self.get_continuity_report(report_id)?,
        };
        if decision == "edit" {
            if updates.is_none() {
                return Err(Failure::value("edit requires updates"));
            }
            let mut result = single("report", report);
            result.insert("edited", proposal_id.as_str());
            return reply(200, result);
        }
        if decision == "reject" {
            let mut result = single(
                "report",
                self.continuity_reports.reject(report_id, proposal_id)?,
            );
            result.insert("rejected", proposal_id.as_str());
            return reply(200, result);
        }
        let voice = VoiceFields::from_body(&request.body);
        reply(
            200,
            self.accept_continuity_proposal(
                report_id,
                proposal_id,
                &report,
                request.get("target_repo_path"),
                &voice,
            )?,
        )
    }
}

impl Daemon {
    /// `observe_continuity_event(event)`.
    pub fn observe_continuity_event(&self, event: &Dict) -> Outcome<Dict> {
        Ok(classification_dict(&self.continuity.observe(event)?))
    }

    /// The continuity event a session change reports.
    fn observe_session_event(
        &self,
        session: &Dict,
        source: &str,
        event: &str,
        time_field: &str,
    ) -> Outcome<()> {
        let mut observation = Dict::new();
        observation.insert("source", source);
        observation.insert("event", event);
        observation.insert(
            "session_id",
            session.get("session_key").cloned().unwrap_or(Value::Null),
        );
        observation.insert(
            "provider",
            session.get("provider_key").cloned().unwrap_or(Value::Null),
        );
        observation.insert(
            "observed_at",
            session.get(time_field).cloned().unwrap_or(Value::Null),
        );
        self.observe_continuity_event(&observation)?;
        Ok(())
    }

    /// `_observe_command_continuity(command, event)`.
    fn observe_command_continuity(&self, command: &Dict, event: &str) {
        let known_session = int_of(command.get("session_id"))
            .and_then(|id| self.orchestrator_sessions.get(id).ok().flatten())
            .and_then(|session| truthy_text(session.get("session_key")));
        let session_id = known_session.unwrap_or_else(|| {
            let repo = truthy_text(command.get("repo_path"))
                .unwrap_or_else(|| self.paths.workspace_root.to_string_lossy().into_owned());
            session_key(&repo)
        });
        let mut observation = Dict::new();
        observation.insert("source", "command");
        observation.insert("event", event);
        observation.insert("session_id", session_id);
        observation.insert(
            "relay_command_id",
            command
                .get("relay_command_id")
                .cloned()
                .unwrap_or(Value::Null),
        );
        observation.insert(
            "provider",
            command
                .truthy("provider_key")
                .cloned()
                .unwrap_or_else(|| Value::from(self.agent_kind.as_str())),
        );
        observation.insert(
            "recovery_generation",
            command
                .truthy("recovery_generation")
                .cloned()
                .unwrap_or_else(|| Value::from("0")),
        );
        observation.insert("observed_at", relay_store::sql::now());
        if let Err(error) = self.continuity.observe(&observation) {
            eprintln!("[orchestrator] ignored invalid continuity event: {error}");
        }
    }

    /// `reconcile_orchestrator_command_states(repo_path=, command_states=)`.
    fn reconcile_orchestrator_command_states(
        &self,
        repo_path: &str,
        command_states: &[Value],
    ) -> Outcome<Dict> {
        let repo = resolve_path(repo_path).to_string_lossy().into_owned();
        let protected: Vec<&str> = TERMINAL_STATUSES
            .iter()
            .copied()
            .filter(|status| {
                !["delivery_failed", "superseded", "clarification_required"].contains(status)
            })
            .collect();
        let mut reconciled = Vec::new();
        let mut ignored = Vec::new();
        let start = command_states.len().saturating_sub(200);
        for raw in &command_states[start..] {
            let Some(raw) = raw.as_dict() else {
                continue;
            };
            let command_id = raw.text("relay_command_id");
            let intent = raw.text("intent_id");
            let intent_id = Some(intent.as_str()).filter(|id| !id.is_empty());
            let state = py_strip(
                &raw.truthy("state")
                    .or_else(|| raw.truthy("status"))
                    .map(Value::py_str)
                    .unwrap_or_default(),
            )
            .to_lowercase();
            let Some(command_seq) = int_of(raw.get("relay_command_seq")) else {
                continue;
            };
            if command_id.is_empty()
                || !["claimed", "delivery_failed", "superseded"].contains(&state.as_str())
            {
                continue;
            }
            let event_repo = truthy_text(raw.get("repo_path")).unwrap_or_else(|| repo.clone());
            if resolve_path(&event_repo).to_string_lossy() != repo {
                ignored.push(Value::from(command_id));
                continue;
            }
            let Some(existing) = self
                .orchestrator_commands
                .get_private(&command_id, intent_id)?
            else {
                if state != "delivery_failed" {
                    ignored.push(Value::from(command_id));
                    continue;
                }
                let source_text = Some(raw.text("source_text"))
                    .filter(|text| !text.is_empty())
                    .unwrap_or_else(|| {
                        "Relay command delivery failed before provider readiness.".to_string()
                    });
                self.orchestrator_commands.record(&CommandRecord {
                    repo_path: repo.clone(),
                    source_text,
                    relay_command_seq: Value::Int(command_seq),
                    relay_command_id: command_id.clone(),
                    intent_id: intent_id.map(str::to_string),
                    within_turn_order: raw.get("within_turn_order").cloned(),
                    provider_key: truthy_text(raw.get("provider")),
                    action: truthy_text(raw.get("action")),
                    outcome: Some("delivery-failed".to_string()),
                    target: truthy_text(raw.get("target")),
                    disposition: truthy_text(raw.get("disposition")),
                    cancellation_scope: truthy_text(raw.get("cancellation_scope")),
                    lifecycle_state: truthy_text(raw.get("lifecycle_state")),
                    received_at: raw.get("received_at").and_then(Value::py_float),
                    status: Some("delivery_failed".to_string()),
                    ..CommandRecord::default()
                })?;
                if let Some(updated) = self.orchestrator_commands.update_status(
                    &command_id,
                    intent_id,
                    &CommandStatus {
                        status: "delivery_failed".to_string(),
                        outcome: Some("delivery-failed".to_string()),
                        status_message: Some(
                            "Delivery failed before the embedded provider confirmed a ticket \
                             action."
                                .to_string(),
                        ),
                        ..CommandStatus::default()
                    },
                )? {
                    self.observe_command_continuity(&updated, "completed");
                    reconciled.push(Value::Dict(updated));
                }
                continue;
            };
            let existing_status = existing.string("status");
            if protected.contains(&existing_status.as_str())
                || (state == "claimed"
                    && !["received", "classified", "queued", "planning"]
                        .contains(&existing_status.as_str()))
                || (state == "delivery_failed" && existing_status == "superseded")
            {
                ignored.push(Value::from(command_id));
                continue;
            }
            let (outcome, message) = match state.as_str() {
                "delivery_failed" => (
                    "delivery-failed",
                    "Delivery failed before the embedded provider confirmed a ticket action.",
                ),
                "superseded" => (
                    "superseded",
                    "The command was superseded locally and will not be recovered or replayed.",
                ),
                _ => (
                    "provider-claimed",
                    "The embedded provider claimed the command before the previous session ended.",
                ),
            };
            if let Some(updated) = self.orchestrator_commands.update_status(
                &command_id,
                intent_id,
                &CommandStatus {
                    status: state.clone(),
                    outcome: Some(outcome.to_string()),
                    status_message: Some(message.to_string()),
                    ..CommandStatus::default()
                },
            )? {
                if TERMINAL_STATUSES.contains(&state.as_str()) {
                    self.observe_command_continuity(&updated, "completed");
                }
                reconciled.push(Value::Dict(updated));
            }
        }
        let mut result = Dict::new();
        result.insert("reconciled", Value::List(reconciled));
        result.insert("ignored", Value::List(ignored));
        Ok(result)
    }

    /// `process_orchestrator_commands(limit=...)`: the command loop's work.
    pub fn process_orchestrator_commands(&self, limit: i64) -> Outcome<()> {
        self.process_commands(None, limit).map(|_| ())
    }

    /// `process_orchestrator_commands(repo_path=, limit=)`:
    /// `{"processed": [...]}`.
    fn process_commands(&self, repo_path: Option<&str>, limit: i64) -> Outcome<Dict> {
        let commands = self.orchestrator_commands.pending(repo_path, limit)?;
        let mut processed = Vec::new();
        for command in commands {
            processed.push(Value::Dict(self.process_command(&command)?));
        }
        Ok(single("processed", Value::List(processed)))
    }

    /// `update_status(...) or fallback`.
    fn command_status(
        &self,
        command_id: &str,
        intent_id: &str,
        status: CommandStatus,
        fallback: Dict,
    ) -> Outcome<Dict> {
        Ok(self
            .orchestrator_commands
            .update_status(command_id, Some(intent_id), &status)?
            .unwrap_or(fallback))
    }

    /// `_process_orchestrator_command(command)`.
    fn process_command(&self, command: &Dict) -> Outcome<Dict> {
        let command_id = command.string("relay_command_id");
        if command_id.is_empty() {
            let mut result = single("status", "failed");
            result.insert("error", "missing relay_command_id");
            return Ok(result);
        }
        let intent_id = command
            .truthy("intent_id")
            .map(Value::py_str)
            .unwrap_or_else(|| command_id.clone());
        let fallback = |status: &str| {
            let mut result = single("relay_command_id", command_id.as_str());
            result.insert("status", status);
            result
        };
        let seq = command
            .get("relay_command_seq")
            .cloned()
            .unwrap_or(Value::Null);
        let id_value = command
            .get("relay_command_id")
            .cloned()
            .unwrap_or(Value::Null);
        let current = relay_command_current(&self.paths, Some(&seq), &command_id, None);
        if !current && !authorization_exists(&self.paths.authorization_file, &seq, &id_value, "") {
            let updated = self.orchestrator_commands.update_status(
                &command_id,
                Some(&intent_id),
                &CommandStatus {
                    status: "stale".to_string(),
                    outcome: Some("stale-command".to_string()),
                    status_message: Some(
                        "Skipped stale Relay command because a newer command superseded it."
                            .to_string(),
                    ),
                    ..CommandStatus::default()
                },
            )?;
            self.observe_command_continuity(updated.as_ref().unwrap_or(command), "completed");
            return Ok(updated.unwrap_or_else(|| fallback("stale")));
        }
        self.orchestrator_commands.update_status(
            &command_id,
            Some(&intent_id),
            &CommandStatus {
                status: "planning".to_string(),
                ..CommandStatus::default()
            },
        )?;
        self.observe_command_continuity(command, "planning");
        self.heartbeat_command_session(command, "planning");
        match self.handle_command(command, &command_id, &intent_id) {
            Ok(result) => Ok(result),
            Err(failure) => {
                let stale =
                    is_value_error(&failure) && failure.message.contains("stale Relay command");
                let (status, outcome, message) = if stale {
                    ("stale", "stale-command", failure.message.clone())
                } else if is_value_error(&failure) {
                    (
                        "blocked",
                        "blocked",
                        "Blocked while authoring a ticket.".to_string(),
                    )
                } else {
                    (
                        "failed",
                        "failed",
                        "Failed while authoring a ticket.".to_string(),
                    )
                };
                let updated = self.orchestrator_commands.update_status(
                    &command_id,
                    Some(&intent_id),
                    &CommandStatus {
                        status: status.to_string(),
                        outcome: Some(outcome.to_string()),
                        status_message: Some(message.clone()),
                        error: Some(failure.message.clone()),
                        ..CommandStatus::default()
                    },
                )?;
                if !stale {
                    self.heartbeat_command_session(command, status);
                    self.notify_command_outcome(command, &message, None, None);
                    self.observe_command_continuity(command, "failed");
                }
                self.observe_command_continuity(updated.as_ref().unwrap_or(command), "completed");
                if status == "failed" {
                    eprintln!("[orchestrator] command {command_id} failed: {failure}");
                }
                Ok(updated.unwrap_or_else(|| {
                    let mut result = fallback(status);
                    result.insert("error", failure.message);
                    result
                }))
            }
        }
    }

    /// The `try` body of `_process_orchestrator_command`.
    fn handle_command(&self, command: &Dict, command_id: &str, intent_id: &str) -> Outcome<Dict> {
        let fallback = |status: &str| {
            let mut result = single("relay_command_id", command_id);
            result.insert("status", status);
            result
        };
        let repo_path = command.string("repo_path");
        let mut relay = Dict::new();
        relay.insert(
            "relay_command_seq",
            command
                .get("relay_command_seq")
                .cloned()
                .unwrap_or(Value::Null),
        );
        relay.insert(
            "relay_command_id",
            command
                .get("relay_command_id")
                .cloned()
                .unwrap_or(Value::Null),
        );
        relay.insert("intent_id", intent_id);
        relay.insert(
            "within_turn_order",
            command
                .get("within_turn_order")
                .cloned()
                .unwrap_or(Value::Null),
        );
        if let Some(provider) = command.truthy("provider_key") {
            relay.insert("provider", provider.clone());
        }
        let action = resolve_command_action(
            &command.string("source_text"),
            Some(&repo_path),
            Some(&relay),
        );
        let kind = action.kind.as_str();
        if kind == "create_ticket" {
            let result = self.author_ticket_for_command(command, &relay, command_id, intent_id)?;
            self.observe_command_continuity(command, "completed");
            self.heartbeat_command_session(command, "idle");
            return Ok(result);
        }
        if let (true, Some(ticket_id)) = (
            ["dispatch_ticket", "update_ticket"].contains(&kind),
            action.ticket_id.as_deref(),
        ) {
            if kind == "dispatch_ticket" {
                let result = self.dispatch_ticket_internal(&DispatchCall {
                    ticket_id,
                    repo_path: &repo_path,
                    context: None,
                    source: "orchestrator-command",
                    relay_command_seq: command.get("relay_command_seq"),
                    relay_command_id: Some(&Value::from(command_id)),
                    relay_intent_id: Some(intent_id),
                })?;
                let run_id = result
                    .get("run")
                    .and_then(Value::as_dict)
                    .and_then(|run| run.get("id"))
                    .and_then(Value::py_int);
                let message = if result.get("already_active").is_some_and(Value::truthy) {
                    format!("{ticket_id} already has an active or review-pending run.")
                } else {
                    format!("Dispatching {ticket_id}.")
                };
                let updated = self.command_status(
                    command_id,
                    intent_id,
                    CommandStatus {
                        status: "authored".to_string(),
                        action: Some(kind.to_string()),
                        outcome: Some("dispatch-started".to_string()),
                        ticket_id: Some(ticket_id.to_string()),
                        status_message: Some(message.clone()),
                        ..CommandStatus::default()
                    },
                    fallback("authored"),
                )?;
                self.heartbeat_command_session(command, "awaiting_workers");
                self.notify_command_outcome(command, &message, Some(ticket_id), run_id);
                self.observe_command_continuity(command, "completed");
                return Ok(updated);
            }
            let message = format!(
                "Clarification needed before changing {ticket_id}; the backstage loop will not \
                 guess at ticket edits from raw command text."
            );
            let updated = self.command_status(
                command_id,
                intent_id,
                CommandStatus {
                    status: "blocked".to_string(),
                    action: Some(kind.to_string()),
                    outcome: Some("clarification-needed".to_string()),
                    ticket_id: Some(ticket_id.to_string()),
                    status_message: Some(message.clone()),
                    ..CommandStatus::default()
                },
                fallback("blocked"),
            )?;
            self.heartbeat_command_session(command, "blocked");
            self.notify_command_outcome(command, &message, Some(ticket_id), None);
            self.observe_command_continuity(command, "completed");
            return Ok(updated);
        }
        if [
            "conversation",
            "control",
            "inline_work",
            "direct_action",
            "inspect_ticket",
        ]
        .contains(&kind)
        {
            let updated = self.command_status(
                command_id,
                intent_id,
                CommandStatus {
                    status: "handled".to_string(),
                    action: Some(kind.to_string()),
                    outcome: Some("non-work-command".to_string()),
                    status_message: Some(
                        "No backstage ticket action is needed for this Relay command.".to_string(),
                    ),
                    ..CommandStatus::default()
                },
                fallback("handled"),
            )?;
            self.heartbeat_command_session(command, "idle");
            self.observe_command_continuity(command, "completed");
            return Ok(updated);
        }
        let message = "Clarification needed before creating or dispatching a ticket.";
        let updated = self.command_status(
            command_id,
            intent_id,
            CommandStatus {
                status: "blocked".to_string(),
                action: Some(kind.to_string()),
                outcome: Some("clarification-needed".to_string()),
                status_message: Some(message.to_string()),
                ..CommandStatus::default()
            },
            fallback("blocked"),
        )?;
        self.heartbeat_command_session(command, "blocked");
        self.notify_command_outcome(command, message, None, None);
        self.observe_command_continuity(command, "completed");
        Ok(updated)
    }

    /// `_author_ticket_for_command(command, relay_metadata)`.
    fn author_ticket_for_command(
        &self,
        command: &Dict,
        relay: &Dict,
        command_id: &str,
        intent_id: &str,
    ) -> Outcome<Dict> {
        let repo = resolve_path(&command.string("repo_path"));
        if !repo.is_dir() || !repo.join(".git").exists() {
            return Err(Failure::value(format!(
                "repo_path {} is not a git repository",
                repo.display()
            )));
        }
        if !repo.join(".orchestrator").join("config.toml").is_file() {
            return Err(Failure::value(format!(
                "repo_path {} has no .orchestrator/config.toml",
                repo.display()
            )));
        }
        let action = autonomous_ticket_action(
            &command.string("source_text"),
            &self.config_table("general"),
            &command.string("context"),
        )?;
        let result = self.apply_orchestrator_actions(&ActionBatch {
            repo_path: repo.to_string_lossy().into_owned(),
            actions: Value::List(vec![Value::Dict(action)]),
            request_id: Some(Value::from(format!("relay-command:{intent_id}"))),
            voice: VoiceFields {
                relay_command_seq: relay.get("relay_command_seq").cloned(),
                relay_command_id: Some(Value::from(relay.string("relay_command_id"))),
                relay_intent_id: Some(Value::from(intent_id)),
                relay_session_key: None,
            },
        })?;
        let ticket_id = result
            .get("tickets_written")
            .and_then(Value::as_list)
            .and_then(|written| written.first())
            .and_then(Value::as_dict)
            .and_then(|first| first.truthy("ticket_id"))
            .map(Value::py_str);
        let message = match &ticket_id {
            Some(id) => format!("Created ticket {id}."),
            None => "Created a refined ticket.".to_string(),
        };
        let updated = self.orchestrator_commands.update_status(
            command_id,
            Some(intent_id),
            &CommandStatus {
                status: "authored".to_string(),
                action: Some("create_ticket".to_string()),
                outcome: Some("ticket-created".to_string()),
                ticket_id: ticket_id.clone(),
                status_message: Some(message.clone()),
                ..CommandStatus::default()
            },
        )?;
        self.notify_command_outcome(command, &message, ticket_id.as_deref(), None);
        Ok(updated.unwrap_or_else(|| {
            let mut result = single("relay_command_id", command_id);
            result.insert("status", "authored");
            result.insert("ticket_id", ticket_id);
            result
        }))
    }

    /// `_heartbeat_command_session(command, state=...)`: best effort.
    fn heartbeat_command_session(&self, command: &Dict, state: &str) {
        let session_id = match command.get("session_id") {
            None | Some(Value::Null) => None,
            Some(value) => match value.py_int() {
                Some(id) => Some(id),
                None => return,
            },
        };
        let repo_path = truthy_text(command.get("repo_path"));
        let provider = truthy_text(command.get("provider_key"));
        let _ = self.orchestrator_sessions.heartbeat(
            session_id,
            repo_path.as_deref(),
            provider.as_deref(),
            Some(state),
        );
    }

    /// `_notify_command_outcome(command, message=, ticket_id=, run_id=)`.
    fn notify_command_outcome(
        &self,
        command: &Dict,
        message: &str,
        ticket_id: Option<&str>,
        run_id: Option<i64>,
    ) {
        let mut metadata = Dict::new();
        for (key, field) in [
            ("relay_command_seq", "relay_command_seq"),
            ("relay_command_id", "relay_command_id"),
            ("provider", "provider_key"),
        ] {
            metadata.insert(key, command.get(field).cloned().unwrap_or(Value::Null));
        }
        let event = RelayCommandMetadata::from_dict(&metadata).and_then(|command| {
            PMStatusEvent::new(
                "outcome",
                message,
                "orchestrator",
                command,
                run_id,
                ticket_id,
            )
        });
        let event = match event {
            Ok(event) => event,
            Err(error) => {
                eprintln!("[orchestrator] could not build command status event: {error}");
                return;
            }
        };
        let mut fields = single("text", event.message.as_str());
        fields.insert("status_event", event.to_dict());
        self.notify_state("working", fields);
    }

    /// `sample_continuity()`: the continuity sampler's work.
    pub fn sample_continuity(&self) -> Outcome<()> {
        self.continuity.sample(None)?;
        Ok(())
    }

    /// `get_continuity_report(report_id)`.
    fn get_continuity_report(&self, report_id: &str) -> Outcome<Dict> {
        self.continuity_reports
            .get(py_strip(report_id))?
            .ok_or_else(|| Failure::value(format!("continuity report {report_id} not found")))
    }

    /// The `accept` half of `review_continuity_proposal`.
    fn accept_continuity_proposal(
        &self,
        report_id: &str,
        proposal_id: &str,
        report: &Dict,
        target_repo_path: Option<&Value>,
        voice: &VoiceFields,
    ) -> Outcome<Dict> {
        let has_seq = voice
            .relay_command_seq
            .as_ref()
            .is_some_and(|seq| !matches!(seq, Value::Null));
        let has_id = voice.relay_command_id.as_ref().is_some_and(Value::truthy);
        let has_relay_authorization = has_seq || has_id;
        if has_relay_authorization && !(has_seq && has_id) {
            return Err(Failure::value(
                "continuity proposal acceptance requires complete Relay authorization metadata",
            ));
        }
        let target_text = truthy_text(target_repo_path).unwrap_or_default();
        if py_strip(&target_text).is_empty() {
            return Err(Failure::value(
                "target_repo_path is required for acceptance",
            ));
        }
        let target = resolve_path(&target_text);
        let registered: Vec<PathBuf> =
            registered_project_repo_paths(self.paths.registered_projects())
                .iter()
                .map(|path| resolve_path(path))
                .collect();
        if !registered.contains(&target) {
            return Err(Failure::value(
                "continuity proposal acceptance requires one registered target project",
            ));
        }
        if !target.join(".orchestrator").join("config.toml").is_file() {
            return Err(Failure::value(format!(
                "target project {} has no canonical board config",
                target.display()
            )));
        }
        let Some(draft) = self
            .continuity_reports
            .claim_acceptance(report_id, proposal_id)?
        else {
            let mut result = single("report", self.get_continuity_report(report_id)?);
            result.insert("duplicate", true);
            return Ok(result);
        };
        let key =
            relay_intents::sha256::hex_digest(format!("{report_id}\0{proposal_id}").as_bytes());
        let marker = format!("relay-continuity-followup-key: {key}");
        let committed = |ticket_id: &str| {
            let mut entry = single("proposal_id", proposal_id);
            entry.insert("ticket_id", ticket_id);
            Value::List(vec![Value::Dict(entry)])
        };
        let attempt = || -> Outcome<(String, bool)> {
            for ticket in scan_tickets(&target)? {
                if ticket.body.contains(&marker) {
                    return Ok((ticket.id, true));
                }
            }
            let Value::Dict(draft) = &draft else {
                return Err(Failure::escape("continuity draft is not an object"));
            };
            let incident_id = report
                .get("incident")
                .and_then(Value::as_dict)
                .and_then(|incident| incident.get("incident_id"))
                .ok_or_else(|| Failure::escape("'incident_id'"))?
                .py_str();
            let description = draft
                .get("description")
                .ok_or_else(|| Failure::escape("'description'"))?
                .py_str();
            let mut action = single("kind", "create_ticket");
            action.update(draft);
            action.insert(
                "description",
                format!(
                    "{description}\n\n## Provenance\n\n- Continuity report: `{report_id}`\n\
                     - Incident: `{incident_id}`\n\n<!-- {marker} -->"
                ),
            );
            let result = self.apply_orchestrator_actions(&ActionBatch {
                repo_path: target.to_string_lossy().into_owned(),
                actions: Value::List(vec![Value::Dict(action)]),
                request_id: Some(Value::from(format!("continuity-proposal:{key}"))),
                voice: voice.clone(),
            })?;
            let ticket_id = result
                .get("tickets_written")
                .and_then(Value::as_list)
                .and_then(|written| written.first())
                .and_then(Value::as_dict)
                .and_then(|first| first.get("ticket_id"))
                .ok_or_else(|| Failure::escape("list index out of range"))?
                .py_str();
            let ticket = relay_artifacts::tickets::read(
                &target.join(".orchestrator").join(format!("{ticket_id}.md")),
            )?;
            let dispatched = result.get("dispatches").is_some_and(Value::truthy);
            if ticket.status != "backlog" || dispatched {
                return Err(Failure::runtime(
                    "continuity proposal did not remain backlog-only",
                ));
            }
            Ok((ticket_id, false))
        };
        match attempt() {
            Ok((ticket_id, duplicate)) => {
                let accepted = self.continuity_reports.finish_acceptance(
                    report_id,
                    proposal_id,
                    Some(&ticket_id),
                    None,
                )?;
                let mut result = single("report", accepted);
                result.insert("committed", committed(&ticket_id));
                if duplicate {
                    result.insert("duplicate", true);
                } else {
                    result.insert(
                        "authorization_source",
                        if has_relay_authorization {
                            "authorized_user_command"
                        } else {
                            "foreground_pm"
                        },
                    );
                }
                Ok(result)
            }
            Err(error) => {
                let failed = self.continuity_reports.finish_acceptance(
                    report_id,
                    proposal_id,
                    None,
                    Some(&error.message),
                )?;
                let mut not_committed = single("proposal_id", proposal_id);
                not_committed.insert("error", error.message);
                let mut result = single("report", failed);
                result.insert("partial", true);
                result.insert("committed", Value::List(Vec::new()));
                result.insert(
                    "not_committed",
                    Value::List(vec![Value::Dict(not_committed)]),
                );
                Ok(result)
            }
        }
    }
}

/// `ContinuityLifecycleAdapter(emit=self._emit_continuity_incident)`: each
/// incident envelope is appended to `continuity_incidents.jsonl`, owner-only.
pub fn continuity_adapter(data_root: &Path) -> ContinuityLifecycleAdapter {
    let path = data_root.join("continuity_incidents.jsonl");
    ContinuityLifecycleAdapter::new(Some(Box::new(move |envelope: &Dict| {
        if let Err(error) = append_incident(&path, envelope) {
            eprintln!("[orchestrator] could not record continuity incident: {error}");
        }
    })))
}

/// `_emit_continuity_incident`'s file write.
fn append_incident(path: &Path, envelope: &Dict) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut handle = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let line = json::dumps_compact_sorted(&Value::Dict(envelope.clone())) + "\n";
    handle.write_all(line.as_bytes())?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_ids_bind_as_sqlite_compares_them() {
        assert_eq!(session_id_param(None), None);
        assert_eq!(session_id_param(Some(&Value::Null)), None);
        assert_eq!(session_id_param(Some(&Value::Int(3))), Some(3));
        assert_eq!(session_id_param(Some(&Value::from(" 4 "))), Some(4));
        assert_eq!(session_id_param(Some(&Value::from("abc"))), Some(NO_ROW));
        assert_eq!(session_id_param(Some(&Value::Float(2.5))), Some(NO_ROW));
    }

    #[test]
    fn incidents_append_sorted_compact_lines_owner_only() {
        let directory = std::env::temp_dir().join(format!(
            "rr497-incidents-{}-{}",
            std::process::id(),
            relay_store::sql::now()
        ));
        let path = directory.join("continuity_incidents.jsonl");
        let mut envelope = Dict::new();
        envelope.insert("z", 1);
        envelope.insert("a", "b");
        append_incident(&path, &envelope).unwrap();
        append_incident(&path, &envelope).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text, "{\"a\":\"b\",\"z\":1}\n{\"a\":\"b\",\"z\":1}\n");
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn classifications_answer_in_the_route_shape() {
        let adapter = ContinuityLifecycleAdapter::new(None);
        let mut event = Dict::new();
        event.insert("source", "bridge");
        event.insert("event", "command_received");
        event.insert("session_id", "app-session-1");
        let result = classification_dict(&adapter.observe(&event).unwrap());
        let keys: Vec<&str> = result.iter().map(|(key, _)| key).collect();
        assert_eq!(
            keys,
            ["state", "fingerprint", "suppression_reason", "incident"]
        );
        event.insert("event", "teleported");
        assert_eq!(
            adapter.observe(&event).unwrap_err().message,
            "unsupported continuity lifecycle event"
        );
    }
}
