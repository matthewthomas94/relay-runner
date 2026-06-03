from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from orchestrator import derive_codex_activity  # noqa: E402


class CodexActivityTests(unittest.TestCase):
    def command_activity(self, command: str) -> str:
        return derive_codex_activity({
            "type": "command_execution",
            "command": command,
            "aggregated_output": "",
            "exit_code": None,
            "status": "in_progress",
        })

    def test_command_execution_unwraps_shell_file_reads(self):
        activity = self.command_activity(
            "/bin/zsh -lc \"sed -n '1,220p' .orchestrator/RR-26.md\""
        )

        self.assertEqual(activity, "Reading source files")

    def test_command_execution_summarizes_builds_and_git(self):
        cases = {
            "/bin/zsh -lc 'swift build'": "Running Swift build",
            "/bin/zsh -lc 'git status --short --branch'": "Checking git status",
            "/bin/zsh -lc 'git diff -- services/orchestrator.py'": "Inspecting git changes",
            "/bin/zsh -lc 'git log --oneline -3'": "Inspecting git changes",
        }

        for command, expected in cases.items():
            with self.subTest(command=command):
                self.assertEqual(self.command_activity(command), expected)

    def test_file_change_summarizes_source_and_ticket_updates(self):
        source_activity = derive_codex_activity({
            "type": "file_change",
            "changes": [{"path": "/repo/services/orchestrator.py", "kind": "update"}],
            "status": "in_progress",
        })
        ticket_activity = derive_codex_activity({
            "type": "file_change",
            "changes": [{"path": "/repo/.orchestrator/RR-26.md", "kind": "update"}],
            "status": "in_progress",
        })

        self.assertEqual(source_activity, "Editing source files")
        self.assertEqual(ticket_activity, "Updating ticket run log")


if __name__ == "__main__":
    unittest.main()
