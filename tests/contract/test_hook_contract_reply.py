"""Reply helper contract: `$RELAY_REPLY_HELPER` reads a reply on stdin and
publishes it for the claimed voice command.

The helper writes at most one `__ORCHESTRATOR_REPLY__:` line to the FIFO. It
always exits 0 and prints nothing on stdout; a reply it may not publish is
dropped.
"""

from __future__ import annotations

import json
import os
import unittest

from hook_contract_support import (
    FIFO_BUFFER_BYTES,
    ORCHESTRATOR_REPLY_PREFIX,
    REPLY_IS_REFERENCE,
    ContractCase,
    known_difference,
)

REPLY = "The release notes are ready."
PRESERVE = {
    "route": "continue_current",
    "authorization_effect": "preserve",
    "cancellation_scope": "none",
}


class ReplyCase(ContractCase):
    def publish(self, text=REPLY, *, env=None):
        result = self.box.reply(text, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        if isinstance(text, str) and text.strip():
            self.assertNotIn(text.strip(), result.stderr)
        return result

    def expected(self, command: dict, text: str = REPLY, **fields) -> dict:
        reply = {
            "relay_command_id": command["relay_command_id"],
            "relay_command_seq": command["relay_command_seq"],
            "intent_id": command["intent_id"],
            "text": text,
            "session_key": "session-key-1",
            "provider_session_id": self.box.PROVIDER_SESSION_ID,
        }
        reply.update(self.box.ownership)
        reply.update(fields)
        return reply

    def line(self, reply: dict) -> str:
        return ORCHESTRATOR_REPLY_PREFIX + json.dumps(reply, sort_keys=True)

    def assertPublished(self, reply: dict) -> None:
        self.assertEqual(self.box.fifo_lines(), [self.line(reply)])

    def assertDropped(self) -> None:
        self.assertEqual(self.box.fifo_bytes(), b"")


class ReplyContract:
    """Cases every provider must satisfy."""

    # -- acceptance ------------------------------------------------------------

    def test_reply_for_the_current_command_is_published_as_one_sorted_json_line(self):
        box = self.box
        box.claim()
        before = box.tree()
        self.publish()
        self.assertEqual(
            box.fifo_bytes().decode("utf-8"),
            '__ORCHESTRATOR_REPLY__:{"actor_role": "foreground_pm", "app_session_id": "app-session-1", '
            '"foreground_gate_handle": "gate-1", "intent_id": "intent-7", '
            '"provider_session_id": "0f3a1c52-7d4e-4b8a-9c11-5e6f7a8b9c0d", '
            '"recovery_generation": "generation-1", "relay_command_id": "cmd-7", "relay_command_seq": 7, '
            '"session_key": "session-key-1", "text": "The release notes are ready."}\n',
        )
        self.assertEqual(box.tree(), before)

    def test_reply_text_is_trimmed_and_escaped_onto_one_line(self):
        command = self.box.claim()
        self.publish('\n  Done — déjà vu ✅\n"second" line\\\ttab  \n\n')
        text = 'Done — déjà vu ✅\n"second" line\\\ttab'
        data = self.box.fifo_bytes()
        self.assertEqual(data.count(b"\n"), 1)
        self.assertEqual(data.decode("ascii"), self.line(self.expected(command, text)) + "\n")
        self.assertIn(b'"Done \\u2014 d\\u00e9j\\u00e0 vu \\u2705\\n\\"second\\" line\\\\\\ttab"', data)

    def test_reply_names_the_command_as_claimed(self):
        cases = (
            ("sequence given as text", {"relay_command_seq": "7"}, {}),
            ("command id is trimmed", {"relay_command_id": " cmd-7 "}, {}),
            ("structured intent id", {"intent_id": {"turn": 3}}, {"intent_id": {"turn": 3}}),
            ("extra claim fields are not copied", {"target": "relay-runner", "agent_prompt": "x"}, {}),
        )
        for name, claimed, expected in cases:
            with self.subTest(name):
                self.setUp()
                command = self.box.command()
                self.box.write_state(command)
                self.box.write_claim(dict(command, **claimed))
                self.publish()
                self.assertPublished(self.expected(command, **expected))

    def test_claim_without_an_intent_omits_the_intent(self):
        box = self.box
        command = box.command()
        del command["intent_id"]
        box.write_claim(command)
        box.write_state(command)
        self.publish()
        expected = self.expected(dict(command, intent_id=None))
        del expected["intent_id"]
        self.assertPublished(expected)

    def test_manual_foreground_actor_may_reply(self):
        command = self.box.claim()
        self.publish(env=self.box.env(RELAY_ACTOR_ROLE="foreground_manual"))
        self.assertPublished(self.expected(command, actor_role="foreground_manual"))

    def test_session_key_falls_back_to_the_spool_directory_name(self):
        box = self.box
        command = box.claim()
        self.publish(env=box.env(RELAY_SESSION_KEY=None, RELAY_SESSION_SPOOL_DIR=str(box.spool) + "/"))
        self.assertPublished(self.expected(command))

    def test_origin_fields_are_omitted_when_the_session_has_none(self):
        box = self.box
        command = box.claim()
        env = box.env(RELAY_SESSION_KEY=None, RELAY_SESSION_SPOOL_DIR=None, RELAY_PROVIDER_SESSION_ID=None)
        self.publish(env=env)
        expected = self.expected(command)
        del expected["session_key"], expected["provider_session_id"]
        self.assertPublished(expected)

    def test_reply_is_published_when_a_newer_command_preserves_current_work(self):
        box = self.box
        command = box.command()
        box.write_claim(command)
        box.write_state(dict(box.command(8, "what is the status"), work_disposition=PRESERVE))
        self.publish()
        self.assertPublished(self.expected(command))

    def test_reply_is_judged_against_its_own_session(self):
        box = self.box
        command = box.command()
        box.write_claim(command)
        elsewhere = box.command(9, "a request in another session")
        box.write_state(dict(elsewhere, session_commands={"session-key-1": command, "session-key-2": elsewhere}))
        self.publish()
        self.assertPublished(self.expected(command))

    def test_reply_that_fills_the_fifo_buffer_arrives_whole(self):
        command = self.box.claim()
        empty = self.line(self.expected(command, "")) + "\n"
        text = "x" * (FIFO_BUFFER_BYTES - len(empty))
        self.publish(text)
        self.assertPublished(self.expected(command, text))

    @known_difference(
        "The Python helper writes without waiting for the reader, so a reply line longer than the "
        "8192-byte FIFO buffer is cut off after 8192 bytes and the helper exits 1.",
        reference=REPLY_IS_REFERENCE,
    )
    def test_reply_longer_than_the_fifo_buffer_arrives_whole(self):
        command = self.box.claim()
        text = "The release notes, at length. " * 1000
        with self.box.slow_fifo_reader() as reader:
            self.publish(text)
        self.assertEqual(self.box.fifo_lines(reader.data), [self.line(self.expected(command, text.strip()))])

    # -- rejection -------------------------------------------------------------

    def test_reply_for_a_superseded_command_is_dropped(self):
        box = self.box
        box.write_claim(box.command(7))
        newer = box.command(8, "a newer request")
        dispositions = (
            None,
            dict(PRESERVE, route="replace_current"),
            dict(PRESERVE, authorization_effect="revoke"),
            dict(PRESERVE, cancellation_scope="current_item"),
            "continue_current",
        )
        for disposition in dispositions:
            with self.subTest(disposition=disposition):
                box.write_state(dict(newer, work_disposition=disposition))
                result = self.publish()
                self.assertNotEqual(result.stderr, "")
                self.assertDropped()

    def test_reply_for_a_command_superseded_in_its_own_session_is_dropped(self):
        box = self.box
        command = box.command()
        box.write_claim(command)
        box.write_state(dict(command, session_commands={"session-key-1": box.command(8, "a newer request")}))
        self.publish()
        self.assertDropped()

    def test_reply_for_a_cancelled_intent_is_dropped(self):
        box = self.box
        command = box.command()
        box.write_claim(command)
        box.write_state(dict(command, cancelled_intent_ids=["intent-3", "intent-7"]))
        self.publish()
        self.assertDropped()

    def test_reply_is_dropped_unless_the_claim_is_the_known_current_command(self):
        box = self.box
        command = box.command()
        cases = (
            ("no state file", command, None),
            ("state is not JSON", command, "{"),
            ("state has no command", command, {}),
            ("state is an older command", command, box.command(6)),
            ("same sequence, another command", command, dict(command, relay_command_id="cmd-other")),
            ("no claim file", None, command),
            ("claim is not JSON", "{", command),
            ("claim is not an object", [command], command),
            ("claim has no command id", dict(command, relay_command_id=""), command),
            ("claim has no sequence", dict(command, relay_command_seq=None), command),
        )
        for name, claim, state in cases:
            with self.subTest(name):
                self.setUp()
                for path, value in ((self.box.claim_path, claim), (self.box.state_path, state)):
                    if value is not None:
                        path.write_text(value if isinstance(value, str) else json.dumps(value))
                self.publish()
                self.assertDropped()

    def test_reply_without_foreground_ownership_is_dropped(self):
        box = self.box
        box.claim()
        cases = (
            {"RELAY_ACTOR_ROLE": "voice_bridge"},
            {"RELAY_ACTOR_ROLE": None},
            {"RELAY_APP_SESSION_ID": None},
            {"RELAY_RECOVERY_GENERATION": " "},
            {"RELAY_FOREGROUND_GATE_HANDLE": ""},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.publish(env=box.env(**overrides))
                self.assertDropped()

    def test_empty_reply_is_dropped(self):
        self.box.claim()
        for text in ("", "  \n\t\n"):
            with self.subTest(text=text):
                self.publish(text)
                self.assertDropped()

    def test_reply_without_a_fifo_reader_is_dropped(self):
        box = self.box
        box.claim()
        box.close_fifo_reader()
        self.publish()
        os.unlink(str(box.fifo_path))
        self.publish()
        self.assertFalse(box.fifo_path.exists())

    def test_helper_leaves_the_turn_state_alone(self):
        box = self.box
        box.claim()
        self.assertQuietSuccess(box.hook(box.payload("UserPromptSubmit", prompt="ship the release notes")))
        box.fifo_bytes()
        before = box.ledger_records(), box.rows("provider_turns"), box.rows("provider_turn_transitions")
        self.publish()
        self.assertEqual(len(box.fifo_lines()), 1)
        after = box.ledger_records(), box.rows("provider_turns"), box.rows("provider_turn_transitions")
        self.assertEqual(after, before)
        self.assertEqual(box.rows("provider_turn_effects"), [])


class ClaudeReply(ReplyContract, ReplyCase):
    provider = "claude"


class CodexReply(ReplyContract, ReplyCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
