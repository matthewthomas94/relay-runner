"""RR-489: the relay-intents crate against the Python intent inbox, turn broker
and intent model.

``IntentsContract`` holds the voice-bridge contract cases for the inbox and
the turn ledger (docs/specs/voice-bridge-contract.md, "Commands, the inbox and
the claim lifecycle", "Restart" and the broker gaps it names), written against
the library calls the bridge makes. Each case runs once per implementation:
``PythonIntentsContract`` and ``RustIntentsContract``. ``ParityTest`` then runs
every case on both and requires the same results call by call, the same
database rows, schema and files, and the same intent-model answers over a
corpus of voice turns.

Rust cases skip when the crate's test driver is not built (``cargo test`` in
rust/ builds it); see tests/relay_intents_support.py.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
import tempfile
import unittest
from pathlib import Path

from relay_intents_support import (
    Refused,
    database_dump,
    driver_command,
    implementation,
    normalized,
)

SESSION = "session-a"
OTHER_SESSION = "session-b"
GENERATION = "generation-1"
OWNER = {
    "app_session_id": "app-session-1",
    "recovery_generation": GENERATION,
    "actor_role": "foreground_pm",
    "foreground_gate_handle": "gate-1",
}


class Mailbox:
    """One session's spool: the ready prompt, its metadata and the claim."""

    def __init__(self, root: Path):
        root.mkdir(parents=True, exist_ok=True)
        self.command = root / "voice_cmd_ready"
        self.meta = root / "voice_cmd_ready.meta"
        self.claim_file = root / "voice_cmd_claimed.json"

    def pending(self):
        try:
            return self.command.read_text(), json.loads(self.meta.read_text())
        except OSError:
            return None

    def claim(self) -> dict:
        """Take the waiting command as the app's terminal delivery does."""
        _, metadata = self.pending()
        self.command.unlink()
        self.meta.unlink()
        self.claim_file.write_text(json.dumps(metadata))
        return metadata


