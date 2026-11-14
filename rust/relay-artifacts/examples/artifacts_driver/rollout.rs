//! `rollout.*` operations: `services/artifact_rollout.py` through
//! `relay_artifacts::rollout`. Every call names its `state_root` and may pin
//! `now` (an ISO 8601 instant) so both implementations write one timestamp.

use std::path::Path;

use relay_artifacts::instant::Instant;
use relay_artifacts::rollout::{self, ArtifactRolloutStore, RolloutEvidence};
use relay_artifacts::{Error, ErrorKind};
use relay_intents::json::{Dict, Value};

use crate::{Answer, Driver, dict, invalid, optional_text, text};

fn flag(request: &Dict, key: &str) -> bool {
    request.get(key).is_some_and(Value::truthy)
}

fn open(request: &Dict) -> Result<ArtifactRolloutStore, Error> {
    let now = match optional_text(request, "now") {
        Some(value) => {
            let fixed = Instant::fromisoformat_z(&value)?
                .ok_or_else(|| invalid("now must be timezone-aware"))?;
            Some(Box::new(move || fixed) as Box<dyn Fn() -> Instant + Send + Sync>)
        }
        None => None,
    };
    ArtifactRolloutStore::new(Path::new(&text(request, "state_root")), now)
}

pub(crate) fn handle(_driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    match function {
        "privacy_safe_report_digest" => {
            let report = request.get("report").cloned().unwrap_or(Value::Null);
            return Ok(Value::Str(rollout::privacy_safe_report_digest(&report)?));
        }
        "dumps_indent_sorted" => {
            let value = request.get("value").cloned().unwrap_or(Value::Null);
            return Ok(Value::Str(rollout::dumps_indent_sorted(&value)));
        }
        _ => {}
    }
    let store = open(request)?;
    let project = text(request, "project_id");
    let cohort = text(request, "cohort");
    Ok(match function {
        "paths" => {
            let mut paths = Dict::new();
            for (key, path) in [
                ("path", &store.path),
                ("backup_path", &store.backup_path),
                ("lock_path", &store.lock_path),
            ] {
                paths.insert(key, path.to_string_lossy().into_owned());
            }
            Value::Dict(paths)
        }
        "load" => Value::Dict(store.load()?),
        "diagnostics" => Value::Dict(store.diagnostics(None)?),
        "record_evidence" => Value::Dict(
            store.record_evidence(&RolloutEvidence::from_raw(&dict(request, "evidence"))?)?,
        ),
        "set_project_opt_in" => Value::Dict(
            store
                .set_project_opt_in(
                    &project,
                    flag(request, "enabled"),
                    flag(request, "confirmed"),
                    flag(request, "writers_drained"),
                    flag(request, "sync_frozen"),
                )?
                .as_dict(),
        ),
        "promote_cohort" => Value::Dict(store.promote_cohort(&cohort, flag(request, "confirmed"))?),
        "pause_cohort" => Value::Dict(store.pause_cohort(
            &cohort,
            flag(request, "writers_drained"),
            flag(request, "sync_frozen"),
            &text(request, "reason_code"),
        )?),
        "resume_cohort" => Value::Dict(store.resume_cohort(&cohort, flag(request, "confirmed"))?),
        "decision" => Value::Dict(
            store
                .decision(
                    &project,
                    &text(request, "project_kind"),
                    flag(request, "configured_opt_in"),
                )?
                .as_dict(),
        ),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}
