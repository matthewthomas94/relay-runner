"""Relay Remote wire protocol (docs/specs/relay-remote.md, "Wire protocol").

Python twin of Sources/RelayRemoteProtocol. Both must agree byte for byte on
tests/RelayRemoteProtocolTests/Vectors. Pure data code: no sockets, SSH or
bridge integration.
"""

from __future__ import annotations

import json
import uuid
from collections import OrderedDict
from dataclasses import dataclass, fields
from typing import Any

try:
    from services.speech_coordinator import SPEECH_KINDS, SPEECH_SOURCES
except ImportError:  # pragma: no cover - run from inside services/
    from speech_coordinator import SPEECH_KINDS, SPEECH_SOURCES

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 64 * 1024
DEFAULT_DEDUP_WINDOW = 1024
REPLAY_MAX_FRAMES = 200
REPLAY_MAX_AGE = 300.0

CONTROL_ACTIONS = frozenset({"stop", "interrupt", "cancel", "play", "replay"})
SPEECH_CONTROL_ACTIONS = frozenset({"stop", "skip"})


class FrameError(Exception):
    """`code` strings are identical to the Swift FrameError codes."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class Hello:
    device_id: str
    device_name: str
    app_version: str
    resume_after_seq: int | None = None
    protocol: int = PROTOCOL_VERSION
    TYPE = "hello"
    PHONE_TO_MAC = True


@dataclass(frozen=True)
class Utterance:
    client_id: str
    text: str
    captured_at: str
    TYPE = "utterance"
    PHONE_TO_MAC = True


@dataclass(frozen=True)
class Control:
    client_id: str
    action: str
    TYPE = "control"
    PHONE_TO_MAC = True


@dataclass(frozen=True)
class Ack:
    seq: int
    played: bool
    TYPE = "ack"
    PHONE_TO_MAC = True


@dataclass(frozen=True)
class Ping:
    t: int
    TYPE = "ping"
    PHONE_TO_MAC = True


@dataclass(frozen=True)
class Welcome:
    session_state: str
    server_seq: int
    dropped: bool
    resumed_from: int | None = None
    protocol: int = PROTOCOL_VERSION
    TYPE = "welcome"
    PHONE_TO_MAC = False


@dataclass(frozen=True)
class Accepted:
    client_id: str
    relay_command_seq: int
    relay_command_id: str
    TYPE = "accepted"
    PHONE_TO_MAC = False


@dataclass(frozen=True)
class Speech:
    seq: int
    kind: str
    source: str
    text: str
    relay_command_seq: int | None = None
    TYPE = "speech"
    PHONE_TO_MAC = False


@dataclass(frozen=True)
class SpeechControl:
    seq: int
    action: str
    reason: str | None = None
    TYPE = "speech_control"
    PHONE_TO_MAC = False


@dataclass(frozen=True)
class Status:
    seq: int
    text: str
    TYPE = "status"
    PHONE_TO_MAC = False


@dataclass(frozen=True)
class ErrorFrame:
    code: str
    message: str
    TYPE = "error"
    PHONE_TO_MAC = False


@dataclass(frozen=True)
class Pong:
    t: int
    TYPE = "pong"
    PHONE_TO_MAC = False


FRAME_TYPES = {
    cls.TYPE: cls
    for cls in (
        Hello, Utterance, Control, Ack, Ping, Welcome, Accepted,
        Speech, SpeechControl, Status, ErrorFrame, Pong,
    )
}
_ENUMS = {
    ("control", "action"): CONTROL_ACTIONS,
    ("speech_control", "action"): SPEECH_CONTROL_ACTIONS,
    ("speech", "kind"): SPEECH_KINDS,
    ("speech", "source"): SPEECH_SOURCES,
}
_UUID_FIELDS = {("utterance", "client_id"), ("control", "client_id"), ("accepted", "client_id")}


def _check(type_name: str, name: str, value: Any, annotation: str) -> None:
    optional = annotation.endswith("| None")
    base = annotation.removesuffix(" | None")
    if value is None and optional:
        return
    if base == "int":
        ok = isinstance(value, int) and not isinstance(value, bool)
    elif base == "bool":
        ok = isinstance(value, bool)
    else:
        ok = isinstance(value, str)
    if not ok:
        raise FrameError("invalid_field", name)
    allowed = _ENUMS.get((type_name, name))
    if allowed is not None and value not in allowed:
        raise FrameError("invalid_field", name)
    if (type_name, name) in _UUID_FIELDS:
        try:
            uuid.UUID(value)
        except ValueError:
            raise FrameError("invalid_field", name) from None


def _validate(frame: Any) -> None:
    for f in fields(frame):
        _check(frame.TYPE, f.name, getattr(frame, f.name), f.type)


def encode(frame: Any) -> bytes:
    """One canonical line (sorted keys, compact) including the trailing newline."""
    _validate(frame)
    obj = {f.name: getattr(frame, f.name) for f in fields(frame) if getattr(frame, f.name) is not None}
    obj["type"] = frame.TYPE
    line = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(line) > MAX_LINE_BYTES:
        raise FrameError("line_too_long", str(len(line)))
    return line + b"\n"


def decode(line: bytes | str) -> Any:
    """Decode one line; a single trailing newline is accepted."""
    body = line.encode("utf-8") if isinstance(line, str) else bytes(line)
    if body.endswith(b"\n"):
        body = body[:-1]
    if len(body) > MAX_LINE_BYTES:
        raise FrameError("line_too_long", str(len(body)))
    try:
        obj = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise FrameError("invalid_json") from None
    if not isinstance(obj, dict):
        raise FrameError("invalid_json")
    if "type" not in obj:
        raise FrameError("missing_field", "type")
    type_name = obj["type"]
    cls = FRAME_TYPES.get(type_name) if isinstance(type_name, str) else None
    if cls is None:
        raise FrameError("unknown_type", str(type_name))
    kwargs = {}
    for f in fields(cls):
        if f.name in obj:
            kwargs[f.name] = obj[f.name]
        elif not f.type.endswith("| None") and f.name != "protocol":
            raise FrameError("missing_field", f.name)
    try:
        frame = cls(**kwargs)
    except TypeError:  # pragma: no cover - guarded above
        raise FrameError("invalid_json") from None
    _validate(frame)
    return frame


def frame_seq(frame: Any) -> int | None:
    return getattr(frame, "seq", None) if not isinstance(frame, Ack) else None


class SeqCounter:
    """Per-device monotonically increasing sequence for Mac-to-phone frames."""

    def __init__(self, last: int = 0):
        self.last = last

    def next(self) -> int:
        self.last += 1
        return self.last


class ClientIDDeduplicator:
    """Remembers the most recent `window` client ids; a duplicate does not refresh."""

    def __init__(self, window: int = DEFAULT_DEDUP_WINDOW):
        self._window = window
        self._seen: OrderedDict[str, None] = OrderedDict()

    def is_duplicate(self, client_id: str) -> bool:
        key = client_id.lower()
        if key in self._seen:
            return True
        self._seen[key] = None
        if len(self._seen) > self._window:
            self._seen.popitem(last=False)
        return False


@dataclass(frozen=True)
class Resume:
    frames: list
    dropped: bool
    server_seq: int


class ReplayBuffer:
    """Last 200 sequenced frames or five minutes, whichever is smaller, trimmed by ack.

    Time is passed in so behaviour is deterministic.
    """

    def __init__(self) -> None:
        self._entries: list[tuple[int, Any, float]] = []
        self._highest_acked = 0
        self.server_seq = 0

    def record(self, frame: Any, now: float) -> None:
        seq = frame_seq(frame)
        if seq is None or seq <= self.server_seq:
            raise FrameError("invalid_field", "seq")
        self.server_seq = seq
        self._entries.append((seq, frame, now))
        self._prune(now)

    def ack(self, seq: int) -> None:
        if seq > self.server_seq:
            return
        self._highest_acked = max(self._highest_acked, seq)
        self._entries = [e for e in self._entries if e[0] > self._highest_acked]

    def resume(self, after: int | None, now: float) -> Resume:
        """Frames after `after` in order, and whether any missed frame is gone.

        None is a fresh connection: nothing to replay and nothing missed.
        """
        self._prune(now)
        if after is None:
            return Resume([], False, self.server_seq)
        if after > self.server_seq:
            return Resume([], True, self.server_seq)
        effective = max(after, self._highest_acked)
        frames = [frame for seq, frame, _ in self._entries if seq > effective]
        first = frame_seq(frames[0]) if frames else None
        dropped = effective < self.server_seq and (first is None or first > effective + 1)
        return Resume(frames, dropped, self.server_seq)

    def _prune(self, now: float) -> None:
        self._entries = [e for e in self._entries if now - e[2] <= REPLAY_MAX_AGE]
        del self._entries[: max(0, len(self._entries) - REPLAY_MAX_FRAMES)]
