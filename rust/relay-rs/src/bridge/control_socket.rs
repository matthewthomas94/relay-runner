//! The bridge's datagram control socket (`voice_bridge.py`
//! `_start_control_socket`): reload, shutdown, ping, session focus and
//! playback, and the continuity agent's recovery requests.

use std::io::ErrorKind;
use std::os::unix::net::UnixDatagram;
use std::sync::LazyLock;
use std::time::Duration;

use relay_intents::pattern::{self, Regex};

use super::context::Bridge;
use super::controls;
use super::finals;
use super::recovery;
use super::settings::settings;
use super::store;
use super::targets;
use crate::json::{self, Dict, Value};

const VOICE_FOCUS_PREFIX: &str = "__FOCUS__:";
const VOICE_REPLAY_PREFIX: &str = "__REPLAY__:";
const VOICE_SESSION_PLAYBACK_PREFIX: &str = "__SESSION_PLAYBACK__:";

static RECOVERY_REPLY_PATH_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile_full(r"/tmp/relay_recovery_recovery_[0-9a-f]{24}\.json", false)
});

fn parse_object(text: &str) -> Option<Dict> {
    match json::parse(text) {
        Some(Value::Dict(payload)) => Some(payload),
        _ => None,
    }
}

/// Binds `BRIDGE_CONTROL_SOCK`, replacing a leftover one.
pub fn bind() -> std::io::Result<UnixDatagram> {
    let path = &settings().control_sock;
    store::remove(path);
    let socket = UnixDatagram::bind(path)?;
    socket.set_read_timeout(Some(Duration::from_millis(500)))?;
    Ok(socket)
}

/// Serves the control socket until shutdown, then removes it.
pub fn serve(bridge: &'static Bridge, socket: UnixDatagram) {
    let mut buffer = [0u8; 4096];
    while !bridge.shutdown.is_set() {
        controls::publish_session_playback(bridge);
        let count = match socket.recv(&mut buffer) {
            Ok(count) => count,
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(error) => {
                eprintln!("[voice_bridge] Control socket failed: {error}");
                break;
            }
        };
        let command = String::from_utf8_lossy(&buffer[..count]);
        handle(bridge, json::py_strip(&command));
    }
    drop(socket);
    store::remove(&settings().control_sock);
}

fn handle(bridge: &'static Bridge, command: &str) {
    if let Some(raw) = command.strip_prefix(VOICE_FOCUS_PREFIX) {
        if let Some(payload) = parse_object(raw) {
            // RR-488: a focus switch leaves speech alone, so a reply playing
            // or queued is still heard.
            targets::apply_voice_focus(
                &payload,
                bridge.start_target_orchestrator.get().cloned(),
                bridge.stop_target_orchestrator.get().cloned(),
            );
            if let Some(messenger) = bridge.messenger() {
                messenger.focus(&targets::focused_key().unwrap_or_default());
            }
        }
        return;
    }
    if let Some(raw) = command.strip_prefix(VOICE_REPLAY_PREFIX) {
        if let Some(payload) = parse_object(raw) {
            controls::handle_session_replay(bridge, &payload);
        }
        return;
    }
    if let Some(raw) = command.strip_prefix(VOICE_SESSION_PLAYBACK_PREFIX) {
        if let Some(payload) = parse_object(raw) {
            controls::handle_session_playback(bridge, &payload);
        }
        return;
    }
    let mut recovery_payload = None;
    if command.starts_with('{')
        && let Some(candidate) = parse_object(command)
    {
        match candidate.get("type").and_then(Value::as_str) {
            Some("continuity_recovery") => recovery_payload = Some(candidate),
            Some("continuity_resume") => {
                recovery::bridge_continuity_resume_response(bridge, &candidate);
                return;
            }
            Some("continuity_provider_ready") => {
                if candidate
                    .get("event")
                    .is_some_and(|event| event.is_str("provider_ready"))
                {
                    finals::handle_provider_turn_event_control(
                        bridge,
                        &json::dumps(&Value::Dict(candidate.clone())),
                        bridge.ownership.as_deref(),
                        &settings().claim_file,
                        &settings().command_state_file,
                    );
                }
                return;
            }
            _ => {}
        }
    }
    if let Some(payload) = recovery_payload {
        let response = recovery::bridge_continuity_recovery_response(bridge, &payload);
        if let Some(Value::Str(reply_path)) = payload.get("reply_path")
            && pattern::search(&RECOVERY_REPLY_PATH_RE, reply_path)
        {
            let temporary = format!("{reply_path}.{}.tmp", std::process::id());
            let written = std::fs::write(&temporary, json::dumps(&Value::Dict(response)))
                .and_then(|()| std::fs::rename(&temporary, reply_path));
            if written.is_err() {
                store::remove(&temporary);
            }
        }
        return;
    }
    match command.to_lowercase().as_str() {
        "reload" => {
            eprintln!("[voice_bridge] Reloading config...");
            bridge.speech().reload_config();
        }
        "shutdown" => {
            eprintln!("[voice_bridge] Shutdown requested.");
            bridge.shutdown.set();
        }
        // A liveness probe: the socket existing means the bridge is alive.
        _ => {}
    }
}
