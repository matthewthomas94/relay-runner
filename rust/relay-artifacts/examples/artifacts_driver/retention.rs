//! `retention.*` operations against the driver's open store (RR-495).
//!
//! Each call builds an `ArtifactRetentionManager` from `remote_mode`
//! (default `enabled`), `enabled` (default true), an optional
//! `confirmation` (the `ArchiveRemoteConfirmation` fields), a pinned `now`
//! (ISO 8601) and an optional `fail_stage`. With `synchronizer` (default
//! true) it also gets an enabled sync engine on remote `remote_name`
//! (default `origin`), one attempt and no sleep, as the daemon builds it.
//! `preview` with `keep` remembers its plan for a later `archive` with
//! `kept_plan`, so a test can archive a stale plan. Results are the Python
//! dataclasses as JSON, instants as `isoformat()` with `Z`.

use std::cell::RefCell;

use relay_artifacts::instant::Instant;
use relay_artifacts::retention::{
    self, ArchiveRemoteConfirmation, ArchiveResult, ArtifactRetentionManager, EventArgs,
    HistoricalCard, HistoryAccess, LeaseRequest, RetentionOptions, RetentionPlan, StoragePaths,
};
use relay_artifacts::sync::{ArtifactSyncEngine, SyncMode, SyncOptions};
use relay_artifacts::{Error, ErrorKind};
use relay_intents::json::{Dict, Value};

use crate::{Answer, Driver, dict, hex, invalid, optional_text, strings, text, write_result};

thread_local! {
    static KEPT_PLAN: RefCell<Option<RetentionPlan>> = const { RefCell::new(None) };
}

fn instant(value: &str) -> Result<Instant, Error> {
    Instant::fromisoformat_z(value)?.ok_or_else(|| invalid("instants must be timezone-aware"))
}

fn optional_instant(request: &Dict, key: &str) -> Result<Option<Instant>, Error> {
    optional_text(request, key)
        .map(|value| instant(&value))
        .transpose()
}

fn flag(request: &Dict, key: &str, default: bool) -> bool {
    request.get(key).map_or(default, Value::truthy)
}

fn confirmation(request: &Dict) -> Option<ArchiveRemoteConfirmation> {
    let value = dict(request, "confirmation");
    if value.is_empty() {
        return None;
    }
    Some(ArchiveRemoteConfirmation {
        service: text(&value, "service"),
        remote_name: text(&value, "remote_name"),
        remote_url_sha256: text(&value, "remote_url_sha256"),
        push_url_sha256: text(&value, "push_url_sha256"),
        exposure_confirmed: value.get("exposure_confirmed").is_some_and(Value::truthy),
    })
}

fn sync_options(request: &Dict) -> SyncOptions {
    let remote = optional_text(request, "remote_name").unwrap_or_else(|| "origin".to_string());
    let mut options = SyncOptions::new(SyncMode::Enabled, Some(&remote));
    options.max_attempts = 1;
    options.base_retry_seconds = 0.0;
    options.sleep = Box::new(|_| {});
    options.jitter = Box::new(|| 0.0);
    options
}

fn manager<'s>(
    store: &'s relay_artifacts::store::ArtifactStore,
    synchronizer: Option<&'s ArtifactSyncEngine<'s>>,
    request: &Dict,
) -> Result<ArtifactRetentionManager<'s>, Error> {
    let now = optional_instant(request, "now")?
        .map(|fixed| Box::new(move || fixed) as Box<dyn Fn() -> Instant + Send + Sync>);
    let failure_injector = optional_text(request, "fail_stage").map(|wanted| {
        Box::new(move |stage: &str| {
            if stage == wanted {
                Err(Error::new(
                    ErrorKind::InjectedFailure,
                    format!("injected failure at {stage}"),
                ))
            } else {
                Ok(())
            }
        }) as relay_artifacts::store::FailureInjector
    });
    ArtifactRetentionManager::new(
        store,
        RetentionOptions {
            lease_store: None,
            remote_mode: optional_text(request, "remote_mode").unwrap_or_else(|| "enabled".into()),
            remote_confirmation: confirmation(request),
            synchronizer,
            enabled: flag(request, "enabled", true),
            now,
            failure_injector,
        },
    )
}

fn archive_value(result: ArchiveResult) -> Value {
    let mut value = Dict::new();
    value.insert("state", result.state.value());
    value.insert("write", result.write.map_or(Value::Null, write_result));
    value.insert("ticket_ids", strings(&result.ticket_ids));
    value.insert("warnings", strings(&result.warnings));
    value.insert("recovery", result.recovery);
    Value::Dict(value)
}

fn card_value(card: &HistoricalCard) -> Value {
    retention::history_card_payload(card)
}

fn event(request: &Dict) -> Result<EventArgs, Error> {
    Ok(EventArgs {
        event_id: text(request, "event_id"),
        device_id: text(request, "device_id"),
        actor_type: optional_text(request, "actor_type"),
        provider: optional_text(request, "provider"),
        at: optional_instant(request, "at")?,
    })
}

fn lease_request(request: &Dict) -> Result<LeaseRequest, Error> {
    Ok(LeaseRequest {
        lease_id: text(request, "lease_id"),
        ticket_id: text(request, "ticket_id"),
        artifact_id: text(request, "artifact_id"),
        artifact_head: text(request, "artifact_head"),
        run_id: text(request, "run_id"),
        role: text(request, "role"),
        provider: text(request, "provider"),
        attachment_paths: request
            .get("attachment_paths")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .map(Value::py_str)
            .collect(),
        now: optional_instant(request, "now")?,
    })
}

