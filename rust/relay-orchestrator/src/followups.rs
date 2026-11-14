//! Spike follow-up proposals: `propose_spike_followups`,
//! `review_spike_followup`, `_completed_spike`, `_followup_target_repo` and
//! `_accept_spike_followup`, which authors one legacy-board `backlog` ticket
//! and commits it with the ticket counter.

use std::path::{Path, PathBuf};

use relay_artifacts::followup::{
    FOLLOWUP_KEY_PREFIX, automatic_followup_drafts, sanitize_followup_draft,
};
use relay_artifacts::tickets::{self, Fields, Ticket};
use relay_intents::json::{Dict, Value, py_is_space, py_strip};
use relay_store::followups::acceptance_key;

use crate::actions::{
    body_section, clean_optional_text, commit_ticket_authorship,
    ensure_ticket_authoring_paths_clean, git, scan_tickets, structured_ticket_body, ticket_config,
    write_ticket_config_next_id,
};
use crate::daemon::{Daemon, guard, registered_project_repo_paths, resolve_path};
use crate::failure::{Class, Failure, Outcome};
use crate::relay_command::{VoiceFields, mutation_metadata, validate_relay_command};
use crate::request::{Request, parse_int};
use crate::router::{Reply, reply, single};

/// `int(body.get("origin_run_id") or 0)`.
fn origin_run_id(value: Option<&Value>) -> Outcome<i64> {
    match value.filter(|value| value.truthy()) {
        None => Ok(0),
        Some(Value::Str(text)) => parse_int(text),
        Some(value) => value.py_int().ok_or_else(|| {
            Failure::escape("int() argument must be a string, a bytes-like object or a real number")
        }),
    }
}

/// `_git_text(repo, *args)`: stdout, or the error text on failure.
fn git_text(repo: &Path, arguments: &[&str]) -> Outcome<String> {
    let result = git(repo, arguments)?;
    let text = py_strip(&result.stdout).to_string();
    if result.status == 0 {
        return Ok(text);
    }
    let error = py_strip(&result.stderr).to_string();
    Ok(if !error.is_empty() {
        error
    } else if !text.is_empty() {
        text
    } else {
        format!(
            "git {} failed with exit {}",
            arguments.join(" "),
            result.status
        )
    })
}

/// Whether Python's `except (ValueError, RuntimeError)` catches a failure.
fn value_or_runtime(failure: &Failure) -> bool {
    !matches!(failure.class, Class::Io | Class::Escape)
}

/// A dict field as a list of strings.
fn strings(draft: &Dict, key: &str) -> Vec<String> {
    draft
        .get(key)
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .map(Value::py_str)
        .collect()
}

impl Daemon {
    pub fn propose_spike_followups_route(&self, request: &Request) -> Outcome<Reply> {
        let proposals = request
            .get("proposals")
            .filter(|value| !matches!(value, Value::Null));
        if proposals.is_some_and(|value| value.as_list().is_none()) {
            return Err(Failure::value("proposals must be a list"));
        }
        let run_id = origin_run_id(request.get("origin_run_id"))?;
        let origin_ticket_id = request.text("origin_ticket_id");
        let (origin_repo, spike) =
            self.completed_spike(&request.text("origin_repo_path"), &origin_ticket_id, run_id)?;
        let origin_text = origin_repo.to_string_lossy().into_owned();
        let raw_drafts: Vec<Value> = match proposals.and_then(Value::as_list) {
            Some(items) => items.to_vec(),
            None => automatic_followup_drafts(&spike.body, &origin_text)?
                .into_iter()
                .map(Value::Dict)
                .collect(),
        };
        if raw_drafts.is_empty() {
            return Err(Failure::value(
                "the completed spike has no actionable recommended next steps; provide refined proposals",
            ));
        }
        let mut drafts = Vec::new();
        for raw in &raw_drafts {
            let draft = sanitize_followup_draft(raw, &origin_text)?;
            self.followup_target_repo(&origin_repo, &draft.string("target_repo_path"))?;
            drafts.push(draft);
        }
        let provider = clean_optional_text(request.get("provider"));
        let (batch, created) = self.followup_proposals.create_or_get(
            &origin_text,
            &origin_ticket_id.to_uppercase(),
            run_id,
            provider.as_deref(),
            &drafts,
        )?;
        let mut result = single("batch", batch);
        result.insert("created", created);
        result.insert("duplicate", !created);
        reply(if created { 201 } else { 200 }, result)
    }

