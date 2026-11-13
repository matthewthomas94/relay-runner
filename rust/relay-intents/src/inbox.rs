//! The durable ordered inbox in front of Relay's ready-file transport:
//! `services/intent_inbox.py`.
//!
//! Every intent has stable intent, delivery, claim and ack identities. A
//! session's mailbox holds one unacknowledged intent at a time; its queue is
//! delivered in command, item and arrival order. With a turn projection path
//! the inbox also records its lifecycle events on the provider-turn tables in
//! the same transaction, and rewrites the projection after each change.

use std::fs;
use std::path::Path;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};

use crate::broker::{self, AUTHORITATIVE_REPLY, ensure_broker_schema, record_intent_events};
use crate::database::{self, LockWait, bind, immediate, placeholders, row_dict, sql_to_json};
use crate::json::{self, Dict, Value};
use crate::model::{
    CommandKey, IntentState, TurnState, normalize_recovery_generation, recovery_generation_text,
    session_key,
};
use crate::{Error, Result};

pub const SCHEMA_VERSION: i64 = 6;

/// The route of work a sidecar lane runs; it never takes the mailbox.
pub const SIDECAR_ROUTE: &str = "run_sidecar";

/// Byte for byte the tables of `IntentInbox.__init__`, so a table either
/// implementation creates has the same `sqlite_master` text. The journal mode
/// is set when the connection opens.
const SCHEMA: &str = "
                CREATE TABLE IF NOT EXISTS inbox_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS intents (
                    ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                    intent_id TEXT NOT NULL UNIQUE,
                    command_seq INTEGER NOT NULL,
                    command_id TEXT NOT NULL,
                    within_turn_order INTEGER NOT NULL DEFAULT 1,
                    prompt TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    route TEXT NOT NULL,
                    state TEXT NOT NULL,
                    delivery_id TEXT NOT NULL UNIQUE,
                    claim_id TEXT,
                    ack_id TEXT,
                    created_at REAL NOT NULL,
                    delivered_at REAL,
                    claimed_at REAL,
                    acked_at REAL,
                    cancelled_at REAL,
                    transport TEXT,
                    lease_attempts INTEGER NOT NULL DEFAULT 0,
                    recovered_at REAL,
                    recovery_generation TEXT NOT NULL DEFAULT '0',
                    recovery_decision TEXT,
                    session_key TEXT NOT NULL DEFAULT ''
                );
                ";

/// How `IntentInbox::open` treats the database it finds.
#[derive(Clone, Debug, Default)]
pub struct InboxOptions {
    /// The v2 turn projection. When set, lifecycle events are recorded on
    /// the provider-turn tables; when unset (the broker's `legacy` mode) they
    /// are not.
    pub provider_turn_projection_path: Option<String>,
    /// Holds recovered work as `recovery_pending` until continuity recovery
    /// releases it.
    pub hold_recovered_delivery: bool,
    pub lock_wait: LockWait,
}

/// One intent's place in the queue, without its prompt or metadata: the
/// entries of `deliverable_commands` and `source_command_intents`.
#[derive(Clone, Debug, PartialEq)]
pub struct IntentSummary {
    pub relay_command_seq: i64,
    pub relay_command_id: String,
    pub within_turn_order: i64,
    pub intent_id: String,
    pub route: String,
    pub state: String,
}

impl IntentSummary {
    const COLUMNS: &str = "command_seq, command_id, within_turn_order, intent_id, route, state";

    fn read(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            relay_command_seq: row.get(0)?,
            relay_command_id: row.get(1)?,
            within_turn_order: row.get(2)?,
            intent_id: row.get(3)?,
            route: row.get(4)?,
            state: row.get(5)?,
        })
    }

    pub fn to_dict(&self) -> Dict {
        let mut record = Dict::new();
        record.insert("relay_command_seq", self.relay_command_seq);
        record.insert("relay_command_id", self.relay_command_id.as_str());
        record.insert("within_turn_order", self.within_turn_order);
        record.insert("intent_id", self.intent_id.as_str());
        record.insert("route", self.route.as_str());
        record.insert("state", self.state.as_str());
        record
    }
}

/// The uncertain mailbox lease that holds the queue after a restart, without
/// its private prompt.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryBlocker {
    pub intent_id: String,
    pub command_seq: i64,
    pub command_id: String,
    pub recovered_at: Option<f64>,
}

impl RecoveryBlocker {
    pub fn to_dict(&self) -> Dict {
        let mut record = Dict::new();
        record.insert("intent_id", self.intent_id.as_str());
        record.insert("command_seq", self.command_seq);
        record.insert("command_id", self.command_id.as_str());
        record.insert("recovered_at", self.recovered_at);
        record
    }
}

/// Routes an intent's metadata to its session's `(command, metadata)`
/// mailbox paths, or `None` for the default mailbox.
pub type MailboxRoute<'a> = &'a dyn Fn(&Dict) -> Option<(String, String)>;

/// Work a non-mailbox lane owns.
#[derive(Clone, Debug)]
pub struct PendingWork {
    pub prompt: String,
    pub metadata: Value,
}

/// The columns of one `intents` row the inbox decides on.
struct IntentRow {
    ordinal: i64,
    intent_id: String,
    command_seq: i64,
    command_id: String,
    within_turn_order: i64,
    prompt: String,
    metadata_json: String,
    state: String,
    delivery_id: String,
    claim_id: Option<String>,
    ack_id: Option<String>,
    claimed_at: Option<f64>,
    recovery_generation: String,
    recovery_decision: Option<String>,
}

impl IntentRow {
    fn read(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            ordinal: row.get("ordinal")?,
            intent_id: row.get("intent_id")?,
            command_seq: row.get("command_seq")?,
            command_id: row.get("command_id")?,
            within_turn_order: row.get("within_turn_order")?,
            prompt: row.get("prompt")?,
            metadata_json: row.get("metadata_json")?,
            state: row.get("state")?,
            delivery_id: row.get("delivery_id")?,
            claim_id: row.get("claim_id")?,
            ack_id: row.get("ack_id")?,
            claimed_at: row.get("claimed_at")?,
            recovery_generation: row.get("recovery_generation")?,
            recovery_decision: row.get("recovery_decision")?,
        })
    }

    fn state(&self) -> Option<IntentState> {
        IntentState::parse(&self.state)
    }

    fn metadata(&self) -> Result<Dict> {
        metadata_dict(&self.metadata_json)
    }
}

