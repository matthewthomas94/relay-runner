#!/usr/bin/env python3
"""Voice bridge daemon for relay-mode voice sessions.

Supported app/script paths run with --relay: the bridge writes commands to the
foreground agent through /tmp/voice_cmd_ready and runs a persistent tool-free
messenger for spoken replies. /tmp/tts_in.fifo remains as a compatibility and
failure-fallback input. The non-relay branch below is legacy Claude-only direct
mode retained for manual debugging; Start Session and relay-bridge do not use it.
"""

from __future__ import annotations

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
from messenger import MessengerRuntime, create_messenger_runtime
from tts_worker import TTSWorker, publish_waiting_preview

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
FOREGROUND_REPLY_FALLBACK_SECONDS = float(os.environ.get("FOREGROUND_REPLY_FALLBACK_SECONDS", "120"))
PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS = float(os.environ.get("PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS", "5"))

_FOREGROUND_REPLY_LOCK = threading.Lock()
_FOREGROUND_REPLIED_COMMANDS: set[tuple[int, str]] = set()


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
VOICE_COMMAND_AUTHORIZATION_FILE = os.environ.get(
    "VOICE_COMMAND_AUTHORIZATION_FILE",
    "/tmp/voice_command_authorizations.json",
)
VOICE_PROVIDER_TURNS_FILE = os.environ.get("VOICE_PROVIDER_TURNS_FILE", "/tmp/voice_provider_turns.json")
VOICE_COMMAND_EVENT_LOG = os.environ.get("VOICE_COMMAND_EVENT_LOG", "/tmp/relay_command_events.jsonl")
VOICE_COMMAND_EVENT_LIMIT = 200
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
        "repo_path": repo_path,
        "provider": provider,
        "thread": thread,
        "shutdown_event": shutdown_event,
        "state": session_state,
        "state_lock": session_lock,
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
        "limit": 10,
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

    delivered = 0
    for outcome in outcomes:
        if not isinstance(outcome, dict):
            continue
        outcome_id = outcome.get("id")
        payload = outcome.get("payload")
        trace = payload.get("trace_event") if isinstance(payload, dict) else None
        if not isinstance(trace, dict):
            continue
        if messenger.submit_trace(trace):
            try:
                request_json(f"/v1/messenger/outcomes/{int(outcome_id)}/delivered", {})
                delivered += 1
            except (TypeError, ValueError, OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
                print(f"[voice_bridge] pending messenger outcome ack failed: {e}", file=sys.stderr)
        else:
            try:
                request_json(f"/v1/messenger/outcomes/{int(outcome_id)}/attempt", {})
            except (TypeError, ValueError, OSError, urllib.error.URLError, json.JSONDecodeError, TimeoutError):
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
    }
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
        with open(tmp, "w") as f:
            for line in existing:
                f.write(line + "\n")
            f.write(json.dumps(event, sort_keys=True) + "\n")
        os.replace(tmp, event_log_path)
    except (OSError, TypeError, ValueError) as e:
        print(f"[voice_bridge] Could not record private command event: {e}", file=sys.stderr)


def _begin_relay_command(
    source_text: str,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
) -> dict:
    """Record a new newest-intent generation as soon as voice input arrives."""
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
    }
    provider = os.environ.get("RELAY_RUNNER_PROVIDER", "").strip()
    if provider:
        metadata["provider"] = provider
    _atomic_write_json(state_path, metadata)
    _record_private_command_capture(metadata, event_log_path=event_log_path)
    return metadata


