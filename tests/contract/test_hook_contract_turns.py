"""Turn lifecycle contract: SessionStart, UserPromptSubmit, Stop, StopFailure.

Shared cases run once per provider. Claude names a turn with `prompt_id` and
Codex with `turn_id`; `Sandbox.payload` builds the matching shape.
"""

from __future__ import annotations

import calendar
import json
import os
import time
import unittest

from hook_contract_support import (
    COMPLETION_PREFIX,
    PROVIDER_TURN_EVENT_PREFIX,
    ContractCase,
    Sandbox,
    sha256_hex,
    stable_event_id,
)

PROMPT = "ship the release notes"
FINAL = "Release notes are ready \u2014 d\u00e9j\u00e0 vu \u2705"
OTHER_SESSION = "11111111-2222-4333-8444-555555555555"
PRESERVE = {
    "route": "continue_current",
    "authorization_effect": "preserve",
    "cancellation_scope": "none",
}


class TurnCase(ContractCase):
    def fresh_sandbox(self) -> Sandbox:
        self.box = Sandbox(self, self.provider)
        self.box.open_fifo()
        return self.box

    def submit(self, *, turn="turn-1", prompt=PROMPT, env=None, **fields):
        payload = self.box.payload("UserPromptSubmit", turn=turn, prompt=prompt, **fields)
        return self.box.hook(payload, env=env)

    def stop(self, *, turn="turn-1", text=FINAL, env=None, event="Stop", **fields):
        payload = self.box.payload(event, turn=turn, last_assistant_message=text, **fields)
        return self.box.hook(payload, env=env)

    def bound_turn(self, seq: int = 7, turn: str = "turn-1", prompt: str = PROMPT) -> dict:
        command = self.box.claim(seq, prompt)
        self.assertQuietSuccess(self.submit(turn=turn, prompt=prompt))
        self.assertEqual(len(self.box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
        return command

    def expected_completion(self, command: dict, *, turn="turn-1", event="Stop", **extra) -> dict:
        completion = {
            "event": event,
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "session_id": self.box.NATIVE_SESSION_ID,
            "session_key": "session-key-1",
            "intent_id": command["intent_id"],
            "within_turn_order": 1,
            "turn_id": turn,
            "provider": self.provider,
        }
        completion.update(self.box.ownership)
        completion.update(extra)
        return completion

    def completion_line(self, completion: dict) -> str:
        return COMPLETION_PREFIX + json.dumps(completion, sort_keys=True)

    def turn_states(self) -> list:
        return [
            (row["command_id"], row["native_turn_id"], row["state"], row["release_reason"])
            for row in self.box.rows("provider_turns")
        ]

    def transitions(self) -> list:
        return [
            (row["event_type"], row["from_state"], row["to_state"], row["release_reason"])
            for row in self.box.rows("provider_turn_transitions")
        ]

    def assertNothingBound(self) -> None:
        self.assertEqual(self.box.fifo_lines(), [])
        self.assertEqual(self.box.ledger_records(), [])
        self.assertEqual(self.box.rows("provider_turns"), [])
        self.assertEqual(self.box.rows("provider_turn_transitions"), [])


class TurnLifecycleContract:
    """Cases every provider must satisfy."""

    # -- UserPromptSubmit --------------------------------------------------

    def test_prompt_submit_binds_the_claimed_relay_command(self):
        box = self.box
        box.claim(action="dispatch", target="relay-runner")
        started = time.time()
        result = self.submit()
        self.assertQuietSuccess(result)
        self.assertNotIn(PROMPT, result.stderr)

        events = box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)
        self.assertEqual(len(events), 1)
        at = events[0]["observed_at"]
        self.assertRecent(at, started)
        self.assertEqual(events[0], {
            "event": "provider_started",
            "provider": self.provider,
            "relay_command_id": "cmd-7",
            "recovery_generation": "generation-1",
            "observed_at": at,
        })

        record = {
            "state": "active",
            "session_id": box.NATIVE_SESSION_ID,
            "turn_id": "turn-1",
            "created_at": at,
            "updated_at": at,
            "relay_command_seq": 7,
            "relay_command_id": "cmd-7",
            "intent_id": "intent-7",
            "within_turn_order": 1,
            "target": "relay-runner",
            "action": "dispatch",
            "prompt_sha256": sha256_hex(PROMPT),
            "provider": self.provider,
            "provider_session_id": box.PROVIDER_SESSION_ID,
        }
        record.update(box.ownership)
        self.assertEqual(box.ledger_records(), [record])

        owner_id, turn_id = box.owner_id(), box.turn_id()
        self.assertEqual(box.rows("provider_turn_meta"), [{"key": "schema_version", "value": "3"}])
        owner = {"owner_id": owner_id, "created_at": at}
        owner.update(box.ownership)
        self.assertEqual(box.rows("provider_turn_owners"), [owner])
        row = {
            "turn_id": turn_id,
            "owner_id": owner_id,
            "provider": self.provider,
            "provider_session_id": box.PROVIDER_SESSION_ID,
            "native_session_id": box.NATIVE_SESSION_ID,
            "native_turn_id": "turn-1",
            "local_turn_seq": None,
            "origin": "relay",
            "intent_id": "intent-7",
            "command_seq": 7,
            "command_id": "cmd-7",
            "manual_submission_id": None,
            "manual_submit_evidence_source": None,
            "state": "active",
            "release_reason": None,
            "created_at": at,
            "updated_at": at,
        }
        row.update(box.ownership)
        self.assertEqual(box.rows("provider_turns"), [row])
        self.assertEqual(box.rows("provider_turn_transitions"), [{
            "transition_ordinal": 1,
            "event_id": stable_event_id("activate", turn_id),
            "turn_id": turn_id,
            "event_type": "prompt_submitted",
            "from_state": None,
            "to_state": "active",
            "occurred_at": at,
            "release_reason": None,
        }])
        self.assertEqual(box.rows("provider_turn_effects"), [])

        projected = {
            "state": "active",
            "origin": "relay",
            "session_id": box.NATIVE_SESSION_ID,
            "turn_id": "turn-1",
            "relay_command_seq": 7,
            "relay_command_id": "cmd-7",
            "intent_id": "intent-7",
            "provider": self.provider,
            "provider_session_id": box.PROVIDER_SESSION_ID,
            "created_at": at,
            "updated_at": at,
        }
        projected.update(box.ownership)
        self.assertEqual(box.projection_records(), [projected])
        self.assertEqual(box.mode(box.projection_path), 0o600)

    def test_prompt_submit_without_foreground_ownership_is_ignored(self):
        cases = (
            ("bridge role", {"RELAY_ACTOR_ROLE": "voice_bridge"}),
            ("no gate handle", {"RELAY_FOREGROUND_GATE_HANDLE": None}),
            ("no app session", {"RELAY_APP_SESSION_ID": ""}),
        )
        for name, overrides in cases:
            with self.subTest(name):
                box = self.fresh_sandbox()
                box.claim()
                self.assertQuietSuccess(self.submit(env=box.env(**overrides)))
                self.assertNothingBound()
                self.assertFalse(box.inbox_path.exists())
                self.assertEqual(box.jsonl(box.compaction_events_path), [])

    def test_prompt_submit_with_a_stale_claim_is_not_bound(self):
        box = self.box
        box.write_claim(box.command(7))
        box.write_state(box.command(8))
        self.assertQuietSuccess(self.submit())
        self.assertNothingBound()

    def test_prompt_submit_with_a_mismatched_prompt_is_not_bound(self):
        self.box.claim()
        result = self.submit(prompt="something the user typed")
        self.assertQuietSuccess(result)
        self.assertNotIn("something the user typed", result.stderr)
        self.assertNothingBound()

    def test_prompt_submit_without_a_claim_is_not_bound(self):
        self.box.write_state(self.box.command(7))
        self.assertQuietSuccess(self.submit())
        self.assertNothingBound()

    def test_prompt_submit_without_prompt_text_is_ignored(self):
        self.box.claim()
        self.assertQuietSuccess(self.submit(prompt=""))
        self.assertNothingBound()

    def test_prompt_submit_from_a_tool_continuation_is_ignored(self):
        self.box.claim()
        self.assertQuietSuccess(self.submit(parent_tool_use_id="toolu_01"))
        self.assertNothingBound()

    def test_leased_command_binds_while_a_newer_command_is_current(self):
        box = self.box
        leased = box.command(7)
        box.write_claim(leased)
        newest = box.command(8, "a newer request")
        newest["deliverable_commands"] = [dict(leased, state="claimed")]
        box.write_state(newest)
        self.assertQuietSuccess(self.submit())
        self.assertEqual([e["relay_command_id"] for e in box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)], ["cmd-7"])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])

    def test_agent_prompt_is_the_text_matched_when_the_claim_has_one(self):
        box = self.box
        box.claim(agent_prompt="[voice] " + PROMPT)
        self.assertQuietSuccess(self.submit(prompt=PROMPT))
        self.assertNothingBound()
        self.assertQuietSuccess(self.submit(prompt="[voice] " + PROMPT))
        self.assertEqual(len(box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
        self.assertEqual(box.ledger_records()[0]["prompt_sha256"], sha256_hex("[voice] " + PROMPT))

    def test_repeated_prompt_submit_for_one_turn_binds_once(self):
        self.bound_turn()
        self.assertQuietSuccess(self.submit())
        self.assertEqual(self.box.fifo_lines(), [])
        self.assertEqual(len(self.box.ledger_records()), 1)
        self.assertEqual(self.transitions(), [("prompt_submitted", None, "active", None)])

    def test_prompt_submit_binds_without_a_fifo_reader(self):
        box = self.box
        box.claim()
        box.close_fifo_reader()
        self.assertQuietSuccess(self.submit())
        self.assertEqual([r["state"] for r in box.ledger_records()], ["active"])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])

    def test_prompt_submit_binds_without_a_fifo(self):
        box = self.box
        box.claim()
        box.close_fifo_reader()
        os.unlink(str(box.fifo_path))
        self.assertQuietSuccess(self.submit())
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])
        self.assertFalse(box.fifo_path.exists())

    def test_newer_command_supersedes_the_active_turn(self):
        box = self.box
        self.bound_turn(7, "turn-1")
        newer = self.bound_turn(8, "turn-2", "also update the changelog")

        older, current = box.ledger_records()
        self.assertEqual(older["state"], "orphaned")
        self.assertEqual(older["release_reason"], "superseded_by_prompt_submit")
        self.assertEqual(older["provider_ownership_disposition"], "source_superseded")
        self.assertEqual(older["successor_record_key"], box.NATIVE_SESSION_ID + ":turn-2")
        self.assertEqual(older["successor_origin"], "relay")
        self.assertEqual((current["relay_command_id"], current["state"]), ("cmd-8", "active"))
        self.assertEqual(self.turn_states(), [
            ("cmd-7", "turn-1", "orphaned", "superseded_by_prompt_submit"),
            ("cmd-8", "turn-2", "active", None),
        ])
        self.assertEqual(self.transitions(), [
            ("prompt_submitted", None, "active", None),
            ("superseded", "active", "orphaned", "superseded_by_prompt_submit"),
            ("prompt_submitted", None, "active", None),
        ])
        superseded = box.rows("provider_turn_transitions")[1]
        self.assertEqual(
            superseded["event_id"],
            stable_event_id("supersede", box.turn_id("turn-1"), box.turn_id("turn-2")),
        )

        self.assertQuietSuccess(self.stop(turn="turn-1", text="late answer"))
        self.assertEqual(box.fifo_lines(), [])
        self.assertQuietSuccess(self.stop(turn="turn-2"))
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(newer, turn="turn-2", text=FINAL))],
        )

    def test_same_text_after_the_command_finished_is_not_bound_again(self):
        self.bound_turn()
        self.assertQuietSuccess(self.stop())
        self.assertEqual(len(self.box.fifo_lines()), 1)
        self.assertQuietSuccess(self.submit(turn="turn-2"))
        self.assertEqual(self.box.fifo_lines(), [])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "completed_final", "provider_stop")])

    # -- manual terminal input ---------------------------------------------

    def test_manual_terminal_submission_opens_and_closes_a_manual_turn(self):
        box = self.box
        evidence = box.write_manual_evidence()
        started = time.time()
        result = self.submit(prompt="typed by hand")
        self.assertQuietSuccess(result)
        self.assertNotIn("typed by hand", result.stderr)
        self.assertEqual(box.fifo_lines(), [])

        (record,) = box.ledger_records()
        at = record["created_at"]
        self.assertRecent(at, started)
        expected = {
            "state": "active",
            "origin": "manual",
            "session_id": box.NATIVE_SESSION_ID,
            "turn_id": "turn-1",
            "created_at": at,
            "updated_at": at,
            "manual_submission_id": "submission-1",
            "manual_submit_evidence_source": "relay_terminal_manual_submit",
            "provider": self.provider,
            "provider_session_id": box.PROVIDER_SESSION_ID,
        }
        expected.update(box.ownership)
        self.assertEqual(record, expected)
        consumed = dict(evidence, state="consumed", consumed_at=at,
                        native_session_id=box.NATIVE_SESSION_ID, native_turn_id="turn-1")
        self.assertEqual(box.read_json(box.manual_path), consumed)

        (row,) = box.rows("provider_turns")
        self.assertEqual(
            (row["origin"], row["state"], row["intent_id"], row["command_seq"], row["command_id"]),
            ("manual", "active", None, None, None),
        )
        self.assertEqual(row["manual_submission_id"], "submission-1")
        self.assertEqual(row["manual_submit_evidence_source"], "relay_terminal_manual_submit")

        self.assertQuietSuccess(self.stop())
        self.assertEqual(box.fifo_lines(), [])
        (record,) = box.ledger_records()
        self.assertEqual((record["state"], record["release_reason"]), ("completed_manual", "provider_stop"))
        self.assertEqual(self.transitions(), [
            ("prompt_submitted", None, "active", None),
            ("provider_completed", "active", "completed_manual", "provider_stop"),
        ])

    def test_manual_submission_without_valid_evidence_is_not_bound(self):
        other_provider = "codex" if self.provider == "claude" else "claude"
        cases = (
            ("stale boundary", {"observed_at": time.time() - 60}),
            ("future boundary", {"observed_at": time.time() + 60}),
            ("already consumed", {"state": "consumed"}),
            ("unknown source", {"evidence_source": "keyboard"}),
            ("other provider session", {"provider_session_id": OTHER_SESSION}),
            ("other provider", {"provider": other_provider}),
            ("other foreground owner", {"foreground_gate_handle": "gate-2"}),
            ("no submission id", {"submission_id": ""}),
        )
        for name, overrides in cases:
            with self.subTest(name):
                box = self.fresh_sandbox()
                evidence = box.write_manual_evidence(**overrides)
                self.assertQuietSuccess(self.submit(prompt="typed by hand"))
                self.assertNothingBound()
                self.assertEqual(box.read_json(box.manual_path), evidence)

    # -- Stop ----------------------------------------------------------------

    def test_stop_publishes_the_final_reply(self):
        box = self.box
        command = self.bound_turn()
        started = time.time()
        result = self.stop(text="  " + FINAL + "\n")
        self.assertQuietSuccess(result)
        self.assertNotIn(FINAL, result.stderr)

        line = self.completion_line(self.expected_completion(command, text=FINAL))
        self.assertIn("\\u2014 d\\u00e9j\\u00e0 vu \\u2705", line)
        self.assertEqual(box.fifo_lines(), [line])

        (record,) = box.ledger_records()
        self.assertEqual(
            (record["state"], record["delivery"], record["release_reason"]),
            ("completed_final", "sent", "provider_stop"),
        )
        self.assertRecent(record["updated_at"], started)
        (row,) = box.rows("provider_turns")
        self.assertEqual((row["state"], row["release_reason"]), ("completed_final", "provider_stop"))
        self.assertEqual(row["updated_at"], record["updated_at"])
        completed = box.rows("provider_turn_transitions")[1]
        self.assertEqual(completed, {
            "transition_ordinal": 2,
            "event_id": stable_event_id("provider_completed", box.turn_id(), "completed_final", "provider_stop"),
            "turn_id": box.turn_id(),
            "event_type": "provider_completed",
            "from_state": "active",
            "to_state": "completed_final",
            "occurred_at": record["updated_at"],
            "release_reason": "provider_stop",
        })
        self.assertEqual([r["state"] for r in box.projection_records()], ["completed_final"])

    def test_stop_without_final_text_reports_an_empty_completion(self):
        command = self.bound_turn()
        self.assertQuietSuccess(self.stop(text="   "))
        self.assertEqual(
            self.box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, completion_status="empty"))],
        )
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "empty", "provider_stop")])
        self.assertEqual(self.box.ledger_records()[0]["state"], "empty")

    def test_second_stop_for_a_finished_turn_is_ignored(self):
        self.bound_turn()
        self.assertQuietSuccess(self.stop())
        self.assertEqual(len(self.box.fifo_lines()), 1)
        self.assertQuietSuccess(self.stop(text="a different answer"))
        self.assertEqual(self.box.fifo_lines(), [])
        self.assertEqual(len(self.transitions()), 2)

    def test_stop_without_foreground_ownership_leaves_the_turn_open(self):
        box = self.box
        command = self.bound_turn()
        for overrides in ({"RELAY_ACTOR_ROLE": "voice_bridge"}, {"RELAY_RECOVERY_GENERATION": None}):
            self.assertQuietSuccess(self.stop(env=box.env(**overrides)))
            self.assertEqual(box.fifo_lines(), [])
            self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])
        # Another foreground owner cannot finish this owner's turn either.
        self.assertQuietSuccess(self.stop(env=box.env(RELAY_FOREGROUND_GATE_HANDLE="gate-2")))
        self.assertEqual(box.fifo_lines(), [])
        self.assertQuietSuccess(self.stop())
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )

    def test_stop_without_a_bound_turn_publishes_nothing(self):
        self.box.claim()
        result = self.stop()
        self.assertQuietSuccess(result)
        self.assertNotIn(FINAL, result.stderr)
        self.assertNothingBound()

    def test_stop_for_a_superseded_command_is_dropped_as_stale(self):
        box = self.box
        self.bound_turn()
        box.write_state(box.command(8, "a newer request"))
        self.assertQuietSuccess(self.stop())
        self.assertEqual(box.fifo_lines(), [])
        (record,) = box.ledger_records()
        self.assertEqual((record["state"], record["release_reason"]), ("stale", "stale_current_command"))
        self.assertNotIn("delivery", record)
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "stale", "stale_current_command")])
        stale = box.rows("provider_turn_transitions")[1]
        self.assertEqual(stale["event_type"], "provider_completion_stale")
        self.assertEqual(
            stale["event_id"],
            stable_event_id("provider_completion_stale", box.turn_id(), "stale", "stale_current_command"),
        )

    def test_stop_for_a_cancelled_intent_is_dropped_as_stale(self):
        box = self.box
        command = self.bound_turn()
        box.write_state(dict(command, cancelled_intent_ids=["intent-7"]))
        self.assertQuietSuccess(self.stop())
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "stale", "stale_current_command")])

    def test_stop_is_published_when_a_newer_command_preserves_current_work(self):
        box = self.box
        command = self.bound_turn()
        box.write_state(dict(box.command(8, "what is the status"), work_disposition=PRESERVE))
        self.assertQuietSuccess(self.stop())
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )

    def test_stop_without_a_fifo_reader_records_the_bridge_as_unavailable(self):
        box = self.box
        self.bound_turn()
        box.close_fifo_reader()
        result = self.stop()
        self.assertQuietSuccess(result)
        self.assertNotIn(FINAL, result.stderr)
        (record,) = box.ledger_records()
        self.assertEqual((record["state"], record["delivery"]), ("completed_final", "bridge_unavailable"))
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "completed_final", "provider_stop")])

    def test_stop_without_a_fifo_records_the_bridge_as_unavailable(self):
        box = self.box
        self.bound_turn()
        box.close_fifo_reader()
        os.unlink(str(box.fifo_path))
        self.assertQuietSuccess(self.stop())
        (record,) = box.ledger_records()
        self.assertEqual((record["state"], record["delivery"]), ("completed_final", "bridge_unavailable"))
        self.assertFalse(box.fifo_path.exists())

    # -- correlation through the broker tables --------------------------------

    def test_stop_completes_a_turn_after_the_ledger_file_was_removed(self):
        box = self.box
        command = self.bound_turn()
        os.unlink(str(box.turns_path))
        self.assertQuietSuccess(self.stop())
        expected = self.expected_completion(command, text=FINAL)
        del expected["within_turn_order"]  # not a column of provider_turns
        self.assertEqual(box.fifo_lines(), [self.completion_line(expected)])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "completed_final", "provider_stop")])

    def test_stop_completes_a_turn_another_writer_recorded_in_the_tables(self):
        box = self.box
        box.create_inbox()
        box.seed_turn()
        command = box.command(7)
        box.write_state(command)
        self.assertQuietSuccess(self.stop())
        expected = self.expected_completion(command, text=FINAL)
        del expected["within_turn_order"]
        self.assertEqual(box.fifo_lines(), [self.completion_line(expected)])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "completed_final", "provider_stop")])
        self.assertEqual(self.transitions(), [("provider_completed", "active", "completed_final", "provider_stop")])

    def test_stop_ignores_a_turn_another_writer_already_closed(self):
        box = self.box
        box.create_inbox()
        box.seed_turn(state="terminated", release_reason="provider_exit")
        box.write_state(box.command(7))
        self.assertQuietSuccess(self.stop())
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "terminated", "provider_exit")])
        self.assertEqual(self.transitions(), [])

    def test_legacy_broker_mode_keeps_the_ledger_and_skips_the_tables(self):
        box = self.box
        command = box.claim()
        env = box.env(RELAY_PROVIDER_TURN_BROKER_MODE="legacy")
        self.assertQuietSuccess(self.submit(env=env))
        self.assertEqual(len(box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
        self.assertQuietSuccess(self.stop(env=env))
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )
        self.assertEqual(box.ledger_records()[0]["state"], "completed_final")
        self.assertFalse(box.inbox_path.exists())
        self.assertFalse(box.projection_path.exists())


class ClaudeTurnLifecycle(TurnLifecycleContract, TurnCase):
    provider = "claude"

    # -- SessionStart ----------------------------------------------------------

    def test_session_start_records_the_first_run_boundary(self):
        box = self.box
        started = int(time.time())
        result = box.hook(
            box.payload("SessionStart", source="startup"),
            env=box.env(RELAY_ACTOR_ROLE="voice_bridge"),
        )
        self.assertQuietSuccess(result)
        raw = box.session_events_path.read_text()
        (event,) = box.jsonl(box.session_events_path)
        self.assertEqual(raw, json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
        self.assertEqual(sorted(event), ["outcome", "stage", "timestamp"])
        self.assertEqual((event["outcome"], event["stage"]), ("ready", "provider_session_start"))
        self.assertRegex(event["timestamp"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        recorded = calendar.timegm(time.strptime(event["timestamp"], "%Y-%m-%dT%H:%M:%SZ"))
        self.assertTrue(started <= recorded <= int(time.time()) + 1)
        self.assertEqual(box.mode(box.session_events_path), 0o600)
        self.assertNothingBound()
        self.assertFalse(box.inbox_path.exists())
        self.assertFalse(box.compaction_events_path.exists())

    def test_session_start_appends_to_existing_session_events(self):
        box = self.box
        box.session_events_path.write_text('{"stage":"launcher_start"}\n')
        self.assertQuietSuccess(box.hook(box.payload("SessionStart", source="resume")))
        stages = [event["stage"] for event in box.jsonl(box.session_events_path)]
        self.assertEqual(stages, ["launcher_start", "provider_session_start"])

    def test_session_start_without_a_session_events_path_writes_nothing(self):
        box = self.box
        before = sorted(str(path) for path in box.root.rglob("*"))
        result = box.hook(
            box.payload("SessionStart", source="startup"),
            env=box.env(RELAY_SESSION_EVENTS=None),
        )
        self.assertQuietSuccess(result)
        self.assertEqual(sorted(str(path) for path in box.root.rglob("*")), before)

    def test_session_start_with_an_unwritable_events_path_still_succeeds(self):
        box = self.box
        missing = box.root / "missing-directory" / "session.events.jsonl"
        result = box.hook(
            box.payload("SessionStart", source="startup"),
            env=box.env(RELAY_SESSION_EVENTS=str(missing)),
        )
        self.assertQuietSuccess(result)
        self.assertFalse(missing.parent.exists())

    # -- Claude payload shape --------------------------------------------------

    def test_prompt_id_stands_in_for_the_turn_id(self):
        box = self.box
        box.claim()
        payload = box.payload("UserPromptSubmit", turn=None, prompt=PROMPT, prompt_id="prompt-abc")
        self.assertNotIn("turn_id", payload)
        self.assertQuietSuccess(box.hook(payload))
        self.assertEqual(box.ledger_records()[0]["turn_id"], "prompt-abc")
        (row,) = box.rows("provider_turns")
        self.assertEqual(row["native_turn_id"], "prompt-abc")
        self.assertEqual(row["turn_id"], box.turn_id("prompt-abc"))

    def test_stop_with_a_rotated_prompt_id_completes_the_sole_active_turn(self):
        command = self.bound_turn()
        self.assertQuietSuccess(self.stop(turn="prompt-after-dequeue"))
        self.assertEqual(
            self.box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )

    def test_pasted_prompt_envelope_matches_the_claim(self):
        envelopes = (
            ("new prompt", '\n\n<pasted_content id="1f">\n%s\n</pasted_content id="1f">\n'),
            ("steered into a turn", '<pasted_content id="1f">\n%s\n</pasted_content id="1f">'),
        )
        for name, envelope in envelopes:
            with self.subTest(name):
                box = self.fresh_sandbox()
                box.claim(prompt="line one\nline two")
                prompt = envelope % "line one\nline two"
                self.assertQuietSuccess(self.submit(prompt=prompt))
                self.assertEqual(len(box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
                self.assertEqual(box.ledger_records()[0]["prompt_sha256"], sha256_hex(prompt))

    def test_incomplete_pasted_prompt_envelope_is_not_matched(self):
        envelopes = (
            ("leading newlines only", '\n\n<pasted_content id="1f">\n%s\n</pasted_content id="1f">'),
            ("mismatched ids", '<pasted_content id="1f">\n%s\n</pasted_content id="2a">'),
            ("extra text", 'please <pasted_content id="1f">\n%s\n</pasted_content id="1f">'),
        )
        for name, envelope in envelopes:
            with self.subTest(name):
                box = self.fresh_sandbox()
                box.claim()
                self.assertQuietSuccess(self.submit(prompt=envelope % PROMPT))
                self.assertNothingBound()

    def test_manual_submission_without_a_prompt_id_uses_a_local_turn_sequence(self):
        box = self.box
        box.write_manual_evidence()
        self.assertQuietSuccess(self.submit(turn=None, prompt="typed by hand"))
        (record,) = box.ledger_records()
        self.assertEqual(record["local_turn_seq"], 1)
        self.assertNotIn("turn_id", record)
        self.assertNotIn("native_turn_id", box.read_json(box.manual_path))
        (row,) = box.rows("provider_turns")
        self.assertEqual((row["native_turn_id"], row["local_turn_seq"]), (None, 1))
        self.assertEqual(row["turn_id"], box.turn_id("local:1"))

        self.assertQuietSuccess(self.stop(turn=None))
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual([r["state"] for r in box.rows("provider_turns")], ["completed_manual"])

    # -- StopFailure -----------------------------------------------------------

    def test_stop_failure_publishes_a_failed_completion_without_text(self):
        box = self.box
        command = self.bound_turn()
        result = self.stop(event="StopFailure", text="partial answer", error="rate_limit")
        self.assertQuietSuccess(result)
        expected = self.expected_completion(command, event="StopFailure", completion_status="failed")
        self.assertEqual(box.fifo_lines(), [self.completion_line(expected)])
        (record,) = box.ledger_records()
        self.assertEqual(
            (record["state"], record["delivery"], record["release_reason"]),
            ("failed", "sent", "provider_stop_failure"),
        )
        self.assertEqual(self.transitions()[1], ("provider_completed", "active", "failed", "provider_stop_failure"))
        self.assertEqual(
            box.rows("provider_turn_transitions")[1]["event_id"],
            stable_event_id("provider_completed", box.turn_id(), "failed", "provider_stop_failure"),
        )

    def test_stop_failure_closes_a_manual_turn_as_failed(self):
        box = self.box
        box.write_manual_evidence()
        self.assertQuietSuccess(self.submit(prompt="typed by hand"))
        self.assertQuietSuccess(self.stop(event="StopFailure", text="", error="overloaded"))
        self.assertEqual(box.fifo_lines(), [])
        (record,) = box.ledger_records()
        self.assertEqual((record["state"], record["release_reason"]), ("failed_manual", "provider_stop_failure"))
        self.assertEqual([r["state"] for r in box.rows("provider_turns")], ["failed_manual"])

    def test_stop_failure_without_a_bound_turn_publishes_nothing(self):
        self.box.claim()
        self.assertQuietSuccess(self.stop(event="StopFailure", text="", error="rate_limit"))
        self.assertNothingBound()

    def test_stop_failure_without_foreground_ownership_leaves_the_turn_open(self):
        box = self.box
        self.bound_turn()
        env = box.env(RELAY_ACTOR_ROLE="voice_bridge")
        self.assertQuietSuccess(self.stop(event="StopFailure", text="", error="rate_limit", env=env))
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])


class CodexTurnLifecycle(TurnLifecycleContract, TurnCase):
    provider = "codex"

    def test_prompt_id_is_not_a_turn_id_for_codex(self):
        box = self.box
        box.claim()
        payload = box.payload("UserPromptSubmit", turn=None, prompt=PROMPT, prompt_id="prompt-abc")
        self.assertQuietSuccess(box.hook(payload))
        (record,) = box.ledger_records()
        self.assertNotIn("turn_id", record)
        (row,) = box.rows("provider_turns")
        self.assertIsNone(row["native_turn_id"])
        self.assertEqual(row["turn_id"], box.turn_id("session"))

    def test_camel_case_payload_keys_are_accepted(self):
        box = self.box
        command = box.claim()
        common = {"sessionId": box.NATIVE_SESSION_ID, "turnId": "turn-1"}
        self.assertQuietSuccess(box.hook(dict(common, hookEventName="UserPromptSubmit", prompt=PROMPT)))
        self.assertEqual(len(box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
        self.assertQuietSuccess(box.hook(dict(common, hookEventName="Stop", last_assistant_message=FINAL)))
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )

    def test_pasted_prompt_envelope_is_not_matched_for_codex(self):
        self.box.claim()
        prompt = '<pasted_content id="1f">\n%s\n</pasted_content id="1f">' % PROMPT
        self.assertQuietSuccess(self.submit(prompt=prompt))
        self.assertNothingBound()

    def test_stop_with_an_unknown_turn_id_is_rejected(self):
        self.bound_turn()
        self.assertQuietSuccess(self.stop(turn="turn-unknown"))
        self.assertEqual(self.box.fifo_lines(), [])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])

    def test_startup_identity_is_rebound_to_the_persisted_session(self):
        box = self.box
        command = box.claim()
        self.assertQuietSuccess(self.submit(session=OTHER_SESSION))
        self.assertQuietSuccess(self.submit())
        events = box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)
        self.assertEqual([e["relay_command_id"] for e in events], ["cmd-7", "cmd-7"])

        startup, persisted = box.ledger_records()
        self.assertEqual((startup["session_id"], startup["state"]), (OTHER_SESSION, "orphaned"))
        self.assertEqual(startup["release_reason"], "provider_identity_rebound")
        self.assertEqual(startup["provider_ownership_disposition"], "continued")
        self.assertEqual(startup["successor_record_key"], box.NATIVE_SESSION_ID + ":turn-1")
        self.assertEqual((persisted["session_id"], persisted["state"]), (box.NATIVE_SESSION_ID, "active"))
        self.assertEqual(
            [(row["native_session_id"], row["state"], row["release_reason"]) for row in box.rows("provider_turns")],
            [(OTHER_SESSION, "orphaned", "provider_identity_rebound"), (box.NATIVE_SESSION_ID, "active", None)],
        )
        self.assertEqual(self.transitions(), [
            ("prompt_submitted", None, "active", None),
            ("superseded", "active", "orphaned", "provider_identity_rebound"),
            ("prompt_submitted", None, "active", None),
        ])

        self.assertQuietSuccess(self.stop())
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )

    def test_stop_from_a_changed_native_session_is_reconciled_by_turn_id(self):
        box = self.box
        command = self.bound_turn()
        self.assertQuietSuccess(self.stop(session=OTHER_SESSION))
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(command, text=FINAL))],
        )
        (record,) = box.ledger_records()
        self.assertEqual(record["state"], "completed_final")
        self.assertEqual(record["release_reason"], "provider_stop_identity_reconciled")
        self.assertEqual(record["completion_correlation"], "provider_identity_reconciled")
        self.assertEqual(record["completion_native_session_id"], OTHER_SESSION)
        self.assertIsInstance(record["completion_record_age_ms"], int)
        self.assertEqual(
            self.turn_states(),
            [("cmd-7", "turn-1", "completed_final", "provider_stop_identity_reconciled")],
        )

    def test_changed_native_session_without_a_provider_session_is_rejected(self):
        box = self.box
        self.bound_turn()
        env = box.env(RELAY_PROVIDER_SESSION_ID=None)
        self.assertQuietSuccess(self.stop(session=OTHER_SESSION, env=env))
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(self.turn_states(), [("cmd-7", "turn-1", "active", None)])

    def test_steered_prompt_moves_the_physical_turn_to_the_newer_command(self):
        box = self.box
        self.bound_turn(7)
        newer = self.bound_turn(8, "turn-1", "also update the changelog")

        (record,) = box.ledger_records()
        self.assertEqual((record["relay_command_id"], record["state"]), ("cmd-8", "active"))
        (row,) = box.rows("provider_turns")
        self.assertEqual((row["command_seq"], row["command_id"], row["intent_id"]), (8, "cmd-8", "intent-8"))
        self.assertEqual(self.transitions(), [
            ("prompt_submitted", None, "active", None),
            ("prompt_steered", "active", "active", None),
        ])
        self.assertEqual(
            box.rows("provider_turn_transitions")[1]["event_id"],
            stable_event_id("steer", box.turn_id(), "relay", "intent-8", 8, "cmd-8", None),
        )

        self.assertQuietSuccess(self.stop())
        self.assertEqual(
            box.fifo_lines(),
            [self.completion_line(self.expected_completion(newer, text=FINAL))],
        )


if __name__ == "__main__":
    unittest.main()
