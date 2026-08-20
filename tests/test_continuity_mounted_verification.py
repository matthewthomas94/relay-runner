from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "continuity-mounted-verification.py"
SPEC = importlib.util.spec_from_file_location("continuity_mounted_verification", SCRIPT)
mounted = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(mounted)


class ContinuityMountedVerificationTests(unittest.TestCase):
    def test_signed_provider_matrix_correlates_lifecycle_and_keeps_physical_gate_separate(self):
        continuity, speech, delivery = self.evidence()
        signature = {
            "verified": True,
            "developer_id": True,
            "team_identifier": "TEAM123",
            "bundle_identifier": "com.relayrunner.app",
        }

        report = mounted.build_mounted_report(
            signature, continuity, speech, delivery
        )

        self.assertEqual(report["status"], "verification_blocked")
        self.assertEqual(report["mounted_app_evidence"]["status"], "passed")
        self.assertEqual(report["physical_audio_evidence"]["status"], "blocked")
        self.assertIn("physical_audio_attestation_missing", report["blocker_codes"])
        self.assertEqual(
            {item["provider"] for item in report["mounted_app_evidence"]["provider_scenarios"]},
            {"codex", "claude"},
        )
        for scenario in report["mounted_app_evidence"]["provider_scenarios"]:
            self.assertTrue(scenario["command_lifecycle_complete"])
            self.assertTrue(scenario["provider_acknowledged"])
            self.assertTrue(scenario["afplay_started"])
            self.assertTrue(scenario["play_request_id"])
            self.assertTrue(scenario["utterance_id"])

        attested = mounted.build_mounted_report(
            signature,
            continuity,
            speech,
            delivery,
            physical_audio_attested=True,
        )
        self.assertEqual(attested["status"], "passed")

    def test_missing_provider_duplicate_playback_and_adhoc_signature_fail_closed(self):
        continuity, speech, delivery = self.evidence()
        continuity = [item for item in continuity if item["provider"] == "codex"]
        speech.append(dict(speech[-1]))
        report = mounted.build_mounted_report(
            {
                "verified": True,
                "developer_id": False,
                "team_identifier": None,
                "bundle_identifier": "com.relayrunner.app",
            },
            continuity,
            speech,
            delivery,
            physical_audio_attested=True,
        )

        self.assertEqual(report["mounted_app_evidence"]["status"], "blocked")
        self.assertIn("provider_scenario_missing:claude", report["blocker_codes"])
        self.assertIn("developer_id_signature_missing", report["blocker_codes"])

        continuity, speech, delivery = self.evidence()
        duplicate_lifecycle = next(
            item for item in continuity
            if item["provider"] == "codex" and item["event"] == "command_accepted"
        )
        continuity.append(dict(duplicate_lifecycle))
        duplicate = mounted.build_mounted_report(
            {
                "verified": True,
                "developer_id": True,
                "team_identifier": "TEAM123",
                "bundle_identifier": "com.relayrunner.app",
            },
            continuity,
            speech,
            delivery,
            physical_audio_attested=True,
        )
        self.assertIn("provider_scenario_missing:codex", duplicate["blocker_codes"])

    @staticmethod
    def evidence():
        continuity = []
        speech = []
        delivery = []
        for index, provider in enumerate(("codex", "claude"), start=1):
            command = {
                "provider": provider,
                "scenario_id": f"mounted-{provider}",
                "relay_command_seq": index,
                "relay_command_id": f"command-{provider}",
            }
            continuity.extend(
                [{**command, "event": event} for event in (
                    "speech_captured", "transcript_captured",
                    "command_accepted", "command_completed",
                )]
            )
            delivery.append({
                "event": "provider_acknowledged",
                "timestamp": 100.0 + index,
                **{key: command[key] for key in (
                    "provider", "relay_command_seq", "relay_command_id",
                )},
            })
            speech.append({
                "event": "afplay_started",
                "at": 100.2 + index,
                "play_request_id": f"play-{provider}",
                "utterance_id": f"utterance-{provider}",
                "relay_command_seq": index,
                "relay_command_id": f"command-{provider}",
            })
        return continuity, speech, delivery


if __name__ == "__main__":
    unittest.main()
