from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import orchestrator  # noqa: E402
import voice_bridge  # noqa: E402
from orchestrator import Daemon, MessengerOutcomeStore, OrchestratorCommandStore, OrchestratorSessionStore  # noqa: E402
from tickets import read as read_ticket  # noqa: E402


class OrchestratorLifecycleTests(unittest.TestCase):
    def test_orchestrator_session_starts_and_reuses_project_provider(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = OrchestratorSessionStore(Path(tmp) / "sessions.db")
            repo = Path(tmp) / "repo"
            repo.mkdir()

            first = store.ensure(
                repo_path=str(repo),
                provider_key="codex",
                model_alias="gpt-5.5",
                effort="high",
                source="relay-bridge",
                pid=123,
            )
            second = store.ensure(
                repo_path=str(repo),
                provider_key="codex",
                model_alias="gpt-5.5",
                effort="high",
                source="relay-bridge",
                pid=123,
            )

            self.assertTrue(first["created"])
            self.assertFalse(second["created"])
            self.assertEqual(first["id"], second["id"])
            self.assertEqual(second["state"], "idle")
            self.assertEqual(second["provider_key"], "codex")

    def test_orchestrator_session_handles_provider_change_on_same_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = OrchestratorSessionStore(Path(tmp) / "sessions.db")
            repo = Path(tmp) / "repo"
            repo.mkdir()
            store.ensure(repo_path=str(repo), provider_key="codex")

            changed = store.ensure(repo_path=str(repo), provider_key="claude")

            self.assertFalse(changed["created"])
            self.assertTrue(changed["provider_changed"])
            self.assertEqual(changed["provider_key"], "claude")
            self.assertIn("provider changed from codex to claude", changed["stop_reason"])

    def test_orchestrator_session_heartbeat_stop_stale_and_project_switch(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = OrchestratorSessionStore(Path(tmp) / "sessions.db")
            repo_a = Path(tmp) / "repo-a"
            repo_b = Path(tmp) / "repo-b"
            repo_a.mkdir()
            repo_b.mkdir()

            first = store.ensure(repo_path=str(repo_a), provider_key="codex")
            second = store.ensure(repo_path=str(repo_b), provider_key="codex")
            self.assertNotEqual(first["id"], second["id"])

            planning = store.heartbeat(session_id=first["id"], state="planning")
            self.assertEqual(planning["state"], "planning")

            stopped = store.stop(session_id=first["id"], reason="bridge stopped")
            self.assertEqual(stopped["state"], "stopped")
            self.assertEqual(stopped["stop_reason"], "bridge stopped")

            stale_count = store.reconcile_stale(stale_after_seconds=0)
            self.assertEqual(stale_count, 1)
            sessions = store.list(limit=10)
            states_by_id = {session["id"]: session["state"] for session in sessions}
            self.assertEqual(states_by_id[first["id"]], "stopped")
            self.assertEqual(states_by_id[second["id"]], "stale")

    def test_messenger_outcome_store_dedupes_and_marks_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = MessengerOutcomeStore(Path(tmp) / "outcomes.db")
            payload = {
                "text": "RR-7 run 12 awaiting review",
                "trace_event": {
                    "kind": "run-review-needed",
                    "message": "RR-7 run 12 awaiting review",
                    "source": "worker",
                    "ticket_id": "RR-7",
                    "run_id": 12,
                },
            }

            first = store.record(repo_path=tmp, provider_key="codex", payload=payload)
            second = store.record(repo_path=tmp, provider_key="codex", payload=payload)
            pending = store.pending(repo_path=tmp, provider_key="codex")

            self.assertEqual(first["id"], second["id"])
            self.assertEqual(len(pending), 1)
            self.assertEqual(pending[0]["payload"]["trace_event"]["kind"], "run-review-needed")

            delivered = store.mark_delivered(first["id"])

            self.assertIsNotNone(delivered["delivered_at"])
            self.assertEqual(store.pending(repo_path=tmp, provider_key="codex"), [])

    def test_messenger_outcome_store_keeps_latest_bounded_pending_outcomes(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = MessengerOutcomeStore(Path(tmp) / "outcomes.db", max_pending_per_repo=2)
            for run_id in (1, 2, 3):
                store.record(
                    repo_path=tmp,
                    provider_key="claude",
                    payload={
                        "text": f"RR-{run_id} run {run_id} failed",
                        "trace_event": {
                            "kind": "run-failed",
                            "message": f"RR-{run_id} run {run_id} failed",
                            "source": "worker",
                            "ticket_id": f"RR-{run_id}",
                            "run_id": run_id,
                        },
                    },
                )

            pending = store.pending(repo_path=tmp, provider_key="claude")

            self.assertEqual([row["run_id"] for row in pending], [2, 3])

    def test_messenger_outcome_pending_delivery_is_project_scoped_across_providers(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = MessengerOutcomeStore(Path(tmp) / "outcomes.db")
            store.record(
                repo_path=tmp,
                provider_key="codex",
                payload={
                    "text": "RR-7 run 12 merged",
                    "trace_event": {
                        "kind": "run-merged",
                        "message": "RR-7 run 12 merged",
                        "source": "orchestrator",
                        "ticket_id": "RR-7",
                        "run_id": 12,
                    },
                },
            )

            pending = store.pending(repo_path=tmp, provider_key="claude")

            self.assertEqual(len(pending), 1)
            self.assertEqual(pending[0]["kind"], "run-merged")

    def test_daemon_lifecycle_emit_updates_state_and_queues_messenger_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            daemon = self.make_daemon(root, provider="codex")
            notifications: list[tuple[str, dict]] = []

            with patch("orchestrator._notify_state", lambda state, **payload: notifications.append((state, payload))):
                daemon._emit_lifecycle(
                    "run-review-needed",
                    ticket_id="RR-7",
                    run_id=12,
                    source="worker",
                    repo_path=str(repo),
                    provider_key="codex",
                )
                daemon._emit_lifecycle(
                    "run-review-needed",
                    ticket_id="RR-7",
                    run_id=12,
                    source="worker",
                    repo_path=str(repo),
                    provider_key="codex",
                )

            pending = daemon.pending_messenger_outcomes(repo_path=str(repo), provider="codex")

            self.assertEqual(notifications[0][0], "working")
            self.assertEqual(notifications[0][1]["trace_event"]["kind"], "run-review-needed")
            self.assertEqual(len(pending), 1)
            self.assertEqual(pending[0]["message"], "RR-7 run 12 awaiting review")

    def test_daemon_persists_full_lifecycle_detail_with_compact_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            daemon = self.make_daemon(root, provider="claude")
            notifications: list[tuple[str, dict]] = []
            detail = (
                "RR-279 verification resumed: Mounted test on the currently running installed "
                "Relay Runner v0.4.35 after Screen Recording and Accessibility were granted."
            )

            with patch(
                "orchestrator._notify_state",
                lambda state, **payload: notifications.append((state, payload)),
            ):
                daemon._emit_lifecycle(
                    "run-verification-resumed",
                    ticket_id="RR-279",
                    run_id=15,
                    message=detail,
                    repo_path=str(repo),
                    provider_key="claude",
                )

            persisted = MessengerOutcomeStore(root / "messenger_outcomes.db").pending(
                repo_path=str(repo),
                provider_key="codex",
            )
            compact = notifications[0][1]["text"]
            self.assertLessEqual(len(compact), 96)
            self.assertEqual(notifications[0][1]["trace_event"]["message"], compact)
            self.assertEqual(
                notifications[0][1]["trace_event"]["lifecycle_detail"],
                detail,
            )
            self.assertEqual(persisted[0]["message"], compact)
            self.assertEqual(
                persisted[0]["payload"]["trace_event"]["lifecycle_detail"],
                detail,
            )

    def test_voice_bridge_registers_heartbeats_and_stops_lifecycle(self):
        requests: list[tuple[str, dict]] = []

        def fake_request(path: str, payload: dict) -> dict:
            requests.append((path, payload))
            if path == "/v1/orchestrator-session/ensure":
                return {"orchestrator_session": {"id": 7}}
            if path == "/v1/orchestrator-session/heartbeat":
                return {"orchestrator_session": {"id": payload["session_id"]}}
            if path == "/v1/orchestrator-session/stop":
                return {"orchestrator_session": {"id": payload["session_id"]}}
            return {}

        with tempfile.TemporaryDirectory() as tmp:
            previous_interval = voice_bridge.ORCHESTRATOR_HEARTBEAT_SECONDS
            previous_provider = os.environ.get("RELAY_RUNNER_PROVIDER")
            voice_bridge.ORCHESTRATOR_HEARTBEAT_SECONDS = 0.01
            os.environ["RELAY_RUNNER_PROVIDER"] = "claude"
            shutdown_event = threading.Event()
            event_log = Path(tmp) / "command-actions.jsonl"
            event_log.write_text(
                json.dumps({
                    "relay_command_seq": 6,
                    "relay_command_id": "failed-before-restart",
                    "source_text": "private failed request",
                    "repo_path": tmp,
                    "state": "queued",
                })
                + "\n"
                + json.dumps({
                    "relay_command_seq": 6,
                    "relay_command_id": "failed-before-restart",
                    "state": "delivery_failed",
                })
                + "\n"
            )
            try:
                session = voice_bridge.start_persistent_orchestrator_lifecycle(
                    {
                        "general": {
                            "provider": "codex",
                            "model": "sonnet",
                            "orchestrator_effort": "xhigh",
                        }
                    },
                    shutdown_event,
                    cwd=tmp,
                    event_log_path=str(event_log),
                    request_json=fake_request,
                )
                time.sleep(0.04)
                shutdown_event.set()
                voice_bridge.stop_persistent_orchestrator_lifecycle(
                    session,
                    reason="bridge stopped",
                    request_json=fake_request,
                )
            finally:
                voice_bridge.ORCHESTRATOR_HEARTBEAT_SECONDS = previous_interval
                if previous_provider is None:
                    os.environ.pop("RELAY_RUNNER_PROVIDER", None)
                else:
                    os.environ["RELAY_RUNNER_PROVIDER"] = previous_provider

        self.assertEqual(requests[0][0], "/v1/orchestrator-session/ensure")
        self.assertEqual(requests[0][1]["provider"], "claude")
        self.assertEqual(requests[0][1]["state"], "idle")
        self.assertEqual(
            requests[0][1]["command_action_states"][0]["state"],
            "delivery_failed",
        )
        self.assertEqual(
            requests[0][1]["command_action_states"][0]["source_text"],
            "private failed request",
        )
        self.assertTrue(any(path == "/v1/orchestrator-session/heartbeat" for path, _ in requests))
        self.assertEqual(requests[-1][0], "/v1/orchestrator-session/stop")
        self.assertEqual(requests[-1][1]["reason"], "bridge stopped")

    def test_orchestrator_command_store_keeps_raw_text_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = OrchestratorCommandStore(Path(tmp) / "commands.db")

            public = store.record(
                repo_path=tmp,
                source_text="fix login with private transcript details",
                relay_command_seq=4,
                relay_command_id="cmd-4",
                session_id=7,
                provider_key="claude",
                action="create_ticket",
                outcome="project work needs refined ticket",
                received_at=123.0,
            )

            self.assertNotIn("source_text", public)
            self.assertEqual(public["relay_command_seq"], 4)
            self.assertEqual(public["relay_command_id"], "cmd-4")
            self.assertEqual(public["provider_key"], "claude")
            private = store.get_private("cmd-4")
            self.assertIsNotNone(private)
            self.assertEqual(
                private["source_text"],
                "fix login with private transcript details",
            )

    def test_orchestrator_command_store_migrates_v1_without_losing_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "commands.db"
            with sqlite3.connect(db_path) as conn:
                conn.executescript(
                    """
                    CREATE TABLE orchestrator_commands (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        relay_command_id TEXT NOT NULL UNIQUE,
                        relay_command_seq INTEGER NOT NULL,
                        session_id INTEGER,
                        repo_path TEXT NOT NULL,
                        provider_key TEXT,
                        source_text TEXT NOT NULL,
                        action TEXT,
                        outcome TEXT,
                        status TEXT NOT NULL,
                        received_at REAL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE INDEX idx_orchestrator_commands_repo ON orchestrator_commands(repo_path);
                    CREATE INDEX idx_orchestrator_commands_status ON orchestrator_commands(status);
                    PRAGMA user_version = 1;
                    """
                )
                conn.execute(
                    "INSERT INTO orchestrator_commands("
                    "relay_command_id, relay_command_seq, repo_path, source_text, "
                    "action, outcome, status, created_at, updated_at"
                    ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        "cmd-1",
                        1,
                        tmp,
                        "preserve this private command",
                        "create_ticket",
                        "project work needs refined ticket",
                        "received",
                        10.0,
                        10.0,
                    ),
                )

            store = OrchestratorCommandStore(db_path)

            private = store.get_private("cmd-1")
            self.assertIsNotNone(private)
            self.assertEqual(private["source_text"], "preserve this private command")
            self.assertEqual(private["status"], "received")
            self.assertIn("ticket_id", private)
            self.assertIsNone(private["ticket_id"])
            with sqlite3.connect(db_path) as conn:
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 5)

    def test_orchestrator_command_store_migrates_v4_generation_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "commands.db"
            legacy_schema = OrchestratorCommandStore.SCHEMA.replace(
                "        recovery_generation TEXT NOT NULL DEFAULT '0',\n",
                "",
            )
            with sqlite3.connect(db_path) as conn:
                conn.executescript(legacy_schema)
                conn.execute("PRAGMA user_version = 4")

            store = OrchestratorCommandStore(db_path)
            public = store.record(
                repo_path=tmp,
                source_text="preserve generation",
                relay_command_seq=1,
                relay_command_id="cmd-generation",
                recovery_generation="12345678-1234-4abc-8def-1234567890ab",
            )

            self.assertEqual(
                public["recovery_generation"],
                "12345678-1234-4abc-8def-1234567890ab",
            )
            with sqlite3.connect(db_path) as conn:
                self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 5)

    def test_orchestrator_command_store_preserves_two_items_from_one_turn(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                store = OrchestratorCommandStore(Path(tmp) / "commands.db")
                for order, target in ((2, "search"), (1, "login")):
                    store.record(
                        repo_path=tmp,
                        source_text=f"fix {target}",
                        relay_command_seq=7,
                        relay_command_id=f"{provider}-7",
                        intent_id=f"{provider}-7:item:{order}",
                        within_turn_order=order,
                        provider_key=provider,
                        target=target,
                        disposition="accepted",
                        status="queued",
                    )

                pending = store.recoverable(repo_path=tmp)

                self.assertEqual([item["target"] for item in pending], ["login", "search"])
                self.assertEqual([item["within_turn_order"] for item in pending], [1, 2])
                self.assertEqual(
                    {item["relay_command_id"] for item in pending},
                    {f"{provider}-7"},
                )

    def test_orchestrator_command_store_keeps_refined_context_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = OrchestratorCommandStore(Path(tmp) / "commands.db")

            public = store.record(
                repo_path=tmp,
                source_text="write the ticket from our discussion",
                context="Title: Fix review follow-through\nAcceptance criteria:\n- Awaiting review is visible",
                relay_command_seq=4,
                relay_command_id="cmd-4",
                provider_key="codex",
            )

            self.assertNotIn("source_text", public)
            self.assertNotIn("context", public)
            private = store.get_private("cmd-4")
            self.assertIn("Fix review follow-through", private["context"])

    def test_orchestrator_command_store_recovers_only_unfinished_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = OrchestratorCommandStore(Path(tmp) / "commands.db")
            for seq, status in enumerate(
                ("queued", "claimed", "mutation_authorized", "delivery_failed", "created"),
                start=1,
            ):
                command_id = f"cmd-{seq}"
                store.record(
                    repo_path=tmp,
                    source_text=f"private command {seq}",
                    relay_command_seq=seq,
                    relay_command_id=command_id,
                    action="create_ticket",
                    status=status,
                )

            recoverable = store.recoverable(repo_path=tmp)

            self.assertEqual(
                [command["status"] for command in recoverable],
                ["queued", "claimed", "mutation_authorized", "delivery_failed"],
            )
            self.assertTrue(all("source_text" not in command for command in recoverable))

    def test_deferred_workspace_command_requests_project_without_parent_ticket(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                workspace.mkdir()
                child = workspace / "child-repo"
                self.make_git_repo(child)
                state_path = root / "voice_command_state.json"
                command_id = f"{provider}-workspace"
                state_path.write_text(json.dumps({
                    "relay_command_seq": 11,
                    "relay_command_id": command_id,
                }))
                original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
                orchestrator.RELAY_COMMAND_STATE_FILE = state_path
                daemon = self.make_daemon(root, provider=provider)
                try:
                    result = daemon.record_orchestrator_command(
                        repo_path=str(workspace),
                        source_text="fix the login flow",
                        relay_command_seq=11,
                        relay_command_id=command_id,
                        provider=provider,
                        action="create_ticket",
                        status="queued",
                        defer_processing=True,
                    )
                finally:
                    orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

                command = result["orchestrator_command"]
                self.assertEqual(command["status"], "clarification_required")
                self.assertEqual(command["outcome"], "waiting-for-project-choice")
                self.assertIn("target project", command["status_message"])
                self.assertFalse((workspace / ".orchestrator").exists())
                self.assertFalse((child / ".orchestrator" / "RR-1.md").exists())

    def test_deferred_project_command_survives_session_restart_without_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            state_path = root / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 12,
                "relay_command_id": "queued-project",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = self.make_daemon(root, provider="codex")
            try:
                result = daemon.record_orchestrator_command(
                    repo_path=str(repo),
                    source_text="fix the login flow",
                    relay_command_seq=12,
                    relay_command_id="queued-project",
                    provider="codex",
                    action="create_ticket",
                    status="queued",
                    defer_processing=True,
                )
                restarted = daemon.ensure_orchestrator_session(
                    repo_path=str(repo),
                    provider="codex",
                    source="test-restart",
                )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            self.assertEqual(result["orchestrator_command"]["status"], "queued")
            self.assertFalse((repo / ".orchestrator" / "RR-1.md").exists())
            self.assertEqual(
                [command["relay_command_id"] for command in restarted["recoverable_commands"]],
                ["queued-project"],
            )
            self.assertNotIn("source_text", restarted["recoverable_commands"][0])

    def test_delivery_failed_journal_record_is_recovered_next_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            daemon = self.make_daemon(root, provider="claude")
            event_log = root / "command-actions.jsonl"
            event_log.write_text(
                json.dumps({
                    "relay_command_seq": 14,
                    "relay_command_id": "delivery-failed",
                    "repo_path": str(repo),
                    "provider": "claude",
                    "source_text": "fix the private delivery issue",
                    "action": "create_ticket",
                    "state": "queued",
                })
                + "\n"
                + json.dumps({
                    "relay_command_seq": 14,
                    "relay_command_id": "delivery-failed",
                    "state": "delivery_failed",
                })
                + "\n"
            )

            restarted = daemon.ensure_orchestrator_session(
                repo_path=str(repo),
                provider="claude",
                source="test-restart",
                command_action_states=voice_bridge._command_action_journal_snapshot(
                    event_log_path=str(event_log),
                    repo_path=repo,
                ),
            )

            self.assertEqual(
                [command["status"] for command in restarted["recoverable_commands"]],
                ["delivery_failed"],
            )
            recovered = restarted["recoverable_commands"][0]
            self.assertEqual(recovered["relay_command_id"], "delivery-failed")
            self.assertIn("Delivery failed", recovered["status_message"])
            self.assertNotIn("source_text", recovered)

    def test_superseded_journal_record_removes_queued_daemon_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            daemon = self.make_daemon(root, provider="codex")
            daemon.orchestrator_commands.record(
                repo_path=str(repo),
                source_text="fix the command that was replaced",
                relay_command_seq=15,
                relay_command_id="superseded-locally",
                provider_key="codex",
                action="create_ticket",
                status="queued",
            )
            event_log = root / "command-actions.jsonl"
            event_log.write_text(
                json.dumps({
                    "relay_command_seq": 15,
                    "relay_command_id": "superseded-locally",
                    "repo_path": str(repo),
                    "provider": "codex",
                    "state": "queued",
                })
                + "\n"
                + json.dumps({
                    "relay_command_seq": 15,
                    "relay_command_id": "superseded-locally",
                    "state": "superseded",
                })
                + "\n"
            )

            restarted = daemon.ensure_orchestrator_session(
                repo_path=str(repo),
                provider="codex",
                source="test-restart",
                command_action_states=voice_bridge._command_action_journal_snapshot(
                    event_log_path=str(event_log),
                    repo_path=repo,
                ),
            )

            self.assertEqual(restarted["recoverable_commands"], [])
            reconciled = daemon.orchestrator_commands.get_public("superseded-locally")
            self.assertEqual(reconciled["status"], "superseded")
            self.assertIn("will not be recovered", reconciled["status_message"])

    def test_daemon_rejects_stale_orchestrator_command_before_recording(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "second",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = object.__new__(Daemon)
            daemon.orchestrator_commands = OrchestratorCommandStore(Path(tmp) / "commands.db")
            try:
                with self.assertRaisesRegex(ValueError, "stale Relay command"):
                    Daemon.record_orchestrator_command(
                        daemon,
                        repo_path=tmp,
                        source_text="fix stale thing",
                        relay_command_seq=1,
                        relay_command_id="first",
                    )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            self.assertIsNone(daemon.orchestrator_commands.get_private("first"))

    def test_daemon_authors_received_command_without_raw_transcript_leakage(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                repo = root / "repo"
                self.make_git_repo(repo)
                (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
                state_path = root / "voice_command_state.json"
                state_path.write_text(json.dumps({
                    "relay_command_seq": 7,
                    "relay_command_id": f"{provider}-cmd",
                }))
                original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
                orchestrator.RELAY_COMMAND_STATE_FILE = state_path
                daemon = self.make_daemon(root, provider=provider)
                notifications: list[tuple[str, dict]] = []
                try:
                    with patch("orchestrator._notify_state", lambda state, **payload: notifications.append((state, payload))):
                        result = daemon.record_orchestrator_command(
                            repo_path=str(repo),
                            source_text="fix private login bug details",
                            relay_command_seq=7,
                            relay_command_id=f"{provider}-cmd",
                            provider=provider,
                        )
                finally:
                    orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

                command = result["orchestrator_command"]
                self.assertEqual(command["status"], "authored")
                self.assertEqual(command["ticket_id"], "RR-1")
                self.assertNotIn("source_text", command)
                ticket = read_ticket(repo / ".orchestrator/RR-1.md")
                self.assertEqual(ticket["_raw_fields"]["worker_model"], "balanced")
                self.assertEqual(ticket["_raw_fields"]["worker_effort"], "medium")
                self.assertIn("Codex uses model_reasoning_effort", ticket["_raw_fields"]["worker_provider_notes"])
                raw_ticket = (repo / ".orchestrator/RR-1.md").read_text()
                self.assertNotIn("fix private login bug details", raw_ticket)
                self.assertNotIn("source_text", raw_ticket)
                self.assertIn("Fix login bug", raw_ticket)
                self.assertEqual(notifications[-1][1]["status_event"]["phase"], "outcome")
                self.assertEqual(notifications[-1][1]["status_event"]["ticket_id"], "RR-1")
                self.assertNotIn("source_text", notifications[-1][1]["status_event"]["command"])

    def test_daemon_authors_generic_ticket_from_refined_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            state_path = root / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 8,
                "relay_command_id": "context-cmd",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = self.make_daemon(root, provider="codex")
            try:
                result = daemon.record_orchestrator_command(
                    repo_path=str(repo),
                    source_text="write ticket also orchestrator was meant review",
                    context=(
                        "Title: Fix review follow-through\n"
                        "Description: Completed worker runs that reach AwaitingReview should be obvious in PM status and board lanes.\n"
                        "source_text: do not include this private line\n"
                        "Acceptance criteria:\n"
                        "- Review-pending runs are not shown as untouched backlog work.\n"
                        "- Codex and Claude users see equivalent review next-step status."
                    ),
                    relay_command_seq=8,
                    relay_command_id="context-cmd",
                    provider="codex",
                )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            self.assertEqual(result["orchestrator_command"]["status"], "authored")
            raw_ticket = (repo / ".orchestrator/RR-1.md").read_text()
            self.assertIn("title: Fix review follow-through", raw_ticket)
            self.assertIn("Review-pending runs are not shown", raw_ticket)
            self.assertIn("Codex and Claude users", raw_ticket)
            self.assertNotIn("write ticket also orchestrator", raw_ticket)
            self.assertNotIn("source_text", raw_ticket)

    def test_daemon_blocks_generic_ticket_without_refined_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            state_path = root / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 9,
                "relay_command_id": "generic-cmd",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = self.make_daemon(root, provider="claude")
            try:
                result = daemon.record_orchestrator_command(
                    repo_path=str(repo),
                    source_text="write ticket also orchestrator was meant review",
                    relay_command_seq=9,
                    relay_command_id="generic-cmd",
                    provider="claude",
                )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            command = result["orchestrator_command"]
            self.assertEqual(command["status"], "blocked")
            self.assertIn("Blocked while authoring a ticket", command["status_message"])
            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())

    def test_daemon_marks_non_work_orchestrator_command_handled_without_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            state_path = root / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 10,
                "relay_command_id": "conversation-cmd",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = self.make_daemon(root, provider="codex")
            try:
                result = daemon.record_orchestrator_command(
                    repo_path=str(repo),
                    source_text="why is the board not being updated",
                    relay_command_seq=10,
                    relay_command_id="conversation-cmd",
                    provider="codex",
                )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            command = result["orchestrator_command"]
            self.assertEqual(command["status"], "handled")
            self.assertEqual(command["outcome"], "non-work-command")
            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())

    def test_daemon_marks_received_command_stale_before_ticket_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
            state_path = root / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "newer",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = self.make_daemon(root, provider="codex")
            daemon.orchestrator_commands.record(
                repo_path=str(repo),
                source_text="fix login bug",
                relay_command_seq=1,
                relay_command_id="older",
                provider_key="codex",
            )
            try:
                result = daemon.process_orchestrator_commands(repo_path=str(repo))
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            self.assertEqual(result["processed"][0]["status"], "stale")
            self.assertFalse((repo / ".orchestrator/RR-1.md").exists())

    def test_daemon_dispatches_existing_ticket_from_received_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            self.make_git_repo(repo)
            self.write_ticket(repo, "RR-7")
            self.git(repo, "add", ".orchestrator/RR-7.md")
            self.git(repo, "commit", "-m", "add ticket")
            state_path = root / "voice_command_state.json"
            state_path.write_text(json.dumps({
                "relay_command_seq": 3,
                "relay_command_id": "dispatch",
            }))
            original_state_path = orchestrator.RELAY_COMMAND_STATE_FILE
            orchestrator.RELAY_COMMAND_STATE_FILE = state_path
            daemon = self.make_daemon(root, provider="codex")
            try:
                with patch("orchestrator.create_worktree") as create_worktree, \
                        patch.object(orchestrator.Worker, "start") as start_worker:
                    result = daemon.record_orchestrator_command(
                        repo_path=str(repo),
                        source_text="dispatch RR-7",
                        relay_command_seq=3,
                        relay_command_id="dispatch",
                        provider="codex",
                    )
            finally:
                orchestrator.RELAY_COMMAND_STATE_FILE = original_state_path

            create_worktree.assert_called_once()
            start_worker.assert_called_once()
            command = result["orchestrator_command"]
            self.assertEqual(command["status"], "authored")
            self.assertEqual(command["ticket_id"], "RR-7")
            self.assertEqual(command["outcome"], "dispatch-started")

    def make_git_repo(self, repo: Path) -> None:
        (repo / ".orchestrator").mkdir(parents=True)
        self.git(repo, "init")
        self.git(repo, "config", "user.email", "relay@example.test")
        self.git(repo, "config", "user.name", "Relay Test")
        (repo / ".orchestrator" / "config.toml").write_text('prefix = "RR"\nnext_id = 1\n')
        self.git(repo, "add", ".orchestrator/config.toml")
        self.git(repo, "commit", "-m", "add board config")

    def make_daemon(self, root: Path, *, provider: str) -> Daemon:
        daemon = object.__new__(Daemon)
        daemon.cfg = {}
        daemon.workspace_root = root / "workspaces"
        daemon.branch_prefix = "relay/"
        daemon.workflow_path = Path(ROOT) / "services" / "orchestrator_workflow.md"
        daemon.worker_health_check_seconds = 600
        daemon._run_health = {}
        daemon._run_health_lock = threading.Lock()
        daemon.agent_kind = provider
        daemon.agent_bin = provider
        daemon.runs = orchestrator.RunsStore(root / "runs.db")
        daemon.orchestrator_sessions = OrchestratorSessionStore(root / "sessions.db")
        daemon.orchestrator_commands = OrchestratorCommandStore(root / "commands.db")
        daemon.messenger_outcomes = MessengerOutcomeStore(root / "messenger_outcomes.db")
        daemon._dispatch_lock = threading.Lock()
        daemon._ticket_authoring_lock = threading.Lock()
        daemon._orchestrator_action_request_ids = set()
        daemon._workers = {}
        daemon._workers_lock = threading.Lock()
        return daemon

    def write_ticket(self, repo: Path, ticket_id: str) -> None:
        (repo / ".orchestrator" / f"{ticket_id}.md").write_text(
            f"""---
id: {ticket_id}
title: {ticket_id}
status: ready
priority: medium
depends_on: []
run_id: null
canceled: false
worker_model: balanced
worker_effort: medium
worker_sizing_rationale: "Dispatch test ticket."
worker_provider_notes: "Codex uses model_reasoning_effort; Claude uses --effort."
---

## Description

Test ticket.
"""
        )

    def git(self, repo: Path, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
