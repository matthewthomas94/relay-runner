//! Relay Remote wire protocol (docs/specs/relay-remote.md, "Wire protocol").
//!
//! Rust twin of `services/relay_remote_protocol.py` and
//! `Sources/RelayRemoteProtocol`. All three agree byte for byte on
//! `tests/RelayRemoteProtocolTests/Vectors`. Pure data code: no sockets.
//!
//! Every frame is checked against one field table on the way in and on the
//! way out, as the Python twin's `_validate` is, so an invalid frame never
//! reaches the wire and an invalid line never becomes a frame.

use std::collections::{HashSet, VecDeque};

use crate::json::{self, Dict, Value};

pub const PROTOCOL_VERSION: i64 = 1;
pub const MAX_LINE_BYTES: usize = 64 * 1024;
pub const DEFAULT_DEDUP_WINDOW: usize = 1024;
pub const REPLAY_MAX_FRAMES: usize = 200;
pub const REPLAY_MAX_AGE: f64 = 300.0;
/// RR-457: base64 bytes of Mac-voiced audio per `speech_audio` frame.
pub const MAX_AUDIO_DATA_BYTES: usize = 32 * 1024;

const CONTROL_ACTIONS: &[&str] = &["stop", "interrupt", "cancel", "play", "replay"];
const SPEECH_CONTROL_ACTIONS: &[&str] = &["stop", "skip"];
const SPOKEN_BY: &[&str] = &["mac", "phone"];
const AUDIO_FORMATS: &[&str] = &["aac", "opus"];
/// RR-456: session control from the phone.
const SESSION_ACTIONS: &[&str] = &["list_projects", "start", "stop", "state"];
const SESSION_PHASES: &[&str] = &["none", "starting", "ready", "failed"];
/// `speech_coordinator.SPEECH_KINDS` and `SPEECH_SOURCES`.
const SPEECH_KINDS: &[&str] = &[
    "handoff",
    "progress",
    "clarification",
    "final",
    "fallback",
    "control",
];
const SPEECH_SOURCES: &[&str] = &[
    "messenger",
    "orchestrator",
    "lifecycle",
    "completion",
    "fallback",
];

/// `code` strings are identical to the Swift and Python `FrameError` codes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameError {
    pub code: &'static str,
    pub detail: String,
}

