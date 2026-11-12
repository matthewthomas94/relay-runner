"""RR-478: the Rust hook and the Python bridge write one intent inbox.

Each provider drives a run of turns through `relay-rs hook` (UserPromptSubmit
then Stop) while a Python writer thread updates the same SQLite database with
services/provider_turn_broker.py, the module the bridge uses, and holds
`BEGIN IMMEDIATE` write locks between its own turns. Every turn transition on
both sides must be recorded exactly once, and every hook turn must reach the
FIFO as exactly one completion.

The hook under test is `RELAY_HOOK_CMD` when set, otherwise the release build
of relay-rs (`cargo build --release` in rust/). Without either the case skips.
"""

from __future__ import annotations

import collections
import json
import os
import shlex
import sqlite3
import sys
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests" / "contract"))
sys.path.insert(0, str(REPO / "services"))

from hook_contract_support import (  # noqa: E402
    COMPLETION_PREFIX,
    HOOK_BUDGET_SECONDS,
    Sandbox,
    run_command,
)
from provider_turn_broker import ProviderTurnBroker  # noqa: E402

RUST_HOOK = REPO / "rust" / "target" / "release" / "relay-rs"
TURNS = 24
# The writer holds the write lock this long, then leaves it free for IDLE: a
# writer that never lets go starves any SQLite client, the Python hook too.
LOCK_HOLD_SECONDS = 0.02
IDLE_SECONDS = 0.04

BRIDGE_OWNER = {
    "app_session_id": "app-session-bridge",
    "recovery_generation": "generation-bridge",
    "actor_role": "foreground_pm",
    "foreground_gate_handle": "gate-bridge",
}
BRIDGE_SESSION = "9e8d7c6b-5a49-4382-9170-6f5e4d3c2b1a"


def hook_command() -> list | None:
    configured = os.environ.get("RELAY_HOOK_CMD", "").strip()
    if configured:
        return shlex.split(configured)
    if os.access(RUST_HOOK, os.X_OK):
        return [str(RUST_HOOK), "hook"]
    return None


class PythonWriter(threading.Thread):
    """Bridge-side turns plus long write transactions on the shared inbox."""

    def __init__(self, inbox: Path, provider: str):
        super().__init__(daemon=True)
        self.inbox = inbox
        self.provider = provider
        self.stop_requested = threading.Event()
        self.turns: list = []
        self.error: BaseException | None = None

    def run(self) -> None:
        broker = ProviderTurnBroker(self.inbox)
        locker = sqlite3.connect(str(self.inbox), timeout=10, isolation_level=None)
        try:
            index = 0
            while not self.stop_requested.is_set():
                index += 1
                record = dict(BRIDGE_OWNER)
                record.update({
                    "provider": self.provider,
                    "provider_session_id": "bridge-provider-session",
                    "session_id": BRIDGE_SESSION,
                    "turn_id": "bridge-turn-%d" % index,
                    "relay_command_seq": 1000 + index,
                    "relay_command_id": "bridge-cmd-%d" % index,
                    "intent_id": "bridge-intent-%d" % index,
                })
                broker.activate(record)
                locker.execute("BEGIN IMMEDIATE")
                time.sleep(LOCK_HOLD_SECONDS)
                locker.execute("COMMIT")
                broker.transition(
                    record, to_state="completed_final", event_type="provider_completed",
                    release_reason="provider_stop",
                )
                self.turns.append(record["turn_id"])
                self.stop_requested.wait(IDLE_SECONDS)
        except BaseException as error:  # surfaced by the test
            self.error = error
        finally:
            locker.close()
            broker.close()


class InboxConcurrencyCase:
    provider = "claude"

    def setUp(self):
        self.command = hook_command()
        if self.command is None:
            self.skipTest("no relay-rs release build; run cargo build --release in rust/")
        self.box = Sandbox(self, self.provider)
        self.box.open_fifo()
        self.box.create_inbox()

    def hook(self, event: str, turn: str, **fields):
        payload = self.box.payload(event, turn=turn, **fields)
        result = run_command(self.command, json.dumps(payload).encode(), self.box.env(),
                             cwd=str(self.box.workdir))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertLess(result.elapsed, HOOK_BUDGET_SECONDS, event)
        return result

    def test_hook_and_python_writer_keep_every_turn_transition_once(self):
        box = self.box
        writer = PythonWriter(box.inbox_path, self.provider)
        fifo = b""
        writer.start()
        try:
            for seq in range(1, TURNS + 1):
                turn = "turn-%d" % seq
                box.claim(seq, "prompt %d" % seq)
                self.hook("UserPromptSubmit", turn, prompt="prompt %d" % seq)
                self.hook("Stop", turn, last_assistant_message="reply %d" % seq)
                # Read as the bridge does, so the FIFO buffer never fills.
                fifo += box.fifo_bytes()
        finally:
            writer.stop_requested.set()
            writer.join(30)
        self.assertIsNone(writer.error)
        self.assertGreater(len(writer.turns), 0)

        hook_owner, bridge_owner = box.owner_id(), box.owner_id(**BRIDGE_OWNER)
        turns = box.rows("provider_turns")
        by_owner = collections.defaultdict(dict)
        for row in turns:
            by_owner[row["owner_id"]][row["native_turn_id"]] = row["state"]
        self.assertEqual(by_owner[hook_owner],
                         {"turn-%d" % seq: "completed_final" for seq in range(1, TURNS + 1)})
        # The writer may have activated one more turn when it was stopped.
        bridge_states = by_owner[bridge_owner]
        for turn in writer.turns:
            self.assertEqual(bridge_states.pop(turn), "completed_final")
        self.assertLessEqual(set(bridge_states.values()), {"active"})

        turn_ids = {row["turn_id"]: (row["owner_id"], row["native_turn_id"]) for row in turns}
        transitions = collections.Counter()
        for row in box.rows("provider_turn_transitions"):
            transitions[(turn_ids[row["turn_id"]], row["event_type"],
                         row["from_state"], row["to_state"])] += 1
        expected = collections.Counter()
        for owner, names in ((hook_owner, ["turn-%d" % s for s in range(1, TURNS + 1)]),
                             (bridge_owner, writer.turns)):
            for name in names:
                expected[((owner, name), "prompt_submitted", None, "active")] += 1
                expected[((owner, name), "provider_completed", "active", "completed_final")] += 1
        for turn in bridge_states:
            expected[((bridge_owner, turn), "prompt_submitted", None, "active")] += 1
        self.assertEqual(transitions, expected)

        completions = [json.loads(line[len(COMPLETION_PREFIX):])
                       for line in box.fifo_lines(fifo) if line.startswith(COMPLETION_PREFIX)]
        self.assertEqual(sorted(c["relay_command_seq"] for c in completions),
                         list(range(1, TURNS + 1)))


class ClaudeInboxConcurrencyTests(InboxConcurrencyCase, unittest.TestCase):
    provider = "claude"


class CodexInboxConcurrencyTests(InboxConcurrencyCase, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