def _metadata_for_action(action, relay_command: dict) -> dict:
    metadata = dict(relay_command)
    relationship = command_relationship(
        getattr(action, "kind", None),
        reason=getattr(action, "reason", None),
        source_text=getattr(action, "source_text", None),
    )
    metadata.update({
        "action": action.kind,
        "outcome": action.outcome,
        "requires_ticket": action.requires_ticket,
        "authorization_relationship": relationship,
    })
    if action.ticket_id:
        metadata["ticket_id"] = action.ticket_id
    if action.ticket_path:
        metadata["ticket_path"] = action.ticket_path
    if action.repo_path:
        metadata["repo_path"] = action.repo_path
    if action.reason:
        metadata["reason"] = action.reason
    return metadata


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
        "received_at": metadata.get("received_at"),
        "action": metadata.get("action"),
        "outcome": metadata.get("outcome"),
    }
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
    request_json=_post_orchestrator_json,
) -> bool:
    command_seq = relay_command.get("relay_command_seq")
    command_id = relay_command.get("relay_command_id")
    if not _relay_command_current(command_seq, command_id, state_path=state_path):
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
        print(f"[voice_bridge] Could not fan out raw command to orchestrator: {e}", file=sys.stderr)
        return False
    return True


def _fanout_raw_instruction_to_orchestrator(
    source_text: str,
    relay_command: dict,
    action,
    *,
    repo_path: str | Path | None = None,
    orchestrator_session: dict | None = None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
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
            "request_json": request_json,
        },
        name="orchestrator-raw-command-fanout",
        daemon=True,
    )
    thread.start()
    return thread


def _should_fanout_raw_instruction_to_orchestrator(action) -> bool:
    """Keep the default voice path two-layer: foreground PM first, workers next."""
    del action
    return False


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
) -> None:
    """Publish a Relay command and sidecar metadata as the newest intent."""
    _discard_pending_command(command_path=command_path, meta_path=meta_path)
    published_metadata = dict(metadata)
    published_metadata["agent_prompt"] = text
    if not published_metadata.get("authorization_relationship"):
        published_metadata["authorization_relationship"] = command_relationship(
            published_metadata.get("action"),
            reason=published_metadata.get("reason"),
            source_text=published_metadata.get("source_text"),
        )
    _atomic_write_json(meta_path, published_metadata)
    _atomic_write_json(state_path, published_metadata)
    if authorization_path:
        try:
            record_command_authorization(
                authorization_path,
                published_metadata,
                relationship=str(published_metadata.get("authorization_relationship") or ""),
                allowed_mutations=allowed_mutations_for_metadata(published_metadata),
            )
        except (OSError, TypeError, ValueError) as e:
            print(f"[voice_bridge] Could not record Relay mutation authorization: {e}", file=sys.stderr)
    _write_cmd_file(text, path=command_path)


def _relay_command_current(
    relay_command_seq: int | str | None,
    relay_command_id: str | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> bool:
    if relay_command_seq is None or not relay_command_id:
        return False
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


def _provider_turn_state(
    relay_command: dict | None,
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
) -> str | None:
    key = _relay_command_key(relay_command)
    if key is None:
        return None
    data = _read_json_file(turns_path)
    records = data.get("records") if isinstance(data, dict) else None
    if not isinstance(records, list):
        return None
    for record in reversed(records):
        if isinstance(record, dict) and _relay_command_key(record) == key:
            state = str(record.get("state") or "").strip()
            return state or None
    return None


def _provider_turn_active(
    relay_command: dict | None,
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
) -> bool:
    return _provider_turn_state(relay_command, turns_path=turns_path) == "active"


def _any_provider_turn_active(
    *,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
) -> bool:
    data = _read_json_file(turns_path)
    records = data.get("records") if isinstance(data, dict) else None
    if not isinstance(records, list):
        return False
    return any(
        isinstance(record, dict)
        and str(record.get("state") or "").strip() == "active"
        for record in records
    )


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
    return _relay_command_key(metadata) == key


def _foreground_reply_delivered(command: dict | None) -> bool:
    key = _relay_command_key(command)
    if key is None:
        return False
    with _FOREGROUND_REPLY_LOCK:
        return key in _FOREGROUND_REPLIED_COMMANDS


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


def _start_control_socket(tts_worker: TTSWorker, shutdown_event: threading.Event):
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
                data, _ = sock.recvfrom(256)
                cmd = data.decode("utf-8", errors="replace").strip()
                cmd_lower = cmd.lower()
                if cmd_lower == "reload":
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


def _queue_tts_text(
    text: str,
    tts_queue: queue.Queue,
    command_path: str = VOICE_CMD_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    allow_pending_command: bool = False,
    notify_waiting_preview=None,
) -> bool:
    """Queue TTS unless a newer Relay command is already waiting."""
    text, display_text, command_seq, command_id = _parse_tts_payload(text)
    display_preview = _normalize_display_preview(display_text)
    text = _strip_markdown_for_tts(text.strip()).strip()
    if not text and display_preview:
        text = _strip_markdown_for_tts(display_preview).strip()
    if not text:
        return False
    if command_seq is not None or command_id:
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
    publisher = publish_waiting_preview if notify_waiting_preview is None else notify_waiting_preview
    if publisher is not None:
        try:
            publisher(display_preview or text)
        except Exception as exc:
            print(f"[voice_bridge] Could not publish waiting preview: {exc}", file=sys.stderr)
    if display_preview:
        tts_queue.put({"text": text, "display_text": display_preview})
    else:
        tts_queue.put(text)
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
) -> bool:
    """Schedule a short acknowledgement for the newest command."""
    del tts_queue
    text = build_voice_acknowledgement(source_text, relay_command).strip()
    if not text:
        return False
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


