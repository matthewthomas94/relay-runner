//! Port of `services/speech_client.py` for the Rust bridge (RR-492): the
//! bridge's client for the speech service (RR-480), plus the two overlay
//! helpers the bridge takes from `services/tts_worker.py`.
//!
//! `SpeechServiceClient` starts the service, supervises it and offers the
//! surface the bridge used on the in-process `SpeechCoordinator`. Each call is
//! one request in docs/specs/speech-service-protocol.md, written as Python's
//! `json.dumps(..., separators=(",", ":"))` wrote it.

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use super::ports::{Speech, SpeechText};
use crate::json::{self, Dict, Value, py_eq, py_is_space};
use crate::remote::audio::{AUDIO_FORMAT, AudioPart, SAMPLE_RATE};
use crate::remote::protocol::FrameError;
use crate::remote::server::{DeviceSession, peer_uid};
use crate::support::{env_optional, env_or};

pub const PROTOCOL_VERSION: i64 = 1;
/// A crashed service is restarted this often before speech is given up on.
pub const MAX_RESTARTS: usize = 3;
pub const RESTART_WINDOW_SECONDS: f64 = 60.0;
const START_TIMEOUT_SECONDS: f64 = 300.0;
const REQUEST_TIMEOUT_SECONDS: f64 = 10.0;

/// `tts_worker.VOICE_STATE_SOCK` without `VOICE_STATE_SOCK` set. It is not
/// the bridge's own default, which follows `RELAY_BRIDGE_RUNTIME_DIR`.
const DEFAULT_VOICE_STATE_SOCK: &str = "/tmp/voice_state.sock";
/// `tts_worker.MAX_STATE_DATAGRAM_BYTES`: macOS refuses a Unix datagram over
/// `net.local.dgram.maxdgram` (2048 bytes by default).
const MAX_STATE_DATAGRAM_BYTES: usize = 2048;

/// `SpeechServiceError`: the service could not be started or did not answer
/// a request.
#[derive(Debug)]
pub struct SpeechServiceError(pub String);

impl SpeechServiceError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for SpeechServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for SpeechServiceError {}

/// A Relay Remote device session as the service's calls reach it: what
/// `_answer` calls on `DeviceSession`, so a case can stand in a fake.
pub trait RemoteDevice: Send + Sync {
    fn device_id(&self) -> &str;
    fn routable(&self) -> bool;
    fn speech(
        &self,
        kind: &str,
        source: &str,
        text: &str,
        relay_command_seq: Option<i64>,
        spoken_by: Option<&str>,
        audio: Option<bool>,
    ) -> Result<i64, FrameError>;
    fn speech_control(&self, action: &str, reason: &str) -> Result<i64, FrameError>;
    fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), FrameError>;
}

impl RemoteDevice for DeviceSession {
    fn device_id(&self) -> &str {
        &self.device_id
    }

    fn routable(&self) -> bool {
        DeviceSession::routable(self)
    }

    fn speech(
        &self,
        kind: &str,
        source: &str,
        text: &str,
        relay_command_seq: Option<i64>,
        spoken_by: Option<&str>,
        audio: Option<bool>,
    ) -> Result<i64, FrameError> {
        DeviceSession::speech(
            self,
            kind,
            source,
            text,
            relay_command_seq,
            spoken_by,
            audio,
        )
    }

    fn speech_control(&self, action: &str, reason: &str) -> Result<i64, FrameError> {
        DeviceSession::speech_control(self, action, reason)
    }

    fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), FrameError> {
        DeviceSession::speech_audio(self, seq, part)
    }
}

/// `on_reply_finished(reason)`.
pub type OnReplyFinished = Box<dyn Fn(&str) + Send + Sync>;
/// `on_restart()`.
pub type OnRestart = Box<dyn Fn() + Send + Sync>;

type Devices = Vec<(String, Arc<dyn RemoteDevice>)>;

/// `_Pending`: a request waiting for its response.
struct Pending {
    op: String,
    params: Dict,
    message: Option<Dict>,
    answered: bool,
}

#[derive(Default)]
struct State {
    instance_id: String,
    /// `_ready`: the service said hello and was given what it must restore.
    ready: bool,
    closing: bool,
    failed: bool,
    restarts: Vec<Instant>,
    /// `_ids`: the last request id used.
    next_id: i64,
    pending: HashMap<i64, Pending>,
    /// Replies the service holds, so a restarted service can be given them
    /// again: original utterance id -> its `speak` request, in queue order.
    queued: Vec<String>,
    held: Vec<(String, Dict)>,
    /// What a service that stopped unexpectedly was still holding.
    lost: Vec<Dict>,
    /// Relay Remote devices as the coordinator knows them, for its calls,
    /// keyed by device id in Python's dict order.
    remote_sinks: Devices,
    remote_mirrors: Devices,
}

/// `_write_lock` and what it guards.
#[derive(Default)]
struct Wire {
    sock: Option<UnixStream>,
    generation: u64,
}

struct Inner {
    command: Vec<String>,
    socket_path: String,
    env: Vec<(String, String)>,
    on_reply_finished: OnReplyFinished,
    on_restart: OnRestart,
    start_timeout: f64,
    request_timeout: f64,
    process: Mutex<Option<Child>>,
    wire: Mutex<Wire>,
    state: Mutex<State>,
    /// Notified when `ready` is set or a pending request is answered.
    changed: Condvar,
    events: Sender<Option<Dict>>,
    calls: Sender<Option<Dict>>,
}

/// `SpeechServiceClient`. Dropping it closes the service, as `close` does.
pub struct SpeechServiceClient {
    inner: Arc<Inner>,
}

impl SpeechServiceClient {
    /// `SpeechServiceClient(command, socket_path, env=..., on_reply_finished=...,
    /// on_restart=...)`. `env` is added to this process's environment.
    pub fn new(
        command: Vec<String>,
        socket_path: &str,
        env: Vec<(String, String)>,
        on_reply_finished: OnReplyFinished,
        on_restart: OnRestart,
    ) -> Self {
        Self::with_timeouts(
            command,
            socket_path,
            env,
            on_reply_finished,
            on_restart,
            START_TIMEOUT_SECONDS,
            REQUEST_TIMEOUT_SECONDS,
        )
    }

    /// `new` with Python's `start_timeout` and `request_timeout`, in seconds.
    pub fn with_timeouts(
        command: Vec<String>,
        socket_path: &str,
        env: Vec<(String, String)>,
        on_reply_finished: OnReplyFinished,
        on_restart: OnRestart,
        start_timeout: f64,
        request_timeout: f64,
    ) -> Self {
        let (events, event_queue) = mpsc::channel();
        let (calls, call_queue) = mpsc::channel();
        let inner = Arc::new(Inner {
            command,
            socket_path: socket_path.to_string(),
            env,
            on_reply_finished,
            on_restart,
            start_timeout,
            request_timeout,
            process: Mutex::new(None),
            wire: Mutex::new(Wire::default()),
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            events,
            calls,
        });
        let events_inner = Arc::clone(&inner);
        spawn("speech-client-events", move || {
            events_inner.event_loop(event_queue)
        });
        let calls_inner = Arc::clone(&inner);
        spawn("speech-client-calls", move || {
            calls_inner.call_loop(call_queue)
        });
        Self { inner }
    }

    /// `start`: start the service and wait until it has loaded its voice.
    pub fn start(&self) -> Result<(), SpeechServiceError> {
        self.inner.launch(false).inspect_err(|_| self.inner.close())
    }

    /// `instance_id`: the running service's, from its `hello`.
    #[cfg(test)]
    pub fn instance_id(&self) -> String {
        self.inner.lock().instance_id.clone()
    }

    /// `speaking`.
    #[cfg(test)]
    pub fn speaking(&self) -> bool {
        self.status_flag("speaking")
    }

    /// `play`.
    #[cfg(test)]
    pub fn play(&self) {
        self.inner.request("play", Dict::new());
    }

    /// `arm_waiting_playback` (`_InputQueue.arm_waiting_playback`).
    #[cfg(test)]
    pub fn arm_waiting_playback(&self, command_seq: i64, command_id: &str, kind: &str) {
        self.inner.request(
            "arm_waiting_playback",
            params([
                ("command_seq", command_seq.into()),
                ("command_id", command_id.into()),
                ("kind", kind.into()),
            ]),
        );
    }

    fn status_flag(&self, name: &str) -> bool {
        truthy(&self.inner.request("status", Dict::new()), name)
    }
}

