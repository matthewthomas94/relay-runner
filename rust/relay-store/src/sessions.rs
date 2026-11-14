//! `orchestrator_sessions.db`: `OrchestratorSessionStore` in
//! `services/orchestrator.py`. Durable foreground-orchestrator lifecycle
//! records; they hold no model process.

use std::path::Path;

use rusqlite::Connection;

use crate::sql::{self, DEFAULT_TIMEOUT, Db, int, opt_int, opt_text, real, resolve_path, text};
use crate::{Dict, Error, Result};

pub const SCHEMA_VERSION: i64 = 1;

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS orchestrator_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT NOT NULL UNIQUE,
        repo_path TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        model_alias TEXT,
        effort TEXT,
        state TEXT NOT NULL,
        started_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        heartbeat_at REAL NOT NULL,
        stopped_at REAL,
        stop_reason TEXT,
        pid INTEGER,
        source TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_orchestrator_sessions_repo ON orchestrator_sessions(repo_path);
    CREATE INDEX IF NOT EXISTS idx_orchestrator_sessions_state ON orchestrator_sessions(state);
    ";

/// `ORCHESTRATOR_SESSION_STATES`, sorted.
pub const STATES: [&str; 8] = [
    "awaiting_workers",
    "blocked",
    "failed",
    "idle",
    "planning",
    "reviewing",
    "stale",
    "stopped",
];
pub const STALE_AFTER_SECONDS: f64 = 30.0;

/// `_normalize_provider`: anything naming Claude is `claude`, else `codex`.
pub fn normalize_provider(provider_key: Option<&str>) -> String {
    let provider = relay_intents::json::py_strip(
        provider_key
            .filter(|key| !key.is_empty())
            .unwrap_or("codex"),
    )
    .to_lowercase();
    if provider.contains("claude") {
        "claude".to_string()
    } else {
        "codex".to_string()
    }
}

/// `_normalize_state`.
pub fn normalize_state(state: Option<&str>) -> Result<String> {
    let value =
        relay_intents::json::py_strip(state.filter(|state| !state.is_empty()).unwrap_or("idle"))
            .to_lowercase();
    if !STATES.contains(&value.as_str()) {
        let shown = state.map_or("None".to_string(), sql::py_repr);
        return Err(Error::invalid(format!(
            "invalid orchestrator state {shown}; expected one of {}",
            STATES.join(", ")
        )));
    }
    Ok(value)
}

/// `session_key`: `project:` and the first 16 hex digits of the SHA-1 of the
/// resolved repository path.
pub fn session_key(repo_path: &str) -> String {
    let repo = resolve_path(repo_path);
    let digest = crate::sha1::hex_digest(repo.as_bytes());
    format!("project:{}", &digest[..16])
}

/// What a session registers with (`OrchestratorSessionStore.ensure`).
#[derive(Clone, Debug, Default)]
pub struct EnsureSession {
    pub repo_path: String,
    pub provider_key: Option<String>,
    pub model_alias: Option<String>,
    pub effort: Option<String>,
    pub source: Option<String>,
    pub pid: Option<i64>,
    /// `None` is `idle`.
    pub state: Option<String>,
}

pub struct SessionStore {
    db: Db,
}

