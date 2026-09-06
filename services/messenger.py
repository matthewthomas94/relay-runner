#!/usr/bin/env python3
"""Persistent, provider-neutral voice messenger for Relay sessions.

The messenger is deliberately narrower than the foreground agent: it cannot
plan work or use tools. It turns user speech plus public orchestrator progress
events into short conversational replies while the foreground Codex or Claude
session remains authoritative.
"""

from __future__ import annotations

import inspect
import json
import os
import queue
import re
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

from continuity_incidents import normalize_recovery_generation

from codex_model_catalog import (
    CODEX_FAMILIES,
    CODEX_MESSENGER_DEFAULT_FAMILY,
    CodexModelResolutionError,
    codex_family_for_model,
    normalize_codex_family,
    resolve_codex_effort,
    resolve_codex_family_from_cli,
)
from command_actions import is_relay_runner_self_explanation
from pm_frontstage import LIFECYCLE_DETAIL_TRACE_KINDS

CODEX_DEFAULT_MODEL = CODEX_MESSENGER_DEFAULT_FAMILY
CODEX_DEFAULT_EFFORT = "low"
CLAUDE_DEFAULT_MODEL = "haiku"
CLAUDE_DEFAULT_EFFORT = "default"
SILENT_RESPONSE = "__SILENT__"
MESSENGER_DEGRADED_TEXT = (
    "I couldn't produce a fast response, but your request is still with the "
    "foreground session."
)
RELAY_RUNNER_DEMO_EXPLANATION = (
    "Relay Runner is a local macOS workspace that turns natural conversation "
    "into visible, coordinated software work. It organizes requests into tickets, "
    "runs coding agents in isolated workspaces, and tracks progress through testing, "
    "review, and integration."
)
_REALIZATION_DECISIONS = frozenset({"full", "delta", "suppress"})
_PROTECTED_LIFECYCLE_ROLES = frozenset({"result", "failure", "blocker", "decision"})
_LIFECYCLE_ROLES_BY_DETAIL = {
    "clarification-request": "decision",
    "run-canceled": "failure",
    "run-failed": "failure",
    "run-health-warning": "blocker",
    "run-review-needed": "blocker",
    "run-reconciled": "result",
    "run-integration-blocked": "blocker",
    "run-verification-blocked": "blocker",
    "run-verification-resumed": "decision",
    "run-merged": "result",
    "run-succeeded": "result",
    "sidecar-outcome": "result",
}
_SEMANTIC_TOKEN_RE = re.compile(r"[a-z0-9]+(?:[-_.:/][a-z0-9]+)*", re.IGNORECASE)
_USER_RESPONSE_ROLE_RE = re.compile(
    r"^__(?P<role>ANSWER|HANDOFF)__\s*(?::|-)?\s*",
    re.IGNORECASE,
)
_HANDOFF_RESPONSE_RE = re.compile(
    r"\b(?:"
    r"(?:received|picked\s+up|understood)\b.{0,100}\b(?:request|task|question)"
    r"|(?:i|we)\s+(?:will|(?:'|’)ll|am\s+going\s+to|are\s+going\s+to)\s+"
    r"(?:check|confirm|find|inspect|investigate|look|open|report|review|run|use|verify)"
    r"|(?:come|get)\s+back\b|report\s+back\b|return\s+with\b"
    r")",
    re.IGNORECASE,
)
_SEMANTIC_STOPWORDS = frozenset({
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "for",
    "from", "i", "in", "is", "it", "me", "my", "of", "on", "or", "our",
    "so", "that", "the", "their", "them", "they", "this", "to", "was", "we",
    "were", "with", "you", "your", "youre",
})
CODEX_CLI_CANDIDATES = (
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
)
CLAUDE_CLI_CANDIDATES = (
    "~/.local/bin/claude",
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
)

_CODEX_MODELS = CODEX_FAMILIES
_CLAUDE_MODELS = frozenset({"best", "claude-fable-5-1", "fable", "opus", "sonnet", "haiku"})
_BASE_EFFORTS = frozenset({"default", "low", "medium", "high", "xhigh"})
_UNSCOPED_LIFECYCLE_KINDS = LIFECYCLE_DETAIL_TRACE_KINDS
_WORK_LIFECYCLE_KINDS = frozenset({"sidecar-outcome"})
_PROMPT_CONTEXT_ENTRY_LIMIT = 4
_PROMPT_CONTEXT_ENTRY_CHAR_LIMIT = 640


def _first_semantic_response(text: str, *, complete: bool = False) -> str | None:
    """Return the first speakable sentence without exposing partial token noise."""
    cleaned = " ".join(str(text or "").split()).strip()
    if not cleaned or cleaned == SILENT_RESPONSE:
        return None
    for boundary in re.finditer(r"[.!?](?:[\"'’])?(?=\s|$)", cleaned):
        candidate = cleaned[:boundary.end()]
        if len(_SEMANTIC_TOKEN_RE.findall(candidate)) >= 3:
            return candidate
    if complete and len(_SEMANTIC_TOKEN_RE.findall(cleaned)) >= 3:
        return cleaned
    return None


def _user_response_role(text: str, *, action_kind: str) -> tuple[str, str]:
    """Return speakable text and whether it answers now or promises a handoff."""
    cleaned = " ".join(str(text or "").split()).strip()
    marker = _USER_RESPONSE_ROLE_RE.match(cleaned)
    explicit_role = marker.group("role").lower() if marker is not None else ""
    if marker is not None:
        cleaned = cleaned[marker.end():].strip()
    if action_kind == "self_explanation":
        return cleaned, "answer"
    if explicit_role == "handoff" or _HANDOFF_RESPONSE_RE.search(cleaned):
        return cleaned, "handoff"
    if explicit_role == "answer" or action_kind == "conversation":
        return cleaned, "answer"
    return cleaned, "handoff"

FOREGROUND_ONLY_ENVIRONMENT_KEYS = frozenset({
    "RELAY_CONTEXT_COMPACTION_EVENTS",
    "RELAY_FOREGROUND_GATE_HANDLE",
    "RELAY_PROVIDER_SESSION_ID",
    "RELAY_RECOVERY_GENERATION",
    "RELAY_REPLY_HELPER",
    "RELAY_RUNNER_APP_SESSION",
    "RELAY_SESSION_EVENTS",
    "VOICE_COMMAND_CLAIM_FILE",
    "VOICE_COMMAND_STATE_FILE",
    "VOICE_PROVIDER_TURNS_FILE",
})


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

Because you speak on behalf of the authoritative foreground orchestrator, use
first-person singular language such as "I" and "me" for its receipt, planning,
progress, and outcomes. Do not call it "the orchestrator" in user-facing speech.
If an authoritative event identifies a worker or workers, refer to them directly
as the worker or workers instead of folding their actions into "I".

