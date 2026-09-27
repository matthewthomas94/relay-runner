"""Exact, bounded computer actions for the opt-in local Laya experiment.

Laya decides only whether the request is an Action. This module resolves an
explicit operation and target; it never treats model probabilities as authority
to invent a target, a shell command, or a multi-step UI plan.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import socket
import subprocess
from typing import Callable
from urllib.parse import urlsplit


ACTION_SOCKET = "/tmp/relay_actions.sock"
_SINGLE_TARGET = re.compile(r"^[\w .()+&'-]{1,80}$", re.UNICODE)
_COMPOUND = re.compile(r"\b(?:and|then|after|before|but|while)\b", re.I)
_KEYS = {
    "escape": "escape", "esc": "escape", "return": "return", "enter": "return",
    "tab": "tab", "space": "space", "up": "up", "down": "down",
    "left": "left", "right": "right", "command s": "cmd+s",
    "cmd s": "cmd+s", "command f": "cmd+f", "cmd f": "cmd+f",
}
_FOLDERS = {"downloads": "Downloads", "documents": "Documents", "desktop": "Desktop"}


@dataclass(frozen=True)
class FastAction:
    kind: str
    target: str | dict
    spoken_result: str


@dataclass(frozen=True)
class FastActionResult:
    text: str
    confirmed: bool
    kind: str


def parse_fast_action(text: str, *, repo_path: Path) -> FastAction | None:
    """Accept one complete, literal operation. Ambiguous text stays with the PM."""
    source = str(text or "").strip()
    source = re.sub(r"^(?:please\s+|can you\s+|could you\s+)", "", source, flags=re.I)
    source = source.rstrip(".!?").strip()
    if not source or "\n" in source or ";" in source or _COMPOUND.search(source):
        return None

    match = re.fullmatch(r"(?:open|visit|go to)\s+(https?://\S+)", source, re.I)
    if match:
        url = match.group(1)
        parsed = urlsplit(url)
        if parsed.scheme in {"http", "https"} and parsed.netloc and not parsed.username:
            return FastAction("open_url", url, f"Opened {parsed.netloc}.")
        return None

    match = re.fullmatch(r"(?:open|show)\s+(?:(?:my|the)\s+)?(downloads|documents|desktop|home|project)(?:\s+folder)?", source, re.I)
    if match:
        label = match.group(1).lower()
        path = repo_path if label == "project" else Path.home() / _FOLDERS[label] if label in _FOLDERS else Path.home()
        if path.is_dir():
            return FastAction("open_path", str(path), f"Opened the {label} folder.")
        return None

    match = re.fullmatch(r"(open|reveal)\s+(/\S+)(?:\s+in Finder)?", source, re.I)
    if match:
        path = Path(match.group(2)).expanduser()
        if path.exists():
            verb = "Revealed" if match.group(1).lower() == "reveal" else "Opened"
            return FastAction("reveal_path" if verb == "Revealed" else "open_path", str(path), f"{verb} {path.name}.")
        return None

    match = re.fullmatch(r"(?:press|hit)\s+(.+)", source, re.I)
    if match:
        combo = _KEYS.get(re.sub(r"\s*\+\s*", " ", match.group(1).lower()).strip())
        if combo:
            return FastAction("key", combo, f"Pressed {match.group(1).strip()}.")
        return None

    match = re.fullmatch(r"(click|double click|right click)\s+at\s+\(?([0-9]{1,5})\s*,\s*([0-9]{1,5})\)?", source, re.I)
    if match:
        x, y = int(match.group(2)), int(match.group(3))
        arguments = {"x": x, "y": y}
        if match.group(1).lower() == "double click":
            arguments["double"] = True
        elif match.group(1).lower() == "right click":
            arguments["button"] = "right"
        return FastAction("click", arguments, f"Clicked at {x}, {y}.")

    match = re.fullmatch(r"scroll\s+(up|down)\s+([1-9][0-9]?)\s+lines?\s+at\s+\(?([0-9]{1,5})\s*,\s*([0-9]{1,5})\)?", source, re.I)
    if match:
        direction, lines, x, y = match.group(1).lower(), int(match.group(2)), int(match.group(3)), int(match.group(4))
        return FastAction("scroll", {"x": x, "y": y, "dy": lines if direction == "up" else -lines}, f"Scrolled {direction} {lines} lines.")

    match = re.fullmatch(r"type\s+(.{1,500})\s+into\s+(?:the\s+)?(?:focused|active)\s+field", source, re.I)
    if match:
        value = match.group(1).strip()
        if len(value) >= 2 and (value[0], value[-1]) in {('"', '"'), ("'", "'"), ('“', '”')}:
            value = value[1:-1]
        if value:
            return FastAction("type", value, "Typed the text into the focused field.")

    match = re.fullmatch(r"(?:open|launch|focus|switch to|bring up|bring to the front)\s+(.+)", source, re.I)
    if match:
        app = re.sub(r"\s+(?:app|application)$", "", match.group(1), flags=re.I).strip()
        if _SINGLE_TARGET.fullmatch(app) and not app.startswith("-"):
            return FastAction("open_app", app, f"Opened {app}.")
    return None


def eligible_fast_action(resolved_items: list[dict], hint: dict | None) -> bool:
    if os.environ.get("RELAY_LAYA_FAST_ACTIONS") != "1" or len(resolved_items) != 1:
        return False
    resolved = resolved_items[0]
    item = resolved["item"]
    action = resolved["action"]
    disposition = resolved["disposition"]
    metadata = resolved["metadata"]
    return bool(
        isinstance(hint, dict)
        and hint.get("bucket") == "action"
        and not hint.get("fallback_reason")
        and all(hint.get(key) == metadata.get(key) for key in ("relay_command_id", "relay_command_seq"))
        and action.kind == "direct_action"
        and metadata.get("intent_qualification", {}).get("bucket") == "action"
        and item.lifecycle_state != "cancelled"
        and item.disposition == "accepted"
        and disposition.route.value == "continue_current"
        and disposition.cancellation_scope.value == "none"
    )


def _relay_action(name: str, arguments: dict) -> bool:
    wire = (json.dumps({"type": "perform_tool", "tool": name, "arguments": arguments}) + "\n").encode()
    # Mirror the MCP helper's ActionGlow signal through the same Relay bus.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as glow:
        glow.settimeout(1.0)
        glow.connect(ACTION_SOCKET)
        glow.sendall((json.dumps({"type": "tool_fired", "tool": name}) + "\n").encode())
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(1.0)
        connection.connect(ACTION_SOCKET)
        connection.sendall(wire)
        data = b""
        while b"\n" not in data:
            part = connection.recv(8192)
            if not part or len(data) > 32768:
                return False
            data += part
    return json.loads(data.split(b"\n", 1)[0]).get("result") == "ok"


def execute_fast_action(action: FastAction) -> FastActionResult:
    """Execute once. A timeout after submission is uncertain and never retried."""
    try:
        if action.kind in {"open_app", "open_url", "open_path", "reveal_path"}:
            argv = ["/usr/bin/open"]
            if action.kind == "open_app":
                argv += ["-a", action.target]
            elif action.kind == "reveal_path":
                argv += ["-R", action.target]
            else:
                argv.append(action.target)
            result = subprocess.run(argv, capture_output=True, timeout=1.0, check=False)
            confirmed = result.returncode == 0
        else:
            arguments = (
                {"combo": action.target} if action.kind == "key" else
                {"text": action.target} if action.kind == "type" else action.target
            )
            confirmed = _relay_action(action.kind, arguments)
    except (OSError, ValueError, subprocess.TimeoutExpired, socket.timeout):
        confirmed = False
    return FastActionResult(
        action.spoken_result if confirmed else "I could not confirm that action completed. Please check before repeating it.",
        confirmed,
        action.kind,
    )


def try_fast_action(
    text: str,
    *,
    repo_path: Path,
    resolved_items: list[dict],
    hint: dict | None,
    current_command: Callable[[], bool],
) -> FastActionResult | None:
    if not eligible_fast_action(resolved_items, hint):
        return None
    action = parse_fast_action(text, repo_path=repo_path)
    if action is None or not current_command():
        return None
    return execute_fast_action(action)
