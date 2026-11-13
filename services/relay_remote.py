"""Relay Remote device sessions (docs/specs/relay-remote.md, "Mac-side integration").

Owned by voice_bridge.py. Accepts the forced-command helper on a Unix socket,
keys sessions by device id, and feeds utterances and controls into the
bridge's ingress queue so remote and microphone input share one ordered path
through ``_begin_relay_command``. Each session is also the SpeechCoordinator's
remote sink (RR-424): speech becomes ``speech`` frames, followed by
``speech_audio`` parts in the Mac's voice (RR-457), and acks feed realization.
"""

from __future__ import annotations

import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import OrderedDict, deque
from dataclasses import dataclass
from typing import Any, Callable

try:
    from services import relay_remote_protocol as proto
except ImportError:  # pragma: no cover - run from inside services/
    import relay_remote_protocol as proto

REMOTE_SOCK = os.environ.get("RELAY_REMOTE_SOCK", "/tmp/relay_remote.sock")
VOICE_STATE_SOCK = os.environ.get("VOICE_STATE_SOCK", "/tmp/voice_state.sock")
INPUT_SOURCE = "remote"
CONTROL_TOKENS = {
    "stop": "__TTS_STOP__",
    "interrupt": "__INTERRUPT__",
    "cancel": "__CANCEL__",
    "play": "__PLAY__",
    "replay": "__REPLAY__",
}
# Utterance text must never be read as a bridge control (`__CANCEL__`,
# `__VOICE_TARGET__:`, a raw `{"type":"__ORCHESTRATOR_REPLY__"}` object).
_RESERVED_TEXT_RE = re.compile(r"__[A-Z][A-Z0-9_]*__")

# macOS <sys/un.h> and <sys/ucred.h>: getsockopt(SOL_LOCAL, LOCAL_PEERCRED)
# returns struct xucred, the source of getpeereid().
_SOL_LOCAL = 0
_LOCAL_PEERCRED = 0x001
_XUCRED_SIZE = 76


def peer_uid(conn: socket.socket) -> int:
    if sys.platform == "darwin":
        raw = conn.getsockopt(_SOL_LOCAL, _LOCAL_PEERCRED, _XUCRED_SIZE)
        _version, uid = struct.unpack_from("=II", raw)
        return uid
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", raw)[1]


