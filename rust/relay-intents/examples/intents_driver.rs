//! A test driver for the crate: one JSON request per stdin line, one JSON
//! answer per stdout line. `tests/relay_intents_support.py` runs the same
//! scenarios through it and through the Python modules, on one database.
//!
//! A request is `{"op": "<object>.<method>", ...arguments}`; the answer is
//! `{"ok": true, "result": ...}` or `{"ok": false, "error": "<Python class>"}`.
//! `inbox.open` and `broker.open` open the object the other operations use.
//! It is an example, so `cargo test` builds it and no release ships it.

use std::io::{self, BufRead, Write};

use relay_intents::arbitration::{
    self, ActiveWork, CancellationScope, DispositionRequest, IntentDisposition,
};
use relay_intents::broker::{AUTHORITATIVE_REPLY, ProviderTurnBroker};
use relay_intents::inbox::{self, InboxOptions, IntentInbox};
use relay_intents::json::{self, Dict, Value};
use relay_intents::model::{TurnState, session_key};
use relay_intents::{Error, qualification};

#[derive(Default)]
struct Driver {
    inbox: Option<IntentInbox>,
    broker: Option<ProviderTurnBroker>,
}

/// A failure named as the Python module's exception class.
struct Failure(&'static str);

impl From<Error> for Failure {
    fn from(error: Error) -> Self {
        Failure(match error {
            Error::Sqlite(error) => match error.sqlite_error_code() {
                Some(rusqlite::ErrorCode::ConstraintViolation) => "IntegrityError",
                Some(rusqlite::ErrorCode::NotADatabase | rusqlite::ErrorCode::DatabaseCorrupt) => {
                    "DatabaseError"
                }
                _ => "OperationalError",
            },
            Error::Io(error) => match error.kind() {
                io::ErrorKind::NotFound => "FileNotFoundError",
                io::ErrorKind::PermissionDenied => "PermissionError",
                _ => "OSError",
            },
            Error::Invalid(_) => "ValueError",
        })
    }
}

type Answer = Result<Value, Failure>;

fn dict(request: &Dict, key: &str) -> Dict {
    match request.get(key) {
        Some(Value::Dict(value)) => value.clone(),
        _ => Dict::new(),
    }
}

fn text(request: &Dict, key: &str) -> String {
    request
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn optional_text(request: &Dict, key: &str) -> Option<String> {
    request.get(key).and_then(Value::as_str).map(str::to_string)
}

fn number(request: &Dict, key: &str) -> Option<f64> {
    request.present(key).and_then(Value::py_float)
}

fn integer(request: &Dict, key: &str) -> Option<i64> {
    request.present(key).and_then(Value::py_int)
}

fn flag(request: &Dict, key: &str) -> bool {
    request.get(key).is_some_and(Value::truthy)
}

fn strings(request: &Dict, key: &str) -> Vec<String> {
    request
        .get(key)
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .map(Value::py_str)
        .collect()
}

fn list<T>(values: impl IntoIterator<Item = T>, convert: impl Fn(T) -> Value) -> Value {
    Value::List(values.into_iter().map(convert).collect())
}

fn active_work(request: &Dict) -> Vec<ActiveWork> {
    request
        .get("active_work")
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .map(|work| ActiveWork {
            work_id: work.string("work_id"),
            resources: strings(work, "resources"),
            target: optional_text(work, "target"),
        })
        .collect()
}

fn disposition(request: &Dict) -> IntentDisposition {
    let active = active_work(request);
    let resources = strings(request, "requested_resources");
    let targets = strings(request, "target_work_ids");
    let action_reason = optional_text(request, "action_reason");
    let scope = request
        .present("cancellation_scope")
        .map(|scope| CancellationScope::from_wire(Some(&scope.py_str())));
    arbitration::resolve_intent_disposition(&DispositionRequest {
        intent_id: &text(request, "intent_id"),
        action_kind: &text(request, "action_kind"),
        action_reason: action_reason.as_deref(),
        source_text: &text(request, "source_text"),
        active_work: &active,
        requested_resources: &resources,
        cancellation_scope: scope,
        target_work_ids: &targets,
    })
}

impl Driver {
    fn inbox(&self) -> Result<&IntentInbox, Failure> {
        self.inbox.as_ref().ok_or(Failure("RuntimeError"))
    }

    fn broker(&self) -> Result<&ProviderTurnBroker, Failure> {
        self.broker.as_ref().ok_or(Failure("RuntimeError"))
    }

    fn handle(&mut self, request: &Dict) -> Answer {
        let op = text(request, "op");
        if let Some(method) = op.strip_prefix("inbox.") {
            return self.inbox_op(method, request);
        }
        if let Some(method) = op.strip_prefix("broker.") {
            return self.broker_op(method, request);
        }
        if let Some(function) = op.strip_prefix("model.") {
            return model_op(function, request);
        }
        Err(Failure("KeyError"))
    }

    fn inbox_op(&mut self, method: &str, request: &Dict) -> Answer {
        if method == "open" {
            self.inbox = None;
            self.inbox = Some(IntentInbox::open(
                &text(request, "path"),
                InboxOptions {
                    provider_turn_projection_path: optional_text(request, "projection_path"),
                    hold_recovered_delivery: flag(request, "hold_recovered_delivery"),
                    ..Default::default()
                },
            )?);
            return Ok(Value::Null);
        }
        if method == "close" {
            self.inbox = None;
            return Ok(Value::Null);
        }
        let inbox = self.inbox()?;
        Ok(match method {
            "enqueue" => Value::Dict(inbox.enqueue(
                &text(request, "prompt"),
                &dict(request, "metadata"),
                &text(request, "route"),
            )?),
            "retire_stale_foreground" => {
                let retired = inbox.retire_stale_foreground(
                    &text(request, "recovery_generation"),
                    &text(request, "command_path"),
                    &text(request, "metadata_path"),
                    integer(request, "before_command_seq"),
                    optional_text(request, "session_key").as_deref(),
                )?;
                Value::Int(retired as i64)
            }
            "retire_ended_sessions" => {
                let live = strings(request, "live");
                Value::Int(
                    inbox.retire_ended_sessions(|key| live.iter().any(|live| live == key))? as i64,
                )
            }
            "resume_after_recovery" => Value::Bool(inbox.resume_after_recovery(
                &text(request, "intent_id"),
                &text(request, "recovery_generation"),
                number(request, "now"),
            )?),
            "cancel_pending_before" => Value::Int(
                inbox.cancel_pending_before(integer(request, "command_seq").unwrap_or_default())?
                    as i64,
            ),
            "cancel_scoped" => list(
                inbox.cancel_scoped(
                    &dict(request, "metadata"),
                    optional_text(request, "command_path").as_deref(),
                    optional_text(request, "metadata_path").as_deref(),
                )?,
                Value::from,
            ),
            "materialize_next" => {
                let routes = dict(request, "routes");
                let route = |metadata: &Dict| {
                    let paths = routes.get(&session_key(metadata))?.as_list()?;
                    Some((paths.first()?.py_str(), paths.get(1)?.py_str()))
                };
                let materialized = inbox.materialize_next(
                    &text(request, "command_path"),
                    &text(request, "metadata_path"),
                    &text(request, "transport"),
                    request
                        .present("routes")
                        .map(|_| &route as inbox::MailboxRoute<'_>),
                )?;
                materialized.map_or(Value::Null, Value::Dict)
            }
            "observe_claim" => Value::Bool(inbox.observe_claim(
                &dict(request, "claimed"),
                flag(request, "provider_turn_seen"),
                number(request, "now"),
            )?),
            "reconcile_terminal_claims" => {
                Value::Int(inbox.reconcile_terminal_claims(number(request, "now"))? as i64)
            }
            "pending_for_route" => {
                list(inbox.pending_for_route(&text(request, "route"))?, |work| {
                    let mut entry = Dict::new();
                    entry.insert("prompt", work.prompt);
                    entry.insert("metadata", work.metadata);
                    Value::Dict(entry)
                })
            }
            "deliverable_commands" => list(inbox.deliverable_commands()?, |summary| {
                Value::Dict(summary.to_dict())
            }),
            "source_command_intents" => {
                let command = request.get("command").and_then(Value::as_dict);
                list(inbox.source_command_intents(command)?, |summary| {
                    Value::Dict(summary.to_dict())
                })
            }
            "state_snapshot" => {
                let (latest, deliverable) = inbox.state_snapshot()?;
                Value::List(vec![
                    latest.unwrap_or(Value::Null),
                    list(deliverable, |summary| Value::Dict(summary.to_dict())),
                ])
            }
            "records" => list(inbox.records()?, Value::Dict),
            "retire_replaced_claim" => {
                Value::Bool(inbox.retire_replaced_claim(&dict(request, "expected"))?)
            }
            "recovery_blocker" => inbox
                .recovery_blocker()?
                .map_or(Value::Null, |blocker| Value::Dict(blocker.to_dict())),
            "skip_recovery_blocker" => Value::Bool(
                inbox.skip_recovery_blocker(request.get("expected").unwrap_or(&Value::Null))?,
            ),
            "cancelled_intent_ids" => list(inbox.cancelled_intent_ids()?, Value::from),
            "sync_deliverable_state" => {
                inbox::sync_deliverable_state(&text(request, "state_path"), inbox)?;
                Value::Null
            }
            _ => return Err(Failure("KeyError")),
        })
    }

    fn broker_op(&mut self, method: &str, request: &Dict) -> Answer {
        if method == "open" {
            self.broker = None;
            self.broker = Some(ProviderTurnBroker::open(
                &text(request, "path"),
                optional_text(request, "projection_path").as_deref(),
            )?);
            return Ok(Value::Null);
        }
        if method == "close" {
            self.broker = None;
            return Ok(Value::Null);
        }
        let broker = self.broker()?;
        let record = dict(request, "record");
        Ok(match method {
            "activate" => Value::Bool(
                broker.activate(
                    &record,
                    number(request, "now"),
                    &optional_text(request, "release_reason")
                        .unwrap_or_else(|| "superseded_by_prompt_submit".to_string()),
                )?,
            ),
            "transition" => {
                let Some(to_state) = TurnState::parse(&text(request, "to_state")) else {
                    return Ok(Value::Bool(false));
                };
                Value::Bool(broker.transition(
                    &record,
                    to_state,
                    &text(request, "event_type"),
                    &text(request, "release_reason"),
                    number(request, "now"),
                    optional_text(request, "event_id").as_deref(),
                )?)
            }
            "state_for" => broker.state_for(&record)?.map_or(Value::Null, Value::from),
            "terminate_owner" => Value::Int(broker.terminate_owner(
                &dict(request, "ownership"),
                &text(request, "provider_session_id"),
                &text(request, "release_reason"),
                &text(request, "event_id"),
                number(request, "now"),
            )? as i64),
            "reserve_effect" => Value::Dict(
                broker
                    .reserve_effect(
                        &dict(request, "command"),
                        &optional_text(request, "effect_kind")
                            .unwrap_or_else(|| AUTHORITATIVE_REPLY.to_string()),
                        number(request, "now"),
                    )?
                    .to_dict(),
            ),
            "authorize_effect_delivery" => {
                Value::Bool(broker.authorize_effect_delivery(
                    &text(request, "effect_id"),
                    number(request, "now"),
                )?)
            }
            "finish_effect" => {
                broker.finish_effect(
                    &text(request, "effect_id"),
                    flag(request, "delivered"),
                    number(request, "now"),
                )?;
                Value::Null
            }
            "project" => {
                broker.project()?;
                Value::Null
            }
            "session_records" => list(
                broker.session_records(&text(request, "native_session_id"))?,
                Value::Dict,
            ),
            "table_records" => list(broker.table_records(&text(request, "table"))?, Value::Dict),
            _ => return Err(Failure("KeyError")),
        })
    }
}

fn model_op(function: &str, request: &Dict) -> Answer {
    let source = text(request, "text");
    Ok(match function {
        "normalize_voice_work_items" => list(
            arbitration::normalize_voice_work_items(
                &source,
                integer(request, "relay_command_seq").unwrap_or_default(),
                &text(request, "relay_command_id"),
            ),
            |item| Value::Dict(item.to_dict()),
        ),
        "resolve_intent_disposition" => Value::Dict(disposition(request).to_dict()),
        "authorization_relationship_for" => {
            Value::from(arbitration::authorization_relationship_for(
                &disposition(request),
                &text(request, "fallback"),
            ))
        }
        "explicit_replace_requested" => Value::Bool(arbitration::explicit_replace_requested(
            &source,
            &text(request, "action_reason"),
        )),
        "explicit_cancel_requested" => Value::Bool(arbitration::explicit_cancel_requested(&source)),
        "inferred_resource_claims" => {
            list(arbitration::inferred_resource_claims(&source), Value::from)
        }
        "sidecar_eligible" => Value::Bool(arbitration::sidecar_eligible(
            &source,
            &active_work(request),
            &strings(request, "requested_resources"),
            flag(request, "project_mutation"),
        )),
        "qualify_intent" => Value::Dict(
            qualification::qualify_intent(
                &source,
                &text(request, "action_kind"),
                optional_text(request, "action_reason").as_deref(),
                optional_text(request, "command_id").as_deref(),
                integer(request, "command_seq"),
            )
            .to_dict(),
        ),
        "format_qualification_for_agent" => Value::from(
            qualification::format_qualification_for_agent(&qualification::qualify_intent(
                &source,
                &text(request, "action_kind"),
                optional_text(request, "action_reason").as_deref(),
                optional_text(request, "command_id").as_deref(),
                integer(request, "command_seq"),
            )),
        ),
        "dispatch_forbidden" => Value::Bool(qualification::dispatch_forbidden(&source)),
        "foreground_action_requested" => {
            Value::Bool(qualification::foreground_action_requested(&source))
        }
        "discussion_only_requested" => {
            Value::Bool(qualification::discussion_only_requested(&source))
        }
        "context_dependent_assent" => Value::Bool(qualification::context_dependent_assent(&source)),
        "mixed_bucket_request" => Value::Bool(qualification::mixed_bucket_request(&source)),
        "whole_turn_resolution_required" => {
            Value::Bool(qualification::whole_turn_resolution_required(&source))
        }
        _ => return Err(Failure("KeyError")),
    })
}

fn main() {
    let mut driver = Driver::default();
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            break;
        };
        let mut answer = Dict::new();
        match json::parse(&line) {
            Some(Value::Dict(request)) => match driver.handle(&request) {
                Ok(result) => {
                    answer.insert("ok", true);
                    answer.insert("result", result);
                }
                Err(Failure(error)) => {
                    answer.insert("ok", false);
                    answer.insert("error", error);
                }
            },
            _ => {
                answer.insert("ok", false);
                answer.insert("error", "JSONDecodeError");
            }
        }
        let written = writeln!(stdout, "{}", json::dumps_sorted(&Value::Dict(answer)))
            .and_then(|()| stdout.flush());
        if written.is_err() {
            break;
        }
    }
}
