//! What the bridge needs from the speech service client, the messenger
//! runtime and the sidecar lane. The bridge holds them behind these traits so
//! its own logic does not depend on how each is built; `wiring.rs` connects
//! the real ones.

use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::json::Dict;

/// The keyword arguments of `_InputQueue.submit_text` (`speech_client.py`):
/// one typed speech intent offered to the speech service.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpeechText {
    pub text: String,
    pub display_text: String,
    pub semantic_brief: Option<String>,
    pub command_seq: Option<i64>,
    pub command_id: Option<String>,
    pub source: String,
    pub kind: String,
    pub authoritative: bool,
    pub priority: Option<i64>,
    pub dedup_key: Option<String>,
    pub work_disposition: Option<Dict>,
    pub replayable: Option<bool>,
    pub freshness_scope: String,
    pub lifecycle_role: Option<String>,
    pub covered_facts: Option<Vec<String>>,
    pub realization_decision: String,
    pub suppression_reason: Option<String>,
    pub session_key: String,
    pub waiting_playback_kind: Option<String>,
}

/// The speech service, as the bridge drives it in service mode
/// (`SpeechServiceClient`).
pub trait Speech: Send + Sync {
    fn submit_text(&self, request: SpeechText) -> bool;
    fn stop_playback(&self, reason: &str);
    fn skip(&self, reason: &str);
    /// `getattr(tts_worker, "playing", None)`.
    fn playing(&self) -> bool;
    fn play_or_replay(&self) -> bool;
    fn note_play_control(&self, option_detected_at: Option<f64>, fifo_received_at: f64);
    fn note_visual_acknowledgement(&self, option_detected_at: f64, acknowledged_at: f64);
    fn replay(&self) -> bool;
    fn new_turn(&self, command_seq: i64, command_id: &str);
    fn reload_config(&self);
    fn control_session(&self, session_key: &str, action: &str, waiting_session_key: &str) -> bool;
    /// `session_playback_states(...)`: session key to playback state.
    fn session_playback_states(&self, waiting_session_key: &str) -> Dict;
    fn queue_depth(&self) -> i64;
    fn record_messenger_stage(
        &self,
        stage: &str,
        command_seq: i64,
        command_id: &str,
        at: Option<f64>,
        provider: Option<&str>,
        outcome: &str,
    );
    fn record_missing_outcome(
        &self,
        command_seq: i64,
        command_id: &str,
        reason: &str,
        signals: &[String],
    ) -> bool;
    fn shutdown(&self);
}

/// `MessengerRuntime`, as the bridge calls it.
pub trait Messenger: Send + Sync {
    fn start(&self);
    fn submit_user(&self, text: &str, command: &Dict) -> bool;
    fn update_user_context(&self, command: &Dict) -> bool;
    fn submit_trace(&self, trace: Dict) -> bool;
    fn submit_final(&self, payload: Dict) -> bool;
    fn focus(&self, partition_key: &str) -> bool;
    fn interrupt(&self);
    fn recover_backend(&self) -> bool;
    fn shutdown(&self);
}

/// `SidecarLane`, as the bridge calls it.
pub trait Sidecar: Send + Sync {
    fn submit(&self, prompt: &str, command: &Dict) -> bool;
    fn shutdown(&self);
}

/// `threading.Event`.
#[derive(Default)]
pub struct Event {
    set: Mutex<bool>,
    changed: Condvar,
}

impl Event {
    pub fn set(&self) {
        *self.set.lock().unwrap() = true;
        self.changed.notify_all();
    }

    pub fn is_set(&self) -> bool {
        *self.set.lock().unwrap()
    }

    /// `event.wait(timeout)`: whether the event is set when it returns.
    pub fn wait(&self, timeout: f64) -> bool {
        let deadline = Instant::now() + Duration::from_secs_f64(timeout.max(0.0));
        let mut set = self.set.lock().unwrap();
        while !*set {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            set = self.changed.wait_timeout(set, deadline - now).unwrap().0;
        }
        true
    }
}