impl FrameError {
    fn new(code: &'static str, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }

    fn invalid(field: &str) -> Self {
        Self::new("invalid_field", field)
    }
}

// -- Frames -------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub struct Hello {
    pub device_id: String,
    pub device_name: String,
    pub app_version: String,
    pub resume_after_seq: Option<i64>,
    /// RR-454: the phone's Remote mode switch; absent means on.
    pub remote_mode: Option<bool>,
    pub protocol: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Utterance {
    pub client_id: String,
    pub text: String,
    pub captured_at: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Control {
    pub client_id: String,
    pub action: String,
}

/// RR-454: on, the phone owns mic and speaker; off, speech plays on the Mac.
#[derive(Clone, Debug, PartialEq)]
pub struct RemoteMode {
    pub client_id: String,
    pub enabled: bool,
}

/// RR-456: list projects, or start, stop or inspect the Mac's session.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionCommand {
    pub client_id: String,
    pub action: String,
    pub project_id: Option<String>,
}

/// One registered project inside `SessionState::projects` (not a frame).
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectEntry {
    pub project_id: String,
    pub display_name: String,
    pub availability: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Ack {
    pub seq: i64,
    pub played: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Welcome {
    pub session_state: String,
    pub server_seq: i64,
    pub dropped: bool,
    pub resumed_from: Option<i64>,
    pub protocol: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Accepted {
    pub client_id: String,
    pub relay_command_seq: i64,
    pub relay_command_id: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Speech {
    pub seq: i64,
    pub kind: String,
    pub source: String,
    pub text: String,
    pub relay_command_seq: Option<i64>,
    /// RR-454: `mac` means Kokoro speaks it and the phone only shows the text.
    pub spoken_by: Option<String>,
    /// RR-457: true when `speech_audio` parts in the Mac's voice follow.
    pub audio: Option<bool>,
}

/// RR-457: one slice of the Mac's voice for the `speech` frame `seq`. It takes
/// no seq of its own and is replayed with the frame it voices.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeechAudio {
    pub seq: i64,
    pub part: i64,
    pub parts: i64,
    pub format: String,
    pub sample_rate: i64,
    pub data: String,
    pub last: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpeechControl {
    pub seq: i64,
    pub action: String,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    pub seq: i64,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ErrorFrame {
    pub code: String,
    pub message: String,
}

/// RR-456: Relay Runner's session as the Mac app reports it.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionState {
    pub app_running: bool,
    pub session: String,
    pub project_id: Option<String>,
    pub project_name: Option<String>,
    pub projects: Option<Vec<ProjectEntry>>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Frame {
    Hello(Hello),
    Utterance(Utterance),
    Control(Control),
    RemoteMode(RemoteMode),
    SessionCommand(SessionCommand),
    Ack(Ack),
    Ping { t: i64 },
    Welcome(Welcome),
    Accepted(Accepted),
    Speech(Speech),
    SpeechAudio(SpeechAudio),
    SpeechControl(SpeechControl),
    Status(Status),
    Error(ErrorFrame),
    Pong { t: i64 },
    SessionState(SessionState),
}

impl Frame {
    pub fn type_name(&self) -> &'static str {
        match self {
            Frame::Hello(_) => "hello",
            Frame::Utterance(_) => "utterance",
            Frame::Control(_) => "control",
            Frame::RemoteMode(_) => "remote_mode",
            Frame::SessionCommand(_) => "session_command",
            Frame::Ack(_) => "ack",
            Frame::Ping { .. } => "ping",
            Frame::Welcome(_) => "welcome",
            Frame::Accepted(_) => "accepted",
            Frame::Speech(_) => "speech",
            Frame::SpeechAudio(_) => "speech_audio",
            Frame::SpeechControl(_) => "speech_control",
            Frame::Status(_) => "status",
            Frame::Error(_) => "error",
            Frame::Pong { .. } => "pong",
            Frame::SessionState(_) => "session_state",
        }
    }

    /// The sequence number a replayable frame takes; `speech_audio` takes none.
    pub fn seq(&self) -> Option<i64> {
        match self {
            Frame::Speech(frame) => Some(frame.seq),
            Frame::SpeechControl(frame) => Some(frame.seq),
            Frame::Status(frame) => Some(frame.seq),
            _ => None,
        }
    }

    pub fn error(code: &str, message: &str) -> Frame {
        Frame::Error(ErrorFrame {
            code: code.to_string(),
            message: message.to_string(),
        })
    }

    /// The frame's fields as a JSON object, `None` fields left out.
    fn to_dict(&self) -> Dict {
        let mut out = Dict::new();
        fn opt<T: Clone + Into<Value>>(out: &mut Dict, key: &str, value: &Option<T>) {
            if let Some(value) = value {
                out.insert(key, value.clone());
            }
        }
        match self {
            Frame::Hello(f) => {
                out.insert("device_id", f.device_id.as_str());
                out.insert("device_name", f.device_name.as_str());
                out.insert("app_version", f.app_version.as_str());
                opt(&mut out, "resume_after_seq", &f.resume_after_seq);
                opt(&mut out, "remote_mode", &f.remote_mode);
                out.insert("protocol", f.protocol);
            }
            Frame::Utterance(f) => {
                out.insert("client_id", f.client_id.as_str());
                out.insert("text", f.text.as_str());
                out.insert("captured_at", f.captured_at.as_str());
            }
            Frame::Control(f) => {
                out.insert("client_id", f.client_id.as_str());
                out.insert("action", f.action.as_str());
            }
            Frame::RemoteMode(f) => {
                out.insert("client_id", f.client_id.as_str());
                out.insert("enabled", f.enabled);
            }
            Frame::SessionCommand(f) => {
                out.insert("client_id", f.client_id.as_str());
                out.insert("action", f.action.as_str());
                opt(&mut out, "project_id", &f.project_id);
            }
            Frame::Ack(f) => {
                out.insert("seq", f.seq);
                out.insert("played", f.played);
            }
            Frame::Ping { t } | Frame::Pong { t } => out.insert("t", *t),
            Frame::Welcome(f) => {
                out.insert("session_state", f.session_state.as_str());
                out.insert("server_seq", f.server_seq);
                out.insert("dropped", f.dropped);
                opt(&mut out, "resumed_from", &f.resumed_from);
                out.insert("protocol", f.protocol);
            }
            Frame::Accepted(f) => {
                out.insert("client_id", f.client_id.as_str());
                out.insert("relay_command_seq", f.relay_command_seq);
                out.insert("relay_command_id", f.relay_command_id.as_str());
            }
            Frame::Speech(f) => {
                out.insert("seq", f.seq);
                out.insert("kind", f.kind.as_str());
                out.insert("source", f.source.as_str());
                out.insert("text", f.text.as_str());
                opt(&mut out, "relay_command_seq", &f.relay_command_seq);
                opt(&mut out, "spoken_by", &f.spoken_by);
                opt(&mut out, "audio", &f.audio);
            }
            Frame::SpeechAudio(f) => {
                out.insert("seq", f.seq);
                out.insert("part", f.part);
                out.insert("parts", f.parts);
                out.insert("format", f.format.as_str());
                out.insert("sample_rate", f.sample_rate);
                out.insert("data", f.data.as_str());
                opt(&mut out, "last", &f.last);
            }
            Frame::SpeechControl(f) => {
                out.insert("seq", f.seq);
                out.insert("action", f.action.as_str());
                opt(&mut out, "reason", &f.reason);
            }
            Frame::Status(f) => {
                out.insert("seq", f.seq);
                out.insert("text", f.text.as_str());
            }
            Frame::Error(f) => {
                out.insert("code", f.code.as_str());
                out.insert("message", f.message.as_str());
            }
            Frame::SessionState(f) => {
                out.insert("app_running", f.app_running);
                out.insert("session", f.session.as_str());
                opt(&mut out, "project_id", &f.project_id);
                opt(&mut out, "project_name", &f.project_name);
                if let Some(projects) = &f.projects {
                    let items = projects
                        .iter()
                        .map(|entry| {
                            let mut item = Dict::new();
                            item.insert("project_id", entry.project_id.as_str());
                            item.insert("display_name", entry.display_name.as_str());
                            item.insert("availability", entry.availability.as_str());
                            Value::Dict(item)
                        })
                        .collect::<Vec<_>>();
                    out.insert("projects", items);
                }
                opt(&mut out, "error", &f.error);
            }
        }
        out
    }
}

// -- The field table ------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Str,
    Int,
    Bool,
    /// `session_state.projects`: a list of `ProjectEntry` objects.
    Projects,
}

struct Field {
    name: &'static str,
    kind: Kind,
    optional: bool,
}

const fn req(name: &'static str, kind: Kind) -> Field {
    Field {
        name,
        kind,
        optional: false,
    }
}

const fn opt(name: &'static str, kind: Kind) -> Field {
    Field {
        name,
        kind,
        optional: true,
    }
}

use Kind::{Bool, Int, Projects, Str};

/// Each frame's fields in the Python dataclass order, which decides which
/// field an error names first.
fn fields(type_name: &str) -> Option<&'static [Field]> {
    Some(match type_name {
        "hello" => {
            const {
                &[
                    req("device_id", Str),
                    req("device_name", Str),
                    req("app_version", Str),
                    opt("resume_after_seq", Int),
                    opt("remote_mode", Bool),
                    req("protocol", Int),
                ]
            }
        }
        "utterance" => {
            const {
                &[
                    req("client_id", Str),
                    req("text", Str),
                    req("captured_at", Str),
                ]
            }
        }
        "control" => const { &[req("client_id", Str), req("action", Str)] },
        "remote_mode" => const { &[req("client_id", Str), req("enabled", Bool)] },
        "session_command" => {
            const {
                &[
                    req("client_id", Str),
                    req("action", Str),
                    opt("project_id", Str),
                ]
            }
        }
        "ack" => const { &[req("seq", Int), req("played", Bool)] },
        "ping" | "pong" => const { &[req("t", Int)] },
        "welcome" => {
            const {
                &[
                    req("session_state", Str),
                    req("server_seq", Int),
                    req("dropped", Bool),
                    opt("resumed_from", Int),
                    req("protocol", Int),
                ]
            }
        }
        "accepted" => {
            const {
                &[
                    req("client_id", Str),
                    req("relay_command_seq", Int),
                    req("relay_command_id", Str),
                ]
            }
        }
        "speech" => {
            const {
                &[
                    req("seq", Int),
                    req("kind", Str),
                    req("source", Str),
                    req("text", Str),
                    opt("relay_command_seq", Int),
                    opt("spoken_by", Str),
                    opt("audio", Bool),
                ]
            }
        }
        "speech_audio" => {
            const {
                &[
                    req("seq", Int),
                    req("part", Int),
                    req("parts", Int),
                    req("format", Str),
                    req("sample_rate", Int),
                    req("data", Str),
                    opt("last", Bool),
                ]
            }
        }
        "speech_control" => const { &[req("seq", Int), req("action", Str), opt("reason", Str)] },
        "status" => const { &[req("seq", Int), req("text", Str)] },
        "error" => const { &[req("code", Str), req("message", Str)] },
        "session_state" => {
            const {
                &[
                    req("app_running", Bool),
                    req("session", Str),
                    opt("project_id", Str),
                    opt("project_name", Str),
                    opt("projects", Projects),
                    opt("error", Str),
                ]
            }
        }
        _ => return None,
    })
}

const PROJECT_FIELDS: &[&str] = &["project_id", "display_name", "availability"];

fn allowed_values(type_name: &str, field: &str) -> Option<&'static [&'static str]> {
    Some(match (type_name, field) {
        ("control", "action") => CONTROL_ACTIONS,
        ("speech_control", "action") => SPEECH_CONTROL_ACTIONS,
        ("speech", "kind") => SPEECH_KINDS,
        ("speech", "source") => SPEECH_SOURCES,
        ("speech", "spoken_by") => SPOKEN_BY,
        ("session_command", "action") => SESSION_ACTIONS,
        ("session_state", "session") => SESSION_PHASES,
        ("speech_audio", "format") => AUDIO_FORMATS,
        _ => return None,
    })
}

fn is_uuid_field(type_name: &str, field: &str) -> bool {
    field == "client_id"
        && matches!(
            type_name,
            "utterance" | "control" | "remote_mode" | "session_command" | "accepted"
        )
}

/// What Python's `uuid.UUID(value)` accepts, short of the sign, whitespace
/// and underscore spellings `int(..., 16)` also allows: optional `urn:` and
/// `uuid:` prefixes and braces, hyphens anywhere, and 32 hex digits.
fn is_uuid(value: &str) -> bool {
    let value = value.replace("urn:", "").replace("uuid:", "");
    let digits: String = value
        .trim_matches(|c| c == '{' || c == '}')
        .chars()
        .filter(|&c| c != '-')
        .collect();
    digits.len() == 32 && digits.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The type check of one value. An integer outside `i64` is refused, as the
/// Swift twin refuses it.
fn kind_matches(kind: Kind, value: &Value) -> bool {
    match kind {
        Str => matches!(value, Value::Str(_)),
        Int => matches!(value, Value::Int(_)),
        Bool => matches!(value, Value::Bool(_)),
        Projects => value.as_list().is_some_and(|items| {
            items.iter().all(|item| {
                item.as_dict().is_some_and(|entry| {
                    PROJECT_FIELDS
                        .iter()
                        .all(|name| matches!(entry.get(name), Some(Value::Str(_))))
                })
            })
        }),
    }
}

/// `_validate`: every field's type, enumerations, client ids and the audio
/// slice size.
fn validate(type_name: &str, frame: &Dict) -> Result<(), FrameError> {
    let table = fields(type_name).ok_or_else(|| FrameError::new("unknown_type", type_name))?;
    for field in table {
        let value = frame.get(field.name).unwrap_or(&Value::Null);
        if matches!(value, Value::Null) && field.optional {
            continue;
        }
        if !kind_matches(field.kind, value) {
            return Err(FrameError::invalid(field.name));
        }
        if let (Some(allowed), Some(text)) = (allowed_values(type_name, field.name), value.as_str())
            && !allowed.contains(&text)
        {
            return Err(FrameError::invalid(field.name));
        }
        if is_uuid_field(type_name, field.name) && !value.as_str().is_some_and(is_uuid) {
            return Err(FrameError::invalid(field.name));
        }
    }
    if type_name == "speech_audio"
        && frame
            .get("data")
            .and_then(Value::as_str)
            .is_some_and(|data| data.len() > MAX_AUDIO_DATA_BYTES)
    {
        return Err(FrameError::invalid("data"));
    }
    Ok(())
}

// -- Encoding -------------------------------------------------------------------

/// One canonical line (sorted keys, compact, non-ASCII as UTF-8) including the
/// trailing newline: `json.dumps(sort_keys=True, separators=(",", ":"),
/// ensure_ascii=False)`, and Swift's `[.sortedKeys, .withoutEscapingSlashes]`.
pub fn encode(frame: &Frame) -> Result<Vec<u8>, FrameError> {
    let mut object = frame.to_dict();
    validate(frame.type_name(), &object)?;
    object.insert("type", frame.type_name());
    let mut line = String::new();
    write_canonical(&mut line, &Value::Dict(object));
    if line.len() > MAX_LINE_BYTES {
        return Err(FrameError::new("line_too_long", line.len().to_string()));
    }
    let mut bytes = line.into_bytes();
    bytes.push(b'\n');
    Ok(bytes)
}

fn write_canonical(out: &mut String, value: &Value) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Int(number) => out.push_str(&number.to_string()),
        Value::Str(text) => write_string(out, text),
        Value::List(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical(out, item);
            }
            out.push(']');
        }
        Value::Dict(dict) => {
            let mut entries: Vec<(&str, &Value)> = dict.iter().collect();
            // UTF-8 byte order is code point order, Python's key order.
            entries.sort_by(|left, right| left.0.cmp(right.0));
            out.push('{');
            for (index, (key, item)) in entries.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(out, key);
                out.push(':');
                write_canonical(out, item);
            }
            out.push('}');
        }
        // No frame field is a float or an integer outside i64.
        Value::BigInt(_) | Value::Float(_) => unreachable!("frames hold no such value"),
    }
}

