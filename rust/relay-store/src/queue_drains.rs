//! `queue_drains.db`: `QueueDrainStore` in `services/orchestrator.py`, the
//! daemon's restartable liveness ledger for rolling queue drains. The board
//! and ticket files stay the source of truth for the work itself.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;

use rusqlite::Connection;
use rusqlite::types::Value as Sql;

use relay_intents::json;

use crate::sessions::normalize_provider;
use crate::sql::{
    self, DEFAULT_TIMEOUT, Db, field_str, int, opt_int, opt_real, opt_text, placeholders, real,
    resolve_path, text,
};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA_VERSION: i64 = 1;

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS queue_drains (
        id TEXT PRIMARY KEY,
        repo_path TEXT NOT NULL,
        target_branch TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        provider_goal_id TEXT,
        provider_goal_state TEXT NOT NULL,
        provider_goal_mode TEXT NOT NULL,
        state TEXT NOT NULL,
        status_message TEXT,
        observed_ticket_ids TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        quiescent_since REAL,
        completed_at REAL,
        canceled_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_queue_drains_repo_state
        ON queue_drains(repo_path, state);
    CREATE TABLE IF NOT EXISTS queue_drain_items (
        drain_id TEXT NOT NULL,
        ticket_id TEXT NOT NULL,
        state TEXT NOT NULL,
        run_id INTEGER,
        reason TEXT,
        next_action_at REAL,
        blocker_owner TEXT,
        blocker_next_step TEXT,
        unresolved_dependencies TEXT NOT NULL DEFAULT '[]',
        updated_at REAL NOT NULL,
        PRIMARY KEY(drain_id, ticket_id)
    );
    CREATE INDEX IF NOT EXISTS idx_queue_drain_items_ticket
        ON queue_drain_items(ticket_id);
    ";

/// `QUEUE_DRAIN_ACTIVE_STATES`, sorted.
pub const ACTIVE_STATES: [&str; 3] = ["active", "blocked", "waiting"];
/// `QUEUE_DRAIN_TERMINAL_STATES`, sorted.
pub const TERMINAL_STATES: [&str; 2] = ["canceled", "completed"];

/// `_json_list`: the strings of a JSON list column, `[]` for anything else.
pub fn json_list(raw: Option<&Value>) -> Vec<String> {
    let decoded = match raw {
        Some(Value::List(items)) => Some(items.clone()),
        Some(value) if value.truthy() => match json::parse(&value.py_str()) {
            Some(Value::List(items)) => Some(items),
            _ => None,
        },
        _ => None,
    };
    decoded
        .unwrap_or_default()
        .iter()
        .map(Value::py_str)
        .filter(|item| !item.is_empty())
        .collect()
}

/// `_queue_drain_id`.
pub fn queue_drain_id(
    repo_path: &str,
    target_branch: &str,
    provider_key: &str,
    sequence: i64,
) -> String {
    let canonical = format!(
        "{}|{target_branch}|{provider_key}|{sequence}",
        resolve_path(repo_path)
    );
    let digest = crate::sha1::hex_digest(canonical.as_bytes());
    format!("drain-{}-{sequence}", &digest[..12])
}

/// `_provider_goal_mode`. Codex has a goal lifecycle; the Claude CLI has no
/// documented equivalent, so Relay Runner keeps the goal durable itself.
pub fn provider_goal_mode(provider_key: &str) -> &'static str {
    if normalize_provider(Some(provider_key)) == "codex" {
        "codex-goal-lifecycle"
    } else {
        "relay-runner-durable-goal"
    }
}

/// One ticket's classification in a drain (`update_items`).
#[derive(Clone, Debug, Default)]
pub struct DrainItem {
    pub ticket_id: String,
    /// `None` or empty is `unknown`.
    pub state: Option<String>,
    pub run_id: Option<i64>,
    pub reason: Option<String>,
    pub next_action_at: Option<f64>,
    pub blocker_owner: Option<String>,
    pub blocker_next_step: Option<String>,
    pub unresolved_dependencies: Vec<String>,
}

