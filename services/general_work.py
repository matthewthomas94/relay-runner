"""Daemon-owned, repository-independent tasks and reviewed local artifacts.

The database is the only task writer. Worker directories contain output, never
board metadata or a manufactured source repository. Restart recovery records an
interruption and requires an explicit retry; it does not replay accepted work.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import threading
import time
import uuid

from claude_subscription import METERED_ENVIRONMENT


def general_worker_environment(files_root=None):
    excluded = {*METERED_ENVIRONMENT, "ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY",
                "RELAY_GENERAL_FILES_ROOT", "RELAY_PROVIDER_SESSION_ID", "RELAY_PROVIDER_PROCESS_ID", "RELAY_APP_SESSION_ID"}
    environment = {key: value for key, value in os.environ.items() if key not in excluded
                   and not key.startswith(("RELAY_PROJECT_", "RELAY_SESSION_", "RELAY_CONTEXT_"))}
    environment["RELAY_SESSION_SCOPE"] = "general"
    if files_root is not None:
        environment["RELAY_GENERAL_FILES_ROOT"] = str(files_root)
    return environment


class GeneralWorkStore:
    def __init__(self, root: Path, *, command_factory=None, preflight=None, runner=None, personal_storage=None):
        self.root = Path(root).expanduser().resolve()
        self.state = self.root / "general"
        self.files = self.root / "files" / "tasks"
        self.state.mkdir(parents=True, exist_ok=True)
        self.files.mkdir(parents=True, exist_ok=True)
        self.path = self.state / "work.db"
        self.command_factory = command_factory
        self.preflight = preflight
        self.personal_storage = personal_storage
        self.runner = runner or self._run_process
        self._lock = threading.RLock()
        self._processes = {}
        self._cancellations = {}
        with self._connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
                    request_hash TEXT NOT NULL, document TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL,
                    run_id TEXT, kind TEXT NOT NULL, at REAL NOT NULL, detail TEXT NOT NULL);
            """)
            for row in db.execute("SELECT document FROM tasks").fetchall():
                task = json.loads(row[0])
                if task["status"] == "in_progress":
                    run = task["runs"][-1]
                    run.update(state="interrupted", ended_at=time.time(),
                               error="Relay Runner restarted. Review preserved files and explicitly retry; no action was replayed.")
                    task["status"] = "interrupted"
                    self._save(db, task, "interrupted", run["id"])

    @contextmanager
    def _connect(self):
        db = sqlite3.connect(str(self.path), timeout=15)
        try:
            db.execute("PRAGMA journal_mode=WAL")
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def _save(db, task, kind, run_id=None, detail=None):
        task["updated_at"] = time.time()
        db.execute("UPDATE tasks SET document=? WHERE id=?", (json.dumps(task), task["id"]))
        db.execute("INSERT INTO events(task_id,run_id,kind,at,detail) VALUES(?,?,?,?,?)",
                   (task["id"], run_id, kind, task["updated_at"], json.dumps(detail or {})))

    @staticmethod
    def _load(db, task_id):
        row = db.execute("SELECT document FROM tasks WHERE id=?", (task_id,)).fetchone()
        if not row:
            raise ValueError("General task not found")
        return json.loads(row[0])

    def create(self, *, title, description, acceptance_criteria, request_id):
        if not all(isinstance(value, str) and value.strip() for value in (title, description, request_id)):
            raise ValueError("title, description and request_id are required")
        if not isinstance(acceptance_criteria, list) or not acceptance_criteria or not all(
                isinstance(value, str) and value.strip() for value in acceptance_criteria):
            raise ValueError("Provide at least one actionable acceptance criterion")
        if len(title) > 200 or len(description) > 50000 or len(acceptance_criteria) > 50:
            raise ValueError("General task description is too large")
        payload = dict(title=title.strip(), description=description.strip(),
                       acceptance_criteria=[value.strip() for value in acceptance_criteria])
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        with self._lock, self._connect() as db:
            row = db.execute("SELECT request_hash,document FROM tasks WHERE request_id=?", (request_id,)).fetchone()
            if row:
                if row[0] != digest:
                    raise ValueError("request_id already belongs to a different General task")
                return {"task": json.loads(row[1]), "idempotent": True}
            task = dict(id="GEN-" + uuid.uuid4().hex[:16].upper(), scope="general", status="backlog",
                        created_at=time.time(), updated_at=time.time(), runs=[], **payload)
            db.execute("INSERT INTO tasks VALUES(?,?,?,?)", (task["id"], request_id, digest, json.dumps(task)))
            self._save(db, task, "created")
            return {"task": task, "idempotent": False}

    def list(self, *, limit=100):
        limit = max(1, min(int(limit), 500))
        with self._lock, self._connect() as db:
            tasks = [json.loads(row[0]) for row in db.execute("SELECT document FROM tasks")]
        tasks.sort(key=lambda value: value["updated_at"], reverse=True)
        return {"tasks": tasks[:limit], "total_count": len(tasks), "scope": "general"}

    def get(self, task_id):
        with self._lock, self._connect() as db:
            task = self._load(db, task_id)
            events = [dict(sequence=row[0], run_id=row[1], kind=row[2], at=row[3], detail=json.loads(row[4]))
                      for row in db.execute("SELECT seq,run_id,kind,at,detail FROM events WHERE task_id=? ORDER BY seq", (task_id,))]
            return {"task": task, "events": events}

    def dispatch(self, task_id, *, provider=None):
        with self._lock, self._connect() as db:
            task = self._load(db, task_id)
            if task["status"] == "in_progress":
                return {"task": task, "already_active": True}
            if task["status"] not in {"backlog", "failed", "interrupted", "changes_requested"}:
                raise ValueError("Only backlog, failed, interrupted or changes-requested General tasks can run")
            previous = task["runs"][-1] if task["runs"] else {}
            if self._preserved_process(previous):
                raise ValueError("The previous General worker is still running. Cancel that exact run before retrying; no work was replayed.")
            if self.command_factory is None:
                raise ValueError("General task execution is unavailable")
            run_id = uuid.uuid4().hex
            workspace = self.files / task_id / run_id
            workspace.mkdir(parents=True, exist_ok=False)
            try:
                selected_provider, command = self.command_factory(provider)
                if selected_provider not in {"codex", "claude"}:
                    raise ValueError("General tasks require Codex or Claude")
                if self.preflight is not None:
                    self.preflight(selected_provider, command, workspace)
            except Exception:
                try:
                    workspace.rmdir()
                except OSError:
                    pass  # A provider preflight may leave diagnostics; preserve them.
                raise
            run = dict(id=run_id, attempt=len(task["runs"]) + 1, provider=selected_provider,
                       state="running", workspace_path=str(workspace), started_at=time.time(),
                       artifact_manifest=[], result=None, error=None)
            task["runs"].append(run)
            task["status"] = "in_progress"
            self._save(db, task, "dispatched", run_id)
            cancelled = threading.Event()
            self._cancellations[run_id] = cancelled
        thread = threading.Thread(target=self._execute, args=(task, run, command, cancelled),
                                  name="general-" + run_id[:8], daemon=True)
        thread.start()
        return {"task": task, "already_active": False}

    def _execute(self, task, run, command, cancelled):
        error = None
        result = None
        manifest = []
        try:
            rc = self.runner(command, Path(run["workspace_path"]), self._prompt(task), run["id"], cancelled)
            if rc:
                raise ValueError(f"{run['provider']} worker exited with status {rc}; inspect this run's local worker.log")
            if not cancelled.is_set():
                result, manifest = self._validate_result(task, Path(run["workspace_path"]))
        except Exception as exc:  # A provider failure must leave a recoverable canonical task.
            error = str(exc)
        finally:
            with self._lock, self._connect() as db:
                current = self._load(db, task["id"])
                current_run = current["runs"][-1]
                if current_run["id"] != run["id"]:
                    return
                state = "canceled" if cancelled.is_set() else ("failed" if error else "awaiting_review")
                current_run.update(state=state, ended_at=time.time(), error=error,
                                   result=result, artifact_manifest=manifest)
                current["status"] = state
                self._save(db, current, state, run["id"])
                self._processes.pop(run["id"], None)
                self._cancellations.pop(run["id"], None)

    def _run_process(self, command, workspace, prompt, run_id, cancelled):
        if cancelled.is_set():
            return -signal.SIGTERM
        environment = general_worker_environment(self.root / "files")
        with (workspace / "worker.log").open("w") as log:
            proc = subprocess.Popen(command, cwd=workspace, env=environment, stdin=subprocess.PIPE,
                                    stdout=log, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            try:
                with self._lock, self._connect() as db:
                    self._processes[run_id] = proc
                    for row in db.execute("SELECT document FROM tasks").fetchall():
                        task = json.loads(row[0])
                        if task["runs"] and task["runs"][-1]["id"] == run_id:
                            task["runs"][-1].update(worker_pid=proc.pid, process_identity=self._process_identity(proc.pid))
                            self._save(db, task, "process_started", run_id)
                            break
                    if cancelled.is_set():
                        self._terminate(proc)
                proc.communicate(prompt)
            finally:
                if proc.poll() is None:
                    self._terminate(proc)
            return proc.returncode

    @staticmethod
    def _process_identity(pid):
        try:
            result = subprocess.run(["/bin/ps", "-p", str(int(pid)), "-o", "lstart="],
                                    capture_output=True, text=True, timeout=3)
            return result.stdout.strip() if result.returncode == 0 else None
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return None

    @classmethod
    def _preserved_process(cls, run):
        pid, identity = run.get("worker_pid"), run.get("process_identity")
        if not pid:
            return False
        current = cls._process_identity(pid)
        if current:
            return not identity or current == identity
        try:
            os.kill(int(pid), 0)
            return True  # Identity is unavailable; do not replay a possibly live worker.
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    @staticmethod
    def _terminate(proc):
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=3)
            except ProcessLookupError:
                pass

    @staticmethod
    def _prompt(task):
        return (
            "You are a Relay Runner General task worker. Work only on this bounded task in the current "
            "managed output directory. This is not a source repository; do not initialize Git, edit project "
            "boards, dispatch workers, or commit. Preserve unrelated files and accepted work. "
            "Task classification does not authorize sending messages, publishing, purchasing, deleting "
            "existing user data or other external effects. If completing the task needs an effect not "
            "explicitly authorized in the description, stop with an exact blocker instead of doing it. "
            "Create local drafts for review. Do not copy credentials, machine logs or provider transcripts "
            "into artifacts. Do not change your task's canonical lifecycle.\n\n"
            + json.dumps({key: task[key] for key in ("id", "title", "description", "acceptance_criteria")}, indent=2)
            + '\n\nWhen finished, write result.json containing {"summary":"...", "criteria":'
              '[{"criterion":"exact acceptance criterion", "evidence":"specific result and validation"}], '
              '"artifacts":["relative/output.md"]}. Cover each criterion exactly once. Include all '
              'deliverable files, not worker.log or result.json. Outputs remain pending PM review. '
              'If blocked, exit without a success result and write a local blocker.md explaining the resume path.\n'
        )

    @staticmethod
    def _manifest(workspace, paths):
        if not isinstance(paths, list) or not paths or not all(isinstance(value, str) for value in paths):
            raise ValueError("Worker result must name at least one local artifact")
        manifest = []
        for relative in paths:
            path = Path(relative)
            if path.is_absolute() or ".." in path.parts or relative in {"result.json", "worker.log"}:
                raise ValueError("Worker artifact path is outside its output contract")
            candidate = workspace / path
            if any((workspace.joinpath(*path.parts[:index])).is_symlink()
                   for index in range(1, len(path.parts) + 1)):
                raise ValueError("Worker artifacts cannot contain symlinks")
            if not candidate.resolve().is_relative_to(workspace.resolve()) or not candidate.is_file():
                raise ValueError("Worker artifact is missing or outside its managed run")
            content = candidate.read_bytes()
            manifest.append(dict(path=relative, size_bytes=len(content), sha256=hashlib.sha256(content).hexdigest()))
        if len({item["path"] for item in manifest}) != len(manifest):
            raise ValueError("Worker artifacts must be unique")
        return manifest

    def _validate_result(self, task, workspace):
        path = workspace / "result.json"
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
            raise ValueError("Worker did not produce a valid bounded result.json")
        result = json.loads(path.read_text())
        if not isinstance(result, dict) or not isinstance(result.get("summary"), str) or not result["summary"].strip():
            raise ValueError("Worker result needs a summary")
        criteria = result.get("criteria")
        if not isinstance(criteria, list) or not all(isinstance(value, dict) and
                isinstance(value.get("evidence"), str) and value["evidence"].strip() for value in criteria):
            raise ValueError("Worker result needs evidence for each acceptance criterion")
        declared = [value.get("criterion") for value in criteria]
        if sorted(declared, key=str) != sorted(task["acceptance_criteria"]):
            raise ValueError("Worker result must cover every acceptance criterion exactly once")
        return result, self._manifest(workspace, result.get("artifacts"))

    def review(self, task_id, *, run_id, approve, summary):
        if not isinstance(approve, bool) or not isinstance(summary, str) or not summary.strip():
            raise ValueError("Review requires approve true/false and an evidence-based summary")
        with self._lock, self._connect() as db:
            task = self._load(db, task_id)
            if task["status"] != "awaiting_review" or task["runs"][-1]["id"] != run_id:
                raise ValueError("Review must target the current General run awaiting review")
            run = task["runs"][-1]
            if approve:
                actual = self._manifest(Path(run["workspace_path"]), [value["path"] for value in run["artifact_manifest"]])
                if actual != run["artifact_manifest"]:
                    raise ValueError("Artifacts changed after execution; reject this run and retry before approval")
                if self.personal_storage is not None:
                    references = []
                    for item in actual:
                        identity = "general-" + hashlib.sha256(
                            f"{task_id}/{run_id}/{item['path']}".encode()).hexdigest()[:40]
                        reference = self.personal_storage.register_file(
                            Path(run["workspace_path"]) / item["path"], artifact_id=identity,
                            active=False, approved=False)
                        if reference["sha256"] != item["sha256"]:
                            raise ValueError("Artifacts changed during review; original outputs are preserved")
                        references.append({"path": item["path"], "artifact_id": identity, "sha256": item["sha256"]})
                    run["artifact_references"] = references
            run["review"] = dict(approved=approve, summary=summary.strip(), reviewed_at=time.time(),
                                 artifact_manifest=run["artifact_manifest"])
            run["state"] = "done" if approve else "changes_requested"
            task["status"] = run["state"]
            self._save(db, task, "reviewed", run_id, run["review"])
        # The durable task receipt must exist before removing duplicate source files.
        # Storage approval/upload remains a separate explicit user action.
        if approve and self.personal_storage is not None:
            for reference in run.get("artifact_references", []):
                try:
                    source = Path(run["workspace_path"]) / reference["path"]
                    if hashlib.sha256(source.read_bytes()).hexdigest() != reference["sha256"]:
                        continue
                    self.personal_storage.register_file(source,
                        artifact_id=reference["artifact_id"], active=False, approved=False, adopt=True)
                except (OSError, ValueError, RuntimeError):
                    pass  # Both verified copies remain safe if cleanup cannot complete.
        return {"task": task}

    def artifact(self, task_id, *, run_id, artifact_id):
        """Materialize one reviewed immutable output; never approve or upload it."""
        if self.personal_storage is None:
            raise ValueError("Personal file storage is unavailable")
        task = self.get(task_id)["task"]
        run = next((run for run in task["runs"] if run["id"] == run_id), None)
        if not run or not run.get("review", {}).get("approved"):
            raise ValueError("Only reviewed General outputs can be retrieved")
        reference = next((item for item in run.get("artifact_references", [])
                          if item["artifact_id"] == artifact_id), None)
        if not reference:
            raise ValueError("The requested artifact does not belong to this General run")
        self.personal_storage.read(artifact_id, reference["sha256"])
        materialized = self.personal_storage.reference(artifact_id, reference["sha256"])
        return {"reference": materialized,
                "absolute_path": str(self.personal_storage.root / materialized["local_path"])}

    def cancel(self, task_id, *, run_id=None):
        with self._lock, self._connect() as db:
            task = self._load(db, task_id)
            if run_id is not None and (not task["runs"] or task["runs"][-1]["id"] != run_id):
                raise ValueError("Cancellation must target the current General run")
            if task["status"] in {"done", "canceled"}:
                return {"task": task}
            if task["status"] == "in_progress":
                active_run = task["runs"][-1]["id"]
                cancelled = self._cancellations.get(active_run)
                if cancelled:
                    cancelled.set()
                proc = self._processes.get(active_run)
                if proc:
                    self._terminate(proc)
                task["runs"][-1].update(state="canceled", ended_at=time.time())
            elif task["runs"] and self._preserved_process(task["runs"][-1]):
                # Verify creation identity before touching a process inherited from an older daemon.
                previous = task["runs"][-1]
                if not previous.get("process_identity") or self._process_identity(previous["worker_pid"]) != previous["process_identity"]:
                    raise ValueError("The previous worker may still be running, but its identity cannot be verified. No process was canceled; retry after it exits.")
                pid = int(task["runs"][-1]["worker_pid"])
                try:
                    os.killpg(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                task["runs"][-1].update(state="canceled", ended_at=time.time())
            task["status"] = "canceled"
            self._save(db, task, "canceled", run_id)
            return {"task": task}
