//! The bridge's client of the orchestrator daemon (`voice_bridge.py` from
//! `_orchestrator_port` to `_start_messenger_outcome_polling`, with
//! `_start_target_orchestrator`): the persistent orchestrator session and its
//! heartbeat, continuity observations, PM update mode's status polling and
//! the worker outcomes the messenger speaks.
//!
//! Every request goes to `127.0.0.1:<port>` with a one second timeout, and
//! every failure is logged and absorbed: the bridge keeps working when no
//! daemon answers.

use std::collections::BTreeSet;
use std::fmt::{self, Write as _};
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use relay_intents::model::normalize_recovery_generation;

use super::ports::{Event, Messenger};
use super::settings::settings;
use super::store;
use super::targets::{self, VoiceTarget};
use crate::json::{self, Dict, Value, py_strip};
use crate::support::{env_optional, env_text, now};

/// `urlopen(..., timeout=1.0)`: every request the bridge makes.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(1);
/// `MESSENGER_OUTCOME_FETCH_LIMIT`.
const MESSENGER_OUTCOME_FETCH_LIMIT: i64 = 50;
/// `http.client`'s `_MAXLINE`.
const MAX_LINE: u64 = 65536;

/// `_CONTINUITY_SESSION_NATIVE_ID`: the orchestrator session key continuity
/// observations are attributed to.
static CONTINUITY_SESSION_NATIVE_ID: Mutex<Option<String>> = Mutex::new(None);

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn continuity_session_native_id() -> Option<String> {
    locked(&CONTINUITY_SESSION_NATIVE_ID).clone()
}

fn set_continuity_session_native_id(value: Option<String>) {
    *locked(&CONTINUITY_SESSION_NATIVE_ID) = value;
}

// -- HTTP --------------------------------------------------------------------

/// The exceptions the Python callers catch: `OSError`, `URLError` (with
/// `HTTPError`), `TimeoutError` and `json.JSONDecodeError`.
#[derive(Debug)]
pub enum DaemonError {
    Io(io::Error),
    /// `TimeoutError`; its text contains "timed out", which
    /// `replies::note_daemon_fetch_failure` reads.
    TimedOut,
    /// `HTTPError`: a status outside 2xx.
    Status(u16, String),
    /// A response `http.client` could not read.
    Protocol(&'static str),
    /// `json.JSONDecodeError`.
    Json,
}

impl DaemonError {
    pub fn timed_out(&self) -> bool {
        matches!(self, DaemonError::TimedOut)
    }
}

impl From<io::Error> for DaemonError {
    fn from(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => DaemonError::TimedOut,
            io::ErrorKind::UnexpectedEof => DaemonError::Protocol("incomplete read"),
            _ => DaemonError::Io(error),
        }
    }
}

impl fmt::Display for DaemonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DaemonError::Io(error) => write!(formatter, "{error}"),
            DaemonError::TimedOut => formatter.write_str("timed out"),
            DaemonError::Status(code, reason) => write!(formatter, "HTTP Error {code}: {reason}"),
            DaemonError::Protocol(message) => formatter.write_str(message),
            DaemonError::Json => formatter.write_str("the response is not JSON"),
        }
    }
}

/// The daemon's HTTP API: the `request_json=` / `request_get_json=`
/// parameters of the Python functions. `LocalDaemon` is the real one.
pub trait Daemon: Send + Sync {
    /// `_post_orchestrator_json(path, payload)`.
    fn post_json(&self, path: &str, payload: &Dict) -> Result<Dict, DaemonError>;
    /// `_get_orchestrator_json(path, params)`.
    fn get_json(&self, path: &str, params: &Dict) -> Result<Dict, DaemonError>;
}

/// The local daemon, at the port `ORCHESTRATOR_PORT_FILE` names when each
/// request is made.
pub struct LocalDaemon;

impl Daemon for LocalDaemon {
    fn post_json(&self, path: &str, payload: &Dict) -> Result<Dict, DaemonError> {
        let port = orchestrator_port(&settings().orchestrator_port_file);
        let body = json::dumps(&Value::Dict(payload.clone()));
        exchange(port, "POST", path, Some(&body), REQUEST_TIMEOUT)
    }

    fn get_json(&self, path: &str, params: &Dict) -> Result<Dict, DaemonError> {
        let port = orchestrator_port(&settings().orchestrator_port_file);
        let query = urlencode(params);
        let target = if query.is_empty() {
            path.to_string()
        } else {
            format!("{path}?{query}")
        };
        exchange(port, "GET", &target, None, REQUEST_TIMEOUT)
    }
}

/// `_orchestrator_port`: the port in the file, else the default.
pub fn orchestrator_port(port_file: &str) -> u16 {
    let default = settings().orchestrator_default_port;
    let Ok(text) = fs::read_to_string(port_file) else {
        return default;
    };
    let raw = py_strip(&text);
    if raw.is_empty() {
        return default;
    }
    json::py_int_from_str(raw)
        .and_then(|port| u16::try_from(port).ok())
        .unwrap_or(default)
}

/// `urllib.parse.quote_plus`.
fn quote_plus(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len());
    for &byte in text.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'.' | b'-' | b'~' => {
                quoted.push(char::from(byte));
            }
            b' ' => quoted.push('+'),
            _ => {
                let _ = write!(quoted, "%{byte:02X}");
            }
        }
    }
    quoted
}

/// `_get_orchestrator_json`'s query: `urlencode` of the parameters that are
/// neither `None` nor `""`.
fn urlencode(params: &Dict) -> String {
    params
        .iter()
        .filter(|(_, value)| !matches!(value, Value::Null) && !value.is_str(""))
        .map(|(key, value)| format!("{}={}", quote_plus(key), quote_plus(&value.py_str())))
        .collect::<Vec<_>>()
        .join("&")
}

/// One request, as `urllib.request.urlopen` makes it: `Connection: close`,
/// the timeout on the connect and on each read and write, and any status
/// outside 2xx an error. An empty body is `{}`, and so is JSON that is not
/// an object.
fn exchange(
    port: u16,
    method: &str,
    target: &str,
    body: Option<&str>,
    timeout: Duration,
) -> Result<Dict, DaemonError> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&address, timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    let mut request = format!(
        "{method} {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\
         Accept-Encoding: identity\r\nConnection: close\r\n"
    );
    if let Some(body) = body {
        let _ = write!(
            request,
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        );
    }
    request.push_str("\r\n");
    request.push_str(body.unwrap_or(""));
    stream.write_all(request.as_bytes())?;
    let body = read_response(&mut BufReader::new(stream))?;
    if body.is_empty() {
        return Ok(Dict::new());
    }
    match json::parse_bytes(&body) {
        None => Err(DaemonError::Json),
        Some(Value::Dict(data)) => Ok(data),
        Some(_) => Ok(Dict::new()),
    }
}

fn read_line(reader: &mut impl BufRead) -> Result<Vec<u8>, DaemonError> {
    let mut line = Vec::new();
    reader
        .by_ref()
        .take(MAX_LINE + 1)
        .read_until(b'\n', &mut line)?;
    if line.len() as u64 > MAX_LINE {
        return Err(DaemonError::Protocol(
            "got more than 65536 bytes when reading a line",
        ));
    }
    Ok(line)
}

fn is_blank_line(line: &[u8]) -> bool {
    matches!(line, b"" | b"\n" | b"\r\n")
}

/// Exactly `length` bytes, without trusting `length` for the allocation.
fn read_exactly(
    reader: &mut impl BufRead,
    length: u64,
    body: &mut Vec<u8>,
) -> Result<(), DaemonError> {
    let wanted = body.len() as u64 + length;
    reader.by_ref().take(length).read_to_end(body)?;
    if body.len() as u64 != wanted {
        return Err(DaemonError::Protocol("incomplete read"));
    }
    Ok(())
}

