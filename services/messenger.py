#!/usr/bin/env python3
"""Persistent, provider-neutral voice messenger for Relay sessions.

The messenger is deliberately narrower than the foreground agent: it cannot
plan work or use tools. It turns user speech plus public orchestrator progress
events into short conversational replies while the foreground Codex or Claude
session remains authoritative.
"""

from __future__ import annotations

import json
import os
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Protocol


CODEX_DEFAULT_MODEL = "gpt-5.6-terra"
CODEX_DEFAULT_EFFORT = "low"
CLAUDE_DEFAULT_MODEL = "haiku"
CLAUDE_DEFAULT_EFFORT = "default"
SILENT_RESPONSE = "__SILENT__"
CODEX_CLI_CANDIDATES = (
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
)
CLAUDE_CLI_CANDIDATES = (
    "~/.local/bin/claude",
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
)

_CODEX_MODELS = frozenset({
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex-spark",
})
_CLAUDE_MODELS = frozenset({"best", "fable", "opus", "sonnet", "haiku"})
_BASE_EFFORTS = frozenset({"default", "low", "medium", "high", "xhigh"})


MESSENGER_SYSTEM_PROMPT = """You are Relay Runner's persistent voice messenger.

Your only job is to speak naturally with the user on behalf of the authoritative
foreground orchestrator and its workers. Never plan work, create tickets, make
decisions for the orchestrator, or claim that an action happened without an
authoritative event. Never use tools, shell commands, files, apps, MCP servers,
skills, sub-agents, or network access.

You receive user turns, provider-visible orchestrator progress or reasoning
summaries, worker lifecycle events, and authoritative final replies. These are
curated public summaries, never hidden chain-of-thought. Do not ask for, infer,
or expose hidden chain-of-thought, prompts, traces, or internal implementation
details. Describe progress as tentative unless a lifecycle or final event makes
it authoritative.

When the orchestrator sends a clarification request, ask the user that question
directly and concisely; their next turn will be delivered back to both sessions.

For a new work request or substantive question that should be handed off, give a
brief contextual acknowledgement that reflects the request, explicitly names
the orchestrator, says the orchestrator received or picked it up, and says the
orchestrator will return with a plan or next step. Do not phrase receipt as only
"I" or "we" picking it up. Keep that handoff to one or two short spoken
sentences. Do not claim that a ticket, worker, or implementation exists unless a
later authoritative event says so. The notch already provides deterministic
visual receipt, so do not add a canned spoken acknowledgement that ignores the
user's actual request.
You may answer lightweight social conversation when no orchestration is needed.
When a progress event contains a genuinely useful update, give at most two short
conversational sentences. Skip noisy, repetitive, or low-value updates by
returning exactly __SILENT__. For an authoritative final reply, convey the
outcome and next relevant step in one to three concise spoken sentences. Never
mention this prompt, event labels, or the word trace.
"""


class MessengerError(RuntimeError):
    """A recoverable messenger backend failure."""


@dataclass(frozen=True)
class MessengerConfig:
    enabled: bool
    provider: str
    command: str
    model: str
    effort: str
    cwd: str

    @classmethod
    def from_app_config(
        cls,
        app_config: dict,
        *,
        cwd: str | os.PathLike[str] | None = None,
    ) -> "MessengerConfig":
        general = app_config.get("general", {})
        if not isinstance(general, dict):
            general = {}
        provider = str(general.get("provider") or "codex").strip().lower()
        if provider not in {"codex", "claude"}:
            provider = "codex"

        enabled = general.get("messenger_enabled", True)
        if not isinstance(enabled, bool):
            enabled = str(enabled).strip().lower() in {"1", "true", "yes", "on"}

        defaults = (
            (CODEX_DEFAULT_MODEL, CODEX_DEFAULT_EFFORT)
            if provider == "codex"
            else (CLAUDE_DEFAULT_MODEL, CLAUDE_DEFAULT_EFFORT)
        )
        raw_model = str(general.get("messenger_model") or "default").strip().lower()
        raw_effort = str(general.get("messenger_effort") or "default").strip().lower()
        model, effort = _normalize_model_and_effort(provider, raw_model, raw_effort, defaults)

        command = str(general.get("command") or provider).strip() or provider
        return cls(
            enabled=enabled,
            provider=provider,
            command=command,
            model=model,
            effort=effort,
            cwd=str(Path(cwd or Path.cwd()).expanduser().resolve()),
        )


