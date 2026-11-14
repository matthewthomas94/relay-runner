//! `services/project_notes.py`: canonical project note allocation,
//! checkpointing, catalog and history reads, built only on the canonical
//! artifact ref. Every change is one `relay-artifacts` mutation, so its
//! commit is byte for byte the one the Python manager makes.

use std::fs;
use std::sync::{Arc, LazyLock};

use fancy_regex::Regex;
use relay_artifacts::ErrorKind;
use relay_artifacts::store::{ArtifactStore, Entries, Mutation, Operation, TreeEntry};
use relay_artifacts::{pystr, toml};
use relay_intents::json::{self, Dict, Value};
use relay_intents::sha256;

use super::contract::{
    NOTE_INDEX_SCHEMA_VERSION, NoteDocument, NoteIdentity, NoteSegment, NoteUpdate,
    decode_note_index, encode_note_index, identity_dict, metadata_eq, metadata_for_update,
    note_source, parse_note_document, render_note_document, segment_dict, validate_note_id,
    validate_note_metadata, validate_timestamp,
};
use super::{CreateNote, NoteManager, util};
use crate::{Error, Result};

pub const NOTE_CATALOG_DEFAULT_LIMIT: i64 = 50;
pub const NOTE_CATALOG_MAX_LIMIT: i64 = 100;
const CONFIG_PATH: &str = ".orchestrator/config.toml";
const INDEX_PATH: &str = ".orchestrator/note-index.jsonl";

// Python's `(?m)$` matches before each `\n`, as this one does.
static NEXT_NOTE_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^next_note_id\s*=\s*[^\n]+$").expect("next_note_id pattern"));

/// A snapshot's files, in `git ls-tree` order.
type Files = Vec<(String, Vec<u8>)>;

pub(crate) fn validation(message: impl Into<String>) -> Error {
    Error::new("ArtifactValidationError", message)
}

pub(crate) fn identity_error(message: impl Into<String>) -> Error {
    Error::new("ArtifactIdentityError", message)
}

pub(crate) fn collision(message: impl Into<String>) -> Error {
    Error::new("ArtifactEventCollision", message)
}

/// The note index by artifact id, in file order: Python's `dict`.
pub type Catalog = Vec<(String, Dict)>;

pub(crate) fn catalog_get<'c>(catalog: &'c Catalog, artifact_id: &str) -> Option<&'c Dict> {
    catalog
        .iter()
        .find(|(id, _)| id == artifact_id)
        .map(|(_, entry)| entry)
}

pub(crate) fn catalog_set(catalog: &mut Catalog, artifact_id: &str, entry: Dict) {
    match catalog.iter_mut().find(|(id, _)| id == artifact_id) {
        Some(slot) => slot.1 = entry,
        None => catalog.push((artifact_id.to_string(), entry)),
    }
}

fn tree_entry<'e>(entries: &'e Entries, path: &str) -> Option<&'e TreeEntry> {
    entries
        .iter()
        .find(|(name, _)| name == path)
        .map(|(_, entry)| entry)
}

fn is_true(entry: &Dict, key: &str) -> bool {
    matches!(entry.get(key), Some(Value::Bool(true)))
}

/// `ProjectNoteManager`.
pub struct ProjectNoteManager {
    pub store: Arc<ArtifactStore>,
    pub device_id: String,
}

impl ProjectNoteManager {
    pub fn new(store: Arc<ArtifactStore>, device_id: &str) -> Self {
        Self {
            store,
            device_id: device_id.to_string(),
        }
    }

    /// The store's writer lock around `work`, whose own errors pass through.
    fn locked<T>(&self, work: impl FnOnce() -> Result<T>) -> Result<T> {
        self.store.with_writer_lock(|| Ok(work()))?
    }

    fn snapshot_files(&self) -> Result<(String, Files)> {
        let snapshot = self.store.snapshot()?;
        Ok((snapshot.commit_id, snapshot.files))
    }

    /// `ensure_global_codes`: backfill stable public codes without changing
    /// saved or recoverable identities.
    pub fn ensure_global_codes(&self) -> Result<()> {
        self.locked(|| {
            let (head, files) = self.snapshot_files()?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            let mut missing: Vec<(String, String, String)> = catalog
                .iter()
                .filter(|(_, row)| !row.get("global_code").is_some_and(Value::truthy))
                .map(|(id, row)| (row.string("created_at"), row.string("note_id"), id.clone()))
                .collect();
            if missing.is_empty() {
                return Ok(());
            }
            let mut number = next_note_number(&config(&files)?, &files, &catalog)?;
            let mut used: Vec<String> = catalog
                .iter()
                .filter_map(|(_, row)| row.truthy("global_code").map(Value::py_str))
                .collect();
            missing.sort();
            for (_, note_id, artifact_id) in missing {
                let mut code = format!("N{}", validate_note_id(&note_id)?.1);
                if used.contains(&code) {
                    code = format!("N{number}");
                    number += 1;
                }
                let mut row = catalog_get(&catalog, &artifact_id).cloned().unwrap();
                row.insert("global_code", code.as_str());
                catalog_set(&mut catalog, &artifact_id, row);
                used.push(code);
            }
            let mut mutation = Mutation::new(
                &format!("global-note-codes:{head}"),
                "system",
                &self.device_id,
                vec![
                    Operation::ConfigWrite {
                        content: set_next_note_id(file(&files, CONFIG_PATH)?, number)?,
                    },
                    Operation::NoteIndexWrite {
                        content: encode_note_index(&catalog, &self.store.project_id)?,
                    },
                ],
            );
            mutation.expected_base = Some(head);
            mutation.summary = "Assign global note codes".to_string();
            self.store.mutate(&mutation)?;
            Ok(())
        })
    }