impl SessionStore {
    pub fn open(path: &Path) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
        };
        store.db.with(|c| {
            let current = sql::user_version(c)?;
            if current > SCHEMA_VERSION {
                return Err(Error::NewerSchema {
                    database: "orchestrator_sessions",
                    found: current,
                    supported: SCHEMA_VERSION,
                });
            }
            if current != SCHEMA_VERSION {
                c.execute_batch("DROP TABLE IF EXISTS orchestrator_sessions")?;
                c.execute_batch(SCHEMA)?;
                sql::set_user_version(c, SCHEMA_VERSION)?;
            } else {
                c.execute_batch(SCHEMA)?;
            }
            Ok(())
        })?;
        Ok(store)
    }

    /// Creates or refreshes the repository's session row. The result is the
    /// row plus `created` and `provider_changed`.
    pub fn ensure(&self, session: &EnsureSession) -> Result<Dict> {
        let repo = resolve_path(&session.repo_path);
        let key = session_key(&repo);
        let provider = normalize_provider(session.provider_key.as_deref());
        let next_state = normalize_state(session.state.as_deref())?;
        let now = sql::now();
        self.db.with(|c| {
            let existing = sql::row(
                c,
                "SELECT * FROM orchestrator_sessions WHERE session_key = ?",
                &[text(&key)],
            )?;
            let Some(row) = existing else {
                sql::execute(
                    c,
                    "INSERT INTO orchestrator_sessions(\
                     session_key, repo_path, provider_key, model_alias, effort, state, \
                     started_at, updated_at, heartbeat_at, pid, source\
                     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    &[
                        text(&key),
                        text(&repo),
                        text(&provider),
                        opt_text(session.model_alias.as_ref()),
                        opt_text(session.effort.as_ref()),
                        text(&next_state),
                        real(now),
                        real(now),
                        real(now),
                        opt_int(session.pid),
                        opt_text(session.source.as_ref()),
                    ],
                )?;
                let mut result = get_row(c, c.last_insert_rowid())?.unwrap_or_default();
                result.insert("created", true);
                result.insert("provider_changed", false);
                return Ok(result);
            };
            let previous = sql::field_str(&row, "provider_key").to_string();
            let provider_changed = previous != provider;
            let stop_reason =
                provider_changed.then(|| format!("provider changed from {previous} to {provider}"));
            let id = sql::field_int(&row, "id").unwrap_or_default();
            sql::execute(
                c,
                "UPDATE orchestrator_sessions SET \
                 repo_path = ?, provider_key = ?, model_alias = ?, effort = ?, \
                 state = ?, updated_at = ?, heartbeat_at = ?, stopped_at = NULL, \
                 stop_reason = ?, pid = ?, source = ? \
                 WHERE id = ?",
                &[
                    text(&repo),
                    text(&provider),
                    opt_text(session.model_alias.as_ref()),
                    opt_text(session.effort.as_ref()),
                    text(&next_state),
                    real(now),
                    real(now),
                    opt_text(stop_reason),
                    opt_int(session.pid),
                    opt_text(session.source.as_ref()),
                    int(id),
                ],
            )?;
            let mut result = get_row(c, id)?.unwrap_or_default();
            result.insert("created", false);
            result.insert("provider_changed", provider_changed);
            Ok(result)
        })
    }

    /// Refreshes the heartbeat of the session named by id or repository. A
    /// stale, stopped or failed session comes back `idle` unless `state` says.
    pub fn heartbeat(
        &self,
        session_id: Option<i64>,
        repo_path: Option<&str>,
        provider_key: Option<&str>,
        state: Option<&str>,
    ) -> Result<Option<Dict>> {
        let now = sql::now();
        let next_state = state
            .map(|state| normalize_state(Some(state)))
            .transpose()?;
        self.db.with(|c| {
            let Some(row) = find_row(c, session_id, repo_path)? else {
                return Ok(None);
            };
            let provider = match provider_key.filter(|key| !key.is_empty()) {
                Some(key) => normalize_provider(Some(key)),
                None => sql::field_str(&row, "provider_key").to_string(),
            };
            let mut fields = vec![
                "heartbeat_at = ?",
                "updated_at = ?",
                "provider_key = ?",
                "stopped_at = NULL",
                "stop_reason = NULL",
            ];
            let mut values = vec![real(now), real(now), text(provider)];
            if let Some(next_state) = &next_state {
                fields.push("state = ?");
                values.push(text(next_state));
            } else if ["stale", "stopped", "failed"].contains(&sql::field_str(&row, "state")) {
                fields.push("state = ?");
                values.push(text("idle"));
            }
            let id = sql::field_int(&row, "id").unwrap_or_default();
            values.push(int(id));
            sql::execute(
                c,
                &format!(
                    "UPDATE orchestrator_sessions SET {} WHERE id = ?",
                    fields.join(", ")
                ),
                &values,
            )?;
            get_row(c, id)
        })
    }

    pub fn stop(
        &self,
        session_id: Option<i64>,
        repo_path: Option<&str>,
        reason: Option<&str>,
    ) -> Result<Option<Dict>> {
        let now = sql::now();
        self.db.with(|c| {
            let Some(row) = find_row(c, session_id, repo_path)? else {
                return Ok(None);
            };
            let id = sql::field_int(&row, "id").unwrap_or_default();
            sql::execute(
                c,
                "UPDATE orchestrator_sessions SET state = 'stopped', updated_at = ?, \
                 stopped_at = ?, stop_reason = ? WHERE id = ?",
                &[real(now), real(now), opt_text(reason), int(id)],
            )?;
            get_row(c, id)
        })
    }

    /// Marks sessions whose heartbeat is older than `stale_after_seconds`
    /// `stale`; returns how many changed.
    pub fn reconcile_stale(&self, stale_after_seconds: f64) -> Result<usize> {
        let cutoff = sql::now() - stale_after_seconds.max(0.0);
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE orchestrator_sessions SET state = 'stale', updated_at = ?, \
                 stop_reason = 'heartbeat expired' \
                 WHERE state NOT IN ('stopped', 'stale') AND heartbeat_at < ?",
                &[real(sql::now()), real(cutoff)],
            )
        })
    }

    pub fn get(&self, session_id: i64) -> Result<Option<Dict>> {
        self.db.with(|c| get_row(c, session_id))
    }

    /// Sessions, newest first, after marking expired heartbeats stale.
    pub fn list(&self, repo_path: Option<&str>, limit: i64) -> Result<Vec<Dict>> {
        self.reconcile_stale(STALE_AFTER_SECONDS)?;
        self.db
            .with(|c| match repo_path.filter(|repo| !repo.is_empty()) {
                Some(repo_path) => sql::rows(
                    c,
                    "SELECT * FROM orchestrator_sessions WHERE repo_path = ? \
                 ORDER BY updated_at DESC LIMIT ?",
                    &[text(resolve_path(repo_path)), int(limit)],
                ),
                None => sql::rows(
                    c,
                    "SELECT * FROM orchestrator_sessions ORDER BY updated_at DESC LIMIT ?",
                    &[int(limit)],
                ),
            })
    }
}

