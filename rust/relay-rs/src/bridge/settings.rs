//! The bridge's paths and timings, read once from the environment as
//! `voice_bridge.py` reads them at import. Each field names the module
//! constant it replaces.

use std::path::Path;
use std::sync::OnceLock;

use crate::json::py_strip;
use crate::support::{env_optional, env_or, env_text};

pub struct Settings {
    pub voice_fifo: String,
    pub control_sock: String,
    /// `RELAY_REMOTE_SOCK`, read by `relay_remote.py`.
    pub remote_sock: String,
    pub voice_state_sock: String,
    pub orchestrator_port_file: String,
    pub orchestrator_default_port: u16,
    pub heartbeat_seconds: f64,
    pub pm_update_poll_seconds: f64,
    pub pm_update_cadence_seconds: f64,
    pub pm_update_startup_grace_seconds: f64,
    pub outcome_poll_seconds: f64,
    pub fallback_seconds: f64,
    pub completion_active_poll_seconds: f64,
    pub hard_ceiling_seconds: f64,
    pub trace_active_seconds: f64,
    /// `RELAY_SESSION_SPOOL_DIR`, stripped; empty for a manual bridge.
    pub spool_dir: String,
    pub cmd_file: String,
    pub cmd_meta_file: String,
    pub command_state_file: String,
    pub claim_file: String,
    pub manual_ack_file: String,
    pub legacy_command_state_file: String,
    /// `_MIRRORED_COMMAND_STATE_FILE`: the spool's state file, mirrored to the
    /// legacy path, when a targeted spool moved it.
    pub mirrored_command_state_file: Option<String>,
    pub authorization_file: String,
    /// `RELAY_SESSION_KEY`: the targeted spool's own key, or empty.
    pub relay_session_key: String,
    pub provider_turns_file: String,
    pub provider_turn_projection_file: String,
    pub broker_mode: String,
    pub provider_session_id: String,
    pub command_event_log: String,
    pub intent_inbox: String,
    pub speech_event_log: String,
    pub speech_service_sock: String,
    pub tts_control_sock: String,
    pub tts_in_fifo: String,
    pub sessions_root: String,
    pub bridge_cwd_file: String,
    pub bridge_provider_file: String,
    pub bridge_spool_file: String,
    pub bridge_pid_file: String,
    pub watchdog_restart_file: String,
    pub stop_requested_file: String,
    pub voice_acknowledgement: String,
}

static SETTINGS: OnceLock<Settings> = OnceLock::new();

/// The settings of this process, read on first use.
pub fn settings() -> &'static Settings {
    SETTINGS.get_or_init(Settings::from_environment)
}

fn join(folder: &str, name: &str) -> String {
    Path::new(folder).join(name).to_string_lossy().into_owned()
}

/// `float(os.environ.get(name, default))`; an unreadable value keeps the
/// default, where Python would have failed at import.
fn env_float(name: &str, default: f64) -> f64 {
    env_optional(name)
        .and_then(|value| py_strip(&value).parse::<f64>().ok())
        .unwrap_or(default)
}

/// `os.path.dirname`.
pub fn dirname(path: &str) -> String {
    match path.rfind('/') {
        None => String::new(),
        Some(index) => {
            let head = &path[..=index];
            let trimmed = head.trim_end_matches('/');
            if trimmed.is_empty() {
                head.to_string()
            } else {
                trimmed.to_string()
            }
        }
    }
}

/// `os.path.basename`.
pub fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// `os.path.normpath` for a POSIX path.
pub fn normpath(path: &str) -> String {
    if path.is_empty() {
        return ".".to_string();
    }
    let initial = if path.starts_with("//") && !path.starts_with("///") {
        2
    } else {
        usize::from(path.starts_with('/'))
    };
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if initial == 0 && (parts.is_empty() || parts.last() == Some(&"..")) {
                    parts.push("..");
                } else if !parts.is_empty() {
                    parts.pop();
                }
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    let result = format!("{}{joined}", "/".repeat(initial));
    if result.is_empty() {
        ".".to_string()
    } else {
        result
    }
}