/// The fields of `update_state`.
#[derive(Clone, Debug, Default)]
pub struct DrainState {
    pub state: String,
    pub provider_goal_state: Option<String>,
    pub status_message: Option<String>,
    pub quiescent_since: Option<f64>,
    pub complete: bool,
    pub canceled: bool,
}

pub struct QueueDrainStore {
    db: Db,
}

impl QueueDrainStore {
    pub fn open(path: &Path) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
        };
        store.db.with(|c| {
            let current = sql::user_version(c)?;
            if current > SCHEMA_VERSION {
                return Err(Error::NewerSchema {
                    database: "queue_drains",
                    found: current,
                    supported: SCHEMA_VERSION,
                });
            }
            if current != SCHEMA_VERSION {
                c.execute_batch("DROP TABLE IF EXISTS queue_drain_items")?;
                c.execute_batch("DROP TABLE IF EXISTS queue_drains")?;
                c.execute_batch(SCHEMA)?;
                sql::set_user_version(c, SCHEMA_VERSION)?;
            } else {
                c.execute_batch(SCHEMA)?;
            }
            Ok(())
        })?;
        Ok(store)
    }

    pub fn active_for_repo(&self, repo_path: &str, include_items: bool) -> Result<Option<Dict>> {
        let repo = resolve_path(repo_path);
        self.db.with(|c| match active_row(c, &repo)? {
            Some(row) => public_drain(c, &row, include_items).map(Some),
            None => Ok(None),
        })
    }

    pub fn active_repo_paths(&self) -> Result<Vec<String>> {
        let statement = format!(
            "SELECT DISTINCT repo_path FROM queue_drains WHERE state IN ({})",
            placeholders(ACTIVE_STATES.len())
        );
        self.db.with(|c| {
            let rows = sql::rows(c, &statement, &states(&ACTIVE_STATES))?;
            Ok(rows
                .iter()
                .map(|row| field_str(row, "repo_path").to_string())
                .collect())
        })
    }

    /// The repository's live drain, with `observed_ticket_ids` merged in, or
    /// a new one. The flag says whether the drain was created.
    pub fn ensure_active(
        &self,
        repo_path: &str,
        target_branch: &str,
        provider_key: &str,
        observed_ticket_ids: &[String],
        status_message: Option<&str>,
        include_items: bool,
    ) -> Result<(Dict, bool)> {
        let repo = resolve_path(repo_path);
        let provider = normalize_provider(Some(provider_key));
        let target = if target_branch.is_empty() {
            "main"
        } else {
            target_branch
        };
        let observed: Vec<String> = observed_ticket_ids
            .iter()
            .filter(|ticket| !json::py_strip(ticket).is_empty())
            .map(|ticket| ticket.to_uppercase())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let now = sql::now();
        self.db.with(|c| {
            if let Some(row) = active_row(c, &repo)? {
                let current = json_list(row.get("observed_ticket_ids"));
                let merged = merge(&current, &observed);
                if merged == current {
                    return Ok((public_drain(c, &row, include_items)?, false));
                }
                let id = field_str(&row, "id").to_string();
                sql::execute(
                    c,
                    "UPDATE queue_drains SET observed_ticket_ids = ?, updated_at = ? WHERE id = ?",
                    &[
                        text(json::dumps(&sql::string_list(&merged))),
                        real(now),
                        text(&id),
                    ],
                )?;
                let fresh = get_row(c, &id)?.unwrap_or_default();
                return Ok((public_drain(c, &fresh, include_items)?, false));
            }

            let count = sql::row(
                c,
                "SELECT COUNT(*) AS count FROM queue_drains WHERE repo_path = ? AND target_branch = ? \
                 AND provider_key = ?",
                &[text(&repo), text(target), text(&provider)],
            )?
            .and_then(|row| sql::field_int(&row, "count"))
            .unwrap_or(0);
            let sequence = count + 1;
            let drain_id = queue_drain_id(&repo, target, &provider, sequence);
            let goal_id = if provider == "codex" {
                format!("{provider}:{drain_id}")
            } else {
                drain_id.clone()
            };
            let message = match status_message.filter(|message| !message.is_empty()) {
                Some(message) => message.to_string(),
                None => format!(
                    "Draining {} queued/in-progress ticket(s).",
                    observed.len()
                ),
            };
            sql::execute(
                c,
                "INSERT INTO queue_drains(\
                 id, repo_path, target_branch, provider_key, provider_goal_id, provider_goal_state, \
                 provider_goal_mode, state, status_message, observed_ticket_ids, created_at, updated_at\
                 ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    text(&drain_id),
                    text(&repo),
                    text(target),
                    text(&provider),
                    text(goal_id),
                    text("active"),
                    text(provider_goal_mode(&provider)),
                    text("active"),
                    text(message),
                    text(json::dumps(&sql::string_list(&observed))),
                    real(now),
                    real(now),
                ],
            )?;
            let fresh = get_row(c, &drain_id)?.unwrap_or_default();
            Ok((public_drain(c, &fresh, include_items)?, true))
        })
    }

    /// Writes the items whose classification changed, in one commit. An
    /// item's `updated_at` is when its classification last changed.
    pub fn update_items(&self, drain_id: &str, items: &[DrainItem]) -> Result<()> {
        let now = sql::now();
        self.db.with(|c| {
            let mut stored: HashMap<String, Vec<Sql>> = HashMap::new();
            {
                let mut statement = c.prepare(
                    "SELECT drain_id, ticket_id, state, run_id, reason, next_action_at, blocker_owner, \
                     blocker_next_step, unresolved_dependencies FROM queue_drain_items WHERE drain_id = ?",
                )?;
                let mut rows = statement.query([drain_id])?;
                while let Some(row) = rows.next()? {
                    let ticket: String = row.get::<_, String>(1)?;
                    let values = (2..9)
                        .map(|index| row.get::<_, Sql>(index))
                        .collect::<rusqlite::Result<Vec<_>>>()?;
                    stored.insert(ticket, values);
                }
            }
            let mut changed = Vec::new();
            for item in items {
                let values = vec![
                    text(
                        item.state
                            .as_deref()
                            .filter(|state| !state.is_empty())
                            .unwrap_or("unknown"),
                    ),
                    opt_int(item.run_id),
                    opt_text(item.reason.as_ref()),
                    opt_real(item.next_action_at),
                    opt_text(item.blocker_owner.as_ref()),
                    opt_text(item.blocker_next_step.as_ref()),
                    text(json::dumps(&sql::string_list(&item.unresolved_dependencies))),
                ];
                let ticket = item.ticket_id.to_uppercase();
                let same = stored.get(&ticket).is_some_and(|previous| {
                    previous.len() == values.len()
                        && previous.iter().zip(&values).all(|(a, b)| sql::sql_eq(a, b))
                });
                if !same {
                    changed.push((ticket, values));
                }
            }
            if changed.is_empty() {
                return Ok(());
            }
            sql::transaction(c, "BEGIN", || {
                for (ticket, values) in &changed {
                    let mut params = vec![text(drain_id), text(ticket)];
                    params.extend(values.iter().cloned());
                    params.push(real(now));
                    sql::execute(
                        c,
                        "INSERT INTO queue_drain_items(\
                         drain_id, ticket_id, state, run_id, reason, next_action_at, blocker_owner, \
                         blocker_next_step, unresolved_dependencies, updated_at\
                         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                         ON CONFLICT(drain_id, ticket_id) DO UPDATE SET \
                         state = excluded.state, run_id = excluded.run_id, reason = excluded.reason, \
                         next_action_at = excluded.next_action_at, blocker_owner = excluded.blocker_owner, \
                         blocker_next_step = excluded.blocker_next_step, \
                         unresolved_dependencies = excluded.unresolved_dependencies, updated_at = excluded.updated_at",
                        &params,
                    )?;
                }
                Ok(())
            })
        })
    }

    pub fn update_state(&self, drain_id: &str, update: &DrainState) -> Result<Option<Dict>> {
        let now = sql::now();
        let mut fields = vec!["state = ?", "updated_at = ?"];
        let mut values = vec![text(&update.state), real(now)];
        if let Some(goal_state) = &update.provider_goal_state {
            fields.push("provider_goal_state = ?");
            values.push(text(goal_state));
        }
        if let Some(message) = &update.status_message {
            fields.push("status_message = ?");
            values.push(text(message));
        }
        fields.push("quiescent_since = ?");
        values.push(opt_real(update.quiescent_since));
        if update.complete {
            fields.push("completed_at = ?");
            values.push(real(now));
        }
        if update.canceled {
            fields.push("canceled_at = ?");
            values.push(real(now));
        }
        values.push(text(drain_id));
        let statement = format!("UPDATE queue_drains SET {} WHERE id = ?", fields.join(", "));
        self.db.with(|c| {
            sql::execute(c, &statement, &values)?;
            match get_row(c, drain_id)? {
                Some(row) => public_drain(c, &row, true).map(Some),
                None => Ok(None),
            }
        })
    }

    pub fn append_observed(
        &self,
        drain_id: &str,
        ticket_ids: &[String],
        include_items: bool,
    ) -> Result<Option<Dict>> {
        let normalized: Vec<String> = ticket_ids
            .iter()
            .filter(|ticket| !json::py_strip(ticket).is_empty())
            .map(|ticket| ticket.to_uppercase())
            .collect();
        self.db.with(|c| {
            let Some(row) = get_row(c, drain_id)? else {
                return Ok(None);
            };
            let current = json_list(row.get("observed_ticket_ids"));
            let merged = merge(&current, &normalized);
            if merged == current {
                return public_drain(c, &row, include_items).map(Some);
            }
            sql::execute(
                c,
                "UPDATE queue_drains SET observed_ticket_ids = ?, updated_at = ? WHERE id = ?",
                &[
                    text(json::dumps(&sql::string_list(&merged))),
                    real(sql::now()),
                    text(drain_id),
                ],
            )?;
            let fresh = get_row(c, drain_id)?.unwrap_or_default();
            public_drain(c, &fresh, include_items).map(Some)
        })
    }

    pub fn cancel(&self, drain_id: &str, reason: Option<&str>) -> Result<Option<Dict>> {
        let message = reason
            .filter(|reason| !reason.is_empty())
            .unwrap_or("Queue drain canceled by user.");
        self.update_state(
            drain_id,
            &DrainState {
                state: "canceled".to_string(),
                provider_goal_state: Some("canceled".to_string()),
                status_message: Some(message.to_string()),
                quiescent_since: None,
                complete: false,
                canceled: true,
            },
        )
    }

    /// Drains, newest first. `limit` 0 is 20, as `int(limit or 20)` reads it.
    pub fn list(
        &self,
        repo_path: Option<&str>,
        include_terminal: bool,
        limit: i64,
    ) -> Result<Vec<Dict>> {
        let limit = if limit == 0 { 20 } else { limit.max(1) };
        let mut clauses = Vec::new();
        let mut values = Vec::new();
        if let Some(repo_path) = repo_path.filter(|repo| !repo.is_empty()) {
            clauses.push("repo_path = ?".to_string());
            values.push(text(resolve_path(repo_path)));
        }
        if !include_terminal {
            clauses.push(format!(
                "state NOT IN ({})",
                placeholders(TERMINAL_STATES.len())
            ));
            values.extend(states(&TERMINAL_STATES));
        }
        let filter = if clauses.is_empty() {
            String::new()
        } else {
            format!("WHERE {} ", clauses.join(" AND "))
        };
        values.push(int(limit));
        let statement =
            format!("SELECT * FROM queue_drains {filter}ORDER BY created_at DESC LIMIT ?");
        self.db.with(|c| {
            sql::rows(c, &statement, &values)?
                .iter()
                .map(|row| public_drain(c, row, true))
                .collect()
        })
    }

    pub fn get(&self, drain_id: &str) -> Result<Option<Dict>> {
        self.db.with(|c| match get_row(c, drain_id)? {
            Some(row) => public_drain(c, &row, true).map(Some),
            None => Ok(None),
        })
    }
}

