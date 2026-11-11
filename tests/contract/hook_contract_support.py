"""Shared harness for the hook and reply-helper contract suite (RR-477).

The programs under test are opaque commands. Nothing here imports the
implementation; the suite only starts a process, feeds stdin, and reads back
stdout, the exit code, FIFO lines, files and SQLite rows.
See docs/specs/hook-contract.md.
"""

from __future__ import annotations

import hashlib
import json
import os
import select
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

COMPLETION_PREFIX = "__RELAY_COMPLETION__:"
PROVIDER_TURN_EVENT_PREFIX = "__PROVIDER_TURN_EVENT__:"
ORCHESTRATOR_REPLY_PREFIX = "__ORCHESTRATOR_REPLY__:"

# macOS gives a FIFO an 8192-byte buffer; a longer line needs a second write.
FIFO_BUFFER_BYTES = 8192
# How long the slow reader of `Sandbox.slow_fifo_reader` leaves data unread.
SLOW_READER_DELAY_SECONDS = 0.02


def _command(variable: str, script: str) -> list:
    configured = os.environ.get(variable, "").strip()
    if configured:
        return shlex.split(configured)
    # Relay Runner starts both scripts with the system interpreter.
    interpreter = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
    return [interpreter, str(REPO_ROOT / "services" / script)]


HOOK_CMD = _command("RELAY_HOOK_CMD", "relay_completion_hook.py")
REPLY_CMD = _command("RELAY_REPLY_CMD", "relay_reply.py")
HOOK_IS_REFERENCE = not os.environ.get("RELAY_HOOK_CMD", "").strip()
REPLY_IS_REFERENCE = not os.environ.get("RELAY_REPLY_CMD", "").strip()
# The providers stop a hook after 2 seconds.
HOOK_BUDGET_SECONDS = float(os.environ.get("RELAY_HOOK_BUDGET_SECONDS", "2.0"))


def known_difference(reason: str, *, reference: bool = HOOK_IS_REFERENCE):
    """Mark a case whose intended contract the Python implementation misses.

    The case states the contract. It is an expected failure only while the
    default Python script is under test; a replacement must pass it.
    """

    def decorate(test):
        test.known_difference = reason
        return unittest.expectedFailure(test) if reference else test

    return decorate


def stable_event_id(kind: str, *parts) -> str:
    """Identity rule shared by every writer of the provider_turn* tables."""
    material = json.dumps([kind, *parts], sort_keys=True, separators=(",", ":"))
    return kind + ":" + hashlib.sha256(material.encode("utf-8")).hexdigest()


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def process_identity(pid: int) -> str:
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "uid=", "-o", "pgid="],
        capture_output=True, text=True, check=False,
    )
    return result.stdout.strip()


