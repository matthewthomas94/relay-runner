//! `services/personal_notes.py`: the global note API over the personal-file
//! cache after the verified Git migration.
//!
//! The document, identity and checkpoint contract is the project notes' one.
//! The catalog's `personal_notes` and `personal_note_events` tables keep
//! entries and idempotency digests; transcript versions live in the bounded
//! personal-file cache and immutable private GitHub objects.

use std::sync::Arc;

use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256;
use relay_store::personal_catalog::{NOTE_ENTRIES_TABLE, NOTE_EVENTS_TABLE};
use rusqlite::types::Value as Sql;

use super::contract::{
    NoteDocument, NoteIdentity, NoteUpdate, identity_dict, metadata_eq, metadata_for_update,
    note_source, parse_note_document, render_note_document, validate_note_id,
    validate_note_metadata, validate_timestamp,
};
use super::project::{
    ProjectNoteManager, card, collision, deleted, digest, event_id, identity_error, note_update,
    validate_provider, validated_segment_payload, validation,
};
use super::{CreateNote, NoteManager, util};
use crate::personal_storage::{PersonalFileStorage, text};
use crate::{Error, Result};

/// The personal note logic over a borrowed storage. [`PersonalNoteManager`]
/// owns its storage; the catalog import borrows one.
pub struct PersonalNotes<'s> {
    pub storage: &'s PersonalFileStorage,
    pub device_id: String,
}

fn entry_path(note_id: &str) -> String {
    format!("notes/{note_id}.md")
}

fn parse_entry(text: &str) -> Result<Dict> {
    json::parse(text)
        .and_then(|value| value.as_dict().cloned())
        .ok_or_else(|| Error::value("Expecting value"))
}

fn sql_int(value: i64) -> Sql {
    Sql::Integer(value)
}

impl<'s> PersonalNotes<'s> {
    /// `PersonalNoteManager(storage, device_id, commit=...)`: creates the
    /// note tables.
    pub fn open(storage: &'s PersonalFileStorage, device_id: &str, commit: bool) -> Result<Self> {
        let _guard = storage.lock.lock();
        storage.db.raw(NOTE_ENTRIES_TABLE)?;
        storage.db.raw(NOTE_EVENTS_TABLE)?;
        if commit {
            storage.db.commit()?;
        }
        Ok(Self {
            storage,
            device_id: device_id.to_string(),
        })
    }

    /// `import_remote_entry(entry, commit=...)`.
    pub fn import_remote_entry(&self, entry: &Dict, commit: bool) -> Result<()> {
        let _guard = self.storage.lock.lock();
        if !entry
            .get("project_id")
            .is_some_and(|id| id.is_str("global-notes"))
            || !matches!(entry.get("global_code"), Some(Value::Str(_)))
        {
            return Err(identity_error(
                "Remote note catalog has an invalid global identity",
            ));
        }
        let note_id = entry
            .get("note_id")
            .map(Value::py_str)
            .ok_or_else(|| Error::new("KeyError", "'note_id'"))?;
        validate_note_id(&note_id)?;
        let artifact_id = entry.string("artifact_id");
        let global_code = entry.string("global_code");
        for row in self
            .storage
            .db
            .rows("SELECT entry FROM personal_notes WHERE deleted=0", &[])?
        {
            let local = parse_entry(&row.string("entry"))?;
            if local.string("artifact_id") != artifact_id
                && (local.string("note_id") == note_id
                    || local
                        .get("global_code")
                        .is_some_and(|code| code.is_str(&global_code)))
            {
                return Err(identity_error(
                    "Remote note code collides with another note; both histories are preserved",
                ));
            }
        }
        let mut copied = entry.clone();
        copied.insert("path", entry_path(&note_id));
        copied.insert("legacy_recovery", Value::Null);
        copied.remove("deleted");
        let removed = entry.get("deleted").is_some_and(Value::truthy);
        self.storage.db.execute(
            "INSERT OR REPLACE INTO personal_notes VALUES(?,?,?)",
            &[
                text(artifact_id),
                text(json::dumps(&Value::Dict(copied))),
                sql_int(i64::from(removed)),
            ],
        )?;
        if commit {
            self.storage.db.commit()?;
        }
        Ok(())
    }

