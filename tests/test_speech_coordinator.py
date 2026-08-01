from __future__ import annotations

import json
import os
import queue
from pathlib import Path
import statistics
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from speech_coordinator import SpeechCoordinator, SpeechIntent  # noqa: E402


class FakeWorker:
    def __init__(self):
        self.input_queue = queue.Queue()
        self.calls: list[str] = []
        self.eligibility = None
        self.observer = None

    def set_speech_callbacks(self, *, eligibility, observer):
        self.eligibility = eligibility
        self.observer = observer

    def skip(self):
        self.calls.append("skip")

    def stop_playback(self):
        self.calls.append("stop")

    def play(self):
        self.calls.append("play")

    def reload_config(self):
        self.calls.append("reload")

    def shutdown(self):
        self.calls.append("shutdown")


def intent(
    *,
    seq: int = 1,
    command_id: str = "one",
    kind: str = "handoff",
    text: str = "spoken",
    authoritative: bool = False,
    replayable: bool | None = None,
) -> SpeechIntent:
    return SpeechIntent.build(
        spoken_text=text,
        display_text=f"display {text}",
        semantic_brief=f"brief {text}",
        command_seq=seq,
        command_id=command_id,
        source="orchestrator" if authoritative else "messenger",
        kind=kind,
        authoritative=authoritative,
        replayable=replayable,
    )


