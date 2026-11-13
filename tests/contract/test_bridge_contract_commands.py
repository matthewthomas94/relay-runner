"""Voice bridge contract: commands, the spool mailbox and its claim
lifecycle, multi-item turns, work dispositions, the authorization ledger, the
private command log and the TTS FIFO (docs/specs/voice-bridge-contract.md,
"Commands" and "Spool files")."""

from __future__ import annotations

import json
import os
import stat
import unittest

from bridge_contract_support import BridgeCase, wait_until

TICKET_TURN = "create a ticket to add dark mode to the board"


class CommandContract:
    def deliverable(self) -> list:
        return [(item["relay_command_seq"], item["within_turn_order"], item["state"])
                for item in self.session.state().get("deliverable_commands", [])]

    def row(self, intent_id: str) -> dict:
        return next(row for row in self.box.inbox() if row["intent_id"] == intent_id)

    # -- Mailbox and claim -------------------------------------------------

    def test_mailbox_holds_the_agent_prompt_and_its_metadata(self):
        """Spool: `voice_cmd_ready` holds the agent prompt and
        `voice_cmd_ready.meta` its metadata: the command identity, one intent
        with delivery, claim and ack ids, its order, its disposition and its
        provisional qualification. The intent is `delivered` in the inbox."""
        prompt, metadata = self.turn_delivered("what is left on the release checklist")
        command_id = metadata["relay_command_id"]
        intent_id = f"{command_id}:item:1"
        self.assertEqual(metadata["intent_id"], intent_id)
        self.assertEqual(metadata["intent_delivery_id"], f"delivery:{intent_id}")
        self.assertEqual(metadata["intent_claim_id"], f"claim:{intent_id}")
        self.assertEqual(metadata["intent_ack_id"], f"ack:{intent_id}")
        self.assertEqual(metadata["within_turn_order"], 1)
        self.assertEqual(metadata["voice_target_session_key"], self.session.key)
        self.assertEqual(metadata["work_disposition"]["route"], "continue_current")
        self.assertEqual(metadata["work_disposition"]["intent_id"], intent_id)
        self.assertEqual(metadata["intent_qualification"]["command_seq"], 1)
        self.assertEqual(metadata["agent_prompt"], prompt)
        self.assertIn("Relay work-intent disposition:", prompt)
        self.assertIn("Relay intent qualification (provisional):", prompt)
        self.assertEqual(self.row(intent_id)["state"], "delivered")
        self.assertEqual(self.deliverable(), [(1, 1, "delivered")])

    def test_claim_then_acknowledgement_moves_the_intent_through_its_states(self):
        """Claim lifecycle: a claim file naming the intent makes it `claimed`;
        the consumer acknowledgement makes it `acked`, after which the bridge
        removes the acknowledgement file and the intent leaves
        `deliverable_commands`."""
        self.turn_delivered("check the deploy status")
        claimed = self.session.claim()
        self.box.wait_intent_state(claimed["intent_id"], "claimed")
        wait_until(lambda: self.deliverable() == [(1, 1, "claimed")], message="the claimed state")
        self.session.acknowledge(claimed)
        self.box.wait_intent_state(claimed["intent_id"], "acked")
        wait_until(lambda: not self.session.manual_ack.exists(), message="the acknowledgement file to go")
        wait_until(lambda: self.deliverable() == [], message="an empty deliverable list")

    def test_a_provider_turn_in_the_ledger_acknowledges_a_claim(self):
        """Claim lifecycle: a claimed intent is also acknowledged once the turn
        ledger shows a provider turn for it under this session's ownership."""
        self.turn_delivered("look at the failing build")
        claimed = self.session.claim()
        self.box.wait_intent_state(claimed["intent_id"], "claimed")
        self.box.write_turns(self.box.turn_record(claimed, "active"))
        self.box.wait_intent_state(claimed["intent_id"], "acked")

    def test_an_acknowledgement_that_does_not_match_the_claim_is_ignored(self):
        """Claim lifecycle: an acknowledgement whose delivery, claim or ack id
        differs from the claim leaves the intent `claimed` and the file in place."""
        self.turn_delivered("review the open pull requests")
        claimed = self.session.claim()
        self.box.wait_intent_state(claimed["intent_id"], "claimed")
        self.session.acknowledge({**claimed, "intent_ack_id": "ack:someone-else"})
        self.assertStays(lambda: self.row(claimed["intent_id"])["state"] == "claimed")
        self.assertTrue(self.session.manual_ack.exists())

    def test_a_newer_turn_waits_until_the_delivered_one_is_acknowledged(self):
        """Sequencing: a session's mailbox holds one unacknowledged command at a
        time. A newer turn becomes the newest command at once but is delivered
        only after the older one is acknowledged."""
        _, first = self.turn_delivered("first piece of work")
        second = self.turn("second piece of work")
        self.assertEqual(self.session.state()["relay_command_id"], second["relay_command_id"])
        self.assertStays(lambda: self.session.pending()[1]["relay_command_id"] == first["relay_command_id"])
        claimed = self.session.claim()
        self.session.acknowledge(claimed)
        _, delivered = self.session.wait_pending("the second command")
        self.assertEqual(delivered["relay_command_id"], second["relay_command_id"])

    def test_queued_turns_are_delivered_in_arrival_order(self):
        """Sequencing: turns queued behind an unacknowledged command are
        delivered one at a time, oldest first."""
        texts = ["alpha request", "bravo request", "charlie request"]
        for text in texts:
            self.turn(text)
        delivered = []
        for _ in texts:
            claimed = self.session.claim()
            delivered.append(claimed["source_text"])
            self.session.acknowledge(claimed)
            self.box.wait_intent_state(claimed["intent_id"], "acked")
        self.assertEqual(delivered, texts)

    # -- Multi-item turns and dispositions ---------------------------------

    def test_a_turn_with_two_requests_becomes_two_ordered_items(self):
        """Multi-item turns: a turn joining two requests ("... and then ...")
        becomes two intents of one command, ordered 1 and 2. The second is
        delivered after the first is acknowledged."""
        _, first = self.turn_delivered("fix the login bug and then update the readme")
        command_id = first["relay_command_id"]
        rows = [row for row in self.box.inbox() if row["command_id"] == command_id]
        self.assertEqual([row["within_turn_order"] for row in rows], [1, 2])
        self.assertEqual(first["intent_id"], f"{command_id}:item:1")
        self.assertEqual(first["source_text"], "fix the login bug")
        claimed = self.session.claim()
        self.session.acknowledge(claimed)
        _, second = wait_until(
            lambda: self.session.pending() if (self.session.pending() or ("", {}))[1].get("within_turn_order") == 2 else None,
            message="the second item",
        )
        self.assertEqual(second["intent_id"], f"{command_id}:item:2")
        self.assertEqual(second["relay_command_seq"], first["relay_command_seq"])
        self.assertEqual(second["source_text"], "update the readme")

    def test_project_work_is_queued_on_the_ticket_path_and_fanned_out(self):
        """Dispositions: a ticket request is `queue_project_work`. The bridge
        posts it to `/v1/orchestrator-session/command` as queued, deferred work
        and starts PM update mode, which reads sessions, runs and program
        status. No ticket file is written."""
        _, metadata = self.turn_delivered(TICKET_TURN)
        self.assertEqual(metadata["action"], "create_ticket")
        self.assertIs(metadata["requires_ticket"], True)
        self.assertEqual(metadata["work_disposition"]["route"], "queue_project_work")
        posted = wait_until(
            lambda: self.box.orchestrator.requests("/v1/orchestrator-session/command"), message="the fan-out"
        )[0]["body"]
        self.assertEqual(posted["source_text"], TICKET_TURN)
        self.assertEqual(posted["status"], "queued")
        self.assertIs(posted["defer_processing"], True)
        self.assertEqual(posted["action"], "create_ticket")
        self.assertEqual(posted["relay_command_id"], metadata["relay_command_id"])
        self.assertEqual(posted["intent_id"], metadata["intent_id"])
        self.assertEqual(posted["session_id"], self.box.orchestrator.session_id)
        self.assertEqual(posted["repo_path"], os.path.realpath(self.box.repo))
        for path in ("/v1/orchestrator-sessions", "/v1/runs", "/v1/program/status"):
            wait_until(lambda path=path: self.box.orchestrator.requests(path, "GET"), message=path)
        self.assertFalse((self.box.repo / ".orchestrator").exists())

    def test_conversation_is_not_fanned_out_to_the_daemon(self):
        """Dispositions: a conversational turn is `continue_current` and is not
        posted to the daemon."""
        _, metadata = self.turn_delivered("how are the builds looking today")
        self.assertEqual(metadata["work_disposition"]["route"], "continue_current")
        self.assertEqual(metadata["work_disposition"]["authorization_effect"], "preserve")
        self.assertStays(lambda: not self.box.orchestrator.requests("/v1/orchestrator-session/command"))

    def test_an_ambiguous_cancellation_asks_for_its_target(self):
        """Dispositions: a cancellation without a target is `clarify_priority`
        with a clarification question, and cancels nothing."""
        _, metadata = self.turn_delivered("cancel that")
        disposition = metadata["work_disposition"]
        self.assertEqual(disposition["route"], "clarify_priority")
        self.assertTrue(disposition["clarification_question"])
        self.assertEqual(self.session.state().get("cancelled_intent_ids"), [])

    def test_a_scoped_cancellation_cancels_only_the_queued_item_it_names(self):
        """Dispositions: "never mind the <item>" is `replace_current` with
        scope `item`. It cancels the queued intent it names, which is listed in
        `cancelled_intent_ids`, and leaves other queued work alone."""
        self.turn_delivered("check the deploy status")
        readme = self.turn("update the readme")
        notes = self.turn("write the release notes")
        cancel = self.turn("never mind the readme")
        readme_intent = f"{readme['relay_command_id']}:item:1"
        notes_intent = f"{notes['relay_command_id']}:item:1"
        self.assertEqual(cancel["work_disposition"]["route"], "replace_current")
        self.assertEqual(cancel["work_disposition"]["cancellation_scope"], "item")
        wait_until(lambda: readme_intent in self.session.state().get("cancelled_intent_ids", []),
                   message="the readme intent to be cancelled")
        self.assertEqual(self.row(readme_intent)["state"], "cancelled")
        self.assertEqual(self.row(notes_intent)["state"], "pending")

    def test_cancelling_everything_cancels_all_queued_work_and_preempts(self):
        """Dispositions: "stop everything" is `replace_current` with scope
        `all_work`: every queued intent of the session is cancelled and the
        command preempts the provider."""
        self.turn_delivered("check the deploy status")
        queued = self.turn("update the readme")
        stop = self.turn("stop everything")
        self.assertEqual(stop["work_disposition"]["route"], "replace_current")
        self.assertEqual(stop["work_disposition"]["cancellation_scope"], "all_work")
        self.assertIs(stop["preempt_provider"], True)
        queued_intent = f"{queued['relay_command_id']}:item:1"
        wait_until(lambda: queued_intent in self.session.state().get("cancelled_intent_ids", []),
                   message="the queued intent to be cancelled")

    def test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar(self):
        """Dispositions: while another provider session's turn is active and
        this session's provider is idle, a bounded read-only request ("in
        parallel research ...") is `run_sidecar`: it never reaches the mailbox,
        runs on the sidecar lane (the provider started with read-only web
        tools) and its result is spoken as a work outcome."""
        claimed = self.claimed_turn("refactor the settings page")
        self.box.write_turns(self.box.turn_record(claimed, "active", provider_session_id="another-session"))
        sidecar = self.turn("in parallel research the competitors pricing")
        self.assertEqual(sidecar["work_disposition"]["route"], "run_sidecar")
        spoken = self.box.wait_spoken(message="the sidecar outcome", command_id=sidecar["relay_command_id"], kind="final")
        self.assertIn("Sidecar result:", spoken["text"])
        self.assertEqual(spoken["source"], "lifecycle")
        self.assertIs(spoken["authoritative"], True)
        self.assertIsNone(self.session.pending())
        launches = [record["argv"] for record in self.box.messenger_records("launch")]
        marker = "WebSearch,WebFetch" if self.provider == "claude" else "tools.web_search=true"
        self.assertTrue(any(marker in argv for argv in launches), launches)

    def test_a_busy_foreground_provider_is_steered_instead_of_a_sidecar(self):
        """Dispositions: while this session's own provider turn is active, the
        same read-only request is `continue_current` and goes to the mailbox,
        so the busy PM receives it."""
        claimed = self.claimed_turn("refactor the settings page")
        self.box.write_turns(self.box.turn_record(claimed, "active"))
        _, metadata = self.turn_delivered("in parallel research the competitors pricing")
        self.assertEqual(metadata["work_disposition"]["route"], "continue_current")

    # -- Authorization ledger and private log ------------------------------

    def test_authorizations_follow_the_turns_relationship(self):
        """Authorization ledger: an explicit ticket request registers an active
        authorization for its intent, keyed to the session; a question
        registers none; "stop everything" revokes the session's active ones."""
        self.turn_delivered("what is the weather like")
        self.assertStays(lambda: self.box.authorization_records() == [], 0.5)
        ticket = self.turn(TICKET_TURN)
        record = wait_until(lambda: self.box.authorization_records(), message="an authorization")[0]
        self.assertEqual(record["relay_command_id"], ticket["relay_command_id"])
        self.assertEqual(record["status"], "active")
        self.assertEqual(record["relay_session_key"], self.session.key)
        self.assertTrue(record["allowed_mutations"])
        self.turn("stop everything")
        revoked = wait_until(
            lambda: [item for item in self.box.authorization_records() if item.get("status") == "revoked"],
            message="the revocation",
        )[0]
        self.assertEqual(revoked["relay_command_id"], ticket["relay_command_id"])
        self.assertEqual(revoked["revoked_by"]["relationship"], "redirect")

    def test_private_command_log_records_each_intents_states(self):
        """Private log: `VOICE_COMMAND_EVENT_LOG` gets one line per state of a
        command (`received`, then `classified` and `queued` for each intent),
        and is private (mode 0600)."""
        command = self.turn("summarise yesterday's standup")
        events = wait_until(
            lambda: [event["state"] for event in self.box.command_events()
                     if event.get("relay_command_id") == command["relay_command_id"]]
            if len(self.box.command_events()) >= 3 else None,
            message="three command events",
        )
        self.assertEqual(events, ["received", "classified", "queued"])
        self.assertEqual(stat.S_IMODE(os.stat(self.box.event_log).st_mode), 0o600)
        self.assertEqual(self.box.command_events()[0]["source_text"], "summarise yesterday's standup")

    # -- TTS FIFO ----------------------------------------------------------

    def test_tts_fifo_lines_are_spoken_unless_stale(self):
        """TTS FIFO: a plain line is spoken as a fallback with markdown removed;
        a JSON line names its command and is dropped once that command is no
        longer the newest; a plain line is dropped while a command waits in the
        mailbox."""
        self.box.speak_into_tts_fifo("**Plain** `status` line")
        self.box.wait_spoken(text="Plain status line", source="fallback")
        first = self.turn("first question")
        claimed = self.session.claim()
        self.session.acknowledge(claimed)
        self.box.wait_intent_state(claimed["intent_id"], "acked")
        self.box.speak_into_tts_fifo(json.dumps({
            "text": "Reply to the first question.", "relay_command_seq": first["relay_command_seq"],
            "relay_command_id": first["relay_command_id"],
        }))
        self.box.wait_spoken(text="Reply to the first question.", command_id=first["relay_command_id"])
        self.turn("second question")
        self.box.speak_into_tts_fifo(json.dumps({
            "text": "Late reply to the first question.", "relay_command_seq": first["relay_command_seq"],
            "relay_command_id": first["relay_command_id"],
        }))
        self.box.speak_into_tts_fifo("Plain line while a command waits.")
        self.assertNeverSpoken("Late reply to the first question.")
        self.assertNotIn("Plain line while a command waits.", self.box.spoken_texts())


