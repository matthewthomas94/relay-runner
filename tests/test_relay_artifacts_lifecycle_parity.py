"""RR-495: services/artifact_lifecycle.py against relay_artifacts::lifecycle.

Each scenario builds the fixture of tests/test_artifact_lifecycle.py (a source
repository with an artifact store whose board enables the artifact
lifecycle, and a registry-v2 record for its project) and runs a run's whole
lifecycle through the Python coordinator in-process and the Rust coordinator
through the relay-artifacts test driver, with pinned Git dates and one pinned
clock: scope validation, claim and read-only snapshot materialization,
structured outcome posts (including one superseding post), completion
checks, review leases, the merge-gated `done` publication with dependency
promotion, the verification-blocked publication, resume and close-out,
failure, retry, cancel and merge-conflict records, spike publication, lease
recovery and dependency queueing. Every step's answer (results, and every
refusal's class and message) is compared, and so are the bytes left behind
after each step: all refs, the materialized board, the project state (leases,
outcome files, snapshot proofs) and each worker worktree's snapshot tree
with its file modes.

Every run uses the same absolute fixture path, one after another, so paths
in results and manifests are equal. Alternation runs the steps with Python
and Rust taking turns on one repository and data root, in both orders, and
must leave exactly what an all-Python run leaves.

Rust cases skip when the crate's test driver is not built (``cargo test`` in
rust/ builds it); see tests/relay_artifacts_support.py.
"""

from __future__ import annotations

import base64
import dataclasses
import hashlib
import importlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
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
PROJECT = "lifecycle-project"
DEVICE = "daemon-device"
PNG = b"\x89PNG\r\n\x1a\nworker-proof"
NOW = "2026-08-04T05:06:07.123456Z"
REGISTRY_UPDATED = "2026-08-04T05:00:00Z"