fn states(names: &[&str]) -> Vec<Sql> {
    names.iter().map(|name| text(*name)).collect()
}

fn merge(current: &[String], added: &[String]) -> Vec<String> {
    current
        .iter()
        .chain(added)
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn get_row(c: &Connection, drain_id: &str) -> Result<Option<Dict>> {
    sql::row(
        c,
        "SELECT * FROM queue_drains WHERE id = ?",
        &[text(drain_id)],
    )
}

fn active_row(c: &Connection, repo: &str) -> Result<Option<Dict>> {
    let statement = format!(
        "SELECT * FROM queue_drains WHERE repo_path = ? AND state IN ({}) \
         ORDER BY created_at DESC LIMIT 1",
        placeholders(ACTIVE_STATES.len())
    );
    let mut params = vec![text(repo)];
    params.extend(states(&ACTIVE_STATES));
    sql::row(c, &statement, &params)
}

fn items(c: &Connection, drain_id: &str) -> Result<Vec<Dict>> {
    let rows = sql::rows(
        c,
        "SELECT * FROM queue_drain_items WHERE drain_id = ? ORDER BY ticket_id",
        &[text(drain_id)],
    )?;
    Ok(rows
        .iter()
        .map(|row| {
            let mut item = Dict::new();
            for key in ["ticket_id", "state", "run_id", "reason", "next_action_at"] {
                item.insert(key, column(row, key));
            }
            for key in ["blocker_owner", "blocker_next_step"] {
                item.insert(key, column(row, key));
            }
            item.insert(
                "unresolved_dependencies",
                sql::string_list(&json_list(row.get("unresolved_dependencies"))),
            );
            item.insert("updated_at", column(row, "updated_at"));
            item
        })
        .collect())
}

fn column(row: &Dict, key: &str) -> Value {
    row.get(key).cloned().unwrap_or(Value::Null)
}

/// `_public_drain`.
fn public_drain(c: &Connection, row: &Dict, include_items: bool) -> Result<Dict> {
    let mut drain = Dict::new();
    for key in [
        "id",
        "repo_path",
        "target_branch",
        "provider_key",
        "provider_goal_id",
        "provider_goal_state",
        "provider_goal_mode",
        "state",
        "status_message",
    ] {
        drain.insert(key, column(row, key));
    }
    drain.insert(
        "observed_ticket_ids",
        sql::string_list(&json_list(row.get("observed_ticket_ids"))),
    );
    for key in [
        "created_at",
        "updated_at",
        "quiescent_since",
        "completed_at",
        "canceled_at",
    ] {
        drain.insert(key, column(row, key));
    }
    if include_items {
        let id = field_str(row, "id").to_string();
        drain.insert(
            "items",
            Value::List(items(c, &id)?.into_iter().map(Value::Dict).collect()),
        );
    }
    Ok(drain)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_list_follows_python() {
        assert_eq!(
            json_list(Some(&Value::Str("[\"A\", 2, \"\", null]".into()))),
            vec!["A", "2", "None"]
        );
        assert!(json_list(Some(&Value::Str("{}".into()))).is_empty());
        assert!(json_list(Some(&Value::Str("nope".into()))).is_empty());
        assert!(json_list(None).is_empty());
    }

    #[test]
    fn goal_modes_follow_the_provider() {
        assert_eq!(provider_goal_mode("codex"), "codex-goal-lifecycle");
        assert_eq!(provider_goal_mode("claude"), "relay-runner-durable-goal");
    }
}
