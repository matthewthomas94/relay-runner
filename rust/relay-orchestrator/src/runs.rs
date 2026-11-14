//! The run routes other than dispatch: list, get, outcome, review inspection and decision, cancel, verification resume and preserved-run recovery.

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn list_runs_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: list_runs_route"))
    }

    pub fn get_run_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: get_run_route"))
    }

    pub fn submit_worker_outcome_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: submit_worker_outcome_route",
        ))
    }

    pub fn get_worker_outcome_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: get_worker_outcome_route"))
    }

    pub fn inspect_run_for_review_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: inspect_run_for_review_route",
        ))
    }

    pub fn dispatch_review_worker_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: dispatch_review_worker_route",
        ))
    }

    pub fn review_decision_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: review_decision_route"))
    }

    pub fn cancel_run_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: cancel_run_route"))
    }

    pub fn reconcile_preserved_run_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: reconcile_preserved_run_route",
        ))
    }

    pub fn recover_preserved_run_collision_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: recover_preserved_run_collision_route",
        ))
    }

    pub fn resume_verification_blocked_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: resume_verification_blocked_route",
        ))
    }
}