def isolation() -> dict:
    return {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", **git_dates()}


def run_git(repo, *arguments, allow=(0,)) -> str:
    command = ["git"] + (["-C", str(repo)] if repo is not None else []) + list(arguments)
    process = subprocess.run(command, capture_output=True, check=False,
                             env={**os.environ, **isolation()})
    if process.returncode not in allow:
        raise AssertionError(f"{' '.join(command)} failed: {process.stderr.decode()}")
    return process.stdout.decode().strip()


def commit(repo: Path, message: str) -> str:
    run_git(repo, "add", "source.txt")
    run_git(repo, "-c", "user.name=Lifecycle Tests", "-c", "user.email=lifecycle@example.invalid",
            "commit", "-q", "-m", message)
    return run_git(repo, "rev-parse", "HEAD")


def bare_module(name: str):
    """A services/ module bound to the same bare `artifact_store` module
    PythonArtifacts opens stores with, not a second `services.` copy."""
    if name in sys.modules:
        return sys.modules[name]
    saved = {key: sys.modules.pop(key) for key in list(sys.modules)
             if key == "services" or key.startswith("services.")}
    sys.modules["services"] = None
    try:
        return importlib.import_module(name)
    finally:
        sys.modules.pop("services", None)
        sys.modules.update(saved)


def remove_tree(path: Path) -> None:
    """Remove a fixture, including read-only worker snapshots."""
    for directory, _dirs, _files in os.walk(path):
        os.chmod(directory, 0o755)
    shutil.rmtree(path)


class PythonLifecycle(PythonArtifacts):
    """PythonArtifacts with the `lifecycle.*` operations of the Rust driver."""

    def _lifecycle(self, function: str, a: dict):
        lifecycle = bare_module("artifact_lifecycle")
        coordinator_class = lifecycle.ArtifactLifecycleCoordinator
        if function == "cleanup_snapshot":
            return coordinator_class.cleanup_snapshot(Path(a["workspace"]))
        if function == "is_enabled":
            return coordinator_class.is_enabled(self.store)
        now = datetime.fromisoformat(a["now"].replace("Z", "+00:00")) if a.get("now") else None
        coordinator = coordinator_class(
            self.store, registry_path=Path(a["registry_path"]), device_id=a["device_id"],
            now=(lambda: now) if now else None,
        )
        run = {"run_id": a.get("run_id"), "ticket_id": a.get("ticket_id"), "provider": a.get("provider")}

        def written(result):
            return None if result is None else dataclasses.asdict(result)

        if function == "validate_scope":
            return dataclasses.asdict(coordinator.validate_scope(
                a.get("token"), internally_confirmed_project_id=a.get("internal")))
        if function == "claim":
            snapshot = coordinator.claim_and_materialize(**run, workspace_path=Path(a["workspace"]))
            return {**dataclasses.asdict(snapshot), "manifest_path": str(snapshot.manifest_path)}
        if function == "update_worker_sizing":
            return written(coordinator.update_worker_sizing(
                ticket_id=a["ticket_id"], provider=a["provider"], fields=a["fields"]))
        if function == "submit_outcome":
            workspace = Path(a["workspace"]) if a.get("workspace") else None
            return lifecycle._outcome_json(coordinator.submit_outcome(
                **run, payload=a["payload"], workspace_path=workspace))
        if function == "outcome":
            outcome = coordinator.outcome(a["run_id"])
            return None if outcome is None else lifecycle._outcome_json(outcome)
        if function == "validate_worker_completion":
            return list(coordinator.validate_worker_completion(
                workspace_path=Path(a["workspace"]), **run, start_head=a.get("start_head")))
        if function == "begin_review":
            return coordinator.begin_review(run_id=a["run_id"], provider=a["provider"])
        if function == "record_failure":
            return written(coordinator.record_failure(
                **run, reason=a["reason"], canceled=bool(a.get("canceled")),
                retry=bool(a.get("retry"))))
        if function == "recover_spike_completion":
            return written(coordinator.recover_spike_completion(a["run_id"]))
        if function == "recover_spike_failure":
            return coordinator.recover_spike_failure(a["run_id"])
        if function == "publish_spike_result":
            return written(coordinator.publish_spike_result(
                **run, workspace_path=Path(a["workspace"]), report=a["report"]))
        if function == "record_merge_conflict":
            return written(coordinator.record_merge_conflict(**run, reason=a["reason"]))
        if function == "publish_merge_success":
            return written(coordinator.publish_merge_success(
                **run, merged_source_commit=a["merged_source_commit"]))
        if function == "publish_verification_closeout":
            return written(coordinator.publish_verification_closeout(**run))
        if function == "promote_unblocked_dependents":
            return list(coordinator.promote_unblocked_dependents())
        if function == "queue_for_dependencies":
            return written(coordinator.queue_for_dependencies(a["ticket_id"]))
        if function == "resume_verification":
            return written(coordinator.resume_verification(**run, reason=a["reason"]))
        if function == "recover_leases":
            states = a.get("run_states", {})
            return list(coordinator.recover_leases(
                lambda run_id: states.get(str(run_id)),
                preserve_run_ids=tuple(a.get("preserve_run_ids", ()))))
        if function == "cap_local_log":
            return coordinator.cap_local_log(Path(a["path"]), max_bytes=a["max_bytes"])
        raise KeyError(function)


def make_implementation(name: str):
    if name == "python":
        return PythonLifecycle(environment=isolation())
    return implementation("rust", environment=isolation())


# -- the fixture ----------------------------------------------------------------


def ticket_write(ticket_id: str, title: str, *, status="ready", depends_on=(), canceled=False,
                 draft=False, extra=()) -> dict:
    fields = [
        f"id: {ticket_id}", f"artifact_id: artifact-{ticket_id}", f"title: {title}",
        f"status: {status}", "priority: medium", "run_id: null",
        "activity_at: 2026-08-04T00:00:00.000000Z", f"depends_on: [{', '.join(depends_on)}]",
        f"canceled: {str(canceled).lower()}", f"draft: {str(draft).lower()}",
        "worker_model: strong", "worker_effort: high", "worker_sizing_rationale: fixture",
        "worker_provider_notes: provider-neutral fixture", *extra,
    ]
    markdown = ("---\n" + "\n".join(fields) + "\n---\n\n## Description\n\n" + title + "\n").encode()
    return {"type": "TicketWrite", "ticket_id": ticket_id, "artifact_id": f"artifact-{ticket_id}",
            "markdown": markdown.hex()}


class Fixture:
    def __init__(self, root: Path, kinds: tuple):
        if root.exists():
            remove_tree(root)
        root.mkdir(parents=True)
        self.root = root
        self.repo = root / "repo"
        self.state = root / "state"
        self.repo.mkdir()
        run_git(self.repo, "init", "--initial-branch=main", "--quiet")
        (self.repo / "source.txt").write_text("base\n")
        commit(self.repo, "source base")
        self.registry = self.state / "projects/registry-v2.json"
        self.registry.parent.mkdir(parents=True)
        self.registry.write_text(json.dumps({
            "schema_version": 2, "active_project_id": PROJECT,
            "projects": [{
                "project_id": PROJECT, "display_name": "Lifecycle",
                "selected_path": str(self.repo), "last_resolved_path": str(self.repo),
                "git_common_directory_fingerprint": "fingerprint-a", "availability": "available",
                "updated_at": REGISTRY_UPDATED,
            }],
        }))
        self.implementations = {kind: make_implementation(kind) for kind in set(kinds)}
        self.current = None
        self.use(kinds[0])
        self.call("store.initialize", device_id=DEVICE)
        config = bytes.fromhex(self.call("store.snapshot")["files"][".orchestrator/config.toml"])
        config = config.decode().replace('artifact_lifecycle = "legacy"', 'artifact_lifecycle = "enabled"')
        self.mutate("enable-lifecycle", {"type": "ConfigWrite", "content": config.encode().hex()},
                    actor_type="user")

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

    def mutate(self, event_id: str, *operations, actor_type="pm"):
        head = run_git(self.repo, "rev-parse", "--verify", "-q", "refs/heads/relay/artifacts",
                       allow=(0, 1))
        return self.call("store.mutate", mutation={
            "event_id": event_id, "actor_type": actor_type, "device_id": DEVICE,
            "expected_base": head or None, "operations": list(operations),
        })

    def lifecycle(self, function: str, **arguments):
        options = {"registry_path": str(self.registry), "device_id": DEVICE, "now": NOW}
        options.update(arguments)
        return self.outcome("lifecycle." + function, **options)

    def worktree(self, name: str) -> Path:
        path = self.root / name
        if not path.exists():
            run_git(self.repo, "worktree", "add", "-q", "-b", name, str(path), "main")
        return path

    def token(self, *, fingerprint="fingerprint-a", repository_path=None) -> str:
        payload = {
            "version": 1, "registrySchemaVersion": 2, "projectID": PROJECT,
            "repositoryPath": repository_path or str(self.repo),
            "gitCommonDirectoryFingerprint": fingerprint,
            "registryRecordUpdatedAt": datetime.fromisoformat(
                REGISTRY_UPDATED.replace("Z", "+00:00")).timestamp(),
            "issuedAt": 1_786_000_000.0,
        }
        return base64.b64encode(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).decode()

    def disk(self) -> dict:
        """Everything the lifecycle may leave behind, as comparable data."""
        refs = run_git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)").splitlines()

        def tree(root: Path, modes: bool) -> dict:
            result = {}
            if not root.exists():
                return result
            for path in sorted(root.rglob("*")):
                relative = str(path.relative_to(root))
                mode = oct(stat.S_IMODE(path.lstat().st_mode)) if modes else None
                if path.is_dir():
                    result[relative + "/"] = mode
                else:
                    result[relative] = [hashlib.sha256(path.read_bytes()).hexdigest(), mode]
            return result

        state = {}
        project_state = self.state / "artifacts" / PROJECT
        for path in sorted(project_state.rglob("*")) if project_state.exists() else ():
            if not path.is_file() or path.suffix in {".lock", ".tmp"}:
                continue
            content = path.read_bytes()
            if path.name == "materialization.json":
                value = json.loads(content)
                value.pop("materialized_at", None)  # wall clock, not the pinned one
                content = json.dumps(value, sort_keys=True).encode()
            state[str(path.relative_to(project_state))] = content.decode()
        snapshots = {path.name: tree(path / ".orchestrator", True)
                     for path in sorted(self.root.glob("run-*"))}
        return {"refs": refs, "board": tree(self.repo / ".orchestrator", False),
                "state": state, "snapshots": snapshots,
                "source_status": run_git(self.repo, "status", "--porcelain")}


