//! Binding a submitted prompt to a provider turn, and closing that turn when
//! the provider stops.
//!
//! The broker tables decide every lifecycle transition. The version 1 ledger
//! (`VOICE_PROVIDER_TURNS_FILE`) is still written beside them for the
//! dual-write release.

use crate::json::{self, Dict, Value, py_eq_optional};
use crate::sha256;
use crate::support::{
    self, FOREGROUND_OWNERSHIP_FIELDS, Failure, atomic_write_json, current_or_preserved,
    intent_cancelled, read_json_file, relay_command_key, write_fifo_line,
};

use super::broker::ProviderTurnBroker;
use super::{Event, continuation, note};

const RELAY_COMPLETION_PREFIX: &str = "__RELAY_COMPLETION__:";
const PROVIDER_TURN_EVENT_PREFIX: &str = "__PROVIDER_TURN_EVENT__:";
/// Fields a turn and its completion take from the claimed command.
const COMMAND_FIELDS: [&str; 5] = [
    "intent_id",
    "within_turn_order",
    "target",
    "disposition",
    "cancellation_scope",
];
const ACCEPTED_MANUAL_SUBMIT: &str = "accepted_terminal_manual_submit";

pub fn same_foreground_owner(left: &Dict, right: &Dict) -> bool {
    FOREGROUND_OWNERSHIP_FIELDS
        .iter()
        .all(|field| py_eq_optional(left.get(field), right.get(field)))
}

fn nonnegative_int(value: Option<&Value>) -> Option<i64> {
    value
        .and_then(Value::py_int_not_bool)
        .filter(|number| *number >= 0)
}

fn is_active(record: &Dict) -> bool {
    record.string("state") == "active"
}

fn relay_intent_matches(left: &Dict, right: &Dict) -> bool {
    if relay_command_key(left) != relay_command_key(right) {
        return false;
    }
    let (left_intent, right_intent) = (left.text("intent_id"), right.text("intent_id"));
    if left_intent.is_empty() && right_intent.is_empty() {
        return true;
    }
    !left_intent.is_empty() && left_intent == right_intent
}

/// Whether the turn's command is still the newest, or preserved by it.
fn command_current_or_preserved(command: &Dict, state_path: &str) -> bool {
    let Some(expected) = relay_command_key(command) else {
        return false;
    };
    let current = read_json_file(state_path);
    !intent_cancelled(&current, command) && current_or_preserved(&expected, &current)
}

/// Accept the exact leased inbox command even when a newer turn is current.
fn command_deliverable(command: &Dict, state_path: &str) -> bool {
    let Some(expected) = relay_command_key(command) else {
        return false;
    };
    let state = read_json_file(state_path);
    if relay_command_key(&state).as_ref() == Some(&expected) {
        return true;
    }
    state
        .get("deliverable_commands")
        .and_then(Value::as_list)
        .is_some_and(|deliverable| {
            deliverable
                .iter()
                .filter_map(Value::as_dict)
                .any(|candidate| {
                    relay_intent_matches(candidate, command)
                        && matches!(
                            candidate.string("state").as_str(),
                            "pending" | "delivered" | "claimed"
                        )
                })
        })
}