impl Settings {
    fn from_environment() -> Self {
        let runtime_dir = {
            let configured = env_text("RELAY_BRIDGE_RUNTIME_DIR");
            if configured.is_empty() {
                "/tmp".to_string()
            } else {
                configured
            }
        };
        let spool_dir = env_text("RELAY_SESSION_SPOOL_DIR");
        // `_session_spool_path`: an explicit override wins, then the spool,
        // then the runtime folder.
        let spool_path = |name: &str, override_env: &str| -> String {
            let explicit = env_text(override_env);
            if !explicit.is_empty() {
                return explicit;
            }
            join(
                if spool_dir.is_empty() {
                    &runtime_dir
                } else {
                    &spool_dir
                },
                name,
            )
        };
        let cmd_file = spool_path("voice_cmd_ready", "VOICE_CMD_FILE");
        let command_state_file = spool_path("voice_command_state.json", "VOICE_COMMAND_STATE_FILE");
        let legacy_command_state_file = join(&runtime_dir, "voice_command_state.json");
        let mirrored_command_state_file = (!spool_dir.is_empty()
            && command_state_file != legacy_command_state_file)
            .then(|| command_state_file.clone());
        let targeted_spool = spool_dir.trim_end_matches('/').to_string();
        let sessions_root = join(&runtime_dir, "relay-sessions");
        let relay_session_key = if dirname(&targeted_spool) == sessions_root {
            basename(&targeted_spool).to_string()
        } else {
            String::new()
        };
        let voice_state_sock = match env_optional("VOICE_STATE_SOCK") {
            Some(value) if !value.is_empty() => value,
            _ => join(&runtime_dir, "voice_state.sock"),
        };
        let speech_service_sock = {
            let configured = env_text("RELAY_SPEECH_SERVICE_SOCK");
            if configured.is_empty() {
                "/tmp/relay_speech_service.sock".to_string()
            } else {
                configured
            }
        };
        let home = env_or("HOME", "");
        Self {
            voice_fifo: env_or("VOICE_FIFO", "/tmp/voice_in.fifo"),
            control_sock: env_or("BRIDGE_CONTROL_SOCK", "/tmp/voice_bridge.sock"),
            remote_sock: env_or("RELAY_REMOTE_SOCK", "/tmp/relay_remote.sock"),
            voice_state_sock,
            orchestrator_port_file: env_or(
                "ORCHESTRATOR_PORT_FILE",
                "/tmp/relay_orchestrator.port",
            ),
            orchestrator_default_port: env_optional("ORCHESTRATOR_DEFAULT_PORT")
                .and_then(|value| py_strip(&value).parse().ok())
                .unwrap_or(7634),
            heartbeat_seconds: env_float("ORCHESTRATOR_HEARTBEAT_SECONDS", 10.0),
            pm_update_poll_seconds: env_float("PM_UPDATE_POLL_SECONDS", 2.0),
            pm_update_cadence_seconds: env_float("PM_UPDATE_CADENCE_SECONDS", 8.0),
            pm_update_startup_grace_seconds: env_float("PM_UPDATE_STARTUP_GRACE_SECONDS", 6.0),
            outcome_poll_seconds: env_float("MESSENGER_OUTCOME_POLL_SECONDS", 2.0),
            fallback_seconds: env_float("FOREGROUND_REPLY_FALLBACK_SECONDS", 120.0),
            completion_active_poll_seconds: env_float(
                "PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS",
                5.0,
            ),
            hard_ceiling_seconds: env_float("FOREGROUND_REPLY_HARD_CEILING_SECONDS", 900.0),
            trace_active_seconds: env_float("FOREGROUND_REPLY_TRACE_ACTIVE_SECONDS", 60.0),
            cmd_meta_file: format!("{cmd_file}.meta"),
            cmd_file,
            claim_file: spool_path("voice_cmd_claimed.json", "VOICE_COMMAND_CLAIM_FILE"),
            manual_ack_file: spool_path("voice_cmd_manual_ack.json", "VOICE_MANUAL_CLAIM_ACK_FILE"),
            command_state_file,
            legacy_command_state_file,
            mirrored_command_state_file,
            authorization_file: env_or(
                "VOICE_COMMAND_AUTHORIZATION_FILE",
                "/tmp/voice_command_authorizations.json",
            ),
            relay_session_key,
            provider_turns_file: env_or(
                "VOICE_PROVIDER_TURNS_FILE",
                "/tmp/voice_provider_turns.json",
            ),
            provider_turn_projection_file: env_or(
                "VOICE_PROVIDER_TURN_PROJECTION_FILE",
                "/tmp/voice_provider_turns_v2.json",
            ),
            broker_mode: py_strip(&env_or("RELAY_PROVIDER_TURN_BROKER_MODE", "dual_write"))
                .to_string(),
            provider_session_id: env_text("RELAY_PROVIDER_SESSION_ID"),
            command_event_log: env_or(
                "VOICE_COMMAND_EVENT_LOG",
                &format!(
                    "{home}/Library/Application Support/relay-runner/command-actions/events.jsonl"
                ),
            ),
            intent_inbox: env_or("VOICE_INTENT_INBOX", "/tmp/relay_intent_inbox.sqlite3"),
            speech_event_log: env_or("SPEECH_EVENT_LOG", "/tmp/relay_speech_events.jsonl"),
            speech_service_sock,
            tts_control_sock: env_or("TTS_CONTROL_SOCK", "/tmp/tts_control.sock"),
            tts_in_fifo: join(&runtime_dir, "tts_in.fifo"),
            bridge_cwd_file: join(&runtime_dir, "voice_bridge.cwd"),
            bridge_provider_file: join(&runtime_dir, "voice_bridge.provider"),
            bridge_spool_file: join(&runtime_dir, "voice_bridge.spool"),
            bridge_pid_file: join(&runtime_dir, "voice_bridge.pid"),
            watchdog_restart_file: join(&runtime_dir, "voice_bridge_watchdog_restart"),
            stop_requested_file: join(&runtime_dir, "voice_bridge_stop_requested"),
            voice_acknowledgement: env_or("VOICE_ACKNOWLEDGEMENT", "Got it. I'm on it."),
            sessions_root,
            spool_dir,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirname_and_basename_follow_os_path() {
        assert_eq!(dirname("/tmp/relay-sessions/abc"), "/tmp/relay-sessions");
        assert_eq!(dirname("/abc"), "/");
        assert_eq!(dirname("abc"), "");
        assert_eq!(basename("/tmp/relay-sessions/abc"), "abc");
        assert_eq!(basename("abc"), "abc");
        assert_eq!(dirname("/tmp/a/"), "/tmp/a");
        assert_eq!(normpath("/tmp//a/./b/../c/"), "/tmp/a/c");
        assert_eq!(normpath("/"), "/");
        assert_eq!(normpath("a/../.."), "..");
    }
}
