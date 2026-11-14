//! Relay notes (RR-499): the Rust form of `services/note_contract.py`,
//! `project_notes.py`, `personal_notes.py`, `global_notes.py` and
//! `note_metadata.py`.
//!
//! Notes are Markdown artifacts. A project's notes, and the global library
//! until it moves into personal storage, are commits on the project's
//! `refs/heads/relay/artifacts` made through `relay_artifacts::store`, so a
//! Rust and a Python daemon write the same commits. After migration the
//! global library lives in the personal-file cache
//! ([`crate::personal_storage`]) with the same note identities and request
//! receipts.
//!
//! Responses are the Python managers' dictionaries, in their key order, for
//! the HTTP layer to serialise. Errors carry the Python class name the routes
//! map to a status: `NoteContractError` and `ValueError` are 400,
//! `ArtifactValidationError` is 422.

pub mod contract;
pub mod global;
pub mod metadata;
pub mod personal;
pub mod project;
pub mod util;

use relay_intents::json::{Dict, Value};

use crate::{Error, Result};
use contract::{NoteIdentity, NoteUpdate, note_source};

/// The arguments of `create(...)`, as the create route passes them.
#[derive(Clone, Debug)]
pub struct CreateNote {
    pub request_id: String,
    pub created_at: String,
    pub capture_started_at: String,
    pub captured_at: String,
    pub recording_state: String,
    pub checkpoint_reason: String,
    /// The raw `segments` value; anything but an array is refused.
    pub segments: Value,
    pub capture_ended_at: Option<String>,
    pub provider: Option<String>,
}

impl CreateNote {
    /// The request payload whose digest makes a repeated create idempotent.
    pub(crate) fn payload(&self, raw_segments: &[Dict]) -> Dict {
        let mut payload = Dict::new();
        payload.insert("created_at", self.created_at.as_str());
        payload.insert("capture_started_at", self.capture_started_at.as_str());
        payload.insert("captured_at", self.captured_at.as_str());
        payload.insert("recording_state", self.recording_state.as_str());
        payload.insert("checkpoint_reason", self.checkpoint_reason.as_str());
        payload.insert(
            "segments",
            Value::List(raw_segments.iter().cloned().map(Value::Dict).collect()),
        );
        payload.insert("capture_ended_at", self.capture_ended_at.clone());
        payload
    }
}

/// What both note managers offer: `ProjectNoteManager` on an artifact ref,
/// `PersonalNoteManager` on the personal-file cache.
pub trait NoteManager: Send + Sync {
    /// `manager.store.project_id`.
    fn project_id(&self) -> String;
    /// `manager.store._head()`.
    fn head(&self) -> Result<Option<String>>;
    fn ensure_global_codes(&self) -> Result<()>;
    fn import_saved_note(&self, source: &Dict, repository_path: Option<&str>) -> Result<()>;
    fn create(&self, request: &CreateNote) -> Result<Dict>;
    fn update(&self, request_id: &str, update: &Dict, provider: Option<&str>) -> Result<Dict>;
    fn publish_metadata(
        &self,
        identity: &NoteIdentity,
        source_sha256: &str,
        metadata: &Dict,
        expected_metadata: Option<&Dict>,
    ) -> Result<bool>;
    fn delete(
        &self,
        note_id: &str,
        artifact_id: &str,
        request_id: &str,
        cancel_recording: bool,
    ) -> Result<Dict>;
    fn archive(
        &self,
        note_id: &str,
        artifact_id: &str,
        archived_at: &str,
        request_id: &str,
        provider: Option<&str>,
    ) -> Result<Dict>;
    fn get(&self, identity: &str) -> Result<Dict>;
    fn list(&self, limit: i64, after: Option<&str>) -> Result<Dict>;
}

/// The checks of `artifact_note_update` in `services/orchestrator.py`
/// before an update reaches its manager.
pub fn checked_update<'u>(note_id: &str, update: &'u Value) -> Result<&'u Dict> {
    let Some(update) = update.as_dict() else {
        return Err(Error::value("note update must be an object"));
    };
    let matches = update
        .get("identity")
        .and_then(Value::as_dict)
        .and_then(|identity| identity.get("note_id"))
        .is_some_and(|id| id.is_str(note_id));
    if !matches {
        return Err(Error::value(
            "note update path does not match its immutable identity",
        ));
    }
    Ok(update)
}

/// `artifact_note_metadata_retry` in `services/orchestrator.py`: reset a
/// note's generated metadata to pending (or empty) from its current source.
/// The caller schedules generation and returns `manager.get(note_id)`.
pub fn retry_metadata(manager: &dyn NoteManager, note_id: &str) -> Result<()> {
    let result = manager.get(note_id)?;
    if !result
        .get("materialized")
        .is_some_and(|materialized| materialized.truthy())
    {
        return Err(Error::value("Archived notes cannot generate metadata"));
    }
    let note = result
        .get("note")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default();
    let update = NoteUpdate::from_mapping(&note)?;
    let (text, digest) = note_source(&update);
    let previous = note.get("metadata").and_then(Value::as_dict).cloned();
    if previous
        .as_ref()
        .and_then(|previous| previous.get("origin"))
        .is_some_and(|origin| origin.is_str("manual"))
    {
        return Err(Error::value("User-authored note metadata is preserved"));
    }
    let mut desired = previous.clone().unwrap_or_default();
    desired.insert("origin", "generated");
    desired.insert("state", if text.is_empty() { "empty" } else { "pending" });
    desired.insert("source_sha256", digest.as_str());
    desired.insert("error_code", Value::Null);
    manager.publish_metadata(&update.identity, &digest, &desired, previous.as_ref())?;
    Ok(())
}
