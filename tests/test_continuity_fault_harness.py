from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

from continuity_fault_harness import FAULT_CASES, run_fault_matrix  # noqa: E402


class ContinuityFaultHarnessTests(unittest.TestCase):
    def test_complete_fault_matrix_restores_or_escalates_without_duplicate_effects(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = run_fault_matrix(Path(temporary))

        self.assertTrue(report["passed"])
        self.assertEqual(report["providers"], ["codex", "claude"])
        self.assertEqual(report["case_count"], len(FAULT_CASES))
        self.assertEqual(
            {case["name"] for case in report["cases"]},
            {
                "transcription_dropout", "capture_interruption", "bridge_loss",
                "messenger_crash", "foreground_codex_hang", "foreground_codex_exit",
                "foreground_claude_hang", "foreground_claude_exit", "daemon_loss",
                "ipc_loss", "stale_session_ownership", "configured_provider_fallback",
                "simultaneous_component_faults", "recovery_budget_exhaustion",
            },
        )
        self.assertTrue(all(report["invariants"].values()))

        recoverable = [
            case for case in report["cases"] if case["final_result"] == "restored"
        ]
        self.assertTrue(all(case["classification"] == "stalled" for case in recoverable))
        self.assertTrue(all(case["agent_launch"] == "launched" for case in recoverable))
        self.assertTrue(all(case["broker_action_count"] == 1 for case in recoverable))
        self.assertTrue(all(case["restored_health"] for case in recoverable))
        self.assertTrue(all(case["continued_without_session_restart"] for case in recoverable))

        pretranscript = {
            case["name"]: case for case in report["cases"]
            if case["name"] in {"transcription_dropout", "capture_interruption"}
        }
        self.assertTrue(all(case["handoff_action"] == "ask_repeat" for case in pretranscript.values()))
        self.assertTrue(all(case["tts_count"] == 1 for case in pretranscript.values()))

        fallback = next(
            case for case in report["cases"]
            if case["name"] == "configured_provider_fallback"
        )
        self.assertEqual((fallback["provider"], fallback["agent_provider"]), ("codex", "claude"))
        simultaneous = next(
            case for case in report["cases"]
            if case["name"] == "simultaneous_component_faults"
        )
        self.assertEqual(simultaneous["simultaneous_second_launch"], "single_flight")

        exhausted = next(
            case for case in report["cases"]
            if case["name"] == "recovery_budget_exhaustion"
        )
        self.assertEqual(exhausted["handoff_action"], "foreground_review")
        self.assertTrue(exhausted["unresolved_report_persisted"])
        self.assertEqual(exhausted["proposal_state"], "draft")


if __name__ == "__main__":
    unittest.main()
