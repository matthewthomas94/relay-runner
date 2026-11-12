"""Speech service contract: playing, stopping, skipping and replaying.

Sections "Playback control", "Sessions" and "Events" of
docs/specs/speech-service-protocol.md.
"""

from __future__ import annotations

import unittest

from speech_contract_support import LONG, LONG_SENTENCES, SHORT, SpeechCase, wait_until

HANDOFF = {"kind": "handoff", "source": "messenger", "authoritative": False}
THREE = "One sentence. Then another. And a third."


class PlaybackEventTests(SpeechCase):
    """Events: `playback`, `state` and `reply_finished`."""

    def test_playback_events_follow_the_lifecycle(self):
        """`playback`: the phases of one utterance, in order."""
        command = self.new_command()
        utterance_id = self.speak(THREE, command=command, session_key="session-a")
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")

        events = self.conn.events_named("playback", utterance_id=utterance_id)
        self.assertEqual(
            [event["phase"] for event in events],
            ["queued", "preparing", "ready", "started",
             "chunk_started", "chunk_started", "chunk_started", "completed"],
        )
        for event in events:
            self.assertEqual(event["original_utterance_id"], utterance_id)
            self.assertEqual(event["relay_command_seq"], command[0])
            self.assertEqual(event["relay_command_id"], command[1])
            self.assertEqual(event["kind"], "final")
            self.assertEqual(event["source"], "orchestrator")
            self.assertEqual(event["session_key"], "session-a")
            self.assertIsNone(event["replay_of"])
        self.assertIsNone(events[-1]["stop_reason"])
        self.assertIsNone(events[-1]["requeued_as"])
        self.assertNotIn("stop_reason", events[0])
        self.assertEqual(
            self.box.spoken(),
            [("One sentence.", True), ("Then another.", True), ("And a third.", True)],
        )

    def test_state_follows_the_reply(self):
        """`state`: `speaking`, `playing` and `queue_depth` as a reply waits, plays and ends."""
        utterance_id = self.speak(LONG)
        waiting = self.status()
        self.assertEqual(
            (waiting["speaking"], waiting["playing"], waiting["held"], waiting["queue_depth"]),
            (True, False, False, 1),
        )
        self.assertEqual(
            waiting["queue"],
            [{"utterance_id": utterance_id, "original_utterance_id": utterance_id}],
        )

        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        playing = self.status()
        self.assertEqual((playing["speaking"], playing["playing"], playing["queue_depth"]), (True, True, 1))

        self.conn.request("skip")
        self.wait_phase(utterance_id, "cancelled")
        self.assertEqual(
            self.status(),
            {"speaking": False, "playing": False, "held": False, "queue_depth": 0, "queue": []},
        )

    def test_reply_finished_when_the_last_reply_ends(self):
        """`reply_finished`: "A reply ended and nothing else is queued"."""
        first = self.speak("First reply.")
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "completed")
        self.wait_phase(second, "queued")
        self.assertEqual(self.conn.events_named("reply_finished"), [])

        self.conn.request("play")
        self.wait_phase(second, "completed")
        self.assertEqual(
            self.conn.wait_event("reply_finished"), {"event": "reply_finished", "reason": "completed"}
        )
        self.assertEqual(len(self.conn.events_named("reply_finished")), 1)

    def test_reply_finished_when_the_last_reply_is_skipped(self):
        """`reply_finished` carries `user_stop` when the user dismissed the reply."""
        utterance_id = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        self.conn.request("skip")
        self.assertEqual(self.conn.wait_event("reply_finished")["reason"], "user_stop")

    def test_handoff_ending_does_not_report_a_reply_finished(self):
        """`reply_finished` is about replies only."""
        handoff = self.speak("Looking into it.", **HANDOFF)
        self.conn.request("play")
        self.wait_phase(handoff, "completed")
        self.wait_idle()
        self.assertStays(lambda: not self.conn.events_named("reply_finished"), 0.2)


