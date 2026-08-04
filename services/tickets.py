"""Read/write helpers for .orchestrator/<id>.md ticket files.

Mirrors the Swift TicketParser in Sources/relay-runner/Board/Ticket.swift —
line-based YAML-ish parsing, preserves body verbatim on write. The daemon
uses this for dependency progression: when a ticket completes, the daemon
scans dependents and flips backlog->ready on any whose deps are now satisfied.

We don't pull PyYAML — the frontmatter is intentionally narrow (flat
key:value pairs, one bracketed list, scalar enums) so a 50-line parser is
sufficient and matches the Swift parser bug-for-bug.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

VALID_STATUSES = ("backlog", "ready", "in_progress", "verification_blocked", "done")
VALID_PRIORITIES = ("urgent", "high", "medium", "low")
VALID_EXECUTION_MODES = ("implementation", "spike")
VALID_VERIFICATION_ORIGINS = ("inline",)


class TicketParseError(ValueError):
    pass


def _strip_quotes(s: str) -> str:
    if len(s) >= 2 and ((s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'")):
        return s[1:-1]
    return s


def _parse_list(raw: str) -> list[str]:
    if not (raw.startswith("[") and raw.endswith("]")):
        return []
    inner = raw[1:-1].strip()
    if not inner:
        return []
    return [_strip_quotes(p.strip()) for p in inner.split(",") if p.strip()]


def _format_list(items: list[str]) -> str:
    if not items:
        return "[]"
    return "[" + ", ".join(items) + "]"


def _split_frontmatter(contents: str) -> tuple[str, str]:
    """Return (frontmatter_text, body_text). Raises if delimiters are missing."""
    lines = contents.split("\n")
    if not lines or lines[0].strip() != "---":
        raise TicketParseError("missing opening --- frontmatter delimiter")
    try:
        end_idx = next(i for i, line in enumerate(lines[1:], start=1) if line.strip() == "---")
    except StopIteration as e:
        raise TicketParseError("missing closing --- frontmatter delimiter") from e
    frontmatter = "\n".join(lines[1:end_idx])
    body = "\n".join(lines[end_idx + 1:])
    return frontmatter, body


def _parse_frontmatter(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        fields[key.strip()] = _strip_quotes(value.strip())
    return fields


def parse(contents: str) -> dict[str, Any]:
    """Parse a ticket file's contents into a dict with structured values."""
    frontmatter_text, body = _split_frontmatter(contents)
    raw = _parse_frontmatter(frontmatter_text)

    def require(key: str) -> str:
        if key not in raw:
            raise TicketParseError(f"missing required field: {key}")
        return raw[key]

    status = require("status")
    if status not in VALID_STATUSES:
        raise TicketParseError(f"invalid status: {status!r}")
    priority = require("priority")
    if priority not in VALID_PRIORITIES:
        raise TicketParseError(f"invalid priority: {priority!r}")
    execution_mode = raw.get("execution_mode", "implementation").strip().lower()
    if execution_mode not in VALID_EXECUTION_MODES:
        raise TicketParseError(f"invalid execution_mode: {execution_mode!r}")

    canceled_raw = require("canceled").lower()
    if canceled_raw not in ("true", "false"):
        raise TicketParseError(f"invalid canceled: {canceled_raw!r}")
    canceled = canceled_raw == "true"

    draft_raw = raw.get("draft", "false").lower()
    if draft_raw not in ("true", "false"):
        raise TicketParseError(f"invalid draft: {draft_raw!r}")
    draft = draft_raw == "true"

    run_id_raw = require("run_id")
    run_id: int | None
    if run_id_raw.lower() in ("null", ""):
        run_id = None
    else:
        try:
            run_id = int(run_id_raw)
        except ValueError as e:
            raise TicketParseError(f"invalid run_id: {run_id_raw!r}") from e

    verification_blocker = raw.get("verification_blocker", "").strip() or None
    verification_resume = raw.get("verification_resume", "").strip() or None
    verification_origin = raw.get("verification_origin", "").strip().lower() or None
    if verification_origin not in (None, *VALID_VERIFICATION_ORIGINS):
        raise TicketParseError(f"invalid verification_origin: {verification_origin!r}")
    if status == "verification_blocked":
        if run_id is None and verification_origin != "inline":
            raise TicketParseError("verification_blocked ticket requires run_id")
        if verification_blocker is None:
            raise TicketParseError("missing required field: verification_blocker")
        if verification_resume is None:
            raise TicketParseError("missing required field: verification_resume")

    return {
        "id": require("id"),
        "title": require("title"),
        "status": status,
        "priority": priority,
        "execution_mode": execution_mode,
        "depends_on": _parse_list(require("depends_on")),
        "run_id": run_id,
        "canceled": canceled,
        "draft": draft,
        "verification_blocker": verification_blocker,
        "verification_resume": verification_resume,
        "verification_origin": verification_origin,
        "order": int(raw.get("order", "0") or "0"),
        "body": body,
        "_raw_fields": raw,  # preserves any extra fields on round-trip
    }


