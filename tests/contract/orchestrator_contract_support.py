"""Shared harness for the orchestrator daemon contract suite (RR-485).

The daemon under test is an opaque command. Nothing here imports the
implementation: the suite starts a process, talks HTTP to it, and reads back
the files, SQLite databases and git objects it leaves behind.
See docs/specs/orchestrator-http-api.md.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = Path(__file__).resolve().parent
GOLDEN_DIR = CONTRACT_DIR / "golden" / "orchestrator"
FAKES_DIR = CONTRACT_DIR / "fakes"
FIXTURES_DIR = CONTRACT_DIR / "fixtures" / "orchestrator"

ARTIFACT_REF = "refs/heads/relay/artifacts"


def _command(variable: str, script: str) -> list:
    configured = os.environ.get(variable, "").strip()
    if configured:
        return shlex.split(configured)
    return [sys.executable, str(REPO_ROOT / "services" / script)]


DAEMON_CMD = _command("RELAY_ORCHESTRATOR_CMD", "orchestrator.py")
MIGRATION_CMD = _command("RELAY_ARTIFACT_MIGRATION_CMD", "artifact_migration_cli.py")
DAEMON_IS_REFERENCE = not os.environ.get("RELAY_ORCHESTRATOR_CMD", "").strip()
UPDATE_GOLDEN = os.environ.get("RELAY_CONTRACT_UPDATE_GOLDEN", "").strip() == "1"
START_TIMEOUT_SECONDS = float(os.environ.get("RELAY_ORCHESTRATOR_START_TIMEOUT", "30"))
WAIT_TIMEOUT_SECONDS = float(os.environ.get("RELAY_ORCHESTRATOR_WAIT_TIMEOUT", "60"))

GIT = shutil.which("git") or "/usr/bin/git"

# The identity every repository in the suite commits with.
GIT_IDENTITY = {
    "GIT_AUTHOR_NAME": "Contract Suite",
    "GIT_AUTHOR_EMAIL": "suite@contract.invalid",
    "GIT_COMMITTER_NAME": "Contract Suite",
    "GIT_COMMITTER_EMAIL": "suite@contract.invalid",
}


def git(repo, *arguments, check: bool = True, env=None, binary: bool = False):
    """Run git in `repo` with a fixed identity; return stripped stdout."""
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(Path(repo)),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        **GIT_IDENTITY,
    }
    environment.update(env or {})
    done = subprocess.run(
        [GIT, *arguments], cwd=str(repo), env=environment, capture_output=True, check=False
    )
    if check and done.returncode != 0:
        raise AssertionError(
            "git %s failed in %s: %s" % (" ".join(arguments), repo, done.stderr.decode("utf-8", "replace"))
        )
    if binary:
        return done.stdout
    return done.stdout.decode("utf-8", "replace").strip()


class Response:
    def __init__(self, status: int, body: bytes, headers):
        self.status = status
        self.body = body
        self.headers = headers
        try:
            self.json = json.loads(body.decode("utf-8")) if body else None
        except ValueError:
            self.json = None

    def __repr__(self) -> str:
        return "Response(%d, %s)" % (self.status, self.body[:400])


# -- golden normalisation ----------------------------------------------------
#
# The rules are documented in docs/specs/orchestrator-http-api.md under
# "Golden files". Keep the two in step.

_ISO_RE = re.compile(
    r"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"
)
# A bare 40-hex value is a git object id. One behind a `ticket-` style prefix
# is an artifact id derived from the project and ticket ids; it is stable and
# stays in the golden file.
_OID_RE = re.compile(r"(?<![\w-])[0-9a-f]{40}\b")
_SHA256_RE = re.compile(r"(?<![\w-])[0-9a-f]{64}\b")
_HEX32_RE = re.compile(r"(?<![\w-])[0-9a-f]{32}\b")
_UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE
)
_DEVICE_RE = re.compile(r"\bdaemon-[0-9a-f]{24}\b")
# A worktree directory is `<repo name>-<8 hex of the repo path>-<ticket id>`.
_WORKSPACE_RE = re.compile(r"-[0-9a-f]{8}-(?=[a-z0-9]+-\d)")
# A queue drain id is `drain-<12 hex of repo, branch and provider>-<sequence>`.
_DRAIN_RE = re.compile(r"\bdrain-[0-9a-f]{12}-")

# Numeric fields that hold wall-clock times, durations or process ids.
VOLATILE_NUMBER_KEYS = {
    "pid", "port", "exit_code_time", "duration_seconds", "elapsed_seconds", "age_seconds",
    "idle_seconds", "uptime_seconds", "worker_pid", "review_pid",
}


class Normalizer:
    """Replace volatile values with stable placeholders.

    Equal inputs get equal placeholders, so a golden file still shows which
    fields carry the same commit id or the same path.
    """

    def __init__(self):
        self._literals = []
        self._numbered = {}

    def literal(self, value, placeholder: str) -> None:
        value = str(value)
        if value:
            self._literals.append((value, placeholder))
            self._literals.sort(key=lambda item: len(item[0]), reverse=True)

    def _number(self, kind: str, value: str) -> str:
        seen = self._numbered.setdefault(kind, {})
        if value not in seen:
            seen[value] = "<%s:%d>" % (kind, len(seen) + 1)
        return seen[value]

    def text(self, value: str) -> str:
        for literal, placeholder in self._literals:
            value = value.replace(literal, placeholder)
        value = _ISO_RE.sub("<TIMESTAMP>", value)
        value = _SHA256_RE.sub(lambda match: self._number("SHA256", match.group(0)), value)
        value = _OID_RE.sub(lambda match: self._number("OID", match.group(0)), value)
        value = _HEX32_RE.sub(lambda match: self._number("HEX32", match.group(0)), value)
        value = _UUID_RE.sub(lambda match: self._number("UUID", match.group(0).lower()), value)
        value = _DEVICE_RE.sub("<DEVICE>", value)
        value = _WORKSPACE_RE.sub("-<HASH8>-", value)
        value = _DRAIN_RE.sub("drain-<HASH12>-", value)
        return value

    def value(self, value, key: str = ""):
        if isinstance(value, dict):
            return {self.text(str(name)): self.value(item, str(name)) for name, item in value.items()}
        if isinstance(value, list):
            return [self.value(item, key) for item in value]
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, bool) or value is None:
            return value
        if isinstance(value, (int, float)):
            if key in VOLATILE_NUMBER_KEYS:
                return "<%s>" % key.upper()
            if key.endswith("_at") or key.endswith("_time") or key.endswith("_until") or key in {
                "timestamp", "ts", "deadline", "issuedAt", "registryRecordUpdatedAt",
            }:
                return "<TIME>"
        return value

    def blob(self, path: str, content: bytes) -> bytes:
        """Normalise a file from a git tree. Binary files pass through."""
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError:
            return content
        if "\x00" in text:
            return content
        return self.text(text).encode("utf-8")


def golden_path(name: str) -> Path:
    return GOLDEN_DIR / name


def _dump_json(value) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# -- the sandbox ---------------------------------------------------------------


class Sandbox:
    """One isolated daemon: its own home, state root, runtime directory and PATH."""

    FINGERPRINT = "git-common-v1:contract-fingerprint"
    REGISTRY_UPDATED_AT = "2026-08-04T05:00:00Z"

    def __init__(self, add_cleanup, *, agent: str = "claude", orchestrator=None,
                 general=None, sections=None, environment=None):
        """`add_cleanup` is `self.addCleanup` or `cls.addClassCleanup`."""
        self.test = _Assertions()
        self.agent = agent
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="relay-orch-contract-")))
        add_cleanup(shutil.rmtree, str(self.root), True)
        self.home = self.root / "home"
        self.state_root = self.root / "state"
        self.data_root = self.state_root / "orchestrator"
        self.runtime = self.root / "runtime"
        self.bin = self.root / "bin"
        self.fake_state = self.root / "fake"
        self.diagnostics = self.root / "diagnostics"
        self.temporary = self.root / "tmp"
        self.workspaces = self.root / "workspaces"
        self.config_path = self.root / "config.toml"
        self.port_file = self.runtime / "relay_orchestrator.port"
        self.registry_path = self.state_root / "projects" / "registry-v2.json"
        self.stderr_path = self.root / "daemon.stderr"
        for directory in (self.home, self.data_root, self.runtime, self.bin, self.fake_state,
                          self.diagnostics, self.temporary, self.workspaces):
            directory.mkdir(parents=True, exist_ok=True)
        self.extra_environment = dict(environment or {})
        self.process = None
        self.port = None
        self._literals = [(str(self.root), "<ROOT>"), (str(REPO_ROOT), "<SOURCE>")]
        self._install_fakes()
        self.write_config(orchestrator=orchestrator, general=general, sections=sections)
        add_cleanup(self.stop)

    def normalizer(self) -> Normalizer:
        """A fresh normaliser per golden file, so placeholder numbers start at 1."""
        normalizer = Normalizer()
        for value, placeholder in self._literals:
            normalizer.literal(value, placeholder)
        if self.port:
            normalizer.literal("127.0.0.1:%d" % self.port, "127.0.0.1:<PORT>")
        return normalizer

    # -- files the daemon reads -------------------------------------------

    def _install_fakes(self) -> None:
        provider = FAKES_DIR / "provider.py"
        for name in ("claude", "codex"):
            script = self.bin / name
            script.write_text(
                "#!/bin/sh\nexec %s %s %s \"$@\"\n"
                % (shlex.quote(sys.executable), shlex.quote(str(provider)), name)
            )
            script.chmod(0o755)
        gh = self.bin / "gh"
        gh.write_text(
            "#!/bin/sh\nexec %s %s \"$@\"\n"
            % (shlex.quote(sys.executable), shlex.quote(str(FAKES_DIR / "gh.py")))
        )
        gh.chmod(0o755)
        # The only real program the daemon needs from outside the system
        # directories. Linking it keeps the rest of its directory off PATH.
        os.symlink(GIT, str(self.bin / "git"))

    def write_config(self, *, orchestrator=None, general=None, sections=None) -> None:
        settings = {
            "workspace_root": str(self.workspaces),
            "agent": self.agent,
            # Codex is looked up in the ChatGPT and Codex application bundles
            # before PATH, so the fake is named outright.
            "command": str(self.bin / self.agent),
            "port": 0,
            "worker_health_check_seconds": 3600,
        }
        settings.update(orchestrator or {})
        tables = {"orchestrator": settings, "general": dict(general or {}),
                  "continuity": {"enabled": False}}
        for name, values in (sections or {}).items():
            tables.setdefault(name, {}).update(values)
        lines = []
        for name, values in tables.items():
            lines.append("[%s]" % name)
            for key, value in values.items():
                lines.append("%s = %s" % (key, _toml(value)))
            lines.append("")
        self.config_path.write_text("\n".join(lines))

    def environment(self) -> dict:
        """Everything the daemon inherits. Nothing comes from the caller's environment."""
        environment = {
            "PATH": "%s:/usr/bin:/bin:/usr/sbin:/sbin" % self.bin,
            "HOME": str(self.home),
            "TMPDIR": str(self.temporary),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TZ": "UTC",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "RELAY_ORCHESTRATOR_DATA_ROOT": str(self.data_root),
            "RELAY_ORCHESTRATOR_RUNTIME_DIR": str(self.runtime),
            "RELAY_DIAGNOSTICS_DIR": str(self.diagnostics),
            "RELAY_SESSION_WORK_STYLE_FILE": str(self.state_root / "session-work-style.json"),
            "RELAY_CONTRACT_FAKE_STATE": str(self.fake_state),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        environment.update(self.extra_environment)
        return environment

    # -- process -----------------------------------------------------------

    def start(self) -> "Sandbox":
        self.test.assertIsNone(self.process, "daemon already running")
        try:
            self.port_file.unlink()
        except FileNotFoundError:
            pass
        stderr = open(str(self.stderr_path), "ab")
        self.process = subprocess.Popen(
            [*DAEMON_CMD, "--config", str(self.config_path)],
            cwd=str(self.root), env=self.environment(),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=stderr,
            start_new_session=True,
        )
        stderr.close()
        deadline = time.monotonic() + START_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError(
                    "daemon exited with %s during start:\n%s" % (self.process.returncode, self.stderr())
                )
            try:
                self.port = int(self.port_file.read_text().strip())
                if self.get("/v1/health").status == 200:
                    return self
            except (OSError, ValueError, urllib.error.URLError):
                pass
            time.sleep(0.05)
        raise AssertionError("daemon did not become healthy:\n%s" % self.stderr())

    def stop(self, sig: int = signal.SIGTERM) -> None:
        process, self.process = self.process, None
        if process is None:
            return
        if process.poll() is None:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=20)
        # Workers are children in the same process group; make sure none outlive the daemon.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def kill(self) -> None:
        """Stop without giving the daemon a chance to clean up."""
        process, self.process = self.process, None
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=20)

    def restart(self) -> "Sandbox":
        self.stop()
        return self.start()

    def stderr(self) -> str:
        """The daemon's diagnostics, without its per-request access log."""
        try:
            lines = self.stderr_path.read_text(errors="replace").splitlines()
        except OSError:
            return ""
        kept = [line for line in lines if not line.startswith("[orchestrator-http]")]
        return "\n".join(kept)[-4000:]

    # -- HTTP ----------------------------------------------------------------

    def request(self, method: str, path: str, body=None, *, query=None, raw=None,
                timeout: float = 120) -> Response:
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        if query:
            pairs = []
            for key, value in query.items():
                if value is None:
                    continue
                for item in value if isinstance(value, (list, tuple)) else [value]:
                    pairs.append((key, _query_value(item)))
            url += "?" + urllib.parse.urlencode(pairs)
        data = None
        headers = {}
        if raw is not None:
            data = raw
        elif method == "POST":
            data = json.dumps({} if body is None else body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return Response(response.status, response.read(), response.headers)
        except urllib.error.HTTPError as error:
            with error:
                return Response(error.code, error.read(), error.headers)

    def get(self, path: str, **query) -> Response:
        return self.request("GET", path, query=query or None)

    def post(self, path: str, body=None, **query) -> Response:
        return self.request("POST", path, body, query=query or None)

    # -- waiting -------------------------------------------------------------

    def wait_for(self, probe, *, timeout: float = None, message: str = "condition"):
        """Poll `probe` until it returns something truthy; return that value."""
        deadline = time.monotonic() + (WAIT_TIMEOUT_SECONDS if timeout is None else timeout)
        last = None
        while time.monotonic() < deadline:
            last = probe()
            if last:
                return last
            time.sleep(0.05)
        raise AssertionError("timed out waiting for %s (last: %r)\n%s" % (message, last, self.stderr()))

    def run(self, run_id: int) -> dict:
        response = self.get("/v1/runs/%d" % run_id)
        self.test.assertEqual(response.status, 200, response)
        return response.json["run"]

    def wait_for_run(self, run_id: int, *states: str, timeout: float = None) -> dict:
        def probe():
            run = self.run(run_id)
            return run if run["state"] in states else None
        return self.wait_for(probe, timeout=timeout, message="run %d in %s" % (run_id, states))

    # -- fake provider -------------------------------------------------------

    def plan(self, role: str, identifier: str = None, **plan) -> Path:
        directory = self.fake_state / "plans"
        directory.mkdir(parents=True, exist_ok=True)
        name = "%s.%s.json" % (role, identifier) if identifier else "%s.json" % role
        path = directory / name
        path.write_text(json.dumps(plan))
        return path

    def invocations(self, **match) -> list:
        path = self.fake_state / "invocations.jsonl"
        if not path.exists():
            return []
        entries = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        return [entry for entry in entries if all(entry.get(k) == v for k, v in match.items())]

    def hold(self, name: str) -> Path:
        """A path a plan can wait on; `release` creates it."""
        return self.fake_state / ("hold-%s" % name)

    @staticmethod
    def release(path: Path) -> None:
        path.write_text("go")

    # -- projects ------------------------------------------------------------

    def make_repo(self, name: str = "project", *, prefix: str = "CT", next_id: int = 1) -> Path:
        """A git repository with one source commit and a legacy `.orchestrator/` board."""
        repo = self.root / name
        repo.mkdir()
        git(repo, "init", "--initial-branch=main", "--quiet")
        git(repo, "config", "user.name", GIT_IDENTITY["GIT_AUTHOR_NAME"])
        git(repo, "config", "user.email", GIT_IDENTITY["GIT_AUTHOR_EMAIL"])
        git(repo, "config", "commit.gpgsign", "false")
        (repo / "README.md").write_text("# Contract project\n")
        (repo / ".gitignore").write_text(".relay/\n")
        board = repo / ".orchestrator"
        board.mkdir()
        (board / "config.toml").write_text('prefix = "%s"\nnext_id = %d\n' % (prefix, next_id))
        git(repo, "add", "README.md", ".gitignore", ".orchestrator/config.toml")
        git(repo, "commit", "--quiet", "-m", "chore: initial project")
        self._literals.append((str(repo), "<REPO:%s>" % name))
        return repo

    def write_ticket(self, repo: Path, ticket_id: str, *, commit: bool = True, **fields) -> Path:
        """Write a ticket file into a legacy board and commit it."""
        path = repo / ".orchestrator" / ("%s.md" % ticket_id)
        path.write_text(ticket_markdown(ticket_id, **fields))
        if commit:
            git(repo, "add", "--", ".orchestrator/%s.md" % ticket_id)
            git(repo, "commit", "--quiet", "-m", "chore(%s): write ticket" % ticket_id)
        return path

    def register(self, repo: Path, *, project_id: str = None, updated_at: str = None,
                 extra: dict = None) -> dict:
        """Add `repo` to registry-v2.json, the file the app owns."""
        project_id = project_id or self.project_id(repo)
        record = {
            "project_id": project_id,
            "display_name": repo.name,
            "selected_path": str(repo),
            "last_resolved_path": str(repo),
            "git_common_directory_fingerprint": self.FINGERPRINT,
            "availability": "available",
            "worktree_kind": "main",
            "remote": {"mode": "local_only", "artifactRef": ARTIFACT_REF},
            "created_at": self.REGISTRY_UPDATED_AT,
            "last_resolved_at": self.REGISTRY_UPDATED_AT,
            "updated_at": updated_at or self.REGISTRY_UPDATED_AT,
        }
        record.update(extra or {})
        document = {"schema_version": 2, "projects": []}
        if self.registry_path.exists():
            document = json.loads(self.registry_path.read_text())
        document["projects"] = [
            item for item in document["projects"] if item.get("project_id") != project_id
        ] + [record]
        self.registry_path.parent.mkdir(parents=True, exist_ok=True)
        self.registry_path.write_text(json.dumps(document, indent=2))
        return record

    @staticmethod
    def project_id(repo: Path) -> str:
        """The suite names a project after its directory, so ids stay fixed in golden files."""
        return "contract-%s" % Path(repo).name

    def registry_record(self, repo: Path) -> dict:
        document = json.loads(self.registry_path.read_text())
        return next(
            item for item in document["projects"] if item["last_resolved_path"] == str(repo)
        )

    def scope_token(self, repo: Path, **overrides) -> str:
        """The confirmed-project token the app issues from the current registry record."""
        record = self.registry_record(repo)
        updated = datetime.fromisoformat(record["updated_at"].replace("Z", "+00:00"))
        payload = {
            "version": 1,
            "registrySchemaVersion": 2,
            "projectID": record["project_id"],
            "repositoryPath": str(repo),
            "gitCommonDirectoryFingerprint": record["git_common_directory_fingerprint"],
            "registryRecordUpdatedAt": round(updated.timestamp(), 6),
            "issuedAt": datetime(2026, 8, 4, tzinfo=timezone.utc).timestamp(),
        }
        payload.update(overrides)
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return base64.b64encode(encoded).decode("ascii")

    def migrate_to_artifacts(self, repo: Path) -> dict:
        """Move a registered legacy board onto refs/heads/relay/artifacts.

        This is the product's own migration command, run as a process before
        the daemon has seen the project.
        """
        project_id = self.registry_record(repo)["project_id"]
        done = subprocess.run(
            [*MIGRATION_CMD, "migrate", "--repo", str(repo), "--project-id", project_id,
             "--state-root", str(self.state_root), "--confirm-source-cleanup"],
            env=self.environment(), cwd=str(self.root), capture_output=True, check=False,
        )
        output = done.stdout.decode("utf-8", "replace")
        self.test.assertEqual(done.returncode, 0, output + done.stderr.decode("utf-8", "replace"))
        return json.loads(output)["result"]

    def artifact_project(self, name: str = "project", *, tickets=(), **repo_options) -> Path:
        """A registered project whose board lives on the artifact ref."""
        repo = self.make_repo(name, **repo_options)
        for ticket_id, fields in tickets:
            self.write_ticket(repo, ticket_id, **fields)
        self.register(repo)
        self.migrate_to_artifacts(repo)
        return repo

    # -- reading results -----------------------------------------------------

    def rows(self, database: str, sql: str, *parameters) -> list:
        """Query one of the daemon's databases read-only."""
        connection = sqlite3.connect(
            "file:%s?mode=ro" % urllib.parse.quote(str(self.data_root / database)), uri=True, timeout=10
        )
        connection.row_factory = sqlite3.Row
        try:
            return [dict(row) for row in connection.execute(sql, parameters)]
        finally:
            connection.close()

    def runs_index(self) -> dict:
        return json.loads((self.data_root / "runs.json").read_text())

    def tree(self, directory: Path = None) -> list:
        directory = directory or self.root
        return sorted(str(path.relative_to(directory)) for path in directory.rglob("*"))

    # -- golden files --------------------------------------------------------

    def assert_golden_json(self, name: str, value) -> None:
        """Compare a JSON value with golden/orchestrator/<name>.json after normalisation."""
        actual = _dump_json(self.normalizer().value(value))
        path = golden_path(name + ".json")
        if UPDATE_GOLDEN:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(actual)
            return
        self.test.assertTrue(path.exists(), "missing golden file %s" % path)
        self.test.assertEqual(actual, path.read_text(), "golden mismatch: %s" % path)

    def commit_record(self, repo: Path, revision: str = ARTIFACT_REF) -> dict:
        """One commit as bytes: its message, identities, and every blob in its tree."""
        commit = git(repo, "rev-parse", "--verify", revision + "^{commit}")
        header = git(repo, "cat-file", "commit", commit)
        head, _, message = header.partition("\n\n")
        fields = [line.split(" ", 1) for line in head.splitlines()]
        identities = {}
        parents = 0
        for key, value in fields:
            if key == "parent":
                parents += 1
            if key in {"author", "committer"}:
                identities[key] = re.sub(r" \d+ [+-]\d{4}$", "", value)
        files = {}
        listing = git(repo, "ls-tree", "-r", "-z", commit, binary=True)
        for entry in listing.split(b"\x00"):
            if not entry:
                continue
            meta, _, path = entry.partition(b"\t")
            mode, kind, oid = meta.decode("ascii").split(" ")
            files[path.decode("utf-8")] = (
                mode, git(repo, "cat-file", kind, oid, binary=True)
            )
        return {"commit": commit, "message": message, "identities": identities,
                "parents": parents, "files": files}

    def assert_golden_commit(self, name: str, repo: Path, revision: str = ARTIFACT_REF) -> dict:
        """Compare a commit with the directory golden/orchestrator/<name>/.

        `COMMIT.json` holds the message, identities, parent count and file
        modes; `tree/` holds each blob. Blobs are compared byte for byte after
        the documented normalisation.
        """
        record = self.commit_record(repo, revision)
        normalizer = self.normalizer()
        blobs = {
            path: normalizer.blob(path, content)
            for path, (_mode, content) in sorted(record["files"].items())
        }
        summary = _dump_json({
            "message": normalizer.text(record["message"]),
            "identities": record["identities"],
            "parents": record["parents"],
            "modes": {path: mode for path, (mode, _content) in record["files"].items()},
        }).encode("utf-8")
        directory = golden_path(name)
        if UPDATE_GOLDEN:
            shutil.rmtree(str(directory), ignore_errors=True)
            (directory / "tree").mkdir(parents=True)
            (directory / "COMMIT.json").write_bytes(summary)
            for path, content in blobs.items():
                target = directory / "tree" / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            return record
        self.test.assertTrue(directory.is_dir(), "missing golden commit %s" % directory)
        self.test.assertEqual(
            summary.decode("utf-8"), (directory / "COMMIT.json").read_text(),
            "golden commit mismatch: %s" % name,
        )
        expected = {
            str(path.relative_to(directory / "tree")): path.read_bytes()
            for path in sorted((directory / "tree").rglob("*")) if path.is_file()
        }
        self.test.assertEqual(sorted(blobs), sorted(expected), "golden tree paths differ: %s" % name)
        for path in sorted(blobs):
            self.test.assertEqual(
                blobs[path], expected[path], "golden blob differs: %s:%s" % (name, path)
            )
        return record


def _toml(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return json.dumps(str(value))


def _query_value(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def ticket_markdown(ticket_id: str, *, title: str = None, status: str = "backlog",
                    priority: str = "medium", depends_on=(), execution_mode: str = "implementation",
                    sizing: bool = True, body: str = None, extra: dict = None) -> str:
    """A ticket file in the documented board schema (docs/specs/orchestrator-tickets.md)."""
    lines = [
        "---",
        "id: %s" % ticket_id,
        'title: "%s"' % (title or "Contract ticket %s" % ticket_id),
        "status: %s" % status,
        "priority: %s" % priority,
        "execution_mode: %s" % execution_mode,
        "depends_on: [%s]" % ", ".join(depends_on),
        "run_id: null",
        "canceled: false",
    ]
    if sizing:
        lines += [
            "worker_model: balanced",
            "worker_effort: medium",
            "worker_sizing_rationale: A scripted change with no ambiguity.",
            "worker_provider_notes: none",
        ]
    for key, value in (extra or {}).items():
        lines.append("%s: %s" % (key, value))
    lines.append("---")
    lines.append("")
    lines.append(body if body is not None else (
        "## Description\n\nApply the scripted change for %s.\n\n"
        "## Acceptance criteria\n\n- [ ] The scripted change is committed.\n" % ticket_id
    ))
    return "\n".join(lines)


def b64(content) -> str:
    data = content if isinstance(content, bytes) else content.encode("utf-8")
    return base64.b64encode(data).decode("ascii")


class _Assertions(unittest.TestCase):
    """Assertion methods for the harness, outside any one test."""

    maxDiff = None

    def runTest(self) -> None:  # pragma: no cover - never run
        pass


class DaemonCase(unittest.TestCase):
    """Base for cases that share one running daemon per class.

    `agent` selects the worker provider; a subclass repeats the cases for the
    other provider by overriding it. Cases in a class share the daemon and
    whatever `prepare` built, so each uses its own ticket ids; a case that
    needs a pristine daemon builds a `Sandbox` of its own.
    """

    agent = "claude"
    orchestrator_settings = None
    general_settings = None
    config_sections = None
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.box = Sandbox(
            cls.addClassCleanup, agent=cls.agent, orchestrator=cls.orchestrator_settings,
            general=cls.general_settings, sections=cls.config_sections,
        )
        cls.prepare()
        cls.box.start()

    @classmethod
    def prepare(cls) -> None:
        """Hook: create repositories and registry entries before the daemon starts."""

    def assertStatus(self, response: Response, status: int) -> Response:
        self.assertEqual(response.status, status, response)
        return response

    def assertError(self, response: Response, status: int, fragment: str = None) -> dict:
        self.assertEqual(response.status, status, response)
        self.assertIsInstance(response.json, dict, response)
        self.assertIn("error", response.json, response)
        if fragment is not None:
            self.assertIn(fragment, response.json["error"], response)
        return response.json
