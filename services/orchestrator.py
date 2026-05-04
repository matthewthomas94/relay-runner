#!/usr/bin/env python3
"""Relay-runner orchestrator daemon.

Symphony-style sub-agent orchestrator: links Linear projects to local git repos,
dispatches issues to autonomous `claude -p` runs in isolated worktrees, and tracks
state in SQLite. HTTP API on 127.0.0.1; MCP tool surface is the thin Swift proxy
in Sources/relay-orchestrator-mcp/ which calls these endpoints.

MVP scope: voice/MCP-driven dispatch only. The daemon does not talk to Linear —
the spawned worker uses the user's Linear MCP to read issue context and post
status comments back. Autonomous Linear polling lands in v1 behind a
`[orchestrator].linear_api_key` config.
"""

from __future__ import annotations

import argparse
import json
import os
import re
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

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        tomllib = None  # type: ignore

# Reuse the existing config loader (sibling file).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load_config

PORT_FILE = Path("/tmp/relay_orchestrator.port")
DEFAULT_PORT = 7634


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _data_root() -> Path:
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    return base / "relay-runner" / "orchestrator"


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


def _find_claude_bin() -> str:
    p = shutil.which("claude")
    if p:
        return p
    fallback = os.path.expanduser("~/.local/bin/claude")
    if os.access(fallback, os.X_OK):
        return fallback
    raise RuntimeError("claude CLI not found on PATH or at ~/.local/bin/claude")


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


_TEMPLATE_RE = re.compile(r"\{\{\s*([\w_]+)\s*\}\}")


def render_template(template: str, **vars: Any) -> str:
    """Tiny `{{key}}` renderer. Missing keys → empty string. No escaping (we trust the template)."""
    return _TEMPLATE_RE.sub(lambda m: str(vars.get(m.group(1).strip(), "")), template)


def _toml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


# ---------------------------------------------------------------------------
# Stores
# ---------------------------------------------------------------------------

class ProjectsStore:
    """Human-readable TOML store for project links.

    File layout:
        [projects.<linear_project_id>]
        linear_project_id = "..."
        repo_path = "..."
        repo_remote = "..."
        default_branch = "main"
        created_at = 1700000000.0
    """

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def _read(self) -> dict[str, dict]:
        if not self.path.exists() or tomllib is None:
            return {}
        try:
            with open(self.path, "rb") as f:
                data = tomllib.load(f)
        except (OSError, ValueError, tomllib.TOMLDecodeError):  # type: ignore[attr-defined]
            return {}
        return data.get("projects", {}) or {}

    def _write(self, projects: dict[str, dict]) -> None:
        lines = [
            "# relay-runner orchestrator project links — managed by the daemon.",
            "# Edit via the link_project / unlink_project MCP tools, not by hand.",
            "",
        ]
        for key in sorted(projects):
            project = projects[key]
            lines.append(f'[projects."{_toml_escape(key)}"]')
            for field in ("linear_project_id", "repo_path", "repo_remote", "default_branch"):
                if field in project:
                    lines.append(f'{field} = "{_toml_escape(str(project[field]))}"')
            if "created_at" in project:
                lines.append(f"created_at = {float(project['created_at'])}")
            lines.append("")
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text("\n".join(lines))
        tmp.replace(self.path)

    def add(self, *, linear_project_id: str, repo_path: str, repo_remote: str, default_branch: str) -> dict:
        record = {
            "linear_project_id": linear_project_id,
            "repo_path": str(Path(repo_path).expanduser().resolve()),
            "repo_remote": repo_remote,
            "default_branch": default_branch or "main",
            "created_at": time.time(),
        }
        with self._lock:
            projects = self._read()
            projects[linear_project_id] = record
            self._write(projects)
        return record

    def remove(self, linear_project_id: str) -> bool:
        with self._lock:
            projects = self._read()
            if linear_project_id not in projects:
                return False
            del projects[linear_project_id]
            self._write(projects)
            return True

    def get(self, linear_project_id: str) -> dict | None:
        with self._lock:
            return self._read().get(linear_project_id)

    def list(self) -> list[dict]:
        with self._lock:
            return list(self._read().values())


