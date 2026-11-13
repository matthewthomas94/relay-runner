"""Voice bridge contract: reply delivery from the reply helper
(`__ORCHESTRATOR_REPLY__`) and the completion hook (`__RELAY_COMPLETION__`),
their de-duplication, the missing-reply fallback, traces, provider turn events
and daemon outcomes (docs/specs/voice-bridge-contract.md, "Replies")."""

from __future__ import annotations

import json
import time
import unittest

from bridge_contract_support import (
    MISSING_REPLY_PREFIX,
    BridgeCase,
    wait_until,
)

REPLY = "The release checklist has two items left."
COMPLETION = "The deploy finished without errors."


LONG_DETAIL = (
    "I found three verification-blocked tickets. I am separating their real-world "
    "evidence requirements from the checks that can run in this worktree now."
)


class ReplyContract:
    def finals(self, command: dict) -> list:
        return [
            request for request in self.box.spoken(command_id=command["relay_command_id"])
            if request.get("kind") in ("final", "fallback") and request.get("authoritative")
        ]

    def assertSpokenOnce(self, command: dict, text: str) -> dict:
        spoken = wait_until(lambda: self.finals(command), message=f"the final {text!r}")[0]
        self.assertEqual(spoken["text"], text)
        self.assertStays(lambda: len(self.finals(command)) == 1, message="the final was offered twice")
        return spoken

    # -- The reply helper --------------------------------------------------

    def test_reply_for_the_current_command_is_spoken_once_as_its_final(self):
        """Replies: `__ORCHESTRATOR_REPLY__` for the newest command is offered
        to speech once as that command's authoritative `final` from
        `orchestrator`; a repeated reply line is not offered again."""
        command = self.claimed_turn("what is left on the release checklist")
        self.box.say(self.reply_line(command, REPLY))
        self.box.say(self.reply_line(command, REPLY))
        spoken = self.assertSpokenOnce(command, REPLY)
        self.assertEqual(spoken["source"], "orchestrator")
        self.assertEqual(spoken["kind"], "final")
        self.assertEqual(spoken["command_seq"], command["relay_command_seq"])
        self.assertIs(spoken["replayable"], True)

    def test_a_replys_display_text_has_its_whitespace_collapsed(self):
        """Replies: a final is offered to speech with its text as written and a
        `display_text` for the overlay preview with runs of whitespace and line
        breaks collapsed to single spaces."""
        command = self.claimed_turn("summarise the incident")
        self.box.say(self.reply_line(command, "The incident\n was   a bad push."))
        spoken = self.box.wait_spoken(text="The incident\n was   a bad push.")
        self.assertEqual(spoken["display_text"], "The incident was a bad push.")

    def test_completion_with_text_is_spoken_as_the_completion_final(self):
        """Replies: `__RELAY_COMPLETION__` with `text` for the newest command is
        offered once as its authoritative `final` from `completion`."""
        command = self.claimed_turn("check whether the deploy finished")
        self.box.say(self.completion_line(command, COMPLETION))
        spoken = self.assertSpokenOnce(command, COMPLETION)
        self.assertEqual(spoken["source"], "completion")
        self.assertEqual(spoken["kind"], "final")

    def test_reply_then_completion_for_one_command_is_spoken_once(self):
        """De-duplication: when the reply helper and then the completion hook
        both deliver a command's reply, only the first is spoken."""
        command = self.claimed_turn("summarise the incident")
        self.box.say(self.reply_line(command, REPLY))
        self.box.say(self.completion_line(command, COMPLETION))
        self.assertSpokenOnce(command, REPLY)

    def test_completion_then_reply_for_one_command_is_spoken_once(self):
        """De-duplication: in the other order the completion's text is spoken
        and the later reply is not."""
        command = self.claimed_turn("summarise the incident")
        self.box.say(self.completion_line(command, COMPLETION))
        self.box.say(self.reply_line(command, REPLY))
        self.assertSpokenOnce(command, COMPLETION)

    def test_reply_for_a_superseded_command_is_dropped(self):
        """Freshness: once a newer command replaces work ("stop everything"),
        replies and completions for the older command are not spoken."""
        command = self.claimed_turn("summarise the incident")
        self.turn("stop everything")
        self.box.say(self.reply_line(command, REPLY))
        self.box.say(self.completion_line(command, COMPLETION))
        self.assertStays(lambda: not self.finals(command))

    def test_reply_preserved_by_a_newer_conversation_turn_is_spoken(self):
        """Freshness: a newer turn whose disposition is `continue_current` with
        `authorization_effect: preserve` keeps the older command's reply
        speakable."""
        command = self.claimed_turn("summarise the incident")
        newer = self.turn("what time is it in Tokyo")
        self.assertEqual(newer["work_disposition"]["route"], "continue_current")
        self.box.say(self.reply_line(command, REPLY))
        self.assertSpokenOnce(command, REPLY)

    def test_reply_for_a_cancelled_intent_is_dropped(self):
        """Freshness: a reply whose intent is listed in `cancelled_intent_ids`
        is not spoken even if its command is otherwise preserved."""
        self.claimed_turn("check the deploy status")
        readme = self.turn("update the readme")
        self.turn("never mind the readme")
        readme_intent = f"{readme['relay_command_id']}:item:1"
        wait_until(lambda: readme_intent in self.session.state().get("cancelled_intent_ids", []),
                   message="the cancellation")
        self.box.say(self.reply_line({**readme, "intent_id": readme_intent}, REPLY))
        self.assertStays(lambda: not self.finals(readme))

    def test_malformed_and_unkeyed_replies_are_ignored(self):
        """Replies: a reply that is not a JSON object, names no command, or has
        no text is dropped, and a later valid completion is still spoken."""
        command = self.claimed_turn("summarise the incident")
        for line in (
            "__ORCHESTRATOR_REPLY__:{not json",
            "__ORCHESTRATOR_REPLY__:[1, 2]",
            "__ORCHESTRATOR_REPLY__:" + json.dumps({"text": "no command here"}),
            self.reply_line(command, "   "),
            "__RELAY_COMPLETION__:{not json",
        ):
            self.box.say(line)
        self.assertStays(lambda: not self.finals(command), 0.5)
        self.assertNotIn("no command here", self.box.spoken_texts())
        self.box.say(self.completion_line(command, COMPLETION))
        self.assertSpokenOnce(command, COMPLETION)

    # -- Traces and provider turn events ------------------------------------

    def test_trace_for_the_current_command_reaches_the_overlay_and_the_messenger(self):
        """Traces: `__TRACE__:<json>` for the newest command sends a `working`
        datagram with the public trace event and becomes a messenger
        `orchestrator_trace` whose words are spoken as lifecycle `progress`."""
        command = self.claimed_turn("ship the settings page")
        self.box.say("__TRACE__:" + json.dumps({
            "kind": "reasoning-summary", "message": "Comparing the two layouts now.",
            "relay_command": {key: command[key] for key in ("relay_command_seq", "relay_command_id")},
        }))
        working = wait_until(
            lambda: [item for item in self.box.states("working", source="bridge") if item.get("trace_event")],
            message="the working datagram",
        )[-1]
        self.assertEqual(working["trace_event"]["kind"], "reasoning-summary")
        self.assertEqual(working["text"], "Comparing the two layouts now.")
        self.box.wait_messenger_prompt("orchestrator_trace", "Comparing the two layouts now.")
        spoken = self.box.wait_spoken(text="Comparing the two layouts now.")
        self.assertEqual((spoken["source"], spoken["kind"]), ("lifecycle", "progress"))

    def test_long_progress_is_compact_on_the_overlay_and_whole_for_the_messenger(self):
        """Traces: a long trace message is cut to at most 96 characters ending
        `...` in the `working` datagram, while the messenger's
        `orchestrator_trace` prompt carries the whole message."""
        command = self.claimed_turn("review blocked verification")
        self.box.say("__TRACE__:" + json.dumps({
            "kind": "reasoning-summary", "message": LONG_DETAIL,
            "relay_command": {key: command[key] for key in ("relay_command_seq", "relay_command_id")},
        }))
        working = wait_until(
            lambda: [item for item in self.box.states("working", source="bridge") if item.get("trace_event")],
            message="the working datagram",
        )[-1]
        self.assertLessEqual(len(working["text"]), 96)
        self.assertTrue(working["text"].endswith("..."))
        prompt = wait_until(
            lambda: [item for item in self.box.messenger_prompts("orchestrator_trace") if LONG_DETAIL in item["prompt"]],
            message="the whole detail in the messenger prompt",
        )
        self.assertTrue(prompt)

    def test_trace_without_a_command_uses_the_claimed_command(self):
        """Traces: a trace that names no command belongs to the session's
        claimed command; plain text is a `board-change` trace."""
        self.claimed_turn("ship the settings page")
        self.box.say("__TRACE__:Moved the ticket to review.")
        working = wait_until(
            lambda: [item for item in self.box.states("working", source="bridge") if item.get("trace_event")],
            message="the working datagram",
        )[-1]
        self.assertEqual(working["trace_event"]["kind"], "board-change")
        self.assertEqual(working["text"], "Moved the ticket to review.")

    def test_trace_for_a_superseded_command_is_dropped(self):
        """Traces: a trace whose command is no longer the newest sends nothing."""
        command = self.claimed_turn("ship the settings page")
        self.turn("what time is it in Tokyo")
        before = len(self.box.states("working"))
        self.box.say("__TRACE__:" + json.dumps({
            "kind": "reasoning-summary", "message": "Late progress.",
            "relay_command": {key: command[key] for key in ("relay_command_seq", "relay_command_id")},
        }))
        self.assertStays(lambda: len(self.box.states("working")) == before)
        self.assertNotIn("Late progress.", self.box.spoken_texts())

    def test_clarification_request_trace_is_asked_by_the_messenger(self):
        """Traces: a `clarification-request` trace is spoken as a
        `clarification` from the messenger."""
        command = self.claimed_turn("ship the settings page")
        self.box.say("__TRACE__:" + json.dumps({
            "kind": "clarification-request", "message": "Which project should get the ticket?",
            "relay_command": {key: command[key] for key in ("relay_command_seq", "relay_command_id")},
        }))
        spoken = self.box.wait_spoken(text="Which project should get the ticket?")
        self.assertEqual((spoken["source"], spoken["kind"]), ("messenger", "clarification"))

    def test_provider_turn_events_are_reported_as_continuity_observations(self):
        """Provider turn events: `provider_started` and `provider_progress` post
        `provider` observations named for the provider's stream
        (`stream_started`/`stream_progress` for Claude,
        `turn_started`/`turn_progress` for Codex); an unknown event, a
        `provider_terminated` with an unknown reason and malformed JSON post
        nothing."""
        command = self.claimed_turn("ship the settings page")
        base = {"provider": self.provider, "relay_command_id": command["relay_command_id"],
                "recovery_generation": self.box.recovery_generation, "observed_at": time.time()}
        for event in ("provider_started", "provider_progress", "provider_unknown"):
            self.box.say("__PROVIDER_TURN_EVENT__:" + json.dumps({**base, "event": event}))
        self.box.say("__PROVIDER_TURN_EVENT__:" + json.dumps({**base, "event": "provider_terminated",
                                                             "release_reason": "bored"}))
        self.box.say("__PROVIDER_TURN_EVENT__:{broken")

        def provider_events():
            return [call["body"]["event"] for call in self.box.orchestrator.requests("/v1/continuity/observation")
                    if call["body"].get("source") == "provider"]

        expected = (["stream_started", "stream_progress"] if self.provider == "claude"
                    else ["turn_started", "turn_progress"])
        wait_until(lambda: provider_events() == expected, message=f"observations {expected}")
        self.assertStays(lambda: provider_events() == expected)

    # -- Daemon outcomes ----------------------------------------------------

    def test_daemon_outcomes_are_spoken_and_marked_delivered(self):
        """Outcomes: the bridge polls `/v1/messenger/outcomes` for its voice
        session key every `MESSENGER_OUTCOME_POLL_SECONDS`, hands each outcome's
        `trace_event` to the messenger, and posts `.../<id>/delivered`."""
        self.box.orchestrator.add_outcome(7, {
            "kind": "run-merged", "message": "RR-7 merged into main.", "source": "orchestrator", "ticket_id": "RR-7",
        })
        wait_until(lambda: self.box.orchestrator.requests("/v1/messenger/outcomes/7/delivered"), message="delivered")
        self.box.wait_spoken(text="RR-7 merged into main.")
        query = self.box.orchestrator.requests("/v1/messenger/outcomes", "GET")[-1]["query"]
        self.assertEqual(query["repo_path"], self.box.orchestrator.requests(
            "/v1/orchestrator-session/ensure")[0]["body"]["repo_path"])
        self.assertEqual(query["provider"], self.provider)
        self.assertEqual(query["limit"], "50")
        self.assertEqual(query["session_key"], self.session.key)

    def test_an_outcomes_whole_lifecycle_detail_reaches_the_messenger(self):
        """Outcomes: an outcome whose `trace_event.message` is cut short but
        whose `lifecycle_detail` is whole reaches the messenger's
        `orchestrator_trace` prompt with the whole detail, and is marked
        delivered."""
        self.box.orchestrator.add_outcome(15, {
            "kind": "run-verification-resumed", "message": LONG_DETAIL[:93] + "...",
            "lifecycle_detail": LONG_DETAIL, "source": "orchestrator", "ticket_id": "RR-279", "run_id": 15,
        })
        wait_until(
            lambda: [item for item in self.box.messenger_prompts("orchestrator_trace") if LONG_DETAIL in item["prompt"]],
            message="the whole detail in the messenger prompt",
        )
        wait_until(lambda: self.box.orchestrator.requests("/v1/messenger/outcomes/15/delivered"), message="delivered")

    def test_several_outcomes_at_once_are_summarised_in_one_update(self):
        """Outcomes: two or more outcomes in one poll become one summary
        ("N Relay work updates accumulated ...") and each is marked delivered."""
        with self.box.orchestrator.lock:
            for outcome_id, ticket in ((8, "RR-8"), (9, "RR-9")):
                self.box.orchestrator.outcomes.append({"id": outcome_id, "payload": {"trace_event": {
                    "kind": "run-merged", "message": f"{ticket} merged.", "source": "orchestrator",
                    "ticket_id": ticket,
                }}})
        for outcome_id in (8, 9):
            wait_until(lambda outcome_id=outcome_id: self.box.orchestrator.requests(
                f"/v1/messenger/outcomes/{outcome_id}/delivered"), message=f"outcome {outcome_id}")
        spoken = wait_until(
            lambda: [text for text in self.box.spoken_texts() if "Relay work updates accumulated" in text],
            message="the summary",
        )[0]
        self.assertTrue(spoken.startswith("2 Relay work updates accumulated"))