    /// `head()`: a digest of every note entry, standing in for a commit.
    pub fn head(&self) -> Result<String> {
        let _guard = self.storage.lock.lock();
        let rows = self.storage.db.rows(
            "SELECT artifact_id,entry,deleted FROM personal_notes ORDER BY artifact_id",
            &[],
        )?;
        let tuples: Vec<Value> = rows
            .into_iter()
            .map(|row| {
                Value::List(vec![
                    row.get("artifact_id").cloned().unwrap_or(Value::Null),
                    row.get("entry").cloned().unwrap_or(Value::Null),
                    row.get("deleted").cloned().unwrap_or(Value::Null),
                ])
            })
            .collect();
        Ok(digest(&Value::List(tuples)))
    }

    fn entry(&self, identity: &str, include_deleted: bool) -> Result<Dict> {
        let mut matches = Vec::new();
        for row in self
            .storage
            .db
            .rows("SELECT entry,deleted FROM personal_notes", &[])?
        {
            let entry = parse_entry(&row.string("entry"))?;
            let named = entry
                .get("artifact_id")
                .is_some_and(|id| id.is_str(identity))
                || entry.get("note_id").is_some_and(|id| id.is_str(identity))
                || entry
                    .get("global_code")
                    .is_some_and(|code| code.is_str(identity));
            if named && (include_deleted || !row.get("deleted").is_some_and(Value::truthy)) {
                matches.push(entry);
            }
        }
        if matches.len() != 1 {
            return Err(validation("No unique global note matches this identity"));
        }
        Ok(matches.remove(0))
    }

    fn document(&self, entry: &Dict, revision: Option<&str>) -> Result<NoteDocument> {
        parse_note_document(&self.storage.read(&entry.string("artifact_id"), revision)?)
    }

    fn reference(&self, entry: &Dict, revision: Option<&str>) -> Result<Dict> {
        let reference = self
            .storage
            .reference(&entry.string("artifact_id"), revision)?;
        let local = reference
            .get("local_path")
            .and_then(Value::as_str)
            .filter(|local| !local.is_empty());
        let path = match local {
            Some(local) => {
                let full = self.storage.root.join(local);
                full.strip_prefix(&self.storage.files_root)
                    .map(|relative| relative.to_string_lossy().into_owned())
                    .map_err(|_| Error::value("path is not in the subpath of the files root"))?
            }
            None => entry.get("path").map(Value::py_str).unwrap_or_default(),
        };
        let sha = reference.string("sha256");
        let or_sha = |key: &str| {
            reference
                .truthy(key)
                .cloned()
                .unwrap_or_else(|| Value::Str(sha.clone()))
        };
        let mut result = Dict::new();
        result.insert("path", path);
        result.insert("artifact_ref", "personal/files");
        result.insert("commit", or_sha("remote_commit"));
        result.insert("revision", or_sha("remote_blob"));
        result.insert("history_reference", sha.as_str());
        result.insert(
            "verified",
            reference.get("materialized").is_some_and(Value::truthy)
                || reference.get("remote_commit").is_some_and(Value::truthy),
        );
        result.insert("catalog_commit", self.head()?);
        result.insert(
            "personal_file_id",
            entry.get("artifact_id").cloned().unwrap_or(Value::Null),
        );
        result.insert("sha256", sha.as_str());
        Ok(result)
    }

    fn sync(&self) -> Result<Dict> {
        let state = self.storage.status()?;
        let mut sync = Dict::new();
        sync.insert(
            "mode",
            if state.get("connected").is_some_and(Value::truthy) {
                "enabled"
            } else {
                "local_only"
            },
        );
        sync.insert("state", state.get("state").cloned().unwrap_or(Value::Null));
        sync.insert(
            "recovery",
            state.get("message").cloned().unwrap_or(Value::Null),
        );
        Ok(sync)
    }

