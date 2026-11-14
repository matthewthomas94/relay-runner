"""RR-495: the relay-artifacts crate's sync engine against services/artifact_sync.py.

Each scenario from tests/test_artifact_sync.py runs once with every device on
the Python engine and once with every device on the Rust engine, in identical
fixtures with pinned Git dates, and the two runs must give the same answers
call by call: states, transitions, heads, recovery text, conflict reports,
refusal classes and messages, and the same `sync-state.json` and
`remote-history-verification.json` files. Because the dates are pinned, equal
answers include equal commit ids for rebased and resolution commits.

The alternation cases then put a Python device and a Rust device on one
remote, and a Python and a Rust engine on one data root in turn, as a daemon
swap would.

Rust cases skip when the crate's test driver is not built (``cargo test`` in
rust/ builds it); see tests/relay_artifacts_support.py.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from relay_artifacts_support import (
    PythonArtifacts,
    Refused,
    driver_command,
    git_dates,
    implementation,
)

ARTIFACT_REF = "refs/heads/relay/artifacts"
PROJECT = "project-sync"


def isolation() -> dict:
    return {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", **git_dates()}


def run_git(repo, *arguments, allow=(0,)) -> str:
    command = ["git"]
    if repo is not None:
        command += ["-C", str(repo)]
    command += list(arguments)
    process = subprocess.run(
        command, capture_output=True, check=False, env={**os.environ, **isolation()},
    )
    if process.returncode not in allow:
        raise AssertionError(f"{' '.join(command)} failed: {process.stderr.decode()}")
    return process.stdout.decode().strip()


def commit_source(repo: Path, message: str) -> None:
    run_git(repo, "add", "-A")
    run_git(repo, "-c", "user.name=Relay Sync Tests", "-c", "user.email=relay-sync@example.invalid",
            "commit", "-q", "-m", message)


def re_sub_line(content: str, key: str, replacement: str) -> str:
    lines = content.splitlines()
    for index, line in enumerate(lines):
        if line.strip().startswith(f"{key} ="):
            lines[index] = replacement
            break
    else:
        lines.append(replacement)
    return "\n".join(lines) + "\n"


def ticket_bytes(ticket_id: str, title: str, artifact_id: str) -> bytes:
    return (
        f"---\nid: {ticket_id}\nartifact_id: {artifact_id}\n"
        f"title: {title}\nstatus: backlog\n---\n\n## Description\n\n{title}\n"
    ).encode()


class PythonSync(PythonArtifacts):
    """PythonArtifacts with the `sync.*` operations of the Rust driver."""

    def _sync(self, function: str, a: dict):
        import artifact_store

        engine_module = _artifact_sync()
        if function == "classify_git_failure":
            state, recovery = engine_module.ArtifactSyncEngine.classify_git_failure(
                a["message"], operation=a["operation"]
            )
            return [state.value, recovery]
        injector = None
        if a.get("fail_stage"):
            wanted = a["fail_stage"]

            def injector(stage):
                if stage == wanted:
                    raise artifact_store.ArtifactInjectedFailure(f"injected failure at {stage}")
        elif a.get("stage_command"):
            command = a["stage_command"]
            fired = []

            def injector(stage):
                if stage == command["stage"] and not fired:
                    fired.append(stage)
                    done = subprocess.run(command["argv"], capture_output=True, check=False)
                    if done.returncode != 0:
                        raise RuntimeError(done.stderr.decode())

        options = {
            "mode": engine_module.ArtifactSyncMode(a.get("mode", "enabled")),
            "remote_name": a.get("remote_name"),
            "base_retry_seconds": a.get("base_retry_seconds", 0),
            "sleep": lambda _: None,
            "jitter": lambda: 0,
            "failure_injector": injector,
        }
        if "max_attempts" in a:
            options["max_attempts"] = a["max_attempts"]
        engine = engine_module.ArtifactSyncEngine(self.store, **options)
        if function == "new":
            return None
        if function in {"status", "sync"}:
            return self._result(getattr(engine, function)())
        if function == "sync_confirmed":
            return self._result(engine.sync_confirmed(
                expected_remote_url_sha256=a["expected_remote_url_sha256"],
                expected_push_url_sha256=a["expected_push_url_sha256"],
            ))
        if function == "publish_initial":
            return self._result(engine.publish_initial(confirmed=bool(a.get("confirmed"))))
        if function == "publish_prepared":
            return self._result(engine.publish_prepared(
                a["candidate_head"],
                expected_remote_head=a["expected_remote_head"],
                proofs=tuple(engine_module.ArtifactRemoteProof(**proof) for proof in a.get("proofs", [])),
                expected_remote_url_sha256=a.get("expected_remote_url_sha256"),
                expected_push_url_sha256=a.get("expected_push_url_sha256"),
            ))
        if function == "recover_exact_ref":
            validated = []

            def validate(head):
                validated.append(head)
                if a.get("reject_head"):
                    raise ValueError(a["reject_head"])

            result = engine.recover_exact_ref(
                expected_remote_url_sha256=a["expected_remote_url_sha256"],
                validate_head=validate if a.get("validate") else None,
            )
            return {"result": self._result(result), "validated": validated}
        if function == "fetch_historical_object":
            return engine.fetch_historical_object(
                a["commit_id"], expected_remote_url_sha256=a["expected_remote_url_sha256"]
            )
        if function == "resolve_conflict":
            raw = a["report"]
            report = engine_module.ArtifactConflictReport(
                project_id=raw["project_id"],
                merge_base=raw["merge_base"],
                local_head=raw["local_head"],
                remote_head=raw["remote_head"],
                local_events=tuple(tuple(item) for item in raw["local_events"]),
                conflicts=tuple(engine_module.ArtifactConflict(**item) for item in raw["conflicts"]),
            )
            decisions = {
                item["path"]: item["keyword"] if "keyword" in item else bytes.fromhex(item["content"])
                for item in a["decisions"]
            }
            return self._result(engine.resolve_conflict(
                report,
                decisions,
                resolution_event_id=a["resolution_event_id"],
                device_id=a["device_id"],
                actor_type=a.get("actor_type", "user"),
                provider=a.get("provider"),
            ))
        if function == "remote_history_verification_path":
            return str(engine._remote_history_verification_path())
        raise KeyError(function)

    @staticmethod
    def _result(result) -> dict:
        report = result.conflict_report
        return {
            "state": result.state.value,
            "observed_state": result.observed_state.value,
            "transitions": [state.value for state in result.transitions],
            "attempts": result.attempts,
            "local_head": result.local_head,
            "remote_head": result.remote_head,
            "recovery": result.recovery,
            "conflict_report": None if report is None else {
                "project_id": report.project_id,
                "merge_base": report.merge_base,
                "local_head": report.local_head,
                "remote_head": report.remote_head,
                "local_events": [list(item) for item in report.local_events],
                "conflicts": [
                    {
                        "path": item.path, "kind": item.kind, "base_oid": item.base_oid,
                        "local_oid": item.local_oid, "remote_oid": item.remote_oid,
                        "recovery": item.recovery,
                    }
                    for item in report.conflicts
                ],
            },
        }


def _artifact_sync():
    """services/artifact_sync.py bound to the same `artifact_store` module
    PythonArtifacts opens stores with, not a second `services.` copy."""
    import sys

    if "artifact_sync" in sys.modules:
        return sys.modules["artifact_sync"]
    saved = sys.modules.get("services", ...)
    sys.modules["services"] = None
    try:
        import artifact_sync
    finally:
        if saved is ...:
            sys.modules.pop("services", None)
        else:
            sys.modules["services"] = saved
    return artifact_sync


def make_implementation(name: str):
    if name == "python":
        return PythonSync(environment=isolation())
    return implementation("rust", environment=isolation())


class Device:
    def __init__(self, fixture, name: str, repo: Path, kind: str):
        self.fixture = fixture
        self.name = name
        self.repo = repo
        self.state = fixture.root / f"state-{name}"
        self.kind = kind
        self.target = make_implementation(kind)
        fixture.test.addCleanup(self.target.close)
        self.open()

    def open(self):
        self.target.call("store.open", repo=str(self.repo), project_id=PROJECT,
                         state_root=str(self.state), enabled=True)

    def switch(self, kind: str):
        """Another implementation takes over this device's data root."""
        self.target.close()
        self.kind = kind
        self.target = make_implementation(kind)
        self.fixture.test.addCleanup(self.target.close)
        self.open()

    def call(self, op: str, **arguments):
        return self.target.call(op, **arguments)

    def outcome(self, op: str, **arguments):
        """The answer, or the refusal's class and message."""
        try:
            return {"ok": self.call(op, **arguments)}
        except Refused as refused:
            return {"error": refused.error, "message": refused.message}

    def sync(self, function: str = "sync", **arguments):
        options = {"mode": "enabled", "remote_name": "origin"}
        options.update(arguments)
        return self.outcome("sync." + function, **options)

    def head(self) -> str:
        return run_git(self.repo, "rev-parse", "--verify", "-q", ARTIFACT_REF, allow=(0, 1))

    def files(self) -> dict:
        return self.call("store.snapshot")["files"]

    def mutation(self, event_id: str, *operations, expected_base=None) -> dict:
        return {
            "event_id": event_id, "actor_type": "pm", "device_id": f"device-{self.name}",
            "provider": "codex" if self.name.startswith("a") else "claude",
            "expected_base": expected_base, "operations": list(operations), "summary": event_id,
        }

    def mutate(self, event_id: str, *operations) -> dict:
        return self.call("store.mutate", mutation=self.mutation(event_id, *operations,
                                                                expected_base=self.head() or None))

    def write_ticket(self, event_id: str, ticket_id: str, title: str, artifact_id=None) -> str:
        artifact_id = artifact_id or f"artifact-{ticket_id}"
        return self.mutate(event_id, {
            "type": "TicketWrite", "ticket_id": ticket_id, "artifact_id": artifact_id,
            "markdown": ticket_bytes(ticket_id, title, artifact_id).hex(),
        })["commit_id"]

    def config_bytes(self, remote_name: str = "origin") -> bytes:
        current = bytes.fromhex(self.files()[".orchestrator/config.toml"]).decode()
        current = re_sub_line(current, "remote_sync", 'remote_sync = "enabled"')
        current = re_sub_line(current, "remote_name", f'remote_name = "{remote_name}"')
        return current.encode()

    def write_config(self, event_id: str, content: bytes) -> dict:
        return self.mutate(event_id, {"type": "ConfigWrite", "content": content.hex()})

    def fetch_digest(self, remote: str = "origin") -> str:
        return hashlib.sha256(run_git(self.repo, "remote", "get-url", remote).encode()).hexdigest()

    def state_files(self) -> dict:
        root = self.state / "artifacts" / PROJECT
        result = {}
        for name in ("sync-state.json", "remote-history-verification.json"):
            path = root / name
            if path.exists():
                value = json.loads(path.read_text())
                value.pop("updated_at", None)
                result[name] = value
        return result


