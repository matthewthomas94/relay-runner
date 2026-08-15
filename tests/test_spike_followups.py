from __future__ import annotations

import concurrent.futures
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

from followup_tickets import FollowupProposalStore  # noqa: E402
from orchestrator import Daemon  # noqa: E402
from relay_authorization import (  # noqa: E402
    allowed_mutations_for_metadata,
    record_command_authorization,
    validate_and_mark_mutation,
)
from tickets import read as read_ticket  # noqa: E402


class SpikeFollowupTests(unittest.TestCase):
    def test_ticket_command_authorization_allows_spike_followup_accept(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index, action in enumerate(("create_ticket", "update_ticket"), start=1):
                with self.subTest(action=action):
                    ledger = root / f"{action}.json"
                    metadata = {
                        "relay_command_seq": index,
                        "relay_command_id": f"command-{index}",
                        "action": action,
                        "source_text": "accept the first spike follow-up proposal",
                    }
                    record_command_authorization(
                        ledger,
                        metadata,
                        relationship="replacement",
                        allowed_mutations=allowed_mutations_for_metadata(metadata),
                    )

                    record = validate_and_mark_mutation(
                        ledger,
                        index,
                        f"command-{index}",
                        {
                            "kind": "spike_followup_accept",
                            "request_id": "batch:proposal",
                        },
                    )

                    self.assertEqual(
                        record["started_mutations"][0]["mutation"]["kind"],
                        "spike_followup_accept",
                    )

    def test_proposals_are_durable_editable_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_spike_repo(root / "repo")
            store_path = root / "followups.db"
            daemon = self.make_daemon(store_path, root / "registry.json")

            first = daemon.propose_spike_followups(
                origin_repo_path=str(repo), origin_ticket_id="RR-1", origin_run_id=7
            )
            self.assertTrue(first["created"])
            self.assertEqual(len(first["batch"]["proposals"]), 2)
            proposal = first["batch"]["proposals"][0]
            self.assertEqual(proposal["state"], "draft")
            self.assertEqual(proposal["draft"]["target_repo_path"], str(repo.resolve()))

            restarted = self.make_daemon(store_path, root / "registry.json")
            repeated = restarted.propose_spike_followups(
                origin_repo_path=str(repo), origin_ticket_id="RR-1", origin_run_id=7
            )
            self.assertTrue(repeated["duplicate"])
            self.assertEqual(repeated["batch"]["id"], first["batch"]["id"])

            edited = restarted.review_spike_followup(
                batch_id=first["batch"]["id"],
                proposal_id=proposal["id"],
                decision="edit",
                updates={"title": "Implement the refined parser boundary"},
            )
            self.assertEqual(
                edited["batch"]["proposals"][0]["draft"]["title"],
                "Implement the refined parser boundary",
            )
            self.assertFalse((repo / ".orchestrator/RR-2.md").exists())

    def test_accept_commits_backlog_ticket_once_with_provenance_and_preserves_unrelated_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_spike_repo(root / "repo")
            unrelated = repo / "notes.txt"
            unrelated.write_text("keep me dirty\n")
            daemon = self.make_daemon(root / "followups.db", root / "registry.json")
            proposed = daemon.propose_spike_followups(
                origin_repo_path=str(repo), origin_ticket_id="RR-1", origin_run_id=7
            )
            batch = proposed["batch"]
            proposal = batch["proposals"][0]

            accepted = daemon.review_spike_followup(
                batch_id=batch["id"], proposal_id=proposal["id"], decision="accept"
            )
            self.assertEqual(accepted["authorization_source"], "foreground_pm")
            ticket_id = accepted["committed"][0]["ticket_id"]
            ticket = read_ticket(repo / ".orchestrator" / f"{ticket_id}.md")
            self.assertEqual(ticket["status"], "backlog")
            self.assertEqual(ticket["execution_mode"], "implementation")
            self.assertEqual(ticket["run_id"], None)
            self.assertIn("Originating spike: `RR-1`", ticket["body"])
            self.assertIn("Spike run: 7", ticket["body"])
            self.assertIn("relay-spike-followup-key:", ticket["body"])
            self.assertEqual(unrelated.read_text(), "keep me dirty\n")
            self.assertIn("notes.txt", self.git(repo, "status", "--short").stdout)
            self.assertEqual(self.config_next_id(repo), 3)

            duplicate = daemon.review_spike_followup(
                batch_id=batch["id"], proposal_id=proposal["id"], decision="accept"
            )
            self.assertTrue(duplicate["duplicate"])
            self.assertEqual(self.config_next_id(repo), 3)
            self.assertEqual(len(list((repo / ".orchestrator").glob("RR-2.md"))), 1)

    def test_concurrent_accepts_allocate_distinct_ids_and_leave_clean_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_spike_repo(root / "repo")
            daemon = self.make_daemon(root / "followups.db", root / "registry.json")
            first = self.refined_proposal(repo)
            second = self.refined_proposal(repo)
            first["title"] = "Implement the first parser boundary"
            second["title"] = "Implement the second parser boundary"
            batch = daemon.propose_spike_followups(
                origin_repo_path=str(repo),
                origin_ticket_id="RR-1",
                origin_run_id=7,
                proposals=[first, second],
            )["batch"]

            original_accept = daemon._accept_spike_followup
            probe_lock = threading.Lock()
            start = threading.Barrier(2)
            active = 0
            maximum_active = 0

            def probed_accept(**kwargs):
                nonlocal active, maximum_active
                with probe_lock:
                    active += 1
                    maximum_active = max(maximum_active, active)
                try:
                    time.sleep(0.05)
                    return original_accept(**kwargs)
                finally:
                    with probe_lock:
                        active -= 1

            daemon._accept_spike_followup = probed_accept

            def accept(proposal: dict) -> dict:
                start.wait(timeout=5)
                return daemon.review_spike_followup(
                    batch_id=batch["id"],
                    proposal_id=proposal["id"],
                    decision="accept",
                )

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(accept, batch["proposals"]))

            self.assertEqual(maximum_active, 1)
            self.assertEqual(
                {result["committed"][0]["ticket_id"] for result in results},
                {"RR-2", "RR-3"},
            )
            self.assertEqual(self.config_next_id(repo), 4)
            self.assertTrue((repo / ".orchestrator/RR-2.md").is_file())
            self.assertTrue((repo / ".orchestrator/RR-3.md").is_file())
            self.assertEqual(self.git(repo, "status", "--short").stdout, "")

    def test_cross_project_acceptance_uses_registered_target_counter(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = self.make_spike_repo(root / "origin")
            target = self.make_repo(root / "target", prefix="TG", next_id=11)
            registry = root / "registry.json"
            registry.write_text(
                '{"projects":[{"id":"' + str(target) + '","repoPath":"' + str(target) + '"}]}'
            )
            daemon = self.make_daemon(root / "followups.db", registry)
            proposal = self.refined_proposal(target)
            batch = daemon.propose_spike_followups(
                origin_repo_path=str(origin),
                origin_ticket_id="RR-1",
                origin_run_id=7,
                proposals=[proposal],
            )["batch"]

            result = daemon.review_spike_followup(
                batch_id=batch["id"], proposal_id=batch["proposals"][0]["id"], decision="accept"
            )
            self.assertEqual(result["committed"][0]["ticket_id"], "TG-11")
            self.assertEqual(self.config_next_id(target), 12)
            self.assertFalse((origin / ".orchestrator/RR-2.md").exists())

    def test_unregistered_project_and_private_material_fail_before_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = self.make_spike_repo(root / "origin")
            target = self.make_repo(root / "target", prefix="TG", next_id=1)
            daemon = self.make_daemon(root / "followups.db", root / "registry.json")
            private = self.refined_proposal(origin)
            private["description"] = "Copy the raw provider transcript into the ticket"
            with self.assertRaisesRegex(ValueError, "private provider"):
                daemon.propose_spike_followups(
                    origin_repo_path=str(origin), origin_ticket_id="RR-1", origin_run_id=7,
                    proposals=[private],
                )

            unsupported = self.refined_proposal(origin)
            unsupported["worker_effort"] = "max"
            with self.assertRaisesRegex(ValueError, "Claude-scoped"):
                daemon.propose_spike_followups(
                    origin_repo_path=str(origin), origin_ticket_id="RR-1", origin_run_id=7,
                    proposals=[unsupported],
                )

            routed = self.refined_proposal(target)
            with self.assertRaisesRegex(ValueError, "ambiguous project ownership"):
                daemon.propose_spike_followups(
                    origin_repo_path=str(origin), origin_ticket_id="RR-1", origin_run_id=7,
                    proposals=[routed],
                )
            self.assertEqual(self.config_next_id(target), 1)

    def test_acceptance_failure_keeps_recoverable_draft_and_reports_exact_partial_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_spike_repo(root / "repo")
            daemon = self.make_daemon(root / "followups.db", root / "registry.json")
            proposal = self.refined_proposal(repo)
            proposal["depends_on"] = ["RR-404"]
            batch = daemon.propose_spike_followups(
                origin_repo_path=str(repo), origin_ticket_id="RR-1", origin_run_id=7,
                proposals=[proposal],
            )["batch"]

            result = daemon.review_spike_followup(
                batch_id=batch["id"], proposal_id=batch["proposals"][0]["id"], decision="accept"
            )
            self.assertTrue(result["partial"])
            self.assertEqual(result["committed"], [])
            self.assertIn("RR-404", result["not_committed"][0]["error"])
            self.assertEqual(result["batch"]["proposals"][0]["state"], "draft")
            self.assertIn("RR-404", result["batch"]["proposals"][0]["error"])
            self.assertEqual(self.config_next_id(repo), 2)

    def test_acceptance_rejects_incomplete_user_authorization_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_spike_repo(root / "repo")
            daemon = self.make_daemon(root / "followups.db", root / "registry.json")
            batch = daemon.propose_spike_followups(
                origin_repo_path=str(repo), origin_ticket_id="RR-1", origin_run_id=7
            )["batch"]

            with self.assertRaisesRegex(ValueError, "complete Relay authorization metadata"):
                daemon.review_spike_followup(
                    batch_id=batch["id"],
                    proposal_id=batch["proposals"][0]["id"],
                    decision="accept",
                    relay_command_seq=4,
                )

            self.assertFalse((repo / ".orchestrator/RR-2.md").exists())

    def test_acceptance_blocks_dirty_board_overlap_without_touching_unrelated_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_spike_repo(root / "repo")
            daemon = self.make_daemon(root / "followups.db", root / "registry.json")
            batch = daemon.propose_spike_followups(
                origin_repo_path=str(repo), origin_ticket_id="RR-1", origin_run_id=7
            )["batch"]
            proposal = batch["proposals"][0]
            config = repo / ".orchestrator/config.toml"
            config.write_text('prefix = "RR"\nnext_id = 99\n')
            unrelated = repo / "notes.txt"
            unrelated.write_text("keep me dirty\n")

            result = daemon.review_spike_followup(
                batch_id=batch["id"], proposal_id=proposal["id"], decision="accept"
            )

            self.assertTrue(result["partial"])
            self.assertIn("existing changes to .orchestrator/config.toml", result["not_committed"][0]["error"])
            self.assertFalse((repo / ".orchestrator/RR-2.md").exists())
            self.assertEqual(config.read_text(), 'prefix = "RR"\nnext_id = 99\n')
            self.assertEqual(unrelated.read_text(), "keep me dirty\n")
            self.assertEqual(result["batch"]["proposals"][0]["state"], "draft")

    def make_daemon(self, store_path: Path, registry_path: Path) -> Daemon:
        daemon = object.__new__(Daemon)
        daemon.followup_proposals = FollowupProposalStore(store_path)
        daemon.program_registry_path = registry_path
        daemon._ticket_authoring_lock = __import__("threading").Lock()
        return daemon

    def make_spike_repo(self, path: Path) -> Path:
        repo = self.make_repo(path, prefix="RR", next_id=2)
        ticket = repo / ".orchestrator/RR-1.md"
        ticket.write_text("""---
id: RR-1
title: Investigate parser boundaries
status: done
priority: high
execution_mode: spike
depends_on: []
run_id: 7
canceled: false
order: 1
worker_model: strong
worker_effort: high
worker_sizing_rationale: Research required repository evidence.
worker_provider_notes: Codex and Claude used the same read-only result contract.
---

## Description

Investigate parser behavior.

## Acceptance criteria

- [ ] Record evidence.

## Spike report

- **Run:** 7 (attempt 1)
- **Provider:** codex

**Conclusions**

- The parser boundary should be explicit.

**Evidence**

- `parser.py` - Current behavior is implicit.

**Uncertainties**

- None recorded.

**Recommended next steps**

- Add an explicit parser boundary with focused tests.
- Document the provider-neutral parsing contract.
""")
        self.git(repo, "add", ".orchestrator/RR-1.md")
        self.git(repo, "commit", "-m", "record spike")
        return repo

    def make_repo(self, path: Path, *, prefix: str, next_id: int) -> Path:
        path.mkdir(parents=True)
        self.git(path, "init", "-b", "main")
        self.git(path, "config", "user.email", "test@example.com")
        self.git(path, "config", "user.name", "Test")
        (path / ".orchestrator").mkdir()
        (path / ".orchestrator/config.toml").write_text(
            f'prefix = "{prefix}"\nnext_id = {next_id}\n'
        )
        (path / "README.md").write_text("fixture\n")
        self.git(path, "add", ".orchestrator/config.toml", "README.md")
        self.git(path, "commit", "-m", "initial")
        return path

    @staticmethod
    def refined_proposal(target: Path) -> dict:
        return {
            "title": "Implement explicit parser boundaries",
            "description": "Add the parser boundary identified by the completed spike.",
            "acceptance_criteria": ["Focused parser tests pass."],
            "priority": "high",
            "depends_on": [],
            "worker_model": "strong",
            "worker_effort": "high",
            "worker_sizing_rationale": "Parser behavior crosses several call sites.",
            "worker_provider_notes": "Codex and Claude preserve the same parser behavior.",
            "target_repo_path": str(target),
        }

    @staticmethod
    def config_next_id(repo: Path) -> int:
        line = (repo / ".orchestrator/config.toml").read_text().splitlines()[1]
        return int(line.split("=", 1)[1])

    @staticmethod
    def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
        )


if __name__ == "__main__":
    unittest.main()
