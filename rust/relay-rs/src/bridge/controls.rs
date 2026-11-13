//! Relay control tokens on the voice FIFO, quarantine of control-shaped
//! input, and per-session playback (`voice_bridge.py`
//! `_handle_relay_control_message` and its helpers, `_cancel_speech`,
//! `_handle_session_playback`, `_publish_session_playback`).

use std::sync::LazyLock;

use relay_intents::arbitration::{self, DispositionRequest};
use relay_intents::pattern::{self, Regex};

use super::commands::{self, PublishPaths};
use super::context::Bridge;
use super::finals::{self, ReplyPaths};
use super::orchestrator::{LocalDaemon, observe_stt_continuity_signal, observe_stt_status};
use super::settings::settings;
use super::store;
use super::targets;
use super::traces;
use crate::json::{self, Dict, Value};
use crate::support::now;

static RELAY_CONTROL_TYPE_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile_full(r"__[A-Z][A-Z0-9_]*__", false));
static RAW_RELAY_CONTROL_TYPE_RE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r#""type"\s*:\s*"(?P<type>__[A-Z][A-Z0-9_]*__)""#, false));
static RESERVED_CONTROL_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"^(?P<type>__[A-Z][A-Z0-9_]*__)(?P<separator>:|\s+|$)",
        false,
    )
});

/// `_RELAY_CONTROL_TYPE_LABELS`.
fn control_type_label(control_type: &str) -> &'static str {
    match control_type {
        "__TTS_STOP__" => "tts_stop",
        "__INTERRUPT__" => "interrupt",
        "__CANCEL__" => "cancel",
        "__PLAY__" => "play",
        "__REPLAY__" => "replay",
        "__TRACE__" => "trace",
        "__ORCHESTRATOR_REPLY__" => "orchestrator_reply",
        "__RELAY_COMPLETION__" => "relay_completion",
        "__PROVIDER_TURN_EVENT__" => "provider_turn_event",
        "__STATUS__" => "status",
        _ => "unknown",
    }
}

/// `_log_quarantined_relay_control`: only fixed, bounded metadata.
pub fn log_quarantined_relay_control(
    envelope: &str,
    control_type: &str,
    shape: &str,
    syntax: &str,
    reason: &str,
) {
    eprintln!(
        "[voice_bridge] quarantined_relay_control envelope={envelope} control_type={} shape={shape} syntax={syntax} reason={reason}",
        control_type_label(control_type)
    );
}

/// `_find_control_shaped_type`: a bounded top-level or nested
/// `type: __CONTROL__` marker.
fn find_control_shaped_type(value: &Value) -> Option<(String, &'static str)> {
    let mut pending: Vec<(&Value, usize)> = vec![(value, 0)];
    let mut visited = 0;
    while let Some((current, depth)) = pending.pop() {
        if visited >= 64 {
            break;
        }
        visited += 1;
        let Some(current) = current.as_dict() else {
            continue;
        };
        if let Some(Value::Str(raw_type)) = current.get("type")
            && pattern::search(&RELAY_CONTROL_TYPE_RE, raw_type)
        {
            return Some((
                raw_type.clone(),
                if depth == 0 { "top_level" } else { "nested" },
            ));
        }
        if depth >= 4 {
            continue;
        }
        for (_, child) in current.iter() {
            match child {
                Value::Dict(_) => pending.push((child, depth + 1)),
                Value::List(items) => pending.extend(
                    items
                        .iter()
                        .take(16)
                        .filter(|item| item.as_dict().is_some())
                        .map(|item| (item, depth + 1)),
                ),
                _ => {}
            }
        }
    }
    None
}

fn raw_control_type(source: &str) -> Option<String> {
    RAW_RELAY_CONTROL_TYPE_RE
        .captures(source)
        .ok()
        .flatten()
        .and_then(|captures| {
            captures
                .name("type")
                .map(|found| found.as_str().to_string())
        })
}

/// `_quarantine_raw_relay_control_object`: reject noncanonical JSON control
/// shapes before they become user intent.
pub fn quarantine_raw_relay_control_object(text: &str) -> bool {
    let source = json::py_strip(text);
    if !source.starts_with('{') {
        return false;
    }
    let (control_type, shape, syntax) = match json::parse(source) {
        None => {
            let Some(control_type) = raw_control_type(source) else {
                return false;
            };
            (control_type, "unverified", "malformed")
        }
        Some(decoded @ Value::Dict(_)) => match find_control_shaped_type(&decoded) {
            Some((control_type, shape)) => (control_type, shape, "valid"),
            None => {
                let Some(control_type) = raw_control_type(source) else {
                    return false;
                };
                (control_type, "nested", "valid")
            }
        },
        Some(_) => return false,
    };
    log_quarantined_relay_control(
        "raw_json",
        &control_type,
        shape,
        syntax,
        "noncanonical_envelope",
    );
    true
}