class Fixture:
    """The two-device fixture of tests/test_artifact_sync.py: a bare remote,
    device A that published the enabled config, and its clone, device B."""

    def __init__(self, test, root: Path, kinds: tuple):
        self.test = test
        self.root = root
        self.kinds = kinds
        self.remote = root / "remote.git"
        run_git(None, "init", "--bare", "--quiet", str(self.remote))
        run_git(self.remote, "symbolic-ref", "HEAD", "refs/heads/main")
        self.a = self.first_device("a", kinds[0])
        initialized = self.a.call("store.initialize", device_id="device-a")
        self.a.call("store.mutate", mutation=self.a.mutation(
            "enable-a", {"type": "ConfigWrite", "content": self.a.config_bytes().hex()},
            expected_base=initialized["commit_id"],
        ))
        self.published = self.a.sync("publish_initial", confirmed=True)
        self.b = self.clone_device("b", kinds[1])
        self.b.call("store.initialize", device_id="device-b")

    def first_device(self, name: str, kind: str, remote: Path = None) -> Device:
        repo = self.root / f"device-{name}"
        repo.mkdir()
        run_git(repo, "init", "--initial-branch=main", "--quiet")
        (repo / "source.txt").write_text(f"source {name}\n")
        commit_source(repo, "source root")
        run_git(repo, "remote", "add", "origin", str(remote or self.remote))
        run_git(repo, "push", "-q", "-u", "origin", "main")
        return Device(self, name, repo, kind)

    def clone_device(self, name: str, kind: str) -> Device:
        repo = self.root / f"device-{name}"
        run_git(None, "clone", "-q", str(self.remote), str(repo))
        run_git(repo, "fetch", "-q", "--no-tags", "origin", f"{ARTIFACT_REF}:{ARTIFACT_REF}")
        return Device(self, name, repo, kind)

    def fresh_device(self, name: str, kind: str) -> Device:
        repo = self.root / f"device-{name}"
        repo.mkdir()
        run_git(repo, "init", "--initial-branch=main", "--quiet")
        (repo / "source.txt").write_text("fresh source\n")
        commit_source(repo, "fresh source")
        run_git(repo, "remote", "add", "origin", str(self.remote))
        return Device(self, name, repo, kind)


