from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from provider_turn_fault_harness import (  # noqa: E402
    DIAGNOSTIC_FIELDS,
    LIFECYCLE_BOUNDARIES,
    PROVIDERS,
    RESTART_COMPONENTS,
    run_fault_matrix,
)


class ProviderTurnFaultHarnessTests(unittest.TestCase):
    def test_restart_and_revocation_matrix_is_lossless_for_both_providers(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = run_fault_matrix(Path(temp_dir))

        self.assertTrue(report["passed"], report["violations"])
        self.assertEqual(report["providers"], ["codex", "claude"])
        self.assertEqual(
            report["normal_scenario_count"],
            len(PROVIDERS) * len(RESTART_COMPONENTS) * len(LIFECYCLE_BOUNDARIES),
        )
        self.assertEqual(
            report["revocation_scenario_count"],
            len(PROVIDERS) * (len(LIFECYCLE_BOUNDARIES) - 1),
        )
        self.assertEqual(report["replacement_scenario_count"], len(PROVIDERS))
        self.assertLessEqual(report["acknowledgement_to_playback_p95_ms"], 500)
        self.assertEqual(report["violations"], [])

    def test_failure_diagnostics_have_a_bounded_privacy_safe_shape(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = run_fault_matrix(Path(temp_dir))

        self.assertLessEqual(len(report["violations"]), 100)
        for diagnostic in report["violations"]:
            self.assertEqual(set(diagnostic), DIAGNOSTIC_FIELDS)
            serialized = str(diagnostic).lower()
            self.assertNotIn("prompt", serialized)
            self.assertNotIn("transcript", serialized)
            self.assertNotIn(temp_dir.lower(), serialized)


if __name__ == "__main__":
    unittest.main()