impl Drop for SpeechServiceClient {
    fn drop(&mut self) {
        self.inner.close();
    }
}

impl Speech for SpeechServiceClient {
    /// `_InputQueue.submit_text`: every field that is not `None`, in the
    /// order `_queue_tts_text` passes them.
    fn submit_text(&self, request: SpeechText) -> bool {
        truthy(
            &self.inner.request("speak", speak_params(request)),
            "accepted",
        )
    }

    fn stop_playback(&self, reason: &str) {
        self.inner
            .request("stop_playback", params([("reason", reason.into())]));
    }

    fn skip(&self, reason: &str) {
        self.inner
            .request("skip", params([("reason", reason.into())]));
    }

    fn playing(&self) -> bool {
        self.status_flag("playing")
    }

    fn play_or_replay(&self) -> bool {
        truthy(
            &self.inner.request("play_or_replay", Dict::new()),
            "handled",
        )
    }

    fn note_play_control(&self, option_detected_at: Option<f64>, fifo_received_at: f64) {
        self.inner.request(
            "note_play_control",
            params([
                ("option_detected_at", option_detected_at.into()),
                ("fifo_received_at", fifo_received_at.into()),
            ]),
        );
    }

    fn note_visual_acknowledgement(&self, option_detected_at: f64, acknowledged_at: f64) {
        self.inner.request(
            "note_visual_acknowledgement",
            params([
                ("option_detected_at", option_detected_at.into()),
                ("acknowledged_at", acknowledged_at.into()),
            ]),
        );
    }

    fn replay(&self) -> bool {
        truthy(&self.inner.request("replay", Dict::new()), "accepted")
    }

    fn new_turn(&self, command_seq: i64, command_id: &str) {
        self.inner.request(
            "new_turn",
            params([
                ("command_seq", command_seq.into()),
                ("command_id", command_id.into()),
            ]),
        );
    }

    fn reload_config(&self) {
        self.inner.request("reload_config", Dict::new());
    }

    fn control_session(&self, session_key: &str, action: &str, waiting_session_key: &str) -> bool {
        let result = self.inner.request(
            "control_session",
            params([
                ("session_key", session_key.into()),
                ("action", action.into()),
                ("waiting_session_key", waiting_session_key.into()),
            ]),
        );
        truthy(&result, "handled")
    }

    fn session_playback_states(&self, waiting_session_key: &str) -> Dict {
        let result = self.inner.request(
            "session_playback_states",
            params([("waiting_session_key", waiting_session_key.into())]),
        );
        match result.get("states") {
            Some(Value::Dict(states)) => states.clone(),
            _ => Dict::new(),
        }
    }

    /// `queue_depth`: `int(... or 0)`; a depth that is not a number is 0.
    fn queue_depth(&self) -> i64 {
        self.inner
            .request("status", Dict::new())
            .truthy("queue_depth")
            .and_then(Value::py_int)
            .unwrap_or(0)
    }

    fn record_messenger_stage(
        &self,
        stage: &str,
        command_seq: i64,
        command_id: &str,
        at: Option<f64>,
        provider: Option<&str>,
        outcome: &str,
    ) {
        self.inner.request(
            "record_messenger_stage",
            params([
                ("stage", stage.into()),
                ("command_seq", command_seq.into()),
                ("command_id", command_id.into()),
                ("at", at.into()),
                ("provider", provider.into()),
                ("outcome", outcome.into()),
            ]),
        );
    }

    fn record_missing_outcome(
        &self,
        command_seq: i64,
        command_id: &str,
        reason: &str,
        signals: &[String],
    ) -> bool {
        let signals: Vec<Value> = signals
            .iter()
            .map(|signal| signal.as_str().into())
            .collect();
        let result = self.inner.request(
            "record_missing_outcome",
            params([
                ("command_seq", command_seq.into()),
                ("command_id", command_id.into()),
                ("reason", reason.into()),
                ("signals", signals.into()),
            ]),
        );
        truthy(&result, "recorded")
    }

    /// `shutdown`: ask the service to exit, then make sure it has.
    fn shutdown(&self) {
        self.inner.shutdown();
    }

    fn played_coverage(&self, command_seq: i64, command_id: &str) -> Vec<Dict> {
        let result = self.inner.request(
            "played_coverage",
            params([
                ("command_seq", command_seq.into()),
                ("command_id", command_id.into()),
            ]),
        );
        result
            .get("coverage")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .cloned()
            .collect()
    }

    fn record_realization(
        &self,
        command_seq: i64,
        command_id: &str,
        lifecycle_role: &str,
        decision: &str,
        reason: &str,
    ) {
        self.inner.request(
            "record_realization",
            params([
                ("command_seq", command_seq.into()),
                ("command_id", command_id.into()),
                ("lifecycle_role", lifecycle_role.into()),
                ("decision", decision.into()),
                ("reason", reason.into()),
            ]),
        );
    }

    // A device is known here for as long as the service may call on it.

    fn attach_remote_sink(&self, sink: Arc<dyn RemoteDevice>) {
        let device_id = sink.device_id().to_string();
        {
            // Newest last, as the coordinator keeps them.
            let mut state = self.inner.lock();
            remove_device(&mut state.remote_sinks, &device_id);
            state.remote_sinks.push((device_id.clone(), sink));
        }
        self.inner.request(
            "remote_attach",
            params([
                ("device_id", device_id.as_str().into()),
                ("role", "sink".into()),
            ]),
        );
        remove_device(&mut self.inner.lock().remote_mirrors, &device_id);
    }

    fn detach_remote_sink(&self, device_id: &str, reason: &str) {
        self.inner.request(
            "remote_detach",
            params([
                ("device_id", device_id.into()),
                ("role", "sink".into()),
                ("reason", reason.into()),
            ]),
        );
        remove_device(&mut self.inner.lock().remote_sinks, device_id);
    }

    fn attach_remote_mirror(&self, sink: Arc<dyn RemoteDevice>) {
        let device_id = sink.device_id().to_string();
        {
            // `self._remote_mirrors[id] = sink`: a known device keeps its place.
            let mut state = self.inner.lock();
            match state
                .remote_mirrors
                .iter_mut()
                .find(|(known, _)| *known == device_id)
            {
                Some(entry) => entry.1 = sink,
                None => state.remote_mirrors.push((device_id.clone(), sink)),
            }
        }
        self.inner.request(
            "remote_attach",
            params([
                ("device_id", device_id.as_str().into()),
                ("role", "mirror".into()),
            ]),
        );
    }

    fn detach_remote_mirror(&self, device_id: &str) {
        self.inner.request(
            "remote_detach",
            params([("device_id", device_id.into()), ("role", "mirror".into())]),
        );
        remove_device(&mut self.inner.lock().remote_mirrors, device_id);
    }