    /// `import_saved_note`: copy a legacy note atomically, including archived
    /// and recoverable content. The durable import event also keeps a deleted
    /// global note from coming back on the next migration sweep.
    pub fn import_saved_note(&self, source: &Dict, repository_path: Option<&str>) -> Result<()> {
        let original = NoteUpdate::from_mapping(source)?;
        let mut event_id = format!(
            "note-import:{}",
            digest(&Value::Dict(identity_dict(&original.identity)))
        );
        self.locked(|| {
            let prior_import = self.store.find_event(&event_id)?;
            let (head, files) = self.snapshot_files()?;
            let config = config(&files)?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            let existing = catalog_get(&catalog, &original.identity.artifact_id).cloned();
            let source_digest = digest(&Value::Dict(source.clone()));
            let creation_event_id = event_id.clone();
            if prior_import.is_some() {
                // Deletion is final. Completed imports are owned by the
                // global library; only an unfinished legacy recovery can
                // update a copy.
                match &existing {
                    None => return Ok(()),
                    Some(existing)
                        if existing
                            .get("recording_state")
                            .is_some_and(|state| state.is_str("completed"))
                            || existing
                                .get("creation_request_sha256")
                                .is_some_and(|sha| sha.is_str(&source_digest)) =>
                    {
                        return Ok(());
                    }
                    Some(_) => event_id = format!("note-import-update:{source_digest}"),
                }
            }
            let mut number = next_note_number(&config, &files, &catalog)?;
            let global_code = match &existing {
                Some(existing) => existing.get("global_code").cloned().unwrap_or(Value::Null),
                None => Value::Str(format!("N{number}")),
            };
            let mut note_id = match &existing {
                Some(existing) => existing.string("note_id"),
                None => original.identity.note_id.clone(),
            };
            if existing.is_none()
                && catalog
                    .iter()
                    .any(|(_, row)| row.string("note_id") == note_id)
            {
                note_id = format!("{}-N{number}", toml_text(config.get("prefix")));
            }
            number =
                (number + u64::from(existing.is_none())).max(validate_note_id(&note_id)?.1 + 1);
            let identity = NoteIdentity {
                note_id: note_id.clone(),
                project_id: self.store.project_id.clone(),
                ..original.identity.clone()
            };
            let update = NoteUpdate {
                identity: identity.clone(),
                ..original.clone()
            };
            let metadata = match source.present("metadata") {
                Some(metadata) => Some(validate_note_metadata(metadata)?),
                None => None,
            };
            let document = NoteDocument {
                identity: identity.clone(),
                update: update.clone(),
                metadata: metadata.clone(),
            };
            let mut entry = Dict::new();
            entry.insert("schema_version", NOTE_INDEX_SCHEMA_VERSION);
            entry.insert("global_code", global_code);
            entry.insert("note_id", note_id.as_str());
            entry.insert("artifact_id", identity.artifact_id.as_str());
            entry.insert("project_id", self.store.project_id.as_str());
            entry.insert("path", note_path(&note_id));
            entry.insert("created_at", identity.created_at.as_str());
            entry.insert("updated_at", update.captured_at.as_str());
            entry.insert("recording_state", update.recording_state.as_str());
            entry.insert("segment_count", update.segments.len() as i64);
            entry.insert("materialized", true);
            entry.insert("creation_event_id", creation_event_id.as_str());
            entry.insert("last_event_id", event_id.as_str());
            entry.insert("creation_request_sha256", source_digest.as_str());
            entry.insert("metadata", metadata);
            let recovery = match repository_path {
                Some(path) if !path.is_empty() && original.recording_state != "completed" => {
                    let mut recovery = Dict::new();
                    recovery.insert("repository_path", path);
                    recovery.insert("project_id", original.identity.project_id.as_str());
                    recovery.insert("note_id", original.identity.note_id.as_str());
                    Value::Dict(recovery)
                }
                _ => Value::Null,
            };
            entry.insert("legacy_recovery", recovery);
            catalog_set(&mut catalog, &identity.artifact_id, entry);
            let mut mutation = Mutation::new(
                &event_id,
                "system",
                &self.device_id,
                vec![
                    Operation::ConfigWrite {
                        content: set_next_note_id(file(&files, CONFIG_PATH)?, number)?,
                    },
                    Operation::NoteWrite {
                        note_id: note_id.clone(),
                        artifact_id: identity.artifact_id.clone(),
                        project_id: self.store.project_id.clone(),
                        markdown: render_note_document(&document)?,
                    },
                    Operation::NoteIndexWrite {
                        content: encode_note_index(&catalog, &self.store.project_id)?,
                    },
                ],
            );
            mutation.expected_base = Some(head);
            mutation.summary = format!("Import saved note {note_id} into global library");
            self.store.mutate(&mutation)?;
            Ok(())
        })
    }

