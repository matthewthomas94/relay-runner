from __future__ import annotations

import importlib.util
import math
import os
import unittest


ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT = os.path.join(ROOT, "scripts", "speech-latency-report.py")
SPEC = importlib.util.spec_from_file_location("speech_latency_report", SCRIPT)
speech_latency_report = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(speech_latency_report)

AUTHORITATIVE_FINAL = {
    "authoritative": True,
    "kind": "final",
    "source": "orchestrator",
    "lifecycle_role": "result",
}


class SpeechLatencyReportTests(unittest.TestCase):
    def test_report_correlates_terminal_acknowledgement_to_privacy_safe_playback(self):
        speech_records = []
        delivery_records = []
        for index, (provider, latency_ms) in enumerate(
            (("codex", 180), ("claude", 220), ("codex", 420)),
            start=1,
        ):
            acknowledged_at = 1_000.0 + index * 10
            command = {
                "relay_command_seq": index,
                "relay_command_id": f"cmd-{index}",
            }
            request = {**command, "play_request_id": f"play-{index}"}
            utterance = {**request, "utterance_id": f"utt-{index}"}
            delivery_records.append({
                "event": "provider_acknowledged",
                "timestamp": acknowledged_at,
                "provider": provider,
                **command,
            })
            speech_records.extend([
                {
                    "event": "accepted",
                    "at": acknowledged_at + 0.005,
                    **AUTHORITATIVE_FINAL,
                    **utterance,
                },
                {"event": "option_detected", "at": acknowledged_at + 0.01, **request},
                {"event": "tts_preparing", "at": acknowledged_at + 0.02, **utterance},
                {"event": "first_wav_ready", "at": acknowledged_at + 0.12, **utterance},
                {
                    "event": "afplay_started",
                    "at": acknowledged_at + latency_ms / 1_000,
                    **AUTHORITATIVE_FINAL,
                    **utterance,
                },
            ])

        report = speech_latency_report.build_report(speech_records, delivery_records)

        self.assertEqual(report["sample_count"], 3)
        self.assertEqual(report["provider_sample_counts"], {"codex": 2, "claude": 1})
        self.assertEqual(report["ack_to_first_audio_p95_ms"], 420.0)
        self.assertEqual(report["provider_ack_to_first_audio_p95_ms"], 420.0)
        self.assertEqual(report["realization_trigger_to_first_audio_p95_ms"], 410.0)
        self.assertEqual(report["option_to_first_audio_p95_ms"], 410.0)
        self.assertEqual(report["samples"][0]["realization_trigger_event"], "option_detected")
        self.assertEqual(report["samples"][0]["play_request_id"], "play-1")
        self.assertEqual(report["samples"][0]["utterance_id"], "utt-1")
        self.assertNotIn("text", report["samples"][0])

    def test_report_accepts_mounted_resume_without_option_gesture(self):
        identifiers = {
            "relay_command_seq": 12,
            "relay_command_id": "mounted-resume",
        }
        report = speech_latency_report.build_report(
            [
                {
                    "event": "accepted",
                    "at": 50.010,
                    "play_request_id": "play-resume",
                    "utterance_id": "utterance-resume",
                    **AUTHORITATIVE_FINAL,
                    **identifiers,
                },
                {
                    "event": "afplay_started",
                    "at": 50.420,
                    "play_request_id": "play-resume",
                    "utterance_id": "utterance-resume",
                    **AUTHORITATIVE_FINAL,
                    **identifiers,
                },
            ],
            [{
                "event": "provider_acknowledged",
                "timestamp": 50.0,
                "provider": "claude",
                **identifiers,
            }],
        )

        self.assertEqual(report["sample_count"], 1)
        self.assertEqual(report["ack_to_first_audio_p95_ms"], 420.0)
        self.assertEqual(report["realization_trigger_to_first_audio_p95_ms"], 410.0)
        self.assertIsNone(report["option_to_first_audio_p95_ms"])
        self.assertEqual(report["samples"][0]["realization_trigger_event"], "accepted")

    def test_automatic_playback_ignores_non_authoritative_acceptance(self):
        identifiers = {
            "relay_command_seq": 12,
            "relay_command_id": "mounted-resume",
            "play_request_id": "play-resume",
            "utterance_id": "utterance-resume",
        }
        report = speech_latency_report.build_report(
            [
                {
                    "event": "accepted",
                    "at": 50.010,
                    "authoritative": False,
                    "kind": "handoff",
                    "source": "messenger",
                    "lifecycle_role": "conversation",
                    **identifiers,
                },
                {
                    "event": "afplay_started",
                    "at": 50.420,
                    **AUTHORITATIVE_FINAL,
                    **identifiers,
                },
            ],
            [{
                "event": "provider_acknowledged",
                "timestamp": 50.0,
                "provider": "claude",
                "relay_command_seq": 12,
                "relay_command_id": "mounted-resume",
            }],
        )

        self.assertEqual(report["sample_count"], 1)
        self.assertIsNone(report["realization_trigger_to_first_audio_p95_ms"])
        self.assertIsNone(report["samples"][0]["realization_trigger"])

    def test_queue_wait_is_not_counted_as_playback_realization_latency(self):
        command = {
            "relay_command_seq": 7,
            "relay_command_id": "queued-command",
        }
        request = {**command, "play_request_id": "queued-play"}
        utterance = {**request, "utterance_id": "queued-utterance"}
        report = speech_latency_report.build_report(
            [
                {"event": "accepted", "at": 12.0, **AUTHORITATIVE_FINAL, **utterance},
                {"event": "option_detected", "at": 42.0, **request},
                {
                    "event": "afplay_started",
                    "at": 42.011,
                    **AUTHORITATIVE_FINAL,
                    **utterance,
                },
            ],
            [{
                "event": "provider_acknowledged",
                "timestamp": 10.0,
                "provider": "codex",
                **command,
            }],
        )

        self.assertEqual(report["sample_count"], 1)
        self.assertEqual(report["provider_ack_to_first_audio_p95_ms"], 32_011.0)
        self.assertEqual(report["realization_trigger_to_first_audio_p95_ms"], 11.0)
        self.assertEqual(report["samples"][0]["realization_trigger_event"], "option_detected")

    def test_report_rejects_incomplete_duplicate_and_non_finite_evidence(self):
        identifiers = {
            "relay_command_seq": 1,
            "relay_command_id": "cmd-invalid",
            "play_request_id": "play-invalid",
            "utterance_id": "utterance-invalid",
        }
        acknowledgement = {
            "event": "provider_acknowledged",
            "timestamp": 10.0,
            "provider": "codex",
            "relay_command_seq": 1,
            "relay_command_id": "cmd-invalid",
        }
        playback = {
            "event": "afplay_started",
            "at": 10.2,
            **AUTHORITATIVE_FINAL,
            **identifiers,
        }

        self.assertEqual(
            speech_latency_report.build_report([playback], [acknowledgement, acknowledgement])[
                "sample_count"
            ],
            0,
        )
        self.assertEqual(
            speech_latency_report.build_report([playback, playback], [acknowledgement])[
                "sample_count"
            ],
            0,
        )
        for invalid in (True, math.nan, math.inf, -math.inf):
            with self.subTest(invalid=invalid):
                invalid_playback = {**playback, "at": invalid}
                invalid_acknowledgement = {**acknowledgement, "timestamp": invalid}
                self.assertEqual(
                    speech_latency_report.build_report(
                        [invalid_playback], [acknowledgement]
                    )["sample_count"],
                    0,
                )
                self.assertEqual(
                    speech_latency_report.build_report(
                        [playback], [invalid_acknowledgement]
                    )["sample_count"],
                    0,
                )
                self.assertIsNone(
                    speech_latency_report._percentile([100.0, invalid], 95)
                )

    def test_report_rejects_distinct_playback_identities_for_one_command(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                command = {
                    "relay_command_seq": 1,
                    "relay_command_id": f"cmd-{provider}",
                }
                acknowledgement = {
                    "event": "provider_acknowledged",
                    "timestamp": 10.0,
                    "provider": provider,
                    **command,
                }
                playbacks = [
                    {
                        "event": "afplay_started",
                        "at": 10.2 + index / 10,
                        "play_request_id": f"play-{provider}-{index}",
                        "utterance_id": f"utterance-{provider}-{index}",
                        **AUTHORITATIVE_FINAL,
                        **command,
                    }
                    for index in range(2)
                ]

                report = speech_latency_report.build_report(
                    playbacks,
                    [acknowledgement],
                )

                self.assertEqual(report["sample_count"], 0)
                self.assertEqual(
                    report["provider_sample_counts"],
                    {"codex": 0, "claude": 0},
                )
                self.assertIsNone(report["ack_to_first_audio_p95_ms"])

    def test_report_rejects_boolean_command_sequence_and_unknown_provider(self):
        speech = [{
            "event": "afplay_started",
            "at": 10.2,
            "relay_command_seq": True,
            "relay_command_id": "cmd-bool",
            "play_request_id": "play-bool",
            "utterance_id": "utterance-bool",
            **AUTHORITATIVE_FINAL,
        }]
        delivery = [{
            "event": "provider_acknowledged",
            "timestamp": 10.0,
            "provider": "codex",
            "relay_command_seq": True,
            "relay_command_id": "cmd-bool",
        }]
        self.assertEqual(
            speech_latency_report.build_report(speech, delivery)["sample_count"],
            0,
        )
        speech[0]["relay_command_seq"] = 1
        delivery[0]["relay_command_seq"] = 1
        delivery[0]["provider"] = "other"
        self.assertEqual(
            speech_latency_report.build_report(speech, delivery)["sample_count"],
            0,
        )

    def test_report_selects_authoritative_final_without_counting_handoff(self):
        command = {
            "relay_command_seq": 10,
            "relay_command_id": "mounted-command",
        }
        acknowledgement = {
            "event": "provider_acknowledged",
            "timestamp": 20.0,
            "provider": "codex",
            **command,
        }
        handoff = {
            "event": "afplay_started",
            "at": 23.365099,
            "play_request_id": "play-handoff",
            "utterance_id": "utterance-handoff",
            "authoritative": False,
            "kind": "handoff",
            "source": "messenger",
            "lifecycle_role": "acknowledgement",
            **command,
        }
        final = {
            "event": "afplay_started",
            "at": 20.420,
            "play_request_id": "play-final",
            "utterance_id": "utterance-final",
            **AUTHORITATIVE_FINAL,
            **command,
        }
        accepted = {
            **final,
            "event": "accepted",
            "at": 20.010,
        }

        report = speech_latency_report.build_report(
            [handoff, accepted, final],
            [acknowledgement],
        )

        self.assertEqual(report["sample_count"], 1)
        sample = report["samples"][0]
        self.assertEqual(sample["ack_to_first_audio_ms"], 420.0)
        self.assertEqual(sample["realization_trigger_to_first_audio_ms"], 410.0)
        self.assertEqual(sample["relay_command_seq"], 10)
        self.assertEqual(sample["relay_command_id"], "mounted-command")
        self.assertEqual(sample["play_request_id"], "play-final")
        self.assertEqual(sample["utterance_id"], "utterance-final")
        self.assertTrue(sample["authoritative"])
        self.assertEqual(sample["kind"], "final")
        self.assertEqual(sample["source"], "orchestrator")
        self.assertEqual(sample["lifecycle_role"], "result")

        self.assertEqual(
            speech_latency_report.build_report([handoff], [acknowledgement])["sample_count"],
            0,
        )

    def test_report_rejects_duplicate_authoritative_playback_but_not_conversation(self):
        command = {
            "relay_command_seq": 4,
            "relay_command_id": "duplicate-authoritative",
        }
        acknowledgement = {
            "event": "provider_acknowledged",
            "timestamp": 40.0,
            "provider": "claude",
            **command,
        }
        final = {
            "event": "afplay_started",
            "at": 40.2,
            "play_request_id": "play-final",
            "utterance_id": "utterance-final",
            **AUTHORITATIVE_FINAL,
            **command,
        }
        duplicate = {
            **final,
            "at": 40.3,
            "play_request_id": "play-duplicate",
            "utterance_id": "utterance-duplicate",
        }
        incomplete_duplicate = {
            key: value
            for key, value in duplicate.items()
            if key not in {"play_request_id", "utterance_id"}
        }
        conversation = {
            **final,
            "at": 40.1,
            "play_request_id": "play-conversation",
            "utterance_id": "utterance-conversation",
            "authoritative": False,
            "kind": "conversation",
            "source": "messenger",
            "lifecycle_role": "conversation",
        }

        self.assertEqual(
            speech_latency_report.build_report(
                [conversation, final],
                [acknowledgement],
            )["sample_count"],
            1,
        )
        self.assertEqual(
            speech_latency_report.build_report(
                [conversation, final, duplicate],
                [acknowledgement],
            )["sample_count"],
            0,
        )
        self.assertEqual(
            speech_latency_report.build_report(
                [conversation, final, incomplete_duplicate],
                [acknowledgement],
            )["sample_count"],
            0,
        )


if __name__ == "__main__":
    unittest.main()
