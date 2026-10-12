"""Transferred voice requests retain their original canonical mutation grant.

The fixture uses real inbox/broker databases, authorization ledger, daemon scope
validation and artifact publication. Only provider process startup is replaced;
no running daemon, user board, provider account or Git remote is touched.
"""
from __future__ import annotations

import json
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))
sys.path.insert(0, str(ROOT / "tests"))

import orchestrator
import relay_completion_hook as hook
import test_orchestrator_artifact_lifecycle as artifact_fixture
from intent_inbox import IntentInbox
from provider_turn_broker import ProviderTurnBroker
from relay_authorization import record_command_authorization


class ContextContinuationMutationTests(unittest.TestCase):
    def setUp(self):
        notify = patch.object(orchestrator, "_notify_state", return_value=True)
        notify.start()
        self.addCleanup(notify.stop)
        self.fixture = artifact_fixture.OrchestratorArtifactLifecycleTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.write_ticket("RR-next")
        self.root = self.fixture.root
        self.database = self.root / "intent-inbox.sqlite3"
        self.projection = self.root / "provider-turns.json"
        self.ledger = self.root / "authorizations.json"
        self.state = self.root / "command-state.json"
        self.inbox = IntentInbox(self.database, provider_turn_projection_path=self.projection)
        self.broker = ProviderTurnBroker(self.database, projection_path=self.projection)
        self.addCleanup(self.inbox.close)
        self.addCleanup(self.broker.close)
        for name, value in (("RELAY_COMMAND_STATE_FILE", self.state),
                            ("RELAY_COMMAND_AUTHORIZATION_FILE", self.ledger)):
            replacement = patch.object(orchestrator, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def transferred_request(self, provider):
        command = {"relay_command_seq": 41, "relay_command_id": "original-voice-command",
                   "intent_id": "original-voice-intent", "action": "dispatch_ticket",
                   "ticket_id": "RR-1"}
        stored = self.inbox.enqueue("Continue this authorized task in the selected project.", command,
                                    "continue_current")
        self.assertTrue(self.inbox.observe_claim(stored, provider_turn_seen=True, now=100))
        record_command_authorization(self.ledger, command, relationship="replacement", now=100,
                                     allowed_mutations=[{"kind": "dispatch_ticket",
                                                         "ticket_ids": ["RR-1", "RR-NEXT"]}])
        original_ledger = self.ledger.read_bytes()
        source = {"app_session_id": "source-app", "recovery_generation": "source-generation",
                  "actor_role": "foreground_pm", "foreground_gate_handle": "source-gate",
                  "provider": provider, "provider_session_id": str(uuid.uuid4()),
                  "session_id": str(uuid.uuid4()), "turn_id": str(uuid.uuid4()),
                  "origin": "relay", "created_at": 100, **command}
        self.assertTrue(self.broker.activate(source, now=100))
        owner = {key: source[key] for key in ("app_session_id", "recovery_generation",
                 "foreground_gate_handle", "provider", "provider_session_id")}
        owner["native_session_id"] = source["session_id"]
        captured = self.authority({"operation": "capture", "source": owner})
        self.assertEqual(captured["status"], "active")
        self.source = captured["source"]
        self.assertTrue(self.broker.transition(source, to_state="completed_final", event_type="final",
                                               release_reason="successful_source_reply", now=101))
        self.assertEqual(self.authority({"operation": "check", "source": self.source})["status"], "ready")

        # This is the canonical destination turn emitted after its guarded manual
        # continuation boundary is acknowledged. Its origin remains manual while
        # the parent's voice tuple remains attached to it.
        destination = {**source, "app_session_id": "destination-app",
                       "recovery_generation": "destination-generation",
                       "foreground_gate_handle": "destination-gate",
                       "provider_session_id": str(uuid.uuid4()), "session_id": str(uuid.uuid4()),
                       "turn_id": str(uuid.uuid4()), "origin": "manual", "created_at": 102,
                       "manual_submission_id": "continuation-fixture",
                       "manual_submit_evidence_source": "relay_context_continuation"}
        self.assertTrue(self.broker.activate(destination, now=102))
        destination_owner = {key: destination[key] for key in owner if key != "native_session_id"}
        destination_owner["native_session_id"] = destination["session_id"]
        self.assertEqual(self.authority({"operation": "ack", "source": self.source,
                                        "destination": destination_owner,
                                        "submission_id": "continuation-fixture"})["status"], "consumed")
        projected = next(row for row in json.loads(self.projection.read_text())["records"]
                         if row["provider_session_id"] == destination["provider_session_id"])
        self.assertEqual(projected["origin"], "manual")
        self.assertEqual(projected["manual_submission_id"], "continuation-fixture")
        self.assertEqual(self.ledger.read_bytes(), original_ledger,
                         "Context transfer must preserve used/revoked grants without registering new authority")
        self.lineage = {key: projected[key] for key in ("relay_command_seq", "relay_command_id")}
        self.lineage["relay_intent_id"] = projected["intent_id"]
        self.assertEqual(self.lineage, {"relay_command_seq": 41,
                                        "relay_command_id": "original-voice-command",
                                        "relay_intent_id": "original-voice-intent"})
        # The parent is deliberately older than the current voice status turn;
        # admission must consult its preserved ledger rather than current-turn fallback.
        self.state.write_text(json.dumps({"relay_command_seq": 42, "relay_command_id": "status-question"}))

    def authority(self, request):
        return hook.context_continuation_authority(request, database_path=str(self.database),
                                                   authorization_path=str(self.ledger))

    def dispatch(self, ticket_id):
        return self.fixture.daemon.dispatch(ticket_id=ticket_id, repo_path=str(self.fixture.repo),
                                           project_scope_token=self.fixture.scope_token(), **self.lineage)

    def allowed_and_replayed(self, provider):
        self.transferred_request(provider)
        before = self.fixture.store._head()
        with patch.object(orchestrator.Worker, "start") as startup, patch.object(
            self.fixture.daemon, "_effective_worker_agent", return_value=(provider, "/usr/bin/true", {}),
        ):
            run = self.dispatch("RR-1")["run"]
            self.addCleanup(orchestrator.remove_worktree, str(self.fixture.repo), Path(run["workspace_path"]))
            startup.assert_called_once()
            self.assertEqual(run["provider_key"], provider)
            self.assertEqual(run["repo_path"], str(self.fixture.repo.resolve()))
            self.assertNotEqual(self.fixture.store._head(), before)
            markdown = self.fixture.store.snapshot().files[".orchestrator/RR-1.md"]
            self.assertIn(b"status: in_progress", markdown)
            self.assertIn(f"run_id: {run['id']}".encode(), markdown)
            self.assertEqual((self.fixture.repo / ".orchestrator/RR-1.md").read_bytes(), markdown)
            ledger = json.loads(self.ledger.read_text())["authorizations"][0]
            self.assertEqual(ledger["intent_id"], self.lineage["relay_intent_id"])
            self.assertEqual(len(ledger["started_mutations"]), 1)
            self.assertEqual(ledger["started_mutations"][0]["mutation"],
                             {"kind": "dispatch_ticket", "ticket_id": "RR-1"})
            head, runs = self.fixture.store._head(), self.fixture.daemon.runs.list()
            with self.assertRaisesRegex(ValueError, "replayed Relay mutation authorization"):
                self.dispatch("RR-1")
            self.assertEqual(self.fixture.store._head(), head)
            self.assertEqual(self.fixture.daemon.runs.list(), runs)
            startup.assert_called_once()

    def revoked_parent(self, provider):
        self.transferred_request(provider)
        cancellation = {"relay_command_seq": 43, "relay_command_id": "cancel-parent",
                        "intent_id": "cancel-intent", "cancellation_scope": "item",
                        "target_intent_ids": [self.lineage["relay_intent_id"]]}
        record_command_authorization(self.ledger, cancellation, relationship="cancel", allowed_mutations=[], now=103)
        self.state.write_text(json.dumps(cancellation))
        self.assertEqual(self.inbox.cancel_scoped(cancellation), [self.lineage["relay_intent_id"]])
        self.assertEqual(self.authority({"operation": "check", "source": self.source})["status"], "blocked")
        before, runs = self.fixture.store._head(), self.fixture.daemon.runs.list()
        with patch.object(orchestrator.Worker, "start") as startup, \
                self.assertRaisesRegex(ValueError, "authorization was revoked"):
            # Keep the original tuple even after cancellation; dropping it would
            # incorrectly turn the destination's manual origin into unrestricted work.
            self.dispatch("RR-next")
        startup.assert_not_called()
        self.assertEqual(self.fixture.store._head(), before)
        self.assertEqual(self.fixture.daemon.runs.list(), runs)
        self.assertIn(b"status: ready", self.fixture.store.snapshot().files[".orchestrator/RR-next.md"])

    def test_codex_transferred_parent_publishes_once_and_rejects_replay(self):
        self.allowed_and_replayed("codex")

    def test_claude_transferred_parent_publishes_once_and_rejects_replay(self):
        self.allowed_and_replayed("claude")

    def test_codex_cancelled_parent_cannot_publish_after_transfer(self):
        self.revoked_parent("codex")

    def test_claude_cancelled_parent_cannot_publish_after_transfer(self):
        self.revoked_parent("claude")


if __name__ == "__main__":
    unittest.main()