# -- scenarios: each takes a fixture and returns the answers to compare -------


def scenario_local_only(fx: Fixture) -> list:
    repo = fx.root / "local-only"
    repo.mkdir()
    run_git(repo, "init", "--initial-branch=main", "--quiet")
    (repo / "source.txt").write_text("source\n")
    commit_source(repo, "source")
    device = Device(fx, "local", repo, fx.kinds[0])
    device.target.call("store.open", repo=str(repo), project_id="local-project",
                       state_root=str(fx.root / "local-state"), enabled=True)
    head = device.call("store.initialize", device_id="local-device")["commit_id"]
    answers = [
        device.outcome("sync.sync", mode="local_only"),
        device.outcome("sync.status", mode="local_only"),
        device.outcome("sync.status", mode="paused"),
        run_git(repo, "remote"),
        device.outcome("sync.new", mode="enabled"),
        device.outcome("sync.new", mode="local_only", remote_name="origin"),
        device.outcome("sync.new", mode="enabled", remote_name="bad name"),
        device.outcome("sync.sync", mode="enabled", remote_name="origin"),
    ]
    config = bytes.fromhex(device.files()[".orchestrator/config.toml"]).decode()
    config = re_sub_line(config, "remote_sync", 'remote_sync = "enabled"')
    config = re_sub_line(config, "remote_name", 'remote_name = "missing"')
    device.call("store.mutate", mutation={
        "event_id": "select-missing", "actor_type": "user", "device_id": "local-device",
        "operations": [{"type": "ConfigWrite", "content": config.encode().hex()}],
        "expected_base": head,
    })
    answers.append(device.outcome("sync.sync", mode="enabled", remote_name="missing"))
    answers.append(device.outcome("sync.publish_initial", mode="enabled", remote_name="other"))
    return answers


