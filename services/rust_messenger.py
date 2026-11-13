"""The voice messenger's provider backends in Rust (RR-490).

`relay-rs messenger` owns the Codex app-server and Claude stream-json
backends, with model and effort resolution, the Claude subscription gate,
warm-up, re-binding and interruption. This module is the MessengerBackend the
Python MessengerRuntime drives in their place, over one JSON object per line
on the helper's stdio (the protocol is described in
rust/relay-rs/src/messenger/mod.rs).

`RELAY_MESSENGER_RUNTIME=rust` selects it. The helper is `RELAY_RS_BINARY`, or
the relay-rs the app bundle ships in Contents/MacOS. Without it the Python
backends are used, as they are by default until the bridge cut-over.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from pathlib import Path
from typing import Callable

RUNTIME_ENVIRONMENT = "RELAY_MESSENGER_RUNTIME"
BINARY_ENVIRONMENT = "RELAY_RS_BINARY"
# How much longer than the provider's own limits the proxy waits for the
# helper before it gives up on a request.
_START_TIMEOUT = 90.0
_CONFIGURE_TIMEOUT = 60.0
_ASK_MARGIN = 30.0


class RustMessengerUnavailable(RuntimeError):
    """The helper could not be started or configured."""


def rust_backend_requested(environment: dict[str, str] | None = None) -> bool:
    environment = os.environ if environment is None else environment
    return str(environment.get(RUNTIME_ENVIRONMENT) or "").strip().lower() == "rust"


def rust_binary(environment: dict[str, str] | None = None) -> str | None:
    environment = os.environ if environment is None else environment
    configured = str(environment.get(BINARY_ENVIRONMENT) or "").strip()
    candidate = configured or str(Path(__file__).resolve().parent.parent.parent / "MacOS" / "relay-rs")
    return candidate if os.path.isfile(candidate) and os.access(candidate, os.X_OK) else None


class RustMessengerBackend:
    """MessengerBackend served by `relay-rs messenger`."""

    actor_role = "messenger"

    def __init__(self, binary: str, general: dict, cwd: str, *, error_type: type[Exception]):
        self._binary = binary
        self._general = general
        self._cwd = cwd
        self._error = error_type
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._next_id = 1
        self._waiting: dict[int, dict] = {}
        self.config = None
        self.config = self._configure()

    # -- MessengerBackend ----------------------------------------------------

    def start(self) -> None:
        self._request("start", timeout=_START_TIMEOUT)

    def ask(
        self,
        prompt: str,
        timeout: float = 60.0,
        on_partial: Callable[[str], object] | None = None,
    ) -> str:
        result = self._request(
            "ask",
            {"prompt": prompt, "timeout": float(timeout), "partial": on_partial is not None},
            timeout=float(timeout) + _START_TIMEOUT + _ASK_MARGIN,
            on_partial=on_partial,
        )
        return str(result.get("text") or "")

    def rebind(self, partition_key: str) -> None:
        self._request("rebind", {"partition": str(partition_key or "")}, timeout=_START_TIMEOUT)

    def interrupt(self) -> None:
        self._send_only("interrupt")

    def shutdown(self) -> None:
        try:
            self._request("shutdown", timeout=5.0, respawn=False)
        except self._error:
            pass

    # -- helper process ------------------------------------------------------

    def _configure(self):
        from messenger import MessengerConfig  # the runtime's own config type

        try:
            result = self._request(
                "configure", {"general": self._general, "cwd": self._cwd}, timeout=_CONFIGURE_TIMEOUT,
            )
        except self._error as exc:
            raise RustMessengerUnavailable(str(exc)) from exc
        return MessengerConfig(
            enabled=bool(result.get("enabled")),
            provider=str(result.get("provider") or ""),
            command=str(result.get("command") or ""),
            model=str(result.get("model") or ""),
            effort=str(result.get("effort") or ""),
            cwd=str(result.get("cwd") or self._cwd),
        )

    def _ensure_process(self, *, respawn: bool) -> subprocess.Popen | None:
        with self._lock:
            proc = self._proc
            if proc is not None and proc.poll() is None:
                return proc
            if not respawn:
                return None
            try:
                proc = subprocess.Popen(
                    [self._binary, "messenger"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    text=True,
                    bufsize=1,
                )
            except OSError as exc:
                raise self._error(f"could not start the Rust messenger: {exc}") from exc
            self._proc = proc
        threading.Thread(target=self._read, args=(proc,), name="rust-messenger-reader", daemon=True).start()
        if self.config is not None:
            # A helper that died lost its configuration; give it the same one.
            try:
                self._configure()
            except RustMessengerUnavailable as exc:
                raise self._error(str(exc)) from exc
        return proc

    def _write(self, proc: subprocess.Popen, message: dict) -> None:
        try:
            with self._write_lock:
                # A TOML table can hold dates; the helper reads them as text.
                proc.stdin.write(json.dumps(message, separators=(",", ":"), default=str) + "\n")
                proc.stdin.flush()
        except (AttributeError, BrokenPipeError, OSError, ValueError) as exc:
            raise self._error(f"could not write to the Rust messenger: {exc}") from exc

    def _send_only(self, op: str) -> None:
        proc = self._ensure_process(respawn=False)
        if proc is None:
            return
        with self._lock:
            request_id = self._next_id
            self._next_id += 1
        try:
            self._write(proc, {"id": request_id, "op": op})
        except self._error:
            pass

    def _request(
        self,
        op: str,
        fields: dict | None = None,
        *,
        timeout: float,
        on_partial: Callable[[str], object] | None = None,
        respawn: bool = True,
    ) -> dict:
        proc = self._ensure_process(respawn=respawn)
        if proc is None:
            return {}
        waiter = {"event": threading.Event(), "reply": None, "on_partial": on_partial, "proc": proc}
        with self._lock:
            request_id = self._next_id
            self._next_id += 1
            self._waiting[request_id] = waiter
        try:
            self._write(proc, {"id": request_id, "op": op, **(fields or {})})
            if not waiter["event"].wait(timeout=max(0.1, timeout)):
                raise self._error(f"Rust messenger {op} timed out")
        finally:
            with self._lock:
                self._waiting.pop(request_id, None)
        reply = waiter["reply"] or {}
        if "error" in reply:
            raise self._error(str(reply["error"]))
        result = reply.get("result")
        return result if isinstance(result, dict) else {}

    def _read(self, proc: subprocess.Popen) -> None:
        try:
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(message, dict):
                    continue
                with self._lock:
                    waiter = self._waiting.get(message.get("id"))
                if waiter is None:
                    continue
                if "partial" in message:
                    callback = waiter["on_partial"]
                    if callback is not None:
                        try:
                            callback(str(message["partial"]))
                        except Exception:
                            pass
                    continue
                waiter["reply"] = message
                waiter["event"].set()
        except (OSError, ValueError):
            pass
        finally:
            with self._lock:
                orphaned = [w for w in self._waiting.values() if w["proc"] is proc]
                if self._proc is proc:
                    self._proc = None
            for waiter in orphaned:
                if not waiter["event"].is_set():
                    waiter["reply"] = {"error": "Rust messenger process exited"}
                    waiter["event"].set()


def create_rust_backend(app_config: dict, cwd: str, *, error_type: type[Exception]) -> RustMessengerBackend | None:
    """The Rust backend when it is requested and its helper is installed."""
    if not rust_backend_requested():
        return None
    binary = rust_binary()
    if binary is None:
        print("[messenger] Rust messenger requested but relay-rs is not installed; using Python", file=sys.stderr)
        return None
    general = app_config.get("general", {})
    try:
        return RustMessengerBackend(
            binary, general if isinstance(general, dict) else {}, cwd, error_type=error_type,
        )
    except RustMessengerUnavailable as exc:
        print(f"[messenger] Rust messenger unavailable ({exc}); using Python", file=sys.stderr)
        return None
