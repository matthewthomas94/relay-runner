//! Relay Remote device sessions (docs/specs/relay-remote.md, "Mac-side
//! integration"), the twin of `services/relay_remote.py`.
//!
//! Accepts the forced-command helper on a Unix socket, keys sessions by device
//! id, and reports utterances, controls, acks and speech-sink changes to its
//! host as `Event`s, in the order they happen. The host (the bridge) answers
//! with `DeviceSession` calls: speech becomes `speech` frames, followed by
//! `speech_audio` parts in the Mac's voice, and accepted utterances get their
//! `accepted` receipt.

use std::collections::{HashMap, VecDeque};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use super::audio::AudioPart;
use super::protocol::{
    self as proto, Accepted, ClientIdDeduplicator, Frame, FrameError, ReplayBuffer, SeqCounter,
};
use crate::json;

/// What the bridge must act on, in the order the server saw it.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// An utterance, or a control already mapped to its FIFO token. An
    /// utterance needs `DeviceSession::accept` once it is the newest command.
    Item {
        text: String,
        device_id: String,
        client_id: String,
        control: bool,
    },
    AttachSink {
        device_id: String,
    },
    DetachSink {
        device_id: String,
        reason: String,
    },
    AttachMirror {
        device_id: String,
    },
    DetachMirror {
        device_id: String,
    },
    Ack {
        device_id: String,
        seq: i64,
        played: bool,
    },
    /// A `remote_device` event for the app's StateEventBus (RR-454).
    Device {
        state: &'static str,
        device_id: String,
        device_name: String,
    },
}

pub type Events = Arc<dyn Fn(Event) + Send + Sync>;
pub type Clock = Arc<dyn Fn() -> f64 + Send + Sync>;

/// A control action and the FIFO token it acts as.
fn control_token(action: &str) -> &'static str {
    match action {
        "stop" => "__TTS_STOP__",
        "interrupt" => "__INTERRUPT__",
        "cancel" => "__CANCEL__",
        "play" => "__PLAY__",
        _ => "__REPLAY__",
    }
}

/// Utterance text must never be read as a bridge control (`__CANCEL__`,
/// `__VOICE_TARGET__:`, a raw `{"type":"__ORCHESTRATOR_REPLY__"}` object):
/// Python's `__[A-Z][A-Z0-9_]*__`.
fn names_a_reserved_token(text: &str) -> bool {
    let bytes = text.as_bytes();
    let in_class = |byte: u8| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_';
    (0..bytes.len().saturating_sub(4)).any(|start| {
        if !(bytes[start] == b'_'
            && bytes[start + 1] == b'_'
            && bytes[start + 2].is_ascii_uppercase())
        {
            return false;
        }
        let end = (start + 2..bytes.len())
            .find(|&index| !in_class(bytes[index]))
            .unwrap_or(bytes.len());
        // A closing `__` inside the run, after at least the first letter.
        (start + 3..end.saturating_sub(1))
            .any(|index| bytes[index] == b'_' && bytes[index + 1] == b'_')
    })
}

/// The uid of the process at the other end, from `getpeereid`.
pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

