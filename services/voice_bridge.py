#!/usr/bin/env python3
"""Voice bridge daemon for relay-mode voice sessions.

Supported app/script paths run with --relay: the bridge writes commands to the
foreground agent through /tmp/voice_cmd_ready and runs a persistent tool-free
messenger for spoken replies. /tmp/tts_in.fifo remains as a compatibility and
failure-fallback input. The non-relay branch below is legacy Claude-only direct
mode retained for manual debugging; Start Session and relay-bridge do not use it.
"""

from __future__ import annotations

import hashlib
import json
import os
import queue
import re
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from command_actions import format_command_for_agent, resolve_command_action
from intent_arbitration import (
    ActiveWork,
    CancellationScope,
    IntentDisposition,
    IntentRoute,
    VoiceWorkItem,
    authorization_relationship_for,
    normalize_voice_work_items,
    resolve_intent_disposition,
)
from intent_inbox import IntentInbox, sync_deliverable_state
from provider_turn_broker import ProviderTurnBroker
from relay_authorization import (
    allowed_mutations_for_metadata,
    command_relationship,
    record_command_authorization,
)
from pm_frontstage import (
    OrchestrationTraceEvent,
    PMStatusEvent,
    PMUpdateMode,
    RelayCommandMetadata,
    build_pm_update_snapshot,
)
from config import load_config
from continuity_incidents import normalize_recovery_generation, opaque_identifier
from continuity_recovery import (
    CAPABILITY_POLICIES,
    RecoveryExecutionContext,
    recovery_owner_for,
)
from messenger import MessengerRuntime, create_messenger_runtime
from sidecar_lane import (
    SidecarLane,
    SidecarLifecycleEvent,
    create_sidecar_executor,
)
from speech_coordinator import SpeechCoordinator
from support_diagnostics import record_event as record_support_event
from tts_worker import TTS_CONTROL_SOCK, TTSWorker, publish_waiting_preview

VOICE_FIFO = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")
BRIDGE_CONTROL_SOCK = os.environ.get("BRIDGE_CONTROL_SOCK", "/tmp/voice_bridge.sock")
VOICE_STATE_SOCK = "/tmp/voice_state.sock"
ORCHESTRATOR_PORT_FILE = os.environ.get("ORCHESTRATOR_PORT_FILE", "/tmp/relay_orchestrator.port")
ORCHESTRATOR_DEFAULT_PORT = int(os.environ.get("ORCHESTRATOR_DEFAULT_PORT", "7634"))
ORCHESTRATOR_HEARTBEAT_SECONDS = float(os.environ.get("ORCHESTRATOR_HEARTBEAT_SECONDS", "10"))
PM_UPDATE_POLL_SECONDS = float(os.environ.get("PM_UPDATE_POLL_SECONDS", "2"))
PM_UPDATE_CADENCE_SECONDS = float(os.environ.get("PM_UPDATE_CADENCE_SECONDS", "8"))
PM_UPDATE_STARTUP_GRACE_SECONDS = float(os.environ.get("PM_UPDATE_STARTUP_GRACE_SECONDS", "6"))
STARTUP_GREETING = "Hello, what would you like to work on?"
MESSENGER_OUTCOME_POLL_SECONDS = float(os.environ.get("MESSENGER_OUTCOME_POLL_SECONDS", "2"))
MESSENGER_OUTCOME_FETCH_LIMIT = 50
FOREGROUND_REPLY_FALLBACK_SECONDS = float(os.environ.get("FOREGROUND_REPLY_FALLBACK_SECONDS", "120"))
PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS = float(os.environ.get("PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS", "5"))
_CONTINUITY_SESSION_NATIVE_ID: str | None = None

_FOREGROUND_REPLY_LOCK = threading.Lock()
_FOREGROUND_REPLIED_COMMANDS: set[tuple[int, str]] = set()
_FOREGROUND_REPLY_IN_FLIGHT: set[tuple[int, str]] = set()
_VOICE_STATE_LOCK = threading.RLock()
_RELAY_CONTROL_TYPE_RE = re.compile(r"^__[A-Z][A-Z0-9_]*__$")
_RAW_RELAY_CONTROL_TYPE_RE = re.compile(
    r'"type"\s*:\s*"(?P<type>__[A-Z][A-Z0-9_]*__)"'
)
_RELAY_CONTROL_TYPE_LABELS = {
    "__TTS_STOP__": "tts_stop",
    "__INTERRUPT__": "interrupt",
    "__CANCEL__": "cancel",
    "__PLAY__": "play",
    "__REPLAY__": "replay",
    "__TRACE__": "trace",
    "__ORCHESTRATOR_REPLY__": "orchestrator_reply",
    "__RELAY_COMPLETION__": "relay_completion",
    "__PROVIDER_TURN_EVENT__": "provider_turn_event",
    "__STATUS__": "status",
}


def _notify_state(state: str, **kwargs):
    """Send a state update to the overlay app via Unix datagram socket."""
    msg = {"source": "bridge", "state": state, **kwargs}
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(json.dumps(msg).encode(), VOICE_STATE_SOCK)
        s.close()
    except (OSError, ConnectionRefusedError):
        pass


def ensure_fifo(path: str) -> bool:
    try:
        mode = os.stat(path).st_mode
    except FileNotFoundError:
        pass
    except OSError as e:
        print(f"[voice_bridge] Could not inspect FIFO {path}: {e}", file=sys.stderr)
        return False
    else:
        if stat.S_ISFIFO(mode):
            return True
        try:
            os.unlink(path)
        except OSError as e:
            print(f"[voice_bridge] Could not replace non-FIFO {path}: {e}", file=sys.stderr)
            return False

    try:
        os.mkfifo(path)
        return True
    except FileExistsError:
        try:
            return stat.S_ISFIFO(os.stat(path).st_mode)
        except OSError as e:
            print(f"[voice_bridge] Could not inspect FIFO {path}: {e}", file=sys.stderr)
            return False
    except OSError as e:
        print(f"[voice_bridge] Could not create FIFO {path}: {e}", file=sys.stderr)
        return False


def open_fifo(path: str) -> int | None:
    if not ensure_fifo(path):
        return None
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        print(f"[voice_bridge] Could not open FIFO {path}: {e}", file=sys.stderr)
        return None


class LegacyDirectVoiceBridge:
    """Legacy persistent `claude` session reused across voice prompts.

    This path is intentionally Claude-only and is not a supported user-facing
    launch mode anymore. The first prompt pays CLI startup + MCP-server-spawn
    cost (~5–7s on this machine); subsequent prompts reuse the warm process
    and only pay LLM inference time. Interrupt or crash respawns transparently,
    resuming the same Claude session via --resume so conversation context is
    preserved.
    """

    def __init__(self, claude_bin: str, tts_queue: queue.Queue, session_id: str | None = None):
        self.claude_bin = claude_bin
        self.tts_queue = tts_queue
        self.session_id: str | None = session_id
        self._proc: subprocess.Popen | None = None
        self._reader_thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._pending: dict | None = None

    def _spawn(self) -> subprocess.Popen | None:
        cmd = [
            self.claude_bin,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
        ]
        if self.session_id:
            cmd.extend(["--resume", self.session_id])
        try:
            return subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError as e:
            print(f"[voice_bridge] failed to spawn claude: {e}", file=sys.stderr)
            return None

    def _ensure_warm(self) -> bool:
        with self._lock:
            if self._proc and self._proc.poll() is None:
                return True
            if self._proc is not None:
                print(
                    f"[voice_bridge] warm session died (rc={self._proc.returncode}); respawning",
                    file=sys.stderr,
                )
                self._proc = None
            proc = self._spawn()
            if proc is None:
                return False
            self._proc = proc
            self._reader_thread = threading.Thread(
                target=self._read_stream, args=(proc,), daemon=True
            )
            self._reader_thread.start()
            return True

    def _read_stream(self, proc: subprocess.Popen):
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                sid = obj.get("session_id")
                if sid:
                    self.session_id = sid
                if obj.get("type") == "result":
                    pending = self._pending
                    if pending is not None and not pending["done"]:
                        pending["result_text"] = obj.get("result") or ""
                        pending["done"] = True
                        pending["event"].set()
        except (OSError, ValueError):
            pass
        finally:
            # Wake any pending request so send() doesn't hang on a dead process
            pending = self._pending
            if pending is not None and not pending["done"]:
                pending["done"] = True
                pending["interrupted"] = True
                pending["event"].set()

    def interrupt(self):
        """Kill the warm Claude process; next send() respawns and resumes."""
        with self._lock:
            proc = self._proc
            self._proc = None
        if proc and proc.poll() is None:
            proc.kill()
            proc.wait()
            print("\r\033[2K\033[1;33m  interrupted\033[0m")
            sys.stdout.flush()
        pending = self._pending
        if pending is not None and not pending["done"]:
            pending["interrupted"] = True
            pending["done"] = True
            pending["event"].set()

    def shutdown(self):
        """Close the warm session cleanly on bridge exit."""
        with self._lock:
            proc = self._proc
            self._proc = None
        if proc is None:
            return
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    def send(self, text: str):
        """Send a message to Claude, display + speak the response."""
        print(f"\n\033[1;36m❯ {text}\033[0m")
        print("\033[2m  thinking...\033[0m", end="", flush=True)
        _notify_state("processing", prompt=text[:200])

        envelope = json.dumps({
            "type": "user",
            "message": {"role": "user", "content": text},
        }) + "\n"

        pending = {"event": threading.Event(), "result_text": None, "interrupted": False, "done": False}

        # Up to two attempts: first on warm session, second after respawn if write fails.
        for attempt in range(2):
            if not self._ensure_warm():
                print("\r\033[2K\033[1;31m  spawn failed\033[0m")
                _notify_state("idle")
                return
            self._pending = pending
            try:
                self._proc.stdin.write(envelope)
                self._proc.stdin.flush()
                break
            except (BrokenPipeError, OSError) as e:
                print(f"[voice_bridge] write to warm session failed ({e}); respawning",
                      file=sys.stderr)
                self._pending = None
                with self._lock:
                    self._proc = None
                if attempt == 1:
                    print("\r\033[2K\033[1;31m  send failed\033[0m")
                    _notify_state("idle")
                    return

        completed = pending["event"].wait(timeout=120)
        self._pending = None

        if not completed:
            print("\r\033[2K\033[1;31m  timed out\033[0m")
            self.interrupt()
            _notify_state("idle")
            return

        if pending["interrupted"]:
            _notify_state("idle")
            return

        _notify_state("idle")

        response_text = pending["result_text"] or ""
        if response_text:
            print(f"\r\033[2K\n{response_text}\n")
            sys.stdout.flush()
            self.tts_queue.put(response_text)


VOICE_CMD_FILE = "/tmp/voice_cmd_ready"
VOICE_CMD_META_FILE = "/tmp/voice_cmd_ready.meta"
VOICE_COMMAND_STATE_FILE = "/tmp/voice_command_state.json"
VOICE_COMMAND_CLAIM_FILE = "/tmp/voice_cmd_claimed.json"
VOICE_MANUAL_CLAIM_ACK_FILE = os.environ.get(
    "VOICE_MANUAL_CLAIM_ACK_FILE",
    "/tmp/voice_cmd_manual_ack.json",
)
VOICE_COMMAND_AUTHORIZATION_FILE = os.environ.get(
    "VOICE_COMMAND_AUTHORIZATION_FILE",
    "/tmp/voice_command_authorizations.json",
)
VOICE_PROVIDER_TURNS_FILE = os.environ.get("VOICE_PROVIDER_TURNS_FILE", "/tmp/voice_provider_turns.json")
VOICE_PROVIDER_TURN_PROJECTION_FILE = os.environ.get(
    "VOICE_PROVIDER_TURN_PROJECTION_FILE",
    "/tmp/voice_provider_turns_v2.json",
)
PROVIDER_TURN_BROKER_MODE = os.environ.get(
    "RELAY_PROVIDER_TURN_BROKER_MODE",
    "dual_write",
).strip()
PROVIDER_SESSION_ID = os.environ.get("RELAY_PROVIDER_SESSION_ID", "").strip()
VOICE_COMMAND_EVENT_LOG = os.environ.get(
    "VOICE_COMMAND_EVENT_LOG",
    str(
        Path.home()
        / "Library"
        / "Application Support"
        / "relay-runner"
        / "command-actions"
        / "events.jsonl"
    ),
)
VOICE_INTENT_INBOX = os.environ.get("VOICE_INTENT_INBOX", "/tmp/relay_intent_inbox.sqlite3")
SPEECH_EVENT_LOG = os.environ.get("SPEECH_EVENT_LOG", "/tmp/relay_speech_events.jsonl")
VOICE_COMMAND_EVENT_LIMIT = 200
COMMAND_ACTION_RECOVERY_STATES = frozenset({"claimed", "delivery_failed", "superseded"})
COMMAND_ACTION_TERMINAL_STATES = frozenset({"delivery_failed", "superseded"})
TTS_IN_FIFO = "/tmp/tts_in.fifo"
VOICE_ACKNOWLEDGEMENT = os.environ.get("VOICE_ACKNOWLEDGEMENT", "Got it. I'm on it.")
VOICE_ACKNOWLEDGEMENT_DELAY_SECONDS = 0.0
VOICE_ACKNOWLEDGEMENT_AUTO_DISMISS_SECONDS = 3.0

_GENERIC_ACKNOWLEDGEMENTS = (
    VOICE_ACKNOWLEDGEMENT,
    "Received. I'll take it from here.",
    "Understood. Working on it.",
    "Okay. I'll handle that.",
)
_SENSITIVE_ACK_RE = re.compile(
    r"\b(password|passcode|secret|token|api[_ -]?key|private[_ -]?key|credential|credit card)\b",
    re.IGNORECASE,
)
_INTENT_ACKNOWLEDGEMENTS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"\b(ack|acknowledg)", re.IGNORECASE),
        "I'll take care of the acknowledgement issue.",
    ),
    (
        re.compile(r"\b(subagent|sub-agent|orchestrator model|worker model|gpt-?5|5\.\d)\b", re.IGNORECASE),
        "I'll check the subagent model settings.",
    ),
    (
        re.compile(r"\b(program board|board|ticket card|work card|pill)\b", re.IGNORECASE),
        "I'll update the board behavior.",
    ),
    (
        re.compile(r"\b(test|tests|coverage|failing)\b", re.IGNORECASE),
        "I'll check the tests.",
    ),
    (
        re.compile(r"\b(status|state|show|summari[sz]e|check|look at|inspect)\b", re.IGNORECASE),
        "I'll check that.",
    ),
    (
        re.compile(r"\b(fix|debug|repair|broken|issue|bug)\b", re.IGNORECASE),
        "I'll take care of that issue.",
    ),
    (
        re.compile(r"\b(add|build|create|implement|make|wire)\b", re.IGNORECASE),
        "I'll build that.",
    ),
    (
        re.compile(r"\b(change|update|swap|replace|refactor|tune|adjust)\b", re.IGNORECASE),
        "I'll update that.",
    ),
    (
        re.compile(r"\b(remove|delete|clean up)\b", re.IGNORECASE),
        "I'll remove that.",
    ),
)


def _read_json_file(path: str) -> dict:
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def _atomic_write_json(path: str, payload: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, sort_keys=True)
    os.rename(tmp, path)


