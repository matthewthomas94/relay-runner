//! `orchestrator_commands.db`: `OrchestratorCommandStore` in
//! `services/orchestrator.py`, the private raw-command inbox of the
//! persistent orchestrator. Public rows leave out `source_text` and `context`.

use std::path::Path;

use rusqlite::Connection;

use relay_intents::json;

use crate::sessions::normalize_provider;
use crate::sql::{
    self, DEFAULT_TIMEOUT, Db, int, opt_int, opt_real, opt_text, placeholders, real, resolve_path,
    text,
};
use crate::{Dict, Error, Result, Value};

pub const SCHEMA_VERSION: i64 = 5;

pub const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS orchestrator_commands (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        intent_id TEXT NOT NULL UNIQUE,
        relay_command_id TEXT NOT NULL,
        relay_command_seq INTEGER NOT NULL,
        within_turn_order INTEGER NOT NULL DEFAULT 1,
        session_id INTEGER,
        repo_path TEXT NOT NULL,
        provider_key TEXT,
        recovery_generation TEXT NOT NULL DEFAULT '0',
        source_text TEXT NOT NULL,
        context TEXT,
        action TEXT,
        outcome TEXT,
        ticket_id TEXT,
        target TEXT,
        disposition TEXT,
        cancellation_scope TEXT NOT NULL DEFAULT 'none',
        lifecycle_state TEXT NOT NULL DEFAULT 'recognized',
        status TEXT NOT NULL,
        status_message TEXT,
        error TEXT,
        received_at REAL,
        processed_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_orchestrator_commands_repo ON orchestrator_commands(repo_path);
    CREATE INDEX IF NOT EXISTS idx_orchestrator_commands_status ON orchestrator_commands(status);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_orchestrator_commands_turn_order
        ON orchestrator_commands(relay_command_id, within_turn_order);
    ";

/// `ORCHESTRATOR_COMMAND_STATUSES`, sorted.
pub const STATUSES: [&str; 18] = [
    "authored",
    "blocked",
    "claimed",
    "clarification_required",
    "classified",
    "created",
    "delivery_failed",
    "dispatched",
    "failed",
    "handled",
    "mutation_authorized",
    "planning",
    "queued",
    "received",
    "rejected",
    "stale",
    "superseded",
    "updated",
];

/// `ORCHESTRATOR_COMMAND_TERMINAL_STATUSES`.
pub const TERMINAL_STATUSES: [&str; 12] = [
    "authored",
    "blocked",
    "clarification_required",
    "created",
    "delivery_failed",
    "dispatched",
    "failed",
    "handled",
    "rejected",
    "stale",
    "superseded",
    "updated",
];

/// The statuses `recoverable` returns, in the Python order.
pub const RECOVERABLE_STATUSES: [&str; 5] = [
    "queued",
    "claimed",
    "mutation_authorized",
    "delivery_failed",
    "clarification_required",
];

/// `normalize_recovery_generation` (`services/continuity_incidents.py`): a
/// non-negative integer or `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`.
pub fn normalize_recovery_generation(value: &Value) -> Result<String> {
    let invalid = || Error::invalid("invalid recovery generation");
    let text = match value {
        Value::Int(number) if *number >= 0 => number.to_string(),
        Value::BigInt(digits) if !digits.starts_with('-') => digits.clone(),
        Value::Str(text) => text.clone(),
        _ => return Err(invalid()),
    };
    let mut characters = text.chars();
    let first_ok = characters
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric());
    let rest_ok =
        characters.all(|character| character.is_ascii_alphanumeric() || "._:-".contains(character));
    if !first_ok || !rest_ok || text.chars().count() > 128 {
        return Err(invalid());
    }
    Ok(text)
}

/// `opaque_identifier` (`services/continuity_incidents.py`).
pub fn opaque_identifier(kind: &str, native_value: &str) -> Result<String> {
    if kind != "session" && kind != "command" {
        return Err(Error::invalid(
            "opaque identifier kind must be session or command",
        ));
    }
    if native_value.is_empty() {
        return Err(Error::invalid("opaque identifier source must not be empty"));
    }
    let digest = relay_intents::sha256::hex_digest(
        format!("continuity-v1:{kind}:{native_value}").as_bytes(),
    );
    Ok(format!("{kind}-{}", &digest[..24]))
}

