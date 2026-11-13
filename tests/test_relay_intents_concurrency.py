"""RR-489: Python and Rust writers on one intent inbox, at the same time.

Until the bridge itself is ported, the Python bridge and the Rust crate write
one database: today the Python inbox with the Rust hook's turns, after the
cut-over the Rust inbox with the Python hook as rollback. Each case runs that
pairing with four voice sessions and real lock contention:

* the voice writer enqueues every session's commands (some with two items);
* the bridge pump observes each session's claim file, acknowledges a claim
  once its provider turn exists, reconciles terminal claims and leases the
  next intent into the session's mailbox;
* one provider per session claims what its mailbox holds, opens the turn
  through the hook's broker, waits for the acknowledgement, completes the
  turn, and the bridge delivers its authoritative reply;
* a plain SQLite writer keeps taking `BEGIN IMMEDIATE` locks throughout.

Every intent must be delivered exactly once, in its session's order, and
acknowledged: no claim may be lost or left unacknowledged (the stall seen on
2026-11-13 was a claimed intent that never reached `acked`). Every turn moves
once, and every reply is delivered once.

The Rust side is the crate's test driver; without it the cases skip (see
tests/relay_intents_support.py).
"""

from __future__ import annotations

import collections
import json
import os
import random
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from relay_intents_support import driver_command, implementation

SESSIONS = ("session-a", "session-b", "session-c", "session-d")
COMMANDS = 20
GENERATION = "generation-1"
OWNER = {
    "app_session_id": "app-session-1",
    "recovery_generation": GENERATION,
    "actor_role": "foreground_pm",
    "foreground_gate_handle": "gate-1",
}
DEADLINE_SECONDS = 120
LOCK_HOLD_SECONDS = 0.01
IDLE_SECONDS = 0.02


class Stop(Exception):
    pass


