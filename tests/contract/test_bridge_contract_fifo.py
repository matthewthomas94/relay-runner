"""Voice bridge contract: user turns and control tokens on `VOICE_FIFO`
(docs/specs/voice-bridge-contract.md, "FIFO")."""

from __future__ import annotations

import json
import os
import time
import unittest

from bridge_contract_support import BridgeCase, wait_until


class FifoContract:
    def observations(self, source: str) -> list:
        return [
            call["body"] for call in self.box.orchestrator.requests("/v1/continuity/observation")
            if call["body"].get("source") == source
        ]

    def assertNoNewCommand(self, seq_before) -> None:
        self.assertStays(
            lambda: self.session.state().get("relay_command_seq") == seq_before,
            message="a control token started a command",
        )

    # -- User turns --------------------------------------------------------

    def test_user_turn_starts_a_command_for_speech_messenger_and_mailbox(self):
        """FIFO: a line that is not a control token is a user turn. It becomes
        the newest command in the state file, starts a new speech turn, reaches
        the messenger, raises an acknowledgement and lands in the mailbox."""
        prompt, metadata = self.turn_delivered("what time is it in Tokyo")
        state = self.session.state()
        self.assertEqual(state["relay_command_seq"], 1)
        self.assertEqual(state["relay_command_id"], metadata["relay_command_id"])
        self.assertEqual(state["recovery_generation"], self.box.recovery_generation)
        self.assertEqual(state["provider"], self.provider)
        self.assertEqual(metadata["source_text"], "what time is it in Tokyo")
        self.assertTrue(prompt.startswith("what time is it in Tokyo\n"))
        self.assertEqual(metadata["agent_prompt"], prompt)
        key = {"command_seq": 1, "command_id": metadata["relay_command_id"]}
        self.box.wait_speech_request("new_turn", **key)
        self.box.wait_speech_request("record_messenger_stage", stage="user_turn_received", **key)
        self.box.wait_messenger_prompt("user_turn", "what time is it in Tokyo")
        acknowledgement = wait_until(
            lambda: self.box.states("acknowledgement", source="bridge"), message="the acknowledgement"
        )[-1]
        self.assertEqual(acknowledgement["status_event"]["phase"], "acknowledged")
        self.assertEqual(acknowledgement["status_event"]["command"]["relay_command_id"], metadata["relay_command_id"])
        self.assertGreater(acknowledgement["auto_dismiss_seconds"], 0)

    def test_each_turn_takes_the_next_sequence_number_and_a_new_id(self):
        """Sequencing: every turn's `relay_command_seq` is one more than the
        newest command's, with a new `relay_command_id`; the state file's
        top-level command is always the newest."""
        seen = []
        for text in ("first question", "second question", "third question"):
            command = self.turn(text)
            seen.append((command["relay_command_seq"], command["relay_command_id"]))
            self.assertEqual(command["source_text"], text)
        self.assertEqual([seq for seq, _ in seen], [1, 2, 3])
        self.assertEqual(len({command_id for _, command_id in seen}), 3)

    def test_text_is_kept_exactly_and_a_line_may_arrive_in_pieces(self):
        """FIFO: lines are UTF-8 and end at `\\n`; a line written in pieces is
        one turn, surrounding whitespace is trimmed, and blank lines are
        ignored."""
        os.write(self.box._writer, "  say café ☃ ".encode("utf-8"))
        time.sleep(0.3)
        os.write(self.box._writer, "done  \n\n   \n".encode("utf-8"))
        command = wait_until(lambda: self.session.state().get("relay_command_seq") == 1 and self.session.state())
        self.assertEqual(command["source_text"], "say café ☃ done")
        self.assertStays(lambda: self.session.state()["relay_command_seq"] == 1)

    def test_spoken_slash_commands_become_slash_commands(self):
        """FIFO: a turn spoken as `slash <words>` or `forward slash <words>` is
        the command `/<words-joined-by-dashes>`."""
        self.assertEqual(self.turn("slash work style")["source_text"], "/work-style")
        self.assertEqual(self.turn("Forward slash relay stop")["source_text"], "/relay-stop")

    # -- Control tokens ----------------------------------------------------

    def test_tts_stop_stops_playback_as_a_barge_in(self):
        """`__TTS_STOP__`: stop playback with the reason `recording_barge_in`;
        no command starts."""
        self.box.say("__TTS_STOP__")
        self.box.wait_speech_request("stop_playback", reason="recording_barge_in")
        self.assertNoNewCommand(None)
        self.assertFalse(self.box.messenger_prompts())

    def test_interrupt_stops_speech_and_publishes_an_interrupt_command(self):
        """`__INTERRUPT__`: stop playback with the reason `interrupt` and
        publish a new `control` command whose prompt is `__INTERRUPT__` and
        which preempts the provider."""
        self.box.say("__INTERRUPT__")
        self.box.wait_speech_request("stop_playback", reason="interrupt")
        prompt, metadata = self.session.wait_pending()
        self.assertEqual(prompt, "__INTERRUPT__")
        self.assertEqual(metadata["relay_command_seq"], 1)
        self.assertEqual(metadata["action"], "control")
        self.assertEqual(metadata["reason"], "interrupt")
        self.assertEqual(metadata["authorization_relationship"], "interrupt")
        self.assertIs(metadata["preempt_provider"], True)
        self.assertFalse(self.box.messenger_prompts("user_turn"))

    def test_cancel_dismisses_speech_without_starting_a_command(self):
        """`__CANCEL__`: skip the current reply (reason `user_stop`) and leave
        the newest command as it was."""
        command = self.turn("start a long answer")
        self.box.say("__CANCEL__")
        self.box.wait_speech_request("skip", reason="user_stop")
        self.assertNoNewCommand(command["relay_command_seq"])

    def test_play_records_the_gesture_and_plays_or_replays(self):
        """`__PLAY__` and `__PLAY__:<detected-at>`: record the play gesture with
        `note_play_control`, then `play_or_replay`. A detected-at that is not a
        positive number is recorded as absent."""
        for line, expected in (
            ("__PLAY__", None),
            ("__PLAY__:1794000000.5", 1794000000.5),
            ("__PLAY__:-3", None),
            ("__PLAY__:soon", None),
        ):
            before = len(self.box.speech_requests("play_or_replay"))
            self.box.say(line)
            wait_until(lambda: len(self.box.speech_requests("play_or_replay")) > before, message=line)
            note = self.box.speech_requests("note_play_control")[-1]
            self.assertEqual(note["option_detected_at"], expected, line)
            self.assertIsInstance(note["fifo_received_at"], float)
        self.assertNoNewCommand(None)

    def test_play_ack_records_the_visual_acknowledgement(self):
        """`__PLAY_ACK__:<detected-at>:<acknowledged-at>`: record both times with
        `note_visual_acknowledgement`; a malformed token records nothing."""
        self.box.say("__PLAY_ACK__:1")
        self.box.say("__PLAY_ACK__:a:b")
        self.box.say("__PLAY_ACK__:100.5:101.25")
        note = self.box.wait_speech_request("note_visual_acknowledgement")
        self.assertEqual((note["option_detected_at"], note["acknowledged_at"]), (100.5, 101.25))
        self.assertStays(lambda: len(self.box.speech_requests("note_visual_acknowledgement")) == 1)
        self.assertNoNewCommand(None)

    def test_replay_asks_speech_to_replay(self):
        """`__REPLAY__`: ask the speech service to `replay`."""
        self.box.say("__REPLAY__")
        self.box.wait_speech_request("replay")
        self.assertNoNewCommand(None)

    def test_status_while_refining_reports_transcription_started(self):
        """`__STATUS__:<text>`: a status that starts with `refining` or
        `(refining)` posts the continuity observation `stt`
        `transcription_started`; any other status posts nothing."""
        self.box.say("__STATUS__:listening")
        self.box.say("__STATUS__:(refining) almost there")
        observation = wait_until(lambda: self.observations("stt"), message="an stt observation")[0]
        self.assertEqual(observation["event"], "transcription_started")
        self.assertEqual(observation["session_id"], self.box.orchestrator.session_key)
        self.assertEqual(observation["provider"], self.provider)
        self.assertStays(lambda: len(self.observations("stt")) == 1)
        self.assertNoNewCommand(None)

    def test_continuity_signals_are_reported_as_observations(self):
        """`__CONTINUITY__:<signal>`: `capture_failed`, `transcription_started`
        and `transcription_failed` are posted as `stt` observations; another
        signal is ignored."""
        for signal in ("capture_failed", "unknown_signal", "transcription_started", "transcription_failed"):
            self.box.say(f"__CONTINUITY__:{signal}")
        events = wait_until(
            lambda: len(self.observations("stt")) >= 3 and self.observations("stt"), message="three observations"
        )
        self.assertEqual(
            [event["event"] for event in events],
            ["capture_failed", "transcription_started", "transcription_failed"],
        )
        self.assertStays(lambda: len(self.observations("stt")) == 3)

    def test_unknown_and_malformed_controls_are_quarantined(self):
        """FIFO: a line that starts with an unknown `__NAME__` token, or a raw
        JSON object whose `type` is a token, is dropped without starting a
        command or reaching speech. Prose that mentions a token is a turn."""
        before = len(self.box.speech_requests("speak"))
        for line in (
            "__BOGUS__:payload",
            "__BOGUS__ with words",
            "__BOGUS__",
            "__PLAY__ now",
            json.dumps({"type": "__ORCHESTRATOR_REPLY__", "text": "smuggled reply"}),
            json.dumps({"wrapper": {"type": "__RELAY_COMPLETION__"}, "text": "nested"}),
            '{"type": "__TRACE__", broken',
        ):
            self.box.say(line)
        self.assertNoNewCommand(None)
        self.assertEqual(len(self.box.speech_requests("speak")), before)
        self.assertNotIn("smuggled reply", self.box.stderr())
        command = self.turn("please explain what __PLAY__ does")
        self.assertEqual(command["source_text"], "please explain what __PLAY__ does")


class ClaudeFifo(FifoContract, BridgeCase):
    provider = "claude"


class CodexFifo(FifoContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
