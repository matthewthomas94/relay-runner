"""Voice bridge contract: restarts, recovery and the continuity controls
(docs/specs/voice-bridge-contract.md, "Restart" and "Continuity").

A restart stops the bridge and starts it again on the same sandbox: the intent
inbox, the session spool and the runtime directory carry over.
"""

from __future__ import annotations

import json
import os
import secrets
import time
import unittest
from pathlib import Path

from bridge_contract_support import (
    PLEASE_REPEAT_TEXT,
    STARTUP_GREETING,
    VOICE_PAUSED_PREFIX,
    BridgeCase,
    opaque_identifier,
    read_json,
    wait_until,
)

SPEECH_CAPTURE_LOSS = "Relay Runner cannot capture speech for the active voice session."
STALE_AUTHORIZATION = "stale-authorization-record"


def restart(box) -> None:
    box.stop()
    box.start()


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload))
    os.replace(temporary, path)


def plant_previous_run(box) -> None:
    """Files a previous bridge run could leave behind."""
    session = box.session
    session.ready.write_text("left over from the last run")
    write_json(session.meta, {"relay_command_seq": 98, "relay_command_id": "stale-98"})
    write_json(session.claimed, {"relay_command_seq": 98, "relay_command_id": "stale-98"})
    write_json(session.manual_ack, {"relay_command_seq": 98, "relay_command_id": "stale-98"})
    write_json(session.state_file, {
        "relay_command_seq": 99, "relay_command_id": "stale-99", "recovery_generation": "1",
    })
    write_json(box.turns_file, {"records": [{"relay_command_seq": 98, "relay_command_id": "stale-98", "state": "active"}]})
    write_json(box.authorizations, {"authorizations": [
        {"relay_command_seq": 98, "relay_command_id": STALE_AUTHORIZATION, "allowed_mutations": []},
    ]})


def active_turn_record(box, command: dict, state: str = "active") -> dict:
    """One version 1 turn-ledger record, as the completion hook writes it."""
    return {
        "relay_command_seq": command["relay_command_seq"],
        "relay_command_id": command["relay_command_id"],
        "intent_id": command["intent_id"],
        "provider": box.provider,
        "provider_session_id": box.session.provider_session_id,
        "app_session_id": box.app_session_id,
        "recovery_generation": box.recovery_generation,
        "actor_role": "foreground_pm",
        "state": state,
    }


class StartupCleanupContract:
    start_bridge = False

    def test_startup_removes_files_a_previous_run_left(self):
        """Restart: start-up removes the mailbox, claim, consumer
        acknowledgement, turn ledger, command state and authorization ledger a
        previous run left; the next turn is command 1."""
        plant_previous_run(self.box)
        self.box.start()
        for path in (self.session.ready, self.session.meta, self.session.claimed,
                     self.session.manual_ack, self.box.turns_file):
            self.assertFalse(path.exists(), f"{path.name} was kept")
        self.assertNotIn(STALE_AUTHORIZATION, self.box.authorizations.read_text() if self.box.authorizations.exists() else "")
        self.assertNotEqual(self.session.state().get("relay_command_id"), "stale-99")
        self.assertEqual(self.turn("a fresh first turn")["relay_command_seq"], 1)


class ContinuityPendingContract:
    start_bridge = False
    env = {"RELAY_CONTINUITY_RECOVERY_PENDING": "1"}

    def test_pending_continuity_recovery_keeps_the_command_state(self):
        """Restart: with `RELAY_CONTINUITY_RECOVERY_PENDING=1` start-up keeps
        the command state file, so the next turn follows its newest command."""
        plant_previous_run(self.box)
        self.box.start()
        self.assertFalse(self.session.claimed.exists())
        self.assertEqual(self.session.state().get("relay_command_id"), "stale-99")
        self.assertEqual(self.turn("the turn after recovery")["relay_command_seq"], 100)


class PreservedAuthorizationContract:
    start_bridge = False
    env = {"RELAY_PRESERVE_CONTEXT_AUTHORIZATION": "1"}

    def test_preserved_context_keeps_the_authorization_ledger(self):
        """Restart: with `RELAY_PRESERVE_CONTEXT_AUTHORIZATION=1` start-up keeps
        `VOICE_COMMAND_AUTHORIZATION_FILE`; the other leftovers still go."""
        plant_previous_run(self.box)
        self.box.start()
        self.assertIn(STALE_AUTHORIZATION, self.box.authorizations.read_text())
        self.assertFalse(self.session.claimed.exists())