For a new work request or substantive question that should be handed off, give a
brief contextual acknowledgement that reflects the request, says you received
or picked it up, confirms the immediate next step, and says you will return with
the result or a decision request. Keep that handoff to one short spoken sentence
so it can be delivered as soon as the sentence is complete. Do not claim that a
ticket, worker, or implementation exists unless a later authoritative event says
so. The notch already provides deterministic visual receipt, so do not add a
canned spoken acknowledgement that ignores the user's actual request.
You may answer lightweight social conversation when no orchestration is needed.
Keep those direct social answers to one short spoken sentence so their complete
meaning can be delivered on the first semantic boundary.
For every user turn, make the first complete sentence semantically specific and
use at most twelve spoken words whenever the full meaning can be preserved. End
it promptly with sentence punctuation; never cut off a negation, qualifier,
identifier, result, or required next-step promise merely to meet this length.
For every new user turn, prefix the response with exactly __ANSWER__ when those
words fully answer the user now, or __HANDOFF__ when they acknowledge the turn
and promise a later result. The prefix is delivery metadata and will not be
spoken. Never label a promise to check, inspect, use a tool, report back, or
return with a result as __ANSWER__.
When the user asks what Relay Runner is, what it does, or requests a short
introduction for a demo audience, answer immediately in one or two natural
sentences. Do not hand that request off or promise a later answer. Describe Relay
Runner as a local macOS workspace that turns natural conversation into visible,
coordinated software work through tickets, isolated agent workspaces, and tracked
testing, review, and integration.
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
    if provider == "codex":
        known_codex_selection = (
            raw_model in {"", "default"}
            or raw_model in _CODEX_MODELS
            or codex_family_for_model(raw_model) is not None
            or raw_model.startswith("gpt-")
        )
        model = normalize_codex_family(raw_model, default_family=default_model)
        if not known_codex_selection:
            raw_effort = default_effort
    elif raw_model == "default":
        return defaults
    elif raw_model in _CLAUDE_MODELS:
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
        return _BASE_EFFORTS | {"max", "ultra"}
    if model in {"best", "claude-fable-5-1", "fable", "opus"}:
        return _BASE_EFFORTS | {"max"}
    if model == "sonnet":
        return frozenset({"default", "low", "medium", "high", "max"})
    return frozenset({"default"})


def resolve_messenger_catalog_selection(config: MessengerConfig) -> MessengerConfig:
    if config.provider != "codex":
        return config
    family = normalize_codex_family(config.model, default_family=CODEX_MESSENGER_DEFAULT_FAMILY)
    resolved = resolve_codex_family_from_cli(family, command=config.command)
    effort = resolve_codex_effort(config.effort, resolved)
    return replace(config, model=resolved.launch_model, effort=effort)


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


def provider_child_environment(
    actor_role: str,
    *,
    parent: dict[str, str] | None = None,
) -> dict[str, str]:
    """Return a provider environment without foreground voice authority."""
    environment = dict(os.environ if parent is None else parent)
    for key in FOREGROUND_ONLY_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    environment["RELAY_ACTOR_ROLE"] = actor_role
    return environment


class MessengerBackend(Protocol):
    def start(self) -> None: ...
    def ask(
        self,
        prompt: str,
        timeout: float = 60.0,
        on_partial: Callable[[str], object] | None = None,
    ) -> str: ...
    def interrupt(self) -> None: ...
    def shutdown(self) -> None: ...


class UnavailableMessengerBackend:
    """Provider-neutral sentinel that keeps degraded delivery command-scoped."""

    actor_role = "messenger"

    def __init__(self, config: MessengerConfig, reason: str):
        self.config = config
        self.reason = reason

    def start(self) -> None:
        raise MessengerError(self.reason)

    def ask(
        self,
        prompt: str,
        timeout: float = 60.0,
        on_partial: Callable[[str], object] | None = None,
    ) -> str:
        del prompt, timeout, on_partial
        raise MessengerError(self.reason)

    def interrupt(self) -> None:
        pass

    def shutdown(self) -> None:
        pass


