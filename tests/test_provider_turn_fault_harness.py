from __future__ import annotations

import math
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from provider_turn_fault_harness import (  # noqa: E402
    DIAGNOSTIC_FIELDS,
    LIFECYCLE_BOUNDARIES,
    PYTHON_RESTART_COMPONENTS,
    PROVIDERS,
    RESTART_COMPONENTS,
    _observed_latency_ms,
    _percentile,
    _same_invariant_value,
    run_fault_matrix,
)
import voice_bridge  # noqa: E402


def swift_evidence():
    return {
        "adapter": "RelayVoiceCommandDelivery",
        "providers": list(PROVIDERS),
        "lifecycle_boundaries": list(LIFECYCLE_BOUNDARIES),
        "case_count": len(PROVIDERS) * len(LIFECYCLE_BOUNDARIES),
        "passed": True,
    }


class ProviderTurnFaultHarnessTests(unittest.TestCase):
    def test_restart_and_revocation_matrix_is_lossless_for_both_providers(self):
        with (
            tempfile.TemporaryDirectory() as temp_dir,
            mock.patch.object(voice_bridge, "_publish_authoritative_preview") as preview,
        ):
            report = run_fault_matrix(Path(temp_dir), swift_evidence=swift_evidence())

        self.assertTrue(report["passed"], report["violations"])
        preview.assert_not_called()
        self.assertEqual(report["providers"], ["codex", "claude"])
        self.assertEqual(
            report["normal_scenario_count"],
            len(PROVIDERS) * len(RESTART_COMPONENTS) * len(LIFECYCLE_BOUNDARIES),
        )
        self.assertEqual(report["restart_recovery_count"], report["normal_scenario_count"])
        self.assertEqual(
            report["delayed_acknowledgement_scenario_count"],
            len(PROVIDERS) * len(PYTHON_RESTART_COMPONENTS),
        )
        self.assertEqual(
            report["revocation_scenario_count"],
            len(PROVIDERS) * len(LIFECYCLE_BOUNDARIES),
        )
        self.assertEqual(report["replacement_scenario_count"], len(PROVIDERS) * 2)
        self.assertEqual(
            report["acknowledgement_to_playback_sample_count"],
            report["python_scenario_count"],
        )
        self.assertIsNotNone(report["acknowledgement_to_playback_p95_ms"])
        self.assertLessEqual(report["acknowledgement_to_playback_p95_ms"], 500)
        self.assertEqual(report["violations"], [])

    def test_invariant_counts_reject_boolean_values(self):
        self.assertFalse(_same_invariant_value(1, True))
        self.assertFalse(_same_invariant_value(0, False))
        self.assertTrue(_same_invariant_value(1, 1))

    def test_latency_rejects_boolean_and_non_finite_timestamps(self):
        self.assertIsNone(_observed_latency_ms(True, 2.0))
        self.assertIsNone(_observed_latency_ms(1.0, False))
        for invalid in (math.nan, math.inf, -math.inf):
            with self.subTest(invalid=invalid):
                self.assertIsNone(_observed_latency_ms(invalid, 2.0))
                self.assertIsNone(_observed_latency_ms(1.0, invalid))
                self.assertIsNone(_percentile([100.0, invalid], 95))

    def test_failure_diagnostics_have_a_bounded_privacy_safe_shape(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = run_fault_matrix(Path(temp_dir), swift_evidence=swift_evidence())

        self.assertLessEqual(len(report["violations"]), 100)
        for diagnostic in report["violations"]:
            self.assertEqual(set(diagnostic), DIAGNOSTIC_FIELDS)
            serialized = str(diagnostic).lower()
            self.assertNotIn("prompt", serialized)
            self.assertNotIn("transcript", serialized)
            self.assertNotIn(temp_dir.lower(), serialized)


if __name__ == "__main__":
    unittest.main()
