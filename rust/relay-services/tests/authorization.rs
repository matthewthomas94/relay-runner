//! The daemon's half of the Relay command authorization ledger (RR-499).
//!
//! The grants are registered as the voice bridge registers them (three
//! sessions so the redirect revokes nothing); a sequence of validations and
//! cancellations then runs on the ledger, and the refusals the daemon's
//! routes rely on must appear, including the one the RR-485 session case
//! reads for an unregistered command.

mod common;

use std::fs;
use std::path::Path;

use relay_intents::json::{self, Dict, Value};
use relay_services::authorization::{
    authorization_exists, mark_mutations_canceled, mutation_fingerprint,
    record_command_authorization, validate_and_mark_mutation,
};

use common::TempRoot;

/// The grants: `[metadata, relationship, session key, now]`.
const REGISTER: &str = r#"[
  [{"relay_command_seq": 1, "relay_command_id": "cmd-1", "action": "create_ticket",
    "source_text": "Make a ticket for RR-9", "intent_id": "i-1"}, "replacement", "", 10.0],
  [{"relay_command_seq": 2, "relay_command_id": "cmd-2", "action": "dispatch_ticket",
    "ticket_id": "rr-7", "source_text": "Dispatch RR-7 and RR-8"}, "additive", "spool-a", 11.0],
  [{"relay_command_seq": 3, "relay_command_id": "cmd-3", "action": "update_ticket",
    "ticket_id": "RR-5", "source_text": "Actually change RR-5"}, "redirect", "spool-c", 12.0]
]"#;

fn register(path: &Path, grants: &str) {
    let Some(Value::List(grants)) = json::parse(grants) else {
        panic!("grants")
    };
    for grant in &grants {
        let grant = grant.as_list().unwrap();
        let Value::Float(now) = grant[3] else {
            panic!("now")
        };
        record_command_authorization(
            path,
            grant[0].as_dict().unwrap(),
            grant[1].as_str().unwrap(),
            None,
            grant[2].as_str().unwrap(),
            Some(now),
        )
        .unwrap();
    }
}

/// Each step: `[function, seq, id, mutation or mutations, extra]`; the
/// outcome is the result's JSON or the error.
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
fn the_ledger_marks_validations_and_cancellations() {
    let root = TempRoot::new("authorization");
    let ours = root.path.join("rust/voice_command_authorization.json");
    register(&ours, REGISTER);

    // Each outcome: the refusal, the marked record's command and how many
    // mutations it has started, or the plain result.
    let outcomes: Vec<String> = rust_steps(&ours)
        .iter()
        .map(|line| {
            let line = json::parse(line).unwrap();
            let line = line.as_dict().unwrap();
            if let Some(error) = line.get("error") {
                return error.as_str().unwrap().to_string();
            }
            match line.get("ok").unwrap() {
                Value::Dict(record) => format!(
                    "{} {}",
                    record.get("relay_command_id").unwrap().as_str().unwrap(),
                    record
                        .get("started_mutations")
                        .unwrap()
                        .as_list()
                        .unwrap()
                        .len()
                ),
                other => json::dumps(other),
            }
        })
        .collect();
    let unregistered = "stale Relay command: no mutation authorization was registered";
    let unauthorized = "Relay command is not authorized for this mutation";
    assert_eq!(
        outcomes,
        [
            "cmd-1 1",
            "replayed Relay mutation authorization",
            unauthorized,
            "cmd-1 2",
            unregistered,
            "cmd-2 1",
            unauthorized,
            unregistered,
            "cmd-3 1",
            unauthorized,
            unregistered,
            "stale Relay command: missing mutation authorization metadata",
            "cmd-1 3",
            "null",
            "null",
            "null",
            "true",
            "false",
            "true",
            "false",
        ]
    );
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
    let root = TempRoot::new("authorization-revoked");
    let path = root.path.join("ledger.json");
    register(
        &path,
        r#"[
  [{"relay_command_seq": 1, "relay_command_id": "old", "action": "create_ticket",
    "source_text": "Make a ticket"}, "replacement", "", 1.0],
  [{"relay_command_seq": 2, "relay_command_id": "new", "action": "create_ticket",
    "source_text": "Cancel that"}, "cancel", "", 2.0]
]"#,
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
