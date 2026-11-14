//! `runs.db` and the `runs.json` board index: `RunsStore` in
//! `services/orchestrator.py`.

use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use rusqlite::types::Value as Sql;

use crate::sql::{
    self, DEFAULT_TIMEOUT, Db, field_int, field_str, int, opt_text, placeholders, real,
    resolve_path, text,
};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA_VERSION: i64 = 5;

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticket_id TEXT NOT NULL,
        repo_path TEXT NOT NULL,
        workspace_path TEXT NOT NULL,
        branch TEXT NOT NULL,
        execution_mode TEXT NOT NULL DEFAULT 'implementation',
        state TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        pid INTEGER,
        started_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER,
        log_path TEXT,
        last_error TEXT,
        activity TEXT,
        activity_at REAL,
        provider_key TEXT,
        model_alias TEXT,
        worker_model TEXT,
        worker_effort TEXT,
        worker_sizing_rationale TEXT,
        worker_provider_notes TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_runs_state ON runs(state);
    CREATE INDEX IF NOT EXISTS idx_runs_ticket ON runs(ticket_id);
    ";

pub const ACTIVE_STATES: [&str; 3] = ["Claimed", "Running", "SpikeResultReady"];
pub const VERIFICATION_BLOCKED_RUN_STATE: &str = "VerificationBlocked";
pub const INTEGRATION_BLOCKED_RUN_STATE: &str = "IntegrationBlocked";
pub const DURABLE_INDEX_STATES: [&str; 2] = [
    VERIFICATION_BLOCKED_RUN_STATE,
    INTEGRATION_BLOCKED_RUN_STATE,
];
pub const REVIEW_BLOCKING_STATES: [&str; 4] =
    ["AwaitingReview", "Reviewing", "MergeConflict", "Succeeded"];
pub const MERGEABLE_REVIEW_STATES: [&str; 5] = [
    "AwaitingReview",
    "Reviewing",
    "MergeConflict",
    "Succeeded",
    INTEGRATION_BLOCKED_RUN_STATE,
];
pub const EXECUTION_MODES: [&str; 2] = ["implementation", "spike"];
pub const SPIKE_EXECUTION_MODE: &str = "spike";
/// How long a finished run stays in `runs.json` after `ended_at`, so the board
/// keeps its review pill across the merge gap.
pub const INDEX_RETENTION_SECONDS: f64 = 300.0;

/// `_execution_mode`.
pub fn execution_mode(value: Option<&str>) -> Result<String> {
    let mode =
        relay_intents::json::py_strip(value.filter(|v| !v.is_empty()).unwrap_or("implementation"))
            .to_lowercase();
    if !EXECUTION_MODES.contains(&mode.as_str()) {
        return Err(Error::invalid(format!(
            "invalid execution_mode: {}",
            sql::py_repr(&mode)
        )));
    }
    Ok(mode)
}

/// `sanitize_identifier`: `REL-42` → `rel-42`.
pub fn sanitize_identifier(identifier: &str) -> Result<String> {
    let lowered = relay_intents::json::py_strip(identifier).to_lowercase();
    let mut slug = String::with_capacity(lowered.len());
    for character in lowered.chars() {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            slug.push(character);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        return Err(Error::invalid(format!(
            "Invalid identifier: {}",
            sql::py_repr(identifier)
        )));
    }
    Ok(slug)
}

