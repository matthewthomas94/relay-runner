from __future__ import annotations

import os
import io
import queue
import sys
import tempfile
import threading
import time
import types
import unittest
import json
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402
import relay_completion_hook  # noqa: E402


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
        self.input_queue: queue.Queue = queue.Queue()

    def stop_playback(self):
        self.calls.append("stop_playback")

    def skip(self):
        self.calls.append("skip")

    def play(self):
        self.calls.append("play")

    def replay(self):
        self.calls.append("replay")


class FakeMessenger:
    def __init__(self):
        self.users: list[tuple[str, dict]] = []
        self.traces: list[dict] = []
        self.finals: list[dict] = []
        self.interrupt_count = 0

    def submit_user(self, text: str, command: dict) -> bool:
        self.users.append((text, command))
        return True

    def submit_trace(self, trace: dict) -> bool:
        self.traces.append(trace)
        return True

    def submit_final(self, payload: dict) -> bool:
        self.finals.append(payload)
        return True

    def interrupt(self):
        self.interrupt_count += 1


class RejectingMessenger(FakeMessenger):
    def submit_final(self, payload: dict) -> bool:
        self.finals.append(payload)
        return False


class RejectingTraceMessenger(FakeMessenger):
    def submit_trace(self, trace: dict) -> bool:
        self.traces.append(trace)
        return False


