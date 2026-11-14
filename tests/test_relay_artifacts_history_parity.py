"""RR-495: relay-ticket-history and automatic retention, Python against Rust.

`relay-artifacts history ...` (relay_artifacts::history and
::automatic_retention) is compared with services/artifact_history_cli.py on
real Git: the project's remote is `git@github.com:relay/example.git`, which
passes both implementations' GitHub checks unchanged, and GIT_SSH_COMMAND
points at a small script that serves it from a local bare repository.

One implementation enables archival on a legacy board (the journaled
migration, then the first archive batch) and the other reads and continues
it: search, full-text search, show, a later sweep and a remote-only read
from a fresh checkout must print exactly what the Python command prints.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from relay_artifacts_support import REPO  # noqa: E402

CLI_BINARY = REPO / "rust" / "target" / "debug" / "relay-artifacts"
PYTHON = sys.executable
PROJECT_ID = "history-parity"
REMOTE = "git@github.com:relay/example.git"
FAKE_SSH = """#!/bin/sh
# GIT_SSH_VARIANT=simple: <host> <command>. Serve every host from one root.
shift
cd "$RELAY_FAKE_GITHUB_ROOT" || exit 1
exec sh -c "$1"
"""


def ticket(ticket_id: str, title: str, status: str, activity: str) -> str:
    return (
        "---\n"
        f"id: {ticket_id}\n"
        f"activity_at: {activity}\n"
        f"title: {title}\n"
        f"status: {status}\n"
        "priority: medium\n"
        "execution_mode: implementation\n"
        "depends_on: []\n"
        "run_id: null\n"
        "canceled: false\n"
        "order: 1\n"
        "---\n\n"
        f"## Description\n\nBody of {ticket_id}: the archived evidence.\n"
    )


class HistoryParityTests(unittest.TestCase):
    def setUp(self):
        if not os.access(CLI_BINARY, os.X_OK):
            self.skipTest("relay-artifacts is not built; run cargo build in rust/")
        temporary = tempfile.TemporaryDirectory(prefix="relay-history-parity-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(os.path.realpath(temporary.name))
        self.github = self.root / "github"
        (self.github / "relay").mkdir(parents=True)
        self.git(self.github / "relay", "init", "--bare", "-q", "example.git")
        ssh = self.root / "fake-ssh"
        ssh.write_text(FAKE_SSH)
        ssh.chmod(0o755)
        self.environment = {
            **os.environ,
            "GIT_SSH_COMMAND": str(ssh),
            "GIT_SSH_VARIANT": "simple",
            "RELAY_FAKE_GITHUB_ROOT": str(self.github),
            "RELAY_PYTHON": PYTHON,
            "PYTHONDONTWRITEBYTECODE": "1",
            "GIT_AUTHOR_NAME": "History Tests",
            "GIT_AUTHOR_EMAIL": "history@example.invalid",
            "GIT_COMMITTER_NAME": "History Tests",
            "GIT_COMMITTER_EMAIL": "history@example.invalid",
        }

    def git(self, repo: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(repo), *arguments], check=True, capture_output=True, text=True,
            env=getattr(self, "environment", None),
        ).stdout.strip()

    def project(self, name: str):
        """A legacy board with 27 completed and 2 open tickets, registered."""
        repo = self.root / name
        state = self.root / f"{name}-state"
        board = repo / ".orchestrator"
        board.mkdir(parents=True)
        self.git(repo, "init", "--initial-branch=main", "-q")
        (repo / "README.md").write_text("# History fixture\n")
        (board / "config.toml").write_text('prefix = "RR"\nnext_id = 100\n')
        for number in range(27):
            (board / f"RR-{number:03d}.md").write_text(ticket(
                f"RR-{number:03d}", f"Completed task {number}", "done",
                f"2026-07-01T00:00:{number:02d}Z",
            ))
        (board / "RR-open.md").write_text(ticket("RR-open", "Unfinished", "backlog", "2026-07-02T00:00:00Z"))
        (board / "RR-working.md").write_text(ticket("RR-working", "Still working", "in_progress", "2026-07-02T00:00:00Z"))
        self.git(repo, "add", "README.md", ".orchestrator")
        self.git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "legacy board")
        self.git(repo, "remote", "add", "origin", REMOTE)
        registry = state / "projects/registry-v2.json"
        registry.parent.mkdir(parents=True)
        registry.write_text(json.dumps({
            "schema_version": 2,
            "active_project_id": PROJECT_ID,
            "projects": [{
                "project_id": PROJECT_ID,
                "display_name": "History fixture",
                "selected_path": str(repo),
                "last_resolved_path": str(repo),
                "git_common_directory_fingerprint": "git-common-v1:fixture",
                "availability": "available",
                "updated_at": "2026-08-04T00:00:00Z",
                "remote": {"mode": "local_only", "remoteName": None,
                           "artifactRef": "refs/heads/relay/artifacts"},
            }],
        }))
        return repo, state

    def cli(self, implementation: str, repo: Path, state: Path, *arguments: str):
        command = (
            [str(CLI_BINARY), "history"] if implementation == "rust"
            else [PYTHON, str(REPO / "services/artifact_history_cli.py")]
        )
        done = subprocess.run(
            [*command, *arguments, "--repo", str(repo), "--state-root", str(state)],
            capture_output=True, text=True, env=self.environment, cwd=str(self.root),
        )
        return done.returncode, done.stdout

    def both(self, repo, state, *arguments):
        python = self.cli("python", repo, state, *arguments)
        rust = self.cli("rust", repo, state, *arguments)
        self.assertEqual(rust, python, arguments)
        return json.loads(python[1])

    def add_completed_ticket(self, repo: Path, state: Path, ticket_id: str) -> None:
        sys.path.insert(0, str(REPO / "services"))
        from artifact_store import ArtifactMutation, ArtifactStore, TicketWrite

        store = ArtifactStore(repo, PROJECT_ID, state, enabled=True)
        artifact_id = "ticket-" + hashlib.sha256(f"{PROJECT_ID}:{ticket_id}".encode()).hexdigest()[:40]
        markdown = ticket(ticket_id, "New completion", "done", "2026-07-03T00:00:00Z").replace(
            f"id: {ticket_id}\n", f"id: {ticket_id}\nartifact_id: {artifact_id}\n", 1,
        )
        store.mutate(ArtifactMutation(
            event_id=f"write:{ticket_id}", actor_type="user", device_id="history-tests",
            expected_base=store.snapshot().commit_id,
            operations=(TicketWrite(ticket_id, artifact_id, markdown.encode()),),
        ))

    def exercise(self, writer: str, reader: str):
        repo, state = self.project(f"{writer}-enables")
        code, output = self.cli(writer, repo, state, "enable", "--remote", "origin")
        self.assertEqual(code, 0, output)
        enabled = json.loads(output)
        self.assertEqual(enabled["cleanup"]["state"], "archived")
        self.assertEqual(sorted(enabled["cleanup"]["ticket_ids"]), ["RR-000", "RR-001"])
        self.assertFalse((repo / ".orchestrator/RR-000.md").exists())
        self.assertTrue((repo / ".orchestrator/RR-open.md").exists())

        cards = self.both(repo, state, "search", "")
        self.assertEqual([card["ticket_id"] for card in cards], ["RR-001", "RR-000"])
        self.assertTrue(cards[0]["github_url"].startswith("https://github.com/relay/example/blob/"))
        self.both(repo, state, "search", "task 1")
        self.assertEqual(
            [card["ticket_id"] for card in self.both(repo, state, "search", "archived EVIDENCE", "--full-text")],
            ["RR-001", "RR-000"],
        )
        shown = self.both(repo, state, "show", "RR-000")
        self.assertEqual(shown["availability"], "available")
        self.assertIn("Body of RR-000", shown["markdown"])
        self.both(repo, state, "show", "RR-open")

        # The other implementation continues the archive.
        self.add_completed_ticket(repo, state, "RR-027")
        code, output = self.cli(reader, repo, state, "sweep")
        self.assertEqual(code, 0, output)
        self.assertEqual(json.loads(output)["ticket_ids"], ["RR-002"])
        self.assertEqual(
            [card["ticket_id"] for card in self.both(repo, state, "search", "")],
            ["RR-002", "RR-001", "RR-000"],
        )
        self.assertEqual(self.both(repo, state, "sweep")["state"], "clean")

        # A fresh checkout reads GitHub history without a local archive.
        fresh = self.root / f"{writer}-fresh"
        fresh.mkdir()
        self.git(fresh, "init", "-q")
        self.git(fresh, "remote", "add", "origin", REMOTE)
        remote_cards = self.both(fresh, self.root / f"{writer}-fresh-state", "search", "", "--remote", "origin")
        self.assertEqual([card["ticket_id"] for card in remote_cards], ["RR-002", "RR-001", "RR-000"])
        self.both(fresh, self.root / f"{writer}-fresh-state", "show", "RR-002", "--remote", "origin")
        self.assertEqual(self.git(fresh, "for-each-ref"), "")
        return enabled

    def test_python_enables_and_rust_continues(self):
        self.exercise("python", "rust")

    def test_rust_enables_and_python_continues(self):
        rust = self.exercise("rust", "python")
        self.assertEqual(rust["cleanup"]["recovery"], None)

    def test_refusals_print_the_same_errors(self):
        repo, state = self.project("refusals")
        self.assertEqual(self.both(repo, state, "search", "x")["recovery"], None)
        self.both(repo, state, "sweep")
        fresh = self.root / "no-remote"
        fresh.mkdir()
        self.git(fresh, "init", "-q")
        python = self.cli("python", fresh, state, "search", "x", "--remote", "origin")
        rust = self.cli("rust", fresh, state, "search", "x", "--remote", "origin")
        self.assertEqual(rust, python)
        self.assertEqual(python[0], 1)
        python = self.cli("python", repo, state, "enable")
        rust = self.cli("rust", repo, state, "enable")
        self.assertEqual((rust[0], rust[1]), (python[0], python[1]))
        self.assertEqual(python[0], 2)


if __name__ == "__main__":
    unittest.main()
