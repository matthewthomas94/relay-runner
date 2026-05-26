#!/usr/bin/env python3
"""Relay-runner orchestrator daemon.

Symphony-style sub-agent orchestrator: dispatches tickets from a repo's local
kanban board (`<repo>/.orchestrator/<ticket_id>.md`) to autonomous `claude`
runs in isolated worktrees, and tracks state in SQLite. HTTP API on 127.0.0.1;
MCP tool surface is the thin Swift proxy in Sources/relay-orchestrator-mcp/
which calls these endpoints.

MVP scope: voice/MCP-driven dispatch only. The repo is the source of truth —
tickets live as version-controlled markdown under `.orchestrator/`, and the
sub-agent edits its ticket's YAML frontmatter + appends a "## Run log" section
when it finishes. No external service is involved.
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

# Reuse the existing config loader (sibling file).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load_config
from tickets import scan_repo, write as write_ticket, all_deps_done

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


# ---------------------------------------------------------------------------
# Stores
# ---------------------------------------------------------------------------

class RunsStore:
    SCHEMA_VERSION = 2  # bump when the runs table shape changes

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
        last_error TEXT
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
               branch: str, state: str, attempt: int = 1, log_path: str | None = None) -> int:
        with self._conn() as c:
            cur = c.execute(
                "INSERT INTO runs(ticket_id, repo_path, workspace_path, branch, "
                "state, attempt, started_at, log_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (ticket_id, repo_path, workspace_path, branch,
                 state, attempt, time.time(), log_path),
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

    def find_active(self, ticket_id: str) -> dict | None:
        ph = ",".join("?" * len(self.ACTIVE_STATES))
        with self._conn() as c:
            row = c.execute(
                f"SELECT * FROM runs WHERE ticket_id = ? AND state IN ({ph}) "
                "ORDER BY id DESC LIMIT 1",
                (ticket_id, *self.ACTIVE_STATES),
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

    def next_attempt(self, ticket_id: str) -> int:
        """Returns the attempt number to use for a new run on this ticket (1 if none, max+1 otherwise)."""
        with self._conn() as c:
            row = c.execute(
                "SELECT MAX(attempt) AS a FROM runs WHERE ticket_id = ?",
                (ticket_id,),
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


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class Worker:
    """One `claude` subprocess running against a worktree. Owns its own thread."""

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
                self.claude_bin,
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
        self.runs = RunsStore(data / "runs.db", index_path=data / "runs.json")

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

        self.claude_bin = _find_claude_bin()

    # -- prompt rendering -------------------------------------------------

    def _resolve_workflow_for_repo(self, repo_path: str) -> Path:
        repo_template = Path(repo_path) / "WORKFLOW.md"
        if repo_template.is_file():
            return repo_template
        return self.workflow_path

    def _build_prompt(
        self, *, ticket_id: str, repo_path: str, branch: str, attempt: int, run_id: int,
        caller_context: str | None = None,
    ) -> str:
        template_path = self._resolve_workflow_for_repo(repo_path)
        try:
            template = template_path.read_text()
        except OSError as e:
            raise RuntimeError(f"could not read workflow template at {template_path}: {e}") from e
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

    @staticmethod
    def _resolve_default_branch(repo_path: str) -> str:
        """Resolve the repo's default branch via `git symbolic-ref`. Falls back to 'main'."""
        result = _git(repo_path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", check=False)
        if result.returncode == 0:
            out = result.stdout.strip()
            if out.startswith("origin/"):
                return out[len("origin/"):]
        return "main"

    def dispatch(self, *, ticket_id: str, repo_path: str,
                 context: str | None = None) -> dict:
        if not ticket_id:
            raise ValueError("ticket_id is required")
        if not repo_path:
            raise ValueError("repo_path is required")

        repo = Path(repo_path).expanduser().resolve()
        if not repo.is_dir() or not (repo / ".git").exists():
            raise ValueError(f"repo_path {repo} is not a git repository")
        ticket_file = repo / ".orchestrator" / f"{ticket_id}.md"
        if not ticket_file.is_file():
            raise ValueError(f"ticket {ticket_id} not found at {ticket_file}")

        sanitized = sanitize_identifier(ticket_id)
        branch = f"{self.branch_prefix}{sanitized}"
        workspace_path = self.workspace_root / sanitized
        log_path = workspace_path / ".relay" / "run.log"
        base_branch = self._resolve_default_branch(str(repo))

        with self._dispatch_lock:
            existing = self.runs.find_active(ticket_id)
            if existing:
                return {"already_active": True, "run": existing}

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
                )
                self.runs.update(run_id, last_error=str(e), ended=True, exit_code=-1)
                raise

            # Pre-existing attempts: bump attempt number for THIS ticket.
            attempt = self.runs.next_attempt(ticket_id)

            run_id = self.runs.insert(
                ticket_id=ticket_id,
                repo_path=str(repo),
                workspace_path=str(workspace_path),
                branch=branch,
                state="Claimed",
                attempt=attempt,
                log_path=str(log_path),
            )

            prompt = self._build_prompt(
                ticket_id=ticket_id,
                repo_path=str(repo),
                branch=branch,
                attempt=attempt,
                run_id=run_id,
                caller_context=context,
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
        """When a ticket completes, scan dependents and dispatch any backlog
        tickets whose deps are now fully satisfied. Flips status to 'ready'
        on disk before dispatching — the daemon writing ticket files is the
        deliberate exception to 'sub-agents own the ticket file'.
        """
        repo = Path(repo_path)
        all_tickets = scan_repo(repo)
        dependents = [t for t in all_tickets if finished_ticket_id in t["depends_on"]]
        for dep in dependents:
            if dep["status"] != "backlog":
                continue
            if not all_deps_done(dep, all_tickets):
                continue
            dep["status"] = "ready"
            write_ticket(dep["_path"], dep)
            try:
                self.dispatch(ticket_id=dep["id"], repo_path=str(repo))
            except ValueError as e:
                # Daemon refused dispatch (e.g. file missing, already active);
                # the status flip stays — user can drag/redispatch manually.
                print(f"[orchestrator] auto-dispatch declined for {dep['id']}: {e}", file=sys.stderr)

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

            if method == "POST" and segments == ["v1", "runs"]:
                body = _read_body(self)
                result = self.daemon.dispatch(
                    ticket_id=body.get("ticket_id", ""),
                    repo_path=body.get("repo_path", ""),
                    context=body.get("context"),
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
