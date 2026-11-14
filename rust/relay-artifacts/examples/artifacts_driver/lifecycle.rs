//! `lifecycle.*` operations (RR-495).
//!
//! Each call builds an `ArtifactLifecycleCoordinator` on a fresh store over
//! the driver's open one (same repository, project and data root), with
//! `registry_path`, `device_id` and a pinned `now` (ISO 8601), as the daemon
//! builds one per project. Results are the Python dataclasses as JSON.

use std::path::{Path, PathBuf};

use relay_artifacts::instant::Instant;
use relay_artifacts::lifecycle::{
    ArtifactLifecycleCoordinator, ArtifactWorkerSnapshot, FailureKind, LifecycleWriteResult,
    StructuredWorkerOutcome,
};
use relay_artifacts::store::{ArtifactStore, StoreOptions};
use relay_artifacts::{Error, ErrorKind};
use relay_intents::json::{Dict, Value};

use crate::{Answer, Driver, dict, integer, invalid, optional_text, strings, text};

fn coordinator(driver: &Driver, request: &Dict) -> Result<ArtifactLifecycleCoordinator, Error> {
    let open = driver.store()?;
    let store = ArtifactStore::open(
        &open.repo_path,
        &open.project_id,
        &open.state_root,
        StoreOptions {
            enabled: open.enabled,
            ..StoreOptions::default()
        },
    )?;
    let now = match optional_text(request, "now") {
        Some(value) => {
            let fixed = Instant::fromisoformat_z(&value)?
                .ok_or_else(|| invalid("now must be timezone-aware"))?;
            Some(Box::new(move || fixed) as Box<dyn Fn() -> Instant + Send + Sync>)
        }
        None => None,
    };
    ArtifactLifecycleCoordinator::new(
        store,
        Path::new(&text(request, "registry_path")),
        &text(request, "device_id"),
        now,
    )
}

fn write_value(result: LifecycleWriteResult) -> Value {
    let mut value = Dict::new();
    value.insert("event_id", result.event_id);
    value.insert("commit_id", result.commit_id);
    value.insert("promoted_ticket_ids", strings(&result.promoted_ticket_ids));
    value.insert("idempotent", result.idempotent);
    Value::Dict(value)
}

fn snapshot_value(snapshot: ArtifactWorkerSnapshot) -> Value {
    let mut value = Dict::new();
    value.insert("project_id", snapshot.project_id);
    value.insert("ticket_id", snapshot.ticket_id);
    value.insert("artifact_id", snapshot.artifact_id);
    value.insert("artifact_head", snapshot.artifact_head);
    value.insert("run_id", snapshot.run_id);
    value.insert("provider", snapshot.provider);
    value.insert("lease_id", snapshot.lease_id);
    value.insert(
        "manifest_path",
        snapshot.manifest_path.to_string_lossy().into_owned(),
    );
    value.insert("files", strings(&snapshot.files));
    Value::Dict(value)
}

fn outcome_value(outcome: &StructuredWorkerOutcome) -> Value {
    Value::Dict(outcome.to_json())
}

fn path(request: &Dict, key: &str) -> PathBuf {
    PathBuf::from(text(request, key))
}

fn run_id(request: &Dict) -> i64 {
    integer(request, "run_id").unwrap_or_default()
}

pub(crate) fn handle(driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    if function == "cleanup_snapshot" {
        ArtifactLifecycleCoordinator::cleanup_snapshot(&path(request, "workspace"));
        return Ok(Value::Null);
    }
    if function == "is_enabled" {
        return Ok(Value::Bool(ArtifactLifecycleCoordinator::is_enabled(
            driver.store()?,
        )?));
    }
    let lifecycle = coordinator(driver, request)?;
    let ticket = text(request, "ticket_id");
    let provider = text(request, "provider");
    Ok(match function {
        "validate_scope" => {
            let scope = lifecycle.validate_scope(
                optional_text(request, "token").as_deref(),
                optional_text(request, "internal").as_deref(),
            )?;
            let mut value = Dict::new();
            value.insert("project_id", scope.project_id);
            value.insert("repository_path", scope.repository_path);
            value.insert("registry_schema_version", scope.registry_schema_version);
            Value::Dict(value)
        }
        "claim" => snapshot_value(lifecycle.claim_and_materialize(
            &ticket,
            run_id(request),
            &provider,
            &path(request, "workspace"),
        )?),
        "update_worker_sizing" => write_value(lifecycle.update_worker_sizing(
            &ticket,
            &provider,
            &dict(request, "fields"),
        )?),
        "submit_outcome" => {
            let workspace = optional_text(request, "workspace").map(PathBuf::from);
            outcome_value(&lifecycle.submit_outcome(
                run_id(request),
                &ticket,
                &provider,
                &dict(request, "payload"),
                workspace.as_deref(),
            )?)
        }
        "outcome" => lifecycle
            .outcome(run_id(request))?
            .as_ref()
            .map_or(Value::Null, outcome_value),
        "validate_worker_completion" => {
            let (declared, reason) = lifecycle.validate_worker_completion(
                &path(request, "workspace"),
                &ticket,
                run_id(request),
                &provider,
                optional_text(request, "start_head").as_deref(),
            )?;
            Value::List(vec![Value::from(declared), Value::Str(reason)])
        }
        "begin_review" => {
            lifecycle.begin_review(run_id(request), &provider)?;
            Value::Null
        }
        "record_failure" => write_value(lifecycle.record_failure(
            run_id(request),
            &ticket,
            &provider,
            &text(request, "reason"),
            FailureKind {
                canceled: request.get("canceled").is_some_and(Value::truthy),
                retry: request.get("retry").is_some_and(Value::truthy),
            },
        )?),
        "recover_spike_completion" => lifecycle
            .recover_spike_completion(run_id(request))?
            .map_or(Value::Null, write_value),
        "recover_spike_failure" => Value::from(lifecycle.recover_spike_failure(run_id(request))?),
        "publish_spike_result" => write_value(lifecycle.publish_spike_result(
            run_id(request),
            &ticket,
            &provider,
            &path(request, "workspace"),
            &text(request, "report"),
        )?),
        "record_merge_conflict" => write_value(lifecycle.record_merge_conflict(
            run_id(request),
            &ticket,
            &provider,
            &text(request, "reason"),
        )?),
        "publish_merge_success" => write_value(lifecycle.publish_merge_success(
            run_id(request),
            &ticket,
            &provider,
            &text(request, "merged_source_commit"),
        )?),
        "publish_verification_closeout" => write_value(lifecycle.publish_verification_closeout(
            run_id(request),
            &ticket,
            &provider,
        )?),
        "promote_unblocked_dependents" => strings(&lifecycle.promote_unblocked_dependents()?),
        "queue_for_dependencies" => lifecycle
            .queue_for_dependencies(&ticket)?
            .map_or(Value::Null, write_value),
        "resume_verification" => write_value(lifecycle.resume_verification(
            run_id(request),
            &ticket,
            &provider,
            &text(request, "reason"),
        )?),
        "recover_leases" => {
            let states = dict(request, "run_states");
            let preserve: Vec<i64> = request
                .get("preserve_run_ids")
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .filter_map(Value::py_int)
                .collect();
            let state = |run: i64| -> Option<String> {
                states
                    .get(&run.to_string())
                    .and_then(Value::as_str)
                    .map(str::to_string)
            };
            strings(&lifecycle.recover_leases(&state, &preserve)?)
        }
        "cap_local_log" => Value::Int(lifecycle.cap_local_log(
            &path(request, "path"),
            integer(request, "max_bytes").unwrap_or_default() as u64,
        )? as i64),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}
