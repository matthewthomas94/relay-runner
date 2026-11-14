//! `rollout.*` operations; filled in by the rollout port (RR-495).

use relay_intents::json::Dict;

use crate::{Answer, Driver};

pub(crate) fn handle(_driver: &mut Driver, _function: &str, _request: &Dict) -> Answer {
    Err(relay_artifacts::Error::new(
        relay_artifacts::ErrorKind::Type,
        "unknown operation",
    ))
}
