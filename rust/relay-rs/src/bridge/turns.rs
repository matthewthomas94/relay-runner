//! Whether a command is still current, and what the provider turn ledgers
//! say about it (`voice_bridge.py` from `_relay_command_current` to
//! `_manual_claim_ack_matches`).

use std::collections::{BTreeMap, BTreeSet};

use super::replies;
use super::settings::settings;
use super::store::{self, read_json_file, relay_command_key};
use super::targets;
use crate::json::{Dict, Value};

/// `_relay_command_current(seq, id, state_path)`.
pub fn relay_command_current(seq: Option<&Value>, id: Option<&Value>, state_path: &str) -> bool {
    let (Some(seq), Some(id)) = (seq.filter(|value| !matches!(value, Value::Null)), id) else {
        return false;
    };
    if !id.truthy() {
        return false;
    }
    let current = {
        let _guard = store::voice_state_lock();
        read_json_file(state_path)
    };
    let (Some(current_seq), Some(expected_seq)) = (
        current.get("relay_command_seq").and_then(Value::py_int),
        seq.py_int(),
    ) else {
        return false;
    };
    current_seq == expected_seq && current.string("relay_command_id") == id.py_str()
}

/// `_relay_command_current` for a command's own seq and id.
pub fn command_current(command: &Dict, state_path: &str) -> bool {
    relay_command_current(
        command.get("relay_command_seq"),
        command.get("relay_command_id"),
        state_path,
    )
}

/// `_relay_command_current` with a typed key.
pub fn key_current(seq: i64, id: &str, state_path: &str) -> bool {
    relay_command_current(Some(&Value::Int(seq)), Some(&Value::from(id)), state_path)
}

/// `_relay_command_current_or_preserved`.
pub fn relay_command_current_or_preserved(
    relay_command: &Dict,
    state_path: &str,
    session_key: &str,
) -> bool {
    let Some(expected) = relay_command_key(relay_command) else {
        return false;
    };
    let mut current = {
        let _guard = store::voice_state_lock();
        read_json_file(state_path)
    };
    if let Some(cancelled) = current.get("cancelled_intent_ids").and_then(Value::as_list) {
        let intent_id = relay_command.string("intent_id");
        if cancelled.iter().any(|value| value.py_str() == intent_id) {
            return false;
        }
    }
    if !session_key.is_empty()
        && let Some(session) = current
            .get("session_commands")
            .and_then(Value::as_dict)
            .and_then(|sessions| sessions.get(session_key))
            .and_then(Value::as_dict)
    {
        current = session.clone();
    }
    let current_key = relay_command_key(&current);
    if current_key.as_ref() == Some(&expected) {
        return true;
    }
    match current_key {
        None => return false,
        Some((seq, _)) if seq <= expected.0 => return false,
        _ => {}
    }
    let Some(disposition) = current.get("work_disposition").and_then(Value::as_dict) else {
        return false;
    };
    disposition
        .get("route")
        .is_some_and(|value| value.is_str("continue_current"))
        && disposition
            .get("authorization_effect")
            .is_some_and(|value| value.is_str("preserve"))
        && match disposition.get("cancellation_scope") {
            None | Some(Value::Null) => true,
            Some(value) => value.is_str("none"),
        }
}

/// `_relay_intent_matches`.
pub fn relay_intent_matches(left: Option<&Dict>, right: Option<&Dict>) -> bool {
    if left.and_then(relay_command_key) != right.and_then(relay_command_key) {
        return false;
    }
    let left_intent = left
        .map(|value| value.text("intent_id"))
        .unwrap_or_default();
    let right_intent = right
        .map(|value| value.text("intent_id"))
        .unwrap_or_default();
    if !left_intent.is_empty() || !right_intent.is_empty() {
        return !left_intent.is_empty() && left_intent == right_intent;
    }
    true
}

/// `_provider_turn_ownership_matches`.
pub fn provider_turn_ownership_matches(record: &Dict, ownership: Option<&Dict>) -> bool {
    let Some(ownership) = ownership.filter(|ownership| !ownership.is_empty()) else {
        return true;
    };
    ownership
        .iter()
        .all(|(field, expected)| !expected.truthy() || record.string(field) == expected.py_str())
}

/// `_authoritative_provider_session_id`.
pub fn authoritative_provider_session_id() -> String {
    if let Some(ownership) = targets::provider_session_ownership() {
        let id = ownership.provider_session_id();
        if !id.is_empty() {
            return id;
        }
    }
    if let Some(target) = targets::current_voice_target()
        && !target.provider_session_id.is_empty()
    {
        return target.provider_session_id;
    }
    settings().provider_session_id.clone()
}