    pub fn create(&self, request: &CreateNote) -> Result<Dict> {
        let event_id = event_id("create", &request.request_id)?;
        validate_provider(request.provider.as_deref())?;
        validate_timestamp(&request.created_at, "note created_at")?;
        validate_timestamp(&request.capture_started_at, "note capture_started_at")?;
        let raw_segments = validated_segment_payload(&request.segments)?;
        let request_digest = digest(&Value::Dict(request.payload(&raw_segments)));

        if let Some((commit, _)) = self.store.find_event(&event_id)? {
            self.store.recover()?;
            return self.prior_create(&event_id, &commit, &request_digest);
        }

        self.locked(|| {
            let (head, files) = self.snapshot_files()?;
            let config = config(&files)?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            if let Some((_, existing)) = catalog
                .iter()
                .find(|(_, entry)| entry.string("creation_event_id") == event_id)
            {
                if existing.string("creation_request_sha256") != request_digest {
                    return Err(collision(format!(
                        "note create request {} was already used with different content",
                        pystr::repr(&request.request_id)
                    )));
                }
                return self.read_entry(&head, existing, true);
            }

            let prefix = pystr::strip(&toml_text(config.get("prefix"))).to_string();
            if prefix.is_empty() || !prefix.chars().all(|c| c.is_ascii_alphanumeric()) {
                return Err(validation("artifact config has no valid note prefix"));
            }
            let number = next_note_number(&config, &files, &catalog)?;
            let note_id = format!("{prefix}-N{number}");
            let digest_text =
                sha256::hex_digest(format!("{}:{event_id}", self.store.project_id).as_bytes());
            let artifact_id = format!("note-{}", &digest_text[..40]);
            let identity = NoteIdentity {
                note_id: note_id.clone(),
                artifact_id: artifact_id.clone(),
                project_id: self.store.project_id.clone(),
                created_at: request.created_at.clone(),
                capture_started_at: request.capture_started_at.clone(),
            };
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
                identity,
                update,
                metadata: Some(metadata.clone()),
            };
            let path = note_path(&note_id);
            if files.iter().any(|(name, _)| *name == path)
                || catalog
                    .iter()
                    .any(|(_, entry)| entry.string("note_id") == note_id)
            {
                return Err(Error::new(
                    "ArtifactConcurrentUpdate",
                    format!("note display ID is already issued: {note_id}"),
                ));
            }
            let mut entry = Dict::new();
            entry.insert("schema_version", NOTE_INDEX_SCHEMA_VERSION);
            entry.insert("note_id", note_id.as_str());
            entry.insert("artifact_id", artifact_id.as_str());
            entry.insert("project_id", self.store.project_id.as_str());
            entry.insert("path", path.as_str());
            entry.insert("created_at", request.created_at.as_str());
            entry.insert("updated_at", request.captured_at.as_str());
            entry.insert("recording_state", request.recording_state.as_str());
            entry.insert("segment_count", document.update.segments.len() as i64);
            entry.insert("materialized", true);
            entry.insert("creation_event_id", event_id.as_str());
            entry.insert("last_event_id", event_id.as_str());
            entry.insert("creation_request_sha256", request_digest.as_str());
            entry.insert("metadata", metadata);
            if self.store.project_id == "global-notes" {
                entry.insert("global_code", format!("N{number}"));
            }
            catalog_set(&mut catalog, &artifact_id, entry);
            let config_bytes = set_next_note_id(file(&files, CONFIG_PATH)?, number + 1)?;
            let mut mutation = Mutation::new(
                &event_id,
                "user",
                &self.device_id,
                vec![
                    Operation::ConfigWrite {
                        content: config_bytes,
                    },
                    Operation::NoteWrite {
                        note_id: note_id.clone(),
                        artifact_id: artifact_id.clone(),
                        project_id: self.store.project_id.clone(),
                        markdown: render_note_document(&document)?,
                    },
                    Operation::NoteIndexWrite {
                        content: encode_note_index(&catalog, &self.store.project_id)?,
                    },
                ],
            );
            mutation.expected_base = Some(head);
            mutation.provider = request.provider.clone();
            mutation.summary = format!("Create Relay project note {note_id}");
            let write = self.store.mutate(&mutation)?;
            self.response(&document, &write.commit_id, write.idempotent, true, None)
        })
    }

    pub fn update(&self, request_id: &str, update: &Dict, provider: Option<&str>) -> Result<Dict> {
        let event_id = event_id("update", request_id)?;
        validate_provider(provider)?;
        let desired = parse_update(update)?;
        if let Some((commit, _)) = self.store.find_event(&event_id)? {
            self.store.recover()?;
            let document = self.document_at(&commit, &desired.identity.note_id)?;
            if document.update != desired {
                return Err(collision(format!(
                    "note update request {} was already used with different content",
                    pystr::repr(request_id)
                )));
            }
            let materialized = self.currently_materialized(&desired.identity.artifact_id)?;
            return self.response(&document, &commit, true, materialized, None);
        }

        for attempt in 0..4 {
            let (head, files) = self.snapshot_files()?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            let entry = entry_for_identity(&catalog, &desired.identity)?.clone();
            if !is_true(&entry, "materialized") {
                return Err(validation(format!(
                    "note {} is archived; restore it before updating",
                    desired.identity.note_id
                )));
            }
            let path = note_path(&desired.identity.note_id);
            let Some(content) = files.iter().find(|(name, _)| *name == path) else {
                return Err(validation(format!(
                    "materialized note is missing: {}",
                    desired.identity.note_id
                )));
            };
            let current = parse_document(&content.1)?;
            if current.identity != desired.identity {
                return Err(identity_error(
                    "note update cannot change immutable identity or project",
                ));
            }
            let metadata = metadata_for_update(&desired, current.metadata.as_ref());
            let document = NoteDocument {
                identity: current.identity.clone(),
                update: desired.clone(),
                metadata: Some(metadata.clone()),
            };
            let mut updated = entry.clone();
            updated.insert("updated_at", desired.captured_at.as_str());
            updated.insert("recording_state", desired.recording_state.as_str());
            updated.insert("segment_count", desired.segments.len() as i64);
            updated.insert("metadata", metadata);
            updated.insert("last_event_id", event_id.as_str());
            catalog_set(&mut catalog, &desired.identity.artifact_id, updated);
            let mut mutation = Mutation::new(
                &event_id,
                "user",
                &self.device_id,
                vec![
                    Operation::NoteWrite {
                        note_id: desired.identity.note_id.clone(),
                        artifact_id: desired.identity.artifact_id.clone(),
                        project_id: desired.identity.project_id.clone(),
                        markdown: render_note_document(&document)?,
                    },
                    Operation::NoteIndexWrite {
                        content: encode_note_index(&catalog, &self.store.project_id)?,
                    },
                ],
            );
            mutation.expected_base = Some(head);
            mutation.provider = provider.map(str::to_string);
            mutation.summary =
                format!("Checkpoint Relay project note {}", desired.identity.note_id);
            match self.store.mutate(&mutation) {
                Ok(write) => {
                    return self.response(
                        &document,
                        &write.commit_id,
                        write.idempotent,
                        true,
                        None,
                    );
                }
                Err(error) if error.kind == ErrorKind::ConcurrentUpdate && attempt < 3 => continue,
                Err(error) => return Err(error.into()),
            }
        }
        unreachable!("the last attempt returns")
    }

    /// `publish_metadata`: compare and publish under the same lock as
    /// transcript writes. A recorder never sends metadata and a metadata job
    /// never sends segments, so neither can erase the other.
    pub fn publish_metadata(
        &self,
        identity: &NoteIdentity,
        source_sha256: &str,
        metadata: &Dict,
        expected_metadata: Option<&Dict>,
    ) -> Result<bool> {
        let metadata = validate_note_metadata(&Value::Dict(metadata.clone()))?;
        self.locked(|| {
            let (head, files) = self.snapshot_files()?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            let Some(entry) = catalog_get(&catalog, &identity.artifact_id).cloned() else {
                return Ok(false);
            };
            if !entry.get("materialized").is_some_and(Value::truthy) {
                return Ok(false);
            }
            let path = note_path(&identity.note_id);
            let Some((_, content)) = files.iter().find(|(name, _)| *name == path) else {
                return Ok(false);
            };
            let current = parse_document(content)?;
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
                return Err(validation("metadata digest does not match its source"));
            }
            let document = NoteDocument {
                identity: identity.clone(),
                update: current.update.clone(),
                metadata: Some(metadata.clone()),
            };
            let event_id = event_id("metadata", &util::uuid4_hex())?;
            let mut updated = entry;
            updated.insert("metadata", metadata.clone());
            updated.insert("last_event_id", event_id.as_str());
            catalog_set(&mut catalog, &identity.artifact_id, updated);
            let mut mutation = Mutation::new(
                &event_id,
                "system",
                &self.device_id,
                vec![
                    Operation::NoteWrite {
                        note_id: identity.note_id.clone(),
                        artifact_id: identity.artifact_id.clone(),
                        project_id: identity.project_id.clone(),
                        markdown: render_note_document(&document)?,
                    },
                    Operation::NoteIndexWrite {
                        content: encode_note_index(&catalog, &self.store.project_id)?,
                    },
                ],
            );
            mutation.expected_base = Some(head);
            mutation.provider = metadata
                .get("provider")
                .and_then(Value::as_str)
                .map(str::to_string);
            mutation.summary = format!(
                "Update metadata for Relay project note {}",
                identity.note_id
            );
            self.store.mutate(&mutation)?;
            Ok(true)
        })
    }

    fn sync_state_file(&self) -> Dict {
        fs::read(self.store.project_state.join("sync-state.json"))
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .and_then(|text| json::parse(&text))
            .and_then(|value| value.as_dict().cloned())
            .unwrap_or_default()
    }

    fn require_archive_history_safe(&self, head: &str, files: &[(String, Vec<u8>)]) -> Result<()> {
        let mode = config_mode(&config(files)?);
        if mode == "local_only" {
            return Ok(());
        }
        let state = self.sync_state_file();
        if !(mode == "enabled"
            && state
                .get("state")
                .is_some_and(|state| state.is_str("clean"))
            && state
                .get("local_head")
                .is_some_and(|value| value.is_str(head))
            && state
                .get("remote_head")
                .is_some_and(|value| value.is_str(head)))
        {
            return Err(validation(
                "note archive requires a clean synchronized artifact head so its historical \
                 source commit remains remotely reachable; sync the project and retry",
            ));
        }
        Ok(())
    }

    /// `delete`: delete a saved note, or explicitly cancel an unfinished
    /// recording.
    pub fn delete(
        &self,
        note_id: &str,
        artifact_id: &str,
        request_id: &str,
        cancel_recording: bool,
    ) -> Result<Dict> {
        validate_note_id(note_id)?;
        let event_id = event_id(
            if cancel_recording { "cancel" } else { "delete" },
            request_id,
        )?;
        self.locked(|| {
            let (head, files) = self.snapshot_files()?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            let Some(entry) = catalog_get(&catalog, artifact_id).cloned() else {
                if catalog
                    .iter()
                    .any(|(_, row)| row.string("note_id") == note_id)
                {
                    return Err(identity_error(
                        "note delete identity does not match the catalog",
                    ));
                }
                return Ok(deleted());
            };
            if entry.string("note_id") != note_id {
                return Err(identity_error(
                    "note delete identity does not match the catalog",
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
            catalog.retain(|(id, _)| id != artifact_id);
            let mut operations = vec![Operation::NoteIndexWrite {
                content: encode_note_index(&catalog, &self.store.project_id)?,
            }];
            if is_true(&entry, "materialized") {
                operations.push(Operation::NoteDelete {
                    note_id: note_id.to_string(),
                    artifact_id: artifact_id.to_string(),
                });
            }
            let mut mutation = Mutation::new(&event_id, "user", &self.device_id, operations);
            mutation.expected_base = Some(head);
            mutation.summary = format!(
                "{} Relay project note {note_id}",
                if cancel_recording { "Cancel" } else { "Delete" }
            );
            self.store.mutate(&mutation)?;
            Ok(deleted())
        })
    }

    pub fn archive(
        &self,
        note_id: &str,
        artifact_id: &str,
        archived_at: &str,
        request_id: &str,
        provider: Option<&str>,
    ) -> Result<Dict> {
        validate_note_id(note_id)?;
        validate_timestamp(archived_at, "note archived_at")?;
        validate_provider(provider)?;
        let event_id = event_id("archive", request_id)?;
        if let Some((commit, _)) = self.store.find_event(&event_id)? {
            self.store.recover()?;
            let entries = self.catalog_at(&commit)?;
            let entry = catalog_get(&entries, artifact_id);
            let matches = entry.is_some_and(|entry| {
                entry
                    .get("note_id")
                    .is_some_and(|value| value.is_str(note_id))
                    && entry
                        .get("last_event_id")
                        .is_some_and(|value| value.is_str(&event_id))
                    && entry
                        .get("archived_at")
                        .is_some_and(|value| value.is_str(archived_at))
            });
            if !matches {
                return Err(collision(format!(
                    "note archive request {} was already used for another note",
                    pystr::repr(request_id)
                )));
            }
            let current = self
                .store
                .head()?
                .ok_or_else(|| validation("artifact store is not initialized"))?;
            return self.read_entry(&current, entry.unwrap(), true);
        }

        for attempt in 0..4 {
            let (head, files) = self.snapshot_files()?;
            self.require_archive_history_safe(&head, &files)?;
            let mut catalog = files_catalog(&files, &self.store.project_id)?;
            let entry = match catalog_get(&catalog, artifact_id) {
                Some(entry) if entry.get("note_id").is_some_and(|id| id.is_str(note_id)) => {
                    entry.clone()
                }
                _ => {
                    return Err(identity_error(
                        "note archive identity does not match the catalog",
                    ));
                }
            };
            if !is_true(&entry, "materialized") {
                return self.read_entry(&head, &entry, true);
            }
            let path = note_path(note_id);
            let Some((_, content)) = files.iter().find(|(name, _)| *name == path) else {
                return Err(validation(format!(
                    "materialized note is missing: {note_id}"
                )));
            };
            let document = parse_document(content)?;
            if document.identity.artifact_id != artifact_id {
                return Err(identity_error(
                    "note archive artifact_id does not match Markdown",
                ));
            }
            let entries = self.store.tree_entries(Some(&head))?;
            let blob = tree_entry(&entries, &path)
                .map(|entry| entry.oid.clone())
                .ok_or_else(|| Error::new("KeyError", pystr::repr(&path)))?;
            let mut archived = entry.clone();
            archived.insert("materialized", false);
            archived.insert("archived_at", archived_at);
            archived.insert("source_commit", head.as_str());
            archived.insert("source_blob", blob);
            archived.insert("last_event_id", event_id.as_str());
            catalog_set(&mut catalog, artifact_id, archived);
            let mut mutation = Mutation::new(
                &event_id,
                "user",
                &self.device_id,
                vec![
                    Operation::NoteIndexWrite {
                        content: encode_note_index(&catalog, &self.store.project_id)?,
                    },
                    Operation::NoteDelete {
                        note_id: note_id.to_string(),
                        artifact_id: artifact_id.to_string(),
                    },
                ],
            );
            mutation.expected_base = Some(head);
            mutation.provider = provider.map(str::to_string);
            mutation.summary = format!("Archive Relay project note {note_id}");
            match self.store.mutate(&mutation) {
                Ok(write) => {
                    return self.response(
                        &document,
                        &write.commit_id,
                        write.idempotent,
                        false,
                        None,
                    );
                }
                Err(error) if error.kind == ErrorKind::ConcurrentUpdate && attempt < 3 => continue,
                Err(error) => return Err(error.into()),
            }
        }
        unreachable!("the last attempt returns")
    }

    pub fn get(&self, identity: &str) -> Result<Dict> {
        let (head, files) = self.snapshot_files()?;
        let catalog = files_catalog(&files, &self.store.project_id)?;
        let matches: Vec<&Dict> = catalog
            .iter()
            .filter(|(artifact_id, entry)| {
                artifact_id == identity
                    || entry.get("note_id").is_some_and(|id| id.is_str(identity))
                    || entry
                        .get("global_code")
                        .is_some_and(|code| code.is_str(identity))
            })
            .map(|(_, entry)| entry)
            .collect();
        if matches.len() != 1 {
            return Err(validation(format!(
                "no unique project note matches {}",
                pystr::repr(identity)
            )));
        }
        self.read_entry(&head, matches[0], true)
    }

    pub fn list(&self, limit: i64, after: Option<&str>) -> Result<Dict> {
        if !(1..=NOTE_CATALOG_MAX_LIMIT).contains(&limit) {
            return Err(validation(format!(
                "note catalog limit must be between 1 and {NOTE_CATALOG_MAX_LIMIT}"
            )));
        }
        let (head, files) = self.snapshot_files()?;
        let catalog = files_catalog(&files, &self.store.project_id)?;
        let mut cards = Vec::new();
        for (_, entry) in &catalog {
            let reference = self.reference(&head, entry, false)?;
            cards.push(card(entry, reference));
        }
        let mut keyed = Vec::new();
        for card in cards {
            let number = validate_note_id(&card.string("note_id"))?.1;
            keyed.push((number, card.string("artifact_id"), card));
        }
        keyed.sort_by(|a, b| (a.0, &a.1).cmp(&(b.0, &b.1)));
        let cards: Vec<Dict> = keyed.into_iter().map(|(_, _, card)| card).collect();
        let mut start = 0;
        if let Some(after) = after.filter(|after| !after.is_empty()) {
            let matches: Vec<usize> = cards
                .iter()
                .enumerate()
                .filter(|(_, card)| card.get("note_id").is_some_and(|id| id.is_str(after)))
                .map(|(index, _)| index)
                .collect();
            if matches.len() != 1 {
                return Err(validation(format!(
                    "note catalog cursor does not match this project: {}",
                    pystr::repr(after)
                )));
            }
            start = matches[0] + 1;
        }
        let total_count = cards.len();
        let page: Vec<Dict> = cards.into_iter().skip(start).take(limit as usize).collect();
        let has_more = start + page.len() < total_count;
        let next_cursor = match page.last() {
            Some(last) if has_more => last.get("note_id").cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        };
        let mut result = Dict::new();
        result.insert(
            "notes",
            Value::List(page.into_iter().map(Value::Dict).collect()),
        );
        result.insert("artifact_commit", head.as_str());
        result.insert("limit", limit);
        result.insert("has_more", has_more);
        result.insert("next_cursor", next_cursor);
        result.insert("total_count", total_count as i64);
        result.insert("sync", self.sync_state(&head)?);
        Ok(result)
    }

    fn prior_create(&self, event_id: &str, commit_id: &str, request_digest: &str) -> Result<Dict> {
        let catalog = self.catalog_at(commit_id)?;
        let matches: Vec<&Dict> = catalog
            .iter()
            .filter(|(_, entry)| entry.string("creation_event_id") == event_id)
            .map(|(_, entry)| entry)
            .collect();
        if matches.len() != 1 || matches[0].string("creation_request_sha256") != request_digest {
            return Err(collision(
                "note create event was already committed with different content",
            ));
        }
        self.read_entry(commit_id, matches[0], true)
    }

    /// `_catalog_at`: the note index of one commit.
    pub fn catalog_at(&self, commit_id: &str) -> Result<Catalog> {
        let entries = self.store.tree_entries(Some(commit_id))?;
        let content = match tree_entry(&entries, INDEX_PATH) {
            Some(index) => self.store.cat_blob(&index.oid)?,
            None => Vec::new(),
        };
        decode_catalog(&content, &self.store.project_id)
    }

    fn document_at(&self, commit_id: &str, note_id: &str) -> Result<NoteDocument> {
        let entries = self.store.tree_entries(Some(commit_id))?;
        let Some(entry) = tree_entry(&entries, &note_path(note_id)) else {
            return Err(collision(
                "prior note update does not contain the requested note",
            ));
        };
        parse_document(&self.store.cat_blob(&entry.oid)?)
    }

    fn currently_materialized(&self, artifact_id: &str) -> Result<bool> {
        let (_, files) = self.snapshot_files()?;
        let catalog = files_catalog(&files, &self.store.project_id)?;
        Ok(catalog_get(&catalog, artifact_id).is_some_and(|entry| is_true(entry, "materialized")))
    }

    /// `_read_entry`: the verified note response for a catalog entry.
    pub fn read_entry(&self, head: &str, entry: &Dict, idempotent: bool) -> Result<Dict> {
        let note_id = entry.get("note_id").map(Value::py_str).unwrap_or_default();
        let reference = self.reference(head, entry, true)?;
        let head = reference.string("catalog_commit");
        let content = self.store.cat_blob(&reference.string("revision"))?;
        let materialized = is_true(entry, "materialized");
        let document = parse_document(&content)?;
        if document.identity.note_id != note_id
            || !entry
                .get("artifact_id")
                .is_some_and(|id| id.is_str(&document.identity.artifact_id))
            || document.identity.project_id != self.store.project_id
        {
            return Err(identity_error(
                "note catalog identity disagrees with verified Markdown",
            ));
        }
        self.response(&document, &head, idempotent, materialized, Some(reference))
    }

    fn reference(&self, head: &str, entry: &Dict, verify_history: bool) -> Result<Dict> {
        let note_id = entry.get("note_id").map(Value::py_str).unwrap_or_default();
        let path = note_path(&note_id);
        let (source_commit, source_blob, verified) = if is_true(entry, "materialized") {
            let entries = self.store.tree_entries(Some(head))?;
            let Some(found) = tree_entry(&entries, &path) else {
                return Err(validation(format!(
                    "materialized note is missing: {note_id}"
                )));
            };
            (head.to_string(), found.oid.clone(), true)
        } else {
            let source_commit = entry.string("source_commit");
            let source_blob = entry.string("source_blob");
            let mut verified = false;
            if verify_history {
                let ancestor = self.store.git(
                    &[
                        "merge-base",
                        "--is-ancestor",
                        &source_commit,
                        &self.store.artifact_ref,
                    ],
                    &[],
                    None,
                    &[0, 1, 128],
                )?;
                if ancestor.status != 0 {
                    return Err(validation("archived note source commit is not reachable"));
                }
                let historical = self.store.tree_entries(Some(&source_commit))?;
                if tree_entry(&historical, &path).is_none_or(|found| found.oid != source_blob) {
                    return Err(validation("archived note source reference is invalid"));
                }
                verified = true;
            }
            (source_commit, source_blob, verified)
        };
        let mut reference = Dict::new();
        reference.insert("path", path.as_str());
        reference.insert("artifact_ref", self.store.artifact_ref.as_str());
        reference.insert("commit", source_commit.as_str());
        reference.insert("revision", source_blob);
        reference.insert("history_reference", format!("{source_commit}:{path}"));
        reference.insert("verified", verified);
        reference.insert("catalog_commit", head);
        Ok(reference)
    }

    fn response(
        &self,
        document: &NoteDocument,
        commit_id: &str,
        idempotent: bool,
        materialized: bool,
        reference: Option<Dict>,
    ) -> Result<Dict> {
        let reference = match reference {
            Some(reference) => reference,
            None => {
                let catalog = self.catalog_at(commit_id)?;
                let Some(entry) = catalog_get(&catalog, &document.identity.artifact_id) else {
                    return Err(validation(format!(
                        "note catalog identity is missing: {}",
                        document.identity.note_id
                    )));
                };
                self.reference(commit_id, entry, true)?
            }
        };
        let markdown = render_note_document(document)?;
        let mut result = Dict::new();
        result.insert("note", document.as_dict());
        result.insert("markdown_base64", util::b64encode(&markdown));
        result.insert("materialized", materialized);
        result.insert("artifact_commit", commit_id);
        result.insert("reference", reference);
        result.insert("idempotent", idempotent);
        result.insert("sync", self.sync_state(commit_id)?);
        Ok(result)
    }

    fn sync_state(&self, head: &str) -> Result<Dict> {
        let current_head = self.store.head()?.unwrap_or_else(|| head.to_string());
        let entries = self.store.tree_entries(Some(&current_head))?;
        let Some(config_entry) = tree_entry(&entries, CONFIG_PATH) else {
            return Err(validation("artifact note config is missing"));
        };
        let files = vec![(
            CONFIG_PATH.to_string(),
            self.store.cat_blob(&config_entry.oid)?,
        )];
        let mode = config_mode(&config(&files)?);
        let mut state = Dict::new();
        state.insert("mode", mode.as_str());
        if mode == "local_only" {
            state.insert("state", "local_only");
            state.insert("recovery", Value::Null);
            return Ok(state);
        }
        if mode == "paused" {
            state.insert("state", "pending");
            state.insert("recovery", "Artifact sync is paused.");
            return Ok(state);
        }
        let cached = self.sync_state_file();
        let cached_state = cached.string("state");
        let normalized = if !cached
            .get("local_head")
            .is_some_and(|value| value.is_str(&current_head))
        {
            "pending"
        } else if cached_state == "clean"
            && cached
                .get("remote_head")
                .is_some_and(|value| value.is_str(&current_head))
        {
            "synced"
        } else if cached_state == "clean" || cached_state.is_empty() {
            "pending"
        } else if cached_state == "conflict" {
            "conflict"
        } else if [
            "ahead",
            "syncing",
            "retryable_offline",
            "retryable_auth",
            "remote_race",
        ]
        .contains(&cached_state.as_str())
        {
            "pending"
        } else {
            "failure"
        };
        state.insert("state", normalized);
        state.insert(
            "recovery",
            cached.get("recovery").cloned().unwrap_or(Value::Null),
        );
        Ok(state)
    }
}

impl NoteManager for ProjectNoteManager {
    fn project_id(&self) -> String {
        self.store.project_id.clone()
    }
    fn head(&self) -> Result<Option<String>> {
        Ok(self.store.head()?)
    }
    fn ensure_global_codes(&self) -> Result<()> {
        ProjectNoteManager::ensure_global_codes(self)
    }
    fn import_saved_note(&self, source: &Dict, repository_path: Option<&str>) -> Result<()> {
        ProjectNoteManager::import_saved_note(self, source, repository_path)
    }
    fn create(&self, request: &CreateNote) -> Result<Dict> {
        ProjectNoteManager::create(self, request)
    }
    fn update(&self, request_id: &str, update: &Dict, provider: Option<&str>) -> Result<Dict> {
        ProjectNoteManager::update(self, request_id, update, provider)
    }
    fn publish_metadata(
        &self,
        identity: &NoteIdentity,
        source_sha256: &str,
        metadata: &Dict,
        expected_metadata: Option<&Dict>,
    ) -> Result<bool> {
        ProjectNoteManager::publish_metadata(
            self,
            identity,
            source_sha256,
            metadata,
            expected_metadata,
        )
    }
    fn delete(
        &self,
        note_id: &str,
        artifact_id: &str,
        request_id: &str,
        cancel_recording: bool,
    ) -> Result<Dict> {
        ProjectNoteManager::delete(self, note_id, artifact_id, request_id, cancel_recording)
    }
    fn archive(
        &self,
        note_id: &str,
        artifact_id: &str,
        archived_at: &str,
        request_id: &str,
        provider: Option<&str>,
    ) -> Result<Dict> {
        ProjectNoteManager::archive(
            self,
            note_id,
            artifact_id,
            archived_at,
            request_id,
            provider,
        )
    }
    fn get(&self, identity: &str) -> Result<Dict> {
        ProjectNoteManager::get(self, identity)
    }
    fn list(&self, limit: i64, after: Option<&str>) -> Result<Dict> {
        ProjectNoteManager::list(self, limit, after)
    }
}

pub(crate) fn deleted() -> Dict {
    let mut result = Dict::new();
    result.insert("deleted", true);
    result
}

fn parse_update(value: &Dict) -> Result<NoteUpdate> {
    NoteUpdate::from_mapping(value).map_err(|error| validation(error.message))
}

pub(crate) fn note_update(
    identity: NoteIdentity,
    captured_at: &str,
    recording_state: &str,
    checkpoint_reason: &str,
    segments: &[Dict],
    capture_ended_at: Option<&str>,
) -> Result<NoteUpdate> {
    let segments = Value::List(segments.iter().cloned().map(Value::Dict).collect());
    NoteUpdate::from_values(
        identity,
        captured_at,
        recording_state,
        checkpoint_reason,
        &segments,
        capture_ended_at,
    )
    .map_err(|error| validation(error.message))
}

/// `_validated_segment_payload`: each segment in its canonical form.
pub(crate) fn validated_segment_payload(value: &Value) -> Result<Vec<Dict>> {
    let Some(items) = value.as_list() else {
        return Err(validation("note segments must be an array"));
    };
    let mut result = Vec::new();
    for raw in items {
        let Some(raw) = raw.as_dict() else {
            return Err(validation("each note segment must be an object"));
        };
        let segment = NoteSegment::from_mapping(raw).map_err(|error| validation(error.message))?;
        result.push(segment_dict(&segment));
    }
    Ok(result)
}

fn parse_document(content: &[u8]) -> Result<NoteDocument> {
    parse_note_document(content).map_err(|error| validation(error.message))
}

fn file<'f>(files: &'f [(String, Vec<u8>)], path: &str) -> Result<&'f [u8]> {
    files
        .iter()
        .find(|(name, _)| name == path)
        .map(|(_, content)| content.as_slice())
        .ok_or_else(|| Error::new("KeyError", pystr::repr(path)))
}