def post_device_event(event: dict, path: str = VOICE_STATE_SOCK) -> None:
    """Send a ``remote_device`` event to the app's StateEventBus (RR-454).

    ``RelayRemoteDeviceSession`` suspends the Mac microphone and holds the
    keep-awake assertion while a device's Remote mode is active.
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.sendto(json.dumps(event).encode(), path)
    except OSError:
        pass  # The app is not running.


@dataclass(frozen=True)
class RemoteItem:
    """One utterance or mapped control token waiting for the bridge loop."""

    text: str
    device_id: str
    client_id: str
    on_accepted: Callable[[dict], None] | None = None

    @property
    def is_control(self) -> bool:
        return self.on_accepted is None


class RemoteIngress:
    """Bridge-owned queue whose pipe wakes the FIFO select loop."""

    def __init__(self) -> None:
        self._read_fd, self._write_fd = os.pipe()
        os.set_blocking(self._read_fd, False)
        os.set_blocking(self._write_fd, False)
        self._items: deque[RemoteItem] = deque()
        self._lock = threading.Lock()
        # Set by the bridge loop while it is consuming; no loop means no session.
        self.attached = False

    def fileno(self) -> int:
        return self._read_fd

    def put(self, item: RemoteItem) -> None:
        with self._lock:
            self._items.append(item)
        try:
            os.write(self._write_fd, b"\0")
        except (BlockingIOError, OSError):
            pass  # A wake byte is already pending.

    def drain(self) -> list[RemoteItem]:
        try:
            while os.read(self._read_fd, 4096):
                pass
        except (BlockingIOError, OSError):
            pass
        with self._lock:
            items = list(self._items)
            self._items.clear()
        return items

    def close(self) -> None:
        for fd in (self._read_fd, self._write_fd):
            try:
                os.close(fd)
            except OSError:
                pass


class DeviceSession:
    """Per-device state that survives reconnects: seq, replay and dedupe."""

    def __init__(self, device_id: str, clock: Callable[[], float]):
        self.device_id = device_id
        self._clock = clock
        self.lock = threading.RLock()
        self.conn: socket.socket | None = None
        self.disconnected_at: float | None = None
        self.device_name = ""
        # RR-454: the phone's Remote mode switch. On, this session is the
        # coordinator's speech sink; off, it only mirrors Mac speech as text.
        self.remote_mode = True
        self.seq = proto.SeqCounter()
        self.replay = proto.ReplayBuffer()
        self.dedup = proto.ClientIDDeduplicator()
        self._accepted: OrderedDict[str, proto.Accepted] = OrderedDict()

    def send(self, frame: Any) -> bool:
        with self.lock:
            conn = self.conn
            if conn is None:
                return False
            try:
                conn.sendall(proto.encode(frame))
                return True
            except OSError:
                self.conn = None
                self.disconnected_at = self._clock()
                _close(conn)
                return False

    def emit(self, build: Callable[[int], Any]) -> Any:
        """Send a sequenced Mac-to-phone frame, keeping it for replay."""
        with self.lock:
            frame = build(self.seq.last + 1)
            proto.encode(frame)  # Reject an invalid frame before it takes a seq.
            self.seq.next()
            self.replay.record(frame, self._clock())
            self.send(frame)
            return frame

    def routable(self) -> bool:
        """Connected, or in Remote mode and disconnected within the replay window."""
        with self.lock:
            if self.conn is not None:
                return True
            return (
                self.remote_mode
                and self.disconnected_at is not None
                and self._clock() - self.disconnected_at <= proto.REPLAY_MAX_AGE
            )

    def speech(
        self,
        *,
        kind: str,
        source: str,
        text: str,
        relay_command_seq: int | None,
        spoken_by: str = "phone",
        audio: bool | None = None,
    ) -> int:
        return self.emit(lambda seq: proto.Speech(
            seq=seq,
            kind=kind,
            source=source,
            text=text,
            relay_command_seq=relay_command_seq,
            spoken_by=spoken_by,
            audio=audio,
        )).seq

    def speech_audio(self, seq: int, part: Any) -> None:
        """Send a ``remote_audio.AudioPart`` of the ``speech`` frame ``seq`` (RR-457).

        It takes no seq of its own; the replay buffer keeps it with that frame.
        """
        frame = proto.SpeechAudio(
            seq=seq,
            part=part.part,
            parts=part.parts,
            format=part.format,
            sample_rate=part.sample_rate,
            data=part.data,
            last=part.last or None,
        )
        with self.lock:
            proto.encode(frame)  # Reject an invalid frame before replay keeps it.
            self.replay.attach(frame)
            self.send(frame)

    def speech_control(self, action: str, reason: str) -> int:
        return self.emit(lambda seq: proto.SpeechControl(seq=seq, action=action, reason=reason)).seq

    def accept(self, client_id: str, relay_command: dict) -> None:
        frame = proto.Accepted(
            client_id=client_id,
            relay_command_seq=int(relay_command["relay_command_seq"]),
            relay_command_id=str(relay_command["relay_command_id"]),
        )
        with self.lock:
            self._accepted[client_id.lower()] = frame
            while len(self._accepted) > proto.DEFAULT_DEDUP_WINDOW:
                self._accepted.popitem(last=False)
            self.send(frame)

    def accepted_for(self, client_id: str) -> proto.Accepted | None:
        with self.lock:
            return self._accepted.get(client_id.lower())


def _parse_identify(line: bytes) -> dict | None:
    try:
        obj = json.loads(line)
    except ValueError:
        return None
    if isinstance(obj, dict) and obj.get("type") == "identify" and isinstance(obj.get("device_id"), str):
        return obj
    return None


def _close(conn: socket.socket) -> None:
    try:
        conn.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        conn.close()
    except OSError:
        pass


class RelayRemoteServer:
    def __init__(
        self,
        ingress: RemoteIngress,
        path: str = REMOTE_SOCK,
        *,
        peer_uid: Callable[[socket.socket], int] = peer_uid,
        clock: Callable[[], float] = time.monotonic,
        speech: Any = None,
        notify: Callable[[dict], None] | None = None,
    ):
        self.ingress = ingress
        # The SpeechCoordinator: attach_remote_sink, detach_remote_sink,
        # attach_remote_mirror, detach_remote_mirror, remote_ack.
        self.speech = speech
        # Receives `remote_device` events; the bridge passes post_device_event.
        self._notify = notify
        self.path = path
        self._peer_uid = peer_uid
        self._clock = clock
        self._sessions: dict[str, DeviceSession] = {}
        self._lock = threading.Lock()
        self._listener: socket.socket | None = None
        self._closed = threading.Event()

    def start(self) -> None:
        try:
            os.unlink(self.path)
        except OSError:
            pass
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.path)
        os.chmod(self.path, 0o600)
        listener.listen(4)
        self._listener = listener
        threading.Thread(target=self._accept_loop, name="relay-remote-accept", daemon=True).start()

    def close(self) -> None:
        self._closed.set()
        if self._listener is not None:
            _close(self._listener)
        with self._lock:
            sessions = list(self._sessions.values())
        for session in sessions:
            with session.lock:
                conn, session.conn = session.conn, None
            if conn is not None:
                _close(conn)
            if self.speech is not None:
                self.speech.detach_remote_sink(session.device_id)
                self.speech.detach_remote_mirror(session.device_id)
        self.ingress.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def session(self, device_id: str) -> DeviceSession | None:
        with self._lock:
            return self._sessions.get(device_id)

    def _accept_loop(self) -> None:
        while not self._closed.is_set():
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            threading.Thread(
                target=self._serve, args=(conn,), name="relay-remote-conn", daemon=True
            ).start()

    def _serve(self, conn: socket.socket) -> None:
        try:
            uid = self._peer_uid(conn)
        except OSError:
            uid = None
        if uid != os.getuid():
            print("[relay_remote] Refused connection from another user", file=sys.stderr)
            _close(conn)
            return
        session: DeviceSession | None = None
        identified: str | None = None
        reader = conn.makefile("rb")
        try:
            while not self._closed.is_set():
                line = reader.readline(proto.MAX_LINE_BYTES + 1)
                if not line:
                    return
                if not line.endswith(b"\n") and len(line) > proto.MAX_LINE_BYTES:
                    self._reply(conn, session, "line_too_long", "Frame exceeds 64 KiB")
                    while line and not line.endswith(b"\n"):
                        line = reader.readline(proto.MAX_LINE_BYTES + 1)
                    continue
                if session is None and identified is None:
                    # The forced-command helper opens with `identify`; the device
                    # id comes from the authorized_keys line sshd matched.
                    identity = _parse_identify(line)
                    if identity is not None:
                        if identity.get("command") == "status":
                            conn.sendall(proto.encode(proto.Status(
                                0, "running" if self.ingress.attached else "idle"
                            )))
                            return
                        identified = identity["device_id"]
                        continue
                try:
                    frame = proto.decode(line)
                except proto.FrameError as exc:
                    self._reply(conn, session, exc.code, "Frame rejected")
                    continue
                if session is None:
                    if identified is not None and getattr(frame, "device_id", identified) != identified:
                        self._reply(conn, None, "unsupported_protocol", "Unsupported hello")
                        return
                    session = self._hello(conn, frame)
                    if session is None:
                        return
                    continue
                if session.conn is not conn:
                    return  # Replaced by a newer connection for this device.
                self._handle(session, frame)
        except OSError:
            return
        finally:
            reader.close()
            if session is not None:
                self._disconnected(session, conn)
            _close(conn)

    def _disconnected(self, session: DeviceSession, conn: socket.socket) -> None:
        with session.lock:
            if session.conn is conn:
                session.conn = None
                session.disconnected_at = self._clock()
            elif session.conn is not None:
                return  # Replaced by a newer connection for this device.
            remote_mode = session.remote_mode
        # In Remote mode the sink keeps buffering for the replay window. With
        # the mode off there is no sink, and the text mirror ends now.
        if self.speech is not None and not remote_mode:
            self.speech.detach_remote_mirror(session.device_id)
        self._post(session, "disconnected")

    def _reply(self, conn, session: DeviceSession | None, code: str, message: str) -> None:
        frame = proto.ErrorFrame(code, message)
        if session is not None:
            session.send(frame)
        else:
            conn.sendall(proto.encode(frame))

    def _hello(self, conn: socket.socket, frame: Any) -> DeviceSession | None:
        if not isinstance(frame, proto.Hello):
            self._reply(conn, None, "hello_required", "The first frame must be hello")
            return None
        if frame.protocol != proto.PROTOCOL_VERSION or not frame.device_id:
            self._reply(conn, None, "unsupported_protocol", "Unsupported hello")
            return None
        with self._lock:
            session = self._sessions.get(frame.device_id)
            if session is None:
                session = DeviceSession(frame.device_id, self._clock)
                self._sessions[frame.device_id] = session
        with session.lock:
            previous, session.conn = session.conn, conn
            if previous is not None:
                _close(previous)
            resume = session.replay.resume(frame.resume_after_seq, self._clock())
            session.send(proto.Welcome(
                session_state="running" if self.ingress.attached else "idle",
                server_seq=resume.server_seq,
                dropped=resume.dropped,
                resumed_from=frame.resume_after_seq,
            ))
            for missed in resume.frames:
                session.send(missed)
            session.device_name = frame.device_name
        # A phone built before the switch existed always drove the turn.
        self._set_remote_mode(session, True if frame.remote_mode is None else frame.remote_mode)
        return session

    def _set_remote_mode(self, session: DeviceSession, enabled: bool) -> None:
        """On: the device is the speech sink. Off: Kokoro speaks, the device shows text."""
        with session.lock:
            session.remote_mode = enabled
        if self.speech is not None:
            if enabled:
                self.speech.attach_remote_sink(session)
            else:
                self.speech.detach_remote_sink(session.device_id, reason="remote_mode_off")
                self.speech.attach_remote_mirror(session)
        self._post(session, "active" if enabled else "inactive")

    def _post(self, session: DeviceSession, kind: str) -> None:
        if self._notify is None:
            return
        self._notify({
            "source": "remote_device",
            "state": kind,
            "device_id": session.device_id,
            "device_name": session.device_name,
        })

    def _handle(self, session: DeviceSession, frame: Any) -> None:
        if isinstance(frame, proto.Ping):
            session.send(proto.Pong(frame.t))
        elif isinstance(frame, proto.Ack):
            with session.lock:
                session.replay.ack(frame.seq)
            if self.speech is not None:
                self.speech.remote_ack(session.device_id, frame.seq, frame.played)
        elif isinstance(frame, proto.RemoteMode):
            with session.lock:
                duplicate = session.dedup.is_duplicate(frame.client_id)
            if not duplicate:
                self._set_remote_mode(session, frame.enabled)
        elif isinstance(frame, (proto.Utterance, proto.Control)):
            self._submit(session, frame)
        else:
            session.send(proto.ErrorFrame("unexpected_frame", f"Unexpected {frame.TYPE}"))

    def _submit(self, session: DeviceSession, frame: Any) -> None:
        if not self.ingress.attached:
            session.send(proto.ErrorFrame("no_session", "Relay Runner is not running a session"))
            return
        if isinstance(frame, proto.Utterance):
            text = frame.text.strip()
            if not text or _RESERVED_TEXT_RE.search(text):
                session.send(proto.ErrorFrame("invalid_utterance", "Utterance text rejected"))
                return
        with session.lock:
            if session.dedup.is_duplicate(frame.client_id):
                # A retry after reconnect: re-send its receipt, or let the
                # pending one arrive on this connection. Never queue twice.
                accepted = session.accepted_for(frame.client_id)
                if accepted is not None:
                    session.send(accepted)
                return
        if isinstance(frame, proto.Control):
            item = RemoteItem(CONTROL_TOKENS[frame.action], session.device_id, frame.client_id)
        else:
            client_id = frame.client_id
            item = RemoteItem(
                text,
                session.device_id,
                client_id,
                on_accepted=lambda command: session.accept(client_id, command),
            )
        self.ingress.put(item)


# -- RR-491: the Rust server behind RELAY_REMOTE_RUNTIME=rust ------------------

REMOTE_RUNTIME_ENV = "RELAY_REMOTE_RUNTIME"
RELAY_RS_ENV = "RELAY_RS_BIN"
_RUST_START_TIMEOUT = 5.0
_RUST_CALL_TIMEOUT = 5.0


def rust_remote_binary() -> str | None:
    """The `relay-rs` to run when `RELAY_REMOTE_RUNTIME=rust`, else None.

    `RELAY_RS_BIN` names it; otherwise the app bundle's `Contents/MacOS/relay-rs`
    beside `SharedSupport/services`, or the repository's release build.
    """
    if os.environ.get(REMOTE_RUNTIME_ENV, "").strip().lower() != "rust":
        return None
    configured = os.environ.get(RELAY_RS_ENV, "").strip()
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [configured] if configured else [
        os.path.join(here, "..", "..", "MacOS", "relay-rs"),
        os.path.join(here, "..", "rust", "target", "release", "relay-rs"),
    ]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.realpath(candidate)
    print("[relay_remote] RELAY_REMOTE_RUNTIME=rust but no relay-rs found; using Python", file=sys.stderr)
    return None


def create_server(
    *,
    speech: Any = None,
    notify: Callable[[dict], None] | None = None,
    path: str = REMOTE_SOCK,
):
    """The bridge's Relay Remote server: Python by default, Rust when selected."""
    binary = rust_remote_binary()
    if binary is not None:
        return RustRelayRemoteServer(binary, path, speech=speech, notify=notify)
    return RelayRemoteServer(RemoteIngress(), path, speech=speech, notify=notify)


