//! A command's one authoritative final: the foreground reply, the provider
//! completion, the missing-reply fallback, sidecar outcomes and provider
//! turn events (`voice_bridge.py` from `_missing_foreground_reply_text` to
//! `_handle_provider_turn_event_control`, with `_handle_sidecar_*` and
//! `_log_provider_session_transition`).

use std::thread;
use std::time::{Duration, Instant};

use relay_intents::model::TurnState;

use super::context::Bridge;
use super::controls::log_quarantined_relay_control;
use super::orchestrator::{LocalDaemon, post_continuity_event};
use super::replies;
use super::settings::settings;
use super::speech::{self, TtsOptions, tagged_payload};
use super::store::{read_json_file, relay_command_key};
use super::targets::{self, ProviderSessionOwnership};
use super::turns::{self, ArbitrationPaths};
use crate::json::{self, Dict, Value};
use crate::support::env_or;

/// `_missing_foreground_reply_text_for_kind`.
pub fn missing_foreground_reply_text_for_kind(kind: Option<&str>) -> &'static str {
    match kind {
        Some("create_ticket" | "update_ticket" | "dispatch_ticket") => {
            "I handled that Relay voice turn, but the provider did not send a spoken final reply. \
             Check the terminal for the current details; worker updates will still be announced."
        }
        _ => {
            "I handled that Relay voice turn, but the provider did not send a spoken final reply. \
             Check the terminal for the full result."
        }
    }
}

/// The paths a reply handler reads, defaulting to the bridge's own.
#[derive(Clone, Debug)]
pub struct ReplyPaths {
    pub state_path: String,
    pub turns_path: String,
    pub command_path: String,
    pub meta_path: String,
}

impl Default for ReplyPaths {
    fn default() -> Self {
        let settings = settings();
        Self {
            state_path: settings.command_state_file.clone(),
            turns_path: settings.provider_turns_file.clone(),
            command_path: settings.cmd_file.clone(),
            meta_path: settings.cmd_meta_file.clone(),
        }
    }
}

fn merged(parts: &[&Dict]) -> Dict {
    let mut payload = Dict::new();
    for part in parts {
        payload.update(part);
    }
    payload
}

/// What a broker reservation decided for one effect.
enum Reservation {
    Accepted(Option<String>),
    Duplicate,
    Revoked,
    Refused,
}

fn reserve(bridge: &Bridge, command: &Dict, effect_kind: &str) -> Reservation {
    let Some(broker) = bridge.broker() else {
        return Reservation::Accepted(None);
    };
    let reservation = match broker.reserve_effect(command, effect_kind, None) {
        Ok(reservation) => reservation,
        Err(error) => {
            eprintln!("[voice_bridge] Could not reserve the reply effect: {error}");
            return if bridge.dual_write() {
                Reservation::Accepted(None)
            } else {
                Reservation::Refused
            };
        }
    };
    if reservation.accepted {
        return Reservation::Accepted(reservation.effect_id);
    }
    match reservation.reason {
        "duplicate" => Reservation::Duplicate,
        "turn_revoked" => Reservation::Revoked,
        _ if bridge.dual_write() => Reservation::Accepted(None),
        _ => Reservation::Refused,
    }
}

fn finish_effect(bridge: &Bridge, effect_id: &Option<String>, delivered: bool) {
    if let (Some(effect_id), Some(broker)) = (effect_id, bridge.broker())
        && let Err(error) = broker.finish_effect(effect_id, delivered, None)
    {
        eprintln!("[voice_bridge] Could not finish the reply effect: {error}");
    }
}

fn authorize_effect(bridge: &Bridge, effect_id: &Option<String>) -> bool {
    match (effect_id, bridge.broker()) {
        (Some(effect_id), Some(broker)) => broker
            .authorize_effect_delivery(effect_id, None)
            .unwrap_or(false),
        _ => true,
    }
}

