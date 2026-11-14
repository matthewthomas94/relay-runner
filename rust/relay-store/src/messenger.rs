//! `messenger_outcomes.db`: `MessengerOutcomeStore` in
//! `services/orchestrator.py`, the bounded queue of public worker outcomes
//! awaiting speech. A dispatch binds its ticket to the dispatching session
//! (RR-469), so only that PM tab hears the ticket's outcomes.

use std::collections::BTreeSet;
use std::path::Path;

use rusqlite::Connection;

use relay_intents::json;

use crate::sessions::normalize_provider;
use crate::sql::{self, DEFAULT_TIMEOUT, Db, int, opt_int, opt_text, real, resolve_path, text};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA_VERSION: i64 = 2;
pub const MAX_PENDING_PER_REPO: i64 = 50;
/// Delivered outcomes are kept this long.
const DELIVERED_RETENTION_SECONDS: f64 = 86400.0;

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS messenger_outcomes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_key TEXT NOT NULL UNIQUE,
        repo_path TEXT NOT NULL,
        provider_key TEXT,
        kind TEXT NOT NULL,
        ticket_id TEXT,
        run_id INTEGER,
        message TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        delivered_at REAL,
        delivery_attempts INTEGER NOT NULL DEFAULT 0,
        session_key TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_messenger_outcomes_repo_pending
        ON messenger_outcomes(repo_path, delivered_at, id);
    CREATE TABLE IF NOT EXISTS messenger_dispatchers (
        repo_path TEXT NOT NULL,
        ticket_id TEXT NOT NULL,
        session_key TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (repo_path, ticket_id)
    );
    ";

/// `event_key`: one outcome per repository, kind, ticket, run and source.
pub fn event_key(
    repo_path: &str,
    kind: &str,
    ticket_id: Option<&str>,
    run_id: Option<i64>,
    source: Option<&str>,
) -> String {
    [
        resolve_path(repo_path),
        json::py_strip(kind).to_lowercase(),
        json::py_strip(ticket_id.unwrap_or("")).to_uppercase(),
        run_id
            .filter(|id| *id != 0)
            .map(|id| id.to_string())
            .unwrap_or_default(),
        json::py_strip(source.unwrap_or("")).to_lowercase(),
    ]
    .join("|")
}

/// Which pending outcomes a reader receives (`pending`).
#[derive(Clone, Debug, Default)]
pub struct PendingQuery {
    pub repo_path: Option<String>,
    pub limit: i64,
    /// The reading session. Without one (a manual bridge) every outcome
    /// matches the repository filter.
    pub session_key: Option<String>,
    /// Sessions still running; an outcome keyed to an ended session falls
    /// back to repository routing.
    pub live_session_keys: Vec<String>,
}

pub struct MessengerOutcomeStore {
    db: Db,
    max_pending_per_repo: i64,
}

impl MessengerOutcomeStore {
    pub fn open(path: &Path) -> Result<Self> {
        Self::open_bounded(path, MAX_PENDING_PER_REPO)
    }