def scenario_missing_remote_ref(fx: Fixture) -> list:
    other = fx.root / "empty.git"
    run_git(None, "init", "--bare", "--quiet", str(other))
    device = fx.first_device("missing", fx.kinds[0], remote=other)
    head = device.call("store.initialize", device_id="missing-device")["commit_id"]
    device.call("store.mutate", mutation=device.mutation(
        "enable-missing", {"type": "ConfigWrite", "content": device.config_bytes().hex()},
        expected_base=head,
    ))
    answers = [
        fx.published,
        device.sync("publish_initial", confirmed=False),
        run_git(other, "show-ref", "--verify", ARTIFACT_REF, allow=(0, 1, 128)),
        device.sync("status"),
        device.sync("publish_initial", confirmed=True),
        run_git(other, "rev-parse", ARTIFACT_REF),
        device.sync("publish_initial", confirmed=True),
        device.state_files(),
    ]
    return answers


def scenario_prepared_publication(fx: Fixture) -> list:
    base = fx.a.head()
    content = ticket_bytes("RR-prepared", "Prepared", "artifact-RR-prepared")
    prepared = fx.a.call("store.prepare_mutation", mutation=fx.a.mutation(
        "prepared-ticket",
        {"type": "TicketWrite", "ticket_id": "RR-prepared", "artifact_id": "artifact-RR-prepared",
         "markdown": content.hex()},
        expected_base=base,
    ))
    blob = run_git(fx.a.repo, "rev-parse", f"{prepared['commit_id']}:.orchestrator/RR-prepared.md")
    proof = {"source_commit": prepared["commit_id"], "path": ".orchestrator/RR-prepared.md",
             "blob_id": blob, "sha256": hashlib.sha256(content).hexdigest()}
    digest = fx.a.fetch_digest()
    push_digest = hashlib.sha256(
        run_git(fx.a.repo, "remote", "get-url", "--push", "origin").encode()).hexdigest()
    answers = [
        fx.a.sync("publish_prepared", candidate_head=prepared["commit_id"],
                  expected_remote_head=base, proofs=[dict(proof, sha256="0" * 64)]),
        fx.a.head() == base,
        run_git(fx.remote, "rev-parse", ARTIFACT_REF),
        fx.a.sync("publish_prepared", candidate_head=prepared["commit_id"],
                  expected_remote_head=base, proofs=[proof],
                  expected_remote_url_sha256=digest, expected_push_url_sha256=push_digest),
        fx.a.head() == base,
        fx.a.sync("publish_prepared", candidate_head=prepared["commit_id"],
                  expected_remote_head=base, proofs=[dict(proof, blob_id="z")]),
        fx.a.sync("publish_prepared", candidate_head=prepared["commit_id"],
                  expected_remote_head="0" * 40, proofs=[proof]),
        fx.a.sync("publish_prepared", candidate_head=base, expected_remote_head=base, proofs=[]),
        fx.a.sync("publish_prepared", candidate_head=prepared["commit_id"],
                  expected_remote_head=base, proofs=[], expected_push_url_sha256="1" * 64),
        fx.a.sync("publish_prepared", candidate_head=prepared["commit_id"],
                  expected_remote_head=base, proofs=[], mode="paused", remote_name="origin"),
        fx.a.sync("sync_confirmed", expected_remote_url_sha256=digest,
                  expected_push_url_sha256=push_digest),
        fx.a.sync("sync_confirmed", expected_remote_url_sha256="2" * 64,
                  expected_push_url_sha256=push_digest),
        fx.a.state_files(),
    ]
    return answers