/// `_deliver_missing_foreground_reply`: `None` when another delivery already
/// owns the slot.
pub fn deliver_missing_foreground_reply(
    bridge: &Bridge,
    relay_command: &Dict,
    action_kind: Option<&str>,
    state_path: &str,
) -> Option<bool> {
    let Some((seq, id)) = relay_command_key(relay_command) else {
        return Some(false);
    };
    if replies::foreground_reply_delivered(Some(relay_command))
        || replies::foreground_fallback_delivered(Some(relay_command))
    {
        return None;
    }
    if !turns::relay_command_current_or_preserved(relay_command, state_path, "") {
        return Some(false);
    }
    let effect_id = match reserve(bridge, relay_command, "missing_reply_fallback") {
        Reservation::Accepted(effect_id) => effect_id,
        Reservation::Duplicate => return None,
        Reservation::Revoked => {
            replies::finish_foreground_reply_delivery(Some(relay_command), false, false);
            return Some(false);
        }
        Reservation::Refused => return Some(false),
    };
    if !replies::reserve_foreground_reply_delivery(Some(relay_command)) {
        finish_effect(bridge, &effect_id, false);
        return None;
    }
    let text = missing_foreground_reply_text_for_kind(action_kind);
    let mut payload = Dict::new();
    payload.insert("text", text);
    payload.insert("relay_command_seq", seq);
    payload.insert("relay_command_id", id.as_str());
    payload.insert("speech_source", "fallback");
    if !authorize_effect(bridge, &effect_id) {
        replies::finish_foreground_reply_delivery(Some(relay_command), false, false);
        return Some(false);
    }
    let mut delivered = bridge
        .messenger()
        .is_some_and(|messenger| messenger.submit_final(payload.clone()));
    if !delivered {
        let mut speech_payload = payload.clone();
        speech_payload.insert("display_text", text);
        delivered = speech::queue_tts_text(
            bridge.speech(),
            &json::dumps(&Value::Dict(speech_payload)),
            TtsOptions {
                state_path: state_path.to_string(),
                allow_pending_command: true,
                preserved_command: Some(relay_command.clone()),
                source: "fallback".to_string(),
                kind: "fallback".to_string(),
                authoritative: true,
                semantic_brief: Some(text.to_string()),
                replayable: Some(true),
                ..TtsOptions::default()
            },
        );
    }
    replies::finish_foreground_reply_delivery(Some(relay_command), delivered, true);
    finish_effect(bridge, &effect_id, delivered);
    Some(delivered)
}

/// `_log_foreground_reply_fallback_event`.
fn log_fallback_event(
    event: &str,
    relay_command: &Dict,
    turns_path: &str,
    reason: Option<&str>,
    arbitration: Option<&Dict>,
) {
    let mut fields = vec![format!("event={event}")];
    if let Some((seq, id)) = relay_command_key(relay_command) {
        fields.push(format!("relay_command_seq={seq}"));
        fields.push(format!("relay_command_id={id}"));
    }
    let intent_id = relay_command.text("intent_id");
    if !intent_id.is_empty() {
        fields.push(format!("intent_id={intent_id}"));
    }
    if let Some(order) = relay_command.present("within_turn_order") {
        fields.push(format!("within_turn_order={}", order.py_str()));
    }
    let state = turns::provider_turn_state(Some(relay_command), turns_path, None, None)
        .unwrap_or_else(|| "none".to_string());
    fields.push(format!("provider_turn_state={state}"));
    let provider = relay_command.text("provider");
    if !provider.is_empty() {
        fields.push(format!("provider={provider}"));
    }
    if let Some(arbitration) = arbitration.filter(|arbitration| !arbitration.is_empty()) {
        let decision = arbitration.text("decision");
        if !decision.is_empty() {
            fields.push(format!("decision={decision}"));
        }
        let provider_session_id = arbitration.text("provider_session_id");
        if !provider_session_id.is_empty() {
            fields.push(format!("provider_session_id={provider_session_id}"));
        }
        if let Some(siblings) = arbitration.get("siblings").filter(|value| value.as_list().is_some()) {
            fields.push(format!(
                "aggregate_sibling_states={}",
                json::dumps_compact_sorted(siblings)
            ));
        }
    }
    if let Some(reason) = reason.filter(|reason| !reason.is_empty()) {
        fields.push(format!("reason={reason}"));
    }
    eprintln!("[voice_bridge] foreground_reply_fallback {}", fields.join(" "));
}

