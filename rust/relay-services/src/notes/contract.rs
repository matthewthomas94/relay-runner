//! The note document and checkpoint contract of `services/note_contract.py`
//! that the note managers use, on top of `relay_artifacts::notes` (the part
//! the artifact store already needs): updates that carry their identity,
//! documents, rendering, the provider source digest and the metadata a
//! checkpoint keeps, and the note index encoder.
//!
//! Validation, the predicates, metadata checks and parsing are the
//! `relay_artifacts::notes` ones, so both crates refuse the same documents
//! with the same `NoteContractError` messages.

use relay_artifacts::notes as base;
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256;

pub use relay_artifacts::notes::{
    NOTE_CHECKPOINT_REASONS, NOTE_INDEX_SCHEMA_VERSION, NOTE_MAX_BYTES, NOTE_RECORDING_STATES,
    NOTE_SCHEMA_VERSION, NoteIdentity, NoteSegment, decode_note_index, is_artifact_id, is_digest,
    is_object_id, is_safe_id, validate_note_id, validate_note_metadata, validate_timestamp,
};

use crate::{Error, Result};

const SEGMENT_MARKER: &str = "<!-- relay-note-segment ";

fn contract(message: impl Into<String>) -> Error {
    Error::new("NoteContractError", message)
}

/// `NoteIdentity.from_mapping`.
pub fn identity_from_mapping(value: &Dict) -> Result<NoteIdentity> {
    let identity = NoteIdentity {
        note_id: value.string("note_id"),
        artifact_id: value.string("artifact_id"),
        project_id: value.string("project_id"),
        created_at: value.string("created_at"),
        capture_started_at: value.string("capture_started_at"),
    };
    validate_identity(&identity)?;
    Ok(identity)
}

fn validate_identity(identity: &NoteIdentity) -> Result<()> {
    validate_note_id(&identity.note_id)?;
    if !is_artifact_id(&identity.artifact_id) {
        return Err(contract("note immutable artifact_id is invalid"));
    }
    if !is_safe_id(&identity.project_id) {
        return Err(contract("note project_id is invalid"));
    }
    validate_timestamp(&identity.created_at, "note created_at")?;
    validate_timestamp(&identity.capture_started_at, "note capture_started_at")?;
    Ok(())
}

/// `NoteIdentity.as_dict()`.
pub fn identity_dict(identity: &NoteIdentity) -> Dict {
    let mut value = Dict::new();
    value.insert("note_id", identity.note_id.as_str());
    value.insert("artifact_id", identity.artifact_id.as_str());
    value.insert("project_id", identity.project_id.as_str());
    value.insert("created_at", identity.created_at.as_str());
    value.insert("capture_started_at", identity.capture_started_at.as_str());
    value
}

/// `NoteSegment.as_dict()`.
pub fn segment_dict(segment: &NoteSegment) -> Dict {
    let mut value = segment.metadata();
    value.insert("text", segment.text.as_str());
    value
}

/// `NoteUpdate`: one checkpoint of a note, with its immutable identity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteUpdate {
    pub identity: NoteIdentity,
    pub captured_at: String,
    pub recording_state: String,
    pub checkpoint_reason: String,
    pub segments: Vec<NoteSegment>,
    pub capture_ended_at: Option<String>,
}

/// Python's `isinstance(value, Sequence) and not isinstance(value, (str,
/// bytes))` for JSON, then `isinstance(item, Mapping)` for each item.
fn segment_mappings(raw_segments: &Value) -> Result<Vec<Dict>> {
    let Some(items) = raw_segments.as_list() else {
        return Err(contract("note segments must be an array"));
    };
    items
        .iter()
        .map(|item| {
            item.as_dict()
                .cloned()
                .ok_or_else(|| contract("each note segment must be an object"))
        })
        .collect()
}

impl NoteUpdate {
    /// `NoteUpdate.from_mapping`.
    pub fn from_mapping(value: &Dict) -> Result<Self> {
        let Some(Value::Dict(identity)) = value.get("identity") else {
            return Err(contract("note update identity is required"));
        };
        let identity = identity_from_mapping(identity)?;
        let capture_ended_at = value.present("capture_ended_at").map(Value::py_str);
        Self::from_values(
            identity,
            &value.string("captured_at"),
            &value.string("recording_state"),
            &value.string("checkpoint_reason"),
            value.get("segments").unwrap_or(&Value::Null),
            capture_ended_at.as_deref(),
        )
    }