/// A command as `record` receives it. `relay_command_seq`,
/// `within_turn_order` and `recovery_generation` are read with Python's
/// `int()` and `normalize_recovery_generation`, so text and numbers both work.
#[derive(Clone, Debug)]
pub struct CommandRecord {
    pub repo_path: String,
    pub source_text: String,
    pub relay_command_seq: Value,
    pub relay_command_id: String,
    pub intent_id: Option<String>,
    pub within_turn_order: Option<Value>,
    pub session_id: Option<i64>,
    pub provider_key: Option<String>,
    pub recovery_generation: Value,
    pub context: Option<String>,
    pub action: Option<String>,
    pub outcome: Option<String>,
    pub target: Option<String>,
    pub disposition: Option<String>,
    pub cancellation_scope: Option<String>,
    pub lifecycle_state: Option<String>,
    pub received_at: Option<f64>,
    /// `None` is `received`.
    pub status: Option<String>,
}

impl Default for CommandRecord {
    fn default() -> Self {
        Self {
            repo_path: String::new(),
            source_text: String::new(),
            relay_command_seq: Value::Int(0),
            relay_command_id: String::new(),
            intent_id: None,
            within_turn_order: None,
            session_id: None,
            provider_key: None,
            recovery_generation: Value::Str("0".to_string()),
            context: None,
            action: None,
            outcome: None,
            target: None,
            disposition: None,
            cancellation_scope: None,
            lifecycle_state: None,
            received_at: None,
            status: None,
        }
    }
}

/// The changes `update_status` makes; `None` leaves a column alone.
#[derive(Clone, Debug, Default)]
pub struct CommandStatus {
    pub status: String,
    pub action: Option<String>,
    pub outcome: Option<String>,
    pub ticket_id: Option<String>,
    pub status_message: Option<String>,
    pub error: Option<String>,
}

pub struct CommandStore {
    db: Db,
}

/// The status as stored, or the Python error naming `shown` (`None` when the
/// caller passed none).
fn check_status(status: &str, shown: Option<&str>) -> Result<String> {
    let normalized = json::py_strip(status).to_lowercase();
    if !STATUSES.contains(&normalized.as_str()) {
        return Err(Error::invalid(format!(
            "invalid orchestrator command status {}; expected one of {}",
            shown.map_or("None".to_string(), sql::py_repr),
            STATUSES.join(", ")
        )));
    }
    Ok(normalized)
}

/// `_public_row`: the row without the private command text.
fn public_row(mut row: Dict) -> Dict {
    row.remove("source_text");
    row.remove("context");
    row
}

impl CommandStore {
    pub fn open(path: &Path) -> Result<Self> {
        let store = Self {
            db: Db::open(path, DEFAULT_TIMEOUT)?,
        };
        store.db.with(init)?;
        Ok(store)
    }