fn ledger_records(path: &str) -> Option<Vec<Value>> {
    read_json_file(path)
        .get("records")
        .and_then(Value::as_list)
        .map(<[Value]>::to_vec)
}

/// `_provider_turn_state`. `provider_session_id` `None` means the
/// authoritative one; an empty one matches every session.
pub fn provider_turn_state(
    relay_command: Option<&Dict>,
    turns_path: &str,
    provider_session_id: Option<&str>,
    provider_ownership: Option<&Dict>,
) -> Option<String> {
    let provider_session_id = provider_session_id
        .map(str::to_string)
        .unwrap_or_else(authoritative_provider_session_id);
    relay_command.and_then(relay_command_key)?;
    let records = ledger_records(turns_path)?;
    for record in records.iter().rev() {
        let Some(record) = record.as_dict() else {
            continue;
        };
        if (provider_session_id.is_empty()
            || record.string("provider_session_id") == provider_session_id)
            && provider_turn_ownership_matches(record, provider_ownership)
            && relay_intent_matches(Some(record), relay_command)
        {
            let state = record.text("state");
            return (!state.is_empty()).then_some(state);
        }
    }
    None
}

/// `_any_provider_turn_active`.
pub fn any_provider_turn_active(turns_path: &str, provider_session_id: Option<&str>) -> bool {
    let provider_session_id = provider_session_id
        .map(str::to_string)
        .unwrap_or_else(authoritative_provider_session_id);
    let Some(records) = ledger_records(turns_path) else {
        return false;
    };
    records.iter().filter_map(Value::as_dict).any(|record| {
        record.text("state") == "active"
            && (provider_session_id.is_empty()
                || record.string("provider_session_id") == provider_session_id)
    })
}

/// `_provider_record_key`.
pub fn provider_record_key(record: &Dict) -> String {
    let session_id = match record.truthy("session_id") {
        Some(value) => value.py_str(),
        None => "unknown".to_string(),
    };
    let turn_id = record.text("turn_id");
    if !turn_id.is_empty() {
        return format!("{session_id}:{turn_id}");
    }
    if let Some(local) = record.present("local_turn_seq") {
        return format!("{session_id}:local:{}", local.py_str());
    }
    session_id
}

fn within_turn_order(item: &Dict) -> i64 {
    match item.truthy("within_turn_order") {
        Some(value) => value.py_int().unwrap_or(0),
        None => 0,
    }
}

fn optional_text(text: &str) -> Value {
    if text.is_empty() {
        Value::Null
    } else {
        Value::from(text)
    }
}

fn optional_order(order: i64) -> Value {
    if order == 0 {
        Value::Null
    } else {
        Value::Int(order)
    }
}

/// The paths `_source_turn_reply_arbitration` reads.
pub struct ArbitrationPaths<'a> {
    pub state_path: &'a str,
    pub turns_path: &'a str,
    pub command_path: &'a str,
    pub meta_path: &'a str,
    pub broker_turns_path: Option<&'a str>,
}

fn decided(result: &Dict, decision: &str, reason: &str) -> Dict {
    let mut payload = result.clone();
    payload.insert("decision", decision);
    payload.insert("reason", reason);
    payload
}