/// Python's `float(text)` for a FIFO timestamp.
fn parse_float(text: &str) -> Option<f64> {
    let text = json::py_strip(text);
    let lowered = text.to_ascii_lowercase();
    if lowered.contains("inf") || lowered.contains("nan") {
        return text.parse::<f64>().ok();
    }
    text.replace('_', "")
        .parse::<f64>()
        .ok()
        .filter(|_| !text.starts_with('_') && !text.ends_with('_'))
}

/// `_play_control_detected_at`.
pub fn play_control_detected_at(text: &str) -> Option<f64> {
    let value = parse_float(text.strip_prefix("__PLAY__:")?)?;
    (value > 0.0).then_some(value)
}

/// `_play_ack_timestamps`.
pub fn play_ack_timestamps(text: &str) -> Option<(f64, f64)> {
    let (detected, acknowledged) = text.strip_prefix("__PLAY_ACK__:")?.split_once(':')?;
    let detected = parse_float(detected)?;
    let acknowledged = parse_float(acknowledged)?;
    (detected > 0.0 && acknowledged > 0.0).then_some((detected, acknowledged))
}

/// `_play_or_replay`.
pub fn play_or_replay(bridge: &Bridge, option_detected_at: Option<f64>) -> bool {
    bridge.speech().note_play_control(option_detected_at, now());
    bridge.speech().play_or_replay()
}

/// `_cancel_speech`: dismiss the current reply; the next queued one comes
/// forward.
pub fn cancel_speech(bridge: &Bridge) {
    let playing = bridge.speech().playing();
    bridge.speech().skip("user_stop");
    if !playing {
        // Nothing was playing, so no stop event will report the dismissal.
        targets::on_reply_finished();
    }
}

/// `_handle_session_playback`.
pub fn handle_session_playback(bridge: &Bridge, payload: &Dict) -> bool {
    let Some(target) = targets::voice_target_for_value(payload.get("session_key")) else {
        return false;
    };
    let Some(action) = payload
        .get("action")
        .and_then(Value::as_str)
        .filter(|action| matches!(*action, "play" | "replay" | "stop"))
    else {
        return false;
    };
    let waiting_key = targets::waiting_session_key();
    let speech = bridge.speech();
    if speech.control_session(
        &target.session_key,
        if action == "stop" { "stop" } else { "play" },
        &waiting_key,
    ) {
        return true;
    }
    if action == "stop" {
        return false;
    }
    speech.control_session(&target.session_key, "replay", &waiting_key)
}

/// `_handle_session_replay`: a session's latest reply on explicit request.
pub fn handle_session_replay(bridge: &Bridge, payload: &Dict) -> bool {
    let mut payload = payload.clone();
    payload.insert("action", "replay");
    handle_session_playback(bridge, &payload)
}

/// `_publish_session_playback`: the overlay's per-session playback states
/// and, when it changed, the speech queue depth (RR-464).
pub fn publish_session_playback(bridge: &Bridge) {
    let states = bridge
        .speech()
        .session_playback_states(&targets::waiting_session_key());
    store::notify_text("session_playback", &json::dumps(&Value::Dict(states)));
    let depth = bridge.speech().queue_depth();
    let changed = {
        let mut targets = targets::lock();
        let changed = targets.published_queue_depth != Some(depth);
        targets.published_queue_depth = Some(depth);
        changed
    };
    if changed {
        store::notify_text("speech_queue", &depth.to_string());
    }
}