    /// Records or refreshes one command item. A terminal item is returned as
    /// it stands. The result is the public row.
    pub fn record(&self, command: &CommandRecord) -> Result<Dict> {
        if json::py_strip(&command.source_text).is_empty() {
            return Err(Error::invalid("source_text is required"));
        }
        let command_id = json::py_strip(&command.relay_command_id).to_string();
        if command_id.is_empty() {
            return Err(Error::invalid("relay_command_id is required"));
        }
        let item_id = match command.intent_id.as_deref().filter(|id| !id.is_empty()) {
            Some(intent_id) => json::py_strip(intent_id).to_string(),
            None => command_id.clone(),
        };
        if item_id.is_empty() {
            return Err(Error::invalid("intent_id is required"));
        }
        let command_seq = command.relay_command_seq.py_int().ok_or_else(|| {
            Error::invalid(format!(
                "invalid relay_command_seq: {}",
                py_value_repr(&command.relay_command_seq)
            ))
        })?;
        let status_text = command
            .status
            .as_deref()
            .filter(|status| !status.is_empty())
            .unwrap_or("received");
        let status = check_status(status_text, command.status.as_deref())?;
        let repo = resolve_path(&command.repo_path);
        let now = sql::now();
        let provider = command
            .provider_key
            .as_deref()
            .filter(|key| !key.is_empty())
            .map(|key| normalize_provider(Some(key)));
        let generation = normalize_recovery_generation(&command.recovery_generation)?;
        let refined_context = sql::clean_optional_multiline_text(command.context.as_deref());
        let item_order = match command
            .within_turn_order
            .as_ref()
            .filter(|order| order.truthy())
        {
            None => 1,
            Some(order) => order.py_int().ok_or_else(|| {
                Error::invalid(format!(
                    "invalid within_turn_order: {}",
                    py_value_repr(order)
                ))
            })?,
        }
        .max(1);
        self.db.with(|c| {
            if let Some(existing) = by_identity(c, "intent_id", &item_id, false)?
                && TERMINAL_STATUSES.contains(&sql::field_str(&existing, "status")) {
                    return Ok(public_row(existing));
                }
            sql::execute(
                c,
                "INSERT INTO orchestrator_commands(\
                 intent_id, relay_command_id, relay_command_seq, within_turn_order, session_id, \
                 repo_path, provider_key, recovery_generation, source_text, context, action, outcome, ticket_id, \
                 target, disposition, cancellation_scope, lifecycle_state, status, status_message, \
                 error, received_at, processed_at, created_at, updated_at\
                 ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(intent_id) DO UPDATE SET \
                 relay_command_seq = excluded.relay_command_seq, \
                 within_turn_order = excluded.within_turn_order, \
                 session_id = excluded.session_id, \
                 repo_path = excluded.repo_path, \
                 provider_key = excluded.provider_key, \
                 recovery_generation = excluded.recovery_generation, \
                 source_text = excluded.source_text, \
                 context = excluded.context, \
                 action = excluded.action, \
                 outcome = excluded.outcome, \
                 ticket_id = excluded.ticket_id, \
                 target = excluded.target, \
                 disposition = excluded.disposition, \
                 cancellation_scope = excluded.cancellation_scope, \
                 lifecycle_state = excluded.lifecycle_state, \
                 status = excluded.status, \
                 status_message = excluded.status_message, \
                 error = excluded.error, \
                 received_at = excluded.received_at, \
                 processed_at = excluded.processed_at, \
                 updated_at = excluded.updated_at",
                &[
                    text(&item_id),
                    text(&command_id),
                    int(command_seq),
                    int(item_order),
                    opt_int(command.session_id),
                    text(&repo),
                    opt_text(provider.as_ref()),
                    text(&generation),
                    text(&command.source_text),
                    opt_text(refined_context.as_ref()),
                    opt_text(command.action.as_ref()),
                    opt_text(command.outcome.as_ref()),
                    opt_text(None::<&str>),
                    opt_text(command.target.as_ref()),
                    opt_text(command.disposition.as_ref()),
                    text(
                        command
                            .cancellation_scope
                            .as_deref()
                            .filter(|scope| !scope.is_empty())
                            .unwrap_or("none"),
                    ),
                    text(
                        command
                            .lifecycle_state
                            .as_deref()
                            .filter(|state| !state.is_empty())
                            .unwrap_or("recognized"),
                    ),
                    text(&status),
                    opt_text(None::<&str>),
                    opt_text(None::<&str>),
                    opt_real(command.received_at),
                    opt_real(None),
                    real(now),
                    real(now),
                ],
            )?;
            Ok(public_row(
                by_identity(c, "intent_id", &item_id, false)?.unwrap_or_default(),
            ))
        })
    }

