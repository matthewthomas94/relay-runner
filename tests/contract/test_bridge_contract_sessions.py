"""Voice bridge contract: several app sessions on one bridge, focus and voice
targeting (docs/specs/voice-bridge-contract.md, "Sessions")."""

from __future__ import annotations

import json
import os
import unittest

from bridge_contract_support import BridgeCase, read_json, wait_until


def focus(box, session, **fields) -> None:
    box.control("__FOCUS__:" + json.dumps(session.focus_payload(**fields)))


class SessionCase(BridgeCase):
    def register(self, key: str = "session-2", **fields):
        """Add a session and send its `__FOCUS__`; wait until the bridge took it."""
        session = self.box.add_session(key)
        focus(self.box, session, **fields)
        if fields.get("focus", True):
            wait_until(
                lambda: self.box.runtime_file("voice_bridge.spool").exists()
                and self.box.runtime_file("voice_bridge.spool").read_text().strip() == str(session.spool),
                message=f"the bridge to focus {key}",
            )
        else:
            # A registered session registers its own orchestrator session.
            wait_until(
                lambda: [
                    call for call in self.box.orchestrator.requests("/v1/orchestrator-session/ensure")
                    if call["body"]["repo_path"] == os.path.realpath(session.cwd)
                ],
                message=f"the bridge to register {key}",
            )
        return session

    def refocus(self, session) -> None:
        focus(self.box, session)
        spool = self.box.runtime_file("voice_bridge.spool")
        wait_until(
            lambda: spool.exists() and spool.read_text().strip() == str(session.spool),
            message=f"the bridge to focus {session.key}",
        )

    def turn_in(self, session, text: str) -> tuple:
        """Say a turn and wait for its command in ``session``'s mailbox."""
        before = self.session.state().get("relay_command_seq") or 0
        self.box.say(text)
        return wait_until(
            lambda: (
                session.pending()
                if session.pending()
                and session.pending()[1].get("relay_command_seq", 0) > before
                and session.pending()[1].get("source_text") == text
                else None
            ),
            message=f"{text!r} in the mailbox of {session.key}",
        )

    def hand_over(self, session) -> None:
        """Claim and acknowledge the waiting command, as the provider does."""
        claimed = session.claim()
        session.acknowledge(claimed)
        self.box.wait_intent_state(claimed["intent_id"], "acked")