class FallbackContract:
    env = {"FOREGROUND_REPLY_FALLBACK_SECONDS": "0.5"}

    def fallbacks(self, command: dict) -> list:
        return [
            request for request in self.box.spoken(command_id=command["relay_command_id"])
            if request["text"].startswith(MISSING_REPLY_PREFIX)
        ]

    def test_empty_completion_speaks_the_missing_reply_fallback(self):
        """Missing reply: a completion without text for a finished turn speaks
        the missing-reply text once, `FOREGROUND_REPLY_FALLBACK_SECONDS` later,
        from `fallback`."""
        command = self.claimed_turn("summarise the incident")
        self.box.write_turns(self.box.turn_record(command, "empty"))
        self.box.say(self.completion_line(command))
        spoken = wait_until(lambda: self.fallbacks(command), message="the fallback")[0]
        self.assertEqual(spoken["source"], "fallback")
        self.assertIs(spoken["authoritative"], True)
        self.assertStays(lambda: len(self.fallbacks(command)) == 1)

    def test_a_claimed_command_without_a_finished_turn_gets_no_fallback(self):
        """Missing reply: publishing and claiming a command does not by itself
        start the missing-reply timer; with no finished turn nothing is spoken
        well past `FOREGROUND_REPLY_FALLBACK_SECONDS`."""
        command = self.claimed_turn("summarise the incident")
        self.assertStays(lambda: not self.fallbacks(command), 2.0)

    def test_project_work_fallback_says_worker_updates_still_come(self):
        """Missing reply: for ticket work the fallback also says worker updates
        will still be announced."""
        command = self.claimed_turn("create a ticket to add dark mode to the board")
        self.box.write_turns(self.box.turn_record(command, "empty"))
        self.box.say(self.completion_line(command, action="create_ticket"))
        spoken = wait_until(lambda: self.fallbacks(command), message="the fallback")[0]
        self.assertIn("worker updates will still be announced", spoken["text"])

    def test_a_reply_before_the_fallback_fires_cancels_it(self):
        """Missing reply: a real reply that arrives before the fallback fires
        is spoken and the fallback never is."""
        command = self.claimed_turn("summarise the incident")
        self.box.write_turns(self.box.turn_record(command, "empty"))
        self.box.say(self.completion_line(command))
        self.box.say(self.reply_line(command, REPLY))
        self.box.wait_spoken(text=REPLY)
        self.assertStays(lambda: not self.fallbacks(command), 1.5)

    def test_the_fallback_waits_while_the_provider_turn_is_active(self):
        """Missing reply: while the turn ledger shows the session's turn still
        `active` the fallback waits; it is spoken once the turn ends."""
        command = self.claimed_turn("summarise the incident")
        self.box.write_turns(self.box.turn_record(command, "active"))
        self.box.say(self.completion_line(command))
        self.assertStays(lambda: not self.fallbacks(command), 1.5)
        self.box.write_turns(self.box.turn_record(command, "empty"))
        wait_until(lambda: self.fallbacks(command), message="the fallback")

    def test_no_fallback_once_the_command_is_superseded(self):
        """Missing reply: a command replaced before the fallback fires gets none."""
        command = self.claimed_turn("summarise the incident")
        self.box.write_turns(self.box.turn_record(command, "empty"))
        self.box.say(self.completion_line(command))
        self.turn("stop everything")
        self.assertStays(lambda: not self.fallbacks(command), 1.5)


