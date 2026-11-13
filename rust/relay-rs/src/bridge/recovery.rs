//! The continuity agent's requests on the control socket: execute only
//! bridge-owned recovery capabilities, and resume only provably safe work
//! after the stable-health handoff (`voice_bridge.py`
//! `_bridge_continuity_recovery_response` and
//! `_bridge_continuity_resume_response`).

use super::commands::active_work;
use super::context::Bridge;
use super::continuity::{
    PLEASE_REPEAT_TEXT, RECOVERY_ACTION_REQUIRED_TEXT, RecoveryExecutionContext, capability_policy,
    normalize_recovery_generation, opaque_identifier, plan_continuity_resume, recovery_owner_for,
};
use super::orchestrator::{Daemon, LocalDaemon};
use super::settings::settings;
use super::speech::{self, TtsOptions};
use super::store::{self, read_json_file};
use super::turns;
use crate::json::{self, Dict, Value};
use crate::support::now;

/// Python's `time.monotonic()` on macOS: `mach_absolute_time`, the clock the
/// continuity agent's deadlines are written in.
fn monotonic() -> f64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: clock_gettime writes the timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_UPTIME_RAW, &mut time) };
    time.tv_sec as f64 + time.tv_nsec as f64 / 1e9
}

fn outcome(status: &str, outcome_code: &str) -> Dict {
    let mut response = Dict::new();
    response.insert("status", status);
    response.insert("outcome_code", outcome_code);
    response
}

fn failed(outcome_code: &str) -> Dict {
    outcome("failed", outcome_code)
}

/// `_bridge_continuity_recovery_response`.
pub fn bridge_continuity_recovery_response(bridge: &Bridge, payload: &Dict) -> Dict {
    let Ok(context) = RecoveryExecutionContext::from_mapping(payload) else {
        return failed("invalid_recovery_context");
    };
    let request = &context.request;
    let validation = &context.validation;
    let Some(policy) = capability_policy(&request.capability) else {
        return failed("invalid_recovery_context");
    };
    if recovery_owner_for(&request.capability, &request.component) != "bridge" {
        return failed("unsupported_component_action");
    }
    let epoch = now();
    if validation.validation_token != "live_continuity_watch"
        || !validation.exact_target_owned
        || !validation.incident_active
        || !validation.generation_matches
        || !validation.command_phase_matches
        || !policy
            .required_liveness
            .contains(&validation.liveness.as_str())
        || !policy
            .command_phases
            .contains(&validation.command_phase.as_str())
        || validation.idempotency_state != "new"
        || validation.cooldown_remaining != 0.0
        || request.attempt > policy.max_attempts
        || monotonic() >= request.deadline
        || request.incident_observed_at > epoch + 5.0
        || epoch - request.incident_observed_at > 300.0
    {
        return failed("stale_recovery_context");
    }
    let session = bridge.orchestrator();
    let session_key = session
        .as_ref()
        .map(|session| session.session_key.clone())
        .unwrap_or_default();
    if session_key.is_empty()
        || opaque_identifier("session", &session_key).ok().as_deref() != Some(&request.session_id)
    {
        return failed("unrelated_session_target");
    }
    let provider = match session.as_ref().map(|session| session.provider.clone()) {
        Some(provider) if !provider.is_empty() => provider,
        _ => "none".to_string(),
    };
    if request.provider != "none" && request.provider != provider {
        return failed("provider_target_mismatch");
    }
    let state_path = &settings().command_state_file;
    let command_state = read_json_file(state_path);
    let Ok(current_generation) =
        normalize_recovery_generation(command_state.get("recovery_generation"))
    else {
        return failed("stale_recovery_generation");
    };
    if request.recovery_generation != current_generation {
        return failed("stale_recovery_generation");
    }
    if let Some(command_id) = &request.command_id {
        let native = command_state.string("relay_command_id");
        if native.is_empty()
            || opaque_identifier("command", &native).ok().as_deref() != Some(command_id)
        {
            return failed("unrelated_command_target");
        }
    }
    if !active_work(&settings().provider_turns_file, None).is_empty() {
        return failed("live_work_active");
    }

    let mut recovery = bridge
        .recovery
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if recovery.applied_keys.contains(&request.idempotency_key) {
        return outcome("noop", "action_already_applied");
    }
    let cooldown_key = format!(
        "{}:{}:{}",
        request.capability, request.component, request.session_id
    );
    if monotonic()
        < recovery
            .cooldowns
            .get(&cooldown_key)
            .copied()
            .unwrap_or(0.0)
    {
        return failed("component_cooldown_active");
    }
    let mut applied = false;
    let mut outcome_code = "component_action_failed";
    let capability = request.capability.as_str();
    if matches!(capability, "restart_messenger" | "reconnect_ipc")
        && request.component == "messenger"
    {
        applied = bridge
            .messenger()
            .is_some_and(|messenger| messenger.recover_backend());
        outcome_code = "messenger_process_restart_requested";
    } else if matches!(capability, "restore_session_registration" | "reconnect_ipc") {
        if let Some(session) = &session {
            let mut heartbeat = Dict::new();
            heartbeat.insert("session_id", session.session_id);
            heartbeat.insert("repo_path", session.repo_path.as_str());
            heartbeat.insert("provider", provider.as_str());
            heartbeat.insert("state", "idle");
            applied = LocalDaemon
                .post_json("/v1/orchestrator-session/heartbeat", &heartbeat)
                .is_ok_and(|response| {
                    response
                        .get("orchestrator_session")
                        .and_then(Value::as_dict)
                        .is_some()
                });
        }
        outcome_code = "session_registration_restored";
    } else if capability == "release_dead_ownership" && request.component == "session" {
        let alive = session
            .as_ref()
            .is_some_and(|session| session.heartbeat_running());
        if alive {
            return failed("live_work_active");
        }
        if let Some(session) = &session {
            let mut stop = Dict::new();
            stop.insert("session_id", session.session_id);
            stop.insert("reason", "continuity confirmed dead owner");
            applied = LocalDaemon
                .post_json("/v1/orchestrator-session/stop", &stop)
                .is_ok_and(|response| {
                    response
                        .get("orchestrator_session")
                        .and_then(Value::as_dict)
                        .is_some()
                });
        }
        outcome_code = "dead_ownership_released";
    }
    if !applied {
        return failed("component_action_failed");
    }
    recovery
        .applied_keys
        .insert(request.idempotency_key.clone());
    recovery
        .cooldowns
        .insert(cooldown_key, monotonic() + policy.cooldown_seconds);
    outcome("applied", outcome_code)
}

