//! The provider-turn tables in the intent inbox, as the hook writes them.
//!
//! The Rust form of the part of `services/provider_turn_broker.py` the hook
//! uses. The Python bridge keeps writing the same database, so the schema
//! text, the identities, every statement and the transaction shape
//! (`BEGIN IMMEDIATE`, WAL) are the ones that module uses.

use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, Row, params};

use crate::json::{self, Dict, Value};
use crate::sha256;
use crate::support::{self, FOREGROUND_OWNERSHIP_FIELDS, Failure, is_foreground_owner};

const SCHEMA_VERSION: &str = "3";
const PROJECTION_VERSION: i64 = 2;

/// Byte for byte the script in `ensure_broker_schema`, so a table either
/// implementation creates has the same `sqlite_master` text.
const SCHEMA: &str = "
        CREATE TABLE IF NOT EXISTS provider_turn_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS provider_turn_owners (
            owner_id TEXT PRIMARY KEY,
            app_session_id TEXT NOT NULL,
            recovery_generation TEXT NOT NULL,
            actor_role TEXT NOT NULL,
            foreground_gate_handle TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(app_session_id, recovery_generation, actor_role, foreground_gate_handle)
        );
        CREATE TABLE IF NOT EXISTS provider_turns (
            turn_id TEXT PRIMARY KEY,
            owner_id TEXT NOT NULL REFERENCES provider_turn_owners(owner_id),
            app_session_id TEXT NOT NULL,
            recovery_generation TEXT NOT NULL,
            actor_role TEXT NOT NULL,
            foreground_gate_handle TEXT NOT NULL,
            provider TEXT,
            provider_session_id TEXT,
            native_session_id TEXT NOT NULL,
            native_turn_id TEXT,
            local_turn_seq INTEGER,
            origin TEXT NOT NULL,
            intent_id TEXT,
            command_seq INTEGER,
            command_id TEXT,
            manual_submission_id TEXT,
            manual_submit_evidence_source TEXT,
            state TEXT NOT NULL,
            release_reason TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS provider_turns_owner_state
            ON provider_turns(owner_id, state, updated_at);
        CREATE INDEX IF NOT EXISTS provider_turns_intent
            ON provider_turns(intent_id, updated_at);
        CREATE INDEX IF NOT EXISTS provider_turns_command
            ON provider_turns(command_seq, command_id, updated_at);
        CREATE TABLE IF NOT EXISTS provider_turn_transitions (
            transition_ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id),
            event_type TEXT NOT NULL,
            from_state TEXT,
            to_state TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            release_reason TEXT
        );
        CREATE TABLE IF NOT EXISTS provider_turn_effects (
            effect_id TEXT PRIMARY KEY,
            authority_key TEXT NOT NULL UNIQUE,
            turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id),
            intent_id TEXT,
            effect_kind TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        ";

/// Columns a ledger record takes from a `provider_turns` row under the same
/// name, then the ones it renames.
const PROJECTION_FIELDS: [&str; 15] = [
    "app_session_id",
    "recovery_generation",
    "actor_role",
    "foreground_gate_handle",
    "provider",
    "provider_session_id",
    "local_turn_seq",
    "origin",
    "intent_id",
    "manual_submission_id",
    "manual_submit_evidence_source",
    "state",
    "release_reason",
    "created_at",
    "updated_at",
];
const PROJECTION_RENAMES: [(&str, &str); 4] = [
    ("native_session_id", "session_id"),
    ("native_turn_id", "turn_id"),
    ("command_seq", "relay_command_seq"),
    ("command_id", "relay_command_id"),
];

/// A terminal state a turn may move to; only an `active` turn moves.
const TERMINAL_STATES: [&str; 10] = [
    "cancelled",
    "completed_final",
    "completed_manual",
    "empty",
    "failed",
    "failed_manual",
    "legacy_observation",
    "orphaned",
    "stale",
    "terminated",
];

impl From<rusqlite::Error> for Failure {
    fn from(error: rusqlite::Error) -> Self {
        use rusqlite::ErrorCode;
        Failure(match error.sqlite_error_code() {
            Some(ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt) => "DatabaseError",
            Some(ErrorCode::ConstraintViolation) => "IntegrityError",
            _ => "OperationalError",
        })
    }
}

