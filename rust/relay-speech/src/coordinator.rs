//! The single gateway for speech proposal, playback and replay: the twin of
//! `SpeechCoordinator` in `services/speech_coordinator.py`.
//!
//! The queueing, supersede, staleness, replay, focus and Relay Remote rules
//! are the ones docs/specs/speech-service-protocol.md describes. One mutex
//! guards the queue. The worker is only called with that mutex released, and
//! the worker's callbacks take it, so the lock order is always worker first.

use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::Hash;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::intent::{
    self, CommandKey, IntentSpec, SpeechIntent, is_final_kind, is_queued_reply_kind,
    is_real_final_source, is_superseding_kind,
};
use crate::support::{self, Json, JsonLog, duration_ms, elapsed_ms, number, opt_int, opt_text};

/// A safety bound on queued speech; reaching it is diagnosed, never silent.
pub const SPEECH_QUEUE_LIMIT: usize = 50;
pub const REPLAY_HISTORY_LIMIT: usize = 32;
/// Event-log names for where an intent was realized (RR-424).
const LOCAL_SINK: &str = "kokoro";
const REMOTE_SINK: &str = "relay-remote";
const MESSENGER_TIMING_STAGES: [&str; 6] = [
    "user_turn_received",
    "messenger_submitted",
    "messenger_provider_started",
    "messenger_first_semantic_output",
    "messenger_failed",
    "messenger_unavailable",
];

/// Skips that remove the current item without bringing the next one forward.
fn non_advancing(reason: &str) -> bool {
    matches!(reason, "focus_switch" | "wheel_stop" | "recording_barge_in")
}

/// Talking over a reply counts it as heard: it leaves the queue.
fn heard_stop(reason: &str) -> bool {
    reason == "recording_barge_in"
}

/// Focus switches and wheel stops retain replay without advancing the queue.
fn replay_retaining(reason: &str) -> bool {
    matches!(reason, "user_stop" | "focus_switch" | "wheel_stop")
}

/// Coordinator stop reasons with a protocol-facing name on the remote wire.
fn remote_reason(reason: &str) -> &str {
    if reason == "newer_command" {
        "superseded"
    } else {
        reason
    }
}

/// One item the worker receives: a coordinated intent, a tutorial line of
/// text, or a tutorial control.
#[derive(Clone, Debug)]
pub struct WorkItem {
    pub text: String,
    pub display_text: String,
    pub intent: Option<Arc<SpeechIntent>>,
    pub control: Option<String>,
}

impl WorkItem {
    pub fn for_intent(intent: Arc<SpeechIntent>) -> Self {
        Self {
            text: intent.spoken_text.clone(),
            display_text: intent.display_text.clone(),
            intent: Some(intent),
            control: None,
        }
    }
}

/// One `speech_audio` frame's worth of a reply, without its seq.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioPart {
    pub part: i64,
    pub parts: i64,
    pub last: bool,
    pub data: String,
}

pub const AUDIO_FORMAT: &str = "aac";
pub const AUDIO_SAMPLE_RATE: i64 = 24_000;

/// Sends one audio part of a remote reply to its device.
pub type EmitAudio = Box<dyn Fn(&AudioPart) -> Result<(), CallFailed> + Send>;

/// A reply to voice for a Relay Remote phone (RR-457).
pub struct RemoteJob {
    pub text: String,
    pub cancelled: Arc<AtomicBool>,
    pub emit: EmitAudio,
    pub failed: Box<dyn Fn(&str) + Send>,
}

/// The client did not answer a call: it refused, or the connection ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CallFailed;

/// A Relay Remote device session, which lives in the client.
pub trait RemoteDevice: Send + Sync {
    fn device_id(&self) -> &str;
    fn routable(&self) -> bool;
    fn speech(&self, frame: Json) -> Result<i64, CallFailed>;
    fn speech_control(&self, action: &str, reason: &str) -> Result<i64, CallFailed>;
    fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), CallFailed>;
}

/// What the coordinator gives the worker: eligibility and lifecycle callbacks.
pub trait SpeechHooks: Send + Sync {
    fn eligible(&self, intent: &SpeechIntent) -> bool;
    fn observe(&self, state: &str, intent: &SpeechIntent, at: Option<f64>);
}

/// The worker the coordinator drives (`TTSWorker` in Python).
pub trait Worker: Send + Sync {
    /// The hooks hold the coordinator weakly, so the worker may keep them.
    fn set_hooks(&self, hooks: Arc<dyn SpeechHooks>);
    fn enqueue(&self, item: WorkItem);
    fn play(&self);
    fn skip(&self);
    fn stop_playback(&self, reason: &str);
    fn reload_config(&self);
    fn shutdown(&self);
    fn remote_audio_available(&self) -> bool;
    fn synthesize_remote(&self, job: RemoteJob);
}

pub type IsCurrent = Box<dyn Fn(i64, &str) -> bool + Send + Sync>;
pub type IsPreserved = Box<dyn Fn(i64, &str, &Json) -> bool + Send + Sync>;
pub type OnReplyFinished = Box<dyn Fn(&str) + Send + Sync>;
/// `(state, intent, stop_reason, requeued_as)` for each worker lifecycle state.
pub type OnPlayback = Box<dyn Fn(&str, &SpeechIntent, Option<&str>, Option<&str>) + Send + Sync>;

#[derive(Default)]
pub struct Options {
    pub is_current: Option<IsCurrent>,
    pub is_preserved: Option<IsPreserved>,
    pub event_log: Option<PathBuf>,
    pub control_socket: Option<PathBuf>,
    pub on_reply_finished: Option<OnReplyFinished>,
    pub on_playback: Option<OnPlayback>,
}

/// An insertion-ordered map for the small bounded tables Python keeps in dicts.
struct Ordered<K, V> {
    entries: Vec<(K, V)>,
}

impl<K: PartialEq + Clone, V> Ordered<K, V> {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }
    fn len(&self) -> usize {
        self.entries.len()
    }
    fn get(&self, key: &K) -> Option<&V> {
        self.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
    fn get_mut(&mut self, key: &K) -> Option<&mut V> {
        self.entries
            .iter_mut()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v)
    }
    fn contains(&self, key: &K) -> bool {
        self.get(key).is_some()
    }
    /// Like a dict assignment: an existing key keeps its position.
    fn insert(&mut self, key: K, value: V) {
        match self.get_mut(&key) {
            Some(slot) => *slot = value,
            None => self.entries.push((key, value)),
        }
    }
    fn remove(&mut self, key: &K) -> Option<V> {
        let index = self.entries.iter().position(|(k, _)| k == key)?;
        Some(self.entries.remove(index).1)
    }
    fn pop_oldest(&mut self) {
        if !self.entries.is_empty() {
            self.entries.remove(0);
        }
    }
    fn keys(&self) -> Vec<K> {
        self.entries.iter().map(|(k, _)| k.clone()).collect()
    }
    fn values(&self) -> impl Iterator<Item = &V> {
        self.entries.iter().map(|(_, v)| v)
    }
}

/// An insertion-ordered set that keeps its newest members when trimmed.
struct RecentSet<T: Eq + Hash + Clone> {
    members: HashSet<T>,
    order: VecDeque<T>,
}

impl<T: Eq + Hash + Clone> RecentSet<T> {
    fn new() -> Self {
        Self {
            members: HashSet::new(),
            order: VecDeque::new(),
        }
    }
    fn contains(&self, value: &T) -> bool {
        self.members.contains(value)
    }
    fn len(&self) -> usize {
        self.members.len()
    }
    fn insert(&mut self, value: T) {
        if self.members.insert(value.clone()) {
            self.order.push_back(value);
        }
    }
    fn keep_newest(&mut self, count: usize) {
        while self.order.len() > count {
            if let Some(oldest) = self.order.pop_front() {
                self.members.remove(&oldest);
            }
        }
    }
}