/// `_schedule_foreground_reply_fallback`: after the delay, speak the
/// missing-reply fallback once every sibling of the source turn ended empty.
pub fn schedule_foreground_reply_fallback(
    bridge: &'static Bridge,
    relay_command: &Dict,
    action_kind: Option<String>,
    paths: ReplyPaths,
    delay_seconds: Option<f64>,
    ceiling_seconds: Option<f64>,
) -> bool {
    if relay_command_key(relay_command).is_none() {
        return false;
    }
    let delay = delay_seconds.unwrap_or(settings().fallback_seconds);
    if delay < 0.0 {
        return false;
    }
    let ceiling = ceiling_seconds.unwrap_or(settings().hard_ceiling_seconds);
    let broker_turns_path = bridge.broker_projection_path.clone();
    log_fallback_event("armed", relay_command, &paths.turns_path, None, None);
    let armed_at = Instant::now();
    let relay_command = relay_command.clone();
    let cancel = move |relay_command: &Dict, paths: &ReplyPaths, reason: &str, arbitration: Option<&Dict>| {
        log_fallback_event("cancelled", relay_command, &paths.turns_path, Some(reason), arbitration);
        replies::close_outcome_watch(Some(relay_command), bridge.speech(), &format!("fallback_{reason}"));
    };
    let spawned = thread::Builder::new()
        .name("foreground-reply-fallback".to_string())
        .spawn(move || {
            let mut sleep_for = delay;
            loop {
                if sleep_for > 0.0 {
                    thread::sleep(Duration::from_secs_f64(sleep_for));
                }
                if replies::foreground_reply_delivered(Some(&relay_command))
                    || replies::foreground_fallback_delivered(Some(&relay_command))
                {
                    cancel(&relay_command, &paths, "reply_delivered", None);
                    return;
                }
                if !turns::relay_command_current_or_preserved(&relay_command, &paths.state_path, "") {
                    cancel(&relay_command, &paths, "superseded", None);
                    return;
                }
                let arbitration = turns::source_turn_reply_arbitration(
                    &relay_command,
                    &ArbitrationPaths {
                        state_path: &paths.state_path,
                        turns_path: &paths.turns_path,
                        command_path: &paths.command_path,
                        meta_path: &paths.meta_path,
                        broker_turns_path: broker_turns_path.as_deref(),
                    },
                    None,
                );
                let mut decision = arbitration.string("decision");
                let mut reason = match arbitration.string("reason") {
                    reason if reason.is_empty() => "source_not_terminal".to_string(),
                    reason => reason,
                };
                if decision == "defer" && armed_at.elapsed().as_secs_f64() >= ceiling {
                    decision = "eligible".to_string();
                    reason = format!("hard_ceiling:{reason}");
                }
                if decision == "defer" {
                    log_fallback_event("deferred", &relay_command, &paths.turns_path, Some(&reason), Some(&arbitration));
                    sleep_for = settings().completion_active_poll_seconds.max(0.25);
                    continue;
                }
                if decision == "cancel" {
                    cancel(&relay_command, &paths, &reason, Some(&arbitration));
                    return;
                }
                log_fallback_event("eligible", &relay_command, &paths.turns_path, Some(&reason), Some(&arbitration));
                let delivered = deliver_missing_foreground_reply(
                    bridge,
                    &relay_command,
                    action_kind.as_deref(),
                    &paths.state_path,
                );
                let Some(delivered) = delivered else {
                    cancel(&relay_command, &paths, "source_reply_deduplicated", Some(&arbitration));
                    return;
                };
                log_fallback_event(
                    if delivered { "emitted" } else { "delivery_failed" },
                    &relay_command,
                    &paths.turns_path,
                    Some(&reason),
                    None,
                );
                replies::close_outcome_watch(
                    Some(&relay_command),
                    bridge.speech(),
                    if delivered { "fallback_emitted" } else { "fallback_delivery_failed" },
                );
                return;
            }
        });
    spawned.is_ok()
}