/// The text between a complete `<pasted_content id="…">` envelope, and
/// whether it had the leading blank line and the trailing newline.
fn pasted_content(prompt: &str) -> Option<(bool, bool, &str)> {
    let (leading, rest) = match prompt.strip_prefix("\n\n") {
        Some(rest) => (true, rest),
        None => (false, prompt),
    };
    let rest = rest.strip_prefix("<pasted_content id=\"")?;
    let id_length = rest
        .bytes()
        .take_while(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        .count();
    if id_length == 0 {
        return None;
    }
    let (id, rest) = rest.split_at(id_length);
    let body = rest.strip_prefix("\">\n")?;
    let closing = format!("\n</pasted_content id=\"{id}\">");
    if let Some(content) = body
        .strip_suffix('\n')
        .and_then(|body| body.strip_suffix(closing.as_str()))
    {
        return Some((leading, true, content));
    }
    body.strip_suffix(closing.as_str())
        .map(|content| (leading, false, content))
}

fn prompt_matches_claim(prompt: &str, claim: &Dict) -> bool {
    let expected = claim
        .truthy("agent_prompt")
        .and_then(Value::as_str)
        .or_else(|| claim.get("source_text").and_then(Value::as_str))
        .filter(|text| !text.is_empty());
    let Some(expected) = expected else {
        return false;
    };
    if prompt == expected {
        return true;
    }
    if claim.string("provider").to_lowercase() != "claude" {
        return false;
    }
    // Claude uses different outer newlines for a new pasted prompt and one
    // steered into an active turn. Match only either complete envelope.
    pasted_content(prompt)
        .is_some_and(|(leading, trailing, content)| leading == trailing && content == expected)
}

// -- version 1 ledger ----------------------------------------------------------

fn record_key(record: &Dict) -> String {
    let session_id = record
        .truthy("session_id")
        .map_or_else(|| "unknown".to_string(), Value::py_str);
    let turn_id = record.text("turn_id");
    if !turn_id.is_empty() {
        return format!("{session_id}:{turn_id}");
    }
    match nonnegative_int(record.get("local_turn_seq")) {
        Some(sequence) => format!("{session_id}:local:{sequence}"),
        None => session_id,
    }
}

/// Python's `records[-limit:]`.
fn newest(mut records: Vec<Dict>, limit: i64) -> Vec<Dict> {
    let length = records.len();
    let start = match usize::try_from(limit) {
        Ok(0) => 0,
        Ok(limit) => length.saturating_sub(limit),
        Err(_) => usize::try_from(limit.unsigned_abs()).map_or(length, |skip| skip.min(length)),
    };
    records.drain(..start);
    records
}

/// Whether a record is recent enough to keep. A record without a usable
/// timestamp is kept.
fn within_ttl(record: &Dict, event: &Event) -> bool {
    let stamp = record
        .truthy("updated_at")
        .or_else(|| record.truthy("created_at"));
    let age = stamp
        .and_then(Value::py_float)
        .map_or(0.0, |stamp| event.now - stamp);
    age <= event.settings.turn_ttl_seconds
}

fn load_turn_records(event: &Event) -> Vec<Dict> {
    let raw = read_json_file(&event.settings.turns_path);
    let records = raw
        .get("records")
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .filter(|record| within_ttl(record, event))
        .cloned()
        .collect();
    newest(records, event.settings.turn_limit)
}

fn save_turn_records(event: &Event, records: Vec<Dict>) -> Result<(), Failure> {
    let records = newest(records, event.settings.turn_limit);
    let mut state = Dict::new();
    state.insert("version", 1);
    state.insert("updated_at", event.now);
    state.insert(
        "records",
        records.into_iter().map(Value::Dict).collect::<Vec<_>>(),
    );
    atomic_write_json(&event.settings.turns_path, &Value::Dict(state))
}

fn upsert_turn_record(event: &Event, record: &Dict) -> Result<(), Failure> {
    let key = record_key(record);
    let mut records: Vec<Dict> = load_turn_records(event)
        .into_iter()
        .filter(|existing| record_key(existing) != key)
        .collect();
    let mut record = record.clone();
    record.insert("updated_at", event.now);
    records.push(record);
    save_turn_records(event, records)
}

/// Keep one physical foreground turn active per embedded provider session.
fn activate_turn_record(event: &Event, record: &Dict, release_reason: &str) -> Result<(), Failure> {
    let provider_session_id = record.text("provider_session_id");
    if provider_session_id.is_empty() {
        return upsert_turn_record(event, record);
    }
    let key = record_key(record);
    let successor_command = relay_command_key(record);
    let successor_origin = Some(record.text("origin"))
        .filter(|origin| !origin.is_empty())
        .unwrap_or_else(|| "relay".to_string());
    let mut records = Vec::new();
    for mut existing in load_turn_records(event) {
        if record_key(&existing) == key {
            continue;
        }
        if existing.string("provider_session_id") == provider_session_id
            && is_active(&existing)
            && same_foreground_owner(&existing, record)
        {
            let existing_command = relay_command_key(&existing);
            let intent_matches = relay_intent_matches(&existing, record);
            existing.insert("state", "orphaned");
            existing.insert("release_reason", release_reason);
            if existing_command.is_some() {
                let disposition = if release_reason == "provider_identity_rebound" && intent_matches
                {
                    "continued"
                } else if existing_command != successor_command {
                    "source_superseded"
                } else if intent_matches {
                    "continued"
                } else {
                    "sibling_superseded"
                };
                existing.insert("provider_ownership_disposition", disposition);
                existing.insert("successor_record_key", key.clone());
                existing.insert("successor_origin", successor_origin.clone());
            }
            existing.insert("updated_at", event.now);
        }
        records.push(existing);
    }
    let mut record = record.clone();
    record.insert("updated_at", event.now);
    records.push(record);
    save_turn_records(event, records)
}

fn next_local_turn_seq(event: &Event, session_id: &str) -> i64 {
    load_turn_records(event)
        .iter()
        .filter(|record| record.string("session_id") == session_id)
        .map(|record| nonnegative_int(record.get("local_turn_seq")).unwrap_or(0))
        .max()
        .unwrap_or(0)
        + 1
}

// -- diagnostics ---------------------------------------------------------------

/// `max(0, int(round(seconds * 1000)))`, rounding half to even.
fn milliseconds(seconds: f64) -> Option<i64> {
    let rounded = (seconds * 1000.0).round_ties_even();
    rounded.is_finite().then(|| (rounded as i64).max(0))
}

fn record_age_ms(record: &Dict, now: f64) -> i64 {
    let created_at = record
        .truthy("created_at")
        .or_else(|| record.truthy("updated_at"));
    match created_at {
        None => 0,
        Some(value) => value
            .py_float()
            .and_then(|created_at| milliseconds(now - created_at))
            .unwrap_or(0),
    }
}

fn emit_prompt_submit_diagnostic(event: &Event, evidence: Option<&Dict>, decision: &str) {
    let ownership_field = |field: &str| -> Value {
        event
            .ownership
            .as_ref()
            .and_then(|ownership| ownership.get(field))
            .cloned()
            .into()
    };
    let mut diagnostic = Dict::new();
    diagnostic.insert("app_session_id", ownership_field("app_session_id"));
    diagnostic.insert("actor_role", ownership_field("actor_role"));
    diagnostic.insert("decision", decision);
    diagnostic.insert(
        "drain_result",
        if decision == ACCEPTED_MANUAL_SUBMIT {
            "manual_owner_activated"
        } else {
            "active_relay_turn_preserved"
        },
    );
    diagnostic.insert("event", event.name());
    diagnostic.insert(
        "evidence_source",
        evidence
            .and_then(|evidence| evidence.truthy("evidence_source"))
            .map_or_else(|| "none".to_string(), Value::py_str),
    );
    diagnostic.insert(
        "foreground_gate_handle",
        ownership_field("foreground_gate_handle"),
    );
    diagnostic.insert("native_session_id", event.session_id());
    diagnostic.insert("native_turn_id", event.turn_id());
    diagnostic.insert(
        "provider",
        event
            .provider(None)
            .unwrap_or_else(|| "unknown".to_string()),
    );
    diagnostic.insert("provider_session_id", event.provider_session_id());
    diagnostic.insert(
        "recovery_generation",
        ownership_field("recovery_generation"),
    );
    diagnostic.insert(
        "submission_id",
        evidence
            .and_then(|evidence| evidence.get("submission_id"))
            .cloned(),
    );
    let boundary_age = evidence
        .and_then(|evidence| evidence.get("observed_at"))
        .and_then(Value::py_float)
        .and_then(|observed_at| milliseconds(event.now - observed_at));
    if let Some(age) = boundary_age {
        diagnostic.insert("boundary_age_ms", age);
    }
    event.diagnostic("prompt_submit_ownership", diagnostic);
}

fn emit_completion_correlation_diagnostic(
    event: &Event,
    candidates: &[Dict],
    decision: &str,
    release_reason: &str,
) {
    let mut diagnostic = Dict::new();
    diagnostic.insert("candidate_count", candidates.len() as i64);
    diagnostic.insert("decision", decision);
    diagnostic.insert("event", event.name());
    diagnostic.insert("native_session_id_to", event.session_id());
    diagnostic.insert("native_turn_id", event.turn_id());
    diagnostic.insert(
        "provider",
        event
            .provider(None)
            .unwrap_or_else(|| "unknown".to_string()),
    );
    diagnostic.insert("provider_session_id", event.provider_session_id());
    diagnostic.insert("release_reason", release_reason);
    let field = |record: &Dict, name: &str| -> Value { record.get(name).cloned().into() };
    if let [record] = candidates {
        diagnostic.insert(
            "native_session_id_from",
            record
                .truthy("session_id")
                .map_or_else(|| "unknown".to_string(), Value::py_str),
        );
        diagnostic.insert("record_age_ms", record_age_ms(record, event.now));
        diagnostic.insert("relay_command_seq", field(record, "relay_command_seq"));
        diagnostic.insert("relay_command_id", field(record, "relay_command_id"));
        if let Some(intent_id) = record.present("intent_id") {
            diagnostic.insert("intent_id", intent_id.clone());
        }
    } else if !candidates.is_empty() {
        let commands: Vec<Value> = candidates
            .iter()
            .map(|record| {
                let mut command = Dict::new();
                command.insert("relay_command_seq", field(record, "relay_command_seq"));
                command.insert("relay_command_id", field(record, "relay_command_id"));
                command.insert("intent_id", field(record, "intent_id"));
                command.insert("record_age_ms", record_age_ms(record, event.now));
                Value::Dict(command)
            })
            .collect();
        diagnostic.insert("candidate_commands", commands);
    }
    event.diagnostic("completion_correlation", diagnostic);
}

// -- FIFO ----------------------------------------------------------------------

fn write_bridge_line(event: &Event, prefix: &str, payload: Dict) -> Result<bool, Failure> {
    let line = format!("{prefix}{}", json::dumps_sorted(&Value::Dict(payload)));
    write_fifo_line(&event.settings.fifo_path, &line, support::wait_deadline())
}

fn publish_provider_started(event: &Event, record: &Dict) -> Result<(), Failure> {
    let mut started = Dict::new();
    started.insert("event", "provider_started");
    for field in ["provider", "relay_command_id", "recovery_generation"] {
        if let Some(value) = record.present(field) {
            started.insert(field, value.clone());
        }
    }
    started.insert("observed_at", event.now);
    write_bridge_line(event, PROVIDER_TURN_EVENT_PREFIX, started).map(|_| ())
}

// -- UserPromptSubmit ------------------------------------------------------------

/// The pending manual submission, and whether it lets this prompt open a
/// manual turn.
fn manual_submission_evidence(event: &Event) -> (Option<Dict>, &'static str) {
    let evidence = read_json_file(&event.settings.manual_submissions_path);
    if evidence.is_empty() {
        return (None, "quarantined_provider_continuation_no_manual_boundary");
    }
    let decision = manual_submission_decision(event, &evidence);
    (Some(evidence), decision)
}

fn manual_submission_decision(event: &Event, evidence: &Dict) -> &'static str {
    if !evidence
        .get("state")
        .is_some_and(|state| state.is_str("pending"))
    {
        return "quarantined_provider_continuation_boundary_consumed";
    }
    let source = evidence.get("evidence_source");
    if !source.is_some_and(|source| source.is_str("relay_terminal_manual_submit")) {
        return "quarantined_provider_continuation_invalid_evidence_source";
    }
    if !event.owns(evidence) {
        return "quarantined_provider_continuation_foreground_mismatch";
    }
    match event.provider_session_id() {
        Some(session) if session == evidence.text("provider_session_id") => {}
        _ => return "quarantined_provider_continuation_provider_session_mismatch",
    }
    match event.provider(None) {
        Some(provider) if provider == evidence.text("provider").to_lowercase() => {}
        _ => return "quarantined_provider_continuation_provider_mismatch",
    }
    let Some(observed_at) = evidence.get("observed_at").and_then(Value::py_float) else {
        return "quarantined_provider_continuation_invalid_boundary_time";
    };
    let age = event.now - observed_at;
    if age < -0.25 {
        return "quarantined_provider_continuation_future_boundary";
    }
    if age > event.settings.evidence_ttl_seconds {
        return "quarantined_provider_continuation_stale_boundary";
    }
    if evidence.text("submission_id").is_empty() {
        return "quarantined_provider_continuation_missing_nonce";
    }
    if let Some(continuation) = evidence.present("continuation_source") {
        let prompt = event
            .payload
            .get("prompt")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let digest = Value::from(sha256::hex_digest(prompt.as_bytes()));
        if prompt.is_empty() || !py_eq_optional(Some(&digest), evidence.get("prompt_sha256")) {
            return "quarantined_context_continuation_prompt_mismatch";
        }
        let mut request = Dict::new();
        request.insert("operation", "check");
        request.insert("source", continuation.clone());
        let authority = continuation::authority(&request, &event.settings.inbox_path);
        if !authority
            .get("status")
            .is_some_and(|status| status.is_str("ready"))
        {
            return "quarantined_context_continuation_parent_revoked";
        }
    }
    ACCEPTED_MANUAL_SUBMIT
}

