"""RR-495: services/artifact_migration.py against relay_artifacts::migration.

``RustMigrationTests`` runs every scenario of tests/test_artifact_migration.py
with the coordinator replaced by the Rust one, driven through the
relay-artifacts test driver: preflight, local-only and remote migration,
interruption and resume, rollback, unborn repositories, refusals. Refusals
come back as the same Python exception classes, with their recovery and
report.

``AlternationTests`` lets the two implementations take turns on one
repository and state root: a migration interrupted by one is resumed or
rolled back by the other, and must leave the commits an all-Python run
leaves (pinned Git dates, same device). ``CliTests`` compares
``relay-artifacts migration ...`` with services/artifact_migration_cli.py,
including the Program/Graphify step that runs through
services/artifact_migration_program_bridge.py.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from relay_artifacts_support import REPO, Refused, RustArtifacts, driver_command, git_dates  # noqa: E402

import test_artifact_migration as base  # noqa: E402

CLI_BINARY = REPO / "rust" / "target" / "debug" / "relay-artifacts"
PYTHON = sys.executable
STAGES = (
    "after_preflight_journal", "after_artifact_bootstrap", "after_remote",
    "after_source_commit", "after_materialize", "after_program_export", "before_complete",
)
ERRORS = {
    "ArtifactMigrationError": base.ArtifactMigrationBlocked.__mro__[1],
    "ArtifactMigrationBlocked": base.ArtifactMigrationBlocked,
    "ArtifactMigrationReconciliationRequired": base.ArtifactMigrationReconciliationRequired,
    "ArtifactMigrationInjectedFailure": base.ArtifactMigrationInjectedFailure,
}


class RustCoordinator:
    """`ArtifactMigrationCoordinator`'s interface over the Rust driver."""

    def __init__(self, crate, repo_path, project_id, state_root, *, registry_path,
                 runs_db_path=None, graphify_path=None, device_id="migration-device",
                 provider=None, failure_injector=None, remote_timeout_seconds=15.0,
                 remote_name=None):
        fail_stages = {}
        if failure_injector is not None:
            for stage in STAGES:
                try:
                    failure_injector(stage)
                except Exception as error:  # noqa: BLE001 - replayed by the driver
                    fail_stages[stage] = str(error)
        self.crate = crate
        self.remote_name = remote_name
        self.arguments = {
            "repo": str(repo_path), "project_id": project_id, "state_root": str(state_root),
            "registry_path": str(registry_path), "device_id": device_id,
            "remote_timeout_seconds": remote_timeout_seconds, "fail_stages": fail_stages,
        }
        for key, value in (("runs_db_path", runs_db_path), ("graphify_path", graphify_path),
                           ("provider", provider)):
            if value is not None:
                self.arguments[key] = str(value)
        self.journal_path = Path(self._call("journal_path"))

    def _call(self, function: str, **extra):
        arguments = dict(self.arguments, **extra)
        if self.remote_name is not None:
            arguments["remote_name"] = self.remote_name
        try:
            return self.crate.call("migration." + function, **arguments)
        except Refused as refused:
            error_class = ERRORS.get(refused.error)
            if error_class is None:
                raise
            raise error_class(
                refused.message, recovery=refused.answer.get("recovery") or "",
                report=refused.answer.get("report"),
            ) from None

    def preview(self):
        return types.SimpleNamespace(**self._call("preview"))

    def migrate(self, *, confirm_source_cleanup, confirm_first_push=False):
        return types.SimpleNamespace(**self._call(
            "migrate", confirm_source_cleanup=confirm_source_cleanup,
            confirm_first_push=confirm_first_push,
        ))

    def rollback(self):
        return types.SimpleNamespace(**self._call("rollback"))


def _rust_crate(test_case):
    command = driver_command()
    if not command:
        test_case.skipTest("relay-artifacts driver is not built; run cargo test in rust/")
    crate = RustArtifacts(command, environment={"RELAY_PYTHON": PYTHON, **git_dates()})
    test_case.addCleanup(crate.close)
    return crate


class RustMigrationTests(base.ArtifactMigrationTests):
    """Every Python migration scenario, against the Rust coordinator."""

    def setUp(self):
        self.crate = _rust_crate(self)
        super().setUp()

    def coordinator(self, repo: Path | None = None, **kwargs):
        return RustCoordinator(
            self.crate,
            repo or self.repo,
            kwargs.pop("project_id", self.project_id),
            kwargs.pop("state_root", self.state),
            registry_path=kwargs.pop("registry_path", self.registry),
            runs_db_path=kwargs.pop("runs_db_path", self.runs),
            graphify_path=kwargs.pop("graphify_path", None),
            device_id=kwargs.pop("device_id", "migration-test-device"),
            **kwargs,
        )


def pin_mtimes(repo: Path) -> None:
    """Legacy file mtimes are manifest evidence; give every copy the same ones."""
    for path in sorted((repo / ".orchestrator").rglob("*")):
        if path.is_file():
            os.utime(path, ns=(1_780_000_000_000_000_000, 1_780_000_000_000_000_000))