class InboxRestartContract:
    def uncertain_claim(self) -> dict:
        """A command the provider claimed and never acknowledged."""
        self.turn_delivered("deploy the staging build")
        claimed = self.session.claim()
        self.box.wait_intent_state(claimed["intent_id"], "claimed")
        return claimed

    def test_sequence_numbers_continue_after_a_restart(self):
        """Restart: the intent inbox survives, so the first turn after a
        restart takes the sequence number after the last one before it."""
        self.claimed_turn("first question")
        self.claimed_turn("second question")
        restart(self.box)
        self.assertEqual(self.turn("third question")["relay_command_seq"], 3)

    def test_a_delivered_unclaimed_command_is_delivered_again(self):
        """Restart: a command in the mailbox that no provider claimed is
        delivered again, with the same identity, after a restart."""
        prompt, metadata = self.turn_delivered("summarise the open tickets")
        restart(self.box)
        again_prompt, again = self.session.wait_pending("the redelivered command")
        self.assertEqual(again_prompt, prompt)
        self.assertEqual(again["intent_id"], metadata["intent_id"])
        self.assertEqual(again["relay_command_id"], metadata["relay_command_id"])
        row = [row for row in self.box.inbox() if row["intent_id"] == metadata["intent_id"]][0]
        self.assertEqual(row["state"], "delivered")
        self.assertEqual(row["recovery_decision"], "resume_exact")
        self.assertEqual(row["lease_attempts"], 2)

    def test_queued_commands_are_delivered_again_in_order(self):
        """Restart: commands queued behind an unclaimed one keep their order."""
        _, first = self.turn_delivered("look at the first thing")
        second = self.turn("look at the second thing")
        restart(self.box)
        _, again = self.session.wait_pending("the first command again")
        self.assertEqual(again["intent_id"], first["intent_id"])
        claimed = self.session.claim()
        self.session.acknowledge(claimed)
        _, after = self.session.wait_pending("the second command")
        self.assertEqual(after["relay_command_id"], second["relay_command_id"])

    def test_a_claimed_unacknowledged_command_becomes_a_recovery_blocker(self):
        """Restart: a command claimed but never acknowledged is uncertain. The
        inbox marks it for review, the state file names it as
        `inbox_recovery_blocker`, the next turn is held and the user hears that
        voice is paused."""
        claimed = self.uncertain_claim()
        restart(self.box)
        blocker = wait_until(lambda: self.session.state().get("inbox_recovery_blocker"), message="the blocker")
        self.assertEqual(blocker["intent_id"], claimed["intent_id"])
        self.assertEqual(blocker["command_seq"], claimed["relay_command_seq"])
        self.assertEqual(blocker["command_id"], claimed["relay_command_id"])
        held = self.turn("what is the weather")
        paused = wait_until(
            lambda: [text for text in self.box.spoken_texts() if text.startswith(VOICE_PAUSED_PREFIX)],
            message="the voice-paused announcement",
        )[-1]
        self.assertIn(f"Message {claimed['relay_command_seq']} has an uncertain outcome", paused)
        self.assertStays(lambda: self.session.pending() is None, message="the held turn was delivered")
        rows = {row["intent_id"]: row["state"] for row in self.box.inbox()}
        self.assertEqual(rows[claimed["intent_id"]], "review_required")
        self.assertEqual(rows[held["intent_id"]], "pending")

    def test_skip_uncertain_with_the_exact_blocker_releases_the_queue(self):
        """Restart: `__SKIP_UNCERTAIN__:<blocker>` cancels the blocker only
        when it equals the state file's `inbox_recovery_blocker`; the held
        turn is then delivered. A mismatching blocker changes nothing."""
        claimed = self.uncertain_claim()
        restart(self.box)
        blocker = wait_until(lambda: self.session.state().get("inbox_recovery_blocker"), message="the blocker")
        held = self.turn("what is the weather")
        self.box.say("__SKIP_UNCERTAIN__:" + json.dumps({**blocker, "recovered_at": 1.0}))
        self.box.say("__SKIP_UNCERTAIN__:not json")
        self.assertStays(lambda: self.session.state().get("inbox_recovery_blocker") == blocker)
        self.assertIsNone(self.session.pending())
        self.box.say("__SKIP_UNCERTAIN__:" + json.dumps(blocker))
        wait_until(lambda: self.session.state().get("inbox_recovery_blocker") is None
                   and "inbox_recovery_blocker" in self.session.state(), message="the blocker to clear")
        self.assertIn(claimed["intent_id"], self.session.state()["cancelled_intent_ids"])
        _, delivered = self.session.wait_pending("the held turn")
        self.assertEqual(delivered["intent_id"], held["intent_id"])
        self.assertEqual(self.session.state()["relay_command_seq"], held["relay_command_seq"])

    def test_a_new_recovery_generation_retires_the_old_unacknowledged_work(self):
        """Restart: a bridge started with a different `RELAY_RECOVERY_GENERATION`
        cancels this session's unacknowledged work of the older generation
        instead of delivering it again."""
        _, metadata = self.turn_delivered("summarise the open tickets")
        self.box.recovery_generation = "2"
        restart(self.box)
        row = self.box.wait_intent_state(metadata["intent_id"], "cancelled")
        self.assertEqual(row["recovery_decision"], "stale_generation_retired")
        self.assertStays(lambda: self.session.pending() is None)
        command = self.turn("a turn in the new generation")
        self.assertEqual(command["recovery_generation"], "2")
        self.assertEqual(command["relay_command_seq"], 2)

    def test_a_reply_after_a_restart_is_still_spoken(self):
        """Restart: the newest command is restored from the inbox, so the reply
        for the command the provider was working on is spoken after a
        restart."""
        claimed = self.claimed_turn("explain the failing build")
        restart(self.box)
        self.box.say(self.reply_line(claimed, "The build fails on a missing import."))
        spoken = self.box.wait_spoken(text="The build fails on a missing import.")
        self.assertEqual(spoken["command_seq"], claimed["relay_command_seq"])
        self.assertEqual(spoken["command_id"], claimed["relay_command_id"])
        self.assertEqual(spoken["kind"], "final")
        self.assertIs(spoken["authoritative"], True)