    fn response(&self, entry: &Dict, revision: Option<&str>, idempotent: bool) -> Result<Dict> {
        let document = self.document(entry, revision)?;
        let reference = self.reference(entry, revision)?;
        let mut result = Dict::new();
        result.insert("note", document.as_dict());
        result.insert(
            "markdown_base64",
            util::b64encode(&render_note_document(&document)?),
        );
        result.insert(
            "materialized",
            !entry.get("archived_at").is_some_and(Value::truthy),
        );
        result.insert("artifact_commit", self.head()?);
        result.insert("reference", reference);
        result.insert("idempotent", idempotent);
        result.insert("sync", self.sync()?);
        Ok(result)
    }

    /// `_next_number()`.
    pub fn next_number(&self) -> Result<i64> {
        Ok(self
            .storage
            .get("next_personal_note_id", Value::Int(1))?
            .py_int()
            .unwrap_or(1))
    }

    fn set_next(&self, number: i64) -> Result<()> {
        self.storage
            .set("next_personal_note_id", &Value::Int(number))
    }

    fn save(
        &self,
        entry: &Dict,
        document: &NoteDocument,
        event_id: &str,
        digest: &str,
    ) -> Result<Dict> {
        let artifact_id = entry.string("artifact_id");
        let existing = self.storage.db.row(
            "SELECT digest,artifact_id,revision FROM personal_note_events WHERE event_id=?",
            &[text(event_id)],
        )?;
        if let Some(existing) = existing {
            if existing.string("digest") != digest || existing.string("artifact_id") != artifact_id
            {
                return Err(collision(
                    "Note request was already used with different content",
                ));
            }
            return self.response(entry, Some(&existing.string("revision")), true);
        }
        let mut metadata = Dict::new();
        metadata.insert("note_entry", entry.clone());
        let reference = self.storage.put(
            &artifact_id,
            &entry_path(&entry.string("note_id")),
            &render_note_document(document)?,
            "notes",
            Some(&Value::Dict(metadata)),
            document.update.recording_state != "completed",
            None,
            false,
        )?;
        self.storage.db.execute(
            "INSERT OR REPLACE INTO personal_notes VALUES(?,?,0)",
            &[
                text(artifact_id.as_str()),
                text(json::dumps(&Value::Dict(entry.clone()))),
            ],
        )?;
        self.storage.db.execute(
            "INSERT INTO personal_note_events VALUES(?,?,?,?)",
            &[
                text(event_id),
                text(digest),
                text(artifact_id),
                text(reference.string("sha256")),
            ],
        )?;
        self.storage.db.commit()?;
        self.response(entry, None, false)
    }

    /// `import_catalog_entry(entry, document)`: migration keeps note codes,
    /// paths, event keys and immutable identity.
    pub fn import_catalog_entry(&self, entry: &Dict, document: &NoteDocument) -> Result<()> {
        let _guard = self.storage.lock.lock();
        let artifact_id = entry.string("artifact_id");
        let mut copied = entry.clone();
        copied.insert("path", entry_path(&entry.string("note_id")));
        let row = self.storage.db.row(
            "SELECT entry FROM personal_notes WHERE artifact_id=?",
            &[text(artifact_id.as_str())],
        )?;
        if let Some(row) = row
            && json::py_eq(
                &Value::Dict(parse_entry(&row.string("entry"))?),
                &Value::Dict(copied.clone()),
            )
        {
            return Ok(());
        }
        let document_digest = digest(&Value::Dict(document.as_dict()));
        self.save(
            &copied,
            document,
            &format!("migration:{artifact_id}:{document_digest}"),
            &document_digest,
        )?;
        // Existing create requests still return their original identity
        // after compaction.
        let creation = entry.string("creation_event_id");
        if !creation.is_empty()
            && entry
                .get("creation_request_sha256")
                .is_some_and(Value::truthy)
        {
            let reference = self.storage.reference(&artifact_id, None)?;
            self.storage.db.execute(
                "INSERT OR IGNORE INTO personal_note_events VALUES(?,?,?,?)",
                &[
                    text(creation),
                    text(entry.string("creation_request_sha256")),
                    text(artifact_id),
                    text(reference.string("sha256")),
                ],
            )?;
        }
        let code = entry
            .get("global_code")
            .map(Value::py_str)
            .unwrap_or_else(|| "N0".to_string());
        let code_number = code
            .get(1..)
            .and_then(|digits| digits.parse::<i64>().ok())
            .ok_or_else(|| {
                Error::value(format!(
                    "invalid literal for int() with base 10: {}",
                    json::str_repr(code.get(1..).unwrap_or_default())
                ))
            })?;
        let number = validate_note_id(&entry.string("note_id"))?.1 as i64;
        self.set_next(self.next_number()?.max(number + 1).max(code_number + 1))?;
        self.storage.db.commit()
    }

