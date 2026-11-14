//! `sync.*` operations against the driver's open store (RR-495).
//!
//! Each call builds an engine from `mode`, `remote_name`, `max_attempts`,
//! `base_retry_seconds` (sleep is a no-op and jitter 0) and an optional
//! `fail_stage`, or a `stage_command`: `{"stage": ..., "argv": [...]}` run
//! once, the first time the engine reaches that stage, so a test can race
//! the remote. Results are the Python dataclasses as JSON.

use std::process::Command;
use std::sync::Mutex;

use relay_artifacts::store::FailureInjector;
use relay_artifacts::sync::{
    ArtifactSyncEngine, Conflict, ConflictReport, Decision, RemoteProof, SyncMode, SyncOptions,
    SyncResult, SyncState,
};
use relay_artifacts::{Error, ErrorKind};
use relay_intents::json::{Dict, Value};

use crate::{Answer, Driver, dict, dicts, integer, invalid, optional_text, text, unhex};

fn optional(value: &Option<String>) -> Value {
    value.clone().map_or(Value::Null, Value::Str)
}

fn states(values: &[SyncState]) -> Value {
    Value::List(
        values
            .iter()
            .map(|state| Value::Str(state.value().to_string()))
            .collect(),
    )
}

fn report_value(report: &ConflictReport) -> Value {
    let mut value = Dict::new();
    value.insert("project_id", report.project_id.as_str());
    value.insert("merge_base", report.merge_base.as_str());
    value.insert("local_head", report.local_head.as_str());
    value.insert("remote_head", report.remote_head.as_str());
    value.insert(
        "local_events",
        Value::List(
            report
                .local_events
                .iter()
                .map(|(event, digest)| {
                    Value::List(vec![Value::Str(event.clone()), Value::Str(digest.clone())])
                })
                .collect(),
        ),
    );
    value.insert(
        "conflicts",
        Value::List(
            report
                .conflicts
                .iter()
                .map(|conflict| Value::Dict(conflict.as_dict()))
                .collect(),
        ),
    );
    Value::Dict(value)
}

pub(crate) fn result_value(result: &SyncResult) -> Value {
    let mut value = Dict::new();
    value.insert("state", result.state.value());
    value.insert("observed_state", result.observed_state.value());
    value.insert("transitions", states(&result.transitions));
    value.insert("attempts", result.attempts);
    value.insert("local_head", optional(&result.local_head));
    value.insert("remote_head", optional(&result.remote_head));
    value.insert("recovery", optional(&result.recovery));
    value.insert(
        "conflict_report",
        result
            .conflict_report
            .as_ref()
            .map_or(Value::Null, report_value),
    );
    Value::Dict(value)
}

fn report_from(value: &Dict) -> ConflictReport {
    let opt = |entry: &Dict, key: &str| optional_text(entry, key);
    ConflictReport {
        project_id: text(value, "project_id"),
        merge_base: text(value, "merge_base"),
        local_head: text(value, "local_head"),
        remote_head: text(value, "remote_head"),
        local_events: value
            .get("local_events")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_list)
            .map(|pair| {
                let item = |index: usize| {
                    pair.get(index)
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string()
                };
                (item(0), item(1))
            })
            .collect(),
        conflicts: dicts(value, "conflicts")
            .iter()
            .map(|entry| Conflict {
                path: text(entry, "path"),
                kind: text(entry, "kind"),
                base_oid: opt(entry, "base_oid"),
                local_oid: opt(entry, "local_oid"),
                remote_oid: opt(entry, "remote_oid"),
                recovery: text(entry, "recovery"),
            })
            .collect(),
    }
}

fn injector(request: &Dict) -> Option<FailureInjector> {
    if let Some(wanted) = optional_text(request, "fail_stage") {
        return Some(Box::new(move |stage: &str| {
            if stage == wanted {
                Err(Error::new(
                    ErrorKind::InjectedFailure,
                    format!("injected failure at {stage}"),
                ))
            } else {
                Ok(())
            }
        }));
    }
    let command = dict(request, "stage_command");
    let stage = optional_text(&command, "stage")?;
    let argv: Vec<String> = command
        .get("argv")
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect();
    let fired = Mutex::new(false);
    Some(Box::new(move |reached: &str| {
        let mut done = fired.lock().unwrap_or_else(|poison| poison.into_inner());
        if reached == stage && !*done && !argv.is_empty() {
            *done = true;
            let status = Command::new(&argv[0]).args(&argv[1..]).output()?;
            if !status.status.success() {
                return Err(Error::new(
                    ErrorKind::Runtime,
                    String::from_utf8_lossy(&status.stderr).into_owned(),
                ));
            }
        }
        Ok(())
    }))
}

