//! `relay-rs reply`: publish the foreground reply for the claimed voice
//! command. The Rust form of `services/relay_reply.py`; see
//! docs/specs/hook-contract.md.
//!
//! The helper owns FIFO framing and command correlation so providers never
//! build Relay control envelopes themselves. Diagnostics omit reply text,
//! prompt text, command ids and raw payloads.

use std::time::{Duration, Instant};

use crate::json::{self, Dict, Value, py_strip};
use crate::support::{
    self, FOREGROUND_OWNERSHIP_FIELDS, current_or_preserved, env_or, env_text, intent_cancelled,
    is_foreground_owner, read_json_file, relay_command_key, write_fifo_line,
};

const ORCHESTRATOR_REPLY_PREFIX: &str = "__ORCHESTRATOR_REPLY__:";

/// How long a reply may wait for the bridge to drain its FIFO.
const FIFO_WAIT: Duration = Duration::from_secs(5);

fn session_key() -> String {
    let key = env_text("RELAY_SESSION_KEY");
    if !key.is_empty() {
        return key;
    }
    let spool = env_text("RELAY_SESSION_SPOOL_DIR");
    let spool = spool.trim_end_matches('/');
    spool.rsplit('/').next().unwrap_or_default().to_string()
}

/// RR-401: the state file is shared, so a reply is judged against its own
/// session's newest command, not another session's newer one.
fn claimed_reply_authorized(
    claim: &Dict,
    key: &(i64, String),
    state: &Dict,
    session_key: &str,
) -> bool {
    if intent_cancelled(state, claim) {
        return false;
    }
    let own_session = state
        .get("session_commands")
        .and_then(Value::as_dict)
        .filter(|_| !session_key.is_empty())
        .and_then(|sessions| sessions.get(session_key))
        .and_then(Value::as_dict);
    current_or_preserved(key, own_session.unwrap_or(state))
}

/// The one explicit foreground-reply envelope, as sorted JSON.
fn encode_orchestrator_reply(
    reply: &str,
    claim: &Dict,
    key: &(i64, String),
    ownership: &Dict,
) -> String {
    let mut payload = Dict::new();
    payload.insert("relay_command_id", key.1.clone());
    payload.insert("relay_command_seq", key.0);
    payload.insert("text", reply);
    if let Some(intent_id) = claim.present("intent_id") {
        payload.insert("intent_id", intent_id.clone());
    }
    for field in FOREGROUND_OWNERSHIP_FIELDS {
        payload.insert(field, ownership.string(field));
    }
    // RR-401: the shared bridge routes the reply to its origin session.
    for (field, value) in [
        ("session_key", session_key()),
        ("provider_session_id", env_text("RELAY_PROVIDER_SESSION_ID")),
    ] {
        if !value.is_empty() {
            payload.insert(field, value);
        }
    }
    format!(
        "{ORCHESTRATOR_REPLY_PREFIX}{}",
        json::dumps_sorted(&Value::Dict(payload))
    )
}

/// Python reads stdin as text with universal newlines.
fn stdin_text(data: &[u8]) -> String {
    String::from_utf8_lossy(data)
        .replace("\r\n", "\n")
        .replace('\r', "\n")
}

/// Writes one reply line when the claimed command is still current, and says
/// why not otherwise.
fn publish_current_reply(text: &str) -> Result<(), &'static str> {
    let ownership = support::ownership_from_environment();
    if !is_foreground_owner(&ownership) {
        return Err("foreground ownership unavailable");
    }
    let claim = read_json_file(&env_or(
        "VOICE_COMMAND_CLAIM_FILE",
        "/tmp/voice_cmd_claimed.json",
    ));
    let Some(key) = relay_command_key(&claim) else {
        return Err("claimed command unavailable");
    };
    let state = read_json_file(&env_or(
        "VOICE_COMMAND_STATE_FILE",
        "/tmp/voice_command_state.json",
    ));
    if !claimed_reply_authorized(&claim, &key, &state, &session_key()) {
        return Err("claimed command is not current");
    }
    let reply = py_strip(text);
    if reply.is_empty() {
        return Err("final text unavailable");
    }
    let line = encode_orchestrator_reply(reply, &claim, &key, &ownership);
    let fifo = env_or("VOICE_FIFO", "/tmp/voice_in.fifo");
    match write_fifo_line(&fifo, &line, Instant::now() + FIFO_WAIT) {
        Ok(true) => Ok(()),
        Ok(false) => Err("Relay bridge unavailable"),
        Err(_) => Err("Relay bridge write failed"),
    }
}

/// Always exits 0: a reply that may not be published is dropped.
pub fn run() -> u8 {
    if let Err(reason) = publish_current_reply(&stdin_text(&support::read_stdin())) {
        eprintln!("[relay_reply] reply not emitted: {reason}");
    }
    0
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
    fn reply_is_judged_against_its_own_session_when_the_state_names_it() {
        let claim = dict(
            r#"{"relay_command_id": "cmd-7", "relay_command_seq": 7, "intent_id": "intent-7"}"#,
        );
        let key = (7, "cmd-7".to_string());
        let newer = r#""relay_command_id": "cmd-9", "relay_command_seq": 9"#;
        let own = r#"{"relay_command_id": "cmd-7", "relay_command_seq": 7}"#;
        let shared = dict(&format!(
            r#"{{{newer}, "session_commands": {{"session-1": {own}}}}}"#
        ));
        assert!(claimed_reply_authorized(&claim, &key, &shared, "session-1"));
        assert!(!claimed_reply_authorized(
            &claim,
            &key,
            &shared,
            "session-2"
        ));
        assert!(!claimed_reply_authorized(&claim, &key, &shared, ""));
        let cancelled = dict(&format!(
            r#"{{{newer}, "cancelled_intent_ids": ["intent-7"], "session_commands": {{"session-1": {own}}}}}"#
        ));
        assert!(!claimed_reply_authorized(
            &claim,
            &key,
            &cancelled,
            "session-1"
        ));
    }

    #[test]
    fn stdin_newlines_are_translated_like_python_text_mode() {
        assert_eq!(stdin_text(b"a\r\nb\rc\n"), "a\nb\nc\n");
        assert_eq!(stdin_text(b"caf\xc3\xa9 \xff"), "caf\u{e9} \u{fffd}");
    }
}