def _command_action_journal_snapshot(
    *,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    repo_path: str | Path | None = None,
    limit: int = 20,
) -> list[dict]:
    """Return latest recovery-relevant command states from the private journal."""
    if not event_log_path:
        return []
    try:
        with open(event_log_path) as f:
            lines = [line for line in f if line.strip()]
    except OSError:
        return []

    by_id: dict[str, dict] = {}
    order: list[str] = []
    for line in lines:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        command_id = str(event.get("relay_command_id") or "").strip()
        intent_id = str(event.get("intent_id") or "").strip()
        event_id = intent_id or command_id
        try:
            command_seq = int(event.get("relay_command_seq"))
        except (TypeError, ValueError):
            continue
        state = str(event.get("state") or "").strip().lower()
        if not command_id or not state:
            continue

        current = by_id.get(event_id, {
            "relay_command_id": command_id,
            "relay_command_seq": command_seq,
        })
        if intent_id:
            current["intent_id"] = intent_id
        for name in (
            "source_text",
            "provider",
            "repo_path",
            "action",
            "outcome",
            "received_at",
            "within_turn_order",
            "target",
            "disposition",
            "cancellation_scope",
            "lifecycle_state",
        ):
            value = event.get(name)
            if value is not None and value != "":
                current[name] = value
        current["relay_command_seq"] = command_seq
        current_state = str(current.get("state") or "")
        if (
            state in COMMAND_ACTION_TERMINAL_STATES
            or current_state not in COMMAND_ACTION_TERMINAL_STATES
        ):
            current["state"] = state
        if event_id in order:
            order.remove(event_id)
        order.append(event_id)
        by_id[event_id] = current

    resolved_repo = (
        str(Path(repo_path).expanduser().resolve())
        if repo_path is not None
        else None
    )
    snapshot: list[dict] = []
    for event_id in order:
        event = by_id[event_id]
        if event.get("state") not in COMMAND_ACTION_RECOVERY_STATES:
            continue
        event_repo = event.get("repo_path")
        if event_repo and resolved_repo:
            try:
                if str(Path(str(event_repo)).expanduser().resolve()) != resolved_repo:
                    continue
            except (OSError, RuntimeError):
                continue
        elif resolved_repo:
            event["repo_path"] = resolved_repo
        snapshot.append(event)
    return snapshot[-max(1, int(limit)):]


def _orchestrator_port(port_file: str = ORCHESTRATOR_PORT_FILE) -> int:
    try:
        raw = Path(port_file).read_text().strip()
        return int(raw) if raw else ORCHESTRATOR_DEFAULT_PORT
    except (OSError, TypeError, ValueError):
        return ORCHESTRATOR_DEFAULT_PORT


def _post_orchestrator_json(path: str, payload: dict, *, timeout: float = 1.0) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{_orchestrator_port()}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read()
    if not body:
        return {}
    data = json.loads(body.decode("utf-8"))
    return data if isinstance(data, dict) else {}


def _get_orchestrator_json(path: str, params: dict[str, object] | None = None, *, timeout: float = 1.0) -> dict:
    query = urllib.parse.urlencode({
        key: value
        for key, value in (params or {}).items()
        if value is not None and value != ""
    })
    url = f"http://127.0.0.1:{_orchestrator_port()}{path}"
    if query:
        url += "?" + query
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read()
    if not body:
        return {}
    data = json.loads(body.decode("utf-8"))
    return data if isinstance(data, dict) else {}


def _post_continuity_event(
    source: str,
    event: str,
    metadata: dict | None = None,
    *,
    observed_at: float | None = None,
    request_json=_post_orchestrator_json,
) -> dict:
    """Send only allowlisted lifecycle identity, never native event contents."""
    source_data = metadata if isinstance(metadata, dict) else {}
    session_id = (
        _CONTINUITY_SESSION_NATIVE_ID
        or source_data.get("session_id")
    )
    if not session_id:
        return {}
    raw_generation = source_data.get("recovery_generation")
    if raw_generation is None or raw_generation == "":
        raw_generation = os.environ.get("RELAY_RECOVERY_GENERATION") or "0"
    try:
        recovery_generation = normalize_recovery_generation(raw_generation)
    except ValueError:
        return {}
    payload = {
        "source": source,
        "event": event,
        "session_id": session_id,
        "relay_command_id": source_data.get("relay_command_id"),
        "provider": (
            source_data.get("provider")
            or os.environ.get("RELAY_RUNNER_PROVIDER")
            or "codex"
        ),
        "recovery_generation": recovery_generation,
        "observed_at": observed_at if observed_at is not None else time.time(),
    }
    try:
        return request_json("/v1/continuity/observation", payload)
    except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return {}


def _observe_stt_status(status: str) -> None:
    normalized = str(status or "").strip().lower()
    if normalized.startswith("(refining)") or normalized.startswith("refining"):
        _post_continuity_event("stt", "transcription_started")


def _observe_stt_continuity_signal(signal: str) -> None:
    normalized = str(signal or "").strip().lower()
    event = {
        "capture_failed": "capture_failed",
        "transcription_started": "transcription_started",
        "transcription_failed": "transcription_failed",
    }.get(normalized)
    if event is not None:
        _post_continuity_event("stt", event)


def _bridge_provider(cfg: dict) -> str:
    env_provider = os.environ.get("RELAY_RUNNER_PROVIDER", "").strip().lower()
    if env_provider:
        return env_provider
    general = cfg.get("general") if isinstance(cfg, dict) else {}
    provider = str((general or {}).get("provider") or "codex").strip().lower()
    return "claude" if "claude" in provider else "codex"


def _bridge_model(cfg: dict) -> str | None:
    general = cfg.get("general") if isinstance(cfg, dict) else {}
    model = str((general or {}).get("model") or "").strip().lower()
    return model or None


def _bridge_effort(cfg: dict) -> str | None:
    general = cfg.get("general") if isinstance(cfg, dict) else {}
    effort = str((general or {}).get("orchestrator_effort") or "").strip().lower()
    return effort or None


def start_persistent_orchestrator_lifecycle(
    cfg: dict,
    shutdown_event: threading.Event,
    *,
    cwd: str | None = None,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    request_json=_post_orchestrator_json,
) -> dict | None:
    """Register this bridge as the durable foreground orchestrator session.

    The lifecycle record is daemon/database state plus periodic heartbeats; it
    does not spawn or keep a model process busy while idle.
    """
    repo_path = str(Path(cwd or os.getcwd()).expanduser().resolve())
    provider = _bridge_provider(cfg)
    payload = {
        "repo_path": repo_path,
        "provider": provider,
        "model": _bridge_model(cfg),
        "effort": _bridge_effort(cfg),
        "source": "relay-bridge",
        "pid": os.getpid(),
        "state": "idle",
        "command_action_states": _command_action_journal_snapshot(
            event_log_path=event_log_path,
            repo_path=repo_path,
        ),
    }
    try:
        response = request_json("/v1/orchestrator-session/ensure", payload)
    except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        print(f"[voice_bridge] Persistent orchestrator unavailable: {e}", file=sys.stderr)
        return None

    session = response.get("orchestrator_session") if isinstance(response, dict) else None
    if not isinstance(session, dict) or not session.get("id"):
        print("[voice_bridge] Persistent orchestrator did not return a session id.", file=sys.stderr)
        return None

    session_id = int(session["id"])
    session_key = str(session.get("session_key") or "").strip()
    if not session_key:
        session_key = "project:" + hashlib.sha1(repo_path.encode("utf-8")).hexdigest()[:16]
    global _CONTINUITY_SESSION_NATIVE_ID
    _CONTINUITY_SESSION_NATIVE_ID = session_key
    recoverable_commands = response.get("recoverable_commands")
    if isinstance(recoverable_commands, list):
        session["recoverable_commands"] = [
            command for command in recoverable_commands if isinstance(command, dict)
        ]
    session_state = {"value": "idle"}
    session_lock = threading.Lock()

    def _send_heartbeat() -> None:
        with session_lock:
            heartbeat_state = session_state["value"]
        try:
            request_json(
                "/v1/orchestrator-session/heartbeat",
                {
                    "session_id": session_id,
                    "repo_path": repo_path,
                    "provider": provider,
                    "state": heartbeat_state,
                },
            )
        except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
            print(f"[voice_bridge] Persistent orchestrator heartbeat failed: {e}", file=sys.stderr)

    def _heartbeat_loop() -> None:
        _send_heartbeat()
        while not shutdown_event.wait(ORCHESTRATOR_HEARTBEAT_SECONDS):
            _send_heartbeat()

    thread = threading.Thread(
        target=_heartbeat_loop,
        name="orchestrator-lifecycle-heartbeat",
        daemon=True,
    )
    thread.start()
    print(
        f"[voice_bridge] Persistent orchestrator session {session_id} active "
        f"provider={provider} repo={repo_path}",
        file=sys.stderr,
    )
    return {
        "session_id": session_id,
        "session_key": session_key,
        "repo_path": repo_path,
        "provider": provider,
        "thread": thread,
        "shutdown_event": shutdown_event,
        "state": session_state,
        "state_lock": session_lock,
        "recoverable_commands": session.get("recoverable_commands", []),
    }


def stop_persistent_orchestrator_lifecycle(
    session: dict | None,
    *,
    reason: str,
    request_json=_post_orchestrator_json,
) -> None:
    if not session:
        return
    event = session.get("shutdown_event")
    if hasattr(event, "set"):
        event.set()
    thread = session.get("thread")
    if hasattr(thread, "join"):
        thread.join(timeout=0.5)
    payload = {"reason": reason}
    if session.get("session_id"):
        payload["session_id"] = session["session_id"]
    elif session.get("repo_path"):
        payload["repo_path"] = session["repo_path"]
    else:
        return
    try:
        request_json("/v1/orchestrator-session/stop", payload)
    except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        print(f"[voice_bridge] Persistent orchestrator stop failed: {e}", file=sys.stderr)
    finally:
        global _CONTINUITY_SESSION_NATIVE_ID
        if _CONTINUITY_SESSION_NATIVE_ID == session.get("session_key"):
            _CONTINUITY_SESSION_NATIVE_ID = None


def _surface_recoverable_command_status(
    orchestrator_session: dict | None,
    *,
    messenger: MessengerRuntime | None,
    notify_state=_notify_state,
) -> str | None:
    commands = (orchestrator_session or {}).get("recoverable_commands")
    if not isinstance(commands, list) or not commands:
        return None
    clarification_count = sum(
        1 for command in commands
        if isinstance(command, dict) and command.get("status") == "clarification_required"
    )
    delivery_failed_count = sum(
        1 for command in commands
        if isinstance(command, dict) and command.get("status") == "delivery_failed"
    )
    if clarification_count:
        message = (
            "A previous project-work request is waiting for a target project. "
            "Choose a child project in Workspace, then repeat the request; no parent workspace ticket was created."
        )
    elif delivery_failed_count:
        noun = "request" if delivery_failed_count == 1 else "requests"
        message = (
            f"Delivery failed for {delivery_failed_count} previous project-work {noun} "
            "before a ticket action was confirmed. Repeat the request in this recovered session; "
            "completed mutations will not be replayed."
        )
    else:
        count = len(commands)
        noun = "request" if count == 1 else "requests"
        message = (
            f"{count} previous project-work {noun} did not reach a confirmed ticket action. "
            "Repeat the request in this recovered session; completed mutations will not be replayed."
        )
    notify_state("working", text=message)
    if messenger is not None:
        messenger.submit_trace({
            "kind": "command-recovery",
            "message": message,
            "source": "orchestrator",
        })
    return message


def _set_orchestrator_session_state(session: dict | None, state: str) -> None:
    if not session:
        return
    lock = session.get("state_lock")
    holder = session.get("state")
    if not hasattr(lock, "__enter__") or not isinstance(holder, dict):
        return
    with lock:
        holder["value"] = state


def _fetch_pm_update_snapshot(
    *,
    repo_path: str,
    provider: str | None,
    session_id: int | None,
    request_get_json=_get_orchestrator_json,
) -> object:
    sessions = request_get_json(
        "/v1/orchestrator-sessions",
        {"repo_path": repo_path, "limit": 8},
    )
    runs = request_get_json("/v1/runs", {"limit": 32})
    program = request_get_json(
        "/v1/program/status",
        {"query": "summary", "provider": provider, "limit": 0},
    )
    return build_pm_update_snapshot(
        repo_path=repo_path,
        sessions_payload=sessions,
        runs_payload=runs,
        program_payload=program,
        provider=provider,
        session_id=session_id,
    )


def _should_start_pm_update_mode(action) -> bool:
    return action.kind in {"create_ticket", "update_ticket", "dispatch_ticket"}


def _start_pm_update_mode(
    relay_command: dict,
    action,
    *,
    orchestrator_session: dict | None,
    messenger: MessengerRuntime | None = None,
    source_text: str | None = None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    notify_state=_notify_state,
    request_get_json=_get_orchestrator_json,
) -> threading.Thread | None:
    if not _should_start_pm_update_mode(action) or not orchestrator_session:
        return None
    repo_path = str(orchestrator_session.get("repo_path") or Path.cwd())
    provider = str(orchestrator_session.get("provider") or "").strip() or None
    session_id = orchestrator_session.get("session_id")
    try:
        command = RelayCommandMetadata.from_dict(relay_command, source_text=source_text)
    except ValueError:
        return None

    def emit(event: PMStatusEvent) -> None:
        payload = {
            "text": event.message,
            "status_event": event.to_dict(),
        }
        notify_state("working", **payload)
        if messenger is not None:
            messenger.submit_trace({
                "kind": "pm-update",
                "message": event.message,
                "source": event.source,
                "command": event.command.to_public_dict(),
                "ticket_id": event.ticket_id,
                "run_id": event.run_id,
            })

    def read_current_command() -> dict | None:
        return _read_json_file(state_path)

    mode = PMUpdateMode(
        command=command,
        status_reader=lambda: _fetch_pm_update_snapshot(
            repo_path=repo_path,
            provider=provider,
            session_id=session_id if isinstance(session_id, int) else None,
            request_get_json=request_get_json,
        ),
        current_command_reader=read_current_command,
        emit=emit,
        cadence_seconds=PM_UPDATE_CADENCE_SECONDS,
        startup_grace_seconds=PM_UPDATE_STARTUP_GRACE_SECONDS,
    )
    _set_orchestrator_session_state(orchestrator_session, "planning")

    def _run() -> None:
        poll_seconds = max(0.25, PM_UPDATE_POLL_SECONDS)
        while True:
            try:
                result = mode.poll()
            except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
                print(f"[voice_bridge] PM update mode status fetch failed: {e}", file=sys.stderr)
                _set_orchestrator_session_state(orchestrator_session, "blocked")
                return
            if result.stale:
                return
            _set_orchestrator_session_state(orchestrator_session, result.state)
            if not result.continue_running:
                if result.state == "idle":
                    _set_orchestrator_session_state(orchestrator_session, "idle")
                return
            time.sleep(poll_seconds)

    thread = threading.Thread(
        target=_run,
        name="pm-update-mode",
        daemon=True,
    )
    thread.start()
    return thread


def _pending_messenger_outcome_params(orchestrator_session: dict | None) -> dict[str, object]:
    repo_path = str((orchestrator_session or {}).get("repo_path") or Path.cwd())
    provider = str((orchestrator_session or {}).get("provider") or "").strip() or None
    return {
        "repo_path": repo_path,
        "provider": provider,
        "limit": MESSENGER_OUTCOME_FETCH_LIMIT,
    }


def _messenger_outcome_trace(outcomes: list[tuple[int, dict]]) -> dict:
    if len(outcomes) == 1:
        return outcomes[0][1]

    ticket_ids: list[str] = []
    for _, trace in outcomes:
        ticket_id = str(trace.get("ticket_id") or "").strip().upper()
        if ticket_id and ticket_id not in ticket_ids:
            ticket_ids.append(ticket_id)
    ticket_count = len(ticket_ids)
    ticket_summary = (
        f" across {ticket_count} {'ticket' if ticket_count == 1 else 'tickets'}"
        if ticket_count
        else ""
    )
    return {
        "kind": "run-health-warning",
        "message": (
            f"{len(outcomes)} Relay work updates accumulated while this session was away"
            f"{ticket_summary}. Open Workspace for current status."
        ),
        "source": "orchestrator",
        "ticket_ids": ticket_ids,
        "outcome_count": len(outcomes),
    }


