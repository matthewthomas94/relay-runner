//! The notes routes (`artifact_note_*`): the global notes library when
//! `repo_path` is empty, or an artifact project's notes after its scope token
//! is confirmed. Each saved change schedules the metadata worker
//! (`_schedule_note_metadata`) once it is durable.

use std::sync::Arc;

use relay_intents::json::{Dict, Value};
use relay_services::notes::project::ProjectNoteManager;
use relay_services::notes::{CreateNote, NoteManager, checked_update, retry_metadata};

use crate::daemon::{Daemon, reopen_store};
use crate::failure::Outcome;
use crate::request::Request;
use crate::router::{Reply, reply};

/// `result["note"]["identity"]["artifact_id"]`.
fn note_artifact_id(result: &Dict) -> Option<String> {
    result
        .get("note")
        .and_then(Value::as_dict)
        .and_then(|note| note.get("identity"))
        .and_then(Value::as_dict)
        .and_then(|identity| identity.get("artifact_id"))
        .map(Value::py_str)
}

/// `body.get(key)` as the optional string a manager argument takes.
fn optional(request: &Request, key: &str) -> Option<String> {
    request.optional_text(key)
}

impl Daemon {
    /// `_artifact_note_manager(repo_path, project_scope_token)`.
    pub fn artifact_note_manager(
        &self,
        repo_path: &str,
        project_scope_token: Option<&str>,
    ) -> Outcome<Arc<dyn NoteManager>> {
        if repo_path.is_empty() {
            return Ok(self.global_notes.manager()?);
        }
        let lifecycle = self.artifact_board_lifecycle(repo_path, project_scope_token)?;
        Ok(Arc::new(ProjectNoteManager::new(
            Arc::new(reopen_store(&lifecycle.store)?),
            &self.device_id,
        )))
    }

    /// `_schedule_note_metadata(manager, result)`: metadata failures never
    /// turn a successful save into a failure.
    fn schedule_note_metadata(&self, manager: &Arc<dyn NoteManager>, result: &Dict) {
        if let (Some(queue), Some(artifact_id)) = (&self.note_metadata, note_artifact_id(result)) {
            queue.schedule(manager.clone(), &artifact_id);
        }
    }

    /// The manager named by a POST body's `repo_path` and scope token.
    fn body_note_manager(&self, request: &Request) -> Outcome<Arc<dyn NoteManager>> {
        let repo_path = request.text("repo_path");
        let token = optional(request, "project_scope_token");
        self.artifact_note_manager(&repo_path, token.as_deref())
    }

    pub fn artifact_note_list(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = request.query_first("project_scope_token");
        let limit = request.query_int("limit", 50)?;
        let after = request.query_first("after");
        if repo_path.is_empty() {
            let result = self.global_notes.list(limit, after.as_deref())?;
            if let Some(queue) = &self.note_metadata {
                let cards = result
                    .get("notes")
                    .and_then(Value::as_list)
                    .unwrap_or_default();
                for card in cards.iter().filter_map(Value::as_dict) {
                    let pending = card
                        .get("metadata")
                        .and_then(Value::as_dict)
                        .and_then(|metadata| metadata.get("state"))
                        .is_some_and(|state| state.is_str("pending"));
                    let global = card
                        .get("project_id")
                        .is_some_and(|project| project.is_str("global-notes"));
                    if global && pending {
                        let manager = self.global_notes.manager()?;
                        let artifact_id = card
                            .get("artifact_id")
                            .map(Value::py_str)
                            .unwrap_or_default();
                        queue.schedule(manager, &artifact_id);
                    }
                }
            }
            return reply(200, result);
        }
        let Some(lifecycle) = self.artifact_lifecycle(&repo_path)? else {
            // A legacy project has no note catalog; an empty page is normal.
            let mut sync = Dict::new();
            sync.insert("mode", "disabled");
            sync.insert("state", "unavailable");
            sync.insert("recovery", Value::Null);
            let mut body = Dict::new();
            body.insert("notes", Value::List(Vec::new()));
            body.insert("artifact_commit", "");
            body.insert("limit", limit);
            body.insert("has_more", false);
            body.insert("next_cursor", Value::Null);
            body.insert("total_count", 0_i64);
            body.insert("sync", sync);
            return reply(200, body);
        };
        lifecycle.validate_scope(token.as_deref(), None)?;
        let manager =
            ProjectNoteManager::new(Arc::new(reopen_store(&lifecycle.store)?), &self.device_id);
        reply(200, manager.list(limit, after.as_deref())?)
    }

    pub fn artifact_note_get(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_or("repo_path", "");
        let token = request.query_first("project_scope_token");
        let identity = request.unquoted(3);
        let manager = self.artifact_note_manager(&repo_path, token.as_deref())?;
        reply(200, manager.get(&identity)?)
    }

    pub fn artifact_note_create(&self, request: &Request) -> Outcome<Reply> {
        let manager = self.body_note_manager(request)?;
        let create = CreateNote {
            request_id: request.text("request_id"),
            created_at: request.text("created_at"),
            capture_started_at: request.text("capture_started_at"),
            captured_at: request.text("captured_at"),
            recording_state: request.text("recording_state"),
            checkpoint_reason: request.text("checkpoint_reason"),
            segments: request
                .get("segments")
                .cloned()
                .unwrap_or_else(|| Value::List(Vec::new())),
            capture_ended_at: optional(request, "capture_ended_at"),
            provider: optional(request, "provider"),
        };
        let result = manager.create(&create)?;
        self.schedule_note_metadata(&manager, &result);
        reply(201, result)
    }

    pub fn artifact_note_update(&self, request: &Request) -> Outcome<Reply> {
        let note_id = request.unquoted(3);
        let update = request.get("update").cloned().unwrap_or(Value::Null);
        let update = checked_update(&note_id, &update)?;
        let manager = self.body_note_manager(request)?;
        let provider = optional(request, "provider");
        let result = manager.update(&request.text("request_id"), update, provider.as_deref())?;
        self.schedule_note_metadata(&manager, &result);
        reply(200, result)
    }

    pub fn artifact_note_metadata_retry(&self, request: &Request) -> Outcome<Reply> {
        let note_id = request.unquoted(3);
        let manager = self.body_note_manager(request)?;
        retry_metadata(manager.as_ref(), &note_id)?;
        let result = manager.get(&note_id)?;
        self.schedule_note_metadata(&manager, &result);
        reply(200, result)
    }

    pub fn artifact_note_archive(&self, request: &Request) -> Outcome<Reply> {
        let note_id = request.unquoted(3);
        let manager = self.body_note_manager(request)?;
        let provider = optional(request, "provider");
        reply(
            200,
            manager.archive(
                &note_id,
                &request.text("artifact_id"),
                &request.text("archived_at"),
                &request.text("request_id"),
                provider.as_deref(),
            )?,
        )
    }

    pub fn artifact_note_delete(&self, request: &Request) -> Outcome<Reply> {
        let note_id = request.unquoted(3);
        let cancel_recording = request.segments[4] == "cancel";
        let manager = self.body_note_manager(request)?;
        reply(
            200,
            manager.delete(
                &note_id,
                &request.text("artifact_id"),
                &request.text("request_id"),
                cancel_recording,
            )?,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_scheduled_artifact_is_the_note_identity() {
        let mut identity = Dict::new();
        identity.insert("artifact_id", "note-1");
        let mut note = Dict::new();
        note.insert("identity", identity);
        let mut result = Dict::new();
        result.insert("note", note);
        assert_eq!(note_artifact_id(&result).as_deref(), Some("note-1"));
        assert_eq!(note_artifact_id(&Dict::new()), None);
    }
}
