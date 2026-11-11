"""Fault contract: malformed stdin, a locked inbox and an oversized reply.

A lifecycle hook must never fail the provider's turn: whatever it is given, it
exits 0, prints nothing on stdout and leaves no half-written state.
"""

from __future__ import annotations

import json
import threading
import time
import unittest

from hook_contract_support import (
    COMPLETION_PREFIX,
    FIFO_BUFFER_BYTES,
    HOOK_BUDGET_SECONDS,
    PROVIDER_TURN_EVENT_PREFIX,
    ContractCase,
    known_difference,
)

PROMPT = "ship the release notes"
FINAL = "Release notes are ready."


class FaultCase(ContractCase):
    def bind(self) -> dict:
        box = self.box
        command = box.claim()
        self.assertQuietSuccess(box.hook(box.payload("UserPromptSubmit", prompt=PROMPT)))
        self.assertEqual(len(box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
        return command

    def stop(self, text: str = FINAL):
        box = self.box
        return box.hook(box.payload("Stop", last_assistant_message=text))

    def turn_states(self) -> list:
        return [(row["command_id"], row["state"]) for row in self.box.rows("provider_turns")]

    def assertUntouched(self) -> None:
        box = self.box
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(box.ledger_records(), [])
        self.assertEqual(box.rows("provider_turns"), [])
        self.assertEqual(box.rows("provider_turn_transitions"), [])
        self.assertFalse(box.binding_path.parent.exists())
        self.assertFalse(box.session_events_path.exists())
        self.assertFalse(box.compaction_events_path.exists())


class FaultContract:
    """Cases every provider must satisfy."""

    # -- malformed stdin -----------------------------------------------------

    def test_stdin_that_is_not_a_json_object_is_ignored(self):
        box = self.box
        box.claim()
        inputs = (
            b"", b"   \n", b"{", b'{"hook_event_name": "Stop"', b"not json at all",
            b"[]", b'[{"hook_event_name": "Stop"}]', b'"Stop"', b"42", b"null", b"true",
            b'{"hook_event_name": "Stop"} trailing',
        )
        for data in inputs:
            with self.subTest(stdin=data):
                self.assertQuietSuccess(box.hook(data, env=box.binding_env()))
                self.assertUntouched()
                self.assertFalse(box.inbox_path.exists())

    @known_difference(
        "Under a UTF-8 locale the Python hook exits 1 with a traceback when stdin is not valid UTF-8."
    )
    def test_stdin_that_is_not_utf8_is_ignored(self):
        box = self.box
        self.bind()
        stop = json.dumps(box.payload("Stop", last_assistant_message="FINAL")).encode("utf-8")
        for locale in (None, "en_US.UTF-8"):
            for data in (b"\xff\xfe" + stop, stop.replace(b"FINAL", b"caf\xe9 \xff")):
                with self.subTest(locale=locale, stdin=data[:12]):
                    self.assertQuietSuccess(box.hook(data, env=box.env(LC_ALL=locale)))
                    self.assertNotIn(b"\xff", box.fifo_bytes())

    def test_event_with_unusable_fields_is_ignored(self):
        box = self.box
        box.claim()
        payloads = (
            {},
            {"hook_event_name": None},
            {"hook_event_name": ["Stop"]},
            {"hook_event_name": "Unknown", "session_id": box.NATIVE_SESSION_ID, "prompt": PROMPT},
            {"hook_event_name": "stop", "session_id": box.NATIVE_SESSION_ID},
            {"hook_event_name": "UserPromptSubmit", "session_id": box.NATIVE_SESSION_ID, "prompt": 42},
            {"hook_event_name": "UserPromptSubmit", "session_id": box.NATIVE_SESSION_ID, "prompt": [PROMPT]},
            {"hook_event_name": "UserPromptSubmit", "session_id": box.NATIVE_SESSION_ID},
            {"hook_event_name": "Stop", "session_id": {"id": 1}, "last_assistant_message": {"text": FINAL}},
            {"hook_event_name": "Stop", "session_id": None, "turn_id": 7, "last_assistant_message": FINAL},
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                self.assertQuietSuccess(box.hook(payload))
                self.assertEqual(box.fifo_lines(), [])
                self.assertEqual(box.ledger_records(), [])
                self.assertEqual(box.rows("provider_turns"), [])

    def test_unreadable_claim_and_state_files_bind_nothing(self):
        box = self.box
        command = box.command()
        cases = (
            ("claim is not JSON", "{", json.dumps(command)),
            ("claim is not an object", "[1]", json.dumps(command)),
            ("claim has no command id", json.dumps(dict(command, relay_command_id="")), json.dumps(command)),
            ("claim has no sequence", json.dumps(dict(command, relay_command_seq="next")), json.dumps(command)),
            ("state is not JSON", json.dumps(command), "{"),
            ("state is not an object", json.dumps(command), '"cmd-7"'),
        )
        for name, claim, state in cases:
            with self.subTest(name):
                box.claim_path.write_text(claim)
                box.state_path.write_text(state)
                self.assertQuietSuccess(box.hook(box.payload("UserPromptSubmit", prompt=PROMPT)))
                self.assertEqual(box.fifo_lines(), [])
                self.assertEqual(box.ledger_records(), [])
                self.assertEqual(box.rows("provider_turns"), [])

    def test_unreadable_turn_ledger_is_replaced(self):
        box = self.box
        box.turns_path.write_text("{ not json")
        self.bind()
        self.assertEqual([record["state"] for record in box.ledger_records()], ["active"])

    # -- locked inbox ----------------------------------------------------------

    def test_hook_waits_for_a_briefly_locked_inbox(self):
        box = self.box
        box.create_inbox()
        command = box.claim()
        lock = box.hold_write_lock()
        threading.Timer(0.5, lock.rollback).start()
        result = box.hook(box.payload("UserPromptSubmit", prompt=PROMPT))
        self.assertQuietSuccess(result)
        self.assertGreaterEqual(result.elapsed, 0.4)
        self.assertEqual(len(box.fifo_messages(PROVIDER_TURN_EVENT_PREFIX)), 1)
        self.assertEqual(self.turn_states(), [(command["relay_command_id"], "active")])

    def test_stop_while_the_inbox_stays_locked_publishes_nothing(self):
        box = self.box
        self.bind()
        box.hold_write_lock()
        result = self.stop()
        self.assertQuietSuccess(result)
        self.assertNotIn(FINAL, result.stderr)
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual([record["state"] for record in box.ledger_records()], ["active"])
        self.assertEqual(self.turn_states(), [("cmd-7", "active")])
        self.assertEqual(len(box.rows("provider_turn_transitions")), 1)

    def test_inbox_that_is_not_a_database_publishes_nothing(self):
        box = self.box
        box.claim()
        box.inbox_path.write_bytes(b"this is not a database" * 100)
        self.assertQuietSuccess(box.hook(box.payload("UserPromptSubmit", prompt=PROMPT)))
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual(box.ledger_records(), [])
        self.assertEqual(box.inbox_path.read_bytes(), b"this is not a database" * 100)

    # -- oversized reply ---------------------------------------------------------

    def test_reply_that_fills_the_fifo_buffer_arrives_whole(self):
        box = self.box
        command = self.bind()
        empty = COMPLETION_PREFIX + json.dumps(self.completion(command, ""), sort_keys=True) + "\n"
        text = "x" * (FIFO_BUFFER_BYTES - len(empty))
        self.assertQuietSuccess(self.stop(text))
        line = COMPLETION_PREFIX + json.dumps(self.completion(command, text), sort_keys=True)
        self.assertEqual(len(line) + 1, FIFO_BUFFER_BYTES)
        self.assertEqual(box.fifo_lines(), [line])

    @known_difference(
        "The Python hook writes without waiting for the reader, so a completion line longer than the "
        "8192-byte FIFO buffer is cut off after 8192 bytes and the turn is left half-closed."
    )
    def test_reply_longer_than_the_fifo_buffer_arrives_whole(self):
        box = self.box
        command = self.bind()
        text = "The release notes, at length. " * 1000
        with box.slow_fifo_reader() as reader:
            result = self.stop(text)
        self.assertQuietSuccess(result)
        line = COMPLETION_PREFIX + json.dumps(self.completion(command, text.strip()), sort_keys=True)
        self.assertEqual(box.fifo_lines(reader.data), [line])
        self.assertEqual(
            [(record["state"], record["delivery"]) for record in box.ledger_records()],
            [("completed_final", "sent")],
        )
        self.assertEqual(self.turn_states(), [("cmd-7", "completed_final")])

    def completion(self, command: dict, text: str) -> dict:
        completion = {
            "event": "Stop",
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "session_id": self.box.NATIVE_SESSION_ID,
            "session_key": "session-key-1",
            "intent_id": command["intent_id"],
            "within_turn_order": 1,
            "turn_id": "turn-1",
            "provider": self.provider,
            "text": text,
        }
        completion.update(self.box.ownership)
        return completion


class ClaudeFaults(FaultContract, FaultCase):
    provider = "claude"


class CodexFaults(FaultContract, FaultCase):
    provider = "codex"


class LockedInboxBudget(FaultCase):
    """One provider is enough: the wait happens before the event is read."""

    @known_difference(
        "The Python hook waits 5 seconds for a locked inbox, past the providers' 2 second hook timeout."
    )
    def test_locked_inbox_is_given_up_within_the_hook_budget(self):
        box = self.box
        box.create_inbox()
        box.claim()
        box.hold_write_lock()
        started = time.perf_counter()
        result = box.hook(box.payload("UserPromptSubmit", prompt=PROMPT))
        self.assertLess(time.perf_counter() - started, HOOK_BUDGET_SECONDS)
        self.assertQuietSuccess(result)


if __name__ == "__main__":
    unittest.main()