/// `_source_turn_reply_arbitration`: decide a missing final once from every
/// intent in the current source turn.
pub fn source_turn_reply_arbitration(
    relay_command: &Dict,
    paths: &ArbitrationPaths<'_>,
    provider_session_id: Option<&str>,
) -> Dict {
    let Some(key) = relay_command_key(relay_command) else {
        let mut payload = Dict::new();
        payload.insert("decision", "cancel");
        payload.insert("reason", "missing_source_identity");
        payload.insert("siblings", Value::List(Vec::new()));
        return payload;
    };
    let provider_session_id = provider_session_id
        .map(str::to_string)
        .unwrap_or_else(authoritative_provider_session_id);

    let state = {
        let _guard = store::voice_state_lock();
        read_json_file(paths.state_path)
    };
    let cancelled: BTreeSet<String> = state
        .get("cancelled_intent_ids")
        .and_then(Value::as_list)
        .map(|values| {
            values
                .iter()
                .map(Value::py_str)
                .filter(|value| !value.is_empty())
                .collect()
        })
        .unwrap_or_default();

    // Insertion-ordered, as the Python dict is before it is sorted.
    let mut inbox_items: Vec<(String, Dict)> = Vec::new();
    fn entry<'a>(items: &'a mut [(String, Dict)], identity: &str) -> Option<&'a mut Dict> {
        items
            .iter_mut()
            .find(|(existing, _)| existing == identity)
            .map(|(_, item)| item)
    }
    let mut candidates: Vec<Dict> = Vec::new();
    for name in ["deliverable_commands", "source_command_intents"] {
        if let Some(values) = state.get(name).and_then(Value::as_list) {
            candidates.extend(values.iter().filter_map(Value::as_dict).cloned());
        }
    }
    if store::exists(paths.command_path) {
        let mut ready = read_json_file(paths.meta_path);
        if !ready.is_empty() {
            let ready_state = match ready.truthy("state") {
                Some(value) => value.py_str(),
                None => "delivered".to_string(),
            };
            ready.insert("state", ready_state);
            candidates.push(ready);
        }
    }
    for item in &candidates {
        if relay_command_key(item).as_ref() != Some(&key) {
            continue;
        }
        let intent_id = item.text("intent_id");
        let order = within_turn_order(item);
        let identity = if intent_id.is_empty() {
            format!("order:{order}")
        } else {
            intent_id.clone()
        };
        let item_state = match item.text("state") {
            state if state.is_empty() => "recognized".to_string(),
            state => state,
        };
        let mut summary = Dict::new();
        summary.insert("intent_id", optional_text(&intent_id));
        summary.insert("within_turn_order", optional_order(order));
        summary.insert("state", item_state);
        match entry(&mut inbox_items, &identity) {
            Some(existing) => *existing = summary,
            None => inbox_items.push((identity, summary)),
        }
    }

    let raw_records = ledger_records(paths.turns_path).unwrap_or_default();
    let session_matches = |record: &Dict| {
        provider_session_id.is_empty()
            || record.string("provider_session_id") == provider_session_id
    };
    let source_records: Vec<Dict> = raw_records
        .iter()
        .filter_map(Value::as_dict)
        .filter(|record| {
            relay_command_key(record).as_ref() == Some(&key)
                && session_matches(record)
                && !cancelled.contains(&record.string("intent_id"))
        })
        .cloned()
        .collect();
    let scoped_records: Vec<Dict> = raw_records
        .iter()
        .filter_map(Value::as_dict)
        .filter(|record| session_matches(record))
        .cloned()
        .collect();

    let mut record_states: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for record in &source_records {
        let intent_id = record.text("intent_id");
        let order = within_turn_order(record);
        let identity = if intent_id.is_empty() {
            format!("order:{order}")
        } else {
            intent_id.clone()
        };
        let state_name = match record.text("state") {
            state if state.is_empty() => "unknown".to_string(),
            state => state,
        };
        record_states
            .entry(identity.clone())
            .or_default()
            .push(state_name);
        if entry(&mut inbox_items, &identity).is_none() {
            let mut summary = Dict::new();
            summary.insert("intent_id", optional_text(&intent_id));
            summary.insert("within_turn_order", optional_order(order));
            summary.insert("state", Value::Null);
            inbox_items.push((identity, summary));
        }
    }

    let mut sorted: Vec<&(String, Dict)> = inbox_items.iter().collect();
    sorted.sort_by(|left, right| {
        let left_order = left
            .1
            .get("within_turn_order")
            .and_then(Value::py_int)
            .unwrap_or(0);
        let right_order = right
            .1
            .get("within_turn_order")
            .and_then(Value::py_int)
            .unwrap_or(0);
        (left_order, &left.0).cmp(&(right_order, &right.0))
    });
    let siblings: Vec<Value> = sorted
        .iter()
        .map(|(identity, item)| {
            let mut sibling = item.clone();
            let states: BTreeSet<String> = record_states
                .get(identity)
                .map(|states| states.iter().cloned().collect())
                .unwrap_or_default();
            sibling.insert(
                "provider_states",
                Value::List(states.into_iter().map(Value::from).collect()),
            );
            Value::Dict(sibling)
        })
        .collect();

    let mut result = Dict::new();
    result.insert("decision", "eligible");
    result.insert("reason", "all_siblings_terminal_empty");
    result.insert("siblings", Value::List(siblings));
    result.insert("provider_session_id", optional_text(&provider_session_id));

    let item_intent = |item: &Dict| {
        item.get("intent_id")
            .filter(|value| value.truthy())
            .map(Value::py_str)
    };
    let noncancelled: Vec<&Dict> = inbox_items
        .iter()
        .map(|(_, item)| item)
        .filter(|item| match item_intent(item) {
            None => true,
            Some(id) => !cancelled.contains(&id),
        })
        .collect();
    if !inbox_items.is_empty() && noncancelled.is_empty() {
        return decided(&result, "cancel", "source_cancelled");
    }
    const PENDING: [&str; 6] = [
        "recognized",
        "pending",
        "delivered",
        "claimed",
        "queued",
        "leased",
    ];
    if noncancelled.iter().any(|item| {
        item.get("state")
            .and_then(Value::as_str)
            .is_some_and(|state| PENDING.contains(&state))
    }) {
        return decided(&result, "defer", "sibling_pending");
    }
    if scoped_records
        .iter()
        .any(|record| record.string("state") == "active")
    {
        return decided(&result, "defer", "provider_turn_active");
    }
    if let Some(broker_turns_path) = paths.broker_turns_path
        && provider_turn_state(Some(relay_command), broker_turns_path, Some(""), None).as_deref()
            == Some("active")
    {
        return decided(&result, "defer", "provider_turn_active");
    }
    if replies::pm_trace_recent(Some(relay_command)) {
        return decided(&result, "defer", "provider_turn_active");
    }

    let mut records_by_key: BTreeMap<String, &Dict> = BTreeMap::new();
    for record in &scoped_records {
        records_by_key.insert(provider_record_key(record), record);
    }
    let mut ignored_orphans: BTreeSet<usize> = BTreeSet::new();
    let mut superseded: BTreeSet<String> = BTreeSet::new();
    for (index, record) in source_records.iter().enumerate() {
        if record.string("state") != "orphaned" {
            continue;
        }
        match record.text("provider_ownership_disposition").as_str() {
            "source_superseded" => return decided(&result, "cancel", "source_superseded"),
            "sibling_superseded" => {
                ignored_orphans.insert(index);
                let intent_id = record.text("intent_id");
                if !intent_id.is_empty() {
                    superseded.insert(intent_id);
                }
            }
            "continued" => {
                if !records_by_key.contains_key(&record.string("successor_record_key")) {
                    return decided(&result, "defer", "ownership_continuation_missing");
                }
                ignored_orphans.insert(index);
            }
            _ => return decided(&result, "defer", "orphaned_ownership_ambiguous"),
        }
    }
    let relevant: Vec<&Dict> = source_records
        .iter()
        .enumerate()
        .filter(|(index, _)| !ignored_orphans.contains(index))
        .map(|(_, record)| record)
        .collect();
    if relevant
        .iter()
        .any(|record| record.string("state") == "completed_final")
    {
        return decided(&result, "cancel", "provider_final_observed");
    }
    if relevant
        .iter()
        .any(|record| record.string("state") == "stale")
    {
        return decided(&result, "cancel", "source_stale");
    }
    const TERMINAL: [&str; 5] = ["empty", "failed", "terminated", "cancelled", "abandoned"];
    let terminal = |record: &&Dict| TERMINAL.contains(&record.string("state").as_str());
    for item in &noncancelled {
        let intent_id = item_intent(item)
            .map(|id| id.trim().to_string())
            .unwrap_or_default();
        if superseded.contains(&intent_id) {
            continue;
        }
        let mut matching: Vec<&Dict> = relevant
            .iter()
            .copied()
            .filter(|record| record.text("intent_id") == intent_id)
            .collect();
        if matching.is_empty() && noncancelled.len() == 1 {
            matching = relevant
                .iter()
                .copied()
                .filter(|record| !record.get("intent_id").is_some_and(Value::truthy))
                .collect();
        }
        if item.get("state").is_some_and(|state| state.is_str("acked")) && matching.is_empty() {
            return decided(&result, "defer", "awaiting_correlated_terminal");
        }
        if matching.iter().any(|record| !terminal(record)) {
            return decided(&result, "defer", "sibling_not_terminal");
        }
    }
    if relevant.iter().any(|record| !terminal(record)) {
        return decided(&result, "defer", "source_not_terminal");
    }
    result
}

/// `_provider_turn_seen`.
pub fn provider_turn_seen(
    command: Option<&Dict>,
    turns_path: &str,
    provider_session_id: Option<&str>,
    provider_ownership: Option<&Dict>,
) -> bool {
    provider_turn_state(command, turns_path, provider_session_id, provider_ownership).is_some()
}

/// `_manual_claim_ack_matches`: only the exact durable claim a manual
/// provider loop wrote.
pub fn manual_claim_ack_matches(claimed: Option<&Dict>, acknowledged: Option<&Dict>) -> bool {
    if claimed.and_then(relay_command_key) != acknowledged.and_then(relay_command_key) {
        return false;
    }
    [
        "intent_id",
        "intent_delivery_id",
        "intent_claim_id",
        "intent_ack_id",
    ]
    .iter()
    .all(|field| {
        let claimed = claimed.map(|value| value.text(field)).unwrap_or_default();
        let acknowledged = acknowledged
            .map(|value| value.text(field))
            .unwrap_or_default();
        !claimed.is_empty() && claimed == acknowledged
    })
}
