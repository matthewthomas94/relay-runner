"""Shared harness for the voice bridge contract suite (RR-483).

The bridge under test is an opaque command. Nothing here imports the
implementation: the suite starts the process inside a private folder, with
every path it touches redirected by environment variable, and talks to it only
through its FIFO, its sockets and its spool files. Three fakes stand in for the
processes around it:

- a fake orchestrator daemon (`FakeOrchestrator`, an HTTP server in this
  process) that records every call;
- fake `claude` and `codex` executables (`fakes/messenger.py`) that speak the
  messenger protocols from scripted replies;
- a fake speech service (`fakes/speech_service.py`) that speaks the speech
  protocol and records every request.

See docs/specs/voice-bridge-contract.md.
"""

from __future__ import annotations

import errno
import json
import os
import shlex
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FAKES = Path(__file__).resolve().parent / "fakes"
VECTORS = REPO_ROOT / "tests" / "RelayRemoteProtocolTests" / "Vectors"


def _command() -> list:
    configured = os.environ.get("RELAY_VOICE_BRIDGE_CMD", "").strip()
    if configured:
        return shlex.split(configured)
    return [sys.executable, str(REPO_ROOT / "services" / "voice_bridge.py")]


BRIDGE_CMD = _command()
BRIDGE_IS_REFERENCE = not os.environ.get("RELAY_VOICE_BRIDGE_CMD", "").strip()
# How long a case waits for something the bridge should do promptly.
WAIT_SECONDS = float(os.environ.get("RELAY_BRIDGE_CONTRACT_WAIT_SECONDS", "10"))
# How long a case watches for something the bridge must not do.
QUIET_SECONDS = float(os.environ.get("RELAY_BRIDGE_CONTRACT_QUIET_SECONDS", "1.0"))

STARTUP_GREETING = "Hello, what would you like to work on?"
MESSENGER_DEGRADED_TEXT = (
    "I couldn't produce a fast response, but your request is still with the "
    "foreground session."
)
MISSING_REPLY_PREFIX = "I handled that Relay voice turn, but the provider did not send a spoken final reply."
VOICE_PAUSED_PREFIX = "Voice is paused."
PLEASE_REPEAT_TEXT = (
    "Relay Runner is listening again, but your last speech was not captured. "
    "Please repeat your request."
)

# Field names the bridge publishes; they belong to the contract, not to code.
PRESERVE_DISPOSITION = {
    "route": "continue_current",
    "authorization_effect": "preserve",
    "cancellation_scope": "none",
}


def wait_until(predicate, timeout: float = WAIT_SECONDS, message: str = "condition"):
    """Poll until ``predicate`` returns something true, and return it."""
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {message}")
        time.sleep(0.02)


def read_json(path) -> dict:
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def read_jsonl(path) -> list:
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return []
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return records


def load_vectors(name: str):
    return json.loads((VECTORS / f"{name}.json").read_text())


def opaque_identifier(kind: str, value: str) -> str:
    """The continuity identity rule (see "Continuity" in the contract document)."""
    import hashlib

    digest = hashlib.sha256(f"continuity-v1:{kind}:{value}".encode("utf-8")).hexdigest()
    return f"{kind}-{digest[:24]}"


# -- Fake orchestrator --------------------------------------------------------