fn consume_manual_submission_evidence(event: &Event, evidence: &Dict) -> Result<(), Failure> {
    let mut consumed = evidence.clone();
    consumed.insert("state", "consumed");
    consumed.insert("consumed_at", event.now);
    consumed.insert("native_session_id", event.session_id());
    if let Some(turn_id) = event.turn_id() {
        consumed.insert("native_turn_id", turn_id);
    }
    atomic_write_json(
        &event.settings.manual_submissions_path,
        &Value::Dict(consumed),
    )
}

/// Turns the claimed command already owns under this foreground owner.
fn command_turn_records(event: &Event, command: &Dict) -> Vec<Dict> {
    if relay_command_key(command).is_none() {
        return Vec::new();
    }
    load_turn_records(event)
        .into_iter()
        .filter(|record| {
            event.owns(record)
                && relay_intent_matches(record, command)
                && record.string("state") != "stale"
        })
        .collect()
}

fn command_bound_to_provider_turn(event: &Event, records: &[Dict]) -> bool {
    let session_id = event.session_id();
    let provider_session_id = event.provider_session_id();
    let mut matching_session = records.iter().filter(|record| {
        record.string("session_id") == session_id
            && provider_session_id
                .as_ref()
                .is_none_or(|session| record.string("provider_session_id") == *session)
    });
    match event.turn_id() {
        Some(turn_id) => matching_session.any(|record| record.string("turn_id") == turn_id),
        None => matching_session.any(is_active),
    }
}

