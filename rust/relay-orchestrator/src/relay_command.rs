//! Voice-command freshness and mutation authorization:
//! `_relay_session_key`, `_relay_command_current`, `_validate_relay_command`
//! and `_relay_mutation_metadata` from `services/orchestrator.py`.

use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

use relay_intents::json::{self, Dict, Value};
use relay_services::authorization::{authorization_exists, validate_and_mark_mutation};

use crate::daemon::Paths;
use crate::failure::{Failure, Outcome};

/// `RELAY_SESSION_KEY_RE.fullmatch(key)`: `[a-z0-9-]{1,64}`.
fn is_session_key(key: &str) -> bool {
    (1..=64).contains(&key.len())
        && key
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

/// `str(value or "").strip()`.
fn stripped(value: Option<&Value>) -> String {
    match value {
        Some(value) if value.truthy() => json::py_strip(&value.py_str()).to_string(),
        _ => String::new(),
    }
}

/// `_relay_session_key(value)`.
pub fn relay_session_key(value: Option<&Value>) -> Outcome<Option<String>> {
    let key = stripped(value);
    if key.is_empty() {
        return Ok(None);
    }
    if !is_session_key(&key) {
        return Err(Failure::value("invalid relay_session_key"));
    }
    Ok(Some(key))
}

/// `_optional_relay_session_key(value)`: routing hints never fail a request.
pub fn optional_relay_session_key(value: Option<&Value>) -> Option<String> {
    relay_session_key(value).ok().flatten()
}

/// `_relay_command_state_file(relay_session_key)`: a keyed session reads only
/// its own spool, which must be a directory this user owns.
pub fn command_state_file(paths: &Paths, session_key: Option<&str>) -> Option<PathBuf> {
    let Some(key) = session_key else {
        return Some(paths.command_state_file.clone());
    };
    let spool = paths.session_spool_root.join(key);
    let info = std::fs::symlink_metadata(&spool).ok()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !info.file_type().is_dir() || info.uid() != uid {
        return None;
    }
    Some(spool.join("voice_command_state.json"))
}

/// `int(value)` for a JSON value, as Python's `int()` takes it.
fn python_int(value: &Value) -> Option<i64> {
    match value {
        Value::Str(text) => json::py_int_from_str(text),
        Value::Float(number) if number.is_finite() => Some(number.trunc() as i64),
        other => other.py_int(),
    }
}

/// `_relay_command_current(seq, id, relay_session_key=...)`.
pub fn relay_command_current(
    paths: &Paths,
    relay_command_seq: Option<&Value>,
    relay_command_id: &str,
    session_key: Option<&str>,
) -> bool {
    let Some(seq) = relay_command_seq.filter(|value| !matches!(value, Value::Null)) else {
        return false;
    };
    if relay_command_id.is_empty() {
        return false;
    }
    let Some(state_file) = command_state_file(paths, session_key) else {
        return false;
    };
    let Some(Value::Dict(current)) = crate::daemon::read_json(&state_file) else {
        return false;
    };
    let current_seq = current.get("relay_command_seq").and_then(python_int);
    let expected_seq = python_int(seq);
    match (current_seq, expected_seq) {
        (Some(current_seq), Some(expected_seq)) => {
            current_seq == expected_seq
                && stripped_or_empty(current.get("relay_command_id")) == relay_command_id
        }
        _ => false,
    }
}

/// `str(current.get("relay_command_id") or "")`.
fn stripped_or_empty(value: Option<&Value>) -> String {
    match value {
        Some(value) if value.truthy() => value.py_str(),
        _ => String::new(),
    }
}

/// The voice fields a mutating request may carry.
#[derive(Clone, Debug, Default)]
pub struct VoiceFields {
    pub relay_command_seq: Option<Value>,
    pub relay_command_id: Option<Value>,
    pub relay_intent_id: Option<Value>,
    pub relay_session_key: Option<Value>,
}

impl VoiceFields {
    /// The four fields of a request body.
    pub fn from_body(body: &Dict) -> Self {
        let field = |key: &str| body.get(key).cloned();
        Self {
            relay_command_seq: field("relay_command_seq"),
            relay_command_id: field("relay_command_id"),
            relay_intent_id: field("relay_intent_id"),
            relay_session_key: field("relay_session_key"),
        }
    }
}

/// `_validate_relay_command(seq, id, relay_intent_id=..., mutation=...,
/// relay_session_key=...)`.
pub fn validate_relay_command(
    paths: &Paths,
    voice: &VoiceFields,
    mutation: Option<&Dict>,
) -> Outcome<()> {
    let seq = voice
        .relay_command_seq
        .clone()
        .filter(|value| !matches!(value, Value::Null));
    let id = voice.relay_command_id.clone().filter(Value::truthy);
    if seq.is_none() && id.is_none() {
        return Ok(());
    }
    let session_key = relay_session_key(voice.relay_session_key.as_ref())?;
    let id_text = id.as_ref().map(Value::py_str).unwrap_or_default();
    let seq_value = seq.clone().unwrap_or(Value::Null);
    let id_value = voice.relay_command_id.clone().unwrap_or(Value::Null);
    let intent = voice
        .relay_intent_id
        .as_ref()
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default();
    let session = session_key.clone().unwrap_or_default();
    let current = relay_command_current(paths, seq.as_ref(), &id_text, session_key.as_deref());
    let mark = |mutation: &Dict| -> Outcome<()> {
        validate_and_mark_mutation(
            &paths.authorization_file,
            &seq_value,
            &id_value,
            mutation,
            &intent,
            &session,
            None,
        )?;
        Ok(())
    };
    if current {
        if let Some(mutation) = mutation
            && authorization_exists(&paths.authorization_file, &seq_value, &id_value, &session)
        {
            mark(mutation)?;
        }
        return Ok(());
    }
    if let Some(mutation) = mutation {
        return mark(mutation);
    }
    Err(Failure::value(
        "stale Relay command: a newer voice command has superseded this action",
    ))
}

/// `_relay_mutation_metadata(kind, ticket_id=, action_kind=, action_index=,
/// request_id=)`.
pub fn mutation_metadata(
    kind: &str,
    ticket_id: Option<&str>,
    action_kind: Option<&str>,
    action_index: Option<i64>,
    request_id: Option<&Value>,
) -> Dict {
    let mut mutation = Dict::new();
    mutation.insert("kind", kind);
    if let Some(ticket_id) = ticket_id.filter(|value| !value.is_empty()) {
        mutation.insert("ticket_id", json::py_strip(ticket_id).to_uppercase());
    }
    if let Some(action_kind) = action_kind.filter(|value| !value.is_empty()) {
        mutation.insert("action_kind", json::py_strip(action_kind));
    }
    if let Some(index) = action_index {
        mutation.insert("action_index", index);
    }
    if let Some(request_id) = request_id.filter(|value| value.truthy()) {
        mutation.insert("request_id", request_id.clone());
    }
    mutation
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_keys_are_lowercase_words() {
        assert!(is_session_key("relay-1"));
        assert!(!is_session_key("Relay"));
        assert!(!is_session_key(&"a".repeat(65)));
        assert_eq!(
            relay_session_key(Some(&Value::from("BAD KEY")))
                .unwrap_err()
                .message,
            "invalid relay_session_key"
        );
        assert_eq!(relay_session_key(Some(&Value::from("  "))).unwrap(), None);
    }

    #[test]
    fn mutation_metadata_uppercases_the_ticket() {
        let mutation = mutation_metadata(
            "dispatch_ticket",
            Some(" ct-1 "),
            None,
            Some(0),
            Some(&Value::from("r-1")),
        );
        assert_eq!(mutation.string("ticket_id"), "CT-1");
        assert_eq!(mutation.string("request_id"), "r-1");
        assert!(mutation.get("action_kind").is_none());
    }
}