class RunsStore:
    SCHEMA = """
    CREATE TABLE IF NOT EXISTS runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        issue_identifier TEXT NOT NULL,
        linear_project_id TEXT NOT NULL,
        workspace_path TEXT NOT NULL,
        branch TEXT NOT NULL,
        state TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        pid INTEGER,
        started_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER,
        log_path TEXT,
        last_error TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_runs_state ON runs(state);
    CREATE INDEX IF NOT EXISTS idx_runs_issue ON runs(issue_identifier);
    """

    ACTIVE_STATES = ("Claimed", "Running")

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
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
        with self._conn() as c:
            c.executescript(self.SCHEMA)

    def insert(self, *, issue_identifier: str, linear_project_id: str, workspace_path: str,
               branch: str, state: str, attempt: int = 1, log_path: str | None = None) -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO runs(issue_identifier, linear_project_id, workspace_path, branch, "
                "state, attempt, started_at, log_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (issue_identifier, linear_project_id, workspace_path, branch,
                 state, attempt, time.time(), log_path),
            )
            return int(cur.lastrowid)

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

    def find_active(self, issue_identifier: str) -> dict | None:
        ph = ",".join("?" * len(self.ACTIVE_STATES))
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM runs WHERE issue_identifier = ? AND state IN ({ph}) "
                "ORDER BY id DESC LIMIT 1",
                (issue_identifier, *self.ACTIVE_STATES),
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

    def next_attempt(self, issue_identifier: str) -> int:
        """Returns the attempt number to use for a new run on this issue (1 if none, max+1 otherwise)."""
        with self._conn() as c:
            row = c.execute(
                "SELECT MAX(attempt) AS a FROM runs WHERE issue_identifier = ?",
                (issue_identifier,),
            ).fetchone()
            if row and row["a"]:
                return int(row["a"]) + 1
            return 1


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


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class Worker:
    """One `claude -p` subprocess running against a worktree. Owns its own thread."""

    def __init__(self, *, run_id: int, run: dict, prompt: str, claude_bin: str,
                 store: RunsStore, log_path: Path, timeout_seconds: int,
                 on_complete: Callable[[int], None] | None = None):
        self.run_id = run_id
        self.run = run
        self.prompt = prompt
        self.claude_bin = claude_bin
        self.store = store
        self.log_path = log_path
        self.timeout_seconds = timeout_seconds
        self.on_complete = on_complete
        self.proc: subprocess.Popen | None = None
        self.thread: threading.Thread | None = None
        self._cancel_requested = threading.Event()

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
            cmd = [
                self.claude_bin, "-p",
                "--output-format", "json",
                "--dangerously-skip-permissions",
            ]
            try:
                self.proc = subprocess.Popen(
                    cmd,
                    cwd=self.run["workspace_path"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
            except FileNotFoundError as e:
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"claude CLI not found: {e}",
                                  ended=True, exit_code=-1)
                log.write(f"[orchestrator] claude CLI not found: {e}\n")
                return

            self.store.update(self.run_id, state="Running", pid=self.proc.pid)

            try:
                stdout, _ = self.proc.communicate(input=self.prompt, timeout=self.timeout_seconds)
            except subprocess.TimeoutExpired:
                log.write(f"\n[orchestrator] worker timed out at {self.timeout_seconds}s\n")
                self._terminate()
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"Timed out after {self.timeout_seconds}s",
                                  ended=True, exit_code=-1)
                return

            if stdout:
                log.write(stdout)
            log.flush()
            rc = self.proc.returncode

            if self._cancel_requested.is_set():
                self.store.update(self.run_id, state="Canceled", ended=True, exit_code=rc)
            elif rc == 0:
                self.store.update(self.run_id, state="Succeeded", ended=True, exit_code=rc)
            elif rc in (-9, -15):
                self.store.update(self.run_id, state="Canceled", ended=True, exit_code=rc)
            else:
                tail = (stdout or "").splitlines()[-5:]
                self.store.update(self.run_id, state="Failed",
                                  last_error=f"exit={rc}; tail={' / '.join(tail)[:500]}",
                                  ended=True, exit_code=rc)
        finally:
            try:
                log.close()
            except OSError:
                pass
            self._notify_complete()

    def _notify_complete(self):
        if self.on_complete:
            try:
                self.on_complete(self.run_id)
            except Exception:  # noqa: BLE001 — don't let callback crash worker thread
                pass

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
        self.projects = ProjectsStore(data / "projects.toml")
        self.runs = RunsStore(data / "runs.db")

        # MVP: single concurrency. Held during the dispatch claim → spawn window
        # (release immediately after spawn — the worker runs in its own thread).
        # Concurrency > 1 lands in v1 alongside Linear polling.
        self._dispatch_lock = threading.Lock()
        self._workers: dict[int, Worker] = {}
        self._workers_lock = threading.Lock()

        stalled = self.runs.reconcile_on_startup()
        if stalled:
            print(f"[orchestrator] reconciled {stalled} stalled run(s) on startup", file=sys.stderr)

        self.claude_bin = _find_claude_bin()

    # -- prompt rendering -------------------------------------------------

    def _resolve_workflow_for_repo(self, repo_path: str) -> Path:
        repo_template = Path(repo_path) / "WORKFLOW.md"
        if repo_template.is_file():
            return repo_template
        return self.workflow_path

    def _build_prompt(self, *, identifier: str, repo_path: str, branch: str, attempt: int) -> str:
        template_path = self._resolve_workflow_for_repo(repo_path)
        try:
            template = template_path.read_text()
        except OSError as e:
            raise RuntimeError(f"could not read workflow template at {template_path}: {e}") from e
        return render_template(
            template,
            identifier=identifier,
            repo_path=repo_path,
            branch=branch,
            attempt=str(attempt),
        )

    # -- API -----------------------------------------------------------------

    def link_project(self, *, linear_project_id: str, repo_path: str, repo_remote: str,
                     default_branch: str | None = None) -> dict:
        if not linear_project_id:
            raise ValueError("linear_project_id is required")
        repo = Path(repo_path).expanduser()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        new_default = default_branch or "main"

        existing = self.projects.get(linear_project_id)
        record = self.projects.add(
            linear_project_id=linear_project_id,
            repo_path=str(repo.resolve()),
            repo_remote=repo_remote,
            default_branch=new_default,
        )

        # If default_branch changed while runs are still active, the existing
        # worktrees stay on the old base. Warn so the caller knows to cancel +
        # redispatch to migrate them.
        if existing and existing.get("default_branch", "main") != new_default:
            old_default = existing.get("default_branch", "main")
            affected = [
                r for r in self.runs.list(limit=1000)
                if r["linear_project_id"] == linear_project_id
                and r["state"] in self.runs.ACTIVE_STATES
            ]
            if affected:
                ids = ", ".join(
                    f"run {r['id']} ({r['issue_identifier']})" for r in affected
                )
                warning = (
                    f"default_branch changed {old_default!r} -> {new_default!r} for "
                    f"project {linear_project_id!r}, but {len(affected)} active run(s) "
                    f"are still based on {old_default!r}: {ids}. Cancel and redispatch "
                    f"to migrate them to {new_default!r}."
                )
                print(f"[orchestrator] WARNING: {warning}", file=sys.stderr)
                return {**record, "warnings": [warning]}

        return record

    def unlink_project(self, linear_project_id: str) -> bool:
        return self.projects.remove(linear_project_id)

    def list_projects(self) -> list[dict]:
        return self.projects.list()

    def dispatch(self, *, identifier: str, linear_project_id: str | None = None) -> dict:
        if not identifier:
            raise ValueError("issue identifier is required")

        # Resolve project link.
        project = None
        if linear_project_id:
            project = self.projects.get(linear_project_id)
            if not project:
                raise ValueError(f"no link for linear_project_id={linear_project_id!r}")
        else:
            projects = self.projects.list()
            if not projects:
                raise ValueError("no linked projects — run link_project first")
            if len(projects) > 1:
                raise ValueError(
                    "multiple linked projects exist — pass linear_project_id explicitly"
                )
            project = projects[0]

        sanitized = sanitize_identifier(identifier)
        branch = f"{self.branch_prefix}{sanitized}"
        workspace_path = self.workspace_root / sanitized
        log_path = workspace_path / ".relay" / "run.log"

        with self._dispatch_lock:
            existing = self.runs.find_active(identifier)
            if existing:
                return {"already_active": True, "run": existing}

            try:
                create_worktree(
                    repo_path=project["repo_path"],
                    workspace_path=workspace_path,
                    branch=branch,
                    base_branch=project.get("default_branch", "main"),
                )
            except RuntimeError as e:
                # Pre-flight failure — record the attempt as Failed for visibility.
                run_id = self.runs.insert(
                    issue_identifier=identifier,
                    linear_project_id=project["linear_project_id"],
                    workspace_path=str(workspace_path),
                    branch=branch,
                    state="Failed",
                    log_path=str(log_path),
                )
                self.runs.update(run_id, last_error=str(e), ended=True, exit_code=-1)
                raise

            # Pre-existing attempts: bump attempt number for THIS issue.
            attempt = self.runs.next_attempt(identifier)

            prompt = self._build_prompt(
                identifier=identifier,
                repo_path=project["repo_path"],
                branch=branch,
                attempt=attempt,
            )

            run_id = self.runs.insert(
                issue_identifier=identifier,
                linear_project_id=project["linear_project_id"],
                workspace_path=str(workspace_path),
                branch=branch,
                state="Claimed",
                attempt=attempt,
                log_path=str(log_path),
            )

            run = self.runs.get(run_id) or {}
            worker = Worker(
                run_id=run_id, run=run, prompt=prompt, claude_bin=self.claude_bin,
                store=self.runs, log_path=log_path, timeout_seconds=self.worker_timeout,
                on_complete=self._on_worker_complete,
            )
            with self._workers_lock:
                self._workers[run_id] = worker
            worker.start()

        return {"already_active": False, "run": self.runs.get(run_id)}

    def _on_worker_complete(self, run_id: int) -> None:
        with self._workers_lock:
            self._workers.pop(run_id, None)

    def list_runs(self, state: str | None = None, limit: int = 100) -> list[dict]:
        return self.runs.list(state=state, limit=limit)

    def get_run(self, run_id: int) -> dict | None:
        return self.runs.get(run_id)

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
            project = self.projects.get(run["linear_project_id"])
            if project:
                removed, error = remove_worktree(
                    project["repo_path"], Path(run["workspace_path"])
                )
                result["worktree_removed"] = removed
                if error:
                    result["worktree_error"] = error
                # Drop the throwaway branch ref so a re-dispatch starts fresh off the
                # current default_branch instead of attaching to the old tip.
                delete_branch(project["repo_path"], run["branch"])
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

            if method == "GET" and segments == ["v1", "projects"]:
                return 200, {"projects": self.daemon.list_projects()}

            if method == "POST" and segments == ["v1", "projects"]:
                body = _read_body(self)
                project = self.daemon.link_project(
                    linear_project_id=body.get("linear_project_id", ""),
                    repo_path=body.get("repo_path", ""),
                    repo_remote=body.get("repo_remote", ""),
                    default_branch=body.get("default_branch") or "main",
                )
                return 200, {"project": project}

            if method == "DELETE" and len(segments) == 3 and segments[:2] == ["v1", "projects"]:
                removed = self.daemon.unlink_project(segments[2])
                return (200 if removed else 404), {"removed": removed}

            if method == "GET" and segments == ["v1", "runs"]:
                state = (query.get("state") or [None])[0]
                limit = int((query.get("limit") or ["100"])[0])
                return 200, {"runs": self.daemon.list_runs(state=state, limit=limit)}

            if method == "POST" and segments == ["v1", "runs"]:
                body = _read_body(self)
                result = self.daemon.dispatch(
                    identifier=body.get("identifier", ""),
                    linear_project_id=body.get("linear_project_id"),
                )
                return (200 if result["already_active"] else 202), result

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

    def do_DELETE(self) -> None:
        status, payload = self._route("DELETE", self.path)
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
    if tomllib is None:
        print(
            "[orchestrator] error: tomllib is not available. Run under Python 3.11+ "
            "or `pip install tomli` in the active environment.",
            file=sys.stderr,
        )
        sys.exit(2)
    cfg = load_config(args.config) if args.config else load_config()
    daemon = Daemon(cfg)
    if args.print_port:
        # Print early — port file still gets written by serve().
        print(daemon.port)
    serve(daemon)


if __name__ == "__main__":
    main()