fn options(request: &Dict) -> Result<SyncOptions, Error> {
    let mode_text = optional_text(request, "mode").unwrap_or_else(|| "enabled".to_string());
    let mode = SyncMode::from_value(&mode_text).ok_or_else(|| invalid("unknown sync mode"))?;
    let mut options = SyncOptions::new(mode, optional_text(request, "remote_name").as_deref());
    if let Some(attempts) = integer(request, "max_attempts") {
        options.max_attempts = attempts;
    }
    options.base_retry_seconds = request
        .get("base_retry_seconds")
        .and_then(Value::py_float)
        .unwrap_or(0.0);
    options.sleep = Box::new(|_| {});
    options.jitter = Box::new(|| 0.0);
    options.failure_injector = injector(request);
    Ok(options)
}

fn proofs(request: &Dict) -> Vec<RemoteProof> {
    dicts(request, "proofs")
        .iter()
        .map(|proof| RemoteProof {
            source_commit: text(proof, "source_commit"),
            path: text(proof, "path"),
            blob_id: text(proof, "blob_id"),
            sha256: text(proof, "sha256"),
        })
        .collect()
}

fn decisions(request: &Dict) -> Result<Vec<(String, Decision)>, Error> {
    dicts(request, "decisions")
        .iter()
        .map(|entry| {
            let decision = match optional_text(entry, "keyword") {
                Some(word) => Decision::Keyword(word),
                None => Decision::Bytes(unhex(entry, "content")?),
            };
            Ok((text(entry, "path"), decision))
        })
        .collect()
}

pub(crate) fn handle(driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    if function == "classify_git_failure" {
        let (state, recovery) = ArtifactSyncEngine::classify_git_failure(
            &text(request, "message"),
            &text(request, "operation"),
        );
        return Ok(Value::List(vec![
            Value::Str(state.value().to_string()),
            Value::Str(recovery),
        ]));
    }
    let store = driver.store()?;
    let engine = ArtifactSyncEngine::new(store, options(request)?)?;
    let optional_str = |key: &str| optional_text(request, key);
    Ok(match function {
        "new" => Value::Null,
        "status" => result_value(&engine.status()?),
        "sync" => result_value(&engine.sync()?),
        "sync_confirmed" => result_value(&engine.sync_confirmed(
            &text(request, "expected_remote_url_sha256"),
            &text(request, "expected_push_url_sha256"),
        )?),
        "publish_initial" => result_value(
            &engine.publish_initial(request.get("confirmed").is_some_and(Value::truthy))?,
        ),
        "publish_prepared" => result_value(&engine.publish_prepared(
            &text(request, "candidate_head"),
            &text(request, "expected_remote_head"),
            &proofs(request),
            optional_str("expected_remote_url_sha256").as_deref(),
            optional_str("expected_push_url_sha256").as_deref(),
        )?),
        "recover_exact_ref" => {
            let reject = optional_str("reject_head");
            let validated = std::sync::Mutex::new(Vec::new());
            let validate = |head: &str| -> relay_artifacts::Result<()> {
                validated
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .push(Value::Str(head.to_string()));
                match &reject {
                    Some(message) => Err(Error::new(ErrorKind::Value, message.clone())),
                    None => Ok(()),
                }
            };
            let use_validator = request.get("validate").is_some_and(Value::truthy);
            let result = engine.recover_exact_ref(
                &text(request, "expected_remote_url_sha256"),
                if use_validator { Some(&validate) } else { None },
            )?;
            let mut value = Dict::new();
            value.insert("result", result_value(&result));
            value.insert(
                "validated",
                Value::List(
                    validated
                        .into_inner()
                        .unwrap_or_else(|poison| poison.into_inner()),
                ),
            );
            Value::Dict(value)
        }
        "fetch_historical_object" => {
            engine.fetch_historical_object(
                &text(request, "commit_id"),
                &text(request, "expected_remote_url_sha256"),
            )?;
            Value::Null
        }
        "resolve_conflict" => result_value(&engine.resolve_conflict(
            &report_from(&dict(request, "report")),
            &decisions(request)?,
            &text(request, "resolution_event_id"),
            &text(request, "device_id"),
            &optional_str("actor_type").unwrap_or_else(|| "user".to_string()),
            optional_str("provider").as_deref(),
        )?),
        "remote_history_verification_path" => Value::Str(
            engine
                .remote_history_verification_path()
                .to_string_lossy()
                .into_owned(),
        ),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}