class SessionsContract:
    def test_focus_moves_turns_to_the_focused_session(self):
        """Sessions: a valid `__FOCUS__` registers and focuses a session. The
        next turn lands in its spool mailbox with `voice_target_session_key`,
        the bridge rewrites `voice_bridge.cwd`, `.provider` and `.spool` in
        `RELAY_BRIDGE_RUNTIME_DIR`, the state file gains
        `session_commands[<key>]`, and the state file is mirrored into the
        focused session's spool."""
        other = self.register()
        self.assertEqual(self.box.runtime_file("voice_bridge.cwd").read_text(), f"{other.cwd}\n")
        self.assertEqual(self.box.runtime_file("voice_bridge.provider").read_text(), f"{self.provider}\n")
        self.assertEqual(self.box.runtime_file("voice_bridge.spool").read_text(), f"{other.spool}\n")
        _, metadata = self.turn_in(other, "check the other session")
        self.assertEqual(metadata["voice_target_session_key"], other.key)
        self.assertIsNone(self.session.pending())
        state = wait_until(
            lambda: self.session.state() if other.key in self.session.state().get("session_commands", {}) else None,
            message="session_commands",
        )
        entry = state["session_commands"][other.key]
        self.assertEqual(entry["relay_command_id"], metadata["relay_command_id"])
        self.assertEqual(entry["relay_command_seq"], metadata["relay_command_seq"])
        self.assertEqual(entry["intent_id"], metadata["intent_id"])
        wait_until(
            lambda: other.state().get("relay_command_id") == metadata["relay_command_id"],
            message="the state file mirrored into the focused spool",
        )

    def test_invalid_focus_payloads_are_rejected(self):
        """Sessions: a `__FOCUS__` whose key does not match its spool's name,
        whose spool is outside `<runtime>/relay-sessions`, whose cwd is
        relative, whose key has other characters than `a-z0-9-`, or that is
        not a JSON object is ignored; turns keep going to the current session."""
        other = self.box.add_session("session-2")
        outside = self.box.root / "elsewhere" / "session-2"
        outside.mkdir(parents=True)
        for payload in (
            other.focus_payload(session_key="session-3"),
            other.focus_payload(spool_dir=str(outside)),
            other.focus_payload(cwd="repo-session-2"),
            other.focus_payload(session_key="Session_2", spool_dir=str(other.spool.parent / "Session_2")),
            other.focus_payload(cwd=""),
        ):
            self.box.control("__FOCUS__:" + json.dumps(payload))
        self.box.control("__FOCUS__:{not json")
        self.box.control("__FOCUS__:[1, 2]")
        _, metadata = self.turn_delivered("where does this go")
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)
        self.assertIsNone(other.pending())
        self.assertFalse(self.box.runtime_file("voice_bridge.spool").exists())

    def test_focus_false_registers_without_focusing(self):
        """Sessions: `"focus": false` registers a session without focusing it;
        turns stay with the focused session and the bridge files are not
        rewritten."""
        other = self.register(focus=False)
        _, metadata = self.turn_delivered("stay where you are")
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)
        self.assertIsNone(other.pending())
        self.assertFalse(self.box.runtime_file("voice_bridge.spool").exists())

    def test_voice_target_pins_only_the_next_transcript(self):
        """Sessions: `__VOICE_TARGET__:<key>` pins the next transcript to that
        session, even when focus moves before it arrives. Only that one
        transcript is pinned."""
        other = self.register(focus=False)
        self.box.say(f"__VOICE_TARGET__:{other.key}")
        self.turn_in(other, "pinned to the other session")
        _, metadata = self.turn_delivered("back to the focused session")
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)
        # Pin the startup session, then move focus away before the transcript.
        self.hand_over(self.session)
        self.box.say(f"__VOICE_TARGET__:{self.session.key}")
        self.refocus(other)
        _, metadata = self.turn_delivered("recorded before the focus moved")
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)

    def test_cancel_clears_a_voice_target_pin(self):
        """Sessions: `__CANCEL__` clears a pending `__VOICE_TARGET__` pin."""
        other = self.register(focus=False)
        self.box.say(f"__VOICE_TARGET__:{other.key}")
        self.box.say("__CANCEL__")
        _, metadata = self.turn_delivered("the pin was cancelled")
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)
        self.assertIsNone(other.pending())

    def test_each_added_session_registers_its_own_orchestrator_session(self):
        """Sessions: a session other than the startup one registers its own
        orchestrator session for its working directory; when
        `live_session_keys` omits it, that registration is stopped with the
        reason `voice session ended`."""
        orchestrator = self.box.orchestrator
        other = self.register()
        ensure = wait_until(
            lambda: [
                call for call in orchestrator.requests("/v1/orchestrator-session/ensure")
                if call["body"]["repo_path"] == os.path.realpath(other.cwd)
            ],
            message="the second session's registration",
        )[0]
        self.assertEqual(ensure["body"]["provider"], self.provider)
        self.assertFalse(orchestrator.requests("/v1/orchestrator-session/stop"))
        focus(self.box, self.session, live_session_keys=[self.session.key])
        stop = wait_until(
            lambda: orchestrator.requests("/v1/orchestrator-session/stop"), message="the stop"
        )[0]
        self.assertEqual(stop["body"], {"session_id": orchestrator.session_id, "reason": "voice session ended"})

    def test_pruned_session_hands_its_undelivered_command_to_the_focused_session(self):
        """Sessions: a session that `live_session_keys` omits is dropped; a
        command waiting unclaimed in its mailbox moves to the focused
        session's mailbox, and its mutation grants move to that session."""
        other = self.register()
        prompt, metadata = self.turn_in(other, "create a ticket for the flaky login test")
        focus(self.box, self.session, live_session_keys=[self.session.key])
        moved_prompt, moved = self.session.wait_pending("the handed-off command")
        self.assertEqual(moved_prompt, prompt)
        self.assertEqual(moved["relay_command_id"], metadata["relay_command_id"])
        self.assertIsNone(other.pending())
        records = read_json(self.box.authorizations).get("authorizations", [])
        granted = [record for record in records if record.get("relay_command_id") == metadata["relay_command_id"]]
        self.assertTrue(granted)
        for record in granted:
            if record.get("status") == "active":
                self.assertEqual(record.get("relay_session_key"), self.session.key)
        # The dropped session no longer takes a voice target pin.
        self.hand_over(self.session)
        self.box.say(f"__VOICE_TARGET__:{other.key}")
        _, metadata = self.turn_delivered("the other session is gone")
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)

    def test_background_reply_is_spoken_in_its_session_without_a_badge(self):
        """Sessions: a reply for a background session's current command is
        spoken too (RR-488). It skips the messenger and reaches speech as a
        `speak` for that session with no command key, only its own outcome
        slot `outcome:<seq>:<id>`. It is judged against
        `session_commands[<key>]`, not the newest command of another session,
        so the same reply without its session is dropped. No
        `voice_reply_badge.json` is written."""
        other = self.register()
        _, command = self.turn_in(other, "summarise the other repository")
        self.refocus(self.session)
        # The newest command overall is project work in the startup session,
        # which does not preserve the other session's command.
        self.turn_delivered("create a ticket for the broken build")
        finals_before = len(self.box.messenger_prompts("orchestrator_final"))
        self.box.say(self.reply_line(command, "Reply without its session."))
        self.box.say(self.reply_line(command, "The other repository is tidy.", session_key=other.key))
        spoken = self.box.wait_spoken(text="The other repository is tidy.")
        self.assertEqual(spoken["session_key"], other.key)
        self.assertEqual(
            spoken["dedup_key"], f"outcome:{command['relay_command_seq']}:{command['relay_command_id']}"
        )
        self.assertIsNone(spoken.get("command_seq"))
        self.assertStays(lambda: (
            not self.box.spoken(text="Reply without its session.")
            and len(self.box.spoken(text="The other repository is tidy.")) == 1
            and len(self.box.messenger_prompts("orchestrator_final")) == finals_before
        ))
        self.refocus(other)
        self.assertFalse(other.badge.exists())
        self.assertFalse(self.session.badge.exists())

    def test_background_completion_is_matched_by_its_provider_session(self):
        """Sessions: a `__RELAY_COMPLETION__` names no session key; its
        `session_id` is matched to the session whose provider session it is,
        and a background session's reply is spoken for that session."""
        other = self.register()
        _, command = self.turn_in(other, "look at the other tests")
        self.refocus(self.session)
        self.box.say(self.completion_line(command, "The other tests pass.", session_id=other.provider_session_id))
        spoken = self.box.wait_spoken(text="The other tests pass.")
        self.assertEqual(spoken["session_key"], other.key)
        self.assertFalse(other.badge.exists())

    def test_replay_asks_speech_to_play_then_replay_the_session(self):
        """Sessions: `__REPLAY__:{"session_key": ...}` on the control socket asks
        speech to `control_session` the session with `play` (queued speech
        first) and, when that is not handled, `replay` (its replay history).
        The bridge reads nothing out itself; an unknown session does nothing."""
        other = self.register()
        self.box.control("__REPLAY__:" + json.dumps({"session_key": "session-9"}))
        self.box.control("__REPLAY__:" + json.dumps({"session_key": other.key}))
        replay = self.box.wait_speech_request("control_session", action="replay")
        self.assertEqual(replay["session_key"], other.key)
        self.assertEqual(
            [(request["session_key"], request["action"]) for request in self.box.speech_requests("control_session")],
            [(other.key, "play"), (other.key, "replay")],
        )
        self.assertStays(lambda: not self.box.speech_requests("read_out"))

    def test_session_playback_asks_speech_for_the_session(self):
        """Sessions: `__SESSION_PLAYBACK__` with `play` asks speech to
        `control_session` with `play`, then `replay` when that is not handled.
        `stop` only asks `control_session` with `stop`. An unknown session or
        action does nothing, and the bridge never reads a reply out itself."""
        other = self.register()
        for payload in (
            {"session_key": "session-9", "action": "play"},
            {"session_key": other.key, "action": "pause"},
            {"session_key": other.key, "action": "stop"},
        ):
            self.box.control("__SESSION_PLAYBACK__:" + json.dumps(payload))
        stop = self.box.wait_speech_request("control_session", action="stop")
        self.assertEqual(stop["session_key"], other.key)
        self.box.control("__SESSION_PLAYBACK__:" + json.dumps({"session_key": other.key, "action": "play"}))
        self.box.wait_speech_request("control_session", action="replay")
        self.assertEqual(
            [(request["session_key"], request["action"]) for request in self.box.speech_requests("control_session")],
            [(other.key, "stop"), (other.key, "play"), (other.key, "replay")],
        )
        self.assertStays(lambda: not self.box.speech_requests("read_out"))

    def test_focused_session_hears_its_outcomes_and_others_wait_for_focus(self):
        """Sessions: undelivered worker outcomes are fetched per session key.
        The focused session's outcomes go to the messenger and are marked
        delivered; a background session's outcomes are left undelivered, and
        uncounted, until it is focused, when they are delivered."""
        orchestrator = self.box.orchestrator
        scoped = {
            self.session.key: [{"id": 1, "payload": {"trace_event": {
                "kind": "run-succeeded", "message": "Worker RR-7 finished.", "source": "orchestrator",
            }}}],
            "session-2": [
                {"id": 2, "payload": {"trace_event": {
                    "kind": "run-failed", "message": "Worker RR-8 failed.", "source": "orchestrator",
                    "ticket_id": "RR-8",
                }}},
                {"id": 3, "payload": {"trace_event": {
                    "kind": "run-merged", "message": "Worker RR-9 merged.", "source": "orchestrator",
                    "ticket_id": "RR-9",
                }}},
            ],
        }
        respond = orchestrator.respond

        def scoped_respond(call):
            path = call["path"]
            if path == "/v1/messenger/outcomes":
                with orchestrator.lock:
                    return 200, {"outcomes": list(scoped.get(call["query"].get("session_key"), []))}
            if path.startswith("/v1/messenger/outcomes/") and path.endswith("/delivered"):
                outcome_id = int(path.split("/")[4])
                with orchestrator.lock:
                    for key in scoped:
                        scoped[key] = [item for item in scoped[key] if item["id"] != outcome_id]
                return 200, {"delivered": True}
            return respond(call)

        orchestrator.respond = scoped_respond
        other = self.register(focus=False)
        self.box.wait_messenger_prompt("orchestrator_trace", "Worker RR-7 finished.")
        wait_until(lambda: orchestrator.requests("/v1/messenger/outcomes/1/delivered"), message="outcome 1 delivered")
        focused = [
            call["query"] for call in orchestrator.requests("/v1/messenger/outcomes")
            if call["query"].get("session_key") == self.session.key
        ][-1]
        self.assertEqual(focused["live_session_keys"], f"{self.session.key},{other.key}")
        self.assertEqual(focused["repo_path"], os.path.realpath(self.box.repo))
        self.assertStays(lambda: not orchestrator.requests("/v1/messenger/outcomes/2/delivered"))
        self.assertFalse(other.badge.exists())
        self.refocus(other)
        wait_until(
            lambda: orchestrator.requests("/v1/messenger/outcomes/2/delivered")
            and orchestrator.requests("/v1/messenger/outcomes/3/delivered"),
            message="the background outcomes delivered",
        )
        background = [
            call["query"] for call in orchestrator.requests("/v1/messenger/outcomes")
            if call["query"].get("session_key") == other.key
        ][-1]
        self.assertEqual(background["repo_path"], str(other.cwd))
        self.assertEqual(background["provider"], self.provider)
        # Two outcomes are summarised as one update.
        self.box.wait_messenger_prompt("orchestrator_trace", "2 Relay work updates accumulated")
        self.assertFalse(other.badge.exists())