def read(path: Path) -> dict[str, Any]:
    return parse(path.read_text())


# Field order matches the Swift writer (Sources/relay-runner/Board/TicketWriter.swift)
# so files round-trip without unnecessary diff churn.
_FIELD_ORDER = (
    "id",
    "title",
    "status",
    "priority",
    "execution_mode",
    "depends_on",
    "run_id",
    "canceled",
    "verification_blocker",
    "verification_resume",
    "verification_origin",
    "order",
)


def _format_value(key: str, value: Any) -> str:
    if key == "depends_on":
        return _format_list(value if isinstance(value, list) else [])
    if key == "run_id":
        return "null" if value is None else str(value)
    if key == "canceled":
        return "true" if value else "false"
    if key == "order":
        return str(int(value))
    return str(value)


def write(path: Path, ticket: dict[str, Any]) -> None:
    """Write a ticket dict back to disk, preserving the body verbatim."""
    lines = ["---"]
    for key in _FIELD_ORDER:
        if key in ticket and (ticket[key] is not None or key == "run_id"):
            lines.append(f"{key}: {_format_value(key, ticket[key])}")
    # Allow callers to round-trip unknown fields by stashing them in _raw_fields.
    extras = ticket.get("_raw_fields", {})
    for key, raw_value in extras.items():
        if key in _FIELD_ORDER:
            continue
        lines.append(f"{key}: {raw_value}")
    lines.append("---")
    body = ticket.get("body", "")
    # The body always starts with the newline that follows the closing ---,
    # so prepending "\n" reconstructs the line terminator. Any blank-line
    # separator the original had survives because it's encoded as a leading
    # "\n" inside body (see _split_frontmatter — it joins from end_idx + 1).
    output = "\n".join(lines) + "\n" + body
    if not output.endswith("\n"):
        output += "\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(output)
    tmp.replace(path)


def scan_repo(repo_path: Path) -> list[dict[str, Any]]:
    """Return every parseable ticket in <repo>/.orchestrator/. Skips bad files."""
    orch_dir = repo_path / ".orchestrator"
    if not orch_dir.is_dir():
        return []
    tickets: list[dict[str, Any]] = []
    for path in sorted(orch_dir.glob("*.md")):
        try:
            t = parse(path.read_text())
            t["_path"] = path
            tickets.append(t)
        except (OSError, TicketParseError):
            continue
    return tickets


def find_dependents(repo_path: Path, ticket_id: str) -> list[dict[str, Any]]:
    """Return tickets in the same repo whose depends_on includes `ticket_id`."""
    return [t for t in scan_repo(repo_path) if ticket_id in t["depends_on"]]


def all_deps_done(ticket: dict[str, Any], all_tickets: list[dict[str, Any]]) -> bool:
    """True iff every id in ticket['depends_on'] resolves to a ticket with status=done."""
    by_id = {t["id"]: t for t in all_tickets}
    for dep_id in ticket["depends_on"]:
        dep = by_id.get(dep_id)
        if dep is None or dep["status"] != "done":
            return False
    return True