class _RustIngress(RemoteIngress):
    """A RemoteIngress whose `attached` flag is also told to the Rust server."""

    def __init__(self, on_attached: Callable[[bool], None]) -> None:
        self._on_attached = None
        super().__init__()
        self._on_attached = on_attached

    @property
    def attached(self) -> bool:
        return self._attached

    @attached.setter
    def attached(self, value: bool) -> None:
        self._attached = bool(value)
        if self._on_attached is not None:
            self._on_attached(self._attached)


class _RustDeviceSession:
    """The SpeechCoordinator's view of a device whose session lives in Rust."""

    def __init__(self, server: "RustRelayRemoteServer", device_id: str):
        self._server = server
        self.device_id = device_id

    def routable(self) -> bool:
        return bool(self._server._call("routable", device_id=self.device_id).get("routable"))

    def speech(
        self,
        *,
        kind: str,
        source: str,
        text: str,
        relay_command_seq: int | None,
        spoken_by: str | None = "phone",
        audio: bool | None = None,
    ) -> int:
        return int(self._server._call(
            "speech",
            device_id=self.device_id,
            kind=kind,
            source=source,
            text=text,
            relay_command_seq=relay_command_seq,
            spoken_by=spoken_by,
            audio=audio,
        )["seq"])

    def speech_audio(self, seq: int, part: Any) -> None:
        self._server._call(
            "speech_audio",
            device_id=self.device_id,
            seq=int(seq),
            part=part.part,
            parts=part.parts,
            format=part.format,
            sample_rate=part.sample_rate,
            data=part.data,
            last=bool(part.last),
        )

    def speech_control(self, action: str, reason: str) -> int:
        return int(self._server._call(
            "speech_control", device_id=self.device_id, action=action, reason=reason
        )["seq"])

    def accept(self, client_id: str, relay_command: dict) -> None:
        self._server._send({
            "op": "accept",
            "device_id": self.device_id,
            "client_id": client_id,
            "relay_command_seq": int(relay_command["relay_command_seq"]),
            "relay_command_id": str(relay_command["relay_command_id"]),
        })