    fn remote_ack(&self, device_id: &str, seq: i64, played: bool) -> bool {
        let result = self.inner.request(
            "remote_ack",
            params([
                ("device_id", device_id.into()),
                ("seq", seq.into()),
                ("played", played.into()),
            ]),
        );
        truthy(&result, "known")
    }
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }

    // -- Lifecycle ---------------------------------------------------------

    /// `close`.
    fn close(&self) {
        {
            let mut state = self.lock();
            state.closing = true;
            state.ready = false;
        }
        self.disconnect();
        self.stop_process(0.0);
        let _ = self.events.send(None);
        let _ = self.calls.send(None);
    }

    /// `shutdown`.
    fn shutdown(&self) {
        let ready = {
            let mut state = self.lock();
            state.closing = true;
            state.ready
        };
        if ready {
            let _ = self.roundtrip("shutdown", Dict::new(), Some(5.0), true);
        }
        self.lock().ready = false;
        self.stop_process(3.0);
        self.disconnect();
        let _ = self.events.send(None);
        let _ = self.calls.send(None);
    }

    /// `_launch`.
    fn launch(self: &Arc<Self>, restore: bool) -> Result<(), SpeechServiceError> {
        // A leftover path could belong to a service this bridge did not start.
        let _ = fs::remove_file(&self.socket_path);
        let mut argv = self.command.clone();
        argv.push("--socket".to_string());
        argv.push(self.socket_path.clone());
        let child = Command::new(&argv[0])
            .args(&argv[1..])
            .envs(self.env.iter().map(|(name, value)| (name, value)))
            .stdin(Stdio::null())
            .spawn()
            .map_err(|error| {
                SpeechServiceError::new(format!("could not start the speech service: {error}"))
            })?;
        *self.process.lock().unwrap() = Some(child);
        let deadline = Instant::now() + seconds(self.start_timeout);
        let sock = loop {
            if let Some(status) = self.exit_status() {
                return Err(SpeechServiceError::new(status));
            }
            if Instant::now() >= deadline {
                return Err(SpeechServiceError::new(
                    "speech service did not open its socket",
                ));
            }
            match UnixStream::connect(&self.socket_path) {
                Ok(sock) => break sock,
                Err(_) => thread::sleep(Duration::from_millis(20)),
            }
        };
        // Replies are sent over this socket: only this user's service may read them.
        if peer_uid(&sock).ok() != Some(unsafe { libc::getuid() }) {
            return Err(SpeechServiceError::new(
                "speech service socket belongs to another user",
            ));
        }
        let reader = sock
            .try_clone()
            .map_err(|_| SpeechServiceError::new("speech service connection lost"))?;
        let generation = {
            let mut wire = self.wire.lock().unwrap();
            wire.generation += 1;
            wire.sock = Some(sock);
            wire.generation
        };
        {
            let mut state = self.lock();
            state.queued.clear();
            state.held.clear();
        }
        let read_inner = Arc::clone(self);
        spawn("speech-client-read", move || {
            read_inner.read_loop(reader, generation)
        });
        let remaining = deadline
            .saturating_duration_since(Instant::now())
            .as_secs_f64();
        let hello = self.roundtrip(
            "hello",
            params([
                ("protocol", PROTOCOL_VERSION.into()),
                ("client", "voice_bridge".into()),
                ("pid", i64::from(std::process::id()).into()),
            ]),
            Some(remaining.max(1.0)),
            false,
        )?;
        if !hello
            .get("protocol")
            .is_some_and(|protocol| py_eq(protocol, &Value::Int(PROTOCOL_VERSION)))
        {
            return Err(SpeechServiceError::new(
                "speech service speaks another protocol version",
            ));
        }
        self.lock().instance_id = hello.string("instance_id");
        if restore {
            self.restore()?;
        }
        self.lock().ready = true;
        self.changed.notify_all();
        Ok(())
    }

    /// `process.poll()` while waiting for the socket: why the service ended.
    fn exit_status(&self) -> Option<String> {
        let mut process = self.process.lock().unwrap();
        let Some(child) = process.as_mut() else {
            // `close` took it to stop it.
            return Some("speech service was stopped".to_string());
        };
        match child.try_wait() {
            Ok(Some(status)) => Some(format!(
                "speech service exited with status {}",
                returncode(status)
            )),
            _ => None,
        }
    }

    /// `_restore`: give a restarted service the devices and the replies the
    /// old one held.
    fn restore(&self) -> Result<(), SpeechServiceError> {
        (self.on_restart)();
        for role in ["sink", "mirror"] {
            let devices: Vec<String> = {
                let state = self.lock();
                let devices = if role == "sink" {
                    &state.remote_sinks
                } else {
                    &state.remote_mirrors
                };
                devices
                    .iter()
                    .map(|(device_id, _)| device_id.clone())
                    .collect()
            };
            for device_id in devices {
                self.roundtrip(
                    "remote_attach",
                    params([("device_id", device_id.into()), ("role", role.into())]),
                    None,
                    false,
                )?;
            }
        }
        let lost = self.lock().lost.clone();
        for request in &lost {
            self.roundtrip("speak", request.clone(), None, false)?;
        }
        if !lost.is_empty() {
            eprintln!("[speech_client] Resubmitted {} queued replies.", lost.len());
        }
        self.lock().lost.clear();
        Ok(())
    }

    /// `_restart`.
    fn restart(self: &Arc<Self>) {
        loop {
            {
                let mut state = self.lock();
                if state.closing {
                    return;
                }
                let now = Instant::now();
                state
                    .restarts
                    .retain(|at| now.duration_since(*at).as_secs_f64() < RESTART_WINDOW_SECONDS);
                if state.restarts.len() >= MAX_RESTARTS {
                    state.failed = true;
                    eprintln!("[speech_client] Speech service keeps failing; speech is off.");
                    return;
                }
                state.restarts.push(now);
            }
            self.stop_process(0.0);
            match self.launch(true) {
                Ok(()) => {
                    eprintln!("[speech_client] Speech service restarted.");
                    return;
                }
                Err(error) => {
                    eprintln!("[speech_client] Speech service restart failed: {error}");
                    self.disconnect();
                }
            }
        }
    }

    /// `_stop_process`: wait `grace` seconds for it to exit, then terminate
    /// it, then kill it.
    fn stop_process(&self, grace: f64) {
        let Some(mut child) = self.process.lock().unwrap().take() else {
            return;
        };
        if exited_within(&mut child, grace) {
            return;
        }
        // The child has not been reaped, so its pid is still its own.
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
        }
        if exited_within(&mut child, 2.0) {
            return;
        }
        let _ = child.kill();
        let _ = child.wait();
    }

    /// `_disconnect`.
    fn disconnect(&self) {
        let sock = self.wire.lock().unwrap().sock.take();
        if let Some(sock) = sock {
            let _ = sock.shutdown(Shutdown::Both);
        }
    }

    // -- Wire --------------------------------------------------------------

    /// `_send`: one compact JSON line.
    fn send(&self, message: Dict) -> Result<(), SpeechServiceError> {
        let mut data = json::dumps_compact(&Value::Dict(message));
        data.push('\n');
        let wire = self.wire.lock().unwrap();
        let mut sock = wire
            .sock
            .as_ref()
            .ok_or_else(|| SpeechServiceError::new("speech service is not connected"))?;
        sock.write_all(data.as_bytes())
            .map_err(|_| SpeechServiceError::new("speech service connection lost"))
    }

    /// `_roundtrip`: one request and its result. `timeout` defaults to the
    /// request timeout; without `wait_ready` it does not wait for `hello`.
    fn roundtrip(
        &self,
        op: &str,
        params: Dict,
        timeout: Option<f64>,
        wait_ready: bool,
    ) -> Result<Dict, SpeechServiceError> {
        let timeout = timeout.unwrap_or(self.request_timeout);
        let mut state = self.lock();
        if wait_ready {
            let wait = if state.failed || state.closing {
                0.0
            } else {
                timeout
            };
            state = self
                .changed
                .wait_timeout_while(state, seconds(wait), |state| !state.ready)
                .unwrap()
                .0;
            if !state.ready {
                return Err(SpeechServiceError::new("speech service is unavailable"));
            }
        }
        state.next_id += 1;
        let request_id = state.next_id;
        let mut message = Dict::new();
        message.insert("id", request_id);
        message.insert("op", op);
        message.update(&params);
        state.pending.insert(
            request_id,
            Pending {
                op: op.to_string(),
                params,
                message: None,
                answered: false,
            },
        );
        drop(state);
        let sent = self.send(message);
        let mut state = self.lock();
        if sent.is_ok() {
            state = self
                .changed
                .wait_timeout_while(state, seconds(timeout), |state| {
                    state
                        .pending
                        .get(&request_id)
                        .is_some_and(|pending| !pending.answered)
                })
                .unwrap()
                .0;
        }
        let pending = state.pending.remove(&request_id);
        drop(state);
        sent?;
        let pending = pending.filter(|pending| pending.answered).ok_or_else(|| {
            SpeechServiceError::new(format!("speech service did not answer {op}"))
        })?;
        let message = pending.message.unwrap_or_default();
        if !truthy(&message, "ok") {
            let code = match message.get("error") {
                Some(Value::Dict(error)) => {
                    error.get("code").map_or("None".to_string(), Value::py_str)
                }
                _ => "connection_lost".to_string(),
            };
            return Err(SpeechServiceError::new(format!(
                "speech service refused {op}: {code}"
            )));
        }
        match message.get("result") {
            Some(Value::Dict(result)) => Ok(result.clone()),
            _ => Ok(Dict::new()),
        }
    }

    /// `_request`: one request; a service that cannot answer counts as an
    /// empty result.
    fn request(&self, op: &str, params: Dict) -> Dict {
        match self.roundtrip(op, params, None, true) {
            Ok(result) => result,
            Err(error) => {
                let quiet = {
                    let state = self.lock();
                    state.failed || state.closing
                };
                if !quiet {
                    eprintln!("[speech_client] {error}");
                }
                Dict::new()
            }
        }
    }

    /// `_read_loop`: one connection's lines until it ends.
    fn read_loop(self: Arc<Self>, sock: UnixStream, generation: u64) {
        let mut reader = BufReader::new(sock);
        let mut line = Vec::new();
        loop {
            line.clear();
            match reader.read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let Some(Value::Dict(message)) = json::parse_bytes(&line) else {
                continue;
            };
            if message.get("call").is_some() {
                let _ = self.calls.send(Some(message));
            } else if let Some(event) = message.get("event") {
                if event.is_str("state") {
                    self.note_state(&message);
                }
                let _ = self.events.send(Some(message));
            } else if message.get("id").is_some() {
                self.resolve(message);
            }
        }
        self.connection_lost(generation);
    }

    /// `_resolve`.
    fn resolve(&self, message: Dict) {
        let Some(Value::Int(request_id)) = message.get("id") else {
            return;
        };
        let request_id = *request_id;
        let mut guard = self.lock();
        let State {
            pending,
            queued,
            held,
            ..
        } = &mut *guard;
        let Some(pending) = pending.get_mut(&request_id) else {
            return;
        };
        if pending.op == "speak"
            && truthy(&message, "ok")
            && let Some(Value::Dict(result)) = message.get("result")
        {
            let utterance_id = result.string("utterance_id");
            // The state that lists it was sent before this response.
            if truthy(result, "accepted") && queued.contains(&utterance_id) {
                match held.iter_mut().find(|(known, _)| *known == utterance_id) {
                    Some(entry) => entry.1 = pending.params.clone(),
                    None => held.push((utterance_id, pending.params.clone())),
                }
            }
        }
        pending.message = Some(message);
        pending.answered = true;
        drop(guard);
        self.changed.notify_all();
    }

    /// `_note_state`.
    fn note_state(&self, event: &Dict) {
        let queued: Vec<String> = event
            .get("queue")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .map(|item| item.string("original_utterance_id"))
            .collect();
        let mut state = self.lock();
        // Keep what is still queued, in the order it would play.
        let mut held: Vec<(String, Dict)> = Vec::new();
        for key in &queued {
            if held.iter().any(|(known, _)| known == key) {
                continue;
            }
            if let Some(entry) = state.held.iter().find(|(known, _)| known == key) {
                held.push(entry.clone());
            }
        }
        state.held = held;
        state.queued = queued;
    }

    /// `_connection_lost`.
    fn connection_lost(self: &Arc<Self>, generation: u64) {
        let sock = {
            let mut wire = self.wire.lock().unwrap();
            if generation != wire.generation {
                return;
            }
            wire.sock.take()
        };
        drop(sock);
        let mut state = self.lock();
        let was_ready = state.ready;
        state.ready = false;
        for pending in state.pending.values_mut() {
            pending.answered = true;
        }
        self.changed.notify_all();
        if state.closing || !was_ready {
            return;
        }
        state.lost = state
            .held
            .iter()
            .map(|(_, request)| request.clone())
            .collect();
        drop(state);
        eprintln!("[speech_client] Speech service stopped unexpectedly; restarting it.");
        let restart_inner = Arc::clone(self);
        spawn("speech-client-restart", move || restart_inner.restart());
    }

    /// `_event_loop`.
    fn event_loop(&self, events: Receiver<Option<Dict>>) {
        while let Ok(Some(event)) = events.recv() {
            let Some(name) = event.get("event") else {
                continue;
            };
            if name.is_str("reply_finished") {
                let reason = event.string("reason");
                (self.on_reply_finished)(if reason.is_empty() {
                    "completed"
                } else {
                    reason.as_str()
                });
            } else if name.is_str("error") {
                let code = event.get("code").map_or("None".to_string(), Value::py_str);
                eprintln!("[speech_client] Speech service error: {code}");
            }
        }
    }

    /// `_call_loop`: answer the service's calls on Relay Remote devices, one
    /// at a time.
    fn call_loop(&self, calls: Receiver<Option<Dict>>) {
        while let Ok(Some(call)) = calls.recv() {
            let mut reply = Dict::new();
            reply.insert("reply", call.get("call").cloned().unwrap_or(Value::Null));
            reply.insert("ok", true);
            match self.answer(&call) {
                Ok(result) => reply.insert("result", result),
                Err(exception) => {
                    let mut error = Dict::new();
                    error.insert("code", "call_failed");
                    error.insert("message", exception);
                    reply.insert("ok", false);
                    reply.insert("error", error);
                }
            }
            let _ = self.send(reply);
        }
    }

    /// `_answer`: one call's result, or the name of the exception Python
    /// raised for it (the `message` of the failed reply).
    fn answer(&self, call: &Dict) -> Result<Dict, &'static str> {
        let device_id = call.string("device_id");
        let device = {
            let state = self.lock();
            let devices = if call.get("role").is_some_and(|role| role.is_str("mirror")) {
                &state.remote_mirrors
            } else {
                &state.remote_sinks
            };
            devices
                .iter()
                .find(|(known, _)| *known == device_id)
                .map(|(_, device)| Arc::clone(device))
        }
        .ok_or("KeyError")?;
        let mut result = Dict::new();
        match call.get("op").and_then(Value::as_str).unwrap_or_default() {
            "remote_routable" => result.insert("routable", device.routable()),
            "remote_speech" => {
                // `device.speech(**frame)`: four keyword arguments are
                // required, and the frame encoder checks their types.
                let required = |name| call.get(name).ok_or("TypeError");
                let text_of =
                    |value: &Value| value.as_str().map(str::to_string).ok_or("FrameError");
                let kind = text_of(required("kind")?)?;
                let source = text_of(required("source")?)?;
                let text = text_of(required("text")?)?;
                let relay_command_seq = match required("relay_command_seq")? {
                    Value::Null => None,
                    Value::Int(seq) => Some(*seq),
                    _ => return Err("FrameError"),
                };
                let spoken_by = match call.get("spoken_by") {
                    None => Some("phone"),
                    Some(Value::Null) => None,
                    Some(Value::Str(spoken_by)) => Some(spoken_by.as_str()),
                    Some(_) => return Err("FrameError"),
                };
                let audio = match call.get("audio") {
                    None | Some(Value::Null) => None,
                    Some(Value::Bool(audio)) => Some(*audio),
                    Some(_) => return Err("FrameError"),
                };
                let seq = device
                    .speech(&kind, &source, &text, relay_command_seq, spoken_by, audio)
                    .map_err(|_| "FrameError")?;
                result.insert("seq", seq);
            }
            "remote_speech_control" => {
                let action = call.get("action").map_or("None".to_string(), Value::py_str);
                let reason = call.get("reason").map_or("None".to_string(), Value::py_str);
                let seq = device
                    .speech_control(&action, &reason)
                    .map_err(|_| "FrameError")?;
                result.insert("seq", seq);
            }
            "remote_speech_audio" => {
                let seq = python_int(call.get("seq"))?;
                let part = AudioPart {
                    part: python_int(call.get("part"))?,
                    parts: python_int(call.get("parts"))?,
                    last: truthy(call, "last"),
                    data: call.string("data"),
                    format: call
                        .truthy("format")
                        .map_or(AUDIO_FORMAT.to_string(), Value::py_str),
                    sample_rate: match call.truthy("sample_rate") {
                        Some(rate) => python_int(Some(rate))?,
                        None => SAMPLE_RATE,
                    },
                };
                device.speech_audio(seq, &part).map_err(|_| "FrameError")?;
            }
            _ => return Err("ValueError"),
        }
        Ok(result)
    }
}