class CodexMessengerBackend:
    """Warm Codex app-server process with one ephemeral messenger thread."""

    actor_role = "messenger"

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
        self._turn_partial_callbacks: dict[str, Callable[[str], object]] = {}
        self._pending_partial_callback: Callable[[str], object] | None = None
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
            "dynamicTools": [],
            "environments": [],
            "runtimeWorkspaceRoots": [],
            "selectedCapabilityRoots": [],
            "ephemeral": True,
        }

    def child_environment(self) -> dict[str, str]:
        return provider_child_environment(self.actor_role)

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
                    env=self.child_environment(),
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

    def ask(
        self,
        prompt: str,
        timeout: float = 60.0,
        on_partial: Callable[[str], object] | None = None,
    ) -> str:
        self.start()
        thread_id = self._thread_id
        if not thread_id:
            raise MessengerError("Codex messenger is not ready")

        with self._state_lock:
            self._ask_in_progress = True
            self._pending_partial_callback = on_partial
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
                callback = self._pending_partial_callback
                self._pending_partial_callback = None
                if callback is not None:
                    self._turn_partial_callbacks[turn_id] = callback
                event = self._turn_events.setdefault(turn_id, threading.Event())
                if turn_id in self._turn_text or turn_id in self._turn_errors:
                    event.set()
                partial = self._take_partial_locked(turn_id, complete=False)
            self._emit_partial(partial)
            if not event.wait(timeout=max(0.1, timeout)):
                self.interrupt()
                raise MessengerError("Codex messenger response timed out")
            with self._state_lock:
                error = self._turn_errors.pop(turn_id, None)
                text = self._turn_text.pop(turn_id, "")
                self._turn_events.pop(turn_id, None)
                self._turn_partial_callbacks.pop(turn_id, None)
                if self._active_turn_id == turn_id:
                    self._active_turn_id = None
            if error:
                raise MessengerError(error)
            return text.strip()
        finally:
            with self._state_lock:
                self._ask_in_progress = False
                self._pending_partial_callback = None

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
                    self._handle_message(message, proc=proc)
        except (OSError, ValueError):
            pass
        finally:
            self._fail_pending("Codex messenger process exited", proc=proc)

    def _handle_message(
        self,
        message: dict,
        *,
        proc: subprocess.Popen | None = None,
    ) -> None:
        if proc is not None:
            with self._state_lock:
                if self._proc is not proc:
                    return
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
                partial = self._take_partial_locked(turn_id, complete=False)
            self._emit_partial(partial)
            return
        if method == "item/completed" and turn_id:
            item = params.get("item")
            if isinstance(item, dict) and item.get("type") == "agentMessage":
                text = str(item.get("text") or "")
                if text:
                    with self._state_lock:
                        self._turn_text[turn_id] = text
                        partial = self._take_partial_locked(turn_id, complete=True)
                    self._emit_partial(partial)
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
            partial = self._take_partial_locked(turn_id, complete=True)
            if status == "failed" or error:
                self._turn_errors[turn_id] = f"Codex messenger turn failed: {error or status}"
            self._turn_events.setdefault(turn_id, threading.Event()).set()
        self._emit_partial(partial)

    def _take_partial_locked(
        self,
        turn_id: str,
        *,
        complete: bool,
    ) -> tuple[Callable[[str], object], str] | None:
        callback = self._turn_partial_callbacks.get(turn_id)
        response = _first_semantic_response(
            self._turn_text.get(turn_id, ""),
            complete=complete,
        )
        if callback is None or response is None:
            return None
        self._turn_partial_callbacks.pop(turn_id, None)
        return callback, response

    @staticmethod
    def _emit_partial(
        pending: tuple[Callable[[str], object], str] | None,
    ) -> None:
        if pending is None:
            return
        callback, response = pending
        try:
            callback(response)
        except Exception:
            pass

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
            self._turn_partial_callbacks.clear()
            self._pending_partial_callback = None
            if proc is not None:
                self._proc = None

    def _stop_process(self) -> None:
        proc = self._proc
        self._proc = None
        self._thread_id = None
        self._active_turn_id = None
        self._pending_partial_callback = None
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

    actor_role = "messenger"

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

    def child_environment(self) -> dict[str, str]:
        return provider_child_environment(self.actor_role)

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
                    env=self.child_environment(),
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

    def ask(
        self,
        prompt: str,
        timeout: float = 60.0,
        on_partial: Callable[[str], object] | None = None,
    ) -> str:
        self.start()
        proc = self._proc
        if proc is None or proc.poll() is not None:
            raise MessengerError("Claude messenger is not ready")
        pending = {
            "event": threading.Event(),
            "text": "",
            "error": None,
            "on_partial": on_partial,
            "partial_delivered": False,
            "process": proc,
        }
        with self._state_lock:
            self._pending = pending
        payload = {
            "type": "user",
            "message": {"role": "user", "content": prompt},
        }
        try:
            self._write_json(payload, proc=proc)
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

    def _write_json(
        self,
        payload: dict,
        *,
        proc: subprocess.Popen | None = None,
    ) -> None:
        current_proc = self._proc
        if proc is not None and current_proc is not proc:
            raise MessengerError("Claude messenger process was superseded")
        proc = current_proc
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
                with self._state_lock:
                    if self._proc is not proc:
                        return
                session_id = message.get("session_id")
                if session_id:
                    self._session_id = str(session_id)
                if message.get("type") == "stream_event":
                    stream_event = message.get("event")
                    delta = stream_event.get("delta") if isinstance(stream_event, dict) else None
                    if (
                        isinstance(stream_event, dict)
                        and stream_event.get("type") == "content_block_delta"
                        and isinstance(delta, dict)
                        and delta.get("type") == "text_delta"
                    ):
                        self._append_partial(
                            proc,
                            str(delta.get("text") or ""),
                            complete=False,
                        )
                    continue
                if message.get("type") == "assistant":
                    assistant = message.get("message")
                    content = assistant.get("content") if isinstance(assistant, dict) else None
                    if isinstance(content, list):
                        text = "".join(
                            str(block.get("text") or "")
                            for block in content
                            if isinstance(block, dict) and block.get("type") == "text"
                        )
                        if text:
                            self._set_partial(proc, text, complete=False)
                    continue
                if message.get("type") != "result":
                    continue
                with self._state_lock:
                    pending = self._pending
                    if (
                        self._proc is not proc
                        or pending is None
                        or pending.get("process") is not proc
                    ):
                        continue
                    if message.get("is_error"):
                        pending["error"] = message.get("result") or "Claude messenger turn failed"
                    else:
                        pending["text"] = message.get("result") or ""
                        partial = self._take_claude_partial_locked(pending, complete=True)
                    pending["event"].set()
                if not message.get("is_error"):
                    self._emit_claude_partial(partial)
        except (OSError, ValueError):
            pass
        finally:
            with self._state_lock:
                if self._proc is proc:
                    pending = self._pending
                    if (
                        pending is not None
                        and pending.get("process") is proc
                        and not pending["event"].is_set()
                    ):
                        pending["error"] = "Claude messenger process exited"
                        pending["event"].set()
                    self._proc = None

    def _append_partial(
        self,
        proc: subprocess.Popen,
        text: str,
        *,
        complete: bool,
    ) -> None:
        if not text:
            return
        with self._state_lock:
            pending = self._pending
            if (
                self._proc is not proc
                or pending is None
                or pending.get("process") is not proc
            ):
                return
            pending["text"] = str(pending.get("text") or "") + text
            partial = self._take_claude_partial_locked(pending, complete=complete)
        self._emit_claude_partial(partial)

    def _set_partial(
        self,
        proc: subprocess.Popen,
        text: str,
        *,
        complete: bool,
    ) -> None:
        with self._state_lock:
            pending = self._pending
            if (
                self._proc is not proc
                or pending is None
                or pending.get("process") is not proc
            ):
                return
            pending["text"] = text
            partial = self._take_claude_partial_locked(pending, complete=complete)
        self._emit_claude_partial(partial)

    @staticmethod
    def _take_claude_partial_locked(
        pending: dict,
        *,
        complete: bool,
    ) -> tuple[Callable[[str], object], str] | None:
        if pending.get("partial_delivered"):
            return None
        callback = pending.get("on_partial")
        response = _first_semantic_response(
            str(pending.get("text") or ""),
            complete=complete,
        )
        if not callable(callback) or response is None:
            return None
        pending["partial_delivered"] = True
        return callback, response

    @staticmethod
    def _emit_claude_partial(
        partial: tuple[Callable[[str], object], str] | None,
    ) -> None:
        if partial is None:
            return
        callback, response = partial
        try:
            callback(response)
        except Exception:
            pass


@dataclass(frozen=True)
class _MessengerEvent:
    kind: str
    text: str
    command_seq: int | None
    command_id: str | None
    generation: int
    detail: str = ""
    work_disposition: dict | None = None
    speech_source: str = ""
    work_lifecycle: bool = False
    action_kind: str = ""


@dataclass(frozen=True)
class _SpeechRealization:
    decision: str
    spoken_text: str
    lifecycle_role: str
    covered_facts: tuple[str, ...]
    reason: str