class EventLimitContract:
    env = {"VOICE_COMMAND_EVENT_LIMIT": "4"}

    def test_private_command_log_keeps_only_the_newest_events(self):
        """Private log: the log keeps the newest `VOICE_COMMAND_EVENT_LIMIT` lines."""
        for text in ("one question", "two questions", "three questions"):
            self.turn(text)
        wait_until(
            lambda: any(event.get("source_text") == "three questions" and event.get("state") == "queued"
                        for event in self.box.command_events()),
            message="the third command's queued event",
        )
        self.assertEqual(len(self.box.command_events()), 4)


class ManualSessionContract:
    app_session = False

    def test_a_manual_bridge_uses_the_legacy_mailbox_paths(self):
        """Spool: without `RELAY_SESSION_SPOOL_DIR` the mailbox, claim and
        state files are the ones named by `VOICE_CMD_FILE`,
        `VOICE_COMMAND_STATE_FILE`, `VOICE_COMMAND_CLAIM_FILE` and
        `VOICE_MANUAL_CLAIM_ACK_FILE`, and the claim lifecycle is the same."""
        ready = self.box.runtime / "voice_cmd_ready"
        state_file = self.box.runtime / "voice_command_state.json"
        self.box.say("check on the manual bridge")
        wait_until(lambda: ready.exists(), message="the legacy mailbox")
        metadata = json.loads((self.box.runtime / "voice_cmd_ready.meta").read_text())
        self.assertEqual(json.loads(state_file.read_text())["relay_command_id"], metadata["relay_command_id"])
        os.unlink(ready)
        os.unlink(self.box.runtime / "voice_cmd_ready.meta")
        (self.box.runtime / "voice_cmd_claimed.json").write_text(json.dumps(metadata))
        (self.box.runtime / "voice_cmd_manual_ack.json").write_text(json.dumps(metadata))
        self.box.wait_intent_state(metadata["intent_id"], "acked")


class ClaudeCommands(CommandContract, BridgeCase):
    provider = "claude"


class CodexCommands(CommandContract, BridgeCase):
    provider = "codex"


class ClaudeEventLimit(EventLimitContract, BridgeCase):
    provider = "claude"


class CodexEventLimit(EventLimitContract, BridgeCase):
    provider = "codex"


class ClaudeManualSession(ManualSessionContract, BridgeCase):
    provider = "claude"


class CodexManualSession(ManualSessionContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
