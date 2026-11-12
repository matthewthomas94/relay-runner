"""Shared harness for the speech service contract suite (RR-480).

The service under test is an opaque command. Nothing here imports the
implementation; the suite starts the process in its documented test mode,
speaks the socket protocol, and reads back responses, events, the playback
log, state datagrams and the speech event log.
See docs/specs/speech-service-protocol.md.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROTOCOL_VERSION = 1


def _command() -> list:
    configured = os.environ.get("RELAY_SPEECH_SERVICE_CMD", "").strip()
    if configured:
        return shlex.split(configured)
    return [sys.executable, str(REPO_ROOT / "services" / "speech_service.py")]


SERVICE_CMD = _command()
# How long a case waits for something the service should do promptly.
WAIT_SECONDS = float(os.environ.get("RELAY_SPEECH_CONTRACT_WAIT_SECONDS", "10"))
# Test mode renders this much silence per character of a sentence.
MS_PER_CHAR = 2

# About 0.03 s of test-mode audio: over before a case can act on it.
SHORT = "Short reply."
# About 4 s of test-mode audio at rate 1.0, in 40 sentences: still playing
# when a case acts on it.
LONG_SENTENCES = [f"Sentence {number} keeps this long reply going for a while." for number in range(40)]
LONG = " ".join(LONG_SENTENCES)


def wait_until(predicate, timeout: float = WAIT_SECONDS, message: str = "condition"):
    """Poll until ``predicate`` returns something true, and return it."""
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {message}")
        time.sleep(0.01)


class FakeDevice:
    """A Relay Remote device as the client sees it: it numbers and keeps frames."""

    def __init__(self, device_id: str):
        self.device_id = device_id
        self.routable = True
        # Ops this device answers with a failed reply.
        self.refuse: set = set()
        self.seq = 0
        self.frames: list = []

    def answer(self, call: dict) -> dict | None:
        op = call["op"]
        if op in self.refuse:
            return None
        if op == "remote_routable":
            return {"routable": self.routable}
        if op in ("remote_speech", "remote_speech_control"):
            self.seq += 1
            self.frames.append({**call, "seq": self.seq})
            return {"seq": self.seq}
        if op == "remote_speech_audio":
            self.frames.append(dict(call))
            return {}
        raise AssertionError(f"unexpected call {op}")

    def of(self, op: str) -> list:
        return [frame for frame in self.frames if frame["op"] == op]


class Connection:
    """One client connection: requests, the events received, and answered calls."""

    def __init__(self, path: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
        except OSError:
            self.sock.close()
            raise
        # Every response, event and call, in the order received.
        self.messages: list = []
        self.events: list = []
        self.calls: list = []
        self.devices: dict = {}
        self.closed = threading.Event()
        self._responses: dict = {}
        self._changed = threading.Condition()
        self._next_id = 0
        self._write_lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        try:
            with self.sock.makefile("rb") as reader:
                for line in reader:
                    message = json.loads(line)
                    with self._changed:
                        self.messages.append(message)
                        if "call" in message:
                            self.calls.append(message)
                        elif "event" in message:
                            self.events.append(message)
                        else:
                            self._responses[message.get("id")] = message
                        self._changed.notify_all()
                    if "call" in message:
                        self._answer(message)
        except (OSError, ValueError):
            pass
        finally:
            self.closed.set()
            with self._changed:
                self._changed.notify_all()

    def _answer(self, call: dict) -> None:
        device = self.devices.get((call.get("device_id"), call.get("role")))
        result = device.answer(call) if device is not None else None
        if result is None:
            reply = {"reply": call["call"], "ok": False, "error": {"code": "call_failed"}}
        else:
            reply = {"reply": call["call"], "ok": True, "result": result}
        self.send(reply)

    def send(self, message) -> None:
        data = message if isinstance(message, bytes) else json.dumps(message).encode("utf-8") + b"\n"
        with self._write_lock:
            self.sock.sendall(data)

    def exchange(self, op: str, request_id=None, **params) -> dict:
        """Send one request and return the whole response message."""
        if request_id is None:
            self._next_id += 1
            request_id = self._next_id
        self.send({"id": request_id, "op": op, **params})
        with self._changed:
            if not self._changed.wait_for(
                lambda: request_id in self._responses or self.closed.is_set(), WAIT_SECONDS
            ):
                raise AssertionError(f"no response to {op}")
            if request_id not in self._responses:
                raise AssertionError(f"connection closed before the response to {op}")
            return self._responses.pop(request_id)

    def request(self, op: str, **params) -> dict:
        """Send one request that must succeed and return its result."""
        response = self.exchange(op, **params)
        if not response.get("ok"):
            raise AssertionError(f"{op} failed: {response.get('error')}")
        return response["result"]

    def hello(self) -> dict:
        return self.request("hello", protocol=PROTOCOL_VERSION, client="contract-suite")

    def responses(self) -> list:
        """Every response received, in order."""
        with self._changed:
            return [message for message in self.messages if "id" in message]

    def events_named(self, name: str, **fields) -> list:
        with self._changed:
            return [
                event for event in self.events
                if event.get("event") == name
                and all(event.get(key) == value for key, value in fields.items())
            ]

    def wait_event(self, name: str, timeout: float = WAIT_SECONDS, **fields) -> dict:
        """The first event with this name and these fields, waiting for it if needed."""
        return wait_until(
            lambda: self.events_named(name, **fields),
            timeout,
            f"{name} event {fields}",
        )[0]

    def attach(self, device: FakeDevice, role: str = "sink") -> FakeDevice:
        self.devices[(device.device_id, role)] = device
        self.request("remote_attach", device_id=device.device_id, role=role)
        return device

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class Sandbox:
    """One service process with every path it touches inside a private folder."""

    def __init__(self, test: unittest.TestCase, *, auto_play: bool = False, rate: float = 1.0):
        self.test = test
        # Short on purpose: a Unix socket path holds at most 104 bytes on macOS.
        self.root = Path(tempfile.mkdtemp(prefix="rsc-", dir="/tmp"))
        test.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.socket_path = str(self.root / "speech.sock")
        self.control_path = str(self.root / "tts_control.sock")
        self.state_socket_path = str(self.root / "voice_state.sock")
        self.playback_log = self.root / "playback.jsonl"
        self.event_log = self.root / "speech_events.jsonl"
        self.command_state = self.root / "voice_command_state.json"
        self.config_path = self.root / "config.toml"
        self.configure(auto_play=auto_play, rate=rate)
        self.stderr_path = self.root / "stderr.log"
        self.stdout_path = self.root / "stdout.log"
        # Where the audio lease lives under the service's HOME.
        self.lease_path = (
            self.root / "Library" / "Application Support" / "relay-runner" / "voice-audio.lock"
        )
        self.process: subprocess.Popen | None = None
        self.conn: Connection | None = None
        self.datagrams: list = []
        self._state_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self._state_socket.bind(self.state_socket_path)
        self._state_socket.settimeout(0.1)
        self._listening = True
        threading.Thread(target=self._collect_datagrams, daemon=True).start()
        test.addCleanup(self.close)

    def env(self, **overrides) -> dict:
        """The whole environment of the service: nothing of the caller's leaks in."""
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.root),
            "RELAY_SPEECH_TEST_MODE": "1",
            "RELAY_SPEECH_TEST_PLAYBACK_LOG": str(self.playback_log),
            "RELAY_SPEECH_TEST_MS_PER_CHAR": str(MS_PER_CHAR),
            "TTS_CONTROL_SOCK": self.control_path,
            "VOICE_STATE_SOCK": self.state_socket_path,
            "SPEECH_EVENT_LOG": str(self.event_log),
            "VOICE_COMMAND_STATE_FILE": str(self.command_state),
        }
        env.update(overrides)
        return env

    # -- Process -----------------------------------------------------------

    def command(self) -> list:
        return [*SERVICE_CMD, "--socket", self.socket_path, "--config", str(self.config_path)]

    def spawn(self, **env) -> subprocess.Popen:
        with open(self.stderr_path, "ab") as stderr, open(self.stdout_path, "ab") as stdout:
            self.process = subprocess.Popen(
                self.command(),
                env=self.env(**env),
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
            )
        return self.process

    def configure(self, *, auto_play: bool = False, rate: float = 1.0) -> None:
        """Rewrite config.toml; the service reads it again on ``reload_config``."""
        self.config_path.write_text(
            "[tts]\n"
            f"auto_play = {'true' if auto_play else 'false'}\n"
            f"rate = {rate}\n"
        )

    def stderr(self) -> str:
        return self.stderr_path.read_text(errors="replace")

    def connect(self) -> Connection:
        """Connect as soon as the service listens; the previous connection is dropped."""
        def attempt():
            if self.process.poll() is not None:
                raise AssertionError(
                    f"service exited with {self.process.returncode}: {self.stderr()[-2000:]}"
                )
            try:
                return Connection(self.socket_path)
            except OSError:
                return None

        self.conn = wait_until(attempt, message="the service socket")
        return self.conn

    def start(self, **env) -> Connection:
        """Start the service, connect and say hello."""
        self.spawn(**env)
        conn = self.connect()
        self.hello = conn.hello()
        return conn

    def wait_exit(self, timeout: float = WAIT_SECONDS) -> int:
        return self.process.wait(timeout=timeout)

    def kill(self) -> None:
        self.process.send_signal(signal.SIGKILL)
        self.process.wait()

    def close(self) -> None:
        if self.conn is not None:
            self.conn.close()
        if self.process is not None:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait()
        self._listening = False
        self._state_socket.close()

    # -- Inputs ------------------------------------------------------------

    def set_command(self, seq: int, command_id: str, **fields) -> None:
        """Write the command state file the way the bridge does: whole, then renamed."""
        temporary = self.command_state.with_suffix(".tmp")
        temporary.write_text(json.dumps({
            "relay_command_seq": seq, "relay_command_id": command_id, **fields,
        }))
        os.replace(temporary, self.command_state)

    def control(self, command: str) -> None:
        """Send one datagram to the play/pause control socket."""
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            wait_until(lambda: os.path.exists(self.control_path), message="the control socket")
            sender.sendto(command.encode("utf-8"), self.control_path)
        finally:
            sender.close()

    # -- Outputs -----------------------------------------------------------

    def _collect_datagrams(self) -> None:
        while self._listening:
            try:
                data = self._state_socket.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            self.datagrams.append(json.loads(data))

    def playback(self, event: str | None = None) -> list:
        """The test-mode playback log, optionally only one kind of record."""
        try:
            lines = self.playback_log.read_text().splitlines()
        except FileNotFoundError:
            return []
        records = [json.loads(line) for line in lines if line.strip()]
        return [record for record in records if event is None or record["event"] == event]

    def spoken(self) -> list:
        """The sentences that reached the output, in order, with whether each finished."""
        return [(record["text"], record["completed"]) for record in self.playback("chunk_finished")]

    def logged(self, event: str | None = None) -> list:
        """The speech event log, optionally only one kind of record."""
        try:
            lines = self.event_log.read_text().splitlines()
        except FileNotFoundError:
            return []
        records = [json.loads(line) for line in lines if line.strip()]
        return [record for record in records if event is None or record["event"] == event]


