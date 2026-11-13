//! `--context-continuation`: whether a request in one context may continue in
//! another. It reads the canonical turn and intent rows and never creates a
//! lease, replays a request or writes the inbox.

use std::path::Path;
use std::time::Duration;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params_from_iter};

use crate::json::{self, Dict, Value, py_eq_optional};
use crate::support::{Failure, read_json_file};

use super::broker::sql_to_json;

/// What names one foreground provider session.
const OWNER_FIELDS: [&str; 6] = [
    "provider",
    "provider_session_id",
    "native_session_id",
    "app_session_id",
    "recovery_generation",
    "foreground_gate_handle",
];
/// The columns a captured source carries, after the owner fields.
const TURN_IDENTITY_FIELDS: [&str; 8] = [
    "native_turn_id",
    "local_turn_seq",
    "owner_id",
    "origin",
    "intent_id",
    "command_seq",
    "command_id",
    "manual_submission_id",
];
/// Read beside the identity, but not part of a source.
const TURN_STATE_FIELDS: [&str; 3] = ["turn_id", "state", "created_at"];

/// The bridge's voice authorization ledger. The path is fixed, as it is in
/// the Python script.
const AUTHORIZATION_LEDGER: &str = "/tmp/voice_command_authorizations.json";
const BUSY_TIMEOUT: Duration = Duration::from_millis(250);

fn blocked(message: &str) -> Dict {
    let mut reply = Dict::new();
    reply.insert("status", "blocked");
    reply.insert("message", message);
    reply
}

fn has_owner(identity: &Dict) -> bool {
    OWNER_FIELDS
        .iter()
        .all(|field| identity.truthy(field).is_some())
}

/// A request value as SQLite binds it. A list or an object cannot be bound.
fn sql(value: Option<&Value>) -> Result<Sql, Failure> {
    Ok(match value {
        None | Some(Value::Null) => Sql::Null,
        Some(Value::Bool(flag)) => Sql::Integer(i64::from(*flag)),
        Some(Value::Int(number)) => Sql::Integer(*number),
        Some(Value::Float(number)) => Sql::Real(*number),
        Some(Value::Str(text)) => Sql::Text(text.clone()),
        Some(Value::BigInt(_) | Value::List(_) | Value::Dict(_)) => {
            return Err(Failure("ProgrammingError"));
        }
    })
}

fn owner_parameters(identity: &Dict) -> Result<Vec<Sql>, Failure> {
    OWNER_FIELDS
        .iter()
        .map(|field| sql(identity.get(field)))
        .collect()
}

fn owner_query() -> String {
    OWNER_FIELDS.map(|field| format!("{field}=?")).join(" AND ")
}

/// The foreground turns of one provider session, newest first.
fn session_turns(db: &Connection, source: &Dict) -> Result<Vec<Dict>, Failure> {
    let columns: Vec<&str> = OWNER_FIELDS
        .iter()
        .chain(&TURN_IDENTITY_FIELDS)
        .chain(&TURN_STATE_FIELDS)
        .copied()
        .collect();
    let mut statement = db.prepare(&format!(
        "SELECT {} FROM provider_turns WHERE {} AND actor_role='foreground_pm'
          ORDER BY created_at DESC, updated_at DESC",
        columns.join(", "),
        owner_query()
    ))?;
    let turns = statement
        .query_map(params_from_iter(owner_parameters(source)?), |row| {
            let mut turn = Dict::new();
            for (index, column) in columns.iter().enumerate() {
                turn.insert(column, sql_to_json(row.get(index)?));
            }
            Ok(turn)
        })?
        .collect::<rusqlite::Result<_>>()?;
    Ok(turns)
}

fn state_is(turn: &Dict, state: &str) -> bool {
    turn.get("state").is_some_and(|value| value.is_str(state))
}

