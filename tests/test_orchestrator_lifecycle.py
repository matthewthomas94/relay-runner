from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import orchestrator  # noqa: E402
import voice_bridge  # noqa: E402
from orchestrator import Daemon, OrchestratorCommandStore, OrchestratorSessionStore  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
