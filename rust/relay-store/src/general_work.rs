//! `general/work.db`: the task ledger of `GeneralWorkStore` in
//! `services/general_work.py`. Each task is one JSON document; every change
//! appends an event. Running, reviewing and cancelling a task's worker are
//! the execution part of the port; they build on [`GeneralWorkStore::update`].

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::Connection;

use relay_intents::json;
use relay_intents::sha256::hex_digest;

use crate::sql::{self, int, opt_text, real, text};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA: &str = "
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
                    request_hash TEXT NOT NULL, document TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL,
                    run_id TEXT, kind TEXT NOT NULL, at REAL NOT NULL, detail TEXT NOT NULL);
            ";

/// The error a run interrupted by a restart carries.
pub const INTERRUPTED_ERROR: &str =
    "Relay Runner restarted. Review preserved files and explicitly retry; no action was replayed.";

const TIMEOUT: Duration = Duration::from_secs(15);

pub struct GeneralWorkStore {
    root: PathBuf,
    path: PathBuf,
    lock: std::sync::Mutex<()>,
}

impl GeneralWorkStore {
    /// Opens `<state root>/general/work.db`, creating `general/` and
    /// `files/tasks/`. A task still `in_progress` was interrupted by a
    /// restart: its last run and the task become `interrupted`.
    pub fn open(state_root: &Path) -> Result<Self> {
        let root = PathBuf::from(sql::resolve_path(&state_root.to_string_lossy()));
        let state = root.join("general");
        fs::create_dir_all(&state)?;
        fs::create_dir_all(root.join("files").join("tasks"))?;
        let store = Self {
            path: state.join("work.db"),
            root,
            lock: std::sync::Mutex::new(()),
        };
        store.connect(|db| {
            db.execute_batch(SCHEMA)?;
            let documents = sql::rows(db, "SELECT document FROM tasks", &[])?;
            for row in documents {
                let mut task = document(&row)?;
                if sql::field_str(&task, "status") != "in_progress" {
                    continue;
                }
                let mut run_id = Value::Null;
                if let Some(Value::List(runs)) = task.get("runs").cloned() {
                    let mut runs = runs;
                    if let Some(Value::Dict(run)) = runs.last_mut() {
                        run.insert("state", "interrupted");
                        run.insert("ended_at", sql::now());
                        run.insert("error", INTERRUPTED_ERROR);
                        run_id = run.get("id").cloned().unwrap_or(Value::Null);
                    }
                    task.insert("runs", Value::List(runs));
                }
                task.insert("status", "interrupted");
                save(db, &mut task, "interrupted", &run_id, None)?;
            }
            Ok(())
        })?;
        Ok(store)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `_connect`: a connection in WAL mode, `work` in one transaction.
    fn connect<T>(&self, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let db = sql::connect(&self.path, TIMEOUT)?;
        db.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
        sql::transaction(&db, "BEGIN", || work(&db))
    }

    fn locked<T>(&self, work: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let _guard = self
            .lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.connect(work)
    }

    /// Creates a backlog task, idempotent on `request_id`:
    /// `{"task": …, "idempotent": …}`.
    pub fn create(
        &self,
        title: &str,
        description: &str,
        acceptance_criteria: &[String],
        request_id: &str,
    ) -> Result<Dict> {
        if [title, description, request_id]
            .iter()
            .any(|value| json::py_strip(value).is_empty())
        {
            return Err(Error::invalid(
                "title, description and request_id are required",
            ));
        }
        if acceptance_criteria.is_empty()
            || acceptance_criteria
                .iter()
                .any(|value| json::py_strip(value).is_empty())
        {
            return Err(Error::invalid(
                "Provide at least one actionable acceptance criterion",
            ));
        }
        if title.chars().count() > 200
            || description.chars().count() > 50000
            || acceptance_criteria.len() > 50
        {
            return Err(Error::invalid("General task description is too large"));
        }
        let mut payload = Dict::new();
        payload.insert("title", json::py_strip(title));
        payload.insert("description", json::py_strip(description));
        payload.insert(
            "acceptance_criteria",
            Value::List(
                acceptance_criteria
                    .iter()
                    .map(|value| Value::Str(json::py_strip(value).to_string()))
                    .collect(),
            ),
        );
        let digest = hex_digest(json::dumps_sorted(&Value::Dict(payload.clone())).as_bytes());
        self.locked(|db| {
            if let Some(row) = sql::row(
                db,
                "SELECT request_hash,document FROM tasks WHERE request_id=?",
                &[text(request_id)],
            )? {
                if sql::field_str(&row, "request_hash") != digest {
                    return Err(Error::invalid(
                        "request_id already belongs to a different General task",
                    ));
                }
                return Ok(result("task", document(&row)?, true));
            }
            let mut task = Dict::new();
            task.insert("id", format!("GEN-{}", sql::random_hex16()?.to_uppercase()));
            task.insert("scope", "general");
            task.insert("status", "backlog");
            task.insert("created_at", sql::now());
            task.insert("updated_at", sql::now());
            task.insert("runs", Value::List(Vec::new()));
            task.update(&payload);
            sql::execute(
                db,
                "INSERT INTO tasks VALUES(?,?,?,?)",
                &[
                    text(sql::field_str(&task, "id")),
                    text(request_id),
                    text(&digest),
                    text(json::dumps(&Value::Dict(task.clone()))),
                ],
            )?;
            save(db, &mut task, "created", &Value::Null, None)?;
            Ok(result("task", task, false))
        })
    }

    /// `{"tasks": …, "total_count": …, "scope": "general"}`, most recently
    /// updated first; `limit` is held to 1–500.
    pub fn list(&self, limit: i64) -> Result<Dict> {
        let limit = limit.clamp(1, 500) as usize;
        let mut tasks = self.locked(|db| {
            sql::rows(db, "SELECT document FROM tasks", &[])?
                .iter()
                .map(document)
                .collect::<Result<Vec<_>>>()
        })?;
        let updated = |task: &Dict| {
            task.get("updated_at")
                .and_then(Value::py_float)
                .unwrap_or(0.0)
        };
        tasks.sort_by(|a, b| {
            updated(b)
                .partial_cmp(&updated(a))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let total = tasks.len() as i64;
        tasks.truncate(limit);
        let mut listing = Dict::new();
        listing.insert(
            "tasks",
            Value::List(tasks.into_iter().map(Value::Dict).collect()),
        );
        listing.insert("total_count", total);
        listing.insert("scope", "general");
        Ok(listing)
    }

    /// `{"task": …, "events": […]}`.
    pub fn get(&self, task_id: &str) -> Result<Dict> {
        self.locked(|db| {
            let task = load(db, task_id)?;
            let events = sql::rows(
                db,
                "SELECT seq,run_id,kind,at,detail FROM events WHERE task_id=? ORDER BY seq",
                &[text(task_id)],
            )?
            .iter()
            .map(|row| {
                let mut event = Dict::new();
                event.insert("sequence", row.get("seq").cloned().unwrap_or(Value::Null));
                event.insert("run_id", row.get("run_id").cloned().unwrap_or(Value::Null));
                event.insert("kind", row.get("kind").cloned().unwrap_or(Value::Null));
                event.insert("at", row.get("at").cloned().unwrap_or(Value::Null));
                event.insert(
                    "detail",
                    sql::loads(sql::field_str(row, "detail"), "detail")?,
                );
                Ok(Value::Dict(event))
            })
            .collect::<Result<Vec<_>>>()?;
            let mut found = result("task", task, false);
            found.remove("idempotent");
            found.insert("events", Value::List(events));
            Ok(found)
        })
    }

    /// Loads a task, lets `change` edit it, and saves it with an event of
    /// `change`'s returned kind, run id and detail, in one transaction.
    pub fn update<T>(
        &self,
        task_id: &str,
        change: impl FnOnce(&mut Dict) -> Result<(String, Value, Option<Dict>, T)>,
    ) -> Result<(Dict, T)> {
        self.locked(|db| {
            let mut task = load(db, task_id)?;
            let (kind, run_id, detail, value) = change(&mut task)?;
            save(db, &mut task, &kind, &run_id, detail.as_ref())?;
            Ok((task, value))
        })
    }
}

fn result(key: &str, task: Dict, idempotent: bool) -> Dict {
    let mut wrapped = Dict::new();
    wrapped.insert(key, Value::Dict(task));
    wrapped.insert("idempotent", idempotent);
    wrapped
}

fn document(row: &Dict) -> Result<Dict> {
    match sql::loads(sql::field_str(row, "document"), "document")? {
        Value::Dict(task) => Ok(task),
        _ => Err(Error::invalid("General task document is not an object")),
    }
}

/// `_load`.
fn load(db: &Connection, task_id: &str) -> Result<Dict> {
    let row = sql::row(
        db,
        "SELECT document FROM tasks WHERE id=?",
        &[text(task_id)],
    )?
    .ok_or_else(|| Error::invalid("General task not found"))?;
    document(&row)
}

/// `_save`: stamps `updated_at`, rewrites the document and appends an event.
fn save(
    db: &Connection,
    task: &mut Dict,
    kind: &str,
    run_id: &Value,
    detail: Option<&Dict>,
) -> Result<()> {
    let at = sql::now();
    task.insert("updated_at", at);
    let id = sql::field_str(task, "id").to_string();
    sql::execute(
        db,
        "UPDATE tasks SET document=? WHERE id=?",
        &[text(json::dumps(&Value::Dict(task.clone()))), text(&id)],
    )?;
    let run_id = match run_id {
        Value::Null => opt_text(None::<&str>),
        Value::Int(number) => int(*number),
        other => text(other.py_str()),
    };
    let detail = detail.cloned().unwrap_or_default();
    sql::execute(
        db,
        "INSERT INTO events(task_id,run_id,kind,at,detail) VALUES(?,?,?,?,?)",
        &[
            text(&id),
            run_id,
            text(kind),
            real(at),
            text(json::dumps(&Value::Dict(detail))),
        ],
    )?;
    Ok(())
}
