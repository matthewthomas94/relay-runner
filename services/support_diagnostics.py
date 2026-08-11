"""Privacy-safe local startup journal shared by Relay service processes."""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Optional


SCHEMA_VERSION = 1
RETENTION_DAYS = 7
MAXIMUM_BYTES = 5 * 1024 * 1024
ALLOWED_PROCESSES = frozenset({"app", "setup", "shell", "orchestrator", "provider"})
ALLOWED_PROVIDERS = frozenset({"codex", "claude"})
ALLOWED_ATTRIBUTE_KEYS = frozenset({
    "build", "error_code", "exit_code", "launch_mode", "payload_count", "transport", "version",
})
_IDENTIFIER = re.compile(r"^[a-z0-9_]{1,64}$")
_REDACTIONS = (
    (re.compile(r"(?i)\b(authorization|token|secret|password|api[_-]?key)\s*[:=]\s*[^\s,;]+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"), r"\1 [REDACTED]"),
    (re.compile(r"(?:file://)?/(?:Users|Volumes|private/tmp|tmp)/[^\s,;]+"), "[PATH]"),
    (re.compile(r"(?<!:)(?<![A-Za-z0-9])/(?:Applications|Library|System|opt|usr|var|etc|bin|sbin|dev|private)/[^\s,;]+"), "[PATH]"),
    (re.compile(r"\b(?:sk|ghp|github_pat|xox[baprs])-[-A-Za-z0-9_]{8,}\b"), "[TOKEN]"),
)
_APP_SESSION_ID = os.environ.get("RELAY_APP_SESSION_ID") or str(uuid.uuid4())


def _safe_id(value: str) -> str:
    safe = "".join(character for character in value.lower() if character.isalnum() or character == "-")
    return (safe or str(uuid.uuid4()))[:64]


def redact(value: str, *, limit: int = 300) -> tuple[str, int]:
    result = value[:limit]
    count = int(len(value) > limit)
    for pattern, replacement in _REDACTIONS:
        result, replacements = pattern.subn(replacement, result)
        count += replacements
    return result, count


def journal_directory() -> Path:
    override = os.environ.get("RELAY_DIAGNOSTICS_DIR")
    if override:
        return Path(override)
    return Path.home() / "Library/Application Support/relay-runner/support-diagnostics/v1"


def record_event(
    *,
    process: str,
    phase: str,
    outcome: str,
    incident_id: Optional[str] = None,
    retry_attempt: Optional[int] = None,
    correlation_id: Optional[str] = None,
    provider: Optional[str] = None,
    summary: Optional[str] = None,
    attributes: Optional[Mapping[str, str]] = None,
) -> Optional[dict[str, object]]:
    attributes = dict(attributes or {})
    if (
        process not in ALLOWED_PROCESSES
        or not _IDENTIFIER.fullmatch(phase)
        or not _IDENTIFIER.fullmatch(outcome)
        or (provider is not None and provider not in ALLOWED_PROVIDERS)
        or (retry_attempt is not None and retry_attempt < 1)
        or not set(attributes).issubset(ALLOWED_ATTRIBUTE_KEYS)
    ):
        return None

    redaction_count = 0
    safe_summary = None
    if summary is not None:
        safe_summary, count = redact(summary)
        redaction_count += count
    safe_attributes: dict[str, str] = {}
    for key, value in attributes.items():
        safe_attributes[key], count = redact(str(value), limit=120)
        redaction_count += count

    event: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "app_session_id": _safe_id(_APP_SESSION_ID),
        "incident_id": _safe_id(incident_id) if incident_id else None,
        "retry_attempt": retry_attempt,
        "correlation_id": _safe_id(correlation_id or os.environ.get("RELAY_CORRELATION_ID") or str(uuid.uuid4())),
        "process": process,
        "phase": phase,
        "outcome": outcome,
        "provider": provider,
        "summary": safe_summary,
        "attributes": safe_attributes,
        "redaction_count": redaction_count,
    }
    _append(event)
    return event


def _append(event: Mapping[str, object]) -> None:
    directory = journal_directory()
    try:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory.chmod(0o700)
        _prune(directory)
        path = directory / f"events-v1-{event['process']}-{os.getpid()}.jsonl"
        payload = (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode()
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(descriptor, payload)
        finally:
            os.close(descriptor)
        path.chmod(0o600)
    except OSError:
        # Diagnostics must never prevent an offline/local service from starting.
        return


def _prune(directory: Path) -> None:
    files = sorted(directory.glob("events-v1-*.jsonl"), key=lambda path: path.stat().st_mtime)
    cutoff = time.time() - RETENTION_DAYS * 86400
    for path in list(files):
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)
            files.remove(path)
    total = sum(path.stat().st_size for path in files)
    while total > MAXIMUM_BYTES and files:
        oldest = files.pop(0)
        total -= oldest.stat().st_size
        oldest.unlink(missing_ok=True)