# The tables the hook shares with the voice bridge. `intents` is written only
# by the bridge; the provider_turn* tables are written by both.
INBOX_SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS intents (
    ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
    intent_id TEXT NOT NULL UNIQUE,
    command_seq INTEGER NOT NULL,
    command_id TEXT NOT NULL,
    within_turn_order INTEGER NOT NULL DEFAULT 1,
    prompt TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    route TEXT NOT NULL,
    state TEXT NOT NULL,
    delivery_id TEXT NOT NULL UNIQUE,
    claim_id TEXT,
    ack_id TEXT,
    created_at REAL NOT NULL,
    delivered_at REAL,
    claimed_at REAL,
    acked_at REAL,
    cancelled_at REAL,
    transport TEXT,
    lease_attempts INTEGER NOT NULL DEFAULT 0,
    recovered_at REAL,
    recovery_generation TEXT NOT NULL DEFAULT '0',
    recovery_decision TEXT,
    session_key TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS provider_turn_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS provider_turn_owners (
    owner_id TEXT PRIMARY KEY,
    app_session_id TEXT NOT NULL,
    recovery_generation TEXT NOT NULL,
    actor_role TEXT NOT NULL,
    foreground_gate_handle TEXT NOT NULL,
    created_at REAL NOT NULL,
    UNIQUE(app_session_id, recovery_generation, actor_role, foreground_gate_handle)
);
CREATE TABLE IF NOT EXISTS provider_turns (
    turn_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES provider_turn_owners(owner_id),
    app_session_id TEXT NOT NULL,
    recovery_generation TEXT NOT NULL,
    actor_role TEXT NOT NULL,
    foreground_gate_handle TEXT NOT NULL,
    provider TEXT,
    provider_session_id TEXT,
    native_session_id TEXT NOT NULL,
    native_turn_id TEXT,
    local_turn_seq INTEGER,
    origin TEXT NOT NULL,
    intent_id TEXT,
    command_seq INTEGER,
    command_id TEXT,
    manual_submission_id TEXT,
    manual_submit_evidence_source TEXT,
    state TEXT NOT NULL,
    release_reason TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS provider_turn_transitions (
    transition_ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id),
    event_type TEXT NOT NULL,
    from_state TEXT,
    to_state TEXT NOT NULL,
    occurred_at REAL NOT NULL,
    release_reason TEXT
);
CREATE TABLE IF NOT EXISTS provider_turn_effects (
    effect_id TEXT PRIMARY KEY,
    authority_key TEXT NOT NULL UNIQUE,
    turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id),
    intent_id TEXT,
    effect_kind TEXT NOT NULL,
    state TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
"""

PROVIDER_TURN_TABLES = (
    "provider_turn_meta",
    "provider_turn_owners",
    "provider_turns",
    "provider_turn_transitions",
    "provider_turn_effects",
)


class Result:
    def __init__(self, returncode: int, stdout: bytes, stderr: bytes, elapsed: float):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr.decode("utf-8", "replace")
        self.elapsed = elapsed


def run_command(command, stdin, env, *, cwd=None, timeout: float = 60) -> Result:
    data = stdin if isinstance(stdin, bytes) else json.dumps(stdin).encode("utf-8")
    started = time.perf_counter()
    done = subprocess.run(
        command, input=data, env=env, cwd=cwd, capture_output=True, check=False, timeout=timeout,
    )
    return Result(done.returncode, done.stdout, done.stderr, time.perf_counter() - started)


class Sandbox:
    """One session's files: spool, FIFO, ledgers, binding path and inbox."""

    APP_SESSION_ID = "app-session-1"
    RECOVERY_GENERATION = "generation-1"
    ACTOR_ROLE = "foreground_pm"
    GATE_HANDLE = "gate-1"
    PROVIDER_SESSION_ID = "0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0d"
    NATIVE_SESSION_ID = "6b1d2f90-3c4a-4e5b-8f60-a1b2c3d4e5f6"
    CONTEXT_ID = "context-1"
    THRESHOLD_TOKENS = 150000

    def __init__(self, test: unittest.TestCase, provider: str):
        self.test = test
        self.provider = provider
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="relay-hook-contract-")))
        test.addCleanup(shutil.rmtree, str(self.root), True)
        self.spool = self.root / "relay-sessions" / "session-key-1"
        self.spool.mkdir(parents=True)
        self.workdir = self.root / "project"
        self.workdir.mkdir()
        self.claim_path = self.spool / "voice_cmd_claimed.json"
        self.state_path = self.root / "voice_command_state.json"
        self.manual_path = self.spool / "relay_terminal_manual_submission.json"
        self.fifo_path = self.spool / "voice_in.fifo"
        self.turns_path = self.root / "voice_provider_turns.json"
        self.projection_path = self.root / "voice_provider_turns_v2.json"
        self.inbox_path = self.root / "relay_intent_inbox.sqlite3"
        self.session_events_path = self.root / "session.events.jsonl"
        self.compaction_events_path = self.root / "session.events.jsonl.context-compaction.jsonl"
        self.transcript_path = self.root / "transcript.jsonl"
        self.binding_path = self.root / "bindings" / (self.PROVIDER_SESSION_ID + ".json")
        self.codex_home = self.root / "codex-home"
        self._fifo_reader = None

    # -- environment -----------------------------------------------------

    @property
    def ownership(self) -> dict:
        return {
            "app_session_id": self.APP_SESSION_ID,
            "recovery_generation": self.RECOVERY_GENERATION,
            "actor_role": self.ACTOR_ROLE,
            "foreground_gate_handle": self.GATE_HANDLE,
        }

    def env(self, **overrides) -> dict:
        """Only documented variables; a None override removes one."""
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            # The real HOME keeps the interpreter's bytecode cache warm.
            "HOME": os.environ.get("HOME", str(self.root)),
            "VOICE_COMMAND_STATE_FILE": str(self.state_path),
            "VOICE_COMMAND_CLAIM_FILE": str(self.claim_path),
            "VOICE_PROVIDER_TURNS_FILE": str(self.turns_path),
            "VOICE_PROVIDER_TURN_PROJECTION_FILE": str(self.projection_path),
            "RELAY_TERMINAL_MANUAL_SUBMISSION_FILE": str(self.manual_path),
            "VOICE_INTENT_INBOX": str(self.inbox_path),
            "VOICE_FIFO": str(self.fifo_path),
            "RELAY_SESSION_EVENTS": str(self.session_events_path),
            "RELAY_CONTEXT_COMPACTION_EVENTS": str(self.compaction_events_path),
            "RELAY_AUTO_COMPACT_THRESHOLD_TOKENS": str(self.THRESHOLD_TOKENS),
            "RELAY_SESSION_SPOOL_DIR": str(self.spool),
            "RELAY_SESSION_KEY": self.spool.name,
            "RELAY_RUNNER_PROVIDER": self.provider,
            "RELAY_PROVIDER_SESSION_ID": self.PROVIDER_SESSION_ID,
            "RELAY_APP_SESSION_ID": self.APP_SESSION_ID,
            "RELAY_RECOVERY_GENERATION": self.RECOVERY_GENERATION,
            "RELAY_ACTOR_ROLE": self.ACTOR_ROLE,
            "RELAY_FOREGROUND_GATE_HANDLE": self.GATE_HANDLE,
        }
        for key, value in overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return env

    def binding_env(self, **overrides) -> dict:
        values = {
            "RELAY_SESSION_BINDING_PATH": str(self.binding_path),
            "RELAY_CONTEXT_ID": self.CONTEXT_ID,
            "RELAY_CONTEXT_WORKING_DIRECTORY": str(self.workdir),
            "CODEX_HOME": str(self.codex_home),
        }
        values.update(overrides)
        return self.env(**values)

    # -- running ---------------------------------------------------------

    def hook(self, stdin, *args, env=None, cwd=None, timeout: float = 60) -> Result:
        return run_command(
            [*HOOK_CMD, *args], stdin, self.env() if env is None else env,
            cwd=str(cwd or self.workdir), timeout=timeout,
        )

    def reply(self, text, *, env=None) -> Result:
        data = text if isinstance(text, bytes) else text.encode("utf-8")
        return run_command(REPLY_CMD, data, self.env() if env is None else env, cwd=str(self.workdir))

    def start_hook(self, *args, env=None) -> subprocess.Popen:
        """Start a hook mode that waits, without feeding it stdin."""
        process = subprocess.Popen(
            [*HOOK_CMD, *args], env=self.env() if env is None else env, cwd=str(self.workdir),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.test.addCleanup(stop_process, process)
        return process

    # -- provider payloads -----------------------------------------------

    def turn_fields(self, turn) -> dict:
        """Claude names a turn with prompt_id; Codex sends turn_id."""
        if turn is None:
            return {}
        return {"prompt_id": turn} if self.provider == "claude" else {"turn_id": turn}

    def payload(self, event: str, *, turn="turn-1", session=None, **fields) -> dict:
        payload = {
            "session_id": session or self.NATIVE_SESSION_ID,
            "transcript_path": str(self.transcript_path),
            "cwd": str(self.workdir),
            "hook_event_name": event,
        }
        if self.provider == "claude":
            payload["permission_mode"] = "bypassPermissions"
        else:
            payload["model"] = "codex-model"
        if event in {"UserPromptSubmit", "Stop", "StopFailure"}:
            payload.update(self.turn_fields(turn))
        if event in {"Stop", "StopFailure"}:
            payload["stop_hook_active"] = False
        payload.update(fields)
        return payload

    # -- state the bridge and the app write --------------------------------

    def command(self, seq: int = 7, prompt: str = "ship the release notes", **extra) -> dict:
        command = {
            "relay_command_seq": seq,
            "relay_command_id": "cmd-%d" % seq,
            "intent_id": "intent-%d" % seq,
            "within_turn_order": 1,
            "source_text": prompt,
            "provider": self.provider,
        }
        command.update(extra)
        return command

    def write_claim(self, command: dict) -> None:
        self.claim_path.write_text(json.dumps(command))

    def write_state(self, state: dict) -> None:
        self.state_path.write_text(json.dumps(state))

    def claim(self, seq: int = 7, prompt: str = "ship the release notes", **extra) -> dict:
        """A claimed command that is also the newest command."""
        command = self.command(seq, prompt, **extra)
        self.write_claim(command)
        self.write_state(command)
        return command

    def write_manual_evidence(self, **overrides) -> dict:
        evidence = {
            "state": "pending",
            "evidence_source": "relay_terminal_manual_submit",
            "provider": self.provider,
            "provider_session_id": self.PROVIDER_SESSION_ID,
            "observed_at": time.time(),
            "submission_id": "submission-1",
        }
        evidence.update(self.ownership)
        evidence.update(overrides)
        self.manual_path.write_text(json.dumps(evidence))
        return evidence

    # -- FIFO --------------------------------------------------------------

    def open_fifo(self) -> None:
        os.mkfifo(str(self.fifo_path))
        self._fifo_reader = os.open(str(self.fifo_path), os.O_RDONLY | os.O_NONBLOCK)
        self.test.addCleanup(self.close_fifo_reader)

    def close_fifo_reader(self) -> None:
        if self._fifo_reader is not None:
            os.close(self._fifo_reader)
            self._fifo_reader = None

    def fifo_bytes(self) -> bytes:
        """Everything written since the last read. The writer has exited."""
        chunks = []
        while True:
            try:
                chunk = os.read(self._fifo_reader, 1 << 16)
            except BlockingIOError:
                break
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)

    def slow_fifo_reader(self) -> "SlowFifoReader":
        return SlowFifoReader(self)

    def fifo_lines(self, data=None) -> list:
        data = (self.fifo_bytes() if data is None else data).decode("utf-8")
        if not data:
            return []
        self.test.assertTrue(data.endswith("\n"), "FIFO data must end with a newline: %r" % data[-80:])
        return data[:-1].split("\n")

    def fifo_messages(self, prefix: str) -> list:
        """Parsed lines, after checking each is the canonical sorted JSON."""
        messages = []
        for line in self.fifo_lines():
            self.test.assertTrue(line.startswith(prefix), line[:80])
            message = json.loads(line[len(prefix):])
            self.test.assertEqual(line, prefix + json.dumps(message, sort_keys=True))
            messages.append(message)
        return messages

    # -- files -------------------------------------------------------------

    def read_json(self, path):
        return json.loads(Path(path).read_text())

    def ledger_records(self) -> list:
        if not self.turns_path.exists():
            return []
        ledger = self.read_json(self.turns_path)
        self.test.assertEqual(ledger["version"], 1)
        return ledger["records"]

    def projection_records(self) -> list:
        projection = self.read_json(self.projection_path)
        self.test.assertEqual(projection["schema_version"], 2)
        return projection["records"]

    def jsonl(self, path) -> list:
        path = Path(path)
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def write_transcript(self, records, *, path=None) -> None:
        """One JSON object per line; a str record is written as it is."""
        lines = [record if isinstance(record, str) else json.dumps(record) for record in records]
        Path(path or self.transcript_path).write_text("".join(line + "\n" for line in lines))

    def tree(self) -> list:
        return sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))

    def mode(self, path) -> int:
        return stat.S_IMODE(os.stat(str(path)).st_mode)

    # -- SQLite ------------------------------------------------------------

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(str(self.inbox_path), timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    def create_inbox(self) -> None:
        """Create the inbox and keep it open, as the running bridge does.

        A read-only reader needs the write-ahead log files, which some SQLite
        builds remove when the last connection closes.
        """
        connection = self.connect()
        self.test.addCleanup(connection.close)
        connection.executescript(INBOX_SCHEMA)
        connection.commit()

    def hold_write_lock(self) -> sqlite3.Connection:
        """Keep the inbox write-locked, as a bridge transaction in flight does."""
        connection = sqlite3.connect(str(self.inbox_path), timeout=10, check_same_thread=False)
        connection.execute("BEGIN IMMEDIATE")
        self.test.addCleanup(connection.close)
        return connection

    def rows(self, table: str) -> list:
        if not self.inbox_path.exists():
            return []
        connection = self.connect()
        try:
            known = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
            ).fetchone()
            if known is None:
                return []
            return [dict(row) for row in connection.execute("SELECT * FROM %s ORDER BY rowid" % table)]
        finally:
            connection.close()

    def insert(self, table: str, **values) -> None:
        connection = self.connect()
        try:
            columns = ", ".join(values)
            marks = ", ".join("?" for _ in values)
            connection.execute(
                "INSERT INTO %s(%s) VALUES(%s)" % (table, columns, marks), tuple(values.values())
            )
            connection.commit()
        finally:
            connection.close()

    # -- identities --------------------------------------------------------

    def owner_id(self, **ownership) -> str:
        owner = dict(self.ownership)
        owner.update(ownership)
        return stable_event_id(
            "owner", owner["app_session_id"], owner["recovery_generation"],
            owner["actor_role"], owner["foreground_gate_handle"],
        )

    def turn_id(self, physical_turn: str = "turn-1", *, session=None, provider_session_id=None) -> str:
        """`physical_turn` is the native turn id, `local:<n>` or `session`."""
        return stable_event_id(
            "turn",
            self.owner_id(),
            self.PROVIDER_SESSION_ID if provider_session_id is None else provider_session_id,
            session or self.NATIVE_SESSION_ID,
            physical_turn,
        )

    def seed_turn(self, *, state: str = "active", turn="turn-1", session=None, origin: str = "relay",
                  seq=7, created_at=None, actor_role=None, **columns) -> str:
        """Insert a provider turn the way the bridge would, with plain SQL."""
        created_at = time.time() if created_at is None else created_at
        owner = dict(self.ownership)
        if actor_role:
            owner["actor_role"] = actor_role
        owner_id = self.owner_id(**owner)
        session = session or self.NATIVE_SESSION_ID
        turn_id = stable_event_id("turn", owner_id, self.PROVIDER_SESSION_ID, session, turn or "session")
        connection = self.connect()
        try:
            connection.execute(
                "INSERT OR IGNORE INTO provider_turn_owners VALUES(?, ?, ?, ?, ?, ?)",
                (owner_id, owner["app_session_id"], owner["recovery_generation"],
                 owner["actor_role"], owner["foreground_gate_handle"], created_at),
            )
            row = {
                "turn_id": turn_id,
                "owner_id": owner_id,
                "provider": self.provider,
                "provider_session_id": self.PROVIDER_SESSION_ID,
                "native_session_id": session,
                "native_turn_id": turn,
                "origin": origin,
                "intent_id": None if seq is None else "intent-%d" % seq,
                "command_seq": seq,
                "command_id": None if seq is None else "cmd-%d" % seq,
                "state": state,
                "created_at": created_at,
                "updated_at": created_at,
            }
            row.update(owner)
            row.update(columns)
            connection.execute(
                "INSERT INTO provider_turns(%s) VALUES(%s)"
                % (", ".join(row), ", ".join("?" for _ in row)),
                tuple(row.values()),
            )
            connection.commit()
        finally:
            connection.close()
        return turn_id


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.kill()
    process.communicate()


