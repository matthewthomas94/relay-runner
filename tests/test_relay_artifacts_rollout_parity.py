"""RR-495: services/artifact_rollout.py against relay_artifacts::rollout.

Each scenario runs the same calls through the Python store in-process and the
Rust store through the relay-artifacts test driver, on separate state roots
with one pinned clock, and compares every result, every refusal (class,
message, code and recovery) and the policy bytes left on disk. Alternation
runs one state root with the two implementations taking turns, and must
leave the bytes an all-Python run leaves. The CLI cases compare
`relay-artifacts rollout ...` with services/artifact_rollout_cli.py.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from relay_artifacts_support import REPO, RustArtifacts, driver_command  # noqa: E402

from services import artifact_rollout  # noqa: E402
from services.artifact_rollout import (  # noqa: E402
    LEGACY_REQUIRED_EVIDENCE,
    NEW_PROJECT_REQUIRED_EVIDENCE,
    ArtifactRolloutStore,
    RolloutEvidence,
)

NOW = "2026-08-05T00:00:00Z"
LATER = "2026-08-05T01:02:03.000456Z"
CLI_BINARY = REPO / "rust" / "target" / "debug" / "relay-artifacts"
PYTHON_CLI = REPO / "services" / "artifact_rollout_cli.py"


def jsonable(value):
    return json.loads(json.dumps(value))


class PythonRollout:
    name = "python"

    def call(self, op: str, **a):
        function = op.split(".", 1)[1]
        try:
            return {"ok": True, "result": jsonable(self._call(function, a))}
        except Exception as error:  # noqa: BLE001 - compared with the Rust class
            return {
                "ok": False,
                "error": type(error).__name__,
                "message": str(error),
                "code": getattr(error, "code", None),
                "recovery": getattr(error, "recovery", None),
            }

    def _call(self, function: str, a: dict):
        if function == "privacy_safe_report_digest":
            return artifact_rollout.privacy_safe_report_digest(a["report"])
        if function == "dumps_indent_sorted":
            return json.dumps(a["value"], sort_keys=True, indent=2)
        now = a.get("now")
        clock = (lambda: datetime.fromisoformat(now.replace("Z", "+00:00"))) if now else None
        store = ArtifactRolloutStore(a["state_root"], now=clock)
        if function == "load":
            return store.load()
        if function == "diagnostics":
            return store.diagnostics()
        if function == "record_evidence":
            raw = a["evidence"]
            return store.record_evidence(RolloutEvidence(
                evidence_id=raw.get("evidence_id"),
                kind=raw.get("kind"),
                outcome=raw.get("outcome"),
                recorded_at=raw.get("recorded_at"),
                report_sha256=raw.get("report_sha256"),
                build_version=raw.get("build_version"),
                build_number=raw.get("build_number"),
                bundle_sha256=raw.get("bundle_sha256"),
                signer_team_id=raw.get("signer_team_id"),
                providers=tuple(raw.get("providers") or ()),
                scenario_ids=tuple(raw.get("scenario_ids") or ()),
                rejection_code=raw.get("rejection_code"),
            ))
        if function == "set_project_opt_in":
            return dataclasses.asdict(store.set_project_opt_in(
                a["project_id"], enabled=bool(a.get("enabled")), confirmed=bool(a.get("confirmed")),
                writers_drained=bool(a.get("writers_drained")), sync_frozen=bool(a.get("sync_frozen")),
            ))
        if function == "promote_cohort":
            return store.promote_cohort(a["cohort"], confirmed=bool(a.get("confirmed")))
        if function == "pause_cohort":
            return store.pause_cohort(
                a["cohort"], writers_drained=bool(a.get("writers_drained")),
                sync_frozen=bool(a.get("sync_frozen")), reason_code=a["reason_code"],
            )
        if function == "resume_cohort":
            return store.resume_cohort(a["cohort"], confirmed=bool(a.get("confirmed")))
        if function == "decision":
            return dataclasses.asdict(store.decision(
                a["project_id"], project_kind=a["project_kind"],
                configured_opt_in=bool(a.get("configured_opt_in")),
            ))
        raise TypeError("unknown operation")

    def close(self):
        pass


class RustRollout(RustArtifacts):
    def call(self, op: str, **arguments):
        request = json.dumps({"op": op, **arguments})
        with self._lock:
            self._process.stdin.write(request + "\n")
            self._process.stdin.flush()
            line = self._process.stdout.readline()
        if not line:
            raise RuntimeError(f"artifacts driver exited: {self._process.stderr.read()}")
        answer = json.loads(line)
        if not answer["ok"]:
            answer.setdefault("code", None)
            answer.setdefault("recovery", None)
        return answer


def evidence(kind: str, *, outcome: str, suffix: str = "one", **overrides) -> dict:
    installed = kind in {"signed_installed_workspace", "installed_provider_parity"}
    value = {
        "evidence_id": f"{kind}:{suffix}",
        "kind": kind,
        "outcome": outcome,
        "recorded_at": "2026-08-05T00:00:00Z",
        "report_sha256": hashlib.sha256(f"{kind}:{suffix}:{outcome}".encode()).hexdigest(),
        "build_version": "0.4.99" if installed else None,
        "build_number": "99" if installed else None,
        "bundle_sha256": hashlib.sha256(b"bundle").hexdigest() if installed else None,
        "signer_team_id": "TEAM123" if installed else None,
        "providers": ["codex", "claude"] if kind == "installed_provider_parity" else [],
        "scenario_ids": ["mounted_workspace"] if installed else [],
        "rejection_code": "installed_gate_failed" if outcome == "rejected" else None,
    }
    value.update(overrides)
    return value


def opt_in(project, enabled=True, **flags):
    return ("set_project_opt_in", {"project_id": project, "enabled": enabled, "confirmed": True, **flags})


# Each scenario is a list of steps: (op, arguments) or ("write", file, text).
SCENARIOS = {
    "default_off_and_reversible_opt_in": [
        ("decision", {"project_id": "project-a", "project_kind": "existing"}),
        ("decision", {"project_id": "project-b", "project_kind": "new"}),
        ("decision", {"project_id": "project-c", "project_kind": "legacy"}),
        ("set_project_opt_in", {"project_id": "project-a", "enabled": True, "confirmed": False}),
        opt_in("project-a"),
        ("decision", {"project_id": "project-other", "project_kind": "existing"}),
        opt_in("project-a", enabled=False),
        opt_in("project-a", enabled=False, writers_drained=True, sync_frozen=True),
        ("diagnostics", {}),
        ("load", {}),
    ],
    "configured_opt_in_and_opt_out": [
        ("decision", {"project_id": "configured", "project_kind": "existing", "configured_opt_in": True}),
        ("decision", {"project_id": "configured-new", "project_kind": "new", "configured_opt_in": True}),
        ("decision", {"project_id": "x", "project_kind": "other"}),
        ("decision", {"project_id": "bad id!", "project_kind": "existing"}),
        opt_in("configured", enabled=False, writers_drained=True, sync_frozen=True),
        ("decision", {"project_id": "configured", "project_kind": "existing", "configured_opt_in": True}),
    ],
    "staged_cohorts": [
        opt_in("pilot"),
        *[("record_evidence", {"evidence": evidence(kind, outcome="accepted")})
          for kind in sorted(NEW_PROJECT_REQUIRED_EVIDENCE)],
        ("decision", {"project_id": "new-one", "project_kind": "new"}),
        ("promote_cohort", {"cohort": "new_project_default", "confirmed": False}),
        ("promote_cohort", {"cohort": "project_opt_in", "confirmed": True}),
        ("promote_cohort", {"cohort": "nope", "confirmed": True}),
        ("promote_cohort", {"cohort": "new_project_default", "confirmed": True}),
        ("decision", {"project_id": "new-one", "project_kind": "new"}),
        ("promote_cohort", {"cohort": "legacy_migration_offer", "confirmed": True}),
        *[("record_evidence", {"evidence": evidence(kind, outcome="accepted")})
          for kind in sorted(LEGACY_REQUIRED_EVIDENCE - NEW_PROJECT_REQUIRED_EVIDENCE)],
        ("promote_cohort", {"cohort": "legacy_migration_offer", "confirmed": True}),
        ("decision", {"project_id": "legacy-one", "project_kind": "legacy"}),
        ("resume_cohort", {"cohort": "legacy_migration_offer", "confirmed": True}),
        ("diagnostics", {}),
    ],
    "rejected_latest_evidence": [
        *[("record_evidence", {"evidence": evidence(kind, outcome="accepted", suffix="first")})
          for kind in sorted(NEW_PROJECT_REQUIRED_EVIDENCE)],
        ("record_evidence", {"evidence": evidence("signed_installed_workspace", outcome="rejected",
                                                  suffix="rejected")}),
        ("promote_cohort", {"cohort": "new_project_default", "confirmed": True}),
        ("resume_cohort", {"cohort": "new_project_default", "confirmed": True}),
        ("record_evidence", {"evidence": evidence("signed_installed_workspace", outcome="accepted",
                                                  suffix="reviewed")}),
        ("promote_cohort", {"cohort": "new_project_default", "confirmed": True}),
        # The same evidence again is idempotent; different content collides.
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted", suffix="first")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted", suffix="first",
                                                  report_sha256="0" * 64)}),
    ],
    "kill_switch": [
        opt_in("pilot"),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted")}),
        ("pause_cohort", {"cohort": "project_opt_in", "writers_drained": False, "sync_frozen": True,
                          "reason_code": "cas_failure"}),
        ("pause_cohort", {"cohort": "project_opt_in", "writers_drained": True, "sync_frozen": True,
                          "reason_code": "bad reason"}),
        ("pause_cohort", {"cohort": "project_opt_in", "writers_drained": True, "sync_frozen": True,
                          "reason_code": "cas_failure"}),
        ("decision", {"project_id": "pilot", "project_kind": "existing"}),
        ("decision", {"project_id": "configured", "project_kind": "existing", "configured_opt_in": True}),
        opt_in("pilot-2"),
        ("resume_cohort", {"cohort": "project_opt_in", "confirmed": False}),
        ("resume_cohort", {"cohort": "project_opt_in", "confirmed": True}),
        ("resume_cohort", {"cohort": "new_project_default", "confirmed": True}),
        ("decision", {"project_id": "pilot", "project_kind": "existing"}),
    ],
    "corrupt_primary_uses_backup": [
        opt_in("first"),
        opt_in("second"),
        ("write", "primary", "{not-json"),
        ("load", {}),
        ("decision", {"project_id": "first", "project_kind": "existing"}),
        opt_in("repair"),
        ("load", {}),
        ("decision", {"project_id": "repair", "project_kind": "existing"}),
        ("write", "primary", "[]"),
        ("write", "backup", "{}"),
        ("load", {}),
        ("decision", {"project_id": "repair", "project_kind": "existing"}),
        ("write", "primary", "\xff"),
        ("load", {}),
    ],
    "evidence_validation": [
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted", evidence_id="")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted", evidence_id=7)}),
        ("record_evidence", {"evidence": evidence("nope", outcome="accepted")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="maybe")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  recorded_at="yesterday")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  recorded_at="2026-08-05T00:00:00")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted", recorded_at=5)}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  report_sha256="ABC")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  bundle_sha256="x")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  build_version="has space")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted", build_number=12)}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  providers=["codex", "gemini"])}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  providers="codex")}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  providers=[["codex"]])}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  scenario_ids=["Upper"])}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  scenario_ids=["s%d" % n for n in range(129)])}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  scenario_ids=[3])}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="rejected",
                                                  rejection_code=None)}),
        ("record_evidence", {"evidence": evidence("signed_installed_workspace", outcome="accepted",
                                                  signer_team_id=None)}),
        ("record_evidence", {"evidence": evidence("installed_provider_parity", outcome="accepted",
                                                  providers=["codex"])}),
        ("record_evidence", {"evidence": evidence("installed_provider_parity", outcome="accepted",
                                                  providers=["codex", "claude", "codex"])}),
        ("record_evidence", {"evidence": evidence("source_matrix", outcome="accepted",
                                                  scenario_ids=["b_two", "a_one", "b_two"],
                                                  providers=["claude", "codex"])}),
        ("diagnostics", {}),
    ],
}

# Documents written as the primary (with no backup) and then loaded.
INVALID_DOCUMENTS = [
    "null",
    "{}",
    '{"schema_version": 2}',
    "NaN",
]


def base_document() -> dict:
    stamp = "2026-08-05T00:00:00Z"
    cohort = lambda enabled: {  # noqa: E731
        "enabled": enabled, "paused": False, "writes_allowed": enabled, "sync_allowed": enabled,
        "pause_reason_code": None, "updated_at": stamp,
    }
    return {
        "schema_version": 1, "revision": 3, "last_event": "x", "updated_at": stamp,
        "cohorts": {"project_opt_in": cohort(True), "new_project_default": cohort(False),
                    "legacy_migration_offer": cohort(False)},
        "project_opt_ins": {"p": {"enabled": True, "updated_at": stamp}},
        "evidence": [evidence("source_matrix", outcome="accepted")],
    }


def variants() -> list:
    result = []

    def variant(change):
        document = base_document()
        change(document)
        result.append(json.dumps(document))

    variant(lambda d: d.update(revision=-1))
    variant(lambda d: d.update(revision=1.0))
    variant(lambda d: d.update(revision=True))
    variant(lambda d: d.update(schema_version=1.0))
    variant(lambda d: d.update(schema_version=True))
    variant(lambda d: d.update(extra=1))
    variant(lambda d: d["cohorts"].pop("legacy_migration_offer"))
    variant(lambda d: d["cohorts"]["project_opt_in"].update(paused=0))
    variant(lambda d: d["cohorts"]["project_opt_in"].pop("updated_at"))
    variant(lambda d: d.update(project_opt_ins=[]))
    variant(lambda d: d["project_opt_ins"].update({"bad id": {"enabled": True, "updated_at": "x"}}))
    variant(lambda d: d["project_opt_ins"].update({"q": {"enabled": 1, "updated_at": "x"}}))
    variant(lambda d: d.update(evidence={}))
    variant(lambda d: d["evidence"].append(dict(d["evidence"][0])))
    variant(lambda d: d["evidence"][0].update(raw_transcript="x"))
    variant(lambda d: d["evidence"][0].update(kind=["list"]))
    variant(lambda d: d["evidence"][0].update(providers={"codex": 1}))
    variant(lambda d: d["evidence"][0].update(providers=5))
    variant(lambda d: d["evidence"][0].update(scenario_ids="abc"))
    variant(lambda d: d.update(last_event=["anything"], updated_at=12))
    return result


DIGEST_REPORTS = [
    {"rows": [{"RAW_LOG": "x"}]},
    {"summary": "x" * 5000},
    {"summary": "é" * 2049},
    {"b": [1, 2.5, None, True], "a": {"nested": "ünïcode"}},
    {"blob": ["y" * 4000] * 70},
    [],
    {"Token": 1},
]


@unittest.skipUnless(driver_command(), "relay-artifacts driver is not built; run cargo test in rust/")
class RolloutParityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-rollout-parity-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.python = PythonRollout()
        self.rust = RustRollout(driver_command())
        self.addCleanup(self.rust.close)

    def state_root(self, name: str) -> Path:
        path = self.root / name
        path.mkdir()
        return path

    @staticmethod
    def files(state_root: Path) -> dict:
        rollout = state_root / "rollout"
        return {
            name: (rollout / name).read_bytes() if (rollout / name).exists() else None
            for name in ("artifact-rollout-v1.json", "artifact-rollout-v1.backup.json")
        }

    @staticmethod
    def write(state_root: Path, which: str, text: str) -> None:
        rollout = state_root / "rollout"
        rollout.mkdir(parents=True, exist_ok=True)
        name = "artifact-rollout-v1.json" if which == "primary" else "artifact-rollout-v1.backup.json"
        (rollout / name).write_bytes(text.encode("latin-1") if text == "\xff" else text.encode())

    def run_step(self, implementation, state_root: Path, step, now: str):
        if step[0] == "write":
            self.write(state_root, step[1], step[2])
            return None
        op, arguments = step
        return implementation.call("rollout." + op, state_root=str(state_root), now=now, **arguments)

    def test_scenarios_match(self):
        for name, steps in SCENARIOS.items():
            with self.subTest(scenario=name):
                roots = {"python": self.state_root(name + "-py"), "rust": self.state_root(name + "-rs")}
                for index, step in enumerate(steps):
                    now = NOW if index % 2 else LATER
                    answers = {
                        impl.name: self.run_step(impl, roots[impl.name], step, now)
                        for impl in (self.python, self.rust)
                    }
                    self.assertEqual(answers["rust"], answers["python"], "%s step %d: %r" % (name, index, step))
                    self.assertEqual(self.files(roots["rust"]), self.files(roots["python"]),
                                     "%s step %d files" % (name, index))

    def test_alternation_leaves_python_bytes(self):
        for name, steps in SCENARIOS.items():
            with self.subTest(scenario=name):
                shared = self.state_root(name + "-shared")
                reference = self.state_root(name + "-reference")
                for index, step in enumerate(steps):
                    now = NOW if index % 3 else LATER
                    turn = (self.rust, self.python)[index % 2]
                    shared_answer = self.run_step(turn, shared, step, now)
                    reference_answer = self.run_step(self.python, reference, step, now)
                    self.assertEqual(shared_answer, reference_answer, "%s step %d" % (name, index))
                    self.assertEqual(self.files(shared), self.files(reference), "%s step %d" % (name, index))

    def test_document_validation_matches(self):
        for index, text in enumerate(INVALID_DOCUMENTS + variants()):
            with self.subTest(document=text[:80]):
                for which in ("alone", "with-backup"):
                    roots = {}
                    for impl in (self.python, self.rust):
                        root = self.state_root("doc-%d-%s-%s" % (index, which, impl.name))
                        if which == "with-backup":
                            self.write(root, "backup", json.dumps(base_document()))
                        self.write(root, "primary", text)
                        roots[impl.name] = root
                    for step in (("load", {}), ("diagnostics", {}), opt_in("after")):
                        answers = {impl.name: self.run_step(impl, roots[impl.name], step, NOW)
                                   for impl in (self.python, self.rust)}
                        self.assertEqual(answers["rust"], answers["python"], step)
                        self.assertEqual(self.files(roots["rust"]), self.files(roots["python"]))

    def test_digest_and_json_forms_match(self):
        for report in DIGEST_REPORTS:
            with self.subTest(report=str(report)[:60]):
                self.assertEqual(
                    self.rust.call("rollout.privacy_safe_report_digest", report=report),
                    self.python.call("rollout.privacy_safe_report_digest", report=report),
                )
        for value in (base_document(), {"a": [], "b": {}, "c": [{}, [[]]], "é": " "}, [1, [2, []]], "x"):
            self.assertEqual(
                self.rust.call("rollout.dumps_indent_sorted", value=value),
                self.python.call("rollout.dumps_indent_sorted", value=value),
            )

    def test_lock_file_is_shared(self):
        root = self.state_root("lock")
        python_paths = ArtifactRolloutStore(root)
        rust_paths = self.rust.call("rollout.paths", state_root=str(root))["result"]
        self.assertEqual(rust_paths, {
            "path": str(python_paths.path), "backup_path": str(python_paths.backup_path),
            "lock_path": str(python_paths.lock_path),
        })
        # While Python holds the lock, a Rust write waits for it.
        import fcntl
        import threading
        python_paths.rollout_root.mkdir(parents=True)
        with python_paths.lock_path.open("a+b") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            done = threading.Event()
            thread = threading.Thread(target=lambda: (
                self.rust.call("rollout.set_project_opt_in", state_root=str(root), now=NOW,
                               project_id="locked", enabled=True, confirmed=True), done.set()))
            thread.start()
            self.assertFalse(done.wait(1.0))
            self.assertFalse(python_paths.path.exists())
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        thread.join(10)
        self.assertTrue(done.is_set())
        self.assertEqual(python_paths.load()["project_opt_ins"]["locked"]["enabled"], True)


def run_cli(command: list, state_root: Path, *arguments) -> tuple:
    done = subprocess.run(
        [*command, "--state-root", str(state_root), *arguments],
        capture_output=True, text=True, check=False,
        cwd=str(REPO / "services"), env={**os.environ, "PYTHONPATH": str(REPO / "services")},
    )
    output = json.loads(done.stdout) if done.returncode in (0, 2) and done.stdout.strip() else None
    return done.returncode, output


@unittest.skipUnless(os.access(CLI_BINARY, os.X_OK), "relay-artifacts binary is not built; run cargo build in rust/")
class RolloutCliParityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-rollout-cli-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.commands = {
            "python": [sys.executable, str(PYTHON_CLI)],
            "rust": [str(CLI_BINARY), "rollout"],
        }

    def evidence_file(self, name: str, value) -> str:
        path = self.root / name
        path.write_text(value if isinstance(value, str) else json.dumps(value))
        return str(path)

    def test_cli_commands_match(self):
        valid = self.evidence_file("valid.json", evidence("source_matrix", outcome="accepted"))
        extra = self.evidence_file("extra.json", {**evidence("source_matrix", outcome="accepted"), "x": 1})
        bad_id = self.evidence_file("bad.json", evidence("source_matrix", outcome="accepted", evidence_id="!"))
        broken = self.evidence_file("broken.json", "{")
        sequence = [
            ("status",),
            ("decision", "--project-id", "p-1", "--project-kind", "existing"),
            ("decision", "--project-id", "p-1", "--project-kind", "other"),
            ("decision", "--project-id", "p-1"),
            ("opt-in", "--project-id", "p-1"),
            ("opt-in", "--project-id", "p-1", "--confirm"),
            ("opt-in", "--project-id=p-2", "--conf"),
            ("opt-out", "--project-id", "p-1", "--confirm"),
            ("opt-out", "--project-id", "p-1", "--confirm", "--writers-drained", "--sync-frozen"),
            ("record-evidence", "--file", valid),
            ("record-evidence", "--file", valid),
            ("record-evidence", "--file", extra),
            ("record-evidence", "--file", bad_id),
            ("record-evidence", "--file", str(self.root / "missing.json")),
            ("promote", "--cohort", "new_project_default", "--confirm"),
            ("promote", "--cohort", "unknown", "--confirm"),
            ("pause", "--cohort", "project_opt_in", "--reason-code", "cas_failure"),
            ("pause", "--cohort", "project_opt_in", "--reason-code", "cas_failure",
             "--writers-drained", "--sync-frozen"),
            ("resume", "--cohort", "project_opt_in"),
            ("resume", "--cohort", "project_opt_in", "--confirm"),
            ("status", "--unknown"),
            ("bogus",),
            ("status",),
        ]
        roots = {name: self.root / ("state-" + name) for name in self.commands}
        for arguments in sequence:
            with self.subTest(arguments=arguments):
                answers = {name: run_cli(command, roots[name], *arguments)
                           for name, command in self.commands.items()}
                self.assertEqual(answers["rust"], answers["python"])
        # A JSON decode failure is caught by both, with Python's position details only there.
        answers = {name: run_cli(command, roots[name], "record-evidence", "--file", broken)
                   for name, command in self.commands.items()}
        self.assertEqual(answers["rust"][0], answers["python"][0])
        self.assertEqual(answers["rust"][1]["error_code"], answers["python"][1]["error_code"])

    def test_cli_alternation_on_one_state_root(self):
        shared = self.root / "shared"
        order = ["python", "rust"]
        steps = [
            ("opt-in", "--project-id", "alpha", "--confirm"),
            ("opt-in", "--project-id", "beta", "--confirm"),
            ("pause", "--cohort", "project_opt_in", "--reason-code", "drill",
             "--writers-drained", "--sync-frozen"),
            ("resume", "--cohort", "project_opt_in", "--confirm"),
            ("status",),
        ]
        for index, arguments in enumerate(steps):
            name = order[index % 2]
            code, output = run_cli(self.commands[name], shared, *arguments)
            self.assertEqual(code, 0, output)
        document = json.loads((shared / "rollout" / "artifact-rollout-v1.json").read_text())
        self.assertEqual(document["revision"], 4)
        self.assertEqual(output["result"]["project_opt_in_count"], 2)


if __name__ == "__main__":
    unittest.main()