    /// `NoteUpdate.from_values`.
    pub fn from_values(
        identity: NoteIdentity,
        captured_at: &str,
        recording_state: &str,
        checkpoint_reason: &str,
        raw_segments: &Value,
        capture_ended_at: Option<&str>,
    ) -> Result<Self> {
        // The order of checks is Python's: state fields first, then segments.
        validate_timestamp(captured_at, "note captured_at")?;
        if !NOTE_RECORDING_STATES.contains(&recording_state) {
            return Err(contract("note recording_state is invalid"));
        }
        if !NOTE_CHECKPOINT_REASONS.contains(&checkpoint_reason) {
            return Err(contract("note checkpoint_reason is invalid"));
        }
        if let Some(ended) = capture_ended_at {
            validate_timestamp(ended, "note capture_ended_at")?;
        }
        if (recording_state == "completed") != capture_ended_at.is_some() {
            return Err(contract(
                "capture_ended_at is required exactly when recording_state is completed",
            ));
        }
        let mappings = segment_mappings(raw_segments)?;
        let checked = base::NoteUpdate::from_values(
            captured_at,
            recording_state,
            checkpoint_reason,
            &mappings,
            capture_ended_at,
        )?;
        Ok(Self {
            identity,
            captured_at: checked.captured_at,
            recording_state: checked.recording_state,
            checkpoint_reason: checked.checkpoint_reason,
            segments: checked.segments,
            capture_ended_at: checked.capture_ended_at,
        })
    }

    /// `NoteUpdate.as_dict()`.
    pub fn as_dict(&self) -> Dict {
        let mut value = Dict::new();
        value.insert("identity", identity_dict(&self.identity));
        value.insert("captured_at", self.captured_at.as_str());
        value.insert("recording_state", self.recording_state.as_str());
        value.insert("checkpoint_reason", self.checkpoint_reason.as_str());
        value.insert(
            "segments",
            Value::List(
                self.segments
                    .iter()
                    .map(|segment| Value::Dict(segment_dict(segment)))
                    .collect(),
            ),
        );
        if let Some(ended) = &self.capture_ended_at {
            value.insert("capture_ended_at", ended.as_str());
        }
        value
    }
}

/// `NoteDocument`.
#[derive(Clone, Debug)]
pub struct NoteDocument {
    pub identity: NoteIdentity,
    pub update: NoteUpdate,
    pub metadata: Option<Dict>,
}

impl NoteDocument {
    /// `NoteDocument.as_dict()`.
    pub fn as_dict(&self) -> Dict {
        let mut value = self.update.as_dict();
        value.insert("metadata", self.metadata.clone());
        value
    }
}

/// Python's `a == b` for two optional metadata objects.
pub fn metadata_eq(left: Option<&Dict>, right: Option<&Dict>) -> bool {
    match (left, right) {
        (None, None) => true,
        (Some(a), Some(b)) => json::py_eq(&Value::Dict(a.clone()), &Value::Dict(b.clone())),
        _ => false,
    }
}