def fresh(fixture, name: str):
    """A second identical legacy project, with its own state root."""
    repo = fixture.root / name
    state = fixture.root / f"{name}-state"
    registry = state / "projects/registry-v2.json"
    fixture._make_legacy_repo(repo, explicit_activity=True)
    pin_mtimes(repo)
    fixture._write_registry(repo, registry_path=registry)
    return repo, state, registry


class AlternationTests(unittest.TestCase):
    """Python and Rust taking turns on one migration."""

    maxDiff = None

    def setUp(self):
        self.crate = _rust_crate(self)
        dates = mock.patch.dict(os.environ, git_dates())
        dates.start()
        self.addCleanup(dates.stop)
        self.f = base.ArtifactMigrationTests(methodName="run")
        self.f.setUp()
        self.addCleanup(self.f.tearDown)
        self.setup_alternation_repo()

    def git(self, repo, *arguments):
        return self.f.git(repo, *arguments)

    def python(self, repo=None, **kwargs):
        return self.f.coordinator(repo, **kwargs)

    def rust(self, repo=None, **kwargs):
        f = self.f
        return RustCoordinator(
            self.crate, repo or f.repo, kwargs.pop("project_id", f.project_id),
            kwargs.pop("state_root", f.state),
            registry_path=kwargs.pop("registry_path", f.registry),
            runs_db_path=kwargs.pop("runs_db_path", f.runs),
            device_id="migration-test-device", **kwargs,
        )

    def outcome(self, repo: Path) -> dict:
        artifact = self.git(repo, "rev-parse", base.ARTIFACT_REF)
        return {
            "artifact_commit": artifact,
            "artifact_files": self.f._artifact_files(repo, artifact),
            "source_head": self.git(repo, "rev-parse", "HEAD"),
            "source_message": self.git(repo, "log", "-1", "--format=%B"),
            "projection": self.f._tree_bytes(repo / ".orchestrator"),
            "tracked": self.git(repo, "ls-files", ".orchestrator"),
        }

    def reference(self) -> dict:
        repo, state, registry = fresh(self.f, "reference")
        result = self.python(repo, state_root=state, registry_path=registry,
                             runs_db_path=state / "runs.db").migrate(confirm_source_cleanup=True)
        self.assertEqual(result.stage, "complete")
        return self.outcome(repo)

    def setup_alternation_repo(self):
        shutil.rmtree(self.f.repo)
        self.f._make_legacy_repo(self.f.repo, explicit_activity=True)
        pin_mtimes(self.f.repo)
        self.f._write_registry(self.f.repo)

    def interrupt(self, coordinator_factory, stage: str):
        def fail(current):
            if current == stage:
                raise RuntimeError("interrupted")

        with self.assertRaises(base.ArtifactMigrationInjectedFailure):
            coordinator_factory(failure_injector=fail).migrate(confirm_source_cleanup=True)

    def test_each_implementation_resumes_the_others_interrupted_migration(self):
        expected = self.reference()
        for first, second in (("python", "rust"), ("rust", "python")):
            for stage in ("after_artifact_bootstrap", "after_source_commit", "after_materialize"):
                with self.subTest(first=first, stage=stage):
                    shutil.rmtree(self.f.state, ignore_errors=True)
                    self.setup_alternation_repo()
                    self.interrupt(getattr(self, first), stage)
                    result = getattr(self, second)().migrate(confirm_source_cleanup=True)
                    self.assertEqual(result.stage, "complete")
                    self.assertEqual(self.outcome(self.f.repo), expected)
                    again = getattr(self, first)().migrate(confirm_source_cleanup=True)
                    self.assertTrue(again.idempotent)
                    self.assertEqual(again.artifact_commit, expected["artifact_commit"])

    def test_each_implementation_rolls_back_the_others_migration(self):
        for first, second in (("python", "rust"), ("rust", "python")):
            with self.subTest(first=first):
                shutil.rmtree(self.f.state, ignore_errors=True)
                self.setup_alternation_repo()
                legacy = self.f._tree_bytes(self.f.repo / ".orchestrator")
                source = self.git(self.f.repo, "rev-parse", "HEAD")
                migrated = getattr(self, first)().migrate(confirm_source_cleanup=True)
                rolled = getattr(self, second)().rollback()
                self.assertEqual(rolled.stage, "rolled_back")
                self.assertFalse(rolled.idempotent)
                self.assertEqual(self.f._tree_bytes(self.f.repo / ".orchestrator"), legacy)
                self.assertEqual(self.git(self.f.repo, "rev-parse", "HEAD^"), migrated.source_commit)
                self.assertEqual(self.git(self.f.repo, "rev-parse", "HEAD^^"), source)
                self.assertEqual(self.git(self.f.repo, "rev-parse", base.ARTIFACT_REF),
                                 migrated.artifact_commit)
                self.assertTrue(getattr(self, first)().rollback().idempotent)

    def test_previews_are_identical(self):
        self.f._make_dirty_source_state(self.f.repo)
        python = self.python().preview().as_dict()
        rust = dict(vars(self.rust().preview()))
        self.assertTrue(rust.pop("can_migrate"))
        self.assertEqual(rust, json.loads(json.dumps(python)))

    def test_journals_and_registry_are_the_same_documents(self):
        repo, state, registry = fresh(self.f, "python-run")
        self.python(repo, state_root=state, registry_path=registry,
                    runs_db_path=state / "runs.db").migrate(confirm_source_cleanup=True)
        self.setup_alternation_repo()
        self.rust().migrate(confirm_source_cleanup=True)

        def normalized(path: Path, repo_path: Path, state_root: Path):
            text = path.read_text()
            for value, placeholder in ((str(state_root), "<STATE>"), (str(repo_path), "<REPO>")):
                text = text.replace(value, placeholder)
            document = json.loads(text)
            for key in ("started_at", "completed_at"):
                document.pop(key, None)
            document.get("retention_preview", {}).pop("evaluated_at", None)
            for record in document.get("projects", []):
                record.pop("updated_at", None)
            return document

        project_state = Path("artifacts") / self.f.project_id / "legacy-migration"
        for name in ("journal.json", "preflight.json"):
            with self.subTest(file=name):
                python = normalized(state / project_state / name, repo, state)
                rust = normalized(self.f.state / project_state / name, self.f.repo, self.f.state)
                self.assertEqual(rust, python)