/// The `speak` request of `_InputQueue.submit_text`.
fn speak_params(request: SpeechText) -> Dict {
    let covered_facts = request
        .covered_facts
        .map(|facts| Value::List(facts.into_iter().map(Value::from).collect()));
    let fields: [(&str, Option<Value>); 19] = [
        ("text", Some(request.text.into())),
        ("display_text", Some(request.display_text.into())),
        ("semantic_brief", request.semantic_brief.map(Value::from)),
        ("command_seq", request.command_seq.map(Value::from)),
        ("command_id", request.command_id.map(Value::from)),
        ("source", Some(request.source.into())),
        ("kind", Some(request.kind.into())),
        ("authoritative", Some(request.authoritative.into())),
        ("priority", request.priority.map(Value::from)),
        ("dedup_key", request.dedup_key.map(Value::from)),
        (
            "work_disposition",
            request.work_disposition.map(Value::from),
        ),
        ("replayable", request.replayable.map(Value::from)),
        ("freshness_scope", Some(request.freshness_scope.into())),
        ("lifecycle_role", request.lifecycle_role.map(Value::from)),
        ("covered_facts", covered_facts),
        (
            "realization_decision",
            Some(request.realization_decision.into()),
        ),
        (
            "suppression_reason",
            request.suppression_reason.map(Value::from),
        ),
        ("session_key", Some(request.session_key.into())),
        (
            "waiting_playback_kind",
            request.waiting_playback_kind.map(Value::from),
        ),
    ];
    let mut params = Dict::new();
    for (name, value) in fields {
        if let Some(value) = value {
            params.insert(name, value);
        }
    }
    params
}

