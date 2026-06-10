from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from command_actions import (  # noqa: E402
    CONTROL_COMMANDS,
    classify_command,
    format_command_for_agent,
    resolve_command_action,
)


class CommandActionsTests(unittest.TestCase):
    def test_internal_controls_are_no_ticket_actions(self):
        for command, reason in CONTROL_COMMANDS.items():
            with self.subTest(command=command):
                action = classify_command(command)

                self.assertEqual(action.kind, "control")
                self.assertFalse(action.requires_ticket)
                self.assertIsNone(action.ticket_id)
                self.assertEqual(action.reason, reason)
                self.assertEqual(format_command_for_agent(action), command)

    def test_new_project_work_creates_backlog_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            orch = repo / ".orchestrator"
            orch.mkdir()
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')

            action = resolve_command_action("fix the login retry bug", repo_path=repo)

            self.assertEqual(action.kind, "create_ticket")
            self.assertEqual(action.ticket_id, "RR-3")
            self.assertTrue((orch / "RR-3.md").is_file())
            self.assertIn("status: backlog", (orch / "RR-3.md").read_text())
            self.assertIn("> fix the login retry bug", (orch / "RR-3.md").read_text())
            self.assertEqual((orch / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 4\n')

            prompt = format_command_for_agent(action)
            self.assertIn("action: create_ticket", prompt)
            self.assertIn("ticket_id: RR-3", prompt)
            self.assertIn("Do not perform substantive source-code implementation directly", prompt)

    def test_existing_ticket_dispatch_attaches_to_ticket(self):
        action = classify_command("dispatch rr-7 to a worker")

        self.assertEqual(action.kind, "dispatch_ticket")
        self.assertTrue(action.requires_ticket)
        self.assertEqual(action.ticket_id, "RR-7")
        self.assertIn("action: dispatch_ticket", format_command_for_agent(action))

    def test_existing_ticket_update_attaches_to_ticket(self):
        action = classify_command("update RR-8 with the auth context")

        self.assertEqual(action.kind, "update_ticket")
        self.assertTrue(action.requires_ticket)
        self.assertEqual(action.ticket_id, "RR-8")

    def test_work_without_project_waits_on_target_choice(self):
        with tempfile.TemporaryDirectory() as tmp:
            action = resolve_command_action("implement the sidebar", repo_path=tmp)

            self.assertEqual(action.kind, "needs_project")
            self.assertTrue(action.requires_ticket)
            self.assertIsNone(action.ticket_id)
            self.assertIn("waiting on target-project choice", format_command_for_agent(action))


if __name__ == "__main__":
    unittest.main()