# -- the steps ------------------------------------------------------------------
# A step is a function of the fixture returning its answer; the runner calls it
# with the implementation whose turn it is already selected.


def write_board(fx: Fixture):
    return fx.mutate(
        "write-board",
        ticket_write("RR-1", "Work"),
        ticket_write("RR-2", "Dependent", status="backlog", depends_on=("RR-1",)),
        ticket_write("RR-3", "Canceled dependent", status="backlog", depends_on=("RR-1",),
                     canceled=True),
        ticket_write("RR-4", "Draft dependent", status="backlog", depends_on=("RR-1",), draft=True),
        ticket_write("RR-5", "Waits on a spike", status="backlog", depends_on=("RR-1", "RR-6")),
        ticket_write("RR-6", "Finished spike", status="done", extra=("execution_mode: spike",)),
        ticket_write("RR-7", "Physical proof"),
        ticket_write("RR-8", "After proof", status="backlog", depends_on=("RR-7",)),
        ticket_write("RR-9", "Research", extra=("execution_mode: spike",)),
        ticket_write("RR-10", "Failure target"),
        ticket_write("RR-11", "After failure", status="backlog", depends_on=("RR-10",)),
    )


def scope(fx: Fixture):
    alias = fx.root / "repository-alias"
    if not alias.exists():
        alias.symlink_to(fx.repo, target_is_directory=True)
    return [
        fx.lifecycle("is_enabled"),
        fx.lifecycle("validate_scope", token=fx.token()),
        fx.lifecycle("validate_scope", token=fx.token(repository_path=str(alias))),
        fx.lifecycle("validate_scope", token=None),
        fx.lifecycle("validate_scope", token=fx.token(fingerprint="stale")),
        fx.lifecycle("validate_scope", token=fx.token(repository_path=str(fx.state))),
        fx.lifecycle("validate_scope", token="!!!"),
        fx.lifecycle("validate_scope", token=base64.b64encode(b'{"version": 2}').decode()),
        fx.lifecycle("validate_scope", internal=PROJECT),
        fx.lifecycle("validate_scope", internal="other-project"),
        fx.lifecycle("validate_scope", registry_path=str(fx.root / "missing.json"), internal=PROJECT),
        fx.lifecycle("validate_scope", device_id="bad device"),
    ]