class AutoPlayTests(SpeechCase):
    """Queue rules: "with `auto_play` it plays at once"."""

    auto_play = True

    def test_each_reply_plays_as_it_reaches_the_head(self):
        texts = ["First reply.", "Second reply.", "Third reply."]
        ids = [self.speak(text) for text in texts]
        for utterance_id in ids:
            self.wait_phase(utterance_id, "completed")
        self.assertEqual(self.box.spoken(), [(text, True) for text in texts])
        # With auto_play nothing waits, so the chime never sounds.
        self.assertEqual(self.box.playback("chime"), [])


class RateTests(SpeechCase):
    """Process: `[tts]` `rate` sets how fast the output consumes audio."""

    rate = 2.0

    def test_rate_reaches_the_output(self):
        utterance_id = self.speak()
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        self.assertEqual([record["rate"] for record in self.box.playback("chunk_started")], [2.0])
        self.assertEqual([record["rate"] for record in self.box.playback("output_started")], [2.0])


class BargeInTests(SpeechCase):
    """Playback control: `stop_playback` and `pause`."""

    def test_talking_over_a_reply_counts_it_as_heard(self):
        """`stop_playback` with `recording_barge_in`: the reply leaves the queue."""
        first = self.speak(LONG)
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "started")

        self.conn.request("stop_playback", reason="recording_barge_in")

        ended = self.wait_phase(first, "cancelled")
        self.assertEqual(ended["stop_reason"], "recording_barge_in")
        self.assertIsNone(ended["requeued_as"])
        state = self.status()
        self.assertEqual([item["original_utterance_id"] for item in state["queue"]], [second])
        self.assertFalse(state["playing"])
        self.assertFalse(state["held"])
        # The audio stopped inside a sentence.
        self.wait_cut_off()
        self.assertLess(len(self.box.spoken()), len(LONG_SENTENCES))
        # Nothing else starts until the new turn.
        self.assertStays(lambda: self.phases(second) == [], 0.3, "the next reply came forward")

        command = self.new_command()
        self.conn.request("new_turn", command_seq=command[0], command_id=command[1])
        self.wait_phase(second, "queued")

    def test_reply_talked_over_stays_replayable(self):
        """`stop_playback` with `recording_barge_in`: the reply "stays replayable"."""
        first = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(first, "started")
        self.conn.request("stop_playback", reason="recording_barge_in")
        self.wait_phase(first, "cancelled")

        self.assertTrue(self.conn.request("replay")["accepted"])
        replay = self.conn.wait_event("playback", phase="started", replay_of=first)
        self.assertNotEqual(replay["utterance_id"], first)

    def test_stop_returns_the_reply_to_the_head_and_holds_the_queue(self):
        """`stop_playback` with any other reason: back to the head, queue held."""
        first = self.speak(LONG)
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "started")

        self.conn.request("stop_playback", reason="interrupt")

        ended = self.wait_phase(first, "cancelled")
        self.assertEqual(ended["stop_reason"], "interrupt")
        requeued = ended["requeued_as"]
        self.assertTrue(requeued)
        self.assertNotEqual(requeued, first)
        state = self.status()
        self.assertTrue(state["held"])
        self.assertFalse(state["playing"])
        self.assertEqual(
            state["queue"],
            [
                {"utterance_id": requeued, "original_utterance_id": first},
                {"utterance_id": second, "original_utterance_id": second},
            ],
        )
        self.assertEqual(state["queue_depth"], 2)
        self.assertStays(lambda: not self.status()["playing"], 0.3, "a held queue played")

        # The next play starts the reply again from its first sentence.
        before = len(self.box.playback("chunk_started"))
        self.conn.request("play")
        started = self.wait_phase(requeued, "started")
        self.assertEqual(started["original_utterance_id"], first)
        self.assertFalse(self.status()["held"])
        again = wait_until(
            lambda: self.box.playback("chunk_started")[before:], message="the reply to start again"
        )[0]
        self.assertEqual(again["text"], LONG_SENTENCES[0])
        self.assertEqual(again["utterance_id"], requeued)

    def test_stop_with_nothing_playing_holds_the_queue(self):
        """`stop_playback`: "With nothing playing it acts as `pause`"."""
        utterance_id = self.speak()
        self.wait_phase(utterance_id, "queued")
        self.conn.request("stop_playback")
        self.assertTrue(self.status()["held"])
        self.assertEqual(self.queue(), [utterance_id])

    def test_pause_holds_the_queue_and_play_resumes_it(self):
        """`pause`: stops the audio, holds the queue; `play` starts the reply again."""
        first = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(first, "started")
        wait_until(lambda: len(self.box.spoken()) >= 2, message="two sentences to play")

        self.conn.request("pause")

        ended = self.wait_phase(first, "cancelled")
        self.assertEqual(ended["stop_reason"], "speech_only_barge_in")
        requeued = ended["requeued_as"]
        self.assertTrue(self.status()["held"])
        self.assertEqual(self.queue(), [first])
        spoken = len(self.box.playback("chunk_started"))
        self.assertStays(
            lambda: len(self.box.playback("chunk_started")) == spoken, 0.3, "audio went on after pause"
        )

        self.conn.request("play")
        self.wait_phase(requeued, "started")
        again = wait_until(
            lambda: self.box.playback("chunk_started")[spoken:], message="the reply to start again"
        )[0]
        self.assertEqual(again["text"], LONG_SENTENCES[0])

    def test_pause_before_play_keeps_the_reply_waiting(self):
        """`pause` holds a queue whose head has not started; nothing is dropped."""
        utterance_id = self.speak()
        self.conn.request("pause")
        self.assertTrue(self.status()["held"])
        later = self.speak("Later reply.")
        self.assertEqual(self.queue(), [utterance_id, later])

        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        self.assertFalse(self.status()["held"])

    def test_play_does_nothing_while_audio_is_playing(self):
        """`play`: "Does nothing while audio is playing"."""
        first = self.speak(LONG)
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "started")
        self.conn.request("play")
        self.assertStays(lambda: self.phases(second) == [], 0.2, "play moved past the playing reply")
        self.assertNotIn("cancelled", self.phases(first))


