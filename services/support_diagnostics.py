"""Privacy-safe local startup journal shared by Relay service processes."""

from __future__ import annotations

import json
import os
import re
import shutil
import time
import uuid
from contextlib import contextmanager
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
_SAFE_IDS = (
    re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
    re.compile(r"^inc-[0-9a-f]{12}$"),
    re.compile(r"^(?:shell|orchestrator)-[0-9]{10,}-[0-9]+$"),
)
_REDACTED_ID = "redacted-id"
_LOCK_NAME = ".journal.lock"
_LOCK_WAIT_SECONDS = 5.0
_LOCK_STALE_SECONDS = 30.0
_REDACTIONS = (
    (re.compile(r"(?i)\b(authorization|token|secret|password|api[_-]?key)\s*[:=]\s*[^\s,;]+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"), r"\1 [REDACTED]"),
    (re.compile(r"(?:file://)?/(?:Users|Volumes|private/tmp|tmp)/[^\s,;]+"), "[PATH]"),
    (re.compile(r"(?<!:)(?<![A-Za-z0-9])/(?:Applications|Library|System|opt|usr|var|etc|bin|sbin|dev|private)/[^\s,;]+"), "[PATH]"),
    (re.compile(r"\b(?:sk|ghp|github_pat|xox[baprs])-[-A-Za-z0-9_]{8,}\b"), "[TOKEN]"),
)
_APP_SESSION_ID = os.environ.get("RELAY_APP_SESSION_ID") or str(uuid.uuid4())


def _safe_id(value: str) -> tuple[str, int]:
    if len(value) <= 64 and any(pattern.fullmatch(value) for pattern in _SAFE_IDS):
        return value, 0
    return _REDACTED_ID, 1


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

    safe_app_session_id, count = _safe_id(_APP_SESSION_ID)
    redaction_count += count
    safe_incident_id = None
    if incident_id is not None:
        safe_incident_id, count = _safe_id(incident_id)
        redaction_count += count
    safe_correlation_id, count = _safe_id(
        correlation_id or os.environ.get("RELAY_CORRELATION_ID") or str(uuid.uuid4())
    )
    redaction_count += count

    event: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "app_session_id": safe_app_session_id,
        "incident_id": safe_incident_id,
        "retry_attempt": retry_attempt,
        "correlation_id": safe_correlation_id,
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
        with _journal_lock(directory):
            path = directory / f"events-v1-{event['process']}-{os.getpid()}.jsonl"
            payload = (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode()
            descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(descriptor, payload)
            finally:
                os.close(descriptor)
            path.chmod(0o600)
            _prune(directory)
    except OSError:
        # Diagnostics must never prevent an offline/local service from starting.
        return


@contextmanager
def _journal_lock(directory: Path):
    """Use the shared mkdir lock: 5s bounded wait, 30s stale recovery."""
    lock = directory / _LOCK_NAME
    deadline = time.monotonic() + _LOCK_WAIT_SECONDS
    while True:
        try:
            lock.mkdir(mode=0o700)
            break
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime >= _LOCK_STALE_SECONDS:
                    stale = directory / f"{_LOCK_NAME}.stale-{os.getpid()}-{uuid.uuid4().hex}"
                    lock.rename(stale)
                    shutil.rmtree(stale, ignore_errors=True)
                    continue
            except FileNotFoundError:
                continue
            if time.monotonic() >= deadline:
                raise TimeoutError("support journal lock timed out")
            time.sleep(0.05)
    try:
        yield
    finally:
        shutil.rmtree(lock, ignore_errors=True)


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