/// `_config`: the project's `config.toml`.
fn config(files: &[(String, Vec<u8>)]) -> Result<toml::Table> {
    let invalid = |detail: String| validation(format!("artifact note config is invalid: {detail}"));
    let content = file(files, CONFIG_PATH).map_err(|error| invalid(error.message))?;
    toml::loads_bytes(content).map_err(|error| invalid(error.message))
}

/// `str(value or "")` for a TOML value.
fn toml_text(value: Option<&toml::Value>) -> String {
    match value {
        Some(toml::Value::String(text)) => text.clone(),
        Some(toml::Value::Integer(number)) if *number != 0 => number.to_string(),
        Some(toml::Value::BigInteger(digits)) => digits.clone(),
        Some(toml::Value::Boolean(true)) => "True".to_string(),
        _ => String::new(),
    }
}

fn config_mode(config: &toml::Table) -> String {
    let mode = toml_text(config.get("remote_sync"));
    if mode.is_empty() {
        "local_only".to_string()
    } else {
        mode
    }
}

fn files_catalog(files: &[(String, Vec<u8>)], project_id: &str) -> Result<Catalog> {
    let content = files
        .iter()
        .find(|(name, _)| name == INDEX_PATH)
        .map(|(_, content)| content.as_slice())
        .unwrap_or_default();
    decode_catalog(content, project_id)
}

