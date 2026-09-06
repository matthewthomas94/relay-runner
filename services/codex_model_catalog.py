"""Codex model catalogue resolution from the provider-owned app-server API."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Iterable


CODEX_FAMILIES = frozenset({"astra", "sol", "terra", "luna"})
CODEX_DEFAULT_FAMILY = "sol"
CODEX_MESSENGER_DEFAULT_FAMILY = "luna"
CODEX_WORKER_TIER_FAMILIES = {
    "fast": "luna",
    "balanced": "terra",
    "strong": "sol",
}
CODEX_PROVIDER_DEFAULT_EFFORT = "default"
_CODEX_FAMILY_RE = re.compile(r"^gpt-(?P<version>\d+(?:\.\d+)*)(?:-[a-z0-9]+)*-(?P<family>astra|sol|terra|luna)$")
_CODEX_GENERIC_VERSION_RE = re.compile(r"^gpt-\d+(?:\.\d+)*(?:-[a-z0-9]+)*$")


class CodexModelResolutionError(RuntimeError):
    """Raised when a selected Codex family cannot resolve to a concrete model."""


@dataclass(frozen=True)
class CodexModel:
    id: str
    model: str
    hidden: bool
    is_default: bool
    default_reasoning_effort: str
    supported_reasoning_efforts: tuple[str, ...]
    input_modalities: tuple[str, ...]

    @property
    def launch_model(self) -> str:
        return self.model or self.id

    @property
    def is_text_compatible(self) -> bool:
        return not self.input_modalities or "text" in self.input_modalities


def normalize_codex_family(value: object, *, default_family: str = CODEX_DEFAULT_FAMILY) -> str:
    text = str(value or "").strip().lower()
    if text in CODEX_FAMILIES:
        return text
    if text in {"", "default"}:
        return default_family
    match = _CODEX_FAMILY_RE.match(text)
    if match:
        return match.group("family")
    if _CODEX_GENERIC_VERSION_RE.match(text):
        return default_family
    return default_family


def codex_family_for_model(value: object) -> str | None:
    text = str(value or "").strip().lower()
    if text in CODEX_FAMILIES:
        return text
    match = _CODEX_FAMILY_RE.match(text)
    return match.group("family") if match else None


def is_codex_family(value: object) -> bool:
    return str(value or "").strip().lower() in CODEX_FAMILIES


def codex_family_version(value: object) -> tuple[int, ...] | None:
    match = _CODEX_FAMILY_RE.match(str(value or "").strip().lower())
    if not match:
        return None
    return tuple(int(part) for part in match.group("version").split("."))


def codex_models_from_model_list(payload: dict[str, Any] | list[Any]) -> list[CodexModel]:
    if isinstance(payload, list):
        raw_models = payload
    elif isinstance(payload, dict):
        raw_models = (
            payload.get("data")
            or payload.get("models")
            or payload.get("items")
            or payload.get("result", {}).get("data")
            or []
        )
    else:
        raw_models = []

    models: list[CodexModel] = []
    for raw in raw_models:
        if not isinstance(raw, dict):
            continue
        model_id = str(raw.get("id") or raw.get("model") or "").strip().lower()
        concrete_model = str(raw.get("model") or raw.get("id") or "").strip().lower()
        if not model_id and not concrete_model:
            continue
        efforts = tuple(_supported_efforts(raw.get("supportedReasoningEfforts")))
        default_effort = str(raw.get("defaultReasoningEffort") or "").strip().lower()
        if not default_effort and efforts:
            default_effort = efforts[0]
        if not default_effort:
            default_effort = CODEX_PROVIDER_DEFAULT_EFFORT
        models.append(CodexModel(
            id=model_id or concrete_model,
            model=concrete_model or model_id,
            hidden=bool(raw.get("hidden")),
            is_default=bool(raw.get("isDefault")),
            default_reasoning_effort=default_effort,
            supported_reasoning_efforts=efforts,
            input_modalities=tuple(
                str(modality or "").strip().lower()
                for modality in raw.get("inputModalities", [])
                if str(modality or "").strip()
            ),
        ))
    return models


def resolve_codex_family(family: object, models: Iterable[CodexModel]) -> CodexModel:
    normalized_family = normalize_codex_family(family)
    candidates = [
        model for model in models
        if not model.hidden
        and model.is_text_compatible
        and codex_family_for_model(model.launch_model) == normalized_family
        and codex_family_version(model.launch_model) is not None
    ]
    if not candidates:
        raise CodexModelResolutionError(
            f"Codex model family '{normalized_family}' is unavailable in the provider catalogue"
        )
    return max(candidates, key=lambda model: codex_family_version(model.launch_model) or ())


def resolve_codex_effort(effort: object, resolved_model: CodexModel) -> str:
    value = str(effort or "").strip().lower()
    if value in {"", CODEX_PROVIDER_DEFAULT_EFFORT}:
        return resolved_model.default_reasoning_effort
    if value in resolved_model.supported_reasoning_efforts:
        return value
    allowed = ", ".join(resolved_model.supported_reasoning_efforts)
    raise CodexModelResolutionError(
        f"Codex model {resolved_model.launch_model} does not advertise reasoning effort {value!r}; "
        f"supported efforts: {allowed}"
    )


def resolve_codex_family_from_cli(
    family: object,
    *,
    command: str = "codex",
    include_hidden: bool = False,
    timeout: float = 10.0,
) -> CodexModel:
    return resolve_codex_family(
        family,
        fetch_codex_models_from_cli(command=command, include_hidden=include_hidden, timeout=timeout),
    )


def fetch_codex_models_from_cli(
    *,
    command: str = "codex",
    include_hidden: bool = False,
    timeout: float = 10.0,
) -> list[CodexModel]:
    fixture = os.environ.get("RELAY_CODEX_MODEL_LIST_JSON")
    if fixture:
        return codex_models_from_model_list(json.loads(fixture))

    cmd = _command_prefix(command)
    cmd.extend([
        "app-server",
        "--stdio",
        "-c",
        "mcp_servers={}",
    ])
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except OSError as exc:
        raise CodexModelResolutionError(f"could not start Codex app-server: {exc}") from exc

    responses: dict[int, dict[str, Any]] = {}
    lock = threading.Lock()

    def _reader() -> None:
        if proc.stdout is None:
            return
        for line in proc.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            request_id = message.get("id") if isinstance(message, dict) else None
            if isinstance(request_id, int):
                with lock:
                    responses[request_id] = message

    threading.Thread(target=_reader, name="codex-model-list-reader", daemon=True).start()
    try:
        _write_json(proc, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "relay-runner-model-resolver",
                    "title": "Relay Runner Model Resolver",
                    "version": "1",
                },
                "capabilities": {"experimentalApi": True},
            },
        })
        _wait_for_response(responses, lock, 1, timeout=min(timeout, 5.0))
        _write_json(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})

        models: list[CodexModel] = []
        cursor: str | None = None
        request_id = 2
        deadline = time.monotonic() + timeout
        while True:
            _write_json(proc, {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "model/list",
                "params": {
                    "cursor": cursor,
                    "includeHidden": include_hidden,
                    "limit": 100,
                },
            })
            response = _wait_for_response(
                responses,
                lock,
                request_id,
                timeout=max(0.1, deadline - time.monotonic()),
            )
            if "error" in response:
                message = response.get("error", {}).get("message") or response["error"]
                raise CodexModelResolutionError(f"Codex model/list failed: {message}")
            result = response.get("result") or {}
            models.extend(codex_models_from_model_list(result))
            cursor = result.get("nextCursor") if isinstance(result, dict) else None
            if not cursor:
                return models
            request_id += 1
    finally:
        _stop_process(proc)


def _supported_efforts(raw_efforts: object) -> tuple[str, ...]:
    efforts: list[str] = []
    if isinstance(raw_efforts, list):
        for raw in raw_efforts:
            if isinstance(raw, dict):
                value = raw.get("reasoningEffort") or raw.get("value") or raw.get("id")
            else:
                value = raw
            text = str(value or "").strip().lower()
            if text and text not in efforts:
                efforts.append(text)
    return tuple(efforts)


def _command_prefix(command: str) -> list[str]:
    expanded = os.path.expanduser(str(command or "").strip())
    if os.path.exists(expanded):
        return [expanded]
    return shlex.split(str(command or "").strip()) or ["codex"]


def _write_json(proc: subprocess.Popen, payload: dict[str, Any]) -> None:
    if proc.stdin is None or proc.poll() is not None:
        raise CodexModelResolutionError("Codex app-server is not writable")
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def _wait_for_response(
    responses: dict[int, dict[str, Any]],
    lock: threading.Lock,
    request_id: int,
    *,
    timeout: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with lock:
            response = responses.pop(request_id, None)
        if response is not None:
            if "error" in response:
                message = response.get("error", {}).get("message") or response["error"]
                raise CodexModelResolutionError(f"Codex app-server request {request_id} failed: {message}")
            return response
        time.sleep(0.02)
    raise CodexModelResolutionError(f"Codex app-server request {request_id} timed out")


def _stop_process(proc: subprocess.Popen) -> None:
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


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", default="codex")
    parser.add_argument("--family", required=True)
    parser.add_argument("--effort", default=CODEX_PROVIDER_DEFAULT_EFFORT)
    parser.add_argument("--include-hidden", action="store_true")
    args = parser.parse_args(argv)
    try:
        model = resolve_codex_family_from_cli(
            args.family,
            command=args.command,
            include_hidden=args.include_hidden,
        )
        effort = resolve_codex_effort(args.effort, model)
    except CodexModelResolutionError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps({
        "selectedFamily": normalize_codex_family(args.family),
        "resolvedModel": model.launch_model,
        "defaultReasoningEffort": model.default_reasoning_effort,
        "supportedReasoningEfforts": list(model.supported_reasoning_efforts),
        "resolvedEffort": effort,
    }, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