    pub fn review_spike_followup_route(&self, request: &Request) -> Outcome<Reply> {
        let _authoring = guard(&self.authoring_lock);
        reply(
            200,
            self.review_spike_followup(
                &request.segments[3],
                &request.segments[5],
                &request.text("decision"),
                request
                    .get("updates")
                    .filter(|value| !matches!(value, Value::Null)),
                &VoiceFields::from_body(&request.body),
            )?,
        )
    }
}

impl Daemon {
    /// `_completed_spike(repo_path, ticket_id, run_id)`: the originating
    /// repository and its done spike ticket with a durable report.
    fn completed_spike(
        &self,
        repo_path: &str,
        ticket_id: &str,
        run_id: i64,
    ) -> Outcome<(PathBuf, Ticket)> {
        let repo = resolve_path(repo_path);
        if !repo.is_dir() || !repo.join(".git").exists() {
            return Err(Failure::value(format!(
                "origin_repo_path {} is not a git repository",
                repo.display()
            )));
        }
        let id = ticket_id.to_uppercase();
        let ticket_path = repo.join(".orchestrator").join(format!("{id}.md"));
        if !ticket_path.is_file() {
            return Err(Failure::value(format!("originating spike {id} not found")));
        }
        let ticket = tickets::read(&ticket_path)?;
        if ticket.execution_mode != "spike" {
            return Err(Failure::value(format!(
                "originating ticket {id} is not a spike"
            )));
        }
        if ticket.status != "done" {
            return Err(Failure::value(format!(
                "originating spike {id} is not complete"
            )));
        }
        if ticket.run_id != Some(run_id) {
            return Err(Failure::value(format!(
                "originating spike run changed: expected {run_id}, found {}",
                ticket
                    .run_id
                    .map_or_else(|| "None".to_string(), |id| id.to_string())
            )));
        }
        if body_section(&ticket.body, "Spike report").is_empty() {
            return Err(Failure::value(format!(
                "originating spike {id} has no durable Spike report"
            )));
        }
        Ok((repo, ticket))
    }

    /// `_followup_target_repo(origin_repo, value)`.
    fn followup_target_repo(&self, origin_repo: &Path, value: &str) -> Outcome<PathBuf> {
        let target = resolve_path(value);
        let registered = registered_project_repo_paths(self.paths.registered_projects())
            .iter()
            .any(|path| resolve_path(path) == target);
        if target != origin_repo && !registered {
            return Err(Failure::value(
                "ambiguous project ownership: select one registered target project before accepting",
            ));
        }
        if !target.is_dir() || !target.join(".git").exists() {
            return Err(Failure::value(format!(
                "target project {} is not a git repository",
                target.display()
            )));
        }
        if !target.join(".orchestrator").join("config.toml").is_file() {
            return Err(Failure::value(format!(
                "target project {} has no canonical board config",
                target.display()
            )));
        }
        Ok(target)
    }

