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

from speech_coordinator import SPEECH_QUEUE_LIMIT, SpeechCoordinator, SpeechIntent  # noqa: E402


class FakeWorker:
    def __init__(self):
        self.input_queue = queue.Queue()
        self.calls: list[str] = []
        self.eligibility = None
        self.observer = None

    def set_speech_callbacks(self, *, eligibility, observer):
        self.eligibility = eligibility
        self.observer = observer

    def skip(self, *, reason="user_stop"):
        del reason
        self.calls.append("skip")

    def stop_playback(self, *, reason="user_stop"):
        del reason
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
    def test_session_controls_follow_waiting_preparing_playing_and_replay(self):
        worker, coordinator, _ = self.make_coordinator()
        speech = SpeechIntent.build(spoken_text="A reply", session_key="a", kind="final")
        coordinator.submit(speech)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(coordinator.session_playback_states(), {"a": "play"})
        self.assertTrue(coordinator.control_session("a", "play"))
        self.assertEqual(coordinator.session_playback_states(), {"a": "stop"})
        self.assertFalse(coordinator.control_session("b", "stop"))
        self.assertNotIn("stop", worker.calls)
        worker.observer("started", payload)
        self.assertTrue(coordinator.control_session("a", "stop"))
        self.assertIn("stop", worker.calls)
        worker.observer("cancelled", payload)
        # RR-464: a stopped reply was not heard, so it stays queued.
        self.assertEqual(coordinator.session_playback_states(), {"a": "play"})
        self.assertTrue(coordinator.control_session("a", "play"))
        resumed = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(resumed["original_utterance_id"], speech.utterance_id)
        self.assertIsNone(resumed["replay_of"])
        worker.observer("started", resumed)
        worker.observer("completed", resumed)
        self.assertEqual(coordinator.session_playback_states(), {"a": "replay"})
        self.assertTrue(coordinator.control_session("a", "replay"))
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["session_key"], "a")
        self.assertEqual(replay["replay_of"], speech.utterance_id)

    def test_session_replay_prefers_new_pending_speech_and_filters_history(self):
        worker, coordinator, _ = self.make_coordinator()
        for key in ("a", "b"):
            coordinator.read_out(f"Reply {key}", session_key=key)
            payload = worker.input_queue.get_nowait()["_speech_intent"]
            worker.observer("started", payload)
            worker.observer("completed", payload)
        self.assertEqual(coordinator.session_playback_states(), {"a": "replay", "b": "replay"})
        self.assertTrue(coordinator.control_session("a", "replay"))
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["session_key"], "a")
        worker.observer("started", replay)
        worker.observer("completed", replay)
        coordinator.submit(SpeechIntent.build(spoken_text="New A", session_key="a", kind="final"))
        pending = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(coordinator.session_playback_states()["a"], "play")
        self.assertTrue(coordinator.control_session("a", "replay"))
        self.assertTrue(worker.input_queue.empty(), "Play must not manufacture a replay while a new message waits")
        self.assertEqual(coordinator._play_dispatched_id, pending["utterance_id"])

    def test_wheel_stop_does_not_advance_the_reply_queue(self):
        worker, coordinator, _ = self.make_coordinator()
        finished = []
        coordinator._on_reply_finished = finished.append
        speech = SpeechIntent.build(spoken_text="A reply", session_key="a", kind="final")
        coordinator.submit(speech)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        coordinator.control_session("a", "play")
        worker.observer("started", payload)

        self.assertTrue(coordinator.control_session("a", "stop"))
        self.assertEqual(coordinator._stopped_attempt_reasons[speech.utterance_id], "wheel_stop")
        worker.observer("cancelled", payload)

        self.assertEqual(finished, [], "Stopping from the wheel must not surface the next reply")
        self.assertEqual(coordinator.session_playback_states(), {"a": "play"})
        self.assertTrue(coordinator.control_session("a", "play"))
        resumed = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(resumed["original_utterance_id"], speech.utterance_id)
        self.assertIsNone(resumed["replay_of"])

    def test_session_play_latches_before_messenger_finishes_without_changing_other_session(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.arm_waiting_playback(1, "one", kind="final")
        self.assertEqual(coordinator.session_playback_states(waiting_session_key="a"), {"a": "play"})
        self.assertFalse(coordinator.control_session("b", "play", waiting_session_key="a"))
        self.assertTrue(coordinator.control_session("a", "play", waiting_session_key="a"))
        coordinator.submit(SpeechIntent.build(spoken_text="A reply", session_key="a", kind="final",
                                              command_seq=1, command_id="one"))
        self.assertIn("play", worker.calls)

    def test_stop_during_preparation_preserves_other_queued_messages(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.read_out("A reply", session_key="a")
        active = worker.input_queue.get_nowait()["_speech_intent"]
        coordinator.submit(SpeechIntent.build(spoken_text="Next B", session_key="b"))
        self.assertTrue(coordinator.control_session("a", "stop"))
        worker.observer("cancelled", active)
        self.assertEqual(coordinator.session_playback_states(), {"a": "play", "b": "play"})
        self.assertTrue(coordinator.control_session("b", "play"))
        self.assertEqual(worker.input_queue.get_nowait()["_speech_intent"]["session_key"], "b")

    def test_reading_a_background_reply_plays_that_session_and_keeps_the_other_waiting(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(SpeechIntent.build(spoken_text="A waiting", session_key="a"))
        worker.input_queue.get_nowait()
        self.assertTrue(coordinator.read_out("B requested", session_key="b"))
        selected = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(selected["session_key"], "b")
        self.assertEqual(coordinator.session_playback_states(), {"a": "play", "b": "stop"})

    def make_coordinator(
        self,
        *,
        current=(1, "one"),
        log=None,
    ):
        worker = FakeWorker()
        holder = {"key": current}
        coordinator = SpeechCoordinator(
            worker,
            is_current=lambda seq, command_id: holder["key"] == (seq, command_id),
            event_log_path=log,
        )
        return worker, coordinator, holder

    def test_blank_display_text_falls_back_to_exact_spoken_text(self):
        speech = SpeechIntent.build(
            spoken_text="Complete user-facing response.",
            display_text="  ",
            semantic_brief="bounded internal summary",
            command_seq=1,
            command_id="one",
            source="completion",
            kind="final",
            authoritative=True,
        )

        self.assertEqual(speech.display_text, "Complete user-facing response.")
        self.assertEqual(
            speech.to_worker_payload()["display_text"],
            "Complete user-facing response.",
        )
        self.assertNotEqual(speech.display_text, speech.semantic_brief)

    def test_current_messenger_handoff_does_not_wait_for_foreground_claim(self):
        worker, coordinator, _ = self.make_coordinator(current=(2, "two"))

        self.assertTrue(coordinator.submit(intent(
            seq=2,
            command_id="two",
            kind="handoff",
            text="immediate semantic handoff",
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

    # RR-460: a late real final replaces a provisional fallback outcome.

    def fallback(self, *, source="messenger", kind="fallback", text="provisional"):
        # kind="conversation" is the messenger's own answer; it normalizes to
        # a fallback outcome, which is how seq 89/91 lost their real finals.
        return SpeechIntent.build(
            spoken_text=text,
            command_seq=1,
            command_id="one",
            source=source,
            kind=kind,
            authoritative=source != "messenger",
            replayable=True,
        )

    def completion_final(self, text="real final"):
        return intent(kind="final", text=text, authoritative=True, source="completion")

    def test_late_final_replaces_a_queued_fallback(self):
        for shape in (
            {"source": "messenger", "kind": "conversation"},
            {"source": "fallback", "kind": "fallback"},
            {"source": "fallback", "kind": "final"},
        ):
            with self.subTest(**shape):
                worker, coordinator, _ = self.make_coordinator()
                fallback = self.fallback(**shape)
                final = self.completion_final()
                self.assertTrue(fallback.is_fallback_outcome)
                self.assertNotEqual(fallback.dedup_key, final.dedup_key)

                self.assertTrue(coordinator.submit(fallback))
                queued_fallback = worker.input_queue.get_nowait()["_speech_intent"]
                self.assertTrue(coordinator.submit(final))

                self.assertEqual(worker.calls, ["skip"])
                queued_final = worker.input_queue.get_nowait()["_speech_intent"]
                self.assertEqual(queued_final["utterance_id"], final.utterance_id)
                self.assertFalse(worker.eligibility(queued_fallback))
                self.assertTrue(worker.eligibility(queued_final))

    def test_late_final_cuts_a_playing_fallback_and_owns_replay(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(self.fallback())
        playing = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", playing)
        final = self.completion_final()

        self.assertTrue(coordinator.submit(final))

        self.assertEqual(worker.calls, ["skip"])
        queued_final = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("cancelled", playing)
        self.assertTrue(worker.eligibility(queued_final))
        worker.observer("started", queued_final)
        worker.observer("completed", queued_final)
        self.assertTrue(coordinator.replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], "real final")

    def test_late_final_is_spoken_after_a_played_fallback(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(self.fallback())
        played = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", played)
        worker.observer("completed", played)

        self.assertTrue(coordinator.submit(self.completion_final()))

        self.assertEqual(worker.calls, [])
        spoken = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual((spoken["kind"], spoken["spoken_text"]), ("final", "real final"))

    def test_late_final_drops_a_fallback_waiting_behind_a_handoff(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(intent(kind="handoff", text="handoff"))
        handoff = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", handoff)
        coordinator.submit(self.fallback(source="fallback", kind="final"))
        coordinator.submit(self.completion_final())

        worker.observer("completed", handoff)

        following = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(following["spoken_text"], "real final")
        worker.observer("started", following)
        worker.observer("completed", following)
        self.assertTrue(worker.input_queue.empty())

    def test_fallback_after_a_real_final_is_suppressed(self):
        worker, coordinator, _ = self.make_coordinator()
        self.assertTrue(coordinator.submit(self.completion_final()))
        queued_final = worker.input_queue.get_nowait()["_speech_intent"]

        for shape in (
            {"source": "fallback", "kind": "final"},
            {"source": "messenger", "kind": "conversation"},
        ):
            self.assertFalse(coordinator.submit(self.fallback(**shape)))
        self.assertTrue(worker.input_queue.empty())
        self.assertEqual(worker.calls, [])
        self.assertTrue(worker.eligibility(queued_final))

    def test_two_real_finals_are_still_deduplicated(self):
        worker, coordinator, _ = self.make_coordinator()
        coordinator.submit(self.fallback())
        self.assertTrue(coordinator.submit(self.completion_final("first")))
        self.assertFalse(coordinator.submit(
            intent(kind="final", text="second", authoritative=True, source="orchestrator")
        ))

    def test_missing_outcome_is_logged_once_and_only_without_an_outcome(self):
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "events.jsonl"
            worker, coordinator, _ = self.make_coordinator(log=log)
            coordinator.submit(intent(kind="handoff", text="handoff"))

            self.assertTrue(coordinator.record_missing_outcome(
                1, "one", "hook_not_received", signals=["daemon_fetch_timed_out"]
            ))
            self.assertFalse(coordinator.record_missing_outcome(1, "one", "again"))

            records = [json.loads(line) for line in log.read_text().splitlines()]
            missing = [record for record in records if record["event"] == "missing_outcome"]
            self.assertEqual(len(missing), 1)
            self.assertEqual(
                (missing[0]["relay_command_seq"], missing[0]["relay_command_id"], missing[0]["reason"]),
                (1, "one", "hook_not_received"),
            )
            self.assertEqual(missing[0]["signals"], ["daemon_fetch_timed_out"])

    def test_missing_outcome_is_not_logged_after_an_accepted_outcome(self):
        _, coordinator, _ = self.make_coordinator()
        coordinator.submit(self.fallback())
        self.assertFalse(coordinator.record_missing_outcome(1, "one", "hook_not_received"))

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

    def test_replay_still_plays_last_final_after_newer_command(self):
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
        worker.observer("started", replay["_speech_intent"])
        worker.observer("completed", replay["_speech_intent"])

        holder["key"] = (2, "two")
        self.assertTrue(coordinator.replay())
        replay = worker.input_queue.get_nowait()
        self.assertEqual(replay["_speech_intent"]["spoken_text"], final.spoken_text)

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

    def test_replay_selects_latest_completed_target(self):
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
        self.assertEqual(replay["_speech_intent"]["spoken_text"], conversation_final.spoken_text)
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

        # RR-464: it was not heard, so it stays queued rather than replayable.
        self.assertFalse(coordinator.replay())
        self.assertTrue(worker.input_queue.empty())
        self.assertEqual(coordinator.queue_depth, 1)

    def test_finished_final_reports_completion_and_user_stop_only(self):
        for state, reason, expected in (
            ("completed", None, ["completed"]),
            ("cancelled", "user_stop", ["user_stop"]),
            ("cancelled", "focus_switch", []),
            ("cancelled", "wheel_stop", []),
        ):
            with self.subTest(state=state, reason=reason):
                worker = FakeWorker()
                finished: list[str] = []
                coordinator = SpeechCoordinator(
                    worker,
                    is_current=lambda seq, command_id: True,
                    on_reply_finished=finished.append,
                )
                coordinator.submit(intent(kind="final", authoritative=True, replayable=True))
                payload = worker.input_queue.get_nowait()["_speech_intent"]
                worker.observer("started", payload)
                self.assertTrue(coordinator.speaking)
                self.assertTrue(coordinator.playing)
                if reason:
                    coordinator.skip(reason=reason)
                worker.observer(state, payload)

                self.assertEqual(finished, expected)
                self.assertFalse(coordinator.speaking)

    def test_read_out_plays_text_without_command_metadata(self):
        worker, coordinator, _ = self.make_coordinator(current=(9, "newer"))
        coordinator.read_out("  Stored reply.  ")
        coordinator.read_out("")

        payload = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(payload["spoken_text"], "Stored reply.")
        self.assertIn("play", worker.calls)
        self.assertTrue(worker.input_queue.empty())

    def test_stopping_initial_playback_retains_one_fresh_replay(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)

        coordinator.stop_playback()
        worker.observer("cancelled", payload)

        # The stopped message stays queued and replayable without a notch
        # announcement; Play resumes it as the same message (RR-464).
        self.assertEqual(worker.calls, ["stop"])
        self.assertTrue(coordinator.play_or_replay())
        resumed = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(resumed["spoken_text"], final.spoken_text)
        self.assertEqual(resumed["command_seq"], final.command_seq)
        self.assertEqual(resumed["command_id"], final.command_id)
        self.assertEqual(resumed["replacement_policy"], "semantic")
        self.assertEqual(resumed["original_utterance_id"], payload["original_utterance_id"])
        self.assertIsNone(resumed["replay_of"])
        self.assertEqual(worker.calls, ["stop", "play"])
        self.assertTrue(worker.input_queue.empty())

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
        self.assertTrue(coordinator.play_or_replay())
        self.assertEqual(worker.input_queue.qsize(), 1)

    def test_message_cancelled_before_playing_becomes_the_replay_target(self):
        worker, coordinator, _ = self.make_coordinator()
        older = intent(kind="handoff", text="older", replayable=True)
        coordinator.submit(older)
        older_payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", older_payload)
        worker.observer("completed", older_payload)

        newer = intent(kind="final", text="newer", authoritative=True, replayable=True)
        coordinator.submit(newer)
        newer_payload = worker.input_queue.get_nowait()["_speech_intent"]
        coordinator.skip()
        worker.observer("cancelled", newer_payload)

        self.assertEqual(worker.calls, ["skip"])
        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], "newer")
        self.assertEqual(replay["replay_of"], newer_payload["original_utterance_id"])

    def test_cancel_while_idle_keeps_last_message_replayable(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)
        worker.observer("completed", payload)

        coordinator.skip()

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], final.spoken_text)

    def test_barge_in_keeps_interrupted_message_replayable(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)

        coordinator.stop()
        worker.observer("cancelled", payload)

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], final.spoken_text)

    def test_interrupt_stop_keeps_message_replayable(self):
        worker, coordinator, _ = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)

        coordinator.stop_playback(reason="interrupt")
        worker.observer("cancelled", payload)

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], final.spoken_text)

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

    def test_newer_turn_keeps_last_message_replayable(self):
        worker, coordinator, holder = self.make_coordinator()
        final = intent(kind="final", authoritative=True, replayable=True)
        coordinator.submit(final)
        payload = worker.input_queue.get_nowait()["_speech_intent"]
        worker.observer("started", payload)
        coordinator.stop_playback()
        worker.observer("cancelled", payload)

        holder["key"] = (2, "two")
        coordinator.new_turn(2, "two")

        self.assertTrue(coordinator.play_or_replay())
        replay = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(replay["spoken_text"], final.spoken_text)

    def test_stopped_attempt_respects_replayable_policy(self):
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

                # A newer command doesn't stop a replayable message replaying;
                # either way the unheard message stays queued (RR-464).
                self.assertEqual(coordinator.replay(), replayable)
                self.assertGreaterEqual(coordinator.queue_depth, 1)

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

    def test_stopped_attempt_is_played_when_its_resumed_delivery_completes(self):
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
            resumed = worker.input_queue.get_nowait()["_speech_intent"]
            worker.observer("started", resumed)
            worker.observer("completed", resumed)

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
            # RR-464: Play resumes the same message, not a replay of it.
            self.assertEqual(
                terminal[1]["original_utterance_id"],
                terminal[0]["original_utterance_id"],
            )
            self.assertEqual(
                [record["presentation_mode"] for record in terminal],
                ["new_delivery", "new_delivery"],
            )
            self.assertEqual(terminal[0]["requeued_as"], terminal[1]["utterance_id"])
            self.assertEqual(terminal[0]["stop_reason"], "user_stop")

    def test_stop_holds_the_queue_and_play_resumes_the_stopped_message(self):
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
        self.assertEqual(worker.calls, ["stop"])

        self.assertTrue(coordinator.play_or_replay())
        resumed = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(resumed["spoken_text"], "first")
        self.assertEqual(resumed["original_utterance_id"], first_payload["utterance_id"])
        self.assertIsNone(resumed["replay_of"])
        self.assertEqual(worker.calls, ["stop", "play"])

        worker.observer("started", resumed)
        worker.observer("completed", resumed)
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

    def test_retained_play_plays_queued_finals_in_arrival_order_across_previews(self):
        worker = FakeWorker()
        coordinator = SpeechCoordinator(worker, is_current=lambda _seq, _command_id: True)
        coordinator.arm_waiting_playback(1, "one", kind="final")
        coordinator.play()
        coordinator.arm_waiting_playback(2, "two", kind="final")

        # RR-464: an older final is not stale; it plays in its turn.
        coordinator.submit(intent(seq=1, command_id="one", kind="final", text="old"))
        old = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(worker.calls, ["play"])
        self.assertTrue(worker.eligibility(old))

        coordinator.submit(intent(seq=2, command_id="two", kind="final", text="new"))
        self.assertTrue(worker.input_queue.empty())
        self.assertEqual(worker.calls, ["play"])
        worker.observer("started", old)
        worker.observer("completed", old)
        new = worker.input_queue.get_nowait()["_speech_intent"]
        self.assertEqual(new["spoken_text"], "new")
        self.assertTrue(worker.eligibility(new))

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
                ["proposed", "tts_enqueued", "accepted", "realization"],
            )
            self.assertEqual(records[-1]["lifecycle_role"], "progress")
            self.assertEqual(records[-1]["realization_decision"], "suppress")
            self.assertEqual(records[-1]["suppression_reason"], "covered_by_played_speech")
            self.assertNotIn("private words", log.read_text())

    def test_messenger_timing_stages_are_command_scoped_and_privacy_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "speech.jsonl"
            _, coordinator, _ = self.make_coordinator(log=log)

            coordinator.record_messenger_stage(
                "user_turn_received",
                7,
                "timing-command",
                at=10.0,
                provider="codex",
            )
            coordinator.record_messenger_stage(
                "messenger_first_semantic_output",
                7,
                "timing-command",
                at=10.4,
                provider="codex",
            )
            coordinator.record_messenger_stage(
                "not_a_supported_stage",
                7,
                "timing-command",
            )

            records = [json.loads(line) for line in log.read_text().splitlines()]

        self.assertEqual(
            [record["event"] for record in records],
            ["user_turn_received", "messenger_first_semantic_output"],
        )
        self.assertTrue(all(record["relay_command_seq"] == 7 for record in records))
        self.assertTrue(all(record["relay_command_id"] == "timing-command" for record in records))
        self.assertTrue(all("text" not in record for record in records))

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