/// Whether the voice intent behind `source` is acknowledged and its
/// authorization, when it has one, is still active.
fn parent_intent_refusal(db: &Connection, source: &Dict) -> Result<Option<&'static str>, Failure> {
    let intent_state: Option<Sql> = db
        .query_row(
            "SELECT state FROM intents WHERE intent_id=? AND command_seq=? AND command_id=?",
            [
                sql(source.get("intent_id"))?,
                sql(source.get("command_seq"))?,
                sql(source.get("command_id"))?,
            ],
            |row| row.get(0),
        )
        .optional()?;
    if !matches!(&intent_state, Some(Sql::Text(state)) if state == "acked") {
        return Ok(Some(
            "The parent voice intent is not acknowledged or was cancelled.",
        ));
    }
    let text = |value: Option<&Value>| value.unwrap_or(&Value::Null).py_str();
    let ledger = read_json_file(AUTHORIZATION_LEDGER);
    let mut granted = ledger
        .get("authorizations")
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .filter(|grant| {
            source
                .get("intent_id")
                .is_some_and(|intent_id| intent_id.is_str(&grant.string("intent_id")))
                && text(grant.get("relay_command_seq")) == text(source.get("command_seq"))
                && py_eq_optional(grant.get("relay_command_id"), source.get("command_id"))
        })
        .peekable();
    // Conversation-only voice turns have no mutation grant. Keep them bounded
    // by their canonical intent; never manufacture a grant.
    if granted.peek().is_some()
        && !granted.any(|grant| {
            grant
                .get("status")
                .is_some_and(|status| status.is_str("active"))
        })
    {
        return Ok(Some("The parent voice authorization was revoked."));
    }
    Ok(None)
}

