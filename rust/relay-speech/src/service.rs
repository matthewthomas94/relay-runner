//! The speech service's protocol host, the twin of `SpeechService` in
//! `services/speech_service.py`: one coordinator and worker, driven by one
//! client connection over the line protocol in
//! docs/specs/speech-service-protocol.md.
//!
//! Four threads serve the connection: the reader routes lines to requests,
//! replies and errors; the executor applies requests one at a time; the writer
//! sends every outgoing message in the order it was queued; the state poller
//! reports queue changes no request made.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, mpsc};
use std::time::Duration;

use serde_json::{Value, json};

use crate::coordinator::{AudioPart, CallFailed, Options, RemoteDevice, SpeechCoordinator, Worker};
use crate::intent::{
    self, Malformed, SpeechIntent, py_float, py_int, py_str, py_str_or_empty, truthy,
};
use crate::support::{Json, opt_int, opt_text};

pub const PROTOCOL_VERSION: i64 = 1;
pub const SERVICE_NAME: &str = "relay-speech-rust";
pub const DEFAULT_SOCKET: &str = "/tmp/relay_speech_service.sock";
pub const MAX_LINE_BYTES: usize = 1024 * 1024;
const STATE_POLL: Duration = Duration::from_millis(200);
const CALL_POLL: Duration = Duration::from_millis(250);
/// `IntentRoute.CONTINUE_CURRENT` in services/intent_arbitration.py.
const CONTINUE_CURRENT_ROUTE: &str = "continue_current";

// -- Freshness -------------------------------------------------------------------

/// The command state file the bridge writes atomically; unreadable is empty.
pub fn read_command_state(path: &Path) -> Json {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| match value {
            Value::Object(map) => Some(map),
            _ => None,
        })
        .unwrap_or_default()
}

fn command_key(seq: Option<&Value>, id: Option<&Value>) -> Option<(i64, String)> {
    let id = py_str_or_empty(id).trim().to_string();
    if id.is_empty() {
        return None;
    }
    Some((py_int(seq?).ok()?, id))
}

/// Mirrors `voice_bridge._relay_command_current`.
pub fn command_is_current(state: &Json, command_seq: i64, command_id: &str) -> bool {
    if command_id.is_empty() {
        return false;
    }
    let Some(current_seq) = state
        .get("relay_command_seq")
        .and_then(|seq| py_int(seq).ok())
    else {
        return false;
    };
    current_seq == command_seq && py_str_or_empty(state.get("relay_command_id")) == command_id
}

/// Mirrors `voice_bridge._relay_command_current_or_preserved` without a session key.
pub fn command_is_preserved(
    state: &Json,
    command_seq: i64,
    command_id: &str,
    intent_id: Option<&Value>,
) -> bool {
    let Some(expected) = command_key(Some(&command_seq.into()), Some(&command_id.into())) else {
        return false;
    };
    if let Some(Value::Array(cancelled)) = state.get("cancelled_intent_ids") {
        let intent_id = py_str_or_empty(intent_id);
        if cancelled.iter().any(|value| py_str(value) == intent_id) {
            return false;
        }
    }
    let current = command_key(
        state.get("relay_command_seq"),
        state.get("relay_command_id"),
    );
    if current.as_ref() == Some(&expected) {
        return true;
    }
    match current {
        Some((seq, _)) if seq > expected.0 => {}
        _ => return false,
    }
    let Some(Value::Object(disposition)) = state.get("work_disposition") else {
        return false;
    };
    disposition.get("route").and_then(Value::as_str) == Some(CONTINUE_CURRENT_ROUTE)
        && disposition
            .get("authorization_effect")
            .and_then(Value::as_str)
            == Some("preserve")
        && match disposition.get("cancellation_scope") {
            None | Some(Value::Null) => true,
            Some(scope) => scope.as_str() == Some("none"),
        }
}

// -- Requests --------------------------------------------------------------------

struct RequestError {
    code: &'static str,
    message: &'static str,
}

