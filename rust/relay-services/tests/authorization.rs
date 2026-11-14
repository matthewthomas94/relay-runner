//! The daemon's half of the Relay command authorization ledger against
//! `services/relay_authorization.py` (RR-499).
//!
//! Python registers the grants (the voice bridge's half, three sessions so
//! the redirect revokes nothing); the same sequence of
//! validations and cancellations then runs in Python on one ledger and in
//! Rust on a copy, and the two files must stay byte-identical. The refusals
//! carry Python's messages, including the one the RR-485 session case reads
//! for an unregistered command.

mod common;

use std::fs;
use std::path::Path;

use relay_intents::json::{self, Dict, Value};
use relay_services::authorization::{
    authorization_exists, mark_mutations_canceled, mutation_fingerprint, validate_and_mark_mutation,
};

use common::{TempRoot, python, run_python};

const REGISTER: &str = r#"
import json, relay_authorization as a
path = sys.argv[1]
a.record_command_authorization(path, {"relay_command_seq": 1, "relay_command_id": "cmd-1",
    "action": "create_ticket", "source_text": "Make a ticket for RR-9", "intent_id": "i-1"},
    relationship="replacement", now=10.0)
a.record_command_authorization(path, {"relay_command_seq": 2, "relay_command_id": "cmd-2",
    "action": "dispatch_ticket", "ticket_id": "rr-7", "source_text": "Dispatch RR-7 and RR-8"},
    relationship="additive", session_key="spool-a", now=11.0)
a.record_command_authorization(path, {"relay_command_seq": 3, "relay_command_id": "cmd-3",
    "action": "update_ticket", "ticket_id": "RR-5", "source_text": "Actually change RR-5"},
    relationship="redirect", session_key="spool-c", now=12.0)
"#;

/// Each step: `[function, seq, id, mutation or mutations, extra]`, run by
/// both implementations; the outcome is the result's JSON or the error.
const STEPS: &str = r#"[
  ["validate", 1, "cmd-1", {"kind": "orchestrator_action", "action_kind": "create_ticket", "request_id": "r1"}, {}],
  ["validate", 1, "cmd-1", {"kind": "orchestrator_action", "action_kind": "create_ticket", "request_id": "r1"}, {}],
  ["validate", 1, "cmd-1", {"kind": "orchestrator_action", "action_kind": "launch", "request_id": "r2"}, {}],
  ["validate", 1, "cmd-1", {"kind": "orchestrator_action", "action_kind": "edit_ticket", "ticket_id": "rr-3"}, {"intent": "i-1"}],
  ["validate", 1, "cmd-1", {"kind": "orchestrator_action", "action_kind": "edit_ticket"}, {"intent": "other"}],
  ["validate", 2, "cmd-2", {"kind": "dispatch_ticket", "ticket_id": "RR-8"}, {"session": "spool-a"}],
  ["validate", 2, "cmd-2", {"kind": "dispatch_ticket", "ticket_id": "RR-9"}, {"session": "spool-a"}],
  ["validate", 2, "cmd-2", {"kind": "dispatch_ticket", "ticket_id": "RR-8"}, {"session": "spool-b"}],
  ["validate", 3, "cmd-3", {"kind": "dispatch_ticket", "ticket_id": "RR-5"}, {}],
  ["validate", 3, "cmd-3", {"kind": "dispatch_ticket", "ticket_id": "RR-6"}, {}],
  ["validate", 4, "cmd-4", {"kind": "dispatch_ticket"}, {}],
  ["validate", null, "cmd-4", {"kind": "dispatch_ticket"}, {}],
  ["validate", "1", " cmd-1 ", {"kind": "spike_followup_accept"}, {}],
  ["cancel", 3, "cmd-3", [{"kind": "dispatch_ticket", "ticket_id": "RR-5"}, {"kind": "dispatch_ticket", "ticket_id": "RR-5"}], {"reason": "interrupted"}],
  ["cancel", 3, "cmd-3", [{"kind": "dispatch_ticket", "ticket_id": "RR-5"}, {"kind": "orchestrator_command"}], {"reason": "again"}],
  ["cancel", 9, "cmd-9", [{"kind": "dispatch_ticket"}], {"reason": "unknown"}],
  ["exists", 2, "cmd-2", null, {"session": "spool-a"}],
  ["exists", 2, "cmd-2", null, {"session": "spool-b"}],
  ["exists", 2, "cmd-2", null, {}],
  ["exists", 5, "cmd-5", null, {}]
]"#;

const PYTHON_STEPS: &str = r#"
import json, relay_authorization as a
path, steps = sys.argv[1], json.loads(sys.argv[2])
for index, (function, seq, command, mutation, extra) in enumerate(steps):
    now = 100.0 + index
    try:
        if function == "validate":
            result = a.validate_and_mark_mutation(path, seq, command, mutation,
                relay_intent_id=extra.get("intent"), session_key=extra.get("session"), now=now)
        elif function == "cancel":
            result = a.mark_mutations_canceled(path, seq, command, mutation,
                reason=extra["reason"], now=now)
        else:
            result = a.authorization_exists(path, seq, command, session_key=extra.get("session"))
        print(json.dumps({"ok": result}))
    except ValueError as error:
        print(json.dumps({"error": str(error)}))