class WatchdogRestartContract:
    def marker(self) -> Path:
        return self.box.runtime_file("voice_bridge_watchdog_restart")

    def prepare(self) -> dict:
        claimed = self.claimed_turn("refactor the parser")
        write_json(self.box.turns_file, {"records": [active_turn_record(self.box, claimed)]})
        self.marker().write_text(f"{self.session.provider_session_id} {self.box.process.pid}\n")
        return claimed

    def test_a_watchdog_restart_keeps_the_claim_turns_and_command_state(self):
        """Restart: when `voice_bridge_watchdog_restart` names this provider
        session and the stopping bridge's pid, the stopping bridge keeps the
        claim, the turn ledger and the command state, the new bridge keeps them
        too, and the in-flight command's completion is spoken."""
        claimed = self.prepare()
        self.box.stop()
        for path in (self.session.claimed, self.box.turns_file, self.session.state_file):
            self.assertTrue(path.exists(), f"{path.name} was removed")
        self.assertFalse(self.box.tts_fifo.exists())
        self.box.start()
        self.assertEqual(read_json(self.session.claimed)["intent_id"], claimed["intent_id"])
        self.assertTrue(read_json(self.box.turns_file)["records"])
        self.assertEqual(self.session.state()["relay_command_id"], claimed["relay_command_id"])
        self.box.say(self.completion_line(claimed, "The parser is refactored."))
        spoken = self.box.wait_spoken(text="The parser is refactored.")
        self.assertEqual(spoken["command_id"], claimed["relay_command_id"])
        self.assertEqual(spoken["source"], "completion")

    def test_an_explicit_stop_request_cleans_despite_the_marker(self):
        """Restart: with `voice_bridge_stop_requested` present the stop is
        explicit; the claim, turn ledger and command state are removed."""
        self.prepare()
        self.box.runtime_file("voice_bridge_stop_requested").write_text("1\n")
        self.box.stop()
        for path in (self.session.claimed, self.box.turns_file, self.session.state_file):
            self.assertFalse(path.exists(), f"{path.name} was kept")

    def test_a_marker_for_another_bridge_does_not_preserve(self):
        """Restart: a marker naming another pid does not keep the stopping
        bridge's claim or turn ledger."""
        self.prepare()
        self.marker().write_text(f"{self.session.provider_session_id} 1\n")
        self.box.stop()
        self.assertFalse(self.session.claimed.exists())
        self.assertFalse(self.box.turns_file.exists())