fn provider_name(primary: Option<&Value>, secondary: Option<&Value>) -> String {
    let value = primary
        .filter(|value| value.truthy())
        .or(secondary.filter(|value| value.truthy()))
        .map(Value::py_str)
        .unwrap_or_else(|| match env_or("RELAY_RUNNER_PROVIDER", "") {
            provider if !provider.is_empty() => provider,
            _ => "codex".to_string(),
        });
    json::py_strip(&value).to_lowercase()
}

/// `_handle_provider_completion_control`: route the provider Stop hook's
/// completion through the authoritative reply path.
pub fn handle_provider_completion_control(
    bridge: &'static Bridge,
    raw: &str,
    paths: &ReplyPaths,
    fallback_delay_seconds: Option<f64>,
) -> bool {
    let text = json::py_strip(raw);
    if text.is_empty() {
        return false;
    }
    let Some(Value::Dict(data)) = json::parse(text) else {
        return false;
    };
    let command = match data.get("relay_command").and_then(Value::as_dict) {
        Some(command) => command.clone(),
        None => data.clone(),
    };
    let Some((seq, id)) = relay_command_key(&command) else {
        return false;
    };
    let provider = provider_name(data.get("provider"), command.get("provider"));
    let failed = data.string("event") == "StopFailure";
    let terminal_signal = if provider.contains("claude") {
        if failed { "result_error" } else { "result_success" }
    } else if failed {
        "turn_failed"
    } else {
        "turn_completed"
    };
    let mut observation = merged(&[&data, &command]);
    observation.insert("provider", provider.as_str());
    post_continuity_event("provider", terminal_signal, Some(&observation), None, &LocalDaemon);
    replies::note_outcome_signal(Some(&command), "hook_received");
    if replies::foreground_reply_delivered(Some(&command)) {
        replies::close_outcome_watch(Some(&command), bridge.speech(), "reply_delivered");
        return true;
    }
    let origin = targets::reply_origin_target(&data);
    let origin_key = origin.as_ref().map(|target| target.session_key.clone()).unwrap_or_default();
    if !turns::relay_command_current_or_preserved(&command, &paths.state_path, &origin_key) {
        eprintln!("[voice_bridge] Dropping provider completion because its Relay command was superseded.");
        replies::close_outcome_watch(Some(&command), bridge.speech(), "completion_superseded");
        return false;
    }
    let reply = match data.truthy("text").or(data.truthy("last_assistant_message")) {
        Some(value) => json::py_strip(&value.py_str()).to_string(),
        None => String::new(),
    };
    if !reply.is_empty() {
        let mut payload = Dict::new();
        payload.insert("text", reply.as_str());
        payload.insert("relay_command_seq", seq);
        payload.insert("relay_command_id", id.as_str());
        payload.insert("speech_source", "completion");
        for field in [
            "intent_id",
            "app_session_id",
            "recovery_generation",
            "actor_role",
            "foreground_gate_handle",
            "session_key",
            "provider_session_id",
        ] {
            if let Some(value) = data.present(field) {
                payload.insert(field, value.clone());
            }
        }
        if let Some(origin) = &origin {
            payload.insert("session_key", origin.session_key.as_str());
        }
        let delivered =
            handle_orchestrator_reply_control(bridge, &json::dumps(&Value::Dict(payload)), &paths.state_path);
        replies::close_outcome_watch(Some(&command), bridge.speech(), "completion_reply_not_delivered");
        return delivered;
    }
    schedule_foreground_reply_fallback(
        bridge,
        &command,
        Some(data.string("action")),
        paths.clone(),
        fallback_delay_seconds,
        None,
    )
}