class FakeRemoteSink:
    """A Relay Remote device: frames and controls share one seq counter."""

    device_id = "phone-1"

    def __init__(self):
        self.online = True
        self.seq = 0
        self.frames: list[tuple[int, str]] = []
        self.controls: list[tuple[int, str, str]] = []

    def routable(self):
        return self.online

    def speech(self, **frame):
        self.seq += 1
        self.frames.append((self.seq, frame["text"]))
        return self.seq

    def speech_control(self, action, reason):
        self.seq += 1
        self.controls.append((self.seq, action, reason))
        return self.seq


def reply(label: str, seq: int, session: str, kind: str = "final") -> dict:
    return {"label": label, "seq": seq, "session": session, "kind": kind}


# RR-464: the queue rules from docs/architecture.md ("Speech queue rules").
# Each row is (rule, steps, expected spoken order once the queue drains).
# Steps: ("submit", reply), ("reject", reply), ("turn", seq), ("start",),
# ("stop",), ("skip",), ("depth", n), ("no_event", event, label),
# ("event", event, label).
QUEUE_RULES = (
    ("Q1 two finals from one session play in arrival order", [
        ("submit", reply("A1", 1, "a")),
        ("submit", reply("A2", 2, "a")),
        ("depth", 2),
    ], ["A1", "A2"]),
    ("Q1/Q3 finals from three sessions keep arrival order; only the newer command's progress is replaced", [
        ("submit", reply("A", 1, "a")),
        ("submit", reply("B", 2, "b")),
        ("turn", 4),
        ("submit", reply("P4", 4, "d", kind="progress")),
        ("submit", reply("C", 3, "c")),
        ("submit", reply("D", 4, "d")),
        ("depth", 4),
        ("event", "replaced", "P4"),
        ("no_event", "replaced", "A"),
        ("no_event", "interrupted", "B"),
        ("no_event", "interrupted", "C"),
    ], ["A", "B", "C", "D"]),
    ("Q5 a newer command during playback returns the playing final to the head", [
        ("submit", reply("A", 1, "a")),
        ("start",),
        ("submit", reply("B", 2, "b")),
        ("turn", 3),
        ("depth", 2),
        ("event", "interrupted", "A"),
        ("no_event", "interrupted", "B"),
    ], ["A", "B"]),
    ("Q5/Q9 a final interrupted by a newer command is lost only when skipped", [
        ("submit", reply("A", 1, "a")),
        ("start",),
        ("submit", reply("B", 2, "b")),
        ("turn", 3),
        ("skip",),
        ("depth", 1),
    ], ["B"]),
    ("Q7/Q8 stop holds the queue and Play resumes the same item", [
        ("submit", reply("A", 1, "a")),
        ("start",),
        ("stop",),
        ("submit", reply("B", 2, "b")),
        ("depth", 2),
        ("event", "stopped", "A"),
    ], ["A", "B"]),
    ("Q9 skip removes only the current item", [
        ("submit", reply("A", 1, "a")),
        ("submit", reply("B", 2, "b")),
        ("submit", reply("C", 3, "c")),
        ("start",),
        ("skip",),
        ("depth", 2),
        ("no_event", "interrupted", "B"),
    ], ["B", "C"]),
    ("Q1 five queued finals are all kept", [
        *(("submit", reply(f"F{n}", n, f"s{n}")) for n in range(1, 6)),
        ("depth", 5),
    ], [f"F{n}" for n in range(1, 6)]),
    ("Q11 the 50-item cap rejects the 51st with a diagnostic", [
        *(("submit", reply(f"F{n}", n, "a")) for n in range(1, 51)),
        ("reject", reply("F51", 51, "a")),
        ("event", "queue_full", "F51"),
        ("depth", 50),
    ], [f"F{n}" for n in range(1, 51)]),
)


class SpeechQueueRuleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / "speech.jsonl"
        self.current = (1, "cmd-1")
        self.worker = FakeWorker()
        self.coordinator = SpeechCoordinator(
            self.worker,
            is_current=lambda seq, command_id: (seq, command_id) == self.current,
            # Accepted background finals are preserved, as the bridge does.
            is_preserved=lambda seq, command_id, disposition: True,
            event_log_path=self.log,
        )
        self.ids: dict[str, str] = {}
        self.pending = None
        self.playing = None
        self.seen_calls = 0

    def build(self, spec: dict) -> SpeechIntent:
        speech = SpeechIntent.build(
            spoken_text=spec["label"],
            command_seq=spec["seq"],
            command_id=f"cmd-{spec['seq']}",
            source="orchestrator" if spec["kind"] == "final" else "lifecycle",
            kind=spec["kind"],
            authoritative=spec["kind"] == "final",
            session_key=spec["session"],
        )
        self.ids[spec["label"]] = speech.utterance_id
        return speech

    def sync_worker(self) -> None:
        """Mirror TTSWorker: stop/skip cancel what it holds; collect the rest."""
        calls = self.worker.calls[self.seen_calls:]
        self.seen_calls = len(self.worker.calls)
        if any(call in {"stop", "skip"} for call in calls) and self.playing is not None:
            playing, self.playing = self.playing, None
            self.worker.observer("cancelled", playing)
        if "skip" in calls and self.pending is not None:
            pending, self.pending = self.pending, None
            self.worker.observer("cancelled", pending)
        while not self.worker.input_queue.empty():
            self.pending = self.worker.input_queue.get_nowait()["_speech_intent"]

    def start(self) -> None:
        self.sync_worker()
        self.playing, self.pending = self.pending, None
        self.worker.observer("started", self.playing)

    def records(self, event: str, label: str) -> list[dict]:
        original = self.ids[label]
        return [
            record
            for record in (json.loads(line) for line in self.log.read_text().splitlines())
            if record["event"] == event and record["original_utterance_id"] == original
        ]

    def drain(self) -> list[str]:
        spoken = []
        for _ in range(SPEECH_QUEUE_LIMIT + 5):
            self.sync_worker()
            if self.pending is None:
                self.coordinator.play()
                self.sync_worker()
            if self.pending is None:
                break
            self.start()
            spoken.append(self.playing["spoken_text"])
            playing, self.playing = self.playing, None
            self.worker.observer("completed", playing)
        return spoken

    def run_rule(self, steps) -> list[str]:
        for step in steps:
            op = step[0]
            if op == "submit":
                self.assertTrue(self.coordinator.submit(self.build(step[1])), step)
            elif op == "reject":
                self.assertFalse(self.coordinator.submit(self.build(step[1])), step)
            elif op == "turn":
                self.current = (step[1], f"cmd-{step[1]}")
                self.coordinator.new_turn(*self.current)
            elif op == "start":
                self.start()
            elif op == "stop":
                self.coordinator.stop_playback()
            elif op == "skip":
                self.coordinator.skip()
            elif op == "depth":
                self.assertEqual(self.coordinator.queue_depth, step[1], step)
            elif op == "event":
                self.assertTrue(self.records(step[1], step[2]), step)
            elif op == "no_event":
                self.assertEqual(self.records(step[1], step[2]), [], step)
            self.sync_worker()
        return self.drain()

    def test_queue_rules(self):
        for rule, steps, expected in QUEUE_RULES:
            with self.subTest(rule=rule):
                self.setUp()
                self.assertEqual(self.run_rule(steps), expected)
                self.assertEqual(self.coordinator.queue_depth, 0)
                self.assert_replacements_name_their_own_command()

    def assert_replacements_name_their_own_command(self) -> None:
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        accepted = {
            record["utterance_id"]: (record["relay_command_seq"], record["relay_command_id"])
            for record in records
            if record["event"] == "accepted"
        }
        for record in records:
            if record["event"] == "replaced":
                self.assertEqual(
                    (record["relay_command_seq"], record["relay_command_id"]),
                    accepted[record["replaced_by"]],
                )

    def test_remote_sink_keeps_order_one_ack_each_and_returns_unplayed_finals(self):
        sink = FakeRemoteSink()
        self.coordinator.attach_remote_sink(sink)
        for step in (
            ("submit", reply("A", 1, "a")),
            ("submit", reply("B", 2, "b")),
            ("turn", 4),
            ("submit", reply("P4", 4, "d", kind="progress")),
            ("submit", reply("C", 3, "c")),
            ("submit", reply("D", 4, "d")),
        ):
            self.run_rule([step])
        self.assertEqual([text for _, text in sink.frames], ["A", "B", "P4", "C", "D"])
        # A newer command never sends a stop that would drop a queued reply.
        self.assertEqual(sink.controls, [])
        self.assertTrue(self.worker.input_queue.empty())
        seqs = {text: seq for seq, text in sink.frames}

        self.assertTrue(self.coordinator.remote_ack(sink.device_id, seqs["A"], True))
        self.assertFalse(self.coordinator.remote_ack(sink.device_id, seqs["A"], True))
        self.assertTrue(self.coordinator.remote_ack(sink.device_id, seqs["B"], True))
        self.assertEqual(len(self.records("played", "A")), 1)
        self.assertEqual(len(self.records("played", "B")), 1)

        # The device leaves: its unplayed replies come back in seq order.
        sink.online = False
        self.assertEqual(self.run_rule([("submit", reply("E", 5, "e"))]), ["C", "D", "E"])
        self.assertTrue(self.records("remote_returned", "C"))
        self.assertEqual(self.records("remote_returned", "P4"), [])