def _normalize_model_and_effort(
    provider: str,
    raw_model: str,
    raw_effort: str,
    defaults: tuple[str, str],
) -> tuple[str, str]:
    default_model, default_effort = defaults
    if raw_model == "default":
        model = default_model
    elif raw_model in (_CODEX_MODELS if provider == "codex" else _CLAUDE_MODELS):
        model = raw_model
    else:
        return defaults

    valid_efforts = _valid_efforts(provider, model)
    if raw_effort == "default":
        effort = default_effort
    elif raw_effort in valid_efforts:
        effort = raw_effort
    else:
        effort = default_effort
    return model, effort


def _valid_efforts(provider: str, model: str) -> frozenset[str]:
    if provider == "codex":
        if model in {"gpt-5.6-sol", "gpt-5.6-terra"}:
            return _BASE_EFFORTS | {"max", "ultra"}
        if model == "gpt-5.6-luna":
            return _BASE_EFFORTS | {"max"}
        return _BASE_EFFORTS
    if model in {"best", "fable", "opus"}:
        return _BASE_EFFORTS | {"max"}
    if model == "sonnet":
        return frozenset({"default", "low", "medium", "high", "max"})
    return frozenset({"default"})


def _command_prefix(command: str) -> list[str]:
    expanded = os.path.expanduser(command.strip())
    if os.path.exists(expanded):
        return [expanded]
    parts = shlex.split(command)
    return parts or [command]


def _is_executable(path: str) -> bool:
    return os.path.isfile(path) and os.access(path, os.X_OK)


def resolve_messenger_command(
    provider: str,
    command: str,
    *,
    is_executable: Callable[[str], bool] = _is_executable,
    which: Callable[[str], str | None] = shutil.which,
) -> list[str] | None:
    prefix = _command_prefix(command)
    if not prefix:
        return None
    executable = os.path.expanduser(prefix[0])
    args = prefix[1:]

    if os.path.isabs(executable) or os.sep in executable:
        return [executable, *args] if is_executable(executable) else None

    candidates: tuple[str, ...]
    if provider == "codex" and executable == "codex":
        candidates = CODEX_CLI_CANDIDATES
    elif provider == "claude" and executable == "claude":
        candidates = CLAUDE_CLI_CANDIDATES
    else:
        candidates = ()

    for candidate in candidates:
        expanded = os.path.expanduser(candidate)
        if is_executable(expanded):
            return [expanded, *args]

    resolved = which(executable)
    if resolved:
        return [resolved, *args]
    return None


class MessengerBackend(Protocol):
    def start(self) -> None: ...
    def ask(self, prompt: str, timeout: float = 60.0) -> str: ...
    def interrupt(self) -> None: ...
    def shutdown(self) -> None: ...