fn metadata_value(text: &str) -> Result<Value> {
    json::parse(text).ok_or(Error::Invalid("intent metadata is not JSON"))
}

fn metadata_dict(text: &str) -> Result<Dict> {
    match metadata_value(text)? {
        Value::Dict(metadata) => Ok(metadata),
        _ => Err(Error::Invalid("intent metadata is not a JSON object")),
    }
}

/// `metadata.get(key)` when it is an object, else an empty one.
fn object_field(metadata: &Dict, key: &str) -> Dict {
    match metadata.get(key) {
        Some(Value::Dict(item)) => item.clone(),
        _ => Dict::new(),
    }
}

/// `a.get(key_a) or b.get(key_b) or …`: the first truthy value of the
/// `(object, key)` lookups, in order.
fn first_truthy<'a>(lookups: &[(&'a Dict, &str)]) -> Option<&'a Value> {
    lookups.iter().find_map(|(source, key)| source.truthy(key))
}

/// `json.loads(Path(path).read_text())` as an object, else `{}`.
fn read_leased(path: &str) -> Dict {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| json::parse(&text))
        .and_then(|value| match value {
            Value::Dict(leased) => Some(leased),
            _ => None,
        })
        .unwrap_or_default()
}

/// Removes the mailbox files when they hold one of `intent_ids`.
fn release_lease(command_path: &str, metadata_path: &str, intent_ids: &[String]) {
    let leased = read_leased(metadata_path).string("intent_id");
    if intent_ids.contains(&leased) {
        for path in [command_path, metadata_path] {
            let _ = fs::remove_file(path);
        }
    }
}

fn intent_ids(statement_rows: Vec<Sql>) -> Vec<String> {
    statement_rows
        .into_iter()
        .map(|value| sql_to_json(value).py_str())
        .collect()
}

/// SQLite-backed FIFO with stable intent, delivery, claim and ack identity.
pub struct IntentInbox {
    connection: Connection,
    projection_path: Option<String>,
}

impl IntentInbox {
    /// `IntentInbox(path, ...)`: creates or migrates the schema, then moves
    /// the leases a previous bridge left. A delivered intent goes back to
    /// `pending` (`resume_exact`); a claimed one is uncertain and becomes
    /// `review_required` (`foreground_review`). With
    /// `hold_recovered_delivery`, pending and delivered work waits as
    /// `recovery_pending` instead.
    pub fn open(path: &str, options: InboxOptions) -> Result<Self> {
        let connection = database::connect(path, options.lock_wait)?;
        let inbox = Self {
            connection,
            projection_path: options.provider_turn_projection_path,
        };
        let db = &inbox.connection;
        let hold = i64::from(options.hold_recovered_delivery);
        let resumed_state = if options.hold_recovered_delivery {
            IntentState::RecoveryPending
        } else {
            IntentState::Pending
        };
        immediate(db, || {
            db.execute_batch(SCHEMA)?;
            inbox.migrate()?;
            let mut recovered = Vec::new();
            if inbox.events_enabled() {
                let ids: Vec<Sql> = db
                    .prepare(
                        "SELECT intent_id FROM intents \
                         WHERE state IN ('delivered', 'claimed') \
                         OR (? = 1 AND state='pending')",
                    )?
                    .query_map([hold], |row| row.get(0))?
                    .collect::<rusqlite::Result<_>>()?;
                recovered = intent_ids(ids);
                ensure_broker_schema(db)?;
            }
            db.execute(
                RECOVER_LEASES,
                params![resumed_state.as_str(), database::now(), hold],
            )?;
            inbox.events(
                recovered.iter().map(String::as_str),
                "inbox_recovered",
                &format!("startup:{}", database::now_ns()),
                database::now(),
                None,
            )?;
            Ok(())
        })?;
        inbox.project_provider_turns()?;
        Ok(inbox)
    }