fn params<const N: usize>(fields: [(&str, Value); N]) -> Dict {
    let mut params = Dict::new();
    for (name, value) in fields {
        params.insert(name, value);
    }
    params
}

/// `bool(d.get(name))`.
fn truthy(dict: &Dict, name: &str) -> bool {
    dict.truthy(name).is_some()
}

/// `int(value)`, or the name of the exception Python raises.
fn python_int(value: Option<&Value>) -> Result<i64, &'static str> {
    let value = value.ok_or("KeyError")?;
    value.py_int().ok_or(match value {
        Value::Str(_) | Value::Float(_) => "ValueError",
        _ => "TypeError",
    })
}

fn remove_device(devices: &mut Devices, device_id: &str) {
    devices.retain(|(known, _)| known != device_id);
}

fn seconds(value: f64) -> Duration {
    Duration::from_secs_f64(value.max(0.0))
}

/// `Popen.returncode`: the exit code, or minus the signal that ended it.
fn returncode(status: ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| -status.signal().unwrap_or(0))
}

/// `process.wait(timeout=seconds)` without the exception: whether it exited.
fn exited_within(child: &mut Child, timeout: f64) -> bool {
    let deadline = Instant::now() + seconds(timeout);
    loop {
        if !matches!(child.try_wait(), Ok(None)) {
            return true;
        }
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        thread::sleep((deadline - now).min(Duration::from_millis(10)));
    }
}

fn spawn(name: &str, body: impl FnOnce() + Send + 'static) {
    if thread::Builder::new()
        .name(name.to_string())
        .spawn(body)
        .is_err()
    {
        eprintln!("[speech_client] Could not start the {name} thread");
    }
}

// -- tts_worker.py -----------------------------------------------------------

/// `tts_worker.publish_idle`: clear the overlay's speech state when the
/// worker that showed it is gone.
pub fn publish_idle() {
    notify_state("idle", None);
}

/// `tts_worker._notify_state`: one state datagram to the overlay; a missing
/// overlay is ignored.
fn notify_state(state: &str, text: Option<String>) {
    let data = state_datagram(&state_message(state, text));
    if let Ok(sock) = UnixDatagram::unbound() {
        let _ = sock.send_to(&data, env_or("VOICE_STATE_SOCK", DEFAULT_VOICE_STATE_SOCK));
    }
}

fn state_message(state: &str, text: Option<String>) -> Dict {
    let mut message = Dict::new();
    message.insert("source", "tts");
    message.insert("state", state);
    message.insert(
        "tutorial",
        env_optional("RELAY_TUTORIAL_TTS").as_deref() == Some("1"),
    );
    if let Some(text) = text {
        message.insert("text", text);
    }
    message
}