class IntentsContract:
    implementation_name = "python"
    maxDiff = None

    def setUp(self):
        self.impl = implementation(self.implementation_name)
        if self.impl is None:
            self.skipTest("relay-intents driver not built; run cargo test in rust/")
        self.root = Path(tempfile.mkdtemp(prefix="rr489-"))
        self.inbox_path = self.root / "inbox.sqlite3"
        self.projection = self.root / "turns_v2.json"
        self.state_path = self.root / "voice_command_state.json"
        self.default = Mailbox(self.root / "default")
        self.mailboxes = {key: Mailbox(self.root / key) for key in (SESSION, OTHER_SESSION)}
        self.transcript: list = []

    def tearDown(self):
        self.impl.close()
        shutil.rmtree(self.root, ignore_errors=True)

    # -- calls and fixtures -------------------------------------------------

    def call(self, op: str, **arguments):
        try:
            result = self.impl.call(op, **arguments)
        except Refused as refused:
            self.transcript.append((op, "refused", refused.error))
            raise
        self.transcript.append((op, normalized(result, root=str(self.root))))
        return result

    def open_inbox(self, *, events: bool = True, hold: bool = False):
        self.call(
            "inbox.open",
            path=str(self.inbox_path),
            projection_path=str(self.projection) if events else None,
            hold_recovered_delivery=hold,
        )

    def open_broker(self):
        self.call("broker.open", path=str(self.inbox_path), projection_path=str(self.projection))

    def restart(self, *, events: bool = True, hold: bool = False):
        """A new bridge: the mailbox files are gone, the inbox survives."""
        for mailbox in [self.default, *self.mailboxes.values()]:
            for path in (mailbox.command, mailbox.meta):
                path.unlink(missing_ok=True)
        self.call("inbox.close")
        self.open_inbox(events=events, hold=hold)

    def metadata(self, seq: int, *, item: int = 1, session: str = SESSION,
                 text: str | None = None, command_id: str | None = None, **extra) -> dict:
        command_id = command_id or f"cmd-{seq}"
        intent_id = f"{command_id}:item:{item}"
        metadata = {
            "relay_command_seq": seq,
            "relay_command_id": command_id,
            "intent_id": intent_id,
            "within_turn_order": item,
            "source_text": text or f"request {seq}.{item}",
            "voice_target_session_key": session,
            "recovery_generation": GENERATION,
            "provider": "claude",
            "work_disposition": {"route": "continue_current", "intent_id": intent_id},
        }
        metadata.update(extra)
        return metadata

    def enqueue(self, seq: int, *, route: str = "continue_current", **fields) -> dict:
        metadata = self.metadata(seq, **fields)
        return self.call(
            "inbox.enqueue",
            prompt=f"Agent prompt for {metadata['intent_id']}",
            metadata=metadata,
            route=route,
        )

    def routes(self) -> dict:
        return {key: [str(box.command), str(box.meta)] for key, box in self.mailboxes.items()}

    def materialize(self, routes: dict | None = None):
        return self.call(
            "inbox.materialize_next",
            command_path=str(self.default.command),
            metadata_path=str(self.default.meta),
            transport="contract-ready-file",
            routes=self.routes() if routes is None else routes,
        )

    def observe(self, claimed: dict, seen: bool) -> bool:
        return self.call("inbox.observe_claim", claimed=claimed, provider_turn_seen=seen)

    def claim(self, session: str = SESSION) -> dict:
        claimed = self.mailboxes[session].claim()
        self.assertTrue(self.observe(claimed, False))
        return claimed

    def acknowledge(self, claimed: dict):
        self.assertTrue(self.observe(claimed, True))

    def rows(self) -> dict:
        return {row["intent_id"]: row for row in self.call("inbox.records")}

    def state_of(self, intent_id: str) -> str:
        return self.rows()[intent_id]["state"]

    def deliverable(self) -> list:
        return [
            (item["relay_command_seq"], item["within_turn_order"], item["state"])
            for item in self.call("inbox.deliverable_commands")
        ]

    def turn(self, command: dict, **fields) -> dict:
        """The provider turn the completion hook records for ``command``."""
        session = command.get("voice_target_session_key") or SESSION
        record = {
            **OWNER,
            "provider": "claude",
            "provider_session_id": f"native-{session}",
            "session_id": f"native-{session}",
            "turn_id": f"turn-{command['intent_id']}",
            "intent_id": command["intent_id"],
            "relay_command_seq": command["relay_command_seq"],
            "relay_command_id": command["relay_command_id"],
            "origin": "relay",
        }
        record.update(fields)
        return record

    def complete(self, record: dict, state: str = "completed_final") -> bool:
        return self.call(
            "broker.transition", record=record, to_state=state,
            event_type="provider_stop", release_reason="provider_stop",
        )

    def deliver_reply(self, command: dict) -> bool:
        reservation = self.call("broker.reserve_effect", command={**OWNER, **command})
        if not reservation["accepted"]:
            return False
        authorized = self.call("broker.authorize_effect_delivery", effect_id=reservation["effect_id"])
        self.call("broker.finish_effect", effect_id=reservation["effect_id"], delivered=authorized)
        return authorized

    def table(self, name: str) -> list:
        return self.call("broker.table_records", table=name)

    def transitions(self, record_intent_id: str) -> list:
        turns = {turn["turn_id"]: turn for turn in self.table("provider_turns")}
        return [
            (row["event_type"], row["from_state"], row["to_state"])
            for row in self.table("provider_turn_transitions")
            if turns.get(row["turn_id"], {}).get("intent_id") == record_intent_id
        ]

    def dump(self) -> dict:
        files = {}
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix in {".sqlite3", ".lock"} or "sqlite3-" in path.name:
                continue
            text = path.read_text()
            try:
                content = json.loads(text)
            except json.JSONDecodeError:
                content = text
            files[str(path.relative_to(self.root))] = content
        return normalized(
            {"database": database_dump(self.inbox_path), "files": files},
            root=str(self.root),
        )

    # -- mailbox and claim --------------------------------------------------

    def test_mailbox_holds_the_agent_prompt_and_its_metadata(self):
        """commands/test_mailbox_holds_the_agent_prompt_and_its_metadata: the
        oldest intent is leased into its session's mailbox with its delivery,
        claim and ack ids, and is `delivered`."""
        self.open_inbox()
        stored = self.enqueue(1)
        self.assertEqual(stored["intent_inbox_version"], 6)
        delivered = self.materialize()
        intent_id = "cmd-1:item:1"
        self.assertEqual(delivered["intent_id"], intent_id)
        self.assertEqual(delivered["intent_delivery_id"], f"delivery:{intent_id}")
        self.assertEqual(delivered["intent_claim_id"], f"claim:{intent_id}")
        self.assertEqual(delivered["intent_ack_id"], f"ack:{intent_id}")
        mailbox = self.mailboxes[SESSION]
        prompt, metadata = mailbox.pending()
        self.assertEqual(prompt, f"Agent prompt for {intent_id}")
        self.assertEqual(metadata, delivered)
        self.assertEqual(mailbox.meta.read_text(), json.dumps(delivered, sort_keys=True))
        row = self.rows()[intent_id]
        self.assertEqual((row["state"], row["lease_attempts"], row["transport"]),
                         ("delivered", 1, "contract-ready-file"))
        self.assertEqual(self.deliverable(), [(1, 1, "delivered")])
        self.assertIsNone(self.materialize(), "a second lease while the first is unacknowledged")

    def test_claim_then_acknowledgement_moves_the_intent_through_its_states(self):
        """commands/test_claim_then_acknowledgement_moves_the_intent_through_its_states."""
        self.open_inbox()
        self.enqueue(1)
        self.materialize()
        claimed = self.claim()
        self.assertEqual(self.state_of(claimed["intent_id"]), "claimed")
        self.assertEqual(self.deliverable(), [(1, 1, "claimed")])
        self.acknowledge(claimed)
        self.assertEqual(self.state_of(claimed["intent_id"]), "acked")
        self.assertEqual(self.deliverable(), [])
        self.assertTrue(self.observe(claimed, True), "a repeated acknowledgement is still observed")

    def test_a_provider_turn_in_the_ledger_acknowledges_a_claim(self):
        """commands/test_a_provider_turn_in_the_ledger_acknowledges_a_claim:
        once the claimed intent has a provider turn the claim is acknowledged,
        and the acknowledgement is recorded on that turn once."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1)
        self.materialize()
        claimed = self.claim()
        record = self.turn(claimed)
        self.assertTrue(self.call("broker.activate", record=record))
        self.assertEqual(self.call("broker.state_for", record=record), "active")
        self.acknowledge(claimed)
        self.acknowledge(claimed)
        self.assertEqual(self.state_of(claimed["intent_id"]), "acked")
        self.assertEqual(self.transitions(claimed["intent_id"]), [
            ("prompt_submitted", None, "active"),
            ("intent_acknowledged", "active", "active"),
        ])
        projection = json.loads(self.projection.read_text())
        self.assertEqual(projection["schema_version"], 2)
        self.assertEqual([(r["intent_id"], r["state"]) for r in projection["records"]],
                         [(claimed["intent_id"], "active")])

    def test_a_claim_for_another_command_is_ignored(self):
        """commands/test_an_acknowledgement_that_does_not_match_the_claim_is_ignored,
        the inbox's part: a claim naming the intent under another command is
        not observed and changes nothing."""
        self.open_inbox()
        self.enqueue(1)
        self.materialize()
        claimed = self.claim()
        self.assertFalse(self.observe({**claimed, "relay_command_id": "cmd-other"}, True))
        self.assertFalse(self.observe({**claimed, "relay_command_seq": 9}, True))
        self.assertFalse(self.observe({"intent_id": claimed["intent_id"]}, True))
        self.assertEqual(self.state_of(claimed["intent_id"]), "claimed")

    # -- sequencing -----------------------------------------------------------

    def test_a_newer_turn_waits_until_the_delivered_one_is_acknowledged(self):
        """commands/test_a_newer_turn_waits_until_the_delivered_one_is_acknowledged."""
        self.open_inbox()
        self.enqueue(1)
        self.enqueue(2)
        self.assertEqual(self.materialize()["relay_command_seq"], 1)
        claimed = self.claim()
        self.assertIsNone(self.materialize(), "the claimed command still holds the session")
        self.acknowledge(claimed)
        self.assertEqual(self.materialize()["relay_command_seq"], 2)

    def test_queued_turns_are_delivered_in_arrival_order(self):
        """commands/test_queued_turns_are_delivered_in_arrival_order."""
        self.open_inbox()
        for seq in (1, 2, 3):
            self.enqueue(seq)
        delivered = []
        for _ in range(3):
            self.materialize()
            claimed = self.claim()
            delivered.append(claimed["relay_command_seq"])
            self.acknowledge(claimed)
        self.assertEqual(delivered, [1, 2, 3])
        self.assertIsNone(self.materialize())

    def test_a_turn_with_two_requests_becomes_two_ordered_items(self):
        """commands/test_a_turn_with_two_requests_becomes_two_ordered_items:
        the second item waits for the first item's turn to finish and for its
        authoritative reply, then is delivered."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1, item=1)
        self.enqueue(1, item=2)
        self.assertEqual(self.materialize()["intent_id"], "cmd-1:item:1")
        first = self.claim()
        record = self.turn(first)
        self.call("broker.activate", record=record)
        self.acknowledge(first)
        self.assertIsNone(self.materialize(), "while the first item's turn runs")
        self.assertTrue(self.complete(record))
        self.assertIsNone(self.materialize(), "before the first item's reply")
        self.assertTrue(self.deliver_reply(first))
        second = self.materialize()
        self.assertEqual(second["intent_id"], "cmd-1:item:2")
        self.assertEqual(
            [(item["within_turn_order"], item["state"])
             for item in self.call("inbox.source_command_intents", command=second)],
            [(1, "acked"), (2, "delivered")],
        )

    def test_one_sessions_turn_never_blocks_another_sessions_queue(self):
        """sessions: each live session's mailbox is gated by its own
        unacknowledged intent only (RR-400)."""
        self.open_inbox()
        self.enqueue(1, session=SESSION)
        self.enqueue(2, session=SESSION)
        self.enqueue(3, session=OTHER_SESSION)
        self.assertEqual(self.materialize()["relay_command_seq"], 1)
        self.assertEqual(self.materialize()["relay_command_seq"], 3)
        self.assertIsNone(self.materialize())
        self.assertEqual(self.mailboxes[OTHER_SESSION].pending()[1]["relay_command_seq"], 3)
        self.assertEqual(self.deliverable(), [(1, 1, "delivered"), (2, 1, "pending"), (3, 1, "delivered")])

    def test_a_mailbox_another_session_is_routed_to_waits_for_its_lease(self):
        """sessions: an ended session's work is routed to the focused mailbox,
        so it waits while that mailbox holds any unacknowledged intent, and a
        mailbox with a file in it is never overwritten."""
        self.open_inbox()
        shared = self.routes()
        shared[OTHER_SESSION] = shared[SESSION]
        self.enqueue(1, session=SESSION)
        self.enqueue(2, session=OTHER_SESSION)
        self.assertEqual(self.materialize(shared)["relay_command_seq"], 1)
        first = self.claim()
        self.assertIsNone(self.materialize(shared), "the claimed lease still holds the mailbox")
        self.acknowledge(first)
        stray = self.mailboxes[SESSION].command
        stray.write_text("left by an earlier consumer")
        self.assertIsNone(self.materialize(shared), "a file in the mailbox is never overwritten")
        stray.unlink()
        self.assertEqual(self.materialize(shared)["relay_command_seq"], 2)
        self.assertEqual(self.mailboxes[SESSION].pending()[1]["voice_target_session_key"], OTHER_SESSION)

    def test_without_routing_the_default_mailbox_must_be_empty(self):
        """The manual-bridge mailbox (no live session routing): nothing is
        leased while either default file exists."""
        self.open_inbox()
        self.enqueue(1, session="")
        self.default.meta.write_text("{}")
        materialize = lambda: self.call(  # noqa: E731
            "inbox.materialize_next", command_path=str(self.default.command),
            metadata_path=str(self.default.meta), transport="shared-ready-file")
        self.assertIsNone(materialize())
        self.default.meta.unlink()
        self.assertEqual(materialize()["relay_command_seq"], 1)
        self.assertEqual(self.default.command.read_text(), "Agent prompt for cmd-1:item:1")

    def test_a_sidecar_intent_never_takes_the_mailbox(self):
        """commands/test_a_read_only_task_beside_other_active_work_runs_as_a_sidecar,
        the inbox's part: `run_sidecar` work is listed for its lane and acked
        through its lifecycle without a mailbox lease."""
        self.open_inbox()
        stored = self.enqueue(1, route="run_sidecar")
        self.assertIsNone(self.materialize())
        pending = self.call("inbox.pending_for_route", route="run_sidecar")
        self.assertEqual([work["metadata"]["intent_id"] for work in pending], [stored["intent_id"]])
        self.assertTrue(self.observe(stored, False))
        self.assertTrue(self.observe(stored, True))
        self.assertEqual(self.state_of(stored["intent_id"]), "acked")

    # -- cancellation ----------------------------------------------------------

    def test_a_scoped_cancellation_cancels_only_the_queued_item_it_names(self):
        """commands/test_a_scoped_cancellation_cancels_only_the_queued_item_it_names."""
        self.open_inbox()
        self.enqueue(1, text="add dark mode to the board")
        self.enqueue(2, text="update the release notes")
        self.enqueue(3, text="add dark mode to settings")
        cancelled = self.call("inbox.cancel_scoped", metadata=self.metadata(
            4, cancellation_scope="item", target_intent_ids=["cmd-2:item:1"]))
        self.assertEqual(cancelled, ["cmd-2:item:1"])
        by_text = self.call("inbox.cancel_scoped", metadata=self.metadata(
            5, cancellation_scope="item", target="dark mode"))
        self.assertEqual(by_text, ["cmd-3:item:1"], "item scope takes the newest match only")
        self.assertEqual(self.call("inbox.cancelled_intent_ids"), ["cmd-2:item:1", "cmd-3:item:1"])
        self.assertEqual(self.call("inbox.cancel_scoped", metadata=self.metadata(6)), [],
                         "no scope cancels nothing")

    def test_cancelling_everything_cancels_all_queued_work_and_preempts(self):
        """commands/test_cancelling_everything_cancels_all_queued_work_and_preempts:
        `all_work` reaches every open intent of the issuing session only,
        releases its mailbox and cancels the running turn."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1)
        self.enqueue(2)
        self.enqueue(3, session=OTHER_SESSION)
        self.assertEqual(self.materialize()["relay_command_seq"], 1)
        self.assertEqual(self.materialize()["relay_command_seq"], 3)
        first = self.claim()
        record = self.turn(first)
        self.call("broker.activate", record=record)
        self.acknowledge(first)
        self.assertEqual(self.materialize()["relay_command_seq"], 2)
        cancelled = self.call(
            "inbox.cancel_scoped",
            metadata=self.metadata(4, cancellation_scope="all_work"),
            command_path=str(self.mailboxes[SESSION].command),
            metadata_path=str(self.mailboxes[SESSION].meta),
        )
        self.assertEqual(cancelled, ["cmd-2:item:1", "cmd-1:item:1"])
        self.assertIsNone(self.mailboxes[SESSION].pending(), "the cancelled lease is released")
        self.assertEqual(self.call("broker.state_for", record=record), "cancelled")
        self.assertEqual(self.state_of("cmd-3:item:1"), "delivered")
        self.assertFalse(self.deliver_reply(first), "a cancelled intent's reply is revoked")

    def test_a_newer_command_cancels_older_open_work(self):
        """`cancel_pending_before`: open foreground work of older commands is
        cancelled; sidecars and acknowledged work are not."""
        self.open_inbox()
        self.enqueue(1)
        self.materialize()
        self.acknowledge(self.claim())
        self.enqueue(2)
        self.enqueue(3, route="run_sidecar")
        self.enqueue(4)
        self.assertEqual(self.call("inbox.cancel_pending_before", command_seq=4), 1)
        self.assertEqual({key: row["state"] for key, row in self.rows().items()}, {
            "cmd-1:item:1": "acked",
            "cmd-2:item:1": "cancelled",
            "cmd-3:item:1": "pending",
            "cmd-4:item:1": "pending",
        })

    # -- restart ----------------------------------------------------------------

    def test_a_delivered_unclaimed_command_is_delivered_again(self):
        """restart/test_a_delivered_unclaimed_command_is_delivered_again."""
        self.open_inbox()
        self.enqueue(1)
        self.materialize()
        self.restart()
        row = self.rows()["cmd-1:item:1"]
        self.assertEqual((row["state"], row["recovery_decision"]), ("pending", "resume_exact"))
        self.assertEqual(self.materialize()["intent_id"], "cmd-1:item:1")
        self.assertEqual(self.rows()["cmd-1:item:1"]["lease_attempts"], 2)

    def test_queued_commands_are_delivered_again_in_order(self):
        """restart/test_queued_commands_are_delivered_again_in_order."""
        self.open_inbox()
        for seq in (1, 2, 3):
            self.enqueue(seq)
        self.materialize()
        self.restart()
        delivered = []
        for _ in range(3):
            self.materialize()
            claimed = self.claim()
            delivered.append(claimed["relay_command_seq"])
            self.acknowledge(claimed)
        self.assertEqual(delivered, [1, 2, 3])

    def test_a_claimed_unacknowledged_command_becomes_a_recovery_blocker(self):
        """restart/test_a_claimed_unacknowledged_command_becomes_a_recovery_blocker:
        the uncertain claim is `review_required`, named in the state file, and
        holds the next turn."""
        self.open_inbox()
        self.enqueue(1)
        self.materialize()
        claimed = self.claim()
        self.restart()
        self.enqueue(2)
        row = self.rows()[claimed["intent_id"]]
        self.assertEqual((row["state"], row["recovery_decision"]), ("review_required", "foreground_review"))
        blocker = self.call("inbox.recovery_blocker")
        self.assertEqual(
            (blocker["intent_id"], blocker["command_seq"], blocker["command_id"]),
            (claimed["intent_id"], 1, "cmd-1"),
        )
        self.assertIsNone(self.materialize(), "the uncertain claim holds the session")
        self.call("inbox.sync_deliverable_state", state_path=str(self.state_path))
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["inbox_recovery_blocker"], blocker)
        self.assertEqual(state["relay_command_seq"], 2)
        self.assertEqual([item["intent_id"] for item in state["deliverable_commands"]], ["cmd-2:item:1"])

    def test_a_recovered_claim_is_acknowledged_by_its_provider_turn(self):
        """Partly-covered test_provider_hook_binds_recovered_and_middle_deliverable_intents:
        after a restart the claim file is observed again; once the provider
        turn for the uncertain claim is seen, it is acknowledged and the queue
        moves on. A recovered lease that is pending again is claimed and
        acknowledged by one observation."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1)
        self.enqueue(2)
        self.materialize()
        claimed = self.claim()
        self.restart()
        self.assertTrue(self.observe(claimed, False))
        self.assertEqual(self.state_of(claimed["intent_id"]), "review_required")
        self.call("broker.activate", record=self.turn(claimed))
        self.assertTrue(self.observe(claimed, True))
        self.assertEqual(self.state_of(claimed["intent_id"]), "acked")
        self.assertIsNone(self.call("inbox.recovery_blocker"))
        delivered = self.materialize()
        self.assertEqual(delivered["relay_command_seq"], 2)
        self.restart()
        self.assertEqual(self.state_of(delivered["intent_id"]), "pending")
        self.assertTrue(self.observe(delivered, True))
        self.assertEqual(self.state_of(delivered["intent_id"]), "acked")

    def test_skip_uncertain_with_the_exact_blocker_releases_the_queue(self):
        """restart/test_skip_uncertain_with_the_exact_blocker_releases_the_queue:
        a stale confirmation cannot skip, the exact blocker can."""
        self.open_inbox()
        self.enqueue(1)
        self.materialize()
        self.claim()
        self.restart()
        self.enqueue(2)
        blocker = self.call("inbox.recovery_blocker")
        self.assertFalse(self.call("inbox.skip_recovery_blocker", expected={**blocker, "command_seq": 7}))
        self.assertTrue(self.call("inbox.skip_recovery_blocker", expected=blocker))
        row = self.rows()[blocker["intent_id"]]
        self.assertEqual((row["state"], row["recovery_decision"]), ("cancelled", "user_skipped_uncertain"))
        self.assertIsNone(self.call("inbox.recovery_blocker"))
        self.assertEqual(self.materialize()["relay_command_seq"], 2)

    def test_a_blocker_whose_turn_is_known_is_not_skipped(self):
        """restart: a recovered claim with a provider turn belongs to
        acknowledgement, not to a skip."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1)
        self.materialize()
        claimed = self.claim()
        self.call("broker.activate", record=self.turn(claimed))
        self.restart()
        blocker = self.call("inbox.recovery_blocker")
        self.assertFalse(self.call("inbox.skip_recovery_blocker", expected=blocker))
        self.assertEqual(self.state_of(claimed["intent_id"]), "review_required")

    def test_a_new_recovery_generation_retires_the_old_unacknowledged_work(self):
        """restart/test_a_new_recovery_generation_retires_the_old_unacknowledged_work:
        only this session's (and unrouted) work of another generation is
        retired, and its mailbox lease released."""
        self.open_inbox()
        self.enqueue(1)
        self.enqueue(2, session=OTHER_SESSION)
        self.materialize()
        self.materialize()
        retired = self.call(
            "inbox.retire_stale_foreground",
            recovery_generation="generation-2",
            command_path=str(self.mailboxes[SESSION].command),
            metadata_path=str(self.mailboxes[SESSION].meta),
            before_command_seq=5,
            session_key=SESSION,
        )
        self.assertEqual(retired, 1)
        row = self.rows()["cmd-1:item:1"]
        self.assertEqual((row["state"], row["recovery_decision"]), ("cancelled", "stale_generation_retired"))
        self.assertIsNone(self.mailboxes[SESSION].pending())
        self.assertEqual(self.state_of("cmd-2:item:1"), "delivered")
        with self.assertRaises(Refused):
            self.call("inbox.retire_stale_foreground", recovery_generation="-bad",
                      command_path="", metadata_path="")

    def test_a_terminal_recovered_claim_is_released_without_its_old_reply(self):
        """Gap test_pump_releases_terminal_recovered_claim_without_waiting_for_old_reply:
        after a restart, a claimed intent whose turn already finished is
        acknowledged, not left as a blocker, and the next intent is delivered."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1)
        self.enqueue(2)
        self.materialize()
        claimed = self.claim()
        record = self.turn(claimed)
        self.call("broker.activate", record=record)
        self.complete(record)
        self.restart()
        self.assertEqual(self.state_of(claimed["intent_id"]), "review_required")
        self.assertEqual(self.call("inbox.reconcile_terminal_claims"), 1)
        row = self.rows()[claimed["intent_id"]]
        self.assertEqual((row["state"], row["recovery_decision"]), ("acked", "terminal_claim_reconciled"))
        self.assertIsNone(self.call("inbox.recovery_blocker"))
        self.assertEqual(self.materialize()["relay_command_seq"], 2)

    def test_an_explicit_restart_retires_only_the_exact_unacknowledged_claim(self):
        """Gap test_explicit_restart_retires_only_unacknowledged_claim_and_drains_queue:
        the exact claim is retired; a wrong lease id or a running turn keeps it."""
        self.open_inbox()
        self.open_broker()
        self.enqueue(1)
        self.enqueue(2)
        self.materialize()
        claimed = self.claim()
        self.assertFalse(self.call("inbox.retire_replaced_claim",
                                   expected={**claimed, "intent_claim_id": "claim:other"}))
        record = self.turn(claimed)
        self.call("broker.activate", record=record)
        self.assertFalse(self.call("inbox.retire_replaced_claim", expected=claimed),
                         "a running turn keeps its claim")
        self.complete(record, "failed")
        self.assertTrue(self.call("inbox.retire_replaced_claim", expected=claimed))
        row = self.rows()[claimed["intent_id"]]
        self.assertEqual((row["state"], row["recovery_decision"]), ("cancelled", "user_restart_skipped_uncertain"))
        self.assertEqual(self.materialize()["relay_command_seq"], 2)

    def test_held_recovery_resumes_each_exact_intent_once_then_its_next_sibling(self):
        """Continuity: with delivery held, recovered work waits as
        `recovery_pending`; one exact resume releases it once, and its
        acknowledgement releases the next sibling of its turn."""
        self.open_inbox()
        self.enqueue(1, item=1)
        self.enqueue(1, item=2)
        self.restart(hold=True)
        self.assertEqual({key: row["state"] for key, row in self.rows().items()},
                         {"cmd-1:item:1": "recovery_pending", "cmd-1:item:2": "recovery_pending"})
        self.assertIsNone(self.materialize())
        self.assertFalse(self.call("inbox.resume_after_recovery", intent_id="cmd-1:item:1",
                                   recovery_generation="generation-2"))
        self.assertTrue(self.call("inbox.resume_after_recovery", intent_id="cmd-1:item:1",
                                  recovery_generation=GENERATION))
        self.assertFalse(self.call("inbox.resume_after_recovery", intent_id="cmd-1:item:1",
                                   recovery_generation=GENERATION), "a second resume")
        self.materialize()
        first = self.claim()
        self.acknowledge(first)
        row = self.rows()["cmd-1:item:2"]
        self.assertEqual((row["state"], row["recovery_decision"]), ("pending", f"resumed:{GENERATION}"))

    def test_an_ended_sessions_unclaimed_work_is_retired(self):
        """RR-447: never-claimed work of an ended session is cancelled; claimed
        work stays for review; live sessions keep theirs."""
        self.open_inbox()
        self.enqueue(1)
        self.enqueue(2)
        self.enqueue(3, session=OTHER_SESSION)
        self.materialize()
        self.claim()
        retired = self.call("inbox.retire_ended_sessions", live=[OTHER_SESSION])
        self.assertEqual(retired, 1)
        self.assertEqual({key: row["state"] for key, row in self.rows().items()}, {
            "cmd-1:item:1": "claimed",
            "cmd-2:item:1": "cancelled",
            "cmd-3:item:1": "pending",
        })

    def test_the_turn_projection_is_written_unless_the_broker_is_legacy(self):
        """environment/test_the_turn_projection_is_written_unless_the_broker_is_legacy:
        with a projection path the inbox records lifecycle events and writes
        the v2 projection; without one it touches no provider-turn table."""
        self.open_inbox()
        projection = json.loads(self.projection.read_text())
        self.assertEqual(projection["schema_version"], 2)
        self.assertEqual(projection["records"], [])
        self.call("inbox.close")
        for path in (self.projection, *self.root.glob("inbox.sqlite3*")):
            path.unlink()
        self.open_inbox(events=False)
        self.enqueue(1)
        self.materialize()
        self.acknowledge(self.claim())
        self.assertFalse(self.projection.exists())
        tables = {row[1] for row in database_dump(self.inbox_path)["schema"]}
        self.assertNotIn("provider_turns", tables)
        self.assertEqual(self.call("inbox.reconcile_terminal_claims"), 0)

    # -- state file ---------------------------------------------------------------

    def test_the_state_file_follows_the_newest_command(self):
        """Spool `voice_command_state.json`: the inbox's newest command fills
        an older state, keeps a newer one, and under the same command the
        state's own fields win; the queue fields are always the inbox's."""
        self.open_inbox()
        self.enqueue(1)
        self.enqueue(2, item=1)
        self.enqueue(2, item=2)
        self.call("inbox.cancel_scoped", metadata=self.metadata(
            3, cancellation_scope="item", target_intent_ids=["cmd-1:item:1"]))
        sync = lambda: self.call("inbox.sync_deliverable_state", state_path=str(self.state_path))  # noqa: E731
        sync()
        state = json.loads(self.state_path.read_text())
        self.assertEqual((state["relay_command_seq"], state["intent_id"]), (2, "cmd-2:item:2"))
        self.assertEqual(state["cancelled_intent_ids"], ["cmd-1:item:1"])
        self.assertEqual([item["within_turn_order"] for item in state["source_command_intents"]], [1, 2])
        self.assertIsNone(state["inbox_recovery_blocker"])
        self.state_path.write_text(json.dumps({"relay_command_seq": 2, "relay_command_id": "cmd-2",
                                               "source_text": "kept"}))
        sync()
        self.assertEqual(json.loads(self.state_path.read_text())["source_text"], "kept")
        self.state_path.write_text(json.dumps({"relay_command_seq": 9, "relay_command_id": "cmd-9"}))
        sync()
        state = json.loads(self.state_path.read_text())
        self.assertEqual((state["relay_command_id"], state["source_command_intents"]), ("cmd-9", []))
        self.assertNotIn("intent_id", state)
        self.state_path.write_text("not json")
        sync()
        self.assertEqual(json.loads(self.state_path.read_text())["relay_command_seq"], 2)
        self.assertEqual(self.state_path.read_text(), json.dumps(json.loads(self.state_path.read_text()),
                                                                 sort_keys=True))

    # -- enqueue ---------------------------------------------------------------------

    def test_enqueue_needs_identity_and_keeps_the_first_copy(self):
        """An intent needs a command key and an intent id; a repeated enqueue
        keeps the stored row; a cancelled item is stored cancelled."""
        self.open_inbox()
        for metadata in ({"relay_command_id": "cmd-1"}, {"relay_command_seq": 1},
                         {"relay_command_seq": "x", "relay_command_id": "cmd-1"},
                         {**self.metadata(1), "recovery_generation": "bad generation"}):
            with self.assertRaises(Refused) as refused:
                self.call("inbox.enqueue", prompt="p", metadata=metadata, route="continue_current")
            self.assertEqual(refused.exception.error, "ValueError")
        first = self.enqueue(1, text="first")
        again = self.enqueue(1, text="second")
        self.assertEqual(again["source_text"], "second")
        self.assertEqual(json.loads(self.rows()[first["intent_id"]]["metadata_json"])["source_text"], "first")
        stored = self.call("inbox.enqueue", prompt="p", metadata={
            "relay_command_seq": " 4 ", "relay_command_id": " cmd-4 ",
            "voice_work_item": {"within_turn_order": 3, "lifecycle_state": "abandoned"},
            "recovery_generation": 12,
        }, route="continue_current")
        self.assertEqual((stored["intent_id"], stored["within_turn_order"]), ("cmd-4", 3))
        row = self.rows()["cmd-4"]
        self.assertEqual((row["state"], row["command_seq"], row["recovery_generation"], row["session_key"]),
                         ("cancelled", 4, "12", ""))
        snapshot = self.call("inbox.state_snapshot")
        self.assertEqual(snapshot[0]["intent_id"], "cmd-4")

    # -- the turn ledger ----------------------------------------------------------------

    def test_a_new_prompt_supersedes_the_active_turn_and_a_steer_moves_it(self):
        """Turn ledger: a newer prompt in the same provider session orphans the
        active turn; a second prompt under one physical turn rebinds it."""
        self.open_broker()
        first = self.turn(self.metadata(1))
        second = self.turn(self.metadata(2))
        self.assertTrue(self.call("broker.activate", record=first))
        self.assertFalse(self.call("broker.activate", record=first), "the same prompt again")
        self.assertTrue(self.call("broker.activate", record=second))
        self.assertEqual(self.call("broker.state_for", record=first), "orphaned")
        steered = {**second, **{key: value for key, value in self.turn(self.metadata(3)).items()
                                if key in {"intent_id", "relay_command_seq", "relay_command_id"}}}
        self.assertFalse(self.call("broker.activate", record=steered))
        turns = {turn["turn_id"]: turn for turn in self.table("provider_turns")}
        self.assertEqual(sorted((turn["intent_id"], turn["state"]) for turn in turns.values()),
                         [("cmd-1:item:1", "orphaned"), ("cmd-3:item:1", "active")])
        self.assertEqual(
            [row["event_type"] for row in self.table("provider_turn_transitions")],
            ["prompt_submitted", "superseded", "prompt_submitted", "prompt_steered"],
        )
        self.assertEqual(
            [(record["intent_id"], record["state"]) for record in
             self.call("broker.session_records", native_session_id=f"native-{SESSION}")],
            [("cmd-1:item:1", "orphaned"), ("cmd-3:item:1", "active")],
        )
        with self.assertRaises(Refused):
            self.call("broker.activate", record={**first, "actor_role": "voice_bridge"})

    def test_a_turn_finishes_exactly_once(self):
        """Turn ledger: only an active turn moves, to a terminal state, once;
        an unknown turn or state does not move."""
        self.open_broker()
        record = self.turn(self.metadata(1))
        self.assertFalse(self.complete(record), "unknown turn")
        self.call("broker.activate", record=record)
        self.assertFalse(self.complete(record, "active"))
        self.assertFalse(self.complete(record, "finished"))
        self.assertTrue(self.complete(record, "empty"))
        self.assertFalse(self.complete(record, "completed_final"))
        self.assertEqual(self.call("broker.state_for", record=record), "empty")

    def test_a_provider_interrupt_cancels_a_turn_once_per_event(self):
        """Gap test_interrupted_claude_turns_cancel_once_per_interrupt_in_one_session:
        an interrupt with an event id cancels the turn once, and a later reply
        for that turn is refused."""
        self.open_broker()
        command = self.metadata(1)
        record = self.turn(command)
        self.call("broker.activate", record=record)
        cancel = lambda event_id: self.call(  # noqa: E731
            "broker.transition", record=record, to_state="cancelled", event_type="provider_turn_cancelled",
            release_reason="provider_interrupted", event_id=event_id)
        self.assertTrue(cancel("interrupt-1"))
        self.assertFalse(cancel("interrupt-1"))
        reservation = self.call("broker.reserve_effect", command={**OWNER, **command})
        self.assertEqual((reservation["accepted"], reservation["reason"]), (False, "turn_revoked"))

    def test_a_terminated_provider_ends_its_owners_active_turns_once(self):
        """Gap test_durable_broker_deduplicates_authoritative_effect_after_bridge_restart,
        its termination part: `provider_terminated` ends every active turn of
        the owner's provider session, once per event id."""
        self.open_broker()
        record = self.turn(self.metadata(1))
        self.call("broker.activate", record=record)
        terminate = lambda session, event: self.call(  # noqa: E731
            "broker.terminate_owner", ownership=OWNER, provider_session_id=session,
            release_reason="app_teardown", event_id=event)
        self.assertEqual(terminate("native-other", "teardown-1"), 0)
        self.assertEqual(terminate(f"native-{SESSION}", ""), 0)
        self.assertEqual(terminate(f"native-{SESSION}", "teardown-1"), 1)
        self.assertEqual(terminate(f"native-{SESSION}", "teardown-1"), 0)
        self.assertEqual(self.call("broker.state_for", record=record), "terminated")

    def test_a_reply_effect_is_delivered_once_across_a_restart(self):
        """Gap test_durable_broker_deduplicates_authoritative_effect_after_bridge_restart:
        one authoritative reply per intent, even from a new bridge."""
        self.open_inbox()
        self.open_broker()
        command = self.enqueue(1)
        record = self.turn(command)
        self.call("broker.activate", record=record)
        self.assertEqual(self.call("broker.reserve_effect", command={"intent_id": "x"})["reason"],
                         "ownership_or_command_missing")
        self.assertEqual(self.call("broker.reserve_effect", command={**OWNER, "intent_id": "cmd-9:item:1"})
                         ["reason"], "turn_missing")
        self.assertTrue(self.deliver_reply(command))
        self.call("broker.close")
        self.open_broker()
        again = self.call("broker.reserve_effect", command={**OWNER, **command})
        self.assertEqual((again["accepted"], again["reason"]), (False, "duplicate"))
        self.assertFalse(self.call("broker.authorize_effect_delivery", effect_id=again["effect_id"]))
        effects = self.table("provider_turn_effects")
        self.assertEqual([(effect["intent_id"], effect["state"]) for effect in effects],
                         [(command["intent_id"], "delivered")])
        by_command = self.call("broker.reserve_effect", command={
            **OWNER, "relay_command_seq": 1, "relay_command_id": "cmd-1", "intent_id": " "})
        self.assertTrue(by_command["accepted"], "a command-keyed authority is separate")

    def test_revocation_between_reservation_and_delivery_fails_the_effect(self):
        """replies/test_reply_for_a_cancelled_intent_is_dropped, the ledger's
        part: an intent cancelled after its reply was reserved is never
        delivered."""
        self.open_inbox()
        self.open_broker()
        command = self.enqueue(1)
        self.call("broker.activate", record=self.turn(command))
        reservation = self.call("broker.reserve_effect", command={**OWNER, **command})
        self.assertTrue(reservation["accepted"])
        self.call("inbox.cancel_scoped", metadata=self.metadata(
            2, cancellation_scope="item", target_intent_ids=[command["intent_id"]]))
        self.assertFalse(self.call("broker.authorize_effect_delivery", effect_id=reservation["effect_id"]))
        self.call("broker.finish_effect", effect_id=reservation["effect_id"], delivered=True)
        self.assertEqual([effect["state"] for effect in self.table("provider_turn_effects")], ["failed"])
        finished = self.enqueue(3)
        record = self.turn(finished)
        self.call("broker.activate", record=record)
        self.complete(record)
        self.call("inbox.cancel_scoped", metadata=self.metadata(
            4, cancellation_scope="item", target_intent_ids=[finished["intent_id"]]))
        self.assertEqual(self.call("broker.state_for", record=record), "completed_final",
                         "a finished turn keeps its state")
        refused = self.call("broker.reserve_effect", command={**OWNER, **finished})
        self.assertEqual((refused["accepted"], refused["reason"]), (False, "turn_revoked"))
        with self.assertRaises(Refused):
            self.call("broker.table_records", table="intents")