/// `ensure_ascii=False`: only `"`, `\` and control characters are escaped.
fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            control if (control as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", control as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

// -- Decoding -------------------------------------------------------------------

/// Decode one line; a single trailing newline is accepted.
pub fn decode(line: &[u8]) -> Result<Frame, FrameError> {
    let body = line.strip_suffix(b"\n").unwrap_or(line);
    if body.len() > MAX_LINE_BYTES {
        return Err(FrameError::new("line_too_long", body.len().to_string()));
    }
    let Some(Value::Dict(mut object)) = json::parse_bytes(body) else {
        return Err(FrameError::new("invalid_json", ""));
    };
    let type_name = match object.get("type") {
        None => return Err(FrameError::new("missing_field", "type")),
        Some(Value::Str(name)) if fields(name).is_some() => name.clone(),
        Some(other) => return Err(FrameError::new("unknown_type", other.py_str())),
    };
    let table = fields(&type_name).unwrap_or_default();
    // An absent `protocol` is the dataclass default.
    if table.iter().any(|field| field.name == "protocol") && object.get("protocol").is_none() {
        object.insert("protocol", PROTOCOL_VERSION);
    }
    // Presence and nested shape first, field by field, as the Python twin
    // builds its keyword arguments; types after.
    for field in table {
        match object.get(field.name) {
            Some(value) if field.kind == Projects => check_projects_shape(value)?,
            Some(_) => {}
            None if field.optional => {}
            None => return Err(FrameError::new("missing_field", field.name)),
        }
    }
    validate(&type_name, &object)?;
    Ok(build(&type_name, &object))
}

/// Mirror Swift's decoder: a wrong shape is `invalid_field`, a missing key
/// `missing_field`.
fn check_projects_shape(value: &Value) -> Result<(), FrameError> {
    if matches!(value, Value::Null) {
        return Ok(());
    }
    let items = value
        .as_list()
        .ok_or_else(|| FrameError::invalid("projects"))?;
    for item in items {
        let entry = item
            .as_dict()
            .ok_or_else(|| FrameError::invalid("projects"))?;
        if let Some(name) = PROJECT_FIELDS.iter().find(|name| entry.get(name).is_none()) {
            return Err(FrameError::new("missing_field", *name));
        }
    }
    Ok(())
}

/// A validated object becomes its frame.
fn build(type_name: &str, object: &Dict) -> Frame {
    let s = |key: &str| {
        object
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    let os = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
    let int = |key: &str| match object.get(key) {
        Some(Value::Int(number)) => Some(*number),
        _ => None,
    };
    let i = |key: &str| int(key).unwrap_or_default();
    let ob = |key: &str| match object.get(key) {
        Some(Value::Bool(flag)) => Some(*flag),
        _ => None,
    };
    let b = |key: &str| ob(key).unwrap_or_default();
    match type_name {
        "hello" => Frame::Hello(Hello {
            device_id: s("device_id"),
            device_name: s("device_name"),
            app_version: s("app_version"),
            resume_after_seq: int("resume_after_seq"),
            remote_mode: ob("remote_mode"),
            protocol: i("protocol"),
        }),
        "utterance" => Frame::Utterance(Utterance {
            client_id: s("client_id"),
            text: s("text"),
            captured_at: s("captured_at"),
        }),
        "control" => Frame::Control(Control {
            client_id: s("client_id"),
            action: s("action"),
        }),
        "remote_mode" => Frame::RemoteMode(RemoteMode {
            client_id: s("client_id"),
            enabled: b("enabled"),
        }),
        "session_command" => Frame::SessionCommand(SessionCommand {
            client_id: s("client_id"),
            action: s("action"),
            project_id: os("project_id"),
        }),
        "ack" => Frame::Ack(Ack {
            seq: i("seq"),
            played: b("played"),
        }),
        "ping" => Frame::Ping { t: i("t") },
        "pong" => Frame::Pong { t: i("t") },
        "welcome" => Frame::Welcome(Welcome {
            session_state: s("session_state"),
            server_seq: i("server_seq"),
            dropped: b("dropped"),
            resumed_from: int("resumed_from"),
            protocol: i("protocol"),
        }),
        "accepted" => Frame::Accepted(Accepted {
            client_id: s("client_id"),
            relay_command_seq: i("relay_command_seq"),
            relay_command_id: s("relay_command_id"),
        }),
        "speech" => Frame::Speech(Speech {
            seq: i("seq"),
            kind: s("kind"),
            source: s("source"),
            text: s("text"),
            relay_command_seq: int("relay_command_seq"),
            spoken_by: os("spoken_by"),
            audio: ob("audio"),
        }),
        "speech_audio" => Frame::SpeechAudio(SpeechAudio {
            seq: i("seq"),
            part: i("part"),
            parts: i("parts"),
            format: s("format"),
            sample_rate: i("sample_rate"),
            data: s("data"),
            last: ob("last"),
        }),
        "speech_control" => Frame::SpeechControl(SpeechControl {
            seq: i("seq"),
            action: s("action"),
            reason: os("reason"),
        }),
        "status" => Frame::Status(Status {
            seq: i("seq"),
            text: s("text"),
        }),
        "error" => Frame::Error(ErrorFrame {
            code: s("code"),
            message: s("message"),
        }),
        _ => Frame::SessionState(SessionState {
            app_running: b("app_running"),
            session: s("session"),
            project_id: os("project_id"),
            project_name: os("project_name"),
            projects: object
                .get("projects")
                .and_then(Value::as_list)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_dict)
                        .map(|entry| {
                            let text = |key: &str| {
                                entry
                                    .get(key)
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_string()
                            };
                            ProjectEntry {
                                project_id: text("project_id"),
                                display_name: text("display_name"),
                                availability: text("availability"),
                            }
                        })
                        .collect()
                }),
            error: os("error"),
        }),
    }
}