class FakeOrchestrator:
    """The daemon's HTTP API, as far as the bridge uses it, recording each call."""

    def __init__(self, port_file: Path):
        self.calls: list = []
        self.lock = threading.Lock()
        self.session_id = 41
        self.session_key = "project:contract"
        self.recoverable_commands: list = []
        # GET /v1/messenger/outcomes answers these until each is delivered.
        self.outcomes: list = []
        self.runs: dict = {"runs": []}
        self.program: dict = {"status": "ok"}
        self.sessions: dict = {"orchestrator_sessions": []}
        self.fail_paths: set = set()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _answer(self, method: str) -> None:
                parsed = urllib.parse.urlsplit(self.path)
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                try:
                    body = json.loads(raw) if raw else None
                except ValueError:
                    body = raw.decode("utf-8", "replace")
                query = {key: values[-1] for key, values in urllib.parse.parse_qs(parsed.query).items()}
                call = {"method": method, "path": parsed.path, "query": query, "body": body, "at": time.time()}
                with owner.lock:
                    owner.calls.append(call)
                status, payload = owner.respond(call)
                data = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._answer("GET")

            def do_POST(self):
                self._answer("POST")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        port_file.write_text(f"{self.port}\n")
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def session(self) -> dict:
        return {"id": self.session_id, "session_key": self.session_key, "state": "idle"}

    def respond(self, call: dict) -> tuple:
        path = call["path"]
        if path in self.fail_paths:
            return 503, {"error": "scripted failure"}
        if path == "/v1/orchestrator-session/ensure":
            return 200, {"orchestrator_session": self.session(), "recoverable_commands": self.recoverable_commands}
        if path in ("/v1/orchestrator-session/heartbeat", "/v1/orchestrator-session/stop"):
            return 200, {"orchestrator_session": self.session()}
        if path == "/v1/messenger/outcomes":
            with self.lock:
                return 200, {"outcomes": list(self.outcomes)}
        if path.startswith("/v1/messenger/outcomes/") and path.endswith("/delivered"):
            outcome_id = int(path.split("/")[4])
            with self.lock:
                self.outcomes = [item for item in self.outcomes if item["id"] != outcome_id]
            return 200, {"delivered": True}
        if path == "/v1/runs":
            return 200, self.runs
        if path == "/v1/program/status":
            return 200, self.program
        if path == "/v1/orchestrator-sessions":
            return 200, self.sessions
        return 200, {}

    def add_outcome(self, outcome_id: int, trace: dict) -> None:
        with self.lock:
            self.outcomes.append({"id": outcome_id, "payload": {"trace_event": trace}})

    def requests(self, path: str | None = None, method: str | None = None) -> list:
        with self.lock:
            calls = list(self.calls)
        return [
            call for call in calls
            if (path is None or call["path"] == path) and (method is None or call["method"] == method)
        ]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


# -- Sandbox ------------------------------------------------------------------


class Session:
    """One app-owned voice session's spool, as the app lays it out."""

    def __init__(self, box: "Sandbox", key: str, cwd: Path):
        self.box = box
        self.key = key
        self.cwd = cwd
        self.spool = box.sessions_root / key
        self.provider_session_id = str(uuid.uuid4())

    def path(self, name: str) -> Path:
        return self.spool / name

    @property
    def ready(self) -> Path:
        return self.path("voice_cmd_ready")

    @property
    def meta(self) -> Path:
        return self.path("voice_cmd_ready.meta")

    @property
    def claimed(self) -> Path:
        return self.path("voice_cmd_claimed.json")

    @property
    def manual_ack(self) -> Path:
        return self.path("voice_cmd_manual_ack.json")

    @property
    def state_file(self) -> Path:
        return self.path("voice_command_state.json")

    @property
    def badge(self) -> Path:
        return self.path("voice_reply_badge.json")

    def state(self) -> dict:
        return read_json(self.state_file)

    def pending(self) -> tuple | None:
        """The command waiting in the mailbox: (prompt, metadata), or None."""
        try:
            prompt = self.ready.read_text()
        except OSError:
            return None
        return prompt, read_json(self.meta)

    def wait_pending(self, message: str = "a command in the mailbox") -> tuple:
        return wait_until(self.pending, message=f"{message} of session {self.key}")

    def claim(self) -> dict:
        """Take the waiting command as the app's terminal delivery does.

        The command and metadata files are moved away and the metadata is
        written as the claim file.
        """
        prompt, metadata = self.wait_pending()
        os.unlink(self.ready)
        try:
            os.unlink(self.meta)
        except OSError:
            pass
        temporary = self.claimed.with_suffix(".tmp")
        temporary.write_text(json.dumps(metadata))
        os.replace(temporary, self.claimed)
        metadata["_prompt"] = prompt
        return metadata

    def acknowledge(self, metadata: dict) -> None:
        """Write the consumer acknowledgement a manual provider loop writes."""
        payload = {key: value for key, value in metadata.items() if not key.startswith("_")}
        temporary = self.manual_ack.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload))
        os.replace(temporary, self.manual_ack)

    def focus_payload(self, **fields) -> dict:
        payload = {
            "session_key": self.key,
            "spool_dir": str(self.spool),
            "cwd": str(self.cwd),
            "provider": self.box.provider,
            "provider_session_id": self.provider_session_id,
            "app_session_id": self.box.app_session_id,
            "recovery_generation": self.box.recovery_generation,
        }
        payload.update(fields)
        return payload