def claim_one(fx: Fixture):
    return fx.lifecycle("claim", ticket_id="RR-1", run_id=2, provider="claude",
                        workspace=str(fx.worktree("run-2")))


def claim_refusals(fx: Fixture):
    other = str(fx.worktree("run-3"))
    return [
        fx.lifecycle("claim", ticket_id="RR-1", run_id=3, provider="codex", workspace=other),
        fx.lifecycle("claim", ticket_id="RR-3", run_id=3, provider="codex", workspace=other),
        fx.lifecycle("claim", ticket_id="RR-6", run_id=3, provider="codex", workspace=other),
        fx.lifecycle("claim", ticket_id="RR-missing", run_id=3, provider="codex", workspace=other),
        fx.lifecycle("claim", ticket_id="RR-1", run_id=0, provider="codex", workspace=other),
        fx.lifecycle("claim", ticket_id="RR-1", run_id=3, provider="gemini", workspace=other),
        fx.lifecycle("claim", ticket_id="bad id!", run_id=3, provider="codex", workspace=other),
    ]


def payload(source_commit: str, **changes) -> dict:
    value = {"status": "completed", "summary": "Implemented the scoped source change.",
             "changed_paths": ["source.txt"], "verification": ["focused tests passed"],
             "source_commit": source_commit}
    value.update(changes)
    return value