/// `_handle_relay_control_message`: provider-neutral relay controls before
/// command publication. `true` when `text` was a control.
pub fn handle_relay_control_message(
    bridge: &'static Bridge,
    text: &str,
    paths: &PublishPaths,
) -> bool {
    let state_path = paths.state_path.as_str();
    if let Some(raw) = text.strip_prefix("__SKIP_UNCERTAIN__:") {
        if let Some(expected @ Value::Dict(_)) = json::parse(raw)
            && let Some(inbox) = bridge.inbox()
        {
            if let Err(error) = inbox.skip_recovery_blocker(&expected) {
                eprintln!("[voice_bridge] Could not skip the uncertain message: {error}");
            }
            drop(inbox);
            bridge.sync_inbox_state(state_path);
        }
        return true;
    }
    match text {
        "__TTS_STOP__" => {
            bridge.speech().stop_playback("recording_barge_in");
            return true;
        }
        "__INTERRUPT__" => {
            bridge.speech().stop_playback("interrupt");
            if let Some(messenger) = bridge.messenger() {
                messenger.interrupt();
            }
            let relay_command = commands::begin_relay_command(text, state_path, None, None);
            let active = commands::active_work(&settings().provider_turns_file, None);
            let intent_id = relay_command.string("relay_command_id");
            let disposition = arbitration::resolve_intent_disposition(&DispositionRequest {
                intent_id: &intent_id,
                action_kind: "control",
                action_reason: Some("interrupt"),
                source_text: text,
                active_work: &active,
                requested_resources: &[],
                cancellation_scope: None,
                target_work_ids: &[],
            });
            let mut metadata = relay_command.clone();
            metadata.insert("action", "control");
            metadata.insert("outcome", "control action interrupt");
            metadata.insert("reason", "interrupt");
            metadata.insert("authorization_relationship", "interrupt");
            metadata.insert("intent_id", disposition.intent_id.as_str());
            metadata.insert("work_disposition", disposition.to_dict());
            metadata.insert("preempt_provider", true);
            let inbox = bridge.inbox();
            commands::publish_command("__INTERRUPT__", &metadata, paths, inbox.as_deref());
            return true;
        }
        "__CANCEL__" => {
            // Double-tap Control also dismisses acknowledgement and speech;
            // it must not advance newest-intent metadata for either provider.
            cancel_speech(bridge);
            return true;
        }
        "__REPLAY__" => {
            bridge.speech().replay();
            return true;
        }
        _ => {}
    }
    if text == "__PLAY__" || text.starts_with("__PLAY__:") {
        play_or_replay(bridge, play_control_detected_at(text));
        return true;
    }
    if text.starts_with("__PLAY_ACK__:") {
        if let Some((detected, acknowledged)) = play_ack_timestamps(text) {
            bridge
                .speech()
                .note_visual_acknowledgement(detected, acknowledged);
        }
        return true;
    }
    if let Some(raw) = text.strip_prefix("__TRACE__:") {
        traces::handle_orchestration_trace_control(bridge, raw, state_path);
        return true;
    }
    if let Some(raw) = text.strip_prefix("__ORCHESTRATOR_REPLY__:") {
        finals::handle_orchestrator_reply_control(bridge, raw, state_path);
        return true;
    }
    if let Some(raw) = text.strip_prefix("__RELAY_COMPLETION__:") {
        let reply_paths = ReplyPaths {
            state_path: state_path.to_string(),
            ..ReplyPaths::default()
        };
        finals::handle_provider_completion_control(bridge, raw, &reply_paths, None);
        return true;
    }
    if let Some(raw) = text.strip_prefix("__PROVIDER_TURN_EVENT__:") {
        finals::handle_provider_turn_event_control(
            bridge,
            raw,
            None,
            &settings().claim_file,
            state_path,
        );
        return true;
    }
    if let Some(raw) = text.strip_prefix("__STATUS__:") {
        observe_stt_status(raw, &LocalDaemon);
        return true;
    }
    if let Some(raw) = text.strip_prefix("__CONTINUITY__:") {
        observe_stt_continuity_signal(raw, &LocalDaemon);
        return true;
    }
    if quarantine_raw_relay_control_object(text) {
        return true;
    }
    if let Ok(Some(captures)) = RESERVED_CONTROL_RE.captures(text) {
        let control_type = captures
            .name("type")
            .map(|found| found.as_str())
            .unwrap_or("");
        let separator = captures
            .name("separator")
            .map(|found| found.as_str())
            .unwrap_or("");
        let unknown = separator == ":";
        log_quarantined_relay_control(
            "prefixed",
            control_type,
            "top_level",
            if unknown { "unknown" } else { "malformed" },
            if unknown {
                "unknown_control_type"
            } else {
                "noncanonical_separator"
            },
        );
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn play_timestamps_parse_as_python_floats() {
        assert_eq!(play_control_detected_at("__PLAY__"), None);
        assert_eq!(play_control_detected_at("__PLAY__:12.5"), Some(12.5));
        assert_eq!(play_control_detected_at("__PLAY__:0"), None);
        assert_eq!(play_control_detected_at("__PLAY__:x"), None);
        assert_eq!(play_ack_timestamps("__PLAY_ACK__:1.5:2"), Some((1.5, 2.0)));
        assert_eq!(play_ack_timestamps("__PLAY_ACK__:1.5"), None);
        assert_eq!(play_ack_timestamps("__PLAY_ACK__:-1:2"), None);
    }

    #[test]
    fn control_shaped_json_is_quarantined() {
        assert!(quarantine_raw_relay_control_object(
            r#"{"type": "__INTERRUPT__"}"#
        ));
        assert!(quarantine_raw_relay_control_object(
            r#"{"a": {"type": "__PLAY__"}}"#
        ));
        assert!(quarantine_raw_relay_control_object(
            r#"{"type": "__PLAY__", "#
        ));
        assert!(!quarantine_raw_relay_control_object(r#"{"type": "note"}"#));
        assert!(!quarantine_raw_relay_control_object("hello {"));
    }
}