"#;

fn rust_steps(path: &Path) -> Vec<String> {
    let Some(Value::List(steps)) = json::parse(STEPS) else {
        panic!("steps")
    };
    let mut lines = Vec::new();
    for (index, step) in steps.iter().enumerate() {
        let step = step.as_list().unwrap();
        let (function, seq, command, extra) = (
            step[0].as_str().unwrap(),
            &step[1],
            &step[2],
            step[4].as_dict().unwrap(),
        );
        let now = Some(100.0 + index as f64);
        let intent = extra.get("intent").and_then(Value::as_str).unwrap_or("");
        let session = extra.get("session").and_then(Value::as_str).unwrap_or("");
        let outcome = match function {
            "validate" => validate_and_mark_mutation(
                path,
                seq,
                command,
                step[3].as_dict().unwrap(),
                intent,
                session,
                now,
            )
            .map(Value::Dict),
            "cancel" => {
                let mutations: Vec<Dict> = step[3]
                    .as_list()
                    .unwrap()
                    .iter()
                    .map(|item| item.as_dict().unwrap().clone())
                    .collect();
                mark_mutations_canceled(
                    path,
                    seq,
                    command,
                    &mutations,
                    extra.get("reason").and_then(Value::as_str).unwrap(),
                    now,
                )
                .map(|()| Value::Null)
            }
            _ => Ok(Value::Bool(authorization_exists(
                path, seq, command, session,
            ))),
        };
        let mut line = Dict::new();
        match outcome {
            Ok(value) => line.insert("ok", value),
            Err(error) => {
                assert_eq!(error.class, "ValueError");
                line.insert("error", error.message);
            }
        }
        lines.push(json::dumps(&Value::Dict(line)));
    }
    lines
}

#[test]
fn rust_marks_the_ledger_exactly_as_python_does() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("authorization");
    let theirs = root.path.join("python/voice_command_authorization.json");
    let ours = root.path.join("rust/voice_command_authorization.json");
    run_python(&python, &root.path, REGISTER, &[theirs.to_str().unwrap()]);
    fs::create_dir_all(ours.parent().unwrap()).unwrap();
    fs::copy(&theirs, &ours).unwrap();

    let expected = run_python(
        &python,
        &root.path,
        PYTHON_STEPS,
        &[theirs.to_str().unwrap(), STEPS],
    );
    let actual = rust_steps(&ours);
    assert_eq!(actual, expected.lines().collect::<Vec<_>>());
    assert_eq!(fs::read(&ours).unwrap(), fs::read(&theirs).unwrap());

    // The outcomes the daemon's routes rely on.
    assert!(expected.contains("replayed Relay mutation authorization"));
    assert!(expected.contains("Relay command is not authorized for this mutation"));
    assert!(expected.contains("stale Relay command: no mutation authorization was registered"));
    assert!(expected.contains("stale Relay command: missing mutation authorization metadata"));
    // The lock file is the owner's only.
    let mut lock = ours.clone().into_os_string();
    lock.push(".lock");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        fs::metadata(lock).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

#[test]
fn a_revoked_grant_names_the_turn_that_revoked_it() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("authorization-revoked");
    let path = root.path.join("ledger.json");
    run_python(
        &python,
        &root.path,
        r#"
import relay_authorization as a
path = sys.argv[1]
a.record_command_authorization(path, {"relay_command_seq": 1, "relay_command_id": "old",
    "action": "create_ticket", "source_text": "Make a ticket"}, relationship="replacement", now=1.0)
a.record_command_authorization(path, {"relay_command_seq": 2, "relay_command_id": "new",
    "action": "create_ticket", "source_text": "Cancel that"}, relationship="cancel", now=2.0)
"#,
        &[path.to_str().unwrap()],
    );
    let error = validate_and_mark_mutation(
        &path,
        &Value::Int(1),
        &Value::Str("old".to_string()),
        &json::parse(r#"{"kind": "orchestrator_action", "action_kind": "create_ticket"}"#)
            .unwrap()
            .as_dict()
            .unwrap()
            .clone(),
        "",
        "",
        Some(3.0),
    )
    .unwrap_err();
    assert_eq!(
        error.message,
        "stale Relay command: mutation authorization was revoked by a newer cancel turn"
    );
}

#[test]
fn a_missing_ledger_authorizes_nothing() {
    let root = TempRoot::new("authorization-missing");
    let path = root.path.join("absent/ledger.json");
    assert!(!authorization_exists(
        &path,
        &Value::Int(1),
        &Value::Str("contract-1".to_string()),
        ""
    ));
    let mut mutation = Dict::new();
    mutation.insert("kind", "orchestrator_command");
    let error = validate_and_mark_mutation(
        &path,
        &Value::Int(1),
        &Value::Str("contract-1".to_string()),
        &mutation,
        "",
        "",
        None,
    )
    .unwrap_err();
    assert_eq!(
        error.message,
        "stale Relay command: no mutation authorization was registered"
    );
    assert!(!path.exists());
    assert_eq!(
        mutation_fingerprint(&mutation),
        r#"{"kind": "orchestrator_command"}"#
    );
}
