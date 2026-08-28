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
        self.presentation_events: list[tuple[str, dict, str]] = []
        self.eligibility = None
        self.observer = None

    def set_speech_callbacks(self, *, eligibility, observer):
        self.eligibility = eligibility
        self.observer = observer

    def skip(self):
        self.calls.append("skip")

    def stop_playback(self, *, reason="user_stop"):
        del reason
        self.calls.append("stop")

    def publish_replay_retained(self, speech_intent, *, stop_reason):
        self.calls.append("replay_retained")
        self.presentation_events.append(("retained", speech_intent, stop_reason))

    def publish_replay_invalidated(self, speech_intent, *, reason):
        self.calls.append("replay_invalidated")
        self.presentation_events.append(("invalidated", speech_intent, reason))

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
    source: str | None = None,
    freshness_scope: str = "conversation",
) -> SpeechIntent:
    return SpeechIntent.build(
        spoken_text=text,
        display_text=f"display {text}",
        semantic_brief=f"brief {text}",
        command_seq=seq,
        command_id=command_id,
        source=source or ("orchestrator" if authoritative else "messenger"),
        kind=kind,
        authoritative=authoritative,
        replayable=replayable,
        freshness_scope=freshness_scope,
    )


class SpeechCoordinatorTests(unittest.TestCase):
    def make_coordinator(
        self,
        *,
        current=(1, "one"),
        log=None,
        has_foreground_ownership=None,
    ):
        worker = FakeWorker()
        holder = {"key": current}
        coordinator = SpeechCoordinator(
            worker,
            is_current=lambda seq, command_id: holder["key"] == (seq, command_id),
            has_foreground_ownership=has_foreground_ownership,
            event_log_path=log,
        )
        return worker, coordinator, holder

    def test_messenger_handoff_waits_for_exact_foreground_ownership(self):
        owned: set[tuple[int, str]] = {(1, "one")}
        worker, coordinator, _ = self.make_coordinator(
            current=(2, "two"),
            has_foreground_ownership=lambda seq, command_id: (
                (seq, command_id) in owned
            ),
        )

        self.assertFalse(coordinator.submit(intent(
            seq=2,
            command_id="two",
            kind="handoff",
            text="later provisional",
        )))
        self.assertTrue(worker.input_queue.empty())

        owned.add((2, "two"))
        self.assertTrue(coordinator.submit(intent(
            seq=2,
            command_id="two",
            kind="handoff",
            text="owned provisional",
        )))
        queued = worker.input_queue.get_nowait()
        self.assertEqual(queued["_speech_intent"]["command_seq"], 2)

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

    def test_replay_preserves_progress_semantics_when_no_final_was_accepted(self):
        worker, coordinator, _ = self.make_coordinator()
        progress = SpeechIntent.build(
            spoken_text="Complete retained progress.",
            display_text="Complete retained progress.",
            command_seq=1,
            command_id="one",
            source="lifecycle",
            kind="progress",
            authoritative=False,
            replayable=True,
            lifecycle_role="progress",
            realization_decision="full",
            suppression_reason="lossy_delta",
        )
        coordinator.submit(progress)
        payload = worker.input_queue.get_nowait()
        worker.observer("started", payload["_speech_intent"])
        worker.observer("completed", payload["_speech_intent"])

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["source"], "lifecycle")
        self.assertEqual(replay["kind"], "progress")
        self.assertFalse(replay["authoritative"])
        self.assertEqual(replay["lifecycle_role"], "progress")
        self.assertEqual(replay["spoken_text"], progress.spoken_text)
        self.assertEqual(replay["display_text"], progress.display_text)
        self.assertEqual(replay["realization_decision"], "full")
        self.assertEqual(replay["suppression_reason"], "lossy_delta")
        self.assertEqual(replay["replacement_policy"], "replay")

    def test_replay_selects_latest_fresh_completed_target(self):
        worker, coordinator, holder = self.make_coordinator()
        work_result = intent(
            seq=0,
            command_id="old-work",
            kind="final",
            text="durable work result",
            authoritative=True,
            replayable=True,
            source="lifecycle",
            freshness_scope="work",
        )
        coordinator.submit(work_result)
        work_payload = worker.input_queue.get_nowait()
        worker.observer("started", work_payload["_speech_intent"])
        worker.observer("completed", work_payload["_speech_intent"])

        conversation_final = intent(
            kind="final",
            text="newer conversation final",
            authoritative=True,
            replayable=True,
        )
        coordinator.submit(conversation_final)
        conversation_payload = worker.input_queue.get_nowait()
        worker.observer("started", conversation_payload["_speech_intent"])
        worker.observer("completed", conversation_payload["_speech_intent"])
        holder["key"] = (2, "two")

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()
        self.assertEqual(replay["_speech_intent"]["spoken_text"], work_result.spoken_text)
        self.assertEqual(replay["_speech_intent"]["replacement_policy"], "replay")

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

    def test_cancelled_replayable_speech_is_never_retained_for_replay(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()
        worker.observer("started", payload["_speech_intent"])
        worker.observer("cancelled", payload["_speech_intent"])

        self.assertFalse(coordinator.play_or_replay())
        self.assertTrue(worker.input_queue.empty())

    def test_stopping_initial_playback_retains_one_fresh_replay(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)

        coordinator.stop_playback()
        worker.observer("cancelled", payload)

        self.assertEqual(worker.calls, ["stop", "replay_retained"])
        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], final.spoken_text)
        self.assertEqual(replay["command_seq"], final.command_seq)
        self.assertEqual(replay["command_id"], final.command_id)
        self.assertEqual(replay["replacement_policy"], "replay")
        self.assertEqual(replay["original_utterance_id"], payload["original_utterance_id"])
        self.assertEqual(replay["replay_of"], payload["utterance_id"])
        self.assertEqual(worker.calls, ["stop", "replay_retained", "play"])
        self.assertTrue(worker.input_queue.empty())
        retained = worker.presentation_events[0]
        self.assertEqual(retained[0], "retained")
        self.assertEqual(retained[1]["utterance_id"], payload["utterance_id"])
        self.assertEqual(retained[2], "user_stop")

    def test_stopping_replay_repeatedly_keeps_same_message_replayable(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)
        worker.observer("completed", payload)

        for _ in range(3):
            self.assertTrue(coordinator.play_or_replay())
            replay = worker.input_queue.get_nowait()["_speech_intent"]
            self.assertEqual(replay["spoken_text"], final.spoken_text)
            worker.observer("started", replay)
            coordinator.skip()
            worker.observer("cancelled", replay)

        self.assertEqual(worker.calls.count("play"), 3)
        self.assertEqual(worker.calls.count("stop"), 3)
        self.assertEqual(worker.calls.count("replay_retained"), 3)
        self.assertTrue(coordinator.play_or_replay())
        self.assertEqual(worker.input_queue.qsize(), 1)

    def test_stopped_attempt_is_not_retained_after_actual_intent_cancellation(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)

        coordinator.stop()
        worker.observer("cancelled", payload)

        self.assertFalse(coordinator.play_or_replay())
        self.assertEqual(worker.calls, ["stop"])
        self.assertTrue(worker.input_queue.empty())

    def test_interrupt_stop_reason_invalidates_instead_of_retaining(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)

        coordinator.stop_playback(reason="interrupt")
        worker.observer("cancelled", payload)

        self.assertFalse(coordinator.play_or_replay())
        self.assertNotIn("replay_retained", worker.calls)

    def test_recording_barge_in_does_not_advance_queued_speech(self):
        worker, coordinator, _ = self.make_coordinator()
        first = intent(kind="handoff", text="first", replayable=True)
        second = intent(kind="final", text="second", authoritative=True)
        coordinator.submit(first)
        first_payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", first_payload)
        coordinator.submit(second)

        coordinator.stop_playback(reason="recording_barge_in")
        worker.observer("cancelled", first_payload)

        self.assertTrue(worker.input_queue.empty())
        self.assertFalse(coordinator.play_or_replay())
        self.assertNotIn("replay_retained", worker.calls)

    def test_newer_turn_clears_retained_replay_presentation(self):
        worker, coordinator, holder = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)
        coordinator.stop_playback()
        worker.observer("cancelled", payload)

        holder["key"] = (2, "two")
        coordinator.new_turn(2, "two")

        self.assertEqual(worker.calls[-1], "replay_invalidated")
        self.assertEqual(worker.presentation_events[-1][2], "newer_command")
        self.assertFalse(coordinator.play_or_replay())

    def test_stopped_attempt_respects_freshness_and_replayable_policy(self):
        for replayable in (False, True):
            with self.subTest(replayable=replayable):
                worker, coordinator, holder = self.make_coordinator()
                final = intent(
                    kind="final",
                    authoritative=True,
                    replayable=replayable,
                )
                coordinator.submit(final)
                payload = worker.input_queue.get_nowait()["_speech_intent"]
                worker.observer("started", payload)
                if replayable:
                    holder["key"] = (2, "two")
                coordinator.stop_playback()
                worker.observer("cancelled", payload)

                self.assertFalse(coordinator.play_or_replay())
                self.assertNotIn("replay_retained", worker.calls)

    def test_stopped_attempt_retention_covers_supported_speech_sources(self):
        cases = (
            intent(kind="final", authoritative=True, replayable=True),
            intent(
                seq=0,
                command_id="work",
                kind="final",
                authoritative=True,
                replayable=True,
                source="lifecycle",
                freshness_scope="work",
            ),
            intent(kind="progress", replayable=True),
        )
        for original in cases:
            with self.subTest(source=original.source, kind=original.kind):
                worker, coordinator, _ = self.make_coordinator()
                coordinator.submit(original)
                payload = worker.input_queue.get_nowait()["_speech_intent"]
                worker.observer("started", payload)
                coordinator.stop_playback()
                worker.observer("cancelled", payload)

                self.assertTrue(coordinator.play_or_replay())
                replay = worker.input_queue.get_nowait()["_speech_intent"]
                self.assertEqual(replay["spoken_text"], original.spoken_text)
                self.assertEqual(replay["command_id"], original.command_id)

    def test_stopped_attempt_is_not_played_until_later_replay_completes(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "speech.jsonl"
            worker, coordinator, _ = self.make_coordinator(log=log)
            final = intent(kind="final", authoritative=True, replayable=True)
            coordinator.submit(final)
            initial = worker.input_queue.get_nowait()["_speech_intent"]
            worker.observer("started", initial)
            coordinator.stop_playback()
            worker.observer("cancelled", initial)

            self.assertTrue(coordinator.play_or_replay())
            replay = worker.input_queue.get_nowait()["_speech_intent"]
            worker.observer("started", replay)
            worker.observer("completed", replay)

            terminal = [
                record
                for record in (
                    json.loads(line) for line in log.read_text().splitlines()
                )
                if record["event"] in {"stopped", "played"}
            ]
            self.assertEqual([record["event"] for record in terminal], ["stopped", "played"])
            self.assertEqual(
                {record["relay_command_id"] for record in terminal},
                {final.command_id},
            )
            self.assertNotEqual(
                terminal[0]["utterance_id"],
                terminal[1]["utterance_id"],
            )
            self.assertEqual(
                terminal[1]["replay_of"],
                terminal[0]["original_utterance_id"],
            )
            self.assertEqual(
                [record["presentation_mode"] for record in terminal],
                ["new_delivery", "explicit_replay"],
            )
            self.assertEqual(terminal[0]["stop_reason"], "user_stop")

    def test_stop_holds_next_queued_message_until_explicit_replay_finishes(self):
        worker, coordinator, _ = self.make_coordinator()
        first = intent(kind="handoff", text="first", replayable=True)
        second = intent(kind="final", text="second", authoritative=True)
        coordinator.submit(first)
        first_payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", first_payload)
        coordinator.submit(second)

        coordinator.stop_playback()
        worker.observer("cancelled", first_payload)

        self.assertTrue(worker.input_queue.empty())
        self.assertEqual(worker.calls, ["stop", "replay_retained"])

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], "first")
        self.assertEqual(replay["replacement_policy"], "replay")
        self.assertEqual(worker.calls, ["stop", "replay_retained", "play"])

        worker.observer("started", replay)
        worker.observer("completed", replay)
        next_payload = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(next_payload["spoken_text"], "second")

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

    def test_replay_rejection_reports_selection_boundary_without_text(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "speech.jsonl"
            _, coordinator, _ = self.make_coordinator(log=log)
            coordinator.note_play_control(
                option_detected_at=1_000.0,
                fifo_received_at=1_000.02,
            )

            self.assertFalse(coordinator.play_or_replay())

            records = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(records[-1]["event"], "replay_rejected")
            self.assertEqual(records[-1]["reason"], "no_completed_target")
            self.assertEqual(
                records[-1]["play_request_id"],
                records[0]["play_request_id"],
            )
            self.assertNotIn("spoken_text", records[-1])
            self.assertNotIn("display_text", records[-1])

    def test_retained_play_diagnostics_correlate_every_audio_stage_without_text(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "speech.jsonl"
            worker, coordinator, _ = self.make_coordinator(log=log)
            coordinator.arm_waiting_playback(1, "one", kind="final")
            coordinator.note_play_control(
                option_detected_at=1_000.0,
                fifo_received_at=1_000.02,
            )
            coordinator.play()
            coordinator.note_visual_acknowledgement(
                option_detected_at=1_000.0,
                acknowledged_at=1_000.05,
            )

            final = intent(kind="final", text="private final", authoritative=True)
            self.assertTrue(coordinator.submit(final))
            payload = worker.input_queue.get_nowait()["_speech_intent"]
            worker.observer("preparing", {**payload, "_event_at": 1_000.10})
            worker.observer("wav_ready", {**payload, "_event_at": 1_000.70})
            worker.observer("started", payload)
            worker.observer("afplay_started", {**payload, "_event_at": 1_000.90})
            worker.observer("completed", payload)

            records = [json.loads(line) for line in log.read_text().splitlines()]
            events = [record["event"] for record in records]
            for event in (
                "option_detected",
                "fifo_play_received",
                "retained_play_latched",
                "visual_play_acknowledged",
                "intent_committed",
                "tts_preparing",
                "first_wav_ready",
                "afplay_started",
            ):
                self.assertIn(event, events)
            self.assertNotIn("private final", log.read_text())
            afplay = next(record for record in records if record["event"] == "afplay_started")
            self.assertEqual(afplay["utterance_id"], final.utterance_id)
            self.assertEqual(afplay["option_to_stage_ms"], 900.0)

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