/// `_process_is_alive`: `os.kill(pid, 0)` succeeds or is refused.
pub fn process_is_alive(pid: Option<i64>) -> bool {
    let Some(pid) = pid.filter(|pid| *pid > 0 && *pid <= i64::from(i32::MAX)) else {
        return false;
    };
    // SAFETY: kill with signal 0 only checks that the process exists.
    if unsafe { libc::kill(pid as libc::pid_t, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// The fields of a new run (`RunsStore.insert`).
#[derive(Clone, Debug, Default)]
pub struct NewRun {
    pub ticket_id: String,
    pub repo_path: String,
    pub workspace_path: String,
    pub branch: String,
    pub state: String,
    /// `None` is `implementation`.
    pub execution_mode: Option<String>,
    /// `None` is 1.
    pub attempt: Option<i64>,
    pub log_path: Option<String>,
    pub provider_key: Option<String>,
    pub model_alias: Option<String>,
    pub worker_model: Option<String>,
    pub worker_effort: Option<String>,
    pub worker_sizing_rationale: Option<String>,
    pub worker_provider_notes: Option<String>,
}

/// The columns `RunsStore.update` may change; `None` leaves one alone.
#[derive(Clone, Debug, Default)]
pub struct RunUpdate {
    pub state: Option<String>,
    pub pid: Option<i64>,
    pub exit_code: Option<i64>,
    /// `Some(None)` clears `last_error`.
    pub last_error: Option<Option<String>>,
    pub ended: bool,
}

pub struct RunsStore {
    db: Db,
    /// The board's live-state file; `None` writes no index.
    index_path: Option<PathBuf>,
}

impl RunsStore {
    pub fn open(path: &Path, index_path: Option<&Path>) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
            index_path: index_path.map(Path::to_path_buf),
        };
        store.db.with(init)?;
        Ok(store)
    }

    pub fn path(&self) -> &Path {
        &self.db.path
    }

    pub fn insert(&self, run: &NewRun) -> Result<i64> {
        let mode = execution_mode(run.execution_mode.as_deref())?;
        let run_id = self.db.with(|c| {
            sql::execute(
                c,
                "INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, execution_mode, \
                 state, attempt, started_at, log_path, provider_key, model_alias, \
                 worker_model, worker_effort, worker_sizing_rationale, worker_provider_notes) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    text(&run.ticket_id),
                    text(&run.repo_path),
                    text(&run.workspace_path),
                    text(&run.branch),
                    text(mode),
                    text(&run.state),
                    int(run.attempt.unwrap_or(1)),
                    real(sql::now()),
                    opt_text(run.log_path.as_ref()),
                    opt_text(run.provider_key.as_ref()),
                    opt_text(run.model_alias.as_ref()),
                    opt_text(run.worker_model.as_ref()),
                    opt_text(run.worker_effort.as_ref()),
                    opt_text(run.worker_sizing_rationale.as_ref()),
                    opt_text(run.worker_provider_notes.as_ref()),
                ],
            )?;
            Ok(c.last_insert_rowid())
        })?;
        self.write_index();
        Ok(run_id)
    }

    /// Restores one terminal run identity whose canonical ticket survived.
    /// Never overwrites a ledger row and never invents a live worktree.
    pub fn insert_reconciled(
        &self,
        run_id: i64,
        ticket_id: &str,
        repo_path: &str,
        state: &str,
        attempt: i64,
        last_error: Option<&str>,
    ) -> Result<Dict> {
        if run_id <= 0 {
            return Err(Error::invalid("run_id must be positive"));
        }
        if attempt <= 0 {
            return Err(Error::invalid("attempt must be positive"));
        }
        let branch = format!("preserved/{}", sanitize_identifier(ticket_id)?);
        let now = sql::now();
        let reconciled = self.db.with(|c| {
            if sql::row(c, "SELECT 1 FROM runs WHERE id = ?", &[int(run_id)])?.is_some() {
                return Err(Error::invalid(format!("run {run_id} already exists")));
            }
            sql::execute(
                c,
                "INSERT INTO runs(id, ticket_id, repo_path, workspace_path, branch, \
                 state, attempt, started_at, ended_at, exit_code, last_error, activity, \
                 activity_at) VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                &[
                    int(run_id),
                    text(ticket_id),
                    text(repo_path),
                    text(branch),
                    text(state),
                    int(attempt),
                    real(now),
                    real(now),
                    opt_text(last_error),
                    text("Reconciled from committed canonical ticket evidence"),
                    real(now),
                ],
            )?;
            get_row(c, run_id).map(Option::unwrap_or_default)
        })?;
        self.write_index();
        Ok(reconciled)
    }

    /// Allocates a replacement identity without altering the occupied row.
    pub fn insert_reconciled_replacement(
        &self,
        historical_run_id: i64,
        ticket_id: &str,
        repo_path: &str,
        state: &str,
        attempt: i64,
        last_error: Option<&str>,
    ) -> Result<Dict> {
        if historical_run_id <= 0 {
            return Err(Error::invalid("historical_run_id must be positive"));
        }
        if attempt <= 0 {
            return Err(Error::invalid("attempt must be positive"));
        }
        let branch = format!("preserved/{}", sanitize_identifier(ticket_id)?);
        let now = sql::now();
        let activity = replacement_activity(historical_run_id);
        let replacement = self.db.with(|c| {
            sql::execute(
                c,
                "INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, \
                 state, attempt, started_at, ended_at, exit_code, last_error, activity, \
                 activity_at) VALUES (?, ?, '', ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                &[
                    text(ticket_id),
                    text(repo_path),
                    text(branch),
                    text(state),
                    int(attempt),
                    real(now),
                    real(now),
                    opt_text(last_error),
                    text(activity),
                    real(now),
                ],
            )?;
            get_row(c, c.last_insert_rowid()).map(Option::unwrap_or_default)
        })?;
        self.write_index();
        Ok(replacement)
    }

    pub fn reconciled_replacements(
        &self,
        historical_run_id: i64,
        ticket_id: &str,
        repo_path: &str,
    ) -> Result<Vec<Dict>> {
        let repo = resolve_path(repo_path);
        self.db.with(|c| {
            sql::rows(
                c,
                "SELECT * FROM runs WHERE ticket_id = ? AND repo_path = ? AND activity = ? \
                 ORDER BY id",
                &[
                    text(ticket_id),
                    text(repo),
                    text(replacement_activity(historical_run_id)),
                ],
            )
        })
    }

    pub fn update(&self, run_id: i64, update: &RunUpdate) -> Result<()> {
        let mut fields = Vec::new();
        let mut values = Vec::new();
        if let Some(state) = &update.state {
            fields.push("state = ?");
            values.push(text(state));
        }
        if let Some(pid) = update.pid {
            fields.push("pid = ?");
            values.push(int(pid));
        }
        if let Some(exit_code) = update.exit_code {
            fields.push("exit_code = ?");
            values.push(int(exit_code));
        }
        if let Some(last_error) = &update.last_error {
            fields.push("last_error = ?");
            values.push(opt_text(last_error.as_ref()));
        }
        if update.ended {
            fields.push("ended_at = ?");
            values.push(real(sql::now()));
        }
        if fields.is_empty() {
            return Ok(());
        }
        values.push(int(run_id));
        let statement = format!("UPDATE runs SET {} WHERE id = ?", fields.join(", "));
        self.db.with(|c| sql::execute(c, &statement, &values))?;
        self.write_index();
        Ok(())
    }

    /// The worker's current activity summary and its timestamp.
    pub fn set_activity(&self, run_id: i64, activity: &str) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE runs SET activity = ?, activity_at = ? WHERE id = ?",
                &[text(activity), real(sql::now()), int(run_id)],
            )
        })?;
        self.write_index();
        Ok(())
    }

    /// The activity timestamp alone: the heartbeat while a tool is in flight.
    pub fn touch_activity(&self, run_id: i64) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE runs SET activity_at = ? WHERE id = ?",
                &[real(sql::now()), int(run_id)],
            )
        })?;
        self.write_index();
        Ok(())
    }

    pub fn get(&self, run_id: i64) -> Result<Option<Dict>> {
        self.db.with(|c| get_row(c, run_id))
    }

    pub fn list(&self, state: Option<&str>, limit: i64) -> Result<Vec<Dict>> {
        self.db
            .with(|c| match state.filter(|state| !state.is_empty()) {
                Some(state) => sql::rows(
                    c,
                    "SELECT * FROM runs WHERE state = ? ORDER BY id DESC LIMIT ?",
                    &[text(state), int(limit)],
                ),
                None => sql::rows(
                    c,
                    "SELECT * FROM runs ORDER BY id DESC LIMIT ?",
                    &[int(limit)],
                ),
            })
    }

    pub fn list_for_repo(&self, repo_path: &str, limit: i64) -> Result<Vec<Dict>> {
        let repo = resolve_path(repo_path);
        self.db.with(|c| {
            sql::rows(
                c,
                "SELECT * FROM runs WHERE repo_path = ? ORDER BY id DESC LIMIT ?",
                &[text(repo), int(limit.max(1))],
            )
        })
    }

    pub fn active_count(&self, repo_path: Option<&str>) -> Result<i64> {
        let mut params: Vec<Sql> = ACTIVE_STATES.iter().map(|state| text(*state)).collect();
        let mut repo_clause = "";
        if let Some(repo_path) = repo_path {
            repo_clause = "AND repo_path = ? ";
            params.push(text(resolve_path(repo_path)));
        }
        let statement = format!(
            "SELECT COUNT(*) AS count FROM runs WHERE state IN ({}) {repo_clause}",
            placeholders(ACTIVE_STATES.len())
        );
        self.db.with(|c| {
            let row = sql::row(c, &statement, &params)?.unwrap_or_default();
            Ok(field_int(&row, "count").unwrap_or(0))
        })
    }

    pub fn find_active(&self, ticket_id: &str, repo_path: Option<&str>) -> Result<Option<Dict>> {
        self.latest_in_states(ticket_id, repo_path, &ACTIVE_STATES)
    }

    pub fn find_awaiting_merge(
        &self,
        ticket_id: &str,
        repo_path: Option<&str>,
    ) -> Result<Option<Dict>> {
        self.latest_in_states(ticket_id, repo_path, &MERGEABLE_REVIEW_STATES)
    }

    fn latest_in_states(
        &self,
        ticket_id: &str,
        repo_path: Option<&str>,
        states: &[&str],
    ) -> Result<Option<Dict>> {
        let mut params = vec![text(ticket_id)];
        params.extend(states.iter().map(|state| text(*state)));
        let mut repo_clause = "";
        if let Some(repo_path) = repo_path {
            repo_clause = "AND repo_path = ? ";
            params.push(text(resolve_path(repo_path)));
        }
        let statement = format!(
            "SELECT * FROM runs WHERE ticket_id = ? AND state IN ({}) \
             {repo_clause}ORDER BY id DESC LIMIT 1",
            placeholders(states.len())
        );
        self.db.with(|c| sql::row(c, &statement, &params))
    }

    /// Marks abandoned runs `Stalled`, keeping implementation workers whose
    /// process is still alive. A spike never survives a restart: its process
    /// is sent `SIGTERM`. Returns how many runs were reconciled.
    pub fn reconcile_on_startup(&self) -> Result<usize> {
        let statement = format!(
            "SELECT id, pid, execution_mode FROM runs WHERE state IN ({})",
            placeholders(ACTIVE_STATES.len())
        );
        let states: Vec<Sql> = ACTIVE_STATES.iter().map(|state| text(*state)).collect();
        self.db.with(|c| {
            let rows = sql::rows(c, &statement, &states)?;
            let mut abandoned = Vec::new();
            for row in &rows {
                let spike = field_str(row, "execution_mode") == SPIKE_EXECUTION_MODE;
                let pid = field_int(row, "pid");
                if spike || !process_is_alive(pid) {
                    abandoned.push(field_int(row, "id").unwrap_or_default());
                }
                if spike
                    && let Some(pid) = pid.filter(|pid| *pid > 0 && *pid <= i64::from(i32::MAX)) {
                        // SAFETY: signals the spike worker this run recorded.
                        unsafe {
                            libc::kill(pid as libc::pid_t, libc::SIGTERM);
                        }
                    }
            }
            if abandoned.is_empty() {
                return Ok(0);
            }
            let mut params = vec![real(sql::now())];
            params.extend(abandoned.iter().map(|id| int(*id)));
            let update = format!(
                "UPDATE runs SET state = 'Stalled', ended_at = ?, \
                 last_error = CASE WHEN execution_mode = 'spike' AND state = 'SpikeResultReady' \
                 THEN 'Spike terminal result ready before daemon restart' \
                 WHEN execution_mode = 'spike' THEN 'Spike stopped during daemon restart; retry is available' \
                 ELSE 'Worker process was no longer running when daemon restarted' END \
                 WHERE id IN ({})",
                placeholders(abandoned.len())
            );
            sql::execute(c, &update, &params)?;
            Ok(abandoned.len())
        })
    }

    /// The attempt number for a new run on this ticket: 1, or the highest
    /// recorded attempt plus one.
    pub fn next_attempt(&self, ticket_id: &str, repo_path: Option<&str>) -> Result<i64> {
        let mut params = vec![text(ticket_id)];
        let mut repo_clause = "";
        if let Some(repo_path) = repo_path {
            repo_clause = "AND repo_path = ? ";
            params.push(text(resolve_path(repo_path)));
        }
        let statement =
            format!("SELECT MAX(attempt) AS a FROM runs WHERE ticket_id = ? {repo_clause}");
        self.db.with(|c| {
            let row = sql::row(c, &statement, &params)?.unwrap_or_default();
            Ok(match row.get("a").and_then(Value::py_int) {
                Some(attempt) if attempt != 0 => attempt + 1,
                _ => 1,
            })
        })
    }

    pub fn recent_for_ticket(
        &self,
        ticket_id: &str,
        repo_path: Option<&str>,
        limit: i64,
    ) -> Result<Vec<Dict>> {
        let mut params = vec![text(ticket_id)];
        let mut repo_clause = "";
        if let Some(repo_path) = repo_path {
            repo_clause = "AND repo_path = ? ";
            params.push(text(resolve_path(repo_path)));
        }
        params.push(int(limit.max(1)));
        let statement = format!(
            "SELECT * FROM runs WHERE ticket_id = ? {repo_clause}\
             ORDER BY attempt DESC, id DESC LIMIT ?"
        );
        self.db.with(|c| sql::rows(c, &statement, &params))
    }

    /// The board's entries: active runs, runs that ended inside the
    /// retention window, and runs in review-blocking or durable states.
    pub fn index_entries(&self) -> Result<Vec<Dict>> {
        self.db.with(index_entries)
    }

    /// Rewrites `runs.json` from the ledger, atomically (temp file and
    /// rename). A failure is reported on stderr, as the Python store does.
    pub fn write_index(&self) {
        let Some(index_path) = &self.index_path else {
            return;
        };
        let entries = match self.index_entries() {
            Ok(entries) => entries,
            Err(error) => {
                eprintln!(
                    "[orchestrator] could not write runs index {}: {error}",
                    index_path.display()
                );
                return;
            }
        };
        let mut payload = Dict::new();
        payload.insert(
            "runs",
            Value::List(entries.into_iter().map(Value::Dict).collect()),
        );
        let text = sql::dumps_indent(&Value::Dict(payload));
        let mut temporary = index_path.as_os_str().to_os_string();
        temporary.push(".tmp");
        let temporary = PathBuf::from(temporary);
        if let Err(error) =
            fs::write(&temporary, text).and_then(|()| fs::rename(&temporary, index_path))
        {
            eprintln!(
                "[orchestrator] could not write runs index {}: {error}",
                index_path.display()
            );
        }
    }
}

