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
                {"event": "option_detected", "at": acknowledged_at + 0.01, **request},
                {"event": "tts_preparing", "at": acknowledged_at + 0.02, **utterance},
                {"event": "first_wav_ready", "at": acknowledged_at + 0.12, **utterance},
                {
                    "event": "afplay_started",
                    "at": acknowledged_at + latency_ms / 1_000,
                    **utterance,
                },
            ])

        report = speech_latency_report.build_report(speech_records, delivery_records)

        self.assertEqual(report["sample_count"], 3)
        self.assertEqual(report["provider_sample_counts"], {"codex": 2, "claude": 1})
        self.assertEqual(report["ack_to_first_audio_p95_ms"], 420.0)
        self.assertEqual(report["option_to_first_audio_p95_ms"], 410.0)
        self.assertEqual(report["samples"][0]["play_request_id"], "play-1")
        self.assertEqual(report["samples"][0]["utterance_id"], "utt-1")
        self.assertNotIn("text", report["samples"][0])

    def test_report_accepts_mounted_resume_without_option_gesture(self):
        identifiers = {
            "relay_command_seq": 12,
            "relay_command_id": "mounted-resume",
        }
        report = speech_latency_report.build_report(
            [{
                "event": "afplay_started",
                "at": 50.420,
                "play_request_id": "play-resume",
                "utterance_id": "utterance-resume",
                **identifiers,
            }],
            [{
                "event": "provider_acknowledged",
                "timestamp": 50.0,
                "provider": "claude",
                **identifiers,
            }],
        )

        self.assertEqual(report["sample_count"], 1)
        self.assertEqual(report["ack_to_first_audio_p95_ms"], 420.0)
        self.assertIsNone(report["option_to_first_audio_p95_ms"])

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
        playback = {"event": "afplay_started", "at": 10.2, **identifiers}

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


if __name__ == "__main__":
    unittest.main()