def scenario_historical_fetch(fx: Fixture) -> list:
    head = fx.a.write_ticket("history-ticket", "RR-history", "Historical")
    answers = [fx.a.sync()]
    tree = run_git(fx.a.repo, "rev-parse", f"{head}^{{tree}}")
    orphan = run_git(fx.a.repo, "-c", "user.name=Relay Sync Tests",
                     "-c", "user.email=relay-sync@example.invalid",
                     "commit-tree", tree, "-m", "unrelated matching tree")
    run_git(fx.a.repo, "push", "-q", "origin", f"{orphan}:refs/heads/unrelated-history")
    digest = fx.a.fetch_digest()
    answers += [
        fx.a.sync("fetch_historical_object", commit_id=orphan, expected_remote_url_sha256=digest),
        fx.a.sync("fetch_historical_object", commit_id=head, expected_remote_url_sha256=digest),
        fx.b.sync("fetch_historical_object", commit_id=head, expected_remote_url_sha256=digest),
        fx.a.sync("fetch_historical_object", commit_id="nothex", expected_remote_url_sha256=digest),
        fx.a.sync("fetch_historical_object", commit_id=head, expected_remote_url_sha256="bad"),
        fx.a.sync("fetch_historical_object", commit_id="1" * 40, expected_remote_url_sha256=digest),
    ]
    return answers


def scenario_fresh_recovery(fx: Fixture) -> list:
    head = fx.a.write_ticket("recovery-ticket", "RR-recovery", "Recovered")
    answers = [fx.a.sync()]
    fresh = fx.fresh_device("fresh", fx.kinds[1])
    answers.append(fresh.sync("recover_exact_ref", expected_remote_url_sha256=fresh.fetch_digest(),
                              validate=True, reject_head="no thanks"))
    answers.append(fresh.head())
    answers.append(fresh.sync("recover_exact_ref", expected_remote_url_sha256=fresh.fetch_digest(),
                              validate=True))
    answers.append(head in fresh.head())
    answers.append(".orchestrator/RR-recovery.md" in fresh.files())
    answers.append(run_git(fresh.repo, "for-each-ref", "--format=%(refname)").splitlines())
    answers.append(fresh.sync("recover_exact_ref", expected_remote_url_sha256=fresh.fetch_digest()))
    answers.append(fresh.state_files())

    crash = fx.fresh_device("fresh-crash", fx.kinds[0])
    answers.append(crash.sync("recover_exact_ref", expected_remote_url_sha256=crash.fetch_digest(),
                              fail_stage="after_recovery_ref_update"))
    answers.append(crash.head() == head)
    answers.append((crash.repo / ".orchestrator").exists())
    crash.switch(fx.kinds[1])
    answers.append(crash.sync("recover_exact_ref", expected_remote_url_sha256=crash.fetch_digest()))
    answers.append((crash.repo / ".orchestrator" / "RR-recovery.md").is_file())

    occupied = fx.fresh_device("occupied", fx.kinds[0])
    (occupied.repo / ".orchestrator").mkdir()
    answers.append(occupied.sync("recover_exact_ref",
                                 expected_remote_url_sha256=occupied.fetch_digest()))
    answers.append(occupied.sync("recover_exact_ref", expected_remote_url_sha256=fresh.fetch_digest(),
                                 mode="paused"))
    return answers


def scenario_manual_materialization(fx: Fixture) -> list:
    fx.a.write_ticket("manual-base", "RR-manual", "Shared before edit")
    answers = [fx.a.sync(), fx.b.sync()]
    local_head = fx.b.head()
    ticket_path = fx.b.repo / ".orchestrator/RR-manual.md"
    manual = ticket_path.read_bytes().replace(b"Shared before edit", b"Manual materialization edit")
    ticket_path.write_bytes(manual)
    fx.a.write_ticket("remote-ahead", "RR-remote", "Remote ahead")
    answers.append(fx.a.sync())
    answers.append(fx.b.sync("recover_exact_ref", expected_remote_url_sha256=fx.b.fetch_digest()))
    answers.append(fx.b.head() == local_head)
    answers.append(ticket_path.read_bytes() == manual)
    answers.append(fx.b.sync())
    return answers


def scenario_rebase_offline_events(fx: Fixture) -> list:
    fx.a.write_ticket("base-ticket", "RR-1", "Base")
    answers = [fx.a.sync(), fx.b.sync()]
    fx.a.write_ticket("offline-a", "RR-2", "Device A")
    fx.b.write_ticket("offline-b", "RR-3", "Device B")
    answers += [fx.a.sync(), fx.b.sync(), sorted(fx.b.files()), fx.b.state_files(),
                fx.a.sync(), fx.a.head() == fx.b.head(), fx.a.state_files()]
    return answers