def _deliver_pending_messenger_outcomes_once(
    *,
    orchestrator_session: dict | None,
    messenger: MessengerRuntime | None,
    request_get_json=_get_orchestrator_json,
    request_json=_post_orchestrator_json,
) -> int:
    if messenger is None:
        return 0
    try:
        response = request_get_json(
            "/v1/messenger/outcomes",
            _pending_messenger_outcome_params(orchestrator_session),
        )
    except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        print(f"[voice_bridge] pending messenger outcome fetch failed: {e}", file=sys.stderr)
        return 0
    outcomes = response.get("outcomes") if isinstance(response, dict) else None
    if not isinstance(outcomes, list):
        return 0

    pending: list[tuple[int, dict]] = []
    for outcome in outcomes:
        if not isinstance(outcome, dict):
            continue
        outcome_id = outcome.get("id")
        payload = outcome.get("payload")
        trace = payload.get("trace_event") if isinstance(payload, dict) else None
        if not isinstance(trace, dict):
            continue
        try:
            pending.append((int(outcome_id), trace))
        except (TypeError, ValueError):
            continue
    if not pending:
        return 0

    delivered = 0
    accepted = messenger.submit_trace(_messenger_outcome_trace(pending))
    for outcome_id, _ in pending:
        if accepted:
            try:
                request_json(f"/v1/messenger/outcomes/{outcome_id}/delivered", {})
                delivered += 1
            except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
                print(f"[voice_bridge] pending messenger outcome ack failed: {e}", file=sys.stderr)
        else:
            try:
                request_json(f"/v1/messenger/outcomes/{outcome_id}/attempt", {})
            except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError):
                pass
    return delivered


def _start_messenger_outcome_polling(
    *,
    orchestrator_session: dict | None,
    messenger: MessengerRuntime | None,
    shutdown_event: threading.Event,
    request_get_json=_get_orchestrator_json,
    request_json=_post_orchestrator_json,
) -> threading.Thread | None:
    if messenger is None or orchestrator_session is None:
        return None

    def _run() -> None:
        poll_seconds = max(0.25, MESSENGER_OUTCOME_POLL_SECONDS)
        while not shutdown_event.is_set():
            _deliver_pending_messenger_outcomes_once(
                orchestrator_session=orchestrator_session,
                messenger=messenger,
                request_get_json=request_get_json,
                request_json=request_json,
            )
            shutdown_event.wait(poll_seconds)

    thread = threading.Thread(
        target=_run,
        name="messenger-outcome-poll",
        daemon=True,
    )
    thread.start()
    return thread


def _acknowledgement_variant(seed: str, options: tuple[str, ...]) -> str:
    if not options:
        return VOICE_ACKNOWLEDGEMENT
    return options[sum(seed.encode("utf-8", errors="ignore")) % len(options)]


def _acknowledgement_intent(text: str | None) -> str | None:
    if not text:
        return None
    cleaned = re.sub(r"\s+", " ", text).strip()
    if not cleaned or cleaned.startswith("__"):
        return None
    if _SENSITIVE_ACK_RE.search(cleaned):
        return None
    for pattern, acknowledgement in _INTENT_ACKNOWLEDGEMENTS:
        if pattern.search(cleaned):
            return acknowledgement
    return None


def build_voice_acknowledgement(text: str | None, relay_command: dict | None = None) -> str:
    """Build concise provider-neutral acknowledgement copy for a user command."""
    seed = f"{text or ''}:{(relay_command or {}).get('relay_command_seq', '')}"
    intent = _acknowledgement_intent(text)
    if intent:
        return intent
    return _acknowledgement_variant(seed, _GENERIC_ACKNOWLEDGEMENTS)


def _pm_status_event_payload(
    *,
    phase: str,
    message: str,
    source: str,
    relay_command: dict,
    source_text: str | None = None,
    ticket_id: str | None = None,
    run_id: int | None = None,
) -> dict | None:
    """Build a public PM-frontstage status event from Relay metadata."""
    try:
        command = RelayCommandMetadata.from_dict(relay_command, source_text=source_text)
        return PMStatusEvent(
            phase=phase,
            message=message,
            source=source,
            command=command,
            ticket_id=ticket_id,
            run_id=run_id,
        ).to_dict()
    except ValueError as e:
        print(f"[voice_bridge] Could not build PM status event: {e}", file=sys.stderr)
        return None


def _coerce_optional_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _orchestration_trace_payload(
    *,
    kind: str,
    relay_command: dict | None = None,
    source_text: str | None = None,
    source: str = "orchestrator",
    message: str | None = None,
    ticket_id: str | None = None,
    run_id: int | None = None,
) -> dict | None:
    """Build a public orchestration trace payload for the notch stream."""
    try:
        command = None
        if relay_command:
            command = RelayCommandMetadata.from_dict(relay_command, source_text=source_text)
        event = OrchestrationTraceEvent(
            kind=kind,
            source=source,
            message=message,
            command=command,
            ticket_id=ticket_id,
            run_id=run_id,
        )
    except ValueError as e:
        print(f"[voice_bridge] Could not build orchestration trace: {e}", file=sys.stderr)
        return None

    payload = {
        "text": event.message,
        "trace_event": event.to_dict(),
    }
    status_event = event.to_status_event_dict()
    if status_event is not None:
        payload["status_event"] = status_event
    return payload


def emit_orchestration_trace(
    *,
    kind: str,
    relay_command: dict | None = None,
    source_text: str | None = None,
    source: str = "orchestrator",
    message: str | None = None,
    ticket_id: str | None = None,
    run_id: int | None = None,
    messenger: MessengerRuntime | None = None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    notify_state=_notify_state,
) -> bool:
    """Emit a short public orchestration trace to the notch if still current."""
    if relay_command:
        command_seq = relay_command.get("relay_command_seq")
        command_id = relay_command.get("relay_command_id")
        if command_seq is not None or command_id:
            if not _relay_command_current(command_seq, command_id, state_path=state_path):
                print(
                    "[voice_bridge] Dropping orchestration trace because its Relay command was superseded.",
                    file=sys.stderr,
                )
                return False

    payload = _orchestration_trace_payload(
        kind=kind,
        relay_command=relay_command,
        source_text=source_text,
        source=source,
        message=message,
        ticket_id=ticket_id,
        run_id=run_id,
    )
    if payload is None:
        return False
    notify_state("working", **payload)
    if messenger is not None:
        messenger.submit_trace(payload["trace_event"])
    return True


def _handle_orchestration_trace_control(
    raw: str,
    *,
    messenger: MessengerRuntime | None = None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    notify_state=_notify_state,
) -> bool:
    text = raw.strip()
    if not text:
        return True
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        data = {"kind": "board-change", "message": text}
    if not isinstance(data, dict):
        return True

    relay_command = data.get("relay_command")
    if not isinstance(relay_command, dict):
        relay_command = _read_json_file(VOICE_COMMAND_CLAIM_FILE)
    if not relay_command:
        relay_command = None

    return emit_orchestration_trace(
        kind=str(data.get("kind") or "board-change"),
        relay_command=relay_command,
        source=str(data.get("source") or "orchestrator"),
        message=data.get("message"),
        ticket_id=data.get("ticket_id"),
        run_id=_coerce_optional_int(data.get("run_id")),
        messenger=messenger,
        state_path=state_path,
        notify_state=notify_state,
    )


def acknowledgement_auto_dismiss_seconds(text: str) -> float:
    return max(
        VOICE_ACKNOWLEDGEMENT_AUTO_DISMISS_SECONDS,
        min(5.0, 2.4 + len(text.strip()) * 0.025),
    )


def _command_event_limit() -> int:
    try:
        return max(1, int(os.environ.get("VOICE_COMMAND_EVENT_LIMIT", VOICE_COMMAND_EVENT_LIMIT)))
    except (TypeError, ValueError):
        return VOICE_COMMAND_EVENT_LIMIT


