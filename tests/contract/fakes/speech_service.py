#!/usr/bin/env python3
"""Stand-in for the speech service, for the voice bridge contract suite.

The bridge starts this file as `RELAY_SPEECH_SERVICE_CMD` with
`--socket <path> [--config <path>]` appended, exactly as it starts the real
service (docs/specs/speech-service-protocol.md). The fake speaks protocol 1
over that socket, plays nothing, and records what the bridge asks for:

    $RELAY_CONTRACT_SPEECH_LOG   one JSON line per request, call reply and
                                 lifecycle event, in the order handled

A request record is `{"record": "request", "op": ..., "params": {...},
"instance": ..., "at": ...}`. Accepted `speak` requests stay queued until the
suite finishes them. The suite drives the fake through datagrams on
`$RELAY_CONTRACT_SPEECH_CONTROL`:

    {"op": "finish", "reason": "completed"}  drop the head of the queue and
                                             send `reply_finished`
    {"op": "refuse", "value": true}          answer `speak` with accepted false
    {"op": "playing", "value": true}         report audio as playing
    {"op": "crash"}                          exit at once with status 3

While a Relay Remote device is attached as `sink`, an accepted `speak` is sent
to it as a `remote_speech` call first, as the real service does; a `mirror`
receives the same call with `spoken_by: "mac"`. The fake never synthesises
audio, so it sends no `remote_speech_audio`.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import socket
import sys
import threading
import time
import uuid

LOG = os.environ.get("RELAY_CONTRACT_SPEECH_LOG", "")
CONTROL = os.environ.get("RELAY_CONTRACT_SPEECH_CONTROL", "")
INSTANCE = uuid.uuid4().hex


class Service:
    def __init__(self, conn: socket.socket):
        self.conn = conn
        self.lock = threading.RLock()
        self.write_lock = threading.Lock()
        self.queue: list[dict] = []
        self.playing = False
        self.refuse = False
        self.sinks: list[str] = []
        self.mirrors: list[str] = []
        self.calls = 0
        self.replies: dict[int, dict] = {}
        # Replies are read on the reader thread while a request waits for one.
        self.replied = threading.Condition()
        self.requests: queue.Queue = queue.Queue()
        self.last_state = None

    # -- Output ------------------------------------------------------------

    def send(self, message: dict) -> None:
        data = json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
        with self.write_lock:
            self.conn.sendall(data)

    def state(self) -> dict:
        return {
            "speaking": bool(self.queue) or self.playing,
            "playing": self.playing,
            "held": False,
            "queue_depth": len(self.queue),
            "queue": [
                {"utterance_id": item["utterance_id"], "original_utterance_id": item["utterance_id"]}
                for item in self.queue
            ],
        }

    def publish_state(self) -> None:
        snapshot = self.state()
        if snapshot != self.last_state:
            self.last_state = snapshot
            self.send({"event": "state", **snapshot})

    def call(self, op: str, **fields) -> dict | None:
        """Make one call on the client and wait for its reply."""
        with self.replied:
            self.calls += 1
            number = self.calls
        self.send({"call": number, "op": op, **fields})
        with self.replied:
            self.replied.wait_for(lambda: number in self.replies, 10)
            reply = self.replies.pop(number, None)
        record({"record": "call", "op": op, "fields": fields, "reply": reply})
        return reply

    # -- Requests ----------------------------------------------------------

    def receive(self, message: dict) -> None:
        if "reply" in message:
            with self.replied:
                self.replies[message["reply"]] = message
                self.replied.notify_all()
        else:
            self.requests.put(message)

    def serve(self) -> None:
        """Apply requests one at a time, in order, as the real service does."""
        while True:
            message = self.requests.get()
            if message is None:
                return
            self.handle(message)

    def handle(self, message: dict) -> None:
        op = message.get("op")
        params = {key: value for key, value in message.items() if key not in ("id", "op")}
        record({"record": "request", "op": op, "params": params})
        with self.lock:
            result = self.apply(op, params)
            self.publish_state()
        self.send({"id": message.get("id"), "ok": True, "result": result})
        if op == "shutdown":
            os._exit(0)

    def apply(self, op: str, params: dict) -> dict:
        if op == "hello":
            return {
                "protocol": 1, "service": "contract-fake", "instance_id": INSTANCE,
                "pid": os.getpid(), "test_mode": True,
            }
        if op == "status":
            return self.state()
        if op == "speak":
            if self.refuse or not str(params.get("text") or "").strip():
                return {"accepted": False, "utterance_id": ""}
            utterance_id = str(params.get("utterance_id") or uuid.uuid4())
            for device_id in list(self.sinks):
                reply = self.call("remote_speech", device_id=device_id, role="sink", **self.remote_fields(params))
                if not (reply or {}).get("ok"):
                    return {"accepted": False, "utterance_id": ""}
            for device_id in list(self.mirrors):
                self.call("remote_speech", device_id=device_id, role="mirror", spoken_by="mac", **self.remote_fields(params))
            if not self.sinks:
                self.queue.append({"utterance_id": utterance_id, **params})
            return {"accepted": True, "utterance_id": utterance_id}
        if op == "read_out":
            accepted = bool(str(params.get("text") or "").strip())
            if accepted:
                self.queue.append({"utterance_id": str(uuid.uuid4()), **params})
            return {"accepted": accepted}
        if op == "replay":
            return {"accepted": False}
        if op == "play_or_replay":
            return {"handled": bool(self.queue)}
        if op == "session_playback_states":
            return {"states": {}}
        if op == "control_session":
            return {"handled": False}
        if op == "played_coverage":
            return {"coverage": []}
        if op == "record_missing_outcome":
            return {"recorded": True}
        if op == "remote_attach":
            device_id = str(params.get("device_id") or "")
            if params.get("role") == "mirror":
                if device_id not in self.mirrors:
                    self.mirrors.append(device_id)
            else:
                if device_id in self.mirrors:
                    self.mirrors.remove(device_id)
                if device_id not in self.sinks:
                    self.sinks.append(device_id)
            return {}
        if op == "remote_detach":
            device_id = str(params.get("device_id") or "")
            devices = self.mirrors if params.get("role") == "mirror" else self.sinks
            if device_id in devices:
                devices.remove(device_id)
            return {}
        if op == "remote_ack":
            return {"known": False}
        return {}

    @staticmethod
    def remote_fields(params: dict) -> dict:
        return {
            "kind": params.get("kind") or "fallback",
            "source": params.get("source") or "fallback",
            "text": params.get("text") or "",
            "relay_command_seq": params.get("command_seq"),
        }

    # -- Suite commands ----------------------------------------------------

    def command(self, command: dict) -> None:
        record({"record": "control", **command})
        op = command.get("op")
        if op == "crash":
            os._exit(3)
        with self.lock:
            if op == "finish":
                if self.queue:
                    self.queue.pop(0)
                self.playing = False
                self.publish_state()
                if not self.queue:
                    self.send({"event": "reply_finished", "reason": command.get("reason") or "completed"})
            elif op == "refuse":
                self.refuse = bool(command.get("value"))
            elif op == "playing":
                self.playing = bool(command.get("value"))
                self.publish_state()


def record(entry: dict) -> None:
    if not LOG:
        return
    entry = {**entry, "instance": INSTANCE, "at": time.time()}
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")


def listen_for_commands(service: Service) -> None:
    if not CONTROL:
        return
    try:
        os.unlink(CONTROL)
    except OSError:
        pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(CONTROL)

    def loop() -> None:
        while True:
            data = sock.recv(65536)
            try:
                command = json.loads(data)
            except ValueError:
                continue
            if isinstance(command, dict):
                service.command(command)

    threading.Thread(target=loop, daemon=True).start()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--config")
    args = parser.parse_args()
    try:
        os.unlink(args.socket)
    except OSError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(args.socket)
    os.chmod(args.socket, 0o600)
    listener.listen(1)
    record({
        "record": "started", "pid": os.getpid(), "ppid": os.getppid(), "socket": args.socket,
        "config": args.config,
        "env": {
            name: os.environ.get(name)
            for name in ("VOICE_COMMAND_STATE_FILE", "SPEECH_EVENT_LOG", "TTS_CONTROL_SOCK", "VOICE_STATE_SOCK")
        },
    })
    conn, _ = listener.accept()
    listener.close()
    os.unlink(args.socket)
    service = Service(conn)
    listen_for_commands(service)
    threading.Thread(target=service.serve, daemon=True).start()
    with conn.makefile("rb") as reader:
        for line in reader:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict):
                service.receive(message)
    # The client is gone: the real service stops speech and exits.
    record({"record": "stopped"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
