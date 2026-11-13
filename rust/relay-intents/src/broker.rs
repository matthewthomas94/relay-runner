//! The provider-turn lifecycle tables and the JSON projection Swift reads:
//! `services/provider_turn_broker.py`.
//!
//! The tables share the intent inbox's database. JSON files are projections
//! or migration surfaces; they never decide a lifecycle transition.

use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::database::{self, LockWait, immediate, row_dict, sql_to_json};
use crate::json::{self, Dict, Value};
use crate::model::{EffectState, OWNERSHIP_FIELDS, TurnState, foreground_ownership};
use crate::sha256;
use crate::{Error, Result};

pub const SCHEMA_VERSION: &str = "3";
pub const PROJECTION_VERSION: i64 = 2;

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

/// The tables `table_records` reads.
pub const TABLES: [&str; 4] = [
    "provider_turn_owners",
    "provider_turns",
    "provider_turn_transitions",
    "provider_turn_effects",
];

/// The effect a final reply reserves.
pub const AUTHORITATIVE_REPLY: &str = "authoritative_reply";

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

/// `_integer`: `int(value)` for anything but a `bool`.
fn integer(record: &Dict, key: &str) -> Option<i64> {
    record.get(key).and_then(Value::py_int_not_bool)
}

fn owner_id_of(ownership: &Dict) -> String {
    let parts: Vec<Value> = OWNERSHIP_FIELDS
        .iter()
        .map(|field| Value::from(ownership.string(field)))
        .collect();
    stable_event_id("owner", &parts)
}

/// `_owner_id`: the identity of a record's foreground owner.
pub fn owner_id(record: &Dict) -> Option<String> {
    foreground_ownership(record).map(|ownership| owner_id_of(&ownership))
}

/// `_turn_id`: the row a ledger record names, from its owner, provider
/// session, native session and native turn (`local:<n>` or `session`).
pub fn turn_id(record: &Dict) -> Option<String> {
    let owner_id = owner_id(record)?;
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

/// Creates the tables and records their schema version.
pub fn ensure_broker_schema(connection: &Connection) -> Result<()> {
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
    Ok(())
}

/// An inbox lifecycle event for the turns of each intent, recorded in the
/// caller's transaction: once per event, scope and turn. With
/// `terminal_state` the turn also moves there when it may. Returns the number
/// of turns that recorded the event.
pub fn record_intent_events<'a>(
    connection: &Connection,
    intent_ids: impl IntoIterator<Item = &'a str>,
    event_type: &str,
    event_scope: &str,
    occurred_at: f64,
    terminal: Option<(TurnState, &str)>,
) -> Result<usize> {
    let mut ids: Vec<&str> = intent_ids
        .into_iter()
        .map(json::py_strip)
        .filter(|id| !id.is_empty())
        .collect();
    ids.sort_unstable();
    ids.dedup();
    let release_reason = terminal.map(|(_, reason)| reason);
    let mut changed = 0;
    for intent_id in ids {
        let turns: Vec<(String, String)> = connection
            .prepare(
                "SELECT turn_id, state FROM provider_turns WHERE intent_id=? ORDER BY updated_at",
            )?
            .query_map([intent_id], |row| {
                Ok((
                    sql_to_json(row.get(0)?).py_str(),
                    sql_to_json(row.get(1)?).py_str(),
                ))
            })?
            .collect::<rusqlite::Result<_>>()?;
        for (turn_id, current_state) in turns {
            let next_state = match terminal {
                Some((state, _)) => {
                    let allowed = TurnState::parse(&current_state)
                        .is_some_and(|current| current.may_become(state));
                    if !allowed {
                        continue;
                    }
                    state.as_str().to_string()
                }
                None => current_state.clone(),
            };
            let event_id =
                stable_event_id(event_type, &[event_scope.into(), turn_id.clone().into()]);
            let inserted = connection.execute(
                "
                INSERT OR IGNORE INTO provider_turn_transitions(
                    event_id, turn_id, event_type, from_state, to_state,
                    occurred_at, release_reason
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                ",
                params![
                    event_id,
                    turn_id,
                    event_type,
                    current_state,
                    next_state,
                    occurred_at,
                    release_reason
                ],
            )?;
            if inserted != 1 {
                continue;
            }
            if terminal.is_some() {
                connection.execute(
                    "UPDATE provider_turns SET state=?, release_reason=?, updated_at=? WHERE turn_id=?",
                    params![next_state, release_reason, occurred_at, turn_id],
                )?;
            }
            changed += 1;
        }
    }
    Ok(changed)
}

/// The outcome of `reserve_effect`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EffectReservation {
    pub accepted: bool,
    pub effect_id: Option<String>,
    /// Why a reservation was refused: `ownership_or_command_missing`,
    /// `turn_missing`, `turn_revoked` or `duplicate`; empty when accepted.
    pub reason: &'static str,
}

