"""The voice bridge's client for the speech service (RR-480).

``SpeechServiceClient`` starts ``speech_service.py``, supervises it, and offers
the surface the bridge used on the in-process ``SpeechCoordinator``. Each call
is one request in docs/specs/speech-service-protocol.md, so the bridge code is
the same for both paths and never loads the voice model itself.
"""

from __future__ import annotations

import itertools
import json
import os
import queue
import socket
import subprocess
import sys
import threading
import time
from typing import Any, Callable

import remote_audio

PROTOCOL_VERSION = 1
DEFAULT_SOCKET = "/tmp/relay_speech_service.sock"
# A crashed service is restarted this often before speech is given up on.
MAX_RESTARTS = 3
RESTART_WINDOW_SECONDS = 60.0
_REMOTE_SPEECH_FIELDS = ("kind", "source", "text", "relay_command_seq", "spoken_by", "audio")


class SpeechServiceError(RuntimeError):
    """The service could not be started or did not answer a request."""


class _Pending:
    def __init__(self, op: str, params: dict):
        self.op = op
        self.params = params
        self.answered = threading.Event()
        self.message: dict | None = None


class _InputQueue:
    """The queue-shaped producer surface of ``CoordinatorInputQueue``."""

    supports_atomic_waiting_playback = True
    publishes_waiting_preview = True

    def __init__(self, client: "SpeechServiceClient"):
        self._client = client

    def put(self, item, block: bool = True, timeout: float | None = None) -> bool:
        del block, timeout
        if isinstance(item, dict):
            spec = item.get("_speech_intent_spec")
            return self.submit_text(
                str(item.get("text") or ""),
                display_text=item.get("display_text"),
                **(spec if isinstance(spec, dict) else {}),
            )
        return self.submit_text(str(item or ""))

    def submit_text(self, text: str, **metadata) -> bool:
        params = {"text": text, **{key: value for key, value in metadata.items() if value is not None}}
        return bool(self._client._request("speak", params).get("accepted"))

    def arm_waiting_playback(self, command_seq: int, command_id: str, *, kind: str = "final") -> None:
        self._client._request(
            "arm_waiting_playback",
            {"command_seq": int(command_seq), "command_id": str(command_id), "kind": kind},
        )

    def empty(self) -> bool:
        return not self._client.speaking


