#!/usr/bin/env python3
"""Relay-runner orchestrator daemon.

Symphony-style sub-agent orchestrator: dispatches tickets from a repo's local
kanban board (`<repo>/.orchestrator/<ticket_id>.md`) to autonomous Codex or
Claude runs in isolated worktrees, and tracks state in SQLite. HTTP API on 127.0.0.1;
MCP tool surface is the thin Swift proxy in Sources/relay-orchestrator-mcp/
which calls these endpoints.

MVP scope: voice/MCP-driven dispatch only. The repo is the source of truth —
tickets live as version-controlled markdown under `.orchestrator/`, and the
sub-agent edits its ticket's YAML frontmatter + appends a "## Run log" section
when it finishes. No external service is involved.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

# Reuse the existing config loader (sibling file).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load_config
from graphify_core import GraphifyCoreStore
from graphify_ingest import ingest_registered_projects
from program_status import build_program_status
from session_capture import capture_session_review
from tickets import (
    TicketParseError,
    read as read_ticket,
    scan_repo,
    write as write_ticket,
    all_deps_done,
)

PORT_FILE = Path("/tmp/relay_orchestrator.port")
RELAY_COMMAND_STATE_FILE = Path("/tmp/voice_command_state.json")
DEFAULT_PORT = 7634

WORKER_SIZING_FIELDS = (
    "worker_model",
    "worker_effort",
    "worker_sizing_rationale",
    "worker_provider_notes",
)
WORKER_MODEL_TIERS = {
    "codex": {
        "fast": "gpt-5.4-mini",
        "balanced": "gpt-5.4",
        "strong": "gpt-5.5",
    },
    "claude": {
        "fast": "haiku",
        "balanced": "sonnet",
        "strong": "opus",
    },
}
CODEX_WORKER_EFFORTS = frozenset({"low", "medium", "high", "xhigh"})
CLAUDE_WORKER_EFFORTS = CODEX_WORKER_EFFORTS | frozenset({"max"})


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _data_root() -> Path:
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    return base / "relay-runner" / "orchestrator"


def _program_registry_path() -> Path:
    return _data_root().parent / "program" / "projects.json"


def _registered_project_repo_paths(registry_path: Path) -> list[str]:
    try:
        payload = json.loads(registry_path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    projects = payload.get("projects") if isinstance(payload, dict) else None
    if not isinstance(projects, list):
        return []

    repo_paths: list[str] = []
    seen: set[str] = set()
    for record in projects:
        if not isinstance(record, dict):
            continue
        raw = record.get("repoPath") or record.get("id")
        repo_path = str(raw or "").strip()
        if not repo_path:
            continue
        resolved = str(Path(repo_path).expanduser().resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        repo_paths.append(resolved)
    return repo_paths


def _resolve_workspace_root(cfg_value: str) -> Path:
    if cfg_value:
        return Path(cfg_value).expanduser()
    return _data_root() / "workspaces"


def _resolve_workflow_default(cfg_value: str) -> Path:
    """Default workflow template: user override → bundled file alongside this script."""
    user_default = _data_root() / "WORKFLOW.md"
    if cfg_value:
        return Path(cfg_value).expanduser()
    if user_default.exists():
        return user_default
    return Path(__file__).with_name("orchestrator_workflow.md")


def _agent_kind(raw: str | None) -> str:
    value = (raw or "codex").strip().lower()
    name = os.path.basename(value)
    if "claude" in name:
        return "claude"
    return "codex"


def _find_agent_bin(agent: str, configured: str = "") -> str:
    if configured:
        expanded = os.path.expanduser(configured)
        if os.path.sep in expanded and os.access(expanded, os.X_OK):
            return expanded
        p = shutil.which(configured)
        if p:
            return p
        raise RuntimeError(f"{agent} CLI not found: {configured}")

    if agent == "claude":
        p = shutil.which("claude")
        if p:
            return p
        fallback = os.path.expanduser("~/.local/bin/claude")
        if os.access(fallback, os.X_OK):
            return fallback
        raise RuntimeError("claude CLI not found on PATH or at ~/.local/bin/claude")

    p = shutil.which("codex")
    if p:
        return p
    fallback = "/Applications/Codex.app/Contents/Resources/codex"
    if os.access(fallback, os.X_OK):
        return fallback
    raise RuntimeError("codex CLI not found on PATH or in /Applications/Codex.app")


# ---------------------------------------------------------------------------
# Pure helpers (unit-testable)
# ---------------------------------------------------------------------------

_BRANCH_INVALID = re.compile(r"[^a-z0-9-]+")


def sanitize_identifier(identifier: str) -> str:
    """`REL-42` → `rel-42`. Lowercase, ASCII alnum + dashes only, no leading/trailing dashes."""
    s = (identifier or "").strip().lower()
    s = _BRANCH_INVALID.sub("-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    if not s:
        raise ValueError(f"Invalid identifier: {identifier!r}")
    return s


def workspace_slug(repo_path: str, ticket_id: str) -> str:
    """Stable worktree directory name scoped by repo, then ticket."""
    repo = Path(repo_path)
    repo_name = sanitize_identifier(repo.name or "repo")
    ticket = sanitize_identifier(ticket_id)
    digest = hashlib.sha1(str(repo.resolve()).encode("utf-8")).hexdigest()[:8]
    return f"{repo_name}-{digest}-{ticket}"


_TEMPLATE_RE = re.compile(r"\{\{\s*([\w_]+)\s*\}\}")


def render_template(template: str, **vars: Any) -> str:
    """Tiny `{{key}}` renderer. Missing keys → empty string. No escaping (we trust the template)."""
    return _TEMPLATE_RE.sub(lambda m: str(vars.get(m.group(1).strip(), "")), template)


def _ticket_frontmatter(ticket: dict[str, Any]) -> dict[str, str]:
    raw = ticket.get("_raw_fields")
    return raw if isinstance(raw, dict) else {}


def _required_sizing_value(ticket: dict[str, Any], field: str) -> str:
    value = str(_ticket_frontmatter(ticket).get(field) or "").strip()
    return value


def _resolve_worker_model(worker_model: str, agent_kind: str) -> str:
    value = worker_model.strip().lower()
    if ":" in value:
        provider, _, model = value.partition(":")
        model = model.strip()
        if provider not in ("codex", "claude") or not model:
            raise ValueError(f"invalid worker_model {worker_model!r}")
        if provider != agent_kind:
            raise ValueError(
                f"worker_model {worker_model!r} is scoped to {provider}, "
                f"but configured worker provider is {agent_kind}"
            )
        return model

    model = WORKER_MODEL_TIERS.get(agent_kind, {}).get(value)
    if model is None:
        allowed = ", ".join(sorted(WORKER_MODEL_TIERS.get(agent_kind, {})))
        raise ValueError(
            f"invalid worker_model {worker_model!r} for {agent_kind}; "
            f"expected one of {allowed} or {agent_kind}:<model>"
        )
    return model


def _validate_worker_effort(worker_effort: str, *, worker_model: str, agent_kind: str,
                            provider_notes: str) -> str:
    effort = worker_effort.strip().lower()
    allowed = CLAUDE_WORKER_EFFORTS if agent_kind == "claude" else CODEX_WORKER_EFFORTS
    if effort not in allowed:
        allowed_text = ", ".join(sorted(allowed))
        raise ValueError(
            f"invalid worker_effort {worker_effort!r} for {agent_kind}; "
            f"expected one of {allowed_text}"
        )
    if effort == "max":
        scoped_to_claude = worker_model.strip().lower().startswith("claude:")
        notes_document_limitation = provider_notes.strip().lower() not in ("", "none")
        if not scoped_to_claude or not notes_document_limitation:
            raise ValueError(
                "worker_effort 'max' requires a Claude-scoped worker_model and "
                "worker_provider_notes documenting the Codex limitation"
            )
    return effort


def resolve_worker_sizing(ticket: dict[str, Any], agent_kind: str) -> dict[str, str]:
    missing = [field for field in WORKER_SIZING_FIELDS if not _required_sizing_value(ticket, field)]
    if missing:
        raise ValueError("missing worker sizing metadata: " + ", ".join(missing))

    worker_model = _required_sizing_value(ticket, "worker_model")
    worker_effort = _required_sizing_value(ticket, "worker_effort")
    provider_notes = _required_sizing_value(ticket, "worker_provider_notes")
    model_alias = _resolve_worker_model(worker_model, agent_kind)
    effort = _validate_worker_effort(
        worker_effort,
        worker_model=worker_model,
        agent_kind=agent_kind,
        provider_notes=provider_notes,
    )
    return {
        "provider_key": agent_kind,
        "model_alias": model_alias,
        "worker_model": worker_model,
        "worker_effort": effort,
        "worker_sizing_rationale": _required_sizing_value(ticket, "worker_sizing_rationale"),
        "worker_provider_notes": provider_notes,
    }


def raw_worker_sizing_metadata(ticket: dict[str, Any], agent_kind: str) -> dict[str, str | None]:
    return {
        "provider_key": agent_kind,
        "model_alias": None,
        "worker_model": _required_sizing_value(ticket, "worker_model") or None,
        "worker_effort": _required_sizing_value(ticket, "worker_effort") or None,
        "worker_sizing_rationale": _required_sizing_value(ticket, "worker_sizing_rationale") or None,
        "worker_provider_notes": _required_sizing_value(ticket, "worker_provider_notes") or None,
    }


def _normalized_default_worker_sizing(general: dict[str, Any]) -> dict[str, str] | None:
    if str(general.get("subagent_sizing_policy") or "").strip().lower() != "user_default":
        return None
    model = str(general.get("subagent_model") or "").strip().lower()
    if model not in WORKER_MODEL_TIERS["codex"]:
        model = "balanced"
    effort = str(general.get("subagent_effort") or "").strip().lower()
    if effort not in CODEX_WORKER_EFFORTS:
        effort = "medium"
    return {
        "worker_model": model,
        "worker_effort": effort,
        "worker_sizing_rationale": "User default from Relay Runner Settings.",
        "worker_provider_notes": (
            "User default applies to Codex and Claude; Codex uses "
            "model_reasoning_effort and Claude uses --effort."
        ),
    }


def apply_default_worker_sizing(
    ticket: dict[str, Any],
    general: dict[str, Any],
) -> bool:
    defaults = _normalized_default_worker_sizing(general)
    if not defaults:
        return False
    explicit_model = _required_sizing_value(ticket, "worker_model")
    explicit_effort = _required_sizing_value(ticket, "worker_effort")
    if explicit_model or explicit_effort:
        return False
    raw = ticket.setdefault("_raw_fields", {})
    if not isinstance(raw, dict):
        raw = {}
        ticket["_raw_fields"] = raw
    raw.update(defaults)
    return True


def _relay_command_current(relay_command_seq: int | str | None, relay_command_id: str | None) -> bool:
    if relay_command_seq is None or not relay_command_id:
        return False
    try:
        current = json.loads(RELAY_COMMAND_STATE_FILE.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return False
    if not isinstance(current, dict):
        return False
    try:
        current_seq = int(current.get("relay_command_seq"))
        expected_seq = int(relay_command_seq)
    except (TypeError, ValueError):
        return False
    return (
        current_seq == expected_seq
        and str(current.get("relay_command_id") or "") == str(relay_command_id)
    )


def _validate_relay_command(relay_command_seq: Any, relay_command_id: Any) -> None:
    if relay_command_seq is None and not relay_command_id:
        return
    if _relay_command_current(relay_command_seq, str(relay_command_id or "")):
        return
    raise ValueError("stale Relay command: a newer voice command has superseded this action")


# -- live activity summary (RR-12) ------------------------------------------
# A worker's most recent tool call, distilled to a ≤60-char chip for the board.
# No-op tools shouldn't clobber a more useful activity set moments earlier; the
# heartbeat keeps `activity_at` fresh while a long-running tool is in flight so
# the board doesn't false-positive into "Idle".
ACTIVITY_MAX_LEN = 60
ACTIVITY_DEBOUNCE_SECONDS = 5.0
ACTIVITY_HEARTBEAT_SECONDS = 5.0
_NOOP_TOOLS = frozenset({"TodoWrite"})
_SHELL_NAMES = frozenset({"sh", "bash", "zsh"})


def _clip(text: str, limit: int = ACTIVITY_MAX_LEN) -> str:
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def _shell_words(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def _unwrap_shell_command(command: str) -> str:
    lines = (command or "").strip().splitlines()
    first = lines[0].strip() if lines else ""
    words = _shell_words(first)
    if not words:
        return ""

    if os.path.basename(words[0]) == "env" and len(words) > 1:
        i = 1
        while i < len(words) and (words[i].startswith("-") or "=" in words[i]):
            i += 1
        if i < len(words):
            words = words[i:]

    if os.path.basename(words[0]) in _SHELL_NAMES:
        for i, word in enumerate(words[1:], start=1):
            if word == "-c" or (word.startswith("-") and "c" in word[1:]):
                if i + 1 < len(words):
                    return words[i + 1].strip()
                break
    return first


def _activity_from_description(description: str) -> str:
    desc = (description or "").strip()
    if not desc:
        return ""
    return _clip(desc[:1].upper() + desc[1:])


def _task_activity(task: str) -> str:
    return {
        "test": "Running tests",
        "lint": "Running lint",
        "build": "Running build",
    }.get(task, "Running project task")


def _semantic_shell_activity(command: str, description: str = "") -> str:
    cmd = _unwrap_shell_command(command)
    lower = re.sub(r"\s+", " ", cmd.lower()).strip()
    words = _shell_words(cmd)
    first = os.path.basename(words[0]) if words else ""

    if not lower:
        return _activity_from_description(description) or "Running command"

    if "apply_patch" in lower:
        return "Editing source files"

    if re.search(r"\b(swift test|xcodebuild\b.*\btest\b)\b", lower):
        return "Running Swift tests"
    if re.search(r"\b(swift build|xcodebuild)\b", lower):
        return "Running Swift build"
    if re.search(r"\b(pytest|python3? -m pytest)\b", lower):
        return "Running Python tests"
    if re.search(r"\b(npm|pnpm|yarn) (run )?(test|lint|build)\b", lower):
        task = re.search(r"\b(test|lint|build)\b", lower)
        return _task_activity(task.group(1)) if task else "Running project task"
    if re.search(r"\b(make|just) (test|lint|build)\b", lower):
        task = re.search(r"\b(test|lint|build)\b", lower)
        return _task_activity(task.group(1)) if task else "Running project task"

    if re.search(r"\b(git grep|rg|grep)\b", lower):
        return "Searching source files"
    if first in {"find", "fd"}:
        return "Finding files"
    if first in {"cat", "sed", "head", "tail", "nl", "wc"}:
        return "Reading source files"
    if first in {"ls", "pwd", "tree"} or re.search(r"\bgit ls-files\b", lower):
        return "Inspecting workspace"

    if re.search(r"\bgit commit\b", lower):
        return "Committing changes"
    if re.search(r"\bgit add\b", lower):
        return "Staging changes"
    if re.search(r"\bgit status\b", lower):
        return "Checking git status"
    if re.search(r"\bgit (diff|show|log)\b", lower):
        return "Inspecting git changes"
    if re.search(r"\bgit \w+", lower):
        return "Working with git"

    return _activity_from_description(description) or "Investigating"


def derive_activity(tool_name: str, tool_input: dict | None) -> str:
    """Heuristic summary of a worker's current tool call. Intentionally
    approximate — grow this table as new tools matter (see RR-12)."""
    ti = tool_input or {}
    name = tool_name or ""

    def base(p: Any) -> str:
        s = str(p or "")
        return os.path.basename(s) or s

    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        f = ti.get("file_path") or ti.get("notebook_path") or ""
        return _clip(f"Editing {base(f)}" if f else "Editing")
    if name == "Read":
        f = ti.get("file_path") or ""
        return _clip(f"Reading {base(f)}" if f else "Reading")
    if name in ("Grep", "Glob"):
        return "Searching"
    if name == "Bash":
        cmd = (ti.get("command") or "").strip()
        desc = (ti.get("description") or "").strip()
        return _semantic_shell_activity(cmd, desc)
    if name in ("WebFetch", "WebSearch"):
        return "Researching"
    if name == "Task":
        return "Delegating to sub-agent"
    if name == "TodoWrite":
        return "Planning"
    # Unknown / MCP tools: just show the (clipped) tool name.
    return _clip(name) or "Working"


def derive_codex_activity(item: dict | None) -> str:
    """Heuristic summary for Codex exec --json item events."""
    item = item or {}
    itype = item.get("type") or ""
    if itype == "command_execution":
        command = (item.get("command") or "").strip()
        return _semantic_shell_activity(command)
    if itype == "file_change":
        changes = item.get("changes") or []
        paths = [str(c.get("path") or "") for c in changes if isinstance(c, dict)]
        if any(f"{os.sep}.orchestrator{os.sep}" in path for path in paths):
            return "Updating ticket run log"
        return "Editing source files"
    name = item.get("name") or item.get("tool_name") or itype
    if str(name).endswith("apply_patch") or str(name) == "apply_patch":
        return "Editing source files"
    return _clip(str(name)) or "Working"


# ---------------------------------------------------------------------------
# Stores
# ---------------------------------------------------------------------------

class RunsStore:
    SCHEMA_VERSION = 4  # bump when the runs table shape changes

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticket_id TEXT NOT NULL,
        repo_path TEXT NOT NULL,
        workspace_path TEXT NOT NULL,
        branch TEXT NOT NULL,
        state TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        pid INTEGER,
        started_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER,
        log_path TEXT,
        last_error TEXT,
        activity TEXT,
        activity_at REAL,
        provider_key TEXT,
        model_alias TEXT,
        worker_model TEXT,
        worker_effort TEXT,
        worker_sizing_rationale TEXT,
        worker_provider_notes TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_runs_state ON runs(state);
    CREATE INDEX IF NOT EXISTS idx_runs_ticket ON runs(ticket_id);
    """

    ACTIVE_STATES = ("Claimed", "Running")
    # Completed entries linger in the runs-index file this long after `ended_at`
    # so the board can render "Succeeded — awaiting merge" pills across the
    # typical merge gap without flicker, then get pruned.
    INDEX_RETENTION_SECONDS = 300

    def __init__(self, path: Path, index_path: Path | None = None):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Ephemeral live-state view consumed by the board overlay. None disables
        # index writes (keeps the store usable in unit tests without a filesystem
        # side effect).
        self.index_path = index_path
        self._lock = threading.Lock()
        self._init()

    @contextmanager
    def _conn(self):
        with self._lock:
            conn = sqlite3.connect(str(self.path), isolation_level=None)
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def _init(self) -> None:
        # PRAGMA user_version gates schema migrations. A version mismatch
        # drops the table entirely (historical runs lose their rows —
        # acceptable for a local dev tool).
        with self._conn() as c:
            current = int(c.execute("PRAGMA user_version").fetchone()[0])
            if current != self.SCHEMA_VERSION:
                c.execute("DROP TABLE IF EXISTS runs")
                c.executescript(self.SCHEMA)
                c.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
            else:
                c.executescript(self.SCHEMA)

    def insert(self, *, ticket_id: str, repo_path: str, workspace_path: str,
               branch: str, state: str, attempt: int = 1, log_path: str | None = None,
               provider_key: str | None = None, model_alias: str | None = None,
               worker_model: str | None = None, worker_effort: str | None = None,
               worker_sizing_rationale: str | None = None,
               worker_provider_notes: str | None = None) -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, "
                "state, attempt, started_at, log_path, provider_key, model_alias, "
                "worker_model, worker_effort, worker_sizing_rationale, worker_provider_notes) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (ticket_id, repo_path, workspace_path, branch,
                 state, attempt, time.time(), log_path, provider_key, model_alias,
                 worker_model, worker_effort, worker_sizing_rationale, worker_provider_notes),
            )
            run_id = int(cur.lastrowid)
        self.write_index()
        return run_id

    def update(self, run_id: int, *, state: str | None = None, pid: int | None = None,
               exit_code: int | None = None, last_error: str | None = None,
               ended: bool = False) -> None:
        fields, values = [], []
        if state is not None:
            fields.append("state = ?"); values.append(state)
        if pid is not None:
            fields.append("pid = ?"); values.append(pid)
        if exit_code is not None:
            fields.append("exit_code = ?"); values.append(exit_code)
        if last_error is not None:
            fields.append("last_error = ?"); values.append(last_error)
        if ended:
            fields.append("ended_at = ?"); values.append(time.time())
        if not fields:
            return
        values.append(run_id)
        with self._conn() as c:
            c.execute(f"UPDATE runs SET {', '.join(fields)} WHERE id = ?", values)
        self.write_index()

    def set_activity(self, run_id: int, activity: str) -> None:
        """Record the worker's current activity summary (RR-12) and refresh its
        timestamp. Rewrites the index so the board picks it up within a poll."""
        with self._conn() as c:
            c.execute("UPDATE runs SET activity = ?, activity_at = ? WHERE id = ?",
                      (activity, time.time(), run_id))
        self.write_index()

    def touch_activity(self, run_id: int) -> None:
        """Bump only the activity timestamp — the heartbeat while a tool is in
        flight, so a long operation doesn't read as stalled on the board."""
        with self._conn() as c:
            c.execute("UPDATE runs SET activity_at = ? WHERE id = ?",
                      (time.time(), run_id))
        self.write_index()

    def get(self, run_id: int) -> dict | None:
        with self._conn() as c:
            row = c.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
            return dict(row) if row else None

    def list(self, state: str | None = None, limit: int = 100) -> list[dict]:
        with self._conn() as c:
            if state:
                rows = c.execute(
                    "SELECT * FROM runs WHERE state = ? ORDER BY id DESC LIMIT ?",
                    (state, limit),
                ).fetchall()
            else:
                rows = c.execute(
                    "SELECT * FROM runs ORDER BY id DESC LIMIT ?", (limit,)
                ).fetchall()
            return [dict(r) for r in rows]

    def find_active(self, ticket_id: str, repo_path: str | None = None) -> dict | None:
        ph = ",".join("?" * len(self.ACTIVE_STATES))
        params: list[Any] = [ticket_id, *self.ACTIVE_STATES]
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM runs WHERE ticket_id = ? AND state IN ({ph}) "
                f"{repo_clause}"
                "ORDER BY id DESC LIMIT 1",
                params,
            ).fetchone()
            return dict(row) if row else None

    def reconcile_on_startup(self) -> int:
        """Mark any in-flight run from a prior daemon as Stalled. Returns count."""
        ph = ",".join("?" * len(self.ACTIVE_STATES))
        with self._conn() as c:
            cur = c.execute(
                f"UPDATE runs SET state = 'Stalled', ended_at = ?, "
                "last_error = 'Daemon restarted while run was active' "
                f"WHERE state IN ({ph})",
                (time.time(), *self.ACTIVE_STATES),
            )
            return cur.rowcount

    def next_attempt(self, ticket_id: str, repo_path: str | None = None) -> int:
        """Returns the attempt number to use for a new run on this ticket (1 if none, max+1 otherwise)."""
        params: list[Any] = [ticket_id]
        repo_clause = ""
        if repo_path is not None:
            repo_clause = "AND repo_path = ? "
            params.append(str(Path(repo_path).expanduser().resolve()))
        with self._conn() as c:
            row = c.execute(
                f"SELECT MAX(attempt) AS a FROM runs WHERE ticket_id = ? {repo_clause}",
                params,
            ).fetchone()
            if row and row["a"]:
                return int(row["a"]) + 1
            return 1

    # -- runs-index file (board live-state view) --------------------------

    def _index_entries(self, conn) -> list[dict]:
        """Active runs plus completed ones inside the retention window. One
        entry per run, shaped for the board overlay (run_id is the row id)."""
        cutoff = time.time() - self.INDEX_RETENTION_SECONDS
        rows = conn.execute(
            "SELECT * FROM runs WHERE ended_at IS NULL OR ended_at >= ? "
            "ORDER BY id DESC",
            (cutoff,),
        ).fetchall()
        return [
            {
                "ticket_id": r["ticket_id"],
                "repo_path": r["repo_path"],
                "run_id": r["id"],
                "state": r["state"],
                "started_at": r["started_at"],
                "ended_at": r["ended_at"],
                "last_error": r["last_error"],
                "workspace_path": r["workspace_path"],
                "branch": r["branch"],
                "activity": r["activity"],
                "activity_at": r["activity_at"],
                "provider_key": r["provider_key"],
                "model_alias": r["model_alias"],
                "worker_model": r["worker_model"],
                "worker_effort": r["worker_effort"],
                "worker_sizing_rationale": r["worker_sizing_rationale"],
                "worker_provider_notes": r["worker_provider_notes"],
            }
            for r in rows
        ]

    def write_index(self) -> None:
        """Rewrite the runs-index file from current state. Called on every
        transition (insert/update) so the file never lags SQLite, and on a
        periodic sweep so completed entries get pruned once their retention
        window lapses. Atomic temp-write + rename so the board never reads a
        half-written file. No-op when index_path is unset."""
        if self.index_path is None:
            return
        with self._conn() as c:
            entries = self._index_entries(c)
        payload = json.dumps({"runs": entries}, default=str, indent=2)
        tmp = self.index_path.with_name(self.index_path.name + ".tmp")
        try:
            tmp.write_text(payload)
            tmp.replace(self.index_path)
        except OSError as e:
            print(f"[orchestrator] could not write runs index {self.index_path}: {e}",
                  file=sys.stderr)