fn replacement_activity(historical_run_id: i64) -> String {
    format!("Reconciled replacement for occupied run {historical_run_id}")
}

fn get_row(c: &Connection, run_id: i64) -> Result<Option<Dict>> {
    sql::row(c, "SELECT * FROM runs WHERE id = ?", &[int(run_id)])
}

fn init(c: &Connection) -> Result<()> {
    // `user_version` gates migrations. 4 gains `execution_mode`; an older
    // version is dropped, as the Python store drops it; a newer one is refused.
    let current = sql::user_version(c)?;
    if current == 4 {
        c.execute_batch(
            "ALTER TABLE runs ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'implementation'",
        )?;
        sql::set_user_version(c, SCHEMA_VERSION)?;
        c.execute_batch(SCHEMA)?;
    } else if current > SCHEMA_VERSION {
        return Err(Error::NewerSchema {
            database: "runs",
            found: current,
            supported: SCHEMA_VERSION,
        });
    } else if current != SCHEMA_VERSION {
        c.execute_batch("DROP TABLE IF EXISTS runs")?;
        c.execute_batch(SCHEMA)?;
        sql::set_user_version(c, SCHEMA_VERSION)?;
    } else {
        c.execute_batch(SCHEMA)?;
    }
    c.execute_batch(
        "UPDATE runs SET last_error = NULL WHERE state = 'Merged' AND last_error IS NOT NULL",
    )?;
    Ok(())
}

