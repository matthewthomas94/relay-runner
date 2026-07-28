"""Bounded provider-neutral execution lane for safe read-only voice sidecars."""

from __future__ import annotations

from dataclasses import dataclass, replace
import queue
import shlex
import sys
import threading
from typing import Callable

from messenger import (
    ClaudeMessengerBackend,
    CodexMessengerBackend,
    MessengerConfig,
    _command_prefix,
    resolve_messenger_catalog_selection,
    resolve_messenger_command,
)


SIDECAR_SYSTEM_PROMPT = """You are Relay Runner's bounded read-only sidecar.

Complete only the independent inspection or public research task in the user
request. You are not the foreground orchestrator: do not plan or mutate project
work, use repository files, control the desktop, contact people, spend money, or
perform any external side effect. Use only public web search/fetch capabilities.
Return a concise, independently verifiable result and include source URLs for
external factual claims. If the task cannot be completed under these limits,
state the limitation plainly. Never address speech or TTS directly.
"""


@dataclass(frozen=True)
class SidecarTask:
    prompt: str
    command: dict


@dataclass(frozen=True)
class SidecarLifecycleEvent:
    phase: str
    command: dict
    public_summary: str


class CodexSidecarBackend(CodexMessengerBackend):
    """Codex app-server with web search enabled and every mutation tool disabled."""

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
            "-c", "tools.web_search=true",
            "-c", "mcp_servers={}",
        ])
        return command

    def thread_start_params(self) -> dict:
        params = super().thread_start_params()
        params.update({
            "baseInstructions": SIDECAR_SYSTEM_PROMPT,
            "developerInstructions": SIDECAR_SYSTEM_PROMPT,
            "sandbox": "read-only",
        })
        return params


class ClaudeSidecarBackend(ClaudeMessengerBackend):
    """Claude print session restricted to public web read tools."""

    def spawn_command(self) -> list[str]:
        command = _command_prefix(self.config.command)
        command.extend([
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", self.config.model,
            "--tools", "WebSearch,WebFetch",
            "--permission-mode", "dontAsk",
            "--safe-mode",
            "--no-chrome",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}',
            "--system-prompt", SIDECAR_SYSTEM_PROMPT,
        ])
        if self.config.effort != "default":
            command.extend(["--effort", self.config.effort])
        return command


class ProviderSidecarExecutor:
    """One-shot provider execution shared by Codex and Claude sidecar tasks."""

    def __init__(
        self,
        config: MessengerConfig,
        *,
        backend_factory: Callable[[MessengerConfig], object] | None = None,
    ):
        self.config = config
        self._backend_factory = backend_factory

    def __call__(self, prompt: str, timeout: float) -> str:
        backend = (
            self._backend_factory(self.config)
            if self._backend_factory is not None
            else (
                ClaudeSidecarBackend(self.config)
                if self.config.provider == "claude"
                else CodexSidecarBackend(self.config)
            )
        )
        task_prompt = (
            f"{SIDECAR_SYSTEM_PROMPT}\n\n"
            "Independent user task:\n"
            f"{str(prompt or '').strip()}"
        )
        try:
            return str(backend.ask(task_prompt, timeout=timeout) or "").strip()
        finally:
            backend.shutdown()


class UnavailableSidecarExecutor:
    def __init__(self, reason: str):
        self.reason = reason

    def __call__(self, prompt: str, timeout: float) -> str:
        del prompt, timeout
        raise RuntimeError(self.reason)


class SidecarLane:
    """Single-flight sidecar worker concurrent with the foreground provider."""

    def __init__(
        self,
        execute: Callable[[str, float], str],
        *,
        on_lifecycle: Callable[[SidecarLifecycleEvent], object],
        on_final: Callable[[str, dict], object],
        timeout: float = 90.0,
        max_pending: int = 4,
    ):
        self._execute = execute
        self._on_lifecycle = on_lifecycle
        self._on_final = on_final
        self._timeout = max(1.0, float(timeout))
        self._tasks: queue.Queue[SidecarTask | None] = queue.Queue(
            maxsize=max(1, int(max_pending))
        )
        self._shutdown = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="relay-read-only-sidecar",
            daemon=True,
        )
        self._thread.start()

    def submit(self, prompt: str, command: dict) -> bool:
        cleaned = str(prompt or "").strip()
        if not cleaned or not isinstance(command, dict) or self._shutdown.is_set():
            return False
        try:
            self._tasks.put_nowait(SidecarTask(cleaned, dict(command)))
        except queue.Full:
            return False
        return True

    def shutdown(self) -> None:
        self._shutdown.set()
        try:
            self._tasks.put_nowait(None)
        except queue.Full:
            pass
        if self._thread is not threading.current_thread():
            self._thread.join(timeout=2)

    def _run(self) -> None:
        while not self._shutdown.is_set():
            try:
                task = self._tasks.get(timeout=0.1)
            except queue.Empty:
                continue
            if task is None:
                return
            self._emit_lifecycle("started", task.command)
            try:
                result = self._execute(task.prompt, self._timeout).strip()
                if not result:
                    raise RuntimeError("sidecar returned no result")
            except Exception as exc:  # noqa: BLE001 - provider failure becomes bounded public state.
                print(
                    f"[sidecar] read-only task failed ({type(exc).__name__})",
                    file=sys.stderr,
                )
                self._emit_lifecycle("failed", task.command)
                self._emit_final(
                    "The independent read-only task could not complete in its bounded sidecar lane.",
                    task.command,
                )
            else:
                self._emit_lifecycle("completed", task.command)
                self._emit_final(result, task.command)
            finally:
                self._tasks.task_done()

    def _emit_lifecycle(self, phase: str, command: dict) -> None:
        disposition = command.get("work_disposition")
        reason = (
            str(disposition.get("public_reason") or "")
            if isinstance(disposition, dict)
            else ""
        )
        event = SidecarLifecycleEvent(
            phase=phase,
            command=dict(command),
            public_summary=reason or "Independent bounded read-only work.",
        )
        try:
            self._on_lifecycle(event)
        except Exception as exc:  # noqa: BLE001 - lifecycle reporting cannot kill the lane.
            print(f"[sidecar] lifecycle callback failed: {exc}", file=sys.stderr)

    def _emit_final(self, text: str, command: dict) -> None:
        try:
            self._on_final(text, dict(command))
        except Exception as exc:  # noqa: BLE001 - reporting failure cannot kill the lane.
            print(f"[sidecar] final callback failed: {exc}", file=sys.stderr)


def create_sidecar_executor(app_config: dict, *, cwd: str) -> ProviderSidecarExecutor | UnavailableSidecarExecutor:
    """Resolve the configured foreground provider into the restricted sidecar runtime."""
    config = MessengerConfig.from_app_config(app_config, cwd=cwd)
    resolved_command = resolve_messenger_command(config.provider, config.command)
    if resolved_command is None:
        executable = _command_prefix(config.command)[0]
        return UnavailableSidecarExecutor(f"provider command not found: {executable}")
    config = replace(
        config,
        enabled=True,
        command=shlex.join(resolved_command),
    )
    try:
        config = resolve_messenger_catalog_selection(config)
    except Exception as exc:  # noqa: BLE001 - report provider catalog failure through the lane.
        return UnavailableSidecarExecutor(f"provider model could not be resolved: {exc}")
    return ProviderSidecarExecutor(config)
