//! `migration.*` operations: `services/artifact_migration.py` through
//! `relay_artifacts::migration`. Every call names the coordinator's
//! arguments (`repo`, `project_id`, `state_root`, `registry_path` and the
//! optional `runs_db_path`, `graphify_path`, `device_id`, `provider`,
//! `remote_name`, `remote_timeout_seconds`). `fail_stages` maps a stage to
//! the message its injected failure raises, as a Python failure injector
//! would. The `automatic_retention.*` calls are routed here too.

use std::path::{Path, PathBuf};

use relay_artifacts::automatic_retention;
use relay_artifacts::migration::{
    ArtifactMigrationCoordinator, MigrationInjector, MigrationOptions, legacy_ticket_content,
};
use relay_artifacts::rollout::ArtifactRolloutStore;
use relay_artifacts::store::{ArtifactStore, StoreOptions};
use relay_artifacts::{Error, ErrorKind};
use relay_intents::json::{Dict, Value};

use crate::{Answer, Driver, dict, optional_text, text};

fn path(request: &Dict, key: &str) -> Option<PathBuf> {
    optional_text(request, key).map(PathBuf::from)
}

fn coordinator(request: &Dict) -> Result<ArtifactMigrationCoordinator, Error> {
    let stages = dict(request, "fail_stages");
    let failure_injector: Option<MigrationInjector> = (!stages.is_empty()).then(|| {
        Box::new(move |stage: &str| match stages.get(stage) {
            Some(message) => Err(Error::new(ErrorKind::Runtime, message.py_str())),
            None => Ok(()),
        }) as MigrationInjector
    });
    let mut options = MigrationOptions {
        runs_db_path: path(request, "runs_db_path"),
        graphify_path: path(request, "graphify_path"),
        provider: optional_text(request, "provider"),
        remote_name: optional_text(request, "remote_name"),
        failure_injector,
        ..MigrationOptions::default()
    };
    if let Some(device) = optional_text(request, "device_id") {
        options.device_id = device;
    }
    if let Some(seconds) = request
        .get("remote_timeout_seconds")
        .and_then(Value::py_float)
    {
        options.remote_timeout_seconds = seconds;
    }
    ArtifactMigrationCoordinator::new(
        Path::new(&text(request, "repo")),
        &text(request, "project_id"),
        Path::new(&text(request, "state_root")),
        Path::new(&text(request, "registry_path")),
        options,
    )
}

fn flag(request: &Dict, key: &str) -> bool {
    request.get(key).is_some_and(Value::truthy)
}

fn store(request: &Dict) -> Result<ArtifactStore, Error> {
    ArtifactStore::open(
        Path::new(&text(request, "repo")),
        &text(request, "project_id"),
        Path::new(&text(request, "state_root")),
        StoreOptions {
            enabled: true,
            ..StoreOptions::default()
        },
    )
}

pub(crate) fn handle(_driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    Ok(match function {
        "legacy_ticket_content" => {
            let content = crate::unhex(request, "content")?;
            crate::hex(&legacy_ticket_content(&content)?)
        }
        "preview" => {
            let preview = coordinator(request)?.preview()?;
            let mut result = preview.as_dict();
            result.insert("can_migrate", preview.can_migrate());
            Value::Dict(result)
        }
        "migrate" => Value::Dict(
            coordinator(request)?
                .migrate(
                    flag(request, "confirm_source_cleanup"),
                    flag(request, "confirm_first_push"),
                )?
                .as_dict(),
        ),
        "rollback" => Value::Dict(coordinator(request)?.rollback()?.as_dict()),
        "journal_path" => Value::Str(
            coordinator(request)?
                .journal_path
                .to_string_lossy()
                .into_owned(),
        ),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}

/// `automatic_retention.*`.
pub(crate) fn handle_automatic(_driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    Ok(match function {
        "retention_registry_revision" => automatic_retention::retention_registry_revision(
            Path::new(&text(request, "registry_path")),
        )
        .map_or(Value::Null, Value::Str),
        "prepare_project_retention" => {
            let rollout = ArtifactRolloutStore::new(Path::new(&text(request, "state_root")), None)?;
            automatic_retention::prepare_project_retention(
                Path::new(&text(request, "repo")),
                Path::new(&text(request, "state_root")),
                Path::new(&text(request, "registry_path")),
                &rollout,
            )?
            .map_or(Value::Null, Value::Dict)
        }
        "enable_automatic_retention" => {
            Value::Dict(automatic_retention::enable_automatic_retention(
                &store(request)?,
                &text(request, "remote_name"),
            )?)
        }
        "sweep_automatic_retention" => Value::Dict(automatic_retention::sweep_automatic_retention(
            &store(request)?,
            None,
        )?),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}