def submit_one(fx: Fixture):
    worktree = fx.worktree("run-2")
    (worktree / "source.txt").write_text("implemented\n")
    head = commit(worktree, "feat: implementation")
    run = {"run_id": 2, "ticket_id": "RR-1", "provider": "claude"}
    return [
        fx.lifecycle("submit_outcome", **run, payload=payload(head)),
        fx.lifecycle("submit_outcome", **run, payload=payload(head)),
        fx.lifecycle("outcome", run_id=2),
        fx.lifecycle("outcome", run_id=99),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, raw_log="private")),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, extra="x")),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, changed_paths=[".orchestrator/RR-1.md"])),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, changed_paths=[])),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, status="maybe")),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, summary="")),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, verification="x")),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, run_id=3)),
        fx.lifecycle("submit_outcome", **run, payload=payload("abc")),
        fx.lifecycle("submit_outcome", **dict(run, provider="codex"), payload=payload(head)),
        fx.lifecycle("submit_outcome", **dict(run, run_id=77), payload=payload(head)),
        fx.lifecycle("submit_outcome", **run, payload=payload(head, summary="Changed.")),
    ]


def complete_one(fx: Fixture):
    worktree = str(fx.worktree("run-2"))
    start = run_git(fx.repo, "rev-parse", "main")
    run = {"run_id": 2, "ticket_id": "RR-1", "workspace": worktree}
    return [
        fx.lifecycle("validate_worker_completion", **run, provider="claude", start_head=start),
        fx.lifecycle("validate_worker_completion", **run, provider="codex", start_head=start),
        fx.lifecycle("validate_worker_completion", **run, provider="claude", start_head=None),
        fx.lifecycle("validate_worker_completion", **run, provider="claude",
                     start_head=run_git(worktree, "rev-parse", "HEAD")),
        fx.lifecycle("publish_merge_success", run_id=2, ticket_id="RR-1", provider="claude",
                     merged_source_commit=run_git(worktree, "rev-parse", "HEAD")),
        fx.lifecycle("begin_review", run_id=2, provider="codex"),
        fx.lifecycle("begin_review", run_id=2, provider="codex"),
        fx.lifecycle("begin_review", run_id=99, provider="codex"),
    ]


def merge(fx: Fixture, branch: str) -> str:
    run_git(fx.repo, "-c", "user.name=Lifecycle Tests", "-c", "user.email=lifecycle@example.invalid",
            "merge", "--no-ff", "--quiet", branch, "-m", f"merge {branch}")
    return run_git(fx.repo, "rev-parse", "HEAD")


def publish_one(fx: Fixture):
    merged = merge(fx, "run-2")
    run = {"run_id": 2, "ticket_id": "RR-1", "provider": "claude"}
    return [
        fx.lifecycle("publish_merge_success", **run, merged_source_commit="nothex"),
        fx.lifecycle("publish_merge_success", **dict(run, provider="codex"), merged_source_commit=merged),
        fx.lifecycle("publish_merge_success", **run, merged_source_commit=merged),
        fx.lifecycle("publish_merge_success", **run, merged_source_commit=merged),
    ]


def queue_and_sizing(fx: Fixture):
    sizing = {"worker_model": "balanced", "worker_effort": "medium",
              "worker_sizing_rationale": "Small bounded follow-up.", "worker_provider_notes": "none"}
    return [
        fx.lifecycle("promote_unblocked_dependents"),
        fx.lifecycle("queue_for_dependencies", ticket_id="RR-5"),
        fx.lifecycle("queue_for_dependencies", ticket_id="RR-5"),
        fx.lifecycle("queue_for_dependencies", ticket_id="RR-missing"),
        fx.lifecycle("update_worker_sizing", ticket_id="RR-8", provider="codex", fields=sizing),
        fx.lifecycle("update_worker_sizing", ticket_id="RR-8", provider="codex", fields=sizing),
        fx.lifecycle("update_worker_sizing", ticket_id="RR-missing", provider="codex", fields=sizing),
        fx.lifecycle("update_worker_sizing", ticket_id="RR-8", provider="codex",
                     fields=dict(sizing, worker_effort="")),
    ]


