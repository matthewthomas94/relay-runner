from __future__ import annotations

import os
import queue
import sys
import tempfile
import threading
import types
import unittest
import json
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402


def claim_ready_command(path: str) -> str:
    claim = path + ".claim"
    os.rename(path, claim)
    try:
        with open(claim) as f:
            return f.read()
    finally:
        os.remove(claim)


class FakeTTSWorker:
    def __init__(self):
        self.calls: list[str] = []

    def stop_playback(self):
        self.calls.append("stop_playback")

    def skip(self):
        self.calls.append("skip")

    def play(self):
        self.calls.append("play")

    def replay(self):
        self.calls.append("replay")


class VoiceBridgePreemptionTests(unittest.TestCase):
    def setUp(self):
        voice_bridge._reset_public_trace_tts_state()

    def test_newer_command_suppresses_stale_tts_after_first_claimed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()

            voice_bridge._write_cmd_file("first request", path=command_path)
            self.assertEqual(claim_ready_command(command_path), "first request")

            voice_bridge._write_cmd_file("second request", path=command_path)

            queued = voice_bridge._queue_tts_text(
                "stale response to first request",
                tts_queue,
                command_path=command_path,
            )

            self.assertFalse(queued)
            self.assertTrue(tts_queue.empty())
            with open(command_path) as f:
                self.assertEqual(f.read(), "second request")

    def test_latest_command_wins_before_agent_claims_input(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")

            voice_bridge._write_cmd_file("first request", path=command_path)
            voice_bridge._write_cmd_file("second request", path=command_path)

            self.assertEqual(claim_ready_command(command_path), "second request")

    def test_single_message_tts_still_queues_without_pending_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()

            queued = voice_bridge._queue_tts_text(
                "**fresh** response",
                tts_queue,
                command_path=command_path,
            )

            self.assertTrue(queued)
            self.assertEqual(tts_queue.get_nowait(), "fresh response")

    def test_sequence_tagged_tts_drops_after_command_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()

            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "second",
            }))

            stale = json.dumps({
                "text": "stale response",
                "relay_command_seq": 1,
                "relay_command_id": "first",
            })
            fresh = json.dumps({
                "text": "**fresh** response",
                "relay_command_seq": 2,
                "relay_command_id": "second",
            })

            self.assertFalse(voice_bridge._queue_tts_text(
                stale,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))
            self.assertTrue(voice_bridge._queue_tts_text(
                fresh,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))
            self.assertEqual(tts_queue.get_nowait(), "fresh response")

    def test_voice_acknowledgement_replaces_stale_pending_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            notifications: list[tuple[str, dict]] = []

            first_meta = voice_bridge._begin_relay_command(
                "first request",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._publish_command(
                "first request",
                {**first_meta, "action": "non_work"},
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )

            second_meta = voice_bridge._begin_relay_command(
                "second request",
                state_path=state_path,
                event_log_path=None,
            )
            queued = voice_bridge._queue_voice_acknowledgement(
                second_meta,
                tts_queue,
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                source_text="second request",
                delay_seconds=0,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertTrue(queued)
            self.assertTrue(tts_queue.empty())
            self.assertEqual(notifications[0][0], "acknowledgement")
            self.assertNotIn("second request", notifications[0][1]["text"])
            self.assertTrue(notifications[0][1]["text"].strip())
            status_event = notifications[0][1]["status_event"]
            self.assertEqual(status_event["phase"], "acknowledged")
            self.assertEqual(status_event["source"], "pm")
            self.assertEqual(status_event["message"], notifications[0][1]["text"])
            self.assertEqual(
                status_event["command"]["relay_command_seq"],
                second_meta["relay_command_seq"],
            )
            self.assertEqual(
                status_event["command"]["relay_command_id"],
                second_meta["relay_command_id"],
            )
            self.assertNotIn("source_text", status_event["command"])
            self.assertFalse(os.path.exists(command_path))
            current = json.loads(Path(state_path).read_text())
            self.assertEqual(current["relay_command_seq"], second_meta["relay_command_seq"])

    def test_voice_acknowledgement_drops_after_command_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            notifications: list[tuple[str, dict]] = []

            first_meta = voice_bridge._begin_relay_command(
                "first request",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._begin_relay_command(
                "second request",
                state_path=state_path,
                event_log_path=None,
            )

            queued = voice_bridge._queue_voice_acknowledgement(
                first_meta,
                queue.Queue(),
                command_path=os.path.join(temp_dir, "voice_cmd_ready"),
                meta_path=os.path.join(temp_dir, "voice_cmd_ready.meta"),
                state_path=state_path,
                source_text="first request",
                delay_seconds=0,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertTrue(queued)
            self.assertEqual(notifications, [])

    def test_acknowledgement_copy_synthesizes_intent_without_echoing_transcript(self):
        acknowledgement = voice_bridge.build_voice_acknowledgement(
            "I want a quick synthesis and response from the agent for the acknowledgement",
            {"relay_command_seq": 1},
        )

        self.assertEqual(acknowledgement, "I'll take care of the acknowledgement issue.")
        self.assertNotIn("quick synthesis", acknowledgement)
        self.assertNotIn("response from the agent", acknowledgement)

    def test_acknowledgement_copy_uses_fast_generic_intent_response(self):
        acknowledgement = voice_bridge.build_voice_acknowledgement(
            "summarize project status",
            {"relay_command_seq": 2},
        )

        self.assertEqual(acknowledgement, "I'll check that.")

    def test_acknowledgement_copy_falls_back_for_sensitive_text(self):
        acknowledgement = voice_bridge.build_voice_acknowledgement(
            "use password hunter2 for the deployment",
            {"relay_command_seq": 3},
        )

        self.assertNotIn("hunter2", acknowledgement)
        self.assertNotIn("deployment", acknowledgement)

    def test_voice_acknowledgement_defaults_to_immediate_delivery(self):
        self.assertEqual(voice_bridge.VOICE_ACKNOWLEDGEMENT_DELAY_SECONDS, 0.0)

    def test_pm_planning_status_event_uses_public_contract(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7 to a worker",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []

            voice_bridge._notify_pm_planning(
                relay_command,
                source_text="dispatch RR-7 to a worker",
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertEqual(notifications[0][0], "working")
            self.assertEqual(
                notifications[0][1]["text"],
                "Checking the project and choosing the route.",
            )
            status_event = notifications[0][1]["status_event"]
            self.assertEqual(status_event["phase"], "planning")
            self.assertEqual(status_event["source"], "orchestrator")
            self.assertEqual(status_event["message"], notifications[0][1]["text"])
            self.assertEqual(
                status_event["command"]["relay_command_id"],
                relay_command["relay_command_id"],
            )
            self.assertNotIn("source_text", status_event["command"])

    def test_public_trace_acknowledgement_speaks_first_safe_status_event(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            payload = voice_bridge._orchestration_trace_payload(
                kind="dispatch-started",
                relay_command=relay_command,
                ticket_id="RR-7",
            )

            queued = voice_bridge._queue_public_trace_acknowledgement(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0,
            )

            self.assertTrue(queued)
            self.assertEqual(tts_queue.get_nowait(), "Dispatching RR-7")

    def test_public_trace_acknowledgement_waits_for_command_claim(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            Path(command_path).write_text("action: dispatch_ticket")
            payload = voice_bridge._orchestration_trace_payload(
                kind="dispatch-started",
                relay_command=relay_command,
                ticket_id="RR-7",
            )

            voice_bridge._queue_public_trace_acknowledgement(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0,
                max_wait_seconds=0.5,
            )
            self.assertTrue(tts_queue.empty())
            os.remove(command_path)
            for _ in range(20):
                if not tts_queue.empty():
                    break
                threading.Event().wait(0.02)

            self.assertEqual(tts_queue.get_nowait(), "Dispatching RR-7")

    def test_public_trace_acknowledgement_drops_after_command_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            first = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._begin_relay_command(
                "newer command",
                state_path=state_path,
                event_log_path=None,
            )
            payload = voice_bridge._orchestration_trace_payload(
                kind="dispatch-started",
                relay_command=first,
                ticket_id="RR-7",
            )

            voice_bridge._queue_public_trace_acknowledgement(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0,
            )

            self.assertTrue(tts_queue.empty())

    def test_public_trace_acknowledgement_does_not_replace_final_tts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            payload = voice_bridge._orchestration_trace_payload(
                kind="dispatch-started",
                relay_command=relay_command,
                ticket_id="RR-7",
            )

            voice_bridge._queue_public_trace_acknowledgement(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0,
            )
            final_payload = json.dumps({
                "text": "Dispatched RR-7 to a worker.",
                "relay_command_seq": relay_command["relay_command_seq"],
                "relay_command_id": relay_command["relay_command_id"],
            })
            self.assertTrue(voice_bridge._queue_tts_text(
                final_payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))

            self.assertEqual(tts_queue.get_nowait(), "Dispatching RR-7")
            self.assertEqual(tts_queue.get_nowait(), "Dispatched RR-7 to a worker.")

    def test_public_trace_acknowledgement_skips_when_final_tts_arrives_quickly(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            payload = voice_bridge._orchestration_trace_payload(
                kind="dispatch-started",
                relay_command=relay_command,
                ticket_id="RR-7",
            )

            voice_bridge._queue_public_trace_acknowledgement(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0.05,
            )
            final_payload = json.dumps({
                "text": "Dispatched RR-7 to a worker.",
                "relay_command_seq": relay_command["relay_command_seq"],
                "relay_command_id": relay_command["relay_command_id"],
            })
            self.assertTrue(voice_bridge._queue_tts_text(
                final_payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))
            threading.Event().wait(0.1)

            self.assertEqual(tts_queue.get_nowait(), "Dispatched RR-7 to a worker.")
            self.assertTrue(tts_queue.empty())

    def test_public_trace_acknowledgement_suppresses_duplicate_final_tts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            payload = voice_bridge._orchestration_trace_payload(
                kind="dispatch-started",
                relay_command=relay_command,
                ticket_id="RR-7",
            )

            voice_bridge._queue_public_trace_acknowledgement(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0,
            )
            duplicate_payload = json.dumps({
                "text": "Dispatching RR-7",
                "relay_command_seq": relay_command["relay_command_seq"],
                "relay_command_id": relay_command["relay_command_id"],
            })

            self.assertFalse(voice_bridge._queue_tts_text(
                duplicate_payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))
            self.assertEqual(tts_queue.get_nowait(), "Dispatching RR-7")
            self.assertTrue(tts_queue.empty())

    def test_public_trace_acknowledgement_rejects_unsafe_trace_copy(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            unsafe_payload = {
                "status_event": {
                    "phase": "planning",
                    "message": "Running git status && cat secret.txt",
                    "source": "orchestrator",
                    "command": {
                        "relay_command_seq": relay_command["relay_command_seq"],
                        "relay_command_id": relay_command["relay_command_id"],
                    },
                }
            }

            queued = voice_bridge._queue_public_trace_acknowledgement(
                unsafe_payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                delay_seconds=0,
            )

            self.assertFalse(queued)
            self.assertTrue(tts_queue.empty())

    def test_persistent_orchestrator_heartbeat_uses_dynamic_update_state(self):
        requests: list[tuple[str, dict]] = []

        def fake_request(path: str, payload: dict) -> dict:
            requests.append((path, payload))
            if path == "/v1/orchestrator-session/ensure":
                return {"orchestrator_session": {"id": 7}}
            return {"orchestrator_session": {"id": payload["session_id"]}}

        previous_interval = voice_bridge.ORCHESTRATOR_HEARTBEAT_SECONDS
        voice_bridge.ORCHESTRATOR_HEARTBEAT_SECONDS = 0.01
        shutdown_event = threading.Event()
        try:
            session = voice_bridge.start_persistent_orchestrator_lifecycle(
                {"general": {"provider": "codex"}},
                shutdown_event,
                cwd="/tmp/repo",
                request_json=fake_request,
            )
            voice_bridge._set_orchestrator_session_state(session, "awaiting_workers")
            for _ in range(20):
                if any(
                    path == "/v1/orchestrator-session/heartbeat"
                    and payload.get("state") == "awaiting_workers"
                    for path, payload in requests
                ):
                    break
                shutdown_event.wait(0.01)
            voice_bridge.stop_persistent_orchestrator_lifecycle(
                session,
                reason="test done",
                request_json=fake_request,
            )
        finally:
            voice_bridge.ORCHESTRATOR_HEARTBEAT_SECONDS = previous_interval

        self.assertTrue(any(
            path == "/v1/orchestrator-session/heartbeat"
            and payload.get("state") == "awaiting_workers"
            for path, payload in requests
        ))

    def test_pm_update_mode_emits_safe_status_and_stops_when_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []
            action = voice_bridge.resolve_command_action(
                "dispatch RR-7",
                repo_path=temp_dir,
                relay_command=relay_command,
            )

            def fake_get(path: str, params: dict | None = None) -> dict:
                if path == "/v1/orchestrator-sessions":
                    return {
                        "orchestrator_sessions": [
                            {
                                "id": 7,
                                "repo_path": temp_dir,
                                "provider_key": "codex",
                                "state": "awaiting_workers",
                            }
                        ]
                    }
                if path == "/v1/runs":
                    return {
                        "runs": [
                            {
                                "id": 51,
                                "repo_path": temp_dir,
                                "ticket_id": "RR-7",
                                "state": "Running",
                                "activity": "Reading source files",
                                "provider_key": "codex",
                            }
                        ]
                    }
                self.assertEqual(path, "/v1/program/status")
                self.assertEqual(params["query"], "summary")
                return {
                    "items": [
                        {
                            "project": {"path": temp_dir},
                            "open_tickets": 1,
                            "blocked": 0,
                            "awaiting_merge": 0,
                            "stale_runs": 0,
                        }
                    ]
                }

            previous_poll = voice_bridge.PM_UPDATE_POLL_SECONDS
            voice_bridge.PM_UPDATE_POLL_SECONDS = 0.01
            try:
                thread = voice_bridge._start_pm_update_mode(
                    relay_command,
                    action,
                    orchestrator_session={
                        "session_id": 7,
                        "repo_path": temp_dir,
                        "provider": "codex",
                        "state": {"value": "idle"},
                        "state_lock": threading.Lock(),
                    },
                    source_text="dispatch RR-7",
                    state_path=state_path,
                    notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
                    request_get_json=fake_get,
                )

                for _ in range(40):
                    if notifications:
                        break
                    thread.join(timeout=0.01)
                self.assertTrue(notifications)
                self.assertEqual(notifications[0][0], "working")
                self.assertEqual(notifications[0][1]["text"], "RR-7 run 51: Reading source files")
                self.assertNotIn("source_text", notifications[0][1]["status_event"]["command"])

                Path(state_path).write_text(json.dumps({
                    "relay_command_seq": relay_command["relay_command_seq"] + 1,
                    "relay_command_id": "newer",
                }))
                thread.join(timeout=0.5)
                self.assertFalse(thread.is_alive())
            finally:
                voice_bridge.PM_UPDATE_POLL_SECONDS = previous_poll

    def test_raw_instruction_fanout_sends_same_private_command_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir) / "repo"
            repo.mkdir()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            requests: list[tuple[str, dict]] = []
            relay_command = voice_bridge._begin_relay_command(
                "fix private login bug details",
                state_path=state_path,
                event_log_path=None,
            )
            relay_command["context"] = (
                "Title: Fix login retries\n"
                "source_text: raw private utterance\n"
                "Acceptance criteria:\n"
                "- Retry errors are visible to users"
            )
            action = voice_bridge.resolve_command_action(
                "fix private login bug details",
                repo_path=repo,
                relay_command=relay_command,
            )

            delivered = voice_bridge._deliver_raw_instruction_to_orchestrator(
                "fix private login bug details",
                relay_command,
                action,
                repo_path=repo,
                orchestrator_session={"session_id": 7, "repo_path": str(repo)},
                state_path=state_path,
                request_json=lambda path, payload: requests.append((path, payload)) or {},
            )

            self.assertTrue(delivered)
            self.assertEqual(requests[0][0], "/v1/orchestrator-session/command")
            payload = requests[0][1]
            self.assertEqual(payload["source_text"], "fix private login bug details")
            self.assertEqual(payload["relay_command_seq"], relay_command["relay_command_seq"])
            self.assertEqual(payload["relay_command_id"], relay_command["relay_command_id"])
            self.assertEqual(payload["session_id"], 7)
            self.assertEqual(payload["action"], "create_ticket")
            self.assertEqual(payload["repo_path"], str(repo.resolve()))
            self.assertIn("Fix login retries", payload["context"])
            self.assertIn("Retry errors are visible", payload["context"])
            self.assertNotIn("source_text", payload["context"])

    def test_raw_instruction_fanout_rejects_stale_command_before_post(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            requests: list[tuple[str, dict]] = []
            first = voice_bridge._begin_relay_command(
                "fix first thing",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._begin_relay_command(
                "fix second thing",
                state_path=state_path,
                event_log_path=None,
            )
            action = voice_bridge.resolve_command_action(
                "fix first thing",
                repo_path=temp_dir,
                relay_command=first,
            )

            delivered = voice_bridge._deliver_raw_instruction_to_orchestrator(
                "fix first thing",
                first,
                action,
                repo_path=temp_dir,
                state_path=state_path,
                request_json=lambda path, payload: requests.append((path, payload)) or {},
            )

            self.assertFalse(delivered)
            self.assertEqual(requests, [])

    def test_orchestration_trace_emits_public_notch_payload(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            relay_command = voice_bridge._begin_relay_command(
                "create a ticket with private transcript details",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []

            emitted = voice_bridge.emit_orchestration_trace(
                kind="ticket-created",
                relay_command=relay_command,
                source_text="create a ticket with private transcript details",
                ticket_id="RR-9",
                state_path=state_path,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertTrue(emitted)
            self.assertEqual(notifications[0][0], "working")
            self.assertEqual(notifications[0][1]["text"], "Created ticket RR-9")
            trace_event = notifications[0][1]["trace_event"]
            self.assertEqual(trace_event["kind"], "ticket-created")
            self.assertEqual(trace_event["ticket_id"], "RR-9")
            self.assertEqual(trace_event["message"], notifications[0][1]["text"])
            self.assertNotIn("source_text", trace_event["command"])
            status_event = notifications[0][1]["status_event"]
            self.assertEqual(status_event["phase"], "planning")
            self.assertEqual(status_event["message"], notifications[0][1]["text"])

    def test_orchestration_trace_drops_after_command_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            first = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._begin_relay_command(
                "newer command",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []

            emitted = voice_bridge.emit_orchestration_trace(
                kind="dispatch-started",
                relay_command=first,
                ticket_id="RR-7",
                state_path=state_path,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertFalse(emitted)
            self.assertEqual(notifications, [])

    def test_build_bundle_includes_pm_frontstage_service(self):
        script_path = os.path.join(ROOT, "scripts", "build-dmg.sh")
        with open(script_path) as f:
            script = f.read()

        self.assertIn("pm_frontstage.py", script)

    def test_tts_dismissal_does_not_supersede_claimed_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            worker = FakeTTSWorker()

            relay_command = voice_bridge._begin_relay_command(
                "fix the login bug",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._publish_command(
                "action: create_ticket",
                {**relay_command, "action": "create_ticket"},
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )
            self.assertEqual(claim_ready_command(command_path), "action: create_ticket")
            os.remove(meta_path)
            state_before_dismissal = json.loads(Path(state_path).read_text())

            handled = voice_bridge._handle_relay_control_message(
                "__CANCEL__",
                worker,
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                event_log_path=None,
            )

            self.assertTrue(handled)
            self.assertEqual(worker.calls, ["skip"])
            self.assertFalse(os.path.exists(command_path))
            self.assertFalse(os.path.exists(meta_path))
            self.assertEqual(json.loads(Path(state_path).read_text()), state_before_dismissal)

    def test_explicit_interrupt_still_supersedes_claimed_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            worker = FakeTTSWorker()

            relay_command = voice_bridge._begin_relay_command(
                "fix the login bug",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._publish_command(
                "action: create_ticket",
                {**relay_command, "action": "create_ticket"},
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )
            self.assertEqual(claim_ready_command(command_path), "action: create_ticket")
            os.remove(meta_path)

            handled = voice_bridge._handle_relay_control_message(
                "__INTERRUPT__",
                worker,
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                event_log_path=None,
            )

            self.assertTrue(handled)
            self.assertEqual(worker.calls, ["stop_playback"])
            self.assertEqual(claim_ready_command(command_path), "__INTERRUPT__")
            current = json.loads(Path(state_path).read_text())
            self.assertEqual(current["source_text"], "__INTERRUPT__")
            self.assertEqual(current["relay_command_seq"], relay_command["relay_command_seq"] + 1)

    def test_newer_pending_project_work_does_not_create_visible_tickets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir) / "repo"
            orch = repo / ".orchestrator"
            orch.mkdir(parents=True)
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            event_path = os.path.join(temp_dir, "voice_command_events.jsonl")

            first_meta = voice_bridge._begin_relay_command(
                "fix the login bug",
                state_path,
                event_log_path=event_path,
            )
            first_action = voice_bridge.resolve_command_action(
                "fix the login bug",
                repo_path=repo,
                relay_command=first_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(first_action),
                voice_bridge._metadata_for_action(first_action, first_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )

            self.assertFalse((orch / "RR-3.md").exists())
            self.assertEqual((orch / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 3\n')

            second_meta = voice_bridge._begin_relay_command(
                "fix the signup bug",
                state_path,
                event_log_path=event_path,
            )
            second_action = voice_bridge.resolve_command_action(
                "fix the signup bug",
                repo_path=repo,
                relay_command=second_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(second_action),
                voice_bridge._metadata_for_action(second_action, second_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )

            self.assertFalse((orch / "RR-3.md").exists())
            self.assertFalse((orch / "RR-4.md").exists())
            self.assertEqual((orch / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 3\n')
            with open(command_path) as f:
                command = f.read()
            self.assertIn("ticket_id: null", command)
            self.assertIn("Create or refine a visible ticket now", command)
            meta = json.loads(Path(meta_path).read_text())
            self.assertNotIn("ticket_id", meta)
            self.assertEqual(meta["action"], "create_ticket")
            self.assertEqual(meta["relay_command_seq"], 2)
            events = [json.loads(line) for line in Path(event_path).read_text().splitlines()]
            self.assertEqual([event["source_text"] for event in events], [
                "fix the login bug",
                "fix the signup bug",
            ])

    def test_private_command_event_log_is_bounded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            event_path = os.path.join(temp_dir, "voice_command_events.jsonl")

            for idx in range(4):
                voice_bridge._record_private_command_capture(
                    {
                        "relay_command_seq": idx + 1,
                        "relay_command_id": f"cmd-{idx + 1}",
                        "received_at": float(idx),
                        "source_text": f"command {idx + 1}",
                        "action": "received",
                    },
                    event_log_path=event_path,
                    limit=2,
                )

            events = [json.loads(line) for line in Path(event_path).read_text().splitlines()]
            self.assertEqual([event["relay_command_seq"] for event in events], [3, 4])

    def test_generated_provider_skills_share_preemption_contract(self):
        script_path = os.path.join(ROOT, "scripts", "relay-bridge")
        with open(script_path) as f:
            script = f.read()

        self.assertEqual(
            script.count("Codex and Claude use the same cooperative preemption contract"),
            2,
        )
        self.assertEqual(
            script.count("Run the preemption checkpoint immediately before"),
            2,
        )
        self.assertEqual(
            script.count("Codex and Claude follow the same command-action contract"),
            2,
        )
        self.assertGreaterEqual(
            script.count("cmd_tmp=$(mktemp /tmp/voice_cmd_claim.XXXXXX) || exit 1"),
            4,
        )
        self.assertGreaterEqual(
            script.count("voice_cmd_claimed.json"),
            8,
        )
        self.assertGreaterEqual(
            script.count("voice_bridge_stop_requested"),
            10,
        )
        self.assertEqual(
            script.count("if [ -f /tmp/voice_bridge_stop_requested ]; then"),
            6,
        )

    def test_generated_provider_skills_preserve_bridge_context_after_response(self):
        script_path = os.path.join(ROOT, "scripts", "relay-bridge")
        with open(script_path) as f:
            script = f.read()

        claude_cleanup = script[
            script.index("After generating your response, tear down the background heartbeat refresher"):
            script.index("Then send the TTS response with the claimed Relay command metadata.")
        ]
        codex_cleanup = script[
            script.index("After your response, stop the heartbeat refresher"):
            script.index("Write only the spoken summary to TTS, tagged with the claimed Relay command metadata.")
        ]

        for cleanup in [claude_cleanup, codex_cleanup]:
            self.assertIn("preserving session metadata for app watchdog recovery", cleanup)
            self.assertIn("cat /tmp/voice_bridge.cwd", cleanup)
            self.assertIn("cat /tmp/voice_bridge.provider", cleanup)
            self.assertNotIn("rm -f /tmp/voice_in.fifo", cleanup)
            self.assertNotIn("voice_bridge.cwd /tmp/voice_bridge.provider", cleanup)
            self.assertNotIn("launchctl remove com.relay.voicebridge", cleanup)
            self.assertNotIn("VOICE_BRIDGE_LOG_REASON=restart", cleanup)

        self.assertEqual(script.count("os.O_WRONLY | os.O_NONBLOCK"), 2)
        self.assertNotIn("python3 - <<'PY' > /tmp/tts_in.fifo", script)


if __name__ == "__main__":
    unittest.main()
