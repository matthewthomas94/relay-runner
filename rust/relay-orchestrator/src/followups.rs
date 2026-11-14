//! Spike follow-up proposals.

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn propose_spike_followups_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: propose_spike_followups_route",
        ))
    }

    pub fn review_spike_followup_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: review_spike_followup_route",
        ))
    }
}