class Sandbox:
    """One bridge process with every path it touches inside a private folder."""

    def __init__(
        self,
        test: unittest.TestCase,
        provider: str,
        *,
        app_session: bool = True,
        messenger: bool = True,
        orchestrator: bool = True,
        env: dict | None = None,
        greeting: bool = True,
    ):
        self.test = test
        self.provider = provider
        self.app_session = app_session
        # Short on purpose: a Unix socket path holds at most 104 bytes on macOS.
        self.root = Path(tempfile.mkdtemp(prefix="rbc-", dir="/tmp"))
        test.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.runtime = self.root / "run"
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.repo = self.root / "repo"
        for folder in (self.runtime, self.home, self.bin, self.repo, self.root / "tmp"):
            folder.mkdir(parents=True)
        self.sessions_root = self.runtime / "relay-sessions"
        self.voice_fifo = self.root / "voice_in.fifo"
        self.tts_fifo = self.runtime / "tts_in.fifo"
        self.control_sock = self.root / "bridge.sock"
        self.state_sock = self.root / "state.sock"
        self.remote_sock = self.root / "remote.sock"
        self.speech_sock = self.root / "speech.sock"
        self.speech_control = self.root / "speech-control.sock"
        self.tts_control = self.root / "tts_control.sock"
        self.inbox_path = self.root / "inbox.sqlite3"
        self.speech_log = self.root / "speech.jsonl"
        self.messenger_log = self.root / "messenger.jsonl"
        self.messenger_script = self.root / "messenger-script.json"
        self.event_log = self.root / "command-events.jsonl"
        self.speech_event_log = self.root / "speech-events.jsonl"
        self.authorizations = self.root / "authorizations.json"
        self.turns_file = self.root / "provider_turns.json"
        self.turn_projection = self.root / "provider_turns_v2.json"
        self.port_file = self.root / "orchestrator.port"
        self.config_path = self.root / "config.toml"
        self.stderr_path = self.root / "bridge.stderr"
        self.diagnostics = self.root / "diagnostics"
        self.app_session_id = "app-session-1"
        self.recovery_generation = "1"
        self.extra_env = dict(env or {})
        self.greeting = greeting
        self.process: subprocess.Popen | None = None
        self._writer: int | None = None
        self.datagrams: list = []
        self._datagram_lock = threading.Lock()
        self.orchestrator = FakeOrchestrator(self.port_file) if orchestrator else None
        if self.orchestrator is not None:
            test.addCleanup(self.orchestrator.close)
        self.session = Session(self, "session-1", self.repo)
        self.sessions = {self.session.key: self.session}
        if app_session:
            self.session.spool.mkdir(parents=True, mode=0o700)
        self._write_fakes()
        self.configure(messenger=messenger)
        self.script_messenger([])
        self._state_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self._state_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        self._state_socket.bind(str(self.state_sock))
        self._state_socket.settimeout(0.1)
        self._listening = True
        threading.Thread(target=self._collect_datagrams, daemon=True).start()
        test.addCleanup(self.close)

    # -- Files and environment ---------------------------------------------

    def _write_fakes(self) -> None:
        for provider in ("claude", "codex"):
            wrapper = self.bin / provider
            wrapper.write_text(
                "#!/bin/sh\n"
                f"exec {shlex.quote(sys.executable)} {shlex.quote(str(FAKES / 'messenger.py'))} {provider} \"$@\"\n"
            )
            wrapper.chmod(0o755)

    def configure(self, *, messenger: bool = True) -> None:
        self.config_path.write_text(
            "[general]\n"
            f'provider = "{self.provider}"\n'
            f'command = "{self.bin / self.provider}"\n'
            f"messenger_enabled = {'true' if messenger else 'false'}\n"
            "[tts]\n"
            "auto_play = false\n"
        )

    def script_messenger(self, rules: list, **extra) -> None:
        """Replace the messenger's scripted replies (read again for every prompt)."""
        temporary = self.messenger_script.with_suffix(".tmp")
        temporary.write_text(json.dumps({"rules": rules, **extra}))
        os.replace(temporary, self.messenger_script)

    def add_session(self, key: str) -> Session:
        """Another app-owned session, with its own spool and working directory."""
        cwd = self.root / f"repo-{key}"
        cwd.mkdir()
        session = Session(self, key, cwd)
        session.spool.mkdir(parents=True, mode=0o700)
        self.sessions[key] = session
        return session

    def env(self) -> dict:
        """The bridge's whole environment: nothing of the caller's leaks in."""
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.root / "tmp"),
            "LANG": "en_US.UTF-8",
            "RELAY_BRIDGE_RUNTIME_DIR": str(self.runtime),
            "VOICE_FIFO": str(self.voice_fifo),
            "BRIDGE_CONTROL_SOCK": str(self.control_sock),
            "VOICE_STATE_SOCK": str(self.state_sock),
            "RELAY_REMOTE_SOCK": str(self.remote_sock),
            "TTS_CONTROL_SOCK": str(self.tts_control),
            "RELAY_SPEECH_SERVICE_SOCK": str(self.speech_sock),
            "RELAY_SPEECH_SERVICE_CMD": shlex.join([sys.executable, str(FAKES / "speech_service.py")]),
            "VOICE_INTENT_INBOX": str(self.inbox_path),
            "VOICE_PROVIDER_TURNS_FILE": str(self.turns_file),
            "VOICE_PROVIDER_TURN_PROJECTION_FILE": str(self.turn_projection),
            "VOICE_COMMAND_AUTHORIZATION_FILE": str(self.authorizations),
            "VOICE_COMMAND_EVENT_LOG": str(self.event_log),
            "SPEECH_EVENT_LOG": str(self.speech_event_log),
            "RELAY_DIAGNOSTICS_DIR": str(self.diagnostics),
            "ORCHESTRATOR_PORT_FILE": str(self.port_file),
            # A port nothing listens on, for a sandbox without the fake daemon.
            "ORCHESTRATOR_DEFAULT_PORT": "9",
            "ORCHESTRATOR_HEARTBEAT_SECONDS": "0.5",
            "MESSENGER_OUTCOME_POLL_SECONDS": "0.25",
            "PM_UPDATE_POLL_SECONDS": "0.25",
            "PM_UPDATE_CADENCE_SECONDS": "0.5",
            "PM_UPDATE_STARTUP_GRACE_SECONDS": "0",
            # The missing-reply fallback waits two minutes in a session. A case
            # that checks it shortens it; every other case must never see it.
            "FOREGROUND_REPLY_FALLBACK_SECONDS": "600",
            "PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS": "0.25",
            "RELAY_RUNNER_PROVIDER": self.provider,
            "RELAY_CONTRACT_SPEECH_LOG": str(self.speech_log),
            "RELAY_CONTRACT_SPEECH_CONTROL": str(self.speech_control),
            "RELAY_CONTRACT_MESSENGER_LOG": str(self.messenger_log),
            "RELAY_CONTRACT_MESSENGER_SCRIPT": str(self.messenger_script),
        }
        if self.app_session:
            env.update({
                "RELAY_RUNNER_APP_SESSION": "1",
                "RELAY_SESSION_SPOOL_DIR": str(self.session.spool),
                "RELAY_SESSION_KEY": self.session.key,
                "RELAY_PROVIDER_SESSION_ID": self.session.provider_session_id,
                "RELAY_APP_SESSION_ID": self.app_session_id,
                "RELAY_RECOVERY_GENERATION": self.recovery_generation,
            })
        else:
            # A manual bridge keeps its mailbox at the legacy names.
            env.update({
                "VOICE_CMD_FILE": str(self.runtime / "voice_cmd_ready"),
                "VOICE_COMMAND_STATE_FILE": str(self.runtime / "voice_command_state.json"),
                "VOICE_COMMAND_CLAIM_FILE": str(self.runtime / "voice_cmd_claimed.json"),
                "VOICE_MANUAL_CLAIM_ACK_FILE": str(self.runtime / "voice_cmd_manual_ack.json"),
            })
        env.update(self.extra_env)
        return env

    # -- Process -----------------------------------------------------------

    def command(self) -> list:
        command = [*BRIDGE_CMD, "--config", str(self.config_path), "--relay"]
        if not self.greeting:
            command.append("--suppress-startup-greeting")
        return command

    def start(self, *, wait_ready: bool = True) -> "Sandbox":
        with open(self.stderr_path, "ab") as stderr:
            self.process = subprocess.Popen(
                self.command(),
                cwd=str(self.repo),
                env=self.env(),
                stdin=subprocess.DEVNULL,
                stdout=stderr,
                stderr=stderr,
                start_new_session=True,
            )
        if wait_ready:
            self.wait_ready()
        return self

    def stderr(self) -> str:
        try:
            return self.stderr_path.read_text(errors="replace")
        except OSError:
            return ""

    def _check_alive(self) -> None:
        if self.process is not None and self.process.poll() is not None:
            raise AssertionError(
                f"bridge exited with {self.process.returncode}: {self.stderr()[-3000:]}"
            )

    def _open_writer(self):
        self._check_alive()
        if not is_fifo(self.voice_fifo):
            return None
        try:
            return os.open(self.voice_fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.ENOENT):
                return None
            raise

    def wait_ready(self) -> None:
        """Ready: the FIFO has its reader, the control socket and speech service are up."""
        self._writer = wait_until(self._open_writer, message="the bridge to read its FIFO")
        os.set_blocking(self._writer, True)
        wait_until(lambda: self._check_alive() or self.control_sock.exists(), message="the control socket")
        wait_until(lambda: self.speech_requests("hello"), message="the speech service hello")
        if self.orchestrator is not None:
            wait_until(
                lambda: self.orchestrator.requests("/v1/orchestrator-session/ensure"),
                message="the orchestrator session registration",
            )

    def stop(self, timeout: float = WAIT_SECONDS) -> int:
        """Ask the bridge to shut down on its control socket and wait for it."""
        self.control("shutdown")
        return self.wait_exit(timeout)

    def wait_exit(self, timeout: float = WAIT_SECONDS) -> int:
        returncode = self.process.wait(timeout=timeout)
        self._close_writer()
        return returncode

    def kill(self) -> None:
        os.killpg(self.process.pid, signal.SIGKILL)
        self.process.wait()
        self._close_writer()

    def _close_writer(self) -> None:
        if self._writer is not None:
            try:
                os.close(self._writer)
            except OSError:
                pass
            self._writer = None

    def close(self) -> None:
        self._close_writer()
        if self.process is not None and self.process.poll() is None:
            try:
                self.control("shutdown")
                self.process.wait(timeout=5)
            except (AssertionError, OSError, subprocess.TimeoutExpired):
                pass
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except OSError:
                pass
            self.process.wait()
        self._listening = False
        self._state_socket.close()

    # -- Inputs ------------------------------------------------------------

    def say(self, line: str) -> None:
        """Write one line to the bridge's FIFO, as the app's STT does."""
        if self._writer is None:
            self._writer = wait_until(self._open_writer, message="the bridge to read its FIFO")
            os.set_blocking(self._writer, True)
        data = (line + "\n").encode("utf-8")
        while data:
            written = os.write(self._writer, data)
            data = data[written:]

    def control(self, command) -> None:
        """Send one datagram to the bridge's control socket."""
        payload = command if isinstance(command, str) else json.dumps(command)
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            deadline = time.monotonic() + WAIT_SECONDS
            while True:
                try:
                    sender.sendto(payload.encode("utf-8"), str(self.control_sock))
                    return
                except OSError as error:
                    # macOS creates the file a moment before the socket takes
                    # datagrams, and refuses back-to-back sends with ENOBUFS.
                    if error.errno not in (errno.ENOENT, errno.ECONNREFUSED, errno.ENOBUFS):
                        raise
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.02)
        finally:
            sender.close()

    def speech_command(self, **command) -> None:
        """Drive the fake speech service (see fakes/speech_service.py)."""
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            wait_until(lambda: self.speech_control.exists(), message="the fake speech control socket")
            sender.sendto(json.dumps(command).encode("utf-8"), str(self.speech_control))
        finally:
            sender.close()

    def speak_into_tts_fifo(self, line: str) -> None:
        """Write one line to the TTS input FIFO, the compatibility speech input."""
        wait_until(lambda: self.tts_fifo.exists(), message="the TTS FIFO")
        with open(self.tts_fifo, "w") as fifo:
            fifo.write(line + "\n")

    # -- Outputs -----------------------------------------------------------

    def _collect_datagrams(self) -> None:
        while self._listening:
            try:
                data = self._state_socket.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                message = json.loads(data)
            except ValueError:
                continue
            with self._datagram_lock:
                self.datagrams.append(message)

    def states(self, state: str | None = None, source: str | None = None) -> list:
        """State datagrams sent to the overlay, optionally one state or source."""
        with self._datagram_lock:
            messages = list(self.datagrams)
        return [
            message for message in messages
            if (state is None or message.get("state") == state)
            and (source is None or message.get("source") == source)
        ]

    def speech_records(self) -> list:
        return read_jsonl(self.speech_log)

    def speech_requests(self, op: str | None = None) -> list:
        """Requests the bridge sent the speech service, in order: params plus ``op``."""
        return [
            {"op": record["op"], **record["params"]}
            for record in self.speech_records()
            if record.get("record") == "request" and (op is None or record["op"] == op)
        ]

    def spoken(self, **fields) -> list:
        """``speak`` requests whose fields match ``fields``."""
        return [
            request for request in self.speech_requests("speak")
            if all(request.get(key) == value for key, value in fields.items())
        ]

    def spoken_texts(self, **fields) -> list:
        return [request["text"] for request in self.spoken(**fields)]

    def wait_spoken(self, message: str = "speech", **fields) -> dict:
        return wait_until(lambda: self.spoken(**fields), message=f"{message} {fields}")[-1]

    def wait_speech_request(self, op: str, **fields) -> dict:
        def find():
            return [
                request for request in self.speech_requests(op)
                if all(request.get(key) == value for key, value in fields.items())
            ]
        return wait_until(find, message=f"speech request {op} {fields}")[-1]

    def messenger_records(self, record: str | None = None) -> list:
        return [
            entry for entry in read_jsonl(self.messenger_log)
            if record is None or entry.get("record") == record
        ]

    def messenger_prompts(self, event: str | None = None) -> list:
        return [
            entry for entry in self.messenger_records("prompt")
            if event is None or entry.get("event") == event
        ]

    def wait_messenger_prompt(self, event: str, containing: str = "") -> dict:
        return wait_until(
            lambda: [
                entry for entry in self.messenger_prompts(event)
                if containing in entry.get("content", "")
            ],
            message=f"a messenger {event} prompt containing {containing!r}",
        )[-1]

    def command_events(self) -> list:
        return read_jsonl(self.event_log)

    def inbox(self) -> list:
        """Rows of the intent inbox's ``intents`` table, oldest first."""
        if not self.inbox_path.exists():
            return []
        connection = sqlite3.connect(f"file:{self.inbox_path}?mode=ro", uri=True, timeout=5)
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(
                "SELECT * FROM intents ORDER BY command_seq, within_turn_order, ordinal"
            ).fetchall()
        except sqlite3.Error:
            return []
        finally:
            connection.close()
        return [dict(row) for row in rows]

    def intent_states(self) -> list:
        return [(row["command_seq"], row["within_turn_order"], row["state"]) for row in self.inbox()]

    def wait_intent_state(self, intent_id: str, state: str) -> dict:
        def find():
            return [row for row in self.inbox() if row["intent_id"] == intent_id and row["state"] == state]
        return wait_until(find, message=f"intent {intent_id} to be {state}")[0]

    def authorization_records(self) -> list:
        data = read_json(self.authorizations)
        records = data.get("authorizations") if isinstance(data, dict) else None
        return records if isinstance(records, list) else []

    def runtime_file(self, name: str) -> Path:
        return self.runtime / name

    # -- The completion hook's turn ledger (an input the hook writes) --------

    def turn_record(self, command: dict, state: str = "active", **fields) -> dict:
        """One record of the version 1 turn ledger, as the completion hook writes it."""
        record = {
            "state": state,
            "session_id": self.session.provider_session_id,
            "turn_id": f"turn-{command['relay_command_seq']}-{command.get('within_turn_order', 1)}",
            "created_at": time.time(),
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "provider": self.provider,
            "provider_session_id": self.session.provider_session_id,
            "app_session_id": self.app_session_id,
            "recovery_generation": self.recovery_generation,
            "actor_role": "foreground_pm",
            "foreground_gate_handle": "gate-1",
        }
        if command.get("intent_id"):
            record["intent_id"] = command["intent_id"]
        if command.get("within_turn_order") is not None:
            record["within_turn_order"] = command["within_turn_order"]
        record.update(fields)
        return record

    def write_turns(self, *records: dict) -> None:
        temporary = self.turns_file.with_suffix(".tmp")
        temporary.write_text(json.dumps({"version": 1, "updated_at": time.time(), "records": list(records)}))
        os.replace(temporary, self.turns_file)