/// The body of a 2xx HTTP/1.x response framed by `Content-Length`, by
/// chunks, or by the end of the connection. Another status is an error
/// before its body is read, as `urlopen` raises `HTTPError`.
fn read_response(reader: &mut impl BufRead) -> Result<Vec<u8>, DaemonError> {
    let status_line = read_line(reader)?;
    if status_line.is_empty() {
        return Err(DaemonError::Protocol(
            "Remote end closed connection without response",
        ));
    }
    let status_line = String::from_utf8_lossy(&status_line);
    let mut parts = status_line.trim_end_matches(['\r', '\n']).splitn(3, ' ');
    let version = parts.next().unwrap_or("");
    let status = parts
        .next()
        .and_then(|code| code.parse::<u16>().ok())
        .filter(|code| version.starts_with("HTTP/") && (100..1000).contains(code))
        .ok_or(DaemonError::Protocol("bad status line"))?;
    let reason = py_strip(parts.next().unwrap_or("")).to_string();
    let mut content_length = None;
    let mut chunked = false;
    loop {
        let line = read_line(reader)?;
        if is_blank_line(&line) {
            break;
        }
        let line = String::from_utf8_lossy(&line);
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        match name.trim().to_ascii_lowercase().as_str() {
            "content-length" => content_length = value.parse::<u64>().ok(),
            "transfer-encoding" => chunked = value.to_ascii_lowercase().contains("chunked"),
            _ => {}
        }
    }
    if !(200..300).contains(&status) {
        return Err(DaemonError::Status(status, reason));
    }
    let mut body = Vec::new();
    if chunked {
        loop {
            let line = read_line(reader)?;
            let line = String::from_utf8_lossy(&line);
            let size = line.split(';').next().unwrap_or("").trim();
            let size = u64::from_str_radix(size, 16)
                .map_err(|_| DaemonError::Protocol("bad chunk size"))?;
            if size == 0 {
                while !is_blank_line(&read_line(reader)?) {}
                break;
            }
            read_exactly(reader, size, &mut body)?;
            read_line(reader)?;
        }
    } else if let Some(length) = content_length {
        read_exactly(reader, length, &mut body)?;
    } else {
        reader.read_to_end(&mut body)?;
    }
    Ok(body)
}

// -- Continuity observations -------------------------------------------------

/// `_post_continuity_event`: only allowlisted lifecycle identity, never native
/// event contents. `{}` when there is no session, the generation is invalid
/// or the daemon does not answer.
pub fn post_continuity_event(
    source: &str,
    event: &str,
    metadata: Option<&Dict>,
    observed_at: Option<f64>,
    daemon: &dyn Daemon,
) -> Dict {
    let empty = Dict::new();
    let source_data = metadata.unwrap_or(&empty);
    let session_id = match continuity_session_native_id().filter(|id| !id.is_empty()) {
        Some(native_id) => Value::from(native_id),
        None => source_data
            .get("session_id")
            .cloned()
            .unwrap_or(Value::Null),
    };
    if !session_id.truthy() {
        return Dict::new();
    }
    let raw_generation = match source_data.get("recovery_generation") {
        None | Some(Value::Null) => None,
        Some(value) if value.is_str("") => None,
        Some(value) => Some(value.clone()),
    }
    .unwrap_or_else(|| {
        let configured = env_optional("RELAY_RECOVERY_GENERATION").unwrap_or_default();
        Value::from(if configured.is_empty() {
            "0".to_string()
        } else {
            configured
        })
    });
    let Some(recovery_generation) = normalize_recovery_generation(&raw_generation) else {
        return Dict::new();
    };
    let provider = match source_data.truthy("provider") {
        Some(provider) => provider.clone(),
        None => match env_optional("RELAY_RUNNER_PROVIDER").filter(|value| !value.is_empty()) {
            Some(provider) => Value::from(provider),
            None => Value::from("codex"),
        },
    };
    let mut payload = Dict::new();
    payload.insert("source", source);
    payload.insert("event", event);
    payload.insert("session_id", session_id);
    payload.insert(
        "relay_command_id",
        source_data
            .get("relay_command_id")
            .cloned()
            .unwrap_or(Value::Null),
    );
    payload.insert("provider", provider);
    payload.insert("recovery_generation", recovery_generation);
    payload.insert("observed_at", observed_at.unwrap_or_else(now));
    daemon
        .post_json("/v1/continuity/observation", &payload)
        .unwrap_or_default()
}

/// `_observe_stt_status`: a refining status means transcription started.
pub fn observe_stt_status(status: &str, daemon: &dyn Daemon) {
    let normalized = py_strip(status).to_lowercase();
    if normalized.starts_with("(refining)") || normalized.starts_with("refining") {
        post_continuity_event("stt", "transcription_started", None, None, daemon);
    }
}

/// `_observe_stt_continuity_signal`: a `__CONTINUITY__:<signal>` line.
pub fn observe_stt_continuity_signal(signal: &str, daemon: &dyn Daemon) {
    let normalized = py_strip(signal).to_lowercase();
    if let event @ ("capture_failed" | "transcription_started" | "transcription_failed") =
        normalized.as_str()
    {
        post_continuity_event("stt", event, None, None, daemon);
    }
}

// -- The persistent orchestrator session --------------------------------------

fn general(cfg: &Dict) -> Option<&Dict> {
    cfg.get("general").and_then(Value::as_dict)
}

/// `_bridge_provider`.
pub fn bridge_provider(cfg: &Dict) -> String {
    let env_provider = env_text("RELAY_RUNNER_PROVIDER").to_lowercase();
    if !env_provider.is_empty() {
        return env_provider;
    }
    let provider = general(cfg)
        .and_then(|general| general.truthy("provider"))
        .map_or_else(|| "codex".to_string(), Value::py_str);
    let provider = if py_strip(&provider).to_lowercase().contains("claude") {
        "claude"
    } else {
        "codex"
    };
    provider.to_string()
}

fn general_text(cfg: &Dict, key: &str) -> Option<String> {
    let value = general(cfg)
        .map(|general| general.text(key).to_lowercase())
        .unwrap_or_default();
    (!value.is_empty()).then_some(value)
}

/// `_bridge_model`.
pub fn bridge_model(cfg: &Dict) -> Option<String> {
    general_text(cfg, "model")
}

/// `_bridge_effort`.
pub fn bridge_effort(cfg: &Dict) -> Option<String> {
    general_text(cfg, "orchestrator_effort")
}