# ---------------------------------------------------------------------------
# Git worktree helpers
# ---------------------------------------------------------------------------

def _git(repo_path: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", repo_path, *args],
        capture_output=True, text=True, check=check,
    )


def create_worktree(*, repo_path: str, workspace_path: Path, branch: str, base_branch: str) -> None:
    """Add a worktree for `branch` at `workspace_path`. Reuses if already a worktree on `branch`."""
    workspace_path.parent.mkdir(parents=True, exist_ok=True)

    list_out = _git(repo_path, "worktree", "list", "--porcelain", check=False).stdout
    if str(workspace_path) in list_out:
        return  # already exists as a worktree — reuse

    if workspace_path.exists():
        raise RuntimeError(f"{workspace_path} exists but is not a git worktree")

    add = _git(repo_path, "worktree", "add", "-b", branch, str(workspace_path), base_branch, check=False)
    if add.returncode == 0:
        return
    err = add.stderr or ""
    # Stale branch ref (no worktree owns it): delete and retry fresh off base. This recovers
    # from a prior cancel that left the ref behind, or a default_branch change on the project.
    if "already exists" in err:
        delete_branch(repo_path, branch)
        retry = _git(repo_path, "worktree", "add", "-b", branch, str(workspace_path), base_branch, check=False)
        if retry.returncode == 0:
            return
        raise RuntimeError(f"git worktree add (after stale branch cleanup) failed: {retry.stderr.strip()}")
    if "already used" in err:
        raise RuntimeError(
            f"branch {branch} is checked out by another worktree; cancel that run first: {err.strip()}"
        )
    raise RuntimeError(f"git worktree add failed: {err.strip()}")


