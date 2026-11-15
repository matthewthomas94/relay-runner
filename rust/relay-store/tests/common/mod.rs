//! Shared by the integration tests: temporary data roots, the repository's
//! fixtures, the schema of a database file and earlier schema versions.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use rusqlite::Connection;

/// The repository root (this crate is `rust/relay-store`).
pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repository root")
}

pub fn fixtures(release: &str) -> PathBuf {
    repo_root()
        .join("tests/contract/fixtures/orchestrator")
        .join(release)
}

/// A directory removed on drop. Its `orchestrator/` child is a data root
/// whose parent is the state root, as installed.
pub struct TempRoot {
    pub path: PathBuf,
}

impl TempRoot {
    pub fn new(label: &str) -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "relay-store-{label}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("orchestrator")).expect("temporary root");
        Self {
            path: path.canonicalize().expect("canonical temporary root"),
        }
    }

    pub fn data_root(&self) -> PathBuf {
        self.path.join("orchestrator")
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// `user_version`, and each table's columns, of a database file.
#[derive(Debug, PartialEq)]
pub struct Schema {
    pub user_version: i64,
    pub tables: Vec<(String, Vec<String>)>,
}

pub fn schema(path: &Path) -> Schema {
    let connection = Connection::open(path).expect("open database");
    let user_version = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("user_version");
    let names: Vec<String> = connection
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let tables = names
        .into_iter()
        .map(|name| {
            let columns = relay_store::sql::table_columns(&connection, &name).unwrap();
            (name, columns)
        })
        .collect();
    Schema {
        user_version,
        tables,
    }
}

/// Every schema object of a database file, as SQLite stored its text.
pub fn master(path: &Path) -> Vec<(String, String, String, Option<String>)> {
    let connection = Connection::open(path).expect("open database");
    connection
        .prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
        .unwrap()
        .query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// Version-4 `runs`: no `execution_mode` column yet.
pub const RUNS_V4: &str = "
    CREATE TABLE runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_id TEXT NOT NULL, repo_path TEXT NOT NULL,
        workspace_path TEXT NOT NULL, branch TEXT NOT NULL, state TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1, pid INTEGER, started_at REAL NOT NULL, ended_at REAL,
        exit_code INTEGER, log_path TEXT, last_error TEXT, activity TEXT, activity_at REAL,
        provider_key TEXT, model_alias TEXT, worker_model TEXT, worker_effort TEXT,
        worker_sizing_rationale TEXT, worker_provider_notes TEXT
    );
    INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, state, started_at, last_error)
        VALUES ('OLD-1', '/repo', '/ws', 'relay/old-1', 'Merged', 1.5, 'stale error');
    PRAGMA user_version = 4;
";

/// Version-2 `orchestrator_commands`: one row per command, no intent ids.
pub const COMMANDS_V2: &str = "CREATE TABLE orchestrator_commands (
                id INTEGER PRIMARY KEY AUTOINCREMENT, relay_command_id TEXT NOT NULL UNIQUE,
                relay_command_seq INTEGER NOT NULL, session_id INTEGER, repo_path TEXT NOT NULL,
                provider_key TEXT, source_text TEXT NOT NULL, action TEXT, outcome TEXT,
                status TEXT NOT NULL, received_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            INSERT INTO orchestrator_commands(relay_command_id, relay_command_seq, repo_path,
                source_text, status, created_at, updated_at)
                VALUES ('cmd-1', 1, '/repo', 'old command', 'received', 1.0, 2.0);
            PRAGMA user_version = 2;";

/// Version-1 `messenger_outcomes`: no session routing yet.
pub const OUTCOMES_V1: &str = "CREATE TABLE messenger_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT, event_key TEXT NOT NULL UNIQUE,
                repo_path TEXT NOT NULL, provider_key TEXT, kind TEXT NOT NULL, ticket_id TEXT,
                run_id INTEGER, message TEXT NOT NULL, payload_json TEXT NOT NULL,
                created_at REAL NOT NULL, delivered_at REAL,
                delivery_attempts INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO messenger_outcomes(event_key, repo_path, kind, message, payload_json, created_at)
                VALUES ('k', '/repo', 'run-merged', 'merged', 'not json', 1.0);
            PRAGMA user_version = 1;";