def scenario_same_ticket_conflict(fx: Fixture) -> list:
    fx.a.write_ticket("shared-ticket", "RR-4", "Shared")
    answers = [fx.a.sync(), fx.b.sync()]
    fx.a.write_ticket("edit-a", "RR-4", "From A", artifact_id="artifact-RR-4")
    local_event = fx.b.mutation("edit-b", {
        "type": "TicketWrite", "ticket_id": "RR-4", "artifact_id": "artifact-RR-4",
        "markdown": ticket_bytes("RR-4", "From B", "artifact-RR-4").hex(),
    }, expected_base=fx.b.head())
    fx.b.call("store.mutate", mutation=local_event)
    answers.append(fx.a.sync())
    conflict = fx.b.sync()
    answers.append(conflict)
    report = conflict["ok"]["conflict_report"]
    path = report["conflicts"][0]["path"]
    merged = ticket_bytes("RR-4", "Reviewed merge", "artifact-RR-4")
    resolve = {"report": report, "resolution_event_id": "resolve-RR-4", "device_id": "device-b",
               "provider": "claude"}
    answers += [
        fx.b.sync("resolve_conflict", decisions=[], **resolve),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "local"},
                                                 {"path": "extra", "keyword": "local"}], **resolve),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "local"}],
                  **dict(resolve, provider="other")),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "local"}],
                  **dict(resolve, report=dict(report, project_id="elsewhere"))),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "weird"}], **resolve),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "local"}],
                  **dict(resolve, actor_type="robot")),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "local"}],
                  **dict(resolve, report=dict(report, local_head="0" * 40))),
        fx.b.sync("resolve_conflict", decisions=[{"path": path, "keyword": "local"}],
                  **dict(resolve, report=dict(report, conflicts=[
                      dict(report["conflicts"][0], kind="unrelated_history")]))),
    ]
    resolved = fx.b.sync("resolve_conflict", decisions=[{"path": path, "content": merged.hex()}],
                         **resolve)
    answers.append(resolved)
    answers.append(bytes.fromhex(fx.b.files()[path]).decode())
    retry = fx.b.call("store.mutate", mutation=local_event)
    answers.append([retry["idempotent"], retry["commit_id"] == resolved["ok"]["local_head"]])
    answers.append(run_git(fx.b.repo, "show", "-s", "--format=%B", resolved["ok"]["local_head"]))
    answers += [fx.a.sync(), fx.a.head() == fx.b.head(), fx.b.state_files()]
    return answers


def scenario_conflict_taxonomy(fx: Fixture) -> list:
    answers = []
    # display_id_collision
    fx.a.write_ticket("display-a", "RR-9", "A", artifact_id="artifact-display-a")
    fx.b.write_ticket("display-b", "RR-9", "B", artifact_id="artifact-display-b")
    answers += [fx.a.sync(), fx.b.sync()]
    return answers


def scenario_conflict_config(fx: Fixture) -> list:
    for device, event, next_id in ((fx.a, "config-a", 20), (fx.b, "config-b", 30)):
        content = device.config_bytes().decode().replace("next_id = 1", f"next_id = {next_id}")
        device.write_config(event, content.encode())
    return [fx.a.sync(), fx.b.sync()]


def scenario_conflict_attachment(fx: Fixture) -> list:
    for device, event, marker in ((fx.a, "attachment-a", b"A"), (fx.b, "attachment-b", b"B")):
        device.mutate(event, {"type": "AttachmentWrite", "ticket_id": "RR-10", "filename": "same.png",
                              "mime_type": "image/png",
                              "content": (b"\x89PNG\r\n\x1a\n" + marker).hex()})
    first = [fx.a.sync(), fx.b.sync()]
    report = first[1]["ok"]["conflict_report"]
    resolved = fx.b.sync("resolve_conflict", report=report,
                         decisions=[{"path": item["path"], "keyword": "remote"}
                                    for item in report["conflicts"]],
                         resolution_event_id="resolve-attachment", device_id="device-b")
    return first + [resolved, sorted(fx.b.files())]


def scenario_conflict_delete_edit(fx: Fixture) -> list:
    fx.a.write_ticket("delete-base", "RR-11", "Base")
    answers = [fx.a.sync(), fx.b.sync()]
    fx.a.mutate("delete-a", {"type": "TicketDelete", "ticket_id": "RR-11"})
    fx.b.write_ticket("edit-after-delete", "RR-11", "Edited", artifact_id="artifact-RR-11")
    answers += [fx.a.sync(), fx.b.sync()]
    report = answers[-1]["ok"]["conflict_report"]
    answers.append(fx.b.sync("resolve_conflict", report=report,
                             decisions=[{"path": item["path"], "keyword": "delete"}
                                        for item in report["conflicts"]],
                             resolution_event_id="resolve-delete", device_id="device-b",
                             actor_type="pm", provider="codex"))
    answers.append(sorted(fx.b.files()))
    return answers


def scenario_push_race(fx: Fixture) -> list:
    fx.b.write_ticket("race-b", "RR-7", "B")
    # Device A's next commit, pushed by the stage hook while B is publishing.
    race_head = fx.a.write_ticket("race-a", "RR-8", "A")
    hook = {"stage": "before_push", "argv": [
        "git", "-C", str(fx.a.repo), "push", "-q", "origin", f"{race_head}:{ARTIFACT_REF}",
    ]}
    result = fx.b.sync(max_attempts=3, stage_command=hook)
    log = run_git(fx.b.repo, "log", "--format=%B%x00", ARTIFACT_REF)
    return [result, log.count("Relay-Event-ID: race-b"), sorted(fx.b.files()), fx.b.state_files()]