def remove_worktree(repo_path: str, workspace_path: Path) -> tuple[bool, str | None]:
    """Remove a worktree. Returns (removed, error).

    `git worktree remove --force` can silently leave the directory in place if
    the worker process still holds open file descriptors / cwd inside it at the
    moment of pruning (e.g., right after SIGTERM). When that happens, fall back
    to `rm -rf` + `git worktree prune` so git's bookkeeping stays consistent.
    """
    result = _git(repo_path, "worktree", "remove", "--force", str(workspace_path), check=False)
    if not workspace_path.exists():
        return True, None

    try:
        shutil.rmtree(workspace_path)
    except OSError as e:
        git_err = (result.stderr or "").strip() or f"exit={result.returncode}"
        return False, f"git worktree remove failed ({git_err}); rmtree fallback failed: {e}"

    _git(repo_path, "worktree", "prune", check=False)
    if workspace_path.exists():
        return False, f"worktree directory still present after rm -rf: {workspace_path}"
    return True, None


def delete_branch(repo_path: str, branch: str) -> None:
    """Force-delete a local branch ref. Best-effort — git will refuse if a worktree still owns it."""
    _git(repo_path, "branch", "-D", branch, check=False)


def _git_head(repo_path: str) -> str | None:
    result = _git(repo_path, "rev-parse", "HEAD", check=False)
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def validate_worker_completion(
    *,
    workspace_path: str,
    ticket_id: str,
    run_id: int,
    start_head: str | None,
) -> tuple[bool, str]:
    """Return whether an exit-0 worker actually completed its ticket.

    Agent CLIs can return 0 after answering a clarification or unrelated prompt.
    The orchestrator treats ticket completion as on-disk evidence in the worker
    worktree: a new commit, the requested ticket marked done, and a run-log body
    that mentions the current run.
    """
    workspace = Path(workspace_path)
    ticket_path = workspace / ".orchestrator" / f"{ticket_id}.md"
    reasons: list[str] = []

    current_head = _git_head(str(workspace))
    if start_head and current_head == start_head:
        reasons.append("worker made no new commit")
    elif current_head is None:
        reasons.append("could not read worker git HEAD")

    try:
        ticket = read_ticket(ticket_path)
    except FileNotFoundError:
        return False, f"ticket file missing at {ticket_path}"
    except (OSError, TicketParseError) as e:
        return False, f"ticket file unreadable at {ticket_path}: {e}"

    if ticket.get("id") != ticket_id:
        reasons.append(f"ticket id is {ticket.get('id')!r}, expected {ticket_id!r}")
    if ticket.get("status") != "done":
        reasons.append(f"ticket status is {ticket.get('status')!r}, expected 'done'")
    if ticket.get("run_id") != run_id:
        reasons.append(f"ticket run_id is {ticket.get('run_id')!r}, expected {run_id}")

    rel_ticket = f".orchestrator/{ticket_id}.md"
    diff = _git(str(workspace), "diff", "--quiet", "HEAD", "--", rel_ticket, check=False)
    if diff.returncode == 1:
        reasons.append("ticket completion is not committed")
    elif diff.returncode != 0:
        reasons.append("could not verify committed ticket completion")

    body = str(ticket.get("body") or "")
    if "## Run log" not in body or str(run_id) not in body:
        reasons.append(f"ticket run log does not mention run {run_id}")

    if reasons:
        return False, "; ".join(reasons)
    return True, "ticket marked done with run evidence"


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class Worker:
    """One agent subprocess running against a worktree. Owns its own thread."""

    def __init__(self, *, run_id: int, run: dict, prompt: str, agent_bin: str,
                 agent_kind: str,
                 workflow_path: Path | None = None,
                 store: RunsStore, log_path: Path, timeout_seconds: int,
                 on_complete: Callable[[int], None] | None = None):
        self.run_id = run_id
        self.run = run
        self.prompt = prompt
        self.agent_bin = agent_bin
        self.agent_kind = agent_kind
        self.workflow_path = workflow_path
        self.store = store
        self.log_path = log_path
        self.timeout_seconds = timeout_seconds
        self.on_complete = on_complete
        self.proc: subprocess.Popen | None = None
        self.thread: threading.Thread | None = None
        self._cancel_requested = threading.Event()
        self._timed_out = False
        # Tool-use ids dispatched but not yet resolved by a tool_result. Shared
        # with the heartbeat thread, so guarded by a lock.
        self._inflight: set[str] = set()
        self._inflight_lock = threading.Lock()

    def start(self) -> None:
        self.thread = threading.Thread(target=self._run, name=f"worker-{self.run_id}", daemon=True)
        self.thread.start()

    def _run(self) -> None:
        try:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            log = self.log_path.open("w")
        except OSError as e:
            self.store.update(self.run_id, state="Failed", last_error=f"Could not open log: {e}", ended=True)
            self._notify_complete()
            return

        try:
            log.write(f"[orchestrator] provider={self.agent_kind}\n")
            if self.run.get("model_alias"):
                log.write(f"[orchestrator] model_alias={self.run['model_alias']}\n")
            if self.run.get("worker_model"):
                log.write(f"[orchestrator] worker_model={self.run['worker_model']}\n")
            if self.run.get("worker_effort"):
                log.write(f"[orchestrator] worker_effort={self.run['worker_effort']}\n")
            if self.run.get("worker_sizing_rationale"):
                log.write(f"[orchestrator] worker_sizing_rationale={self.run['worker_sizing_rationale']}\n")
            if self.run.get("worker_provider_notes"):
                log.write(f"[orchestrator] worker_provider_notes={self.run['worker_provider_notes']}\n")
            if self.workflow_path:
                log.write(f"[orchestrator] workflow_template={self.workflow_path}\n")
            log.write(f"[orchestrator] prompt_sha256={hashlib.sha256(self.prompt.encode('utf-8')).hexdigest()}\n")
            start_head = _git_head(self.run["workspace_path"])
            if start_head:
                log.write(f"[orchestrator] start_head={start_head}\n")
            cmd = self._command()
            try:
                self.proc = subprocess.Popen(
                    cmd,
                    cwd=self.run["workspace_path"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
            except FileNotFoundError as e:
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"{self.agent_kind} CLI not found: {e}",
                                  ended=True, exit_code=-1)
                log.write(f"[orchestrator] {self.agent_kind} CLI not found: {e}\n")
                return

            self.store.update(self.run_id, state="Running", pid=self.proc.pid)

            # Feed the prompt and close stdin so the agent starts. The prompt is a
            # few KB — well under the pipe buffer — so this single write won't
            # deadlock against the stdout reads below.
            try:
                if self.proc.stdin:
                    self.proc.stdin.write(self.prompt)
                    self.proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass

            # The read loop blocks on readline, so the timeout can't be enforced
            # inline — a watchdog terminates the process and the loop ends on EOF.
            watchdog = threading.Timer(self.timeout_seconds, self._on_timeout)
            watchdog.daemon = True
            watchdog.start()
            # Keep activity_at fresh while a tool is in flight (e.g. a long
            # `swift build`) so the board doesn't read it as stalled.
            hb_stop = threading.Event()
            hb_thread = threading.Thread(
                target=self._heartbeat, args=(hb_stop,),
                name=f"worker-{self.run_id}-hb", daemon=True,
            )
            hb_thread.start()

            tail: collections.deque[str] = collections.deque(maxlen=5)
            last_meaningful_at = 0.0
            try:
                for line in self.proc.stdout:  # type: ignore[union-attr]
                    log.write(line)
                    stripped = line.strip()
                    if not stripped:
                        continue
                    tail.append(stripped[:500])
                    last_meaningful_at = self._handle_event(stripped, last_meaningful_at)
            finally:
                log.flush()
                hb_stop.set()
                watchdog.cancel()

            self.proc.wait()
            rc = self.proc.returncode

            if self._timed_out:
                log.write(f"\n[orchestrator] worker timed out at {self.timeout_seconds}s\n")
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"Timed out after {self.timeout_seconds}s",
                                  ended=True, exit_code=-1)
            elif self._cancel_requested.is_set():
                self.store.update(self.run_id, state="Canceled", ended=True, exit_code=rc)
            elif rc == 0:
                ok, reason = validate_worker_completion(
                    workspace_path=self.run["workspace_path"],
                    ticket_id=self.run["ticket_id"],
                    run_id=self.run_id,
                    start_head=start_head,
                )
                if ok:
                    self.store.update(self.run_id, state="Succeeded", ended=True, exit_code=rc)
                else:
                    log.write(f"\n[orchestrator] worker exited 0 but did not complete ticket: {reason}\n")
                    self.store.update(
                        self.run_id,
                        state="Failed",
                        last_error=f"exit=0 but ticket incomplete: {reason}",
                        ended=True,
                        exit_code=rc,
                    )
            elif rc in (-9, -15):
                self.store.update(self.run_id, state="Canceled", ended=True, exit_code=rc)
            else:
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"exit={rc}; tail={' / '.join(tail)[:500]}",
                                  ended=True, exit_code=rc)
        finally:
            try:
                log.close()
            except OSError:
                pass
            self._notify_complete()

    def _command(self) -> list[str]:
        model_alias = str(self.run.get("model_alias") or "").strip()
        worker_effort = str(self.run.get("worker_effort") or "").strip()
        if self.agent_kind == "claude":
            # Claude stream-json gives assistant/tool_use/tool_result/result
            # events. The worker parses tool_use blocks into the live board
            # activity chip while teeing the full stream to the run log.
            cmd = [
                self.agent_bin,
                "-p",
                "--dangerously-skip-permissions",
                "--verbose",
                "--output-format", "stream-json",
            ]
            if model_alias:
                cmd.extend(["--model", model_alias])
            if worker_effort:
                cmd.extend(["--effort", worker_effort])
            return cmd

        # Codex exec --json emits JSONL events such as thread.started,
        # item.started command_execution, item.completed, and turn.completed.
        # This is the non-interactive worker surface for Codex sub-agents.
        cmd = [
            self.agent_bin,
            "exec",
            "--json",
            "--ephemeral",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
        ]
        if model_alias:
            cmd.extend(["--model", model_alias])
        if worker_effort:
            cmd.extend(["--config", f"model_reasoning_effort={worker_effort}"])
        return cmd

    def _notify_complete(self):
        if self.on_complete:
            try:
                self.on_complete(self.run_id)
            except Exception:  # noqa: BLE001 — don't let callback crash worker thread
                pass

    def _on_timeout(self) -> None:
        self._timed_out = True
        self._terminate()

    def _heartbeat(self, stop: threading.Event) -> None:
        while not stop.wait(ACTIVITY_HEARTBEAT_SECONDS):
            with self._inflight_lock:
                busy = bool(self._inflight)
            if busy:
                self.store.touch_activity(self.run_id)

    def _handle_event(self, line: str, last_meaningful_at: float) -> float:
        """Parse one stream-json line and update the live activity summary.
        Tolerant of unknown shapes — the format evolves, so anything we don't
        recognise is ignored. Returns the (possibly updated) timestamp of the
        last *meaningful* tool call, used to debounce no-op tools."""
        try:
            evt = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            return last_meaningful_at
        if not isinstance(evt, dict):
            return last_meaningful_at

        etype = evt.get("type")
        if etype == "assistant":
            content = ((evt.get("message") or {}).get("content")) or []
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tool_id = block.get("id")
                if tool_id:
                    with self._inflight_lock:
                        self._inflight.add(tool_id)
                name = block.get("name") or ""
                now = time.time()
                meaningful = name not in _NOOP_TOOLS
                # Don't let a no-op tool clobber a useful activity set seconds ago.
                if not meaningful and (now - last_meaningful_at) < ACTIVITY_DEBOUNCE_SECONDS:
                    continue
                self.store.set_activity(self.run_id, derive_activity(name, block.get("input")))
                if meaningful:
                    last_meaningful_at = now
        elif etype == "user":
            content = ((evt.get("message") or {}).get("content")) or []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    tool_id = block.get("tool_use_id")
                    if tool_id:
                        with self._inflight_lock:
                            self._inflight.discard(tool_id)
        elif etype == "item.started":
            item = evt.get("item") or {}
            if isinstance(item, dict):
                item_id = item.get("id")
                if item_id:
                    with self._inflight_lock:
                        self._inflight.add(item_id)
                self.store.set_activity(self.run_id, derive_codex_activity(item))
        elif etype == "item.completed":
            item = evt.get("item") or {}
            if isinstance(item, dict):
                item_id = item.get("id")
                if item_id:
                    with self._inflight_lock:
                        self._inflight.discard(item_id)
        return last_meaningful_at

    def cancel(self) -> None:
        self._cancel_requested.set()
        self._terminate()

    def _terminate(self) -> None:
        proc = self.proc
        if not proc:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Daemon (orchestration logic + HTTP server)