class SlowFifoReader:
    """Drain the FIFO as a busy bridge does: a moment after data arrives.

    A line longer than the FIFO buffer only arrives whole if the writer waits
    for the reader instead of giving up when the buffer is full.
    """

    def __init__(self, box: Sandbox):
        self.box = box
        self.data = b""
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._drain, daemon=True)

    def _drain(self) -> None:
        descriptor = self.box._fifo_reader
        while not self._stop.is_set():
            readable, _, _ = select.select([descriptor], [], [], 0.05)
            if not readable:
                continue
            time.sleep(SLOW_READER_DELAY_SECONDS)
            try:
                self.data += os.read(descriptor, 1 << 16)
            except BlockingIOError:
                pass

    def __enter__(self) -> "SlowFifoReader":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        self._thread.join()
        self.data += self.box.fifo_bytes()


class ContractCase(unittest.TestCase):
    """Base for cases that run once per provider through a subclass."""

    provider = "claude"
    maxDiff = None

    def setUp(self):
        self.box = Sandbox(self, self.provider)
        self.box.open_fifo()

    def assertQuietSuccess(self, result: Result) -> None:
        """Hook events always exit 0 and print nothing the provider would read."""
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")

    def assertRecent(self, value, started: float) -> None:
        self.assertIsInstance(value, float)
        self.assertGreaterEqual(value, started - 0.001)
        self.assertLessEqual(value, time.time() + 0.001)