class SkipTests(SpeechCase):
    """Playback control: `skip`."""

    def test_skip_removes_the_playing_reply_and_brings_the_next_forward(self):
        first = self.speak(LONG)
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "started")

        self.conn.request("skip")

        ended = self.wait_phase(first, "cancelled")
        self.assertEqual(ended["stop_reason"], "user_stop")
        self.assertIsNone(ended["requeued_as"])
        self.wait_phase(second, "queued")
        self.assertEqual(self.queue(), [second])
        self.assertFalse(self.status()["held"])
        self.assertEqual(self.conn.events_named("reply_finished"), [])

    def test_skip_removes_the_waiting_reply(self):
        """`skip`: "or else the one waiting at the head"."""
        first = self.speak("First reply.")
        second = self.speak("Second reply.")
        self.wait_phase(first, "queued")

        self.conn.request("skip")

        ended = self.wait_phase(first, "cancelled")
        # Nothing was playing, so no stop reason is reported.
        self.assertIsNone(ended["stop_reason"])
        self.assertIsNone(ended["requeued_as"])
        self.wait_phase(second, "queued")
        self.assertEqual(self.queue(), [second])
        self.assertEqual(self.box.spoken(), [])

    def test_skipped_reply_stays_replayable(self):
        """`skip`: the removed reply "stays replayable"."""
        for playing in (True, False):
            with self.subTest(playing=playing):
                utterance_id = self.speak(LONG)
                self.wait_phase(utterance_id, "queued")
                if playing:
                    self.conn.request("play")
                    self.wait_phase(utterance_id, "started")
                self.conn.request("skip")
                self.wait_phase(utterance_id, "cancelled")
                self.assertEqual(self.queue(), [])

                self.assertTrue(self.conn.request("replay")["accepted"])
                replay = self.conn.wait_event("playback", phase="started", replay_of=utterance_id)
                self.conn.request("skip")
                self.wait_phase(replay["utterance_id"], "cancelled")

    def test_focus_switch_skip_brings_nothing_forward(self):
        """`skip` with `focus_switch`, `wheel_stop` or `recording_barge_in`."""
        for reason in ("focus_switch", "wheel_stop", "recording_barge_in"):
            with self.subTest(reason=reason):
                first = self.speak(LONG)
                second = self.speak("Second reply.")
                self.conn.request("play")
                self.wait_phase(first, "started")

                self.conn.request("skip", reason=reason)

                ended = self.wait_phase(first, "cancelled")
                self.assertEqual(ended["stop_reason"], reason)
                self.assertIsNone(ended["requeued_as"])
                self.assertEqual(self.queue(), [second])
                self.assertStays(lambda: self.phases(second) == [], 0.2, "the next reply came forward")
                self.assertFalse(self.status()["held"])

                # The reply left behind plays on the next play.
                self.conn.request("play")
                self.wait_phase(second, "completed")
                self.wait_idle()

    def test_skip_with_nothing_queued_does_nothing(self):
        self.conn.request("skip")
        self.assertEqual(
            self.status(),
            {"speaking": False, "playing": False, "held": False, "queue_depth": 0, "queue": []},
        )
        self.assertEqual(self.conn.events_named("playback"), [])