    /// `import_git_events(manager, current_ids)`: keep retry receipts and
    /// deletion and import tombstones before the old history is pruned.
    pub fn import_git_events(
        &self,
        manager: &ProjectNoteManager,
        current_ids: &[String],
    ) -> Result<()> {
        let _guard = self.storage.lock.lock();
        let history = manager
            .store
            .git(
                &[
                    "log",
                    "--reverse",
                    "--format=%H%x1f%B%x1e",
                    &manager.store.artifact_ref,
                ],
                &[],
                None,
                &[0],
            )?
            .text();
        for record in history.split('\u{1e}') {
            if !record.contains('\u{1f}') {
                continue;
            }
            let (commit, message) = json::py_strip(record)
                .split_once('\u{1f}')
                .unwrap_or_default();
            let event = message
                .lines()
                .find_map(|line| line.strip_prefix("Relay-Event-ID: "))
                .unwrap_or_default()
                .to_string();
            if ![
                "note-create:",
                "note-update:",
                "note-import:",
                "note-import-update:",
            ]
            .iter()
            .any(|prefix| event.starts_with(prefix))
            {
                continue;
            }
            let catalog = manager.catalog_at(commit)?;
            for (_, entry) in &catalog {
                if !(entry
                    .get("last_event_id")
                    .is_some_and(|id| id.is_str(&event))
                    || entry
                        .get("creation_event_id")
                        .is_some_and(|id| id.is_str(&event)))
                {
                    continue;
                }
                if self
                    .storage
                    .db
                    .row(
                        "SELECT 1 FROM personal_note_events WHERE event_id=?",
                        &[text(event.as_str())],
                    )?
                    .is_some()
                {
                    continue;
                }
                let source = manager.read_entry(commit, entry, true)?;
                let markdown = util::b64decode(&source.string("markdown_base64"))
                    .ok_or_else(|| Error::value("Incorrect padding"))?;
                let document = parse_note_document(&markdown)?;
                let artifact_id = entry.string("artifact_id");
                let note_id = entry.string("note_id");
                let mut metadata = Dict::new();
                metadata.insert("note_entry", entry.clone());
                let reference = self.storage.put(
                    &artifact_id,
                    &entry_path(&note_id),
                    &render_note_document(&document)?,
                    "notes",
                    Some(&Value::Dict(metadata)),
                    false,
                    None,
                    true,
                )?;
                let event_digest =
                    if event.starts_with("note-create:") || event.starts_with("note-import:") {
                        entry.string("creation_request_sha256")
                    } else {
                        digest(&Value::Dict(document.update.as_dict()))
                    };
                self.storage.db.execute(
                    "INSERT INTO personal_note_events VALUES(?,?,?,?)",
                    &[
                        text(event.as_str()),
                        text(event_digest),
                        text(artifact_id.as_str()),
                        text(reference.string("sha256")),
                    ],
                )?;
                let mut copied = entry.clone();
                copied.insert("path", entry_path(&note_id));
                self.storage.db.execute(
                    "INSERT OR IGNORE INTO personal_notes VALUES(?,?,?)",
                    &[
                        text(artifact_id.as_str()),
                        text(json::dumps(&Value::Dict(copied))),
                        sql_int(i64::from(!current_ids.contains(&artifact_id))),
                    ],
                )?;
            }
        }
        self.storage.db.commit()
    }