    /// Moves the command named by `intent_id` (or, without one, every item of
    /// `command_id`) to `status`; returns the last item's public row.
    pub fn update_status(
        &self,
        command_id: &str,
        intent_id: Option<&str>,
        update: &CommandStatus,
    ) -> Result<Option<Dict>> {
        let status = check_status(&update.status, Some(&update.status))?;
        let now = sql::now();
        let mut fields = vec!["status = ?", "updated_at = ?"];
        let mut values = vec![text(&status), real(now)];
        if TERMINAL_STATUSES.contains(&status.as_str()) {
            fields.push("processed_at = ?");
            values.push(real(now));
        }
        for (column, value) in [
            ("action = ?", &update.action),
            ("outcome = ?", &update.outcome),
            ("ticket_id = ?", &update.ticket_id),
            ("status_message = ?", &update.status_message),
            ("error = ?", &update.error),
        ] {
            if let Some(value) = value {
                fields.push(column);
                values.push(text(value));
            }
        }
        let (column, identity) = identity(command_id, intent_id);
        values.push(text(&identity));
        let statement = format!(
            "UPDATE orchestrator_commands SET {} WHERE {column} = ?",
            fields.join(", ")
        );
        self.db.with(|c| {
            sql::execute(c, &statement, &values)?;
            Ok(by_identity(c, column, &identity, true)?.map(public_row))
        })
    }

    /// The full row, command text included.
    pub fn get_private(&self, command_id: &str, intent_id: Option<&str>) -> Result<Option<Dict>> {
        let (column, identity) = identity(command_id, intent_id);
        self.db.with(|c| by_identity(c, column, &identity, true))
    }

    pub fn get_public(&self, command_id: &str, intent_id: Option<&str>) -> Result<Option<Dict>> {
        Ok(self.get_private(command_id, intent_id)?.map(public_row))
    }

    /// Resolves one broker identifier among the newest 1000 commands.
    pub fn find_by_opaque_command_id(&self, opaque_command_id: &str) -> Result<Option<Dict>> {
        self.db.with(|c| {
            let rows = sql::rows(
                c,
                "SELECT * FROM orchestrator_commands ORDER BY id DESC LIMIT 1000",
                &[],
            )?;
            for row in rows {
                let native = match row.get("relay_command_id") {
                    Some(value) => value.py_str(),
                    None => continue,
                };
                if opaque_identifier("command", &native).ok().as_deref() == Some(opaque_command_id)
                {
                    return Ok(Some(row));
                }
            }
            Ok(None)
        })
    }

    /// Received commands in turn order (private rows).
    pub fn pending(&self, repo_path: Option<&str>, limit: i64) -> Result<Vec<Dict>> {
        let mut params = vec![text("received")];
        let mut repo_clause = "";
        if let Some(repo_path) = repo_path.filter(|repo| !repo.is_empty()) {
            repo_clause = "AND repo_path = ? ";
            params.push(text(resolve_path(repo_path)));
        }
        params.push(int(limit.max(1)));
        let statement = format!(
            "SELECT * FROM orchestrator_commands WHERE status = ? {repo_clause}\
             ORDER BY relay_command_seq ASC, within_turn_order ASC, id ASC LIMIT ?"
        );
        self.db.with(|c| sql::rows(c, &statement, &params))
    }

    /// Commands a restarted session can pick up, in turn order (public rows).
    pub fn recoverable(&self, repo_path: Option<&str>, limit: i64) -> Result<Vec<Dict>> {
        let mut params: Vec<_> = RECOVERABLE_STATUSES
            .iter()
            .map(|status| text(*status))
            .collect();
        let mut repo_clause = "";
        if let Some(repo_path) = repo_path.filter(|repo| !repo.is_empty()) {
            repo_clause = "AND repo_path = ? ";
            params.push(text(resolve_path(repo_path)));
        }
        params.push(int(limit.max(1)));
        let statement = format!(
            "SELECT * FROM orchestrator_commands WHERE status IN ({}) {repo_clause}\
             ORDER BY relay_command_seq ASC, within_turn_order ASC, id ASC LIMIT ?",
            placeholders(RECOVERABLE_STATUSES.len())
        );
        self.db.with(|c| {
            Ok(sql::rows(c, &statement, &params)?
                .into_iter()
                .map(public_row)
                .collect())
        })
    }
}

fn identity(command_id: &str, intent_id: Option<&str>) -> (&'static str, String) {
    match intent_id.filter(|id| !id.is_empty()) {
        Some(intent_id) => ("intent_id", intent_id.to_string()),
        None => ("relay_command_id", command_id.to_string()),
    }
}