/// `tts_worker._state_datagram`: the update as `json.dumps` writes it, its
/// preview text shortened until the datagram fits.
fn state_datagram(message: &Dict) -> Vec<u8> {
    let mut data = json::dumps(&Value::Dict(message.clone()));
    let Some(Value::Str(text)) = message.get("text") else {
        return data.into_bytes();
    };
    let mut text: Vec<char> = text.chars().collect();
    while data.len() > MAX_STATE_DATAGRAM_BYTES && !text.is_empty() {
        // Every dropped character frees at least one encoded byte.
        let keep = text
            .len()
            .saturating_sub(data.len() - MAX_STATE_DATAGRAM_BYTES + 1);
        text.truncate(keep);
        while text.last().is_some_and(|character| py_is_space(*character)) {
            text.pop();
        }
        let mut shortened = message.clone();
        shortened.insert("text", format!("{}…", text.iter().collect::<String>()));
        data = json::dumps(&Value::Dict(shortened));
    }
    data.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::py_strip;
    use std::collections::VecDeque;
    use std::io::ErrorKind;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::thread::JoinHandle;

    fn wait_until(mut condition: impl FnMut() -> bool, message: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !condition() {
            assert!(Instant::now() < deadline, "timed out waiting for {message}");
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn object(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            _ => panic!("not a JSON object: {text}"),
        }
    }

    /// A request line without its `id`, which depends on what came before.
    fn without_id(line: &str) -> String {
        let mut message = object(line);
        message.remove("id");
        json::dumps_compact(&Value::Dict(message))
    }

    /// A folder under /tmp: a socket path holds at most 104 bytes on macOS.
    struct Folder(PathBuf);

    impl Folder {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = PathBuf::from(format!(
                "/tmp/rsc-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::SeqCst)
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self, name: &str) -> String {
            self.0.join(name).to_string_lossy().into_owned()
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// The service's process: it notes its pid, arguments and one variable
    /// of the extra environment in `launches`, then sleeps. `Fake` serves the
    /// socket for it.
    fn service_command(folder: &Folder) -> Vec<String> {
        vec![
            "/bin/sh".into(),
            "-c".into(),
            "echo \"$$ $1 $2 $RELAY_SPEECH_CLIENT_CASE\" >> \"$0\"; exec sleep 600".into(),
            folder.path("launches"),
        ]
    }

    #[derive(Default)]
    struct Observed {
        finished: Mutex<Vec<String>>,
        restarts: AtomicUsize,
    }

    fn client_for(
        folder: &Folder,
        command: Vec<String>,
        observed: &Arc<Observed>,
        start_timeout: f64,
    ) -> SpeechServiceClient {
        let finished = Arc::clone(observed);
        let restarted = Arc::clone(observed);
        SpeechServiceClient::with_timeouts(
            command,
            &folder.path("speech.sock"),
            vec![("RELAY_SPEECH_CLIENT_CASE".into(), "extra-env".into())],
            Box::new(move |reason| finished.finished.lock().unwrap().push(reason.to_string())),
            Box::new(move || {
                restarted.restarts.fetch_add(1, Ordering::SeqCst);
            }),
            start_timeout,
            5.0,
        )
    }

    #[derive(Default)]
    struct FakeState {
        /// Every line the client sent, with the launch it reached.
        lines: Vec<(usize, String)>,
        writer: Option<UnixStream>,
        pid: i32,
        queue: Vec<String>,
        sinks: Vec<String>,
        utterances: usize,
        calls: usize,
    }

    struct FakeShared {
        socket: String,
        launches: String,
        stop: AtomicBool,
        state: Mutex<FakeState>,
    }

    /// The speech service side of each connection, like the contract suite's
    /// fake: it answers in request order, sends `state` before the response
    /// that changed it, and calls a sink inside the `speak` it diverts.
    struct Fake {
        shared: Arc<FakeShared>,
        thread: Option<JoinHandle<()>>,
    }

    impl Fake {
        fn start(folder: &Folder) -> Self {
            let shared = Arc::new(FakeShared {
                socket: folder.path("speech.sock"),
                launches: folder.path("launches"),
                stop: AtomicBool::new(false),
                state: Mutex::new(FakeState::default()),
            });
            let serving = Arc::clone(&shared);
            let thread = thread::spawn(move || serving.serve());
            Self {
                shared,
                thread: Some(thread),
            }
        }

        fn lines(&self, launch: usize) -> Vec<String> {
            let state = self.shared.state.lock().unwrap();
            state
                .lines
                .iter()
                .filter(|(at, _)| *at == launch)
                .map(|(_, line)| line.clone())
                .collect()
        }

        fn ops(&self, launch: usize) -> Vec<String> {
            self.lines(launch)
                .iter()
                .map(|line| object(line).string("op"))
                .filter(|op| !op.is_empty())
                .collect()
        }

        fn line(&self, launch: usize, op: &str) -> String {
            self.lines(launch)
                .into_iter()
                .find(|line| object(line).get("op").is_some_and(|value| value.is_str(op)))
                .unwrap_or_else(|| panic!("no {op} request"))
        }

        fn send(&self, line: &str) {
            self.shared.write(line);
        }

        /// The head of the queue finished playing.
        fn finish(&self) {
            self.shared.state.lock().unwrap().queue.remove(0);
            self.shared.write_state();
        }

        /// Kill the process and end its connection, as a crash does.
        fn crash(&self) {
            let (writer, pid) = {
                let mut state = self.shared.state.lock().unwrap();
                (state.writer.take(), state.pid)
            };
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
            if let Some(writer) = writer {
                let _ = writer.shutdown(Shutdown::Both);
            }
        }
    }

    impl Drop for Fake {
        fn drop(&mut self) {
            self.shared.stop.store(true, Ordering::SeqCst);
            if let Some(writer) = self.shared.state.lock().unwrap().writer.take() {
                let _ = writer.shutdown(Shutdown::Both);
            }
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    impl FakeShared {
        fn serve(self: Arc<Self>) {
            for launch in 1.. {
                let Some(pid) = self.wait_for_launch(launch) else {
                    return;
                };
                let Some(stream) = self.accept() else {
                    return;
                };
                {
                    let mut state = self.state.lock().unwrap();
                    state.writer = stream.try_clone().ok();
                    state.pid = pid;
                    state.queue.clear();
                    state.sinks.clear();
                }
                let mut reader = BufReader::new(stream);
                let mut backlog = VecDeque::new();
                while let Some(message) = backlog
                    .pop_front()
                    .or_else(|| self.read(&mut reader, launch))
                {
                    if message.get("op").is_some()
                        && message.get("id").is_some()
                        && !self.handle(&message, launch, &mut reader, &mut backlog)
                    {
                        break;
                    }
                }
            }
        }

        /// The pid of the client's `launch`-th process, once it has started.
        fn wait_for_launch(&self, launch: usize) -> Option<i32> {
            loop {
                if self.stop.load(Ordering::SeqCst) {
                    return None;
                }
                let launches = fs::read_to_string(&self.launches).unwrap_or_default();
                if let Some(line) = launches.lines().nth(launch - 1) {
                    return line.split(' ').next()?.parse().ok();
                }
                thread::sleep(Duration::from_millis(5));
            }
        }

        fn accept(&self) -> Option<UnixStream> {
            let _ = fs::remove_file(&self.socket);
            let listener = UnixListener::bind(&self.socket).unwrap();
            listener.set_nonblocking(true).unwrap();
            let stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == ErrorKind::WouldBlock => {
                        if self.stop.load(Ordering::SeqCst) {
                            return None;
                        }
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("accept failed: {error}"),
                }
            };
            drop(listener);
            let _ = fs::remove_file(&self.socket);
            stream.set_nonblocking(false).unwrap();
            Some(stream)
        }

        fn read(&self, reader: &mut BufReader<UnixStream>, launch: usize) -> Option<Dict> {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => return None,
                Ok(_) => {}
            }
            let line = line.trim_end_matches('\n').to_string();
            self.state
                .lock()
                .unwrap()
                .lines
                .push((launch, line.clone()));
            Some(object(&line))
        }

        fn write(&self, line: &str) {
            let state = self.state.lock().unwrap();
            if let Some(mut writer) = state.writer.as_ref() {
                let _ = writer.write_all(format!("{line}\n").as_bytes());
            }
        }

        fn status(&self) -> Dict {
            let state = self.state.lock().unwrap();
            let queue: Vec<Value> = state
                .queue
                .iter()
                .map(|id| {
                    Value::Dict(params([
                        ("utterance_id", id.as_str().into()),
                        ("original_utterance_id", id.as_str().into()),
                    ]))
                })
                .collect();
            params([
                ("speaking", (!state.queue.is_empty()).into()),
                ("playing", false.into()),
                ("held", false.into()),
                ("queue_depth", (state.queue.len() as i64).into()),
                ("queue", queue.into()),
            ])
        }

        fn write_state(&self) {
            let mut event = params([("event", "state".into())]);
            event.update(&self.status());
            self.write(&json::dumps_compact(&Value::Dict(event)));
        }

        /// Answer one request; `false` ends the connection.
        fn handle(
            &self,
            message: &Dict,
            launch: usize,
            reader: &mut BufReader<UnixStream>,
            backlog: &mut VecDeque<Dict>,
        ) -> bool {
            let op = message.string("op");
            let result = match op.as_str() {
                "hello" => {
                    self.write_state();
                    format!(
                        r#"{{"protocol":1,"service":"fake","instance_id":"instance-{launch}","pid":1,"test_mode":true}}"#
                    )
                }
                "status" => json::dumps_compact(&Value::Dict(self.status())),
                "speak" => self.speak(message, launch, reader, backlog),
                "remote_attach" | "remote_detach" => {
                    let device_id = message.string("device_id");
                    let mut state = self.state.lock().unwrap();
                    state.sinks.retain(|known| *known != device_id);
                    if op == "remote_attach"
                        && !message
                            .get("role")
                            .is_some_and(|role| role.is_str("mirror"))
                    {
                        state.sinks.push(device_id);
                    }
                    "{}".to_string()
                }
                "played_coverage" => {
                    r#"{"coverage":[{"utterance_id":"u1","spoken_text":"Hi."},"stray",3]}"#
                        .to_string()
                }
                "session_playback_states" => r#"{"states":{"session-a":"play"}}"#.to_string(),
                "control_session" | "play_or_replay" => r#"{"handled":true}"#.to_string(),
                "remote_ack" => r#"{"known":true}"#.to_string(),
                "record_missing_outcome" => r#"{"recorded":true}"#.to_string(),
                "replay" => {
                    self.write(&format!(
                        r#"{{"id":{},"ok":false,"error":{{"code":"internal_error","message":""}}}}"#,
                        json::dumps_compact(&message.get("id").cloned().unwrap())
                    ));
                    return true;
                }
                _ => "{}".to_string(),
            };
            let id = json::dumps_compact(&message.get("id").cloned().unwrap());
            self.write(&format!(r#"{{"id":{id},"ok":true,"result":{result}}}"#));
            if op == "shutdown" {
                let pid = self.state.lock().unwrap().pid;
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
                return false;
            }
            true
        }

        /// A sink takes the speech through a call, answered before `speak` is;
        /// otherwise it is queued for the Mac.
        fn speak(
            &self,
            message: &Dict,
            launch: usize,
            reader: &mut BufReader<UnixStream>,
            backlog: &mut VecDeque<Dict>,
        ) -> String {
            let sinks = self.state.lock().unwrap().sinks.clone();
            if sinks.is_empty() {
                let utterance_id = {
                    let mut state = self.state.lock().unwrap();
                    state.utterances += 1;
                    let id = format!("u{launch}-{}", state.utterances);
                    state.queue.push(id.clone());
                    id
                };
                self.write_state();
                return format!(r#"{{"accepted":true,"utterance_id":"{utterance_id}"}}"#);
            }
            for device_id in sinks {
                let number = {
                    let mut state = self.state.lock().unwrap();
                    state.calls += 1;
                    state.calls as i64
                };
                let call = params([
                    ("call", number.into()),
                    ("op", "remote_speech".into()),
                    ("device_id", device_id.into()),
                    ("role", "sink".into()),
                    ("kind", message.get("kind").cloned().unwrap_or(Value::Null)),
                    (
                        "source",
                        message.get("source").cloned().unwrap_or(Value::Null),
                    ),
                    ("text", message.get("text").cloned().unwrap_or(Value::Null)),
                    (
                        "relay_command_seq",
                        message.get("command_seq").cloned().unwrap_or(Value::Null),
                    ),
                    ("audio", true.into()),
                ]);
                self.write(&json::dumps_compact(&Value::Dict(call)));
                let reply = loop {
                    let Some(next) = self.read(reader, launch) else {
                        return r#"{"accepted":false,"utterance_id":""}"#.to_string();
                    };
                    if next
                        .get("reply")
                        .is_some_and(|reply| py_eq(reply, &Value::Int(number)))
                    {
                        break next;
                    }
                    backlog.push_back(next);
                };
                if !truthy(&reply, "ok") {
                    return r#"{"accepted":false,"utterance_id":""}"#.to_string();
                }
            }
            r#"{"accepted":true,"utterance_id":"remote"}"#.to_string()
        }
    }

    /// A `speech` frame's `text`, `spoken_by` and `audio`.
    type SentSpeech = (String, Option<String>, Option<bool>);

    #[derive(Default)]
    struct FakeDevice {
        id: String,
        refuse: bool,
        seq: Mutex<i64>,
        speeches: Mutex<Vec<SentSpeech>>,
        controls: Mutex<Vec<(String, String)>>,
        audio: Mutex<Vec<(i64, AudioPart)>>,
    }

    impl FakeDevice {
        fn new(id: &str) -> Arc<Self> {
            Arc::new(Self {
                id: id.into(),
                ..Self::default()
            })
        }

        fn next_seq(&self) -> i64 {
            let mut seq = self.seq.lock().unwrap();
            *seq += 1;
            *seq
        }
    }

    impl RemoteDevice for FakeDevice {
        fn device_id(&self) -> &str {
            &self.id
        }

        fn routable(&self) -> bool {
            true
        }

        fn speech(
            &self,
            _kind: &str,
            _source: &str,
            text: &str,
            _relay_command_seq: Option<i64>,
            spoken_by: Option<&str>,
            audio: Option<bool>,
        ) -> Result<i64, FrameError> {
            if self.refuse {
                return Err(FrameError {
                    code: "invalid_field",
                    detail: "text".into(),
                });
            }
            self.speeches
                .lock()
                .unwrap()
                .push((text.into(), spoken_by.map(str::to_string), audio));
            Ok(self.next_seq())
        }

        fn speech_control(&self, action: &str, reason: &str) -> Result<i64, FrameError> {
            self.controls
                .lock()
                .unwrap()
                .push((action.into(), reason.into()));
            Ok(self.next_seq())
        }

        fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), FrameError> {
            self.audio.lock().unwrap().push((seq, part.clone()));
            Ok(())
        }
    }

    fn reply_text(text: &str, command_seq: i64) -> SpeechText {
        SpeechText {
            text: text.into(),
            display_text: text.into(),
            command_seq: Some(command_seq),
            command_id: Some(format!("cmd-{command_seq}")),
            source: "orchestrator".into(),
            kind: "final".into(),
            authoritative: true,
            freshness_scope: "conversation".into(),
            realization_decision: "full".into(),
            ..SpeechText::default()
        }
    }

    fn started(folder: &Folder, observed: &Arc<Observed>) -> SpeechServiceClient {
        let client = client_for(folder, service_command(folder), observed, 20.0);
        client.start().unwrap();
        client
    }

    #[test]
    fn start_launches_the_service_and_says_hello() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let client = started(&folder, &observed);

        let launches = fs::read_to_string(folder.path("launches")).unwrap();
        let fields: Vec<&str> = launches.trim().split(' ').collect();
        assert_eq!(
            fields[1..],
            ["--socket", folder.path("speech.sock").as_str(), "extra-env"]
        );
        assert_eq!(
            fake.lines(1),
            [format!(
                r#"{{"id":1,"op":"hello","protocol":1,"client":"voice_bridge","pid":{}}}"#,
                std::process::id()
            )]
        );
        assert_eq!(client.instance_id(), "instance-1");
        assert!(client.inner.lock().ready);
    }

    #[test]
    fn requests_are_written_as_python_writes_them() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let client = started(&folder, &observed);

        let mut disposition = Dict::new();
        disposition.insert("intent_id", "i-1");
        assert!(client.submit_text(SpeechText {
            text: "Done, café 🎉".into(),
            display_text: "Done".into(),
            command_seq: Some(7),
            command_id: Some("cmd-7".into()),
            source: "orchestrator".into(),
            kind: "final".into(),
            authoritative: true,
            work_disposition: Some(disposition),
            freshness_scope: "conversation".into(),
            lifecycle_role: Some("result".into()),
            covered_facts: Some(vec!["a".into()]),
            realization_decision: "full".into(),
            session_key: "s-1".into(),
            waiting_playback_kind: Some("final".into()),
            ..SpeechText::default()
        }));
        // What `speech_client.py` wrote for the same keyword arguments.
        assert_eq!(
            fake.line(1, "speak"),
            r#"{"id":2,"op":"speak","text":"Done, caf\u00e9 \ud83c\udf89","display_text":"Done","command_seq":7,"command_id":"cmd-7","source":"orchestrator","kind":"final","authoritative":true,"work_disposition":{"intent_id":"i-1"},"freshness_scope":"conversation","lifecycle_role":"result","covered_facts":["a"],"realization_decision":"full","session_key":"s-1","waiting_playback_kind":"final"}"#
        );

        assert_eq!(client.queue_depth(), 1);
        assert!(client.speaking());
        assert!(!client.playing());
        client.note_play_control(None, 10.5);
        client.record_messenger_stage("messenger_submitted", 1, "one", None, Some("claude"), "ok");
        assert!(client.record_missing_outcome(1, "one", "turn_ended", &["idle".into()]));
        client.record_realization(1, "one", "progress", "suppress", "covered");
        let coverage = client.played_coverage(1, "one");
        assert_eq!(coverage.len(), 1);
        assert_eq!(coverage[0].string("spoken_text"), "Hi.");
        assert_eq!(
            json::dumps_compact(&Value::Dict(client.session_playback_states("s-1"))),
            r#"{"session-a":"play"}"#
        );
        assert!(client.control_session("session-a", "play", ""));
        assert!(client.remote_ack("phone", 4, true));
        assert!(
            !client.replay(),
            "a refused request counts as an empty result"
        );
        client.new_turn(2, "two");
        client.stop_playback("interrupt");
        client.skip("focus_switch");
        client.arm_waiting_playback(2, "two", "final");
        client.reload_config();

        let expected = [
            r#"{"op":"note_play_control","option_detected_at":null,"fifo_received_at":10.5}"#,
            r#"{"op":"record_messenger_stage","stage":"messenger_submitted","command_seq":1,"command_id":"one","at":null,"provider":"claude","outcome":"ok"}"#,
            r#"{"op":"record_missing_outcome","command_seq":1,"command_id":"one","reason":"turn_ended","signals":["idle"]}"#,
            r#"{"op":"record_realization","command_seq":1,"command_id":"one","lifecycle_role":"progress","decision":"suppress","reason":"covered"}"#,
            r#"{"op":"played_coverage","command_seq":1,"command_id":"one"}"#,
            r#"{"op":"session_playback_states","waiting_session_key":"s-1"}"#,
            r#"{"op":"control_session","session_key":"session-a","action":"play","waiting_session_key":""}"#,
            r#"{"op":"remote_ack","device_id":"phone","seq":4,"played":true}"#,
            r#"{"op":"replay"}"#,
            r#"{"op":"new_turn","command_seq":2,"command_id":"two"}"#,
            r#"{"op":"stop_playback","reason":"interrupt"}"#,
            r#"{"op":"skip","reason":"focus_switch"}"#,
            r#"{"op":"arm_waiting_playback","command_seq":2,"command_id":"two","kind":"final"}"#,
            r#"{"op":"reload_config"}"#,
        ];
        let lines: Vec<String> = fake.lines(1).iter().map(|line| without_id(line)).collect();
        assert_eq!(lines[lines.len() - expected.len()..], expected);
    }

    #[test]
    fn reply_finished_events_reach_the_callback() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let _client = started(&folder, &observed);

        fake.send(r#"{"event":"reply_finished","reason":"user_stop"}"#);
        fake.send(r#"{"event":"error","code":"playback_failed"}"#);
        fake.send("not json");
        fake.send(r#"{"event":"reply_finished"}"#);
        wait_until(
            || observed.finished.lock().unwrap().len() == 2,
            "two finished replies",
        );
        assert_eq!(
            *observed.finished.lock().unwrap(),
            ["user_stop", "completed"]
        );
    }

    #[test]
    fn crashed_service_is_restarted_with_its_devices_and_queue() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let client = started(&folder, &observed);
        for (number, text) in ["First.", "Second.", "Third."].into_iter().enumerate() {
            assert!(client.submit_text(reply_text(text, number as i64 + 1)));
        }
        fake.finish();
        wait_until(
            || client.inner.lock().held.len() == 2,
            "the first reply to be heard",
        );
        let phone = FakeDevice::new("phone");
        let tablet = FakeDevice::new("tablet");
        client.attach_remote_sink(phone.clone());
        client.attach_remote_mirror(tablet.clone());
        // Sent before the sink was attached: these stay queued on the Mac.
        let held: Vec<String> = fake
            .lines(1)
            .into_iter()
            .filter(|line| line.contains(r#""op":"speak""#))
            .skip(1)
            .collect();

        fake.crash();
        wait_until(
            || client.instance_id() == "instance-2" && client.inner.lock().ready,
            "the service to restart",
        );

        assert_eq!(observed.restarts.load(Ordering::SeqCst), 1);
        assert_eq!(
            fake.ops(2),
            ["hello", "remote_attach", "remote_attach", "speak", "speak"]
        );
        let lines = fake.lines(2);
        assert_eq!(
            without_id(&lines[1]),
            r#"{"op":"remote_attach","device_id":"phone","role":"sink"}"#
        );
        assert_eq!(
            without_id(&lines[2]),
            r#"{"op":"remote_attach","device_id":"tablet","role":"mirror"}"#
        );
        let resent: Vec<String> = lines
            .iter()
            .filter(|line| line.contains(r#""op":"speak""#))
            .map(|line| without_id(line))
            .collect();
        assert_eq!(
            resent,
            held.iter().map(|line| without_id(line)).collect::<Vec<_>>()
        );
        // The restored sink took them, answering inside each `speak`.
        let spoken: Vec<String> = phone
            .speeches
            .lock()
            .unwrap()
            .iter()
            .map(|speech| speech.0.clone())
            .collect();
        assert_eq!(spoken, ["Second.", "Third."]);

        client.new_turn(4, "four");
        assert_eq!(fake.ops(2).last().unwrap(), "new_turn");
    }

    #[test]
    fn speech_is_given_up_after_repeated_crashes() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let client = started(&folder, &observed);
        for launch in 2..=MAX_RESTARTS + 1 {
            fake.crash();
            let instance = format!("instance-{launch}");
            wait_until(
                || client.instance_id() == instance && client.inner.lock().ready,
                "the service to restart",
            );
        }
        fake.crash();
        wait_until(|| client.inner.lock().failed, "the client to give up");

        let started = Instant::now();
        assert!(!client.submit_text(reply_text("Nobody is listening.", 1)));
        client.play();
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "a failed service made its caller wait"
        );
        assert_eq!(observed.restarts.load(Ordering::SeqCst), MAX_RESTARTS);
    }

    #[test]
    fn calls_are_answered_from_the_attached_devices() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let client = started(&folder, &observed);
        let phone = FakeDevice::new("phone");
        let tablet = FakeDevice::new("tablet");
        client.attach_remote_mirror(phone.clone());
        client.attach_remote_sink(phone.clone());
        assert!(
            client.inner.lock().remote_mirrors.is_empty(),
            "a sink ends the mirror role"
        );
        client.attach_remote_mirror(tablet.clone());

        for call in [
            r#"{"call":1,"op":"remote_routable","device_id":"phone","role":"sink"}"#,
            r#"{"call":2,"op":"remote_speech","device_id":"tablet","role":"mirror","kind":"final","source":"orchestrator","text":"Hi.","relay_command_seq":3,"spoken_by":"mac"}"#,
            r#"{"call":3,"op":"remote_speech_control","device_id":"phone","role":"sink","action":"stop","reason":"superseded"}"#,
            r#"{"call":4,"op":"remote_speech_audio","device_id":"phone","role":"sink","seq":5,"part":0,"parts":1,"last":true,"data":"QUFB"}"#,
            r#"{"call":5,"op":"remote_speech","device_id":"nobody","role":"sink"}"#,
            r#"{"call":6,"op":"remote_unknown","device_id":"phone","role":"sink"}"#,
            r#"{"call":7,"op":"remote_speech","device_id":"phone","role":"sink","kind":"final"}"#,
            r#"{"call":8,"op":"remote_speech_audio","device_id":"phone","role":"sink","seq":"five","part":0,"parts":1}"#,
        ] {
            fake.send(call);
        }
        let replies = || -> Vec<String> {
            fake.lines(1)
                .into_iter()
                .filter(|line| line.starts_with(r#"{"reply""#))
                .collect()
        };
        wait_until(|| replies().len() == 8, "every call to be answered");
        assert_eq!(
            replies(),
            [
                r#"{"reply":1,"ok":true,"result":{"routable":true}}"#,
                r#"{"reply":2,"ok":true,"result":{"seq":1}}"#,
                r#"{"reply":3,"ok":true,"result":{"seq":1}}"#,
                r#"{"reply":4,"ok":true,"result":{}}"#,
                r#"{"reply":5,"ok":false,"error":{"code":"call_failed","message":"KeyError"}}"#,
                r#"{"reply":6,"ok":false,"error":{"code":"call_failed","message":"ValueError"}}"#,
                r#"{"reply":7,"ok":false,"error":{"code":"call_failed","message":"TypeError"}}"#,
                r#"{"reply":8,"ok":false,"error":{"code":"call_failed","message":"ValueError"}}"#,
            ]
        );
        assert_eq!(
            *tablet.speeches.lock().unwrap(),
            [("Hi.".to_string(), Some("mac".to_string()), None)]
        );
        assert_eq!(
            *phone.controls.lock().unwrap(),
            [("stop".to_string(), "superseded".to_string())]
        );
        let part = AudioPart {
            part: 0,
            parts: 1,
            last: true,
            data: "QUFB".into(),
            format: "aac".into(),
            sample_rate: 24000,
        };
        assert_eq!(*phone.audio.lock().unwrap(), [(5, part)]);

        // A call made inside `speak` is answered while the request waits.
        assert!(client.submit_text(reply_text("For the phone.", 1)));
        assert_eq!(
            *phone.speeches.lock().unwrap(),
            [(
                "For the phone.".to_string(),
                Some("phone".to_string()),
                Some(true)
            )]
        );

        // A device that refuses the frame refuses the speech.
        client.detach_remote_sink("phone", "remote_mode_off");
        assert!(client.inner.lock().remote_sinks.is_empty());
        let broken = Arc::new(FakeDevice {
            id: "broken".into(),
            refuse: true,
            ..FakeDevice::default()
        });
        client.attach_remote_sink(broken);
        assert!(!client.submit_text(reply_text("Cannot be sent.", 2)));
        assert_eq!(
            without_id(&fake.line(1, "remote_detach")),
            r#"{"op":"remote_detach","device_id":"phone","role":"sink","reason":"remote_mode_off"}"#
        );
    }

    #[test]
    fn shutdown_asks_the_service_to_exit() {
        let folder = Folder::new();
        let fake = Fake::start(&folder);
        let observed = Arc::new(Observed::default());
        let client = started(&folder, &observed);

        let started = Instant::now();
        client.shutdown();
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "the service was not asked to exit"
        );
        assert_eq!(fake.ops(1).last().unwrap(), "shutdown");
        assert!(client.inner.process.lock().unwrap().is_none());

        let started = Instant::now();
        assert!(!client.speaking());
        assert!(!client.submit_text(reply_text("Too late.", 1)));
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "a closed client made its caller wait"
        );
        assert_eq!(observed.restarts.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn start_fails_when_the_service_exits() {
        let folder = Folder::new();
        let observed = Arc::new(Observed::default());
        let command = vec!["/bin/sh".into(), "-c".into(), "exit 3".into()];
        let client = client_for(&folder, command, &observed, 20.0);
        let error = client.start().unwrap_err();
        assert_eq!(error.to_string(), "speech service exited with status 3");
    }

    #[test]
    fn start_fails_when_the_command_does_not_exist() {
        let folder = Folder::new();
        let observed = Arc::new(Observed::default());
        let client = client_for(
            &folder,
            vec![folder.path("no-such-service")],
            &observed,
            20.0,
        );
        let error = client.start().unwrap_err();
        assert!(
            error
                .to_string()
                .starts_with("could not start the speech service: "),
            "{error}"
        );
    }

    #[test]
    fn start_fails_when_the_service_never_listens() {
        let folder = Folder::new();
        let observed = Arc::new(Observed::default());
        let command = vec!["/bin/sh".into(), "-c".into(), "exec sleep 30".into()];
        let client = client_for(&folder, command, &observed, 0.3);
        let error = client.start().unwrap_err();
        assert_eq!(error.to_string(), "speech service did not open its socket");
        assert!(
            client.inner.process.lock().unwrap().is_none(),
            "the silent process was left running"
        );
    }

    #[test]
    fn state_datagrams_are_written_as_tts_worker_writes_them() {
        assert_eq!(
            state_datagram(&state_message("idle", None)),
            br#"{"source": "tts", "state": "idle", "tutorial": false}"#
        );
        // Multi-byte escapes count as bytes, not characters, as in Python:
        // `tts_worker._state_datagram` gives 1553 bytes for this preview.
        let raw = format!("  {}{}  ", "word ".repeat(300), "café ".repeat(200));
        let preview: String = py_strip(&raw).chars().take(2000).collect();
        let data = String::from_utf8(state_datagram(&state_message(
            "message_waiting",
            Some(preview),
        )))
        .unwrap();
        assert_eq!(data.len(), 1553);
        assert!(data.starts_with(
            r#"{"source": "tts", "state": "message_waiting", "tutorial": false, "text": "word word"#
        ));
        assert!(data.ends_with(r#" word word w\u2026"}"#), "{data}");
    }
}