fn lookup(request: &Dict, source: &Dict, database_path: &str) -> Result<Dict, Failure> {
    if !Path::new(database_path).is_absolute() {
        return Err(Failure("ValueError"));
    }
    let db = Connection::open_with_flags(
        database_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(BUSY_TIMEOUT)?;
    let operation = |name: &str| {
        request
            .get("operation")
            .is_some_and(|operation| operation.is_str(name))
    };
    let mut turns = session_turns(&db, source)?.into_iter();

    let (turn, source) = if operation("capture") {
        let Some(turn) = turns.next().filter(|turn| state_is(turn, "active")) else {
            return Ok(blocked(
                "Continuation requires the current native user turn.",
            ));
        };
        let mut captured = Dict::new();
        for field in OWNER_FIELDS.iter().chain(&TURN_IDENTITY_FIELDS) {
            if let Some(value) = turn.present(field) {
                captured.insert(field, value.py_str());
            }
        }
        let canonical = turn.present("turn_id").ok_or(Failure("KeyError"))?;
        captured.insert("canonical_turn_id", canonical.py_str());
        (turn, captured)
    } else {
        let canonical = source.get("canonical_turn_id");
        let Some(turn) = turns.find(|turn| py_eq_optional(turn.get("turn_id"), canonical)) else {
            return Ok(blocked("The source request is no longer canonical."));
        };
        let newer: Vec<Sql> = db
            .prepare(
                "SELECT origin FROM provider_turns
                  WHERE owner_id=? AND provider_session_id=? AND created_at>?",
            )?
            .query_map(
                [
                    sql(turn.get("owner_id"))?,
                    sql(source.get("provider_session_id"))?,
                    sql(turn.get("created_at"))?,
                ],
                |row| row.get(0),
            )?
            .collect::<rusqlite::Result<_>>()?;
        let manual = |origin: &Sql| matches!(origin, Sql::Text(origin) if origin == "manual");
        if !newer.is_empty() && (source.truthy("intent_id").is_none() || newer.iter().any(manual)) {
            return Ok(blocked(
                "A newer native request superseded this continuation.",
            ));
        }
        (turn, source.clone())
    };

    let active = state_is(&turn, "active");
    if !active && !state_is(&turn, "completed_final") && !state_is(&turn, "completed_manual") {
        return Ok(blocked(
            "The source request was cancelled or did not finish successfully.",
        ));
    }
    if source.truthy("intent_id").is_some()
        && let Some(refusal) = parent_intent_refusal(&db, &source)?
    {
        return Ok(blocked(refusal));
    }
    let mut reply = Dict::new();
    if operation("ack") {
        let destination = match request.truthy("destination") {
            Some(Value::Dict(destination)) if has_owner(destination) => destination,
            _ => return Ok(blocked("Destination identity is unavailable.")),
        };
        let mut parameters = owner_parameters(destination)?;
        parameters.push(sql(request.get("submission_id"))?);
        let accepted = db
            .prepare(&format!(
                "SELECT 1 FROM provider_turns WHERE {} AND actor_role='foreground_pm'
                    AND manual_submission_id=?",
                owner_query()
            ))?
            .exists(params_from_iter(parameters))?;
        reply.insert("status", if accepted { "consumed" } else { "waiting" });
        return Ok(reply);
    }
    reply.insert("status", if active { "active" } else { "ready" });
    reply.insert("source", source);
    Ok(reply)
}

/// The answer to one request: `status`, and a `message` or the `source`.
pub fn authority(request: &Dict, database_path: &str) -> Dict {
    let source = match request.truthy("source") {
        Some(Value::Dict(source)) if has_owner(source) => source,
        _ => return blocked("The exact source request identity is unavailable."),
    };
    lookup(request, source, database_path)
        .unwrap_or_else(|_| blocked("Canonical continuation authority is unavailable."))
}

/// The one line `--context-continuation` prints for the request on stdin.
pub fn answer(stdin: &[u8], database_path: &str) -> String {
    let reply = match json::parse_bytes(stdin) {
        Some(Value::Dict(request)) => authority(&request, database_path),
        Some(_) => {
            let mut reply = Dict::new();
            reply.insert("status", "blocked");
            reply
        }
        None => blocked("Invalid continuation request."),
    };
    json::dumps_compact(&Value::Dict(reply))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            _ => panic!("not an object: {text}"),
        }
    }

    #[test]
    fn requests_without_a_complete_source_are_blocked_before_the_inbox_is_opened() {
        let missing = "/nonexistent/relay-rs-test/inbox.sqlite3";
        let unavailable =
            r#"{"status":"blocked","message":"The exact source request identity is unavailable."}"#;
        for request in [
            "{}",
            r#"{"source": null}"#,
            r#"{"source": "session"}"#,
            r#"{"source": {"provider": "codex"}}"#,
        ] {
            assert_eq!(
                answer(request.as_bytes(), missing),
                unavailable,
                "{request}"
            );
        }
        assert_eq!(answer(b"[]", missing), r#"{"status":"blocked"}"#);
        assert_eq!(
            answer(b"{", missing),
            r#"{"status":"blocked","message":"Invalid continuation request."}"#
        );
    }

    #[test]
    fn an_inbox_that_cannot_be_read_is_blocked() {
        let source = r#"{"provider": "codex", "provider_session_id": "p", "native_session_id": "n",
            "app_session_id": "a", "recovery_generation": "g", "foreground_gate_handle": "h"}"#;
        let request = dict(&format!(r#"{{"operation": "check", "source": {source}}}"#));
        let unavailable = "Canonical continuation authority is unavailable.";
        for path in [
            "/nonexistent/relay-rs-test/inbox.sqlite3",
            "relative.sqlite3",
        ] {
            let reply = authority(&request, path);
            assert_eq!(reply.string("message"), unavailable, "{path}");
        }
    }

    #[test]
    fn only_scalars_bind_as_sql_parameters() {
        let values = dict(
            r#"{"text": "a", "seq": 7, "flag": true, "none": null, "list": [1], "big": 99999999999999999999}"#,
        );
        assert_eq!(sql(values.get("text")).unwrap(), Sql::Text("a".into()));
        assert_eq!(sql(values.get("seq")).unwrap(), Sql::Integer(7));
        assert_eq!(sql(values.get("flag")).unwrap(), Sql::Integer(1));
        assert_eq!(sql(values.get("none")).unwrap(), Sql::Null);
        assert_eq!(sql(values.get("missing")).unwrap(), Sql::Null);
        assert!(sql(values.get("list")).is_err());
        assert!(sql(values.get("big")).is_err());
    }
}
