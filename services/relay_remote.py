"""Relay Remote device sessions (docs/specs/relay-remote.md, "Mac-side integration").

Owned by voice_bridge.py. Accepts the forced-command helper on a Unix socket,
keys sessions by device id, and feeds utterances and controls into the
bridge's ingress queue so remote and microphone input share one ordered path
through ``_begin_relay_command``. Each session is also the SpeechCoordinator's
remote sink (RR-424): speech becomes ``speech`` frames and acks feed realization.
"""

from __future__ import annotations

import json
import os
import re
import socket
import struct
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
        """Connected, or disconnected within the replay window."""
        with self.lock:
            if self.conn is not None:
                return True
            return (
                self.disconnected_at is not None
                and self._clock() - self.disconnected_at <= proto.REPLAY_MAX_AGE
            )

    def speech(self, *, kind: str, source: str, text: str, relay_command_seq: int | None) -> int:
        return self.emit(lambda seq: proto.Speech(
            seq=seq,
            kind=kind,
            source=source,
            text=text,
            relay_command_seq=relay_command_seq,
        )).seq

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
    ):
        self.ingress = ingress
        # The SpeechCoordinator: attach_remote_sink, detach_remote_sink, remote_ack.
        self.speech = speech
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
                with session.lock:
                    if session.conn is conn:
                        session.conn = None
                        session.disconnected_at = self._clock()
            _close(conn)

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
        if self.speech is not None:
            self.speech.attach_remote_sink(session)
        return session

    def _handle(self, session: DeviceSession, frame: Any) -> None:
        if isinstance(frame, proto.Ping):
            session.send(proto.Pong(frame.t))
        elif isinstance(frame, proto.Ack):
            with session.lock:
                session.replay.ack(frame.seq)
            if self.speech is not None:
                self.speech.remote_ack(session.device_id, frame.seq, frame.played)
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
