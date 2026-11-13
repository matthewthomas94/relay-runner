#!/usr/bin/env python3
"""Relay speech as its own process (RR-480).

Hosts ``SpeechCoordinator``, ``TTSWorker`` and ``SpeechPlayer`` and serves one
client, the voice bridge, over a Unix stream socket. The protocol, the
environment and the test mode are described in
docs/specs/speech-service-protocol.md.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import queue
import signal
import socket
import sys
import tempfile
import threading
import time
import uuid
import wave
from typing import Any

from speech_coordinator import SpeechCoordinator, SpeechIntent
from speech_player import BUFFER_SECONDS, SpeechPlayer
from tts_worker import TTS_CONTROL_SOCK, TTSWorker

PROTOCOL_VERSION = 1
SERVICE_NAME = "relay-speech-python"
DEFAULT_SOCKET = "/tmp/relay_speech_service.sock"
MAX_LINE_BYTES = 1024 * 1024
STATE_POLL_SECONDS = 0.2
# ``IntentRoute.CONTINUE_CURRENT`` in intent_arbitration.py.
CONTINUE_CURRENT_ROUTE = "continue_current"

# What a client may set on a ``speak`` request, as SpeechIntent.build names them.
SPEAK_FIELDS = (
    "display_text",
    "semantic_brief",
    "command_seq",
    "command_id",
    "source",
    "kind",
    "authoritative",
    "priority",
    "dedup_key",
    "utterance_id",
    "expires_at",
    "freshness_scope",
    "work_disposition",
    "replayable",
    "lifecycle_role",
    "covered_facts",
    "realization_decision",
    "suppression_reason",
    "session_key",
)
# Worker lifecycle states under their protocol names.
PLAYBACK_PHASES = {"wav_ready": "ready", "afplay_started": "chunk_started"}
FINISHED_PHASES = frozenset({"completed", "cancelled", "failed"})


def read_command_state(path: str) -> dict:
    """The command state file the bridge writes atomically; unreadable is empty."""
    try:
        with open(path) as handle:
            data = json.load(handle)
    except (OSError, ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def command_key(command: Any) -> tuple[int, str] | None:
    if not isinstance(command, dict):
        return None
    command_id = str(command.get("relay_command_id") or "").strip()
    if not command_id:
        return None
    try:
        return int(command.get("relay_command_seq")), command_id
    except (TypeError, ValueError):
        return None


def command_is_current(state: dict, command_seq: Any, command_id: Any) -> bool:
    """Mirrors ``voice_bridge._relay_command_current``."""
    if command_seq is None or not command_id:
        return False
    try:
        current_seq = int(state.get("relay_command_seq"))
        expected_seq = int(command_seq)
    except (TypeError, ValueError):
        return False
    return current_seq == expected_seq and str(state.get("relay_command_id") or "") == str(command_id)


def command_is_preserved(state: dict, command_seq: Any, command_id: Any, intent_id: Any) -> bool:
    """Mirrors ``voice_bridge._relay_command_current_or_preserved`` without a session key."""
    expected = command_key({"relay_command_seq": command_seq, "relay_command_id": command_id})
    if expected is None:
        return False
    cancelled = state.get("cancelled_intent_ids")
    if isinstance(cancelled, list) and str(intent_id or "") in {str(value) for value in cancelled}:
        return False
    current = command_key(state)
    if current == expected:
        return True
    if current is None or current[0] <= expected[0]:
        return False
    disposition = state.get("work_disposition")
    return (
        isinstance(disposition, dict)
        and disposition.get("route") == CONTINUE_CURRENT_ROUTE
        and disposition.get("authorization_effect") == "preserve"
        and disposition.get("cancellation_scope") in {None, "none"}
    )


class _PlaybackLog:
    """Test mode: what would have reached the speaker, one JSON object per line."""

    def __init__(self, path: str | None):
        self._path = path
        self._lock = threading.Lock()

    def write(self, event: str, **fields: Any) -> None:
        if not self._path:
            return
        record = {"event": event, "at": time.time(), **fields}
        with self._lock:
            with open(self._path, "a") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")


class _NullOutput:
    """Test mode: consumes the speech stream in real time without an audio device."""

    def __init__(self, fmt, rate: float, render, log: _PlaybackLog):
        self.error: str | None = None
        self._fmt = fmt
        self._rate = rate
        self._render = render
        self._log = log
        self._buffer_bytes = max(1, round(fmt.sample_rate * BUFFER_SECONDS)) * fmt.frame_bytes
        self._stopped = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._log.write("output_started", sample_rate=self._fmt.sample_rate, rate=self._rate)
        self._thread = threading.Thread(target=self._run, name="speech-null-output", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        interval = BUFFER_SECONDS / self._rate
        deadline = time.monotonic()
        while not self._stopped.is_set():
            self._render(self._buffer_bytes)
            deadline += interval
            self._stopped.wait(max(0.0, deadline - time.monotonic()))

    def fade_out(self, seconds: float) -> None:
        del seconds

    def wait_faded(self, timeout: float) -> bool:
        del timeout
        return True

    def dispose(self) -> None:
        if self._stopped.is_set():
            return
        self._stopped.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=1)
        self._log.write("output_stopped")


class _LoggedPlayer(SpeechPlayer):
    """Test mode: a null output, and a log record for each sentence handed to it."""

    def __init__(self, log: _PlaybackLog, describe, **kwargs: Any):
        super().__init__(
            output_factory=lambda fmt, rate, render: _NullOutput(fmt, rate, render, log), **kwargs
        )
        self._log = log
        self._describe = describe

    def submit_wav(self, path: str, rate: float):
        chunk = super().submit_wav(path, rate)
        chunk.logged = self._describe(path)
        self._log.write("chunk_started", rate=rate, **chunk.logged)
        return chunk

    def wait(self, chunk, *, cancelled=lambda: False) -> bool:
        completed = False
        try:
            completed = super().wait(chunk, cancelled=cancelled)
            return completed
        finally:
            fields = {key: chunk.logged[key] for key in ("utterance_id", "text")}
            self._log.write("chunk_finished", completed=completed, **fields)


class TestModeWorker(TTSWorker):
    """``RELAY_SPEECH_TEST_MODE=1``: silence of a fixed length per character
    instead of Kokoro, and a timed null output instead of an audio device."""

    SAMPLE_RATE = 24000

    def __init__(self, input_queue: queue.Queue, *, log: _PlaybackLog, ms_per_char: float):
        self._test_log = log
        self._test_ms_per_char = ms_per_char
        self._test_chunks: dict[str, tuple[str, float]] = {}
        super().__init__(input_queue, start_control_socket=False)
        self._speech_player = _LoggedPlayer(
            log, self._describe_chunk, keep_alive=lambda: self._playing
        )

    def _load_voice(self):
        self._kokoro = "silence"  # Truthy: nothing below reads the model.

    def _synthesize_to_wav(self, text: str) -> str | None:
        seconds = max(BUFFER_SECONDS, len(text) * self._test_ms_per_char / 1000)
        handle, path = tempfile.mkstemp(suffix=".wav")
        os.close(handle)
        with wave.open(path, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(self.SAMPLE_RATE)
            out.writeframes(bytes(2 * round(seconds * self.SAMPLE_RATE)))
        selection = getattr(getattr(self, "_render_local", None), "selection", None)
        self._test_chunks[path] = (text, seconds)
        self._test_log.write(
            "synthesized",
            text=text,
            seconds=seconds,
            voice=selection.voice if selection else self._voice,
        )
        return path

    def _describe_chunk(self, wav_path: str) -> dict[str, Any]:
        text, seconds = self._test_chunks.get(wav_path, ("", 0.0))
        return {
            "utterance_id": (self._current_speech_intent or {}).get("utterance_id"),
            "text": text,
            "seconds": seconds,
        }

    def _remove_wav(self, wav_path: str | None):
        self._test_chunks.pop(wav_path or "", None)
        super()._remove_wav(wav_path)

    def _play_chime(self):
        self._test_log.write("chime")


class _RequestError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class _CallFailed(RuntimeError):
    """The client did not answer a call: it refused, or the connection ended."""


class _RemoteDevice:
    """Stands in for a Relay Remote ``DeviceSession`` that lives in the client."""

    def __init__(self, service: "SpeechService", device_id: str, role: str):
        self.device_id = device_id
        self._service = service
        self._role = role

    def _call(self, op: str, **params: Any) -> dict:
        return self._service.call(op, device_id=self.device_id, role=self._role, **params)

    def routable(self) -> bool:
        try:
            return bool(self._call("remote_routable").get("routable"))
        except _CallFailed:
            return False

    def speech(self, **frame: Any) -> int:
        return int(self._call("remote_speech", **frame)["seq"])

    def speech_control(self, action: str, reason: str) -> int:
        return int(self._call("remote_speech_control", action=action, reason=reason)["seq"])

    def speech_audio(self, seq: int, part: Any) -> None:
        self._call(
            "remote_speech_audio",
            seq=int(seq),
            part=part.part,
            parts=part.parts,
            last=bool(part.last),
            data=part.data,
            format=part.format,
            sample_rate=part.sample_rate,
        )


def _intent_fields(intent: SpeechIntent) -> dict[str, Any]:
    return {
        "utterance_id": intent.utterance_id,
        "original_utterance_id": intent.original_utterance_id,
        "relay_command_seq": intent.command_seq,
        "relay_command_id": intent.command_id,
        "kind": intent.kind,
        "source": intent.source,
        "session_key": intent.session_key,
        "replay_of": intent.replay_of,
    }


class SpeechService:
    """One coordinator and worker, driven by one client connection."""

    def __init__(
        self,
        worker,
        *,
        state_path: str,
        event_log_path: str | None,
        control_socket_path: str | None,
        test_mode: bool = False,
        done: threading.Event | None = None,
    ):
        self.instance_id = uuid.uuid4().hex
        # Set when the client leaves, asks to shut down, or the process is told to stop.
        self.done = done or threading.Event()
        self._test_mode = test_mode
        self._state_path = state_path
        self._out: queue.Queue = queue.Queue()
        self._requests: queue.Queue = queue.Queue()
        self._greeted = threading.Event()
        self._shut_down = False
        self._emit_lock = threading.Lock()
        self._last_state: dict | None = None
        self._calls: dict[int, dict] = {}
        self._calls_lock = threading.Lock()
        self._call_ids = itertools.count(1)
        self.coordinator = SpeechCoordinator(
            worker,
            is_current=lambda command_seq, command_id: command_is_current(
                read_command_state(self._state_path), command_seq, command_id
            ),
            is_preserved=lambda command_seq, command_id, disposition: command_is_preserved(
                read_command_state(self._state_path),
                command_seq,
                command_id,
                disposition.get("intent_id"),
            ),
            event_log_path=event_log_path,
            control_socket_path=control_socket_path,
            on_reply_finished=lambda reason: self.emit({"event": "reply_finished", "reason": reason}),
            on_playback=self._on_playback,
        )

    # -- Outgoing messages -------------------------------------------------

    def emit(self, message: dict) -> None:
        """Queue an event; nothing is sent before the client has said hello."""
        if self._greeted.is_set():
            self._out.put(message)

    def emit_state(self) -> None:
        """Send the queue snapshot when it changed, in the order snapshots were taken."""
        with self._emit_lock:
            snapshot = self.coordinator.queue_snapshot()
            if snapshot != self._last_state:
                self._last_state = snapshot
                self.emit({"event": "state", **snapshot})

    def _on_playback(self, state: str, intent: SpeechIntent, info: dict[str, Any]) -> None:
        phase = PLAYBACK_PHASES.get(state, state)
        event = {"event": "playback", "phase": phase, **_intent_fields(intent)}
        if phase in FINISHED_PHASES:
            event["stop_reason"] = info.get("stop_reason")
            event["requeued_as"] = info.get("requeued_as")
        self.emit(event)
        if phase == "failed":
            self.emit({
                "event": "error",
                "code": "playback_failed",
                "utterance_id": intent.utterance_id,
            })
        self.emit_state()

    def call(self, op: str, **params: Any) -> dict:
        """Ask the client to act on a Relay Remote device and wait for its reply."""
        if not self._greeted.is_set() or self.done.is_set():
            raise _CallFailed("no_client")
        call_id = next(self._call_ids)
        slot: dict[str, Any] = {"answered": threading.Event(), "message": None}
        with self._calls_lock:
            self._calls[call_id] = slot
        self._out.put({"call": call_id, "op": op, **params})
        try:
            while not slot["answered"].wait(0.25):
                if self.done.is_set():
                    raise _CallFailed("client_gone")
        finally:
            with self._calls_lock:
                self._calls.pop(call_id, None)
        message = slot["message"] or {}
        if not message.get("ok"):
            raise _CallFailed("call_refused")
        result = message.get("result")
        return result if isinstance(result, dict) else {}

    # -- Requests ----------------------------------------------------------

    def _dispatch(self, op: str, request: dict) -> dict | None:
        coordinator = self.coordinator
        if op == "hello":
            if request.get("protocol") != PROTOCOL_VERSION:
                raise _RequestError("unsupported_protocol", "Unsupported protocol version")
            with self._emit_lock:
                self._last_state = None
            self._greeted.set()
            return {
                "protocol": PROTOCOL_VERSION,
                "service": SERVICE_NAME,
                "instance_id": self.instance_id,
                "pid": os.getpid(),
                "test_mode": self._test_mode,
            }
        if not self._greeted.is_set():
            raise _RequestError("hello_required", "The first request must be hello")
        if op == "speak":
            fields = {name: request[name] for name in SPEAK_FIELDS if name in request}
            if not isinstance(fields.get("work_disposition") or {}, dict):
                raise _RequestError("invalid_request", "work_disposition must be an object")
            intent = SpeechIntent.build(spoken_text=str(request.get("text") or ""), **fields)
            accepted = coordinator.submit(
                intent, waiting_playback_kind=request.get("waiting_playback_kind")
            )
            return {"accepted": bool(accepted), "utterance_id": intent.utterance_id}
        if op == "read_out":
            return {"accepted": bool(coordinator.read_out(
                str(request.get("text") or ""), session_key=str(request.get("session_key") or "")
            ))}
        if op == "arm_waiting_playback":
            coordinator.arm_waiting_playback(
                int(request["command_seq"]),
                str(request["command_id"]),
                kind=str(request.get("kind") or "final"),
            )
        elif op == "play":
            coordinator.play()
        elif op == "play_or_replay":
            return {"handled": bool(coordinator.play_or_replay())}
        elif op == "replay":
            return {"accepted": bool(coordinator.replay())}
        elif op == "pause":
            coordinator.stop()
        elif op == "stop_playback":
            coordinator.stop_playback(reason=str(request.get("reason") or "user_stop"))
        elif op == "skip":
            coordinator.skip(reason=str(request.get("reason") or "user_stop"))
        elif op == "new_turn":
            coordinator.new_turn(int(request["command_seq"]), str(request["command_id"]))
        elif op == "control_session":
            return {"handled": bool(coordinator.control_session(
                str(request.get("session_key") or ""),
                str(request.get("action") or ""),
                waiting_session_key=str(request.get("waiting_session_key") or ""),
            ))}
        elif op == "session_playback_states":
            return {"states": coordinator.session_playback_states(
                waiting_session_key=str(request.get("waiting_session_key") or "")
            )}
        elif op == "status":
            return coordinator.queue_snapshot()
        elif op == "played_coverage":
            return {"coverage": list(coordinator.played_coverage(
                int(request["command_seq"]), str(request["command_id"])
            ))}
        elif op == "note_play_control":
            coordinator.note_play_control(
                option_detected_at=request.get("option_detected_at"),
                fifo_received_at=request.get("fifo_received_at"),
            )
        elif op == "note_visual_acknowledgement":
            coordinator.note_visual_acknowledgement(
                option_detected_at=float(request["option_detected_at"]),
                acknowledged_at=float(request["acknowledged_at"]),
            )
        elif op == "record_realization":
            coordinator.record_realization(
                int(request["command_seq"]),
                str(request["command_id"]),
                lifecycle_role=request.get("lifecycle_role"),
                decision=request.get("decision"),
                reason=request.get("reason"),
            )
        elif op == "record_messenger_stage":
            coordinator.record_messenger_stage(
                str(request.get("stage") or ""),
                int(request["command_seq"]),
                str(request["command_id"]),
                at=request.get("at"),
                provider=request.get("provider"),
                outcome=str(request.get("outcome") or "ok"),
            )
        elif op == "record_missing_outcome":
            return {"recorded": bool(coordinator.record_missing_outcome(
                int(request["command_seq"]),
                str(request["command_id"]),
                str(request.get("reason") or ""),
                signals=request.get("signals") or (),
            ))}
        elif op == "reload_config":
            coordinator.reload_config()
        elif op == "remote_attach":
            device = _RemoteDevice(self, self._device_id(request), self._role(request))
            if self._role(request) == "mirror":
                coordinator.attach_remote_mirror(device)
            else:
                coordinator.attach_remote_sink(device)
        elif op == "remote_detach":
            if self._role(request) == "mirror":
                coordinator.detach_remote_mirror(self._device_id(request))
            else:
                coordinator.detach_remote_sink(
                    self._device_id(request), reason=str(request.get("reason") or "closed")
                )
        elif op == "remote_ack":
            return {"known": bool(coordinator.remote_ack(
                self._device_id(request), int(request["seq"]), bool(request.get("played"))
            ))}
        elif op == "shutdown":
            self._shut_down = True
            coordinator.shutdown()
        else:
            raise _RequestError("unknown_op", "Unknown request")
        return None

    @staticmethod
    def _device_id(request: dict) -> str:
        device_id = str(request.get("device_id") or "")
        if not device_id:
            raise _RequestError("invalid_request", "device_id is required")
        return device_id

    @staticmethod
    def _role(request: dict) -> str:
        role = request.get("role", "sink")
        if role not in {"sink", "mirror"}:
            raise _RequestError("invalid_request", "role must be sink or mirror")
        return role

    def _execute_loop(self) -> None:
        """Apply requests one at a time, in the order they were received."""
        while True:
            request = self._requests.get()
            if request is None:
                return
            op = str(request.get("op") or "")
            response: dict[str, Any] = {"id": request.get("id"), "ok": True}
            try:
                response["result"] = self._dispatch(op, request) or {}
            except _RequestError as exc:
                response.update(ok=False, error={"code": exc.code, "message": str(exc)})
            except (KeyError, TypeError, ValueError):
                response.update(ok=False, error={
                    "code": "invalid_request", "message": "Missing or malformed field",
                })
            except Exception as exc:  # Never let one request end the service.
                print(f"[speech_service] {op} failed: {type(exc).__name__}", file=sys.stderr)
                response.update(ok=False, error={
                    "code": "internal_error", "message": type(exc).__name__,
                })
            if self._greeted.is_set():
                # State a request changed reaches the client before its response.
                self.emit_state()
            self._out.put(response)
            if op == "shutdown" and response["ok"]:
                self.done.set()
                return

    # -- Connection --------------------------------------------------------

    def _read_loop(self, conn: socket.socket) -> None:
        reader = conn.makefile("rb")
        try:
            while not self.done.is_set():
                line = reader.readline(MAX_LINE_BYTES + 1)
                if not line:
                    return
                if not line.endswith(b"\n"):
                    if len(line) <= MAX_LINE_BYTES:
                        return  # The connection ended inside a line.
                    while line and not line.endswith(b"\n"):
                        line = reader.readline(MAX_LINE_BYTES + 1)
                    self._protocol_error("line_too_long")
                    continue
                try:
                    message = json.loads(line)
                except ValueError:
                    self._protocol_error("invalid_message")
                    continue
                if isinstance(message, dict) and "reply" in message:
                    with self._calls_lock:
                        slot = self._calls.get(message.get("reply"))
                    if slot is not None:
                        slot["message"] = message
                        slot["answered"].set()
                elif isinstance(message, dict) and "id" in message and "op" in message:
                    self._requests.put(message)
                else:
                    self._protocol_error("invalid_message")
        except OSError:
            return
        finally:
            self.done.set()

    def _protocol_error(self, code: str) -> None:
        # Sent even before hello, so a client learns why it gets no response.
        self._out.put({"event": "error", "code": code})

    def _write_loop(self, conn: socket.socket) -> None:
        while True:
            message = self._out.get()
            if message is None:
                return
            try:
                conn.sendall(json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n")
            except OSError:
                self.done.set()
                return

    def _state_loop(self) -> None:
        # Catches changes no request or playback event reports, such as a
        # command on the control socket.
        while not self.done.wait(STATE_POLL_SECONDS):
            if self._greeted.is_set():
                self.emit_state()

    def serve(self, conn: socket.socket, parent_pid: int) -> None:
        """Serve the one client until it leaves, asks to shut down, or the parent dies."""
        writer = threading.Thread(target=self._write_loop, args=(conn,), name="speech-service-write", daemon=True)
        for target, name in (
            (self._execute_loop, "speech-service-requests"),
            (self._state_loop, "speech-service-state"),
        ):
            threading.Thread(target=target, name=name, daemon=True).start()
        writer.start()
        threading.Thread(target=self._read_loop, args=(conn,), name="speech-service-read", daemon=True).start()
        while not self.done.wait(0.5):
            if os.getppid() != parent_pid:
                self.done.set()
        self.close()
        self._out.put(None)
        writer.join(timeout=2)

    def close(self) -> None:
        if not self._shut_down:
            self._shut_down = True
            self.coordinator.shutdown()


def build_worker(test_mode: bool):
    if not test_mode:
        return TTSWorker(queue.Queue(), start_control_socket=False)
    return TestModeWorker(
        queue.Queue(),
        log=_PlaybackLog(os.environ.get("RELAY_SPEECH_TEST_PLAYBACK_LOG") or None),
        ms_per_char=float(os.environ.get("RELAY_SPEECH_TEST_MS_PER_CHAR") or 20),
    )


def _listen(path: str) -> socket.socket:
    try:
        os.unlink(path)
    except OSError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    previous_mask = os.umask(0o177)  # The socket is never open to another user.
    try:
        listener.bind(path)
    finally:
        os.umask(previous_mask)
    listener.listen(1)
    listener.settimeout(0.5)
    return listener


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Relay speech service")
    parser.add_argument("--socket", default=os.environ.get("RELAY_SPEECH_SERVICE_SOCK") or DEFAULT_SOCKET)
    # Read from sys.argv by config.load_config(); declared so it is accepted here.
    parser.add_argument("--config")
    args = parser.parse_args(argv)

    parent_pid = os.getppid()
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())

    try:
        listener = _listen(args.socket)
    except OSError as exc:
        print(f"[speech_service] Could not listen on {args.socket}: {exc}", file=sys.stderr)
        return 1
    test_mode = os.environ.get("RELAY_SPEECH_TEST_MODE") == "1"
    # The client may connect now; its hello is answered once the voice is loaded.
    service = SpeechService(
        build_worker(test_mode),
        state_path=os.environ.get("VOICE_COMMAND_STATE_FILE") or "/tmp/voice_command_state.json",
        event_log_path=os.environ.get("SPEECH_EVENT_LOG") or "/tmp/relay_speech_events.jsonl",
        control_socket_path=TTS_CONTROL_SOCK,
        test_mode=test_mode,
        done=stop,
    )

    conn = None
    try:
        while conn is None and not stop.is_set():
            if os.getppid() != parent_pid:
                stop.set()
                break
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                stop.set()
    finally:
        # One client for the life of the process: the path is free again.
        listener.close()
        _unlink(args.socket)
    if conn is None:
        service.close()
        return 0
    conn.settimeout(None)
    try:
        service.serve(conn, parent_pid)
    finally:
        try:
            conn.close()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
