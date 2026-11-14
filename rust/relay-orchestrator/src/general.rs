//! General tasks.

use std::sync::Arc;

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;
use relay_intents::json::{Dict, Value};
use relay_services::general_work::GeneralWorkOptions;
use relay_services::personal_storage::PersonalFileStorage;

impl Daemon {
    pub fn general_task_list(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: general_task_list"))
    }

    pub fn general_task_get(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: general_task_get"))
    }

    pub fn general_task_post(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: general_task_post"))
    }
}

/// `_provider_from_general(general, fallback)`.
pub fn provider_from_general(general: &Dict, fallback: &str) -> String {
    let pick = |key: &str| {
        general
            .get(key)
            .filter(|value| value.truthy())
            .map(Value::py_str)
    };
    let raw = pick("provider")
        .or_else(|| pick("command"))
        .unwrap_or_else(|| {
            if fallback.is_empty() {
                "codex".to_string()
            } else {
                fallback.to_string()
            }
        });
    crate::daemon::agent_kind(Some(&raw)).to_string()
}

/// The `GeneralWorkStore` arguments `Daemon.__init__` passes.
pub fn general_work_options(
    _config: &Dict,
    _storage: Arc<PersonalFileStorage>,
) -> GeneralWorkOptions {
    GeneralWorkOptions::default()
}