class SpeechCoordinatorTests(unittest.TestCase):
    def make_coordinator(self, *, current=(1, "one"), log=None):
        worker = FakeWorker()
        holder = {"key": current}
        coordinator = SpeechCoordinator(
            worker,
            is_current=lambda seq, command_id: holder["key"] == (seq, command_id),
            event_log_path=log,
        )
        return worker, coordinator, holder

    def test_final_replaces_unstarted_handoff_and_deduplicates_fallback(self):
        worker, coordinator, _ = self.make_coordinator()
        handoff = intent(kind="handoff", text="handoff")
        final = intent(kind="final", text="final", authoritative=True)

        self.assertTrue(coordinator.submit(handoff))
        self.assertTrue(coordinator.submit(final))
        self.assertEqual(worker.calls, ["skip"])
        queued = [worker.input_queue.get_nowait(), worker.input_queue.get_nowait()]
        self.assertEqual(queued[-1]["_speech_intent"]["kind"], "final")

        duplicate = intent(kind="fallback", text="other rendering", authoritative=True)
        self.assertFalse(coordinator.submit(duplicate))

    def test_playing_handoff_sequences_final_after_completion(self):
        worker, coordinator, _ = self.make_coordinator()
        handoff = intent(kind="handoff", text="handoff")
        final = intent(kind="final", text="final", authoritative=True)
        coordinator.submit(handoff)
        first = worker.input_queue.get_nowait()
        worker.observer("started", first["_speech_intent"])

        self.assertTrue(coordinator.submit(final))
        self.assertTrue(worker.input_queue.empty())
        worker.observer("completed", first["_speech_intent"])

        queued_final = worker.input_queue.get_nowait()
        self.assertEqual(queued_final["_speech_intent"]["kind"], "final")

    def test_progress_cannot_preempt_handoff_and_final_removes_progress(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(intent(kind="handoff", text="handoff"))
        first = worker.input_queue.get_nowait()
        worker.observer("started", first["_speech_intent"])
        coordinator.submit(intent(kind="progress", text="progress"))
        coordinator.submit(intent(kind="clarification", text="question", authoritative=True))
        worker.observer("completed", first["_speech_intent"])

        next_payload = worker.input_queue.get_nowait()
        self.assertEqual(next_payload["_speech_intent"]["kind"], "clarification")
        self.assertTrue(worker.input_queue.empty())

    def test_freshness_is_checked_at_acceptance_and_before_playback(self):
        worker, coordinator, holder = self.make_coordinator()
        stale = intent(seq=0, command_id="old")
        self.assertFalse(coordinator.submit(stale))

        fresh = intent()
        self.assertTrue(coordinator.submit(fresh))
        payload = worker.input_queue.get_nowait()
        self.assertTrue(worker.eligibility(payload["_speech_intent"]))
        holder["key"] = (2, "two")
        self.assertFalse(worker.eligibility(payload["_speech_intent"]))

    def test_new_turn_stops_stale_speech_without_work_cancellation(self):
        worker, coordinator, holder = self.make_coordinator()
        coordinator.submit(intent())
        holder["key"] = (2, "two")
        coordinator.new_turn(2, "two")
        self.assertEqual(worker.calls, ["skip"])

    def test_replay_uses_only_last_completed_replayable_current_final(self):
        worker, coordinator, holder = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()
        worker.observer("started", payload["_speech_intent"])
        worker.observer("completed", payload["_speech_intent"])

        self.assertTrue(coordinator.replay())
        replay = worker.input_queue.get_nowait()
        self.assertEqual(replay["_speech_intent"]["replacement_policy"], "replay")
        self.assertEqual(worker.calls, ["play"])

        holder["key"] = (2, "two")
        self.assertFalse(coordinator.replay())

    def test_play_or_replay_replays_last_completed_replayable_handoff(self):
        worker, coordinator, _ = self.make_coordinator()
        handoff = intent(kind="handoff", replayable=True)
        coordinator.submit(handoff)
        payload = worker.input_queue.get_nowait()
        worker.observer("started", payload["_speech_intent"])
        worker.observer("completed", payload["_speech_intent"])

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()
        self.assertEqual(replay["_speech_intent"]["replacement_policy"], "replay")
        self.assertEqual(replay["_speech_intent"]["spoken_text"], handoff.spoken_text)
        self.assertEqual(worker.calls, ["play"])

    def test_play_and_replay_do_not_start_a_second_active_plan(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(intent(kind="final", authoritative=True))
        payload = worker.input_queue.get_nowait()
        worker.observer("started", payload["_speech_intent"])

        coordinator.play()
        self.assertEqual(worker.calls, [])
        self.assertTrue(coordinator.replay() is False)
        self.assertTrue(coordinator.play_or_replay())
        self.assertEqual(worker.calls, [])

    def test_first_play_is_retained_until_authoritative_speech_is_proposed(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.arm_waiting_playback(1, "one", kind="final")

        coordinator.play()
        coordinator.play()
        self.assertEqual(worker.calls, [])

        final = intent(kind="final", authoritative=True)
        self.assertTrue(coordinator.submit(final))
        payload = worker.input_queue.get_nowait()

        self.assertEqual(worker.calls, ["play"])
        self.assertTrue(worker.eligibility(payload["_speech_intent"]))

        worker.observer("started", payload["_speech_intent"])
        coordinator.play()
        self.assertEqual(worker.calls, ["play"])

    def test_authoritative_preview_does_not_play_an_older_handoff(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(intent(kind="handoff", text="handoff"))
        handoff = worker.input_queue.get_nowait()

        coordinator.arm_waiting_playback(1, "one", kind="final")
        coordinator.play()

        self.assertEqual(worker.calls, [])
        self.assertFalse(worker.eligibility(handoff["_speech_intent"]))

        coordinator.submit(intent(kind="final", text="final", authoritative=True))
        final = worker.input_queue.get_nowait()
        self.assertEqual(worker.calls, ["skip", "play"])
        self.assertEqual(final["_speech_intent"]["kind"], "final")
        self.assertTrue(worker.eligibility(final["_speech_intent"]))

    def test_retained_play_follows_a_newer_preview_without_playing_stale_text(self):
        worker = FakeWorker()
        coordinator = SpeechCoordinator(worker, is_current=lambda _seq, _command_id: True)
        coordinator.arm_waiting_playback(1, "one", kind="final")
        coordinator.play()
        coordinator.arm_waiting_playback(2, "two", kind="final")

        coordinator.submit(intent(seq=1, command_id="one", kind="final", text="old"))
        old = worker.input_queue.get_nowait()
        self.assertEqual(worker.calls, [])
        self.assertFalse(worker.eligibility(old["_speech_intent"]))

        coordinator.submit(intent(seq=2, command_id="two", kind="final", text="new"))
        new = worker.input_queue.get_nowait()
        self.assertEqual(worker.calls, ["skip", "play"])
        self.assertTrue(worker.eligibility(new["_speech_intent"]))

    def test_cancel_clears_a_retained_play_request(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.arm_waiting_playback(1, "one", kind="final")
        coordinator.play()

        coordinator.skip()
        coordinator.submit(intent(kind="final", authoritative=True))

        self.assertEqual(worker.calls, ["skip"])

    def test_auto_play_start_consumes_waiting_preview_without_implicit_replay(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.arm_waiting_playback(1, "one", kind="final")
        coordinator.submit(intent(kind="final", authoritative=True, replayable=True))
        payload = worker.input_queue.get_nowait()

        worker.observer("started", payload["_speech_intent"])
        worker.observer("completed", payload["_speech_intent"])
        coordinator.play()

        self.assertEqual(worker.calls, [])

    def test_diagnostics_never_log_spoken_or_display_text(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "speech.jsonl"
            worker, coordinator, _ = self.make_coordinator(log=log)
            coordinator.submit(intent(text="private words"))
            coordinator.record_realization(
                1,
                "one",
                lifecycle_role="progress",
                decision="suppress",
                reason="covered_by_played_speech",
            )
            records = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(
                [record["event"] for record in records],
                ["proposed", "accepted", "realization"],
            )
            self.assertEqual(records[-1]["lifecycle_role"], "progress")
            self.assertEqual(records[-1]["realization_decision"], "suppress")
            self.assertEqual(records[-1]["suppression_reason"], "covered_by_played_speech")
            self.assertNotIn("private words", log.read_text())

    def test_only_completed_speech_becomes_command_scoped_coverage(self):
        worker, coordinator, _ = self.make_coordinator()
        played = intent(kind="handoff", text="I picked up RR-263.", replayable=True)
        cancelled = intent(kind="progress", text="I am checking it now.")

        coordinator.submit(played)
        played_payload = worker.input_queue.get_nowait()
        worker.observer("started", played_payload["_speech_intent"])
        worker.observer("completed", played_payload["_speech_intent"])
        coordinator.submit(cancelled)
        cancelled_payload = worker.input_queue.get_nowait()
        worker.observer("started", cancelled_payload["_speech_intent"])
        worker.observer("cancelled", cancelled_payload["_speech_intent"])

        coverage = coordinator.played_coverage(1, "one")
        self.assertEqual(len(coverage), 1)
        self.assertEqual(coverage[0]["lifecycle_role"], "acknowledgement")
        self.assertIn("brief I picked up RR-263.", coverage[0]["covered_facts"])
        self.assertEqual(coordinator.played_coverage(2, "two"), ())

    def test_coverage_does_not_leak_across_rapid_turns_or_barge_in(self):
        worker, coordinator, holder = self.make_coordinator()
        first = intent(kind="handoff", text="First acknowledgement")
        coordinator.submit(first)
        first_payload = worker.input_queue.get_nowait()
        worker.observer("started", first_payload["_speech_intent"])
        worker.observer("completed", first_payload["_speech_intent"])

        holder["key"] = (2, "two")
        coordinator.new_turn(2, "two")
        second = intent(seq=2, command_id="two", kind="handoff", text="Interrupted")
        coordinator.submit(second)
        second_payload = worker.input_queue.get_nowait()
        worker.observer("started", second_payload["_speech_intent"])
        coordinator.stop()

        self.assertEqual(len(coordinator.played_coverage(1, "one")), 1)
        self.assertEqual(coordinator.played_coverage(2, "two"), ())

    def test_decision_latency_is_below_ten_milliseconds_p95(self):
        worker, coordinator, _ = self.make_coordinator()
        durations = []
        for index in range(250):
            started = time.perf_counter()
            coordinator.submit(intent(kind="progress", text=f"event {index}"))
            durations.append((time.perf_counter() - started) * 1000)
        p95 = statistics.quantiles(durations, n=20)[18]
        self.assertLess(p95, 10.0)


if __name__ == "__main__":
    unittest.main()
