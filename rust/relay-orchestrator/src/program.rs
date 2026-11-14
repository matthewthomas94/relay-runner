//! Program status, dashboard and capture.

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn program_status_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: program_status_route"))
    }

    pub fn program_dashboard_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: program_dashboard_route"))
    }

    pub fn session_capture_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: session_capture_route"))
    }
}