class NewTurnTests(SpeechCase):
    """Playback control: `new_turn`."""

    def turn(self) -> tuple:
        command = self.new_command()
        self.conn.request("new_turn", command_seq=command[0], command_id=command[1])
        return command

    def test_new_turn_stops_a_playing_older_reply_which_returns_to_the_head(self):
        first = self.speak(LONG)
        second = self.speak("Second reply.")
        self.conn.request("play")
        self.wait_phase(first, "started")

        self.turn()

        ended = self.wait_phase(first, "cancelled")
        self.assertEqual(ended["stop_reason"], "newer_command")
        state = self.status()
        self.assertEqual(
            state["queue"],
            [
                {"utterance_id": ended["requeued_as"], "original_utterance_id": first},
                {"utterance_id": second, "original_utterance_id": second},
            ],
        )
        self.assertFalse(state["held"])
        self.assertFalse(state["playing"])

        self.conn.request("play")
        self.wait_phase(ended["requeued_as"], "started")

    def test_new_turn_leaves_a_reply_of_the_same_command_playing(self):
        command = self.new_command()
        utterance_id = self.speak(LONG, command=command)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        self.conn.request("new_turn", command_seq=command[0], command_id=command[1])
        self.assertStays(lambda: self.status()["playing"], 0.2, "the current command's reply stopped")

    def test_new_turn_drops_waiting_handoff_and_progress_of_older_commands(self):
        older = self.new_command()
        reply = self.speak("The answer.", command=older)
        note = self.speak("One more note.", command=older, kind="progress", source="lifecycle")
        self.assertEqual(self.queue(), [reply, note])
        self.wait_phase(reply, "queued")

        self.turn()

        self.assertEqual(self.queue(), [reply])
        self.assertEqual(self.phases(reply), ["queued"])

    def test_new_turn_drops_an_older_handoff_waiting_at_the_head(self):
        handoff = self.speak("Looking into it.", **HANDOFF)
        self.wait_phase(handoff, "queued")
        self.turn()
        self.wait_phase(handoff, "cancelled")
        self.assertEqual(self.queue(), [])

    def test_new_turn_releases_a_held_queue(self):
        utterance_id = self.speak(LONG)
        self.conn.request("play")
        self.wait_phase(utterance_id, "started")
        self.conn.request("pause")
        requeued = self.wait_phase(utterance_id, "cancelled")["requeued_as"]
        self.assertTrue(self.status()["held"])

        self.turn()

        self.assertFalse(self.status()["held"])
        # The reply waits at the head again, for the next play.
        self.wait_phase(requeued, "queued")
        self.assertEqual(self.queue(), [utterance_id])