#[derive(Clone, Debug, Default)]
struct PlayTiming {
    play_request_id: String,
    option_detected_at: Option<f64>,
    command_seq: Option<i64>,
    command_id: Option<String>,
    latched_at: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
struct Coverage {
    utterance_id: String,
    lifecycle_role: String,
    covered_facts: Vec<String>,
    spoken_text: String,
}

/// The Mac's voice streaming to one device for one `speech` frame (RR-457).
struct RemoteVoice {
    sink: Arc<dyn RemoteDevice>,
    seq: i64,
    intent: Arc<SpeechIntent>,
    started: Instant,
    cancelled: Arc<AtomicBool>,
    sent: Mutex<usize>,
}

type RemoteKey = (String, i64);

struct State {
    accepted_keys: RecentSet<String>,
    // RR-460: commands with an accepted outcome, and those already reported
    // as ending without one.
    outcome_commands: RecentSet<CommandKey>,
    missing_outcomes: RecentSet<CommandKey>,
    intents: HashMap<String, Arc<SpeechIntent>>,
    committed_id: Option<String>,
    playing_id: Option<String>,
    backlog: Vec<Arc<SpeechIntent>>,
    replayable_history: Vec<Arc<SpeechIntent>>,
    stopped_attempt_reasons: HashMap<String, String>,
    // RR-464: items skipped or replaced, so their cancellation never returns
    // them to the queue.
    retired_ids: Ordered<String, String>,
    played_coverage: Ordered<CommandKey, Vec<Coverage>>,
    waiting_preview: Option<(CommandKey, String)>,
    play_requested: bool,
    play_dispatched_id: Option<String>,
    play_timing: Option<PlayTiming>,
    utterance_timings: Ordered<String, PlayTiming>,
    intent_committed_at: Ordered<String, f64>,
    speech_stopped: bool,
    // Relay Remote devices, newest last; outstanding frames await an ack.
    remote_sinks: Ordered<String, Arc<dyn RemoteDevice>>,
    remote_outstanding: Ordered<RemoteKey, Arc<SpeechIntent>>,
    remote_stopped_through: HashMap<String, i64>,
    // RR-454: devices with Remote mode off see Mac speech as text only.
    remote_mirrors: Ordered<String, Arc<dyn RemoteDevice>>,
    // RR-457: replies still being voiced for a device, by (device, seq).
    remote_voices: HashMap<RemoteKey, Arc<RemoteVoice>>,
}

pub struct SpeechCoordinator {
    worker: Arc<dyn Worker>,
    me: Weak<SpeechCoordinator>,
    is_current: IsCurrent,
    is_preserved: Option<IsPreserved>,
    on_reply_finished: Option<OnReplyFinished>,
    on_playback: Option<OnPlayback>,
    log: JsonLog,
    state: Mutex<State>,
    shutdown: Arc<AtomicBool>,
    control_thread: Mutex<Option<JoinHandle<()>>>,
}

struct Hooks(Weak<SpeechCoordinator>);

impl SpeechHooks for Hooks {
    fn eligible(&self, intent: &SpeechIntent) -> bool {
        self.0
            .upgrade()
            .is_some_and(|coordinator| coordinator.eligible_for_worker(intent))
    }
    fn observe(&self, state: &str, intent: &SpeechIntent, at: Option<f64>) {
        if let Some(coordinator) = self.0.upgrade() {
            coordinator.observe_worker(state, intent, at);
        }
    }
}

impl SpeechCoordinator {
    pub fn new(worker: Arc<dyn Worker>, options: Options) -> Arc<Self> {
        let control_socket = options.control_socket.clone();
        let coordinator = Arc::new_cyclic(|me: &Weak<Self>| Self {
            worker,
            me: me.clone(),
            is_current: options.is_current.unwrap_or_else(|| Box::new(|_, _| true)),
            is_preserved: options.is_preserved,
            on_reply_finished: options.on_reply_finished,
            on_playback: options.on_playback,
            log: JsonLog::new(options.event_log),
            state: Mutex::new(State {
                accepted_keys: RecentSet::new(),
                outcome_commands: RecentSet::new(),
                missing_outcomes: RecentSet::new(),
                intents: HashMap::new(),
                committed_id: None,
                playing_id: None,
                backlog: Vec::new(),
                replayable_history: Vec::new(),
                stopped_attempt_reasons: HashMap::new(),
                retired_ids: Ordered::new(),
                played_coverage: Ordered::new(),
                waiting_preview: None,
                play_requested: false,
                play_dispatched_id: None,
                play_timing: None,
                utterance_timings: Ordered::new(),
                intent_committed_at: Ordered::new(),
                speech_stopped: false,
                remote_sinks: Ordered::new(),
                remote_outstanding: Ordered::new(),
                remote_stopped_through: HashMap::new(),
                remote_mirrors: Ordered::new(),
                remote_voices: HashMap::new(),
            }),
            shutdown: Arc::new(AtomicBool::new(false)),
            control_thread: Mutex::new(None),
        });
        coordinator
            .worker
            .set_hooks(Arc::new(Hooks(Arc::downgrade(&coordinator))));
        if let Some(path) = control_socket {
            match bind_control_socket(&path) {
                Ok((socket, inode)) => {
                    let weak = Arc::downgrade(&coordinator);
                    let shutdown = coordinator.shutdown.clone();
                    let handle = std::thread::Builder::new()
                        .name("speech-coordinator-control".into())
                        .spawn(move || control_loop(socket, path, inode, weak, shutdown))
                        .ok();
                    *coordinator.control_thread.lock().unwrap() = handle;
                }
                Err(error) => eprintln!("[speech_coordinator] Control socket unavailable: {error}"),
            }
        }
        coordinator
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    // -- Snapshots -----------------------------------------------------------

    pub fn has_pending_speech(&self) -> bool {
        let st = self.lock();
        st.committed_id.is_some() || st.playing_id.is_some() || !st.backlog.is_empty()
    }

    /// The queue in playing order: the head, then everything behind it (RR-480).
    pub fn queue_snapshot(&self) -> Json {
        let st = self.lock();
        let mut heads: Vec<&Arc<SpeechIntent>> = Vec::new();
        for id in [&st.playing_id, &st.committed_id].into_iter().flatten() {
            if let Some(intent) = st.intents.get(id)
                && !heads.iter().any(|head| head.utterance_id == *id)
            {
                heads.push(intent);
            }
        }
        let queue: Vec<Value> = heads
            .into_iter()
            .chain(st.backlog.iter())
            .map(|item| json!({"utterance_id": item.utterance_id, "original_utterance_id": item.original_utterance_id}))
            .collect();
        let mut snapshot = Json::new();
        snapshot.insert(
            "speaking".into(),
            (st.committed_id.is_some() || st.playing_id.is_some() || !st.backlog.is_empty()).into(),
        );
        snapshot.insert("playing".into(), st.playing_id.is_some().into());
        snapshot.insert("held".into(), st.speech_stopped.into());
        snapshot.insert("queue_depth".into(), queue_depth(&st).into());
        snapshot.insert("queue".into(), Value::Array(queue));
        snapshot
    }

    pub fn session_playback_states(&self, waiting_session_key: &str) -> Json {
        let st = self.lock();
        let mut states = Json::new();
        for item in &st.replayable_history {
            if !item.session_key.is_empty() && !item.expired() {
                states.insert(item.session_key.clone(), "replay".into());
            }
        }
        let committed = intent_for(&st, st.committed_id.as_deref());
        for item in committed.iter().chain(st.backlog.iter()) {
            if !item.session_key.is_empty() && self.fresh(&st, item) {
                states.insert(item.session_key.clone(), "play".into());
            }
        }
        if st.waiting_preview.is_some() && !waiting_session_key.is_empty() {
            states.insert(waiting_session_key.into(), "play".into());
        }
        if let Some(active) = intent_for(
            &st,
            st.playing_id
                .as_deref()
                .or(st.play_dispatched_id.as_deref()),
        ) && !active.session_key.is_empty()
        {
            states.insert(active.session_key.clone(), "stop".into());
        }
        states
    }

    /// A stale wheel action must never stop or replay another session.
    pub fn control_session(
        &self,
        session_key: &str,
        action: &str,
        waiting_session_key: &str,
    ) -> bool {
        let mut action = action.to_string();
        let mut selected = None;
        {
            let mut st = self.lock();
            let active = intent_for(
                &st,
                st.playing_id
                    .as_deref()
                    .or(st.play_dispatched_id.as_deref()),
            );
            let pending = intent_for(&st, st.committed_id.as_deref());
            if action == "stop" {
                if active
                    .as_ref()
                    .is_none_or(|active| active.session_key != session_key)
                {
                    return false;
                }
            } else if let Some(active) = active {
                return active.session_key == session_key;
            } else if pending.as_ref().is_some_and(|pending| {
                pending.session_key == session_key && self.fresh(&st, pending)
            }) || (st.waiting_preview.is_some() && waiting_session_key == session_key)
            {
                action = "play".into();
            } else {
                let found = st
                    .backlog
                    .iter()
                    .position(|item| item.session_key == session_key && self.fresh(&st, item));
                if let Some(index) = found {
                    let item = st.backlog.remove(index);
                    if let Some(pending) = pending {
                        st.backlog.insert(0, pending);
                    }
                    clear_play_request(&mut st, false);
                    st.committed_id = Some(item.utterance_id.clone());
                    selected = Some(item);
                    action = "play".into();
                } else if action != "replay" {
                    return false;
                }
            }
        }
        if let Some(selected) = selected {
            self.worker.skip();
            self.enqueue_worker(&selected);
        }
        match action.as_str() {
            "stop" => self.stop_playback("wheel_stop", Some(session_key)),
            "play" => self.play(Some(session_key), waiting_session_key),
            _ => return self.replay(Some(session_key)),
        }
        true
    }

    /// Speak explicit text now, such as a stored background reply (RR-401).
    pub fn read_out(&self, text: &str, session_key: &str) -> bool {
        let text = text.trim();
        if text.is_empty() {
            return false;
        }
        let intent = intent::build(IntentSpec {
            spoken_text: text.into(),
            dedup_key: Some(format!("read_out:{}", intent::uuid_hex())),
            session_key: Some(session_key.into()),
            replayable: Some(true),
            ..Default::default()
        });
        if !self.submit(Arc::new(intent), None) {
            return false;
        }
        if session_key.is_empty() {
            self.play(None, "");
        } else {
            self.control_session(session_key, "play", "");
        }
        true
    }

    // -- Relay Remote ----------------------------------------------------------

    /// Make a Relay Remote device the active speech output (RR-424).
    pub fn attach_remote_sink(&self, sink: Arc<dyn RemoteDevice>) {
        let device_id = sink.device_id().to_string();
        {
            let mut st = self.lock();
            st.remote_mirrors.remove(&device_id);
            st.remote_sinks.remove(&device_id);
            st.remote_sinks.insert(device_id.clone(), sink);
        }
        self.write(json_record(&[
            ("event", "remote_sink_attached".into()),
            ("at", number(support::now())),
            ("sink", REMOTE_SINK.into()),
            ("device_id", device_id.into()),
        ]));
    }

    pub fn detach_remote_sink(&self, device_id: &str, reason: &str) {
        let next = {
            let mut st = self.lock();
            self.detach_remote_locked(&mut st, device_id, reason);
            self.advance_locked(&mut st)
        };
        if let Some(next) = next {
            self.enqueue_worker(&next);
        }
    }

    /// Show Mac speech on a device whose Remote mode is off (RR-454).
    pub fn attach_remote_mirror(&self, sink: Arc<dyn RemoteDevice>) {
        let device_id = sink.device_id().to_string();
        self.lock().remote_mirrors.insert(device_id, sink);
    }

    pub fn detach_remote_mirror(&self, device_id: &str) {
        self.lock().remote_mirrors.remove(&device_id.to_string());
    }

    /// A device ack: `played` realizes the frame, otherwise receipt only.
    pub fn remote_ack(&self, device_id: &str, seq: i64, played: bool) -> bool {
        let key = (device_id.to_string(), seq);
        let intent = {
            let mut st = self.lock();
            let intent = st.remote_outstanding.remove(&key);
            if let Some(intent) = &intent
                && played
            {
                record_played_coverage(&mut st, intent);
            }
            // The device is done with this frame, so any audio still to come is moot.
            if let Some(voice) = st.remote_voices.remove(&key) {
                voice.cancelled.store(true, Ordering::SeqCst);
            }
            intent
        };
        let Some(intent) = intent else { return false };
        self.diagnostic(
            if played { "played" } else { "remote_received" },
            &intent,
            &[
                ("sink", REMOTE_SINK.into()),
                ("device_id", device_id.into()),
                ("remote_seq", seq.into()),
            ],
        );
        if played && let Some((seq, id)) = intent.command_key() {
            self.record_realization(
                seq,
                &id,
                intent.lifecycle_role.clone().into(),
                intent.realization_decision.clone().into(),
                intent.suppression_reason.clone().into(),
            );
        }
        true
    }

    // -- Diagnostics -----------------------------------------------------------

    /// Bounded semantic coverage from speech that finished playing.
    pub fn played_coverage(&self, command_seq: i64, command_id: &str) -> Vec<Value> {
        let st = self.lock();
        st.played_coverage
            .get(&(command_seq, command_id.to_string()))
            .map(|items| {
                items
                    .iter()
                    .map(|item| {
                        json!({
                            "utterance_id": item.utterance_id,
                            "lifecycle_role": item.lifecycle_role,
                            "covered_facts": item.covered_facts,
                            "spoken_text": item.spoken_text,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Record a synthesis decision without retaining reply text.
    pub fn record_realization(
        &self,
        command_seq: i64,
        command_id: &str,
        role: Value,
        decision: Value,
        reason: Value,
    ) {
        self.write(json_record(&[
            ("event", "realization".into()),
            ("at", number(support::now())),
            ("relay_command_seq", command_seq.into()),
            ("relay_command_id", command_id.into()),
            ("lifecycle_role", role),
            ("realization_decision", decision),
            ("suppression_reason", reason),
        ]));
    }

    /// Record command-scoped latency stages without transcript or reply text.
    pub fn record_messenger_stage(
        &self,
        stage: &str,
        command_seq: i64,
        command_id: &str,
        at: Option<f64>,
        provider: &str,
        outcome: &str,
    ) {
        if !MESSENGER_TIMING_STAGES.contains(&stage) {
            return;
        }
        let provider = provider.trim().to_lowercase();
        self.write(json_record(&[
            ("event", stage.into()),
            ("at", number(at.unwrap_or_else(support::now))),
            ("relay_command_seq", command_seq.into()),
            ("relay_command_id", command_id.into()),
            (
                "provider",
                if matches!(provider.as_str(), "codex" | "claude") {
                    provider.into()
                } else {
                    Value::Null
                },
            ),
            (
                "outcome",
                if outcome.is_empty() {
                    "ok".into()
                } else {
                    outcome.into()
                },
            ),
        ]));
    }

    /// Log once that a command ended with no accepted outcome (RR-460).
    pub fn record_missing_outcome(
        &self,
        command_seq: i64,
        command_id: &str,
        reason: &str,
        signals: &[String],
    ) -> bool {
        let key = (command_seq, command_id.to_string());
        {
            let mut st = self.lock();
            if st.outcome_commands.contains(&key) || st.missing_outcomes.contains(&key) {
                return false;
            }
            st.missing_outcomes.insert(key.clone());
            if st.missing_outcomes.len() > 256 {
                st.missing_outcomes.keep_newest(128);
            }
        }
        let mut signals: Vec<String> = signals
            .iter()
            .filter(|signal| !signal.is_empty())
            .cloned()
            .collect();
        signals.sort();
        signals.dedup();
        self.write(json_record(&[
            ("event", "missing_outcome".into()),
            ("at", number(support::now())),
            ("relay_command_seq", key.0.into()),
            ("relay_command_id", key.1.into()),
            (
                "reason",
                if reason.is_empty() {
                    "unknown".into()
                } else {
                    reason.into()
                },
            ),
            ("signals", signals.into()),
        ]));
        true
    }

    // -- Proposals -------------------------------------------------------------

    pub fn submit(&self, intent: Arc<SpeechIntent>, waiting_playback_kind: Option<&str>) -> bool {
        let started = Instant::now();
        self.diagnostic("proposed", &intent, &[]);
        if intent.spoken_text.is_empty() || !self.fresh(&self.lock(), &intent) {
            self.diagnostic(
                "expired",
                &intent,
                &[("latency_ms", number(elapsed_ms(started)))],
            );
            return false;
        }
        // RR-464: one FIFO for every session. `head` is what the worker
        // receives now; `cut_worker` discards the worker's current item.
        let head;
        let mut cut_worker = false;
        {
            let mut st = self.lock();
            if st.accepted_keys.contains(&intent.dedup_key) || final_already_accepted(&st, &intent)
            {
                self.diagnostic(
                    "deduplicated",
                    &intent,
                    &[("latency_ms", number(elapsed_ms(started)))],
                );
                return false;
            }
            if let Some(sink) = self.active_remote_sink_locked(&mut st) {
                return self.submit_remote_locked(&mut st, sink, intent, started);
            }
            if queue_depth(&st) >= SPEECH_QUEUE_LIMIT {
                self.diagnostic(
                    "queue_full",
                    &intent,
                    &[
                        ("limit", SPEECH_QUEUE_LIMIT.into()),
                        ("latency_ms", number(elapsed_ms(started))),
                    ],
                );
                return false;
            }
            let current = intent_for(&st, st.playing_id.as_deref().or(st.committed_id.as_deref()));
            let playing = intent_for(&st, st.playing_id.as_deref());
            accept_locked(&mut st, &intent);
            if let Some(kind) = waiting_playback_kind.filter(|kind| !kind.is_empty())
                && let Some(key) = intent.command_key()
            {
                arm_waiting_playback_locked(&mut st, key, kind);
            }
            let mut replaced = Vec::new();
            match current {
                Some(current)
                    if replaces_fallback(&intent, &current)
                        || (playing.is_none() && supersedes(&intent, &current)) =>
                {
                    // Same command: the real final, or a reply replacing its
                    // own unstarted handoff/progress, takes the head's place.
                    if let Some(committed) = st.committed_id.clone()
                        && committed != current.utterance_id
                        && let Some(committed) = st.intents.get(&committed).cloned()
                    {
                        replaced.push(current);
                        replaced.push(committed);
                    } else {
                        replaced.push(current);
                    }
                    self.drop_obsolete_backlog(&mut st, &intent);
                    commit_locked(&mut st, &intent);
                    head = Some(intent.clone());
                    cut_worker = true;
                }
                Some(current)
                    if newer_command(&intent, &current)
                        && !is_queued_reply_kind(&current.kind)
                        && current.freshness_scope != "work" =>
                {
                    // A newer command retires stale handoff/progress speech; the
                    // queue, not the newer command, decides what plays next.
                    retire_locked(&mut st, &current, "newer_command");
                    if st.committed_id.as_deref() == Some(current.utterance_id.as_str()) {
                        st.committed_id = None;
                    }
                    self.drop_obsolete_backlog(&mut st, &intent);
                    append_backlog_locked(&mut st, intent.clone());
                    head = self.advance_locked(&mut st);
                    cut_worker = true;
                    self.diagnostic(
                        "interrupted",
                        &current,
                        &[("reason", "newer_command".into())],
                    );
                }
                _ => {
                    self.drop_obsolete_backlog(&mut st, &intent);
                    append_backlog_locked(&mut st, intent.clone());
                    head = self.advance_locked(&mut st);
                }
            }
            for old in replaced {
                retire_locked(&mut st, &old, "replaced");
                if st.play_dispatched_id.as_deref() == Some(old.utterance_id.as_str()) {
                    st.play_dispatched_id = None;
                }
                self.diagnostic(
                    "replaced",
                    &old,
                    &[("replaced_by", intent.utterance_id.clone().into())],
                );
            }
        }
        if cut_worker {
            self.worker.skip();
        }
        if let Some(head) = head {
            self.enqueue_worker(&head);
        }
        self.dispatch_requested_play();
        self.diagnostic(
            "accepted",
            &intent,
            &[("latency_ms", number(elapsed_ms(started)))],
        );
        true
    }

    /// Bind the next play gesture to speech backing an imminent preview.
    pub fn arm_waiting_playback(&self, command_seq: i64, command_id: &str, kind: &str) {
        arm_waiting_playback_locked(
            &mut self.lock(),
            (command_seq, command_id.to_string()),
            kind,
        );
    }

    /// Capture privacy-safe shortcut timing before play mutates coordinator state.
    pub fn note_play_control(
        &self,
        option_detected_at: Option<f64>,
        fifo_received_at: Option<f64>,
    ) {
        let received_at = fifo_received_at
            .filter(|at| *at != 0.0)
            .unwrap_or_else(support::now);
        let detected_at = option_detected_at
            .filter(|at| *at != 0.0)
            .unwrap_or(received_at);
        let mut st = self.lock();
        if st.play_requested
            && let Some(timing) = &st.play_timing
        {
            self.write(json_record(&[
                ("event", "duplicate_play_control".into()),
                ("at", number(received_at)),
                ("play_request_id", timing.play_request_id.clone().into()),
                ("relay_command_seq", opt_int(timing.command_seq)),
                ("relay_command_id", opt_text(timing.command_id.as_deref())),
                (
                    "option_to_fifo_ms",
                    duration_ms(Some(detected_at), Some(received_at)),
                ),
            ]));
            return;
        }
        let pending = intent_for(&st, st.committed_id.as_deref());
        let key = match &st.waiting_preview {
            Some((key, _)) => Some(key.clone()),
            None => pending.as_ref().and_then(|intent| intent.command_key()),
        };
        let timing = PlayTiming {
            play_request_id: intent::support_uuid(),
            option_detected_at: Some(detected_at),
            command_seq: key.as_ref().map(|key| key.0),
            command_id: key.map(|key| key.1),
            latched_at: None,
        };
        let fields = [
            (
                "play_request_id",
                Value::from(timing.play_request_id.clone()),
            ),
            ("relay_command_seq", opt_int(timing.command_seq)),
            ("relay_command_id", opt_text(timing.command_id.as_deref())),
        ];
        st.play_timing = Some(timing);
        let mut detected = json_record(&[
            ("event", "option_detected".into()),
            ("at", number(detected_at)),
        ]);
        detected.extend(fields.iter().cloned().map(|(k, v)| (k.to_string(), v)));
        self.write(detected);
        let mut received = json_record(&[
            ("event", "fifo_play_received".into()),
            ("at", number(received_at)),
            (
                "option_to_fifo_ms",
                duration_ms(Some(detected_at), Some(received_at)),
            ),
        ]);
        received.extend(fields.into_iter().map(|(k, v)| (k.to_string(), v)));
        self.write(received);
    }

    pub fn note_visual_acknowledgement(&self, option_detected_at: f64, acknowledged_at: f64) {
        let st = self.lock();
        let timing = st.play_timing.as_ref();
        self.write(json_record(&[
            ("event", "visual_play_acknowledged".into()),
            ("at", number(acknowledged_at)),
            (
                "play_request_id",
                opt_text(timing.map(|timing| timing.play_request_id.as_str())),
            ),
            (
                "relay_command_seq",
                opt_int(timing.and_then(|timing| timing.command_seq)),
            ),
            (
                "relay_command_id",
                opt_text(timing.and_then(|timing| timing.command_id.as_deref())),
            ),
            (
                "option_to_ack_ms",
                duration_ms(Some(option_detected_at), Some(acknowledged_at)),
            ),
        ]));
    }

    // -- Playback control ------------------------------------------------------

    /// Suppress stale speech without revoking accepted background work.
    ///
    /// RR-464: queued replies from older commands stay queued; one that is
    /// playing stops and returns to the head of the queue.
    pub fn new_turn(&self, command_seq: i64, command_id: &str) {
        let key = (command_seq, command_id.to_string());
        let stale = |intent: &SpeechIntent| {
            intent.freshness_scope != "work" && intent.command_key().as_ref() != Some(&key)
        };
        self.stop_remote(
            "stop",
            remote_reason("newer_command"),
            Some(&|sent: &SpeechIntent| stale(sent) && !is_queued_reply_kind(&sent.kind)),
            true,
        );
        let mut retired = Vec::new();
        let mut interrupted = None;
        let mut next = None;
        let mut cut_committed = false;
        {
            let mut st = self.lock();
            st.speech_stopped = false;
            clear_play_request(&mut st, false);
            if let Some(playing) = intent_for(&st, st.playing_id.as_deref())
                && stale(&playing)
            {
                st.stopped_attempt_reasons
                    .insert(playing.utterance_id.clone(), "newer_command".into());
                retain_replayable(&mut st, &playing);
                interrupted = Some(playing);
            }
            if let Some(committed) = intent_for(&st, st.committed_id.as_deref())
                && stale(&committed)
                && !is_queued_reply_kind(&committed.kind)
            {
                retire_locked(&mut st, &committed, "newer_command");
                st.committed_id = None;
                cut_committed = true;
                retired.push(committed);
            }
            let (dropped, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut st.backlog)
                .into_iter()
                .partition(|intent| stale(intent) && !is_queued_reply_kind(&intent.kind));
            st.backlog = kept;
            retired.extend(dropped);
            // Stale speech stops, but the last message stays replayable.
            for intent in &retired {
                retain_replayable(&mut st, intent);
            }
            if interrupted.is_none() {
                next = self.advance_locked(&mut st);
            }
        }
        if let Some(interrupted) = &interrupted {
            self.worker.stop_playback("newer_command");
            self.diagnostic(
                "interrupted",
                interrupted,
                &[
                    ("reason", "newer_command".into()),
                    ("requeued", true.into()),
                ],
            );
        }
        if cut_committed {
            self.worker.skip();
        }
        for intent in &retired {
            self.diagnostic("interrupted", intent, &[("reason", "newer_command".into())]);
        }
        if let Some(next) = next {
            self.enqueue_worker(&next);
        }
    }

    /// Barge-in stops speech and holds the queue until play (RR-464).
    pub fn stop(&self) {
        self.stop_remote("stop", "speech_only_barge_in", None, false);
        let playing = {
            let mut st = self.lock();
            st.speech_stopped = true;
            clear_play_request(&mut st, false);
            let playing = intent_for(&st, st.playing_id.as_deref());
            if let Some(playing) = &playing {
                st.stopped_attempt_reasons
                    .insert(playing.utterance_id.clone(), "speech_only_barge_in".into());
                retain_replayable(&mut st, playing);
            }
            playing
        };
        self.worker.stop_playback("user_stop");
        if let Some(playing) = playing {
            self.diagnostic(
                "interrupted",
                &playing,
                &[
                    ("reason", "speech_only_barge_in".into()),
                    ("requeued", true.into()),
                ],
            );
        }
    }

    /// Stop one active attempt; it stays queued and replayable (RR-464).
    pub fn stop_playback(&self, reason: &str, session_key: Option<&str>) {
        let reason = match reason.trim() {
            "" => "user_stop".to_string(),
            reason => reason.to_string(),
        };
        let in_session = |sent: &SpeechIntent| Some(sent.session_key.as_str()) == session_key;
        self.stop_remote(
            "stop",
            remote_reason(&reason),
            if session_key.is_some() {
                Some(&in_session)
            } else {
                None
            },
            false,
        );
        let intent = {
            let mut st = self.lock();
            let intent = intent_for(
                &st,
                st.playing_id
                    .as_deref()
                    .or(st.play_dispatched_id.as_deref()),
            );
            if let Some(session_key) = session_key
                && intent
                    .as_ref()
                    .is_none_or(|intent| intent.session_key != session_key)
            {
                return;
            }
            if let Some(intent) = &intent {
                st.stopped_attempt_reasons
                    .insert(intent.utterance_id.clone(), reason.clone());
                clear_play_request(&mut st, false);
                if heard_stop(&reason) && !st.retired_ids.contains(&intent.utterance_id) {
                    retire_locked(&mut st, intent, &reason);
                }
                if !st.retired_ids.contains(&intent.utterance_id) {
                    // A stop holds the queue; a skip moves along.
                    st.speech_stopped = true;
                }
                if !replay_retaining(&reason) {
                    retain_replayable(&mut st, intent);
                }
            }
            intent
        };
        if intent.is_none() {
            self.stop();
            return;
        }
        self.worker.stop_playback(&reason);
    }

    /// Remove only the current item (RR-464); the rest stay queued.
    pub fn skip(&self, reason: &str) {
        self.stop_remote("skip", remote_reason(reason), None, false);
        let active = {
            let mut st = self.lock();
            let active = intent_for(&st, st.playing_id.as_deref());
            if let Some(active) = &active {
                retire_locked(&mut st, active, reason);
            }
            active
        };
        if active.is_some() {
            self.stop_playback(reason, None);
            return;
        }
        let mut next = None;
        let target = {
            let mut st = self.lock();
            clear_play_request(&mut st, false);
            let mut target = intent_for(&st, st.committed_id.as_deref());
            if target.is_some() {
                st.committed_id = None;
            } else if !non_advancing(reason) && !st.backlog.is_empty() {
                target = Some(st.backlog.remove(0));
            }
            if let Some(target) = &target {
                retire_locked(&mut st, target, reason);
                // A message cancelled before it ever played stays replayable
                // and becomes the newest replay target.
                retain_replayable(&mut st, target);
            }
            if !non_advancing(reason) {
                next = self.advance_locked(&mut st);
            }
            target
        };
        self.worker.skip();
        if let Some(target) = target {
            self.diagnostic("interrupted", &target, &[("reason", "skip".into())]);
        }
        if let Some(next) = next {
            self.enqueue_worker(&next);
        }
    }

    pub fn play(&self, session_key: Option<&str>, waiting_session_key: &str) {
        let mut resumed = None;
        {
            let mut st = self.lock();
            if st.playing_id.is_some() {
                return;
            }
            if st.committed_id.is_none() && st.waiting_preview.is_none() && !st.backlog.is_empty() {
                // RR-464: Play resumes the head of the queue.
                let head = st.backlog[0].clone();
                if session_key.is_none_or(|key| head.session_key == key) {
                    st.speech_stopped = false;
                    resumed = self.advance_locked(&mut st);
                }
            }
            let pending = intent_for(&st, st.committed_id.as_deref());
            if let Some(key) = session_key
                && !(pending
                    .as_ref()
                    .is_some_and(|pending| pending.session_key == key)
                    || (st.waiting_preview.is_some() && waiting_session_key == key))
            {
                return;
            }
            if st.committed_id.is_none() && st.waiting_preview.is_none() {
                return;
            }
            st.speech_stopped = false;
            st.play_requested = true;
            if let Some(timing) = st.play_timing.as_mut()
                && timing.latched_at.is_none()
            {
                let latched_at = support::now();
                timing.latched_at = Some(latched_at);
                let record = json_record(&[
                    ("event", "retained_play_latched".into()),
                    ("at", number(latched_at)),
                    ("play_request_id", timing.play_request_id.clone().into()),
                    ("relay_command_seq", opt_int(timing.command_seq)),
                    ("relay_command_id", opt_text(timing.command_id.as_deref())),
                    (
                        "option_to_latch_ms",
                        duration_ms(timing.option_detected_at, Some(latched_at)),
                    ),
                ]);
                self.write(record);
            }
        }
        if let Some(resumed) = resumed {
            self.enqueue_worker(&resumed);
        }
        self.dispatch_requested_play();
    }

    /// Play queued speech, or replay the last completed current message.
    pub fn play_or_replay(&self) -> bool {
        let should_replay = {
            let st = self.lock();
            if st.playing_id.is_some() {
                return true;
            }
            st.committed_id.is_none()
                && st.waiting_preview.is_none()
                && !st.backlog.iter().any(|intent| self.fresh(&st, intent))
        };
        if should_replay {
            return self.replay(None);
        }
        self.play(None, "");
        true
    }

    pub fn replay(&self, session_key: Option<&str>) -> bool {
        let (history, timing) = {
            let st = self.lock();
            (st.replayable_history.clone(), st.play_timing.clone())
        };
        let previous = history
            .iter()
            .rev()
            .find(|intent| {
                !intent.expired() && session_key.is_none_or(|key| intent.session_key == key)
            })
            .cloned();
        let Some(previous) = previous else {
            let latest = history.last();
            self.write(json_record(&[
                ("event", "replay_rejected".into()),
                ("at", number(support::now())),
                (
                    "reason",
                    if history.is_empty() {
                        "no_completed_target"
                    } else {
                        "no_fresh_target"
                    }
                    .into(),
                ),
                (
                    "play_request_id",
                    opt_text(
                        timing
                            .as_ref()
                            .map(|timing| timing.play_request_id.as_str()),
                    ),
                ),
                (
                    "utterance_id",
                    opt_text(latest.map(|latest| latest.utterance_id.as_str())),
                ),
                (
                    "relay_command_seq",
                    opt_int(latest.and_then(|latest| latest.command_seq)),
                ),
                (
                    "relay_command_id",
                    opt_text(latest.and_then(|latest| latest.command_id.as_deref())),
                ),
            ]));
            return false;
        };
        let mut replay = (*previous).clone();
        replay.utterance_id = intent::support_uuid();
        replay.dedup_key = format!(
            "replay:{}:{}",
            previous.utterance_id,
            intent::support_uuid()
        );
        replay.created_at = support::now();
        replay.replacement_policy = "replay".into();
        replay.original_utterance_id = previous.original_utterance_id.clone();
        replay.replay_of = Some(previous.original_utterance_id.clone());
        let replay = Arc::new(replay);
        {
            let mut st = self.lock();
            st.waiting_preview = None;
            st.play_requested = session_key.is_none();
        }
        let accepted = self.submit(replay.clone(), None);
        if accepted {
            if let Some(key) = session_key {
                self.control_session(key, "play", "");
            }
            self.diagnostic(
                "replayed",
                &replay,
                &[("replay_of", opt_text(replay.replay_of.as_deref()))],
            );
        } else {
            self.lock().play_requested = false;
        }
        accepted
    }

    pub fn reload_config(&self) {
        self.worker.reload_config();
        let next = {
            let mut st = self.lock();
            if st.committed_id.is_none() && st.playing_id.is_none() && !st.speech_stopped {
                let next = self.next_eligible_locked(&mut st);
                if let Some(next) = &next {
                    st.committed_id = Some(next.utterance_id.clone());
                }
                next
            } else {
                None
            }
        };
        if let Some(next) = next {
            self.enqueue_worker(&next);
        }
    }

    pub fn shutdown(&self) {
        self.shutdown.store(true, Ordering::SeqCst);
        self.stop();
        self.worker.shutdown();
        let handle = self.control_thread.lock().unwrap().take();
        if let Some(handle) = handle {
            let deadline = Instant::now() + Duration::from_secs(1);
            while !handle.is_finished() && Instant::now() < deadline {
                support::sleep(0.01);
            }
            if handle.is_finished() {
                let _ = handle.join();
            }
        }
    }

    // -- Worker callbacks ------------------------------------------------------

    fn eligible_for_worker(&self, intent: &SpeechIntent) -> bool {
        let st = self.lock();
        let Some(stored) = st.intents.get(&intent.utterance_id).cloned() else {
            return false;
        };
        let id = Some(stored.utterance_id.as_str());
        let accepted = !st.speech_stopped
            && (st.committed_id.as_deref() == id || st.playing_id.as_deref() == id)
            && matches_waiting_preview(&st, &stored);
        accepted && self.fresh(&st, &stored)
    }

    fn observe_worker(&self, state: &str, observed: &SpeechIntent, at: Option<f64>) {
        let intent_id = observed.utterance_id.clone();
        let observed_at = at.unwrap_or_else(support::now);
        let terminal = matches!(state, "completed" | "cancelled" | "failed");
        let mut next = None;
        let mut retained_after_stop = false;
        let mut stop_reason = None;
        let mut requeued: Option<Arc<SpeechIntent>> = None;
        let (intent, timing) = {
            let mut st = self.lock();
            let Some(intent) = st.intents.get(&intent_id).cloned() else {
                return;
            };
            if state == "started" {
                st.playing_id = Some(intent_id.clone());
                if st.committed_id.as_deref() == Some(intent_id.as_str()) {
                    st.committed_id = None;
                }
                if matches_waiting_preview(&st, &intent) {
                    clear_play_request(&mut st, true);
                }
            } else if terminal {
                stop_reason = st.stopped_attempt_reasons.remove(&intent_id);
                let retired_reason = st.retired_ids.remove(&intent_id);
                let was_head = st.committed_id.as_deref() == Some(intent_id.as_str())
                    || st.playing_id.as_deref() == Some(intent_id.as_str());
                let stopped_attempt =
                    state == "cancelled" && stop_reason.as_deref().is_some_and(replay_retaining);
                let slots = &mut *st;
                for slot in [
                    &mut slots.play_dispatched_id,
                    &mut slots.playing_id,
                    &mut slots.committed_id,
                ] {
                    if slot.as_deref() == Some(intent_id.as_str()) {
                        *slot = None;
                    }
                }
                retained_after_stop = stopped_attempt && retain_replayable(&mut st, &intent);
                if state == "completed" {
                    retain_replayable(&mut st, &intent);
                    record_played_coverage(&mut st, &intent);
                }
                // RR-464: a stopped or held reply was not played, so it goes
                // back to the head of the queue; only a skip removes it.
                if state == "cancelled"
                    && was_head
                    && retired_reason.is_none()
                    && intent.replay_of.is_none()
                    && (stop_reason.is_some() || is_queued_reply_kind(&intent.kind))
                    && self.fresh(&st, &intent)
                {
                    requeued = Some(requeue_locked(&mut st, &intent));
                }
                // A stop holds the queue through `speech_stopped`.
                let advances = match &retired_reason {
                    Some(reason) => !non_advancing(reason),
                    None => requeued.is_none(),
                };
                if advances {
                    next = self.advance_locked(&mut st);
                }
            }
            let timing = st.utterance_timings.get(&intent_id).cloned();
            (intent, timing)
        };
        let stage_event = match state {
            "preparing" => Some("tts_preparing"),
            "wav_ready" => Some("first_wav_ready"),
            "afplay_started" => Some("afplay_started"),
            _ => None,
        };
        if let Some(stage_event) = stage_event {
            self.diagnostic(
                stage_event,
                &intent,
                &[
                    ("at", number(observed_at)),
                    (
                        "play_request_id",
                        opt_text(
                            timing
                                .as_ref()
                                .map(|timing| timing.play_request_id.as_str()),
                        ),
                    ),
                    (
                        "option_to_stage_ms",
                        duration_ms(
                            timing.as_ref().and_then(|timing| timing.option_detected_at),
                            Some(observed_at),
                        ),
                    ),
                ],
            );
        } else {
            let name = if state == "completed" {
                "played"
            } else if retained_after_stop {
                "stopped"
            } else {
                state
            };
            let mut fields = vec![
                ("at", number(observed_at)),
                ("stop_reason", opt_text(stop_reason.as_deref())),
            ];
            if let Some(requeued) = &requeued {
                fields.push(("requeued_as", requeued.utterance_id.clone().into()));
            }
            self.diagnostic(name, &intent, &fields);
        }
        if let Some(on_playback) = &self.on_playback {
            on_playback(
                state,
                &intent,
                stop_reason.as_deref(),
                requeued
                    .as_ref()
                    .map(|requeued| requeued.utterance_id.as_str()),
            );
        }
        if let Some(next) = next {
            self.enqueue_worker(&next);
        } else if let Some(on_reply_finished) = &self.on_reply_finished
            && is_final_kind(&intent.kind)
            && (state == "completed" || stop_reason.as_deref() == Some("user_stop"))
            && !self.has_pending_speech()
        {
            on_reply_finished(if state == "completed" {
                "completed"
            } else {
                "user_stop"
            });
        }
        if terminal {
            let mut st = self.lock();
            st.utterance_timings.remove(&intent_id);
            st.intent_committed_at.remove(&intent_id);
        }
    }

    // -- Relay Remote internals ------------------------------------------------

    fn active_remote_sink_locked(&self, st: &mut State) -> Option<Arc<dyn RemoteDevice>> {
        let mut active = None;
        for device_id in st.remote_sinks.keys() {
            let Some(sink) = st.remote_sinks.get(&device_id).cloned() else {
                continue;
            };
            if sink.routable() {
                active = Some(sink);
            } else {
                self.detach_remote_locked(st, &device_id, "replay_window_expired");
            }
        }
        active
    }

    fn detach_remote_locked(&self, st: &mut State, device_id: &str, reason: &str) {
        if st.remote_sinks.remove(&device_id.to_string()).is_none() {
            return;
        }
        let stopped_through = st.remote_stopped_through.remove(device_id).unwrap_or(0);
        let mut keys: Vec<RemoteKey> = st
            .remote_outstanding
            .keys()
            .into_iter()
            .filter(|key| key.0 == device_id)
            .collect();
        keys.sort();
        let mut returned = Vec::new();
        for key in keys {
            let Some(sent) = st.remote_outstanding.remove(&key) else {
                continue;
            };
            // RR-464: an unplayed reply returns to the Mac queue in seq order.
            if key.1 > stopped_through && is_queued_reply_kind(&sent.kind) && !sent.expired() {
                returned.push(sent);
            }
        }
        cancel_remote_voices_locked(st, device_id, None);
        st.backlog.extend(returned.iter().cloned());
        for sent in &returned {
            self.diagnostic(
                "remote_returned",
                sent,
                &[
                    ("sink", REMOTE_SINK.into()),
                    ("device_id", device_id.into()),
                ],
            );
        }
        self.write(json_record(&[
            ("event", "remote_sink_detached".into()),
            ("at", number(support::now())),
            ("sink", REMOTE_SINK.into()),
            ("device_id", device_id.into()),
            ("reason", reason.into()),
        ]));
    }

    /// Send one accepted intent as a `speech` frame, then its audio.
    ///
    /// The text goes first so the phone can show it at once. With `audio` the
    /// worker voices it without the Mac's speaker (RR-457); without, the
    /// phone speaks it with its own voice.
    fn submit_remote_locked(
        &self,
        st: &mut State,
        sink: Arc<dyn RemoteDevice>,
        intent: Arc<SpeechIntent>,
        started: Instant,
    ) -> bool {
        let device_id = sink.device_id().to_string();
        let fields = [
            ("sink", Value::from(REMOTE_SINK)),
            ("device_id", Value::from(device_id.clone())),
        ];
        // RR-464: older handoff/progress frames give way; queued replies stay.
        self.stop_remote_locked(
            st,
            &sink,
            "stop",
            remote_reason("newer_command"),
            Some(&|sent: &SpeechIntent| {
                newer_command(&intent, sent) && !is_queued_reply_kind(&sent.kind)
            }),
            true,
        );
        // RR-460: an unacked fallback frame gives way to the real final.
        self.stop_remote_locked(
            st,
            &sink,
            "stop",
            remote_reason("newer_command"),
            Some(&|sent: &SpeechIntent| replaces_fallback(&intent, sent)),
            true,
        );
        let audio = self.worker.remote_audio_available();
        let frame = json_record(&[
            ("kind", intent.kind.clone().into()),
            ("source", intent.source.clone().into()),
            ("text", intent.spoken_text.clone().into()),
            ("relay_command_seq", opt_int(intent.command_seq)),
            ("audio", audio.into()),
        ]);
        let Ok(seq) = sink.speech(frame) else {
            let mut failed = vec![("latency_ms", number(elapsed_ms(started)))];
            failed.extend(fields.iter().cloned());
            self.diagnostic("remote_failed", &intent, &failed);
            return false;
        };
        if audio {
            let voice = Arc::new(RemoteVoice {
                sink: sink.clone(),
                seq,
                intent: intent.clone(),
                started,
                cancelled: Arc::new(AtomicBool::new(false)),
                sent: Mutex::new(0),
            });
            st.remote_voices
                .insert((device_id.clone(), seq), voice.clone());
            let emitter = (self.me.clone(), voice.clone());
            let failer = (self.me.clone(), intent.clone(), device_id.clone());
            self.worker.synthesize_remote(RemoteJob {
                text: intent.spoken_text.clone(),
                cancelled: voice.cancelled.clone(),
                emit: Box::new(move |part| match emitter.0.upgrade() {
                    Some(coordinator) => coordinator.emit_remote_audio(&emitter.1, part),
                    None => Err(CallFailed),
                }),
                failed: Box::new(move |reason| {
                    if let Some(coordinator) = failer.0.upgrade() {
                        coordinator.diagnostic(
                            "remote_audio_failed",
                            &failer.1,
                            &[
                                ("remote_seq", seq.into()),
                                ("reason", reason.into()),
                                ("sink", REMOTE_SINK.into()),
                                ("device_id", failer.2.clone().into()),
                            ],
                        );
                    }
                }),
            });
        }
        accept_locked(st, &intent);
        retain_replayable(st, &intent);
        if intent.replay_of.is_some() {
            // The device plays the replay; no local play request stays latched.
            st.play_requested = false;
        }
        st.remote_outstanding
            .insert((device_id, seq), intent.clone());
        if st.remote_outstanding.len() > 512 {
            st.remote_outstanding.pop_oldest();
        }
        let mut sent = vec![("remote_seq", Value::from(seq)), ("audio", audio.into())];
        sent.extend(fields.iter().cloned());
        self.diagnostic("remote_speech_sent", &intent, &sent);
        let mut accepted = vec![("latency_ms", number(elapsed_ms(started)))];
        accepted.extend(fields.iter().cloned());
        self.diagnostic("accepted", &intent, &accepted);
        true
    }

    /// Send one audio part unless its reply was stopped; time the first.
    fn emit_remote_audio(&self, voice: &RemoteVoice, part: &AudioPart) -> Result<(), CallFailed> {
        let first = {
            let mut st = self.lock();
            if voice.cancelled.load(Ordering::SeqCst) {
                return Ok(());
            }
            voice.sink.speech_audio(voice.seq, part)?;
            let mut sent = voice.sent.lock().unwrap();
            let first = *sent == 0 && !part.data.is_empty();
            *sent += 1;
            if part.last {
                st.remote_voices
                    .remove(&(voice.sink.device_id().to_string(), voice.seq));
            }
            first
        };
        if first {
            self.diagnostic(
                "remote_first_audio",
                &voice.intent,
                &[
                    ("sink", REMOTE_SINK.into()),
                    ("device_id", voice.sink.device_id().into()),
                    ("remote_seq", voice.seq.into()),
                    (
                        "submit_to_first_audio_ms",
                        number(elapsed_ms(voice.started)),
                    ),
                ],
            );
        }
        Ok(())
    }

    fn stop_remote(
        &self,
        action: &str,
        reason: &str,
        stale: Option<&dyn Fn(&SpeechIntent) -> bool>,
        preserve_replies: bool,
    ) {
        let mut st = self.lock();
        if let Some(sink) = self.active_remote_sink_locked(&mut st) {
            self.stop_remote_locked(&mut st, &sink, action, reason, stale, preserve_replies);
        }
    }

    /// Send `speech_control` once for unacked frames not already stopped.
    ///
    /// The device drops every frame before a `speech_control`. With
    /// `preserve_replies` (RR-464) no stop is sent while an unacked reply that
    /// is not itself stale would be dropped with it.
    fn stop_remote_locked(
        &self,
        st: &mut State,
        sink: &Arc<dyn RemoteDevice>,
        action: &str,
        reason: &str,
        stale: Option<&dyn Fn(&SpeechIntent) -> bool>,
        preserve_replies: bool,
    ) {
        let device_id = sink.device_id().to_string();
        let stopped_through = st
            .remote_stopped_through
            .get(&device_id)
            .copied()
            .unwrap_or(0);
        let unacked: Vec<&Arc<SpeechIntent>> = st
            .remote_outstanding
            .entries
            .iter()
            .filter(|(key, _)| key.0 == device_id && key.1 > stopped_through)
            .map(|(_, sent)| sent)
            .collect();
        let is_stale = |sent: &SpeechIntent| stale.is_none_or(|stale| stale(sent));
        if !unacked.iter().any(|sent| is_stale(sent)) {
            return;
        }
        if preserve_replies
            && unacked
                .iter()
                .any(|sent| is_queued_reply_kind(&sent.kind) && !is_stale(sent))
        {
            return;
        }
        let Ok(seq) = sink.speech_control(action, reason) else {
            eprintln!("[speech_coordinator] speech_control was not sent");
            return;
        };
        st.remote_stopped_through.insert(device_id.clone(), seq);
        // The device drops every frame before a speech_control, so stop voicing them.
        cancel_remote_voices_locked(st, &device_id, Some(seq));
        self.write(json_record(&[
            ("event", "remote_speech_control".into()),
            ("at", number(support::now())),
            ("sink", REMOTE_SINK.into()),
            ("device_id", device_id.into()),
            ("remote_seq", seq.into()),
            ("action", action.into()),
            ("reason", reason.into()),
        ]));
    }

    // -- Queue internals -------------------------------------------------------

    fn enqueue_worker(&self, intent: &Arc<SpeechIntent>) {
        self.diagnostic("tts_enqueued", intent, &[("sink", LOCAL_SINK.into())]);
        self.worker.enqueue(WorkItem::for_intent(intent.clone()));
        let mirrors: Vec<Arc<dyn RemoteDevice>> =
            self.lock().remote_mirrors.values().cloned().collect();
        for mirror in mirrors {
            // A display copy must never stop Mac speech.
            let _ = mirror.speech(json_record(&[
                ("kind", intent.kind.clone().into()),
                ("source", intent.source.clone().into()),
                ("text", intent.spoken_text.clone().into()),
                ("relay_command_seq", opt_int(intent.command_seq)),
                ("spoken_by", "mac".into()),
            ]));
        }
    }

    fn dispatch_requested_play(&self) {
        let should_play = {
            let mut st = self.lock();
            let Some(intent) = intent_for(&st, st.committed_id.as_deref()) else {
                return;
            };
            if !(st.play_requested
                && st.playing_id.is_none()
                && matches_waiting_preview(&st, &intent)
                && st.play_dispatched_id.as_deref() != Some(intent.utterance_id.as_str()))
            {
                return;
            }
            st.play_dispatched_id = Some(intent.utterance_id.clone());
            if let Some(mut timing) = st.play_timing.clone() {
                timing.command_seq = intent.command_seq;
                timing.command_id = intent.command_id.clone();
                let committed_at = st
                    .intent_committed_at
                    .get(&intent.utterance_id)
                    .copied()
                    .unwrap_or_else(support::now);
                self.write(json_record(&[
                    ("event", "intent_committed".into()),
                    ("at", number(committed_at)),
                    ("play_request_id", timing.play_request_id.clone().into()),
                    ("utterance_id", intent.utterance_id.clone().into()),
                    ("relay_command_seq", opt_int(intent.command_seq)),
                    ("relay_command_id", opt_text(intent.command_id.as_deref())),
                    (
                        "option_to_intent_commit_ms",
                        duration_ms(timing.option_detected_at, Some(committed_at)),
                    ),
                ]));
                st.utterance_timings
                    .insert(intent.utterance_id.clone(), timing);
                if st.utterance_timings.len() > 64 {
                    st.utterance_timings.pop_oldest();
                }
            }
            true
        };
        if should_play {
            self.worker.play();
        }
    }

    fn fresh(&self, st: &State, intent: &Arc<SpeechIntent>) -> bool {
        if intent.expired() {
            return false;
        }
        // An explicit replay is user-requested, so an older command is fine.
        if intent.freshness_scope == "work" || intent.replay_of.is_some() {
            return true;
        }
        // RR-464: an accepted reply stays queued after newer commands.
        if is_queued_reply_kind(&intent.kind)
            && st
                .intents
                .get(&intent.utterance_id)
                .is_some_and(|stored| Arc::ptr_eq(stored, intent))
        {
            return true;
        }
        let Some((seq, id)) = intent.command_key() else {
            return true;
        };
        if (self.is_current)(seq, &id) {
            return true;
        }
        intent.authoritative
            && is_final_kind(&intent.kind)
            && self.is_preserved.as_ref().is_some_and(|is_preserved| {
                is_preserved(
                    seq,
                    &id,
                    intent.work_disposition.as_ref().unwrap_or(&Json::new()),
                )
            })
    }

    /// Commit the queue head when nothing is playing, waiting, or held.
    fn advance_locked(&self, st: &mut State) -> Option<Arc<SpeechIntent>> {
        if st.committed_id.is_some() || st.playing_id.is_some() || st.speech_stopped {
            return None;
        }
        let next = self.next_eligible_locked(st)?;
        commit_locked(st, &next);
        Some(next)
    }

    fn next_eligible_locked(&self, st: &mut State) -> Option<Arc<SpeechIntent>> {
        while !st.backlog.is_empty() {
            let candidate = st.backlog.remove(0);
            if self.fresh(st, &candidate) {
                return Some(candidate);
            }
            self.diagnostic("expired", &candidate, &[]);
        }
        None
    }

    fn drop_obsolete_backlog(&self, st: &mut State, incoming: &SpeechIntent) {
        if !is_superseding_kind(&incoming.kind) {
            return;
        }
        let key = incoming.command_key();
        let mut kept = Vec::new();
        for queued in std::mem::take(&mut st.backlog) {
            let obsolete = (key.is_some()
                && queued.command_key() == key
                && matches!(queued.kind.as_str(), "handoff" | "progress"))
                || replaces_fallback(incoming, &queued);
            if obsolete {
                self.diagnostic(
                    "replaced",
                    &queued,
                    &[("replaced_by", incoming.utterance_id.clone().into())],
                );
            } else {
                kept.push(queued);
            }
        }
        st.backlog = kept;
    }

    fn diagnostic(&self, event: &str, intent: &SpeechIntent, fields: &[(&str, Value)]) {
        if !self.log.enabled() {
            return;
        }
        let mut record = json_record(&[
            ("event", event.into()),
            ("at", number(support::now())),
            ("utterance_id", intent.utterance_id.clone().into()),
            ("dedup_key", intent.dedup_key.clone().into()),
            ("relay_command_seq", opt_int(intent.command_seq)),
            ("relay_command_id", opt_text(intent.command_id.as_deref())),
            ("source", intent.source.clone().into()),
            ("kind", intent.kind.clone().into()),
            ("authoritative", intent.authoritative.into()),
            ("replayable", intent.replayable.into()),
            ("freshness_scope", intent.freshness_scope.clone().into()),
            (
                "replacement_policy",
                intent.replacement_policy.clone().into(),
            ),
            (
                "original_utterance_id",
                intent.original_utterance_id.clone().into(),
            ),
            ("replay_of", opt_text(intent.replay_of.as_deref())),
            ("presentation_mode", intent.presentation_mode().into()),
            ("lifecycle_role", intent.lifecycle_role.clone().into()),
            (
                "realization_decision",
                intent.realization_decision.clone().into(),
            ),
            (
                "suppression_reason",
                intent.suppression_reason.clone().into(),
            ),
        ]);
        for (key, value) in fields {
            record.insert((*key).to_string(), value.clone());
        }
        self.write(record);
    }

    fn write(&self, record: Json) {
        self.log.write(&record);
    }
}

fn json_record(fields: &[(&str, Value)]) -> Json {
    fields
        .iter()
        .map(|(key, value)| ((*key).to_string(), value.clone()))
        .collect()
}

fn intent_for(st: &State, id: Option<&str>) -> Option<Arc<SpeechIntent>> {
    id.and_then(|id| st.intents.get(id).cloned())
}

fn queue_depth(st: &State) -> usize {
    let heads = match (&st.playing_id, &st.committed_id) {
        (Some(playing), Some(committed)) if playing == committed => 1,
        (playing, committed) => usize::from(playing.is_some()) + usize::from(committed.is_some()),
    };
    heads + st.backlog.len() + st.remote_outstanding.len()
}

fn accept_locked(st: &mut State, intent: &Arc<SpeechIntent>) {
    st.accepted_keys.insert(intent.dedup_key.clone());
    if is_final_kind(&intent.kind)
        && let Some(key) = intent.command_key()
    {
        st.outcome_commands.insert(key);
        if st.outcome_commands.len() > 256 {
            st.outcome_commands.keep_newest(128);
        }
    }
    st.intents
        .insert(intent.utterance_id.clone(), intent.clone());
    if st.accepted_keys.len() > 512 {
        st.accepted_keys.keep_newest(256);
    }
}

fn arm_waiting_playback_locked(st: &mut State, target: CommandKey, kind: &str) {
    let armed = Some((target.clone(), kind.to_string()));
    let changed = st.waiting_preview != armed;
    st.waiting_preview = armed;
    if changed && let Some(timing) = st.play_timing.as_mut() {
        timing.command_seq = Some(target.0);
        timing.command_id = Some(target.1);
    }
    if let Some(dispatched) = intent_for(st, st.play_dispatched_id.as_deref())
        && !matches_waiting_preview(st, &dispatched)
    {
        st.play_dispatched_id = None;
    }
}

fn matches_waiting_preview(st: &State, intent: &SpeechIntent) -> bool {
    // RR-464: a queued reply plays in its turn whatever preview is armed.
    let Some((key, kind)) = &st.waiting_preview else {
        return true;
    };
    if is_queued_reply_kind(&intent.kind) {
        return true;
    }
    if intent.command_key().as_ref() != Some(key) {
        return false;
    }
    if is_final_kind(kind) {
        is_final_kind(&intent.kind)
    } else {
        intent.kind == *kind
    }
}

fn clear_play_request(st: &mut State, preserve_timing: bool) {
    st.waiting_preview = None;
    st.play_requested = false;
    st.play_dispatched_id = None;
    if !preserve_timing {
        st.play_timing = None;
    }
}

fn retain_replayable(st: &mut State, intent: &Arc<SpeechIntent>) -> bool {
    // Replay is user-requested, so it targets the last message even after a
    // newer command; only expiry and the replayable policy apply.
    if !intent.replayable || intent.expired() {
        return false;
    }
    st.replayable_history
        .retain(|retained| retained.utterance_id != intent.utterance_id);
    st.replayable_history.push(intent.clone());
    let excess = st
        .replayable_history
        .len()
        .saturating_sub(REPLAY_HISTORY_LIMIT);
    st.replayable_history.drain(..excess);
    true
}

fn append_backlog_locked(st: &mut State, intent: Arc<SpeechIntent>) {
    // An explicit replay is user-requested now, so it goes first.
    if intent.replay_of.is_some() {
        st.backlog.insert(0, intent);
    } else {
        st.backlog.push(intent);
    }
}

fn commit_locked(st: &mut State, intent: &Arc<SpeechIntent>) {
    st.committed_id = Some(intent.utterance_id.clone());
    st.intent_committed_at
        .insert(intent.utterance_id.clone(), support::now());
    if st.intent_committed_at.len() > 512 {
        st.intent_committed_at.pop_oldest();
    }
}

/// Mark an item skipped or replaced so its cancellation is final.
fn retire_locked(st: &mut State, intent: &SpeechIntent, reason: &str) {
    st.retired_ids
        .insert(intent.utterance_id.clone(), reason.to_string());
    if st.retired_ids.len() > 256 {
        st.retired_ids.pop_oldest();
    }
}

/// Return an unplayed item to the head of the queue (RR-464). The copy gets a
/// new utterance id so the notch never mistakes its next attempt for a late
/// event from the stopped one.
fn requeue_locked(st: &mut State, intent: &SpeechIntent) -> Arc<SpeechIntent> {
    let mut copy = intent.clone();
    copy.utterance_id = intent::support_uuid();
    let copy = Arc::new(copy);
    st.intents.insert(copy.utterance_id.clone(), copy.clone());
    st.backlog.insert(0, copy.clone());
    copy
}

fn record_played_coverage(st: &mut State, intent: &SpeechIntent) {
    let Some(key) = intent.command_key() else {
        return;
    };
    if intent.replacement_policy == "replay" {
        return;
    }
    let facts = if intent.covered_facts.is_empty() {
        vec![if intent.semantic_brief.is_empty() {
            intent.spoken_text.clone()
        } else {
            intent.semantic_brief.clone()
        }]
    } else {
        intent.covered_facts.clone()
    };
    let entry = Coverage {
        utterance_id: intent.utterance_id.clone(),
        lifecycle_role: intent.lifecycle_role.clone(),
        covered_facts: facts,
        spoken_text: intent.spoken_text.clone(),
    };
    if !st.played_coverage.contains(&key) {
        st.played_coverage.insert(key.clone(), Vec::new());
    }
    let coverage = st.played_coverage.get_mut(&key).expect("inserted above");
    if !coverage.iter().any(|item| {
        (&item.lifecycle_role, &item.covered_facts, &item.spoken_text)
            == (
                &entry.lifecycle_role,
                &entry.covered_facts,
                &entry.spoken_text,
            )
    }) {
        coverage.push(entry);
    }
    let excess = coverage.len().saturating_sub(8);
    coverage.drain(..excess);
    if st.played_coverage.len() > 64 {
        while st.played_coverage.len() > 32 {
            st.played_coverage.pop_oldest();
        }
    }
}

fn cancel_remote_voices_locked(st: &mut State, device_id: &str, before: Option<i64>) {
    let keys: Vec<RemoteKey> = st
        .remote_voices
        .keys()
        .filter(|key| key.0 == device_id && before.is_none_or(|before| key.1 < before))
        .cloned()
        .collect();
    for key in keys {
        if let Some(voice) = st.remote_voices.remove(&key) {
            voice.cancelled.store(true, Ordering::SeqCst);
        }
    }
}

fn newer_command(incoming: &SpeechIntent, current: &SpeechIntent) -> bool {
    match (incoming.command_seq, current.command_seq) {
        (Some(incoming), Some(current)) => incoming > current,
        _ => false,
    }
}

fn replaces_fallback(incoming: &SpeechIntent, current: &SpeechIntent) -> bool {
    incoming.kind == "final"
        && is_real_final_source(&incoming.source)
        && incoming.authoritative
        && current.is_fallback_outcome()
        && incoming.command_key().is_some()
        && incoming.command_key() == current.command_key()
}

/// A fallback never follows, or replaces, the command's real final.
fn final_already_accepted(st: &State, intent: &SpeechIntent) -> bool {
    intent.is_fallback_outcome()
        && intent
            .command_key()
            .is_some_and(|(seq, id)| st.accepted_keys.contains(&format!("outcome:{seq}:{id}")))
}

/// RR-464: only the same command's handoff/progress gives way; a queued reply,
/// or another command's speech, keeps its place.
fn supersedes(incoming: &SpeechIntent, current: &SpeechIntent) -> bool {
    if incoming.command_key() != current.command_key() || is_queued_reply_kind(&current.kind) {
        return false;
    }
    if is_superseding_kind(&incoming.kind)
        && matches!(current.kind.as_str(), "handoff" | "progress")
    {
        return true;
    }
    incoming.priority > current.priority && current.kind != "handoff"
}

fn bind_control_socket(path: &PathBuf) -> std::io::Result<(UnixDatagram, u64)> {
    let _ = std::fs::remove_file(path);
    let socket = UnixDatagram::bind(path)?;
    let inode = std::fs::metadata(path)?.ino();
    socket.set_read_timeout(Some(Duration::from_millis(500)))?;
    Ok((socket, inode))
}

fn control_loop(
    socket: UnixDatagram,
    path: PathBuf,
    inode: u64,
    coordinator: Weak<SpeechCoordinator>,
    shutdown: Arc<AtomicBool>,
) {
    let mut buffer = [0u8; 256];
    while !shutdown.load(Ordering::SeqCst) {
        let Ok(size) = socket.recv(&mut buffer) else {
            continue;
        };
        let command = String::from_utf8_lossy(&buffer[..size])
            .trim()
            .to_lowercase();
        let Some(coordinator) = coordinator.upgrade() else {
            break;
        };
        match command.as_str() {
            "play" | "toggle" => coordinator.play(None, ""),
            "replay" => {
                coordinator.replay(None);
            }
            "skip" | "cancel" => coordinator.skip("user_stop"),
            "pause" | "stop" => coordinator.stop(),
            _ => {}
        }
    }
    drop(socket);
    // RR-480: a speech service that replaced this one, while this one was
    // still stopping, has bound the path again; leave it.
    if std::fs::metadata(&path).is_ok_and(|metadata| metadata.ino() == inode) {
        let _ = std::fs::remove_file(&path);
    }
}

#[cfg(test)]
#[path = "coordinator_tests.rs"]
mod tests;