fn index_entries(c: &Connection) -> Result<Vec<Dict>> {
    let cutoff = sql::now() - INDEX_RETENTION_SECONDS;
    let mut params = vec![real(cutoff)];
    params.extend(REVIEW_BLOCKING_STATES.iter().map(|state| text(*state)));
    params.extend(DURABLE_INDEX_STATES.iter().map(|state| text(*state)));
    let statement = format!(
        "SELECT * FROM runs WHERE ended_at IS NULL OR ended_at >= ? \
         OR state IN ({}) OR state IN ({}) ORDER BY id DESC",
        placeholders(REVIEW_BLOCKING_STATES.len()),
        placeholders(DURABLE_INDEX_STATES.len())
    );
    let rows = sql::rows(c, &statement, &params)?;
    Ok(rows
        .into_iter()
        .map(|row| {
            let mut entry = Dict::new();
            for (key, column) in INDEX_FIELDS {
                entry.insert(key, row.get(column).cloned().unwrap_or(Value::Null));
            }
            entry
        })
        .collect())
}

/// `runs.json` keys and the column each comes from, in the Python order.
const INDEX_FIELDS: [(&str, &str); 19] = [
    ("ticket_id", "ticket_id"),
    ("repo_path", "repo_path"),
    ("run_id", "id"),
    ("state", "state"),
    ("attempt", "attempt"),
    ("started_at", "started_at"),
    ("ended_at", "ended_at"),
    ("last_error", "last_error"),
    ("workspace_path", "workspace_path"),
    ("branch", "branch"),
    ("execution_mode", "execution_mode"),
    ("activity", "activity"),
    ("activity_at", "activity_at"),
    ("provider_key", "provider_key"),
    ("model_alias", "model_alias"),
    ("worker_model", "worker_model"),
    ("worker_effort", "worker_effort"),
    ("worker_sizing_rationale", "worker_sizing_rationale"),
    ("worker_provider_notes", "worker_provider_notes"),
];