    #[allow(clippy::too_many_arguments)]
    fn new_entry(
        identity: &NoteIdentity,
        update: &NoteUpdate,
        event: &str,
        request_digest: &str,
        metadata: Option<Dict>,
        number: i64,
    ) -> Dict {
        let mut entry = Dict::new();
        entry.insert("schema_version", 1);
        entry.insert("global_code", format!("N{number}"));
        entry.insert("note_id", identity.note_id.as_str());
        entry.insert("artifact_id", identity.artifact_id.as_str());
        entry.insert("project_id", identity.project_id.as_str());
        entry.insert("path", entry_path(&identity.note_id));
        entry.insert("created_at", identity.created_at.as_str());
        entry.insert("updated_at", update.captured_at.as_str());
        entry.insert("recording_state", update.recording_state.as_str());
        entry.insert("segment_count", update.segments.len() as i64);
        entry.insert("materialized", true);
        entry.insert("creation_event_id", event);
        entry.insert("last_event_id", event);
        entry.insert("creation_request_sha256", request_digest);
        entry.insert("metadata", metadata);
        entry.insert("legacy_recovery", Value::Null);
        entry
    }

    pub fn import_saved_note(&self, source: &Dict, repository_path: Option<&str>) -> Result<()> {
        let original = NoteUpdate::from_mapping(source)?;
        let mut event = format!(
            "note-import:{}",
            digest(&Value::Dict(identity_dict(&original.identity)))
        );
        let source_digest = digest(&Value::Dict(source.clone()));
        let _guard = self.storage.lock.lock();
        let prior = self.storage.db.row(
            "SELECT artifact_id FROM personal_note_events WHERE event_id=?",
            &[text(event.as_str())],
        )?;
        let (number, note_id) = if prior.is_some() {
            let removed = self.storage.db.row(
                "SELECT deleted FROM personal_notes WHERE artifact_id=?",
                &[text(original.identity.artifact_id.as_str())],
            )?;
            if removed
                .as_ref()
                .is_none_or(|row| row.get("deleted").is_some_and(Value::truthy))
            {
                return Ok(());
            }
            let existing = self.entry(&original.identity.artifact_id, false)?;
            if existing
                .get("recording_state")
                .is_some_and(|state| state.is_str("completed"))
                || existing
                    .get("creation_request_sha256")
                    .is_some_and(|sha| sha.is_str(&source_digest))
            {
                return Ok(());
            }
            let code = existing.string("global_code");
            let number = code
                .get(1..)
                .and_then(|digits| digits.parse::<i64>().ok())
                .ok_or_else(|| Error::value("invalid literal for int() with base 10"))?;
            event = format!("note-import-update:{source_digest}");
            (number, existing.string("note_id"))
        } else {
            let number = self.next_number()?;
            let mut note_id = original.identity.note_id.clone();
            let taken = self
                .storage
                .db
                .rows("SELECT entry FROM personal_notes", &[])?
                .iter()
                .map(|row| parse_entry(&row.string("entry")))
                .collect::<Result<Vec<_>>>()?
                .iter()
                .any(|entry| entry.string("note_id") == note_id);
            if taken {
                note_id = format!("RR-N{number}");
            }
            (number, note_id)
        };
        let identity = NoteIdentity {
            project_id: "global-notes".to_string(),
            note_id: note_id.clone(),
            ..original.identity.clone()
        };
        let update = NoteUpdate {
            identity: identity.clone(),
            ..original.clone()
        };
        let metadata = source.present("metadata").and_then(Value::as_dict).cloned();
        let document = NoteDocument {
            identity: identity.clone(),
            update: update.clone(),
            metadata: metadata.clone(),
        };
        let mut entry =
            Self::new_entry(&identity, &update, &event, &source_digest, metadata, number);
        let recovery = match repository_path {
            Some(path) if !path.is_empty() && update.recording_state != "completed" => {
                let mut recovery = Dict::new();
                recovery.insert("repository_path", path);
                recovery.insert("project_id", original.identity.project_id.as_str());
                recovery.insert("note_id", original.identity.note_id.as_str());
                Value::Dict(recovery)
            }
            _ => Value::Null,
        };
        entry.insert("legacy_recovery", recovery);
        let issued = validate_note_id(&note_id)?.1 as i64;
        self.set_next(self.next_number()?.max(number + 1).max(issued + 1))?;
        self.save(&entry, &document, &event, &source_digest)?;
        Ok(())
    }

