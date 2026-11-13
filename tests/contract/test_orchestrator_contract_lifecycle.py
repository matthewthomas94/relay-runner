"""Daemon process lifecycle: restart with runs in flight, databases from the
previous release, and isolation from the installed daemon's files.
"""

from __future__ import annotations

import os
import sqlite3
import subprocess
import unittest
from pathlib import Path

from orchestrator_contract_support import (
    ARTIFACT_REF, FIXTURES_DIR, REPO_ROOT, DaemonCase, Sandbox, git,
)

PREVIOUS_RELEASE = "v0.5.4"
STALLED_ERROR = "Worker process was no longer running when daemon restarted"


class RestartTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.box = Sandbox(self.addCleanup)
        self.legacy = self.box.make_repo("legacy")
        for ticket_id in ("CT-1", "CT-2"):
            self.box.write_ticket(self.legacy, ticket_id)
            self.box.plan("implementation", ticket_id, hold=str(self.box.hold("never")))
        self.artifact = self.box.artifact_project("artifact", tickets=[("CT-5", {})], next_id=6)
        self.box.plan("artifact-implementation", "CT-5", hold=str(self.box.hold("never")))
        self.box.start()

    def dispatch(self, ticket_id, repo, **extra):
        response = self.box.post("/v1/runs", {"ticket_id": ticket_id, "repo_path": str(repo), **extra})
        self.assertIn(response.status, (200, 202), response)
        return response.json["run"]

    def test_killed_daemon_marks_in_flight_runs_stalled_on_start(self):
        legacy = self.dispatch("CT-1", self.legacy)
        artifact = self.dispatch("CT-5", self.artifact, project_scope_token=self.box.scope_token(self.artifact))
        for run in (legacy, artifact):
            self.box.wait_for_run(run["id"], "Running")
        claimed_head = git(self.artifact, "rev-parse", ARTIFACT_REF)

        self.box.kill()
        self.box.start()
        self.assertIn("reconciled 2 stalled run(s) on startup", self.box.stderr())
        for run in (legacy, artifact):
            stalled = self.box.run(run["id"])
            self.assertEqual(stalled["state"], "Stalled")
            self.assertEqual(stalled["last_error"], STALLED_ERROR)
            self.assertIsNotNone(stalled["ended_at"])
        index = {entry["run_id"]: entry["state"] for entry in self.box.runs_index()["runs"]}
        self.assertEqual(index, {legacy["id"]: "Stalled", artifact["id"]: "Stalled"})
        # Reconciling publishes nothing on the artifact ref and edits no legacy ticket.
        self.assertEqual(git(self.artifact, "rev-parse", ARTIFACT_REF), claimed_head)
        self.assertIn("\nstatus: backlog\n", (self.legacy / ".orchestrator" / "CT-1.md").read_text())

        # A stalled ticket can be dispatched again; ids continue from the ledger.
        self.box.plan("implementation", "CT-1")
        again = self.dispatch("CT-1", self.legacy)
        self.assertEqual(again["id"], artifact["id"] + 1)
        self.assertEqual(again["attempt"], 2)
        self.box.wait_for_run(again["id"], "Merged")

    def test_stopped_daemon_cancels_in_flight_runs(self):
        run = self.dispatch("CT-2", self.legacy)
        self.box.wait_for_run(run["id"], "Running")
        self.box.stop()
        self.assertIn("caught signal 15, shutting down", self.box.stderr())
        self.assertFalse(self.box.port_file.exists(), "the port file is removed on shutdown")
        self.box.start()
        canceled = self.box.run(run["id"])
        self.assertEqual(canceled["state"], "Canceled")
        self.assertIsNotNone(canceled["ended_at"])


def restore_release(box: Sandbox, release: str) -> dict:
    """Write the release's databases into the sandbox data root; return their user_version."""
    versions = {}
    for dump in sorted((FIXTURES_DIR / release).glob("*.sql")):
        target = box.data_root / (dump.stem + ".db")
        connection = sqlite3.connect(str(target))
        try:
            connection.executescript(dump.read_text().replace("<ROOT>", str(box.root)))
            versions[target.name] = connection.execute("PRAGMA user_version").fetchone()[0]
        finally:
            connection.close()
    return versions


def schema(path: Path) -> dict:
    connection = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        tables = [row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]
        return {
            "user_version": connection.execute("PRAGMA user_version").fetchone()[0],
            "columns": {table: [row[1] for row in connection.execute("PRAGMA table_info(%s)" % table)]
                        for table in tables},
        }
    finally:
        connection.close()