/// `_handle_orchestrator_reply_control`: route the foreground agent's
/// authoritative reply through the messenger, else straight to speech.
pub fn handle_orchestrator_reply_control(bridge: &Bridge, raw: &str, state_path: &str) -> bool {
    let text = json::py_strip(raw);
    if text.is_empty() {
        return false;
    }
    let data = match json::parse(text) {
        None => {
            log_quarantined_relay_control("prefixed", "__ORCHESTRATOR_REPLY__", "top_level", "malformed", "invalid_payload");
            return false;
        }
        Some(Value::Dict(data)) => data,
        Some(_) => {
            log_quarantined_relay_control("prefixed", "__ORCHESTRATOR_REPLY__", "top_level", "valid", "invalid_payload");
            return false;
        }
    };
    let reply = data.text("text");
    if reply.is_empty() {
        return false;
    }
    let command = match data.get("relay_command").and_then(Value::as_dict) {
        Some(nested) => nested.clone(),
        None => data.clone(),
    };
    let Some(command_key) = relay_command_key(&command) else {
        log_quarantined_relay_control("prefixed", "__ORCHESTRATOR_REPLY__", "top_level", "valid", "missing_command_key");
        return false;
    };
    if replies::foreground_reply_delivered(Some(&command)) {
        return true;
    }
    let origin = targets::reply_origin_target(&data);
    let origin_key = origin.as_ref().map(|target| target.session_key.clone()).unwrap_or_default();
    if !turns::relay_command_current_or_preserved(&command, state_path, &origin_key) {
        eprintln!("[voice_bridge] Dropping foreground reply because its Relay command was superseded.");
        replies::note_outcome_signal(Some(&command), "reply_helper_rejected");
        return false;
    }
    let effect_id = match reserve(bridge, &command, "authoritative_reply") {
        Reservation::Accepted(effect_id) => effect_id,
        Reservation::Duplicate => return true,
        Reservation::Revoked => {
            replies::finish_foreground_reply_delivery(Some(&command), false, false);
            replies::note_outcome_signal(Some(&command), "reply_helper_rejected");
            return false;
        }
        Reservation::Refused => {
            replies::note_outcome_signal(Some(&command), "reply_helper_rejected");
            return false;
        }
    };
    if !replies::reserve_foreground_reply_delivery(Some(&command)) {
        finish_effect(bridge, &effect_id, false);
        return true;
    }
    let mut payload = Dict::new();
    payload.insert("text", reply.as_str());
    if let Some(source) = data.truthy("speech_source") {
        payload.insert("speech_source", source.py_str());
    }
    let work_disposition = data.get("work_disposition").and_then(Value::as_dict).cloned();
    if let Some(disposition) = &work_disposition {
        payload.insert("work_disposition", disposition.clone());
    }
    for key in ["relay_command_seq", "relay_command_id"] {
        if let Some(value) = command.get(key) {
            payload.insert(key, value.clone());
        }
    }
    if !authorize_effect(bridge, &effect_id) {
        replies::finish_foreground_reply_delivery(Some(&command), false, false);
        replies::note_outcome_signal(Some(&command), "reply_helper_rejected");
        return false;
    }
    let background = targets::is_background_target(origin.as_ref());
    if !background {
        targets::note_spoken_reply(origin.as_ref());
        if let Some(messenger) = bridge.messenger()
            && messenger.submit_final(payload.clone())
        {
            replies::finish_foreground_reply_delivery(Some(&command), true, false);
            finish_effect(bridge, &effect_id, true);
            return true;
        }
    }
    let mut speech_payload = payload.clone();
    speech_payload.insert("display_text", reply.as_str());
    let mut dedup_key = None;
    if background {
        speech_payload.remove("relay_command_seq");
        speech_payload.remove("relay_command_id");
        dedup_key = Some(format!("outcome:{}:{}", command_key.0, command_key.1));
    }
    let speech_source = payload.string("speech_source");
    let delivered = speech::queue_tts_text(
        bridge.speech(),
        &json::dumps(&Value::Dict(speech_payload)),
        TtsOptions {
            state_path: state_path.to_string(),
            allow_pending_command: true,
            preserved_command: Some(command.clone()),
            source: if matches!(speech_source.as_str(), "lifecycle" | "completion") {
                speech_source
            } else {
                "orchestrator".to_string()
            },
            kind: "final".to_string(),
            authoritative: true,
            semantic_brief: Some(reply.clone()),
            dedup_key,
            work_disposition,
            replayable: Some(true),
            session_key: origin.as_ref().map(|target| target.session_key.clone()),
            ..TtsOptions::default()
        },
    );
    replies::finish_foreground_reply_delivery(Some(&command), delivered, false);
    if !delivered {
        replies::note_outcome_signal(Some(&command), "reply_helper_rejected");
    }
    finish_effect(bridge, &effect_id, delivered);
    delivered
}

