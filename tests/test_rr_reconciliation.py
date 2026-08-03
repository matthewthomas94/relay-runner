from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.fspath(ROOT / "services"))

from tickets import TicketParseError, parse, read as read_ticket  # noqa: E402


class RelayRecoveryReconciliationTests(unittest.TestCase):
    def ticket(self, ticket_id: str) -> dict:
        return read_ticket(ROOT / ".orchestrator" / f"{ticket_id}.md")

    def test_rr275_is_done_only_with_preserved_acceptance_evidence(self):
        ticket = self.ticket("RR-275")

        self.assertEqual(ticket["status"], "done")
        self.assertEqual(ticket["run_id"], 9)
        self.assertNotIn("- [ ]", ticket["body"])
        self.assertIn("**Run 8**", ticket["body"])
        self.assertIn("**Run 9**", ticket["body"])
        self.assertIn("224.2–314.5 ms", ticket["body"])
        self.assertIn("zero active records and no queued intents", ticket["body"])

    def test_verification_blocked_schema_requires_a_durable_run_link(self):
        contents = """---
id: RR-1
title: Blocked
status: verification_blocked
priority: high
depends_on: []
run_id: null
canceled: false
verification_blocker: Physical input unavailable.
verification_resume: Connect physical input and resume.
---
"""

        with self.assertRaisesRegex(TicketParseError, "requires run_id"):
            parse(contents)

    def test_rr274_remains_open_with_exact_physical_verification_blocker(self):
        ticket = self.ticket("RR-274")

        self.assertEqual(ticket["status"], "verification_blocked")
        self.assertEqual(ticket["run_id"], 7)
        self.assertIn("Screen Recording", ticket["verification_blocker"])
        self.assertIn("modifier-only Option", ticket["verification_blocker"])
        self.assertIn("physical HID", ticket["verification_blocker"])
        self.assertIn("explicitly resume RR-274", ticket["verification_resume"])
        self.assertIn("No post-repair mounted `started`/`played` evidence is claimed", ticket["body"])
        self.assertIn("foreground/background physical double-Option replay remains open", ticket["body"])

    def test_rr280_closes_recovery_without_claiming_physical_replay(self):
        ticket = self.ticket("RR-280")

        self.assertEqual(ticket["status"], "done")
        self.assertEqual(ticket["run_id"], 4)
        self.assertIn("No post-install `option_detected`, `started`, or `played` event exists", ticket["body"])
        self.assertIn("pre-repair daemon's run 1 remains terminal Failed", ticket["body"])
        self.assertIn("correctly requested retry because RR-274 declared preserved run 7", ticket["body"])
        self.assertIn("pruned only the now-throwaway native RR-280 worktree", ticket["body"])
        self.assertIn("never edits or resumes the ticket, dispatches work, or progresses dependencies", ticket["body"])
        self.assertIn("Those exact commits remain preserved on `recovery/rr-280-run3`", ticket["body"])
        self.assertIn("selected the stronger `1237a2e` repair for final review", ticket["body"])
        self.assertIn("## Superseded original acceptance criteria", ticket["body"])
        self.assertIn("## Coordinator-authorized recovery closure criteria", ticket["body"])
        self.assertIn("Run 4", ticket["body"])


if __name__ == "__main__":
    unittest.main()