class RustRelayRemoteServer:
    """`relay-rs remote` as the bridge's Relay Remote server (RR-491).

    The child owns the socket, framing, pairing state, dedupe and replay; this
    side turns its events into ingress items and SpeechCoordinator calls, and
    the coordinator's calls on a device into requests to the child. The stdio
    protocol is described in rust/relay-rs/src/remote/mod.rs.
    """

    def __init__(
        self,
        binary: str,
        path: str = REMOTE_SOCK,
        *,
        speech: Any = None,
        notify: Callable[[dict], None] | None = None,
    ):
        self.binary = binary
        self.path = path
        self.speech = speech
        self._notify = notify
        self._process: Any = None
        self._write_lock = threading.Lock()
        self._pending: dict[int, dict] = {}
        self._pending_lock = threading.Lock()
        self._answered = threading.Condition(self._pending_lock)
        self._next_id = 0
        self._sessions: dict[str, _RustDeviceSession] = {}
        self._events: deque = deque()
        self._events_ready = threading.Condition()
        self._ready = threading.Event()
        self._failure = ""
        self._closed = threading.Event()
        self.ingress = _RustIngress(self._tell_attached)

    def start(self) -> None:
        self._process = subprocess.Popen(
            [self.binary, "remote", "--socket", self.path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            bufsize=0,
        )
        threading.Thread(target=self._read_loop, name="relay-remote-rust-read", daemon=True).start()
        threading.Thread(target=self._event_loop, name="relay-remote-rust-events", daemon=True).start()
        if not self._ready.wait(_RUST_START_TIMEOUT) or self._failure:
            failure = self._failure or "relay-rs remote did not start"
            self._stop_process()
            raise OSError(failure)
        self._tell_attached(self.ingress.attached)

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        with self._events_ready:
            self._events.clear()
            self._events_ready.notify_all()
        self._stop_process()
        if self.speech is not None:
            for device_id in list(self._sessions):
                self.speech.detach_remote_sink(device_id)
                self.speech.detach_remote_mirror(device_id)
        self.ingress.close()

    def session(self, device_id: str) -> _RustDeviceSession | None:
        return self._sessions.get(device_id)

    # -- The child ------------------------------------------------------------

    def _stop_process(self) -> None:
        process, self._process = self._process, None
        if process is None:
            return
        try:
            process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        with self._answered:
            self._answered.notify_all()

    def _send(self, message: dict) -> None:
        process = self._process
        if process is None:
            raise OSError("relay-rs remote is not running")
        data = json.dumps(message, separators=(",", ":")).encode() + b"\n"
        with self._write_lock:
            process.stdin.write(data)
            process.stdin.flush()

    def _tell_attached(self, attached: bool) -> None:
        if self._process is None:
            return  # Sent once the child starts.
        try:
            self._send({"op": "attached", "value": attached})
        except OSError:
            pass

    def _call(self, op: str, **fields) -> dict:
        with self._pending_lock:
            self._next_id += 1
            call_id = self._next_id
        self._send({"id": call_id, "op": op, **fields})
        with self._answered:
            answered = self._answered.wait_for(
                lambda: call_id in self._pending or self._process is None,
                timeout=_RUST_CALL_TIMEOUT,
            )
            reply = self._pending.pop(call_id, None)
        if not answered or reply is None:
            raise OSError(f"relay-rs remote did not answer {op}")
        if not reply.get("ok"):
            error = reply.get("error") or {}
            raise proto.FrameError(str(error.get("code") or "call_failed"), str(error.get("message") or ""))
        result = reply.get("result")
        return result if isinstance(result, dict) else {}

    def _read_loop(self) -> None:
        process = self._process
        for line in process.stdout:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            if "reply" in message:
                with self._answered:
                    self._pending[message["reply"]] = message
                    self._answered.notify_all()
                continue
            event = message.get("event")
            if event == "ready":
                self._ready.set()
            elif event == "failed":
                self._failure = str(message.get("message") or "relay-rs remote failed")
                self._ready.set()
            elif not self._closed.is_set():
                # In order, off this thread: a speech call made while handling
                # an event needs this loop to read its answer.
                with self._events_ready:
                    self._events.append(message)
                    self._events_ready.notify()
        if not self._ready.is_set():
            self._failure = "relay-rs remote exited"
            self._ready.set()
        with self._answered:
            self._answered.notify_all()

    def _event_loop(self) -> None:
        while True:
            with self._events_ready:
                while not self._events and not self._closed.is_set():
                    self._events_ready.wait()
                if self._closed.is_set():
                    return
                message = self._events.popleft()
            try:
                self._dispatch(message)
            except Exception as exc:  # A failed speech call must not stop events.
                print(f"[relay_remote] Rust event failed: {type(exc).__name__}: {exc}", file=sys.stderr)

    def _device(self, device_id: str) -> _RustDeviceSession:
        session = self._sessions.get(device_id)
        if session is None:
            session = self._sessions[device_id] = _RustDeviceSession(self, device_id)
        return session

    def _dispatch(self, message: dict) -> None:
        event = message.get("event")
        device_id = str(message.get("device_id") or "")
        session = self._device(device_id)
        if event == "item":
            client_id = str(message.get("client_id") or "")
            control = bool(message.get("control"))
            self.ingress.put(RemoteItem(
                str(message.get("text") or ""),
                device_id,
                client_id,
                on_accepted=None if control else (lambda command: session.accept(client_id, command)),
            ))
        elif event == "device":
            if self._notify is not None:
                self._notify({
                    "source": "remote_device",
                    "state": message.get("state"),
                    "device_id": device_id,
                    "device_name": message.get("device_name") or "",
                })
        elif self.speech is None:
            return
        elif event == "attach_sink":
            self.speech.attach_remote_sink(session)
        elif event == "detach_sink":
            self.speech.detach_remote_sink(device_id, reason=str(message.get("reason") or "closed"))
        elif event == "attach_mirror":
            self.speech.attach_remote_mirror(session)
        elif event == "detach_mirror":
            self.speech.detach_remote_mirror(device_id)
        elif event == "ack":
            self.speech.remote_ack(device_id, int(message.get("seq") or 0), bool(message.get("played")))