def scenario_history_verification(fx: Fixture) -> list:
    for index in range(4):
        fx.a.write_ticket(f"history-{index}", "RR-1", f"Title {index}")
    answers = [fx.a.sync(), fx.a.state_files(), fx.b.sync(), fx.b.state_files()]
    path = Path(fx.a.call("sync.remote_history_verification_path", mode="enabled",
                          remote_name="origin"))
    path.write_text(json.dumps({"version": 1, "project_id": PROJECT, "commit_id": "0" * 40}))
    fx.a.write_ticket("history-next", "RR-2", "Next")
    answers += [fx.a.sync(), fx.a.state_files()]
    path.write_text("not json")
    answers += [fx.a.sync("status"), fx.a.state_files()]
    return answers


def scenario_foreign_and_unowned(fx: Fixture) -> list:
    private_repo = fx.root / "private-source"
    run_git(None, "clone", "-q", str(fx.remote), str(private_repo))
    (private_repo / "private.txt").write_text("ordinary source history\n")
    commit_source(private_repo, "private source")
    private_oid = run_git(private_repo, "rev-parse", "HEAD")
    run_git(private_repo, "push", "-q", "origin", "HEAD:refs/heads/private-source")
    answers = [fx.b.sync("status"),
               run_git(fx.b.repo, "cat-file", "-e", private_oid, allow=(0, 1, 128)) == ""]

    foreign_remote = fx.root / "foreign.git"
    run_git(None, "init", "--bare", "--quiet", str(foreign_remote))
    foreign_repo = fx.root / "foreign-work"
    run_git(None, "clone", "-q", str(fx.remote), str(foreign_repo))
    (foreign_repo / "foreign-source.txt").write_text("must not import\n")
    commit_source(foreign_repo, "foreign source")
    foreign_oid = run_git(foreign_repo, "rev-parse", "HEAD")
    run_git(foreign_repo, "push", "-q", str(foreign_remote), f"{foreign_oid}:{ARTIFACT_REF}")
    run_git(fx.b.repo, "remote", "add", "foreign", str(foreign_remote))
    fx.b.write_config("select-foreign", fx.b.config_bytes(remote_name="foreign"))
    answers.append(fx.b.sync(remote_name="foreign"))
    answers.append(subprocess.run(["git", "-C", str(fx.b.repo), "cat-file", "-e", foreign_oid],
                                  capture_output=True).returncode)
    answers.append(fx.b.sync(remote_name="origin"))

    # A commit without Relay trailers fails closed.
    head = fx.a.head()
    tree = run_git(fx.a.repo, "rev-parse", f"{head}^{{tree}}")
    unowned = run_git(fx.a.repo, "-c", "user.name=Manual", "-c", "user.email=manual@example.invalid",
                      "commit-tree", tree, "-p", head, "-m", "manual artifact commit")
    run_git(fx.a.repo, "update-ref", ARTIFACT_REF, unowned, head)
    answers.append(fx.a.sync())
    answers.append(fx.a.state_files())
    return answers


def scenario_classification(fx: Fixture) -> list:
    messages = [
        "Could not resolve host github.com", "Authentication failed",
        "protected branch hook declined", "rejected non-fast-forward",
        "couldn't find remote ref", "Permission denied (publickey)", "stale info", "nothing known",
        "FATAL: Connection timed out",
    ]
    return [fx.a.call("sync.classify_git_failure", message=message, operation=operation)
            for message in messages for operation in ("push", "fetch")]


SCENARIOS = {
    "local_only": scenario_local_only,
    "missing_remote_ref": scenario_missing_remote_ref,
    "prepared_publication": scenario_prepared_publication,
    "historical_fetch": scenario_historical_fetch,
    "fresh_recovery": scenario_fresh_recovery,
    "manual_materialization": scenario_manual_materialization,
    "rebase_offline_events": scenario_rebase_offline_events,
    "same_ticket_conflict": scenario_same_ticket_conflict,
    "conflict_display": scenario_conflict_taxonomy,
    "conflict_config": scenario_conflict_config,
    "conflict_attachment": scenario_conflict_attachment,
    "conflict_delete_edit": scenario_conflict_delete_edit,
    "push_race": scenario_push_race,
    "history_verification": scenario_history_verification,
    "foreign_and_unowned": scenario_foreign_and_unowned,
    "classification": scenario_classification,
}