fn decode_catalog(content: &[u8], project_id: &str) -> Result<Catalog> {
    decode_note_index(content, project_id).map_err(|error| validation(error.message))
}

/// `_next_note_number`.
fn next_note_number(
    config: &toml::Table,
    files: &[(String, Vec<u8>)],
    catalog: &Catalog,
) -> Result<u64> {
    let configured = match config.get("next_note_id") {
        None => 1,
        Some(toml::Value::Integer(number)) if *number > 0 => *number as u64,
        Some(_) => {
            return Err(validation(
                "artifact config next_note_id must be a positive integer",
            ));
        }
    };
    let mut issued = Vec::new();
    for (_, entry) in catalog {
        issued.push(validate_note_id(&entry.string("note_id"))?.1);
    }
    for (path, _) in files {
        if let Some(name) = path.strip_prefix(".orchestrator/notes/")
            && path.ends_with(".md")
        {
            let stem = name.rsplit('/').next().unwrap_or(name);
            let stem = stem.strip_suffix(".md").unwrap_or(stem);
            issued.push(validate_note_id(stem)?.1);
        }
    }
    Ok(configured.max(issued.into_iter().max().unwrap_or(0) + 1))
}

/// `_set_next_note_id`: the first `next_note_id = …` line, or a new last one.
fn set_next_note_id(content: &[u8], next_note_id: u64) -> Result<Vec<u8>> {
    let text =
        std::str::from_utf8(content).map_err(|_| validation("artifact config is not UTF-8"))?;
    let line = format!("next_note_id = {next_note_id}");
    let rendered = match NEXT_NOTE_ID.find(text).ok().flatten() {
        Some(found) => format!("{}{line}{}", &text[..found.start()], &text[found.end()..]),
        None => format!("{}\n{line}\n", text.trim_end_matches('\n')),
    };
    Ok(rendered.into_bytes())
}