pub(crate) fn handle(driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    let store = driver.store()?;
    if function == "confirm_github_remote" {
        let confirmed = retention::confirm_github_remote(
            store,
            &text(request, "remote_name"),
            flag(request, "exposure_confirmed", false),
        )?;
        return Ok(Value::Dict(confirmed.as_dict()));
    }
    let engine = if flag(request, "synchronizer", true) {
        Some(ArtifactSyncEngine::new(store, sync_options(request))?)
    } else {
        None
    };
    let manager = manager(store, engine.as_ref(), request)?;
    let leases = &manager.lease_store;
    let deepen_digest = manager
        .remote_confirmation
        .as_ref()
        .map(|confirmation| confirmation.remote_url_sha256.clone())
        .unwrap_or_default();
    let deepen = |commit_id: &str| -> relay_artifacts::Result<()> {
        match engine.as_ref() {
            Some(engine) => engine.fetch_historical_object(commit_id, &deepen_digest),
            None => Err(invalid(
                "online history retrieval requires confirmed GitHub artifact access",
            )),
        }
    };
    let access = HistoryAccess {
        online: flag(request, "online", false),
        deepen: if flag(request, "online", false) {
            Some(&deepen)
        } else {
            None
        },
    };
    Ok(match function {
        "preview" => {
            let plan = manager.preview(optional_instant(request, "evaluated_at")?)?;
            let value = retention::plan_value(&plan);
            if flag(request, "keep", false) {
                KEPT_PLAN.with(|kept| *kept.borrow_mut() = Some(plan));
            }
            value
        }
        "status" => {
            let confirmation = manager.remote_confirmation.clone();
            retention::status_payload(&manager, engine.as_ref(), confirmation.as_ref())?
        }
        "history_search" => retention::history_search_payload(&manager, &text(request, "query"))?,
        "archive" => {
            let plan = if flag(request, "kept_plan", false) {
                KEPT_PLAN
                    .with(|kept| kept.borrow().clone())
                    .ok_or_else(|| invalid("no kept plan"))?
            } else {
                manager.preview(None)?
            };
            archive_value(manager.archive(&plan, &event(request)?, None)?)
        }
        "recover_archive" => manager
            .recover_archive(None)?
            .map_or(Value::Null, archive_value),
        "recover_from_remote" => crate::sync::result_value(&manager.recover_from_remote(None)?),
        "historical_search" => Value::List(
            manager
                .historical_search(&text(request, "query"))?
                .iter()
                .map(card_value)
                .collect(),
        ),
        "historical_detail" => {
            let detail = manager.historical_detail(&text(request, "artifact_id"), access)?;
            let mut value = Dict::new();
            value.insert("availability", detail.availability.value());
            value.insert("card", detail.card.as_ref().map_or(Value::Null, card_value));
            value.insert(
                "ticket_bytes",
                detail.ticket_bytes.as_deref().map_or(Value::Null, hex),
            );
            value.insert(
                "attachments",
                Value::List(detail.attachments.into_iter().map(Value::Dict).collect()),
            );
            value.insert("recovery", detail.recovery);
            Value::Dict(value)
        }
        "historical_attachment" => {
            let attachment = manager.historical_attachment(
                &text(request, "artifact_id"),
                &text(request, "filename"),
                access,
            )?;
            let mut value = Dict::new();
            value.insert("artifact_id", attachment.artifact_id);
            value.insert("ticket_id", attachment.ticket_id);
            value.insert("filename", attachment.filename);
            value.insert("mime_type", attachment.mime_type);
            value.insert("content", hex(&attachment.content));
            value.insert("blob_id", attachment.blob_id);
            Value::Dict(value)
        }
        "restore" => archive_value(manager.restore(
            &text(request, "artifact_id"),
            &event(request)?,
            access,
        )?),
        "reopen" => archive_value(manager.reopen(
            &text(request, "artifact_id"),
            &event(request)?,
            access,
        )?),
        "delete" => archive_value(manager.delete(&text(request, "ticket_id"), &event(request)?)?),
        "dependency_satisfied" => {
            Value::Bool(manager.dependency_satisfied(&text(request, "dependency_id"), None)?)
        }
        "dependency_execution_mode" => {
            Value::from(manager.dependency_execution_mode(&text(request, "dependency_id"), None)?)
        }
        "transaction_status" => Value::Dict(manager.transaction_status()?),
        "storage_metrics" => {
            Value::Dict(manager.storage_metrics(&StoragePaths::default())?.as_dict())
        }
        "lease_acquire" => Value::Dict(retention::lease_json(
            &leases.acquire(&lease_request(request)?)?,
        )),
        "lease_heartbeat" => Value::Dict(retention::lease_json(&leases.heartbeat(
            &text(request, "lease_id"),
            optional_instant(request, "now")?,
        )?)),
        "lease_release" => Value::Dict(retention::lease_json(&leases.release(
            &text(request, "lease_id"),
            &text(request, "terminal_reason"),
            optional_instant(request, "now")?,
        )?)),
        "lease_active" => Value::List(
            leases
                .active()?
                .iter()
                .map(|lease| Value::Dict(retention::lease_json(lease)))
                .collect(),
        ),
        "lease_active_ticket_ids" => strings(&leases.active_ticket_ids()?),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}
