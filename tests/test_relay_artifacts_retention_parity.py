"""RR-495: services/artifact_retention.py against relay_artifacts::retention.

Each scenario builds the fixture of tests/test_artifact_retention.py (a
source repository, an artifact store with remote sync enabled, and a local
bare repository as the `origin` archive remote, confirmed the way those tests
confirm it) and runs the same steps through the Python manager in-process and
the Rust manager through the relay-artifacts test driver, with pinned Git
dates and one pinned clock. Every step's answer is compared: retention plans
and the daemon's preview and status payloads (services/orchestrator.py),
dependency resolution, archive results through the prepared-transaction path
(including an injected crash and its recovery), history search, detail,
attachments, restore, reopen, delete, leases, storage metrics and every
refusal's class and message. After every step the bytes left behind are
compared too: all refs in the repository and the remote, the materialized
`.orchestrator/` tree and the project state files (leases, the retention
transaction journal, sync state).

Every run uses the same absolute fixture path, one after another, so paths
and remote URL digests are equal. Alternation runs the steps with Python and
Rust taking turns on one repository and data root, in both orders, and must
leave exactly what an all-Python run leaves.

Rust cases skip when the crate's test driver is not built (``cargo test`` in
rust/ builds it); see tests/relay_artifacts_support.py.
"""

from __future__ import annotations

import dataclasses
import hashlib
import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from relay_artifacts_support import (  # noqa: E402
    PythonArtifacts,
    Refused,
    driver_command,
    git_dates,
    implementation,
)

UTC = timezone.utc
PROJECT = "retention-project"
ARTIFACT_REF = "refs/heads/relay/artifacts"
PNG = b"\x89PNG\r\n\x1a\nfixture"
NOW = datetime(2026, 8, 4, 1, 2, 3, 456789, tzinfo=UTC)
OLD = NOW - timedelta(days=31)