    pub fn create(&self, request: &CreateNote) -> Result<Dict> {
        validate_provider(request.provider.as_deref())?;
        let event = event_id("create", &request.request_id)?;
        let raw_segments = validated_segment_payload(&request.segments)?;
        // The legacy request digest keeps retries that span the migration
        // safe.
        let request_digest = digest(&Value::Dict(request.payload(&raw_segments)));
        let _guard = self.storage.lock.lock();
        let prior = self.storage.db.row(
            "SELECT * FROM personal_note_events WHERE event_id=?",
            &[text(event.as_str())],
        )?;
        if let Some(prior) = prior {
            if prior.string("digest") != request_digest {
                return Err(collision(
                    "Note create request was already used with different content",
                ));
            }
            let entry = self.entry(&prior.string("artifact_id"), true)?;
            return self.response(&entry, Some(&prior.string("revision")), true);
        }
        let number = self.next_number()?;
        let artifact = format!(
            "note-{}",
            &sha256::hex_digest(format!("global-notes:{event}").as_bytes())[..40]
        );
        let mut raw_identity = Dict::new();
        raw_identity.insert("note_id", format!("RR-N{number}"));
        raw_identity.insert("artifact_id", artifact);
        raw_identity.insert("project_id", "global-notes");
        raw_identity.insert("created_at", request.created_at.as_str());
        raw_identity.insert("capture_started_at", request.capture_started_at.as_str());
        let identity = super::contract::identity_from_mapping(&raw_identity)?;
        let update = note_update(
            identity.clone(),
            &request.captured_at,
            &request.recording_state,
            &request.checkpoint_reason,
            &raw_segments,
            request.capture_ended_at.as_deref(),
        )?;
        let metadata = metadata_for_update(&update, None);
        let document = NoteDocument {
            identity: identity.clone(),
            update: update.clone(),
            metadata: Some(metadata.clone()),
        };
        let entry = Self::new_entry(
            &identity,
            &update,
            &event,
            &request_digest,
            Some(metadata),
            number,
        );
        self.set_next(number + 1)?;
        self.save(&entry, &document, &event, &request_digest)
    }

    pub fn update(&self, request_id: &str, update: &Dict, provider: Option<&str>) -> Result<Dict> {
        validate_provider(provider)?;
        let desired = NoteUpdate::from_mapping(update)?;
        let event = event_id("update", request_id)?;
        let _guard = self.storage.lock.lock();
        let mut entry = self.entry(&desired.identity.artifact_id, false)?;
        let current = self.document(&entry, None)?;
        if current.identity != desired.identity {
            return Err(identity_error(
                "Note update cannot change immutable identity",
            ));
        }
        if entry.get("archived_at").is_some_and(Value::truthy) {
            return Err(validation("Restore the archived note before updating it"));
        }
        let metadata = metadata_for_update(&desired, current.metadata.as_ref());
        let document = NoteDocument {
            identity: current.identity.clone(),
            update: desired.clone(),
            metadata: Some(metadata.clone()),
        };
        entry.insert("updated_at", desired.captured_at.as_str());
        entry.insert("recording_state", desired.recording_state.as_str());
        entry.insert("segment_count", desired.segments.len() as i64);
        entry.insert("metadata", metadata);
        entry.insert("last_event_id", event.as_str());
        self.save(
            &entry,
            &document,
            &event,
            &digest(&Value::Dict(desired.as_dict())),
        )
    }

    pub fn publish_metadata(
        &self,
        identity: &NoteIdentity,
        source_sha256: &str,
        metadata: &Dict,
        expected_metadata: Option<&Dict>,
    ) -> Result<bool> {
        let metadata = validate_note_metadata(&Value::Dict(metadata.clone()))?;
        let _guard = self.storage.lock.lock();
        let mut entry = match self.entry(&identity.artifact_id, false) {
            Ok(entry) => entry,
            Err(error) if error.class == "ArtifactValidationError" => return Ok(false),
            Err(error) => return Err(error),
        };
        if entry.get("archived_at").is_some_and(Value::truthy) {
            return Ok(false);
        }
        let current = self.document(&entry, None)?;
        let manual = current
            .metadata
            .as_ref()
            .and_then(|current| current.get("origin"))
            .is_some_and(|origin| origin.is_str("manual"));
        if current.identity != *identity
            || note_source(&current.update).1 != source_sha256
            || !metadata_eq(current.metadata.as_ref(), expected_metadata)
            || manual
        {
            return Ok(false);
        }
        if !metadata
            .get("source_sha256")
            .is_some_and(|sha| sha.is_str(source_sha256))
        {
            return Err(validation(
                "Note metadata does not match the source transcript",
            ));
        }
        entry.insert("metadata", metadata.clone());
        let document = NoteDocument {
            identity: identity.clone(),
            update: current.update.clone(),
            metadata: Some(metadata.clone()),
        };
        self.save(
            &entry,
            &document,
            &event_id("metadata", &util::uuid4_hex())?,
            &digest(&Value::Dict(metadata)),
        )?;
        Ok(true)
    }