    /// The column additions and backfills of schema versions 2 to 6.
    fn migrate(&self) -> Result<()> {
        let db = &self.connection;
        let columns: Vec<String> = db
            .prepare("PRAGMA table_info(intents)")?
            .query_map([], |row| row.get(1))?
            .collect::<rusqlite::Result<_>>()?;
        let has = |name: &str| columns.iter().any(|column| column == name);
        if !has("ack_id") {
            db.execute("ALTER TABLE intents ADD COLUMN ack_id TEXT", [])?;
        }
        if !has("lease_attempts") {
            db.execute(
                "ALTER TABLE intents ADD COLUMN lease_attempts INTEGER NOT NULL DEFAULT 0",
                [],
            )?;
        }
        if !has("recovered_at") {
            db.execute("ALTER TABLE intents ADD COLUMN recovered_at REAL", [])?;
        }
        if !has("within_turn_order") {
            db.execute(
                "ALTER TABLE intents ADD COLUMN within_turn_order INTEGER NOT NULL DEFAULT 1",
                [],
            )?;
        }
        if !has("recovery_generation") {
            db.execute(
                "ALTER TABLE intents ADD COLUMN recovery_generation TEXT NOT NULL DEFAULT '0'",
                [],
            )?;
            for (intent_id, metadata) in self.all_metadata()? {
                let Some(Value::Dict(metadata)) = json::parse(&metadata) else {
                    continue;
                };
                let generation = metadata.get("recovery_generation").unwrap_or(&Value::Null);
                let Some(generation) = normalize_recovery_generation(generation) else {
                    continue;
                };
                db.execute(
                    "UPDATE intents SET recovery_generation=? WHERE intent_id=?",
                    params![generation, intent_id],
                )?;
            }
        }
        if !has("recovery_decision") {
            db.execute("ALTER TABLE intents ADD COLUMN recovery_decision TEXT", [])?;
        }
        if !has("session_key") {
            // RR-400: one shared bridge inbox serves every live session, so
            // rows carry their owner. Backfill from the RR-398 routing key.
            db.execute(
                "ALTER TABLE intents ADD COLUMN session_key TEXT NOT NULL DEFAULT ''",
                [],
            )?;
            for (intent_id, metadata) in self.all_metadata()? {
                let Some(Value::Dict(metadata)) = json::parse(&metadata) else {
                    continue;
                };
                let owner = session_key(&metadata);
                if !owner.is_empty() {
                    db.execute(
                        "UPDATE intents SET session_key=? WHERE intent_id=?",
                        params![owner, intent_id],
                    )?;
                }
            }
        }
        db.execute("DROP INDEX IF EXISTS intents_command_key", [])?;
        db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS intents_command_item_key \
             ON intents(command_seq, command_id, within_turn_order)",
            [],
        )?;
        db.execute(
            "INSERT OR REPLACE INTO inbox_meta(key, value) VALUES('schema_version', ?)",
            [SCHEMA_VERSION.to_string()],
        )?;
        Ok(())
    }

    fn all_metadata(&self) -> Result<Vec<(String, String)>> {
        Ok(self
            .connection
            .prepare("SELECT intent_id, metadata_json FROM intents")?
            .query_map([], |row| {
                Ok((
                    sql_to_json(row.get(0)?).py_str(),
                    sql_to_json(row.get(1)?).py_str(),
                ))
            })?
            .collect::<rusqlite::Result<_>>()?)
    }

    /// Whether lifecycle events go to the provider-turn tables.
    fn events_enabled(&self) -> bool {
        self.projection_path.is_some()
    }

    fn project_provider_turns(&self) -> Result<()> {
        match &self.projection_path {
            Some(path) => broker::project(&self.connection, path),
            None => Ok(()),
        }
    }

    fn events<'a>(
        &self,
        intent_ids: impl IntoIterator<Item = &'a str>,
        event_type: &str,
        event_scope: &str,
        occurred_at: f64,
        terminal: Option<(TurnState, &str)>,
    ) -> Result<usize> {
        if !self.events_enabled() {
            return Ok(0);
        }
        record_intent_events(
            &self.connection,
            intent_ids,
            event_type,
            event_scope,
            occurred_at,
            terminal,
        )
    }

    /// Adds one intent, `pending` (or `cancelled` when its item already is),
    /// and returns the metadata as stored. An intent already in the inbox is
    /// kept as it is.
    pub fn enqueue(&self, prompt: &str, metadata: &Dict, route: &str) -> Result<Dict> {
        let key = CommandKey::of(metadata);
        let intent_id = first_truthy(&[(metadata, "intent_id"), (metadata, "relay_command_id")])
            .map(|value| json::py_strip(&value.py_str()).to_string())
            .unwrap_or_default();
        let Some(key) = key.filter(|_| !intent_id.is_empty()) else {
            return Err(Error::Invalid(
                "intent inbox requires stable command and intent identity",
            ));
        };
        let identity = |field: &str, prefix: &str| {
            metadata
                .truthy(field)
                .map_or_else(|| format!("{prefix}:{intent_id}"), Value::py_str)
        };
        let delivery_id = identity("intent_delivery_id", "delivery");
        let claim_id = identity("intent_claim_id", "claim");
        let ack_id = identity("intent_ack_id", "ack");
        let mut stored = metadata.clone();
        stored.insert("intent_id", intent_id.as_str());
        stored.insert("intent_delivery_id", delivery_id.as_str());
        stored.insert("intent_claim_id", claim_id.as_str());
        stored.insert("intent_ack_id", ack_id.as_str());
        stored.insert("intent_inbox_version", SCHEMA_VERSION);
        let generation = stored
            .truthy("recovery_generation")
            .cloned()
            .unwrap_or_else(|| Value::from("0"));
        let recovery_generation = normalize_recovery_generation(&generation)
            .ok_or(Error::Invalid("invalid recovery generation"))?;
        let work_item = object_field(&stored, "voice_work_item");
        let within_turn_order = first_truthy(&[
            (&stored, "within_turn_order"),
            (&work_item, "within_turn_order"),
        ])
        .map_or(Some(1), Value::py_int)
        .map_or(1, |order| order.max(1));
        stored.insert("within_turn_order", within_turn_order);
        let lifecycle_state = first_truthy(&[
            (&stored, "lifecycle_state"),
            (&work_item, "lifecycle_state"),
        ])
        .map_or_else(|| "recognized".to_string(), Value::py_str);
        let initial_state = if matches!(lifecycle_state.as_str(), "cancelled" | "abandoned") {
            IntentState::Cancelled
        } else {
            IntentState::Pending
        };
        self.connection.execute(
            "
                INSERT OR IGNORE INTO intents(
                    intent_id, command_seq, command_id, within_turn_order, prompt, metadata_json,
                    route, state, delivery_id, claim_id, ack_id, created_at,
                    recovery_generation, session_key
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ",
            params![
                intent_id,
                key.seq,
                key.id,
                within_turn_order,
                prompt,
                json::dumps_sorted(&Value::Dict(stored.clone())),
                route,
                initial_state.as_str(),
                delivery_id,
                claim_id,
                ack_id,
                database::now(),
                recovery_generation,
                session_key(&stored)
            ],
        )?;
        Ok(stored)
    }

    /// Retires foreground prompts that cannot belong to this live session:
    /// open work from another recovery generation. With `session_key` only
    /// that session's rows (and unrouted legacy rows) are retired; other live
    /// sessions keep their own generations. The mailbox is released when it
    /// holds a retired intent.
    pub fn retire_stale_foreground(
        &self,
        recovery_generation: &str,
        command_path: &str,
        metadata_path: &str,
        before_command_seq: Option<i64>,
        session_key: Option<&str>,
    ) -> Result<usize> {
        if !recovery_generation_text(recovery_generation) {
            return Err(Error::Invalid("invalid recovery generation"));
        }
        let now = database::now();
        let db = &self.connection;
        let ids = immediate(db, || {
            let ids: Vec<Sql> = db
                .prepare(
                    "
                SELECT intent_id FROM intents
                 WHERE recovery_generation != ?
                   AND (? IS NULL OR command_seq < ?)
                   AND (? IS NULL OR session_key IN (?, ''))
                   AND route!='run_sidecar'
                   AND state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending')
                ",
                )?
                .query_map(
                    params![
                        recovery_generation,
                        before_command_seq,
                        before_command_seq,
                        session_key,
                        session_key
                    ],
                    |row| row.get(0),
                )?
                .collect::<rusqlite::Result<_>>()?;
            let ids = intent_ids(ids);
            if ids.is_empty() {
                return Ok(ids);
            }
            db.execute(
                &format!(
                    "UPDATE intents SET state='cancelled', cancelled_at=?, \
                     recovery_decision='stale_generation_retired' \
                     WHERE intent_id IN ({})",
                    placeholders(ids.len())
                ),
                params_from_iter(
                    std::iter::once(Sql::Real(now)).chain(ids.iter().cloned().map(Sql::Text)),
                ),
            )?;
            self.events(
                ids.iter().map(String::as_str),
                "intent_cancelled",
                &format!("generation:{recovery_generation}"),
                now,
                Some((TurnState::Cancelled, "stale_generation_retired")),
            )?;
            Ok(ids)
        })?;
        if ids.is_empty() {
            return Ok(0);
        }
        release_lease(command_path, metadata_path, &ids);
        self.project_provider_turns()?;
        Ok(ids.len())
    }

    /// Retires never-claimed work owned by sessions that have ended (RR-447).
    /// Claimed and uncertain leases stay for explicit review; only work no
    /// provider received is cancelled, and nothing is replayed.
    pub fn retire_ended_sessions(&self, is_live: impl Fn(&str) -> bool) -> Result<usize> {
        let now = database::now();
        let db = &self.connection;
        let ids = immediate(db, || {
            let rows: Vec<(Sql, Sql)> = db
                .prepare(
                    "
                SELECT intent_id, session_key FROM intents
                 WHERE session_key != ''
                   AND route != 'run_sidecar'
                   AND state IN ('pending', 'delivered', 'recovery_pending')
                ",
                )?
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
            let ids: Vec<String> = rows
                .into_iter()
                .filter(|(_, owner)| !is_live(&sql_to_json(owner.clone()).py_str()))
                .map(|(intent_id, _)| sql_to_json(intent_id).py_str())
                .collect();
            if ids.is_empty() {
                return Ok(ids);
            }
            db.execute(
                &format!(
                    "UPDATE intents SET state='cancelled', cancelled_at=?, \
                     recovery_decision='ended_session_retired' \
                     WHERE intent_id IN ({})",
                    placeholders(ids.len())
                ),
                params_from_iter(
                    std::iter::once(Sql::Real(now)).chain(ids.iter().cloned().map(Sql::Text)),
                ),
            )?;
            self.events(
                ids.iter().map(String::as_str),
                "intent_cancelled",
                "ended_session",
                now,
                Some((TurnState::Cancelled, "ended_session_retired")),
            )?;
            Ok(ids)
        })?;
        if ids.is_empty() {
            return Ok(0);
        }
        self.project_provider_turns()?;
        Ok(ids.len())
    }

    /// Releases only an exact unclaimed intent, once, for its original
    /// generation.
    pub fn resume_after_recovery(
        &self,
        intent_id: &str,
        recovery_generation: &str,
        now: Option<f64>,
    ) -> Result<bool> {
        if !recovery_generation_text(recovery_generation) {
            return Ok(false);
        }
        let now = now.unwrap_or_else(database::now);
        let resumed = format!("resumed:{recovery_generation}");
        let db = &self.connection;
        immediate(db, || {
            let row: Option<(String, String, Option<String>)> = db
                .query_row(
                    "SELECT state, recovery_generation, recovery_decision \
                     FROM intents WHERE intent_id=?",
                    [intent_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;
            let Some((state, generation, decision)) = row else {
                return Ok(false);
            };
            if generation != recovery_generation
                || decision.as_deref() == Some(resumed.as_str())
                || !matches!(
                    IntentState::parse(&state),
                    Some(
                        IntentState::Pending
                            | IntentState::Delivered
                            | IntentState::RecoveryPending
                    )
                )
            {
                return Ok(false);
            }
            db.execute(
                "UPDATE intents SET state='pending', recovered_at=?, recovery_decision=? \
                 WHERE intent_id=? AND state IN ('pending', 'delivered', 'recovery_pending')",
                params![now, resumed, intent_id],
            )?;
            Ok(true)
        })
    }

    /// Cancels every open foreground intent of an older command.
    pub fn cancel_pending_before(&self, command_seq: i64) -> Result<usize> {
        let now = database::now();
        let db = &self.connection;
        let cancelled = immediate(db, || {
            let ids: Vec<Sql> = db
                .prepare(
                    "
                SELECT intent_id FROM intents
                 WHERE command_seq < ?
                   AND route != 'run_sidecar'
                   AND state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending')
                ",
                )?
                .query_map([command_seq], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            let cancelled = db.execute(
                "
                UPDATE intents
                   SET state='cancelled', cancelled_at=?
                 WHERE command_seq < ?
                   AND route != 'run_sidecar'
                   AND state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending')
                ",
                params![now, command_seq],
            )?;
            let ids = intent_ids(ids);
            self.events(
                ids.iter().map(String::as_str),
                "intent_cancelled",
                &format!("before:{command_seq}"),
                now,
                Some((
                    TurnState::Cancelled,
                    "intent_cancelled_before_newer_command",
                )),
            )?;
            Ok(cancelled)
        })?;
        self.project_provider_turns()?;
        Ok(cancelled)
    }

    /// Cancels only the resolved item or ticket and releases its mailbox
    /// lease. Every scope, `all_work` too, is limited to the issuing session.
    /// Returns the cancelled intent ids, newest first.
    pub fn cancel_scoped(
        &self,
        metadata: &Dict,
        command_path: Option<&str>,
        metadata_path: Option<&str>,
    ) -> Result<Vec<String>> {
        let (scope, target_ids, target) = cancellation_fields(metadata);
        if !matches!(scope.as_str(), "item" | "ticket" | "all_work") {
            return Ok(Vec::new());
        }
        let db = &self.connection;
        let matched = immediate(db, || {
            let rows: Vec<(String, String)> = db
                .prepare(
                    "
                SELECT * FROM intents
                 WHERE state IN ('pending', 'delivered', 'claimed', 'review_required', 'recovery_pending', 'acked')
                   AND session_key=?
                 ORDER BY command_seq DESC, within_turn_order DESC, ordinal DESC
                ",
                )?
                .query_map([session_key(metadata)], |row| {
                    Ok((row.get("intent_id")?, row.get("metadata_json")?))
                })?
                .collect::<rusqlite::Result<_>>()?;
            let matched: Vec<String> = if scope == "all_work" {
                rows.into_iter().map(|(intent_id, _)| intent_id).collect()
            } else if !target_ids.is_empty() {
                rows.into_iter()
                    .map(|(intent_id, _)| intent_id)
                    .filter(|intent_id| target_ids.contains(intent_id))
                    .collect()
            } else {
                let mut matched: Vec<String> = rows
                    .into_iter()
                    .filter(|(_, metadata)| row_matches_target(metadata, target.as_deref()))
                    .map(|(intent_id, _)| intent_id)
                    .collect();
                if scope == "item" {
                    matched.truncate(1);
                }
                matched
            };
            if matched.is_empty() {
                return Ok(matched);
            }
            db.execute(
                &format!(
                    "UPDATE intents SET state='cancelled', cancelled_at=? \
                     WHERE intent_id IN ({})",
                    placeholders(matched.len())
                ),
                params_from_iter(
                    std::iter::once(Sql::Real(database::now()))
                        .chain(matched.iter().cloned().map(Sql::Text)),
                ),
            )?;
            let event_scope =
                first_truthy(&[(metadata, "intent_id"), (metadata, "relay_command_id")])
                    .map_or_else(|| "scoped".to_string(), Value::py_str);
            self.events(
                matched.iter().map(String::as_str),
                "intent_cancelled",
                &event_scope,
                database::now(),
                Some((TurnState::Cancelled, &format!("intent_{scope}_cancelled"))),
            )?;
            Ok(matched)
        })?;
        if matched.is_empty() {
            return Ok(matched);
        }
        if let (Some(command_path), Some(metadata_path)) = (command_path, metadata_path)
            && !command_path.is_empty()
            && !metadata_path.is_empty()
            && Path::new(metadata_path).exists()
        {
            release_lease(command_path, metadata_path, &matched);
        }
        self.project_provider_turns()?;
        Ok(matched)
    }

    /// A later voice turn can steer an active PM turn. Siblings of one source
    /// turn stay ordered, and a completed final still waits for its
    /// authoritative reply effect.
    fn awaits_source_predecessor(&self, row: &IntentRow) -> Result<bool> {
        if !self.events_enabled() {
            return Ok(false);
        }
        Ok(self
            .connection
            .query_row(
                AWAITS_SOURCE_PREDECESSOR,
                params![row.command_seq, row.command_id, AUTHORITATIVE_REPLY],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// Atomically leases the oldest deliverable intent into its session's
    /// mailbox: the prompt to `command_path` and the metadata, with its
    /// delivery id, to `metadata_path`. `paths_for` routes an intent to its
    /// own session's mailbox; the given paths are used when it is omitted or
    /// returns `None`. Ordering and the unacknowledged-delivery gate apply per
    /// session, so one session's in-flight turn never blocks another's queue.
    pub fn materialize_next(
        &self,
        command_path: &str,
        metadata_path: &str,
        transport: &str,
        paths_for: Option<MailboxRoute<'_>>,
    ) -> Result<Option<Dict>> {
        if paths_for.is_none()
            && (Path::new(command_path).exists() || Path::new(metadata_path).exists())
        {
            return Ok(None);
        }
        let db = &self.connection;
        let delivered = immediate(db, || {
            let unacked: Vec<(String, String)> = db
                .prepare(
                    "
                SELECT session_key, metadata_json
                  FROM intents
                 WHERE route != 'run_sidecar'
                   AND state IN ('delivered', 'claimed', 'review_required')
                ",
                )?
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
            let mut blocked: Vec<String> = unacked.iter().map(|(owner, _)| owner.clone()).collect();
            // An ended session's work is routed to the focused mailbox, so an
            // in-flight turn also blocks every intent bound for its mailbox.
            let mut busy_mailboxes: Vec<String> = Vec::new();
            if let Some(paths_for) = paths_for {
                for (_, metadata) in &unacked {
                    let paths = paths_for(&metadata_dict(metadata)?);
                    busy_mailboxes
                        .push(paths.map_or_else(|| command_path.to_string(), |paths| paths.0));
                }
            }
            let candidates: Vec<(IntentRow, String)> = db
                .prepare(
                    "
                SELECT *
                  FROM intents
                 WHERE state='pending' AND route != 'run_sidecar'
                 ORDER BY command_seq, within_turn_order, ordinal
                ",
                )?
                .query_map([], |row| {
                    Ok((IntentRow::read(row)?, row.get("session_key")?))
                })?
                .collect::<rusqlite::Result<_>>()?;
            let mut selected = None;
            for (candidate, owner) in candidates {
                if blocked.contains(&owner) {
                    continue;
                }
                // Only a session's oldest pending intent is eligible.
                blocked.push(owner);
                if self.awaits_source_predecessor(&candidate)? {
                    continue;
                }
                let metadata = candidate.metadata()?;
                let mut paths = (command_path.to_string(), metadata_path.to_string());
                if let Some(paths_for) = paths_for {
                    paths = paths_for(&metadata).unwrap_or(paths);
                    if busy_mailboxes.contains(&paths.0)
                        || Path::new(&paths.0).exists()
                        || Path::new(&paths.1).exists()
                    {
                        continue;
                    }
                }
                selected = Some((candidate, metadata, paths));
                break;
            }
            let Some((row, mut metadata, (command_path, metadata_path))) = selected else {
                return Ok(None);
            };
            metadata.insert("intent_delivery_id", row.delivery_id.as_str());
            let command_tmp = format!("{command_path}.tmp");
            let metadata_tmp = format!("{metadata_path}.tmp");
            fs::write(
                &metadata_tmp,
                json::dumps_sorted(&Value::Dict(metadata.clone())),
            )?;
            fs::write(&command_tmp, &row.prompt)?;
            fs::rename(&metadata_tmp, &metadata_path)?;
            fs::rename(&command_tmp, &command_path)?;
            db.execute(
                "
                UPDATE intents
                   SET state='delivered', delivered_at=?, transport=?,
                       lease_attempts=lease_attempts + 1
                 WHERE ordinal=? AND state='pending'
                ",
                params![database::now(), transport, row.ordinal],
            )?;
            let changed = self.events(
                [row.intent_id.as_str()],
                "intent_delivered",
                &row.delivery_id,
                database::now(),
                None,
            )? > 0;
            Ok(Some((metadata, changed)))
        })?;
        let Some((metadata, projection_changed)) = delivered else {
            return Ok(None);
        };
        if projection_changed {
            self.project_provider_turns()?;
        }
        Ok(Some(metadata))
    }

    /// Records a consumer's claim: a delivered or pending intent becomes
    /// `claimed`, and once `provider_turn_seen` it is `acked`, as is a
    /// recovered claim awaiting review. Acknowledging a resumed intent
    /// releases its next held sibling. `false` when the claim names no intent
    /// of its command.
    pub fn observe_claim(
        &self,
        claimed: &Dict,
        provider_turn_seen: bool,
        now: Option<f64>,
    ) -> Result<bool> {
        let Some(key) = CommandKey::of(claimed) else {
            return Ok(false);
        };
        let intent_id = claimed.text("intent_id");
        let now = now.unwrap_or_else(database::now);
        let db = &self.connection;
        let observed = immediate(db, || {
            let row = if intent_id.is_empty() {
                db.query_row(
                    "SELECT * FROM intents WHERE command_seq=? AND command_id=? \
                     ORDER BY within_turn_order, ordinal LIMIT 1",
                    params![key.seq, key.id],
                    IntentRow::read,
                )
                .optional()?
            } else {
                db.query_row(
                    "SELECT * FROM intents WHERE intent_id=?",
                    [&intent_id],
                    IntentRow::read,
                )
                .optional()?
            };
            let Some(row) = row else {
                return Ok(None);
            };
            if row.command_seq != key.seq || row.command_id != key.id {
                return Ok(None);
            }
            let mut changed = false;
            let mut state = row.state();
            let identity = |field: &str, stored: &Option<String>, prefix: &str| {
                claimed
                    .truthy(field)
                    .map(Value::py_str)
                    .or_else(|| stored.clone().filter(|stored| !stored.is_empty()))
                    .unwrap_or_else(|| format!("{prefix}:{}:{}", key.seq, key.id))
            };
            let claim_id = identity("intent_claim_id", &row.claim_id, "claim");
            let ack_id = identity("intent_ack_id", &row.ack_id, "ack");
            if matches!(state, Some(IntentState::Delivered | IntentState::Pending)) {
                db.execute(
                    "
                    UPDATE intents
                       SET state='claimed', claim_id=?, ack_id=?, claimed_at=?
                     WHERE intent_id=?
                    ",
                    params![claim_id, ack_id, now, row.intent_id],
                )?;
                changed |= self.events(
                    [row.intent_id.as_str()],
                    "intent_claimed",
                    &claim_id,
                    now,
                    None,
                )? > 0;
                state = Some(IntentState::Claimed);
            }
            let recovered_claim =
                state == Some(IntentState::ReviewRequired) && row.claimed_at.is_some();
            if provider_turn_seen && (state == Some(IntentState::Claimed) || recovered_claim) {
                db.execute(
                    "
                    UPDATE intents SET state='acked', ack_id=?, acked_at=?
                     WHERE intent_id=?
                    ",
                    params![ack_id, now, row.intent_id],
                )?;
                changed |= self.events(
                    [row.intent_id.as_str()],
                    "intent_acknowledged",
                    &ack_id,
                    now,
                    None,
                )? > 0;
                let resumed = format!("resumed:{}", row.recovery_generation);
                if row.recovery_decision.as_deref() == Some(resumed.as_str()) {
                    self.resume_next_sibling(&row, &resumed, now)?;
                }
            }
            Ok(Some(changed))
        })?;
        let Some(projection_changed) = observed else {
            return Ok(false);
        };
        if projection_changed {
            self.project_provider_turns()?;
        }
        Ok(true)
    }

    fn resume_next_sibling(&self, row: &IntentRow, resumed: &str, now: f64) -> Result<()> {
        let db = &self.connection;
        let sibling: Option<(String, String)> = db
            .query_row(
                "
                        SELECT intent_id, recovery_generation
                          FROM intents
                         WHERE command_seq=? AND command_id=?
                           AND state='recovery_pending'
                           AND (within_turn_order > ?
                                OR (within_turn_order=? AND ordinal > ?))
                         ORDER BY within_turn_order, ordinal
                         LIMIT 1
                        ",
                params![
                    row.command_seq,
                    row.command_id,
                    row.within_turn_order,
                    row.within_turn_order,
                    row.ordinal
                ],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((sibling, generation)) = sibling
            && generation == row.recovery_generation
        {
            db.execute(
                "UPDATE intents SET state='pending', recovered_at=?, \
                 recovery_decision=? WHERE intent_id=? \
                 AND state='recovery_pending' AND recovery_generation=?",
                params![now, resumed, sibling, row.recovery_generation],
            )?;
        }
        Ok(())
    }

    /// Acknowledges recovered claims only once their exact turn is terminal.
    /// Returns how many were acknowledged.
    pub fn reconcile_terminal_claims(&self, now: Option<f64>) -> Result<usize> {
        if !self.events_enabled() {
            return Ok(0);
        }
        let now = now.unwrap_or_else(database::now);
        let mut terminal: Vec<&str> = TurnState::ALL
            .iter()
            .filter(|state| state.is_terminal())
            .map(|state| state.as_str())
            .collect();
        terminal.sort_unstable();
        let db = &self.connection;
        let (count, projection_changed) = immediate(db, || {
            let rows: Vec<(String, Option<String>)> = db
                .prepare(&format!(
                    "
                SELECT intent_id, ack_id
                  FROM intents
                 WHERE state='review_required'
                   AND claimed_at IS NOT NULL
                   AND EXISTS (
                       SELECT 1
                         FROM provider_turns
                        WHERE provider_turns.intent_id=intents.intent_id
                          AND provider_turns.command_seq=intents.command_seq
                          AND provider_turns.command_id=intents.command_id
                          AND provider_turns.state IN ({})
                   )
                 ORDER BY ordinal
                ",
                    placeholders(terminal.len())
                ))?
                .query_map(params_from_iter(&terminal), |row| {
                    Ok((row.get(0)?, row.get(1)?))
                })?
                .collect::<rusqlite::Result<_>>()?;
            let mut changed = false;
            for (intent_id, ack_id) in &rows {
                let ack_id = ack_id
                    .clone()
                    .filter(|ack_id| !ack_id.is_empty())
                    .unwrap_or_else(|| format!("ack:{intent_id}"));
                db.execute(
                    "UPDATE intents SET state='acked', ack_id=?, acked_at=?, \
                     recovery_decision='terminal_claim_reconciled' \
                     WHERE intent_id=? AND state='review_required'",
                    params![ack_id, now, intent_id],
                )?;
                changed |= record_intent_events(
                    db,
                    [intent_id.as_str()],
                    "intent_acknowledged",
                    &ack_id,
                    now,
                    None,
                )? > 0;
            }
            Ok((rows.len(), changed))
        })?;
        if projection_changed {
            self.project_provider_turns()?;
        }
        Ok(count)
    }

    /// Durable work owned by a non-mailbox execution lane.
    pub fn pending_for_route(&self, route: &str) -> Result<Vec<PendingWork>> {
        let rows: Vec<(String, String)> = self
            .connection
            .prepare(
                "
                SELECT prompt, metadata_json
                  FROM intents
                 WHERE state='pending' AND route=?
                 ORDER BY command_seq, within_turn_order, ordinal
                ",
            )?
            .query_map([route], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        rows.into_iter()
            .map(|(prompt, metadata)| {
                Ok(PendingWork {
                    prompt,
                    metadata: metadata_value(&metadata)?,
                })
            })
            .collect()
    }

    pub fn deliverable_commands(&self) -> Result<Vec<IntentSummary>> {
        Ok(self.state_snapshot()?.1)
    }

    /// Privacy-safe lifecycle state for every sibling of one source turn.
    pub fn source_command_intents(&self, command: Option<&Dict>) -> Result<Vec<IntentSummary>> {
        let Some(key) = command.and_then(CommandKey::of) else {
            return Ok(Vec::new());
        };
        Ok(self
            .connection
            .prepare(&format!(
                "SELECT {} FROM intents WHERE command_seq=? AND command_id=? \
                 ORDER BY within_turn_order, ordinal",
                IntentSummary::COLUMNS
            ))?
            .query_map(params![key.seq, key.id], IntentSummary::read)?
            .collect::<rusqlite::Result<_>>()?)
    }

    /// The newest command's metadata and the deliverable queue.
    pub fn state_snapshot(&self) -> Result<(Option<Value>, Vec<IntentSummary>)> {
        let latest: Option<String> = self
            .connection
            .query_row(
                "
                SELECT metadata_json
                  FROM intents
                 ORDER BY command_seq DESC, within_turn_order DESC, ordinal DESC
                 LIMIT 1
                ",
                [],
                |row| row.get(0),
            )
            .optional()?;
        let deliverable = self
            .connection
            .prepare(&format!(
                "SELECT {} FROM intents WHERE state IN ('pending', 'delivered', 'claimed') \
                 ORDER BY command_seq, within_turn_order, ordinal",
                IntentSummary::COLUMNS
            ))?
            .query_map([], IntentSummary::read)?
            .collect::<rusqlite::Result<_>>()?;
        let latest = latest.map(|text| metadata_value(&text)).transpose()?;
        Ok((latest, deliverable))
    }

    /// Every `intents` row and column, in queue order.
    pub fn records(&self) -> Result<Vec<Dict>> {
        Ok(self
            .connection
            .prepare("SELECT * FROM intents ORDER BY command_seq, within_turn_order, ordinal")?
            .query_map([], row_dict)?
            .collect::<rusqlite::Result<_>>()?)
    }

    /// Retires only an exact uncertain claim after an authorised user
    /// restart: the intent, command and every lease id must match, and no
    /// active turn may still be running it.
    pub fn retire_replaced_claim(&self, expected: &Dict) -> Result<bool> {
        let Some(key) = CommandKey::of(expected) else {
            return Ok(false);
        };
        let db = &self.connection;
        immediate(db, || {
            let row: Option<(Sql, Sql, Sql, Sql)> = db
                .query_row(
                    "SELECT intent_id, delivery_id, claim_id, ack_id FROM intents \
                     WHERE intent_id=? AND command_seq=? AND command_id=? \
                     AND state IN ('claimed','review_required') AND route!='run_sidecar'",
                    params![bind(expected.get("intent_id"))?, key.seq, key.id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .optional()?;
            let Some((intent_id, delivery_id, claim_id, ack_id)) = row else {
                return Ok(false);
            };
            for (field, column) in [
                ("intent_delivery_id", delivery_id),
                ("intent_claim_id", claim_id),
                ("intent_ack_id", ack_id),
            ] {
                let matches = expected
                    .truthy(field)
                    .and_then(Value::as_str)
                    .is_some_and(|value| matches!(&column, Sql::Text(stored) if stored == value));
                if !matches {
                    return Ok(false);
                }
            }
            if self.events_enabled()
                && db
                    .query_row(
                        "SELECT 1 FROM provider_turns WHERE intent_id=? AND state='active' LIMIT 1",
                        [&intent_id],
                        |_| Ok(()),
                    )
                    .optional()?
                    .is_some()
            {
                return Ok(false);
            }
            db.execute(
                "UPDATE intents SET state='cancelled', cancelled_at=?, \
                 recovery_decision='user_restart_skipped_uncertain' WHERE intent_id=?",
                params![database::now(), intent_id],
            )?;
            Ok(true)
        })
    }

    /// The one uncertain mailbox lease that holds the queue, if any.
    pub fn recovery_blocker(&self) -> Result<Option<RecoveryBlocker>> {
        Ok(self
            .connection
            .query_row(
                "SELECT intent_id, command_seq, command_id, recovered_at FROM intents \
                 WHERE state='review_required' AND route!='run_sidecar' \
                 ORDER BY command_seq, within_turn_order, ordinal LIMIT 1",
                [],
                |row| {
                    Ok(RecoveryBlocker {
                        intent_id: row.get(0)?,
                        command_seq: row.get(1)?,
                        command_id: row.get(2)?,
                        recovered_at: row.get(3)?,
                    })
                },
            )
            .optional()?)
    }

    /// Explicit compare-and-skip of the recovery blocker: a stale
    /// confirmation cannot cancel newer work, and a blocker whose turn is
    /// known belongs to acknowledgement instead.
    pub fn skip_recovery_blocker(&self, expected: &Value) -> Result<bool> {
        let db = &self.connection;
        let skipped = immediate(db, || {
            // Serialised with native acknowledgements on other connections.
            let Some(current) = self.recovery_blocker()? else {
                return Ok(false);
            };
            if !json::py_eq(&Value::Dict(current.to_dict()), expected) {
                return Ok(false);
            }
            // Active turns may still execute; terminal turns may have just
            // finished.
            if self.events_enabled()
                && db
                    .query_row(
                        "SELECT 1 FROM provider_turns WHERE intent_id=? LIMIT 1",
                        [&current.intent_id],
                        |_| Ok(()),
                    )
                    .optional()?
                    .is_some()
            {
                return Ok(false);
            }
            let now = database::now();
            db.execute(
                "UPDATE intents SET state='cancelled', cancelled_at=?, \
                 recovery_decision='user_skipped_uncertain' \
                 WHERE intent_id=? AND state='review_required'",
                params![now, current.intent_id],
            )?;
            self.events(
                [current.intent_id.as_str()],
                "intent_cancelled",
                "user_skipped_uncertain",
                now,
                Some((TurnState::Cancelled, "user_skipped_uncertain")),
            )?;
            Ok(true)
        })?;
        if skipped {
            self.project_provider_turns()?;
        }
        Ok(skipped)
    }

    pub fn cancelled_intent_ids(&self) -> Result<Vec<String>> {
        Ok(self
            .connection
            .prepare(
                "SELECT intent_id FROM intents WHERE state='cancelled' \
                 ORDER BY command_seq, within_turn_order, ordinal",
            )?
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()?)
    }
}

/// Moves the leases a previous bridge left, as `IntentInbox.__init__` does.
const RECOVER_LEASES: &str = "
                UPDATE intents
                   SET state=CASE
                       WHEN state IN ('pending', 'delivered') THEN ?
                       ELSE 'review_required'
                   END,
                       recovered_at=?,
                       recovery_decision=CASE
                           WHEN state IN ('pending', 'delivered') THEN 'resume_exact'
                           ELSE 'foreground_review'
                       END
                 WHERE state IN ('delivered', 'claimed')
                    OR (? = 1 AND state='pending')
                ";

/// An acknowledged sibling of the same source turn whose turn is still
/// running, or finished without its authoritative reply.
const AWAITS_SOURCE_PREDECESSOR: &str = "
            SELECT intents.ordinal
             FROM intents
             WHERE intents.state='acked'
               AND intents.command_seq=?
               AND intents.command_id=?
               AND (
                   EXISTS (
                       SELECT 1
                         FROM provider_turns
                        WHERE provider_turns.intent_id=intents.intent_id
                          AND provider_turns.command_seq=intents.command_seq
                          AND provider_turns.command_id=intents.command_id
                          AND provider_turns.state='active'
                   )
                   OR (
                       EXISTS (
                           SELECT 1
                             FROM provider_turns
                            WHERE provider_turns.intent_id=intents.intent_id
                              AND provider_turns.command_seq=intents.command_seq
                              AND provider_turns.command_id=intents.command_id
                              AND provider_turns.state='completed_final'
                       )
                       AND NOT EXISTS (
                           SELECT 1
                             FROM provider_turn_effects
                            WHERE provider_turn_effects.intent_id=intents.intent_id
                              AND provider_turn_effects.effect_kind=?
                              AND provider_turn_effects.state IN ('delivered', 'failed')
                       )
                   )
               )
             ORDER BY intents.command_seq, intents.within_turn_order,
                      intents.ordinal
             LIMIT 1
            ";

/// `_cancellation_fields`: the scope, the explicit target intents and the
/// target text of a cancelling command.
fn cancellation_fields(metadata: &Dict) -> (String, Vec<String>, Option<String>) {
    let item = object_field(metadata, "voice_work_item");
    let disposition = object_field(metadata, "work_disposition");
    let scope = first_truthy(&[
        (metadata, "cancellation_scope"),
        (&item, "cancellation_scope"),
        (&disposition, "cancellation_scope"),
    ])
    .map_or_else(|| "none".to_string(), Value::py_str);
    let target_ids = match first_truthy(&[
        (metadata, "target_intent_ids"),
        (&item, "target_intent_ids"),
    ]) {
        Some(Value::List(values)) => values
            .iter()
            .map(Value::py_str)
            .filter(|value| !value.is_empty())
            .collect(),
        _ => Vec::new(),
    };
    let target = first_truthy(&[
        (metadata, "target"),
        (&item, "target"),
        (metadata, "ticket_id"),
    ])
    .map(Value::py_str);
    (scope, target_ids, target)
}

/// `_row_matches_target`: the stored intent names the target as its ticket or
/// target, or its spoken text contains it.
fn row_matches_target(metadata_json: &str, target: Option<&str>) -> bool {
    let Some(target) = target else {
        return false;
    };
    let target = json::py_strip(target).to_lowercase();
    if target.is_empty() {
        return false;
    }
    let Some(Value::Dict(metadata)) = json::parse(metadata_json) else {
        return false;
    };
    let item = object_field(&metadata, "voice_work_item");
    let candidates = [
        metadata.text("ticket_id"),
        metadata.text("target"),
        item.text("target"),
    ];
    if candidates
        .iter()
        .any(|candidate| candidate.to_lowercase() == target)
    {
        return true;
    }
    first_truthy(&[(&item, "source_text"), (&metadata, "source_text")])
        .map(Value::py_str)
        .unwrap_or_default()
        .to_lowercase()
        .contains(&target)
}

/// `sync_deliverable_state`: folds the inbox's newest command, queue,
/// recovery blocker and cancellations into the command state file. A state
/// file naming a newer command keeps it; one naming this command keeps its
/// own fields over the stored ones.
pub fn sync_deliverable_state(state_path: &str, inbox: &IntentInbox) -> Result<()> {
    let (latest_command, deliverable) = inbox.state_snapshot()?;
    let mut payload = match fs::read(state_path) {
        Ok(bytes) => {
            let text = String::from_utf8(bytes)
                .map_err(|_| Error::Invalid("command state is not UTF-8"))?;
            match json::parse(&text) {
                Some(Value::Dict(payload)) => payload,
                _ => Dict::new(),
            }
        }
        Err(_) => Dict::new(),
    };
    let latest = match &latest_command {
        Some(Value::Dict(latest)) => Some(latest),
        _ => None,
    };
    let current_key = CommandKey::of(&payload);
    if let Some(latest_key) = CommandKey::of_value(latest_command.as_ref()) {
        let latest = latest.cloned().unwrap_or_default();
        match current_key {
            Some(current) if current == latest_key => {
                let mut merged = latest;
                merged.update(&payload);
                payload = merged;
            }
            Some(current) if current.seq >= latest_key.seq => {}
            _ => payload.update(&latest),
        }
    }
    payload.insert("intent_inbox_version", SCHEMA_VERSION);
    payload.insert(
        "deliverable_commands",
        deliverable
            .iter()
            .map(|summary| Value::Dict(summary.to_dict()))
            .collect::<Vec<_>>(),
    );
    payload.insert(
        "inbox_recovery_blocker",
        inbox.recovery_blocker()?.map(|blocker| blocker.to_dict()),
    );
    payload.insert(
        "cancelled_intent_ids",
        inbox
            .cancelled_intent_ids()?
            .into_iter()
            .map(Value::from)
            .collect::<Vec<_>>(),
    );
    let siblings = inbox.source_command_intents(Some(&payload))?;
    payload.insert(
        "source_command_intents",
        siblings
            .iter()
            .map(|summary| Value::Dict(summary.to_dict()))
            .collect::<Vec<_>>(),
    );
    let temporary = format!("{state_path}.tmp");
    fs::write(&temporary, json::dumps_sorted(&Value::Dict(payload)))?;
    fs::rename(&temporary, state_path)?;
    Ok(())
}