    /// `_review_spike_followup_locked(...)`; the caller holds the authoring
    /// lock.
    fn review_spike_followup(
        &self,
        batch_id: &str,
        proposal_id: &str,
        decision: &str,
        updates: Option<&Value>,
        voice: &VoiceFields,
    ) -> Outcome<Dict> {
        let mut batch = self
            .followup_proposals
            .get(batch_id)?
            .ok_or_else(|| Failure::value(format!("follow-up batch {batch_id} not found")))?;
        let proposal = batch
            .get("proposals")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .find(|item| item.string("id") == proposal_id)
            .cloned()
            .ok_or_else(|| Failure::value(format!("follow-up proposal {proposal_id} not found")))?;
        if proposal.string("state") != "draft" {
            let mut result = single("batch", batch);
            result.insert("duplicate", true);
            return Ok(result);
        }
        let decision = py_strip(decision).to_lowercase();
        if !["edit", "accept", "reject"].contains(&decision.as_str()) {
            return Err(Failure::value(
                "decision must be 'edit', 'accept', or 'reject'",
            ));
        }
        let mut authorization_source = None;
        if decision == "accept" {
            let has_seq = voice
                .relay_command_seq
                .as_ref()
                .is_some_and(|seq| !matches!(seq, Value::Null));
            let has_id = voice.relay_command_id.as_ref().is_some_and(Value::truthy);
            if (has_seq || has_id) && !(has_seq && has_id) {
                return Err(Failure::value(
                    "spike follow-up acceptance requires complete Relay authorization metadata",
                ));
            }
            authorization_source = Some(if has_seq || has_id {
                "authorized_user_command"
            } else {
                "foreground_pm"
            });
            let request_id = Value::from(format!("{batch_id}:{proposal_id}"));
            validate_relay_command(
                &self.paths,
                voice,
                Some(&mutation_metadata(
                    "spike_followup_accept",
                    None,
                    None,
                    None,
                    Some(&request_id),
                )),
            )?;
        }
        let origin_repo_path = batch.string("origin_repo_path");
        let origin_ticket_id = batch.string("origin_ticket_id");
        let origin_run = batch
            .get("origin_run_id")
            .and_then(Value::py_int)
            .unwrap_or_default();
        let (origin_repo, _) =
            self.completed_spike(&origin_repo_path, &origin_ticket_id, origin_run)?;
        let mut draft = proposal
            .get("draft")
            .and_then(Value::as_dict)
            .cloned()
            .unwrap_or_default();
        match updates {
            Some(Value::Dict(updates)) => {
                let mut merged = draft.clone();
                merged.update(updates);
                draft =
                    sanitize_followup_draft(&Value::Dict(merged), &origin_repo.to_string_lossy())?;
                self.followup_target_repo(&origin_repo, &draft.string("target_repo_path"))?;
                batch = self
                    .followup_proposals
                    .update_draft(batch_id, proposal_id, &draft)?;
            }
            Some(_) => return Err(Failure::value("updates must be an object")),
            None => {}
        }
        if decision == "edit" {
            if updates.is_none() {
                return Err(Failure::value("edit requires updates"));
            }
            let mut result = single("batch", batch);
            result.insert("edited", proposal_id);
            return Ok(result);
        }
        if decision == "reject" {
            let rejected = self.followup_proposals.set_result(
                batch_id,
                proposal_id,
                "rejected",
                None,
                None,
            )?;
            let mut result = single("batch", rejected);
            result.insert("rejected", proposal_id);
            return Ok(result);
        }
        match self.accept_spike_followup(&batch, proposal_id, &draft) {
            Ok((ticket_id, duplicate)) => {
                let accepted = self.followup_proposals.set_result(
                    batch_id,
                    proposal_id,
                    "accepted",
                    Some(&ticket_id),
                    None,
                )?;
                let mut committed = single("proposal_id", proposal_id);
                committed.insert("ticket_id", ticket_id);
                let mut result = single("batch", accepted);
                result.insert("committed", Value::List(vec![Value::Dict(committed)]));
                result.insert("not_committed", Value::List(Vec::new()));
                result.insert("duplicate", duplicate);
                result.insert("authorization_source", authorization_source);
                Ok(result)
            }
            Err(error) if value_or_runtime(&error) => {
                let failed =
                    self.followup_proposals
                        .set_error(batch_id, proposal_id, &error.message)?;
                let mut not_committed = single("proposal_id", proposal_id);
                not_committed.insert("error", error.message);
                let mut result = single("batch", failed);
                result.insert("partial", true);
                result.insert("committed", Value::List(Vec::new()));
                result.insert(
                    "not_committed",
                    Value::List(vec![Value::Dict(not_committed)]),
                );
                result.insert("authorization_source", authorization_source);
                Ok(result)
            }
            Err(error) => Err(error),
        }
    }