class PythonIntentsContract(IntentsContract, unittest.TestCase):
    implementation_name = "python"


class RustIntentsContract(IntentsContract, unittest.TestCase):
    implementation_name = "rust"


VOICE_TURNS = [
    "fix the login bug and then update the readme",
    "go ahead and fix it",
    "Go ahead and fix it",
    "add dark mode, then cancel that",
    "add dark mode; build the export. remove the banner",
    "create a ticket for the export and dispatch it",
    "cancel everything",
    "stop RR-12",
    "never mind",
    "scratch that, update the changelog instead",
    "don't stop the build",
    "do not cancel or stop it",
    "please open Chrome and then fix the login bug",
    "hey, can you please open Chrome",
    "Can you build this? I only want to discuss feasibility, do not implement it",
    "Create a ticket for dark mode; do not implement it",
    "create a ticket but don't dispatch it",
    "backlog only: write a ticket for search",
    "yes, do that",
    "Go ahead.",
    "yes but first check the tests",
    "   ",
    "",
    "meanwhile research the API docs",
    "in parallel, inspect the repository and summarize it",
    "in parallel check the calendar",
    "should we switch to the new design?",
    "maybe instead look at the logs",
    "be quiet",
    "stop talking",
    "stop the dev server",
    "start the development server",
    "write an email to the team",
    "take a screenshot of the browser window",
    "also add tests while you're at it",
    "what is left on the release checklist",
    "why does the build fail? fix it then",
    "replace that with export",
    "switch to the settings page",
    "cancel the dark mode work",
    "cancel GEN-0123456789abcdef",
    "stop the current task",
    "never mind the last one",
    "it's just a question",
    "don’t implement anything yet.",
    "I just want to talk through the plan",
    "explain how the inbox works and then refactor it",
    "update the readme. then fix the tests",
    "fix it\nand then update the docs",
    "redirect to the onboarding flow",
    "abort",
    "actually instead build the importer",
    "no need to stop the deploy",
    "Ship the release and then tap the button",
]
ACTION_KINDS = [
    ("conversation", None),
    ("conversation", "route_undecided"),
    ("control", "cancel"),
    ("control", "interrupt"),
    ("control", "tts_stop"),
    ("direct_action", None),
    ("inline_work", None),
    ("create_ticket", None),
    ("dispatch_ticket", "dispatch"),
    ("needs_project", None),
]
ACTIVE_WORK = [
    [],
    [{"work_id": "cmd-1:item:1", "resources": ["repository"], "target": "dark mode"}],
    [{"work_id": "cmd-1:item:1", "resources": [], "target": None},
     {"work_id": "cmd-2:item:1", "resources": ["desktop"], "target": "browser"}],
]