BLOCKER = "Signed installed app needs physical input."
RESUME = "Install signed build and perform physical input."


def block_and_merge(fx: Fixture):
    worktree = fx.worktree("run-4")
    run = {"run_id": 4, "ticket_id": "RR-7", "provider": "codex"}
    answers = [fx.lifecycle("claim", **run, workspace=str(worktree))]
    (worktree / "source.txt").write_text("reviewable\n")
    head = commit(worktree, "fix: reviewable")
    answers += [
        fx.lifecycle("submit_outcome", **run, payload=payload(
            head, status="verification_blocked", summary="Source complete. " + "界" * 1000,
            verification=["Source tests passed. " + "é" * 900],
            verification_blocker=BLOCKER, verification_resume=RESUME)),
        fx.lifecycle("validate_worker_completion", run_id=4, ticket_id="RR-7", provider="codex",
                     workspace=str(worktree), start_head=run_git(fx.repo, "rev-parse", "main")),
        fx.lifecycle("begin_review", run_id=4, provider="claude"),
    ]
    merged = merge(fx, "run-4")
    answers.append(fx.lifecycle("publish_merge_success", **run, merged_source_commit=merged))
    return answers


def resume(fx: Fixture):
    run = {"ticket_id": "RR-7", "provider": "codex", "reason": "Signed build installed."}
    return [
        fx.lifecycle("resume_verification", run_id=9, **run),
        fx.lifecycle("resume_verification", run_id=4, **run),
        fx.lifecycle("resume_verification", run_id=4, **run),
        fx.lifecycle("resume_verification", run_id=4, **dict(run, ticket_id="RR-1")),
    ]


def closeout(fx: Fixture):
    worktree = fx.worktree("run-5")
    run = {"run_id": 5, "ticket_id": "RR-7", "provider": "claude"}
    answers = [fx.lifecycle("claim", **run, workspace=str(worktree))]
    head = run_git(worktree, "rev-parse", "HEAD")
    closing = payload(head, summary="External verification passed; no source change was needed.",
                      changed_paths=[], verification=["physical input confirmed on the signed build"])
    answers += [
        fx.lifecycle("submit_outcome", **run, payload=dict(closing, verification=[])),
        fx.lifecycle("submit_outcome", **run, payload=closing),
        fx.lifecycle("validate_worker_completion", **run, workspace=str(worktree), start_head=head),
        fx.lifecycle("publish_verification_closeout", **dict(run, provider="codex")),
        fx.lifecycle("publish_verification_closeout", **run),
        fx.lifecycle("publish_verification_closeout", **run),
        fx.lifecycle("publish_verification_closeout", run_id=2, ticket_id="RR-1", provider="claude"),
    ]
    return answers


def failures(fx: Fixture):
    worktree = str(fx.worktree("run-6"))
    target = {"ticket_id": "RR-10"}
    return [
        fx.lifecycle("record_failure", run_id=6, **target, provider="codex", reason="never claimed"),
        fx.lifecycle("claim", run_id=6, **target, provider="codex", workspace=worktree),
        fx.lifecycle("record_failure", run_id=6, **target, provider="codex",
                     reason="review asked for changes", retry=True),
        fx.lifecycle("record_failure", run_id=6, **target, provider="codex",
                     reason="review asked for changes", retry=True),
        fx.lifecycle("claim", run_id=7, **target, provider="claude", workspace=worktree),
        fx.lifecycle("record_merge_conflict", run_id=7, **target, provider="claude",
                     reason="conflict in source.txt"),
        fx.lifecycle("record_merge_conflict", run_id=7, **target, provider="claude",
                     reason="conflict in source.txt"),
        fx.lifecycle("record_failure", run_id=7, **target, provider="claude",
                     reason="user canceled", canceled=True),
        fx.lifecycle("record_failure", run_id=8, **target, provider="claude", reason=""),
        fx.lifecycle("claim", run_id=8, **target, provider="codex", workspace=worktree),
        fx.lifecycle("record_failure", run_id=8, **target, provider="codex",
                     reason="provider authentication failed"),
    ]