class SpeechServiceRestartContract:
    def test_a_crashed_speech_service_is_started_again_and_given_its_queue(self):
        """Restart: when the speech service dies the bridge starts a new one,
        says hello again and resubmits the replies the old one still held."""
        self.box.wait_spoken(text=STARTUP_GREETING)
        first = [record for record in self.box.speech_records() if record["record"] == "started"][0]
        self.box.speech_command(op="crash")
        started = wait_until(
            lambda: len([r for r in self.box.speech_records() if r["record"] == "started"]) >= 2
            and [r for r in self.box.speech_records() if r["record"] == "started"],
            message="a second speech service",
        )
        second = started[1]
        self.assertNotEqual(second["instance"], first["instance"])
        self.assertEqual(second["ppid"], self.box.process.pid)

        def resubmitted():
            return [
                record for record in self.box.speech_records()
                if record["instance"] == second["instance"] and record.get("record") == "request"
                and record["op"] == "speak" and record["params"].get("text") == STARTUP_GREETING
            ]

        wait_until(resubmitted, message="the queued greeting to be resubmitted")
        hellos = [r for r in self.box.speech_records() if r.get("record") == "request" and r["op"] == "hello"]
        self.assertEqual([r["instance"] for r in hellos], [first["instance"], second["instance"]])
        command = self.turn("are you still there")
        self.box.wait_speech_request("new_turn", command_seq=command["relay_command_seq"])


class ContinuityControlContract:
    def send_controls(self, payloads) -> None:
        """Send control datagrams a little apart: the socket's buffer is small."""
        for payload in payloads:
            self.box.control(payload)
            time.sleep(0.1)

    def observations(self, source: str) -> list:
        return [
            call["body"] for call in self.box.orchestrator.requests("/v1/continuity/observation")
            if call["body"].get("source") == source
        ]

    def reply_path(self) -> Path:
        path = Path(f"/tmp/relay_recovery_recovery_{secrets.token_hex(12)}.json")
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        return path

    def test_invalid_continuity_recovery_reports_failure_to_its_reply_path(self):
        """Continuity: a `continuity_recovery` control whose context does not
        parse is answered `failed` / `invalid_recovery_context` in the reply
        file it names, when that path matches
        `/tmp/relay_recovery_recovery_<24 hex>.json`; any other path gets no
        file."""
        good = self.reply_path()
        bad = self.box.root / "relay_recovery_recovery_0123456789abcdef01234567.json"
        short = Path(f"/tmp/relay_recovery_recovery_{secrets.token_hex(4)}.json")
        self.addCleanup(lambda: short.unlink(missing_ok=True))
        self.send_controls(
            {"type": "continuity_recovery", "reply_path": str(path), "capability": "restart_messenger"}
            for path in (bad, short, good)
        )
        answer = wait_until(lambda: read_json(good), message="the recovery reply")
        self.assertEqual(answer, {"status": "failed", "outcome_code": "invalid_recovery_context"})
        self.assertFalse(bad.exists())
        self.assertFalse(short.exists())

    def resume_payload(self, **fields) -> dict:
        payload = {
            "type": "continuity_resume",
            "incident_id": "incident-1",
            "session_id": opaque_identifier("session", self.box.orchestrator.session_key),
            "provider": self.provider,
            "recovery_generation": self.box.recovery_generation,
            "command_id": None,
            "component": "speech_capture",
            "phase": "capture",
            "unavailable_capability": SPEECH_CAPTURE_LOSS,
            "final_result": "restored",
            "incident_observed_at": time.time(),
        }
        payload.update(fields)
        return payload

    def test_continuity_resume_after_lost_speech_asks_the_user_to_repeat(self):
        """Continuity: a `continuity_resume` control for this bridge's session
        and generation, for speech lost before any command was captured, speaks
        the please-repeat text and sends a `continuity_repeat` state datagram.
        The same handoff again is a no-op."""
        self.turn("a first turn sets the generation")
        payload = self.resume_payload()
        self.box.control(payload)
        spoken = self.box.wait_spoken(text=PLEASE_REPEAT_TEXT)
        self.assertNotIn("command_seq", spoken)
        repeat = wait_until(lambda: self.box.states("continuity_repeat", source="bridge"), message="continuity_repeat")
        self.assertEqual(repeat[-1]["text"], PLEASE_REPEAT_TEXT)
        self.box.control(payload)
        self.assertStays(lambda: len(self.box.spoken(text=PLEASE_REPEAT_TEXT)) == 1)

    def test_continuity_resume_for_another_session_or_generation_does_nothing(self):
        """Continuity: a resume handoff for another session, another
        generation, another provider, or one that did not restore health
        speaks nothing."""
        self.turn("a first turn sets the generation")
        other = "codex" if self.provider == "claude" else "claude"
        self.send_controls(self.resume_payload(**fields) for fields in (
            {"session_id": opaque_identifier("session", "project:another")},
            {"recovery_generation": "7"},
            {"provider": other},
            {"final_result": "failed"},
            {"unavailable_capability": "something else"},
        ))
        self.assertNeverSpoken(PLEASE_REPEAT_TEXT)
        self.assertFalse(self.box.states("continuity_repeat"))

    def ready_payload(self, claimed: dict, **fields) -> dict:
        payload = {
            "type": "continuity_provider_ready",
            "event": "provider_ready",
            "relay_command_seq": claimed["relay_command_seq"],
            "relay_command_id": claimed["relay_command_id"],
            "intent_id": claimed["intent_id"],
            "intent_delivery_id": claimed["intent_delivery_id"],
            "intent_claim_id": claimed["intent_claim_id"],
            "intent_ack_id": claimed["intent_ack_id"],
            "previous_provider_session_id": self.session.provider_session_id,
            "provider_session_id": "11111111-2222-4333-8444-555555555555",
            "foreground_gate_handle": "gate-2",
            "provider": self.provider,
            "app_session_id": self.box.app_session_id,
            "recovery_generation": self.box.recovery_generation,
            "actor_role": "foreground_pm",
            "observed_at": time.time(),
        }
        payload.update(fields)
        return payload

    def ready_observations(self) -> list:
        return [body for body in self.observations("provider") if body.get("event") == "process_ready"]

    def test_provider_ready_for_a_mismatched_replacement_is_refused(self):
        """Continuity: a `continuity_provider_ready` control whose claim,
        provider, app session, generation, role or previous provider session
        does not match posts no `process_ready` observation."""
        claimed = self.claimed_turn("keep working on the parser")
        other = "codex" if self.provider == "claude" else "claude"
        self.send_controls(self.ready_payload(claimed, **fields) for fields in (
            {"intent_claim_id": "claim:someone-else"},
            {"previous_provider_session_id": "99999999-2222-4333-8444-555555555555"},
            {"provider_session_id": self.session.provider_session_id},
            {"foreground_gate_handle": ""},
            {"provider": other},
            {"app_session_id": "another-app-session"},
            {"recovery_generation": "9"},
            {"actor_role": "messenger"},
            {"event": "provider_gone"},
        ))
        self.assertStays(lambda: not self.ready_observations())

    def test_provider_ready_for_the_exact_replacement_is_accepted(self):
        """Continuity: a `continuity_provider_ready` control that names the
        claimed command exactly, this session's provider session as the
        previous one, a new provider session and gate handle, and this app
        session, provider and generation, posts a `provider` `process_ready`
        observation."""
        claimed = self.claimed_turn("keep working on the parser")
        self.box.control(self.ready_payload(claimed))
        observation = wait_until(self.ready_observations, message="process_ready")[0]
        self.assertEqual(observation["provider"], self.provider)
        self.assertEqual(observation["relay_command_id"], claimed["relay_command_id"])
        self.assertEqual(observation["session_id"], self.box.orchestrator.session_key)