fn review(reason: &str) -> Dict {
    let mut response = Dict::new();
    response.insert("action", "foreground_review");
    response.insert("reason", reason);
    response
}

fn noop(reason: &str) -> Dict {
    let mut response = Dict::new();
    response.insert("action", "noop");
    response.insert("reason", reason);
    response
}

/// `_bridge_continuity_resume_response`.
pub fn bridge_continuity_resume_response(bridge: &Bridge, payload: &Dict) -> Dict {
    let settings = settings();
    let Some(inbox) = bridge.inbox() else {
        return review("intent_inbox_unavailable");
    };
    let Ok(generation) = normalize_recovery_generation(payload.get("recovery_generation")) else {
        return review("invalid_recovery_generation");
    };
    let command_id = payload
        .get("command_id")
        .filter(|value| !matches!(value, Value::Null));
    let state_exists = store::exists(&settings.command_state_file);
    let state = read_json_file(&settings.command_state_file);
    if command_id.is_none() {
        let bridge_generation = Value::from(bridge.recovery_generation.as_str());
        let Ok(current) = normalize_recovery_generation(Some(&bridge_generation)) else {
            return review("invalid_bridge_generation");
        };
        if current != generation {
            return review("stale_recovery_generation");
        }
        if state_exists && state.string("recovery_generation") != generation {
            return review("stale_recovery_generation");
        }
    } else if state.string("recovery_generation") != generation {
        return review("stale_recovery_generation");
    }
    let session = bridge.orchestrator();
    let session_key = session
        .as_ref()
        .map(|session| session.session_key.clone())
        .unwrap_or_default();
    let session_matches = !session_key.is_empty()
        && opaque_identifier("session", &session_key).is_ok_and(|id| {
            payload
                .get("session_id")
                .is_some_and(|value| value.is_str(&id))
        });
    if !session_matches {
        return review("unrelated_session_target");
    }
    let provider = match session.as_ref().map(|session| session.provider.clone()) {
        Some(provider) if !provider.is_empty() => provider,
        _ => "none".to_string(),
    };
    let payload_provider = payload.get("provider");
    if !payload_provider.is_some_and(|value| value.is_str("none") || value.is_str(&provider)) {
        return review("provider_target_mismatch");
    }
    let resume_key = [
        payload.string("incident_id"),
        generation.clone(),
        match payload.truthy("command_id") {
            Some(value) => value.py_str(),
            None => "no-command".to_string(),
        },
    ]
    .join("|");
    if bridge
        .recovery
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .resume_keys
        .contains(&resume_key)
    {
        return noop("handoff_already_applied");
    }
    let records = inbox.records().unwrap_or_default();
    if command_id.is_none() {
        let incident_at = payload
            .get("incident_observed_at")
            .and_then(Value::py_float)
            .unwrap_or(0.0);
        let captured = records.iter().any(|record| {
            record.string("recovery_generation") == generation
                && record
                    .truthy("created_at")
                    .and_then(Value::py_float)
                    .unwrap_or(0.0)
                    >= incident_at
        });
        if captured {
            return noop("captured_command_now_exists");
        }
    }
    let mut incident = Dict::new();
    incident.insert("command_id", command_id.cloned().unwrap_or(Value::Null));
    for name in ["component", "phase", "unavailable_capability"] {
        incident.insert(name, payload.get(name).cloned().unwrap_or(Value::Null));
    }
    incident.insert("recovery_generation", generation.as_str());
    let final_result = payload.string("final_result");
    let Ok(mut decision) = plan_continuity_resume(&incident, &records, &final_result, None) else {
        return review("invalid_resume_incident");
    };
    if decision.phase == "in_flight_or_completed"
        && let Some(intent_id) = decision.intent_id.clone()
        && let Some(record) = records.iter().find(|record| {
            record
                .get("intent_id")
                .is_some_and(|value| value.is_str(&intent_id))
        })
    {
        let metadata = match json::parse(&match record.truthy("metadata_json") {
            Some(value) => value.py_str(),
            None => "{}".to_string(),
        }) {
            Some(Value::Dict(metadata)) => metadata,
            _ => Dict::new(),
        };
        let provider_state = turns::provider_turn_state(
            Some(&metadata),
            &settings.provider_turns_file,
            Some(&turns::authoritative_provider_session_id()),
            None,
        );
        if let Ok(replanned) = plan_continuity_resume(
            &incident,
            &records,
            &final_result,
            provider_state.as_deref(),
        ) {
            decision = replanned;
        }
    }
    match decision.action {
        "ask_repeat" => {
            let queued = speech::queue_tts_text(
                bridge.speech(),
                PLEASE_REPEAT_TEXT,
                TtsOptions {
                    allow_pending_command: true,
                    ..TtsOptions::default()
                },
            );
            if !queued {
                return review("repeat_delivery_unavailable");
            }
            store::notify_text("continuity_repeat", PLEASE_REPEAT_TEXT);
        }
        "resume_exact" if decision.intent_id.is_some() => {
            let intent_id = decision.intent_id.clone().unwrap_or_default();
            if !inbox
                .resume_after_recovery(&intent_id, &generation, None)
                .unwrap_or(false)
            {
                return noop("resume_already_applied");
            }
            store::notify_text(
                "working",
                "Relay Runner recovered the original command and resumed it.",
            );
        }
        "foreground_review" => {
            let message = if final_result != "restored" {
                RECOVERY_ACTION_REQUIRED_TEXT
            } else {
                "Recovery needs foreground review; Relay did not replay the command."
            };
            store::notify_text("working", message);
        }
        "reattach" => {
            store::notify_text(
                "working",
                "Relay Runner reattached to the original command without replaying it.",
            );
        }
        _ => {}
    }
    bridge
        .recovery
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .resume_keys
        .insert(resume_key);
    decision.as_dict()
}