def leases(fx: Fixture):
    worktree = str(fx.worktree("run-9"))
    return [
        fx.lifecycle("claim", run_id=9, ticket_id="RR-11", provider="codex", workspace=worktree),
        fx.lifecycle("recover_leases", run_states={"9": "Running"}),
        fx.lifecycle("recover_leases", run_states={}, preserve_run_ids=[9]),
        fx.lifecycle("recover_leases", run_states={"9": "Unknown"}),
        fx.lifecycle("recover_leases", run_states={}),
        fx.lifecycle("recover_leases", run_states={}),
    ]


def spike(fx: Fixture):
    worktree = str(fx.worktree("run-10"))
    run = {"run_id": 10, "ticket_id": "RR-9", "provider": "codex"}
    report = "## Conclusion\n\nThe research question is answered.\n"
    return [
        fx.lifecycle("recover_spike_completion", run_id=10),
        fx.lifecycle("recover_spike_failure", run_id=10),
        fx.lifecycle("claim", **run, workspace=worktree),
        fx.lifecycle("publish_spike_result", **dict(run, provider="claude"), workspace=worktree,
                     report=report),
        fx.lifecycle("publish_spike_result", **run, workspace=worktree, report=report),
        fx.lifecycle("publish_spike_result", **run, workspace=worktree, report=report),
        fx.lifecycle("recover_spike_completion", run_id=10),
        fx.lifecycle("recover_spike_failure", run_id=10),
        fx.lifecycle("recover_spike_failure", run_id=6),
    ]


def supersede(fx: Fixture):
    worktree = fx.worktree("run-11")
    run = {"run_id": 11, "ticket_id": "RR-2", "provider": "claude", "workspace": str(worktree)}
    answers = [fx.lifecycle("claim", **run)]
    start = run_git(worktree, "rev-parse", "HEAD")
    (worktree / "source.txt").write_text("first\n")
    first = commit(worktree, "feat: first")
    answers.append(fx.lifecycle("submit_outcome", **run, payload=payload(first, summary="First.")))
    run_git(worktree, "-c", "user.name=Lifecycle Tests", "-c", "user.email=lifecycle@example.invalid",
            "commit", "-q", "--amend", "-m", "feat: amended")
    amended = run_git(worktree, "rev-parse", "HEAD")
    answers.append(fx.lifecycle("submit_outcome", **run, payload=payload(amended, summary="Amended.")))
    run_git(worktree, "reset", "-q", "--hard", first)
    (worktree / "source.txt").write_text("second\n")
    second = commit(worktree, "fix: second")
    answers += [
        fx.lifecycle("submit_outcome", **dict(run, workspace=None), payload=payload(second)),
        fx.lifecycle("submit_outcome", **run, payload=payload(first, summary="Same commit.")),
        fx.lifecycle("submit_outcome", **run, payload=payload(second, summary="Second.")),
        fx.lifecycle("submit_outcome", **run, payload=payload(second, summary="Second.")),
    ]
    (worktree / "source.txt").write_text("third\n")
    third = commit(worktree, "fix: third")
    answers += [
        fx.lifecycle("submit_outcome", **run, payload=payload(third, summary="Third.")),
        fx.lifecycle("outcome", run_id=11),
        fx.lifecycle("validate_worker_completion", **run, start_head=start),
    ]
    run_git(worktree, "reset", "-q", "--hard", second)
    answers.append(fx.lifecycle("validate_worker_completion", **run, start_head=start))
    return answers


