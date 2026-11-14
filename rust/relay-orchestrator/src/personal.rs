//! `/v1/personal-storage/*`: `handle_personal_storage_request` with the
//! body of a POST, or the first value of each query parameter of a GET.

use relay_intents::json::{Dict, Value};
use relay_services::personal_storage::handle_personal_storage_request;

use crate::daemon::Daemon;
use crate::failure::Outcome;
use crate::request::Request;
use crate::router::Reply;

/// `None` when the path is not a personal-storage route, so the remaining
/// routes are tried.
pub fn route(daemon: &Daemon, request: &Request) -> Option<Outcome<Reply>> {
    let payload = if request.method == "POST" {
        request.body.clone()
    } else {
        let mut payload = Dict::new();
        for (key, values) in &request.query {
            if let Some(first) = values.first() {
                payload.insert(key, first.as_str());
            }
        }
        payload
    };
    let answer = handle_personal_storage_request(
        &daemon.personal_storage,
        &request.method,
        &request.path,
        Some(&payload),
    )?;
    Some(
        answer
            .map(|body| (200, Value::Dict(body)))
            .map_err(Into::into),
    )
}