class CliTests(unittest.TestCase):
    """`relay-artifacts migration` against artifact_migration_cli.py."""

    def setUp(self):
        if not os.access(CLI_BINARY, os.X_OK):
            self.skipTest("relay-artifacts is not built; run cargo build in rust/")
        dates = mock.patch.dict(os.environ, git_dates())
        dates.start()
        self.addCleanup(dates.stop)
        self.fixture = base.ArtifactMigrationTests(methodName="run")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)

    def run_cli(self, command, *arguments, repo=None, state=None):
        repo = repo or self.fixture.repo
        state = state or self.fixture.state
        environment = {**os.environ, **git_dates(), "RELAY_PYTHON": PYTHON,
                       "PYTHONDONTWRITEBYTECODE": "1"}
        done = subprocess.run(
            [*command, *arguments, "--repo", str(repo), "--project-id", self.fixture.project_id,
             "--state-root", str(state)],
            capture_output=True, text=True, env=environment, cwd=str(REPO / "services"),
        )
        return done.returncode, done.stdout

    def python_cli(self, *arguments, **kwargs):
        return self.run_cli([PYTHON, str(REPO / "services/artifact_migration_cli.py")], *arguments, **kwargs)

    def rust_cli(self, *arguments, **kwargs):
        return self.run_cli([str(CLI_BINARY), "migration"], *arguments, **kwargs)

    def test_preview_prints_the_same_document(self):
        python = self.python_cli("preview")
        rust = self.rust_cli("preview")
        self.assertEqual(rust[0], python[0])
        self.assertEqual(json.loads(rust[1]), json.loads(python[1]))

    def test_unconfirmed_migration_is_refused_the_same_way(self):
        python = self.python_cli("migrate")
        rust = self.rust_cli("migrate")
        self.assertEqual(python[0], 2)
        self.assertEqual(rust, python)

    def test_migrate_with_the_graphify_rebuild_matches_python(self):
        """The default Graphify path runs the Program step through the bridge."""
        fixture = self.fixture
        python_repo, python_state, python_registry = fresh(fixture, "python-cli")
        fixture.registry = python_registry
        python = self.python_cli("migrate", "--confirm-source-cleanup",
                                 repo=python_repo, state=python_state)
        fixture.registry = fixture.state / "projects/registry-v2.json"
        shutil.rmtree(fixture.repo)
        fixture._make_legacy_repo(fixture.repo, explicit_activity=True)
        pin_mtimes(fixture.repo)
        fixture._write_registry(fixture.repo)
        rust = self.rust_cli("migrate", "--confirm-source-cleanup")
        self.assertEqual(python[0], 0, python[1])
        self.assertEqual(rust[0], 0, rust[1])
        python_result = json.loads(python[1])["result"]
        rust_result = json.loads(rust[1])["result"]
        self.assertEqual(rust_result["artifact_commit"], python_result["artifact_commit"])
        self.assertEqual(rust_result["source_commit"], python_result["source_commit"])
        for repo, state in ((python_repo, python_state), (fixture.repo, fixture.state)):
            journal = json.loads((state / "artifacts" / fixture.project_id /
                                  "legacy-migration/journal.json").read_text())
            self.assertEqual(journal["stage"], "complete")
            self.assertEqual(journal["program_migration"]["exported"], 0)
            self.assertIsNotNone(journal["program_migration"]["rebuild"])
            self.assertTrue((state / "orchestrator/graphify.db").exists())
        rebuilt = [
            json.loads((state / "artifacts" / fixture.project_id /
                        "legacy-migration/journal.json").read_text())["program_migration"]["rebuild"]
            for state in (python_state, fixture.state)
        ]
        for record in rebuilt:
            record.pop("backup_path")
        self.assertEqual(rebuilt[0], rebuilt[1])


if __name__ == "__main__":
    unittest.main()
