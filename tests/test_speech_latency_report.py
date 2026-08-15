from __future__ import annotations

import importlib.util
import os
import unittest


ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT = os.path.join(ROOT, "scripts", "speech-latency-report.py")
SPEC = importlib.util.spec_from_file_location("speech_latency_report", SCRIPT)
speech_latency_report = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(speech_latency_report)


class SpeechLatencyReportTests(unittest.TestCase):
    def test_report_correlates_privacy_safe_stage_breakdown(self):
        records = []
        for index, audio_ms in enumerate((900, 1_100, 2_900), start=1):
            base = 1_000.0 + index * 10
            command = {
                "relay_command_seq": index,
                "relay_command_id": f"cmd-{index}",
            }
            request = {**command, "play_request_id": f"play-{index}"}
            utterance = {**request, "utterance_id": f"utt-{index}"}
            records.extend([
                {"event": "option_detected", "at": base, **request},
                {"event": "visual_play_acknowledged", "at": base + 0.05, **request},
                {"event": "fifo_play_received", "at": base + 0.02, **request},
                {"event": "retained_play_latched", "at": base + 0.03, **request},
                {"event": "intent_committed", "at": base + 0.10, **utterance},
                {"event": "tts_preparing", "at": base + 0.12, **utterance},
                {"event": "first_wav_ready", "at": base + 0.70, **utterance},
                {"event": "afplay_started", "at": base + audio_ms / 1_000, **utterance},
            ])

        report = speech_latency_report.build_report(records)

        self.assertEqual(report["sample_count"], 3)
        self.assertEqual(report["option_to_ack_p95_ms"], 50.0)
        self.assertEqual(report["ack_to_first_audio_p95_ms"], 2_850.0)
        self.assertEqual(report["option_to_first_audio_p95_ms"], 2_900.0)
        self.assertEqual(report["samples"][0]["intent_wait_ms"], 70.0)
        self.assertNotIn("text", report["samples"][0])

    def test_report_ignores_incomplete_attempts(self):
        report = speech_latency_report.build_report([
            {
                "event": "option_detected",
                "at": 1.0,
                "relay_command_seq": 1,
                "relay_command_id": "cmd-1",
            }
        ])

        self.assertEqual(report["sample_count"], 0)
        self.assertIsNone(report["ack_to_first_audio_p95_ms"])
        self.assertIsNone(report["option_to_first_audio_p95_ms"])

    def test_report_measures_normal_path_acknowledgement_to_playback_budget(self):
        records = []
        for index, latency_ms in enumerate((180, 220, 300, 420), start=1):
            base = 2_000.0 + index
            identifiers = {
                "relay_command_seq": index,
                "relay_command_id": f"cmd-{index}",
                "play_request_id": f"play-{index}",
                "utterance_id": f"utterance-{index}",
            }
            records.extend([
                {
                    "event": "option_detected",
                    "at": base - 0.05,
                    **identifiers,
                },
                {
                    "event": "visual_play_acknowledged",
                    "at": base,
                    **identifiers,
                },
                {
                    "event": "afplay_started",
                    "at": base + latency_ms / 1_000,
                    **identifiers,
                },
            ])

        report = speech_latency_report.build_report(records)

        self.assertEqual(report["ack_to_first_audio_p95_ms"], 420.0)
        self.assertLessEqual(report["ack_to_first_audio_p95_ms"], 500.0)


if __name__ == "__main__":
    unittest.main()