def scrub(value, root: Path):
    if isinstance(value, str):
        return value.replace(str(root), "<ROOT>").replace(os.path.realpath(str(root)), "<ROOT>")
    if isinstance(value, list):
        return [scrub(item, root) for item in value]
    if isinstance(value, dict):
        return {key: scrub(item, root) for key, item in value.items()}
    return value


@unittest.skipUnless(driver_command(), "relay-artifacts driver is not built; run cargo test in rust/")
class SyncParityTest(unittest.TestCase):
    maxDiff = None

    def run_scenario(self, name: str, kinds: tuple) -> list:
        temporary = tempfile.TemporaryDirectory(prefix="relay-sync-parity-")
        self.addCleanup(temporary.cleanup)
        # Both runs live at the same relative layout; the root is scrubbed.
        root = Path(temporary.name) / "fixture"
        root.mkdir()
        fixture = Fixture(self, root, kinds)
        return scrub(SCENARIOS[name](fixture), root)

    def test_every_scenario_answers_alike(self):
        for name in SCENARIOS:
            with self.subTest(scenario=name):
                python = self.run_scenario(name, ("python", "python"))
                rust = self.run_scenario(name, ("rust", "rust"))
                self.assertEqual(rust, python)

    def test_expected_outcomes(self):
        """The Rust engine reaches the outcomes the Python tests assert."""
        rebase = self.run_scenario("rebase_offline_events", ("rust", "rust"))
        self.assertEqual(rebase[3]["ok"]["state"], "clean")
        self.assertEqual(rebase[3]["ok"]["observed_state"], "conflict")
        self.assertIn(".orchestrator/RR-2.md", rebase[4])
        self.assertIn(".orchestrator/RR-3.md", rebase[4])
        race = self.run_scenario("push_race", ("rust", "rust"))
        self.assertEqual((race[0]["ok"]["state"], race[0]["ok"]["attempts"]), ("clean", 2))
        self.assertEqual(race[1], 1)
        conflict = self.run_scenario("same_ticket_conflict", ("rust", "rust"))
        self.assertEqual(conflict[3]["ok"]["state"], "conflict")
        self.assertEqual(conflict[3]["ok"]["conflict_report"]["conflicts"][0]["kind"], "same_ticket")
        self.assertEqual(conflict[12]["ok"]["state"], "clean")
        self.assertIn("Relay-Resolved-Event: edit-b", conflict[15])
        for name, kind in (("conflict_display", "display_id_collision"),
                           ("conflict_config", "config_collision"),
                           ("conflict_attachment", "attachment_collision"),
                           ("conflict_delete_edit", "delete_edit")):
            answers = self.run_scenario(name, ("rust", "rust"))
            conflicted = next(item for item in answers
                              if isinstance(item, dict) and item.get("ok", {}).get("state") == "conflict")
            self.assertIn(kind, {item["kind"] for item in conflicted["ok"]["conflict_report"]["conflicts"]})
        foreign = self.run_scenario("foreign_and_unowned", ("rust", "rust"))
        self.assertEqual(foreign[2]["ok"]["state"], "foreign_ref")
        self.assertNotEqual(foreign[3], 0)
        self.assertEqual(foreign[5]["ok"]["state"], "local_ahead_fail_closed")

    def test_python_and_rust_devices_share_one_remote(self):
        for kinds in (("python", "rust"), ("rust", "python")):
            with self.subTest(devices=kinds):
                for name in ("rebase_offline_events", "same_ticket_conflict", "push_race",
                             "conflict_delete_edit", "fresh_recovery"):
                    mixed = self.run_scenario(name, kinds)
                    alike = self.run_scenario(name, ("python", "python"))
                    self.assertEqual(mixed, alike, name)

    def test_python_and_rust_take_turns_on_one_data_root(self):
        temporary = tempfile.TemporaryDirectory(prefix="relay-sync-turns-")
        self.addCleanup(temporary.cleanup)
        answers = {}
        for order in (("python", "rust"), ("rust", "python")):
            root = Path(temporary.name) / "-".join(order)
            root.mkdir()
            fx = Fixture(self, root, (order[0], order[0]))
            steps = []
            for turn in range(4):
                kind = order[turn % 2]
                fx.a.switch(kind)
                fx.b.switch(kind)
                fx.a.write_ticket(f"turn-a-{turn}", f"RR-{20 + turn}", f"A {turn}")
                fx.b.write_ticket(f"turn-b-{turn}", f"RR-{40 + turn}", f"B {turn}")
                steps += [fx.a.sync(), fx.b.sync(), fx.a.sync(), fx.a.state_files(),
                          fx.b.state_files()]
            steps.append(sorted(fx.b.files()))
            answers[order] = scrub(steps, root)
        self.assertEqual(answers[("python", "rust")], answers[("rust", "python")])
        last = answers[("python", "rust")]
        self.assertEqual(last[-2]["sync-state.json"]["state"], "clean")


if __name__ == "__main__":
    unittest.main()