def _handle_relay_control_message(
    text: str,
    tts_worker: TTSWorker,
    command_path: str = VOICE_CMD_FILE,
    meta_path: str = VOICE_CMD_META_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    authorization_path: str | None = None,
    event_log_path: str | None = VOICE_COMMAND_EVENT_LOG,
    messenger: MessengerRuntime | None = None,
) -> bool:
    """Handle provider-neutral relay controls before command publication."""
    if text == "__TTS_STOP__":
        # Kill TTS playback only; preserve queued text for double-tap play.
        tts_worker.stop_playback()
        return True

    if text == "__INTERRUPT__":
        tts_worker.stop_playback()
        if messenger is not None:
            messenger.interrupt()
        relay_command = _begin_relay_command(
            text,
            state_path=state_path,
            event_log_path=event_log_path,
        )
        _publish_command(
            "__INTERRUPT__",
            {
                **relay_command,
                "action": "control",
                "outcome": "control action interrupt",
                "reason": "interrupt",
            },
            command_path=command_path,
            meta_path=meta_path,
            state_path=state_path,
            authorization_path=authorization_path,
        )
        return True

    if text == "__CANCEL__":
        # Double-tap Control is also used to dismiss acknowledgement/TTS UI.
        # In relay mode Codex and Claude share this bridge path, so dismissal
        # must not advance newest-intent metadata for either provider.
        tts_worker.skip()
        return True

    if text == "__PLAY__":
        tts_worker.play()
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
        )
        return True

    if text.startswith("__RELAY_COMPLETION__:"):
        _handle_provider_completion_control(
            text[len("__RELAY_COMPLETION__:"):],
            tts_worker=tts_worker,
            messenger=messenger,
            state_path=state_path,
        )
        return True

    if text.startswith("__STATUS__:"):
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
) -> bool:
    key = _relay_command_key(relay_command)
    if key is None:
        return False
    if _foreground_reply_delivered(relay_command):
        return True
    if not _relay_command_current(key[0], key[1], state_path=state_path):
        return False
    payload = {
        "text": _missing_foreground_reply_text_for_kind(action_kind),
        "relay_command_seq": key[0],
        "relay_command_id": key[1],
    }
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
        )
    if delivered:
        _mark_foreground_reply_delivered(relay_command)
    return delivered