    pub fn delete(
        &self,
        note_id: &str,
        artifact_id: &str,
        request_id: &str,
        cancel_recording: bool,
    ) -> Result<Dict> {
        event_id(
            if cancel_recording { "cancel" } else { "delete" },
            request_id,
        )?;
        let _guard = self.storage.lock.lock();
        let entry = match self.entry(artifact_id, false) {
            Ok(entry) => entry,
            Err(error) if error.class == "ArtifactValidationError" => return Ok(deleted()),
            Err(error) => return Err(error),
        };
        if entry.string("note_id") != note_id {
            return Err(identity_error(
                "Note delete identity does not match the catalog",
            ));
        }
        let completed = entry
            .get("recording_state")
            .is_some_and(|state| state.is_str("completed"));
        if cancel_recording && completed {
            return Err(validation("A saved note cannot be cancelled"));
        }
        if !cancel_recording && !completed {
            return Err(validation("Stop and save this note before deleting it"));
        }
        self.storage.db.execute(
            "UPDATE personal_notes SET deleted=1 WHERE artifact_id=?",
            &[text(artifact_id)],
        )?;
        if self.storage.get("connected", Value::Null)?.truthy() {
            self.storage.set("state", &Value::from("pending"))?;
        }
        self.storage.db.commit()?;
        Ok(deleted())
    }

    pub fn archive(
        &self,
        note_id: &str,
        artifact_id: &str,
        archived_at: &str,
        request_id: &str,
        provider: Option<&str>,
    ) -> Result<Dict> {
        validate_provider(provider)?;
        validate_timestamp(archived_at, "archived_at")?;
        let _guard = self.storage.lock.lock();
        let mut entry = self.entry(artifact_id, false)?;
        if entry.string("note_id") != note_id {
            return Err(identity_error(
                "Note archive identity does not match the catalog",
            ));
        }
        if !entry
            .get("recording_state")
            .is_some_and(|state| state.is_str("completed"))
        {
            return Err(validation("Stop and save this note before archiving it"));
        }
        let document = self.document(&entry, None)?;
        entry.insert("archived_at", archived_at);
        entry.insert("materialized", false);
        let mut receipt = Dict::new();
        receipt.insert("artifact_id", artifact_id);
        receipt.insert("archived_at", archived_at);
        self.save(
            &entry,
            &document,
            &event_id("archive", request_id)?,
            &digest(&Value::Dict(receipt)),
        )
    }

    pub fn get(&self, identity: &str) -> Result<Dict> {
        let _guard = self.storage.lock.lock();
        let entry = self.entry(identity, false)?;
        self.response(&entry, None, true)
    }