/// `kind + ":" + sha256(json([kind, …parts]))` over compact JSON: the identity
/// rule every writer of these tables shares.
pub fn stable_event_id(kind: &str, parts: &[Value]) -> String {
    let mut material = vec![Value::from(kind)];
    material.extend_from_slice(parts);
    let digest = sha256::hex_digest(json::dumps_compact_sorted(&Value::List(material)).as_bytes());
    format!("{kind}:{digest}")
}

/// `str(value or "").strip() or None`.
fn text_or_null(record: &Dict, key: &str) -> Option<String> {
    Some(record.text(key)).filter(|text| !text.is_empty())
}

fn integer(record: &Dict, key: &str) -> Option<i64> {
    record.get(key).and_then(Value::py_int_not_bool)
}

fn ownership(record: &Dict) -> Option<Dict> {
    let mut values = Dict::new();
    for field in FOREGROUND_OWNERSHIP_FIELDS {
        values.insert(field, record.text(field));
    }
    is_foreground_owner(&values).then_some(values)
}

fn owner_id(ownership: &Dict) -> String {
    let parts: Vec<Value> = FOREGROUND_OWNERSHIP_FIELDS
        .iter()
        .map(|field| Value::from(ownership.string(field)))
        .collect();
    stable_event_id("owner", &parts)
}

/// The row a ledger record names: its owner, provider session, native session
/// and the native turn id, `local:<n>` or `session`.
fn turn_id(record: &Dict) -> Option<String> {
    let owner_id = owner_id(&ownership(record)?);
    let native_session_id = record.text("session_id");
    if native_session_id.is_empty() {
        return None;
    }
    let physical_turn = text_or_null(record, "turn_id").unwrap_or_else(|| {
        integer(record, "local_turn_seq").map_or_else(
            || "session".to_string(),
            |sequence| format!("local:{sequence}"),
        )
    });
    Some(stable_event_id(
        "turn",
        &[
            owner_id.into(),
            record.text("provider_session_id").into(),
            native_session_id.into(),
            physical_turn.into(),
        ],
    ))
}

pub(super) fn sql_to_json(value: Sql) -> Value {
    match value {
        Sql::Integer(number) => Value::Int(number),
        Sql::Real(number) => Value::Float(number),
        Sql::Text(text) => Value::Str(text),
        Sql::Null | Sql::Blob(_) => Value::Null,
    }
}

fn option_sql<T: Into<Sql>>(value: Option<T>) -> Sql {
    value.map_or(Sql::Null, Into::into)
}

/// A `provider_turns` row shaped like a version 1 ledger record.
fn projection_record(row: &Row<'_>) -> rusqlite::Result<Dict> {
    let mut record = Dict::new();
    let renamed = PROJECTION_RENAMES.iter().copied();
    for (column, name) in PROJECTION_FIELDS
        .iter()
        .map(|field| (*field, *field))
        .chain(renamed)
    {
        let value = sql_to_json(row.get(column)?);
        if !matches!(value, Value::Null) {
            record.insert(name, value);
        }
    }
    Ok(record)
}

/// SQLite's own retry intervals; the wait ends at the hook's deadline, not
/// after the bridge's 5 seconds, so a locked inbox cannot outlast the 2
/// seconds a provider gives a hook.
fn wait_for_lock(attempt: i32) -> bool {
    const DELAYS_MS: [u64; 12] = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100];
    let remaining = support::wait_deadline().saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return false;
    }
    let index = usize::try_from(attempt)
        .unwrap_or(0)
        .min(DELAYS_MS.len() - 1);
    thread::sleep(Duration::from_millis(DELAYS_MS[index]).min(remaining));
    true
}

pub struct ProviderTurnBroker {
    connection: Connection,
    projection_path: String,
}

impl ProviderTurnBroker {
    pub fn open(path: &str, projection_path: &str) -> Result<Self, Failure> {
        let mut connection = Connection::open(path)?;
        connection.busy_handler(Some(wait_for_lock))?;
        // The bundled SQLite enforces foreign keys by default; Python's does
        // not, and both write these tables.
        connection.pragma_update(None, "foreign_keys", false)?;
        connection.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
        connection.execute_batch(SCHEMA)?;
        let columns: Vec<String> = connection
            .prepare("PRAGMA table_info(provider_turns)")?
            .query_map([], |row| row.get(1))?
            .collect::<rusqlite::Result<_>>()?;
        for column in ["manual_submission_id", "manual_submit_evidence_source"] {
            if !columns.iter().any(|existing| existing == column) {
                connection.execute(
                    &format!("ALTER TABLE provider_turns ADD COLUMN {column} TEXT"),
                    [],
                )?;
            }
        }
        connection.execute(
            "INSERT OR REPLACE INTO provider_turn_meta(key, value) VALUES('schema_version', ?)",
            [SCHEMA_VERSION],
        )?;
        Ok(Self {
            connection,
            projection_path: projection_path.to_string(),
        })
    }