impl EffectReservation {
    fn refused(reason: &'static str) -> Self {
        Self {
            accepted: false,
            effect_id: None,
            reason,
        }
    }

    pub fn to_dict(&self) -> Dict {
        let mut record = Dict::new();
        record.insert("accepted", self.accepted);
        record.insert("effect_id", self.effect_id.clone());
        record.insert("reason", self.reason);
        record
    }
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

fn turn_state(connection: &Connection, turn_id: &str) -> Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT state FROM provider_turns WHERE turn_id=?",
            [turn_id],
            |row| row.get::<_, Sql>(0),
        )
        .optional()?
        .map(|state| sql_to_json(state).py_str()))
}

/// `_text(value)` for a column: `str(value or "").strip()`.
fn sql_text(value: Sql) -> String {
    let value = sql_to_json(value);
    if value.truthy() {
        json::py_strip(&value.py_str()).to_string()
    } else {
        String::new()
    }
}

/// `_intent_cancelled`: whether the inbox, when this database has one, holds
/// the intent as `cancelled`.
fn intent_cancelled(connection: &Connection, intent_id: &str) -> Result<bool> {
    let has_inbox = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='intents'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !has_inbox {
        return Ok(false);
    }
    let state: Option<Sql> = connection
        .query_row(
            "SELECT state FROM intents WHERE intent_id=?",
            [intent_id],
            |row| row.get(0),
        )
        .optional()?;
    Ok(matches!(state, Some(Sql::Text(state)) if state == "cancelled"))
}

/// Rewrites the JSON projection at `projection_path` under its lock file.
/// Nothing happens when the path is empty.
pub fn project(connection: &Connection, projection_path: &str) -> Result<()> {
    if projection_path.is_empty() {
        return Ok(());
    }
    let projection = Path::new(projection_path);
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
        .open(format!("{projection_path}.lock"))?;
    lock.lock()?;
    let mut statement = connection.prepare(
        "
                    SELECT * FROM provider_turns
                     ORDER BY app_session_id, recovery_generation, created_at, turn_id
                    ",
    )?;
    let records: Vec<Value> = statement
        .query_map([], |row| projection_record(row).map(Value::Dict))?
        .collect::<rusqlite::Result<_>>()?;
    let mut payload = Dict::new();
    payload.insert("schema_version", PROJECTION_VERSION);
    payload.insert("updated_at", database::now());
    payload.insert("records", records);
    let temporary = format!("{projection_path}.{}.tmp", std::process::id());
    fs::write(
        &temporary,
        json::dumps_compact_sorted(&Value::Dict(payload)),
    )?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(&temporary, projection)?;
    Ok(())
}

/// SQLite authority for provider turns, ownership, transitions and effects.
pub struct ProviderTurnBroker {
    connection: Connection,
    projection_path: Option<String>,
}

impl ProviderTurnBroker {
    /// `ProviderTurnBroker(path, projection_path=...)`.
    pub fn open(path: &str, projection_path: Option<&str>) -> Result<Self> {
        Self::open_with(path, projection_path, LockWait::default())
    }