class VoiceBridgePreemptionTests(unittest.TestCase):
    def test_relay_startup_queues_greeting_once(self):
        worker = FakeTTSWorker()
        shutdown_event = threading.Event()

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=None),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_queue_tts_text", return_value=True) as queue_tts,
        ):
            voice_bridge._run_relay(worker, shutdown_event)

        queue_tts.assert_called_once_with(
            voice_bridge.STARTUP_GREETING,
            worker.input_queue,
            allow_pending_command=True,
        )

    def test_relay_startup_skips_greeting_when_tutorial_suppresses_it(self):
        worker = FakeTTSWorker()
        shutdown_event = threading.Event()

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=None),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_queue_tts_text") as queue_tts,
        ):
            voice_bridge._run_relay(
                worker,
                shutdown_event,
                suppress_startup_greeting=True,
            )

        queue_tts.assert_not_called()

    def test_parse_args_recognizes_tutorial_startup_greeting_suppression(self):
        with mock.patch.object(
            sys,
            "argv",
            ["voice_bridge.py", "--relay", "--suppress-startup-greeting"],
        ):
            cli = voice_bridge._parse_args()

        self.assertTrue(cli["relay"])
        self.assertTrue(cli["suppress_startup_greeting"])

    def test_tutorial_session_suppresses_only_first_fast_messenger_reply(self):
        worker = FakeTTSWorker()
        messenger = FakeMessenger()
        shutdown_event = threading.Event()
        action = types.SimpleNamespace(kind="non_work", outcome="normal conversation")

        def read_once(_fd, _size):
            shutdown_event.set()
            return b"Hello.\nWhat is next?\n"

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge.os, "read", side_effect=read_once),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_begin_relay_command", side_effect=[
                {
                    "relay_command_seq": 1,
                    "relay_command_id": "tutorial-1",
                },
                {
                    "relay_command_seq": 2,
                    "relay_command_id": "normal-2",
                },
            ]),
            mock.patch.object(voice_bridge, "resolve_command_action", return_value=action),
            mock.patch.object(voice_bridge, "format_command_for_agent", return_value="Hello."),
            mock.patch.object(voice_bridge, "_metadata_for_action", return_value={
                "relay_command_seq": 1,
                "relay_command_id": "tutorial-1",
                "action": "conversation",
            }),
            mock.patch.object(
                voice_bridge,
                "_should_fanout_raw_instruction_to_orchestrator",
                return_value=False,
            ),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement", return_value=True),
            mock.patch.object(voice_bridge, "_start_pm_update_mode"),
            mock.patch.object(voice_bridge, "_publish_command") as publish_command,
        ):
            voice_bridge._run_relay(
                worker,
                shutdown_event,
                messenger=messenger,
                suppress_startup_greeting=True,
            )

        self.assertEqual(
            messenger.users,
            [(
                "What is next?",
                {
                    "relay_command_seq": 2,
                    "relay_command_id": "normal-2",
                },
            )],
        )
        self.assertEqual(publish_command.call_count, 2)

    def test_voice_command_publication_does_not_arm_missing_final_fallback(self):
        worker = FakeTTSWorker()
        shutdown_event = threading.Event()
        action = types.SimpleNamespace(kind="non_work", outcome="foreground command")

        def read_once(_fd, _size):
            shutdown_event.set()
            return b"summarize status\n"

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge.os, "read", side_effect=read_once),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_queue_tts_text", return_value=True),
            mock.patch.object(voice_bridge, "_begin_relay_command", return_value={
                "relay_command_seq": 1,
                "relay_command_id": "cmd-1",
            }),
            mock.patch.object(voice_bridge, "resolve_command_action", return_value=action),
            mock.patch.object(voice_bridge, "format_command_for_agent", return_value="agent prompt"),
            mock.patch.object(voice_bridge, "_metadata_for_action", return_value={
                "relay_command_seq": 1,
                "relay_command_id": "cmd-1",
                "action": "non_work",
            }),
            mock.patch.object(voice_bridge, "_should_fanout_raw_instruction_to_orchestrator", return_value=False),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement", return_value=True),
            mock.patch.object(voice_bridge, "_start_pm_update_mode"),
            mock.patch.object(voice_bridge, "_publish_command") as publish_command,
            mock.patch.object(voice_bridge, "_schedule_foreground_reply_fallback") as schedule_fallback,
        ):
            voice_bridge._run_relay(worker, shutdown_event, messenger=FakeMessenger())

        publish_command.assert_called_once()
        schedule_fallback.assert_not_called()

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

    def test_tts_queue_publishes_waiting_preview_before_collection(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()
            previews: list[tuple[str, bool]] = []

            queued = voice_bridge._queue_tts_text(
                "**fresh** response",
                tts_queue,
                command_path=command_path,
                notify_waiting_preview=lambda text: previews.append((text, tts_queue.empty())),
            )

            self.assertTrue(queued)
            self.assertEqual(previews, [("fresh response", True)])
            self.assertEqual(tts_queue.get_nowait(), "fresh response")

    def test_tts_queue_uses_authoritative_display_text_separate_from_spoken_text(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()
            previews: list[str] = []

            queued = voice_bridge._queue_tts_text(
                json.dumps({
                    "text": "Short messenger wording.",
                    "display_text": "Authoritative **provider** result.\nIncludes `code`.",
                }),
                tts_queue,
                command_path=command_path,
                notify_waiting_preview=lambda text: previews.append(text),
            )

            self.assertTrue(queued)
            self.assertEqual(
                previews,
                ["Authoritative **provider** result. Includes `code`."],
            )
            self.assertEqual(
                tts_queue.get_nowait(),
                {
                    "text": "Short messenger wording.",
                    "display_text": "Authoritative **provider** result. Includes `code`.",
                },
            )

    def test_sequence_tagged_tts_drops_after_command_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            previews: list[str] = []

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
                notify_waiting_preview=lambda text: previews.append(text),
            ))
            self.assertTrue(voice_bridge._queue_tts_text(
                fresh,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                notify_waiting_preview=lambda text: previews.append(text),
            ))
            self.assertEqual(tts_queue.get_nowait(), "fresh response")
            self.assertEqual(previews, ["fresh response"])

    def test_stale_authoritative_payload_does_not_publish_preview_or_queue_tts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            previews: list[str] = []

            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "second",
            }))

            stale = json.dumps({
                "text": "Stale messenger wording.",
                "display_text": "Stale authoritative final.",
                "relay_command_seq": 1,
                "relay_command_id": "first",
            })

            self.assertFalse(voice_bridge._queue_tts_text(
                stale,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                notify_waiting_preview=lambda text: previews.append(text),
            ))
            self.assertEqual(previews, [])
            self.assertTrue(tts_queue.empty())

    def test_messenger_tts_can_speak_while_orchestrator_command_is_pending(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            command = voice_bridge._begin_relay_command(
                "explain the architecture",
                state_path=state_path,
                event_log_path=None,
            )
            Path(command_path).write_text("foreground command")
            payload = json.dumps({"text": "Here is the fast answer.", **command})

            queued = voice_bridge._queue_tts_text(
                payload,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
                allow_pending_command=True,
            )

            self.assertTrue(queued)
            self.assertEqual(tts_queue.get_nowait(), "Here is the fast answer.")

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

    def test_voice_acknowledgement_stays_notch_only_without_generic_planning_response(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()
            relay_command = voice_bridge._begin_relay_command(
                "dispatch RR-7 to a worker",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []

            queued = voice_bridge._queue_voice_acknowledgement(
                relay_command,
                tts_queue,
                command_path=os.path.join(temp_dir, "voice_cmd_ready"),
                meta_path=os.path.join(temp_dir, "voice_cmd_ready.meta"),
                state_path=state_path,
                source_text="dispatch RR-7 to a worker",
                delay_seconds=0,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertTrue(queued)
            self.assertTrue(tts_queue.empty())
            self.assertEqual([state for state, _ in notifications], ["acknowledgement"])
            status_event = notifications[0][1]["status_event"]
            self.assertEqual(status_event["phase"], "acknowledged")
            self.assertEqual(status_event["source"], "pm")
            self.assertEqual(status_event["message"], notifications[0][1]["text"])
            self.assertEqual(
                status_event["command"]["relay_command_id"],
                relay_command["relay_command_id"],
            )
            self.assertNotIn("source_text", status_event["command"])

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

    def test_orchestration_trace_updates_notch_and_messenger_without_direct_tts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            relay_command = voice_bridge._begin_relay_command(
                "inspect the voice bridge",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []
            messenger = FakeMessenger()

            emitted = voice_bridge.emit_orchestration_trace(
                kind="reasoning-summary",
                relay_command=relay_command,
                message="Checking how the bridge routes replies",
                messenger=messenger,
                state_path=state_path,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertTrue(emitted)
            self.assertEqual(notifications[0][0], "working")
            self.assertEqual(messenger.traces[0]["kind"], "reasoning-summary")
            self.assertEqual(messenger.traces[0]["command"]["relay_command_id"], relay_command["relay_command_id"])

    def test_orchestrator_reply_control_is_routed_to_messenger(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "what changed",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()
            payload = json.dumps({"text": "The messenger is ready.", **command})

            with mock.patch.object(voice_bridge, "publish_waiting_preview") as preview:
                handled = voice_bridge._handle_relay_control_message(
                    f"__ORCHESTRATOR_REPLY__:{payload}",
                    worker,
                    messenger=messenger,
                    state_path=state_path,
                    event_log_path=None,
                )

            self.assertTrue(handled)
            preview.assert_called_once_with("The messenger is ready.")
            self.assertEqual(messenger.finals, [{
                "text": "The messenger is ready.",
                "relay_command_seq": command["relay_command_seq"],
                "relay_command_id": command["relay_command_id"],
            }])
            self.assertTrue(worker.input_queue.empty())

    def test_current_orchestrator_reply_falls_back_when_messenger_rejects_it(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            command = voice_bridge._begin_relay_command(
                "what changed",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = RejectingMessenger()
            worker = FakeTTSWorker()
            payload = json.dumps({"text": "The authoritative result.", **command})

            with mock.patch.object(voice_bridge, "publish_waiting_preview") as preview:
                handled = voice_bridge._handle_orchestrator_reply_control(
                    payload,
                    tts_worker=worker,
                    messenger=messenger,
                    state_path=state_path,
                )

            self.assertTrue(handled)
            preview.assert_called_once_with("The authoritative result.")
            self.assertEqual(
                worker.input_queue.get_nowait(),
                {
                    "text": "The authoritative result.",
                    "display_text": "The authoritative result.",
                },
            )
            self.assertFalse(os.path.exists(command_path))

    def test_acknowledgement_does_not_publish_final_response_preview(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "status",
                state_path=state_path,
                event_log_path=None,
            )
            notifications: list[tuple[str, dict]] = []

            with mock.patch.object(voice_bridge, "publish_waiting_preview") as preview:
                queued = voice_bridge._queue_voice_acknowledgement(
                    command,
                    queue.Queue(),
                    command_path=command_path,
                    meta_path=meta_path,
                    state_path=state_path,
                    source_text="status",
                    delay_seconds=0,
                    notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
                )

            self.assertTrue(queued)
            preview.assert_not_called()
            self.assertEqual(notifications[0][0], "acknowledgement")

    def test_duplicate_orchestrator_reply_control_is_spoken_once(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "what changed",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()
            payload = json.dumps({"text": "The authoritative result.", **command})

            first = voice_bridge._handle_orchestrator_reply_control(
                payload,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            )
            second = voice_bridge._handle_orchestrator_reply_control(
                payload,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            )

            self.assertTrue(first)
            self.assertTrue(second)
            self.assertEqual(len(messenger.finals), 1)
            self.assertTrue(worker.input_queue.empty())

    def test_missing_foreground_reply_fallback_reports_current_claim_once(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            action = voice_bridge.resolve_command_action(
                "dispatch RR-7",
                repo_path=temp_dir,
                relay_command=command,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            thread = voice_bridge._schedule_foreground_reply_fallback(
                relay_command=command,
                action=action,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
                turns_path=turns_path,
                delay_seconds=0,
            )
            thread.join(timeout=1)

            self.assertEqual(len(messenger.finals), 1)
            self.assertIn("did not send a spoken final reply", messenger.finals[0]["text"])
            self.assertEqual(messenger.finals[0]["relay_command_id"], command["relay_command_id"])
            self.assertTrue(worker.input_queue.empty())

    def test_missing_foreground_reply_fallback_skips_after_explicit_reply(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "what changed",
                state_path=state_path,
                event_log_path=None,
            )
            action = voice_bridge.resolve_command_action(
                "what changed",
                repo_path=temp_dir,
                relay_command=command,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()
            payload = json.dumps({"text": "The authoritative result.", **command})

            voice_bridge._handle_orchestrator_reply_control(
                payload,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            )
            thread = voice_bridge._schedule_foreground_reply_fallback(
                relay_command=command,
                action=action,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
                delay_seconds=0,
            )
            thread.join(timeout=1)

            self.assertEqual(messenger.finals, [{
                "text": "The authoritative result.",
                "relay_command_seq": command["relay_command_seq"],
                "relay_command_id": command["relay_command_id"],
            }])

    def test_late_provider_final_cancels_pending_missing_final_fallback(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "what changed",
                state_path=state_path,
                event_log_path=None,
            )
            action = voice_bridge.resolve_command_action(
                "what changed",
                repo_path=temp_dir,
                relay_command=command,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            thread = voice_bridge._schedule_foreground_reply_fallback(
                relay_command=command,
                action=action,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
                delay_seconds=0.05,
            )
            payload = json.dumps({"text": "The late authoritative result.", **command})
            voice_bridge._handle_orchestrator_reply_control(
                payload,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            )
            thread.join(timeout=1)

            self.assertEqual(messenger.finals, [{
                "text": "The late authoritative result.",
                "relay_command_seq": command["relay_command_seq"],
                "relay_command_id": command["relay_command_id"],
            }])

    def test_missing_foreground_reply_fallback_waits_while_provider_turn_is_active(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            command = voice_bridge._begin_relay_command(
                "long running request",
                state_path=state_path,
                event_log_path=None,
            )
            Path(turns_path).write_text(json.dumps({
                "records": [{
                    **command,
                    "session_id": "provider-session",
                    "state": "active",
                    "updated_at": 1,
                }]
            }))
            action = voice_bridge.resolve_command_action(
                "long running request",
                repo_path=temp_dir,
                relay_command=command,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            with mock.patch.object(voice_bridge, "PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS", 0.01):
                thread = voice_bridge._schedule_foreground_reply_fallback(
                    relay_command=command,
                    action=action,
                    tts_worker=worker,
                    messenger=messenger,
                    state_path=state_path,
                    turns_path=turns_path,
                    delay_seconds=0,
                )
                time.sleep(0.05)
                self.assertEqual(messenger.finals, [])
                Path(turns_path).write_text(json.dumps({
                    "records": [{
                        **command,
                        "session_id": "provider-session",
                        "state": "empty",
                        "updated_at": 2,
                    }]
                }))
                thread.join(timeout=1)

            self.assertEqual(len(messenger.finals), 1)
            self.assertIn("did not send a spoken final reply", messenger.finals[0]["text"])

    def test_missing_foreground_reply_fallback_waits_for_pending_command_behind_active_turn(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            command = voice_bridge._begin_relay_command(
                "second request",
                state_path=state_path,
                event_log_path=None,
            )
            Path(command_path).write_text("second request")
            Path(meta_path).write_text(json.dumps(command))
            Path(turns_path).write_text(json.dumps({
                "records": [{
                    "relay_command_seq": command["relay_command_seq"] - 1,
                    "relay_command_id": "first",
                    "session_id": "provider-session",
                    "state": "active",
                    "updated_at": 1,
                }]
            }))
            action = voice_bridge.resolve_command_action(
                "second request",
                repo_path=temp_dir,
                relay_command=command,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            with mock.patch.object(voice_bridge, "PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS", 0.01):
                thread = voice_bridge._schedule_foreground_reply_fallback(
                    relay_command=command,
                    action=action,
                    tts_worker=worker,
                    messenger=messenger,
                    state_path=state_path,
                    turns_path=turns_path,
                    command_path=command_path,
                    meta_path=meta_path,
                    delay_seconds=0,
                )
                time.sleep(0.05)
                self.assertEqual(messenger.finals, [])

                Path(turns_path).write_text(json.dumps({
                    "records": [{
                        "relay_command_seq": command["relay_command_seq"] - 1,
                        "relay_command_id": "first",
                        "session_id": "provider-session",
                        "state": "stale",
                        "updated_at": 2,
                    }]
                }))
                time.sleep(0.05)
                self.assertEqual(messenger.finals, [])

                os.remove(command_path)
                os.remove(meta_path)
                thread.join(timeout=1)

            self.assertEqual(len(messenger.finals), 1)
            self.assertIn("did not send a spoken final reply", messenger.finals[0]["text"])

    def test_completion_hook_binds_exact_claimed_prompt_without_storing_text(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            claim = {
                "relay_command_seq": 7,
                "relay_command_id": "cmd-7",
                "agent_prompt": "Refined private agent prompt",
                "source_text": "raw voice text",
                "action": "dispatch_ticket",
                "provider": "codex",
            }
            Path(state_path).write_text(json.dumps(claim))
            Path(claim_path).write_text(json.dumps(claim))

            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-1",
                    "turn_id": "turn-1",
                    "prompt": "Refined private agent prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=10,
                stderr=io.StringIO(),
            ))
            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-2",
                    "turn_id": "turn-2",
                    "prompt": "ordinary typed prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=11,
                stderr=io.StringIO(),
            ))
            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-3",
                    "turn_id": "turn-3",
                    "prompt": "Refined private agent prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=12,
                stderr=io.StringIO(),
            ))
            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-4",
                    "turn_id": "turn-4",
                    "prompt": "Improve documentation in @filename",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=13,
                stderr=io.StringIO(),
            ))

            stored = Path(turns_path).read_text()
            self.assertIn('"state": "active"', stored)
            self.assertIn('"prompt_sha256"', stored)
            self.assertNotIn("Refined private agent prompt", stored)
            self.assertNotIn("raw voice text", stored)
            self.assertNotIn("Improve documentation", stored)

    def test_completion_hook_rapid_turns_deliver_only_current_final(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            first = {
                "relay_command_seq": 11,
                "relay_command_id": "cmd-11",
                "agent_prompt": "First prompt",
                "action": "non_work",
                "provider": "codex",
            }
            second = {
                "relay_command_seq": 12,
                "relay_command_id": "cmd-12",
                "agent_prompt": "Second prompt",
                "action": "non_work",
                "provider": "codex",
            }
            delivered: list[dict] = []
            Path(state_path).write_text(json.dumps(first))
            Path(claim_path).write_text(json.dumps(first))
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-rapid",
                    "turn_id": "turn-11",
                    "prompt": "First prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=40,
                stderr=io.StringIO(),
            ))

            Path(state_path).write_text(json.dumps(second))
            Path(claim_path).write_text(json.dumps(second))
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-rapid",
                    "turn_id": "turn-12",
                    "prompt": "Second prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=41,
                stderr=io.StringIO(),
            ))
            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "session-rapid",
                    "turn_id": "turn-11",
                    "last_assistant_message": "Superseded final.",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda payload: delivered.append(payload) or True,
                now=42,
                stderr=io.StringIO(),
            ))
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "session-rapid",
                    "turn_id": "turn-12",
                    "last_assistant_message": "Current final.",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda payload: delivered.append(payload) or True,
                now=43,
                stderr=io.StringIO(),
            ))

            self.assertEqual([payload.get("text") for payload in delivered], ["Current final."])
            self.assertEqual(delivered[0]["relay_command_id"], "cmd-12")

    def test_app_owned_stale_turn_drops_final_until_newer_claim_is_injected(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as temp_dir:
                    state_path = os.path.join(temp_dir, "voice_command_state.json")
                    claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                    turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                    first = {
                        "relay_command_seq": 21,
                        "relay_command_id": "cmd-21",
                        "agent_prompt": "First prompt",
                        "action": "create_ticket",
                        "provider": provider,
                    }
                    second = {
                        "relay_command_seq": 22,
                        "relay_command_id": "cmd-22",
                        "agent_prompt": "Second prompt",
                        "action": "create_ticket",
                        "provider": provider,
                    }
                    delivered: list[dict] = []
                    Path(state_path).write_text(json.dumps(first))
                    Path(claim_path).write_text(json.dumps(first))

                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "UserPromptSubmit",
                            "session_id": f"{provider}-session",
                            "turn_id": "turn-21",
                            "prompt": "First prompt",
                            "provider": provider,
                        },
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        now=60,
                        stderr=io.StringIO(),
                    ))

                    Path(state_path).write_text(json.dumps(second))
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "Stop",
                            "session_id": f"{provider}-session",
                            "turn_id": "turn-21",
                            "last_assistant_message": "Stale final from active turn.",
                            "provider": provider,
                        },
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        now=61,
                        stderr=io.StringIO(),
                    ))

                    Path(claim_path).write_text(json.dumps(second))
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "UserPromptSubmit",
                            "session_id": f"{provider}-session",
                            "turn_id": "turn-22",
                            "prompt": "Second prompt",
                            "provider": provider,
                        },
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        now=62,
                        stderr=io.StringIO(),
                    ))
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "Stop",
                            "session_id": f"{provider}-session",
                            "turn_id": "turn-22",
                            "last_assistant_message": "Current final.",
                            "provider": provider,
                        },
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        now=63,
                        stderr=io.StringIO(),
                    ))

                    self.assertEqual([payload.get("text") for payload in delivered], ["Current final."])
                    self.assertEqual(delivered[0]["relay_command_id"], "cmd-22")
                    self.assertEqual(delivered[0]["provider"], provider)
                    stored_text = Path(turns_path).read_text()
                    self.assertNotIn("Stale final from active turn.", stored_text)
                    self.assertNotIn("Current final.", stored_text)
                    stored = json.loads(stored_text)
                    states = {record["relay_command_id"]: record["state"] for record in stored["records"]}
                    self.assertEqual(states["cmd-21"], "stale")
                    self.assertEqual(states["cmd-22"], "completed_final")

    def test_completion_hook_does_not_guess_unidentified_stop_with_multiple_active_turns(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            current = {
                "relay_command_seq": 14,
                "relay_command_id": "cmd-14",
                "agent_prompt": "Second prompt",
                "provider": "claude",
            }
            Path(state_path).write_text(json.dumps(current))
            Path(turns_path).write_text(json.dumps({
                "records": [
                    {
                        "state": "active",
                        "session_id": "ambiguous-session",
                        "relay_command_seq": 13,
                        "relay_command_id": "cmd-13",
                    },
                    {
                        "state": "active",
                        "session_id": "ambiguous-session",
                        "relay_command_seq": 14,
                        "relay_command_id": "cmd-14",
                    },
                ]
            }))
            delivered: list[dict] = []

            handled = relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "ambiguous-session",
                    "last_assistant_message": "Could belong to either turn.",
                },
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda payload: delivered.append(payload) or True,
                now=50,
                stderr=io.StringIO(),
            )

            self.assertFalse(handled)
            self.assertEqual(delivered, [])

    def test_completion_hook_stop_delivers_only_correlated_provider_final(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            claim = {
                "relay_command_seq": 8,
                "relay_command_id": "cmd-8",
                "agent_prompt": "Do provider completion",
                "action": "update_ticket",
                "provider": "claude",
            }
            Path(state_path).write_text(json.dumps(claim))
            Path(claim_path).write_text(json.dumps(claim))
            delivered: list[dict] = []

            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-8",
                    "prompt": "Do provider completion",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=20,
                stderr=io.StringIO(),
            )
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "session-8",
                    "last_assistant_message": "Authoritative final from provider.",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda payload: delivered.append(payload) or True,
                now=21,
                stderr=io.StringIO(),
            ))

            self.assertEqual(delivered, [{
                "event": "Stop",
                "relay_command_seq": 8,
                "relay_command_id": "cmd-8",
                "session_id": "session-8",
                "provider": "claude",
                "action": "update_ticket",
                "text": "Authoritative final from provider.",
            }])
            stored = Path(turns_path).read_text()
            self.assertIn('"state": "completed_final"', stored)
            self.assertIn('"delivery": "sent"', stored)
            self.assertNotIn("Authoritative final from provider.", stored)

    def test_completion_hook_empty_stop_delivers_bounded_warning_signal(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            claim = {
                "relay_command_seq": 9,
                "relay_command_id": "cmd-9",
                "agent_prompt": "Do empty completion",
                "action": "dispatch_ticket",
                "provider": "codex",
            }
            Path(state_path).write_text(json.dumps(claim))
            Path(claim_path).write_text(json.dumps(claim))
            delivered: list[dict] = []

            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-9",
                    "turn_id": "turn-9",
                    "prompt": "Do empty completion",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=30,
                stderr=io.StringIO(),
            )
            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "session-9",
                    "turn_id": "turn-9",
                    "last_assistant_message": "",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda payload: delivered.append(payload) or True,
                now=31,
                stderr=io.StringIO(),
            )

            self.assertEqual(delivered, [{
                "event": "Stop",
                "relay_command_seq": 9,
                "relay_command_id": "cmd-9",
                "session_id": "session-9",
                "turn_id": "turn-9",
                "provider": "codex",
                "action": "dispatch_ticket",
                "completion_status": "empty",
            }])

    def test_provider_completion_control_deduplicates_after_explicit_reply(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "summarize result",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            explicit = json.dumps({"text": "Explicit final.", **command})
            provider = json.dumps({"text": "Provider final.", **command})
            self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                explicit,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            ))
            self.assertTrue(voice_bridge._handle_provider_completion_control(
                provider,
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            ))

            self.assertEqual(messenger.finals, [{
                "text": "Explicit final.",
                "relay_command_seq": command["relay_command_seq"],
                "relay_command_id": command["relay_command_id"],
            }])

    def test_provider_completion_control_rejects_superseded_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            stale = voice_bridge._begin_relay_command(
                "first",
                state_path=state_path,
                event_log_path=None,
            )
            voice_bridge._begin_relay_command(
                "second",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            self.assertFalse(voice_bridge._handle_provider_completion_control(
                json.dumps({"text": "Stale provider final.", **stale}),
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            ))
            self.assertEqual(messenger.finals, [])

    def test_provider_completion_control_routes_empty_completion_to_warning(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            self.assertTrue(voice_bridge._handle_provider_completion_control(
                json.dumps({**command, "completion_status": "empty", "action": "dispatch_ticket"}),
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
                turns_path=turns_path,
                fallback_delay_seconds=0,
            ))
            deadline = time.time() + 1
            while not messenger.finals and time.time() < deadline:
                time.sleep(0.01)
            self.assertEqual(len(messenger.finals), 1)
            self.assertIn("worker updates will still be announced", messenger.finals[0]["text"])

    def test_provider_completion_control_arms_missing_final_after_terminal_event(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()

            with mock.patch.object(
                voice_bridge,
                "_schedule_foreground_reply_fallback",
                return_value=object(),
            ) as schedule_fallback:
                handled = voice_bridge._handle_provider_completion_control(
                    json.dumps({**command, "completion_status": "empty", "action": "dispatch_ticket"}),
                    tts_worker=worker,
                    messenger=messenger,
                    state_path=state_path,
                    fallback_delay_seconds=3.5,
                )

            self.assertTrue(handled)
            self.assertEqual(messenger.finals, [])
            schedule_fallback.assert_called_once()
            kwargs = schedule_fallback.call_args.kwargs
            scheduled_command = kwargs["relay_command"]
            self.assertEqual(scheduled_command["relay_command_seq"], command["relay_command_seq"])
            self.assertEqual(scheduled_command["relay_command_id"], command["relay_command_id"])
            self.assertEqual(scheduled_command["completion_status"], "empty")
            self.assertEqual(kwargs["action_kind"], "dispatch_ticket")
            self.assertEqual(kwargs["delay_seconds"], 3.5)

    def test_provider_completion_recovery_fallback_publishes_waiting_preview(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "summarize result",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = RejectingMessenger()
            worker = FakeTTSWorker()
            payload = json.dumps({"text": "Recovered provider final.", **command})

            with mock.patch.object(voice_bridge, "publish_waiting_preview") as preview:
                handled = voice_bridge._handle_provider_completion_control(
                    payload,
                    tts_worker=worker,
                    messenger=messenger,
                    state_path=state_path,
                )

            self.assertTrue(handled)
            preview.assert_called_once_with("Recovered provider final.")
            self.assertEqual(
                worker.input_queue.get_nowait(),
                {
                    "text": "Recovered provider final.",
                    "display_text": "Recovered provider final.",
                },
            )

    def test_pending_messenger_outcome_poll_delivers_and_acks_trace(self):
        messenger = FakeMessenger()
        requests: list[tuple[str, dict]] = []
        outcome = {
            "id": 4,
            "payload": {
                "trace_event": {
                    "kind": "run-review-needed",
                    "message": "RR-7 run 12 awaiting review",
                    "source": "worker",
                    "ticket_id": "RR-7",
                    "run_id": 12,
                }
            },
        }

        delivered = voice_bridge._deliver_pending_messenger_outcomes_once(
            orchestrator_session={"repo_path": "/tmp/repo", "provider": "codex"},
            messenger=messenger,
            request_get_json=lambda path, params: {"outcomes": [outcome]},
            request_json=lambda path, payload: requests.append((path, payload)) or {},
        )

        self.assertEqual(delivered, 1)
        self.assertEqual(messenger.traces, [outcome["payload"]["trace_event"]])
        self.assertEqual(requests, [("/v1/messenger/outcomes/4/delivered", {})])

    def test_pending_messenger_outcome_rejection_is_not_marked_delivered(self):
        messenger = RejectingTraceMessenger()
        requests: list[tuple[str, dict]] = []
        outcome = {
            "id": 5,
            "payload": {
                "trace_event": {
                    "kind": "run-failed",
                    "message": "RR-8 run 13 failed",
                    "source": "worker",
                    "ticket_id": "RR-8",
                    "run_id": 13,
                }
            },
        }

        delivered = voice_bridge._deliver_pending_messenger_outcomes_once(
            orchestrator_session={"repo_path": "/tmp/repo", "provider": "claude"},
            messenger=messenger,
            request_get_json=lambda path, params: {"outcomes": [outcome]},
            request_json=lambda path, payload: requests.append((path, payload)) or {},
        )

        self.assertEqual(delivered, 0)
        self.assertEqual(requests, [("/v1/messenger/outcomes/5/attempt", {})])

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
        self.assertIn("messenger.py", script)
        self.assertIn("relay_authorization.py", script)

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

    def test_acknowledgement_does_not_revoke_dispatch_authorization(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            auth_path = os.path.join(temp_dir, "voice_command_authorizations.json")

            first_meta = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            first_action = voice_bridge.resolve_command_action(
                "dispatch RR-7",
                repo_path=temp_dir,
                relay_command=first_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(first_action),
                voice_bridge._metadata_for_action(first_action, first_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                authorization_path=auth_path,
            )

            second_meta = voice_bridge._begin_relay_command(
                "okay",
                state_path=state_path,
                event_log_path=None,
            )
            second_action = voice_bridge.resolve_command_action(
                "okay",
                repo_path=temp_dir,
                relay_command=second_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(second_action),
                voice_bridge._metadata_for_action(second_action, second_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                authorization_path=auth_path,
            )

            ledger = json.loads(Path(auth_path).read_text())
            authorizations = ledger["authorizations"]
            self.assertEqual(len(authorizations), 1)
            self.assertEqual(authorizations[0]["relay_command_id"], first_meta["relay_command_id"])
            self.assertEqual(authorizations[0]["status"], "active")
            current = json.loads(Path(state_path).read_text())
            self.assertEqual(current["relay_command_id"], second_meta["relay_command_id"])
            self.assertEqual(current["authorization_relationship"], "conversation")

    def test_redirect_revokes_dispatch_authorization(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            auth_path = os.path.join(temp_dir, "voice_command_authorizations.json")

            first_meta = voice_bridge._begin_relay_command(
                "dispatch RR-7",
                state_path=state_path,
                event_log_path=None,
            )
            first_action = voice_bridge.resolve_command_action(
                "dispatch RR-7",
                repo_path=temp_dir,
                relay_command=first_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(first_action),
                voice_bridge._metadata_for_action(first_action, first_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                authorization_path=auth_path,
            )

            second_meta = voice_bridge._begin_relay_command(
                "actually dispatch RR-8 instead",
                state_path=state_path,
                event_log_path=None,
            )
            second_action = voice_bridge.resolve_command_action(
                "actually dispatch RR-8 instead",
                repo_path=temp_dir,
                relay_command=second_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(second_action),
                voice_bridge._metadata_for_action(second_action, second_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                authorization_path=auth_path,
            )

            ledger = json.loads(Path(auth_path).read_text())
            statuses = {
                record["relay_command_id"]: record["status"]
                for record in ledger["authorizations"]
            }
            self.assertEqual(statuses[first_meta["relay_command_id"]], "revoked")
            self.assertEqual(statuses[second_meta["relay_command_id"]], "active")
            current = json.loads(Path(state_path).read_text())
            self.assertEqual(current["authorization_relationship"], "redirect")

    def test_published_command_records_exact_agent_prompt_for_voice_origin(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            source_text = "fix the login bug"
            relay_command = voice_bridge._begin_relay_command(
                source_text,
                state_path=state_path,
                event_log_path=None,
            )
            action = voice_bridge.resolve_command_action(
                source_text,
                repo_path=temp_dir,
                relay_command=relay_command,
            )
            agent_prompt = voice_bridge.format_command_for_agent(action)

            self.assertNotEqual(agent_prompt, source_text)
            voice_bridge._publish_command(
                agent_prompt,
                voice_bridge._metadata_for_action(action, relay_command),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )

            claimed = json.loads(Path(meta_path).read_text())
            current = json.loads(Path(state_path).read_text())
            self.assertEqual(claimed["source_text"], source_text)
            self.assertEqual(claimed["agent_prompt"], agent_prompt)
            self.assertEqual(current["agent_prompt"], agent_prompt)

    def test_explicit_interrupt_still_supersedes_claimed_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            worker = FakeTTSWorker()
            messenger = FakeMessenger()

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
                messenger=messenger,
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                event_log_path=None,
            )

            self.assertTrue(handled)
            self.assertEqual(worker.calls, ["stop_playback"])
            self.assertEqual(messenger.interrupt_count, 1)
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

    def test_voice_commands_default_to_foreground_pm_without_raw_fanout(self):
        relay_command = {"relay_command_seq": 1, "relay_command_id": "cmd-1"}
        action = voice_bridge.resolve_command_action(
            "fix the login bug",
            repo_path="/tmp/repo",
            relay_command=relay_command,
        )

        self.assertFalse(voice_bridge._should_fanout_raw_instruction_to_orchestrator(action))

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
            script.index("Then send your authoritative user-facing response to the messenger")
        ]
        codex_cleanup = script[
            script.index("After each handled command, stop only that command's heartbeat refresher"):
            script.index("Send the authoritative user-facing response to the messenger")
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
        self.assertEqual(script.count('print("__ORCHESTRATOR_REPLY__:" + json.dumps(payload)'), 2)
        self.assertEqual(script.count('"kind":"reasoning-summary"'), 2)
        self.assertNotIn("Voice bridge is ready. You can speak at any point.", script)

    def test_build_bundle_includes_provider_completion_hook_service(self):
        script_path = os.path.join(ROOT, "scripts", "build-dmg.sh")
        with open(script_path) as f:
            script = f.read()

        self.assertIn("relay_completion_hook.py", script)


if __name__ == "__main__":
    unittest.main()
