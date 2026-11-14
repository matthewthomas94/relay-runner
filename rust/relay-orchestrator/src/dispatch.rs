//! `POST /v1/runs`: `Daemon.dispatch` up to the worker launch.

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn dispatch_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: dispatch_route"))
    }
}