class MessengerRuntime:
    """Non-blocking event pump shared by both provider backends."""

    def __init__(
        self,
        backend: MessengerBackend,
        *,
        speak: Callable[..., object],
        is_current: Callable[[int, str], bool],
        context_limit: int = 16,
        response_timeout: float = 60.0,
        coverage_provider: Callable[[int, str], object] | None = None,
        realization_observer: Callable[..., object] | None = None,
        continuity_observer: Callable[[dict], object] | None = None,
        timing_observer: Callable[..., object] | None = None,
        recovery_generation: str = "0",
    ):
        self.backend = backend
        self._speak = speak
        self._speak_accepts_display = self._callable_accepts_display_text(speak)
        self._speak_accepts_metadata = self._callable_accepts_speech_metadata(speak)
        self._is_current = is_current
        self._events: queue.Queue[_MessengerEvent | None] = queue.Queue()
        self._context: deque[str] = deque(maxlen=max(4, context_limit))
        self._response_timeout = response_timeout
        self._coverage_provider = coverage_provider
        self._realization_observer = realization_observer
        self._continuity_observer = continuity_observer
        self._timing_observer = timing_observer
        self._recovery_generation = normalize_recovery_generation(recovery_generation)
        self._coverage_error_events: set[tuple[int, int, str]] = set()
        self._lock = threading.Lock()
        self._generation = 0
        self._current_command: tuple[int, str] | None = None
        self._has_trace_for_current_command = False
        self._final_commands: set[tuple[int, str]] = set()
        self._active_event: _MessengerEvent | None = None
        self._action_kinds: dict[tuple[int, str], str] = {}
        self._work_dispositions: dict[tuple[int, str], dict] = {}
        self._user_response_texts: dict[tuple[int, str], str] = {}
        self._user_response_roles: dict[tuple[int, str], str] = {}
        self._conversation_commands_answered: set[tuple[int, str]] = set()
        self._started = False
        self._shutdown = threading.Event()
        self._worker_thread: threading.Thread | None = None
        self._recovery_lock = threading.Lock()

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
        disposition = command.get("work_disposition")
        if not isinstance(disposition, dict):
            disposition = None
        with self._lock:
            supersedes = self._current_command is not None
            self._generation += 1
            generation = self._generation
            self._current_command = command_key
            route = str((disposition or {}).get("route") or "").strip().lower()
            action_kind = (
                "self_explanation"
                if is_relay_runner_self_explanation(cleaned)
                else (
                    "conversation"
                    if route == "continue_current"
                    else "work" if route else "pending"
                )
            )
            self._action_kinds[command_key] = action_kind
            if disposition:
                self._work_dispositions[command_key] = disposition
            if len(self._action_kinds) > 100:
                for old in list(self._action_kinds)[:50]:
                    self._action_kinds.pop(old, None)
                    self._work_dispositions.pop(old, None)
                    self._user_response_texts.pop(old, None)
                    self._user_response_roles.pop(old, None)
                    self._conversation_commands_answered.discard(old)
            self._has_trace_for_current_command = False
            self._context.append(f"USER: {cleaned}")
            if disposition:
                self._context.append(
                    "PUBLIC WORK DISPOSITION: "
                    f"{disposition.get('route')} — {disposition.get('public_reason')}"
                )
            self._discard_pending_events_locked()
        if supersedes:
            self.backend.interrupt()
        self._observe_timing("messenger_submitted", command_key[0], command_key[1])
        self._events.put(_MessengerEvent(
            kind="user_turn",
            text=cleaned,
            command_seq=command_key[0],
            command_id=command_key[1],
            generation=generation,
            detail=str((disposition or {}).get("route") or ""),
            work_disposition=disposition,
            action_kind=action_kind,
        ))
        return True

    def update_user_context(self, command: dict) -> bool:
        """Attach deterministic routing context without delaying Messenger start."""
        command_key = _command_key(command)
        disposition = command.get("work_disposition") if isinstance(command, dict) else None
        if command_key is None or not isinstance(disposition, dict):
            return False
        route = str(disposition.get("route") or "").strip().lower()
        source_text = str(command.get("source_text") or "").strip()
        with self._lock:
            if command_key != self._current_command:
                return False
            self._action_kinds[command_key] = (
                "self_explanation"
                if is_relay_runner_self_explanation(source_text)
                else "conversation" if route == "continue_current" else "work"
            )
            self._work_dispositions[command_key] = dict(disposition)
            response_text = self._user_response_texts.get(command_key)
            if response_text is not None:
                _, response_role = _user_response_role(
                    response_text,
                    action_kind=self._action_kinds[command_key],
                )
                self._user_response_roles[command_key] = response_role
            if (
                self._action_kinds[command_key] == "conversation"
                and self._user_response_roles.get(command_key) == "answer"
            ):
                self._conversation_commands_answered.add(command_key)
            else:
                self._conversation_commands_answered.discard(command_key)
            self._context.append(
                "PUBLIC WORK DISPOSITION: "
                f"{disposition.get('route')} — {disposition.get('public_reason')}"
            )
        return True

    def submit_trace(self, trace: dict) -> bool:
        if not isinstance(trace, dict):
            return False
        command = trace.get("command")
        command_key = _command_key(command if isinstance(command, dict) else None)
        kind = str(trace.get("kind") or "progress").strip().lower()
        summary = str(trace.get("message") or "").strip()
        detail = str(trace.get("lifecycle_detail") or "").strip()
        message = detail or summary
        work_lifecycle = (
            kind in _WORK_LIFECYCLE_KINDS
            and trace.get("work_valid") is True
        )
        disposition = trace.get("work_disposition")
        if not isinstance(disposition, dict):
            disposition = None
        if not message:
            return False
        with self._lock:
            if work_lifecycle:
                if command_key is None:
                    return False
                if command_key in self._final_commands:
                    return True
                self._final_commands.add(command_key)
                if len(self._final_commands) > 100:
                    for old in list(self._final_commands)[:50]:
                        self._final_commands.discard(old)
                generation = self._generation
                self._context.append(f"AUTHORITATIVE WORK LIFECYCLE ({kind}): {message}")
            elif command_key is None and kind in _UNSCOPED_LIFECYCLE_KINDS:
                generation = self._generation
                self._context.append(f"WORKER LIFECYCLE ({kind}): {message}")
            else:
                command_key = command_key or self._current_command
                if command_key is None or command_key != self._current_command:
                    return False
                self._has_trace_for_current_command = True
                generation = self._generation
                self._context.append(f"ORCHESTRATOR UPDATE ({kind}): {message}")
                if kind == "clarification-request":
                    self._discard_pending_kinds_locked({"orchestrator_trace"})
        self._events.put(_MessengerEvent(
            kind="orchestrator_trace",
            text=message,
            detail=kind,
            command_seq=command_key[0] if command_key is not None else None,
            command_id=command_key[1] if command_key is not None else None,
            generation=generation,
            work_disposition=disposition,
            work_lifecycle=work_lifecycle,
        ))
        return True

    def submit_final(self, payload: dict) -> bool:
        if not isinstance(payload, dict):
            return False
        nested = payload.get("relay_command")
        command_key = _command_key(nested if isinstance(nested, dict) else payload)
        text = str(payload.get("text") or "").strip()
        disposition = payload.get("work_disposition")
        if not isinstance(disposition, dict):
            disposition = None
        if not text:
            return False
        interrupt_handoff = False
        with self._lock:
            command_key = command_key or self._current_command
            if command_key is None or command_key != self._current_command:
                return False
            if command_key in self._final_commands:
                return True
            if (
                self._action_kinds.get(command_key) == "self_explanation"
                or command_key in self._conversation_commands_answered
            ):
                self._final_commands.add(command_key)
                self._context.append(f"AUTHORITATIVE ORCHESTRATOR FINAL: {text}")
                return True
            self._final_commands.add(command_key)
            if len(self._final_commands) > 100:
                for old in list(self._final_commands)[:50]:
                    self._final_commands.discard(old)
            active = self._active_event
            interrupt_handoff = (
                active is not None
                and active.kind == "user_turn"
                and (active.command_seq, active.command_id) == command_key
            )
            self._generation += 1
            generation = self._generation
            self._context.append(f"AUTHORITATIVE ORCHESTRATOR FINAL: {text}")
            self._discard_pending_kinds_locked({"user_turn", "orchestrator_trace"})
        if interrupt_handoff:
            self.backend.interrupt()
        event = _MessengerEvent(
            kind="orchestrator_final",
            text=text,
            command_seq=command_key[0],
            command_id=command_key[1],
            generation=generation,
            work_disposition=disposition,
            speech_source=str(payload.get("speech_source") or "orchestrator"),
            action_kind=self._action_kinds.get(command_key, ""),
        )
        if not self._event_is_current(event):
            return False
        realization = _SpeechRealization(
            "full",
            text,
            self._lifecycle_role_for(event),
            (text,),
            "authoritative_final_direct",
        )
        self._observe_realization(event, realization)
        self._speak_safely(
            text,
            event.command_seq,
            event.command_id,
            display_text=text,
            speech_metadata=self._speech_metadata_for(
                event,
                realization=realization,
                spoken_text=text,
            ),
        )
        return True

    def interrupt(self) -> None:
        with self._lock:
            self._generation += 1
            self._current_command = None
            self._has_trace_for_current_command = False
            self._discard_pending_events_locked()
        self.backend.interrupt()

    def recover_backend(self) -> bool:
        """Recreate a dead provider backend without interrupting queued or live work."""
        with self._recovery_lock:
            with self._lock:
                if (
                    self._shutdown.is_set()
                    or self._active_event is not None
                    or not self._events.empty()
                ):
                    return False
                self.backend.shutdown()
            threading.Thread(
                target=self._warm_backend,
                name="relay-messenger-recovery",
                daemon=True,
            ).start()
            return True

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
            self._observe_continuity("progress")
            print("[messenger] persistent model process is warm", file=sys.stderr)
        except Exception as exc:
            self._observe_continuity("failed")
            print(f"[messenger] warmup deferred after startup failure: {exc}", file=sys.stderr)

    def _run(self) -> None:
        while not self._shutdown.is_set():
            event = self._events.get()
            if event is None:
                return
            if not self._event_is_current(event):
                continue
            prompt = self._prompt_for(event)
            with self._lock:
                self._active_event = event
            delivered_early = threading.Event()

            def deliver_partial(
                response: str,
                bound_event: _MessengerEvent = event,
                delivery_guard: threading.Event = delivered_early,
            ) -> None:
                if delivery_guard.is_set() or not self._event_is_current(bound_event):
                    return
                delivery_guard.set()
                self._observe_timing(
                    "messenger_first_semantic_output",
                    bound_event.command_seq,
                    bound_event.command_id,
                )
                self._deliver_response(bound_event, response)

            try:
                self._observe_continuity("progress", event)
                if event.kind == "user_turn":
                    self._observe_timing(
                        "messenger_provider_started",
                        event.command_seq,
                        event.command_id,
                    )
                if event.kind == "user_turn" and self._backend_accepts_partial():
                    response = self.backend.ask(
                        prompt,
                        timeout=self._response_timeout,
                        on_partial=deliver_partial,
                    ).strip()
                else:
                    response = self.backend.ask(prompt, timeout=self._response_timeout).strip()
            except Exception as exc:
                self._observe_continuity("failed", event)
                if event.kind == "user_turn":
                    self._observe_timing(
                        "messenger_failed",
                        event.command_seq,
                        event.command_id,
                        outcome="provider_unavailable",
                    )
                print(f"[messenger] response failed: {exc}", file=sys.stderr)
                if (
                    (event.kind == "user_turn" or self._must_fail_open(event))
                    and self._event_is_current(event)
                ):
                    realization = self._fallback_realization(event, "arbitration_error")
                    self._observe_realization(event, realization)
                    self._speak_safely(
                        realization.spoken_text,
                        event.command_seq,
                        event.command_id,
                        display_text=event.text,
                        speech_metadata=self._speech_metadata_for(
                            event,
                            fallback=True,
                            realization=realization,
                        ),
                    )
                continue
            finally:
                with self._lock:
                    if self._active_event is event:
                        self._active_event = None
            self._observe_continuity("progress", event)
            if not self._event_is_current(event):
                continue
            if delivered_early.is_set():
                continue
            if not response or response == SILENT_RESPONSE:
                if self._must_fail_open(event) or event.kind == "user_turn":
                    realization = self._fallback_realization(event, "arbitration_unavailable")
                    self._observe_realization(event, realization)
                    self._speak_safely(
                        realization.spoken_text,
                        event.command_seq,
                        event.command_id,
                        display_text=event.text,
                        speech_metadata=self._speech_metadata_for(
                            event,
                            fallback=True,
                            realization=realization,
                        ),
                    )
                continue
            if event.kind == "user_turn":
                self._observe_timing(
                    "messenger_first_semantic_output",
                    event.command_seq,
                    event.command_id,
                )
            self._deliver_response(event, response)

    def _deliver_response(self, event: _MessengerEvent, response: str) -> None:
        if not self._event_is_current(event):
            return
        user_response_role = ""
        raw_response = response
        if event.kind == "user_turn":
            action_kind = self._action_kinds.get(
                (event.command_seq, event.command_id),
                event.action_kind,
            )
            response, user_response_role = _user_response_role(
                response,
                action_kind=action_kind,
            )
        realization = self._realization_for(event, response)
        if realization is not None:
            self._observe_realization(event, realization)
            if realization.decision == "suppress":
                return
            response = realization.spoken_text
        if not response or response == SILENT_RESPONSE:
            return
        with self._lock:
            self._context.append(f"MESSENGER: {response}")
            if event.kind == "user_turn" and event.command_seq is not None and event.command_id:
                command_key = (event.command_seq, event.command_id)
                self._user_response_texts[command_key] = raw_response
                self._user_response_roles[command_key] = user_response_role
                if (
                    self._action_kinds.get(command_key) == "conversation"
                    and user_response_role == "answer"
                ):
                    self._conversation_commands_answered.add(command_key)
                else:
                    self._conversation_commands_answered.discard(command_key)
        self._speak_safely(
            response,
            event.command_seq,
            event.command_id,
            display_text=(
                event.text
                if (
                    event.kind == "orchestrator_final"
                    or event.work_lifecycle
                    or event.kind == "orchestrator_trace"
                )
                else None
            ),
            speech_metadata=self._speech_metadata_for(
                event,
                realization=realization,
                spoken_text=response,
                user_response_role=user_response_role,
            ),
        )

    def _backend_accepts_partial(self) -> bool:
        try:
            parameters = inspect.signature(self.backend.ask).parameters.values()
        except (TypeError, ValueError):
            return False
        return any(
            parameter.name == "on_partial"
            or parameter.kind == inspect.Parameter.VAR_KEYWORD
            for parameter in parameters
        )

    def _observe_timing(
        self,
        stage: str,
        command_seq: int | None,
        command_id: str | None,
        *,
        outcome: str = "ok",
    ) -> None:
        observer = self._timing_observer
        if observer is None or command_seq is None or command_id is None:
            return
        config = getattr(self.backend, "config", None)
        try:
            observer(
                stage,
                command_seq,
                command_id,
                at=time.time(),
                provider=getattr(config, "provider", None),
                outcome=outcome,
            )
        except Exception:
            pass

    def _observe_continuity(
        self,
        lifecycle_event: str,
        event: _MessengerEvent | None = None,
    ) -> None:
        observer = self._continuity_observer
        if observer is None:
            return
        config = getattr(self.backend, "config", None)
        try:
            observer({
                "event": lifecycle_event,
                "relay_command_id": event.command_id if event is not None else None,
                "provider": getattr(config, "provider", "codex"),
                "recovery_generation": self._recovery_generation,
            })
        except Exception:
            pass

    def _event_is_current(self, event: _MessengerEvent) -> bool:
        if event.work_lifecycle:
            return True
        if event.command_seq is None or event.command_id is None:
            return True
        with self._lock:
            current = (
                event.generation == self._generation
                and self._current_command == (event.command_seq, event.command_id)
            )
        return current and self._is_current(event.command_seq, event.command_id)

    @staticmethod
    def _event_is_unscoped_lifecycle(event: _MessengerEvent) -> bool:
        return (
            event.kind == "orchestrator_trace"
            and event.detail in _UNSCOPED_LIFECYCLE_KINDS
            and (event.command_seq is None or event.command_id is None)
        )

    def _must_fail_open(self, event: _MessengerEvent) -> bool:
        return (
            event.kind == "orchestrator_final"
            or event.action_kind == "self_explanation"
            or event.detail == "clarification-request"
            or self._event_is_unscoped_lifecycle(event)
            or event.work_lifecycle
        )

    def _prompt_for(self, event: _MessengerEvent) -> str:
        with self._lock:
            context_entries = list(self._context)[-_PROMPT_CONTEXT_ENTRY_LIMIT:]
        context = "\n".join(
            self._bounded_context_entry(entry) for entry in context_entries
        )
        instructions = {
            "user_turn": (
                "This is a new user turn delivered simultaneously to you and the authoritative "
                "orchestrator. If it is lightweight social conversation that needs no "
                "orchestration, reply naturally. If it is a work request or substantive "
                "question that should be handed off, give a brief contextual acknowledgement "
                "that reflects the request, uses first-person singular language such as I or "
                "me, confirms the accepted action, states the immediate next step, and promises "
                "to return with the result or a decision request, all in one semantically "
                "specific sentence of at most twelve spoken words when the meaning permits. "
                "Do not claim unperformed work. "
                "Do not call yourself the orchestrator in the spoken response. "
                "If authoritative context names workers, refer to the workers directly. Do not "
                "invent scope or "
                "claim that a ticket, worker, or implementation already exists. Prefix the "
                "response with __ANSWER__ only when it fully answers the user now; otherwise "
                "prefix it with __HANDOFF__."
            ),
            "orchestrator_trace": (
                "This is a provider-visible public progress summary or worker lifecycle event. "
                "Use it with the session context to decide whether a brief spoken update is useful. "
                "Preserve the event's state semantics: awaiting review is not done, failure needs "
                "attention, and merged is complete."
            ),
            "orchestrator_final": (
                "This is the authoritative orchestrator reply. Convey its outcome naturally and "
                "concisely without adding unsupported claims."
            ),
        }[event.kind]
        if event.kind == "user_turn" and event.action_kind == "self_explanation":
            instructions = (
                "This is Relay Runner's demo-audience self-introduction. Answer it now in one "
                "or two concise, natural sentences; do not hand it off, promise a later answer, "
                "or mention internal orchestration. Ground the answer in these facts: "
                f"{RELAY_RUNNER_DEMO_EXPLANATION}"
            )
        elif event.kind == "orchestrator_trace" and event.detail == "clarification-request":
            instructions = (
                "This is an authoritative clarification request from the orchestrator. Ask the "
                "user the requested question directly and concisely."
            )
        elif event.work_lifecycle:
            instructions = (
                "This is an authoritative completed sidecar outcome from accepted background "
                "work. Convey its result naturally and concisely without treating its originating "
                "conversation turn as current or adding unsupported claims."
            )
        realization_instructions = ""
        if self._uses_coverage_arbitration(event):
            coverage = self._coverage_for(event)
            lifecycle_role = self._lifecycle_role_for(event)
            realization_instructions = (
                "\n\nSpeech that actually finished playing for this exact Relay command:\n"
                f"{json.dumps(coverage, separators=(',', ':'), ensure_ascii=True)}\n\n"
                f"The authoritative lifecycle role is {lifecycle_role}; do not classify or change it. "
                "Return one JSON object with exactly these fields: decision (full, delta, or "
                "suppress) and spoken_text. Suppress only when the current "
                "event adds no lifecycle advance or user-relevant fact. Use delta when only part is "
                "novel. A result, failure, blocker, or critical decision must remain speakable; "
                "remove overlap but never its novel identifiers, outcomes, errors, decisions, or "
                "next steps. An acknowledgement never covers a later result."
            )
        return (
            f"{instructions}\n\n"
            "Recent session context, oldest to newest:\n"
            f"{context}\n\n"
            f"Current event: {event.kind}\n"
            f"Current event content:\n{event.text}"
            f"{realization_instructions}\n"
            + (
                "Return only the JSON object."
                if realization_instructions
                else (
                    "Return only the role-prefixed words to speak, or __SILENT__."
                    if event.kind == "user_turn"
                    else "Return only the exact words to speak, or __SILENT__."
                )
            )
        )

    @staticmethod
    def _bounded_context_entry(entry: str) -> str:
        if len(entry) <= _PROMPT_CONTEXT_ENTRY_CHAR_LIMIT:
            return entry
        half = (_PROMPT_CONTEXT_ENTRY_CHAR_LIMIT - 5) // 2
        return f"{entry[:half]} ... {entry[-half:]}"

    def _uses_coverage_arbitration(self, event: _MessengerEvent) -> bool:
        return (
            self._coverage_provider is not None
            and event.command_seq is not None
            and event.command_id is not None
            and event.kind != "user_turn"
        )

    def _coverage_for(self, event: _MessengerEvent) -> list[dict]:
        provider = self._coverage_provider
        if provider is None or event.command_seq is None or event.command_id is None:
            return []
        try:
            raw = provider(event.command_seq, event.command_id)
        except Exception as exc:
            self._coverage_error_events.add(
                (event.generation, event.command_seq, event.command_id)
            )
            if len(self._coverage_error_events) > 100:
                self._coverage_error_events = set(list(self._coverage_error_events)[-50:])
            print(f"[messenger] speech coverage unavailable: {exc}", file=sys.stderr)
            return []
        coverage: list[dict] = []
        for item in raw if isinstance(raw, (list, tuple)) else ():
            if not isinstance(item, dict):
                continue
            facts = [
                str(fact or "").strip()[:240]
                for fact in item.get("covered_facts", ())
                if str(fact or "").strip()
            ][:8]
            coverage.append({
                "lifecycle_role": str(item.get("lifecycle_role") or "conversation"),
                "covered_facts": facts,
                "spoken_text": str(item.get("spoken_text") or "").strip()[:800],
            })
        return coverage[-8:]

    def _realization_for(
        self,
        event: _MessengerEvent,
        response: str,
    ) -> _SpeechRealization | None:
        if not self._uses_coverage_arbitration(event):
            return None
        event_key = (event.generation, event.command_seq, event.command_id)
        if event_key in self._coverage_error_events:
            return self._fallback_realization(event, "coverage_unavailable")
        try:
            payload = json.loads(response)
            if not isinstance(payload, dict):
                raise ValueError("realization is not an object")
            decision = str(payload.get("decision") or "").strip().lower()
            spoken = str(payload.get("spoken_text") or "").strip()
            if decision not in _REALIZATION_DECISIONS:
                raise ValueError("unsupported realization value")
            if decision != "suppress" and not spoken:
                raise ValueError("speakable realization is empty")
        except (json.JSONDecodeError, TypeError, ValueError):
            return self._fallback_realization(event, "malformed_arbitration")

        coverage = self._coverage_for(event)
        role = self._lifecycle_role_for(event)
        if decision == "suppress" and not coverage:
            return self._fallback_realization(event, "no_played_coverage")
        if decision == "suppress" and role in _PROTECTED_LIFECYCLE_ROLES:
            return self._fallback_realization(event, "protected_lifecycle")
        retained_coverage = coverage if decision in {"delta", "suppress"} else []
        if not self._preserves_authoritative_content(
            event.text,
            retained_coverage,
            spoken if decision != "suppress" else "",
        ):
            return self._fallback_realization(
                event,
                {
                    "full": "lossy_full",
                    "delta": "lossy_delta",
                    "suppress": "uncovered_content",
                }[decision],
            )
        reason = {
            "full": "no_usable_coverage",
            "delta": "novel_delta",
            "suppress": "covered_by_played_speech",
        }[decision]
        facts = (spoken,) if spoken else ()
        return _SpeechRealization(decision, spoken, role, facts, reason)

    @staticmethod
    def _lifecycle_role_for(event: _MessengerEvent) -> str:
        if event.work_lifecycle:
            return "result"
        if event.kind == "user_turn":
            return (
                "conversation"
                if event.action_kind in {"conversation", "self_explanation"}
                else "acknowledgement"
            )
        if event.kind == "orchestrator_final":
            return (
                "conversation"
                if event.action_kind in {"conversation", "self_explanation"}
                else "result"
            )
        return _LIFECYCLE_ROLES_BY_DETAIL.get(event.detail, "progress")

    @classmethod
    def _preserves_authoritative_content(
        cls,
        authoritative: str,
        coverage: list[dict],
        spoken: str,
    ) -> bool:
        required = cls._semantic_anchors(authoritative)
        retained = cls._semantic_anchors(spoken)
        required_relations = cls._semantic_relations(authoritative)
        retained_relations = cls._semantic_relations(spoken)
        for item in coverage:
            covered = str(item.get("spoken_text") or "")
            retained.update(cls._semantic_anchors(covered))
            retained_relations.update(cls._semantic_relations(covered))
        return required.issubset(retained) and required_relations.issubset(
            retained_relations
        )

    @classmethod
    def _semantic_anchors(cls, text: str) -> set[str]:
        return set(cls._semantic_tokens(text))

    @classmethod
    def _semantic_relations(cls, text: str) -> set[tuple[str, ...]]:
        tokens = cls._semantic_tokens(text)
        # Pairs and triples retain which nearby subject owns an outcome or negation.
        return {
            tuple(tokens[index:index + width])
            for width in (2, 3)
            for index in range(len(tokens) - width + 1)
        }

    @staticmethod
    def _semantic_tokens(text: str) -> list[str]:
        normalized = str(text or "").lower().replace("’", "'")
        return [
            token
            for token in _SEMANTIC_TOKEN_RE.findall(normalized.replace("'", ""))
            if token not in _SEMANTIC_STOPWORDS and token not in {"will", "going"}
        ]

    def _fallback_realization(
        self,
        event: _MessengerEvent,
        reason: str,
    ) -> _SpeechRealization:
        role = MessengerRuntime._lifecycle_role_for(event)
        text = (
            RELAY_RUNNER_DEMO_EXPLANATION
            if event.action_kind == "self_explanation"
            else (
                MESSENGER_DEGRADED_TEXT
                if event.kind == "user_turn"
                else event.text
            )
        )
        return _SpeechRealization(
            "full",
            text,
            role,
            (text,),
            reason,
        )

    def _observe_realization(
        self,
        event: _MessengerEvent,
        realization: _SpeechRealization,
    ) -> None:
        observer = self._realization_observer
        if observer is None or event.command_seq is None or event.command_id is None:
            return
        try:
            observer(
                event.command_seq,
                event.command_id,
                lifecycle_role=realization.lifecycle_role,
                decision=realization.decision,
                reason=realization.reason,
            )
        except Exception as exc:
            print(f"[messenger] could not record realization: {exc}", file=sys.stderr)

    def _discard_pending_events_locked(self) -> None:
        preserved: list[_MessengerEvent] = []
        saw_shutdown = False
        while True:
            try:
                queued = self._events.get_nowait()
            except queue.Empty:
                break
            if queued is None:
                saw_shutdown = True
                break
            if (
                queued.command_seq is None
                or queued.command_id is None
                or queued.work_lifecycle
            ):
                preserved.append(queued)
        for event in preserved:
            self._events.put(event)
        if saw_shutdown:
            self._events.put(None)

    def _discard_pending_kinds_locked(self, kinds: set[str]) -> None:
        preserved: list[_MessengerEvent] = []
        saw_shutdown = False
        while True:
            try:
                queued = self._events.get_nowait()
            except queue.Empty:
                break
            if queued is None:
                saw_shutdown = True
                break
            if queued.kind not in kinds:
                preserved.append(queued)
        for event in preserved:
            self._events.put(event)
        if saw_shutdown:
            self._events.put(None)

    @staticmethod
    def _callable_accepts_display_text(speak: Callable[..., object]) -> bool:
        try:
            signature = inspect.signature(speak)
        except (TypeError, ValueError):
            return False
        positional = [
            parameter
            for parameter in signature.parameters.values()
            if parameter.kind in (
                inspect.Parameter.POSITIONAL_ONLY,
                inspect.Parameter.POSITIONAL_OR_KEYWORD,
            )
        ]
        return (
            any(
                parameter.kind == inspect.Parameter.VAR_POSITIONAL
                for parameter in signature.parameters.values()
            )
            or len(positional) >= 4
        )

    @staticmethod
    def _callable_accepts_speech_metadata(speak: Callable[..., object]) -> bool:
        try:
            signature = inspect.signature(speak)
        except (TypeError, ValueError):
            return False
        positional = [
            parameter
            for parameter in signature.parameters.values()
            if parameter.kind in (
                inspect.Parameter.POSITIONAL_ONLY,
                inspect.Parameter.POSITIONAL_OR_KEYWORD,
            )
        ]
        return (
            any(
                parameter.kind == inspect.Parameter.VAR_POSITIONAL
                for parameter in signature.parameters.values()
            )
            or len(positional) >= 5
        )

    def _speech_metadata_for(
        self,
        event: _MessengerEvent,
        *,
        fallback: bool = False,
        realization: _SpeechRealization | None = None,
        spoken_text: str | None = None,
        user_response_role: str = "",
    ) -> dict:
        action_kind = self._action_kinds.get(
            (event.command_seq, event.command_id),
            event.action_kind,
        )
        if event.work_lifecycle:
            source = "lifecycle"
            kind = "final"
        elif fallback:
            source = "fallback"
            kind = (
                "handoff"
                if event.kind == "user_turn" and action_kind != "self_explanation"
                else "fallback"
            )
        elif event.kind == "user_turn":
            source = "messenger"
            kind = (
                "conversation"
                if user_response_role == "answer"
                else "handoff"
            )
        elif event.kind == "orchestrator_final":
            source = event.speech_source or "orchestrator"
            kind = "final"
        elif event.detail == "clarification-request":
            source = "messenger"
            kind = "clarification"
        else:
            source = "lifecycle"
            kind = "progress"
        return {
            "source": source,
            "kind": kind,
            "authoritative": (
                event.kind == "orchestrator_final"
                or event.work_lifecycle
            ),
            "semantic_brief": (
                realization.spoken_text
                if realization is not None
                else (spoken_text or event.text)
            ),
            "lifecycle_role": (
                realization.lifecycle_role
                if realization is not None
                else (
                    (
                        "conversation"
                        if user_response_role == "answer"
                        else "acknowledgement"
                    )
                    if event.kind == "user_turn"
                    else MessengerRuntime._lifecycle_role_for(event)
                )
            ),
            "covered_facts": (
                realization.covered_facts
                if realization is not None
                else ((spoken_text,) if spoken_text else None)
            ),
            "realization_decision": (
                realization.decision if realization is not None else "full"
            ),
            "suppression_reason": (
                realization.reason if realization is not None else ""
            ),
            "replayable": (
                event.kind in {"user_turn", "orchestrator_final"}
                or event.work_lifecycle
                or (
                    event.kind == "orchestrator_trace"
                    and event.command_seq is not None
                    and event.command_id is not None
                )
            ),
            "work_disposition": self._work_dispositions.get(
                (event.command_seq, event.command_id),
                event.work_disposition,
            ),
            "freshness_scope": "work" if event.work_lifecycle else "conversation",
            "dedup_key": (
                f"work-outcome:{event.command_seq}:{event.command_id}:{event.detail}"
                if event.work_lifecycle
                else None
            ),
        }

    def _speak_safely(
        self,
        text: str,
        command_seq: int | None,
        command_id: str | None,
        *,
        display_text: str | None = None,
        speech_metadata: dict | None = None,
    ) -> None:
        try:
            if self._speak_accepts_metadata:
                self._speak(
                    text,
                    command_seq,
                    command_id,
                    display_text,
                    speech_metadata or {},
                )
            elif self._speak_accepts_display:
                self._speak(text, command_seq, command_id, display_text)
            else:
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
    speak: Callable[..., object],
    is_current: Callable[[int, str], bool],
    cwd: str | os.PathLike[str] | None = None,
    coverage_provider: Callable[[int, str], object] | None = None,
    realization_observer: Callable[..., object] | None = None,
    continuity_observer: Callable[[dict], object] | None = None,
    timing_observer: Callable[..., object] | None = None,
    recovery_generation: str | None = None,
) -> MessengerRuntime | None:
    config = MessengerConfig.from_app_config(app_config, cwd=cwd)
    if not config.enabled:
        print("[messenger] disabled by config", file=sys.stderr)
        return None
    resolved_command = resolve_messenger_command(config.provider, config.command)
    if resolved_command is None:
        executable = _command_prefix(config.command)[0]
        print(f"[messenger] provider command not found: {executable}", file=sys.stderr)
        backend: MessengerBackend = UnavailableMessengerBackend(
            config,
            "messenger provider command is unavailable",
        )
    else:
        config = replace(config, command=shlex.join(resolved_command))
        try:
            config = resolve_messenger_catalog_selection(config)
        except CodexModelResolutionError as exc:
            print(f"[messenger] could not resolve Codex messenger model: {exc}", file=sys.stderr)
            backend = UnavailableMessengerBackend(
                config,
                "messenger model selection is unavailable",
            )
        else:
            backend = (
                ClaudeMessengerBackend(config)
                if config.provider == "claude"
                else CodexMessengerBackend(config)
            )
    return MessengerRuntime(
        backend,
        speak=speak,
        is_current=is_current,
        coverage_provider=coverage_provider,
        realization_observer=realization_observer,
        continuity_observer=continuity_observer,
        timing_observer=timing_observer,
        recovery_generation=(
            recovery_generation
            or os.environ.get("RELAY_RECOVERY_GENERATION")
            or "0"
        ),
    )
