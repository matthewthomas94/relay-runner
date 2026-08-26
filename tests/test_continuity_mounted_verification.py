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
            self.assertIn(scenario["classification"], {"stalled", "recurring"})
            self.assertEqual(scenario["broker_status"], "applied")
            self.assertGreaterEqual(scenario["stable_health_seconds"], 60)
            self.assertEqual(scenario["continuity_resume_action"], "reattach")
            self.assertTrue(scenario["command_lifecycle_complete"])
            self.assertTrue(scenario["provider_acknowledged"])
            self.assertTrue(scenario["afplay_started"])
            self.assertTrue(scenario["audible_playback_attested"])
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

    def test_healthy_speech_command_audio_without_recovery_cannot_pass(self):
        continuity, speech, delivery = self.evidence()
        recovery_proof_events = {
            "incident_classified",
            "continuity_agent_launched",
            "broker_result",
            "continuity_agent_completed",
            "continuity_resume",
        }
        healthy_only = [
            item for item in continuity if item["event"] not in recovery_proof_events
        ]

        report = mounted.build_mounted_report(
            self.signature(),
            healthy_only,
            speech,
            delivery,
            physical_audio_attested=True,
        )

        self.assertEqual(report["status"], "verification_blocked")
        self.assertEqual(report["mounted_app_evidence"]["provider_scenarios"], [])
        self.assertIn("provider_scenario_missing:codex", report["blocker_codes"])
        self.assertIn("provider_scenario_missing:claude", report["blocker_codes"])

    def test_mixed_generation_and_provider_recovery_evidence_fail_closed(self):
        continuity, speech, delivery = self.evidence()
        mixed_generation = [dict(item) for item in continuity]
        broker = next(
            item for item in mixed_generation
            if item["provider"] == "codex" and item["event"] == "broker_result"
        )
        broker["recovery_generation"] = "stale-generation"

        report = mounted.build_mounted_report(
            self.signature(),
            mixed_generation,
            speech,
            delivery,
            physical_audio_attested=True,
        )
        self.assertIn("provider_scenario_missing:codex", report["blocker_codes"])
        self.assertNotIn("provider_scenario_missing:claude", report["blocker_codes"])

        continuity, speech, delivery = self.evidence()
        mixed_provider = [dict(item) for item in continuity]
        handoff = next(
            item for item in mixed_provider
            if item["provider"] == "codex" and item["event"] == "continuity_resume"
        )
        handoff["provider"] = "claude"

        report = mounted.build_mounted_report(
            self.signature(),
            mixed_provider,
            speech,
            delivery,
            physical_audio_attested=True,
        )
        self.assertIn("provider_scenario_missing:codex", report["blocker_codes"])

        continuity, speech, delivery = self.evidence()
        mismatched_audio = [dict(item) for item in continuity]
        audible = next(
            item for item in mismatched_audio
            if item["provider"] == "codex"
            and item["event"] == "audible_playback_attested"
        )
        audible["utterance_id"] = "utterance-from-stale-recovery"
        report = mounted.build_mounted_report(
            self.signature(),
            mismatched_audio,
            speech,
            delivery,
            physical_audio_attested=True,
        )
        self.assertIn("provider_scenario_missing:codex", report["blocker_codes"])

    @staticmethod
    def signature():
        return {
            "verified": True,
            "developer_id": True,
            "team_identifier": "TEAM123",
            "bundle_identifier": "com.relayrunner.app",
        }

    @staticmethod
    def evidence():
        continuity = []
        speech = []
        delivery = []
        for index, provider in enumerate(("codex", "claude"), start=1):
            relay_command_id = f"command-{provider}"
            command = {
                "provider": provider,
                "scenario_id": f"mounted-{provider}",
                "relay_command_seq": index,
                "relay_command_id": relay_command_id,
            }
            recovery = {
                "recovery_generation": f"generation-{provider}",
                "incident_id": f"inc-{index:012x}",
                "session_id": f"session-{index:024x}",
                "command_id": mounted._opaque_command_id(relay_command_id),
            }
            process_identity = f"continuity-{index:032x}"
            continuity.extend(
                [{**command, "event": event} for event in (
                    "speech_captured", "transcript_captured",
                    "command_accepted", "command_completed",
                )]
            )
            continuity.extend([
                {
                    **command,
                    **recovery,
                    "event": "incident_classified",
                    "classification": "stalled",
                    "health": "unavailable",
                },
                {
                    **command,
                    **recovery,
                    "event": "continuity_agent_launched",
                    "process_identity": process_identity,
                },
                {
                    **command,
                    **recovery,
                    "event": "broker_result",
                    "process_identity": process_identity,
                    "broker_outcome": {
                        "capability": "check_processing_health",
                        "status": "applied",
                        "outcome_code": "processing_restored",
                        "health": {
                            "objective_restored": True,
                            "stable_for_seconds": 60,
                            "evidence_codes": ["command_progress_observed"],
                        },
                    },
                },
                {
                    **command,
                    **recovery,
                    "event": "continuity_agent_completed",
                    "process_identity": process_identity,
                    "final_result": "restored",
                },
                {
                    **command,
                    **recovery,
                    "event": "continuity_resume",
                    "actor_role": "canonical_bridge",
                    "final_result": "restored",
                    "action": "reattach",
                },
                {
                    **command,
                    **recovery,
                    "event": "audible_playback_attested",
                    "audible": True,
                    "play_request_id": f"play-{provider}",
                    "utterance_id": f"utterance-{provider}",
                },
            ])
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
                "authoritative": True,
                "kind": "final",
                "source": "orchestrator",
                "lifecycle_role": "result",
                "relay_command_seq": index,
                "relay_command_id": f"command-{provider}",
            })
        return continuity, speech, delivery


if __name__ == "__main__":
    unittest.main()