class WithoutMessengerContract:
    messenger = False

    def test_without_the_messenger_a_reply_goes_straight_to_speech(self):
        """Replies: with `messenger_enabled = false` no messenger is started and
        a reply is offered to speech directly, armed to play on the waiting
        gesture (`waiting_playback_kind: final`)."""
        command = self.claimed_turn("summarise the incident")
        self.box.say(self.reply_line(command, REPLY))
        spoken = self.box.wait_spoken(text=REPLY)
        self.assertEqual((spoken["source"], spoken["kind"]), ("orchestrator", "final"))
        self.assertEqual(spoken["waiting_playback_kind"], "final")
        # Codex still reads its model catalog (`app-server` `model/list`) for
        # the sidecar lane; no messenger process is started.
        self.assertFalse([
            record for record in self.box.messenger_records("launch")
            if "--input-format" in record["argv"] or "features.hooks=false" in record["argv"]
        ])
        self.assertFalse(self.box.messenger_prompts())

    def test_without_the_messenger_outcomes_are_not_polled(self):
        """Outcomes: without a messenger the bridge does not poll outcomes."""
        self.assertStays(lambda: not self.box.orchestrator.requests("/v1/messenger/outcomes"))


class ClaudeReplies(ReplyContract, BridgeCase):
    provider = "claude"


class CodexReplies(ReplyContract, BridgeCase):
    provider = "codex"


class ClaudeFallback(FallbackContract, BridgeCase):
    provider = "claude"


class CodexFallback(FallbackContract, BridgeCase):
    provider = "codex"


class ClaudeWithoutMessenger(WithoutMessengerContract, BridgeCase):
    provider = "claude"


class CodexWithoutMessenger(WithoutMessengerContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