class ReplayTests(SpeechCase):
    """Playback control: `replay`, `play_or_replay` and `read_out`."""

    def play_through(self, text: str = SHORT, **fields) -> str:
        utterance_id = self.speak(text, **fields)
        self.conn.request("play")
        self.wait_phase(utterance_id, "completed")
        return utterance_id

    def test_replay_without_history_is_refused(self):
        """`replay`: "`false` when there is none"."""
        self.assertEqual(self.conn.request("replay"), {"accepted": False})
        self.assertEqual(self.box.logged("replay_rejected")[0]["reason"], "no_completed_target")

    def test_replay_speaks_the_newest_reply_as_a_new_utterance(self):
        """`replay`: a new utterance whose `replay_of` names the original."""
        self.play_through("First reply.")
        newest = self.play_through("Second reply.")

        self.assertEqual(self.conn.request("replay"), {"accepted": True})

        # It plays at once, without another play.
        started = self.conn.wait_event("playback", phase="started", replay_of=newest)
        self.assertNotEqual(started["utterance_id"], newest)
        self.assertEqual(started["original_utterance_id"], newest)
        self.wait_phase(started["utterance_id"], "completed")
        self.assertEqual(
            [text for text, _ in self.box.spoken()], ["First reply.", "Second reply.", "Second reply."]
        )

        # A replay of a replay still names the original reply.
        self.assertTrue(self.conn.request("replay")["accepted"])
        wait_until(
            lambda: len(self.conn.events_named("playback", phase="completed", replay_of=newest)) == 2,
            message="the second replay",
        )

    def test_replay_ignores_the_current_command(self):
        """Freshness: an explicit replay is fresh whatever the current command."""
        utterance_id = self.play_through()
        self.new_command()
        self.assertTrue(self.conn.request("replay")["accepted"])
        self.conn.wait_event("playback", phase="completed", replay_of=utterance_id)

    def test_only_replayable_speech_is_replayed(self):
        """`replayable` defaults to `kind == "final"`."""
        reply = self.play_through("The answer.")
        self.play_through("Which file do you mean?", kind="clarification")
        self.play_through("Not for repeating.", replayable=False)

        self.assertTrue(self.conn.request("replay")["accepted"])
        self.conn.wait_event("playback", phase="completed", replay_of=reply)

    def test_replayable_can_be_set_on_other_kinds(self):
        question = self.play_through("Which file do you mean?", kind="clarification", replayable=True)
        self.assertTrue(self.conn.request("replay")["accepted"])
        self.conn.wait_event("playback", phase="completed", replay_of=question)

    def test_replay_joins_the_queue_behind_the_waiting_head(self):
        """`replay` also acts as `play`: the waiting head plays, the replay is next."""
        heard = self.play_through("Heard reply.")
        waiting = self.speak("Waiting reply.")
        behind = self.speak("Reply behind it.")
        self.wait_phase(waiting, "queued")

        self.assertTrue(self.conn.request("replay")["accepted"])

        self.wait_phase(waiting, "completed")
        # The replay went ahead of the reply that had not reached the head.
        self.assertEqual(self.queue(), [heard, behind])
        queued = self.conn.wait_event("playback", phase="queued", replay_of=heard)
        self.assertEqual(self.status()["queue"][0]["utterance_id"], queued["utterance_id"])

    def test_skipped_waiting_reply_is_the_newest_replay_target(self):
        """`skip`: a reply removed before it played "stays replayable"."""
        self.play_through("Heard reply.")
        waiting = self.speak("Waiting reply.")
        self.wait_phase(waiting, "queued")
        self.conn.request("skip", reason="focus_switch")
        self.wait_phase(waiting, "cancelled")

        self.assertTrue(self.conn.request("replay")["accepted"])

        self.conn.wait_event("playback", phase="completed", replay_of=waiting)
        self.assertEqual(self.box.spoken()[-1], ("Waiting reply.", True))

    def test_play_or_replay_plays_what_is_waiting(self):
        """`play_or_replay`: "`play` when a reply is waiting or queued"."""
        self.play_through("Heard reply.")
        waiting = self.speak("Waiting reply.")
        self.assertEqual(self.conn.request("play_or_replay"), {"handled": True})
        self.wait_phase(waiting, "completed")
        self.assertEqual(self.conn.events_named("playback", phase="started", replay_of=None)[-1]["utterance_id"], waiting)

    def test_play_or_replay_replays_when_nothing_is_queued(self):
        """`play_or_replay`: "otherwise `replay`"."""
        self.assertEqual(self.conn.request("play_or_replay"), {"handled": False})
        heard = self.play_through("Heard reply.")
        self.wait_idle()
        self.assertEqual(self.conn.request("play_or_replay"), {"handled": True})
        self.conn.wait_event("playback", phase="completed", replay_of=heard)

    def test_read_out_speaks_the_text_at_once(self):
        """`read_out`: queues the text as a replayable reply and plays it."""
        self.assertEqual(self.conn.request("read_out", text="A stored reply."), {"accepted": True})
        wait_until(lambda: self.box.spoken() == [("A stored reply.", True)], message="the text to play")
        self.wait_idle()

        self.assertTrue(self.conn.request("replay")["accepted"])
        wait_until(lambda: len(self.box.spoken()) == 2, message="the replay")
        self.assertEqual(self.box.spoken()[-1], ("A stored reply.", True))

    def test_read_out_twice_speaks_twice(self):
        """`read_out` is never deduplicated against an earlier one."""
        for count in (1, 2):
            self.assertTrue(self.conn.request("read_out", text="A stored reply.")["accepted"])
            wait_until(lambda: len(self.box.spoken()) == count, message="the text to play")
            self.wait_idle()

    def test_read_out_refuses_empty_text(self):
        self.assertEqual(self.conn.request("read_out", text="  "), {"accepted": False})