fn entry_for_identity<'c>(catalog: &'c Catalog, identity: &NoteIdentity) -> Result<&'c Dict> {
    match catalog_get(catalog, &identity.artifact_id) {
        Some(entry)
            if entry
                .get("note_id")
                .is_some_and(|id| id.is_str(&identity.note_id))
                && entry
                    .get("project_id")
                    .is_some_and(|id| id.is_str(&identity.project_id)) =>
        {
            Ok(entry)
        }
        _ => Err(identity_error(
            "note identity does not match the project catalog",
        )),
    }
}

/// `_card`: a catalog entry as the list routes show it.
pub(crate) fn card(entry: &Dict, reference: Dict) -> Dict {
    let field = |key: &str| entry.get(key).cloned().unwrap_or(Value::Null);
    let mut card = Dict::new();
    for key in [
        "note_id",
        "artifact_id",
        "project_id",
        "created_at",
        "updated_at",
        "recording_state",
        "segment_count",
        "materialized",
        "archived_at",
    ] {
        card.insert(key, field(key));
    }
    card.insert("reference", reference);
    for key in ["metadata", "legacy_recovery", "global_code"] {
        card.insert(key, field(key));
    }
    card
}

pub(crate) fn note_path(note_id: &str) -> String {
    format!(".orchestrator/notes/{note_id}.md")
}

