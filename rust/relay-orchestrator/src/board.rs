//! The artifact board, retention, history and storage routes (`artifact_board_*`, `artifact_retention_*`, `artifact_history_*`, `artifact_dependency_summary`, `artifact_storage_metrics`, `artifact_rollout_status`).

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn artifact_rollout_status(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_rollout_status"))
    }

    pub fn artifact_retention_preview(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_retention_preview",
        ))
    }

    pub fn artifact_retention_status(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_retention_status",
        ))
    }

    pub fn artifact_storage_metrics(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_storage_metrics"))
    }

    pub fn artifact_history_search(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_history_search"))
    }

    pub fn artifact_history_detail(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_history_detail"))
    }

    pub fn artifact_history_attachment(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_history_attachment",
        ))
    }

    pub fn artifact_dependency_summary(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_dependency_summary",
        ))
    }

    pub fn artifact_retention_apply(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_retention_apply"))
    }

    pub fn artifact_retention_retry(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_retention_retry"))
    }

    pub fn artifact_history_restore(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_history_restore"))
    }

    pub fn artifact_board_claim_next_id(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_board_claim_next_id",
        ))
    }

    pub fn artifact_board_write_ticket(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_board_write_ticket",
        ))
    }

    pub fn artifact_board_delete_ticket(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_board_delete_ticket",
        ))
    }

    pub fn artifact_board_write_attachment(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_board_write_attachment",
        ))
    }
}

/// `_recover_artifact_lifecycle_leases()` at startup.
pub fn recover_artifact_lifecycle_leases(_daemon: &Daemon) {}

/// The `ticket-retention` loop of `serve`; `wait(seconds)` is false once the
/// daemon stops.
pub fn retention_loop(_daemon: &Daemon, wait: &dyn Fn(f64) -> bool) {
    while wait(2.0) {}
}