class ReplayHistoryTests(SpeechCase):
    """Queue rules: "The newest 32 replayable replies ... form the replay history"."""

    auto_play = True

    def test_history_keeps_the_newest_thirty_two(self):
        ids = [self.speak(f"Reply {number}.", session_key=f"session-{number}") for number in range(33)]
        self.wait_phase(ids[-1], "completed")
        self.wait_idle()

        states = self.conn.request("session_playback_states")["states"]

        self.assertEqual(states, {f"session-{number}": "replay" for number in range(1, 33)})


class WaitingPlaybackTests(SpeechCase):
    """Speaking: `arm_waiting_playback` and `waiting_playback_kind`."""

    def test_armed_play_is_kept_for_the_commands_reply(self):
        """`arm_waiting_playback` binds the next play gesture to the command's speech."""
        command = self.new_command()
        self.conn.request("arm_waiting_playback", command_seq=command[0], command_id=command[1])
        self.conn.request("play")

        utterance_id = self.speak(command=command)

        # The reply plays as it arrives; no second play is needed.
        self.wait_phase(utterance_id, "completed")

    def test_armed_play_skips_another_commands_handoff(self):
        """The armed play is for the named command's speech only."""
        handoff = self.speak("Looking into it.", **HANDOFF)
        self.wait_phase(handoff, "queued")
        command = self.new_command()
        self.conn.request("arm_waiting_playback", command_seq=command[0], command_id=command[1])
        self.conn.request("play")
        self.assertStays(lambda: "started" not in self.phases(handoff), 0.2, "the handoff took the play")

    def test_waiting_playback_kind_arms_with_the_speak(self):
        """`speak` with `waiting_playback_kind` arms and proposes in one request."""
        command = self.new_command()
        self.speak(command=command, waiting_playback_kind="final")
        states = self.conn.request("session_playback_states", waiting_session_key="session-a")["states"]
        self.assertEqual(states, {"session-a": "play"})