// -- Session state ----------------------------------------------------------------

/// Per-device monotonically increasing sequence for Mac-to-phone frames.
#[derive(Debug, Default)]
pub struct SeqCounter {
    pub last: i64,
}

impl SeqCounter {
    pub fn next(&mut self) -> i64 {
        self.last += 1;
        self.last
    }
}

/// Remembers the most recent `window` client ids; a duplicate does not refresh.
#[derive(Debug)]
pub struct ClientIdDeduplicator {
    window: usize,
    order: VecDeque<String>,
    seen: HashSet<String>,
}

impl Default for ClientIdDeduplicator {
    fn default() -> Self {
        Self::new(DEFAULT_DEDUP_WINDOW)
    }
}

impl ClientIdDeduplicator {
    pub fn new(window: usize) -> Self {
        Self {
            window,
            order: VecDeque::new(),
            seen: HashSet::new(),
        }
    }

    pub fn is_duplicate(&mut self, client_id: &str) -> bool {
        let key = client_id.to_lowercase();
        if self.seen.contains(&key) {
            return true;
        }
        self.seen.insert(key.clone());
        self.order.push_back(key);
        if self.order.len() > self.window
            && let Some(oldest) = self.order.pop_front()
        {
            self.seen.remove(&oldest);
        }
        false
    }
}