    pub fn open_with(
        path: &str,
        projection_path: Option<&str>,
        lock_wait: LockWait,
    ) -> Result<Self> {
        let connection = database::connect(path, lock_wait)?;
        ensure_broker_schema(&connection)?;
        Ok(Self {
            connection,
            projection_path: projection_path.map(str::to_string),
        })
    }

    /// Opens `record` as the active turn of its owner and provider session.
    /// Another active turn there becomes `orphaned`. A second prompt under the
    /// same physical turn moves that turn to the newer command and returns
    /// `false`, as does any prompt for a turn already recorded.
    pub fn activate(&self, record: &Dict, now: Option<f64>, release_reason: &str) -> Result<bool> {
        let now = now.unwrap_or_else(database::now);
        let Some(turn_id) = turn_id(record) else {
            return Err(Error::Invalid(
                "provider turn requires stable foreground and native identity",
            ));
        };
        let ownership = foreground_ownership(record).ok_or(Error::Invalid(
            "provider turn requires a complete foreground ownership envelope",
        ))?;
        let owner_id = owner_id_of(&ownership);
        let origin = text_or_null(record, "origin").unwrap_or_else(|| "relay".to_string());
        let identity: [Sql; 5] = [
            origin.clone().into(),
            text_or_null(record, "intent_id").into(),
            integer(record, "relay_command_seq").into(),
            text_or_null(record, "relay_command_id").into(),
            text_or_null(record, "manual_submission_id").into(),
        ];
        let evidence_source: Sql = text_or_null(record, "manual_submit_evidence_source").into();
        let db = &self.connection;

        let (changed, inserted) = immediate(db, || {
            db.execute(
                "
            INSERT OR IGNORE INTO provider_turn_owners(
                owner_id, app_session_id, recovery_generation, actor_role,
                foreground_gate_handle, created_at
            ) VALUES(?, ?, ?, ?, ?, ?)
            ",
                params![
                    owner_id,
                    ownership.string("app_session_id"),
                    ownership.string("recovery_generation"),
                    ownership.string("actor_role"),
                    ownership.string("foreground_gate_handle"),
                    now
                ],
            )?;
            let existing: Option<(Sql, [Sql; 5])> = db
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
                .optional()?;
            if let Some((state, previous)) = existing {
                // A steered prompt can share the physical Codex turn id. Keep
                // its one completion bound to the latest submitted input,
                // rather than leaving the original intent active.
                let steered =
                    matches!(&state, Sql::Text(state) if state == "active") && identity != previous;
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
                return Ok((steered, false));
            }

            let active: Vec<Sql> = db
                .prepare(
                    "
                    SELECT turn_id, state FROM provider_turns
                     WHERE owner_id=? AND state='active'
                       AND COALESCE(provider_session_id, '')=?
                    ",
                )?
                .query_map(
                    params![owner_id, record.text("provider_session_id")],
                    |row| row.get(0),
                )?
                .collect::<rusqlite::Result<_>>()?;
            for previous_id in active {
                let previous_id = sql_to_json(previous_id).py_str();
                let event_id = stable_event_id(
                    "supersede",
                    &[previous_id.clone().into(), turn_id.clone().into()],
                );
                db.execute(
                    "
                        INSERT OR IGNORE INTO provider_turn_transitions(
                            event_id, turn_id, event_type, from_state, to_state,
                            occurred_at, release_reason
                        ) VALUES(?, ?, 'superseded', 'active', 'orphaned', ?, ?)
                        ",
                    params![event_id, previous_id, now, release_reason],
                )?;
                db.execute(
                    "
                        UPDATE provider_turns
                           SET state='orphaned', release_reason=?, updated_at=?
                         WHERE turn_id=? AND state='active'
                        ",
                    params![release_reason, now, previous_id],
                )?;
            }
            let created_at = match record.truthy("created_at") {
                Some(value) => value
                    .py_float()
                    .ok_or(Error::Invalid("could not convert created_at to float"))?,
                None => now,
            };
            db.execute(
                "
                    INSERT INTO provider_turns(
                        turn_id, owner_id, app_session_id, recovery_generation, actor_role,
                        foreground_gate_handle, provider, provider_session_id,
                        native_session_id, native_turn_id, local_turn_seq, origin,
                        intent_id, command_seq, command_id, manual_submission_id,
                        manual_submit_evidence_source, state, release_reason,
                        created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', NULL, ?, ?)
                    ",
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
                "
                    INSERT INTO provider_turn_transitions(
                        event_id, turn_id, event_type, from_state, to_state,
                        occurred_at, release_reason
                    ) VALUES(?, ?, 'prompt_submitted', NULL, 'active', ?, NULL)
                    ",
                params![
                    stable_event_id("activate", &[turn_id.clone().into()]),
                    turn_id,
                    now
                ],
            )?;
            Ok((true, true))
        })?;
        if changed {
            self.project()?;
        }
        Ok(inserted)
    }

    /// Moves the turn `record` names to a terminal state. `false` when the
    /// turn is unknown, no longer active, or this transition already happened:
    /// exactly one caller wins. With `event_id` the transition's identity is
    /// that event's rather than the state change's.
    pub fn transition(
        &self,
        record: &Dict,
        to_state: TurnState,
        event_type: &str,
        release_reason: &str,
        now: Option<f64>,
        event_id: Option<&str>,
    ) -> Result<bool> {
        let now = now.unwrap_or_else(database::now);
        let Some(turn_id) = turn_id(record) else {
            return Ok(false);
        };
        let db = &self.connection;
        let moved = immediate(db, || {
            let Some(current) = turn_state(db, &turn_id)? else {
                return Ok(false);
            };
            if !TurnState::parse(&current).is_some_and(|current| current.may_become(to_state)) {
                return Ok(false);
            }
            let event_id = match event_id.filter(|id| !id.is_empty()) {
                Some(event_id) => stable_event_id(event_id, &[turn_id.clone().into()]),
                None => stable_event_id(
                    event_type,
                    &[
                        turn_id.clone().into(),
                        to_state.as_str().into(),
                        release_reason.into(),
                    ],
                ),
            };
            let inserted = db.execute(
                "
                    INSERT OR IGNORE INTO provider_turn_transitions(
                        event_id, turn_id, event_type, from_state, to_state,
                        occurred_at, release_reason
                    ) VALUES(?, ?, ?, ?, ?, ?, ?)
                    ",
                params![
                    event_id,
                    turn_id,
                    event_type,
                    current,
                    to_state.as_str(),
                    now,
                    release_reason
                ],
            )?;
            if inserted != 1 {
                return Ok(false);
            }
            db.execute(
                "UPDATE provider_turns SET state=?, release_reason=?, updated_at=? WHERE turn_id=?",
                params![to_state.as_str(), release_reason, now, turn_id],
            )?;
            Ok(true)
        })?;
        if moved {
            self.project()?;
        }
        Ok(moved)
    }

    /// The state of the turn `record` names, when the tables hold it.
    pub fn state_for(&self, record: &Dict) -> Result<Option<String>> {
        match turn_id(record) {
            Some(turn_id) => turn_state(&self.connection, &turn_id),
            None => Ok(None),
        }
    }

    /// Ends every active turn of one owner's provider session, once per
    /// `event_id`. Returns the number of turns ended.
    pub fn terminate_owner(
        &self,
        ownership: &Dict,
        provider_session_id: &str,
        release_reason: &str,
        event_id: &str,
        now: Option<f64>,
    ) -> Result<usize> {
        let now = now.unwrap_or_else(database::now);
        let Some(owner_id) = owner_id(ownership) else {
            return Ok(0);
        };
        if provider_session_id.is_empty() || event_id.is_empty() {
            return Ok(0);
        }
        let db = &self.connection;
        let changed = immediate(db, || {
            let turns: Vec<Sql> = db
                .prepare(
                    "
                    SELECT turn_id FROM provider_turns
                     WHERE owner_id=? AND provider_session_id=? AND state='active'
                    ",
                )?
                .query_map(params![owner_id, provider_session_id], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            let mut changed = 0;
            for turn_id in turns {
                let turn_id = sql_to_json(turn_id).py_str();
                let inserted = db.execute(
                    "
                        INSERT OR IGNORE INTO provider_turn_transitions(
                            event_id, turn_id, event_type, from_state, to_state,
                            occurred_at, release_reason
                        ) VALUES(?, ?, 'provider_terminated', 'active', 'terminated', ?, ?)
                        ",
                    params![
                        stable_event_id(event_id, &[turn_id.clone().into()]),
                        turn_id,
                        now,
                        release_reason
                    ],
                )?;
                if inserted != 1 {
                    continue;
                }
                db.execute(
                    "
                        UPDATE provider_turns
                           SET state='terminated', release_reason=?, updated_at=?
                         WHERE turn_id=? AND state='active'
                        ",
                    params![release_reason, now, turn_id],
                )?;
                changed += 1;
            }
            Ok(changed)
        })?;
        if changed > 0 {
            self.project()?;
        }
        Ok(changed)
    }

    /// Reserves the one `effect_kind` effect of a command's turn: by intent
    /// when the command names one, else by command. Refused when the turn is
    /// unknown or revoked, and for every caller after the first.
    pub fn reserve_effect(
        &self,
        command: &Dict,
        effect_kind: &str,
        now: Option<f64>,
    ) -> Result<EffectReservation> {
        let now = now.unwrap_or_else(database::now);
        let owner_id = owner_id(command);
        let intent_id = command.text("intent_id");
        let command_seq = integer(command, "relay_command_seq");
        let command_id = command.text("relay_command_id");
        let Some(owner_id) = owner_id else {
            return Ok(EffectReservation::refused("ownership_or_command_missing"));
        };
        if intent_id.is_empty() && (command_seq.is_none() || command_id.is_empty()) {
            return Ok(EffectReservation::refused("ownership_or_command_missing"));
        }
        let db = &self.connection;
        immediate(db, || {
            let (row, authority_identity): (Option<(Sql, Sql)>, String) = if intent_id.is_empty() {
                let seq = command_seq.unwrap_or_default();
                (
                    db.query_row(
                        "
                        SELECT turn_id, state FROM provider_turns
                         WHERE owner_id=? AND command_seq=? AND command_id=?
                         ORDER BY updated_at DESC LIMIT 1
                        ",
                        params![owner_id, seq, command_id],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .optional()?,
                    format!("{seq}:{command_id}"),
                )
            } else {
                (
                    db.query_row(
                        "
                        SELECT turn_id, state FROM provider_turns
                         WHERE owner_id=? AND intent_id=?
                         ORDER BY updated_at DESC LIMIT 1
                        ",
                        params![owner_id, intent_id],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .optional()?,
                    intent_id.clone(),
                )
            };
            let Some((turn_id, state)) = row else {
                return Ok(EffectReservation::refused("turn_missing"));
            };
            let state = sql_to_json(state).py_str();
            if TurnState::parse(&state).is_some_and(TurnState::revokes_effects) {
                return Ok(EffectReservation::refused("turn_revoked"));
            }
            if !intent_id.is_empty() && intent_cancelled(db, &intent_id)? {
                return Ok(EffectReservation::refused("turn_revoked"));
            }
            let authority_key = stable_event_id(
                "authority",
                &[
                    owner_id.clone().into(),
                    authority_identity.into(),
                    effect_kind.into(),
                ],
            );
            let effect_id = stable_event_id("effect", &[authority_key.clone().into()]);
            let inserted = db.execute(
                "
                    INSERT OR IGNORE INTO provider_turn_effects(
                        effect_id, authority_key, turn_id, intent_id, effect_kind,
                        state, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, 'reserved', ?, ?)
                    ",
                params![
                    effect_id,
                    authority_key,
                    turn_id,
                    Some(intent_id.as_str()).filter(|id| !id.is_empty()),
                    effect_kind,
                    now,
                    now
                ],
            )?;
            Ok(EffectReservation {
                accepted: inserted == 1,
                effect_id: Some(effect_id),
                reason: if inserted == 1 { "" } else { "duplicate" },
            })
        })
    }

    /// Linearises revocation against the first delivery attempt: a reserved
    /// effect becomes `authorized`, or `failed` when its turn or intent was
    /// revoked meanwhile.
    pub fn authorize_effect_delivery(&self, effect_id: &str, now: Option<f64>) -> Result<bool> {
        let now = now.unwrap_or_else(database::now);
        let db = &self.connection;
        immediate(db, || {
            let row: Option<(Sql, Sql, Sql)> = db
                .query_row(
                    "
                    SELECT effects.state AS effect_state,
                           effects.intent_id AS intent_id,
                           turns.state AS turn_state
                      FROM provider_turn_effects AS effects
                      JOIN provider_turns AS turns ON turns.turn_id=effects.turn_id
                     WHERE effects.effect_id=?
                    ",
                    [effect_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;
            let Some((effect_state, intent_id, turn_state)) = row else {
                return Ok(false);
            };
            if sql_to_json(effect_state).py_str() != EffectState::Reserved.as_str() {
                return Ok(false);
            }
            let intent_id = sql_text(intent_id);
            let revoked = TurnState::parse(&sql_to_json(turn_state).py_str())
                .is_some_and(TurnState::revokes_effects)
                || (!intent_id.is_empty() && intent_cancelled(db, &intent_id)?);
            let state = if revoked {
                EffectState::Failed
            } else {
                EffectState::Authorized
            };
            db.execute(
                "UPDATE provider_turn_effects SET state=?, updated_at=? WHERE effect_id=?",
                params![state.as_str(), now, effect_id],
            )?;
            Ok(!revoked)
        })
    }

    /// Records the delivery attempt: `delivered` only for an authorised
    /// effect that was delivered, else `failed`.
    pub fn finish_effect(&self, effect_id: &str, delivered: bool, now: Option<f64>) -> Result<()> {
        let now = now.unwrap_or_else(database::now);
        let db = &self.connection;
        immediate(db, || {
            let state: Option<Sql> = db
                .query_row(
                    "
                    SELECT state AS effect_state
                      FROM provider_turn_effects
                     WHERE effect_id=?
                    ",
                    [effect_id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(state) = state.map(|state| sql_to_json(state).py_str()) else {
                return Ok(());
            };
            let Some(state) = EffectState::parse(&state)
                .filter(|state| matches!(state, EffectState::Reserved | EffectState::Authorized))
            else {
                return Ok(());
            };
            let finished = if delivered && state == EffectState::Authorized {
                EffectState::Delivered
            } else {
                EffectState::Failed
            };
            db.execute(
                "UPDATE provider_turn_effects SET state=?, updated_at=? WHERE effect_id=?",
                params![finished.as_str(), now, effect_id],
            )?;
            Ok(())
        })
    }

    /// Rewrites the JSON projection Swift reads, when this broker has one.
    pub fn project(&self) -> Result<()> {
        match &self.projection_path {
            Some(path) => project(&self.connection, path),
            None => Ok(()),
        }
    }

    /// Turns of one native provider session, shaped like the version 1
    /// ledger. RR-465: the hook falls back to these when a bridge restart
    /// removed the ledger while the turn was still running.
    pub fn session_records(&self, native_session_id: &str) -> Result<Vec<Dict>> {
        let mut statement = self.connection.prepare(
            "
                SELECT * FROM provider_turns WHERE native_session_id=?
                 ORDER BY updated_at, created_at, turn_id
                ",
        )?;
        let records = statement
            .query_map([native_session_id], projection_record)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(records)
    }

    /// Every row of one of the broker's `TABLES`.
    pub fn table_records(&self, table: &str) -> Result<Vec<Dict>> {
        if !TABLES.contains(&table) {
            return Err(Error::Invalid("unsupported provider-turn table"));
        }
        let mut statement = self.connection.prepare(&format!("SELECT * FROM {table}"))?;
        let records = statement
            .query_map([], row_dict)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(records)
    }
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