fn close(stream: &UnixStream) {
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

struct Connection {
    id: u64,
    stream: UnixStream,
}

struct SessionState {
    conn: Option<Arc<Connection>>,
    disconnected_at: Option<f64>,
    device_name: String,
    /// RR-454: the phone's Remote mode switch. On, this session is the speech
    /// sink; off, it only mirrors Mac speech as text.
    remote_mode: bool,
    seq: SeqCounter,
    replay: ReplayBuffer,
    dedup: ClientIdDeduplicator,
    /// The receipts of the newest accepted client ids, oldest first.
    accepted: VecDeque<(String, Accepted)>,
}

/// Per-device state that survives reconnects: seq, replay and dedupe.
pub struct DeviceSession {
    pub device_id: String,
    clock: Clock,
    state: Mutex<SessionState>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl DeviceSession {
    fn new(device_id: &str, clock: Clock) -> Self {
        Self {
            device_id: device_id.to_string(),
            clock,
            state: Mutex::new(SessionState {
                conn: None,
                disconnected_at: None,
                device_name: String::new(),
                remote_mode: true,
                seq: SeqCounter::default(),
                replay: ReplayBuffer::default(),
                dedup: ClientIdDeduplicator::default(),
                accepted: VecDeque::new(),
            }),
        }
    }

    /// Write a frame to the current connection; a failed write ends it.
    fn send_locked(&self, state: &mut SessionState, frame: &Frame) -> bool {
        let Some(conn) = state.conn.clone() else {
            return false;
        };
        let Ok(line) = proto::encode(frame) else {
            return false;
        };
        if (&conn.stream).write_all(&line).is_ok() {
            return true;
        }
        state.conn = None;
        state.disconnected_at = Some((self.clock)());
        close(&conn.stream);
        false
    }

    fn send(&self, frame: &Frame) -> bool {
        let mut state = lock(&self.state);
        self.send_locked(&mut state, frame)
    }

    /// Send a sequenced Mac-to-phone frame, keeping it for replay. An invalid
    /// frame is refused before it takes a seq.
    fn emit(&self, build: impl FnOnce(i64) -> Frame) -> Result<i64, FrameError> {
        let mut state = lock(&self.state);
        let frame = build(state.seq.last + 1);
        proto::encode(&frame)?;
        let seq = state.seq.next();
        state.replay.record(frame.clone(), (self.clock)())?;
        self.send_locked(&mut state, &frame);
        Ok(seq)
    }

    /// Connected, or in Remote mode and disconnected within the replay window.
    pub fn routable(&self) -> bool {
        let state = lock(&self.state);
        if state.conn.is_some() {
            return true;
        }
        state.remote_mode
            && state
                .disconnected_at
                .is_some_and(|at| (self.clock)() - at <= proto::REPLAY_MAX_AGE)
    }

    pub fn speech(
        &self,
        kind: &str,
        source: &str,
        text: &str,
        relay_command_seq: Option<i64>,
        spoken_by: Option<&str>,
        audio: Option<bool>,
    ) -> Result<i64, FrameError> {
        self.emit(|seq| {
            Frame::Speech(proto::Speech {
                seq,
                kind: kind.to_string(),
                source: source.to_string(),
                text: text.to_string(),
                relay_command_seq,
                spoken_by: spoken_by.map(str::to_string),
                audio,
            })
        })
    }

    /// Send an audio part of the `speech` frame `seq` (RR-457). It takes no
    /// seq of its own; the replay buffer keeps it with that frame.
    pub fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), FrameError> {
        let audio = proto::SpeechAudio {
            seq,
            part: part.part,
            parts: part.parts,
            format: part.format.clone(),
            sample_rate: part.sample_rate,
            data: part.data.clone(),
            last: part.last.then_some(true),
        };
        let frame = Frame::SpeechAudio(audio.clone());
        proto::encode(&frame)?;
        let mut state = lock(&self.state);
        state.replay.attach(audio);
        self.send_locked(&mut state, &frame);
        Ok(())
    }

    pub fn speech_control(&self, action: &str, reason: &str) -> Result<i64, FrameError> {
        self.emit(|seq| {
            Frame::SpeechControl(proto::SpeechControl {
                seq,
                action: action.to_string(),
                reason: Some(reason.to_string()),
            })
        })
    }

    /// Send, and remember, the receipt for an accepted utterance.
    pub fn accept(&self, client_id: &str, relay_command_seq: i64, relay_command_id: &str) {
        let receipt = Accepted {
            client_id: client_id.to_string(),
            relay_command_seq,
            relay_command_id: relay_command_id.to_string(),
        };
        let key = client_id.to_lowercase();
        let mut state = lock(&self.state);
        match state
            .accepted
            .iter_mut()
            .find(|(existing, _)| *existing == key)
        {
            Some(entry) => entry.1 = receipt.clone(),
            None => state.accepted.push_back((key, receipt.clone())),
        }
        while state.accepted.len() > proto::DEFAULT_DEDUP_WINDOW {
            state.accepted.pop_front();
        }
        self.send_locked(&mut state, &Frame::Accepted(receipt));
    }

    fn accepted_for(state: &SessionState, client_id: &str) -> Option<Accepted> {
        let key = client_id.to_lowercase();
        state
            .accepted
            .iter()
            .find(|(existing, _)| *existing == key)
            .map(|(_, receipt)| receipt.clone())
    }

    fn is_current(&self, conn: &Connection) -> bool {
        lock(&self.state)
            .conn
            .as_ref()
            .is_some_and(|current| current.id == conn.id)
    }
}

pub struct Server {
    path: PathBuf,
    events: Events,
    clock: Clock,
    peer_uid: fn(&UnixStream) -> io::Result<u32>,
    /// Set by the bridge while its loop consumes items; no loop, no session.
    attached: AtomicBool,
    closed: AtomicBool,
    next_connection: AtomicU64,
    sessions: Mutex<HashMap<String, Arc<DeviceSession>>>,
}

impl Server {
    pub fn new(path: &Path, events: Events, clock: Clock) -> Arc<Self> {
        Arc::new(Self {
            path: path.to_path_buf(),
            events,
            clock,
            peer_uid,
            attached: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            next_connection: AtomicU64::new(1),
            sessions: Mutex::new(HashMap::new()),
        })
    }

    pub fn set_attached(&self, attached: bool) {
        self.attached.store(attached, Ordering::SeqCst);
    }

    fn attached(&self) -> bool {
        self.attached.load(Ordering::SeqCst)
    }

    fn session_state(&self) -> &'static str {
        if self.attached() { "running" } else { "idle" }
    }

    /// Bind the socket owner-only and accept connections on a thread.
    pub fn start(self: &Arc<Self>) -> io::Result<()> {
        let _ = std::fs::remove_file(&self.path);
        let listener = UnixListener::bind(&self.path)?;
        std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o600))?;
        let server = Arc::clone(self);
        std::thread::Builder::new()
            .name("relay-remote-accept".into())
            .spawn(move || server.accept_loop(listener))?;
        Ok(())
    }

    /// Stop accepting, end every connection, detach every device and remove
    /// the socket.
    pub fn close(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        // Wake the blocking accept so its thread sees `closed`.
        let _ = UnixStream::connect(&self.path);
        let sessions: Vec<Arc<DeviceSession>> = lock(&self.sessions).values().cloned().collect();
        for session in sessions {
            if let Some(conn) = lock(&session.state).conn.take() {
                close(&conn.stream);
            }
            self.emit(Event::DetachSink {
                device_id: session.device_id.clone(),
                reason: "closed".into(),
            });
            self.emit(Event::DetachMirror {
                device_id: session.device_id.clone(),
            });
        }
        let _ = std::fs::remove_file(&self.path);
    }

    pub fn session(&self, device_id: &str) -> Option<Arc<DeviceSession>> {
        lock(&self.sessions).get(device_id).cloned()
    }

    fn emit(&self, event: Event) {
        (self.events)(event);
    }

    fn accept_loop(self: Arc<Self>, listener: UnixListener) {
        for stream in listener.incoming() {
            if self.closed.load(Ordering::SeqCst) {
                return;
            }
            let Ok(stream) = stream else {
                continue;
            };
            let server = Arc::clone(&self);
            let spawned = std::thread::Builder::new()
                .name("relay-remote-conn".into())
                .spawn(move || server.serve(stream));
            if spawned.is_err() {
                eprintln!("[relay_remote] Could not start a connection thread");
            }
        }
    }

    fn serve(self: Arc<Self>, stream: UnixStream) {
        let uid = (self.peer_uid)(&stream).ok();
        if uid != Some(unsafe { libc::getuid() }) {
            eprintln!("[relay_remote] Refused connection from another user");
            close(&stream);
            return;
        }
        let conn = Arc::new(Connection {
            id: self.next_connection.fetch_add(1, Ordering::SeqCst),
            stream,
        });
        let mut session: Option<Arc<DeviceSession>> = None;
        let _ = self.read_frames(&conn, &mut session);
        if let Some(session) = &session {
            self.disconnected(session, &conn);
        }
        close(&conn.stream);
    }

    /// The connection's lines until it ends, fails, is replaced or is closed.
    fn read_frames(
        &self,
        conn: &Arc<Connection>,
        session: &mut Option<Arc<DeviceSession>>,
    ) -> io::Result<()> {
        let mut reader = BufReader::new(&conn.stream);
        let mut identified: Option<String> = None;
        while !self.closed.load(Ordering::SeqCst) {
            let mut line = read_line(&mut reader, proto::MAX_LINE_BYTES + 1)?;
            if line.is_empty() {
                return Ok(());
            }
            if !line.ends_with(b"\n") && line.len() > proto::MAX_LINE_BYTES {
                self.reply(
                    conn,
                    session.as_deref(),
                    "line_too_long",
                    "Frame exceeds 64 KiB",
                )?;
                while !line.is_empty() && !line.ends_with(b"\n") {
                    line = read_line(&mut reader, proto::MAX_LINE_BYTES + 1)?;
                }
                continue;
            }
            if session.is_none() && identified.is_none() {
                // The forced-command helper opens with `identify`; the device
                // id comes from the authorized_keys line sshd matched.
                if let Some(identity) = parse_identify(&line) {
                    if identity
                        .get("command")
                        .is_some_and(|command| command.is_str("status"))
                    {
                        let probe = Frame::Status(proto::Status {
                            seq: 0,
                            text: self.session_state().to_string(),
                        });
                        if let Ok(line) = proto::encode(&probe) {
                            (&conn.stream).write_all(&line)?;
                        }
                        return Ok(());
                    }
                    identified = identity
                        .get("device_id")
                        .and_then(json::Value::as_str)
                        .map(str::to_string);
                    continue;
                }
            }
            let frame = match proto::decode(&line) {
                Ok(frame) => frame,
                Err(error) => {
                    self.reply(conn, session.as_deref(), error.code, "Frame rejected")?;
                    continue;
                }
            };
            let Some(current) = session.clone() else {
                if let (Some(identified), Frame::Hello(hello)) = (&identified, &frame)
                    && hello.device_id != *identified
                {
                    self.reply(conn, None, "unsupported_protocol", "Unsupported hello")?;
                    return Ok(());
                }
                match self.hello(conn, frame)? {
                    Some(new) => *session = Some(new),
                    None => return Ok(()),
                }
                continue;
            };
            if !current.is_current(conn) {
                return Ok(()); // Replaced by a newer connection for this device.
            }
            self.handle(&current, frame);
        }
        Ok(())
    }

    fn disconnected(&self, session: &DeviceSession, conn: &Connection) {
        let remote_mode = {
            let mut state = lock(&session.state);
            match &state.conn {
                Some(current) if current.id == conn.id => {
                    state.conn = None;
                    state.disconnected_at = Some((self.clock)());
                }
                Some(_) => return, // Replaced by a newer connection for this device.
                None => {}
            }
            state.remote_mode
        };
        // In Remote mode the sink keeps buffering for the replay window. With
        // the mode off there is no sink, and the text mirror ends now.
        if !remote_mode {
            self.emit(Event::DetachMirror {
                device_id: session.device_id.clone(),
            });
        }
        self.post(session, "disconnected");
    }

    /// An `error` frame: through the session once there is one, otherwise
    /// straight to the connection, where a failed write ends it.
    fn reply(
        &self,
        conn: &Connection,
        session: Option<&DeviceSession>,
        code: &str,
        message: &str,
    ) -> io::Result<()> {
        let frame = Frame::error(code, message);
        match session {
            Some(session) => {
                session.send(&frame);
                Ok(())
            }
            None => match proto::encode(&frame) {
                Ok(line) => (&conn.stream).write_all(&line),
                Err(_) => Ok(()),
            },
        }
    }

    fn hello(
        &self,
        conn: &Arc<Connection>,
        frame: Frame,
    ) -> io::Result<Option<Arc<DeviceSession>>> {
        let Frame::Hello(hello) = frame else {
            self.reply(
                conn,
                None,
                "hello_required",
                "The first frame must be hello",
            )?;
            return Ok(None);
        };
        if hello.protocol != proto::PROTOCOL_VERSION || hello.device_id.is_empty() {
            self.reply(conn, None, "unsupported_protocol", "Unsupported hello")?;
            return Ok(None);
        }
        let session = Arc::clone(
            lock(&self.sessions)
                .entry(hello.device_id.clone())
                .or_insert_with(|| {
                    Arc::new(DeviceSession::new(
                        &hello.device_id,
                        Arc::clone(&self.clock),
                    ))
                }),
        );
        {
            let mut state = lock(&session.state);
            if let Some(previous) = state.conn.replace(Arc::clone(conn)) {
                close(&previous.stream);
            }
            let resume = state.replay.resume(hello.resume_after_seq, (self.clock)());
            let welcome = Frame::Welcome(proto::Welcome {
                session_state: self.session_state().to_string(),
                server_seq: resume.server_seq,
                dropped: resume.dropped,
                resumed_from: hello.resume_after_seq,
                protocol: proto::PROTOCOL_VERSION,
            });
            session.send_locked(&mut state, &welcome);
            for missed in &resume.frames {
                session.send_locked(&mut state, missed);
            }
            state.device_name = hello.device_name.clone();
        }
        // A phone built before the switch existed always drove the turn.
        self.set_remote_mode(&session, hello.remote_mode.unwrap_or(true));
        Ok(Some(session))
    }

    /// On: the device is the speech sink. Off: Kokoro speaks, the device shows text.
    fn set_remote_mode(&self, session: &DeviceSession, enabled: bool) {
        lock(&session.state).remote_mode = enabled;
        let device_id = session.device_id.clone();
        if enabled {
            self.emit(Event::AttachSink { device_id });
        } else {
            self.emit(Event::DetachSink {
                device_id: device_id.clone(),
                reason: "remote_mode_off".into(),
            });
            self.emit(Event::AttachMirror { device_id });
        }
        self.post(session, if enabled { "active" } else { "inactive" });
    }

    fn post(&self, session: &DeviceSession, state: &'static str) {
        let device_name = lock(&session.state).device_name.clone();
        self.emit(Event::Device {
            state,
            device_id: session.device_id.clone(),
            device_name,
        });
    }

    fn handle(&self, session: &DeviceSession, frame: Frame) {
        match frame {
            Frame::Ping { t } => {
                session.send(&Frame::Pong { t });
            }
            Frame::Ack(ack) => {
                lock(&session.state).replay.ack(ack.seq);
                self.emit(Event::Ack {
                    device_id: session.device_id.clone(),
                    seq: ack.seq,
                    played: ack.played,
                });
            }
            Frame::RemoteMode(mode) => {
                let duplicate = lock(&session.state).dedup.is_duplicate(&mode.client_id);
                if !duplicate {
                    self.set_remote_mode(session, mode.enabled);
                }
            }
            Frame::Utterance(_) | Frame::Control(_) => self.submit(session, frame),
            other => {
                session.send(&Frame::error(
                    "unexpected_frame",
                    &format!("Unexpected {}", other.type_name()),
                ));
            }
        }
    }

    fn submit(&self, session: &DeviceSession, frame: Frame) {
        if !self.attached() {
            session.send(&Frame::error(
                "no_session",
                "Relay Runner is not running a session",
            ));
            return;
        }
        let (client_id, item) = match &frame {
            Frame::Utterance(utterance) => {
                let text = json::py_strip(&utterance.text);
                if text.is_empty() || names_a_reserved_token(text) {
                    session.send(&Frame::error(
                        "invalid_utterance",
                        "Utterance text rejected",
                    ));
                    return;
                }
                (utterance.client_id.clone(), (text.to_string(), false))
            }
            Frame::Control(control) => (
                control.client_id.clone(),
                (control_token(&control.action).to_string(), true),
            ),
            _ => return,
        };
        {
            let mut state = lock(&session.state);
            if state.dedup.is_duplicate(&client_id) {
                // A retry after reconnect: re-send its receipt, or let the
                // pending one arrive on this connection. Never queue twice.
                if let Some(receipt) = DeviceSession::accepted_for(&state, &client_id) {
                    session.send_locked(&mut state, &Frame::Accepted(receipt));
                }
                return;
            }
        }
        self.emit(Event::Item {
            text: item.0,
            device_id: session.device_id.clone(),
            client_id,
            control: item.1,
        });
    }
}