impl From<Malformed> for RequestError {
    fn from(_: Malformed) -> Self {
        invalid("Missing or malformed field")
    }
}

fn invalid(message: &'static str) -> RequestError {
    RequestError {
        code: "invalid_request",
        message,
    }
}

/// `int(request[name])`.
fn int_field(request: &Json, name: &str) -> Result<i64, RequestError> {
    Ok(py_int(
        request
            .get(name)
            .ok_or_else(|| invalid("Missing or malformed field"))?,
    )?)
}

/// `str(request[name])`.
fn str_field(request: &Json, name: &str) -> Result<String, RequestError> {
    request
        .get(name)
        .map(py_str)
        .ok_or_else(|| invalid("Missing or malformed field"))
}

/// `float(request[name])`.
fn float_field(request: &Json, name: &str) -> Result<f64, RequestError> {
    Ok(py_float(
        request
            .get(name)
            .ok_or_else(|| invalid("Missing or malformed field"))?,
    )?)
}

/// `str(request.get(name) or default)`.
fn str_or(request: &Json, name: &str, default: &str) -> String {
    let value = py_str_or_empty(request.get(name));
    if value.is_empty() {
        default.to_string()
    } else {
        value
    }
}

/// `float(value or fallback)`: a falsy value takes the fallback.
fn optional_float(request: &Json, name: &str) -> Result<Option<f64>, RequestError> {
    let value = request.get(name);
    if truthy(value) {
        Ok(Some(py_float(value.unwrap_or(&Value::Null))?))
    } else {
        Ok(None)
    }
}

/// `str(v) for v in value if v`, iterating a list, a string or an object's keys.
fn string_items(value: Option<&Value>) -> Result<Vec<String>, RequestError> {
    match value {
        _ if !truthy(value) => Ok(Vec::new()),
        Some(Value::Array(items)) => Ok(items
            .iter()
            .filter(|item| truthy(Some(item)))
            .map(py_str)
            .collect()),
        Some(Value::String(text)) => Ok(text.chars().map(String::from).collect()),
        Some(Value::Object(map)) => Ok(map.keys().filter(|key| !key.is_empty()).cloned().collect()),
        _ => Err(invalid("Missing or malformed field")),
    }
}

fn device_id(request: &Json) -> Result<String, RequestError> {
    let device_id = py_str_or_empty(request.get("device_id"));
    if device_id.is_empty() {
        return Err(invalid("device_id is required"));
    }
    Ok(device_id)
}

fn role(request: &Json) -> Result<&'static str, RequestError> {
    match request.get("role") {
        None => Ok("sink"),
        Some(Value::String(role)) if role == "sink" => Ok("sink"),
        Some(Value::String(role)) if role == "mirror" => Ok("mirror"),
        _ => Err(invalid("role must be sink or mirror")),
    }
}

/// `request.get("protocol") != PROTOCOL_VERSION` as Python compares it.
fn supported_protocol(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Number(number)) => number.as_f64() == Some(PROTOCOL_VERSION as f64),
        Some(Value::Bool(flag)) => i64::from(*flag) == PROTOCOL_VERSION,
        _ => false,
    }
}

fn intent_fields(intent: &SpeechIntent) -> Json {
    let mut fields = Json::new();
    fields.insert("utterance_id".into(), intent.utterance_id.clone().into());
    fields.insert(
        "original_utterance_id".into(),
        intent.original_utterance_id.clone().into(),
    );
    fields.insert("relay_command_seq".into(), opt_int(intent.command_seq));
    fields.insert(
        "relay_command_id".into(),
        opt_text(intent.command_id.as_deref()),
    );
    fields.insert("kind".into(), intent.kind.clone().into());
    fields.insert("source".into(), intent.source.clone().into());
    fields.insert("session_key".into(), intent.session_key.clone().into());
    fields.insert("replay_of".into(), opt_text(intent.replay_of.as_deref()));
    fields
}

/// Worker lifecycle states under their protocol names.
fn playback_phase(state: &str) -> &str {
    match state {
        "wav_ready" => "ready",
        "afplay_started" => "chunk_started",
        other => other,
    }
}