/// `_event_id`.
pub(crate) fn event_id(kind: &str, request_id: &str) -> Result<String> {
    let raw = json::py_strip(request_id);
    let valid = (1..=120).contains(&raw.len())
        && raw
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-'));
    if !valid {
        return Err(validation(
            "note request_id must be 1 to 120 safe characters",
        ));
    }
    Ok(format!("note-{kind}:{raw}"))
}

/// `_digest`: SHA-256 of sorted compact JSON.
pub(crate) fn digest(value: &Value) -> String {
    sha256::hex_digest(json::dumps_compact_sorted_unicode(value).as_bytes())
}

/// `_validate_provider`.
pub(crate) fn validate_provider(provider: Option<&str>) -> Result<()> {
    match provider {
        None | Some("codex") | Some("claude") => Ok(()),
        Some(other) => Err(validation(format!(
            "unsupported provider metadata: {}",
            pystr::repr(other)
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_note_id_line_is_replaced_or_added() {
        assert_eq!(
            set_next_note_id(b"prefix = \"RR\"\nnext_note_id = 3\nx = 1\n", 9).unwrap(),
            b"prefix = \"RR\"\nnext_note_id = 9\nx = 1\n"
        );
        assert_eq!(
            set_next_note_id(b"prefix = \"RR\"\n\n", 2).unwrap(),
            b"prefix = \"RR\"\nnext_note_id = 2\n"
        );
    }

    #[test]
    fn request_ids_and_providers() {
        assert_eq!(event_id("create", " c-1 ").unwrap(), "note-create:c-1");
        assert_eq!(
            event_id("create", "").unwrap_err().message,
            "note request_id must be 1 to 120 safe characters"
        );
        assert_eq!(
            validate_provider(Some("gemini")).unwrap_err().message,
            "unsupported provider metadata: 'gemini'"
        );
    }
}