# ---------------------------------------------------------------------------

class Daemon:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        orch_cfg = cfg.get("orchestrator", {})
        self.workspace_root = _resolve_workspace_root(orch_cfg.get("workspace_root", ""))
        self.workspace_root.mkdir(parents=True, exist_ok=True)
        self.branch_prefix = orch_cfg.get("branch_prefix", "relay/")
        self.workflow_path = _resolve_workflow_default(orch_cfg.get("default_workflow_path", ""))
        self.worker_timeout = int(orch_cfg.get("worker_timeout_seconds", 1800))
        self.port = int(orch_cfg.get("port", DEFAULT_PORT))

        data = _data_root()
        self.runs = RunsStore(data / "runs.db", index_path=data / "runs.json")
        self.graphify_path = data / "graphify.db"
        self.program_registry_path = _program_registry_path()

        # MVP: single concurrency. Held during the dispatch claim → spawn window
        # (release immediately after spawn — the worker runs in its own thread).
        self._dispatch_lock = threading.Lock()
        self._workers: dict[int, Worker] = {}
        self._workers_lock = threading.Lock()

        stalled = self.runs.reconcile_on_startup()
        if stalled:
            print(f"[orchestrator] reconciled {stalled} stalled run(s) on startup", file=sys.stderr)
        # Seed the runs-index file so the board has something to read before the
        # first transition (reconcile above mutates state directly, bypassing the
        # insert/update write hooks).
        self.runs.write_index()

        agent_setting = orch_cfg.get("agent") or cfg.get("general", {}).get("command") or "codex"
        self.agent_kind = _agent_kind(str(agent_setting))
        self.agent_bin = _find_agent_bin(
            self.agent_kind,
            str(orch_cfg.get("command") or ""),
        )

    # -- prompt rendering -------------------------------------------------

    def _resolve_workflow_for_repo(self, repo_path: str) -> Path:
        repo_template = Path(repo_path) / ".orchestrator" / "WORKFLOW.md"
        if repo_template.is_file():
            return repo_template
        return self.workflow_path

    @staticmethod
    def _validate_workflow_template(template_path: Path, template: str) -> None:
        missing = [
            marker
            for marker in ("{{ticket_id}}", "{{run_id}}")
            if marker not in template
        ]
        if missing:
            raise RuntimeError(
                f"workflow template at {template_path} is not an orchestrator ticket workflow; "
                f"missing template variable(s): {', '.join(missing)}"
            )

    def _build_prompt(
        self, *, ticket_id: str, repo_path: str, branch: str, attempt: int, run_id: int,
        caller_context: str | None = None, workflow_path: Path | None = None,
    ) -> str:
        template_path = workflow_path or self._resolve_workflow_for_repo(repo_path)
        try:
            template = template_path.read_text()
        except OSError as e:
            raise RuntimeError(f"could not read workflow template at {template_path}: {e}") from e
        self._validate_workflow_template(template_path, template)
        # Sub-agents have no memory of the dispatching session. The caller can
        # pass `caller_context` to inject background that doesn't fit in the
        # ticket file (recent decisions, related runs, etc.). Wrap it in a
        # heading only when present so an empty value collapses cleanly.
        if caller_context and caller_context.strip():
            context_block = (
                "## Additional context from the dispatcher\n\n"
                f"{caller_context.strip()}\n"
            )
        else:
            context_block = ""
        return render_template(
            template,
            ticket_id=ticket_id,
            repo_path=repo_path,
            branch=branch,
            attempt=str(attempt),
            run_id=str(run_id),
            caller_context=context_block,
        )

    # -- API -----------------------------------------------------------------

    def _record_dispatch_refusal(
        self,
        *,
        ticket_id: str,
        repo_path: str,
        workspace_path: Path,
        branch: str,
        log_path: Path,
        reason: str,
        sizing: dict[str, Any] | None = None,
    ) -> dict | None:
        attempt = self.runs.next_attempt(ticket_id, repo_path=repo_path)
        metadata = {
            "provider_key": self.agent_kind,
            "model_alias": None,
            "worker_model": None,
            "worker_effort": None,
            "worker_sizing_rationale": None,
            "worker_provider_notes": None,
        }
        if sizing:
            metadata.update(sizing)
        run_id = self.runs.insert(
            ticket_id=ticket_id,
            repo_path=repo_path,
            workspace_path=str(workspace_path),
            branch=branch,
            state="Failed",
            attempt=attempt,
            log_path=str(log_path),
            **metadata,
        )
        self.runs.update(run_id, last_error=reason, ended=True, exit_code=-1)
        return self.runs.get(run_id)

    @staticmethod
    def _resolve_default_branch(repo_path: str) -> str:
        """Resolve the repo's default branch via `git symbolic-ref`. Falls back to 'main'."""
        result = _git(repo_path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", check=False)
        if result.returncode == 0:
            out = result.stdout.strip()
            if out.startswith("origin/"):
                return out[len("origin/"):]
        return "main"

    def dispatch(
        self,
        *,
        ticket_id: str,
        repo_path: str,
        context: str | None = None,
        source: str = "direct",
        relay_command_seq: int | str | None = None,
        relay_command_id: str | None = None,
    ) -> dict:
        if not ticket_id:
            raise ValueError("ticket_id is required")
        if not repo_path:
            raise ValueError("repo_path is required")
        _validate_relay_command(relay_command_seq, relay_command_id)

        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        ticket_file = repo / ".orchestrator" / f"{ticket_id}.md"
        if not ticket_file.is_file():
            raise ValueError(f"ticket {ticket_id} not found at {ticket_file}")
        try:
            ticket = read_ticket(ticket_file)
        except (OSError, TicketParseError) as e:
            raise ValueError(f"ticket {ticket_id} could not be read: {e}") from e

        sanitized = sanitize_identifier(ticket_id)
        branch = f"{self.branch_prefix}{sanitized}"
        workspace_path = self.workspace_root / workspace_slug(str(repo), ticket_id)
        log_path = workspace_path / ".relay" / "run.log"
        base_branch = self._resolve_default_branch(str(repo))

        with self._dispatch_lock:
            existing = self.runs.find_active(ticket_id, repo_path=str(repo))
            if existing:
                print(
                    f"[orchestrator] dispatch skipped for {ticket_id} from {source}: "
                    f"already active run {existing['id']}",
                    file=sys.stderr,
                )
                return {"already_active": True, "run": existing}

            if apply_default_worker_sizing(ticket, self.cfg.get("general", {})):
                write_ticket(ticket_file, ticket)

            try:
                sizing = resolve_worker_sizing(ticket, self.agent_kind)
            except ValueError as e:
                reason = str(e)
                self._record_dispatch_refusal(
                    ticket_id=ticket_id,
                    repo_path=str(repo),
                    workspace_path=workspace_path,
                    branch=branch,
                    log_path=log_path,
                    reason=reason,
                    sizing=raw_worker_sizing_metadata(ticket, self.agent_kind),
                )
                print(
                    f"[orchestrator] dispatch refused for {ticket_id} from {source}: {reason}",
                    file=sys.stderr,
                )
                raise ValueError(reason) from e

            try:
                create_worktree(
                    repo_path=str(repo),
                    workspace_path=workspace_path,
                    branch=branch,
                    base_branch=base_branch,
                )
            except RuntimeError as e:
                # Pre-flight failure — record the attempt as Failed for visibility.
                run_id = self.runs.insert(
                    ticket_id=ticket_id,
                    repo_path=str(repo),
                    workspace_path=str(workspace_path),
                    branch=branch,
                    state="Failed",
                    log_path=str(log_path),
                    **sizing,
                )
                self.runs.update(run_id, last_error=str(e), ended=True, exit_code=-1)
                raise

            # Pre-existing attempts: bump attempt number for THIS ticket.
            attempt = self.runs.next_attempt(ticket_id, repo_path=str(repo))

            run_id = self.runs.insert(
                ticket_id=ticket_id,
                repo_path=str(repo),
                workspace_path=str(workspace_path),
                branch=branch,
                state="Claimed",
                attempt=attempt,
                log_path=str(log_path),
                **sizing,
            )

            workflow_path = self._resolve_workflow_for_repo(str(repo))
            prompt = self._build_prompt(
                ticket_id=ticket_id,
                repo_path=str(repo),
                branch=branch,
                attempt=attempt,
                run_id=run_id,
                caller_context=context,
                workflow_path=workflow_path,
            )

            run = self.runs.get(run_id) or {}
            worker = Worker(
                run_id=run_id, run=run, prompt=prompt, agent_bin=self.agent_bin,
                agent_kind=self.agent_kind, workflow_path=workflow_path,
                store=self.runs, log_path=log_path, timeout_seconds=self.worker_timeout,
                on_complete=self._on_worker_complete,
            )
            with self._workers_lock:
                self._workers[run_id] = worker
            worker.start()

            print(
                f"[orchestrator] dispatch claimed {ticket_id} from {source}: "
                f"run {run_id} ({self.agent_kind})",
                file=sys.stderr,
            )

        return {"already_active": False, "run": self.runs.get(run_id)}

    def _on_worker_complete(self, run_id: int) -> None:
        with self._workers_lock:
            self._workers.pop(run_id, None)
        # Auto-progress dependents. Released both locks before re-entering
        # dispatch so we don't deadlock against another caller that's mid-claim.
        run = self.runs.get(run_id)
        if not run or run.get("state") != "Succeeded":
            return
        try:
            self._progress_dependents(repo_path=run["repo_path"], finished_ticket_id=run["ticket_id"])
        except Exception as e:  # noqa: BLE001 — never crash the worker thread on follow-up failure
            print(f"[orchestrator] dep-progression error for {run['ticket_id']}: {e}", file=sys.stderr)

    def _progress_dependents(self, *, repo_path: str, finished_ticket_id: str) -> None:
        """When a ticket is done in the source repo, dispatch dependents whose deps are done.

        Backlog dependents are promoted to the on-disk `ready` schema value
        only after every predecessor is actually `done` in the source repo.
        Dependents already in `ready` stay queued until this path sees every
        predecessor done, then use the same provider-neutral dispatch chokepoint
        as manually queued work.
        """
        repo = Path(repo_path)
        all_tickets = scan_repo(repo)
        by_id = {t["id"]: t for t in all_tickets}
        finished = by_id.get(finished_ticket_id)
        if not finished or finished["status"] != "done":
            return
        dependents = [t for t in all_tickets if finished_ticket_id in t["depends_on"]]
        for dep in dependents:
            if dep["status"] not in ("backlog", "ready"):
                continue
            if not all_deps_done(dep, all_tickets):
                continue
            if dep["status"] == "backlog":
                dep["status"] = "ready"
                write_ticket(dep["_path"], dep)
            try:
                self.dispatch(ticket_id=dep["id"], repo_path=str(repo), source="dependency-progression")
            except ValueError as e:
                # Daemon refused dispatch (e.g. file missing, already active);
                # the status flip stays — user can drag/redispatch manually.
                print(f"[orchestrator] auto-dispatch declined for {dep['id']}: {e}", file=sys.stderr)

    def _promote_unblocked_dependents(self, *, repo_path: str) -> list[str]:
        """Promote backlog dependents whose dependencies are done in the source repo."""
        repo = Path(repo_path)
        all_tickets = scan_repo(repo)
        promoted: list[str] = []
        for ticket in all_tickets:
            if ticket["status"] != "backlog" or not ticket["depends_on"]:
                continue
            if not all_deps_done(ticket, all_tickets):
                continue
            ticket["status"] = "ready"
            write_ticket(ticket["_path"], ticket)
            promoted.append(ticket["id"])
        return promoted

    def sweep_ready_tickets(self, *, repo_path: str, trigger: str | None = None) -> dict:
        """Reconcile a repo board and dispatch eligible queued tickets.

        The app calls this repeatedly for the active project. It deliberately
        re-enters `dispatch()` for worker creation so Codex/Claude provider
        selection, worktree creation, and active-run idempotency stay in one
        chokepoint.
        """
        if not repo_path:
            raise ValueError("repo_path is required")

        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")

        promoted = self._promote_unblocked_dependents(repo_path=str(repo))
        all_tickets = scan_repo(repo)
        dispatched: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []

        def skip(ticket: dict[str, Any], reason: str, **extra: Any) -> None:
            entry = {"ticket_id": ticket["id"], "reason": reason}
            entry.update(extra)
            skipped.append(entry)

        for ticket in all_tickets:
            if ticket["status"] != "ready":
                skip(ticket, f"status:{ticket['status']}")
                continue
            if ticket["canceled"]:
                skip(ticket, "canceled")
                continue
            if ticket.get("draft"):
                skip(ticket, "draft")
                continue
            if ticket["run_id"] is not None:
                skip(ticket, "run_id_present", run_id=ticket["run_id"])
                continue
            if not all_deps_done(ticket, all_tickets):
                skip(ticket, "dependencies_not_done")
                continue

            existing = self.runs.find_active(ticket["id"], repo_path=str(repo))
            if existing:
                skip(ticket, "already_active", run_id=existing["id"])
                continue

            try:
                result = self.dispatch(
                    ticket_id=ticket["id"],
                    repo_path=str(repo),
                    source="ready-sweeper",
                )
            except (ValueError, RuntimeError) as e:
                skip(ticket, "dispatch_failed", error=str(e))
                print(
                    f"[orchestrator] ready-sweeper dispatch failed for {ticket['id']}: {e}",
                    file=sys.stderr,
                )
                continue

            run = result.get("run") or {}
            run_id = run.get("id")
            if result.get("already_active"):
                skip(ticket, "already_active", run_id=run_id)
                continue

            dispatched.append({"ticket_id": ticket["id"], "run_id": run_id})
            trigger_note = f" after {trigger}" if trigger else ""
            print(
                f"[orchestrator] ready-sweeper auto-dispatched {ticket['id']}"
                f"{trigger_note}: run {run_id}",
                file=sys.stderr,
            )

        return {
            "repo_path": str(repo),
            "trigger": trigger,
            "promoted": promoted,
            "dispatched": dispatched,
            "skipped": skipped,
        }

    def sweep_program_ready_tickets(self, *, trigger: str | None = None) -> dict:
        """Reconcile queued tickets across every registered project.

        Program Board refresh uses this instead of requiring each project board
        to be opened. Each ticket still dispatches through `dispatch()`, so
        Codex/Claude launch behavior and active-run idempotency stay shared.
        """
        projects: list[dict[str, Any]] = []
        dispatched: list[dict[str, Any]] = []
        skipped: list[dict[str, Any]] = []
        for repo_path in _registered_project_repo_paths(self.program_registry_path):
            try:
                result = self.sweep_ready_tickets(
                    repo_path=repo_path,
                    trigger=trigger or "program-ready-sweep",
                )
            except (ValueError, RuntimeError) as e:
                entry = {"repo_path": repo_path, "error": str(e)}
                projects.append(entry)
                skipped.append(entry)
                continue

            projects.append(result)
            for item in result.get("dispatched", []):
                dispatched.append({"repo_path": result["repo_path"], **item})
            for item in result.get("skipped", []):
                skipped.append({"repo_path": result["repo_path"], **item})

        return {
            "trigger": trigger,
            "projects": projects,
            "dispatched": dispatched,
            "skipped": skipped,
        }

    def list_runs(self, state: str | None = None, limit: int = 100) -> list[dict]:
        return self.runs.list(state=state, limit=limit)

    def get_run(self, run_id: int) -> dict | None:
        return self.runs.get(run_id)

    def program_status(
        self,
        *,
        query: str | None = None,
        provider: str | None = None,
        limit: int = 8,
    ) -> dict:
        store = GraphifyCoreStore(self.graphify_path)
        counts = ingest_registered_projects(
            store,
            registry_path=self.program_registry_path,
            runs_db_path=self.runs.path,
            index_files=False,
        )
        if counts["projects"] == 0:
            return {
                "query": query or "summary",
                "provider": provider,
                "message": (
                    f"No registered projects found at {self.program_registry_path}. "
                    "Activate a project by path or start a Relay bridge in a git repo, then ask again."
                ),
                "items": [],
                "counts": {"projects": 0, "items": 0},
            }
        return build_program_status(
            store,
            query=query,
            provider=provider,
            limit=limit,
        )

    def session_capture(
        self,
        *,
        repo_path: str | None = None,
        entries: list[dict[str, Any]] | None = None,
        ticket_id: str | None = None,
        run_id: int | str | None = None,
        provider: str | None = None,
        context: str | None = None,
        capture_id: str | None = None,
        source: str = "session_capture",
    ) -> dict:
        store = GraphifyCoreStore(self.graphify_path)
        counts = ingest_registered_projects(
            store,
            registry_path=self.program_registry_path,
            runs_db_path=self.runs.path,
            index_files=False,
        )
        result = capture_session_review(
            store,
            repo_path=repo_path,
            entries=entries,
            ticket_id=ticket_id,
            run_id=run_id,
            provider=provider,
            context=context,
            capture_id=capture_id,
            source=source,
        )
        result["ingest_counts"] = counts
        return result

    def cancel_run(self, run_id: int, *, prune_worktree: bool = True) -> dict:
        run = self.runs.get(run_id)
        if not run:
            raise ValueError(f"unknown run_id {run_id}")
        if run["state"] not in self.runs.ACTIVE_STATES and run["state"] != "Stalled":
            return {"canceled": False, "reason": f"run is in terminal state {run['state']}", "run": run}

        with self._workers_lock:
            worker = self._workers.get(run_id)
        if worker:
            worker.cancel()
            if worker.thread:
                worker.thread.join(timeout=10)
        else:
            self.runs.update(run_id, state="Canceled",
                             last_error="Canceled (no live worker)", ended=True)

        result: dict = {"canceled": True, "run": self.runs.get(run_id)}
        if prune_worktree:
            repo_path = run.get("repo_path")
            if repo_path:
                removed, error = remove_worktree(
                    repo_path, Path(run["workspace_path"])
                )
                result["worktree_removed"] = removed
                if error:
                    result["worktree_error"] = error
                # Drop the throwaway branch ref so a re-dispatch starts fresh off the
                # current default branch instead of attaching to the old tip.
                delete_branch(repo_path, run["branch"])
        return result

    def shutdown(self) -> None:
        with self._workers_lock:
            workers = list(self._workers.values())
        for w in workers:
            w.cancel()


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload, default=str).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _read_body(handler: BaseHTTPRequestHandler) -> dict:
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    if not raw:
        return {}
    try:
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except json.JSONDecodeError:
        return {}