fn parse_identify(line: &[u8]) -> Option<json::Dict> {
    match json::parse_bytes(line)? {
        json::Value::Dict(object)
            if object
                .get("type")
                .is_some_and(|kind| kind.is_str("identify"))
                && object
                    .get("device_id")
                    .and_then(json::Value::as_str)
                    .is_some() =>
        {
            Some(object)
        }
        _ => None,
    }
}

/// Python's `readline(limit)`: up to and including a newline, at most
/// `limit` bytes, and whatever is left at the end of the stream.
fn read_line(reader: &mut impl BufRead, limit: usize) -> io::Result<Vec<u8>> {
    let mut line = Vec::new();
    while line.len() < limit {
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if available.is_empty() {
            break;
        }
        let window = &available[..available.len().min(limit - line.len())];
        if let Some(position) = window.iter().position(|&byte| byte == b'\n') {
            line.extend_from_slice(&window[..=position]);
            reader.consume(position + 1);
            return Ok(line);
        }
        let taken = window.len();
        line.extend_from_slice(window);
        reader.consume(taken);
    }
    Ok(line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn reserved_tokens_match_the_python_pattern() {
        for reserved in [
            "__CANCEL__",
            "please run __VOICE_TARGET__:x",
            "a __A__ b",
            "__A1_B__",
            "x__ORCHESTRATOR_REPLY__",
        ] {
            assert!(names_a_reserved_token(reserved), "{reserved}");
        }
        for plain in [
            "__a__",
            "____",
            "__1A__",
            "__A_",
            "_A__",
            "snake_case__name",
            "__A",
            "hello",
            "",
        ] {
            assert!(!names_a_reserved_token(plain), "{plain}");
        }
    }

    #[test]
    fn read_line_follows_python_readline() {
        let mut reader = BufReader::with_capacity(4, &b"abc\ndefghij\nkl"[..]);
        assert_eq!(read_line(&mut reader, 6).unwrap(), b"abc\n");
        assert_eq!(read_line(&mut reader, 6).unwrap(), b"defghi");
        assert_eq!(read_line(&mut reader, 6).unwrap(), b"j\n");
        assert_eq!(read_line(&mut reader, 6).unwrap(), b"kl");
        assert_eq!(read_line(&mut reader, 6).unwrap(), b"");
    }

    struct Harness {
        server: Arc<Server>,
        events: mpsc::Receiver<Event>,
        path: PathBuf,
        _folder: tempfolder::Folder,
    }

    mod tempfolder {
        pub struct Folder(pub std::path::PathBuf);
        impl Folder {
            pub fn new() -> Self {
                use std::sync::atomic::{AtomicU64, Ordering};
                static COUNTER: AtomicU64 = AtomicU64::new(0);
                // A short path: sun_path holds 104 bytes.
                let path = std::path::PathBuf::from(format!(
                    "/tmp/rr-remote-{}-{}",
                    std::process::id(),
                    COUNTER.fetch_add(1, Ordering::SeqCst)
                ));
                std::fs::create_dir_all(&path).unwrap();
                Self(path)
            }
        }
        impl Drop for Folder {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    impl Harness {
        fn new(attached: bool) -> Self {
            let folder = tempfolder::Folder::new();
            let path = folder.0.join("remote.sock");
            let (sender, events) = mpsc::channel();
            let sender = Mutex::new(sender);
            let server = Server::new(
                &path,
                Arc::new(move |event| {
                    let _ = lock(&sender).send(event);
                }),
                Arc::new(|| 0.0),
            );
            server.set_attached(attached);
            server.start().unwrap();
            Self {
                server,
                events,
                path,
                _folder: folder,
            }
        }

        fn connect(&self) -> Device {
            let stream = UnixStream::connect(&self.path).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            Device {
                reader: BufReader::new(stream.try_clone().unwrap()),
                stream,
            }
        }

        fn event(&self) -> Event {
            self.events.recv_timeout(Duration::from_secs(5)).unwrap()
        }
    }

    impl Drop for Harness {
        fn drop(&mut self) {
            self.server.close();
        }
    }

    struct Device {
        stream: UnixStream,
        reader: BufReader<UnixStream>,
    }

    impl Device {
        fn send(&mut self, line: &str) {
            self.stream
                .write_all(format!("{line}\n").as_bytes())
                .unwrap();
        }

        fn line(&mut self) -> String {
            let mut line = String::new();
            self.reader.read_line(&mut line).unwrap();
            line
        }
    }

    const HELLO: &str = r#"{"app_version":"0.1","device_id":"D1","device_name":"iPhone","protocol":1,"type":"hello"}"#;
    const CLIENT: &str = "3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d10";

    #[test]
    fn hello_welcomes_and_attaches_a_sink() {
        let harness = Harness::new(true);
        let mut device = harness.connect();
        device.send(HELLO);
        assert_eq!(
            device.line(),
            "{\"dropped\":false,\"protocol\":1,\"server_seq\":0,\"session_state\":\"running\",\"type\":\"welcome\"}\n"
        );
        assert_eq!(
            harness.event(),
            Event::AttachSink {
                device_id: "D1".into()
            }
        );
        assert_eq!(
            harness.event(),
            Event::Device {
                state: "active",
                device_id: "D1".into(),
                device_name: "iPhone".into()
            }
        );
    }

    #[test]
    fn utterances_are_items_once_and_receipts_are_resent() {
        let harness = Harness::new(true);
        let mut device = harness.connect();
        device.send(HELLO);
        device.line();
        harness.event();
        harness.event();
        let utterance = format!(
            r#"{{"captured_at":"t","client_id":"{CLIENT}","text":"  hello there ","type":"utterance"}}"#
        );
        device.send(&utterance);
        assert_eq!(
            harness.event(),
            Event::Item {
                text: "hello there".into(),
                device_id: "D1".into(),
                client_id: CLIENT.into(),
                control: false
            }
        );
        let session = harness.server.session("D1").unwrap();
        session.accept(CLIENT, 7, "cmd-7");
        let receipt = format!(
            "{{\"client_id\":\"{CLIENT}\",\"relay_command_id\":\"cmd-7\",\"relay_command_seq\":7,\"type\":\"accepted\"}}\n"
        );
        assert_eq!(device.line(), receipt);
        // A retry, even with the id in another case, only re-sends the receipt.
        device.send(&utterance.replace(CLIENT, &CLIENT.to_uppercase()));
        assert_eq!(device.line(), receipt);
        assert!(
            harness
                .events
                .recv_timeout(Duration::from_millis(200))
                .is_err()
        );
    }

    #[test]
    fn speech_is_sequenced_and_replayed_after_reconnect() {
        let harness = Harness::new(true);
        let mut device = harness.connect();
        device.send(HELLO);
        device.line();
        let session = harness.server.session("D1").unwrap();
        assert_eq!(
            session.speech("final", "orchestrator", "one", Some(3), Some("phone"), None),
            Ok(1)
        );
        assert_eq!(
            device.line(),
            "{\"kind\":\"final\",\"relay_command_seq\":3,\"seq\":1,\"source\":\"orchestrator\",\"spoken_by\":\"phone\",\"text\":\"one\",\"type\":\"speech\"}\n"
        );
        assert_eq!(
            session
                .speech("shout", "orchestrator", "bad", None, None, None)
                .unwrap_err()
                .code,
            "invalid_field"
        );
        drop(device);
        // The clock is frozen, so the disconnected session stays routable.
        while lock(&session.state).conn.is_some() {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(session.routable());
        assert_eq!(session.speech_control("stop", "superseded"), Ok(2));
        let mut again = harness.connect();
        again.send(&HELLO.replace("\"protocol\"", "\"resume_after_seq\":1,\"protocol\""));
        assert_eq!(
            again.line(),
            "{\"dropped\":false,\"protocol\":1,\"resumed_from\":1,\"server_seq\":2,\"session_state\":\"running\",\"type\":\"welcome\"}\n"
        );
        assert_eq!(
            again.line(),
            "{\"action\":\"stop\",\"reason\":\"superseded\",\"seq\":2,\"type\":\"speech_control\"}\n"
        );
    }

    #[test]
    fn controls_map_to_fifo_tokens_and_need_a_session() {
        let harness = Harness::new(false);
        let mut device = harness.connect();
        device.send(HELLO);
        assert!(device.line().contains("\"session_state\":\"idle\""));
        device.send(&format!(
            r#"{{"action":"interrupt","client_id":"{CLIENT}","type":"control"}}"#
        ));
        assert_eq!(
            device.line(),
            "{\"code\":\"no_session\",\"message\":\"Relay Runner is not running a session\",\"type\":\"error\"}\n"
        );
        harness.server.set_attached(true);
        device.send(&format!(
            r#"{{"action":"interrupt","client_id":"{CLIENT}","type":"control"}}"#
        ));
        harness.event();
        harness.event();
        assert_eq!(
            harness.event(),
            Event::Item {
                text: "__INTERRUPT__".into(),
                device_id: "D1".into(),
                client_id: CLIENT.into(),
                control: true
            }
        );
    }

    #[test]
    fn the_status_probe_answers_and_closes() {
        let harness = Harness::new(true);
        let mut device = harness.connect();
        device.send(r#"{"type":"identify","device_id":"D1","command":"status"}"#);
        assert_eq!(
            device.line(),
            "{\"seq\":0,\"text\":\"running\",\"type\":\"status\"}\n"
        );
        assert_eq!(device.line(), "");
    }

    #[test]
    fn close_detaches_every_device_and_removes_the_socket() {
        let harness = Harness::new(true);
        let mut device = harness.connect();
        device.send(HELLO);
        device.line();
        harness.event();
        harness.event();
        harness.server.close();
        assert_eq!(
            harness.event(),
            Event::DetachSink {
                device_id: "D1".into(),
                reason: "closed".into()
            }
        );
        assert_eq!(
            harness.event(),
            Event::DetachMirror {
                device_id: "D1".into()
            }
        );
        assert!(!harness.path.exists());
        assert_eq!(device.line(), "");
    }
}