def cleanup(fx: Fixture):
    log = fx.root / "large.log"
    log.write_bytes(b"x" * 4096)
    return [
        fx.lifecycle("cleanup_snapshot", workspace=str(fx.worktree("run-11"))),
        fx.lifecycle("cap_local_log", path=str(log), max_bytes=100),
        fx.lifecycle("cap_local_log", path=str(log), max_bytes=1000),
        fx.lifecycle("cap_local_log", path=str(fx.root / "missing.log"), max_bytes=10),
        log.read_bytes() == b"x" * 100,
        fx.lifecycle("claim", run_id=12, ticket_id="RR-2", provider="codex",
                     workspace=str(fx.worktree("run-11"))),
        fx.lifecycle("promote_unblocked_dependents"),
    ]


STEPS = [
    write_board,
    lambda fx: fx.mutate("attach-RR-1", {
        "type": "AttachmentWrite", "ticket_id": "RR-1", "filename": "proof.png",
        "mime_type": "image/png", "content": PNG.hex()}, actor_type="user"),
    scope,
    claim_one,
    claim_refusals,
    submit_one,
    complete_one,
    publish_one,
    queue_and_sizing,
    block_and_merge,
    resume,
    closeout,
    failures,
    leases,
    spike,
    supersede,
    cleanup,
]


@unittest.skipUnless(driver_command(), "relay-artifacts driver is not built; run cargo test in rust/")
class LifecycleParityTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="relay-lifecycle-parity-")
        cls.root = Path(cls.temporary.name).resolve() / "fixture"

    @classmethod
    def tearDownClass(cls):
        if cls.root.exists():
            remove_tree(cls.root)
        cls.temporary.cleanup()

    def run_steps(self, kinds: tuple) -> list:
        """Each step's answer and the bytes on disk after it; step `i` runs on
        `kinds[i % len(kinds)]`."""
        fixture = Fixture(self.root, kinds)
        try:
            record = []
            for index, step in enumerate(STEPS):
                fixture.use(kinds[index % len(kinds)])
                record.append({"step": index, "answer": step(fixture), "disk": fixture.disk()})
            return record
        finally:
            fixture.close()

    def assertRecordsEqual(self, actual: list, expected: list, label: str):
        self.assertEqual(len(actual), len(expected))
        for got, want in zip(actual, expected):
            self.assertEqual(got, want, "%s step %d (%s)" % (label, want["step"],
                                                           STEPS[want["step"]].__name__))

    def test_lifecycle_alternates_and_matches(self):
        python = self.run_steps(("python",))
        rust = self.run_steps(("rust",))
        self.assertRecordsEqual(rust, python, "rust")
        for order in (("python", "rust"), ("rust", "python")):
            with self.subTest(order=order):
                self.assertRecordsEqual(self.run_steps(order), python, "-".join(order))
        self.check_outcomes(rust)

    def check_outcomes(self, record: list):
        """The Rust run reaches the outcomes tests/test_artifact_lifecycle.py asserts."""
        answers = [item["answer"] for item in record]
        self.assertEqual(answers[3]["ok"]["lease_id"], "run:2:worker")
        snapshot = record[3]["disk"]["snapshots"]["run-2"]
        self.assertEqual(snapshot["RR-1.md"][1], "0o444")
        self.assertIn("attachments/RR-1/proof.png", snapshot)
        self.assertEqual(answers[6][0]["ok"], ["completed", "structured worker outcome accepted"])
        self.assertEqual(answers[7][2]["ok"]["promoted_ticket_ids"], ["RR-2"])
        self.assertTrue(answers[7][3]["ok"]["idempotent"])
        self.assertEqual(answers[9][-1]["ok"]["promoted_ticket_ids"], [])
        self.assertEqual(answers[11][3]["ok"], ["verification_closeout",
                                                "verification-only close-out accepted"])
        self.assertEqual(answers[11][5]["ok"]["promoted_ticket_ids"], ["RR-8"])
        self.assertEqual(answers[13][4]["ok"], ["run:9:worker"])
        self.assertIn("superseded its outcome once", answers[15][7]["message"])


if __name__ == "__main__":
    unittest.main()
