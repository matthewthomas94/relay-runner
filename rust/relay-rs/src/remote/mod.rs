//! `relay-rs remote`: Relay Remote's socket, framing and device sessions
//! (RR-491), the Rust port of `services/relay_remote.py`,
//! `relay_remote_protocol.py` and `remote_audio.py`.
//!
//! Until the Rust bridge hosts it in-process (RR-492), the Python bridge runs
//! this as a child when `RELAY_REMOTE_RUNTIME=rust` and talks to it over
//! stdin and stdout, one compact JSON object per line:
//!
//! - The server writes `{"event": "ready"}` once the socket is bound (or
//!   `{"event": "failed", "message": ...}` and exits 1), then every server
//!   `Event` as `{"event": "item" | "attach_sink" | "detach_sink" |
//!   "attach_mirror" | "detach_mirror" | "ack" | "device", ...}` in order.
//! - The bridge writes `{"op": "attached", "value": bool}` and `{"op":
//!   "accept", ...}`, which have no answer, and calls with an `id` (`routable`,
//!   `speech`, `speech_control`, `speech_audio`), answered by `{"reply": id,
//!   "ok": true, "result": {...}}` or `{"reply": id, "ok": false, "error":
//!   {"code", "message"}}`.
//!
//! End of input closes the server and removes the socket.

pub mod audio;
pub mod protocol;
pub mod server;

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::json::{self, Dict, Value};
use server::{Event, Server};

const DEFAULT_SOCKET: &str = "/tmp/relay_remote.sock";

pub fn run(arguments: &[String]) -> u8 {
    let path = match arguments {
        [] => crate::support::env_or("RELAY_REMOTE_SOCK", DEFAULT_SOCKET),
        [flag, path] if flag == "--socket" => path.clone(),
        _ => {
            eprintln!("usage: relay-rs remote [--socket <path>]");
            return 2;
        }
    };
    let out = Arc::new(Mutex::new(io::stdout()));
    let writer = Arc::clone(&out);
    let started = Instant::now();
    let server = Server::new(
        &PathBuf::from(&path),
        Arc::new(move |event| write_line(&writer, &event_object(event))),
        Arc::new(move || started.elapsed().as_secs_f64()),
    );
    if let Err(error) = server.start() {
        let mut failed = Dict::new();
        failed.insert("event", "failed");
        failed.insert("message", error.to_string());
        write_line(&out, &failed);
        eprintln!("[relay_remote] Relay Remote socket unavailable: {error}");
        return 1;
    }
    let mut ready = Dict::new();
    ready.insert("event", "ready");
    write_line(&out, &ready);
    for line in io::stdin().lock().split(b'\n') {
        let Ok(line) = line else { break };
        let Some(Value::Dict(request)) = json::parse_bytes(&line) else {
            continue;
        };
        if let Some(reply) = handle(&server, &request) {
            write_line(&out, &reply);
        }
    }
    server.close();
    0
}

fn write_line(out: &Mutex<io::Stdout>, object: &Dict) {
    let mut line = json::dumps_compact(&Value::Dict(object.clone()));
    line.push('\n');
    let mut out = out.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    // The bridge has gone when this fails; end of input follows.
    let _ = out.write_all(line.as_bytes()).and_then(|()| out.flush());
}

fn event_object(event: Event) -> Dict {
    let mut out = Dict::new();
    match event {
        Event::Item {
            text,
            device_id,
            client_id,
            control,
        } => {
            out.insert("event", "item");
            out.insert("device_id", device_id);
            out.insert("client_id", client_id);
            out.insert("text", text);
            out.insert("control", control);
        }
        Event::AttachSink { device_id } => {
            out.insert("event", "attach_sink");
            out.insert("device_id", device_id);
        }
        Event::DetachSink { device_id, reason } => {
            out.insert("event", "detach_sink");
            out.insert("device_id", device_id);
            out.insert("reason", reason);
        }
        Event::AttachMirror { device_id } => {
            out.insert("event", "attach_mirror");
            out.insert("device_id", device_id);
        }
        Event::DetachMirror { device_id } => {
            out.insert("event", "detach_mirror");
            out.insert("device_id", device_id);
        }
        Event::Ack {
            device_id,
            seq,
            played,
        } => {
            out.insert("event", "ack");
            out.insert("device_id", device_id);
            out.insert("seq", seq);
            out.insert("played", played);
        }
        Event::Device {
            state,
            device_id,
            device_name,
        } => {
            out.insert("event", "device");
            out.insert("state", state);
            out.insert("device_id", device_id);
            out.insert("device_name", device_name);
        }
    }
    out
}