class Handler(BaseHTTPRequestHandler):
    daemon: Daemon  # set by serve()

    server_version = "RelayOrchestrator/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[orchestrator-http] {self.address_string()} {fmt % args}\n")

    def _route(self, method: str, path: str) -> tuple[int, Any]:
        parsed = urlparse(path)
        segments = [s for s in parsed.path.split("/") if s]
        query = parse_qs(parsed.query)

        try:
            if method == "GET" and segments == ["v1", "health"]:
                return 200, {"ok": True, "version": self.server_version}

            if method == "GET" and segments == ["v1", "runs"]:
                state = (query.get("state") or [None])[0]
                limit = int((query.get("limit") or ["100"])[0])
                return 200, {"runs": self.daemon.list_runs(state=state, limit=limit)}

            if method == "GET" and segments == ["v1", "program", "status"]:
                status_query = (query.get("query") or ["summary"])[0]
                provider = (query.get("provider") or [None])[0]
                limit = int((query.get("limit") or ["8"])[0])
                return 200, self.daemon.program_status(
                    query=status_query,
                    provider=provider,
                    limit=limit,
                )

            if method == "POST" and segments == ["v1", "program", "capture"]:
                body = _read_body(self)
                result = self.daemon.session_capture(
                    repo_path=body.get("repo_path"),
                    entries=body.get("entries"),
                    ticket_id=body.get("ticket_id"),
                    run_id=body.get("run_id"),
                    provider=body.get("provider"),
                    context=body.get("context"),
                    capture_id=body.get("capture_id"),
                    source=body.get("source") or "session_capture",
                )
                return 201, result

            if method == "POST" and segments == ["v1", "runs"]:
                body = _read_body(self)
                dispatch_args: dict[str, Any] = {
                    "ticket_id": body.get("ticket_id", ""),
                    "repo_path": body.get("repo_path", ""),
                    "context": body.get("context"),
                    "source": body.get("source") or "direct",
                }
                if body.get("relay_command_seq") is not None:
                    dispatch_args["relay_command_seq"] = body.get("relay_command_seq")
                if body.get("relay_command_id"):
                    dispatch_args["relay_command_id"] = body.get("relay_command_id")
                result = self.daemon.dispatch(**dispatch_args)
                return (200 if result["already_active"] else 202), result

            if method == "POST" and segments == ["v1", "ready-sweep"]:
                body = _read_body(self)
                result = self.daemon.sweep_ready_tickets(
                    repo_path=body.get("repo_path", ""),
                    trigger=body.get("trigger"),
                )
                return 200, result

            if method == "POST" and segments == ["v1", "program", "ready-sweep"]:
                body = _read_body(self)
                result = self.daemon.sweep_program_ready_tickets(
                    trigger=body.get("trigger"),
                )
                return 200, result

            if method == "GET" and len(segments) == 3 and segments[:2] == ["v1", "runs"]:
                run = self.daemon.get_run(int(segments[2]))
                return (200 if run else 404), {"run": run}

            if (method == "POST" and len(segments) == 4
                    and segments[:2] == ["v1", "runs"] and segments[3] == "cancel"):
                body = _read_body(self)
                prune = bool(body.get("prune_worktree", True))
                result = self.daemon.cancel_run(int(segments[2]), prune_worktree=prune)
                return 200, result

            return 404, {"error": f"no route for {method} {parsed.path}"}
        except ValueError as e:
            return 400, {"error": str(e)}
        except RuntimeError as e:
            return 500, {"error": str(e)}

    def do_GET(self) -> None:
        status, payload = self._route("GET", self.path)
        _json_response(self, status, payload)

    def do_POST(self) -> None:
        status, payload = self._route("POST", self.path)
        _json_response(self, status, payload)