class SessionTests(SpeechCase):
    """Sessions: `session_playback_states` and `control_session`."""

    def states(self, **params) -> dict:
        return self.conn.request("session_playback_states", **params)["states"]

    def control(self, session_key: str, action: str, **params) -> bool:
        return self.conn.request("control_session", session_key=session_key, action=action, **params)["handled"]

    def test_states_follow_each_sessions_reply(self):
        """`session_playback_states`: `play`, `stop` or `replay` per session key."""
        self.assertEqual(self.states(), {})
        first = self.speak(LONG, session_key="session-a")
        self.speak("Second reply.", session_key="session-b")
        self.speak("No session.")
        self.assertEqual(self.states(), {"session-a": "play", "session-b": "play"})

        self.conn.request("play")
        self.wait_phase(first, "started")
        self.assertEqual(self.states(), {"session-a": "stop", "session-b": "play"})

        self.conn.request("skip")
        self.wait_phase(first, "cancelled")
        self.assertEqual(self.states(), {"session-a": "replay", "session-b": "play"})

    def test_waiting_session_key_needs_an_armed_preview(self):
        self.assertEqual(self.states(waiting_session_key="session-a"), {})
        command = self.new_command()
        self.conn.request("arm_waiting_playback", command_seq=command[0], command_id=command[1])
        self.assertEqual(self.states(waiting_session_key="session-a"), {"session-a": "play"})

    def test_stop_acts_on_its_own_session_only(self):
        """`control_session`: "`false` when the action does not apply to that session"."""
        first = self.speak(LONG, session_key="session-a")
        self.speak("Second reply.", session_key="session-b")
        self.conn.request("play")
        self.wait_phase(first, "started")

        self.assertFalse(self.control("session-b", "stop"))
        self.assertStays(lambda: self.status()["playing"], 0.2, "another session's stop was taken")

        self.assertTrue(self.control("session-a", "stop"))
        ended = self.wait_phase(first, "cancelled")
        self.assertEqual(ended["stop_reason"], "wheel_stop")
        # A stop keeps the reply: it returns to the head and the queue is held.
        self.assertTrue(ended["requeued_as"])
        self.assertTrue(self.status()["held"])
        self.assertEqual(self.states(), {"session-a": "play", "session-b": "play"})

    def test_stop_with_nothing_playing_is_not_handled(self):
        self.speak(session_key="session-a")
        self.assertFalse(self.control("session-a", "stop"))

    def test_play_brings_a_sessions_queued_reply_forward(self):
        """`control_session` `play`: "brings its queued reply forward and plays it"."""
        first = self.speak("First reply.", session_key="session-a")
        second = self.speak("Second reply.", session_key="session-b")
        self.wait_phase(first, "queued")

        self.assertTrue(self.control("session-b", "play"))

        self.wait_phase(second, "completed")
        # The reply it passed keeps its identity and waits at the head again.
        self.assertEqual(self.queue(), [first])
        wait_until(lambda: self.phases(first) == ["queued", "cancelled", "queued"], message="the passed reply")
        self.assertEqual(self.status()["queue"], [{"utterance_id": first, "original_utterance_id": first}])
        self.assertEqual(self.box.spoken(), [("Second reply.", True)])

    def test_play_plays_the_sessions_waiting_reply(self):
        utterance_id = self.speak(session_key="session-a")
        self.assertTrue(self.control("session-a", "play"))
        self.wait_phase(utterance_id, "completed")

    def test_play_for_a_session_with_nothing_queued_is_not_handled(self):
        utterance_id = self.speak(session_key="session-a")
        self.wait_phase(utterance_id, "queued")
        self.assertFalse(self.control("session-b", "play"))
        self.assertEqual(self.phases(utterance_id), ["queued"])

    def test_play_while_another_session_plays_is_not_handled(self):
        first = self.speak(LONG, session_key="session-a")
        second = self.speak("Second reply.", session_key="session-b")
        self.conn.request("play")
        self.wait_phase(first, "started")
        self.assertFalse(self.control("session-b", "play"))
        self.assertTrue(self.control("session-a", "play"), "its own reply is already playing")
        self.assertEqual(self.queue(), [first, second])

    def test_replay_repeats_the_sessions_newest_reply(self):
        """`control_session` `replay`: "replays its newest reply"."""
        heard = {}
        for session_key in ("session-a", "session-b"):
            heard[session_key] = self.speak(f"Reply for {session_key}.", session_key=session_key)
            self.conn.request("play")
            self.wait_phase(heard[session_key], "completed")

        self.assertTrue(self.control("session-a", "replay"))

        replay = self.conn.wait_event("playback", phase="completed", replay_of=heard["session-a"])
        self.assertEqual(replay["session_key"], "session-a")
        self.assertEqual(self.box.spoken()[-1], ("Reply for session-a.", True))
        self.assertFalse(self.control("session-c", "replay"))


if __name__ == "__main__":
    unittest.main()