def _log_foreground_reply_fallback_event(
    event: str,
    *,
    relay_command: dict,
    turns_path: str,
    reason: str | None = None,
) -> None:
    key = _relay_command_key(relay_command)
    fields = [f"event={event}"]
    if key is not None:
        fields.append(f"relay_command_seq={key[0]}")
        fields.append(f"relay_command_id={key[1]}")
    state = _provider_turn_state(relay_command, turns_path=turns_path) or "none"
    fields.append(f"provider_turn_state={state}")
    provider = str(relay_command.get("provider") or "").strip()
    if provider:
        fields.append(f"provider={provider}")
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
            if _command_pending_delivery(
                relay_command,
                command_path=command_path,
                meta_path=meta_path,
            ):
                _log_foreground_reply_fallback_event(
                    "deferred",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason="pending_delivery",
                )
                sleep_for = max(0.25, PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS)
                continue
            if _provider_turn_active(relay_command, turns_path=turns_path):
                _log_foreground_reply_fallback_event(
                    "deferred",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason="correlated_turn_active",
                )
                sleep_for = max(0.25, PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS)
                continue
            if _any_provider_turn_active(turns_path=turns_path):
                _log_foreground_reply_fallback_event(
                    "deferred",
                    relay_command=relay_command,
                    turns_path=turns_path,
                    reason="provider_turn_active",
                )
                sleep_for = max(0.25, PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS)
                continue
            _log_foreground_reply_fallback_event(
                "eligible",
                relay_command=relay_command,
                turns_path=turns_path,
            )
            delivered = _deliver_missing_foreground_reply(
                relay_command=relay_command,
                action_kind=action_kind,
                tts_worker=tts_worker,
                messenger=messenger,
                state_path=state_path,
            )
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
        }
        return _handle_orchestrator_reply_control(
            json.dumps(payload),
            tts_worker=tts_worker,
            messenger=messenger,
            state_path=state_path,
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
    )
    return thread is not None