    /// Runs `work` inside `BEGIN IMMEDIATE`; an error rolls back.
    fn immediate<T>(
        &self,
        work: impl FnOnce(&Connection) -> Result<T, Failure>,
    ) -> Result<T, Failure> {
        self.connection.execute_batch("BEGIN IMMEDIATE")?;
        match work(&self.connection) {
            Ok(value) => {
                self.connection.execute_batch("COMMIT")?;
                Ok(value)
            }
            Err(failure) => {
                let _ = self.connection.execute_batch("ROLLBACK");
                Err(failure)
            }
        }
    }

    /// Opens `record` as the active turn of its owner and provider session.
    /// Another active turn there becomes `orphaned`; a second prompt under
    /// the same physical turn moves that turn to the newer command.
    pub fn activate(&self, record: &Dict, now: f64, release_reason: &str) -> Result<(), Failure> {
        let Some(turn_id) = turn_id(record) else {
            return Err(Failure("ValueError"));
        };
        let Some(ownership) = ownership(record) else {
            return Err(Failure("ValueError"));
        };
        let owner_id = owner_id(&ownership);
        let origin = text_or_null(record, "origin").unwrap_or_else(|| "relay".to_string());
        let identity: [Sql; 5] = [
            origin.clone().into(),
            option_sql(text_or_null(record, "intent_id")),
            option_sql(integer(record, "relay_command_seq")),
            option_sql(text_or_null(record, "relay_command_id")),
            option_sql(text_or_null(record, "manual_submission_id")),
        ];
        let evidence_source = option_sql(text_or_null(record, "manual_submit_evidence_source"));

        let changed = self.immediate(|db| {
            db.execute(
                "INSERT OR IGNORE INTO provider_turn_owners(
                    owner_id, app_session_id, recovery_generation, actor_role,
                    foreground_gate_handle, created_at
                ) VALUES(?, ?, ?, ?, ?, ?)",
                params![
                    owner_id,
                    ownership.string("app_session_id"),
                    ownership.string("recovery_generation"),
                    ownership.string("actor_role"),
                    ownership.string("foreground_gate_handle"),
                    now
                ],
            )?;
            let existing: Option<(String, [Sql; 5])> = db
                .query_row(
                    "SELECT state, origin, intent_id, command_seq, command_id,
                            manual_submission_id
                       FROM provider_turns WHERE turn_id=?",
                    [&turn_id],
                    |row| {
                        Ok((
                            row.get(0)?,
                            [
                                row.get(1)?,
                                row.get(2)?,
                                row.get(3)?,
                                row.get(4)?,
                                row.get(5)?,
                            ],
                        ))
                    },
                )
                .map(Some)
                .or_else(|error| match error {
                    rusqlite::Error::QueryReturnedNoRows => Ok(None),
                    other => Err(other),
                })?;
            if let Some((state, previous)) = existing {
                // A steered prompt can share the physical Codex turn id. Keep
                // its one completion bound to the latest submitted input,
                // rather than leaving the original intent active.
                let steered = state == "active" && identity != previous;
                if steered {
                    db.execute(
                        "UPDATE provider_turns
                            SET origin=?, intent_id=?, command_seq=?,
                                command_id=?, manual_submission_id=?,
                                manual_submit_evidence_source=?, updated_at=?
                          WHERE turn_id=? AND state='active'",
                        params![
                            identity[0],
                            identity[1],
                            identity[2],
                            identity[3],
                            identity[4],
                            evidence_source,
                            now,
                            turn_id
                        ],
                    )?;
                    let mut parts = vec![Value::from(turn_id.clone())];
                    parts.extend(identity.iter().cloned().map(sql_to_json));
                    db.execute(
                        "INSERT OR IGNORE INTO provider_turn_transitions(
                             event_id, turn_id, event_type, from_state,
                             to_state, occurred_at, release_reason
                         ) VALUES(?, ?, 'prompt_steered', 'active', 'active', ?, NULL)",
                        params![stable_event_id("steer", &parts), turn_id, now],
                    )?;
                }
                return Ok(steered);
            }

            let active: Vec<String> = db
                .prepare(
                    "SELECT turn_id FROM provider_turns
                      WHERE owner_id=? AND state='active'
                        AND COALESCE(provider_session_id, '')=?",
                )?
                .query_map(
                    params![owner_id, record.text("provider_session_id")],
                    |row| row.get(0),
                )?
                .collect::<rusqlite::Result<_>>()?;
            for previous_id in active {
                let event_id = stable_event_id(
                    "supersede",
                    &[previous_id.clone().into(), turn_id.clone().into()],
                );
                db.execute(
                    "INSERT OR IGNORE INTO provider_turn_transitions(
                        event_id, turn_id, event_type, from_state, to_state,
                        occurred_at, release_reason
                    ) VALUES(?, ?, 'superseded', 'active', 'orphaned', ?, ?)",
                    params![event_id, previous_id, now, release_reason],
                )?;
                db.execute(
                    "UPDATE provider_turns
                        SET state='orphaned', release_reason=?, updated_at=?
                      WHERE turn_id=? AND state='active'",
                    params![release_reason, now, previous_id],
                )?;
            }
            let created_at = match record.truthy("created_at") {
                Some(value) => value.py_float().ok_or(Failure("ValueError"))?,
                None => now,
            };
            db.execute(
                "INSERT INTO provider_turns(
                    turn_id, owner_id, app_session_id, recovery_generation, actor_role,
                    foreground_gate_handle, provider, provider_session_id,
                    native_session_id, native_turn_id, local_turn_seq, origin,
                    intent_id, command_seq, command_id, manual_submission_id,
                    manual_submit_evidence_source, state, release_reason,
                    created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', NULL, ?, ?)",
                params![
                    turn_id,
                    owner_id,
                    ownership.string("app_session_id"),
                    ownership.string("recovery_generation"),
                    ownership.string("actor_role"),
                    ownership.string("foreground_gate_handle"),
                    text_or_null(record, "provider"),
                    text_or_null(record, "provider_session_id"),
                    record.text("session_id"),
                    text_or_null(record, "turn_id"),
                    integer(record, "local_turn_seq"),
                    origin,
                    identity[1],
                    identity[2],
                    identity[3],
                    identity[4],
                    evidence_source,
                    created_at,
                    now
                ],
            )?;
            db.execute(
                "INSERT INTO provider_turn_transitions(
                    event_id, turn_id, event_type, from_state, to_state,
                    occurred_at, release_reason
                ) VALUES(?, ?, 'prompt_submitted', NULL, 'active', ?, NULL)",
                params![
                    stable_event_id("activate", &[turn_id.clone().into()]),
                    turn_id,
                    now
                ],
            )?;
            Ok(true)
        })?;
        if changed {
            self.project()?;
        }
        Ok(())
    }

    /// Moves the turn `record` names to a terminal state. `false` when the
    /// turn is unknown, no longer active, or this transition already
    /// happened: exactly one caller wins.
    pub fn transition(
        &self,
        record: &Dict,
        to_state: &str,
        event_type: &str,
        release_reason: &str,
        now: f64,
    ) -> Result<bool, Failure> {
        let Some(turn_id) = turn_id(record) else {
            return Ok(false);
        };
        let moved = self.immediate(|db| {
            let Some(current) = state_of(db, &turn_id)? else {
                return Ok(false);
            };
            if current != "active" || !TERMINAL_STATES.contains(&to_state) {
                return Ok(false);
            }
            let event_id = stable_event_id(
                event_type,
                &[
                    turn_id.clone().into(),
                    to_state.into(),
                    release_reason.into(),
                ],
            );
            let inserted = db.execute(
                "INSERT OR IGNORE INTO provider_turn_transitions(
                    event_id, turn_id, event_type, from_state, to_state,
                    occurred_at, release_reason
                ) VALUES(?, ?, ?, ?, ?, ?, ?)",
                params![
                    event_id,
                    turn_id,
                    event_type,
                    current,
                    to_state,
                    now,
                    release_reason
                ],
            )?;
            if inserted != 1 {
                return Ok(false);
            }
            db.execute(
                "UPDATE provider_turns SET state=?, release_reason=?, updated_at=? WHERE turn_id=?",
                params![to_state, release_reason, now, turn_id],
            )?;
            Ok(true)
        })?;
        if moved {
            self.project()?;
        }
        Ok(moved)
    }

    /// The state of the turn `record` names, when the tables hold it.
    pub fn state_for(&self, record: &Dict) -> Result<Option<String>, Failure> {
        match turn_id(record) {
            Some(turn_id) => Ok(state_of(&self.connection, &turn_id)?),
            None => Ok(None),
        }
    }

    /// Turns of one native provider session, shaped like the version 1
    /// ledger. RR-465: the hook falls back to these when a bridge restart
    /// removed the ledger while the turn was still running.
    pub fn session_records(&self, native_session_id: &str) -> Result<Vec<Dict>, Failure> {
        let mut statement = self.connection.prepare(
            "SELECT * FROM provider_turns WHERE native_session_id=?
              ORDER BY updated_at, created_at, turn_id",
        )?;
        let records = statement
            .query_map([native_session_id], projection_record)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(records)
    }

    /// Rewrites the JSON projection Swift reads, under its lock file.
    fn project(&self) -> Result<(), Failure> {
        if self.projection_path.is_empty() {
            return Ok(());
        }
        let projection = Path::new(&self.projection_path);
        if let Some(parent) = projection
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            fs::create_dir_all(parent)?;
        }
        let lock: File = OpenOptions::new()
            .append(true)
            .read(true)
            .create(true)
            .open(format!("{}.lock", self.projection_path))?;
        lock.lock()?;
        let mut statement = self.connection.prepare(
            "SELECT * FROM provider_turns
              ORDER BY app_session_id, recovery_generation, created_at, turn_id",
        )?;
        let records: Vec<Value> = statement
            .query_map([], |row| projection_record(row).map(Value::Dict))?
            .collect::<rusqlite::Result<_>>()?;
        let mut payload = Dict::new();
        payload.insert("schema_version", PROJECTION_VERSION);
        payload.insert("updated_at", support::now());
        payload.insert("records", records);
        let temporary = format!("{}.{}.tmp", self.projection_path, std::process::id());
        fs::write(
            &temporary,
            json::dumps_compact_sorted(&Value::Dict(payload)),
        )?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
        fs::rename(&temporary, projection)?;
        Ok(())
    }
}