fn by_identity(c: &Connection, column: &str, value: &str, latest: bool) -> Result<Option<Dict>> {
    let order = if latest {
        " ORDER BY within_turn_order DESC, id DESC LIMIT 1"
    } else {
        ""
    };
    sql::row(
        c,
        &format!("SELECT * FROM orchestrator_commands WHERE {column} = ?{order}"),
        &[text(value)],
    )
}

/// `repr()` of a value in an error message.
fn py_value_repr(value: &Value) -> String {
    match value {
        Value::Str(text) => sql::py_repr(text),
        Value::Null => "None".to_string(),
        other => json::dumps(other),
    }
}

fn init(c: &Connection) -> Result<()> {
    let current = sql::user_version(c)?;
    match current {
        0 => {
            c.execute_batch(SCHEMA)?;
            sql::set_user_version(c, SCHEMA_VERSION)?;
        }
        1..=3 => {
            let existing = sql::table_columns(c, "orchestrator_commands")?;
            for (name, declaration) in [
                ("ticket_id", "TEXT"),
                ("status_message", "TEXT"),
                ("error", "TEXT"),
                ("processed_at", "REAL"),
                ("context", "TEXT"),
            ] {
                if !existing.iter().any(|column| column == name) {
                    c.execute_batch(&format!(
                        "ALTER TABLE orchestrator_commands ADD COLUMN {name} {declaration}"
                    ))?;
                }
            }
            c.execute_batch(
                "ALTER TABLE orchestrator_commands RENAME TO orchestrator_commands_legacy",
            )?;
            c.execute_batch(SCHEMA)?;
            c.execute_batch(
                "INSERT INTO orchestrator_commands(\
                 intent_id, relay_command_id, relay_command_seq, within_turn_order, \
                 session_id, repo_path, provider_key, source_text, context, action, outcome, \
                 ticket_id, target, disposition, cancellation_scope, lifecycle_state, status, \
                 status_message, error, received_at, processed_at, created_at, updated_at\
                 ) SELECT relay_command_id, relay_command_id, relay_command_seq, 1, \
                 session_id, repo_path, provider_key, source_text, context, action, outcome, \
                 ticket_id, NULL, NULL, 'none', 'recognized', status, status_message, error, \
                 received_at, processed_at, created_at, updated_at \
                 FROM orchestrator_commands_legacy",
            )?;
            c.execute_batch("DROP TABLE orchestrator_commands_legacy")?;
            c.execute_batch(SCHEMA)?;
            sql::set_user_version(c, SCHEMA_VERSION)?;
        }
        4 => {
            c.execute_batch(
                "ALTER TABLE orchestrator_commands \
                 ADD COLUMN recovery_generation TEXT NOT NULL DEFAULT '0'",
            )?;
            sql::set_user_version(c, SCHEMA_VERSION)?;
            c.execute_batch(SCHEMA)?;
        }
        SCHEMA_VERSION => c.execute_batch(SCHEMA)?,
        _ => {
            return Err(Error::NewerSchema {
                database: "orchestrator_commands",
                found: current,
                supported: SCHEMA_VERSION,
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_generations_follow_python() {
        assert_eq!(normalize_recovery_generation(&Value::Int(3)).unwrap(), "3");
        assert_eq!(
            normalize_recovery_generation(&Value::Str("gen.1:a-b".into())).unwrap(),
            "gen.1:a-b"
        );
        for bad in [
            Value::Int(-1),
            Value::Bool(true),
            Value::Str(String::new()),
            Value::Str("-x".into()),
            Value::Str("a".repeat(129)),
            Value::Null,
        ] {
            assert!(normalize_recovery_generation(&bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn opaque_identifiers_follow_python() {
        // hashlib.sha256(b"continuity-v1:command:cmd-1").hexdigest()[:24]
        let id = opaque_identifier("command", "cmd-1").unwrap();
        assert!(id.starts_with("command-") && id.len() == 32, "{id}");
        assert!(opaque_identifier("other", "x").is_err());
        assert!(opaque_identifier("command", "").is_err());
    }
}