fn activate(
    event: &Event,
    broker: Option<&ProviderTurnBroker>,
    record: &Dict,
    release_reason: &str,
) -> Result<(), Failure> {
    if let Some(broker) = broker {
        broker.activate(record, event.now, release_reason)?;
    }
    activate_turn_record(event, record, release_reason)
}

pub fn bind_prompt_submit(
    event: &Event,
    broker: Option<&ProviderTurnBroker>,
) -> Result<(), Failure> {
    let Some(ownership) = &event.ownership else {
        return Ok(());
    };
    let payload = event.payload;
    let Some(prompt) = payload
        .get("prompt")
        .and_then(Value::as_str)
        .filter(|prompt| !prompt.is_empty())
    else {
        return Ok(());
    };
    if payload.truthy("parent_tool_use_id").is_some() || payload.truthy("parentToolUseId").is_some()
    {
        emit_prompt_submit_diagnostic(
            event,
            None,
            "ignored_provider_continuation_parent_tool_marker",
        );
        return Ok(());
    }
    let settings = event.settings;
    let claim = read_json_file(&settings.claim_path);
    let mut correlated = !claim.is_empty()
        && command_deliverable(&claim, &settings.state_path)
        && prompt_matches_claim(prompt, &claim);

    let provider_session_id = event.provider_session_id();
    let command_records = if correlated {
        command_turn_records(event, &claim)
    } else {
        Vec::new()
    };
    if correlated && command_bound_to_provider_turn(event, &command_records) {
        return Ok(());
    }
    if correlated && let Some(session) = &provider_session_id {
        let newest_active = command_records
            .iter()
            .rfind(|record| is_active(record) && record.string("provider_session_id") == *session);
        if let Some(active) = newest_active {
            // Codex can emit a startup-scoped prompt identity before its
            // persisted transcript session identity. Rebind the same logical
            // Relay turn to the newest native identity instead of inventing a
            // manual barrier.
            let mut record = active.clone();
            let session_id = event.session_id();
            record.insert("session_id", session_id.clone());
            record.remove("turn_id");
            record.remove("local_turn_seq");
            match event.turn_id() {
                Some(turn_id) => record.insert("turn_id", turn_id),
                None => record.insert("local_turn_seq", next_local_turn_seq(event, &session_id)),
            }
            activate(event, broker, &record, "provider_identity_rebound")?;
            return publish_provider_started(event, &record);
        }
    }
    // Matching text is not a provider-turn identity. Once the Relay command
    // has owned another turn, the same text in a new turn is ordinary manual
    // input.
    if !command_records.is_empty() {
        correlated = false;
    }

    if !correlated {
        let evidence = match manual_submission_evidence(event) {
            (Some(evidence), ACCEPTED_MANUAL_SUBMIT) => evidence,
            (evidence, decision) => {
                emit_prompt_submit_diagnostic(event, evidence.as_ref(), decision);
                return Ok(());
            }
        };
        consume_manual_submission_evidence(event, &evidence)?;
        let session_id = event.session_id();
        let field = |name: &str| -> Value { evidence.get(name).cloned().into() };
        let mut record = Dict::new();
        record.insert("state", "active");
        record.insert("origin", "manual");
        record.insert("session_id", session_id.clone());
        record.insert("created_at", event.now);
        record.insert("manual_submission_id", field("submission_id"));
        record.insert("manual_submit_evidence_source", field("evidence_source"));
        let parent = evidence.get("continuation_source").and_then(Value::as_dict);
        if let Some(parent) = parent
            && let Some(intent_id) = parent.truthy("intent_id")
        {
            let command_seq = parent.get("command_seq").ok_or(Failure("KeyError"))?;
            let command_id = parent.get("command_id").ok_or(Failure("KeyError"))?;
            record.insert("intent_id", intent_id.clone());
            record.insert(
                "relay_command_seq",
                command_seq.py_int().ok_or(Failure("ValueError"))?,
            );
            record.insert("relay_command_id", command_id.clone());
        }
        match event.turn_id() {
            Some(turn_id) => record.insert("turn_id", turn_id),
            None => record.insert("local_turn_seq", next_local_turn_seq(event, &session_id)),
        }
        if let Some(provider) = event.provider(None) {
            record.insert("provider", provider);
        }
        if let Some(session) = provider_session_id {
            record.insert("provider_session_id", session);
        }
        record.update(ownership);
        activate(event, broker, &record, "superseded_by_prompt_submit")?;
        emit_prompt_submit_diagnostic(event, Some(&evidence), ACCEPTED_MANUAL_SUBMIT);
        return Ok(());
    }

    let Some((command_seq, command_id)) = relay_command_key(&claim) else {
        return Ok(());
    };
    let mut record = Dict::new();
    record.insert("state", "active");
    record.insert("session_id", event.session_id());
    record.insert("created_at", event.now);
    record.insert("relay_command_seq", command_seq);
    record.insert("relay_command_id", command_id);
    record.insert("prompt_sha256", sha256::hex_digest(prompt.as_bytes()));
    for field in COMMAND_FIELDS {
        if let Some(value) = claim.present(field) {
            record.insert(field, value.clone());
        }
    }
    if let Some(turn_id) = event.turn_id() {
        record.insert("turn_id", turn_id);
    }
    if let Some(provider) = event.provider(Some(&claim)) {
        record.insert("provider", provider);
    }
    if let Some(session) = provider_session_id {
        record.insert("provider_session_id", session);
    }
    record.update(ownership);
    if let Some(action) = claim.truthy("action") {
        record.insert("action", action.clone());
    }
    activate(event, broker, &record, "superseded_by_prompt_submit")?;
    publish_provider_started(event, &record)
}