class PreviousReleaseDatabaseTests(DaemonCase):
    """Databases written by the previous release, captured by
    fixtures/orchestrator/make_release_fixture.py."""

    @classmethod
    def prepare(cls):
        restored = restore_release(cls.box, PREVIOUS_RELEASE)
        cls.before = {name: schema(cls.box.data_root / name) for name in restored}
        cls.repo = cls.box.make_repo("released")
        cls.box.write_ticket(cls.repo, "CT-9")

    def test_every_release_database_is_still_readable_and_not_downgraded(self):
        self.assertEqual(len(self.before), 8)
        for name, before in self.before.items():
            after = schema(self.box.data_root / name)
            self.assertGreaterEqual(after["user_version"], before["user_version"], name)
            for table, columns in before["columns"].items():
                self.assertIn(table, after["columns"], "%s lost table %s" % (name, table))
                self.assertEqual(
                    after["columns"][table][:len(columns)], columns,
                    "%s.%s changed its existing columns" % (name, table),
                )

    def test_release_runs_are_served(self):
        runs = self.assertStatus(self.box.get("/v1/runs"), 200).json["runs"]
        released = [run for run in runs if run["ticket_id"] in {"CT-1", "CT-2", "CT-3", "CT-4"}]
        self.assertEqual(
            sorted((run["id"], run["ticket_id"], run["state"]) for run in released),
            [(1, "CT-1", "Merged"), (2, "CT-2", "Failed"), (3, "CT-3", "Merged"), (4, "CT-4", "Merged")],
        )
        self.box.assert_golden_json("release/runs.response", {"runs": [
            run for run in runs if run["id"] <= 4
        ]})

    def test_release_queue_drain_sessions_and_outcomes_are_served(self):
        drains = self.box.get("/v1/queue-drains", include_terminal=True).json["queue_drains"]
        # The release's drain keeps its id and stays live, so it goes on
        # observing the project and may have picked up later tickets.
        self.assertEqual([drain["id"] for drain in drains], ["drain-55c0a690382f-1"])
        self.assertLessEqual({"CT-1", "CT-2", "CT-3", "CT-4"}, set(drains[0]["observed_ticket_ids"]))
        sessions = self.box.get("/v1/orchestrator-sessions").json["orchestrator_sessions"]
        self.assertEqual([(session["id"], session["provider_key"]) for session in sessions], [(1, "claude")])
        outcomes = self.box.get("/v1/messenger/outcomes", limit=100).json["outcomes"]
        self.assertIsInstance(outcomes, list)

    def test_new_runs_continue_the_release_ledger(self):
        run = self.assertStatus(
            self.box.post("/v1/runs", {"ticket_id": "CT-9", "repo_path": str(self.repo)}), 202,
        ).json["run"]
        self.assertGreater(run["id"], 4)
        self.box.wait_for_run(run["id"], "Merged")


class IsolationTests(unittest.TestCase):
    """The suite never touches the installed daemon's files."""

    maxDiff = None
    REAL_PORT_FILE = Path("/tmp/relay_orchestrator.port")

    def real_port_file(self):
        try:
            stat = self.REAL_PORT_FILE.stat()
            return self.REAL_PORT_FILE.read_text(), stat.st_mtime_ns, stat.st_ino
        except FileNotFoundError:
            return None

    def test_a_full_session_stays_inside_the_sandbox(self):
        real_home = Path(os.path.expanduser("~"))
        real_support = real_home / "Library" / "Application Support" / "relay-runner"
        port_before = self.real_port_file()

        box = Sandbox(self.addCleanup)
        repo = box.make_repo("isolated")
        box.write_ticket(repo, "CT-1")
        box.plan("implementation", "CT-1", hold=str(box.hold("go")))
        box.start()
        self.assertNotEqual(box.environment()["HOME"], str(real_home))
        self.assertEqual(int(box.port_file.read_text()), box.port)

        run = box.post("/v1/runs", {"ticket_id": "CT-1", "repo_path": str(repo)}).json["run"]
        box.wait_for_run(run["id"], "Running")
        open_files = self.open_paths(box.process.pid)
        box.release(box.hold("go"))
        box.wait_for_run(run["id"], "Merged")
        box.post("/v1/artifacts/notes/create", {
            "repo_path": "", "request_id": "isolation-1", "created_at": "2026-08-04T05:00:00Z",
            "capture_started_at": "2026-08-04T05:00:00Z", "captured_at": "2026-08-04T05:00:00Z",
            "recording_state": "recording", "checkpoint_reason": "checkpoint",
            "segments": [{"segment_id": "s1", "captured_at": "2026-08-04T05:00:00Z", "text": "x"}],
        })
        box.stop()

        # The installed daemon's port file is exactly as it was.
        self.assertEqual(self.real_port_file(), port_before)
        # Every database, the runs index and the notes library are in the sandbox,
        # and nothing was written under the sandbox HOME's default location.
        for name in ("runs.db", "runs.json", "queue_drains.db", "orchestrator_sessions.db",
                     "orchestrator_commands.db", "messenger_outcomes.db", "followup_proposals.db",
                     "continuity_reports.db"):
            self.assertTrue((box.data_root / name).exists(), name)
        self.assertTrue((box.state_root / "notes" / ".git").exists())
        self.assertFalse((box.home / "Library" / "Application Support").exists(),
                         box.tree(box.home))
        # No file the daemon held open lies in the installed state or /tmp.
        forbidden = [path for path in open_files
                     if (path.startswith(str(real_support)) and not path.startswith(str(REPO_ROOT)))
                     or path.startswith(("/tmp/", "/private/tmp/"))]
        self.assertEqual(forbidden, [])
        self.assertTrue(any(path.startswith(str(box.data_root)) for path in open_files), open_files)
        # The installed ledger never saw a sandbox path.
        real_runs = real_support / "orchestrator" / "runs.db"
        if real_runs.exists():
            connection = sqlite3.connect("file:%s?mode=ro" % real_runs, uri=True, timeout=10)
            try:
                leaked = connection.execute(
                    "SELECT COUNT(*) FROM runs WHERE repo_path LIKE ? OR workspace_path LIKE ?",
                    (str(box.root) + "%", str(box.root) + "%"),
                ).fetchone()[0]
            finally:
                connection.close()
            self.assertEqual(leaked, 0)
        # Only the fakes ran: every provider launch was recorded by them.
        self.assertTrue(box.invocations(role="implementation"))
        self.assertTrue(box.invocations(role="review"))

    @staticmethod
    def open_paths(pid: int) -> list:
        """Regular files and directories `pid` and its children hold open."""
        done = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-g", str(os.getpgid(pid)), "-Fn"],
                              capture_output=True, text=True, check=False)
        return sorted({line[1:] for line in done.stdout.splitlines()
                       if line.startswith("n/") and not line.startswith("n/dev/")})


if __name__ == "__main__":
    unittest.main()