def is_fifo(path: Path) -> bool:
    try:
        return stat.S_ISFIFO(os.stat(path).st_mode)
    except OSError:
        return False


class BridgeCase(unittest.TestCase):
    """Base for cases that each start their own bridge.

    A concrete class sets ``provider``; every case file runs its cases for
    ``claude`` and ``codex``.
    """

    maxDiff = None
    provider = "claude"
    app_session = True
    messenger = True
    orchestrator = True
    greeting = True
    start_bridge = True
    env: dict = {}

    def setUp(self):
        self.box = Sandbox(
            self,
            self.provider,
            app_session=self.app_session,
            messenger=self.messenger,
            orchestrator=self.orchestrator,
            env=self.env,
            greeting=self.greeting,
        )
        self.session = self.box.session
        if self.start_bridge:
            self.box.start()

    # -- Turns -------------------------------------------------------------

    def turn(self, text: str) -> dict:
        """Say one user turn and return the newest command it recorded."""
        before = self.session.state().get("relay_command_seq") or 0
        self.box.say(text)
        return wait_until(
            lambda: (
                self.session.state()
                if (self.session.state().get("relay_command_seq") or 0) > before
                else None
            ),
            message=f"the command for {text!r}",
        )

    def turn_delivered(self, text: str) -> tuple:
        """Say one user turn and wait for its command in the mailbox: (prompt, metadata)."""
        command = self.turn(text)
        prompt, metadata = wait_until(
            lambda: (
                self.session.pending()
                if self.session.pending()
                and self.session.pending()[1].get("relay_command_id") == command["relay_command_id"]
                else None
            ),
            message=f"the mailbox command for {text!r}",
        )
        return prompt, metadata

    def claimed_turn(self, text: str) -> dict:
        """Say a turn, claim its command and acknowledge it: the provider owns it."""
        self.turn_delivered(text)
        claimed = self.session.claim()
        self.session.acknowledge(claimed)
        self.box.wait_intent_state(claimed["intent_id"], "acked")
        return claimed

    def reply_line(self, command: dict, text: str, **fields) -> str:
        payload = {
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "text": text,
        }
        if command.get("intent_id"):
            payload["intent_id"] = command["intent_id"]
        payload.update(fields)
        return "__ORCHESTRATOR_REPLY__:" + json.dumps(payload, sort_keys=True)

    def completion_line(self, command: dict, text: str | None = None, **fields) -> str:
        payload = {
            "event": "Stop",
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "session_id": self.session.provider_session_id,
            "provider": self.provider,
        }
        if command.get("intent_id"):
            payload["intent_id"] = command["intent_id"]
        if text is None:
            payload["completion_status"] = "empty"
        else:
            payload["text"] = text
        payload.update(fields)
        return "__RELAY_COMPLETION__:" + json.dumps(payload, sort_keys=True)

    # -- Assertions --------------------------------------------------------

    def assertStays(self, predicate, seconds: float = QUIET_SECONDS, message: str = "condition changed"):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.assertTrue(predicate(), message)
            time.sleep(0.05)

    def assertNeverSpoken(self, text: str, seconds: float = QUIET_SECONDS) -> None:
        self.assertStays(
            lambda: text not in self.box.spoken_texts(),
            seconds,
            f"{text!r} was offered to speech",
        )