// -- Stop and StopFailure --------------------------------------------------------

fn provider_matches(event: &Event, record: &Dict) -> bool {
    let record_provider = record.text("provider").to_lowercase();
    match event.provider(None) {
        Some(provider) => record_provider.is_empty() || record_provider == provider,
        None => true,
    }
}

fn can_reconcile_provider_identity(record: &Dict) -> bool {
    relay_command_key(record).is_some()
        || (is_active(record) && record.string("origin") == "manual")
}

/// The turn a Stop names, how it was found, and the candidates considered.
fn find_turn_record(
    event: &Event,
    broker: Option<&ProviderTurnBroker>,
) -> Result<(Option<Dict>, &'static str, Vec<Dict>), Failure> {
    let session_id = event.session_id();
    let turn_id = event.turn_id();
    let provider_session_id = event.provider_session_id();
    let mut all = load_turn_records(event);
    // RR-465: a bridge restart can remove the version 1 ledger mid-turn while
    // the broker still holds the active turn, so correlate through the broker.
    if let Some(broker) = broker
        && !all
            .iter()
            .any(|record| record.string("session_id") == session_id)
    {
        let known: Vec<String> = all.iter().map(record_key).collect();
        let stored = broker
            .session_records(&session_id)?
            .into_iter()
            .filter(|record| within_ttl(record, event))
            .collect();
        let stored = newest(stored, event.settings.turn_limit);
        all.extend(
            stored
                .into_iter()
                .filter(|record| !known.contains(&record_key(record))),
        );
    }
    let records: Vec<&Dict> = all
        .iter()
        .filter(|record| {
            record.string("session_id") == session_id
                && event.owns(record)
                && provider_session_id
                    .as_ref()
                    .is_none_or(|session| record.string("provider_session_id") == *session)
        })
        .collect();
    let active: Vec<&Dict> = records
        .iter()
        .copied()
        .filter(|record| is_active(record))
        .collect();
    let found =
        |record: &Dict, how: &'static str| Ok((Some(record.clone()), how, vec![record.clone()]));
    let Some(turn_id) = turn_id else {
        return match (active.as_slice(), records.last()) {
            ([only], _) => found(only, "exact_native_session"),
            ([], Some(last)) => found(last, "exact_native_session"),
            ([], None) => Ok((None, "rejected_native_identity_mismatch", Vec::new())),
            _ => Ok((
                None,
                "rejected_ambiguous_native_session",
                active.into_iter().cloned().collect(),
            )),
        };
    };
    if let Some(record) = records
        .iter()
        .rfind(|record| record.string("turn_id") == turn_id)
    {
        return found(record, "exact_native_identity");
    }
    // A voice command queued mid-turn submits under the running turn's
    // prompt_id, but Claude assigns a new prompt_id when it dequeues the
    // message, and the final Stop carries that one. Claude runs a session's
    // turns serially, so a sole active record is this turn.
    if event.provider(None).as_deref() == Some("claude")
        && let [only] = active.as_slice()
    {
        return found(only, "claude_prompt_id_rotated");
    }
    let Some(provider_session_id) = provider_session_id else {
        return Ok((None, "rejected_provider_session_missing", Vec::new()));
    };
    let mut candidates: Vec<Dict> = all
        .iter()
        .filter(|record| {
            record.string("provider_session_id") == provider_session_id
                && event.owns(record)
                && record.string("turn_id") == turn_id
                && can_reconcile_provider_identity(record)
                && provider_matches(event, record)
        })
        .cloned()
        .collect();
    Ok(match candidates.len() {
        0 => (None, "rejected_no_exact_physical_turn", candidates),
        1 => (candidates.pop(), "provider_identity_reconciled", Vec::new()),
        _ => (None, "rejected_ambiguous_provider_identity", candidates),
    })
}