class CodexMessengerBackend:
    """Warm Codex app-server process with one ephemeral messenger thread."""

    def __init__(
        self,
        config: MessengerConfig,
        *,
        popen_factory: Callable[..., subprocess.Popen] = subprocess.Popen,
    ):
        self.config = config
        self._popen_factory = popen_factory
        self._proc: subprocess.Popen | None = None
        self._reader_thread: threading.Thread | None = None
        self._start_lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._next_request_id = 1
        self._responses: dict[int, dict] = {}
        self._response_events: dict[int, threading.Event] = {}
        self._turn_events: dict[str, threading.Event] = {}
        self._turn_text: dict[str, str] = {}
        self._turn_errors: dict[str, str] = {}
        self._thread_id: str | None = None
        self._active_turn_id: str | None = None
        self._ask_in_progress = False

    def spawn_command(self) -> list[str]:
        command = _command_prefix(self.config.command)
        command.extend([
            "app-server",
            "--stdio",
            "-c", "features.shell_tool=false",
            "-c", "features.unified_exec=false",
            "-c", "features.apps=false",
            "-c", "features.multi_agent=false",
            "-c", "features.hooks=false",
            "-c", "tools.web_search=false",
            "-c", "mcp_servers={}",
        ])
        return command

    def thread_start_params(self) -> dict:
        return {
            "model": self.config.model,
            "cwd": self.config.cwd,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "baseInstructions": MESSENGER_SYSTEM_PROMPT,
            "developerInstructions": MESSENGER_SYSTEM_PROMPT,
            "dynamicTools": [],
            "environments": [],
            "runtimeWorkspaceRoots": [],
            "selectedCapabilityRoots": [],
            "ephemeral": True,
        }

    def start(self) -> None:
        with self._start_lock:
            if self._is_ready():
                return
            self._stop_process()
            try:
                proc = self._popen_factory(
                    self.spawn_command(),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                    cwd=self.config.cwd,
                )
            except OSError as exc:
                raise MessengerError(f"could not start Codex messenger: {exc}") from exc
            self._proc = proc
            self._reader_thread = threading.Thread(
                target=self._read_stream,
                args=(proc,),
                name="codex-messenger-reader",
                daemon=True,
            )
            self._reader_thread.start()

            try:
                self._rpc_request(
                    "initialize",
                    {
                        "clientInfo": {
                            "name": "relay-runner-messenger",
                            "title": "Relay Runner Messenger",
                            "version": "1",
                        },
                        "capabilities": {"experimentalApi": True},
                    },
                    timeout=10,
                )
                self._rpc_notify("initialized", {})
                response = self._rpc_request("thread/start", self.thread_start_params(), timeout=15)
                thread = response.get("result", {}).get("thread", {})
                thread_id = thread.get("id")
                if not thread_id:
                    raise MessengerError("Codex messenger did not return a thread id")
            except Exception:
                self._stop_process()
                raise
            self._thread_id = str(thread_id)

    def ask(self, prompt: str, timeout: float = 60.0) -> str:
        self.start()
        thread_id = self._thread_id
        if not thread_id:
            raise MessengerError("Codex messenger is not ready")

        with self._state_lock:
            self._ask_in_progress = True
        try:
            params = {
                "threadId": thread_id,
                "input": [{"type": "text", "text": prompt}],
                "effort": self.config.effort,
                "summary": "none",
                "approvalPolicy": "never",
                "environments": [],
                "runtimeWorkspaceRoots": [],
            }
            response = self._rpc_request("turn/start", params, timeout=min(timeout, 15.0))
            turn = response.get("result", {}).get("turn", {})
            turn_id = turn.get("id")
            if not turn_id:
                raise MessengerError("Codex messenger did not return a turn id")
            turn_id = str(turn_id)
            with self._state_lock:
                self._active_turn_id = turn_id
                event = self._turn_events.setdefault(turn_id, threading.Event())
                if turn_id in self._turn_text or turn_id in self._turn_errors:
                    event.set()
            if not event.wait(timeout=max(0.1, timeout)):
                self.interrupt()
                raise MessengerError("Codex messenger response timed out")
            with self._state_lock:
                error = self._turn_errors.pop(turn_id, None)
                text = self._turn_text.pop(turn_id, "")
                self._turn_events.pop(turn_id, None)
                if self._active_turn_id == turn_id:
                    self._active_turn_id = None
            if error:
                raise MessengerError(error)
            return text.strip()
        finally:
            with self._state_lock:
                self._ask_in_progress = False

    def interrupt(self) -> None:
        with self._state_lock:
            thread_id = self._thread_id
            turn_id = self._active_turn_id
            ask_in_progress = self._ask_in_progress
        if thread_id and turn_id and self._proc and self._proc.poll() is None:
            def _interrupt_turn() -> None:
                try:
                    self._rpc_request(
                        "turn/interrupt",
                        {"threadId": thread_id, "turnId": turn_id},
                        timeout=3,
                    )
                except MessengerError:
                    pass

            threading.Thread(target=_interrupt_turn, name="codex-messenger-interrupt", daemon=True).start()
        elif ask_in_progress:
            def _interrupt_startup() -> None:
                with self._start_lock:
                    self._stop_process()

            threading.Thread(
                target=_interrupt_startup,
                name="codex-messenger-reset",
                daemon=True,
            ).start()

    def shutdown(self) -> None:
        self._stop_process()

    def _is_ready(self) -> bool:
        return bool(
            self._proc
            and self._proc.poll() is None
            and self._thread_id
        )

    def _rpc_request(self, method: str, params: dict, *, timeout: float) -> dict:
        proc = self._proc
        if proc is None or proc.poll() is not None or proc.stdin is None:
            raise MessengerError("Codex messenger process is not running")
        with self._state_lock:
            request_id = self._next_request_id
            self._next_request_id += 1
            event = threading.Event()
            self._response_events[request_id] = event
        self._write_json({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        if not event.wait(timeout=max(0.1, timeout)):
            with self._state_lock:
                self._response_events.pop(request_id, None)
                self._responses.pop(request_id, None)
            raise MessengerError(f"Codex messenger {method} timed out")
        with self._state_lock:
            response = self._responses.pop(request_id, {})
            self._response_events.pop(request_id, None)
        if "error" in response:
            message = response.get("error", {}).get("message") or response["error"]
            raise MessengerError(f"Codex messenger {method} failed: {message}")
        return response

    def _rpc_notify(self, method: str, params: dict) -> None:
        self._write_json({"jsonrpc": "2.0", "method": method, "params": params})

    def _write_json(self, payload: dict) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or proc.poll() is not None:
            raise MessengerError("Codex messenger process is not writable")
        try:
            with self._write_lock:
                proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
                proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as exc:
            raise MessengerError(f"could not write to Codex messenger: {exc}") from exc

    def _read_stream(self, proc: subprocess.Popen) -> None:
        try:
            if proc.stdout is None:
                return
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except (json.JSONDecodeError, TypeError):
                    continue
                if isinstance(message, dict):
                    self._handle_message(message)
        except (OSError, ValueError):
            pass
        finally:
            self._fail_pending("Codex messenger process exited", proc=proc)

    def _handle_message(self, message: dict) -> None:
        request_id = message.get("id")
        if isinstance(request_id, int):
            with self._state_lock:
                event = self._response_events.get(request_id)
                if event is not None:
                    self._responses[request_id] = message
                    event.set()
            return

        method = str(message.get("method") or "")
        params = message.get("params")
        if not isinstance(params, dict):
            return
        turn_id = str(params.get("turnId") or "")
        if method == "item/agentMessage/delta" and turn_id:
            delta = str(params.get("delta") or "")
            with self._state_lock:
                self._turn_text[turn_id] = self._turn_text.get(turn_id, "") + delta
            return
        if method == "item/completed" and turn_id:
            item = params.get("item")
            if isinstance(item, dict) and item.get("type") == "agentMessage":
                text = str(item.get("text") or "")
                if text:
                    with self._state_lock:
                        self._turn_text[turn_id] = text
            return
        if method != "turn/completed":
            return

        turn = params.get("turn")
        if not isinstance(turn, dict):
            return
        turn_id = str(turn.get("id") or turn_id)
        if not turn_id:
            return
        final_text = _last_agent_message(turn.get("items"))
        status = str(turn.get("status") or "")
        error = turn.get("error")
        with self._state_lock:
            if final_text:
                self._turn_text[turn_id] = final_text
            if status == "failed" or error:
                self._turn_errors[turn_id] = f"Codex messenger turn failed: {error or status}"
            self._turn_events.setdefault(turn_id, threading.Event()).set()

    def _fail_pending(self, message: str, *, proc: subprocess.Popen | None = None) -> None:
        with self._state_lock:
            if proc is not None and self._proc is not proc:
                return
            for request_id, event in self._response_events.items():
                self._responses[request_id] = {"error": {"message": message}}
                event.set()
            for turn_id, event in self._turn_events.items():
                self._turn_errors[turn_id] = message
                event.set()
            self._thread_id = None
            self._active_turn_id = None
            if proc is not None:
                self._proc = None

    def _stop_process(self) -> None:
        proc = self._proc
        self._proc = None
        self._thread_id = None
        self._active_turn_id = None
        if proc is None:
            return
        try:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()
        except OSError:
            pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
        self._fail_pending("Codex messenger was interrupted")


def _last_agent_message(items) -> str:
    if not isinstance(items, list):
        return ""
    messages = [
        item for item in items
        if isinstance(item, dict) and item.get("type") == "agentMessage" and item.get("text")
    ]
    finals = [item for item in messages if item.get("phase") == "final_answer"]
    selected = (finals or messages)
    return str(selected[-1].get("text") or "") if selected else ""


class ClaudeMessengerBackend:
    """Warm Claude stream-json process with tools and MCP disabled."""

    def __init__(
        self,
        config: MessengerConfig,
        *,
        popen_factory: Callable[..., subprocess.Popen] = subprocess.Popen,
    ):
        self.config = config
        self._popen_factory = popen_factory
        self._proc: subprocess.Popen | None = None
        self._reader_thread: threading.Thread | None = None
        self._start_lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._pending: dict | None = None
        self._session_id: str | None = None

    def spawn_command(self) -> list[str]:
        command = _command_prefix(self.config.command)
        command.extend([
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", self.config.model,
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}',
            "--system-prompt", MESSENGER_SYSTEM_PROMPT,
        ])
        if self.config.effort != "default":
            command.extend(["--effort", self.config.effort])
        if self._session_id:
            command.extend(["--resume", self._session_id])
        return command

    def start(self) -> None:
        with self._start_lock:
            if self._proc and self._proc.poll() is None:
                return
            try:
                proc = self._popen_factory(
                    self.spawn_command(),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                    cwd=self.config.cwd,
                )
            except OSError as exc:
                raise MessengerError(f"could not start Claude messenger: {exc}") from exc
            self._proc = proc
            self._reader_thread = threading.Thread(
                target=self._read_stream,
                args=(proc,),
                name="claude-messenger-reader",
                daemon=True,
            )
            self._reader_thread.start()

    def ask(self, prompt: str, timeout: float = 60.0) -> str:
        self.start()
        pending = {
            "event": threading.Event(),
            "text": "",
            "error": None,
        }
        with self._state_lock:
            self._pending = pending
        payload = {
            "type": "user",
            "message": {"role": "user", "content": prompt},
        }
        try:
            self._write_json(payload)
            if not pending["event"].wait(timeout=max(0.1, timeout)):
                self.interrupt()
                raise MessengerError("Claude messenger response timed out")
            if pending["error"]:
                raise MessengerError(str(pending["error"]))
            return str(pending["text"] or "").strip()
        finally:
            with self._state_lock:
                if self._pending is pending:
                    self._pending = None

    def interrupt(self) -> None:
        with self._state_lock:
            pending = self._pending
            if pending is None:
                return
            proc = self._proc
            self._proc = None
            pending["error"] = "Claude messenger was interrupted"
            pending["event"].set()
        if proc and proc.poll() is None:
            proc.kill()

    def shutdown(self) -> None:
        with self._state_lock:
            pending = self._pending
            proc = self._proc
            self._proc = None
            if pending is not None:
                pending["error"] = "Claude messenger was interrupted"
                pending["event"].set()
        if proc and proc.poll() is None:
            proc.kill()

    def _write_json(self, payload: dict) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or proc.poll() is not None:
            raise MessengerError("Claude messenger process is not writable")
        try:
            with self._write_lock:
                proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
                proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as exc:
            raise MessengerError(f"could not write to Claude messenger: {exc}") from exc

    def _read_stream(self, proc: subprocess.Popen) -> None:
        try:
            if proc.stdout is None:
                return
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except (json.JSONDecodeError, TypeError):
                    continue
                if not isinstance(message, dict):
                    continue
                session_id = message.get("session_id")
                if session_id:
                    self._session_id = str(session_id)
                if message.get("type") != "result":
                    continue
                with self._state_lock:
                    pending = self._pending
                    if pending is None:
                        continue
                    if message.get("is_error"):
                        pending["error"] = message.get("result") or "Claude messenger turn failed"
                    else:
                        pending["text"] = message.get("result") or ""
                    pending["event"].set()
        except (OSError, ValueError):
            pass
        finally:
            with self._state_lock:
                pending = self._pending
                if pending is not None and not pending["event"].is_set():
                    pending["error"] = "Claude messenger process exited"
                    pending["event"].set()
                if self._proc is proc:
                    self._proc = None


@dataclass(frozen=True)
class _MessengerEvent:
    kind: str
    text: str
    command_seq: int
    command_id: str
    generation: int
    detail: str = ""


class MessengerRuntime:
    """Non-blocking event pump shared by both provider backends."""

    def __init__(
        self,
        backend: MessengerBackend,
        *,
        speak: Callable[[str, int, str], object],
        is_current: Callable[[int, str], bool],
        context_limit: int = 16,
        response_timeout: float = 60.0,
    ):
        self.backend = backend
        self._speak = speak
        self._is_current = is_current
        self._events: queue.Queue[_MessengerEvent | None] = queue.Queue()
        self._context: deque[str] = deque(maxlen=max(4, context_limit))
        self._response_timeout = response_timeout
        self._lock = threading.Lock()
        self._generation = 0
        self._current_command: tuple[int, str] | None = None
        self._has_trace_for_current_command = False
        self._started = False
        self._shutdown = threading.Event()
        self._worker_thread: threading.Thread | None = None

    @property
    def context_size(self) -> int:
        with self._lock:
            return len(self._context)

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
            self._worker_thread = threading.Thread(
                target=self._run,
                name="relay-messenger",
                daemon=True,
            )
            self._worker_thread.start()
        threading.Thread(
            target=self._warm_backend,
            name="relay-messenger-warmup",
            daemon=True,
        ).start()

    def submit_user(self, text: str, command: dict) -> bool:
        command_key = _command_key(command)
        cleaned = str(text or "").strip()
        if command_key is None or not cleaned:
            return False
        with self._lock:
            supersedes = self._current_command is not None
            self._generation += 1
            generation = self._generation
            self._current_command = command_key
            self._has_trace_for_current_command = False
            self._context.append(f"USER: {cleaned}")
            self._discard_pending_events_locked()
        if supersedes:
            self.backend.interrupt()
        self._events.put(_MessengerEvent(
            kind="user_turn",
            text=cleaned,
            command_seq=command_key[0],
            command_id=command_key[1],
            generation=generation,
        ))
        return True

    def submit_trace(self, trace: dict) -> bool:
        if not isinstance(trace, dict):
            return False
        command = trace.get("command")
        command_key = _command_key(command if isinstance(command, dict) else None)
        message = str(trace.get("message") or "").strip()
        kind = str(trace.get("kind") or "progress").strip().lower()
        if not message:
            return False
        with self._lock:
            command_key = command_key or self._current_command
            if command_key is None or command_key != self._current_command:
                return False
            self._has_trace_for_current_command = True
            generation = self._generation
            self._context.append(f"ORCHESTRATOR UPDATE ({kind}): {message}")
        self._events.put(_MessengerEvent(
            kind="orchestrator_trace",
            text=message,
            detail=kind,
            command_seq=command_key[0],
            command_id=command_key[1],
            generation=generation,
        ))
        return True

    def submit_final(self, payload: dict) -> bool:
        if not isinstance(payload, dict):
            return False
        nested = payload.get("relay_command")
        command_key = _command_key(nested if isinstance(nested, dict) else payload)
        text = str(payload.get("text") or "").strip()
        if not text:
            return False
        with self._lock:
            command_key = command_key or self._current_command
            if command_key is None or command_key != self._current_command:
                return False
            generation = self._generation
            self._context.append(f"AUTHORITATIVE ORCHESTRATOR FINAL: {text}")
        self._events.put(_MessengerEvent(
            kind="orchestrator_final",
            text=text,
            command_seq=command_key[0],
            command_id=command_key[1],
            generation=generation,
        ))
        return True

    def interrupt(self) -> None:
        with self._lock:
            self._generation += 1
            self._current_command = None
            self._has_trace_for_current_command = False
            self._discard_pending_events_locked()
        self.backend.interrupt()

    def shutdown(self) -> None:
        if self._shutdown.is_set():
            return
        self._shutdown.set()
        self.backend.interrupt()
        self._events.put(None)
        worker = self._worker_thread
        if worker and worker is not threading.current_thread():
            worker.join(timeout=2)
        self.backend.shutdown()

    def _warm_backend(self) -> None:
        try:
            self.backend.start()
            if self._shutdown.is_set():
                self.backend.shutdown()
                return
            print("[messenger] persistent model process is warm", file=sys.stderr)
        except Exception as exc:
            print(f"[messenger] warmup deferred after startup failure: {exc}", file=sys.stderr)

    def _run(self) -> None:
        while not self._shutdown.is_set():
            event = self._events.get()
            if event is None:
                return
            if not self._event_is_current(event):
                continue
            prompt = self._prompt_for(event)
            try:
                response = self.backend.ask(prompt, timeout=self._response_timeout).strip()
            except Exception as exc:
                print(f"[messenger] response failed: {exc}", file=sys.stderr)
                if event.kind == "orchestrator_final" and self._event_is_current(event):
                    self._speak_safely(event.text, event.command_seq, event.command_id)
                continue
            if not self._event_is_current(event):
                continue
            if not response or response == SILENT_RESPONSE:
                if event.kind == "orchestrator_final":
                    self._speak_safely(event.text, event.command_seq, event.command_id)
                continue
            with self._lock:
                self._context.append(f"MESSENGER: {response}")
            self._speak_safely(response, event.command_seq, event.command_id)

    def _event_is_current(self, event: _MessengerEvent) -> bool:
        with self._lock:
            current = (
                event.generation == self._generation
                and self._current_command == (event.command_seq, event.command_id)
            )
        return current and self._is_current(event.command_seq, event.command_id)

    def _prompt_for(self, event: _MessengerEvent) -> str:
        with self._lock:
            context = "\n".join(self._context)
        instructions = {
            "user_turn": (
                "This is a new user turn delivered simultaneously to you and the authoritative "
                "orchestrator. If it is lightweight social conversation that needs no "
                "orchestration, reply naturally. If it is a work request or substantive "
                "question that should be handed off, give a brief contextual acknowledgement "
                "that reflects the request, explicitly uses the word orchestrator, says the "
                "orchestrator received or picked it up, and says the orchestrator will return "
                "with a plan or next step. Do not describe receipt as only you or we picking it "
                "up. Do not invent scope or "
                "claim that a ticket, worker, or implementation already exists."
            ),
            "orchestrator_trace": (
                "This is a provider-visible public progress summary from the orchestrator. Use it "
                "with the user turn to decide whether a brief spoken update is useful."
            ),
            "orchestrator_final": (
                "This is the authoritative orchestrator reply. Convey its outcome naturally and "
                "concisely without adding unsupported claims."
            ),
        }[event.kind]
        if event.kind == "orchestrator_trace" and event.detail == "clarification-request":
            instructions = (
                "This is an authoritative clarification request from the orchestrator. Ask the "
                "user the requested question directly and concisely."
            )
        return (
            f"{instructions}\n\n"
            "Recent session context, oldest to newest:\n"
            f"{context}\n\n"
            f"Current event: {event.kind}\n"
            "Return only the exact words to speak, or __SILENT__."
        )

    def _discard_pending_events_locked(self) -> None:
        while True:
            try:
                queued = self._events.get_nowait()
            except queue.Empty:
                return
            if queued is None:
                self._events.put(None)
                return

    def _speak_safely(self, text: str, command_seq: int, command_id: str) -> None:
        try:
            self._speak(text, command_seq, command_id)
        except Exception as exc:
            print(f"[messenger] could not queue speech: {exc}", file=sys.stderr)


def _command_key(command: dict | None) -> tuple[int, str] | None:
    if not isinstance(command, dict):
        return None
    command_id = str(command.get("relay_command_id") or "").strip()
    try:
        command_seq = int(command.get("relay_command_seq"))
    except (TypeError, ValueError):
        return None
    return (command_seq, command_id) if command_id else None


def create_messenger_runtime(
    app_config: dict,
    *,
    speak: Callable[[str, int, str], object],
    is_current: Callable[[int, str], bool],
    cwd: str | os.PathLike[str] | None = None,
) -> MessengerRuntime | None:
    config = MessengerConfig.from_app_config(app_config, cwd=cwd)
    if not config.enabled:
        print("[messenger] disabled by config", file=sys.stderr)
        return None
    resolved_command = resolve_messenger_command(config.provider, config.command)
    if resolved_command is None:
        executable = _command_prefix(config.command)[0]
        print(f"[messenger] provider command not found: {executable}", file=sys.stderr)
        return None
    config = replace(config, command=shlex.join(resolved_command))
    backend: MessengerBackend
    if config.provider == "claude":
        backend = ClaudeMessengerBackend(config)
    else:
        backend = CodexMessengerBackend(config)
    return MessengerRuntime(backend, speak=speak, is_current=is_current)