fn state_of(db: &Connection, turn_id: &str) -> rusqlite::Result<Option<String>> {
    db.query_row(
        "SELECT state FROM provider_turns WHERE turn_id=?",
        [turn_id],
        |row| row.get::<_, Sql>(0),
    )
    .map(|state| Some(sql_to_json(state).py_str()))
    .or_else(|error| match error {
        rusqlite::Error::QueryReturnedNoRows => Ok(None),
        other => Err(other),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identities_follow_the_shared_rule() {
        // sha256 of the compact JSON `["owner","app-session-1","generation-1","foreground_pm","gate-1"]`.
        let material = r#"["owner","app-session-1","generation-1","foreground_pm","gate-1"]"#;
        let parts = ["app-session-1", "generation-1", "foreground_pm", "gate-1"].map(Value::from);
        assert_eq!(
            stable_event_id("owner", &parts),
            format!("owner:{}", sha256::hex_digest(material.as_bytes()))
        );
        // `None` and integers keep their JSON form inside the material.
        let steer = r#"["steer","t","relay",null,7,"cmd-7",null]"#;
        let parts = [
            Value::from("t"),
            Value::from("relay"),
            Value::Null,
            Value::from(7),
            Value::from("cmd-7"),
            Value::Null,
        ];
        assert_eq!(
            stable_event_id("steer", &parts),
            format!("steer:{}", sha256::hex_digest(steer.as_bytes()))
        );
    }

    #[test]
    fn turn_identity_needs_a_foreground_owner_and_a_native_session() {
        let mut record = Dict::new();
        for (field, value) in [
            ("app_session_id", "app"),
            ("recovery_generation", "generation"),
            ("actor_role", "foreground_pm"),
            ("foreground_gate_handle", "gate"),
            ("session_id", "native"),
        ] {
            record.insert(field, value);
        }
        let by_session = turn_id(&record).unwrap();
        record.insert("local_turn_seq", 2);
        let by_sequence = turn_id(&record).unwrap();
        record.insert("turn_id", "turn-1");
        let by_turn = turn_id(&record).unwrap();
        assert!(by_session != by_sequence && by_sequence != by_turn);

        let mut bridge = record.clone();
        bridge.insert("actor_role", "voice_bridge");
        assert!(turn_id(&bridge).is_none());
        let mut sessionless = record.clone();
        sessionless.insert("session_id", " ");
        assert!(turn_id(&sessionless).is_none());
    }
}