@unittest.skipUnless(driver_command(), "relay-intents driver not built; run cargo test in rust/")
class MixedWritersTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="rr489-mixed-"))
        self.inbox = self.root / "inbox.sqlite3"
        self.projection = self.root / "turns_v2.json"
        self.mailboxes = {}
        for key in SESSIONS:
            folder = self.root / key
            folder.mkdir()
            self.mailboxes[key] = {
                "command": folder / "voice_cmd_ready",
                "meta": folder / "voice_cmd_ready.meta",
                "claim": folder / "voice_cmd_claimed.json",
            }
        self.stop = threading.Event()
        self.errors: list = []
        self.opened: list = []
        self.delivered = collections.defaultdict(list)
        self.expected = collections.defaultdict(list)
        rng = random.Random(489)
        self.commands = []
        for seq in range(1, COMMANDS + 1):
            session = SESSIONS[rng.randrange(len(SESSIONS))]
            items = 2 if seq % 3 == 0 else 1
            for item in range(1, items + 1):
                self.commands.append((seq, item, session))
                self.expected[session].append(f"cmd-{seq}:item:{item}")

    def tearDown(self):
        self.stop.set()
        for impl in self.opened:
            impl.close()
        shutil.rmtree(self.root, ignore_errors=True)

    # -- parts ---------------------------------------------------------------

    def open(self, name: str):
        impl = implementation(name)
        self.opened.append(impl)
        return impl

    def reader(self) -> sqlite3.Connection:
        connection = sqlite3.connect(f"file:{self.inbox}?mode=ro", uri=True, timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    def guarded(self, work):
        def run():
            try:
                work()
            except Stop:
                pass
            except BaseException as error:  # noqa: BLE001 - reported by the case
                self.errors.append(error)
                self.stop.set()
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread

    def wait(self, condition, message: str):
        deadline = time.monotonic() + DEADLINE_SECONDS
        while not self.stop.is_set():
            value = condition()
            if value:
                return value
            if time.monotonic() > deadline:
                raise AssertionError(f"timed out waiting for {message}")
            time.sleep(0.002)
        raise Stop()

    def metadata(self, seq: int, item: int, session: str) -> dict:
        intent_id = f"cmd-{seq}:item:{item}"
        return {
            "relay_command_seq": seq,
            "relay_command_id": f"cmd-{seq}",
            "intent_id": intent_id,
            "within_turn_order": item,
            "source_text": f"request {seq}.{item}",
            "voice_target_session_key": session,
            "recovery_generation": GENERATION,
            "work_disposition": {"route": "continue_current", "intent_id": intent_id},
        }

    def voice_writer(self, inbox):
        rng = random.Random(1)
        for seq, item, session in self.commands:
            inbox.call("inbox.enqueue", prompt=f"prompt {seq}.{item}",
                       metadata=self.metadata(seq, item, session), route="continue_current")
            if item == 1 or rng.random() < 0.5:
                time.sleep(rng.uniform(0, 0.01))

    def pump(self, inbox):
        routes = {key: [str(box["command"]), str(box["meta"])] for key, box in self.mailboxes.items()}
        turns = self.reader()
        try:
            while not self.stop.is_set():
                for box in self.mailboxes.values():
                    try:
                        claimed = json.loads(box["claim"].read_text())
                    except (OSError, json.JSONDecodeError):
                        continue
                    seen = turns.execute(
                        "SELECT 1 FROM provider_turns WHERE intent_id=? LIMIT 1",
                        (claimed["intent_id"],),
                    ).fetchone() is not None
                    inbox.call("inbox.observe_claim", claimed=claimed, provider_turn_seen=seen)
                inbox.call("inbox.reconcile_terminal_claims")
                inbox.call(
                    "inbox.materialize_next",
                    command_path=str(self.root / "unrouted_ready"),
                    metadata_path=str(self.root / "unrouted_ready.meta"),
                    transport="contract-ready-file",
                    routes=routes,
                )
                time.sleep(0.002)
        finally:
            turns.close()

    def provider(self, session: str, hook, bridge):
        box = self.mailboxes[session]
        states = self.reader()
        try:
            for _ in self.expected[session]:
                self.wait(lambda: box["command"].exists() and box["meta"].exists(),
                          f"a delivery to {session}")
                metadata = json.loads(box["meta"].read_text())
                box["command"].unlink()
                box["meta"].unlink()
                temporary = box["claim"].with_suffix(".tmp")
                temporary.write_text(json.dumps(metadata))
                os.replace(temporary, box["claim"])
                intent_id = metadata["intent_id"]
                self.delivered[session].append(intent_id)
                record = {
                    **OWNER,
                    "provider": "claude",
                    "provider_session_id": f"native-{session}",
                    "session_id": f"native-{session}",
                    "turn_id": f"turn-{intent_id}",
                    "intent_id": intent_id,
                    "relay_command_seq": metadata["relay_command_seq"],
                    "relay_command_id": metadata["relay_command_id"],
                    "origin": "relay",
                }
                hook.call("broker.activate", record=record)

                def acknowledged():
                    row = states.execute("SELECT state FROM intents WHERE intent_id=?", (intent_id,)).fetchone()
                    return row is not None and row["state"] == "acked"

                self.wait(acknowledged, f"the acknowledgement of {intent_id}")
                if not hook.call("broker.transition", record=record, to_state="completed_final",
                                 event_type="provider_stop", release_reason="provider_stop"):
                    raise AssertionError(f"turn of {intent_id} did not complete once")
                reservation = bridge.call("broker.reserve_effect", command={**OWNER, **metadata})
                if not reservation["accepted"]:
                    raise AssertionError(f"reply of {intent_id} refused: {reservation['reason']}")
                authorized = bridge.call("broker.authorize_effect_delivery", effect_id=reservation["effect_id"])
                bridge.call("broker.finish_effect", effect_id=reservation["effect_id"], delivered=authorized)
        finally:
            states.close()

    def contention(self):
        locker = sqlite3.connect(str(self.inbox), timeout=10, isolation_level=None)
        try:
            while not self.stop.is_set():
                locker.execute("BEGIN IMMEDIATE")
                time.sleep(LOCK_HOLD_SECONDS)
                locker.execute("COMMIT")
                time.sleep(IDLE_SECONDS)
        finally:
            locker.close()

    # -- the run -------------------------------------------------------------

    def run_mixed(self, *, bridge_side: str, writer_side: str):
        pump_inbox = self.open(bridge_side)
        pump_inbox.call("inbox.open", path=str(self.inbox), projection_path=str(self.projection))
        writer_inbox = self.open(writer_side)
        writer_inbox.call("inbox.open", path=str(self.inbox), projection_path=str(self.projection))
        brokers = {}
        for session in SESSIONS:
            hook = self.open(writer_side)
            hook.call("broker.open", path=str(self.inbox), projection_path=str(self.projection))
            bridge = self.open(bridge_side)
            bridge.call("broker.open", path=str(self.inbox), projection_path=str(self.projection))
            brokers[session] = (hook, bridge)

        background = [self.guarded(self.contention), self.guarded(lambda: self.pump(pump_inbox))]
        workers = [self.guarded(lambda: self.voice_writer(writer_inbox))]
        workers += [
            self.guarded(lambda session=session: self.provider(session, *brokers[session]))
            for session in SESSIONS
        ]
        for worker in workers:
            worker.join(DEADLINE_SECONDS + 30)
        self.stop.set()
        for thread in background:
            thread.join(30)
        if self.errors:
            raise self.errors[0]
        self.check_outcome()

    def check_outcome(self):
        self.assertEqual(dict(self.delivered), dict(self.expected), "each intent once, in session order")
        reader = self.reader()
        try:
            intents = [dict(row) for row in reader.execute("SELECT * FROM intents ORDER BY ordinal")]
            turns = [dict(row) for row in reader.execute("SELECT * FROM provider_turns")]
            transitions = [dict(row) for row in reader.execute("SELECT * FROM provider_turn_transitions")]
            effects = [dict(row) for row in reader.execute("SELECT * FROM provider_turn_effects")]
        finally:
            reader.close()
        expected_ids = sorted(intent for ids in self.expected.values() for intent in ids)
        self.assertEqual(sorted(row["intent_id"] for row in intents), expected_ids)
        stuck = [(row["intent_id"], row["state"]) for row in intents if row["state"] != "acked"]
        self.assertEqual(stuck, [], "no claim lost or left unacknowledged")
        self.assertEqual({row["lease_attempts"] for row in intents}, {1}, "each intent leased once")

        self.assertEqual(sorted(turn["intent_id"] for turn in turns), expected_ids)
        self.assertEqual({turn["state"] for turn in turns}, {"completed_final"})
        by_turn = collections.defaultdict(collections.Counter)
        for row in transitions:
            by_turn[row["turn_id"]][row["event_type"]] += 1
        for turn in turns:
            events = by_turn[turn["turn_id"]]
            self.assertEqual(
                (events["prompt_submitted"], events["intent_acknowledged"], events["provider_stop"]),
                (1, 1, 1),
                (turn["intent_id"], dict(events)),
            )
            # The Python inbox writes the mailbox before it takes the write
            # lock, so a fast provider can open its turn before the delivery
            # and claim events are recorded on it; the Rust inbox holds the
            # lock across the write. Either is recorded at most once.
            self.assertLessEqual(events["intent_delivered"], 1, turn["intent_id"])
            self.assertLessEqual(events["intent_claimed"], 1, turn["intent_id"])
            self.assertEqual(set(events) - {"prompt_submitted", "intent_delivered", "intent_claimed",
                                            "intent_acknowledged", "provider_stop"}, set())
        self.assertEqual(
            sorted((effect["intent_id"], effect["state"]) for effect in effects),
            [(intent_id, "delivered") for intent_id in expected_ids],
        )
        projection = json.loads(self.projection.read_text())
        self.assertEqual(projection["schema_version"], 2)
        self.assertEqual(len(projection["records"]), len(expected_ids))

    def test_the_python_bridge_with_rust_writers(self):
        """Today's pairing: the Python inbox and bridge-side broker, with the
        Rust crate enqueueing and recording the provider turns."""
        self.run_mixed(bridge_side="python", writer_side="rust")

    def test_the_rust_bridge_with_python_writers(self):
        """After the cut-over: the Rust inbox and bridge-side broker, with the
        Python modules enqueueing and recording the provider turns."""
        self.run_mixed(bridge_side="rust", writer_side="python")


if __name__ == "__main__":
    unittest.main()