    pub fn list(&self, limit: i64, after: Option<&str>) -> Result<Dict> {
        if !(1..=100).contains(&limit) {
            return Err(validation("Note catalog limit must be between 1 and 100"));
        }
        let _guard = self.storage.lock.lock();
        let mut entries = Vec::new();
        for row in self
            .storage
            .db
            .rows("SELECT entry FROM personal_notes WHERE deleted=0", &[])?
        {
            let entry = parse_entry(&row.string("entry"))?;
            let number = validate_note_id(&entry.string("note_id"))?.1;
            entries.push((number, entry.string("artifact_id"), entry));
        }
        entries.sort_by(|a, b| (a.0, &a.1).cmp(&(b.0, &b.1)));
        let entries: Vec<Dict> = entries.into_iter().map(|(_, _, entry)| entry).collect();
        let mut start = 0;
        if let Some(after) = after.filter(|after| !after.is_empty()) {
            let matches: Vec<usize> = entries
                .iter()
                .enumerate()
                .filter(|(_, entry)| entry.get("note_id").is_some_and(|id| id.is_str(after)))
                .map(|(index, _)| index)
                .collect();
            if matches.len() != 1 {
                return Err(validation("Unknown note catalog cursor"));
            }
            start = matches[0] + 1;
        }
        let page: Vec<&Dict> = entries.iter().skip(start).take(limit as usize).collect();
        let mut cards = Vec::new();
        for entry in &page {
            let reference = self.storage.reference(&entry.string("artifact_id"), None)?;
            let mut card = card(entry, self.reference(entry, None)?);
            card.insert(
                "materialized",
                reference.get("materialized").is_some_and(Value::truthy)
                    && !entry.get("archived_at").is_some_and(Value::truthy),
            );
            cards.push(Value::Dict(card));
        }
        let more = start + page.len() < entries.len();
        let next_cursor = match page.last() {
            Some(last) if more => last.get("note_id").cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        };
        let mut result = Dict::new();
        result.insert("notes", Value::List(cards));
        result.insert("artifact_commit", self.head()?);
        result.insert("limit", limit);
        result.insert("has_more", more);
        result.insert("next_cursor", next_cursor);
        result.insert("total_count", entries.len() as i64);
        result.insert("sync", self.sync()?);
        Ok(result)
    }
}

/// `PersonalNoteManager`: the global note manager once notes live in
/// personal storage.
pub struct PersonalNoteManager {
    pub storage: Arc<PersonalFileStorage>,
    pub device_id: String,
}

impl PersonalNoteManager {
    pub fn new(storage: Arc<PersonalFileStorage>, device_id: &str) -> Result<Self> {
        PersonalNotes::open(&storage, device_id, true)?;
        Ok(Self {
            storage,
            device_id: device_id.to_string(),
        })
    }

    /// The borrowed form, for the catalog import.
    pub fn open<'s>(
        storage: &'s PersonalFileStorage,
        device_id: &str,
        commit: bool,
    ) -> Result<PersonalNotes<'s>> {
        PersonalNotes::open(storage, device_id, commit)
    }

    fn notes(&self) -> PersonalNotes<'_> {
        PersonalNotes {
            storage: &self.storage,
            device_id: self.device_id.clone(),
        }
    }
}

impl NoteManager for PersonalNoteManager {
    fn project_id(&self) -> String {
        "global-notes".to_string()
    }
    fn head(&self) -> Result<Option<String>> {
        Ok(Some(self.notes().head()?))
    }
    fn ensure_global_codes(&self) -> Result<()> {
        Ok(())
    }
    fn import_saved_note(&self, source: &Dict, repository_path: Option<&str>) -> Result<()> {
        self.notes().import_saved_note(source, repository_path)
    }
    fn create(&self, request: &CreateNote) -> Result<Dict> {
        self.notes().create(request)
    }
    fn update(&self, request_id: &str, update: &Dict, provider: Option<&str>) -> Result<Dict> {
        self.notes().update(request_id, update, provider)
    }
    fn publish_metadata(
        &self,
        identity: &NoteIdentity,
        source_sha256: &str,
        metadata: &Dict,
        expected_metadata: Option<&Dict>,
    ) -> Result<bool> {
        self.notes()
            .publish_metadata(identity, source_sha256, metadata, expected_metadata)
    }
    fn delete(
        &self,
        note_id: &str,
        artifact_id: &str,
        request_id: &str,
        cancel_recording: bool,
    ) -> Result<Dict> {
        self.notes()
            .delete(note_id, artifact_id, request_id, cancel_recording)
    }
    fn archive(
        &self,
        note_id: &str,
        artifact_id: &str,
        archived_at: &str,
        request_id: &str,
        provider: Option<&str>,
    ) -> Result<Dict> {
        self.notes()
            .archive(note_id, artifact_id, archived_at, request_id, provider)
    }
    fn get(&self, identity: &str) -> Result<Dict> {
        self.notes().get(identity)
    }
    fn list(&self, limit: i64, after: Option<&str>) -> Result<Dict> {
        self.notes().list(limit, after)
    }
}