struct CallError {
    code: &'static str,
    message: String,
}

impl CallError {
    fn bad(name: &str) -> Self {
        Self {
            code: "invalid_argument",
            message: name.to_string(),
        }
    }
}

fn text<'a>(request: &'a Dict, name: &str) -> Result<&'a str, CallError> {
    request
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| CallError::bad(name))
}

fn optional_text<'a>(request: &'a Dict, name: &str) -> Result<Option<&'a str>, CallError> {
    match request.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Str(value)) => Ok(Some(value)),
        Some(_) => Err(CallError::bad(name)),
    }
}

fn integer(request: &Dict, name: &str) -> Result<i64, CallError> {
    match request.get(name) {
        Some(Value::Int(number)) => Ok(*number),
        _ => Err(CallError::bad(name)),
    }
}

fn optional_integer(request: &Dict, name: &str) -> Result<Option<i64>, CallError> {
    match request.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Int(number)) => Ok(Some(*number)),
        Some(_) => Err(CallError::bad(name)),
    }
}

fn optional_flag(request: &Dict, name: &str) -> Result<Option<bool>, CallError> {
    match request.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(flag)) => Ok(Some(*flag)),
        Some(_) => Err(CallError::bad(name)),
    }
}

fn frame_failed(error: protocol::FrameError) -> CallError {
    CallError {
        code: error.code,
        message: error.detail,
    }
}

/// One request from the bridge; calls with an `id` get a reply.
fn handle(server: &Server, request: &Dict) -> Option<Dict> {
    let op = request
        .get("op")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match op {
        "attached" => {
            server.set_attached(request.get("value").is_some_and(Value::truthy));
            return None;
        }
        "accept" => {
            let session = text(request, "device_id")
                .ok()
                .and_then(|id| server.session(id));
            if let (Some(session), Ok(client_id), Ok(seq), Ok(command_id)) = (
                session,
                text(request, "client_id"),
                integer(request, "relay_command_seq"),
                text(request, "relay_command_id"),
            ) {
                session.accept(client_id, seq, command_id);
            }
            return None;
        }
        _ => {}
    }
    let id = request.get("id").cloned()?;
    let mut reply = Dict::new();
    reply.insert("reply", id);
    match call(server, op, request) {
        Ok(result) => {
            reply.insert("ok", true);
            reply.insert("result", result);
        }
        Err(error) => {
            let mut detail = Dict::new();
            detail.insert("code", error.code);
            detail.insert("message", error.message);
            reply.insert("ok", false);
            reply.insert("error", detail);
        }
    }
    Some(reply)
}

fn call(server: &Server, op: &str, request: &Dict) -> Result<Dict, CallError> {
    let device_id = text(request, "device_id")?;
    let session = server.session(device_id).ok_or(CallError {
        code: "unknown_device",
        message: String::new(),
    })?;
    let mut result = Dict::new();
    match op {
        "routable" => result.insert("routable", session.routable()),
        "speech" => {
            // A missing `spoken_by` is the phone, as DeviceSession.speech defaults it.
            let spoken_by = match request.get("spoken_by") {
                None => Some("phone"),
                Some(_) => optional_text(request, "spoken_by")?,
            };
            let seq = session
                .speech(
                    text(request, "kind")?,
                    text(request, "source")?,
                    text(request, "text")?,
                    optional_integer(request, "relay_command_seq")?,
                    spoken_by,
                    optional_flag(request, "audio")?,
                )
                .map_err(frame_failed)?;
            result.insert("seq", seq);
        }
        "speech_control" => {
            let seq = session
                .speech_control(text(request, "action")?, text(request, "reason")?)
                .map_err(frame_failed)?;
            result.insert("seq", seq);
        }
        "speech_audio" => {
            let part = audio::AudioPart {
                part: integer(request, "part")?,
                parts: integer(request, "parts")?,
                last: optional_flag(request, "last")?.unwrap_or(false),
                data: text(request, "data")?.to_string(),
                format: text(request, "format")?.to_string(),
                sample_rate: integer(request, "sample_rate")?,
            };
            session
                .speech_audio(integer(request, "seq")?, &part)
                .map_err(frame_failed)?;
        }
        _ => {
            return Err(CallError {
                code: "unknown_call",
                message: op.to_string(),
            });
        }
    }
    Ok(result)
}