fn get_row(c: &Connection, id: i64) -> Result<Option<Dict>> {
    sql::row(
        c,
        "SELECT * FROM orchestrator_sessions WHERE id = ?",
        &[int(id)],
    )
}

fn find_row(
    c: &Connection,
    session_id: Option<i64>,
    repo_path: Option<&str>,
) -> Result<Option<Dict>> {
    if let Some(id) = session_id {
        return get_row(c, id);
    }
    match repo_path.filter(|repo| !repo.is_empty()) {
        Some(repo_path) => sql::row(
            c,
            "SELECT * FROM orchestrator_sessions WHERE session_key = ?",
            &[text(session_key(repo_path))],
        ),
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn providers_and_states_normalise_as_python() {
        assert_eq!(normalize_provider(None), "codex");
        assert_eq!(normalize_provider(Some(" Claude-Code ")), "claude");
        assert_eq!(normalize_provider(Some("")), "codex");
        assert_eq!(normalize_state(None).unwrap(), "idle");
        assert_eq!(normalize_state(Some(" Planning ")).unwrap(), "planning");
        let error = normalize_state(Some("busy")).unwrap_err().to_string();
        assert_eq!(
            error,
            "invalid orchestrator state 'busy'; expected one of awaiting_workers, blocked, \
             failed, idle, planning, reviewing, stale, stopped"
        );
    }
}
