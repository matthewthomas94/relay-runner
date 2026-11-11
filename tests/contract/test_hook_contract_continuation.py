"""`--context-continuation` contract, and the continuation prompt it authorizes.

The app asks whether a request in one context may continue in another:
`capture` names the current turn, `check` says whether that turn may still be
continued, and `ack` says whether the destination accepted it. The command
only reads the inbox. The intents and turns here are written with plain SQL,
as the bridge writes them.
"""

from __future__ import annotations

import json
import time
import unittest

from hook_contract_support import ContractCase, sha256_hex

PROMPT = "continue the release notes here"
DESTINATION_SESSION = "c0ffee00-1111-4222-8333-444455556666"
DESTINATION_NATIVE = "deadbeef-1111-4222-8333-444455556666"
OWNER_FIELDS = (
    "provider", "provider_session_id", "native_session_id",
    "app_session_id", "recovery_generation", "foreground_gate_handle",
)


class ContinuationCase(ContractCase):
    def setUp(self):
        super().setUp()
        self.box.create_inbox()

    def ask(self, request, *, env=None) -> dict:
        """One request in, one JSON object on one line out, always exit 0."""
        before = self.box.rows("provider_turns"), self.box.rows("provider_turn_transitions")
        result = self.box.hook(request, "--context-continuation", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = result.stdout.decode("utf-8")
        self.assertTrue(text.endswith("\n"), text)
        self.assertEqual(text.count("\n"), 1, text)
        reply = json.loads(text)
        self.assertIsInstance(reply, dict)
        self.assertEqual((self.box.rows("provider_turns"), self.box.rows("provider_turn_transitions")), before)
        self.assertEqual(self.box.fifo_lines(), [])
        return reply

    def assertBlocked(self, reply: dict) -> None:
        self.assertEqual(reply["status"], "blocked")
        self.assertEqual(sorted(set(reply) - {"message"}), ["status"])

    def owner(self, **fields) -> dict:
        box = self.box
        owner = {
            "provider": self.provider,
            "provider_session_id": box.PROVIDER_SESSION_ID,
            "native_session_id": box.NATIVE_SESSION_ID,
            "app_session_id": box.APP_SESSION_ID,
            "recovery_generation": box.RECOVERY_GENERATION,
            "foreground_gate_handle": box.GATE_HANDLE,
        }
        owner.update(fields)
        return owner

    def seed_intent(self, seq: int = 7, state: str = "acked") -> None:
        self.box.insert(
            "intents",
            intent_id="intent-%d" % seq, command_seq=seq, command_id="cmd-%d" % seq,
            prompt="", metadata_json="{}", route="queue_project_work", state=state,
            delivery_id="delivery-%d" % seq, created_at=time.time(),
        )

    def relay_source(self, turn_id: str, **fields) -> dict:
        """What `capture` returns for the relay turn of command 7."""
        source = self.owner(
            native_turn_id="turn-1", owner_id=self.box.owner_id(), origin="relay",
            intent_id="intent-7", command_seq="7", command_id="cmd-7", canonical_turn_id=turn_id,
        )
        source.update(fields)
        return source

    def manual_source(self, turn_id: str) -> dict:
        return self.owner(
            native_turn_id="turn-1", owner_id=self.box.owner_id(), origin="manual",
            manual_submission_id="submission-0", canonical_turn_id=turn_id,
        )

    def seed_manual_turn(self, **columns) -> str:
        return self.box.seed_turn(origin="manual", seq=None, manual_submission_id="submission-0", **columns)

    def capture(self, **owner) -> dict:
        return self.ask({"operation": "capture", "source": self.owner(**owner)})

    def check(self, source: dict) -> dict:
        return self.ask({"operation": "check", "source": source})


class ContinuationContract:
    """Cases every provider must satisfy."""

    # -- capture -------------------------------------------------------------

    def test_capture_names_the_active_relay_turn(self):
        self.seed_intent()
        turn_id = self.box.seed_turn()
        self.assertEqual(self.capture(), {"status": "active", "source": self.relay_source(turn_id)})

    def test_capture_names_the_active_manual_turn(self):
        turn_id = self.seed_manual_turn()
        self.assertEqual(self.capture(), {"status": "active", "source": self.manual_source(turn_id)})

    def test_capture_names_a_turn_without_a_native_turn_id(self):
        turn_id = self.seed_manual_turn(turn=None, native_turn_id=None, local_turn_seq=3)
        expected = self.manual_source(turn_id)
        del expected["native_turn_id"]
        expected["local_turn_seq"] = "3"
        self.assertEqual(self.capture(), {"status": "active", "source": expected})

    def test_capture_names_a_turn_the_hook_bound(self):
        box = self.box
        self.seed_intent()
        box.claim()
        self.assertQuietSuccess(box.hook(box.payload("UserPromptSubmit", prompt="ship the release notes")))
        box.fifo_bytes()
        self.assertEqual(self.capture(), {"status": "active", "source": self.relay_source(box.turn_id())})

    def test_capture_uses_the_newest_turn_of_the_session(self):
        now = time.time()
        self.seed_manual_turn(state="completed_manual", created_at=now - 60)
        newest = self.seed_manual_turn(turn="turn-2", created_at=now)
        self.assertEqual(self.capture()["source"]["canonical_turn_id"], newest)

    def test_capture_is_blocked_without_an_active_turn(self):
        cases = (
            ("no turn", None),
            ("turn finished", {"state": "completed_manual"}),
            ("turn of another native session", {"session": DESTINATION_NATIVE}),
            ("turn of another foreground gate", {"foreground_gate_handle": "gate-2"}),
            ("turn of a manual foreground actor", {"actor_role": "foreground_manual"}),
        )
        for name, columns in cases:
            with self.subTest(name):
                self.setUp()
                if columns is not None:
                    self.seed_manual_turn(**columns)
                self.assertBlocked(self.capture())

    def test_capture_is_blocked_when_a_newer_turn_finished(self):
        now = time.time()
        self.seed_manual_turn(created_at=now - 60)
        self.seed_manual_turn(turn="turn-2", state="completed_manual", created_at=now)
        self.assertBlocked(self.capture())

    def test_capture_is_blocked_until_the_voice_intent_is_acknowledged(self):
        for state in (None, "claimed", "cancelled"):
            with self.subTest(state=state):
                self.setUp()
                if state:
                    self.seed_intent(state=state)
                self.box.seed_turn()
                self.assertBlocked(self.capture())

    def test_capture_is_blocked_for_an_incomplete_source_identity(self):
        self.seed_manual_turn()
        for field in OWNER_FIELDS:
            with self.subTest(field):
                self.assertBlocked(self.capture(**{field: ""}))
                source = self.owner()
                del source[field]
                self.assertBlocked(self.ask({"operation": "capture", "source": source}))

    # -- check ---------------------------------------------------------------

    def test_check_reports_an_active_source_as_active(self):
        source = self.manual_source(self.seed_manual_turn())
        self.assertEqual(self.check(source), {"status": "active", "source": source})

    def test_check_reports_a_finished_source_as_ready(self):
        for state in ("completed_final", "completed_manual"):
            with self.subTest(state):
                self.setUp()
                self.seed_intent()
                source = self.relay_source(self.box.seed_turn(state=state))
                self.assertEqual(self.check(source), {"status": "ready", "source": source})

    def test_check_is_the_default_operation(self):
        source = self.manual_source(self.seed_manual_turn(state="completed_manual"))
        self.assertEqual(self.ask({"source": source}), {"status": "ready", "source": source})

    def test_check_is_blocked_when_the_source_did_not_finish_successfully(self):
        for state in ("stale", "orphaned", "cancelled", "terminated", "failed", "failed_manual", "empty"):
            with self.subTest(state):
                self.setUp()
                self.seed_intent()
                self.assertBlocked(self.check(self.relay_source(self.box.seed_turn(state=state))))

    def test_check_is_blocked_when_the_source_turn_is_not_canonical(self):
        turn_id = self.seed_manual_turn(state="completed_manual")
        source = self.manual_source(turn_id)
        self.assertBlocked(self.check(dict(source, canonical_turn_id="turn:unknown")))
        self.assertBlocked(self.check({k: v for k, v in source.items() if k != "canonical_turn_id"}))
        self.assertBlocked(self.check(dict(source, native_session_id=DESTINATION_NATIVE)))

    def test_check_is_blocked_when_the_voice_intent_is_cancelled(self):
        self.seed_intent(state="cancelled")
        self.assertBlocked(self.check(self.relay_source(self.box.seed_turn(state="completed_final"))))

    def test_check_is_blocked_when_the_intent_does_not_match_the_command(self):
        self.seed_intent()
        source = self.relay_source(self.box.seed_turn(state="completed_final"))
        self.assertBlocked(self.check(dict(source, command_id="cmd-8")))
        self.assertBlocked(self.check(dict(source, command_seq="8")))

    def test_newer_manual_turn_supersedes_a_source(self):
        now = time.time()
        self.seed_intent()
        source = self.relay_source(self.box.seed_turn(state="completed_final", created_at=now - 60))
        self.seed_manual_turn(turn="turn-2", state="completed_manual", created_at=now)
        self.assertBlocked(self.check(source))

    def test_newer_relay_turn_supersedes_only_a_manual_source(self):
        now = time.time()
        self.seed_intent()
        self.seed_intent(8)
        manual = self.manual_source(self.seed_manual_turn(turn="turn-0", state="completed_manual", created_at=now - 90))
        relay = self.relay_source(self.box.seed_turn(state="completed_final", created_at=now - 60))
        self.box.seed_turn(turn="turn-2", seq=8, state="completed_final", created_at=now)
        self.assertBlocked(self.check(dict(manual, native_turn_id="turn-0")))
        self.assertEqual(self.check(relay), {"status": "ready", "source": relay})

    def test_turn_of_another_provider_session_does_not_supersede_a_source(self):
        now = time.time()
        source = self.manual_source(self.seed_manual_turn(state="completed_manual", created_at=now - 60))
        self.seed_manual_turn(turn="turn-2", provider_session_id=DESTINATION_SESSION, created_at=now)
        self.assertEqual(self.check(source)["status"], "ready")

    # -- ack -----------------------------------------------------------------

    def destination(self, **fields) -> dict:
        identity = {"provider_session_id": DESTINATION_SESSION, "native_session_id": DESTINATION_NATIVE}
        identity.update(fields)
        return self.owner(**identity)

    def ack(self, source: dict, submission_id="submission-9", **request) -> dict:
        request = dict({"operation": "ack", "source": source, "destination": self.destination(),
                        "submission_id": submission_id}, **request)
        return self.ask(request)

    def test_ack_waits_until_the_destination_accepts_the_submission(self):
        source = self.manual_source(self.seed_manual_turn(state="completed_manual"))
        self.assertEqual(self.ack(source), {"status": "waiting"})
        self.box.seed_turn(
            origin="manual", seq=None, session=DESTINATION_NATIVE, provider_session_id=DESTINATION_SESSION,
            turn="turn-9", manual_submission_id="submission-9",
        )
        self.assertEqual(self.ack(source), {"status": "consumed"})
        self.assertEqual(self.ack(source, submission_id="submission-10"), {"status": "waiting"})

    def test_ack_is_blocked_without_a_destination_identity(self):
        source = self.manual_source(self.seed_manual_turn(state="completed_manual"))
        self.assertBlocked(self.ack(source, destination=None))
        for field in OWNER_FIELDS:
            with self.subTest(field):
                self.assertBlocked(self.ack(source, destination=self.destination(**{field: ""})))

    def test_ack_is_blocked_when_the_source_was_superseded(self):
        self.seed_intent()
        source = self.relay_source(self.box.seed_turn(state="stale"))
        self.assertBlocked(self.ack(source))

    # -- malformed requests and an unavailable inbox ------------------------------

    def test_malformed_request_is_blocked(self):
        self.seed_manual_turn()
        requests = (
            b"", b"{", b"not json", b"\xff\xfe", b"[]", b"null", b'"capture"', b"7",
            b"{}", b'{"operation":"capture"}', b'{"operation":"capture","source":"session"}',
            b'{"operation":"capture","source":[1]}', b'{"operation":"capture","source":{}}',
        )
        for request in requests:
            with self.subTest(request=request):
                self.assertBlocked(self.ask(request))

    def test_unavailable_inbox_is_blocked(self):
        box = self.box
        source = self.manual_source(self.seed_manual_turn())
        missing = box.root / "missing.sqlite3"
        self.assertBlocked(self.ask({"operation": "check", "source": source}, env=box.env(VOICE_INTENT_INBOX=str(missing))))
        self.assertFalse(missing.exists())
        empty = box.root / "empty.sqlite3"
        empty.write_bytes(b"")
        self.assertBlocked(self.ask({"operation": "check", "source": source}, env=box.env(VOICE_INTENT_INBOX=str(empty))))
        self.assertEqual(empty.read_bytes(), b"")
        garbage = box.root / "garbage.sqlite3"
        garbage.write_bytes(b"this is not a database" * 100)
        self.assertBlocked(self.ask({"operation": "check", "source": source}, env=box.env(VOICE_INTENT_INBOX=str(garbage))))

    def test_inbox_is_read_while_a_writer_holds_it(self):
        source = self.manual_source(self.seed_manual_turn())
        self.box.hold_write_lock()
        self.assertEqual(self.check(source), {"status": "active", "source": source})

    def test_continuation_does_not_need_foreground_ownership(self):
        source = self.manual_source(self.seed_manual_turn())
        env = self.box.env(RELAY_ACTOR_ROLE=None, RELAY_APP_SESSION_ID=None, RELAY_RUNNER_PROVIDER=None)
        self.assertEqual(self.ask({"operation": "check", "source": source}, env=env)["status"], "active")

    # -- the continuation prompt in the destination session ----------------------

    def destination_env(self) -> dict:
        return self.box.env(RELAY_PROVIDER_SESSION_ID=DESTINATION_SESSION)

    def submit_continuation(self, source: dict, *, prompt=PROMPT, **evidence):
        box = self.box
        box.write_manual_evidence(
            provider_session_id=DESTINATION_SESSION, submission_id="submission-9",
            continuation_source=source, prompt_sha256=sha256_hex(PROMPT), **evidence
        )
        payload = box.payload("UserPromptSubmit", session=DESTINATION_NATIVE, turn="turn-9", prompt=prompt)
        result = box.hook(payload, env=self.destination_env())
        self.assertQuietSuccess(result)
        self.assertNotIn(prompt, result.stderr)
        return result

    def destination_turns(self) -> list:
        return [row for row in self.box.rows("provider_turns") if row["native_session_id"] == DESTINATION_NATIVE]

    def test_continuation_prompt_opens_a_manual_turn_for_the_parent_intent(self):
        box = self.box
        self.seed_intent()
        source = self.relay_source(box.seed_turn(state="completed_final", created_at=time.time() - 60))
        self.assertEqual(self.ack(source), {"status": "waiting"})

        self.submit_continuation(source)
        self.assertEqual(box.fifo_lines(), [])
        (row,) = self.destination_turns()
        self.assertEqual(
            (row["origin"], row["state"], row["intent_id"], row["command_seq"], row["command_id"]),
            ("manual", "active", "intent-7", 7, "cmd-7"),
        )
        self.assertEqual(row["manual_submission_id"], "submission-9")
        (record,) = box.ledger_records()
        self.assertEqual(
            (record["origin"], record["intent_id"], record["relay_command_seq"], record["relay_command_id"]),
            ("manual", "intent-7", 7, "cmd-7"),
        )
        self.assertEqual(box.read_json(box.manual_path)["state"], "consumed")
        self.assertEqual(self.ack(source), {"status": "consumed"})

        stop = box.payload("Stop", session=DESTINATION_NATIVE, turn="turn-9", last_assistant_message="done")
        self.assertQuietSuccess(box.hook(stop, env=self.destination_env()))
        self.assertEqual(box.fifo_lines(), [])
        self.assertEqual([row["state"] for row in self.destination_turns()], ["completed_manual"])

    def test_continuation_of_a_manual_request_opens_a_plain_manual_turn(self):
        source = self.manual_source(self.seed_manual_turn(state="completed_manual", created_at=time.time() - 60))
        self.submit_continuation(source)
        (row,) = self.destination_turns()
        self.assertEqual((row["origin"], row["state"], row["intent_id"], row["command_id"]),
                         ("manual", "active", None, None))

    def test_continuation_prompt_is_refused_when_it_may_not_continue(self):
        cases = (
            ("another prompt", "completed_final", "acked", {"prompt": "something else"}),
            ("parent still running", "active", "acked", {}),
            ("parent dropped as stale", "stale", "acked", {}),
            ("parent intent cancelled", "completed_final", "cancelled", {}),
        )
        for name, turn_state, intent_state, fields in cases:
            with self.subTest(name):
                self.setUp()
                box = self.box
                self.seed_intent(state=intent_state)
                source = self.relay_source(box.seed_turn(state=turn_state, created_at=time.time() - 60))
                self.submit_continuation(source, **fields)
                self.assertEqual(self.destination_turns(), [])
                self.assertEqual(box.ledger_records(), [])
                self.assertEqual(box.read_json(box.manual_path)["state"], "pending")
                self.assertEqual(box.fifo_lines(), [])


class ClaudeContinuation(ContinuationContract, ContinuationCase):
    provider = "claude"


class CodexContinuation(ContinuationContract, ContinuationCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