/// `note_source`: only provider input takes part in deduplication, never
/// capture state.
pub fn note_source(update: &NoteUpdate) -> (String, String) {
    let joined = update
        .segments
        .iter()
        .map(|segment| segment.text.as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    let text = json::py_strip(&joined).to_string();
    let digest = sha256::hex_digest(text.as_bytes());
    (text, digest)
}

/// `metadata_for_update`: the metadata a checkpoint keeps or resets.
pub fn metadata_for_update(update: &NoteUpdate, previous: Option<&Dict>) -> Dict {
    let (text, digest) = note_source(update);
    if let Some(previous) = previous.filter(|previous| !previous.is_empty())
        && (previous
            .get("origin")
            .is_some_and(|origin| origin.is_str("manual"))
            || previous
                .get("source_sha256")
                .is_some_and(|source| source.is_str(&digest)))
    {
        return previous.clone();
    }
    if text.is_empty() {
        let mut value = Dict::new();
        value.insert("origin", "generated");
        value.insert("state", "empty");
        value.insert("source_sha256", digest);
        return value;
    }
    let mut value = previous.cloned().unwrap_or_default();
    value.insert("origin", "generated");
    value.insert("state", "pending");
    value.insert("source_sha256", digest);
    value.insert("error_code", Value::Null);
    value
}

/// `render_note_document`: the canonical Markdown of a note.
pub fn render_note_document(document: &NoteDocument) -> Result<Vec<u8>> {
    let identity = &document.identity;
    let update = &document.update;
    if update.identity != *identity {
        return Err(contract("note update identity changed"));
    }
    let mut fields = vec![
        "---".to_string(),
        format!("note_schema_version: {NOTE_SCHEMA_VERSION}"),
        format!("id: {}", identity.note_id),
        format!("artifact_id: {}", identity.artifact_id),
        format!("project_id: {}", identity.project_id),
        format!("created_at: {}", identity.created_at),
        format!("capture_started_at: {}", identity.capture_started_at),
        format!("updated_at: {}", update.captured_at),
        format!("recording_state: {}", update.recording_state),
        format!("checkpoint_reason: {}", update.checkpoint_reason),
        format!("segment_count: {}", update.segments.len()),
    ];
    if let Some(ended) = &update.capture_ended_at {
        fields.push(format!("capture_ended_at: {ended}"));
    }
    if let Some(metadata) = &document.metadata {
        let metadata = validate_note_metadata(&Value::Dict(metadata.clone()))?;
        fields.push(format!(
            "note_metadata: {}",
            json::dumps_unicode(&Value::Dict(metadata))
        ));
    }
    fields.extend(["---", "", "## Transcript", ""].map(str::to_string));
    for segment in &update.segments {
        let metadata = json::dumps_compact_sorted_unicode(&Value::Dict(segment.metadata()));
        fields.push(format!("{SEGMENT_MARKER}{metadata} -->"));
        fields.push(segment.text.clone());
        fields.push(String::new());
    }
    let joined = fields.join("\n");
    Ok(format!("{}\n", joined.trim_end_matches('\n')).into_bytes())
}

/// `parse_note_document`.
pub fn parse_note_document(content: &[u8]) -> Result<NoteDocument> {
    let parsed = base::parse_note_document(content)?;
    let update = NoteUpdate {
        identity: parsed.identity.clone(),
        captured_at: parsed.update.captured_at,
        recording_state: parsed.update.recording_state,
        checkpoint_reason: parsed.update.checkpoint_reason,
        segments: parsed.update.segments,
        capture_ended_at: parsed.update.capture_ended_at,
    };
    Ok(NoteDocument {
        identity: parsed.identity,
        update,
        metadata: parsed.metadata,
    })
}

/// `encode_note_index`: entries ordered by note number, then artifact id,
/// one sorted compact JSON object per line.
pub fn encode_note_index(entries: &[(String, Dict)], project_id: &str) -> Result<Vec<u8>> {
    let mut ordered: Vec<(u64, String, String, &Dict)> = Vec::new();
    for (_, entry) in entries {
        let (prefix, number) = validate_note_id(&entry.string("note_id"))?;
        ordered.push((number, prefix, entry.string("artifact_id"), entry));
    }
    // Python sorts by (prefix, number, artifact_id).
    ordered.sort_by(|a, b| (&a.1, a.0, &a.2).cmp(&(&b.1, b.0, &b.2)));
    let mut lines = Vec::new();
    for (_, _, _, entry) in &ordered {
        lines.push(json::dumps_compact_sorted_unicode(&Value::Dict(
            (*entry).clone(),
        )));
    }
    let content = if lines.is_empty() {
        Vec::new()
    } else {
        format!("{}\n", lines.join("\n")).into_bytes()
    };
    // Each entry is validated exactly as decoding validates it.
    decode_note_index(&content, project_id)?;
    Ok(content)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> NoteIdentity {
        NoteIdentity {
            note_id: "RR-N1".into(),
            artifact_id: "note-0123456789".into(),
            project_id: "global-notes".into(),
            created_at: "2026-08-04T05:00:00Z".into(),
            capture_started_at: "2026-08-04T05:00:00Z".into(),
        }
    }

    fn segments(texts: &[&str]) -> Value {
        Value::List(
            texts
                .iter()
                .enumerate()
                .map(|(index, text)| {
                    let mut segment = Dict::new();
                    segment.insert("segment_id", format!("s{index}"));
                    segment.insert("captured_at", "2026-08-04T05:00:00Z");
                    segment.insert("text", *text);
                    Value::Dict(segment)
                })
                .collect(),
        )
    }

    #[test]
    fn render_round_trips_through_the_artifact_parser() {
        let update = NoteUpdate::from_values(
            identity(),
            "2026-08-04T05:01:00Z",
            "recording",
            "checkpoint",
            &segments(&["Hello.", "World  "]),
            None,
        )
        .unwrap();
        let metadata = metadata_for_update(&update, None);
        assert_eq!(metadata.string("state"), "pending");
        let document = NoteDocument {
            identity: identity(),
            update,
            metadata: Some(metadata),
        };
        let markdown = render_note_document(&document).unwrap();
        let parsed = parse_note_document(&markdown).unwrap();
        assert_eq!(parsed.update, document.update);
        assert_eq!(render_note_document(&parsed).unwrap(), markdown);
        assert_eq!(note_source(&parsed.update).0, "Hello.\n\nWorld");
    }

    #[test]
    fn segment_errors_keep_python_order() {
        let error = NoteUpdate::from_values(
            identity(),
            "bad",
            "recording",
            "checkpoint",
            &Value::Str("x".into()),
            None,
        )
        .unwrap_err();
        assert_eq!(error.message, "note captured_at is not RFC 3339: 'bad'");
        let error = NoteUpdate::from_values(
            identity(),
            "2026-08-04T05:01:00Z",
            "recording",
            "checkpoint",
            &Value::Str("x".into()),
            None,
        )
        .unwrap_err();
        assert_eq!(
            (error.class, error.message.as_str()),
            ("NoteContractError", "note segments must be an array")
        );
    }

    #[test]
    fn empty_source_and_manual_metadata() {
        let update = NoteUpdate::from_values(
            identity(),
            "2026-08-04T05:01:00Z",
            "recording",
            "checkpoint",
            &Value::List(Vec::new()),
            None,
        )
        .unwrap();
        let empty = metadata_for_update(&update, None);
        assert_eq!(empty.string("state"), "empty");
        let mut manual = Dict::new();
        manual.insert("origin", "manual");
        manual.insert("state", "ready");
        assert!(metadata_eq(
            Some(&metadata_for_update(&update, Some(&manual))),
            Some(&manual)
        ));
    }
}