/// The dict `start_persistent_orchestrator_lifecycle` returns: the daemon's
/// session for one project, kept alive by a heartbeat thread until
/// `shutdown_event` is set.
pub struct OrchestratorSession {
    pub session_id: i64,
    pub session_key: String,
    pub repo_path: String,
    pub provider: String,
    pub recoverable_commands: Vec<Dict>,
    pub shutdown_event: Arc<Event>,
    /// `state["value"]` under `state_lock`: what each heartbeat reports.
    state: Arc<Mutex<String>>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl OrchestratorSession {
    /// A session with no heartbeat thread, in the `idle` state.
    pub fn new(
        session_id: i64,
        session_key: &str,
        repo_path: &str,
        provider: &str,
        recoverable_commands: Vec<Dict>,
        shutdown_event: Arc<Event>,
    ) -> Self {
        Self {
            session_id,
            session_key: session_key.to_string(),
            repo_path: repo_path.to_string(),
            provider: provider.to_string(),
            recoverable_commands,
            shutdown_event,
            state: Arc::new(Mutex::new("idle".to_string())),
            thread: Mutex::new(None),
        }
    }

    /// `_set_orchestrator_session_state`.
    pub fn set_state(&self, state: &str) {
        *locked(&self.state) = state.to_string();
    }

    pub fn state(&self) -> String {
        locked(&self.state).clone()
    }

    /// `session["thread"].is_alive()`.
    pub fn heartbeat_running(&self) -> bool {
        locked(&self.thread)
            .as_ref()
            .is_some_and(|thread| !thread.is_finished())
    }

    /// This session's outcome scope (`_pending_messenger_outcome_params`
    /// reading the session dict).
    pub fn outcome_scope(&self) -> OutcomeScope {
        OutcomeScope {
            repo_path: self.repo_path.clone(),
            provider: self.provider.clone(),
            session_key: self.session_key.clone(),
        }
    }
}

/// `hashlib.sha1(data).hexdigest()`.
fn sha1_hex(data: &[u8]) -> String {
    let mut state: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&(data.len() as u64).wrapping_mul(8).to_be_bytes());
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (index, word) in block.chunks_exact(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..80 {
            w[index] = (w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = state;
        for (index, word) in w.iter().enumerate() {
            let (f, k) = match index {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let next = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = next;
        }
        for (total, value) in state.iter_mut().zip([a, b, c, d, e]) {
            *total = total.wrapping_add(value);
        }
    }
    state.iter().map(|word| format!("{word:08x}")).collect()
}

/// `start_persistent_orchestrator_lifecycle`: registers this bridge as the
/// project's durable foreground orchestrator session and heartbeats it every
/// `ORCHESTRATOR_HEARTBEAT_SECONDS` until `shutdown_event` is set. It spawns
/// no model process. `None` when the daemon does not answer with a session.
pub fn start_persistent_orchestrator_lifecycle(
    cfg: &Dict,
    shutdown_event: Arc<Event>,
    cwd: Option<&str>,
    event_log_path: &str,
    daemon: Arc<dyn Daemon>,
) -> Option<Arc<OrchestratorSession>> {
    let repo_path = store::resolve_path(&match cwd.filter(|cwd| !cwd.is_empty()) {
        Some(cwd) => cwd.to_string(),
        None => store::current_dir(),
    });
    let provider = bridge_provider(cfg);
    let command_action_states: Vec<Value> =
        store::command_action_journal_snapshot(event_log_path, Some(&repo_path), 20)
            .into_iter()
            .map(Value::Dict)
            .collect();
    let mut payload = Dict::new();
    payload.insert("repo_path", repo_path.as_str());
    payload.insert("provider", provider.as_str());
    payload.insert("model", bridge_model(cfg));
    payload.insert("effort", bridge_effort(cfg));
    payload.insert("source", "relay-bridge");
    payload.insert("pid", i64::from(std::process::id()));
    payload.insert("state", "idle");
    payload.insert("command_action_states", command_action_states);
    let response = match daemon.post_json("/v1/orchestrator-session/ensure", &payload) {
        Ok(response) => response,
        Err(error) => {
            eprintln!("[voice_bridge] Persistent orchestrator unavailable: {error}");
            return None;
        }
    };
    let session = response
        .get("orchestrator_session")
        .and_then(Value::as_dict);
    // Python raises on an id `int()` refuses; that is no session id either.
    let Some((session, session_id)) = session.and_then(|session| {
        let id = session.truthy("id")?.py_int()?;
        Some((session, id))
    }) else {
        eprintln!("[voice_bridge] Persistent orchestrator did not return a session id.");
        return None;
    };
    let mut session_key = session.text("session_key");
    if session_key.is_empty() {
        session_key = format!("project:{}", &sha1_hex(repo_path.as_bytes())[..16]);
    }
    set_continuity_session_native_id(Some(session_key.clone()));
    let recoverable_commands = response
        .get("recoverable_commands")
        .or_else(|| session.get("recoverable_commands"))
        .and_then(Value::as_list)
        .map(|commands| {
            commands
                .iter()
                .filter_map(Value::as_dict)
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let lifecycle = OrchestratorSession::new(
        session_id,
        &session_key,
        &repo_path,
        &provider,
        recoverable_commands,
        shutdown_event.clone(),
    );
    let heartbeat = {
        let state = lifecycle.state.clone();
        let repo_path = repo_path.clone();
        let provider = provider.clone();
        move || {
            let send_heartbeat = || {
                let mut payload = Dict::new();
                payload.insert("session_id", session_id);
                payload.insert("repo_path", repo_path.as_str());
                payload.insert("provider", provider.as_str());
                payload.insert("state", locked(&state).clone());
                if let Err(error) = daemon.post_json("/v1/orchestrator-session/heartbeat", &payload)
                {
                    eprintln!("[voice_bridge] Persistent orchestrator heartbeat failed: {error}");
                    super::replies::note_daemon_fetch_failure(&error.to_string());
                }
            };
            send_heartbeat();
            while !shutdown_event.wait(settings().heartbeat_seconds) {
                send_heartbeat();
            }
        }
    };
    *locked(&lifecycle.thread) = thread::Builder::new()
        .name("orchestrator-lifecycle-heartbeat".to_string())
        .spawn(heartbeat)
        .ok();
    eprintln!(
        "[voice_bridge] Persistent orchestrator session {session_id} active \
         provider={provider} repo={repo_path}"
    );
    Some(Arc::new(lifecycle))
}

/// `stop_persistent_orchestrator_lifecycle`: ends the heartbeat (waiting up
/// to half a second for it) and tells the daemon the session stopped.
pub fn stop_persistent_orchestrator_lifecycle(
    session: Option<&OrchestratorSession>,
    reason: &str,
    daemon: &dyn Daemon,
) {
    let Some(session) = session else {
        return;
    };
    session.shutdown_event.set();
    let deadline = Instant::now() + Duration::from_millis(500);
    while session.heartbeat_running() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    let finished = locked(&session.thread).take_if(|thread| thread.is_finished());
    if let Some(thread) = finished {
        let _ = thread.join();
    }
    let mut payload = Dict::new();
    payload.insert("reason", reason);
    if session.session_id != 0 {
        payload.insert("session_id", session.session_id);
    } else if !session.repo_path.is_empty() {
        payload.insert("repo_path", session.repo_path.as_str());
    } else {
        return;
    }
    if let Err(error) = daemon.post_json("/v1/orchestrator-session/stop", &payload) {
        eprintln!("[voice_bridge] Persistent orchestrator stop failed: {error}");
    }
    let mut native_id = locked(&CONTINUITY_SESSION_NATIVE_ID);
    if native_id.as_deref() == Some(session.session_key.as_str()) {
        *native_id = None;
    }
}

/// `_start_target_orchestrator`: a heartbeat lifecycle for a non-startup
/// target's project. Continuity events stay attributed to the bridge's own
/// session.
pub fn start_target_orchestrator(
    cfg: &Dict,
    target: &VoiceTarget,
    daemon: Arc<dyn Daemon>,
) -> Option<Arc<OrchestratorSession>> {
    let native_id = continuity_session_native_id();
    let session = start_persistent_orchestrator_lifecycle(
        cfg,
        Arc::new(Event::default()),
        Some(&target.cwd),
        &settings().command_event_log,
        daemon,
    );
    set_continuity_session_native_id(native_id);
    session
}

/// `_surface_recoverable_command_status`: tells the user about project-work
/// requests a previous session left without a confirmed ticket action.
/// `notify_state` is `store::notify_state` outside tests.
pub fn surface_recoverable_command_status(
    orchestrator_session: Option<&OrchestratorSession>,
    messenger: Option<&dyn Messenger>,
    notify_state: &dyn Fn(&str, Dict),
) -> Option<String> {
    let commands = &orchestrator_session?.recoverable_commands;
    if commands.is_empty() {
        return None;
    }
    let count_status = |status: &str| {
        commands
            .iter()
            .filter(|command| {
                command
                    .get("status")
                    .is_some_and(|value| value.is_str(status))
            })
            .count()
    };
    let delivery_failed_count = count_status("delivery_failed");
    let message = if count_status("clarification_required") > 0 {
        "A previous project-work request is waiting for a target project. \
         Choose a child project in Workspace, then repeat the request; \
         no parent workspace ticket was created."
            .to_string()
    } else if delivery_failed_count > 0 {
        let noun = if delivery_failed_count == 1 {
            "request"
        } else {
            "requests"
        };
        format!(
            "Delivery failed for {delivery_failed_count} previous project-work {noun} \
             before a ticket action was confirmed. Repeat the request in this recovered \
             session; completed mutations will not be replayed."
        )
    } else {
        let count = commands.len();
        let noun = if count == 1 { "request" } else { "requests" };
        format!(
            "{count} previous project-work {noun} did not reach a confirmed ticket action. \
             Repeat the request in this recovered session; completed mutations will not \
             be replayed."
        )
    };
    let mut fields = Dict::new();
    fields.insert("text", message.as_str());
    notify_state("working", fields);
    if let Some(messenger) = messenger {
        let mut trace = Dict::new();
        trace.insert("kind", "command-recovery");
        trace.insert("message", message.as_str());
        trace.insert("source", "orchestrator");
        messenger.submit_trace(trace);
    }
    Some(message)
}

// -- PM update mode ------------------------------------------------------------

/// `_notify_state`, as PM update mode's `emit` calls it.
pub type NotifyState = Arc<dyn Fn(&str, Dict) + Send + Sync>;

/// The three status payloads `_fetch_pm_update_snapshot` reads before it
/// calls `build_pm_update_snapshot`.
pub struct PmUpdatePayloads {
    pub sessions: Dict,
    pub runs: Dict,
    pub program: Dict,
}

/// The HTTP half of `_fetch_pm_update_snapshot`.
pub fn fetch_pm_update_payloads(
    repo_path: &str,
    provider: Option<&str>,
    daemon: &dyn Daemon,
) -> Result<PmUpdatePayloads, DaemonError> {
    let mut sessions = Dict::new();
    sessions.insert("repo_path", repo_path);
    sessions.insert("limit", 8);
    let sessions = daemon.get_json("/v1/orchestrator-sessions", &sessions)?;
    let mut runs = Dict::new();
    runs.insert("limit", 32);
    let runs = daemon.get_json("/v1/runs", &runs)?;
    let mut program = Dict::new();
    program.insert("query", "summary");
    program.insert("provider", provider);
    program.insert("limit", 0);
    let program = daemon.get_json("/v1/program/status", &program)?;
    Ok(PmUpdatePayloads {
        sessions,
        runs,
        program,
    })
}

/// SEAM (pm_frontstage): what `_start_pm_update_mode` hands
/// `PMUpdateMode(...)`. `build_pm_update_snapshot` takes `repo_path`,
/// `provider` and `session_id` with the payloads of `fetch_status`;
/// `current_command` is `current_command_reader` and `emit` the `emit`
/// callback, given `PMStatusEvent.to_dict()`.
pub struct PmUpdateSources {
    pub repo_path: String,
    pub provider: Option<String>,
    pub session_id: Option<i64>,
    state_path: String,
    messenger: Option<Arc<dyn Messenger>>,
    notify_state: NotifyState,
    daemon: Arc<dyn Daemon>,
}

impl PmUpdateSources {
    /// `status_reader`'s requests.
    pub fn fetch_status(&self) -> Result<PmUpdatePayloads, DaemonError> {
        fetch_pm_update_payloads(
            &self.repo_path,
            self.provider.as_deref(),
            self.daemon.as_ref(),
        )
    }

    /// `read_current_command`.
    pub fn current_command(&self) -> Dict {
        store::read_json_file(&self.state_path)
    }

    /// `emit(event)`: a `working` state with the event, and a `pm-update`
    /// trace. `PMUpdateMode` never sets an event's `ticket_id` or `run_id`,
    /// so `to_dict()` omitting them is the trace's `None`.
    pub fn emit(&self, status_event: &Dict) {
        let field = |name: &str| status_event.get(name).cloned().unwrap_or(Value::Null);
        let mut fields = Dict::new();
        fields.insert("text", field("message"));
        fields.insert("status_event", status_event.clone());
        (self.notify_state)("working", fields);
        if let Some(messenger) = &self.messenger {
            let mut trace = Dict::new();
            trace.insert("kind", "pm-update");
            trace.insert("message", field("message"));
            trace.insert("source", field("source"));
            trace.insert("command", field("command"));
            trace.insert("ticket_id", field("ticket_id"));
            trace.insert("run_id", field("run_id"));
            messenger.submit_trace(trace);
        }
    }
}

/// SEAM (pm_frontstage): the fields of `PMUpdatePollResult` the loop reads.
pub struct PmUpdateStep {
    pub continue_running: bool,
    pub state: String,
    pub stale: bool,
}

/// SEAM (pm_frontstage): `mode.poll()`. A status fetch failure is the error.
pub type PmUpdatePoll = Box<dyn FnMut() -> Result<PmUpdateStep, DaemonError> + Send>;

/// `_should_start_pm_update_mode`.
pub fn should_start_pm_update_mode(action_kind: &str) -> bool {
    matches!(
        action_kind,
        "create_ticket" | "update_ticket" | "dispatch_ticket"
    )
}

/// `_start_pm_update_mode`: polls PM status for a ticket action and mirrors
/// its state onto the orchestrator session until it settles or the command
/// is superseded. `build_mode` is the seam to `pm_frontstage`: it makes
/// `RelayCommandMetadata.from_dict(relay_command, source_text=...)` (`None`
/// where that raises) and a `PMUpdateMode` over the sources, with
/// `PM_UPDATE_CADENCE_SECONDS` and `PM_UPDATE_STARTUP_GRACE_SECONDS`.
pub fn start_pm_update_mode(
    action_kind: &str,
    orchestrator_session: Option<&Arc<OrchestratorSession>>,
    messenger: Option<Arc<dyn Messenger>>,
    notify_state: NotifyState,
    daemon: Arc<dyn Daemon>,
    build_mode: impl FnOnce(Arc<PmUpdateSources>) -> Option<PmUpdatePoll>,
) -> Option<JoinHandle<()>> {
    let session = orchestrator_session.filter(|_| should_start_pm_update_mode(action_kind))?;
    let repo_path = if session.repo_path.is_empty() {
        store::current_dir()
    } else {
        session.repo_path.clone()
    };
    let provider = py_strip(&session.provider).to_string();
    let sources = Arc::new(PmUpdateSources {
        repo_path,
        provider: (!provider.is_empty()).then_some(provider),
        session_id: Some(session.session_id),
        state_path: settings().command_state_file.clone(),
        messenger,
        notify_state,
        daemon,
    });
    let mut poll = build_mode(sources)?;
    session.set_state("planning");
    let session = session.clone();
    thread::Builder::new()
        .name("pm-update-mode".to_string())
        .spawn(move || {
            let poll_seconds = settings().pm_update_poll_seconds.max(0.25);
            loop {
                let result = match poll() {
                    Ok(result) => result,
                    Err(error) => {
                        eprintln!("[voice_bridge] PM update mode status fetch failed: {error}");
                        session.set_state("blocked");
                        return;
                    }
                };
                if result.stale {
                    return;
                }
                session.set_state(&result.state);
                if !result.continue_running {
                    if result.state == "idle" {
                        session.set_state("idle");
                    }
                    return;
                }
                thread::sleep(Duration::from_secs_f64(poll_seconds));
            }
        })
        .ok()
}

// -- Worker outcomes for the messenger ------------------------------------------

/// The keys `_pending_messenger_outcome_params` reads from its session dict:
/// an orchestrator session's, or `_messenger_outcome_session`'s. Empty is
/// absent.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OutcomeScope {
    pub repo_path: String,
    pub provider: String,
    pub session_key: String,
}

/// `_pending_messenger_outcome_params`. RR-469: a keyed session hears the
/// runs it dispatched, from any project; the live keys let it also take over
/// outcomes of a session that ended.
pub fn pending_messenger_outcome_params(scope: Option<&OutcomeScope>) -> Dict {
    let scope = scope.cloned().unwrap_or_default();
    let repo_path = if scope.repo_path.is_empty() {
        store::current_dir()
    } else {
        scope.repo_path
    };
    let provider = py_strip(&scope.provider).to_string();
    let mut params = Dict::new();
    params.insert("repo_path", repo_path);
    params.insert("provider", (!provider.is_empty()).then_some(provider));
    params.insert("limit", MESSENGER_OUTCOME_FETCH_LIMIT);
    if !scope.session_key.is_empty() {
        let live_keys: BTreeSet<String> = targets::live_voice_targets()
            .iter()
            .map(|target| targets::authorization_key_for_target(Some(target)))
            .filter(|key| !key.is_empty())
            .collect();
        params.insert("session_key", scope.session_key);
        params.insert(
            "live_session_keys",
            live_keys.into_iter().collect::<Vec<_>>().join(","),
        );
    }
    params
}

/// `_messenger_outcome_trace`: one outcome's own trace, or one update that
/// summarises several.
pub fn messenger_outcome_trace(outcomes: &[(i64, Dict)]) -> Dict {
    if let [(_, trace)] = outcomes {
        return trace.clone();
    }
    let mut ticket_ids: Vec<String> = Vec::new();
    for (_, trace) in outcomes {
        let ticket_id = trace.text("ticket_id").to_uppercase();
        if !ticket_id.is_empty() && !ticket_ids.contains(&ticket_id) {
            ticket_ids.push(ticket_id);
        }
    }
    let ticket_summary = match ticket_ids.len() {
        0 => String::new(),
        1 => " across 1 ticket".to_string(),
        count => format!(" across {count} tickets"),
    };
    let mut trace = Dict::new();
    trace.insert("kind", "run-health-warning");
    trace.insert(
        "message",
        format!(
            "{} Relay work updates accumulated while this session was away{ticket_summary}. \
             Open Workspace for current status.",
            outcomes.len()
        ),
    );
    trace.insert("source", "orchestrator");
    trace.insert(
        "ticket_ids",
        ticket_ids.into_iter().map(Value::from).collect::<Vec<_>>(),
    );
    trace.insert("outcome_count", outcomes.len() as i64);
    trace
}

/// `_fetch_pending_messenger_outcomes`: the undelivered outcomes' ids and
/// trace events; the daemon's GET does not mark them delivered.
pub fn fetch_pending_messenger_outcomes(
    scope: Option<&OutcomeScope>,
    daemon: &dyn Daemon,
) -> Vec<(i64, Dict)> {
    let response = match daemon.get_json(
        "/v1/messenger/outcomes",
        &pending_messenger_outcome_params(scope),
    ) {
        Ok(response) => response,
        Err(error) => {
            eprintln!("[voice_bridge] pending messenger outcome fetch failed: {error}");
            super::replies::note_daemon_fetch_failure(&error.to_string());
            return Vec::new();
        }
    };
    let Some(outcomes) = response.get("outcomes").and_then(Value::as_list) else {
        return Vec::new();
    };
    outcomes
        .iter()
        .filter_map(Value::as_dict)
        .filter_map(|outcome| {
            let trace = outcome
                .get("payload")
                .and_then(Value::as_dict)?
                .get("trace_event")
                .and_then(Value::as_dict)?;
            let id = outcome.get("id")?.py_int()?;
            Some((id, trace.clone()))
        })
        .collect()
}

/// `_messenger_outcome_session`: the outcome scope for a target, the
/// bridge's own session for the startup target, else the target's project.
/// RR-469: a keyed target also carries its session key, so PM tabs sharing a
/// project each hear only the runs they dispatched.
pub fn messenger_outcome_session(
    target: Option<&VoiceTarget>,
    fallback: Option<&OrchestratorSession>,
) -> Option<OutcomeScope> {
    let startup_key = targets::startup_key();
    let startup = target.is_none_or(|target| Some(&target.session_key) == startup_key.as_ref());
    let session = match target {
        Some(target) if !startup => Some(OutcomeScope {
            repo_path: target.cwd.clone(),
            provider: target.provider.clone(),
            session_key: String::new(),
        }),
        _ => fallback.map(OrchestratorSession::outcome_scope),
    };
    let key = target
        .map(|target| targets::authorization_key_for_target(Some(target)))
        .unwrap_or_default();
    match session {
        Some(session) if !key.is_empty() => Some(OutcomeScope {
            session_key: key,
            ..session
        }),
        session => session,
    }
}

/// `_deliver_pending_messenger_outcomes_once`: hands the pending outcomes
/// to the messenger, then marks each delivered, or, when the messenger
/// refused them, records the attempt. Returns how many were marked.
pub fn deliver_pending_messenger_outcomes_once(
    scope: Option<&OutcomeScope>,
    messenger: Option<&dyn Messenger>,
    daemon: &dyn Daemon,
) -> usize {
    let Some(messenger) = messenger else {
        return 0;
    };
    let pending = fetch_pending_messenger_outcomes(scope, daemon);
    if pending.is_empty() {
        return 0;
    }
    let accepted = messenger.submit_trace(messenger_outcome_trace(&pending));
    let mut delivered = 0;
    for (outcome_id, _) in &pending {
        if accepted {
            let path = format!("/v1/messenger/outcomes/{outcome_id}/delivered");
            match daemon.post_json(&path, &Dict::new()) {
                Ok(_) => delivered += 1,
                Err(error) => {
                    eprintln!("[voice_bridge] pending messenger outcome ack failed: {error}");
                }
            }
        } else {
            let path = format!("/v1/messenger/outcomes/{outcome_id}/attempt");
            let _ = daemon.post_json(&path, &Dict::new());
        }
    }
    delivered
}

/// `_start_messenger_outcome_polling`: every `MESSENGER_OUTCOME_POLL_SECONDS`
/// until shutdown, delivers the focused session's outcomes; refocusing
/// delivers the rest.
pub fn start_messenger_outcome_polling(
    orchestrator_session: Option<Arc<OrchestratorSession>>,
    messenger: Option<Arc<dyn Messenger>>,
    shutdown_event: Arc<Event>,
    daemon: Arc<dyn Daemon>,
) -> Option<JoinHandle<()>> {
    let (Some(messenger), Some(session)) = (messenger, orchestrator_session) else {
        return None;
    };
    thread::Builder::new()
        .name("messenger-outcome-poll".to_string())
        .spawn(move || {
            let poll_seconds = settings().outcome_poll_seconds.max(0.25);
            while !shutdown_event.is_set() {
                let focused = messenger_outcome_session(
                    targets::current_voice_target().as_ref(),
                    Some(&session),
                );
                deliver_pending_messenger_outcomes_once(
                    focused.as_ref(),
                    Some(messenger.as_ref()),
                    daemon.as_ref(),
                );
                shutdown_event.wait(poll_seconds);
            }
        })
        .ok()
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;
    use std::sync::LazyLock;

    use super::*;

    /// Serializes the tests that set `CONTINUITY_SESSION_NATIVE_ID`.
    static NATIVE_ID: LazyLock<Mutex<()>> = LazyLock::new(Mutex::default);

    fn object(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            other => panic!("not an object: {other:?}"),
        }
    }

    fn dumped(dict: &Dict) -> String {
        json::dumps(&Value::Dict(dict.clone()))
    }

    type Responder = Box<dyn Fn(&str, &str) -> Result<Dict, DaemonError> + Send + Sync>;

    /// The `request_json=` fakes of the Python tests: records each call.
    struct FakeDaemon {
        calls: Mutex<Vec<(String, String, Dict)>>,
        respond: Responder,
    }

    impl FakeDaemon {
        fn new(
            respond: impl Fn(&str, &str) -> Result<Dict, DaemonError> + Send + Sync + 'static,
        ) -> Arc<Self> {
            Arc::new(Self {
                calls: Mutex::default(),
                respond: Box::new(respond),
            })
        }

        fn calls(&self, path: &str) -> Vec<Dict> {
            locked(&self.calls)
                .iter()
                .filter(|(_, called, _)| called == path)
                .map(|(_, _, body)| body.clone())
                .collect()
        }

        fn record(&self, method: &str, path: &str, body: &Dict) -> Result<Dict, DaemonError> {
            locked(&self.calls).push((method.to_string(), path.to_string(), body.clone()));
            (self.respond)(method, path)
        }
    }

    impl Daemon for FakeDaemon {
        fn post_json(&self, path: &str, payload: &Dict) -> Result<Dict, DaemonError> {
            self.record("POST", path, payload)
        }

        fn get_json(&self, path: &str, params: &Dict) -> Result<Dict, DaemonError> {
            self.record("GET", path, params)
        }
    }

    #[derive(Default)]
    struct FakeMessenger {
        refuse: bool,
        traces: Mutex<Vec<Dict>>,
    }

    impl Messenger for FakeMessenger {
        fn start(&self) {}
        fn submit_user(&self, _text: &str, _command: &Dict) -> bool {
            true
        }
        fn update_user_context(&self, _command: &Dict) -> bool {
            true
        }
        fn submit_trace(&self, trace: Dict) -> bool {
            locked(&self.traces).push(trace);
            !self.refuse
        }
        fn submit_final(&self, _payload: Dict) -> bool {
            true
        }
        fn focus(&self, _partition_key: &str) -> bool {
            true
        }
        fn interrupt(&self) {}
        fn recover_backend(&self) -> bool {
            true
        }
        fn shutdown(&self) {}
    }

    fn wait_for(condition: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !condition() {
            assert!(Instant::now() < deadline, "condition not met in time");
            thread::sleep(Duration::from_millis(10));
        }
    }

    /// One connection's request, answered with `response`.
    fn serve_once(response: &'static [u8]) -> (u16, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request = String::new();
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                request.push_str(&line);
                if line == "\r\n" {
                    break;
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            request.push_str(&String::from_utf8(body).unwrap());
            let mut stream = reader.into_inner();
            stream.write_all(response).unwrap();
            request
        });
        (port, server)
    }

    #[test]
    fn query_is_urlencoded_without_empty_values() {
        let params = object(
            r#"{"repo_path": "/tmp/a b/ü", "provider": null, "limit": 50,
                "session_key": "", "live_session_keys": "a,b", "flag": true}"#,
        );
        // urllib.parse.urlencode of the same filtered dict.
        assert_eq!(
            urlencode(&params),
            "repo_path=%2Ftmp%2Fa+b%2F%C3%BC&limit=50&live_session_keys=a%2Cb&flag=True"
        );
    }

    #[test]
    fn port_file_falls_back_to_the_default() {
        let folder = std::env::temp_dir().join(format!("rr-orch-port-{}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        let file = folder.join("port");
        let file_text = file.to_string_lossy().into_owned();
        let default = settings().orchestrator_default_port;
        assert_eq!(orchestrator_port(&file_text), default);
        for (text, port) in [
            ("7700\n", 7700),
            ("", default),
            ("junk", default),
            ("70000", default),
        ] {
            fs::write(&file, text).unwrap();
            assert_eq!(orchestrator_port(&file_text), port, "{text:?}");
        }
        let _ = fs::remove_dir_all(folder);
    }

    #[test]
    fn post_sends_json_and_reads_a_sized_response() {
        let (port, server) = serve_once(
            b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"ok\": true}    ",
        );
        let payload = object(r#"{"reason": "bridge stopped", "session_id": 41}"#);
        let body = json::dumps(&Value::Dict(payload));
        let response = exchange(
            port,
            "POST",
            "/v1/orchestrator-session/stop",
            Some(&body),
            REQUEST_TIMEOUT,
        )
        .unwrap();
        assert_eq!(dumped(&response), r#"{"ok": true}"#);
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /v1/orchestrator-session/stop HTTP/1.1\r\n"));
        assert!(request.contains("Content-Type: application/json\r\n"));
        assert!(request.contains("Content-Length: 46\r\n"));
        assert!(request.ends_with("\r\n\r\n{\"reason\": \"bridge stopped\", \"session_id\": 41}"));
    }

    #[test]
    fn chunked_and_unsized_responses_are_read() {
        let (port, server) = serve_once(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\":\r\n3;x=y\r\n 1}\r\n0\r\n\r\n",
        );
        let response = exchange(port, "GET", "/v1/runs?limit=32", None, REQUEST_TIMEOUT).unwrap();
        assert_eq!(dumped(&response), r#"{"a": 1}"#);
        assert!(
            server
                .join()
                .unwrap()
                .starts_with("GET /v1/runs?limit=32 HTTP/1.1\r\n")
        );

        let (port, server) = serve_once(b"HTTP/1.0 200 OK\r\n\r\n[1, 2]");
        assert!(
            exchange(port, "GET", "/", None, REQUEST_TIMEOUT)
                .unwrap()
                .is_empty()
        );
        server.join().unwrap();

        let (port, server) = serve_once(b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n");
        assert!(
            exchange(port, "GET", "/", None, REQUEST_TIMEOUT)
                .unwrap()
                .is_empty()
        );
        server.join().unwrap();
    }

    #[test]
    fn failures_are_errors() {
        let (port, server) = serve_once(
            b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 29\r\n\r\n{\"error\": \"scripted failure\"}",
        );
        let error = exchange(port, "POST", "/", Some("{}"), REQUEST_TIMEOUT).unwrap_err();
        assert_eq!(error.to_string(), "HTTP Error 503: Service Unavailable");
        server.join().unwrap();

        let (port, server) = serve_once(b"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nnope");
        assert!(matches!(
            exchange(port, "GET", "/", None, REQUEST_TIMEOUT),
            Err(DaemonError::Json)
        ));
        server.join().unwrap();

        let closed = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let refused = exchange(closed, "GET", "/", None, REQUEST_TIMEOUT).unwrap_err();
        assert!(!refused.timed_out());

        let silent = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = silent.local_addr().unwrap().port();
        let error = exchange(port, "GET", "/", None, Duration::from_millis(100)).unwrap_err();
        assert!(error.timed_out());
        assert!(error.to_string().contains("timed out"));
    }

    #[test]
    fn sha1_matches_hashlib() {
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(sha1_hex(b""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(
            sha1_hex(&[b'a'; 1000]),
            "291e9a6c66994949b57ba5e650361e98fc36b1ba"
        );
    }

    #[test]
    fn bridge_model_and_effort_come_from_general() {
        let cfg = object(
            r#"{"general": {"provider": "Claude Code", "model": " Opus ", "orchestrator_effort": ""}}"#,
        );
        assert_eq!(bridge_model(&cfg).as_deref(), Some("opus"));
        assert_eq!(bridge_effort(&cfg), None);
        assert_eq!(bridge_model(&Dict::new()), None);
        if env_text("RELAY_RUNNER_PROVIDER").is_empty() {
            assert_eq!(bridge_provider(&cfg), "claude");
            assert_eq!(
                bridge_provider(&object(r#"{"general": {"provider": "gpt"}}"#)),
                "codex"
            );
            assert_eq!(bridge_provider(&Dict::new()), "codex");
        }
    }

    #[test]
    fn continuity_events_carry_only_lifecycle_identity() {
        let _serial = locked(&NATIVE_ID);
        set_continuity_session_native_id(None);
        let daemon = FakeDaemon::new(|_, _| Ok(object(r#"{"accepted": true}"#)));
        assert!(
            post_continuity_event("stt", "capture_failed", None, None, daemon.as_ref()).is_empty()
        );
        let metadata = object(
            r#"{"session_id": 41, "relay_command_id": "c-1", "provider": "claude",
                "recovery_generation": 3, "source_text": "private"}"#,
        );
        let answer = post_continuity_event(
            "bridge",
            "command_received",
            Some(&metadata),
            Some(1.5),
            daemon.as_ref(),
        );
        assert_eq!(dumped(&answer), r#"{"accepted": true}"#);
        let invalid = object(r#"{"session_id": 41, "recovery_generation": "-bad"}"#);
        post_continuity_event(
            "bridge",
            "command_received",
            Some(&invalid),
            None,
            daemon.as_ref(),
        );
        let posted = daemon.calls("/v1/continuity/observation");
        assert_eq!(posted.len(), 1);
        assert_eq!(
            dumped(&posted[0]),
            r#"{"source": "bridge", "event": "command_received", "session_id": 41, "relay_command_id": "c-1", "provider": "claude", "recovery_generation": "3", "observed_at": 1.5}"#
        );

        set_continuity_session_native_id(Some("project:abc".to_string()));
        observe_stt_continuity_signal(" Transcription_Failed ", daemon.as_ref());
        observe_stt_continuity_signal("unknown_signal", daemon.as_ref());
        observe_stt_status("(refining) hello", daemon.as_ref());
        observe_stt_status("listening", daemon.as_ref());
        set_continuity_session_native_id(None);
        let posted = daemon.calls("/v1/continuity/observation");
        let events: Vec<String> = posted[1..]
            .iter()
            .map(|event| event.string("event"))
            .collect();
        assert_eq!(events, ["transcription_failed", "transcription_started"]);
        assert_eq!(posted[1].string("session_id"), "project:abc");
        assert_eq!(posted[1].string("source"), "stt");
    }

    #[test]
    fn lifecycle_registers_heartbeats_and_stops() {
        let _serial = locked(&NATIVE_ID);
        let daemon = FakeDaemon::new(|_, path| {
            Ok(object(if path == "/v1/orchestrator-session/ensure" {
                r#"{"orchestrator_session": {"id": 41, "session_key": "project:contract"},
                    "recoverable_commands": [{"status": "delivery_failed"}, "junk"]}"#
            } else {
                r#"{"orchestrator_session": {"id": 41}}"#
            }))
        });
        let cwd = std::env::temp_dir();
        let cfg = object(r#"{"general": {"provider": "codex", "model": "Luna"}}"#);
        let session = start_persistent_orchestrator_lifecycle(
            &cfg,
            Arc::new(Event::default()),
            Some(&cwd.to_string_lossy()),
            "",
            daemon.clone(),
        )
        .unwrap();
        let repo_path = fs::canonicalize(&cwd)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let ensure = &daemon.calls("/v1/orchestrator-session/ensure")[0];
        assert_eq!(ensure.string("repo_path"), repo_path);
        assert_eq!(ensure.string("model"), "luna");
        assert!(matches!(ensure.get("effort"), Some(Value::Null)));
        assert_eq!(ensure.string("source"), "relay-bridge");
        assert_eq!(
            ensure.get("pid").and_then(Value::py_int),
            Some(i64::from(std::process::id()))
        );
        assert_eq!(ensure.string("state"), "idle");
        assert!(
            matches!(ensure.get("command_action_states"), Some(Value::List(states)) if states.is_empty())
        );
        assert_eq!(session.session_id, 41);
        assert_eq!(session.session_key, "project:contract");
        assert_eq!(session.recoverable_commands.len(), 1);
        assert_eq!(
            continuity_session_native_id().as_deref(),
            Some("project:contract")
        );

        wait_for(|| {
            !daemon
                .calls("/v1/orchestrator-session/heartbeat")
                .is_empty()
        });
        let heartbeat = &daemon.calls("/v1/orchestrator-session/heartbeat")[0];
        assert_eq!(
            heartbeat.get("session_id").and_then(Value::py_int),
            Some(41)
        );
        assert_eq!(heartbeat.string("repo_path"), repo_path);
        assert_eq!(heartbeat.string("state"), "idle");
        assert!(session.heartbeat_running());

        stop_persistent_orchestrator_lifecycle(Some(&session), "bridge stopped", daemon.as_ref());
        assert!(!session.heartbeat_running());
        assert_eq!(
            dumped(&daemon.calls("/v1/orchestrator-session/stop")[0]),
            r#"{"reason": "bridge stopped", "session_id": 41}"#
        );
        assert_eq!(continuity_session_native_id(), None);
    }

    #[test]
    fn lifecycle_is_absent_without_a_session_id() {
        let _serial = locked(&NATIVE_ID);
        for answer in [
            Err(DaemonError::TimedOut),
            Ok(object(r#"{"orchestrator_session": {"id": 0}}"#)),
            Ok(object(r#"{"orchestrator_session": {"id": "forty-one"}}"#)),
        ] {
            let answer = Mutex::new(Some(answer));
            let daemon = FakeDaemon::new(move |_, _| {
                locked(&answer).take().unwrap_or_else(|| Ok(Dict::new()))
            });
            let session = start_persistent_orchestrator_lifecycle(
                &Dict::new(),
                Arc::new(Event::default()),
                Some("/"),
                "",
                daemon.clone(),
            );
            assert!(session.is_none());
            assert!(
                daemon
                    .calls("/v1/orchestrator-session/heartbeat")
                    .is_empty()
            );
        }
    }

    #[test]
    fn target_lifecycle_keeps_the_bridge_continuity_identity() {
        let _serial = locked(&NATIVE_ID);
        set_continuity_session_native_id(Some("project:bridge".to_string()));
        let daemon = FakeDaemon::new(|_, _| Ok(object(r#"{"orchestrator_session": {"id": 7}}"#)));
        let target = VoiceTarget {
            cwd: "/".to_string(),
            ..VoiceTarget::default()
        };
        let session = start_target_orchestrator(&Dict::new(), &target, daemon.clone()).unwrap();
        assert_eq!(
            session.session_key,
            format!("project:{}", &sha1_hex(b"/")[..16])
        );
        assert_eq!(
            continuity_session_native_id().as_deref(),
            Some("project:bridge")
        );
        stop_persistent_orchestrator_lifecycle(
            Some(&session),
            "voice session ended",
            daemon.as_ref(),
        );
        assert_eq!(
            continuity_session_native_id().as_deref(),
            Some("project:bridge")
        );
        set_continuity_session_native_id(None);
    }

    fn session_with(commands: &str) -> OrchestratorSession {
        let commands = match json::parse(commands) {
            Some(Value::List(items)) => items.iter().filter_map(Value::as_dict).cloned().collect(),
            _ => Vec::new(),
        };
        OrchestratorSession::new(
            41,
            "project:contract",
            "/repo",
            "codex",
            commands,
            Arc::default(),
        )
    }

    #[test]
    fn recoverable_commands_are_surfaced() {
        let states = Mutex::new(Vec::new());
        let notify = |state: &str, fields: Dict| {
            locked(&states).push((state.to_string(), fields.string("text")))
        };
        let messenger = FakeMessenger::default();
        assert_eq!(
            surface_recoverable_command_status(None, Some(&messenger), &notify),
            None
        );
        assert_eq!(
            surface_recoverable_command_status(Some(&session_with("[]")), None, &notify),
            None
        );
        let failed = surface_recoverable_command_status(
            Some(&session_with(r#"[{"status": "delivery_failed"}]"#)),
            Some(&messenger),
            &notify,
        )
        .unwrap();
        assert_eq!(
            failed,
            "Delivery failed for 1 previous project-work request before a ticket action was \
             confirmed. Repeat the request in this recovered session; completed mutations will \
             not be replayed."
        );
        let waiting = surface_recoverable_command_status(
            Some(&session_with(
                r#"[{"status": "delivery_failed"}, {"status": "clarification_required"}]"#,
            )),
            None,
            &notify,
        )
        .unwrap();
        assert!(
            waiting.starts_with("A previous project-work request is waiting for a target project.")
        );
        let other = surface_recoverable_command_status(
            Some(&session_with(r#"[{"status": "claimed"}, {}]"#)),
            None,
            &notify,
        )
        .unwrap();
        assert!(other.starts_with("2 previous project-work requests did not reach"));
        assert_eq!(
            *locked(&states),
            [
                ("working".to_string(), failed.clone()),
                ("working".to_string(), waiting),
                ("working".to_string(), other)
            ]
        );
        let traces = locked(&messenger.traces);
        assert_eq!(traces.len(), 1);
        assert_eq!(traces[0].string("kind"), "command-recovery");
        assert_eq!(traces[0].string("message"), failed);
        assert_eq!(traces[0].string("source"), "orchestrator");
    }

    #[test]
    fn pm_update_mode_mirrors_its_state_onto_the_session() {
        let session = Arc::new(session_with("[]"));
        let daemon = FakeDaemon::new(|_, _| Ok(Dict::new()));
        let notify: NotifyState = Arc::new(|_, _| {});
        let never = |_: Arc<PmUpdateSources>| -> Option<PmUpdatePoll> { panic!("not started") };
        assert!(
            start_pm_update_mode(
                "answer_question",
                Some(&session),
                None,
                notify.clone(),
                daemon.clone(),
                never
            )
            .is_none()
        );
        assert!(
            start_pm_update_mode(
                "create_ticket",
                None,
                None,
                notify.clone(),
                daemon.clone(),
                never
            )
            .is_none()
        );
        let unparsable = |_: Arc<PmUpdateSources>| None;
        assert!(
            start_pm_update_mode(
                "create_ticket",
                Some(&session),
                None,
                notify.clone(),
                daemon.clone(),
                unparsable
            )
            .is_none()
        );
        assert_eq!(session.state(), "idle");

        let seen = Arc::new(Mutex::new(Vec::new()));
        let steps = Mutex::new(vec![("reviewing", true), ("idle", false)].into_iter());
        let observed = seen.clone();
        let observed_session = session.clone();
        let thread = start_pm_update_mode(
            "dispatch_ticket",
            Some(&session),
            None,
            notify.clone(),
            daemon.clone(),
            move |sources| {
                assert_eq!(sources.repo_path, "/repo");
                assert_eq!(sources.provider.as_deref(), Some("codex"));
                assert_eq!(sources.session_id, Some(41));
                Some(Box::new(move || {
                    locked(&observed).push(observed_session.state());
                    let (state, continue_running) = locked(&steps).next().unwrap();
                    Ok(PmUpdateStep {
                        continue_running,
                        state: state.to_string(),
                        stale: false,
                    })
                }))
            },
        )
        .unwrap();
        thread.join().unwrap();
        assert_eq!(*locked(&seen), ["planning", "reviewing"]);
        assert_eq!(session.state(), "idle");

        let failing = |_: Arc<PmUpdateSources>| -> Option<PmUpdatePoll> {
            Some(Box::new(|| Err(DaemonError::TimedOut)))
        };
        start_pm_update_mode(
            "update_ticket",
            Some(&session),
            None,
            notify,
            daemon,
            failing,
        )
        .unwrap()
        .join()
        .unwrap();
        assert_eq!(session.state(), "blocked");
    }

    #[test]
    fn pm_update_sources_fetch_status_and_emit() {
        let daemon = FakeDaemon::new(|_, path| Ok(object(&format!(r#"{{"path": "{path}"}}"#))));
        let states = Arc::new(Mutex::new(Vec::new()));
        let recorded = states.clone();
        let messenger = Arc::new(FakeMessenger::default());
        let sources = PmUpdateSources {
            repo_path: "/repo".to_string(),
            provider: None,
            session_id: Some(41),
            state_path: String::new(),
            messenger: Some(messenger.clone()),
            notify_state: Arc::new(move |state, fields| {
                locked(&recorded).push((state.to_string(), fields))
            }),
            daemon: daemon.clone(),
        };
        let payloads = sources.fetch_status().unwrap();
        assert_eq!(
            payloads.sessions.string("path"),
            "/v1/orchestrator-sessions"
        );
        assert_eq!(payloads.runs.string("path"), "/v1/runs");
        assert_eq!(payloads.program.string("path"), "/v1/program/status");
        assert_eq!(
            urlencode(&daemon.calls("/v1/orchestrator-sessions")[0]),
            "repo_path=%2Frepo&limit=8"
        );
        assert_eq!(urlencode(&daemon.calls("/v1/runs")[0]), "limit=32");
        assert_eq!(
            urlencode(&daemon.calls("/v1/program/status")[0]),
            "query=summary&limit=0"
        );

        let event = object(
            r#"{"phase": "working", "message": "Worker RR-7 is running.", "source": "worker",
                "command": {"relay_command_seq": 3, "relay_command_id": "c-3"}}"#,
        );
        sources.emit(&event);
        let states = locked(&states);
        assert_eq!(states[0].0, "working");
        assert_eq!(states[0].1.string("text"), "Worker RR-7 is running.");
        assert_eq!(
            dumped(
                states[0]
                    .1
                    .get("status_event")
                    .and_then(Value::as_dict)
                    .unwrap()
            ),
            dumped(&event)
        );
        assert_eq!(
            dumped(&locked(&messenger.traces)[0]),
            r#"{"kind": "pm-update", "message": "Worker RR-7 is running.", "source": "worker", "command": {"relay_command_seq": 3, "relay_command_id": "c-3"}, "ticket_id": null, "run_id": null}"#
        );
    }

    #[test]
    fn outcome_params_and_scope() {
        let params = pending_messenger_outcome_params(Some(&OutcomeScope {
            repo_path: "/repo".to_string(),
            provider: " codex ".to_string(),
            session_key: String::new(),
        }));
        assert_eq!(
            dumped(&params),
            r#"{"repo_path": "/repo", "provider": "codex", "limit": 50}"#
        );
        let keyed = pending_messenger_outcome_params(Some(&session_with("[]").outcome_scope()));
        assert_eq!(keyed.string("session_key"), "project:contract");
        assert!(keyed.get("live_session_keys").is_some());
        let unscoped = pending_messenger_outcome_params(None);
        assert_eq!(unscoped.string("repo_path"), store::current_dir());
        assert!(matches!(unscoped.get("provider"), Some(Value::Null)));

        let fallback = session_with("[]");
        assert_eq!(
            messenger_outcome_session(None, Some(&fallback)),
            Some(fallback.outcome_scope())
        );
        assert_eq!(messenger_outcome_session(None, None), None);
        // A target outside the sessions root carries no session key.
        let manual = VoiceTarget {
            session_key: "rr-orch-test-manual".to_string(),
            cwd: "/elsewhere".to_string(),
            provider: "claude".to_string(),
            spool_dir: "/not/the/sessions/root/rr-orch-test-manual".to_string(),
            ..VoiceTarget::default()
        };
        assert_eq!(
            messenger_outcome_session(Some(&manual), Some(&fallback)),
            Some(OutcomeScope {
                repo_path: "/elsewhere".to_string(),
                provider: "claude".to_string(),
                session_key: String::new(),
            })
        );
        // A keyed app session's own key replaces the session's.
        let app = VoiceTarget {
            session_key: "rr-orch-test-app".to_string(),
            cwd: "/project".to_string(),
            spool_dir: format!("{}/rr-orch-test-app", settings().sessions_root),
            ..VoiceTarget::default()
        };
        assert_eq!(
            messenger_outcome_session(Some(&app), Some(&fallback)).map(|scope| scope.session_key),
            Some("rr-orch-test-app".to_string())
        );
    }

    #[test]
    fn several_outcomes_are_summarised_as_one_update() {
        let one =
            object(r#"{"kind": "run-merged", "message": "RR-7 merged.", "ticket_id": "rr-7"}"#);
        assert_eq!(
            dumped(&messenger_outcome_trace(&[(7, one.clone())])),
            dumped(&one)
        );
        let two = object(r#"{"kind": "run-failed", "ticket_id": " RR-7 "}"#);
        let three = object(r#"{"kind": "run-merged", "ticket_id": "RR-9"}"#);
        assert_eq!(
            dumped(&messenger_outcome_trace(&[
                (7, one.clone()),
                (8, two.clone()),
                (9, three)
            ])),
            r#"{"kind": "run-health-warning", "message": "3 Relay work updates accumulated while this session was away across 2 tickets. Open Workspace for current status.", "source": "orchestrator", "ticket_ids": ["RR-7", "RR-9"], "outcome_count": 3}"#
        );
        assert_eq!(
            messenger_outcome_trace(&[(7, one), (8, two)]).string("message"),
            "2 Relay work updates accumulated while this session was away across 1 ticket. Open Workspace for current status."
        );
    }

    fn outcomes_daemon() -> Arc<FakeDaemon> {
        FakeDaemon::new(|method, path| {
            Ok(if method == "GET" && path == "/v1/messenger/outcomes" {
                object(
                    r#"{"outcomes": [
                        {"id": 7, "payload": {"trace_event": {"kind": "run-merged", "message": "RR-7 merged into main."}}},
                        {"id": null, "payload": {"trace_event": {"kind": "x"}}},
                        {"id": 8, "payload": {"trace_event": "not a trace"}},
                        "junk"]}"#,
                )
            } else {
                Dict::new()
            })
        })
    }

    #[test]
    fn delivered_outcomes_are_acknowledged_and_refused_ones_attempted() {
        let scope = session_with("[]").outcome_scope();
        let daemon = outcomes_daemon();
        assert_eq!(
            deliver_pending_messenger_outcomes_once(Some(&scope), None, daemon.as_ref()),
            0
        );
        assert!(daemon.calls("/v1/messenger/outcomes").is_empty());

        let messenger = FakeMessenger::default();
        assert_eq!(
            deliver_pending_messenger_outcomes_once(
                Some(&scope),
                Some(&messenger),
                daemon.as_ref()
            ),
            1
        );
        assert_eq!(
            locked(&messenger.traces)[0].string("message"),
            "RR-7 merged into main."
        );
        assert_eq!(daemon.calls("/v1/messenger/outcomes/7/delivered").len(), 1);
        assert_eq!(
            dumped(&daemon.calls("/v1/messenger/outcomes/7/delivered")[0]),
            "{}"
        );

        let refusing = FakeMessenger {
            refuse: true,
            ..FakeMessenger::default()
        };
        assert_eq!(
            deliver_pending_messenger_outcomes_once(Some(&scope), Some(&refusing), daemon.as_ref()),
            0
        );
        assert_eq!(daemon.calls("/v1/messenger/outcomes/7/attempt").len(), 1);
        assert_eq!(daemon.calls("/v1/messenger/outcomes/7/delivered").len(), 1);

        let unavailable = FakeDaemon::new(|_, _| Err(DaemonError::TimedOut));
        assert!(fetch_pending_messenger_outcomes(Some(&scope), unavailable.as_ref()).is_empty());
    }

    #[test]
    fn outcome_polling_runs_until_shutdown() {
        let daemon = outcomes_daemon();
        let messenger = Arc::new(FakeMessenger::default());
        let shutdown = Arc::new(Event::default());
        assert!(
            start_messenger_outcome_polling(
                None,
                Some(messenger.clone()),
                shutdown.clone(),
                daemon.clone()
            )
            .is_none()
        );
        let session = Arc::new(session_with("[]"));
        assert!(
            start_messenger_outcome_polling(
                Some(session.clone()),
                None,
                shutdown.clone(),
                daemon.clone()
            )
            .is_none()
        );
        let thread = start_messenger_outcome_polling(
            Some(session),
            Some(messenger.clone()),
            shutdown.clone(),
            daemon.clone(),
        )
        .unwrap();
        wait_for(|| {
            !daemon
                .calls("/v1/messenger/outcomes/7/delivered")
                .is_empty()
        });
        shutdown.set();
        thread.join().unwrap();
    }
}