def _record_private_command_capture(
    metadata: dict,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    limit: int | None = None,
) -> None:
    """Append a bounded private command event outside visible board files."""
    if not event_log_path:
        return
    limit = max(1, int(limit or _command_event_limit()))
    event = {
        "relay_command_seq": metadata.get("relay_command_seq"),
        "relay_command_id": metadata.get("relay_command_id"),
        "received_at": metadata.get("received_at"),
        "source_text": metadata.get("source_text"),
        "action": metadata.get("action", "received"),
        "state": metadata.get("state", "received"),
    }
    for name in (
        "outcome",
        "repo_path",
        "ticket_id",
        "intent_id",
        "within_turn_order",
        "target",
        "disposition",
        "cancellation_scope",
        "lifecycle_state",
    ):
        if metadata.get(name):
            event[name] = metadata[name]
    if metadata.get("provider"):
        event["provider"] = metadata["provider"]
    try:
        existing: list[str] = []
        if os.path.exists(event_log_path):
            with open(event_log_path) as f:
                existing = [line.rstrip("\n") for line in f if line.strip()]
        existing = existing[-(limit - 1):] if limit > 1 else []
        tmp = event_log_path + ".tmp"
        parent = os.path.dirname(event_log_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
            os.chmod(parent, 0o700)
        with open(tmp, "w") as f:
            for line in existing:
                f.write(line + "\n")
            f.write(json.dumps(event, sort_keys=True) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, event_log_path)
    except (OSError, TypeError, ValueError) as e:
        print(f"[voice_bridge] Could not record private command event: {e}", file=sys.stderr)


def _begin_relay_command(
    source_text: str,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
) -> dict:
    """Record a new newest-intent generation as soon as voice input arrives."""
    with _VOICE_STATE_LOCK:
        previous = _read_json_file(state_path)
        try:
            seq = int(previous.get("relay_command_seq") or 0) + 1
        except (TypeError, ValueError):
            seq = 1
        metadata = {
            "relay_command_seq": seq,
            "relay_command_id": f"{os.getpid()}-{time.time_ns()}-{seq}",
            "source_text": source_text,
            "received_at": time.time(),
            "action": "received",
            "recovery_generation": normalize_recovery_generation(
                os.environ.get("RELAY_RECOVERY_GENERATION") or str(seq)
            ),
        }
        provider = os.environ.get("RELAY_RUNNER_PROVIDER", "").strip()
        if provider:
            metadata["provider"] = provider
        _atomic_write_json(state_path, metadata)
    _record_private_command_capture(metadata, event_log_path=event_log_path)
    _post_continuity_event("bridge", "command_received", metadata)
    return metadata


def _metadata_for_action(
    action,
    relay_command: dict,
    disposition: IntentDisposition | None = None,
    work_item: VoiceWorkItem | None = None,
) -> dict:
    metadata = dict(relay_command)
    fallback_relationship = command_relationship(
        getattr(action, "kind", None),
        reason=getattr(action, "reason", None),
        source_text=getattr(action, "source_text", None),
    )
    relationship = (
        authorization_relationship_for(disposition, fallback=fallback_relationship)
        if disposition is not None
        else fallback_relationship
    )
    metadata.update({
        "action": action.kind,
        "outcome": action.outcome,
        "requires_ticket": action.requires_ticket,
        "authorization_relationship": relationship,
    })
    if disposition is not None:
        metadata["intent_id"] = disposition.intent_id
        metadata["work_disposition"] = disposition.to_dict()
        metadata["preempt_provider"] = (
            disposition.route == IntentRoute.REPLACE_CURRENT
            and disposition.cancellation_scope == CancellationScope.ALL_WORK
        )
    if work_item is not None:
        cancellation_scope = work_item.cancellation_scope
        target_intent_ids = work_item.target_intent_ids
        if (
            disposition is not None
            and disposition.cancellation_scope != CancellationScope.NONE
        ):
            cancellation_scope = disposition.cancellation_scope
            target_intent_ids = disposition.target_work_ids
        voice_work_item = work_item.to_dict()
        voice_work_item.update({
            "cancellation_scope": cancellation_scope.value,
            "target_intent_ids": list(target_intent_ids),
        })
        metadata.update({
            "intent_id": work_item.intent_id,
            "within_turn_order": work_item.within_turn_order,
            "target": work_item.target,
            "disposition": work_item.disposition,
            "cancellation_scope": cancellation_scope.value,
            "lifecycle_state": work_item.lifecycle_state,
            "target_intent_ids": list(target_intent_ids),
            "voice_work_item": voice_work_item,
        })
        if (
            disposition is not None
            and disposition.route == IntentRoute.REPLACE_CURRENT
            and disposition.cancellation_scope in {
                CancellationScope.ITEM,
                CancellationScope.TICKET,
            }
        ):
            metadata["provider_preempt_intent_ids"] = list(target_intent_ids)
    if action.ticket_id:
        metadata["ticket_id"] = action.ticket_id
    if action.ticket_path:
        metadata["ticket_path"] = action.ticket_path
    if action.repo_path:
        metadata["repo_path"] = action.repo_path
    if action.reason:
        metadata["reason"] = action.reason
    return metadata


def _record_command_action_state(
    metadata: dict,
    state: str,
    *,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
) -> None:
    event = dict(metadata)
    event["state"] = state
    _record_private_command_capture(event, event_log_path=event_log_path)


def _active_work(
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    repo_path: str | Path | None = None,
) -> tuple[ActiveWork, ...]:
    data = _read_json_file(turns_path)
    records = data.get("records") if isinstance(data, dict) else None
    if not isinstance(records, list):
        return ()
    active: list[ActiveWork] = []
    for record in records:
        if not isinstance(record, dict) or str(record.get("state") or "") != "active":
            continue
        key = _relay_command_key(record)
        if key is None:
            continue
        resources = record.get("resource_claims")
        if not isinstance(resources, list):
            resources = ["repository"] if repo_path else []
        active.append(
            ActiveWork(
                work_id=str(record.get("intent_id") or f"{key[0]}:{key[1]}"),
                resources=tuple(str(resource) for resource in resources),
                target=str(record.get("target") or "") or None,
            )
        )
    return tuple(active)


def _resolve_voice_work_items(
    source_text: str,
    relay_command: dict,
    *,
    repo_path: str | Path,
    active_work: tuple[ActiveWork, ...] = (),
) -> list[dict]:
    """Normalize one real turn into provider-neutral ordered item deliveries."""
    items = normalize_voice_work_items(
        source_text,
        relay_command_seq=int(relay_command["relay_command_seq"]),
        relay_command_id=str(relay_command["relay_command_id"]),
    )
    resolved: list[dict] = []
    known_work = list(active_work)
    for item in items:
        item_command = {
            **relay_command,
            "source_text": item.source_text,
            "intent_id": item.intent_id,
            "within_turn_order": item.within_turn_order,
            "voice_work_item": item.to_dict(),
        }
        action = resolve_command_action(
            item.source_text,
            repo_path=repo_path,
            relay_command=item_command,
        )
        disposition = resolve_intent_disposition(
            intent_id=item.intent_id,
            action_kind=action.kind,
            action_reason=getattr(action, "reason", None),
            source_text=item.source_text,
            active_work=tuple(known_work),
            cancellation_scope=item.cancellation_scope,
            target_work_ids=item.target_intent_ids,
        )
        metadata = _metadata_for_action(action, item_command, disposition, item)
        prompt = format_command_for_agent(action, disposition.to_dict())
        resolved.append({
            "item": item,
            "action": action,
            "disposition": disposition,
            "metadata": metadata,
            "prompt": prompt,
        })
        if (
            item.lifecycle_state != "cancelled"
            and item.disposition == "accepted"
            and action.kind != "control"
        ):
            known_work.append(ActiveWork(
                item.intent_id,
                tuple(getattr(disposition, "resource_claims", ())),
                item.target,
            ))
    return resolved


_PRIVATE_CONTEXT_LINE_RE = re.compile(
    r"\b(raw\s+transcript|source_text|hidden\s+reasoning|tool\s+log|shell\s+output|scratchpad|prompt)\b"
    r"|(`|\$\(|&&|\|\||\s;\s|"
    r"\b(?:bash|cat|curl|git|grep|npm|pnpm|python|python3|sh|swift|xcodebuild|yarn|zsh)\s+)",
    re.IGNORECASE,
)


def _sanitized_command_context(relay_command: dict) -> str | None:
    value = (
        relay_command.get("context")
        or relay_command.get("refined_context")
        or relay_command.get("conversation_context")
    )
    if value is None:
        return None
    lines: list[str] = []
    for raw in str(value).splitlines():
        line = re.sub(r"\s+", " ", raw).strip()
        if not line or _PRIVATE_CONTEXT_LINE_RE.search(line):
            continue
        lines.append(line)
        if len(lines) >= 18:
            break
    sanitized = "\n".join(lines).strip()
    return sanitized[:2400].rstrip() if sanitized else None


def _raw_instruction_payload(
    source_text: str,
    relay_command: dict,
    action,
    *,
    repo_path: str | Path | None = None,
    orchestrator_session: dict | None = None,
) -> dict:
    metadata = _metadata_for_action(action, relay_command)
    session_repo = (orchestrator_session or {}).get("repo_path")
    session_id = (orchestrator_session or {}).get("session_id")
    repo = str(Path(repo_path or session_repo or Path.cwd()).expanduser().resolve())
    payload = {
        "repo_path": repo,
        "source_text": source_text,
        "relay_command_seq": metadata.get("relay_command_seq"),
        "relay_command_id": metadata.get("relay_command_id"),
        "provider": metadata.get("provider"),
        "recovery_generation": metadata.get("recovery_generation"),
        "received_at": metadata.get("received_at"),
        "action": metadata.get("action"),
        "outcome": metadata.get("outcome"),
        "status": "queued",
        "defer_processing": True,
    }
    for name in (
        "intent_id",
        "within_turn_order",
        "target",
        "disposition",
        "cancellation_scope",
        "lifecycle_state",
    ):
        if metadata.get(name) is not None:
            payload[name] = metadata[name]
    context = _sanitized_command_context(relay_command)
    if context:
        payload["context"] = context
    if session_id is not None:
        payload["session_id"] = session_id
    return payload


def _deliver_raw_instruction_to_orchestrator(
    source_text: str,
    relay_command: dict,
    action,
    *,
    repo_path: str | Path | None = None,
    orchestrator_session: dict | None = None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    request_json=_post_orchestrator_json,
) -> bool:
    command_seq = relay_command.get("relay_command_seq")
    command_id = relay_command.get("relay_command_id")
    if not _relay_command_current(command_seq, command_id, state_path=state_path):
        _record_command_action_state(
            relay_command,
            "superseded",
            event_log_path=event_log_path,
        )
        print(
            "[voice_bridge] Dropping raw orchestrator command because its Relay command was superseded.",
            file=sys.stderr,
        )
        return False
    payload = _raw_instruction_payload(
        source_text,
        relay_command,
        action,
        repo_path=repo_path,
        orchestrator_session=orchestrator_session,
    )
    try:
        request_json("/v1/orchestrator-session/command", payload)
    except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        failed = dict(relay_command)
        failed["action"] = getattr(action, "kind", None)
        failed["outcome"] = "delivery failed"
        _record_command_action_state(
            failed,
            "delivery_failed",
            event_log_path=event_log_path,
        )
        _post_continuity_event(
            "bridge",
            "delivery_failed",
            {**relay_command, "session_id": (orchestrator_session or {}).get("session_id")},
        )
        print(f"[voice_bridge] Could not fan out raw command to orchestrator: {e}", file=sys.stderr)
        return False
    _post_continuity_event(
        "bridge",
        "command_delivered",
        {**relay_command, "session_id": (orchestrator_session or {}).get("session_id")},
    )
    return True


def _fanout_raw_instruction_to_orchestrator(
    source_text: str,
    relay_command: dict,
    action,
    *,
    repo_path: str | Path | None = None,
    orchestrator_session: dict | None = None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    request_json=_post_orchestrator_json,
) -> threading.Thread:
    thread = threading.Thread(
        target=_deliver_raw_instruction_to_orchestrator,
        kwargs={
            "source_text": source_text,
            "relay_command": relay_command,
            "action": action,
            "repo_path": repo_path,
            "orchestrator_session": orchestrator_session,
            "state_path": state_path,
            "event_log_path": event_log_path,
            "request_json": request_json,
        },
        name="orchestrator-raw-command-fanout",
        daemon=True,
    )
    thread.start()
    return thread


def _should_fanout_raw_instruction_to_orchestrator(action) -> bool:
    """Durably queue project work without bypassing the foreground PM."""
    return getattr(action, "kind", None) in {
        "create_ticket",
        "update_ticket",
        "dispatch_ticket",
    }


def _discard_pending_command(
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
) -> None:
    """Undo file-backed effects for an unclaimed command being superseded."""
    if not os.path.exists(command_path):
        return
    metadata = _read_json_file(meta_path)
    if metadata.get("action") == "create_ticket":
        ticket_path = metadata.get("ticket_path")
        if ticket_path:
            try:
                os.unlink(str(ticket_path))
                print(
                    f"[voice_bridge] Removed stale unclaimed ticket {ticket_path}.",
                    file=sys.stderr,
                )
            except FileNotFoundError:
                pass
            except OSError as e:
                print(
                    f"[voice_bridge] Could not remove stale ticket {ticket_path}: {e}",
                    file=sys.stderr,
                )
    try:
        os.unlink(command_path)
    except OSError:
        pass
    try:
        os.unlink(meta_path)
    except OSError:
        pass


def _publish_command(
    text: str,
    metadata: dict,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    authorization_path: str | None = None,
    inbox: IntentInbox | None = None,
    transport: str = "shared-ready-file",
) -> None:
    """Publish through the durable inbox, retaining ready files as transport."""
    if inbox is None:
        _discard_pending_command(command_path=command_path, meta_path=meta_path)
    published_metadata = dict(metadata)
    published_metadata["agent_prompt"] = text
    if not published_metadata.get("authorization_relationship"):
        published_metadata["authorization_relationship"] = command_relationship(
            published_metadata.get("action"),
            reason=published_metadata.get("reason"),
            source_text=published_metadata.get("source_text"),
        )
    disposition = published_metadata.get("work_disposition")
    route = str(disposition.get("route") or "") if isinstance(disposition, dict) else ""
    if inbox is not None and route == IntentRoute.REPLACE_CURRENT.value:
        if not published_metadata.get("cancellation_scope") and not (
            isinstance(disposition, dict) and disposition.get("cancellation_scope")
        ):
            # Durable records created before item scoping used replace_current
            # only for whole-turn replacement. Preserve that recovery meaning.
            published_metadata["cancellation_scope"] = CancellationScope.ALL_WORK.value
        cancelled_ids = inbox.cancel_scoped(
            published_metadata,
            command_path=command_path,
            metadata_path=meta_path,
        )
        if cancelled_ids:
            published_metadata["target_intent_ids"] = cancelled_ids
            item = published_metadata.get("voice_work_item")
            if isinstance(item, dict):
                item = dict(item)
                item["target_intent_ids"] = cancelled_ids
                published_metadata["voice_work_item"] = item
            if isinstance(disposition, dict):
                disposition = dict(disposition)
                disposition["target_work_ids"] = cancelled_ids
                disposition["conflicting_work_ids"] = cancelled_ids
                published_metadata["work_disposition"] = disposition
            if published_metadata.get("cancellation_scope") in {"item", "ticket"}:
                published_metadata["provider_preempt_intent_ids"] = cancelled_ids
    with _VOICE_STATE_LOCK:
        _atomic_write_json(state_path, published_metadata)
    if authorization_path:
        try:
            record_command_authorization(
                authorization_path,
                published_metadata,
                relationship=str(published_metadata.get("authorization_relationship") or ""),
                allowed_mutations=(
                    []
                    if published_metadata.get("lifecycle_state") == "cancelled"
                    else allowed_mutations_for_metadata(published_metadata)
                ),
            )
        except (OSError, TypeError, ValueError) as e:
            print(f"[voice_bridge] Could not record Relay mutation authorization: {e}", file=sys.stderr)
    if inbox is None:
        _atomic_write_json(meta_path, published_metadata)
        _write_cmd_file(text, path=command_path)
        return

    stored_metadata = inbox.enqueue(text, published_metadata, route or "continue_current")
    with _VOICE_STATE_LOCK:
        _atomic_write_json(state_path, stored_metadata)
        sync_deliverable_state(state_path, inbox)
    inbox.materialize_next(
        command_path=command_path,
        metadata_path=meta_path,
        transport=transport,
    )
    with _VOICE_STATE_LOCK:
        sync_deliverable_state(state_path, inbox)


def _relay_command_current(
    relay_command_seq: int | str | None,
    relay_command_id: str | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> bool:
    if relay_command_seq is None or not relay_command_id:
        return False
    with _VOICE_STATE_LOCK:
        current = _read_json_file(state_path)
    try:
        current_seq = int(current.get("relay_command_seq"))
        expected_seq = int(relay_command_seq)
    except (TypeError, ValueError):
        return False
    return (
        current_seq == expected_seq
        and str(current.get("relay_command_id") or "") == str(relay_command_id)
    )


def _relay_command_key(command: dict | None) -> tuple[int, str] | None:
    if not isinstance(command, dict):
        return None
    command_id = str(command.get("relay_command_id") or "").strip()
    if not command_id:
        return None
    try:
        command_seq = int(command.get("relay_command_seq"))
    except (TypeError, ValueError):
        return None
    return command_seq, command_id


def _relay_intent_matches(left: dict | None, right: dict | None) -> bool:
    if _relay_command_key(left) != _relay_command_key(right):
        return False
    left_intent = str((left or {}).get("intent_id") or "").strip()
    right_intent = str((right or {}).get("intent_id") or "").strip()
    if left_intent or right_intent:
        return bool(left_intent) and left_intent == right_intent
    return True


def _provider_turn_state(
    relay_command: dict | None,
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    provider_session_id: str = PROVIDER_SESSION_ID,
) -> str | None:
    key = _relay_command_key(relay_command)
    if key is None:
        return None
    data = _read_json_file(turns_path)
    records = data.get("records") if isinstance(data, dict) else None
    if not isinstance(records, list):
        return None
    for record in reversed(records):
        if (
            isinstance(record, dict)
            and (
                not provider_session_id
                or str(record.get("provider_session_id") or "") == provider_session_id
            )
            and _relay_intent_matches(record, relay_command)
        ):
            state = str(record.get("state") or "").strip()
            return state or None
    return None


def _provider_turn_active(
    relay_command: dict | None,
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    provider_session_id: str = PROVIDER_SESSION_ID,
) -> bool:
    return _provider_turn_state(
        relay_command,
        turns_path=turns_path,
        provider_session_id=provider_session_id,
    ) == "active"


def _any_provider_turn_active(
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    provider_session_id: str = PROVIDER_SESSION_ID,
) -> bool:
    data = _read_json_file(turns_path)
    records = data.get("records") if isinstance(data, dict) else None
    if not isinstance(records, list):
        return False
    return any(
        isinstance(record, dict)
        and str(record.get("state") or "").strip() == "active"
        and (
            not provider_session_id
            or str(record.get("provider_session_id") or "") == provider_session_id
        )
        for record in records
    )


def _provider_record_key(record: dict) -> str:
    session_id = str(record.get("session_id") or "unknown")
    turn_id = str(record.get("turn_id") or "").strip()
    if turn_id:
        return f"{session_id}:{turn_id}"
    local_turn_seq = record.get("local_turn_seq")
    if local_turn_seq is not None:
        return f"{session_id}:local:{local_turn_seq}"
    return session_id


def _source_turn_reply_arbitration(
    relay_command: dict,
    *,
    state_path: str,
    turns_path: str,
    command_path: str,
    meta_path: str,
    provider_session_id: str = PROVIDER_SESSION_ID,
) -> dict:
    """Decide a missing-final once from every intent in the current source turn."""
    key = _relay_command_key(relay_command)
    if key is None:
        return {"decision": "cancel", "reason": "missing_source_identity", "siblings": []}

    with _VOICE_STATE_LOCK:
        state = _read_json_file(state_path)
    cancelled = {
        str(value)
        for value in state.get("cancelled_intent_ids", [])
        if str(value)
    } if isinstance(state.get("cancelled_intent_ids"), list) else set()

    inbox_items: dict[str, dict] = {}
    candidates = []
    for name in ("deliverable_commands", "source_command_intents"):
        values = state.get(name)
        if isinstance(values, list):
            candidates.extend(value for value in values if isinstance(value, dict))
    if os.path.exists(command_path):
        ready = _read_json_file(meta_path)
        if ready:
            candidates.append({**ready, "state": str(ready.get("state") or "delivered")})
    for item in candidates:
        if _relay_command_key(item) != key:
            continue
        intent_id = str(item.get("intent_id") or "").strip()
        try:
            order = int(item.get("within_turn_order") or 0)
        except (TypeError, ValueError):
            order = 0
        identity = intent_id or f"order:{order}"
        inbox_items[identity] = {
            "intent_id": intent_id or None,
            "within_turn_order": order or None,
            "state": str(item.get("state") or "recognized").strip() or "recognized",
        }

    turn_data = _read_json_file(turns_path)
    raw_records = turn_data.get("records") if isinstance(turn_data, dict) else None
    source_records = [
        record
        for record in (raw_records if isinstance(raw_records, list) else [])
        if (
            isinstance(record, dict)
            and _relay_command_key(record) == key
            and (
                not provider_session_id
                or str(record.get("provider_session_id") or "") == provider_session_id
            )
            and str(record.get("intent_id") or "") not in cancelled
        )
    ]
    scoped_records = [
        record
        for record in (raw_records if isinstance(raw_records, list) else [])
        if (
            isinstance(record, dict)
            and (
                not provider_session_id
                or str(record.get("provider_session_id") or "") == provider_session_id
            )
        )
    ]

    record_states: dict[str, list[str]] = {}
    for record in source_records:
        intent_id = str(record.get("intent_id") or "").strip()
        try:
            order = int(record.get("within_turn_order") or 0)
        except (TypeError, ValueError):
            order = 0
        identity = intent_id or f"order:{order}"
        state_name = str(record.get("state") or "unknown").strip() or "unknown"
        record_states.setdefault(identity, []).append(state_name)
        inbox_items.setdefault(identity, {
            "intent_id": intent_id or None,
            "within_turn_order": order or None,
            "state": None,
        })

    siblings = []
    for identity, item in sorted(
        inbox_items.items(),
        key=lambda entry: (entry[1].get("within_turn_order") or 0, entry[0]),
    ):
        sibling = dict(item)
        sibling["provider_states"] = sorted(set(record_states.get(identity, [])))
        siblings.append(sibling)

    result = {
        "decision": "eligible",
        "reason": "all_siblings_terminal_empty",
        "siblings": siblings,
        "provider_session_id": provider_session_id or None,
    }
    noncancelled_items = [
        item for item in inbox_items.values()
        if not item.get("intent_id") or item["intent_id"] not in cancelled
    ]
    if inbox_items and not noncancelled_items:
        return {**result, "decision": "cancel", "reason": "source_cancelled"}
    pending_states = {"recognized", "pending", "delivered", "claimed", "queued", "leased"}
    if any(item.get("state") in pending_states for item in noncancelled_items):
        return {**result, "decision": "defer", "reason": "sibling_pending"}
    if any(str(record.get("state") or "") == "active" for record in scoped_records):
        return {**result, "decision": "defer", "reason": "provider_turn_active"}

    records_by_key = {_provider_record_key(record): record for record in scoped_records}
    ignored_orphans: set[int] = set()
    superseded_intent_ids: set[str] = set()
    for index, record in enumerate(source_records):
        if str(record.get("state") or "") != "orphaned":
            continue
        disposition = str(record.get("provider_ownership_disposition") or "").strip()
        if disposition == "source_superseded":
            return {**result, "decision": "cancel", "reason": "source_superseded"}
        if disposition == "sibling_superseded":
            ignored_orphans.add(index)
            intent_id = str(record.get("intent_id") or "").strip()
            if intent_id:
                superseded_intent_ids.add(intent_id)
            continue
        if disposition == "continued":
            successor = records_by_key.get(str(record.get("successor_record_key") or ""))
            if successor is None:
                return {**result, "decision": "defer", "reason": "ownership_continuation_missing"}
            ignored_orphans.add(index)
            continue
        return {**result, "decision": "defer", "reason": "orphaned_ownership_ambiguous"}

    relevant_records = [
        record for index, record in enumerate(source_records) if index not in ignored_orphans
    ]
    if any(str(record.get("state") or "") == "completed_final" for record in relevant_records):
        return {**result, "decision": "cancel", "reason": "provider_final_observed"}
    if any(str(record.get("state") or "") == "stale" for record in relevant_records):
        return {**result, "decision": "cancel", "reason": "source_stale"}

    terminal_states = {"empty", "failed", "terminated", "cancelled", "abandoned"}
    for item in noncancelled_items:
        intent_id = str(item.get("intent_id") or "").strip()
        if intent_id in superseded_intent_ids:
            continue
        matching = [
            record for record in relevant_records
            if str(record.get("intent_id") or "").strip() == intent_id
        ]
        if not matching and len(noncancelled_items) == 1:
            matching = [record for record in relevant_records if not record.get("intent_id")]
        if item.get("state") == "acked" and not matching:
            return {**result, "decision": "defer", "reason": "awaiting_correlated_terminal"}
        if any(str(record.get("state") or "") not in terminal_states for record in matching):
            return {**result, "decision": "defer", "reason": "sibling_not_terminal"}
    if any(str(record.get("state") or "") not in terminal_states for record in relevant_records):
        return {**result, "decision": "defer", "reason": "source_not_terminal"}
    return result


def _command_pending_delivery(
    relay_command: dict | None,
    *,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
) -> bool:
    key = _relay_command_key(relay_command)
    if key is None or not os.path.exists(command_path):
        return False
    metadata = _read_json_file(meta_path)
    return _relay_intent_matches(metadata, relay_command)


def _provider_turn_seen(
    command: dict | None,
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    provider_session_id: str = PROVIDER_SESSION_ID,
) -> bool:
    return _provider_turn_state(
        command,
        turns_path=turns_path,
        provider_session_id=provider_session_id,
    ) is not None


def _manual_claim_ack_matches(
    claimed: dict | None,
    acknowledged: dict | None,
) -> bool:
    """Accept only the exact durable claim written by a manual provider loop."""
    if _relay_command_key(claimed) != _relay_command_key(acknowledged):
        return False
    for field in (
        "intent_id",
        "intent_delivery_id",
        "intent_claim_id",
        "intent_ack_id",
    ):
        claimed_value = str((claimed or {}).get(field) or "").strip()
        acknowledged_value = str((acknowledged or {}).get(field) or "").strip()
        if not claimed_value or claimed_value != acknowledged_value:
            return False
    return True


def _start_intent_inbox_pump(
    inbox: IntentInbox,
    shutdown_event: threading.Event,
    *,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    claimed_path: str = VOICE_COMMAND_CLAIM_FILE,
    manual_ack_path: str = VOICE_MANUAL_CLAIM_ACK_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    transport: str = "shared-ready-file",
    poll_seconds: float = 0.05,
) -> threading.Thread:
    """Bridge app-owned and manual consumers onto one ordered inbox protocol."""

    # Bridge startup removes the ephemeral state file while the inbox survives.
    # Restore its newest-command identity before a recovered lease can reach a
    # provider or a new turn can allocate a reset sequence.
    with _VOICE_STATE_LOCK:
        sync_deliverable_state(state_path, inbox)

    def _run() -> None:
        while not shutdown_event.is_set():
            claimed = _read_json_file(claimed_path)
            if claimed:
                inbox.observe_claim(
                    claimed,
                    provider_turn_seen=_provider_turn_seen(claimed, turns_path=turns_path),
                )
            manual_ack = _read_json_file(manual_ack_path)
            if _manual_claim_ack_matches(claimed, manual_ack):
                if inbox.observe_claim(manual_ack, provider_turn_seen=True):
                    try:
                        os.unlink(manual_ack_path)
                    except OSError:
                        pass
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=meta_path,
                transport=transport,
            )
            try:
                with _VOICE_STATE_LOCK:
                    sync_deliverable_state(state_path, inbox)
            except OSError as exc:
                print(f"[voice_bridge] Could not sync intent inbox state: {exc}", file=sys.stderr)
            shutdown_event.wait(max(0.01, poll_seconds))

    thread = threading.Thread(target=_run, name="intent-inbox-pump", daemon=True)
    thread.start()
    return thread


def _sync_intent_inbox_state(
    inbox: IntentInbox,
    *,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> None:
    try:
        with _VOICE_STATE_LOCK:
            sync_deliverable_state(state_path, inbox)
    except OSError as exc:
        print(f"[voice_bridge] Could not sync intent inbox state: {exc}", file=sys.stderr)


def _enqueue_sidecar_intent(
    *,
    prompt: str,
    source_text: str,
    metadata: dict,
    sidecar_lane: SidecarLane,
    inbox: IntentInbox | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> bool:
    """Route an eligible sidecar without occupying the foreground provider mailbox."""
    stored = dict(metadata)
    stored["agent_prompt"] = prompt
    if inbox is not None:
        stored = inbox.enqueue(
            prompt,
            stored,
            IntentRoute.RUN_SIDECAR.value,
        )
    with _VOICE_STATE_LOCK:
        _atomic_write_json(state_path, stored)
        if inbox is not None:
            sync_deliverable_state(state_path, inbox)
    return sidecar_lane.submit(source_text, stored)


def _handle_sidecar_lifecycle(
    event: SidecarLifecycleEvent,
    *,
    inbox: IntentInbox | None,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> bool:
    """Feed sidecar state back through the foreground speech/freshness boundary."""
    if inbox is not None:
        inbox.observe_claim(
            event.command,
            provider_turn_seen=event.phase in {"completed", "failed"},
        )
        _sync_intent_inbox_state(inbox, state_path=state_path)
    if messenger is None:
        return False
    return messenger.submit_trace({
        "kind": f"sidecar-{event.phase}",
        "message": (
            f"Sidecar state={event.phase}; "
            f"{event.public_summary}"
        ),
        "command": event.command,
        "work_disposition": event.command.get("work_disposition"),
    })


def _handle_sidecar_final(
    text: str,
    command: dict,
    *,
    tts_worker: TTSWorker,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> bool:
    """Return an accepted sidecar outcome as durable work lifecycle speech."""
    reply = str(text or "").strip()
    key = _relay_command_key(command)
    if not reply or key is None:
        return False
    if _foreground_reply_delivered(command):
        return True
    disposition = command.get("work_disposition")
    if not isinstance(disposition, dict):
        disposition = None
    if _arm_authoritative_playback(tts_worker, key[0], key[1]):
        _publish_authoritative_preview(reply)
    delivered = False
    if messenger is not None:
        delivered = messenger.submit_trace({
            "kind": "sidecar-outcome",
            "message": reply,
            "command": command,
            "work_disposition": disposition,
            "work_valid": True,
        })
    if not delivered:
        delivered = _queue_tts_text(
            json.dumps({
                "text": reply,
                "display_text": reply,
                "relay_command_seq": key[0],
                "relay_command_id": key[1],
            }),
            tts_worker.input_queue,
            state_path=state_path,
            allow_pending_command=True,
            notify_waiting_preview=lambda _text: None,
            source="lifecycle",
            kind="final",
            authoritative=True,
            semantic_brief=reply,
            dedup_key=f"work-outcome:{key[0]}:{key[1]}:sidecar-outcome",
            work_disposition=disposition,
            replayable=True,
            freshness_scope="work",
        )
    if delivered:
        _mark_foreground_reply_delivered(command)
    return delivered


def _foreground_reply_delivered(command: dict | None) -> bool:
    key = _relay_command_key(command)
    if key is None:
        return False
    with _FOREGROUND_REPLY_LOCK:
        return key in _FOREGROUND_REPLIED_COMMANDS or key in _FOREGROUND_REPLY_IN_FLIGHT


def _reserve_foreground_reply_delivery(command: dict | None) -> bool:
    key = _relay_command_key(command)
    if key is None:
        return False
    with _FOREGROUND_REPLY_LOCK:
        if key in _FOREGROUND_REPLIED_COMMANDS or key in _FOREGROUND_REPLY_IN_FLIGHT:
            return False
        _FOREGROUND_REPLY_IN_FLIGHT.add(key)
        return True


def _finish_foreground_reply_delivery(command: dict | None, *, delivered: bool) -> None:
    key = _relay_command_key(command)
    if key is None:
        return
    with _FOREGROUND_REPLY_LOCK:
        _FOREGROUND_REPLY_IN_FLIGHT.discard(key)
        if delivered:
            _FOREGROUND_REPLIED_COMMANDS.add(key)
            if len(_FOREGROUND_REPLIED_COMMANDS) > 100:
                for old in list(_FOREGROUND_REPLIED_COMMANDS)[:50]:
                    _FOREGROUND_REPLIED_COMMANDS.discard(old)


def _mark_foreground_reply_delivered(command: dict | None) -> None:
    key = _relay_command_key(command)
    if key is None:
        return
    with _FOREGROUND_REPLY_LOCK:
        _FOREGROUND_REPLIED_COMMANDS.add(key)
        if len(_FOREGROUND_REPLIED_COMMANDS) > 100:
            for old in list(_FOREGROUND_REPLIED_COMMANDS)[:50]:
                _FOREGROUND_REPLIED_COMMANDS.discard(old)


def _reset_foreground_reply_delivery_for_tests() -> None:
    with _FOREGROUND_REPLY_LOCK:
        _FOREGROUND_REPLIED_COMMANDS.clear()
        _FOREGROUND_REPLY_IN_FLIGHT.clear()


def _parse_args() -> dict:
    """Parse CLI args for direct and relay bridge modes."""
    args = sys.argv[1:]
    result: dict = {}
    for i, arg in enumerate(args):
        if arg == "--session" and i + 1 < len(args):
            result["session"] = args[i + 1]
        elif arg == "--relay":
            result["relay"] = True
        elif arg == "--suppress-startup-greeting":
            result["suppress_startup_greeting"] = True
    return result


def _bridge_continuity_recovery_response(
    payload: dict,
    *,
    messenger: MessengerRuntime | None,
    orchestrator_session: dict | None,
    applied_keys: set[str],
    cooldowns: dict[str, float],
    recovery_lock: threading.Lock,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    request_json=_post_orchestrator_json,
    monotonic=time.monotonic,
    epoch=time.time,
) -> dict[str, str]:
    """Revalidate and execute only bridge-owned recovery capabilities."""
    try:
        context = RecoveryExecutionContext.from_mapping(payload)
    except (TypeError, ValueError):
        return {"status": "failed", "outcome_code": "invalid_recovery_context"}
    request = context.request
    validation = context.validation
    policy = CAPABILITY_POLICIES[request.capability]
    if recovery_owner_for(request.capability, request.component) != "bridge":
        return {"status": "failed", "outcome_code": "unsupported_component_action"}
    if (
        validation.validation_token != "live_continuity_watch"
        or not validation.exact_target_owned
        or not validation.incident_active
        or not validation.generation_matches
        or not validation.command_phase_matches
        or validation.liveness not in policy.required_liveness
        or validation.command_phase not in policy.command_phases
        or validation.idempotency_state != "new"
        or validation.cooldown_remaining != 0
        or request.attempt > policy.max_attempts
        or monotonic() >= request.deadline
        or request.incident_observed_at > epoch() + 5
        or epoch() - request.incident_observed_at > 300
    ):
        return {"status": "failed", "outcome_code": "stale_recovery_context"}
    session_key = str((orchestrator_session or {}).get("session_key") or "")
    if not session_key or opaque_identifier("session", session_key) != request.session_id:
        return {"status": "failed", "outcome_code": "unrelated_session_target"}
    provider = str((orchestrator_session or {}).get("provider") or "none")
    if request.provider not in {"none", provider}:
        return {"status": "failed", "outcome_code": "provider_target_mismatch"}
    command_state = _read_json_file(state_path)
    try:
        current_generation = normalize_recovery_generation(
            (command_state or {}).get("recovery_generation")
        )
    except ValueError:
        return {"status": "failed", "outcome_code": "stale_recovery_generation"}
    if request.recovery_generation != current_generation:
        return {"status": "failed", "outcome_code": "stale_recovery_generation"}
    if request.command_id is not None:
        native_command_id = str((command_state or {}).get("relay_command_id") or "")
        if not native_command_id or opaque_identifier("command", native_command_id) != request.command_id:
            return {"status": "failed", "outcome_code": "unrelated_command_target"}
    if _active_work(turns_path=turns_path):
        return {"status": "failed", "outcome_code": "live_work_active"}

    with recovery_lock:
        if request.idempotency_key in applied_keys:
            return {"status": "noop", "outcome_code": "action_already_applied"}
        cooldown_key = f"{request.capability}:{request.component}:{request.session_id}"
        if monotonic() < cooldowns.get(cooldown_key, 0):
            return {"status": "failed", "outcome_code": "component_cooldown_active"}

        applied = False
        outcome_code = "component_action_failed"
        if request.capability in {"restart_messenger", "reconnect_ipc"} and request.component == "messenger":
            applied = messenger is not None and messenger.recover_backend()
            outcome_code = "messenger_process_restart_requested"
        elif request.capability in {"restore_session_registration", "reconnect_ipc"}:
            session_id = (orchestrator_session or {}).get("session_id")
            if session_id is not None:
                try:
                    response = request_json(
                        "/v1/orchestrator-session/heartbeat",
                        {
                            "session_id": int(session_id),
                            "repo_path": (orchestrator_session or {}).get("repo_path"),
                            "provider": provider,
                            "state": "idle",
                        },
                    )
                    applied = isinstance(response.get("orchestrator_session"), dict)
                except (OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError, ValueError):
                    applied = False
            outcome_code = "session_registration_restored"
        elif request.capability == "release_dead_ownership" and request.component == "session":
            thread = (orchestrator_session or {}).get("thread")
            if thread is None or not getattr(thread, "is_alive", lambda: True)():
                try:
                    response = request_json(
                        "/v1/orchestrator-session/stop",
                        {
                            "session_id": int((orchestrator_session or {})["session_id"]),
                            "reason": "continuity confirmed dead owner",
                        },
                    )
                    applied = isinstance(response.get("orchestrator_session"), dict)
                except (KeyError, OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError, ValueError):
                    applied = False
            else:
                return {"status": "failed", "outcome_code": "live_work_active"}
            outcome_code = "dead_ownership_released"
        if not applied:
            return {"status": "failed", "outcome_code": "component_action_failed"}
        applied_keys.add(request.idempotency_key)
        cooldowns[cooldown_key] = monotonic() + policy.cooldown_seconds
        return {"status": "applied", "outcome_code": outcome_code}


def _start_control_socket(
    tts_worker: TTSWorker,
    shutdown_event: threading.Event,
    recovery_context: dict | None = None,
):
    """Listen on Unix socket for reload/shutdown commands from Tauri or relay-bridge."""
    try:
        os.unlink(BRIDGE_CONTROL_SOCK)
    except OSError:
        pass

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(BRIDGE_CONTROL_SOCK)
    sock.settimeout(0.5)

    try:
        while not shutdown_event.is_set():
            try:
                data, _ = sock.recvfrom(4096)
                cmd = data.decode("utf-8", errors="replace").strip()
                cmd_lower = cmd.lower()
                recovery_payload = None
                if cmd.startswith("{"):
                    try:
                        candidate = json.loads(cmd)
                    except json.JSONDecodeError:
                        candidate = None
                    if isinstance(candidate, dict) and candidate.get("type") == "continuity_recovery":
                        recovery_payload = candidate
                if recovery_payload is not None:
                    context = recovery_context or {}
                    response = _bridge_continuity_recovery_response(
                        recovery_payload,
                        messenger=context.get("messenger"),
                        orchestrator_session=context.get("orchestrator_session"),
                        applied_keys=context.setdefault("applied_keys", set()),
                        cooldowns=context.setdefault("cooldowns", {}),
                        recovery_lock=context.setdefault("lock", threading.Lock()),
                    )
                    reply_path = recovery_payload.get("reply_path")
                    if (
                        isinstance(reply_path, str)
                        and re.fullmatch(
                            r"/tmp/relay_recovery_recovery_[0-9a-f]{24}\.json",
                            reply_path,
                        )
                    ):
                        temporary_reply = Path(f"{reply_path}.{os.getpid()}.tmp")
                        try:
                            temporary_reply.write_text(json.dumps(response))
                            os.replace(temporary_reply, reply_path)
                        except OSError:
                            temporary_reply.unlink(missing_ok=True)
                elif cmd_lower == "reload":
                    print("[voice_bridge] Reloading config...", file=sys.stderr)
                    tts_worker.reload_config()
                elif cmd_lower == "shutdown":
                    print("[voice_bridge] Shutdown requested.", file=sys.stderr)
                    shutdown_event.set()
                elif cmd_lower == "ping":
                    pass  # Liveness probe — socket exists = alive
            except socket.timeout:
                continue
    finally:
        sock.close()
        try:
            os.unlink(BRIDGE_CONTROL_SOCK)
        except OSError:
            pass


# Strip markdown formatting before TTS so Kokoro doesn't pronounce literal
# *, _, ` as "asterisk", "underscore", "backtick". The skill prompt asks
# Claude to send plain prose, but it routinely returns **bold**, `code`, and
# blockquotes anyway — handle it server-side so the voice always sounds clean.
_MD_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_MD_LINE_PREFIX_RE = re.compile(r"^\s*(?:>+|#+|[-+*]|\d+\.)\s+")


def _strip_markdown_for_tts(text: str) -> str:
    """Strip markdown so Kokoro doesn't pronounce */_/` aloud."""
    text = _MD_LINK_RE.sub(r"\1", text)        # [label](url) → label
    text = _MD_LINE_PREFIX_RE.sub("", text)    # leading >, #, -, *, 1. → drop
    return re.sub(r"[*_`]", "", text)          # any remaining markers


def _parse_tts_payload(raw: str) -> tuple[str, str | None, int | None, str | None]:
    """Accept plain text or JSON lines tagged with Relay command metadata.

    JSON payloads use ``text`` for the spoken rendering and ``display_text`` for
    the authoritative response preview shown in the pill.
    """
    text = raw.strip()
    if not text:
        return "", None, None, None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return text, None, None, None
    if not isinstance(payload, dict) or "text" not in payload:
        return text, None, None, None
    command_seq = payload.get("relay_command_seq")
    try:
        command_seq = int(command_seq) if command_seq is not None else None
    except (TypeError, ValueError):
        command_seq = None
    command_id = payload.get("relay_command_id")
    display_text = payload.get("display_text")
    return (
        str(payload.get("text") or ""),
        str(display_text) if display_text is not None else None,
        command_seq,
        str(command_id) if command_id else None,
    )


def _normalize_display_preview(text: str | None) -> str:
    words = str(text or "").replace("\n", " ").split()
    return " ".join(words)


def _publish_authoritative_preview(text: str) -> None:
    preview = _normalize_display_preview(text)
    if not preview:
        return
    try:
        publish_waiting_preview(preview)
    except Exception as exc:
        print(f"[voice_bridge] Could not publish authoritative preview: {exc}", file=sys.stderr)


def _arm_authoritative_playback(
    speech_gateway,
    command_seq: int,
    command_id: str,
) -> bool:
    arm = getattr(speech_gateway, "arm_waiting_playback", None)
    if arm is None:
        return True
    try:
        arm(command_seq, command_id, kind="final")
        return True
    except Exception as exc:
        print(f"[voice_bridge] Could not arm waiting playback: {exc}", file=sys.stderr)
        return False


def _queue_tts_text(
    text: str,
    tts_queue: queue.Queue,
    command_path: str = VOICE_CMD_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    allow_pending_command: bool = False,
    notify_waiting_preview=None,
    source: str = "fallback",
    kind: str = "fallback",
    authoritative: bool = False,
    semantic_brief: str | None = None,
    priority: int | None = None,
    dedup_key: str | None = None,
    work_disposition: dict | None = None,
    replayable: bool | None = None,
    freshness_scope: str = "conversation",
    lifecycle_role: str | None = None,
    covered_facts: list[str] | tuple[str, ...] | None = None,
    realization_decision: str = "full",
    suppression_reason: str | None = None,
) -> bool:
    """Submit a typed speech intent unless its Relay command is stale."""
    text, display_text, command_seq, command_id = _parse_tts_payload(text)
    display_preview = _normalize_display_preview(display_text)
    text = _strip_markdown_for_tts(text.strip()).strip()
    if not text and display_preview:
        text = _strip_markdown_for_tts(display_preview).strip()
    if not text:
        return False
    work_fresh = (
        freshness_scope == "work"
        and source == "lifecycle"
        and kind == "final"
    )
    if (command_seq is not None or command_id) and not work_fresh:
        if not _relay_command_current(command_seq, command_id, state_path=state_path):
            print(
                "[voice_bridge] Dropping TTS because its Relay command was superseded.",
                file=sys.stderr,
            )
            return False
    if not allow_pending_command and os.path.exists(command_path):
        print(
            "[voice_bridge] Dropping TTS because a newer voice command is pending.",
            file=sys.stderr,
        )
        return False
    coordinated = hasattr(tts_queue, "submit_text")
    publisher = publish_waiting_preview if notify_waiting_preview is None else notify_waiting_preview
    if coordinated:
        accepted = bool(tts_queue.submit_text(
            text,
            display_text=display_preview,
            semantic_brief=semantic_brief,
            command_seq=command_seq,
            command_id=command_id,
            source=source,
            kind=kind,
            authoritative=authoritative,
            priority=priority,
            dedup_key=dedup_key,
            work_disposition=work_disposition,
            replayable=replayable,
            freshness_scope="work" if work_fresh else "conversation",
            lifecycle_role=lifecycle_role,
            covered_facts=covered_facts,
            realization_decision=realization_decision,
            suppression_reason=suppression_reason,
        ))
    else:
        if display_preview:
            tts_queue.put({"text": text, "display_text": display_preview})
        else:
            tts_queue.put(text)
        accepted = True
    if not accepted:
        return False
    if publisher is not None:
        try:
            publisher(display_preview or text)
        except Exception as exc:
            print(f"[voice_bridge] Could not publish waiting preview: {exc}", file=sys.stderr)
    return True


def _queue_voice_acknowledgement(
    relay_command: dict,
    tts_queue: queue.Queue,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    source_text: str | None = None,
    delay_seconds: float = VOICE_ACKNOWLEDGEMENT_DELAY_SECONDS,
    notify_state=_notify_state,
    discard_pending_command: bool = True,
) -> bool:
    """Schedule a short acknowledgement for the newest command."""
    del tts_queue
    text = build_voice_acknowledgement(source_text, relay_command).strip()
    if not text:
        return False
    if discard_pending_command:
        _discard_pending_command(command_path=command_path, meta_path=meta_path)
    command_seq = relay_command.get("relay_command_seq")
    command_id = relay_command.get("relay_command_id")
    auto_dismiss = acknowledgement_auto_dismiss_seconds(text)
    status_event = _pm_status_event_payload(
        phase="acknowledged",
        message=text,
        source="pm",
        relay_command=relay_command,
        source_text=source_text,
    )

    def _notify_if_current():
        if delay_seconds > 0:
            time.sleep(delay_seconds)
        if not _relay_command_current(command_seq, command_id, state_path=state_path):
            print(
                "[voice_bridge] Dropping acknowledgement because its Relay command was superseded.",
                file=sys.stderr,
            )
            return
        payload = {
            "text": text,
            "auto_dismiss_seconds": auto_dismiss,
        }
        if status_event is not None:
            payload["status_event"] = status_event
        notify_state("acknowledgement", **payload)

    if delay_seconds > 0:
        threading.Thread(target=_notify_if_current, daemon=True).start()
    else:
        _notify_if_current()
    return True


def _log_quarantined_relay_control(
    *,
    envelope: str,
    control_type: str,
    shape: str,
    syntax: str,
    reason: str,
) -> None:
    """Emit only fixed, bounded metadata for rejected Relay control shapes."""
    label = _RELAY_CONTROL_TYPE_LABELS.get(control_type, "unknown")
    print(
        "[voice_bridge] quarantined_relay_control "
        f"envelope={envelope} control_type={label} shape={shape} "
        f"syntax={syntax} reason={reason}",
        file=sys.stderr,
    )


def _find_control_shaped_type(value: object) -> tuple[str, str] | None:
    """Find a bounded top-level or nested `type: __CONTROL__` marker."""
    pending: list[tuple[object, int]] = [(value, 0)]
    visited = 0
    while pending and visited < 64:
        current, depth = pending.pop()
        visited += 1
        if not isinstance(current, dict):
            continue
        raw_type = current.get("type")
        if isinstance(raw_type, str) and _RELAY_CONTROL_TYPE_RE.fullmatch(raw_type):
            return raw_type, "top_level" if depth == 0 else "nested"
        if depth >= 4:
            continue
        for child in current.values():
            if isinstance(child, dict):
                pending.append((child, depth + 1))
            elif isinstance(child, list):
                pending.extend(
                    (item, depth + 1)
                    for item in child[:16]
                    if isinstance(item, dict)
                )
    return None


def _quarantine_raw_relay_control_object(text: str) -> bool:
    """Reject noncanonical JSON control shapes before they become user intent."""
    source = str(text or "").strip()
    if not source.startswith("{"):
        return False
    try:
        decoded = json.loads(source)
    except (json.JSONDecodeError, RecursionError):
        match = _RAW_RELAY_CONTROL_TYPE_RE.search(source)
        if match is None:
            return False
        control_type = match.group("type")
        shape = "unverified"
        syntax = "malformed"
    else:
        if not isinstance(decoded, dict):
            return False
        found = _find_control_shaped_type(decoded)
        if found is None:
            match = _RAW_RELAY_CONTROL_TYPE_RE.search(source)
            if match is None:
                return False
            control_type = match.group("type")
            shape = "nested"
        else:
            control_type, shape = found
        syntax = "valid"
    _log_quarantined_relay_control(
        envelope="raw_json",
        control_type=control_type,
        shape=shape,
        syntax=syntax,
        reason="noncanonical_envelope",
    )
    return True


def _play_control_detected_at(text: str) -> float | None:
    if text == "__PLAY__":
        return None
    prefix = "__PLAY__:"
    if not text.startswith(prefix):
        return None
    try:
        detected_at = float(text[len(prefix):])
    except ValueError:
        return None
    return detected_at if detected_at > 0 else None


def _play_ack_timestamps(text: str) -> tuple[float, float] | None:
    prefix = "__PLAY_ACK__:"
    if not text.startswith(prefix):
        return None
    parts = text[len(prefix):].split(":", 1)
    if len(parts) != 2:
        return None
    try:
        detected_at, acknowledged_at = (float(value) for value in parts)
    except ValueError:
        return None
    if detected_at <= 0 or acknowledged_at <= 0:
        return None
    return detected_at, acknowledged_at


def _play_or_replay(
    tts_worker: TTSWorker,
    *,
    option_detected_at: float | None = None,
) -> bool:
    received_at = time.time()
    note_control = getattr(tts_worker, "note_play_control", None)
    if callable(note_control):
        note_control(
            option_detected_at=option_detected_at,
            fifo_received_at=received_at,
        )
    handler = getattr(tts_worker, "play_or_replay", None)
    if callable(handler):
        return bool(handler())
    tts_worker.play()
    return True


def _handle_relay_control_message(
    text: str,
    tts_worker: TTSWorker,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    authorization_path: str | None = None,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    messenger: MessengerRuntime | None = None,
    inbox: IntentInbox | None = None,
    provider_turn_broker: ProviderTurnBroker | None = None,
) -> bool:
    """Handle provider-neutral relay controls before command publication."""
    if text == "__TTS_STOP__":
        # Recording barge-in stops audio without resurfacing it as replay history.
        tts_worker.stop_playback(reason="recording_barge_in")
        return True

    if text == "__INTERRUPT__":
        tts_worker.stop_playback(reason="interrupt")
        if messenger is not None:
            messenger.interrupt()
        relay_command = _begin_relay_command(
            text,
            state_path=state_path,
            event_log_path=event_log_path,
        )
        disposition = resolve_intent_disposition(
            intent_id=str(relay_command["relay_command_id"]),
            action_kind="control",
            action_reason="interrupt",
            source_text=text,
            active_work=_active_work(turns_path=VOICE_PROVIDER_TURNS_FILE),
        )
        _publish_command(
            "__INTERRUPT__",
            {
                **relay_command,
                "action": "control",
                "outcome": "control action interrupt",
                "reason": "interrupt",
                "authorization_relationship": "interrupt",
                "intent_id": disposition.intent_id,
                "work_disposition": disposition.to_dict(),
                "preempt_provider": True,
            },
            command_path=command_path,
            meta_path=meta_path,
            state_path=state_path,
            authorization_path=authorization_path,
            inbox=inbox,
        )
        return True

    if text == "__CANCEL__":
        # Double-tap Control is also used to dismiss acknowledgement/TTS UI.
        # In relay mode Codex and Claude share this bridge path, so dismissal
        # must not advance newest-intent metadata for either provider.
        tts_worker.skip()
        return True

    if text == "__PLAY__" or text.startswith("__PLAY__:"):
        _play_or_replay(
            tts_worker,
            option_detected_at=_play_control_detected_at(text),
        )
        return True

    if text.startswith("__PLAY_ACK__:"):
        timestamps = _play_ack_timestamps(text)
        note_ack = getattr(tts_worker, "note_visual_acknowledgement", None)
        if timestamps is not None and callable(note_ack):
            note_ack(
                option_detected_at=timestamps[0],
                acknowledged_at=timestamps[1],
            )
        return True

    if text == "__REPLAY__":
        tts_worker.replay()
        return True

    if text.startswith("__TRACE__:"):
        _handle_orchestration_trace_control(
            text[len("__TRACE__:"):],
            messenger=messenger,
            state_path=state_path,
        )
        return True

    if text.startswith("__ORCHESTRATOR_REPLY__:"):
        _handle_orchestrator_reply_control(
            text[len("__ORCHESTRATOR_REPLY__:"):],
            tts_worker=tts_worker,
            messenger=messenger,
            state_path=state_path,
            provider_turn_broker=provider_turn_broker,
        )
        return True

    if text.startswith("__RELAY_COMPLETION__:"):
        _handle_provider_completion_control(
            text[len("__RELAY_COMPLETION__:"):],
            tts_worker=tts_worker,
            messenger=messenger,
            state_path=state_path,
            provider_turn_broker=provider_turn_broker,
        )
        return True

    if text.startswith("__PROVIDER_TURN_EVENT__:"):
        _handle_provider_turn_event_control(
            text[len("__PROVIDER_TURN_EVENT__:"):],
            provider_turn_broker=provider_turn_broker,
        )
        return True

    if text.startswith("__STATUS__:"):
        _observe_stt_status(text[len("__STATUS__:"):])
        return True

    if text.startswith("__CONTINUITY__:"):
        _observe_stt_continuity_signal(text[len("__CONTINUITY__:"):])
        return True

    if _quarantine_raw_relay_control_object(text):
        return True

    reserved_control = re.match(
        r"^(?P<type>__[A-Z][A-Z0-9_]*__)(?P<separator>:|\s+|$)",
        text,
    )
    if reserved_control is not None:
        separator = reserved_control.group("separator")
        _log_quarantined_relay_control(
            envelope="prefixed",
            control_type=reserved_control.group("type"),
            shape="top_level",
            syntax="unknown" if separator == ":" else "malformed",
            reason=(
                "unknown_control_type"
                if separator == ":"
                else "noncanonical_separator"
            ),
        )
        return True

    return False


def _missing_foreground_reply_text_for_kind(kind: str | None) -> str:
    if kind in {"create_ticket", "update_ticket", "dispatch_ticket"}:
        return (
            "I handled that Relay voice turn, but the provider did not send a spoken final reply. "
            "Check the terminal for the current details; worker updates will still be announced."
        )
    return (
        "I handled that Relay voice turn, but the provider did not send a spoken final reply. "
        "Check the terminal for the full result."
    )


def _missing_foreground_reply_text(action) -> str:
    return _missing_foreground_reply_text_for_kind(getattr(action, "kind", None))


def _deliver_missing_foreground_reply(
    *,
    relay_command: dict,
    action_kind: str | None = None,
    tts_worker: TTSWorker,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    provider_turn_broker: ProviderTurnBroker | None = None,
) -> bool | None:
    key = _relay_command_key(relay_command)
    if key is None:
        return False
    if _foreground_reply_delivered(relay_command):
        return None
    if not _relay_command_current(key[0], key[1], state_path=state_path):
        return False
    effect_id = None
    if provider_turn_broker is not None:
        reservation = provider_turn_broker.reserve_effect(relay_command)
        if not reservation.accepted:
            if reservation.reason == "duplicate":
                return None
            if reservation.reason == "turn_revoked":
                _finish_foreground_reply_delivery(relay_command, delivered=False)
                return False
            if PROVIDER_TURN_BROKER_MODE != "dual_write":
                return False
        else:
            effect_id = reservation.effect_id
    if not _reserve_foreground_reply_delivery(relay_command):
        if effect_id is not None:
            provider_turn_broker.finish_effect(effect_id, delivered=False)
        return None
    payload = {
        "text": _missing_foreground_reply_text_for_kind(action_kind),
        "relay_command_seq": key[0],
        "relay_command_id": key[1],
        "speech_source": "fallback",
    }
    if effect_id is not None and not provider_turn_broker.authorize_effect_delivery(effect_id):
        _finish_foreground_reply_delivery(relay_command, delivered=False)
        return False
    if _arm_authoritative_playback(tts_worker, key[0], key[1]):
        _publish_authoritative_preview(payload["text"])
    delivered = False
    if messenger is not None:
        delivered = messenger.submit_final(payload)
    if not delivered:
        delivered = _queue_tts_text(
            json.dumps({**payload, "display_text": payload["text"]}),
            tts_worker.input_queue,
            state_path=state_path,
            allow_pending_command=True,
            notify_waiting_preview=lambda _text: None,
            source="fallback",
            kind="fallback",
            authoritative=True,
            semantic_brief=payload["text"],
            replayable=True,
        )
    if delivered:
        _finish_foreground_reply_delivery(relay_command, delivered=True)
    else:
        _finish_foreground_reply_delivery(relay_command, delivered=False)
    if effect_id is not None:
        provider_turn_broker.finish_effect(effect_id, delivered=delivered)
    return delivered


def _log_foreground_reply_fallback_event(
    event: str,
    *,
    relay_command: dict,
    turns_path: str,
    reason: str | None = None,
    arbitration: dict | None = None,
) -> None:
    key = _relay_command_key(relay_command)
    fields = [f"event={event}"]
    if key is not None:
        fields.append(f"relay_command_seq={key[0]}")
        fields.append(f"relay_command_id={key[1]}")
    intent_id = str(relay_command.get("intent_id") or "").strip()
    if intent_id:
        fields.append(f"intent_id={intent_id}")
    if relay_command.get("within_turn_order") is not None:
        fields.append(f"within_turn_order={relay_command['within_turn_order']}")
    state = _provider_turn_state(relay_command, turns_path=turns_path) or "none"
    fields.append(f"provider_turn_state={state}")
    provider = str(relay_command.get("provider") or "").strip()
    if provider:
        fields.append(f"provider={provider}")
    if arbitration:
        decision = str(arbitration.get("decision") or "").strip()
        if decision:
            fields.append(f"decision={decision}")
        provider_session_id = str(arbitration.get("provider_session_id") or "").strip()
        if provider_session_id:
            fields.append(f"provider_session_id={provider_session_id}")
        siblings = arbitration.get("siblings")
        if isinstance(siblings, list):
            fields.append(
                "aggregate_sibling_states="
                + json.dumps(siblings, sort_keys=True, separators=(",", ":"))
            )
    if reason:
        fields.append(f"reason={reason}")
    print("[voice_bridge] foreground_reply_fallback " + " ".join(fields), file=sys.stderr)


def _schedule_foreground_reply_fallback(
    *,
    relay_command: dict,
    action=None,
    action_kind: str | None = None,
    tts_worker: TTSWorker,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    delay_seconds: float | None = None,
    provider_turn_broker: ProviderTurnBroker | None = None,
) -> threading.Thread | None:
    key = _relay_command_key(relay_command)
    if key is None:
        return None
    delay = FOREGROUND_REPLY_FALLBACK_SECONDS if delay_seconds is None else delay_seconds
    if delay < 0:
        return None
    if action_kind is None:
        action_kind = getattr(action, "kind", None)
    _log_foreground_reply_fallback_event(
        "armed",
        relay_command=relay_command,
        turns_path=turns_path,
    )

    def _run() -> None:
        sleep_for = delay
        while True:
            if sleep_for > 0:
                time.sleep(sleep_for)
            if _foreground_reply_delivered(relay_command):
                _log_foreground_reply_fallback_event(
                    "cancelled",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason="reply_delivered",
                )
                return
            if not _relay_command_current(key[0], key[1], state_path=state_path):
                _log_foreground_reply_fallback_event(
                    "cancelled",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason="superseded",
                )
                return
            arbitration = _source_turn_reply_arbitration(
                relay_command,
                state_path=state_path,
                turns_path=turns_path,
                command_path=command_path,
                meta_path=meta_path,
            )
            decision = arbitration["decision"]
            reason = str(arbitration.get("reason") or "source_not_terminal")
            if decision == "defer":
                _log_foreground_reply_fallback_event(
                    "deferred",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason=reason,
                    arbitration=arbitration,
                )
                sleep_for = max(0.25, PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS)
                continue
            if decision == "cancel":
                _log_foreground_reply_fallback_event(
                    "cancelled",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason=reason,
                    arbitration=arbitration,
                )
                return
            _log_foreground_reply_fallback_event(
                "eligible",
                relay_command=relay_command,
                turns_path=turns_path,
                reason=reason,
                arbitration=arbitration,
            )
            delivered = _deliver_missing_foreground_reply(
                relay_command=relay_command,
                action_kind=action_kind,
                tts_worker=tts_worker,
                messenger=messenger,
                state_path=state_path,
                provider_turn_broker=provider_turn_broker,
            )
            if delivered is None:
                _log_foreground_reply_fallback_event(
                    "cancelled",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason="source_reply_deduplicated",
                    arbitration=arbitration,
                )
                return
            _log_foreground_reply_fallback_event(
                "emitted" if delivered else "delivery_failed",
                relay_command=relay_command,
                turns_path=turns_path,
            )
            return

    thread = threading.Thread(
        target=_run,
        name="foreground-reply-fallback",
        daemon=True,
    )
    thread.start()
    return thread


def _handle_provider_completion_control(
    raw: str,
    *,
    tts_worker: TTSWorker,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    fallback_delay_seconds: float | None = None,
    provider_turn_broker: ProviderTurnBroker | None = None,
) -> bool:
    """Route provider Stop hook completion through the authoritative reply path."""
    text = raw.strip()
    if not text:
        return False
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return False
    if not isinstance(data, dict):
        return False

    command = data.get("relay_command")
    if not isinstance(command, dict):
        command = data
    key = _relay_command_key(command)
    if key is None:
        return False
    provider = str(
        data.get("provider")
        or command.get("provider")
        or os.environ.get("RELAY_RUNNER_PROVIDER")
        or "codex"
    ).strip().lower()
    failed = str(data.get("event") or "") == "StopFailure"
    terminal_signal = (
        "result_error" if failed else "result_success"
    ) if "claude" in provider else (
        "turn_failed" if failed else "turn_completed"
    )
    _post_continuity_event(
        "provider",
        terminal_signal,
        {**data, **command, "provider": provider},
    )
    if _foreground_reply_delivered(command):
        return True
    if not _relay_command_current(key[0], key[1], state_path=state_path):
        print(
            "[voice_bridge] Dropping provider completion because its Relay command was superseded.",
            file=sys.stderr,
        )
        return False

    reply = str(data.get("text") or data.get("last_assistant_message") or "").strip()
    if reply:
        payload = {
            "text": reply,
            "relay_command_seq": key[0],
            "relay_command_id": key[1],
            "speech_source": "completion",
        }
        for field in (
            "intent_id",
            "app_session_id",
            "recovery_generation",
            "actor_role",
            "foreground_gate_handle",
        ):
            if data.get(field) is not None:
                payload[field] = data[field]
        return _handle_orchestrator_reply_control(
            json.dumps(payload),
            tts_worker=tts_worker,
            messenger=messenger,
            state_path=state_path,
            provider_turn_broker=provider_turn_broker,
        )

    thread = _schedule_foreground_reply_fallback(
        relay_command=command,
        tts_worker=tts_worker,
        messenger=messenger,
        state_path=state_path,
        turns_path=turns_path,
        command_path=command_path,
        meta_path=meta_path,
        action_kind=str(data.get("action") or ""),
        delay_seconds=fallback_delay_seconds,
        provider_turn_broker=provider_turn_broker,
    )
    return thread is not None


def _handle_orchestrator_reply_control(
    raw: str,
    *,
    tts_worker: TTSWorker,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    provider_turn_broker: ProviderTurnBroker | None = None,
) -> bool:
    """Route the foreground agent's authoritative reply through the messenger."""
    text = raw.strip()
    if not text:
        return False
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        _log_quarantined_relay_control(
            envelope="prefixed",
            control_type="__ORCHESTRATOR_REPLY__",
            shape="top_level",
            syntax="malformed",
            reason="invalid_payload",
        )
        return False
    if not isinstance(data, dict):
        _log_quarantined_relay_control(
            envelope="prefixed",
            control_type="__ORCHESTRATOR_REPLY__",
            shape="top_level",
            syntax="valid",
            reason="invalid_payload",
        )
        return False
    reply = str(data.get("text") or "").strip()
    if not reply:
        return False

    nested = data.get("relay_command")
    command = nested if isinstance(nested, dict) else data
    command_key = _relay_command_key(command)
    if command_key is None:
        _log_quarantined_relay_control(
            envelope="prefixed",
            control_type="__ORCHESTRATOR_REPLY__",
            shape="top_level",
            syntax="valid",
            reason="missing_command_key",
        )
        return False
    if _foreground_reply_delivered(command):
        return True
    if not _relay_command_current(command_key[0], command_key[1], state_path=state_path):
        print(
            "[voice_bridge] Dropping foreground reply because its Relay command was superseded.",
            file=sys.stderr,
        )
        return False
    effect_id = None
    if provider_turn_broker is not None:
        reservation = provider_turn_broker.reserve_effect(command)
        if not reservation.accepted:
            if reservation.reason == "duplicate":
                return True
            if reservation.reason == "turn_revoked":
                _finish_foreground_reply_delivery(command, delivered=False)
                return False
            if PROVIDER_TURN_BROKER_MODE != "dual_write":
                return False
        else:
            effect_id = reservation.effect_id
    if not _reserve_foreground_reply_delivery(command):
        if effect_id is not None:
            provider_turn_broker.finish_effect(effect_id, delivered=False)
        return True
    payload = {"text": reply}
    if data.get("speech_source"):
        payload["speech_source"] = str(data["speech_source"])
    if isinstance(data.get("work_disposition"), dict):
        payload["work_disposition"] = data["work_disposition"]
    for key in ("relay_command_seq", "relay_command_id"):
        if key in command:
            payload[key] = command[key]

    if effect_id is not None and not provider_turn_broker.authorize_effect_delivery(effect_id):
        _finish_foreground_reply_delivery(command, delivered=False)
        return False
    if _arm_authoritative_playback(tts_worker, command_key[0], command_key[1]):
        _publish_authoritative_preview(reply)
    if messenger is not None and messenger.submit_final(payload):
        _finish_foreground_reply_delivery(command, delivered=True)
        if effect_id is not None:
            provider_turn_broker.finish_effect(effect_id, delivered=True)
        return True

    # A missing or out-of-sync messenger must not swallow a current outcome.
    # _queue_tts_text still rejects stale command metadata.
    delivered = _queue_tts_text(
        json.dumps({**payload, "display_text": reply}),
        tts_worker.input_queue,
        state_path=state_path,
        allow_pending_command=True,
        notify_waiting_preview=lambda _text: None,
        source=(
            "lifecycle"
            if payload.get("speech_source") == "lifecycle"
            else "fallback"
        ),
        kind=(
            "final"
            if payload.get("speech_source") == "lifecycle"
            else "fallback"
        ),
        authoritative=True,
        semantic_brief=reply,
        work_disposition=payload.get("work_disposition"),
        replayable=True,
    )
    if delivered:
        _finish_foreground_reply_delivery(command, delivered=True)
    else:
        _finish_foreground_reply_delivery(command, delivered=False)
    if effect_id is not None:
        provider_turn_broker.finish_effect(effect_id, delivered=delivered)
    return delivered


def _handle_provider_turn_event_control(
    raw: str,
    *,
    provider_turn_broker: ProviderTurnBroker | None,
) -> bool:
    try:
        payload = json.loads(raw.strip())
    except (json.JSONDecodeError, TypeError):
        return False
    if not isinstance(payload, dict):
        return False
    event = str(payload.get("event") or "")
    provider = str(
        payload.get("provider")
        or os.environ.get("RELAY_RUNNER_PROVIDER")
        or "codex"
    ).strip().lower()
    if event in {"provider_started", "provider_progress"}:
        if event == "provider_progress":
            signal = "stream_progress" if "claude" in provider else "turn_progress"
        else:
            signal = "stream_started" if "claude" in provider else "turn_started"
        _post_continuity_event(
            "provider",
            signal,
            {**payload, "provider": provider},
            observed_at=payload.get("observed_at"),
        )
        return True
    if event != "provider_terminated":
        return False
    if provider_turn_broker is None:
        return PROVIDER_TURN_BROKER_MODE == "legacy"
    release_reason = str(payload.get("release_reason") or "")
    if release_reason not in {
        "app_teardown",
        "provider_process_terminated",
        "provider_process_exit",
    }:
        return False
    event_id = str(payload.get("event_id") or "").strip()
    provider_session_id = str(payload.get("provider_session_id") or "").strip()
    provider_turn_broker.terminate_owner(
        payload,
        provider_session_id=provider_session_id,
        release_reason=release_reason,
        event_id=event_id,
    )
    _post_continuity_event(
        "provider",
        "process_exit",
        {
            "app_session_id": payload.get("app_session_id"),
            "recovery_generation": payload.get("recovery_generation"),
            "provider": provider,
        },
    )
    return True


def _tts_fifo_reader(tts_queue: queue.Queue, shutdown_event: threading.Event):
    """Read text from TTS input FIFO and put on TTS queue (relay mode only)."""
    while not shutdown_event.is_set():
        try:
            with open(TTS_IN_FIFO, "r") as f:
                for line in f:
                    if shutdown_event.is_set():
                        break
                    _queue_tts_text(line, tts_queue)
        except OSError:
            if not shutdown_event.is_set():
                import time
                time.sleep(0.2)


def _run_relay(
    tts_worker: TTSWorker,
    shutdown_event: threading.Event,
    *,
    orchestrator_session: dict | None = None,
    messenger: MessengerRuntime | None = None,
    suppress_startup_greeting: bool = False,
    inbox: IntentInbox | None = None,
    provider_turn_broker: ProviderTurnBroker | None = None,
    sidecar_lane: SidecarLane | None = None,
    on_ready=None,
):
    """Relay mode: write voice commands for the active agent and read TTS from FIFO."""
    suppress_next_messenger_user_reply = suppress_startup_greeting

    # Create TTS input FIFO
    for path in [
        TTS_IN_FIFO,
        VOICE_CMD_FILE,
        VOICE_CMD_META_FILE,
        VOICE_COMMAND_STATE_FILE,
        VOICE_COMMAND_CLAIM_FILE,
        VOICE_MANUAL_CLAIM_ACK_FILE,
        VOICE_COMMAND_AUTHORIZATION_FILE,
        VOICE_PROVIDER_TURNS_FILE,
    ]:
        try:
            os.unlink(path)
        except OSError:
            pass

    if not ensure_fifo(TTS_IN_FIFO):
        return False

    if inbox is not None:
        _start_intent_inbox_pump(inbox, shutdown_event)
        if sidecar_lane is not None:
            for pending in inbox.pending_for_route(IntentRoute.RUN_SIDECAR.value):
                metadata = pending.get("metadata")
                if not isinstance(metadata, dict):
                    continue
                with _VOICE_STATE_LOCK:
                    _atomic_write_json(VOICE_COMMAND_STATE_FILE, metadata)
                    sync_deliverable_state(VOICE_COMMAND_STATE_FILE, inbox)
                sidecar_lane.submit(
                    str(metadata.get("source_text") or pending.get("prompt") or ""),
                    metadata,
                )

    if not suppress_startup_greeting:
        _queue_tts_text(
            STARTUP_GREETING,
            tts_worker.input_queue,
            allow_pending_command=True,
        )

    # Start TTS input reader thread
    tts_reader = threading.Thread(
        target=_tts_fifo_reader,
        args=(tts_worker.input_queue, shutdown_event),
        daemon=True,
    )
    tts_reader.start()

    print("[voice_bridge] Relay mode — waiting for voice input...", file=sys.stderr)
    print(f"[voice_bridge] Voice commands → {VOICE_CMD_FILE}", file=sys.stderr)
    print(f"[voice_bridge] TTS input ← {TTS_IN_FIFO}", file=sys.stderr)

    fifo_fd = open_fifo(VOICE_FIFO)
    if fifo_fd is None:
        return False
    if on_ready is not None:
        on_ready()

    fifo_buf = b""
    try:
        while not shutdown_event.is_set():
            try:
                readable, _, _ = select.select([fifo_fd], [], [], 0.2)
            except (OSError, ValueError):
                try:
                    os.close(fifo_fd)
                except OSError:
                    pass
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            if fifo_fd not in readable:
                continue

            try:
                data = os.read(fifo_fd, 4096)
            except BlockingIOError:
                continue
            except OSError:
                os.close(fifo_fd)
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            if not data:
                os.close(fifo_fd)
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            fifo_buf += data
            while b"\n" in fifo_buf:
                line, fifo_buf = fifo_buf.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue

                if _handle_relay_control_message(
                    text,
                    tts_worker,
                    authorization_path=VOICE_COMMAND_AUTHORIZATION_FILE,
                    messenger=messenger,
                    inbox=inbox,
                    provider_turn_broker=provider_turn_broker,
                ):
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                relay_command = _begin_relay_command(text)
                if hasattr(tts_worker, "new_turn"):
                    tts_worker.new_turn(
                        relay_command["relay_command_seq"],
                        relay_command["relay_command_id"],
                    )
                else:
                    tts_worker.skip()
                resolved_items = _resolve_voice_work_items(
                    text,
                    relay_command,
                    repo_path=Path.cwd(),
                    active_work=_active_work(repo_path=Path.cwd()),
                )
                relay_command["voice_work_items"] = [
                    resolved["item"].to_dict() for resolved in resolved_items
                ]
                if resolved_items:
                    relay_command["work_disposition"] = resolved_items[-1][
                        "disposition"
                    ].to_dict()
                # Tutorial sessions need one authoritative reply to exercise
                # play, replay, and cancel. A fast social reply here would race
                # the foreground provider and leave its second greeting queued
                # after the tutorial has already advanced.
                should_submit_to_messenger = not suppress_next_messenger_user_reply
                suppress_next_messenger_user_reply = False
                if messenger is not None and should_submit_to_messenger:
                    messenger.submit_user(text, relay_command)
                _queue_voice_acknowledgement(
                    relay_command,
                    tts_worker.input_queue,
                    source_text=text,
                    discard_pending_command=inbox is None,
                )
                for resolved in resolved_items:
                    item = resolved["item"]
                    action = resolved["action"]
                    disposition = resolved["disposition"]
                    metadata = resolved["metadata"]
                    prompt = resolved["prompt"]
                    _record_command_action_state(metadata, "classified")
                    try:
                        record_command_authorization(
                            VOICE_COMMAND_AUTHORIZATION_FILE,
                            metadata,
                            relationship=str(metadata.get("authorization_relationship") or ""),
                            allowed_mutations=(
                                []
                                if item.lifecycle_state == "cancelled"
                                else allowed_mutations_for_metadata(metadata)
                            ),
                        )
                    except (OSError, TypeError, ValueError) as e:
                        print(
                            f"[voice_bridge] Could not record Relay mutation authorization: {e}",
                            file=sys.stderr,
                        )
                    if item.lifecycle_state == "cancelled" and inbox is None:
                        _record_command_action_state(metadata, "cancelled")
                        continue
                    if disposition.route == IntentRoute.RUN_SIDECAR:
                        accepted = (
                            item.lifecycle_state != "cancelled"
                            and sidecar_lane is not None
                            and _enqueue_sidecar_intent(
                                prompt=prompt,
                                source_text=item.source_text,
                                metadata=metadata,
                                sidecar_lane=sidecar_lane,
                                inbox=inbox,
                            )
                        )
                        if not accepted and item.lifecycle_state != "cancelled":
                            failure = SidecarLifecycleEvent(
                                phase="failed",
                                command=metadata,
                                public_summary=disposition.public_reason,
                            )
                            _handle_sidecar_lifecycle(
                                failure,
                                inbox=inbox,
                                messenger=messenger,
                            )
                            _handle_sidecar_final(
                                "The independent read-only task could not enter its bounded sidecar lane.",
                                metadata,
                                tts_worker=tts_worker,
                                messenger=messenger,
                            )
                        print(
                            f"[voice_bridge] Sidecar {'accepted' if accepted else 'rejected'} "
                            f"for intent={disposition.intent_id}",
                            file=sys.stderr,
                        )
                        continue
                    if (
                        item.lifecycle_state != "cancelled"
                        and _should_fanout_raw_instruction_to_orchestrator(action)
                    ):
                        _fanout_raw_instruction_to_orchestrator(
                            item.source_text,
                            metadata,
                            action,
                            repo_path=Path.cwd(),
                            orchestrator_session=orchestrator_session,
                        )
                    if item.lifecycle_state != "cancelled":
                        _start_pm_update_mode(
                            metadata,
                            action,
                            orchestrator_session=orchestrator_session,
                            messenger=messenger,
                            source_text=item.source_text,
                        )
                    _publish_command(
                        prompt,
                        metadata,
                        authorization_path=VOICE_COMMAND_AUTHORIZATION_FILE,
                        inbox=inbox,
                        transport=(
                            "app-or-manual-shared-ready-file"
                            if inbox is not None
                            else "legacy-ready-file"
                        ),
                    )
                    state = "cancelled" if item.lifecycle_state == "cancelled" else "queued"
                    _record_command_action_state(metadata, state)
                    print(
                        f"[voice_bridge] Voice item ready: {action.outcome} "
                        f"intent={item.intent_id} order={item.within_turn_order} "
                        f"disposition={disposition.route.value} state={state}",
                        file=sys.stderr,
                    )

    except KeyboardInterrupt:
        pass
    finally:
        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass
        for path in [
            TTS_IN_FIFO,
            VOICE_CMD_FILE,
            VOICE_CMD_META_FILE,
            VOICE_COMMAND_STATE_FILE,
            VOICE_COMMAND_CLAIM_FILE,
            VOICE_MANUAL_CLAIM_ACK_FILE,
            VOICE_COMMAND_AUTHORIZATION_FILE,
            VOICE_PROVIDER_TURNS_FILE,
        ]:
            try:
                os.unlink(path)
            except OSError:
                pass
    return True


def _record_bridge_readiness(outcome: str) -> None:
    provider = os.environ.get("RELAY_RUNNER_PROVIDER")
    if provider not in {"codex", "claude"}:
        provider = None
    record_support_event(
        process="shell",
        phase="bridge_readiness",
        outcome=outcome,
        provider=provider,
    )


def _write_cmd_file(text: str, path: str = VOICE_CMD_FILE):
    """Atomically write a voice command to the ready file."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, path)


def main():
    cfg = load_config()
    cli = _parse_args()
    relay_mode = cli.get("relay", False)

    if not relay_mode:
        # Legacy direct mode is intentionally Claude-only. The supported
        # script/app entry points always pass --relay and run Codex or Claude
        # through the installed relay-bridge skill/command instead.
        claude_bin = shutil.which("claude")
        if not claude_bin:
            print("[voice_bridge] Error: claude not found on PATH", file=sys.stderr)
            sys.exit(1)

    if not ensure_fifo(VOICE_FIFO):
        sys.exit(1)

    tts_queue: queue.Queue = queue.Queue()
    tts_executor = TTSWorker(tts_queue, start_control_socket=not relay_mode)
    tts_worker = tts_executor
    intent_inbox: IntentInbox | None = None
    provider_turn_broker: ProviderTurnBroker | None = None
    if relay_mode:
        tts_worker = SpeechCoordinator(
            tts_executor,
            is_current=lambda command_seq, command_id: _relay_command_current(
                command_seq,
                command_id,
            ),
            event_log_path=SPEECH_EVENT_LOG,
            control_socket_path=TTS_CONTROL_SOCK,
        )
        projection_path = (
            None
            if PROVIDER_TURN_BROKER_MODE == "legacy"
            else VOICE_PROVIDER_TURN_PROJECTION_FILE
        )
        intent_inbox = IntentInbox(
            VOICE_INTENT_INBOX,
            provider_turn_projection_path=projection_path,
        )
        if projection_path is not None:
            provider_turn_broker = ProviderTurnBroker(
                VOICE_INTENT_INBOX,
                projection_path=projection_path,
            )
            provider_turn_broker.project()

    shutdown_event = threading.Event()
    recovery_context: dict[str, object] = {}

    # Control socket for reload/shutdown from Tauri app
    control_thread = threading.Thread(
        target=_start_control_socket,
        args=(tts_worker, shutdown_event, recovery_context),
        daemon=True,
    )
    control_thread.start()

    # Relay mode: daemon for the relay-bridge skill/command
    if relay_mode:
        orchestrator_session = start_persistent_orchestrator_lifecycle(cfg, shutdown_event)

        def _submit_messenger_speech(
            text,
            command_seq,
            command_id,
            display_text=None,
            speech_metadata=None,
        ):
            metadata = speech_metadata if isinstance(speech_metadata, dict) else {}
            return _queue_tts_text(
                json.dumps({
                    "text": text,
                    "display_text": display_text,
                    "relay_command_seq": command_seq,
                    "relay_command_id": command_id,
                }),
                tts_worker.input_queue,
                allow_pending_command=True,
                **metadata,
            )

        messenger = create_messenger_runtime(
            cfg,
            cwd=Path.cwd(),
            speak=_submit_messenger_speech,
            is_current=lambda command_seq, command_id: _relay_command_current(
                command_seq,
                command_id,
            ),
            coverage_provider=tts_worker.played_coverage,
            realization_observer=tts_worker.record_realization,
            continuity_observer=lambda event: _post_continuity_event(
                "messenger",
                str(event.get("event") or ""),
                event,
            ),
        )
        if messenger is not None:
            messenger.start()
        recovery_context.update({
            "messenger": messenger,
            "orchestrator_session": orchestrator_session,
        })
        _surface_recoverable_command_status(
            orchestrator_session,
            messenger=messenger,
        )
        sidecar_lane = SidecarLane(
            create_sidecar_executor(cfg, cwd=str(Path.cwd())),
            on_lifecycle=lambda event: _handle_sidecar_lifecycle(
                event,
                inbox=intent_inbox,
                messenger=messenger,
            ),
            on_final=lambda text, command: _handle_sidecar_final(
                text,
                command,
                tts_worker=tts_worker,
                messenger=messenger,
            ),
        )
        _start_messenger_outcome_polling(
            orchestrator_session=orchestrator_session,
            messenger=messenger,
            shutdown_event=shutdown_event,
        )
        try:
            bridge_completed = _run_relay(
                tts_worker,
                shutdown_event,
                orchestrator_session=orchestrator_session,
                messenger=messenger,
                suppress_startup_greeting=cli.get(
                    "suppress_startup_greeting",
                    False,
                ),
                inbox=intent_inbox,
                provider_turn_broker=provider_turn_broker,
                sidecar_lane=sidecar_lane,
                on_ready=lambda: _record_bridge_readiness("ready"),
            )
            if not bridge_completed:
                raise RuntimeError("voice bridge initialization failed")
        finally:
            shutdown_event.set()
            sidecar_lane.shutdown()
            if messenger is not None:
                messenger.shutdown()
            stop_persistent_orchestrator_lifecycle(
                orchestrator_session,
                reason="bridge stopped",
            )
            tts_worker.shutdown()
            if intent_inbox is not None:
                intent_inbox.close()
            if provider_turn_broker is not None:
                provider_turn_broker.close()
            try:
                os.unlink(BRIDGE_CONTROL_SOCK)
            except OSError:
                pass
        return

    bridge = LegacyDirectVoiceBridge(claude_bin, tts_queue, session_id=cli.get("session"))

    print("\033[1mRelay Runner\033[0m — Caps Lock to speak, Caps Lock again to interrupt")
    if bridge.session_id:
        print(f"\033[2mResuming session: {bridge.session_id}\033[0m")
    print(f"\033[2mlistening on {VOICE_FIFO}\033[0m\n")
    sys.stdout.flush()

    fifo_fd = open_fifo(VOICE_FIFO)
    if fifo_fd is None:
        sys.exit(1)

    # Run legacy Claude calls in a worker thread so FIFO stays responsive
    request_queue: queue.Queue = queue.Queue()

    def _worker():
        while True:
            text = request_queue.get()
            if text is None:
                break
            bridge.send(text)

    worker_thread = threading.Thread(target=_worker, daemon=True)
    worker_thread.start()

    fifo_buf = b""
    try:
        while not shutdown_event.is_set():
            try:
                readable, _, _ = select.select([fifo_fd], [], [], 0.2)
            except (OSError, ValueError):
                try:
                    os.close(fifo_fd)
                except OSError:
                    pass
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            if fifo_fd not in readable:
                continue

            try:
                data = os.read(fifo_fd, 4096)
            except BlockingIOError:
                continue
            except OSError:
                os.close(fifo_fd)
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            if not data:
                os.close(fifo_fd)
                fifo_fd = open_fifo(VOICE_FIFO)
                if fifo_fd is None:
                    break
                continue

            fifo_buf += data
            while b"\n" in fifo_buf:
                line, fifo_buf = fifo_buf.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue

                if text == "__TTS_STOP__":
                    tts_worker.stop_playback(reason="recording_barge_in")
                    continue

                if text == "__INTERRUPT__":
                    bridge.interrupt()
                    tts_worker.stop_playback(reason="interrupt")
                    continue

                if text == "__CANCEL__":
                    bridge.interrupt()
                    tts_worker.skip()  # Clear pending text so next message gets fresh notification
                    continue

                if text == "__PLAY__" or text.startswith("__PLAY__:"):
                    _play_or_replay(
                        tts_worker,
                        option_detected_at=_play_control_detected_at(text),
                    )
                    continue

                if text.startswith("__PLAY_ACK__:"):
                    continue

                if text == "__REPLAY__":
                    tts_worker.replay()
                    continue

                if text.startswith("__TRACE__:"):
                    _handle_orchestration_trace_control(text[len("__TRACE__:"):])
                    continue

                if text.startswith("__STATUS__:"):
                    status_msg = text[len("__STATUS__:"):]
                    _observe_stt_status(status_msg)
                    print(f"\033[2m  [{status_msg}]\033[0m")
                    sys.stdout.flush()
                    continue

                if text.startswith("__CONTINUITY__:"):
                    _observe_stt_continuity_signal(text[len("__CONTINUITY__:"):])
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                # Interrupt any in-progress legacy Claude request, stop TTS audio
                # (but don't discard pending text — user may still want to play it)
                bridge.interrupt()
                tts_worker.stop_playback(reason="newer_command")
                request_queue.put(text)

    except KeyboardInterrupt:
        pass
    finally:
        shutdown_event.set()
        request_queue.put(None)  # Signal worker to exit
        bridge.shutdown()
        tts_worker.shutdown()
        if fifo_fd is not None:
            try:
                os.close(fifo_fd)
            except OSError:
                pass
        try:
            os.unlink(BRIDGE_CONTROL_SOCK)
        except OSError:
            pass
        print("\n\033[2mSession ended.\033[0m")


if __name__ == "__main__":
    main()