def _handle_orchestrator_reply_control(
    raw: str,
    *,
    tts_worker: TTSWorker,
    messenger: MessengerRuntime | None,
    state_path: str = VOICE_COMMAND_STATE_FILE,
) -> bool:
    """Route the foreground agent's authoritative reply through the messenger."""
    text = raw.strip()
    if not text:
        return False
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        data = {"text": text}
    if not isinstance(data, dict):
        return False
    reply = str(data.get("text") or "").strip()
    if not reply:
        return False

    nested = data.get("relay_command")
    command = nested if isinstance(nested, dict) else data
    if not command.get("relay_command_id"):
        command = _read_json_file(VOICE_COMMAND_CLAIM_FILE)
    if _foreground_reply_delivered(command):
        return True
    command_key = _relay_command_key(command)
    if command_key is None or not _relay_command_current(command_key[0], command_key[1], state_path=state_path):
        print(
            "[voice_bridge] Dropping foreground reply because its Relay command was superseded.",
            file=sys.stderr,
        )
        return False
    payload = {"text": reply}
    for key in ("relay_command_seq", "relay_command_id"):
        if key in command:
            payload[key] = command[key]

    _publish_authoritative_preview(reply)
    if messenger is not None and messenger.submit_final(payload):
        _mark_foreground_reply_delivered(command)
        return True

    # A missing or out-of-sync messenger must not swallow a current outcome.
    # _queue_tts_text still rejects stale command metadata.
    delivered = _queue_tts_text(
        json.dumps({**payload, "display_text": reply}),
        tts_worker.input_queue,
        state_path=state_path,
        allow_pending_command=True,
        notify_waiting_preview=lambda _text: None,
    )
    if delivered:
        _mark_foreground_reply_delivered(command)
    return delivered


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
        VOICE_COMMAND_AUTHORIZATION_FILE,
        VOICE_PROVIDER_TURNS_FILE,
    ]:
        try:
            os.unlink(path)
        except OSError:
            pass

    if not ensure_fifo(TTS_IN_FIFO):
        return

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
        return

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
                ):
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                # Skip TTS for new voice input, write an explicit command
                # action for the foreground orchestrator session.
                tts_worker.skip()
                relay_command = _begin_relay_command(text)
                action = resolve_command_action(
                    text,
                    repo_path=Path.cwd(),
                    relay_command=relay_command,
                )
                metadata = _metadata_for_action(action, relay_command)
                try:
                    record_command_authorization(
                        VOICE_COMMAND_AUTHORIZATION_FILE,
                        metadata,
                        relationship=str(metadata.get("authorization_relationship") or ""),
                        allowed_mutations=allowed_mutations_for_metadata(metadata),
                    )
                except (OSError, TypeError, ValueError) as e:
                    print(f"[voice_bridge] Could not record Relay mutation authorization: {e}", file=sys.stderr)
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
                )
                if _should_fanout_raw_instruction_to_orchestrator(action):
                    _fanout_raw_instruction_to_orchestrator(
                        text,
                        relay_command,
                        action,
                        repo_path=Path.cwd(),
                        orchestrator_session=orchestrator_session,
                    )
                _start_pm_update_mode(
                    relay_command,
                    action,
                    orchestrator_session=orchestrator_session,
                    messenger=messenger,
                    source_text=text,
                )
                _publish_command(
                    format_command_for_agent(action),
                    metadata,
                    authorization_path=VOICE_COMMAND_AUTHORIZATION_FILE,
                )
                print(
                    f"[voice_bridge] Voice command ready: {action.outcome}",
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
            VOICE_COMMAND_AUTHORIZATION_FILE,
            VOICE_PROVIDER_TURNS_FILE,
        ]:
            try:
                os.unlink(path)
            except OSError:
                pass


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
    tts_worker = TTSWorker(tts_queue)

    shutdown_event = threading.Event()

    # Control socket for reload/shutdown from Tauri app
    control_thread = threading.Thread(
        target=_start_control_socket, args=(tts_worker, shutdown_event), daemon=True
    )
    control_thread.start()

    # Relay mode: daemon for the relay-bridge skill/command
    if relay_mode:
        orchestrator_session = start_persistent_orchestrator_lifecycle(cfg, shutdown_event)
        messenger = create_messenger_runtime(
            cfg,
            cwd=Path.cwd(),
            speak=lambda text, command_seq, command_id, display_text=None: _queue_tts_text(
                json.dumps({
                    "text": text,
                    "display_text": display_text,
                    "relay_command_seq": command_seq,
                    "relay_command_id": command_id,
                }),
                tts_worker.input_queue,
                allow_pending_command=True,
            ),
            is_current=lambda command_seq, command_id: _relay_command_current(
                command_seq,
                command_id,
            ),
        )
        if messenger is not None:
            messenger.start()
        _start_messenger_outcome_polling(
            orchestrator_session=orchestrator_session,
            messenger=messenger,
            shutdown_event=shutdown_event,
        )
        try:
            _run_relay(
                tts_worker,
                shutdown_event,
                orchestrator_session=orchestrator_session,
                messenger=messenger,
                suppress_startup_greeting=cli.get(
                    "suppress_startup_greeting",
                    False,
                ),
            )
        finally:
            shutdown_event.set()
            if messenger is not None:
                messenger.shutdown()
            stop_persistent_orchestrator_lifecycle(
                orchestrator_session,
                reason="bridge stopped",
            )
            tts_worker.shutdown()
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
                    tts_worker.stop_playback()
                    continue

                if text == "__INTERRUPT__":
                    bridge.interrupt()
                    tts_worker.stop_playback()
                    continue

                if text == "__CANCEL__":
                    bridge.interrupt()
                    tts_worker.skip()  # Clear pending text so next message gets fresh notification
                    continue

                if text == "__PLAY__":
                    tts_worker.play()
                    continue

                if text == "__REPLAY__":
                    tts_worker.replay()
                    continue

                if text.startswith("__TRACE__:"):
                    _handle_orchestration_trace_control(text[len("__TRACE__:"):])
                    continue

                if text.startswith("__STATUS__:"):
                    status_msg = text[len("__STATUS__:"):]
                    print(f"\033[2m  [{status_msg}]\033[0m")
                    sys.stdout.flush()
                    continue

                # Convert "slash <command>" to "/<command>"
                slash_match = re.match(r"^(?:slash|forward slash)\s+(.+)$", text, re.IGNORECASE)
                if slash_match:
                    text = "/" + slash_match.group(1).replace(" ", "-")

                # Interrupt any in-progress legacy Claude request, stop TTS audio
                # (but don't discard pending text — user may still want to play it)
                bridge.interrupt()
                tts_worker.stop_playback()
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