// -- The service -------------------------------------------------------------------

/// Set when the client leaves, asks to shut down, or the process is told to stop.
pub struct Done(AtomicBool);

impl Done {
    pub fn new() -> Arc<Self> {
        Arc::new(Self(AtomicBool::new(false)))
    }
    pub fn set(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_set(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// What the coordinator's callbacks and the threads share.
struct Shared {
    done: Arc<Done>,
    greeted: AtomicBool,
    out: Mutex<mpsc::Sender<Option<Value>>>,
    /// Guards the last snapshot so state events go out in the order taken.
    last_state: Mutex<Option<Json>>,
    calls: Mutex<HashMap<i64, mpsc::Sender<Json>>>,
    call_ids: AtomicI64,
    coordinator: OnceLock<Arc<SpeechCoordinator>>,
}

impl Shared {
    fn send(&self, message: Value) {
        if let Ok(out) = self.out.lock() {
            let _ = out.send(Some(message));
        }
    }

    /// Queue an event; nothing is sent before the client has said hello.
    fn emit(&self, message: Value) {
        if self.greeted.load(Ordering::SeqCst) {
            self.send(message);
        }
    }

    /// Send the queue snapshot when it changed, in the order snapshots were taken.
    fn emit_state(&self) {
        let Some(coordinator) = self.coordinator.get() else {
            return;
        };
        let mut last = self
            .last_state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let snapshot = coordinator.queue_snapshot();
        if last.as_ref() != Some(&snapshot) {
            let mut event = Json::new();
            event.insert("event".into(), "state".into());
            event.extend(snapshot.clone());
            *last = Some(snapshot);
            self.emit(Value::Object(event));
        }
    }

    fn on_playback(
        &self,
        state: &str,
        intent: &SpeechIntent,
        stop_reason: Option<&str>,
        requeued_as: Option<&str>,
    ) {
        let phase = playback_phase(state);
        let mut event = Json::new();
        event.insert("event".into(), "playback".into());
        event.insert("phase".into(), phase.into());
        event.extend(intent_fields(intent));
        if matches!(phase, "completed" | "cancelled" | "failed") {
            event.insert("stop_reason".into(), opt_text(stop_reason));
            event.insert("requeued_as".into(), opt_text(requeued_as));
        }
        self.emit(Value::Object(event));
        if phase == "failed" {
            self.emit(json!({"event": "error", "code": "playback_failed", "utterance_id": intent.utterance_id}));
        }
        self.emit_state();
    }

    /// Ask the client to act on a Relay Remote device and wait for its reply.
    fn call(&self, op: &str, params: Json) -> Result<Json, CallFailed> {
        if !self.greeted.load(Ordering::SeqCst) || self.done.is_set() {
            return Err(CallFailed);
        }
        let call_id = self.call_ids.fetch_add(1, Ordering::SeqCst);
        let (answer, answered) = mpsc::channel();
        self.calls.lock().unwrap().insert(call_id, answer);
        let mut message = Json::new();
        message.insert("call".into(), call_id.into());
        message.insert("op".into(), op.into());
        message.extend(params);
        self.send(Value::Object(message));
        let reply = loop {
            match answered.recv_timeout(CALL_POLL) {
                Ok(reply) => break Some(reply),
                Err(mpsc::RecvTimeoutError::Timeout) if !self.done.is_set() => {}
                Err(_) => break None,
            }
        };
        self.calls.lock().unwrap().remove(&call_id);
        let reply = reply.ok_or(CallFailed)?;
        if !truthy(reply.get("ok")) {
            return Err(CallFailed);
        }
        match reply.get("result") {
            Some(Value::Object(result)) => Ok(result.clone()),
            _ => Ok(Json::new()),
        }
    }

    fn answer(&self, reply: Json) {
        let call_id = match reply.get("reply") {
            Some(Value::Number(number)) => number.as_i64().or_else(|| {
                number
                    .as_f64()
                    .filter(|id| id.fract() == 0.0)
                    .map(|id| id as i64)
            }),
            Some(Value::Bool(flag)) => Some(i64::from(*flag)),
            _ => None,
        };
        if let Some(call_id) = call_id
            && let Some(slot) = self.calls.lock().unwrap().get(&call_id)
        {
            let _ = slot.send(reply);
        }
    }
}

/// Stands in for a Relay Remote `DeviceSession` that lives in the client.
struct ClientDevice {
    shared: Arc<Shared>,
    device_id: String,
    role: &'static str,
}

impl ClientDevice {
    fn call(&self, op: &str, mut params: Json) -> Result<Json, CallFailed> {
        params.insert("device_id".into(), self.device_id.clone().into());
        params.insert("role".into(), self.role.into());
        self.shared.call(op, params)
    }

    fn seq(result: &Json) -> Result<i64, CallFailed> {
        result
            .get("seq")
            .and_then(|seq| py_int(seq).ok())
            .ok_or(CallFailed)
    }
}

impl RemoteDevice for ClientDevice {
    fn device_id(&self) -> &str {
        &self.device_id
    }

    fn routable(&self) -> bool {
        self.call("remote_routable", Json::new())
            .is_ok_and(|result| truthy(result.get("routable")))
    }

    fn speech(&self, frame: Json) -> Result<i64, CallFailed> {
        Self::seq(&self.call("remote_speech", frame)?)
    }

    fn speech_control(&self, action: &str, reason: &str) -> Result<i64, CallFailed> {
        let mut params = Json::new();
        params.insert("action".into(), action.into());
        params.insert("reason".into(), reason.into());
        Self::seq(&self.call("remote_speech_control", params)?)
    }

    fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), CallFailed> {
        let Value::Object(params) = json!({
            "seq": seq,
            "part": part.part,
            "parts": part.parts,
            "last": part.last,
            "data": part.data,
            "format": crate::coordinator::AUDIO_FORMAT,
            "sample_rate": crate::coordinator::AUDIO_SAMPLE_RATE,
        }) else {
            unreachable!()
        };
        self.call("remote_speech_audio", params).map(|_| ())
    }
}

pub struct Settings {
    pub state_path: std::path::PathBuf,
    pub event_log: Option<std::path::PathBuf>,
    pub control_socket: Option<std::path::PathBuf>,
    pub test_mode: bool,
}

/// One coordinator and worker, driven by one client connection.
pub struct SpeechService {
    shared: Arc<Shared>,
    coordinator: Arc<SpeechCoordinator>,
    instance_id: String,
    test_mode: bool,
    shut_down: AtomicBool,
    requests: Mutex<Option<mpsc::Receiver<Option<Json>>>>,
    request_sender: mpsc::Sender<Option<Json>>,
    out_receiver: Mutex<Option<mpsc::Receiver<Option<Value>>>>,
}

impl SpeechService {
    pub fn new(worker: Arc<dyn Worker>, settings: Settings, done: Arc<Done>) -> Arc<Self> {
        let (out, out_receiver) = mpsc::channel();
        let shared = Arc::new(Shared {
            done,
            greeted: AtomicBool::new(false),
            out: Mutex::new(out),
            last_state: Mutex::new(None),
            calls: Mutex::new(HashMap::new()),
            call_ids: AtomicI64::new(1),
            coordinator: OnceLock::new(),
        });
        let (current_path, preserved_path) = (settings.state_path.clone(), settings.state_path);
        let (playback, finished) = (shared.clone(), shared.clone());
        let coordinator = SpeechCoordinator::new(
            worker,
            Options {
                is_current: Some(Box::new(move |seq, id| {
                    command_is_current(&read_command_state(&current_path), seq, id)
                })),
                is_preserved: Some(Box::new(move |seq, id, disposition| {
                    command_is_preserved(
                        &read_command_state(&preserved_path),
                        seq,
                        id,
                        disposition.get("intent_id"),
                    )
                })),
                event_log: settings.event_log,
                control_socket: settings.control_socket,
                on_reply_finished: Some(Box::new(move |reason| {
                    finished.emit(json!({"event": "reply_finished", "reason": reason}));
                })),
                on_playback: Some(Box::new(move |state, intent, stop_reason, requeued_as| {
                    playback.on_playback(state, intent, stop_reason, requeued_as);
                })),
            },
        );
        let _ = shared.coordinator.set(coordinator.clone());
        let (request_sender, requests) = mpsc::channel();
        Arc::new(Self {
            shared,
            coordinator,
            instance_id: intent::uuid_hex(),
            test_mode: settings.test_mode,
            shut_down: AtomicBool::new(false),
            requests: Mutex::new(Some(requests)),
            request_sender,
            out_receiver: Mutex::new(Some(out_receiver)),
        })
    }

    fn dispatch(&self, op: &str, request: &Json) -> Result<Option<Json>, RequestError> {
        let coordinator = &self.coordinator;
        let result = |value: Value| match value {
            Value::Object(map) => Ok(Some(map)),
            _ => unreachable!(),
        };
        if op == "hello" {
            if !supported_protocol(request.get("protocol")) {
                return Err(RequestError {
                    code: "unsupported_protocol",
                    message: "Unsupported protocol version",
                });
            }
            *self.shared.last_state.lock().unwrap() = None;
            self.shared.greeted.store(true, Ordering::SeqCst);
            return result(json!({
                "protocol": PROTOCOL_VERSION,
                "service": SERVICE_NAME,
                "instance_id": self.instance_id,
                "pid": std::process::id(),
                "test_mode": self.test_mode,
            }));
        }
        if !self.shared.greeted.load(Ordering::SeqCst) {
            return Err(RequestError {
                code: "hello_required",
                message: "The first request must be hello",
            });
        }
        match op {
            "speak" => {
                let spec = intent::spec_from_request(request)?;
                let intent = Arc::new(intent::build(spec));
                let kind = py_str_or_empty(request.get("waiting_playback_kind"));
                let accepted = coordinator.submit(
                    intent.clone(),
                    Some(kind.as_str()).filter(|kind| !kind.is_empty()),
                );
                return result(json!({"accepted": accepted, "utterance_id": intent.utterance_id}));
            }
            "read_out" => {
                let accepted = coordinator.read_out(
                    &py_str_or_empty(request.get("text")),
                    &py_str_or_empty(request.get("session_key")),
                );
                return result(json!({"accepted": accepted}));
            }
            "arm_waiting_playback" => coordinator.arm_waiting_playback(
                int_field(request, "command_seq")?,
                &str_field(request, "command_id")?,
                &str_or(request, "kind", "final"),
            ),
            "play" => coordinator.play(None, ""),
            "play_or_replay" => return result(json!({"handled": coordinator.play_or_replay()})),
            "replay" => return result(json!({"accepted": coordinator.replay(None)})),
            "pause" => coordinator.stop(),
            "stop_playback" => {
                coordinator.stop_playback(&str_or(request, "reason", "user_stop"), None)
            }
            "skip" => coordinator.skip(&str_or(request, "reason", "user_stop")),
            "new_turn" => coordinator.new_turn(
                int_field(request, "command_seq")?,
                &str_field(request, "command_id")?,
            ),
            "control_session" => {
                let handled = coordinator.control_session(
                    &py_str_or_empty(request.get("session_key")),
                    &py_str_or_empty(request.get("action")),
                    &py_str_or_empty(request.get("waiting_session_key")),
                );
                return result(json!({"handled": handled}));
            }
            "session_playback_states" => {
                let states = coordinator
                    .session_playback_states(&py_str_or_empty(request.get("waiting_session_key")));
                return result(json!({"states": states}));
            }
            "status" => return Ok(Some(coordinator.queue_snapshot())),
            "played_coverage" => {
                let coverage = coordinator.played_coverage(
                    int_field(request, "command_seq")?,
                    &str_field(request, "command_id")?,
                );
                return result(json!({"coverage": coverage}));
            }
            "note_play_control" => coordinator.note_play_control(
                optional_float(request, "option_detected_at")?,
                optional_float(request, "fifo_received_at")?,
            ),
            "note_visual_acknowledgement" => coordinator.note_visual_acknowledgement(
                float_field(request, "option_detected_at")?,
                float_field(request, "acknowledged_at")?,
            ),
            "record_realization" => {
                let field = |name: &str| request.get(name).cloned().unwrap_or(Value::Null);
                coordinator.record_realization(
                    int_field(request, "command_seq")?,
                    &str_field(request, "command_id")?,
                    field("lifecycle_role"),
                    field("decision"),
                    field("reason"),
                );
            }
            "record_messenger_stage" => {
                let stage = py_str_or_empty(request.get("stage"));
                let (seq, id) = (
                    int_field(request, "command_seq")?,
                    str_field(request, "command_id")?,
                );
                let at = match request.get("at") {
                    None | Some(Value::Null) => None,
                    Some(value) => Some(py_float(value)?),
                };
                let provider = match request.get("provider") {
                    Some(Value::String(provider)) => provider.clone(),
                    _ => String::new(),
                };
                coordinator.record_messenger_stage(
                    &stage,
                    seq,
                    &id,
                    at,
                    &provider,
                    &str_or(request, "outcome", "ok"),
                );
            }
            "record_missing_outcome" => {
                let (seq, id) = (
                    int_field(request, "command_seq")?,
                    str_field(request, "command_id")?,
                );
                let signals = string_items(request.get("signals"))?;
                let recorded = coordinator.record_missing_outcome(
                    seq,
                    &id,
                    &py_str_or_empty(request.get("reason")),
                    &signals,
                );
                return result(json!({"recorded": recorded}));
            }
            "reload_config" => coordinator.reload_config(),
            "remote_attach" => {
                let device = Arc::new(ClientDevice {
                    shared: self.shared.clone(),
                    device_id: device_id(request)?,
                    role: role(request)?,
                });
                if device.role == "mirror" {
                    coordinator.attach_remote_mirror(device);
                } else {
                    coordinator.attach_remote_sink(device);
                }
            }
            "remote_detach" => {
                let (device_id, role) = (device_id(request)?, role(request)?);
                if role == "mirror" {
                    coordinator.detach_remote_mirror(&device_id);
                } else {
                    coordinator
                        .detach_remote_sink(&device_id, &str_or(request, "reason", "closed"));
                }
            }
            "remote_ack" => {
                let (device_id, seq) = (device_id(request)?, int_field(request, "seq")?);
                let known = coordinator.remote_ack(&device_id, seq, truthy(request.get("played")));
                return result(json!({"known": known}));
            }
            "shutdown" => {
                self.shut_down.store(true, Ordering::SeqCst);
                coordinator.shutdown();
            }
            _ => {
                return Err(RequestError {
                    code: "unknown_op",
                    message: "Unknown request",
                });
            }
        }
        Ok(None)
    }

    /// Apply requests one at a time, in the order they were received.
    fn execute_loop(&self, requests: mpsc::Receiver<Option<Json>>) {
        while let Ok(Some(request)) = requests.recv() {
            let op = py_str_or_empty(request.get("op"));
            let mut response = Json::new();
            response.insert(
                "id".into(),
                request.get("id").cloned().unwrap_or(Value::Null),
            );
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                self.dispatch(&op, &request)
            }));
            match outcome {
                Ok(Ok(result)) => {
                    response.insert("ok".into(), true.into());
                    response.insert("result".into(), Value::Object(result.unwrap_or_default()));
                }
                Ok(Err(error)) => {
                    response.insert("ok".into(), false.into());
                    response.insert(
                        "error".into(),
                        json!({"code": error.code, "message": error.message}),
                    );
                }
                // Never let one request end the service.
                Err(_) => {
                    eprintln!("[relay_speech] {op} failed");
                    response.insert("ok".into(), false.into());
                    response.insert(
                        "error".into(),
                        json!({"code": "internal_error", "message": "panic"}),
                    );
                }
            }
            let ok = response.get("ok") == Some(&Value::Bool(true));
            if self.shared.greeted.load(Ordering::SeqCst) {
                // State a request changed reaches the client before its response.
                self.shared.emit_state();
            }
            self.shared.send(Value::Object(response));
            if op == "shutdown" && ok {
                self.shared.done.set();
                return;
            }
        }
    }

    fn protocol_error(&self, code: &str) {
        // Sent even before hello, so a client learns why it gets no response.
        self.shared.send(json!({"event": "error", "code": code}));
    }

    fn read_loop(&self, conn: UnixStream) {
        let mut reader = BufReader::new(conn);
        let mut line = Vec::new();
        while !self.shared.done.is_set() {
            line.clear();
            match (&mut reader)
                .take(MAX_LINE_BYTES as u64 + 1)
                .read_until(b'\n', &mut line)
            {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            if line.last() != Some(&b'\n') {
                if line.len() <= MAX_LINE_BYTES {
                    break; // The connection ended inside a line.
                }
                if !skip_line(&mut reader) {
                    break;
                }
                self.protocol_error("line_too_long");
                continue;
            }
            match serde_json::from_slice::<Value>(&line) {
                Ok(Value::Object(message)) if message.contains_key("reply") => {
                    self.shared.answer(message)
                }
                Ok(Value::Object(message))
                    if message.contains_key("id") && message.contains_key("op") =>
                {
                    let _ = self.request_sender.send(Some(message));
                }
                _ => self.protocol_error("invalid_message"),
            }
        }
        self.shared.done.set();
    }

    fn write_loop(&self, mut conn: UnixStream, out: mpsc::Receiver<Option<Value>>) {
        while let Ok(Some(message)) = out.recv() {
            let mut bytes = serde_json::to_vec(&message).unwrap_or_default();
            bytes.push(b'\n');
            if conn.write_all(&bytes).is_err() {
                self.shared.done.set();
                return;
            }
        }
    }

    /// Catches changes no request or playback event reports, such as a
    /// command on the control socket.
    fn state_loop(&self) {
        while !self.shared.done.is_set() {
            std::thread::sleep(STATE_POLL);
            if self.shared.greeted.load(Ordering::SeqCst) && !self.shared.done.is_set() {
                self.shared.emit_state();
            }
        }
    }

    /// Serve the one client until it leaves, asks to shut down, or the parent dies.
    pub fn serve(self: &Arc<Self>, conn: UnixStream, parent_pid: i32, stopped: &dyn Fn() -> bool) {
        let (Ok(reader), Ok(writer)) = (conn.try_clone(), conn.try_clone()) else {
            self.close();
            return;
        };
        let requests = self.requests.lock().unwrap().take().expect("served once");
        let out = self
            .out_receiver
            .lock()
            .unwrap()
            .take()
            .expect("served once");
        let spawn = |name: &str, body: Box<dyn FnOnce() + Send>| {
            std::thread::Builder::new()
                .name(name.into())
                .spawn(body)
                .expect("service thread")
        };
        let me = self.clone();
        let writer = spawn(
            "speech-service-write",
            Box::new(move || me.write_loop(writer, out)),
        );
        let me = self.clone();
        spawn(
            "speech-service-requests",
            Box::new(move || me.execute_loop(requests)),
        );
        let me = self.clone();
        spawn("speech-service-state", Box::new(move || me.state_loop()));
        let me = self.clone();
        spawn(
            "speech-service-read",
            Box::new(move || me.read_loop(reader)),
        );
        while !self.shared.done.is_set() {
            std::thread::sleep(Duration::from_millis(50));
            // SAFETY: getppid has no preconditions.
            if stopped() || unsafe { libc::getppid() } != parent_pid {
                self.shared.done.set();
            }
        }
        self.close();
        if let Ok(out) = self.shared.out.lock() {
            let _ = out.send(None);
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while !writer.is_finished() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = conn.shutdown(std::net::Shutdown::Both);
    }

    pub fn close(&self) {
        if !self.shut_down.swap(true, Ordering::SeqCst) {
            self.coordinator.shutdown();
        }
    }
}

/// Read and drop the rest of an over-long line; false when the connection ended.
fn skip_line(reader: &mut impl BufRead) -> bool {
    loop {
        let (consumed, found) = match reader.fill_buf() {
            Ok([]) | Err(_) => return false,
            Ok(buffer) => match buffer.iter().position(|byte| *byte == b'\n') {
                Some(index) => (index + 1, true),
                None => (buffer.len(), false),
            },
        };
        reader.consume(consumed);
        if found {
            return true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(value: Value) -> Json {
        match value {
            Value::Object(map) => map,
            _ => unreachable!(),
        }
    }

    #[test]
    fn the_current_command_matches_seq_and_id() {
        let current = state(json!({"relay_command_seq": 4, "relay_command_id": "cmd-4"}));
        assert!(command_is_current(&current, 4, "cmd-4"));
        assert!(!command_is_current(&current, 3, "cmd-4"));
        assert!(!command_is_current(&current, 4, "cmd-3"));
        assert!(!command_is_current(&current, 4, ""));
        assert!(!command_is_current(&Json::new(), 4, "cmd-4"));
        assert!(command_is_current(
            &state(json!({"relay_command_seq": "4", "relay_command_id": "cmd-4"})),
            4,
            "cmd-4"
        ));
    }

    #[test]
    fn a_newer_continue_current_command_preserves_an_older_one() {
        let preserving = json!({
            "relay_command_seq": 5,
            "relay_command_id": "cmd-5",
            "work_disposition": {"route": "continue_current", "authorization_effect": "preserve"},
        });
        let intent = Value::from("intent-4");
        assert!(command_is_preserved(
            &state(preserving.clone()),
            4,
            "cmd-4",
            Some(&intent)
        ));
        assert!(command_is_preserved(
            &state(preserving.clone()),
            5,
            "cmd-5",
            None
        ));
        // An older current command preserves nothing.
        assert!(!command_is_preserved(
            &state(preserving.clone()),
            6,
            "cmd-6",
            None
        ));
        let mut cancelled = state(preserving.clone());
        cancelled.insert("cancelled_intent_ids".into(), json!(["intent-4"]));
        assert!(!command_is_preserved(&cancelled, 4, "cmd-4", Some(&intent)));
        let mut scoped = state(preserving.clone());
        scoped["work_disposition"]["cancellation_scope"] = "item".into();
        assert!(!command_is_preserved(&scoped, 4, "cmd-4", Some(&intent)));
        let mut none_scope = state(preserving);
        none_scope["work_disposition"]["cancellation_scope"] = "none".into();
        assert!(command_is_preserved(&none_scope, 4, "cmd-4", Some(&intent)));
        let replacing = json!({
            "relay_command_seq": 5,
            "relay_command_id": "cmd-5",
            "work_disposition": {"route": "replace_current", "authorization_effect": "preserve"},
        });
        assert!(!command_is_preserved(
            &state(replacing),
            4,
            "cmd-4",
            Some(&intent)
        ));
    }

    #[test]
    fn protocol_version_compares_like_python() {
        assert!(supported_protocol(Some(&json!(1))));
        assert!(supported_protocol(Some(&json!(1.0))));
        assert!(!supported_protocol(Some(&json!(2))));
        assert!(!supported_protocol(Some(&json!("1"))));
        assert!(!supported_protocol(None));
    }

    #[test]
    fn an_over_long_line_is_skipped_to_its_end() {
        let mut reader = BufReader::new(&b"aaaa\nnext\n"[..]);
        assert!(skip_line(&mut reader));
        let mut rest = String::new();
        reader.read_line(&mut rest).unwrap();
        assert_eq!(rest, "next\n");
        assert!(!skip_line(&mut BufReader::new(&b"no newline"[..])));
    }
}