    /// `_accept_spike_followup(batch=, proposal_id=, draft=)`: the ticket id
    /// and whether it was already on the target board.
    fn accept_spike_followup(
        &self,
        batch: &Dict,
        proposal_id: &str,
        draft: &Dict,
    ) -> Outcome<(String, bool)> {
        let origin_ticket_id = batch.string("origin_ticket_id");
        let origin_run_id = batch
            .get("origin_run_id")
            .and_then(Value::py_int)
            .unwrap_or_default();
        let (origin_repo, _) = self.completed_spike(
            &batch.string("origin_repo_path"),
            &origin_ticket_id,
            origin_run_id,
        )?;
        let target = self.followup_target_repo(&origin_repo, &draft.string("target_repo_path"))?;
        let key = acceptance_key(&batch.string("id"), proposal_id);
        let marker = format!("{FOLLOWUP_KEY_PREFIX} {key}");
        for ticket in scan_tickets(&target)? {
            if ticket.body.contains(&marker) {
                return Ok((ticket.id, true));
            }
        }
        let orch_dir = target.join(".orchestrator");
        let depends_on = strings(draft, "depends_on");
        for dependency in &depends_on {
            if !orch_dir.join(format!("{dependency}.md")).is_file() {
                return Err(Failure::value(format!(
                    "dependency {dependency} is not present on target board {}",
                    target.display()
                )));
            }
        }
        if git_text(&target, &["branch", "--show-current"])?.is_empty() {
            return Err(Failure::value(
                "target project must be on a named canonical branch",
            ));
        }
        let target_head = git_text(&target, &["rev-parse", "HEAD"])?;
        if target == origin_repo {
            let origin_ticket_path = origin_repo
                .join(".orchestrator")
                .join(format!("{origin_ticket_id}.md"));
            let origin_commit = git_text(
                &origin_repo,
                &[
                    "log",
                    "-1",
                    "--format=%H",
                    "--",
                    &origin_ticket_path.to_string_lossy(),
                ],
            )?;
            let ancestry = git(
                &target,
                &["merge-base", "--is-ancestor", &origin_commit, &target_head],
            )?;
            if origin_commit.is_empty() || ancestry.status != 0 {
                return Err(Failure::value(
                    "originating spike result is not an ancestor of the target board branch",
                ));
            }
        }
        let config_path = orch_dir.join("config.toml");
        let (prefix, next_id, config_text) = ticket_config(&config_path)?;
        let mut number = next_id;
        while orch_dir.join(format!("{prefix}-{number}.md")).exists() {
            number += 1;
        }
        let ticket_id = format!("{prefix}-{number}");
        let ticket_path = orch_dir.join(format!("{ticket_id}.md"));
        ensure_ticket_authoring_paths_clean(&target, &[config_path.clone(), ticket_path.clone()])?;
        let staged = git(&target, &["diff", "--cached", "--name-only"])?;
        if staged.status != 0 || !py_strip(&staged.stdout).is_empty() {
            return Err(Failure::value(
                "follow-up authoring blocked by already-staged changes",
            ));
        }
        if git_text(&target, &["rev-parse", "HEAD"])? != target_head {
            return Err(Failure::value(
                "target branch changed while preparing the follow-up ticket",
            ));
        }
        let provenance = format!(
            "## Provenance\n\n- Originating spike: `{origin_ticket_id}`\n- Spike run: \
             {origin_run_id}\n\n<!-- {marker} -->"
        );
        let body = structured_ticket_body(
            &draft.string("description"),
            &strings(draft, "acceptance_criteria"),
        );
        let mut raw_fields = Fields::default();
        for field in crate::actions::WORKER_SIZING_FIELDS {
            raw_fields.insert(field, &draft.string(field));
        }
        let ticket = Ticket {
            id: ticket_id.clone(),
            title: draft.string("title"),
            status: "backlog".to_string(),
            priority: draft.string("priority"),
            execution_mode: "implementation".to_string(),
            depends_on,
            run_id: None,
            canceled: false,
            draft: false,
            verification_blocker: None,
            verification_resume: None,
            verification_origin: None,
            order: number,
            body: format!("{}\n\n{provenance}\n", body.trim_end_matches(py_is_space)),
            raw_fields,
        };
        let written = (|| -> Outcome<()> {
            write_ticket_config_next_id(&config_path, &config_text, number + 1)?;
            tickets::write(&ticket_path, &ticket)?;
            commit_ticket_authorship(
                &target,
                &[config_path.clone(), ticket_path.clone()],
                std::slice::from_ref(&ticket_id),
                Some(&format!(
                    "chore: author {ticket_id} from {origin_ticket_id} spike"
                )),
            )
        })();
        if let Err(error) = written {
            git(
                &target,
                &[
                    "restore",
                    "--staged",
                    "--",
                    ".orchestrator/config.toml",
                    &format!(".orchestrator/{ticket_id}.md"),
                ],
            )?;
            std::fs::write(&config_path, &config_text)?;
            if ticket_path.exists() {
                std::fs::remove_file(&ticket_path)?;
            }
            return Err(Failure::runtime(format!(
                "follow-up ticket commit failed: {error}"
            )));
        }
        self.notify_orchestration_trace("ticket-created", Some(&ticket_id), None, None, None);
        Ok((ticket_id, false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin_run_ids_read_as_python_int() {
        assert_eq!(origin_run_id(None).unwrap(), 0);
        assert_eq!(origin_run_id(Some(&Value::from(""))).unwrap(), 0);
        assert_eq!(origin_run_id(Some(&Value::from(" 7 "))).unwrap(), 7);
        assert_eq!(origin_run_id(Some(&Value::Int(9))).unwrap(), 9);
        assert_eq!(
            origin_run_id(Some(&Value::from("x"))).unwrap_err().message,
            "invalid literal for int() with base 10: 'x'"
        );
        assert_eq!(
            origin_run_id(Some(&Value::List(vec![Value::Int(1)])))
                .unwrap_err()
                .class,
            Class::Escape
        );
    }

    #[test]
    fn only_io_and_escaping_failures_skip_the_partial_answer() {
        assert!(value_or_runtime(&Failure::value("x")));
        assert!(value_or_runtime(&Failure::runtime("x")));
        assert!(!value_or_runtime(&Failure::new(Class::Io, "x")));
        assert!(!value_or_runtime(&Failure::escape("x")));
    }
}