#[derive(Debug, PartialEq)]
pub struct Resume {
    pub frames: Vec<Frame>,
    pub dropped: bool,
    pub server_seq: i64,
}

struct Entry {
    seq: i64,
    frame: Frame,
    at: f64,
    /// Audio parts kept with a `speech` frame (RR-457).
    parts: Vec<SpeechAudio>,
}

/// Last 200 sequenced frames or five minutes, whichever is smaller, trimmed by
/// ack. Time is passed in so behaviour is deterministic.
#[derive(Default)]
pub struct ReplayBuffer {
    entries: VecDeque<Entry>,
    highest_acked: i64,
    pub server_seq: i64,
}

impl ReplayBuffer {
    pub fn record(&mut self, frame: Frame, now: f64) -> Result<(), FrameError> {
        let seq = match frame.seq() {
            Some(seq) if seq > self.server_seq => seq,
            _ => return Err(FrameError::invalid("seq")),
        };
        self.server_seq = seq;
        self.entries.push_back(Entry {
            seq,
            frame,
            at: now,
            parts: Vec::new(),
        });
        self.prune(now);
        Ok(())
    }

    /// Keep an audio part with the `speech` frame it voices. A resume replays
    /// the parts straight after that frame; they leave with it on ack or
    /// expiry and do not count towards the frame limit. False when the frame
    /// is no longer held.
    pub fn attach(&mut self, part: SpeechAudio) -> bool {
        match self
            .entries
            .iter_mut()
            .rev()
            .find(|entry| entry.seq == part.seq)
        {
            Some(entry) if matches!(entry.frame, Frame::Speech(_)) => {
                entry.parts.push(part);
                true
            }
            _ => false,
        }
    }