def isolation() -> dict:
    return {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", **git_dates()}


def stamp(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def iso(value) -> str:
    return value.isoformat().replace("+00:00", "Z")


def run_git(repo, *arguments, allow=(0,)) -> str:
    command = ["git"] + (["-C", str(repo)] if repo is not None else []) + list(arguments)
    process = subprocess.run(command, capture_output=True, check=False,
                             env={**os.environ, **isolation()})
    if process.returncode not in allow:
        raise AssertionError(f"{' '.join(command)} failed: {process.stderr.decode()}")
    return process.stdout.decode().strip()


def bare_module(name: str):
    """A services/ module bound to the same bare `artifact_store` module
    PythonArtifacts opens stores with, not a second `services.` copy."""
    if name in sys.modules:
        return sys.modules[name]
    # Hide the package and its submodules, which `import orchestrator` loads,
    # so the module falls back to its direct-script imports.
    saved = {key: sys.modules.pop(key) for key in list(sys.modules)
             if key == "services" or key.startswith("services.")}
    sys.modules["services"] = None
    try:
        return importlib.import_module(name)
    finally:
        sys.modules.pop("services", None)
        sys.modules.update(saved)


def parse_instant(value):
    return None if value is None else datetime.fromisoformat(value.replace("Z", "+00:00"))


class PythonRetention(PythonArtifacts):
    """PythonArtifacts with the `retention.*` operations of the Rust driver,
    and the `sync.*` ones the fixture needs."""

    kept_plan = None

    def call(self, op: str, **arguments):
        try:
            return super().call(op, **arguments)
        except Refused as refused:
            cause = refused.__cause__
            if cause is not None and type(cause).__name__ == "DependencyHistoryUnavailable":
                raise Refused("DependencyHistoryUnavailable", refused.message) from cause
            raise

    @staticmethod
    def _engine(store, a):
        sync = bare_module("artifact_sync")
        return sync.ArtifactSyncEngine(
            store, mode=sync.ArtifactSyncMode.ENABLED,
            remote_name=a.get("remote_name", "origin"), max_attempts=1,
            base_retry_seconds=0, sleep=lambda _: None, jitter=lambda: 0,
        )

    def _sync(self, function: str, a: dict):
        sync = bare_module("artifact_sync")
        engine = sync.ArtifactSyncEngine(
            self.store, mode=sync.ArtifactSyncMode(a.get("mode", "enabled")),
            remote_name=a.get("remote_name"), max_attempts=a.get("max_attempts", 3),
            base_retry_seconds=0, sleep=lambda _: None, jitter=lambda: 0,
        )
        if function == "publish_initial":
            result = engine.publish_initial(confirmed=bool(a.get("confirmed")))
        elif function == "status":
            result = engine.status()
        else:
            raise KeyError(function)
        return self._sync_result(result)

    @staticmethod
    def _sync_result(result) -> dict:
        report = result.conflict_report
        return {
            "state": result.state.value,
            "observed_state": result.observed_state.value,
            "transitions": [state.value for state in result.transitions],
            "attempts": result.attempts,
            "local_head": result.local_head,
            "remote_head": result.remote_head,
            "recovery": result.recovery,
            "conflict_report": None if report is None else dataclasses.asdict(report),
        }

    def _retention(self, function: str, a: dict):
        import orchestrator

        retention = bare_module("artifact_retention")
        store = self.store
        if function == "confirm_github_remote":
            return dataclasses.asdict(retention.confirm_github_remote(
                store, a["remote_name"], exposure_confirmed=bool(a.get("exposure_confirmed"))))
        engine = self._engine(store, a) if a.get("synchronizer", True) else None
        confirmation = (retention.ArchiveRemoteConfirmation(**a["confirmation"])
                        if a.get("confirmation") else None)
        now = parse_instant(a.get("now"))
        injector = None
        if a.get("fail_stage"):
            wanted = a["fail_stage"]

            def injector(stage):
                if stage == wanted:
                    raise self.modules.artifact_store.ArtifactInjectedFailure(
                        f"injected failure at {stage}")
        manager = retention.ArtifactRetentionManager(
            store, remote_mode=a.get("remote_mode", "enabled"), remote_confirmation=confirmation,
            synchronizer=engine, enabled=a.get("enabled", True),
            now=(lambda: now) if now else None, failure_injector=injector,
        )
        daemon = types.SimpleNamespace(
            _artifact_retention_components=lambda *_, **__: (manager, engine, confirmation),
            _artifact_lifecycle=lambda _: object(),
            _retention_ticket_payload=orchestrator.Daemon._retention_ticket_payload,
        )
        daemon._retention_plan_payload = (
            lambda target: orchestrator.Daemon._retention_plan_payload(daemon, target))

        def deepen(commit_id):
            if engine is None:
                raise ValueError("online history retrieval requires confirmed GitHub artifact access")
            engine.fetch_historical_object(
                commit_id, expected_remote_url_sha256=confirmation.remote_url_sha256 if confirmation else "")

        online = {"online": bool(a.get("online")), "deepen": deepen if a.get("online") else None}
        event = {"event_id": a.get("event_id"), "device_id": a.get("device_id")}
        for key in ("actor_type", "provider"):
            if key in a:
                event[key] = a[key]
        leases = manager.lease_store
        if function == "preview":
            plan = manager.preview(evaluated_at=parse_instant(a.get("evaluated_at")))
            if a.get("keep"):
                self.kept_plan = plan
            return daemon._retention_plan_payload(types.SimpleNamespace(preview=lambda: plan))
        if function == "status":
            return orchestrator.Daemon.artifact_retention_status(
                daemon, repo_path="", project_scope_token=None)
        if function == "history_search":
            return orchestrator.Daemon.artifact_history_search(
                daemon, repo_path="", project_scope_token=None, query=a.get("query", ""))
        if function == "archive":
            plan = self.kept_plan if a.get("kept_plan") else manager.preview()
            return self._archive(manager.archive(plan, **event))
        if function == "recover_archive":
            result = manager.recover_archive()
            return None if result is None else self._archive(result)
        if function == "historical_search":
            return [self._card(card) for card in manager.historical_search(a.get("query", ""))]
        if function == "historical_detail":
            detail = manager.historical_detail(a["artifact_id"], **online)
            return {
                "availability": detail.availability.value,
                "card": None if detail.card is None else self._card(detail.card),
                "ticket_bytes": None if detail.ticket_bytes is None else detail.ticket_bytes.hex(),
                "attachments": [dict(item) for item in detail.attachments],
                "recovery": detail.recovery,
            }
        if function == "historical_attachment":
            item = manager.historical_attachment(a["artifact_id"], a["filename"], **online)
            return {**dataclasses.asdict(item), "content": item.content.hex()}
        if function in {"restore", "reopen", "delete"}:
            at = parse_instant(a.get("at"))
            if function == "delete":
                return self._archive(manager.delete(a["ticket_id"], deleted_at=at, **event))
            keyword = "restored_at" if function == "restore" else "reopened_at"
            operation = getattr(manager, function)
            return self._archive(operation(a["artifact_id"], **{keyword: at}, **event, **online))
        if function == "dependency_satisfied":
            return manager.dependency_satisfied(a["dependency_id"])
        if function == "dependency_execution_mode":
            return manager.dependency_execution_mode(a["dependency_id"])
        if function == "transaction_status":
            return manager.transaction_status()
        if function == "storage_metrics":
            return dataclasses.asdict(manager.storage_metrics())
        if function == "lease_acquire":
            return retention._lease_json(leases.acquire(
                lease_id=a["lease_id"], ticket_id=a["ticket_id"], artifact_id=a["artifact_id"],
                artifact_head=a["artifact_head"], run_id=a["run_id"], role=a["role"],
                provider=a["provider"], attachment_paths=a.get("attachment_paths", ()),
                now=parse_instant(a.get("now")),
            ))
        if function == "lease_heartbeat":
            return retention._lease_json(leases.heartbeat(a["lease_id"], now=parse_instant(a.get("now"))))
        if function == "lease_release":
            return retention._lease_json(leases.release(
                a["lease_id"], terminal_reason=a["terminal_reason"], now=parse_instant(a.get("now"))))
        if function == "lease_active":
            return [retention._lease_json(lease) for lease in leases.active()]
        if function == "lease_active_ticket_ids":
            return sorted(leases.active_ticket_ids())
        raise KeyError(function)

    def _archive(self, result) -> dict:
        return {
            "state": result.state.value,
            "write": None if result.write is None else self._write(result.write),
            "ticket_ids": list(result.ticket_ids),
            "warnings": list(result.warnings),
            "recovery": result.recovery,
        }

    @staticmethod
    def _card(card) -> dict:
        return {
            "artifact_id": card.artifact_id, "ticket_id": card.ticket_id, "title": card.title,
            "status": card.status, "activity_at": iso(card.activity_at), "state": card.state.value,
            "attachment_count": card.attachment_count, "attachment_bytes": card.attachment_bytes,
        }


def make_implementation(name: str):
    if name == "python":
        return PythonRetention(environment=isolation())
    return implementation("rust", environment=isolation())


# -- the fixture ----------------------------------------------------------------


def ticket_markdown(ticket_id: str, title: str, activity_at: datetime, **extra) -> bytes:
    status = extra.pop("status", "backlog")
    fields = {"id": ticket_id, "artifact_id": f"artifact-{ticket_id}", "title": title,
              "status": status, "activity_at": stamp(activity_at), **extra}
    front = "\n".join(f"{key}: {value}" for key, value in fields.items())
    return f"---\n{front}\n---\n\n## Description\n\n{title}\n".encode()


def ticket_write(ticket_id: str, title: str, activity_at: datetime, **extra) -> dict:
    artifact_id = extra.get("artifact_id", f"artifact-{ticket_id}")
    return {"type": "TicketWrite", "ticket_id": ticket_id, "artifact_id": artifact_id,
            "markdown": ticket_markdown(ticket_id, title, activity_at, **extra).hex()}


def attachment_write(ticket_id: str, filename: str, content: bytes) -> dict:
    return {"type": "AttachmentWrite", "ticket_id": ticket_id, "filename": filename,
            "mime_type": "image/png", "content": content.hex()}


class Fixture:
    def __init__(self, root: Path, kinds: tuple):
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True)
        self.root = root
        self.repo = root / "repo"
        self.remote = root / "remote.git"
        self.state = root / "state"
        self.repo.mkdir()
        run_git(self.repo, "init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("source\n")
        run_git(self.repo, "add", "source.txt")
        run_git(self.repo, "-c", "user.name=Retention Tests", "-c",
                "user.email=retention@example.invalid", "commit", "-q", "-m", "source")
        run_git(None, "init", "--bare", "--quiet", str(self.remote))
        run_git(self.repo, "remote", "add", "origin", str(self.remote))
        self.implementations = {kind: make_implementation(kind) for kind in set(kinds)}
        self.current = None
        self.use(kinds[0])
        initialized = self.call("store.initialize", device_id="device-a")
        config = bytes.fromhex(self.call("store.snapshot")["files"][".orchestrator/config.toml"])
        config = config.decode().replace(
            'remote_sync = "local_only"\n', 'remote_sync = "enabled"\nremote_name = "origin"\n')
        self.call("store.mutate", mutation={
            "event_id": "enable-remote", "actor_type": "user", "device_id": "device-a",
            "expected_base": initialized["commit_id"],
            "operations": [{"type": "ConfigWrite", "content": config.encode().hex()}],
        })
        self.call("sync.publish_initial", remote_name="origin", max_attempts=1, confirmed=True)
        digest = hashlib.sha256(str(self.remote).encode()).hexdigest()
        self.confirmation = {"service": "github", "remote_name": "origin",
                             "remote_url_sha256": digest, "push_url_sha256": digest,
                             "exposure_confirmed": True}

    def close(self):
        for target in self.implementations.values():
            target.close()

    def use(self, kind: str):
        if kind != self.current:
            self.current = kind
            self.call("store.open", repo=str(self.repo), project_id=PROJECT,
                      state_root=str(self.state), enabled=True)

    def call(self, op: str, **arguments):
        return self.implementations[self.current].call(op, **arguments)

    def outcome(self, op: str, **arguments):
        try:
            return {"ok": self.call(op, **arguments)}
        except Refused as refused:
            return {"error": refused.error, "message": refused.message}

    def head(self) -> str:
        return run_git(self.repo, "rev-parse", "--verify", "-q", ARTIFACT_REF, allow=(0, 1))

    def files(self) -> dict:
        return {path: bytes.fromhex(content)
                for path, content in self.call("store.snapshot")["files"].items()}

    def mutate(self, event_id: str, *operations):
        return self.call("store.mutate", mutation={
            "event_id": event_id, "actor_type": "pm", "device_id": "device-a",
            "expected_base": self.head(), "operations": list(operations),
        })

    def retention(self, function: str, **arguments):
        options = {"now": stamp(NOW), "confirmation": self.confirmation}
        options.update(arguments)
        return self.outcome("retention." + function, **options)

    def disk(self) -> dict:
        """Everything retention may leave behind, as comparable data."""
        refs = run_git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)")
        remote_refs = run_git(self.remote, "for-each-ref", "--format=%(refname) %(objectname)")
        materialized = {}
        orchestrator = self.repo / ".orchestrator"
        if orchestrator.exists():
            for path in sorted(orchestrator.rglob("*")):
                if path.is_file():
                    materialized[str(path.relative_to(orchestrator))] = hashlib.sha256(
                        path.read_bytes()).hexdigest()
        state = {}
        project_state = self.state / "artifacts" / PROJECT
        for path in sorted(project_state.rglob("*")) if project_state.exists() else ():
            if not path.is_file() or path.suffix in {".lock", ".tmp"}:
                continue
            content = path.read_bytes()
            # Wall-clock stamps the store and sync engine write, not the pinned clock.
            if path.name in {"sync-state.json", "remote-history-verification.json",
                             "materialization.json"}:
                value = json.loads(content)
                value.pop("updated_at", None)
                value.pop("materialized_at", None)
                content = json.dumps(value, sort_keys=True).encode()
            state[str(path.relative_to(project_state))] = content.decode()
        return {"refs": refs.splitlines(), "remote_refs": remote_refs.splitlines(),
                "materialized": materialized, "state": state}


# -- the scenarios ----------------------------------------------------------------
# A step is a function of the fixture returning its answer; the runner calls it
# with the implementation whose turn it is already selected.


def seed_retained(fx: Fixture):
    return fx.mutate("seed-retained-terminal", *[
        ticket_write(f"RR-retained-{index:02d}", f"RR-retained-{index:02d}",
                     NOW + timedelta(seconds=index), status="done")
        for index in range(25)
    ])


def seed_overage(fx: Fixture):
    return fx.mutate(
        "seed-overage",
        ticket_write("RR-1", "Done predecessor", OLD, status="done"),
        ticket_write("RR-2", "Canceled predecessor", OLD, status="backlog", canceled="true"),
        ticket_write("RR-3", "Open dependent", NOW, depends_on="[RR-1, RR-2, RR-missing]"),
        ticket_write("RR-lease", "Leased", OLD, status="done"),
        ticket_write("RR-pending", "Unpublished", OLD, status="done", pending_sync="true"),
        ticket_write("RR-worker", "Reviewing", OLD, status="done", run_state="reviewing"),
        ticket_write("RR-spike", "Old spike", OLD, status="done", execution_mode="spike"),
    )


def acquire_lease(fx: Fixture):
    return fx.retention("lease_acquire", lease_id="lease-codex", ticket_id="RR-lease",
                        artifact_id="artifact-RR-lease", artifact_head=fx.head(), run_id="run-7",
                        role="worker", provider="codex", now=stamp(OLD))


def dependencies(fx: Fixture):
    return [
        [fx.retention("dependency_satisfied", dependency_id=ticket),
         fx.retention("dependency_execution_mode", dependency_id=ticket)]
        for ticket in ("RR-1", "RR-2", "RR-3", "RR-spike", "RR-missing", "RR-retained-00")
    ]


def refusals(fx: Fixture):
    other = dict(fx.confirmation, push_url_sha256="0" * 64)
    return [
        fx.retention("archive", event_id="refused", device_id="device-a", enabled=False),
        fx.retention("archive", event_id="refused", device_id="device-a",
                     remote_mode="local_only", synchronizer=False),
        fx.retention("archive", event_id="refused", device_id="device-a", synchronizer=False),
        fx.retention("archive", event_id="refused", device_id="device-a", confirmation=None),
        fx.retention("archive", event_id="refused", device_id="device-a", confirmation=other),
        fx.retention("archive", event_id="refused", device_id="device-a",
                     confirmation=dict(fx.confirmation, remote_name="upstream")),
        fx.retention("restore", artifact_id="artifact-RR-1", event_id="r", device_id="device-a"),
        fx.retention("delete", ticket_id="RR-lease", event_id="d", device_id="device-a"),
        fx.retention("delete", ticket_id="RR-nope", event_id="d", device_id="device-a"),
        fx.retention("lease_heartbeat", lease_id="lease-unknown"),
        fx.retention("lease_acquire", lease_id="lease-codex", ticket_id="RR-1",
                     artifact_id="artifact-RR-1", artifact_head=fx.head(), run_id="run-7",
                     role="worker", provider="codex"),
        fx.retention("lease_acquire", lease_id="bad id", ticket_id="RR-1", artifact_id="a",
                     artifact_head=fx.head(), run_id="r", role="worker", provider="codex"),
        fx.retention("lease_acquire", lease_id="lease-x", ticket_id="RR-1", artifact_id="a",
                     artifact_head=fx.head(), run_id="r", role="pm", provider="codex"),
        fx.retention("lease_acquire", lease_id="lease-x", ticket_id="RR-1", artifact_id="a",
                     artifact_head="nothex", run_id="r", role="worker", provider="codex"),
        fx.retention("lease_acquire", lease_id="lease-x", ticket_id="RR-1", artifact_id="a",
                     artifact_head=fx.head(), run_id="r", role="worker", provider="claude",
                     attachment_paths=[".orchestrator/attachments/RR-2/x.png"]),
        fx.retention("lease_release", lease_id="lease-codex", terminal_reason=" "),
        fx.retention("confirm_github_remote", remote_name="origin", exposure_confirmed=False),
        fx.retention("confirm_github_remote", remote_name="bad name", exposure_confirmed=True),
        fx.retention("confirm_github_remote", remote_name="origin", exposure_confirmed=True),
        fx.retention("confirm_github_remote", remote_name="missing", exposure_confirmed=True),
        fx.outcome("retention.preview", remote_mode="sideways"),
    ]


def stale_plan(fx: Fixture):
    plan = fx.retention("preview", keep=True)
    fx.mutate("write-RR-new", ticket_write("RR-new", "New", NOW, status="backlog"))
    return [plan, fx.retention("archive", kept_plan=True, event_id="stale-plan", device_id="device-a")]


def crash_after_prepare(fx: Fixture):
    return fx.retention("archive", event_id="retention:apply:one", device_id="device-a",
                        provider="codex", fail_stage="after_archive_prepare")


def blocked_by_transaction(fx: Fixture):
    return [fx.retention("transaction_status"), fx.retention("status"),
            fx.retention("archive", event_id="retention:apply:two", device_id="device-a")]


def history(fx: Fixture):
    return [
        fx.retention("history_search", query="predecessor"),
        fx.retention("historical_search"),
        fx.retention("historical_detail", artifact_id="artifact-RR-1"),
        fx.retention("historical_detail", artifact_id="artifact-RR-2"),
        fx.retention("historical_detail", artifact_id="artifact-missing"),
        fx.retention("historical_detail", artifact_id="artifact-RR-1", online=True),
        fx.retention("historical_attachment", artifact_id="artifact-RR-1", filename="proof.png"),
        fx.retention("historical_attachment", artifact_id="artifact-RR-1", filename="other.png"),
        fx.retention("historical_attachment", artifact_id="artifact-RR-1", filename="../x.png"),
        fx.retention("historical_attachment", artifact_id="bad id!", filename="proof.png"),
    ]


def tamper_catalog(fx: Fixture):
    catalog = [json.loads(line) for line in
               fx.files()[".orchestrator/archive-index.jsonl"].decode().splitlines()]
    owner = next(entry for entry in catalog if entry["ticket_id"] == "RR-spike")
    owner["attachments"] = [dict(next(entry for entry in catalog
                                      if entry["ticket_id"] == "RR-1")["attachments"][0])]
    content = "".join(json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n"
                      for entry in catalog).encode()
    written = fx.mutate("tamper-catalog", {"type": "ArchiveIndexWrite", "content": content.hex()})
    return [written["commit_id"], fx.retention("historical_detail", artifact_id="artifact-RR-spike"),
            fx.retention("preview"), fx.retention("restore", artifact_id="artifact-RR-spike",
                                                  event_id="restore-tampered", device_id="device-a")]


ARCHIVE_STEPS = [
    seed_retained,
    seed_overage,
    lambda fx: fx.mutate("attach-RR-1", attachment_write("RR-1", "proof.png", PNG)),
    acquire_lease,
    lambda fx: fx.retention("preview"),
    lambda fx: fx.retention("status"),
    lambda fx: fx.retention("status", synchronizer=False, remote_mode="local_only", confirmation=None),
    dependencies,
    lambda fx: [fx.retention("lease_active"), fx.retention("lease_active_ticket_ids")],
    refusals,
    stale_plan,
    crash_after_prepare,
    blocked_by_transaction,
    lambda fx: fx.retention("recover_archive"),
    lambda fx: fx.retention("archive", event_id="retention:apply:one", device_id="device-a",
                            provider="codex"),
    lambda fx: fx.retention("recover_archive"),
    lambda fx: fx.retention("preview"),
    lambda fx: fx.retention("status"),
    dependencies,
    history,
    lambda fx: fx.retention("restore", artifact_id="artifact-RR-1", event_id="restore-one",
                            device_id="device-a", at=stamp(NOW)),
    lambda fx: fx.retention("restore", artifact_id="artifact-RR-1", event_id="restore-one",
                            device_id="device-a", at=stamp(NOW)),
    lambda fx: fx.retention("reopen", artifact_id="artifact-RR-2", event_id="reopen-two",
                            device_id="device-a", provider="claude"),
    lambda fx: fx.retention("delete", ticket_id="RR-retained-00", event_id="delete-zero",
                            device_id="device-a"),
    lambda fx: fx.retention("restore", artifact_id="artifact-RR-retained-00",
                            event_id="restore-zero", device_id="device-a", remote_mode="local_only",
                            synchronizer=False, confirmation=None),
    lambda fx: fx.retention("lease_release", lease_id="lease-codex", terminal_reason="run ended"),
    lambda fx: fx.retention("lease_release", lease_id="lease-codex", terminal_reason="run ended"),
    lambda fx: fx.retention("lease_release", lease_id="lease-codex", terminal_reason="other"),
    lambda fx: fx.retention("preview"),
    lambda fx: fx.retention("archive", event_id="retention:apply:three", device_id="device-a"),
    lambda fx: fx.retention("storage_metrics"),
    dependencies,
    tamper_catalog,
    lambda fx: fx.outcome("sync.status", remote_name="origin"),
]


def seed_large_board(fx: Fixture):
    nonterminal = ("backlog", "ready", "queued", "in_progress", "verification_blocked",
                   "awaiting_review", "merge_conflict")
    operations = [ticket_write(f"RR-N{index}", status, OLD - timedelta(days=300),
                               status=status, depends_on="[RR-missing]")
                  for index, status in enumerate(nonterminal, 1)]
    for index in range(40):
        extra = {"status": "done"} if index % 2 else {"status": "backlog", "canceled": "true"}
        operations.append(ticket_write(f"RR-T{index:02d}", f"terminal {index}",
                                       NOW + timedelta(seconds=index // 3), **extra))
    for index in range(6):
        operations.append(ticket_write(f"RR-E{index}", f"equal {index}", NOW + timedelta(days=2),
                                       status="done", artifact_id=f"artifact-equal-{5 - index}"))
    return fx.mutate("seed-large", *operations)


LARGE_BOARD_STEPS = [
    seed_large_board,
    lambda fx: fx.retention("preview"),
    lambda fx: fx.retention("preview", evaluated_at="2026-08-04T06:00:00+05:00"),
    lambda fx: fx.retention("status"),
    lambda fx: [fx.retention("dependency_satisfied", dependency_id=ticket)
                for ticket in ("RR-T00", "RR-T01", "RR-N1", "RR-missing")],
    lambda fx: fx.retention("archive", event_id="retention:apply:large", device_id="device-a"),
    lambda fx: fx.retention("preview"),
    lambda fx: fx.retention("history_search", query="TERMINAL 1"),
    lambda fx: fx.retention("reopen", artifact_id="artifact-RR-T03", event_id="reopen-t03",
                            device_id="device-a", at=stamp(NOW + timedelta(days=3))),
    lambda fx: fx.retention("preview"),
    lambda fx: fx.retention("archive", event_id="retention:apply:large-2", device_id="device-a"),
    lambda fx: fx.retention("storage_metrics"),
]

SCENARIOS = {"archive": ARCHIVE_STEPS, "large_board": LARGE_BOARD_STEPS}


@unittest.skipUnless(driver_command(), "relay-artifacts driver is not built; run cargo test in rust/")
class RetentionParityTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="relay-retention-parity-")
        cls.root = Path(cls.temporary.name).resolve() / "fixture"

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_scenario(self, steps, kinds: tuple) -> list:
        """Each step's answer and the bytes on disk after it; step `i` runs on
        `kinds[i % len(kinds)]`."""
        fixture = Fixture(self.root, kinds)
        try:
            record = []
            for index, step in enumerate(steps):
                fixture.use(kinds[index % len(kinds)])
                record.append({"step": index, "answer": step(fixture), "disk": fixture.disk()})
            return record
        finally:
            fixture.close()

    def assertRecordsEqual(self, actual: list, expected: list, label: str):
        self.assertEqual(len(actual), len(expected))
        for got, want in zip(actual, expected):
            self.assertEqual(got, want, "%s step %d" % (label, want["step"]))

    def test_scenarios_alternate_and_match(self):
        for name, steps in SCENARIOS.items():
            with self.subTest(scenario=name):
                python = self.run_scenario(steps, ("python",))
                rust = self.run_scenario(steps, ("rust",))
                self.assertRecordsEqual(rust, python, name + " rust")
                for order in (("python", "rust"), ("rust", "python")):
                    turns = self.run_scenario(steps, order)
                    self.assertRecordsEqual(turns, python, name + " " + "-".join(order))
                if name == "archive":
                    self.check_archive_outcomes(rust)

    def check_archive_outcomes(self, record: list):
        """The Rust run reaches the outcomes tests/test_artifact_retention.py asserts."""
        answers = [item["answer"] for item in record]
        plan = answers[4]["ok"]
        self.assertEqual(plan["eviction_candidate_ids"], ["RR-1", "RR-2", "RR-spike"])
        self.assertEqual(plan["temporary_overage"], {
            "RR-lease": ["live_lease:snapshot"], "RR-pending": ["unpublished_content"],
            "RR-worker": ["live_lease:reviewing"]})
        status = answers[5]["ok"]
        self.assertEqual(status["state"], "blocked")
        self.assertTrue(any("github.com" in reason for reason in status["blocked_reasons"]))
        self.assertEqual(answers[10][1]["error"], "ArtifactConcurrentUpdate")
        self.assertEqual(answers[11]["error"], "ArtifactInjectedFailure")
        self.assertEqual(answers[12][0]["ok"]["state"], "prepared")
        recovered = answers[13]["ok"]
        self.assertEqual((recovered["state"], recovered["ticket_ids"]),
                         ("archived", ["RR-1", "RR-2", "RR-spike"]))
        self.assertTrue(answers[14]["ok"]["write"]["idempotent"])
        remote = [line for line in record[13]["disk"]["remote_refs"] if ARTIFACT_REF in line]
        self.assertEqual(remote, ["%s %s" % (ARTIFACT_REF, recovered["write"]["commit_id"])])
        self.assertEqual(answers[19][2]["ok"]["availability"], "available")
        self.assertEqual(answers[20]["ok"]["state"], "restore_pending_sync")


if __name__ == "__main__":
    unittest.main()