/// `_log_provider_session_transition`.
pub fn log_provider_session_transition(payload: &Dict, decision: &str) {
    let mut diagnostic = Dict::new();
    let field = |name: &str| payload.get(name).cloned().unwrap_or(Value::Null);
    diagnostic.insert("app_session_id", field("app_session_id"));
    diagnostic.insert("decision", decision);
    diagnostic.insert(
        "drain_result",
        if decision == "accepted_exact_app_owned_replacement" {
            "exact_claim_eligible"
        } else {
            "quarantined"
        },
    );
    diagnostic.insert("evidence_source", "continuity_provider_ready");
    for name in [
        "foreground_gate_handle",
        "intent_id",
        "previous_provider_session_id",
        "provider",
        "provider_session_id",
        "recovery_generation",
        "relay_command_id",
        "relay_command_seq",
    ] {
        diagnostic.insert(name, field(name));
    }
    eprintln!(
        "[voice_bridge] provider_session_transition {}",
        json::dumps_compact_sorted(&Value::Dict(diagnostic))
    );
}

/// `_handle_provider_turn_event_control`.
pub fn handle_provider_turn_event_control(
    bridge: &Bridge,
    raw: &str,
    ownership: Option<&ProviderSessionOwnership>,
    claimed_path: &str,
    state_path: &str,
) -> bool {
    let Some(Value::Dict(payload)) = json::parse(json::py_strip(raw)) else {
        return false;
    };
    let event = payload.string("event");
    let provider = provider_name(payload.get("provider"), None);
    let legacy = settings().broker_mode == "legacy";
    match event.as_str() {
        "provider_ready" | "provider_started" | "provider_progress" => {
            let signal = if event == "provider_ready" {
                if let Some(ownership) = ownership {
                    let decision =
                        ownership.authorize_transition(&payload, &read_json_file(claimed_path), state_path);
                    log_provider_session_transition(&payload, decision);
                    if decision != "accepted_exact_app_owned_replacement" {
                        return false;
                    }
                    if matches!(payload.get("discard_unacknowledged_claim"), Some(Value::Bool(true))) {
                        let retired = bridge.inbox().map(|inbox| inbox.retire_replaced_claim(&payload));
                        if let Some(Err(error)) = &retired {
                            eprintln!("[voice_bridge] Could not retire the replaced claim: {error}");
                        }
                        if retired.is_some() {
                            bridge.sync_inbox_state(state_path);
                        }
                    }
                }
                "process_ready"
            } else if event == "provider_progress" {
                if provider.contains("claude") { "stream_progress" } else { "turn_progress" }
            } else if provider.contains("claude") {
                "stream_started"
            } else {
                "turn_started"
            };
            let mut observation = payload.clone();
            observation.insert("provider", provider.as_str());
            post_continuity_event(
                "provider",
                signal,
                Some(&observation),
                payload.get("observed_at").and_then(Value::py_float),
                &LocalDaemon,
            );
            true
        }
        "provider_turn_cancelled" => {
            let Some(broker) = bridge.broker() else {
                return legacy;
            };
            let event_id = payload.text("event_id");
            let release_reason = payload.string("release_reason");
            if event_id.is_empty() || release_reason != "provider_interrupted" {
                return false;
            }
            broker
                .transition(
                    &payload,
                    TurnState::Cancelled,
                    "provider_interrupted",
                    &release_reason,
                    None,
                    Some(&event_id),
                )
                .unwrap_or(false)
        }
        "provider_terminated" => {
            let Some(broker) = bridge.broker() else {
                return legacy;
            };
            let release_reason = payload.string("release_reason");
            if !matches!(
                release_reason.as_str(),
                "app_teardown" | "provider_process_terminated" | "provider_process_exit"
            ) {
                return false;
            }
            let event_id = payload.text("event_id");
            let provider_session_id = payload.text("provider_session_id");
            if let Err(error) =
                broker.terminate_owner(&payload, &provider_session_id, &release_reason, &event_id, None)
            {
                eprintln!("[voice_bridge] Could not end the provider's turns: {error}");
            }
            drop(broker);
            let mut observation = Dict::new();
            observation.insert("app_session_id", payload.get("app_session_id").cloned().unwrap_or(Value::Null));
            observation.insert(
                "recovery_generation",
                payload.get("recovery_generation").cloned().unwrap_or(Value::Null),
            );
            observation.insert("provider", provider.as_str());
            post_continuity_event("provider", "process_exit", Some(&observation), None, &LocalDaemon);
            true
        }
        _ => false,
    }
}