/// Moves the turn in the tables. A turn accepted before the tables existed
/// has no row and finishes through the ledger alone.
fn transition_broker_turn(
    event: &Event,
    broker: Option<&ProviderTurnBroker>,
    record: &Dict,
    to_state: &str,
    event_type: &str,
    release_reason: &str,
) -> Result<bool, Failure> {
    let Some(broker) = broker else {
        return Ok(true);
    };
    if broker.state_for(record)?.is_none() {
        return Ok(true);
    }
    broker.transition(record, to_state, event_type, release_reason, event.now)
}

pub fn complete_turn(
    event: &Event,
    name: &str,
    broker: Option<&ProviderTurnBroker>,
) -> Result<(), Failure> {
    let (record, correlation, candidates) = find_turn_record(event, broker)?;
    let Some(record) = record else {
        emit_completion_correlation_diagnostic(
            event,
            &candidates,
            correlation,
            "completion_not_correlated",
        );
        note("ignored provider completion without Relay voice correlation");
        return Ok(());
    };
    let identity_reconciled = correlation == "provider_identity_reconciled";
    if !is_active(&record) {
        if identity_reconciled {
            let release_reason = record
                .truthy("release_reason")
                .map_or_else(|| "already_terminal".to_string(), Value::py_str);
            emit_completion_correlation_diagnostic(
                event,
                std::slice::from_ref(&record),
                "rejected_duplicate_provider_completion",
                &release_reason,
            );
        }
        note("ignored duplicate provider completion");
        return Ok(());
    }
    let failed = name == "StopFailure";
    let provider_stop_reason = match (identity_reconciled, failed) {
        (true, true) => "provider_stop_failure_identity_reconciled",
        (true, false) => "provider_stop_identity_reconciled",
        (false, true) => "provider_stop_failure",
        (false, false) => "provider_stop",
    };
    // The record as it is closed: the ledger entry, annotated when the native
    // session changed under the turn.
    let mut closed = record.clone();
    if identity_reconciled {
        closed.insert("completion_correlation", "provider_identity_reconciled");
        closed.insert("completion_native_session_id", event.session_id());
        closed.insert(
            "completion_record_age_ms",
            record_age_ms(&record, event.now),
        );
    }
    let close = |closed: Dict, state: &str, event_type: &str, release_reason: &str| {
        let moved =
            transition_broker_turn(event, broker, &record, state, event_type, release_reason)?;
        if !moved {
            note("ignored duplicate provider completion");
        }
        Ok::<_, Failure>(moved.then_some(closed))
    };
    let accepted = |closed: &Dict, release_reason: &str| {
        if identity_reconciled {
            emit_completion_correlation_diagnostic(
                event,
                std::slice::from_ref(closed),
                "accepted_provider_identity_reconciliation",
                release_reason,
            );
        }
    };

    let manual = record
        .get("origin")
        .is_some_and(|origin| origin.is_str("manual"));
    if manual || relay_command_key(&record).is_none() {
        let state = if failed {
            "failed_manual"
        } else {
            "completed_manual"
        };
        closed.insert("state", state);
        closed.insert("release_reason", provider_stop_reason);
        let Some(closed) = close(closed, state, "provider_completed", provider_stop_reason)? else {
            return Ok(());
        };
        upsert_turn_record(event, &closed)?;
        accepted(&closed, provider_stop_reason);
        return Ok(());
    }
    if !command_current_or_preserved(&record, &event.settings.state_path) {
        let release_reason = if identity_reconciled {
            "stale_current_command_identity_reconciled"
        } else {
            "stale_current_command"
        };
        closed.insert("state", "stale");
        closed.insert("release_reason", release_reason);
        let Some(closed) = close(closed, "stale", "provider_completion_stale", release_reason)?
        else {
            return Ok(());
        };
        upsert_turn_record(event, &closed)?;
        accepted(&closed, release_reason);
        note("dropped stale Relay provider completion");
        return Ok(());
    }

    let final_text = if name == "Stop" {
        event.payload.text("last_assistant_message")
    } else {
        String::new()
    };
    let field = |name: &str| -> Value { record.get(name).cloned().into() };
    let mut completion = Dict::new();
    completion.insert("event", name);
    completion.insert("relay_command_seq", field("relay_command_seq"));
    completion.insert("relay_command_id", field("relay_command_id"));
    completion.insert("session_id", field("session_id"));
    if !event.settings.session_key.is_empty() {
        completion.insert("session_key", event.settings.session_key.clone());
    }
    for copied in COMMAND_FIELDS.iter().chain(&FOREGROUND_OWNERSHIP_FIELDS) {
        if let Some(value) = record.present(copied) {
            completion.insert(copied, value.clone());
        }
    }
    for copied in ["turn_id", "provider", "action"] {
        if let Some(value) = record.truthy(copied) {
            completion.insert(copied, value.clone());
        }
    }
    let state = if !final_text.is_empty() {
        completion.insert("text", final_text);
        "completed_final"
    } else {
        let status = if failed { "failed" } else { "empty" };
        completion.insert("completion_status", status);
        status
    };
    let Some(mut closed) = close(closed, state, "provider_completed", provider_stop_reason)? else {
        return Ok(());
    };

    let delivered = write_bridge_line(event, RELAY_COMPLETION_PREFIX, completion)?;
    closed.insert("state", state);
    closed.insert(
        "delivery",
        if delivered {
            "sent"
        } else {
            "bridge_unavailable"
        },
    );
    closed.insert("release_reason", provider_stop_reason);
    upsert_turn_record(event, &closed)?;
    accepted(&closed, provider_stop_reason);
    if !delivered {
        note(
            "Relay bridge unavailable; provider completion was not spoken. \
             Check the terminal for the final result.",
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            _ => panic!("not an object: {text}"),
        }
    }

    #[test]
    fn claude_prompt_matches_only_a_complete_pasted_envelope() {
        let claim = dict(r#"{"source_text": "ship it\nnow", "provider": "Claude"}"#);
        let open = "<pasted_content id=\"0a1f\">\n";
        let close = "\n</pasted_content id=\"0a1f\">";
        let body = "ship it\nnow";
        assert!(prompt_matches_claim(body, &claim));
        assert!(prompt_matches_claim(
            &format!("{open}{body}{close}"),
            &claim
        ));
        assert!(prompt_matches_claim(
            &format!("\n\n{open}{body}{close}\n"),
            &claim
        ));
        for prompt in [
            format!("\n\n{open}{body}{close}"),
            format!("{open}{body}{close}\n"),
            format!("\n{open}{body}{close}\n"),
            format!("{open}{body}\n</pasted_content id=\"0a1e\">"),
            format!("{open}{body} extra{close}"),
            format!("<pasted_content id=\"0A1F\">\n{body}\n</pasted_content id=\"0A1F\">"),
            format!("<pasted_content id=\"\">\n{body}\n</pasted_content id=\"\">"),
            format!("{open}{body}{close} trailing"),
            "ship it".to_string(),
        ] {
            assert!(!prompt_matches_claim(&prompt, &claim), "{prompt:?}");
        }
        // The text may itself hold a closing tag; the envelope is the outer one.
        let nested =
            dict(r#"{"source_text": "a\n</pasted_content id=\"0a1f\">", "provider": "claude"}"#);
        assert!(prompt_matches_claim(
            &format!("{open}a{close}{close}"),
            &nested
        ));

        let codex = dict(r#"{"source_text": "ship it\nnow", "provider": "codex"}"#);
        assert!(!prompt_matches_claim(
            &format!("{open}{body}{close}"),
            &codex
        ));
        let agent =
            dict(r#"{"agent_prompt": "wrapped", "source_text": "ship it", "provider": "codex"}"#);
        assert!(prompt_matches_claim("wrapped", &agent));
        assert!(!prompt_matches_claim("ship it", &agent));
        assert!(!prompt_matches_claim("", &dict(r#"{"source_text": ""}"#)));
    }

    #[test]
    fn record_key_prefers_the_native_turn_then_the_local_sequence() {
        assert_eq!(
            record_key(&dict(
                r#"{"session_id": "s", "turn_id": " t ", "local_turn_seq": 2}"#
            )),
            "s:t"
        );
        assert_eq!(
            record_key(&dict(r#"{"session_id": "s", "local_turn_seq": 2}"#)),
            "s:local:2"
        );
        assert_eq!(
            record_key(&dict(r#"{"session_id": "s", "local_turn_seq": -1}"#)),
            "s"
        );
        assert_eq!(record_key(&dict(r#"{"local_turn_seq": true}"#)), "unknown");
    }

    #[test]
    fn newest_is_a_python_negative_slice() {
        let records = |count: i64| -> Vec<Dict> {
            (0..count)
                .map(|index| dict(&format!(r#"{{"n": {index}}}"#)))
                .collect()
        };
        let numbers = |records: Vec<Dict>| -> Vec<i64> {
            records
                .iter()
                .map(|record| record.get("n").unwrap().py_int().unwrap())
                .collect()
        };
        assert_eq!(numbers(newest(records(5), 2)), [3, 4]);
        assert_eq!(numbers(newest(records(2), 32)), [0, 1]);
        assert_eq!(numbers(newest(records(3), 0)), [0, 1, 2]);
        assert_eq!(numbers(newest(records(5), -2)), [2, 3, 4]);
        assert_eq!(numbers(newest(records(2), -9)), Vec::<i64>::new());
    }

    #[test]
    fn intents_match_only_within_one_command() {
        let command = |seq: i64, intent: &str| {
            dict(&format!(
                r#"{{"relay_command_id": "cmd", "relay_command_seq": {seq}, "intent_id": "{intent}"}}"#
            ))
        };
        assert!(relay_intent_matches(&command(7, "a"), &command(7, "a")));
        assert!(!relay_intent_matches(&command(7, "a"), &command(7, "b")));
        assert!(!relay_intent_matches(&command(7, "a"), &command(7, "")));
        assert!(relay_intent_matches(&command(7, ""), &command(7, "")));
        assert!(!relay_intent_matches(&command(7, "a"), &command(8, "a")));
        assert!(relay_intent_matches(&Dict::new(), &Dict::new()));
    }

    #[test]
    fn milliseconds_round_half_to_even_and_never_go_negative() {
        assert_eq!(milliseconds(0.0005), Some(0));
        assert_eq!(milliseconds(0.0015), Some(2));
        assert_eq!(milliseconds(1.2344), Some(1234));
        assert_eq!(milliseconds(-3.0), Some(0));
        assert_eq!(milliseconds(f64::NAN), None);
        assert_eq!(milliseconds(f64::INFINITY), None);
    }
}