class SpeechCase(unittest.TestCase):
    """Base for cases that each start their own service."""

    maxDiff = None
    auto_play = False
    rate = 1.0

    def setUp(self):
        self.box = Sandbox(self, auto_play=self.auto_play, rate=self.rate)
        self.conn = self.box.start()
        self.commands = 0

    def propose(self, text: str = SHORT, *, command: tuple | None = None, kind: str = "final", **fields) -> dict:
        """Send one ``speak`` for a command (a new one by default) and return its result.

        Without other fields it is the provider's own final reply.
        """
        if command is None:
            command = self.new_command()
        params = {"source": "orchestrator", "authoritative": True}
        params.update(fields)
        return self.conn.request(
            "speak", text=text, command_seq=command[0], command_id=command[1], kind=kind, **params
        )

    def speak(self, text: str = SHORT, **fields) -> str:
        """``propose`` a reply that must be accepted and return its utterance id."""
        result = self.propose(text, **fields)
        self.assertTrue(result["accepted"], "the service did not accept the reply")
        return result["utterance_id"]

    def new_command(self) -> tuple:
        """Make a newer command the current one, as a new user turn does."""
        self.commands += 1
        command = (self.commands, f"command-{self.commands}")
        self.box.set_command(*command)
        return command

    def status(self) -> dict:
        return self.conn.request("status")

    def queue(self) -> list:
        """Original utterance ids in playing order."""
        return [item["original_utterance_id"] for item in self.status()["queue"]]

    def wait_phase(self, utterance_id: str, phase: str, timeout: float | None = None) -> dict:
        return self.conn.wait_event(
            "playback", WAIT_SECONDS if timeout is None else timeout,
            utterance_id=utterance_id, phase=phase,
        )

    def phases(self, utterance_id: str) -> list:
        return [event["phase"] for event in self.conn.events_named("playback", utterance_id=utterance_id)]

    def wait_idle(self) -> None:
        wait_until(lambda: not self.status()["speaking"], message="the queue to empty")

    def assertStays(self, predicate, seconds: float = 0.3, message: str = "condition changed") -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.assertTrue(predicate(), message)
            time.sleep(0.02)