/// `_handle_sidecar_lifecycle`: feed sidecar state back through the
/// foreground speech and freshness boundary.
pub fn handle_sidecar_lifecycle(bridge: &Bridge, phase: &str, public_summary: &str, command: &Dict) -> bool {
    if let Some(inbox) = bridge.inbox() {
        if let Err(error) = inbox.observe_claim(command, matches!(phase, "completed" | "failed"), None) {
            eprintln!("[voice_bridge] Could not record the sidecar state: {error}");
        }
        drop(inbox);
        bridge.sync_inbox_state(&settings().command_state_file);
    }
    let Some(messenger) = bridge.messenger() else {
        return false;
    };
    let mut trace = Dict::new();
    trace.insert("kind", format!("sidecar-{phase}"));
    trace.insert("message", format!("Sidecar state={phase}; {public_summary}"));
    trace.insert("command", command.clone());
    trace.insert("work_disposition", command.get("work_disposition").cloned().unwrap_or(Value::Null));
    messenger.submit_trace(trace)
}

/// `_handle_sidecar_final`: an accepted sidecar outcome as durable work
/// lifecycle speech.
pub fn handle_sidecar_final(bridge: &Bridge, text: &str, command: &Dict) -> bool {
    let reply = json::py_strip(text);
    let key = relay_command_key(command);
    let (false, Some((seq, id))) = (reply.is_empty(), key) else {
        return false;
    };
    if replies::foreground_reply_delivered(Some(command)) {
        return true;
    }
    let disposition = command.get("work_disposition").and_then(Value::as_dict).cloned();
    let mut delivered = false;
    if let Some(messenger) = bridge.messenger() {
        let mut trace = Dict::new();
        trace.insert("kind", "sidecar-outcome");
        trace.insert("message", reply);
        trace.insert("command", command.clone());
        trace.insert("work_disposition", disposition.clone());
        trace.insert("work_valid", true);
        delivered = messenger.submit_trace(trace);
    }
    if !delivered {
        delivered = speech::queue_tts_text(
            bridge.speech(),
            &tagged_payload(reply, Some(reply), seq, &id),
            TtsOptions {
                allow_pending_command: true,
                source: "lifecycle".to_string(),
                kind: "final".to_string(),
                authoritative: true,
                semantic_brief: Some(reply.to_string()),
                dedup_key: Some(format!("work-outcome:{seq}:{id}:sidecar-outcome")),
                work_disposition: disposition,
                replayable: Some(true),
                freshness_scope: "work".to_string(),
                ..TtsOptions::default()
            },
        );
    }
    if delivered {
        replies::mark_foreground_reply_delivered(Some(command));
    }
    delivered
}