    pub fn ack(&mut self, seq: i64) {
        if seq > self.server_seq {
            return;
        }
        self.highest_acked = self.highest_acked.max(seq);
        let highest = self.highest_acked;
        self.entries.retain(|entry| entry.seq > highest);
    }

    /// Frames after `after` in order, and whether any missed frame is gone.
    /// `None` is a fresh connection: nothing to replay and nothing missed.
    pub fn resume(&mut self, after: Option<i64>, now: f64) -> Resume {
        self.prune(now);
        let server_seq = self.server_seq;
        let Some(after) = after else {
            return Resume {
                frames: Vec::new(),
                dropped: false,
                server_seq,
            };
        };
        if after > server_seq {
            return Resume {
                frames: Vec::new(),
                dropped: true,
                server_seq,
            };
        }
        let effective = after.max(self.highest_acked);
        let mut frames = Vec::new();
        for entry in self.entries.iter().filter(|entry| entry.seq > effective) {
            frames.push(entry.frame.clone());
            frames.extend(entry.parts.iter().cloned().map(Frame::SpeechAudio));
        }
        let first = frames.first().and_then(Frame::seq);
        let dropped = effective < server_seq && first.is_none_or(|first| first > effective + 1);
        Resume {
            frames,
            dropped,
            server_seq,
        }
    }

    fn prune(&mut self, now: f64) {
        self.entries
            .retain(|entry| now - entry.at <= REPLAY_MAX_AGE);
        while self.entries.len() > REPLAY_MAX_FRAMES {
            self.entries.pop_front();
        }
    }
}

#[cfg(test)]
mod tests {
    //! The shared vectors in tests/RelayRemoteProtocolTests/Vectors, as the
    //! Swift and Python twins read them.

    use super::*;

    fn vectors(name: &str) -> Value {
        let path = format!(
            "{}/../../tests/RelayRemoteProtocolTests/Vectors/{name}.json",
            env!("CARGO_MANIFEST_DIR")
        );
        json::parse(&std::fs::read_to_string(&path).unwrap()).unwrap()
    }

    fn list(value: &Value) -> &[Value] {
        value.as_list().unwrap()
    }

    fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
        value.as_dict().unwrap().get(key).unwrap()
    }

    fn text<'a>(value: &'a Value, key: &str) -> &'a str {
        field(value, key).as_str().unwrap()
    }

    fn int(value: &Value, key: &str) -> i64 {
        field(value, key).py_int().unwrap()
    }

    fn optional_int(value: &Value, key: &str) -> Option<i64> {
        match field(value, key) {
            Value::Null => None,
            other => other.py_int(),
        }
    }

    fn phone_to_mac(frame: &Frame) -> bool {
        matches!(
            frame,
            Frame::Hello(_)
                | Frame::Utterance(_)
                | Frame::Control(_)
                | Frame::RemoteMode(_)
                | Frame::SessionCommand(_)
                | Frame::Ack(_)
                | Frame::Ping { .. }
        )
    }

    const ALL_TYPES: &[&str] = &[
        "hello",
        "utterance",
        "control",
        "remote_mode",
        "session_command",
        "ack",
        "ping",
        "welcome",
        "accepted",
        "speech",
        "speech_audio",
        "speech_control",
        "status",
        "error",
        "pong",
        "session_state",
    ];

    #[test]
    fn frame_vectors_round_trip_byte_for_byte() {
        let mut types = HashSet::new();
        for entry in list(&vectors("frames")) {
            let name = text(entry, "name");
            let line = text(entry, "line").as_bytes().to_vec();
            let frame = decode(&line).unwrap_or_else(|error| panic!("{name}: {error:?}"));
            types.insert(frame.type_name());
            assert_eq!(
                phone_to_mac(&frame),
                text(entry, "direction") == "phone_to_mac",
                "{name}"
            );
            let mut expected = line.clone();
            expected.push(b'\n');
            assert_eq!(encode(&frame).unwrap(), expected, "{name}");
            assert_eq!(decode(&expected).unwrap(), frame, "{name}");
        }
        let all: HashSet<&str> = ALL_TYPES.iter().copied().collect();
        assert_eq!(types, all);
        for name in ALL_TYPES {
            assert!(fields(name).is_some(), "{name}");
        }
    }

    #[test]
    fn invalid_vectors_report_shared_error_codes() {
        for entry in list(&vectors("invalid")) {
            let name = text(entry, "name");
            let error = decode(text(entry, "line").as_bytes()).expect_err(name);
            assert_eq!(error.code, text(entry, "error"), "{name}");
        }
    }

    fn utterance(limits: &Value, length: usize) -> Frame {
        Frame::Utterance(Utterance {
            client_id: text(limits, "pad_client_id").to_string(),
            text: "a".repeat(length),
            captured_at: text(limits, "captured_at").to_string(),
        })
    }

    #[test]
    fn line_limit_on_encode_and_decode() {
        let limits = vectors("limits");
        let limit = int(&limits, "max_line_bytes") as usize;
        assert_eq!(limit, MAX_LINE_BYTES);
        let overhead = encode(&utterance(&limits, 0)).unwrap().len() - 1;
        let exact = encode(&utterance(&limits, limit - overhead)).unwrap();
        assert_eq!(exact.len() - 1, limit);
        decode(&exact).unwrap();
        let over = encode(&utterance(&limits, limit - overhead + 1)).unwrap_err();
        assert_eq!(over.code, "line_too_long");
        let mut longer = exact[..exact.len() - 1].to_vec();
        longer.extend_from_slice(b"a\n");
        assert_eq!(decode(&longer).unwrap_err().code, "line_too_long");
    }

    fn part(length: usize) -> Frame {
        Frame::SpeechAudio(SpeechAudio {
            seq: 46,
            part: 0,
            parts: 1,
            format: "aac".into(),
            sample_rate: 24000,
            data: "A".repeat(length),
            last: Some(true),
        })
    }

    #[test]
    fn audio_data_limit_on_encode_and_decode() {
        let limit = int(&vectors("limits"), "max_audio_data_bytes") as usize;
        assert_eq!(limit, MAX_AUDIO_DATA_BYTES);
        let line = encode(&part(limit)).unwrap();
        assert!(line.len() < MAX_LINE_BYTES);
        assert_eq!(decode(&line).unwrap(), part(limit));
        assert_eq!(encode(&part(limit + 1)).unwrap_err().code, "invalid_field");
        let text = String::from_utf8(line).unwrap();
        let over = text.replacen("\"data\":\"", "\"data\":\"A", 1);
        assert_eq!(decode(over.as_bytes()).unwrap_err().code, "invalid_field");
    }

    #[test]
    fn seq_counter_is_monotonic() {
        let mut counter = SeqCounter::default();
        assert_eq!([counter.next(), counter.next(), counter.next()], [1, 2, 3]);
    }

    #[test]
    fn client_id_deduplication_vectors() {
        let vectors = vectors("dedup");
        let mut dedup = ClientIdDeduplicator::new(int(&vectors, "window") as usize);
        let seen: Vec<bool> = list(field(&vectors, "ids"))
            .iter()
            .map(|id| dedup.is_duplicate(id.as_str().unwrap()))
            .collect();
        let expected: Vec<bool> = list(field(&vectors, "expected_duplicates"))
            .iter()
            .map(Value::truthy)
            .collect();
        assert_eq!(seen, expected);
    }

    fn status(seq: i64) -> Frame {
        Frame::Status(Status {
            seq,
            text: format!("frame {seq}"),
        })
    }

    fn at(step: &Value) -> f64 {
        field(step, "at").py_float().unwrap()
    }

    fn check_expectation(name: &str, result: &Resume, expect: &Value) {
        assert_eq!(result.dropped, field(expect, "dropped").truthy(), "{name}");
        assert_eq!(result.server_seq, int(expect, "server_seq"), "{name}");
    }

    #[test]
    fn replay_vectors() {
        for scenario in list(&vectors("replay")) {
            let name = text(scenario, "name");
            let mut counter = SeqCounter::default();
            let mut buffer = ReplayBuffer::default();
            for step in list(field(scenario, "steps")) {
                match text(step, "op") {
                    "send" => {
                        for _ in 0..int(step, "count") {
                            buffer.record(status(counter.next()), at(step)).unwrap();
                        }
                    }
                    "ack" => buffer.ack(int(step, "seq")),
                    _ => {
                        let result = buffer.resume(optional_int(step, "after"), at(step));
                        let expect = field(step, "expect");
                        let seqs: Vec<i64> = result.frames.iter().filter_map(Frame::seq).collect();
                        if let (Some(first), Some(last)) = (seqs.first(), seqs.last()) {
                            assert_eq!(seqs, (*first..=*last).collect::<Vec<_>>(), "{name}");
                        }
                        let range = match field(expect, "replayed_range") {
                            Value::Null => None,
                            range => Some(
                                list(range)
                                    .iter()
                                    .map(|v| v.py_int().unwrap())
                                    .collect::<Vec<_>>(),
                            ),
                        };
                        let got = seqs
                            .first()
                            .map(|first| vec![*first, *seqs.last().unwrap()]);
                        assert_eq!(got, range, "{name}");
                        check_expectation(name, &result, expect);
                    }
                }
            }
        }
    }

    #[test]
    fn audio_replay_vectors() {
        fn label(frame: &Frame) -> String {
            match frame {
                Frame::SpeechAudio(audio) => format!("audio {}.{}", audio.seq, audio.part),
                other => format!("{} {}", other.type_name(), other.seq().unwrap()),
            }
        }
        for scenario in list(&vectors("audio_replay")) {
            let name = text(scenario, "name");
            let mut counter = SeqCounter::default();
            let mut buffer = ReplayBuffer::default();
            let mut parts: std::collections::HashMap<i64, i64> = Default::default();
            for step in list(field(scenario, "steps")) {
                match text(step, "op") {
                    op @ ("speech" | "status") => {
                        let seq = counter.next();
                        let frame = if op == "speech" {
                            Frame::Speech(Speech {
                                seq,
                                kind: "final".into(),
                                source: "orchestrator".into(),
                                text: format!("frame {seq}"),
                                relay_command_seq: None,
                                spoken_by: None,
                                audio: Some(true),
                            })
                        } else {
                            status(seq)
                        };
                        buffer.record(frame, at(step)).unwrap();
                    }
                    "audio" => {
                        let seq = int(step, "seq");
                        for _ in 0..int(step, "count") {
                            let index = parts.entry(seq).or_insert(0);
                            let audio = SpeechAudio {
                                seq,
                                part: *index,
                                parts: 0,
                                format: "aac".into(),
                                sample_rate: 24000,
                                data: "AAAA".into(),
                                last: None,
                            };
                            *index += 1;
                            assert_eq!(
                                buffer.attach(audio.clone()),
                                field(step, "kept").truthy(),
                                "{name}"
                            );
                            assert!(
                                buffer.record(Frame::SpeechAudio(audio), 0.0).is_err(),
                                "{name}"
                            );
                        }
                    }
                    "ack" => buffer.ack(int(step, "seq")),
                    _ => {
                        let result = buffer.resume(optional_int(step, "after"), at(step));
                        let expect = field(step, "expect");
                        let labels: Vec<String> = result.frames.iter().map(label).collect();
                        let replayed: Vec<String> = list(field(expect, "replayed"))
                            .iter()
                            .map(|v| v.as_str().unwrap().to_string())
                            .collect();
                        assert_eq!(labels, replayed, "{name}");
                        check_expectation(name, &result, expect);
                    }
                }
            }
        }
    }

    #[test]
    fn control_characters_are_escaped_as_python_escapes_them() {
        let frame = Frame::Status(Status {
            seq: 1,
            text: "a\u{1}b\u{7f}c\u{2028}/".into(),
        });
        let line = String::from_utf8(encode(&frame).unwrap()).unwrap();
        assert_eq!(
            line,
            "{\"seq\":1,\"text\":\"a\\u0001b\u{7f}c\u{2028}/\",\"type\":\"status\"}\n"
        );
    }

    #[test]
    fn client_ids_accept_the_spellings_python_accepts() {
        for good in [
            "3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d10",
            "3F2B8A52-6C1E-4F0A-9D57-0B7A1C2E4D10",
            "{3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d10}",
            "urn:uuid:3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d10",
            "3f2b8a526c1e4f0a9d570b7a1c2e4d10",
        ] {
            assert!(is_uuid(good), "{good}");
        }
        for bad in [
            "abc",
            "",
            "3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d1",
            "3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d1g",
        ] {
            assert!(!is_uuid(bad), "{bad}");
        }
    }

    #[test]
    fn unknown_fields_are_ignored_and_missing_protocol_defaults() {
        let frame = decode(
            br#"{"type":"hello","device_id":"d","device_name":"n","app_version":"1","pad":"x"}"#,
        )
        .unwrap();
        let Frame::Hello(hello) = frame else { panic!() };
        assert_eq!(hello.protocol, PROTOCOL_VERSION);
        assert_eq!(
            decode(br#"{"type":"ping","t":99999999999999999999}"#)
                .unwrap_err()
                .code,
            "invalid_field"
        );
        assert_eq!(decode(br#"{"type":5}"#).unwrap_err().code, "unknown_type");
        assert_eq!(decode(b"\xff").unwrap_err().code, "invalid_json");
    }
}