def _bind_port(preferred: int) -> tuple[ThreadingHTTPServer, int]:
    """Bind preferred port; if taken (or preferred=0), pick an ephemeral one. Returns (server, actual_port)."""
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", preferred), Handler)
    except OSError:
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    # server_address is the truth — kernel may have picked any port when preferred=0
    # or when SO_REUSEADDR resolves a benign collision.
    return srv, srv.server_address[1]


def _write_port_file(port: int) -> None:
    try:
        PORT_FILE.write_text(str(port))
    except OSError as e:
        print(f"[orchestrator] could not write port file {PORT_FILE}: {e}", file=sys.stderr)


def _clear_port_file() -> None:
    try:
        PORT_FILE.unlink()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

def serve(daemon: Daemon) -> None:
    Handler.daemon = daemon
    server, port = _bind_port(daemon.port)
    daemon.port = port
    _write_port_file(port)
    print(f"[orchestrator] listening on http://127.0.0.1:{port}", file=sys.stderr)

    stop = threading.Event()

    def _signal_handler(signum, _frame):
        print(f"[orchestrator] caught signal {signum}, shutting down", file=sys.stderr)
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _signal_handler)
        except (OSError, ValueError):
            pass

    # Periodic prune sweep: transitions keep the index current, but a run that
    # completes and then sees no further transitions would linger past its
    # retention window without this. Rewriting drops expired entries.
    def _prune_loop():
        while not stop.wait(30):
            daemon.runs.write_index()

    threading.Thread(target=_prune_loop, name="runs-index-pruner", daemon=True).start()

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        daemon.shutdown()
        _clear_port_file()
        print("[orchestrator] stopped", file=sys.stderr)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="relay-runner orchestrator daemon")
    parser.add_argument("--config", help="path to config.toml (otherwise uses default location)")
    parser.add_argument("--print-port", action="store_true",
                        help="print the bound port to stdout (after binding) for callers that scrape it")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    cfg = load_config(args.config) if args.config else load_config()
    daemon = Daemon(cfg)
    if args.print_port:
        # Print early — port file still gets written by serve().
        print(daemon.port)
    serve(daemon)


if __name__ == "__main__":
    main()
