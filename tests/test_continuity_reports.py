from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

from continuity_reports import ContinuityReportStore, build_report  # noqa: E402
from orchestrator import Daemon  # noqa: E402
from tickets import read as read_ticket  # noqa: E402


def incident(provider: str = "codex") -> dict:
    return {
        "schema_version": 1,
        "incident_id": f"inc-{'1' if provider == 'codex' else '2'}23456789abc",
        "fingerprint": "fp-123456789012345678901234",
        "classification": "recurring",
        "session_id": "session-123456789012345678901234",
        "command_id": "command-123456789012345678901234",
        "component": "foreground_provider",
        "provider": provider,
        "recovery_generation": "generation-7",
        "phase": "provider_turn",
        "health": "unavailable",
        "timing": {
            "first_observed_at": 10.0,
            "last_observed_at": 50.0,
            "grace_deadline": 40.0,
            "post_grace_samples": 2,
            "failed_native_recovery": False,
            "cooldown_until": 950.0,
        },
        "recovery_objective": {
            "unavailable_capability": "Relay Runner cannot continue foreground project processing.",
            "restored_when": ["provider_process_alive", "provider_processing_ready"],
        },
    }


class ContinuityReportTests(unittest.TestCase):
    def test_unresolved_report_and_proposal_are_sanitized_and_durable_for_both_providers(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = ContinuityReportStore(Path(temporary) / "reports.db")
            for provider in ("codex", "claude"):
                payload = incident(provider)
                payload.update({
                    "transcript": "private transcript canary",
                    "credential": "private credential canary",
                    "repository": "/private/repository/canary",
                    "screenshot": "private screenshot canary",
                    "raw_log": "private raw-log canary",
                    "external_data": "private external-data canary",
                })
                report, created = store.record_unresolved(payload, "circuit_open")

                self.assertTrue(created)
                self.assertEqual(report["status"], "unresolved")
                self.assertEqual(report["incident"]["provider"], provider)
                self.assertEqual(report["proposals"][0]["state"], "draft")
                self.assertEqual(report["redaction_count"], 6)
                serialized = json.dumps(report, sort_keys=True).lower()
                for canary in (
                    "private transcript", "private credential", "/private/repository",
                    "private screenshot", "private raw-log", "private external-data",
                ):
                    self.assertNotIn(canary, serialized)

                reopened = ContinuityReportStore(Path(temporary) / "reports.db")
                repeated, duplicate_created = reopened.record_unresolved(
                    payload, "circuit_open"
                )
                self.assertFalse(duplicate_created)
                self.assertEqual(repeated["report_id"], report["report_id"])

    def test_restored_result_cannot_create_an_unresolved_report(self):
        with self.assertRaisesRegex(ValueError, "unresolved recovery result"):
            build_report(incident(), "restored")

    def test_daemon_records_unresolved_result_before_canonical_handoff(self):
        with tempfile.TemporaryDirectory() as temporary:
            daemon = Daemon.__new__(Daemon)
            daemon.continuity_reports = ContinuityReportStore(Path(temporary) / "reports.db")
            with patch("orchestrator.socket.socket", side_effect=OSError("no bridge")):
                daemon._publish_continuity_resume(incident(), "provider_failed")

            expected = build_report(incident(), "provider_failed")["report_id"]
            self.assertIsNotNone(daemon.continuity_reports.get(expected))

    def test_proposals_require_individual_acceptance_and_commit_backlog_without_dispatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = self.make_repo(root / "repo")
            daemon = self.make_daemon(root / "reports.db", root / "registry.json", repo)
            report, _ = daemon.continuity_reports.record_unresolved(
                incident(), "circuit_open",
                proposals=[self.proposal(), {**self.proposal(), "title": "Second fix"}],
            )
            first, second = report["proposals"]

            edited = daemon.review_continuity_proposal(
                report_id=report["report_id"],
                proposal_id=first["id"],
                decision="edit",
                updates={"title": "Refined permanent fix"},
            )
            self.assertEqual(
                edited["report"]["proposals"][0]["draft"]["title"],
                "Refined permanent fix",
            )
            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())

            accepted = daemon.review_continuity_proposal(
                report_id=report["report_id"],
                proposal_id=first["id"],
                decision="accept",
                target_repo_path=str(repo),
            )
            ticket_id = accepted["committed"][0]["ticket_id"]
            ticket = read_ticket(repo / ".orchestrator" / f"{ticket_id}.md")
            self.assertEqual(ticket["status"], "backlog")
            self.assertIsNone(ticket["run_id"])
            self.assertIn(report["report_id"], ticket["body"])
            self.assertEqual(accepted["report"]["proposals"][0]["state"], "accepted")
            self.assertEqual(accepted["report"]["proposals"][1]["state"], "draft")

            duplicate = daemon.review_continuity_proposal(
                report_id=report["report_id"],
                proposal_id=first["id"],
                decision="accept",
                target_repo_path=str(repo),
            )
            self.assertTrue(duplicate["duplicate"])
            self.assertEqual(len(list((repo / ".orchestrator").glob("RR-1.md"))), 1)
            self.assertEqual(second["state"], "draft")

    @staticmethod
    def proposal() -> dict:
        return {
            "title": "Fix provider continuity",
            "description": "Correct the provider continuity defect.",
            "acceptance_criteria": ["Both provider regressions pass."],
            "priority": "high",
            "depends_on": [],
            "worker_model": "strong",
            "worker_effort": "high",
            "worker_sizing_rationale": "Provider lifecycle behavior is safety critical.",
            "worker_provider_notes": "Codex and Claude preserve the same outcome.",
        }

    @staticmethod
    def make_daemon(path: Path, registry: Path, repo: Path) -> Daemon:
        registry.write_text(json.dumps({
            "projects": [{"id": str(repo), "repoPath": str(repo)}],
        }))
        daemon = Daemon.__new__(Daemon)
        daemon.continuity_reports = ContinuityReportStore(path)
        daemon.program_registry_path = registry
        daemon._ticket_authoring_lock = threading.Lock()
        daemon._orchestrator_action_request_ids = set()
        daemon.orchestrator_commands = None
        return daemon

    @staticmethod
    def make_repo(path: Path) -> Path:
        path.mkdir()
        subprocess.run(["git", "-C", str(path), "init", "-b", "main"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(path), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(path), "config", "user.name", "Test"], check=True)
        (path / ".orchestrator").mkdir()
        (path / ".orchestrator/config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
        (path / "README.md").write_text("fixture\n")
        subprocess.run(
            ["git", "-C", str(path), "add", ".orchestrator/config.toml", "README.md"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(path), "commit", "-m", "initial"],
            check=True,
            capture_output=True,
        )
        return path


if __name__ == "__main__":
    unittest.main()