class ClaudeStartupCleanup(StartupCleanupContract, BridgeCase):
    provider = "claude"


class CodexStartupCleanup(StartupCleanupContract, BridgeCase):
    provider = "codex"


class ClaudeContinuityPending(ContinuityPendingContract, BridgeCase):
    provider = "claude"


class CodexContinuityPending(ContinuityPendingContract, BridgeCase):
    provider = "codex"


class ClaudePreservedAuthorization(PreservedAuthorizationContract, BridgeCase):
    provider = "claude"


class CodexPreservedAuthorization(PreservedAuthorizationContract, BridgeCase):
    provider = "codex"


class ClaudeInboxRestart(InboxRestartContract, BridgeCase):
    provider = "claude"


class CodexInboxRestart(InboxRestartContract, BridgeCase):
    provider = "codex"


class ClaudeWatchdogRestart(WatchdogRestartContract, BridgeCase):
    provider = "claude"


class CodexWatchdogRestart(WatchdogRestartContract, BridgeCase):
    provider = "codex"


class ClaudeSpeechServiceRestart(SpeechServiceRestartContract, BridgeCase):
    provider = "claude"


class CodexSpeechServiceRestart(SpeechServiceRestartContract, BridgeCase):
    provider = "codex"


class ClaudeContinuityControl(ContinuityControlContract, BridgeCase):
    provider = "claude"


class CodexContinuityControl(ContinuityControlContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