class SpeechServiceClient:
    def __init__(
        self,
        command: list[str],
        socket_path: str = DEFAULT_SOCKET,
        *,
        env: dict[str, str] | None = None,
        on_reply_finished: Callable[[str], None] | None = None,
        on_restart: Callable[[], None] | None = None,
        start_timeout: float = 300.0,
        request_timeout: float = 10.0,
    ):
        self._command = list(command)
        self._socket_path = socket_path
        self._env = env
        self._on_reply_finished = on_reply_finished
        self._on_restart = on_restart
        self._start_timeout = start_timeout
        self._request_timeout = request_timeout
        self.input_queue = _InputQueue(self)
        self.instance_id = ""
        self._process: subprocess.Popen | None = None
        self._sock: socket.socket | None = None
        self._generation = 0
        self._ready = threading.Event()
        self._closing = False
        self._failed = False
        self._restarts: list[float] = []
        self._write_lock = threading.Lock()
        self._ids = itertools.count(1)
        self._pending: dict[int, _Pending] = {}
        self._pending_lock = threading.Lock()
        # Replies the service holds, so a restarted service can be given them
        # again: original utterance id -> its ``speak`` request, in queue order.
        self._queued: list[str] = []
        self._held: dict[str, dict] = {}
        # What a service that stopped unexpectedly was still holding.
        self._lost: list[dict] = []
        # Relay Remote devices as the coordinator knows them, for its calls.
        self._remote_sinks: dict[str, Any] = {}
        self._remote_mirrors: dict[str, Any] = {}
        self._events: queue.Queue = queue.Queue()
        self._calls: queue.Queue = queue.Queue()
        for target, name in ((self._event_loop, "speech-client-events"), (self._call_loop, "speech-client-calls")):
            threading.Thread(target=target, name=name, daemon=True).start()

    # -- Lifecycle ---------------------------------------------------------

    def start(self) -> None:
        """Start the service and wait until it has loaded its voice."""
        try:
            self._launch()
        except SpeechServiceError:
            self.close()
            raise

    def close(self) -> None:
        """Stop the service without asking it to finish anything."""
        self._closing = True
        self._ready.clear()
        self._disconnect()
        self._stop_process(grace=0.0)
        self._events.put(None)
        self._calls.put(None)

    def shutdown(self) -> None:
        self._closing = True
        if self._ready.is_set():
            try:
                self._roundtrip("shutdown", {}, timeout=5.0)
            except SpeechServiceError:
                pass
        self._ready.clear()
        self._stop_process(grace=3.0)
        self._disconnect()
        self._events.put(None)
        self._calls.put(None)

    def _launch(self, *, restore: bool = False) -> None:
        # A leftover path could belong to a service this bridge did not start.
        try:
            os.unlink(self._socket_path)
        except OSError:
            pass
        try:
            process = subprocess.Popen(
                [*self._command, "--socket", self._socket_path],
                env=self._env,
                stdin=subprocess.DEVNULL,
            )
        except OSError as exc:
            raise SpeechServiceError(f"could not start the speech service: {exc}") from exc
        self._process = process
        deadline = time.monotonic() + self._start_timeout
        sock = None
        while sock is None:
            if process.poll() is not None:
                raise SpeechServiceError(f"speech service exited with status {process.returncode}")
            if time.monotonic() >= deadline:
                raise SpeechServiceError("speech service did not open its socket")
            candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                candidate.connect(self._socket_path)
                sock = candidate
            except OSError:
                candidate.close()
                time.sleep(0.02)
        with self._write_lock:
            self._generation += 1
            generation = self._generation
            self._sock = sock
        self._queued = []
        self._held = {}
        threading.Thread(
            target=self._read_loop, args=(sock, generation), name="speech-client-read", daemon=True
        ).start()
        hello = self._roundtrip(
            "hello",
            {"protocol": PROTOCOL_VERSION, "client": "voice_bridge", "pid": os.getpid()},
            timeout=max(1.0, deadline - time.monotonic()),
            wait_ready=False,
        )
        if hello.get("protocol") != PROTOCOL_VERSION:
            raise SpeechServiceError("speech service speaks another protocol version")
        self.instance_id = str(hello.get("instance_id") or "")
        if restore:
            self._restore()
        self._ready.set()

    def _restore(self) -> None:
        """Give a restarted service the devices and the replies the old one held."""
        if self._on_restart is not None:
            try:
                self._on_restart()
            except Exception as exc:
                print(f"[speech_client] Restart callback failed: {exc}", file=sys.stderr)
        for role, devices in (("sink", self._remote_sinks), ("mirror", self._remote_mirrors)):
            for device_id in list(devices):
                self._roundtrip("remote_attach", {"device_id": device_id, "role": role}, wait_ready=False)
        for params in self._lost:
            self._roundtrip("speak", params, wait_ready=False)
        if self._lost:
            print(f"[speech_client] Resubmitted {len(self._lost)} queued replies.", file=sys.stderr)
        self._lost = []

    def _restart(self) -> None:
        while not self._closing:
            now = time.monotonic()
            self._restarts = [at for at in self._restarts if now - at < RESTART_WINDOW_SECONDS]
            if len(self._restarts) >= MAX_RESTARTS:
                self._failed = True
                print("[speech_client] Speech service keeps failing; speech is off.", file=sys.stderr)
                return
            self._restarts.append(now)
            self._stop_process(grace=0.0)
            try:
                self._launch(restore=True)
            except SpeechServiceError as exc:
                print(f"[speech_client] Speech service restart failed: {exc}", file=sys.stderr)
                self._disconnect()
                continue
            print("[speech_client] Speech service restarted.", file=sys.stderr)
            return

    def _stop_process(self, *, grace: float) -> None:
        process, self._process = self._process, None
        if process is None:
            return
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def _disconnect(self) -> None:
        with self._write_lock:
            sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

    # -- Wire --------------------------------------------------------------

    def _send(self, message: dict) -> None:
        data = json.dumps(message, separators=(",", ":"), default=str).encode("utf-8") + b"\n"
        with self._write_lock:
            sock = self._sock
            if sock is None:
                raise SpeechServiceError("speech service is not connected")
            try:
                sock.sendall(data)
            except OSError as exc:
                raise SpeechServiceError("speech service connection lost") from exc

    def _roundtrip(
        self,
        op: str,
        params: dict,
        *,
        timeout: float | None = None,
        wait_ready: bool = True,
    ) -> dict:
        timeout = self._request_timeout if timeout is None else timeout
        if wait_ready and not self._ready.wait(0 if self._failed or self._closing else timeout):
            raise SpeechServiceError("speech service is unavailable")
        pending = _Pending(op, params)
        request_id = next(self._ids)
        with self._pending_lock:
            self._pending[request_id] = pending
        try:
            self._send({"id": request_id, "op": op, **params})
            if not pending.answered.wait(timeout):
                raise SpeechServiceError(f"speech service did not answer {op}")
        finally:
            with self._pending_lock:
                self._pending.pop(request_id, None)
        message = pending.message or {}
        if not message.get("ok"):
            error = message.get("error")
            code = error.get("code") if isinstance(error, dict) else "connection_lost"
            raise SpeechServiceError(f"speech service refused {op}: {code}")
        result = message.get("result")
        return result if isinstance(result, dict) else {}

    def _request(self, op: str, params: dict | None = None) -> dict:
        """One request; a service that cannot answer counts as an empty result."""
        try:
            return self._roundtrip(op, params or {})
        except (SpeechServiceError, TypeError, ValueError) as exc:
            if not (self._failed or self._closing):
                print(f"[speech_client] {exc}", file=sys.stderr)
            return {}

    def _read_loop(self, sock: socket.socket, generation: int) -> None:
        try:
            with sock.makefile("rb") as reader:
                for line in reader:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(message, dict):
                        continue
                    if "call" in message:
                        self._calls.put(message)
                    elif "event" in message:
                        if message["event"] == "state":
                            self._note_state(message)
                        self._events.put(message)
                    elif "id" in message:
                        self._resolve(message)
        except (OSError, ValueError):
            pass
        finally:
            self._connection_lost(generation)

    def _resolve(self, message: dict) -> None:
        with self._pending_lock:
            pending = self._pending.get(message.get("id"))
        if pending is None:
            return
        result = message.get("result")
        if pending.op == "speak" and message.get("ok") and isinstance(result, dict):
            utterance_id = str(result.get("utterance_id") or "")
            # The state that lists it was sent before this response.
            if result.get("accepted") and utterance_id in self._queued:
                self._held[utterance_id] = pending.params
        pending.message = message
        pending.answered.set()

    def _note_state(self, state: dict) -> None:
        queued = [
            str(item.get("original_utterance_id") or "")
            for item in state.get("queue") or []
            if isinstance(item, dict)
        ]
        self._queued = queued
        # Keep what is still queued, in the order it would play.
        self._held = {key: self._held[key] for key in queued if key in self._held}

    def _connection_lost(self, generation: int) -> None:
        with self._write_lock:
            if generation != self._generation:
                return
            sock, self._sock = self._sock, None
        was_ready = self._ready.is_set()
        self._ready.clear()
        if sock is not None:
            sock.close()
        with self._pending_lock:
            waiting = list(self._pending.values())
        for pending in waiting:
            pending.answered.set()
        if self._closing or not was_ready:
            return
        self._lost = list(self._held.values())
        print("[speech_client] Speech service stopped unexpectedly; restarting it.", file=sys.stderr)
        threading.Thread(target=self._restart, name="speech-client-restart", daemon=True).start()

    def _event_loop(self) -> None:
        while True:
            event = self._events.get()
            if event is None:
                return
            name = event.get("event")
            try:
                if name == "reply_finished" and self._on_reply_finished is not None:
                    self._on_reply_finished(str(event.get("reason") or "completed"))
                elif name == "error":
                    print(f"[speech_client] Speech service error: {event.get('code')}", file=sys.stderr)
            except Exception as exc:
                print(f"[speech_client] Event handler failed: {exc}", file=sys.stderr)

    def _call_loop(self) -> None:
        """Answer the service's calls on Relay Remote devices, one at a time."""
        while True:
            call = self._calls.get()
            if call is None:
                return
            reply: dict[str, Any] = {"reply": call.get("call"), "ok": True}
            try:
                reply["result"] = self._answer(call)
            except Exception as exc:
                reply.update(ok=False, error={"code": "call_failed", "message": type(exc).__name__})
            try:
                self._send(reply)
            except SpeechServiceError:
                pass

    def _answer(self, call: dict) -> dict:
        devices = self._remote_mirrors if call.get("role") == "mirror" else self._remote_sinks
        device = devices[str(call.get("device_id") or "")]
        op = call.get("op")
        if op == "remote_routable":
            return {"routable": bool(device.routable())}
        if op == "remote_speech":
            frame = {name: call[name] for name in _REMOTE_SPEECH_FIELDS if name in call}
            return {"seq": int(device.speech(**frame))}
        if op == "remote_speech_control":
            return {"seq": int(device.speech_control(str(call.get("action")), str(call.get("reason"))))}
        if op == "remote_speech_audio":
            device.speech_audio(int(call["seq"]), remote_audio.AudioPart(
                part=int(call["part"]),
                parts=int(call["parts"]),
                last=bool(call.get("last")),
                data=str(call.get("data") or ""),
                format=str(call.get("format") or remote_audio.AUDIO_FORMAT),
                sample_rate=int(call.get("sample_rate") or remote_audio.SAMPLE_RATE),
            ))
            return {}
        raise ValueError("unknown call")

    # -- The SpeechCoordinator surface the bridge uses ---------------------

    @property
    def speaking(self) -> bool:
        return bool(self._request("status").get("speaking"))

    @property
    def has_pending_speech(self) -> bool:
        return self.speaking

    @property
    def playing(self) -> bool:
        return bool(self._request("status").get("playing"))

    @property
    def queue_depth(self) -> int:
        return int(self._request("status").get("queue_depth") or 0)

    def session_playback_states(self, *, waiting_session_key: str = "") -> dict[str, str]:
        states = self._request(
            "session_playback_states", {"waiting_session_key": waiting_session_key}
        ).get("states")
        return dict(states) if isinstance(states, dict) else {}

    def control_session(self, session_key: str, action: str, *, waiting_session_key: str = "") -> bool:
        return bool(self._request("control_session", {
            "session_key": session_key,
            "action": action,
            "waiting_session_key": waiting_session_key,
        }).get("handled"))

    def read_out(self, text: str, *, session_key: str = "") -> bool:
        return bool(self._request("read_out", {"text": text, "session_key": session_key}).get("accepted"))

    def play(self) -> None:
        self._request("play")

    def play_or_replay(self) -> bool:
        return bool(self._request("play_or_replay").get("handled"))

    def replay(self) -> bool:
        return bool(self._request("replay").get("accepted"))

    def stop(self) -> None:
        self._request("pause")

    def stop_playback(self, *, reason: str = "user_stop") -> None:
        self._request("stop_playback", {"reason": reason})

    def skip(self, *, reason: str = "user_stop") -> None:
        self._request("skip", {"reason": reason})

    def new_turn(self, command_seq: int, command_id: str) -> None:
        self._request("new_turn", {"command_seq": int(command_seq), "command_id": str(command_id)})

    def arm_waiting_playback(self, command_seq: int, command_id: str, *, kind: str = "final") -> None:
        self.input_queue.arm_waiting_playback(command_seq, command_id, kind=kind)

    def note_play_control(
        self,
        *,
        option_detected_at: float | None = None,
        fifo_received_at: float | None = None,
    ) -> None:
        self._request("note_play_control", {
            "option_detected_at": option_detected_at,
            "fifo_received_at": fifo_received_at,
        })

    def note_visual_acknowledgement(self, *, option_detected_at: float, acknowledged_at: float) -> None:
        self._request("note_visual_acknowledgement", {
            "option_detected_at": option_detected_at,
            "acknowledged_at": acknowledged_at,
        })

    def played_coverage(self, command_seq: int, command_id: str) -> tuple[dict[str, Any], ...]:
        coverage = self._request(
            "played_coverage", {"command_seq": int(command_seq), "command_id": str(command_id)}
        ).get("coverage")
        return tuple(item for item in coverage or () if isinstance(item, dict))

    def record_realization(
        self,
        command_seq: int,
        command_id: str,
        *,
        lifecycle_role: str,
        decision: str,
        reason: str,
    ) -> None:
        self._request("record_realization", {
            "command_seq": int(command_seq),
            "command_id": str(command_id),
            "lifecycle_role": lifecycle_role,
            "decision": decision,
            "reason": reason,
        })

    def record_messenger_stage(
        self,
        stage: str,
        command_seq: int,
        command_id: str,
        *,
        at: float | None = None,
        provider: str | None = None,
        outcome: str = "ok",
    ) -> None:
        self._request("record_messenger_stage", {
            "stage": stage,
            "command_seq": int(command_seq),
            "command_id": str(command_id),
            "at": at,
            "provider": provider,
            "outcome": outcome,
        })

    def record_missing_outcome(
        self,
        command_seq: int,
        command_id: str,
        reason: str,
        *,
        signals: list[str] | tuple[str, ...] = (),
    ) -> bool:
        return bool(self._request("record_missing_outcome", {
            "command_seq": int(command_seq),
            "command_id": str(command_id),
            "reason": reason,
            "signals": list(signals),
        }).get("recorded"))

    def reload_config(self) -> None:
        self._request("reload_config")

    # A device is known here for as long as the service may call on it.

    def attach_remote_sink(self, sink) -> None:
        self._remote_sinks[sink.device_id] = sink
        self._request("remote_attach", {"device_id": sink.device_id, "role": "sink"})
        self._remote_mirrors.pop(sink.device_id, None)

    def detach_remote_sink(self, device_id: str, *, reason: str = "closed") -> None:
        self._request("remote_detach", {"device_id": str(device_id), "role": "sink", "reason": reason})
        self._remote_sinks.pop(str(device_id), None)

    def attach_remote_mirror(self, sink) -> None:
        self._remote_mirrors[sink.device_id] = sink
        self._request("remote_attach", {"device_id": sink.device_id, "role": "mirror"})

    def detach_remote_mirror(self, device_id: str) -> None:
        self._request("remote_detach", {"device_id": str(device_id), "role": "mirror"})
        self._remote_mirrors.pop(str(device_id), None)

    def remote_ack(self, device_id: str, seq: int, played: bool) -> bool:
        return bool(self._request(
            "remote_ack", {"device_id": str(device_id), "seq": int(seq), "played": bool(played)}
        ).get("known"))