class QuietSessionsContract:
    """Sessions cases that need an empty speech queue: no greeting, no messenger."""

    greeting = False
    messenger = False

    def test_focus_switch_leaves_playing_speech_alone(self):
        """Sessions: changing focus, while speech is playing or not, sends
        speech no `skip`, `stop_playback` or `pause` (RR-488): a reply playing
        or queued is still heard."""
        other = self.register()
        self.refocus(self.session)
        self.box.speech_command(op="playing", value=True)
        wait_until(lambda: any(
            record.get("record") == "control" and record.get("op") == "playing"
            for record in self.box.speech_records()
        ), message="the fake to play")
        self.refocus(other)
        self.refocus(self.session)
        self.assertStays(lambda: not (
            self.box.speech_requests("skip")
            or self.box.speech_requests("stop_playback")
            or self.box.speech_requests("pause")
        ))

    def test_background_reply_queues_behind_playing_speech_once(self):
        """Sessions: a background session's reply that arrives while speech is
        playing is handed to speech as one `speak` and never cuts in: the
        bridge sends no `skip`, `stop_playback` or `pause`. When speech
        reports `reply_finished`, or `__CANCEL__` skips it, the bridge offers
        nothing again; the speech queue owns what plays next."""
        other = self.register()
        _, command = self.turn_in(other, "how is the other build")
        self.refocus(self.session)
        self.box.speech_command(op="playing", value=True)
        self.box.say(self.reply_line(command, "The other build is green.", session_key=other.key))
        spoken = self.box.wait_spoken(text="The other build is green.")
        self.assertEqual(spoken["session_key"], other.key)
        self.assertStays(lambda: not (
            self.box.speech_requests("skip")
            or self.box.speech_requests("stop_playback")
            or self.box.speech_requests("pause")
        ))
        self.box.speech_command(op="finish")
        self.box.say("__CANCEL__")
        self.box.wait_speech_request("skip")
        self.assertStays(lambda: len(self.box.spoken(text="The other build is green.")) == 1)


class ClaudeSessions(SessionsContract, SessionCase):
    provider = "claude"


class CodexSessions(SessionsContract, SessionCase):
    provider = "codex"


class ClaudeQuietSessions(QuietSessionsContract, SessionCase):
    provider = "claude"


class CodexQuietSessions(QuietSessionsContract, SessionCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
