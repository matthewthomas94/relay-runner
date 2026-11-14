//! `personal-storage/catalog.sqlite3`: the catalog behind
//! `PersonalFileStorage` (`services/personal_file_storage.py`) and the note
//! tables `PersonalNoteManager` adds to it (`services/personal_notes.py`).
//!
//! This is the row layer only: settings, file identities, their content
//! versions, note entries and note events. Writing the files themselves,
//! the GitHub sync and the note rules are a later part of the port.

use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

use relay_intents::json;

use crate::sql::{self, DEFAULT_TIMEOUT, Db, int, opt_text, real, text};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA: &str = "
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files(
              artifact_id TEXT PRIMARY KEY, logical_path TEXT NOT NULL UNIQUE, category TEXT NOT NULL,
              current_sha TEXT NOT NULL, metadata TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
              active INTEGER NOT NULL DEFAULT 0, approved INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS versions(
              artifact_id TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, local_path TEXT,
              remote_repo TEXT, remote_commit TEXT, remote_blob TEXT, accessed REAL NOT NULL,
              PRIMARY KEY(artifact_id,sha256));
        ";

pub const NOTE_ENTRIES_TABLE: &str = "CREATE TABLE IF NOT EXISTS personal_notes(artifact_id TEXT PRIMARY KEY, entry TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)";
pub const NOTE_EVENTS_TABLE: &str = "CREATE TABLE IF NOT EXISTS personal_note_events(event_id TEXT PRIMARY KEY, digest TEXT NOT NULL, artifact_id TEXT NOT NULL, revision TEXT NOT NULL)";

/// A file identity's current content, as `PersonalFileStorage.put` records it.
#[derive(Clone, Debug, Default)]
pub struct FileVersion {
    pub artifact_id: String,
    pub logical_path: String,
    pub category: String,
    pub sha256: String,
    pub size: i64,
    pub metadata: Dict,
    pub active: bool,
    /// `None` keeps the identity's approval.
    pub approved: Option<bool>,
    /// The cached copy, relative to the state root.
    pub local_path: Option<String>,
    /// When the row was written (`clock()`).
    pub at: f64,
}

pub struct PersonalCatalog {
    db: Db,
}

impl PersonalCatalog {
    /// Opens `<state root>/personal-storage/catalog.sqlite3` (the directory
    /// owner-only, the database `0600`) in WAL mode.
    pub fn open(state_root: &Path) -> Result<Self> {
        let support =
            PathBuf::from(sql::resolve(&state_root.to_string_lossy())).join("personal-storage");
        if support
            .symlink_metadata()
            .is_ok_and(|metadata| metadata.file_type().is_symlink())
        {
            return Err(Error::invalid(
                "Personal storage folders must not be symbolic links.",
            ));
        }
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&support)?;
        let path = support.join("catalog.sqlite3");
        let store = Self {
            db: Db::open(&path, DEFAULT_TIMEOUT)?,
        };
        store.db.with(|c| {
            c.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
            c.execute_batch(SCHEMA)?;
            Ok(())
        })?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        Ok(store)
    }

    pub fn path(&self) -> &Path {
        &self.db.path
    }

    /// The note tables, as `PersonalNoteManager` creates them on first use.
    pub fn ensure_note_tables(&self) -> Result<()> {
        self.db.with(|c| {
            c.execute_batch(NOTE_ENTRIES_TABLE)?;
            c.execute_batch(NOTE_EVENTS_TABLE)?;
            Ok(())
        })
    }

    /// `_get`: a JSON setting.
    pub fn setting(&self, key: &str) -> Result<Option<Value>> {
        self.db.with(|c| {
            match sql::row(c, "SELECT value FROM settings WHERE key=?", &[text(key)])? {
                Some(row) => sql::loads(sql::field_str(&row, "value"), "setting").map(Some),
                None => Ok(None),
            }
        })
    }

    /// `_set`.
    pub fn set_setting(&self, key: &str, value: &Value) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "INSERT OR REPLACE INTO settings VALUES(?,?)",
                &[text(key), text(json::dumps(value))],
            )?;
            Ok(())
        })
    }

    pub fn file(&self, artifact_id: &str) -> Result<Option<Dict>> {
        self.db.with(|c| {
            sql::row(
                c,
                "SELECT * FROM files WHERE artifact_id=?",
                &[text(artifact_id)],
            )
        })
    }

    pub fn files(&self) -> Result<Vec<Dict>> {
        self.db
            .with(|c| sql::rows(c, "SELECT * FROM files ORDER BY updated DESC", &[]))
    }

    pub fn versions(&self, artifact_id: &str) -> Result<Vec<Dict>> {
        self.db.with(|c| {
            sql::rows(
                c,
                "SELECT * FROM versions WHERE artifact_id=? ORDER BY accessed",
                &[text(artifact_id)],
            )
        })
    }

    /// Records a file identity's new current version, keeping its pin and,
    /// unless `approved` says, its approval. An identity cannot change its
    /// path or category.
    pub fn put_version(&self, version: &FileVersion) -> Result<()> {
        self.db.with(|c| {
            sql::transaction(c, "BEGIN", || {
                let prior = sql::row(
                    c,
                    "SELECT * FROM files WHERE artifact_id=?",
                    &[text(&version.artifact_id)],
                )?;
                if let Some(prior) = &prior
                    && (sql::field_str(prior, "logical_path") != version.logical_path
                        || sql::field_str(prior, "category") != version.category)
                    {
                        return Err(Error::invalid(
                            "Personal file identity cannot change its path or category",
                        ));
                    }
                let flag = |key: &str| {
                    prior
                        .as_ref()
                        .and_then(|prior| sql::field_int(prior, key))
                        .unwrap_or(0)
                };
                let approved = match version.approved {
                    Some(approved) => i64::from(approved),
                    None => i64::from(flag("approved") != 0),
                };
                sql::execute(
                    c,
                    "INSERT INTO files VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(artifact_id) DO UPDATE SET
                current_sha=excluded.current_sha,metadata=excluded.metadata,active=excluded.active,
                approved=excluded.approved,updated=excluded.updated",
                    &[
                        text(&version.artifact_id),
                        text(&version.logical_path),
                        text(&version.category),
                        text(&version.sha256),
                        text(json::dumps(&Value::Dict(version.metadata.clone()))),
                        int(flag("pinned")),
                        int(i64::from(version.active)),
                        int(approved),
                        real(version.at),
                    ],
                )?;
                sql::execute(
                    c,
                    "INSERT INTO versions VALUES(?,?,?,?,NULL,NULL,NULL,?) ON CONFLICT(artifact_id,sha256)
                DO UPDATE SET local_path=excluded.local_path,accessed=excluded.accessed",
                    &[
                        text(&version.artifact_id),
                        text(&version.sha256),
                        int(version.size),
                        opt_text(version.local_path.as_ref()),
                        real(version.at),
                    ],
                )?;
                Ok(())
            })
        })
    }

    pub fn set_pinned(&self, artifact_id: &str, pinned: bool) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE files SET pinned=? WHERE artifact_id=?",
                &[int(i64::from(pinned)), text(artifact_id)],
            )?;
            Ok(())
        })
    }

    /// A note's catalog entry and whether it is deleted.
    pub fn note_entry(&self, artifact_id: &str) -> Result<Option<(Value, bool)>> {
        self.db.with(|c| {
            match sql::row(
                c,
                "SELECT entry,deleted FROM personal_notes WHERE artifact_id=?",
                &[text(artifact_id)],
            )? {
                Some(row) => Ok(Some((
                    sql::loads(sql::field_str(&row, "entry"), "entry")?,
                    sql::field_int(&row, "deleted").unwrap_or(0) != 0,
                ))),
                None => Ok(None),
            }
        })
    }

    /// Every live note entry.
    pub fn note_entries(&self) -> Result<Vec<Value>> {
        self.db.with(|c| {
            sql::rows(c, "SELECT entry FROM personal_notes WHERE deleted=0", &[])?
                .iter()
                .map(|row| sql::loads(sql::field_str(row, "entry"), "entry"))
                .collect()
        })
    }

    pub fn save_note_entry(&self, artifact_id: &str, entry: &Dict, deleted: bool) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "INSERT OR REPLACE INTO personal_notes VALUES(?,?,?)",
                &[
                    text(artifact_id),
                    text(json::dumps(&Value::Dict(entry.clone()))),
                    int(i64::from(deleted)),
                ],
            )?;
            Ok(())
        })
    }

    pub fn delete_note(&self, artifact_id: &str) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE personal_notes SET deleted=1 WHERE artifact_id=?",
                &[text(artifact_id)],
            )?;
            Ok(())
        })
    }

    /// A note event: `{event_id, digest, artifact_id, revision}`.
    pub fn note_event(&self, event_id: &str) -> Result<Option<Dict>> {
        self.db.with(|c| {
            sql::row(
                c,
                "SELECT * FROM personal_note_events WHERE event_id=?",
                &[text(event_id)],
            )
        })
    }

    /// Records a note event once; returns whether it was new.
    pub fn insert_note_event(
        &self,
        event_id: &str,
        digest: &str,
        artifact_id: &str,
        revision: &str,
    ) -> Result<bool> {
        self.db.with(|c| {
            let inserted = sql::execute(
                c,
                "INSERT OR IGNORE INTO personal_note_events VALUES(?,?,?,?)",
                &[
                    text(event_id),
                    text(digest),
                    text(artifact_id),
                    text(revision),
                ],
            )?;
            Ok(inserted == 1)
        })
    }
}