@unittest.skipUnless(driver_command(), "relay-intents driver not built; run cargo test in rust/")
class ParityTest(unittest.TestCase):
    """The Rust crate and the Python modules answer every call alike."""

    maxDiff = None

    def run_case(self, name: str, implementation_name: str):
        case_class = PythonIntentsContract if implementation_name == "python" else RustIntentsContract
        case = case_class(name)
        case.setUp()
        try:
            getattr(case, name)()
            return case.transcript, case.dump()
        finally:
            case.tearDown()

    def test_every_contract_case_leaves_the_same_calls_rows_and_files(self):
        names = sorted(name for name in dir(IntentsContract) if name.startswith("test_"))
        self.assertGreater(len(names), 20)
        for name in names:
            with self.subTest(case=name):
                python_transcript, python_dump = self.run_case(name, "python")
                rust_transcript, rust_dump = self.run_case(name, "rust")
                self.assertEqual(rust_transcript, python_transcript)
                self.assertEqual(rust_dump, python_dump)

    def test_the_intent_model_answers_every_voice_turn_alike(self):
        python, rust = implementation("python"), implementation("rust")
        try:
            def both(op, **arguments):
                expected = python.call(op, **arguments)
                self.assertEqual(rust.call(op, **arguments), expected, (op, arguments))

            predicates = (
                "explicit_cancel_requested", "inferred_resource_claims", "dispatch_forbidden",
                "foreground_action_requested", "discussion_only_requested",
                "context_dependent_assent", "mixed_bucket_request", "whole_turn_resolution_required",
            )
            for text in VOICE_TURNS:
                both("model.normalize_voice_work_items", text=text, relay_command_seq=7, relay_command_id="cmd-7")
                for predicate in predicates:
                    both(f"model.{predicate}", text=text)
                for kind, reason in ACTION_KINDS:
                    both("model.explicit_replace_requested", text=text, action_reason=reason or "")
                    both("model.qualify_intent", text=text, action_kind=kind, action_reason=reason,
                         command_id="cmd-7", command_seq=7)
                    both("model.format_qualification_for_agent", text=text, action_kind=kind,
                         action_reason=reason, command_id=None, command_seq=None)
                    for active in ACTIVE_WORK:
                        for scope in (None, "item", "all_work", "bogus"):
                            request = {
                                "intent_id": "cmd-7:item:1", "action_kind": kind, "action_reason": reason,
                                "source_text": text, "active_work": active, "cancellation_scope": scope,
                                "target_work_ids": ["cmd-1:item:1"] if scope == "item" else [],
                            }
                            both("model.resolve_intent_disposition", **request)
                            for fallback in ("inspection", "mutation"):
                                both("model.authorization_relationship_for", fallback=fallback, **request)
                    both("model.sidecar_eligible", text=text, active_work=ACTIVE_WORK[1],
                         requested_resources=["desktop"] if kind == "direct_action" else [],
                         project_mutation=kind == "create_ticket")
        finally:
            python.close()
            rust.close()

    def test_either_implementation_creates_the_same_schema(self):
        dumps = {}
        for name in ("python", "rust"):
            for events in (True, False):
                root = Path(tempfile.mkdtemp(prefix="rr489-schema-"))
                try:
                    impl = implementation(name)
                    impl.call("inbox.open", path=str(root / "inbox.sqlite3"),
                              projection_path=str(root / "turns.json") if events else None)
                    impl.call("broker.open", path=str(root / "broker.sqlite3"), projection_path=None)
                    impl.close()
                    dumps[(name, events)] = (
                        database_dump(root / "inbox.sqlite3")["schema"],
                        database_dump(root / "broker.sqlite3")["schema"],
                    )
                finally:
                    shutil.rmtree(root, ignore_errors=True)
        self.assertEqual(dumps[("rust", True)], dumps[("python", True)])
        self.assertEqual(dumps[("rust", False)], dumps[("python", False)])

    def test_an_older_inbox_is_migrated_and_recovered_alike(self):
        """A schema-version-1 inbox with leases in every state: both
        implementations add the columns, backfill generations and owners,
        replace the old index and recover the leases the same way."""
        dumps = {}
        for name in ("python", "rust"):
            root = Path(tempfile.mkdtemp(prefix="rr489-migrate-"))
            try:
                path = root / "inbox.sqlite3"
                old = sqlite3.connect(path)
                old.executescript("""
                    CREATE TABLE inbox_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE intents (
                        ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                        intent_id TEXT NOT NULL UNIQUE,
                        command_seq INTEGER NOT NULL,
                        command_id TEXT NOT NULL,
                        prompt TEXT NOT NULL,
                        metadata_json TEXT NOT NULL,
                        route TEXT NOT NULL,
                        state TEXT NOT NULL,
                        delivery_id TEXT NOT NULL UNIQUE,
                        claim_id TEXT,
                        created_at REAL NOT NULL,
                        delivered_at REAL,
                        claimed_at REAL,
                        acked_at REAL,
                        cancelled_at REAL,
                        transport TEXT
                    );
                    CREATE UNIQUE INDEX intents_command_key ON intents(command_seq, command_id);
                """)
                for seq, state, metadata in (
                    (1, "acked", {"recovery_generation": "gen-a", "voice_target_session_key": "s1"}),
                    (2, "delivered", {"recovery_generation": 5, "voice_target_session_key": " s2 "}),
                    (3, "claimed", {"recovery_generation": "bad gen"}),
                    (4, "pending", []),
                    (5, "pending", "not json"),
                ):
                    old.execute(
                        "INSERT INTO intents(intent_id, command_seq, command_id, prompt, metadata_json, "
                        "route, state, delivery_id, claim_id, created_at, claimed_at) "
                        "VALUES(?, ?, ?, 'p', ?, 'continue_current', ?, ?, ?, 1.5, ?)",
                        (f"i{seq}", seq, f"c{seq}",
                         metadata if isinstance(metadata, str) else json.dumps(metadata),
                         state, f"d{seq}", f"k{seq}", 2.5 if state == "claimed" else None),
                    )
                old.commit()
                old.close()
                impl = implementation(name)
                impl.call("inbox.open", path=str(path), projection_path=str(root / "turns.json"))
                records = impl.call("inbox.records")
                impl.close()
                dumps[name] = normalized(
                    {"records": records, "database": database_dump(path)}, root=str(root))
            finally:
                shutil.rmtree(root, ignore_errors=True)
        self.assertEqual(dumps["rust"], dumps["python"])
        states = {row["intent_id"]: (row["state"], row["recovery_generation"], row["session_key"])
                  for row in dumps["python"]["records"]}
        self.assertEqual(states, {
            "i1": ("acked", "gen-a", "s1"),
            "i2": ("pending", "5", "s2"),
            "i3": ("review_required", "0", ""),
            "i4": ("pending", "0", ""),
            "i5": ("pending", "0", ""),
        })


if __name__ == "__main__":
    unittest.main()