    pub fn open_bounded(path: &Path, max_pending_per_repo: i64) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
            max_pending_per_repo: max_pending_per_repo.max(1),
        };
        store.db.with(|c| {
            let current = sql::user_version(c)?;
            if current == 1 {
                // Undelivered outcomes are kept; they stay unkeyed.
                c.execute_batch("ALTER TABLE messenger_outcomes ADD COLUMN session_key TEXT")?;
                c.execute_batch(SCHEMA)?;
                sql::set_user_version(c, SCHEMA_VERSION)?;
            } else if current > SCHEMA_VERSION {
                return Err(Error::NewerSchema {
                    database: "messenger_outcomes",
                    found: current,
                    supported: SCHEMA_VERSION,
                });
            } else if current != SCHEMA_VERSION {
                c.execute_batch("DROP TABLE IF EXISTS messenger_outcomes")?;
                c.execute_batch("DROP TABLE IF EXISTS messenger_dispatchers")?;
                c.execute_batch(SCHEMA)?;
                sql::set_user_version(c, SCHEMA_VERSION)?;
            } else {
                c.execute_batch(SCHEMA)?;
            }
            Ok(())
        })?;
        Ok(store)
    }

    /// Routes the ticket's later outcomes to the session that dispatched it.
    pub fn bind_dispatcher(
        &self,
        repo_path: &str,
        ticket_id: &str,
        session_key: &str,
    ) -> Result<()> {
        let repo = resolve_path(repo_path);
        let ticket = json::py_strip(ticket_id).to_uppercase();
        if ticket.is_empty() || session_key.is_empty() {
            return Ok(());
        }
        self.db.with(|c| {
            sql::execute(
                c,
                "INSERT INTO messenger_dispatchers(repo_path, ticket_id, session_key, updated_at) \
                 VALUES (?, ?, ?, ?) ON CONFLICT(repo_path, ticket_id) DO UPDATE SET \
                 session_key = excluded.session_key, updated_at = excluded.updated_at",
                &[
                    text(repo),
                    text(ticket),
                    text(session_key),
                    real(sql::now()),
                ],
            )?;
            Ok(())
        })
    }

    /// Queues the outcome a lifecycle payload carries in `trace_event`, once
    /// per event key; `None` when the payload has no kind or message.
    pub fn record(
        &self,
        repo_path: &str,
        payload: &Dict,
        provider_key: Option<&str>,
    ) -> Result<Option<Dict>> {
        let Some(Value::Dict(trace)) = payload.get("trace_event") else {
            return Ok(None);
        };
        let kind = trace.text("kind").to_lowercase();
        let message = trace
            .truthy("message")
            .or_else(|| payload.truthy("text"))
            .map(Value::py_str)
            .map(|message| json::py_strip(&message).to_string())
            .unwrap_or_default();
        if kind.is_empty() || message.is_empty() {
            return Ok(None);
        }
        let repo = resolve_path(repo_path);
        let ticket_id = Some(trace.text("ticket_id").to_uppercase()).filter(|id| !id.is_empty());
        let run_id = trace.present("run_id").and_then(Value::py_int);
        let source = Some(trace.text("source").to_lowercase()).filter(|source| !source.is_empty());
        let key = event_key(
            &repo,
            &kind,
            ticket_id.as_deref(),
            run_id,
            source.as_deref(),
        );
        let now = sql::now();
        let payload_json = json::dumps_sorted(&Value::Dict(payload.clone()));
        let provider = provider_key
            .filter(|key| !key.is_empty())
            .map(|key| normalize_provider(Some(key)));
        self.db.with(|c| {
            let dispatcher = match &ticket_id {
                Some(ticket) => sql::row(
                    c,
                    "SELECT session_key FROM messenger_dispatchers WHERE repo_path = ? AND ticket_id = ?",
                    &[text(&repo), text(ticket)],
                )?
                .and_then(|row| row.get("session_key").and_then(Value::as_str).map(str::to_string)),
                None => None,
            };
            sql::execute(
                c,
                "INSERT OR IGNORE INTO messenger_outcomes(\
                 event_key, repo_path, provider_key, kind, ticket_id, run_id, message, \
                 payload_json, created_at, session_key\
                 ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    text(&key),
                    text(&repo),
                    opt_text(provider.as_ref()),
                    text(&kind),
                    opt_text(ticket_id.as_ref()),
                    opt_int(run_id),
                    text(&message),
                    text(payload_json),
                    real(now),
                    opt_text(dispatcher.as_ref()),
                ],
            )?;
            self.prune(c, &repo)?;
            Ok(sql::row(
                c,
                "SELECT * FROM messenger_outcomes WHERE event_key = ?",
                &[text(&key)],
            )?
            .map(public_row))
        })
    }

    /// Pending outcomes for one reader, oldest first.
    ///
    /// With a `session_key`, outcomes keyed to it come from any repository
    /// and ones keyed to another live session are left out. Unkeyed
    /// outcomes, and ones keyed to an ended session, match on `repo_path`.
    pub fn pending(&self, query: &PendingQuery) -> Result<Vec<Dict>> {
        let mut params = Vec::new();
        let mut clauses = vec!["delivered_at IS NULL".to_string()];
        let repo = query
            .repo_path
            .as_deref()
            .filter(|repo| !repo.is_empty())
            .map(resolve_path);
        match query.session_key.as_deref().filter(|key| !key.is_empty()) {
            Some(session_key) => {
                let live: BTreeSet<&str> = query
                    .live_session_keys
                    .iter()
                    .map(String::as_str)
                    .filter(|key| !key.is_empty())
                    .chain([session_key])
                    .collect();
                let marks = vec!["?"; live.len()].join(", ");
                let mut shared = format!("(session_key IS NULL OR session_key NOT IN ({marks}))");
                if repo.is_some() {
                    shared.push_str(" AND repo_path = ?");
                }
                clauses.push(format!("(session_key = ? OR ({shared}))"));
                params.push(text(session_key));
                params.extend(live.iter().map(|key| text(*key)));
                if let Some(repo) = &repo {
                    params.push(text(repo));
                }
            }
            None => {
                if let Some(repo) = &repo {
                    clauses.push("repo_path = ?".to_string());
                    params.push(text(repo));
                }
            }
        }
        params.push(int(query.limit.max(1)));
        let statement = format!(
            "SELECT * FROM messenger_outcomes WHERE {} ORDER BY id ASC LIMIT ?",
            clauses.join(" AND ")
        );
        self.db.with(|c| {
            Ok(sql::rows(c, &statement, &params)?
                .into_iter()
                .map(public_row)
                .collect())
        })
    }

    pub fn mark_delivered(&self, outcome_id: i64) -> Result<Option<Dict>> {
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE messenger_outcomes SET delivered_at = ?, \
                 delivery_attempts = delivery_attempts + 1 \
                 WHERE id = ? AND delivered_at IS NULL",
                &[real(sql::now()), int(outcome_id)],
            )?;
            Ok(sql::row(
                c,
                "SELECT * FROM messenger_outcomes WHERE id = ?",
                &[int(outcome_id)],
            )?
            .map(public_row))
        })
    }

    pub fn record_attempt(&self, outcome_id: i64) -> Result<()> {
        self.db.with(|c| {
            sql::execute(
                c,
                "UPDATE messenger_outcomes SET delivery_attempts = delivery_attempts + 1 \
                 WHERE id = ? AND delivered_at IS NULL",
                &[int(outcome_id)],
            )?;
            Ok(())
        })
    }

    fn prune(&self, c: &Connection, repo: &str) -> Result<()> {
        sql::execute(
            c,
            "DELETE FROM messenger_outcomes \
             WHERE repo_path = ? AND delivered_at IS NULL AND id NOT IN (\
             SELECT id FROM messenger_outcomes \
             WHERE repo_path = ? AND delivered_at IS NULL \
             ORDER BY id DESC LIMIT ?\
             )",
            &[text(repo), text(repo), int(self.max_pending_per_repo)],
        )?;
        sql::execute(
            c,
            "DELETE FROM messenger_outcomes \
             WHERE delivered_at IS NOT NULL AND delivered_at < ?",
            &[real(sql::now() - DELIVERED_RETENTION_SECONDS)],
        )?;
        Ok(())
    }
}

/// `_public_row`: `payload_json` decoded into a trailing `payload`, `{}` when
/// it does not parse.
fn public_row(mut row: Dict) -> Dict {
    let raw = row.remove("payload_json");
    let payload = raw
        .map(|raw| raw.py_str())
        .and_then(|raw| json::parse(&raw))
        .unwrap_or_else(|| Value::Dict(Dict::new()));
    row.insert("payload", payload);
    row
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_keys_follow_python() {
        assert_eq!(
            event_key("/", " Run-Merged ", Some("ct-1"), Some(4), Some("Worker")),
            "/|run-merged|CT-1|4|worker"
        );
        assert_eq!(event_key("/", "k", None, Some(0), None), "/|k|||");
    }
}
