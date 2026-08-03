from __future__ import annotations

import os
import io
import queue
import stat
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
from speech_coordinator import SpeechIntent  # noqa: E402


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
        self.eligibility = None
        self.observer = None

    def set_speech_callbacks(self, *, eligibility, observer):
        self.eligibility = eligibility
        self.observer = observer

    def stop_playback(self):
        self.calls.append("stop_playback")

    def skip(self):
        self.calls.append("skip")

    def play(self):
        self.calls.append("play")

    def replay(self):
        self.calls.append("replay")

    def reload_config(self):
        self.calls.append("reload_config")

    def shutdown(self):
        self.calls.append("shutdown")


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


class FakeSidecarLane:
    def __init__(self):
        self.submissions: list[tuple[str, dict]] = []

    def submit(self, prompt: str, command: dict) -> bool:
        self.submissions.append((prompt, command))
        return True


class CapturingSpeechQueue:
    def __init__(self):
        self.submissions: list[tuple[str, dict]] = []

    def submit_text(self, text: str, **metadata) -> bool:
        self.submissions.append((text, metadata))
        return True


class ImmediateMessengerBackend:
    def __init__(self, response: str):
        self.response = response

    def start(self):
        pass

    def ask(self, prompt: str, timeout: float = 60.0) -> str:
        del prompt, timeout
        return self.response

    def interrupt(self):
        pass

    def shutdown(self):
        pass


class VoiceBridgePreemptionTests(unittest.TestCase):
    def setUp(self):
        # Unit tests may run while Relay Runner is live. Never let fixture
        # previews escape to the shared /tmp/voice_state.sock.
        patcher = mock.patch.object(voice_bridge, "publish_waiting_preview")
        self.publish_waiting_preview = patcher.start()
        self.addCleanup(patcher.stop)

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

        self.assertEqual(len(messenger.users), 1)
        submitted_text, submitted_metadata = messenger.users[0]
        self.assertEqual(submitted_text, "What is next?")
        self.assertEqual(submitted_metadata["relay_command_seq"], 2)
        self.assertEqual(submitted_metadata["relay_command_id"], "normal-2")
        self.assertEqual(len(submitted_metadata["voice_work_items"]), 1)
        self.assertEqual(
            submitted_metadata["voice_work_items"][0]["source_text"],
            "What is next?",
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

    def test_dispatch_feedback_smoke_produces_one_action_and_one_spoken_outcome(self):
        voice_bridge._reset_foreground_reply_delivery_for_tests()
        worker = FakeTTSWorker()
        messenger = FakeMessenger()
        shutdown_event = threading.Event()
        command = {
            "relay_command_seq": 1,
            "relay_command_id": "cmd-1",
            "source_text": "dispatch RR-247",
        }
        raw_feedback = json.dumps({
            "type": "__ORCHESTRATOR_REPLY__",
            **command,
            "text": "Dispatched RR-247.",
        })
        completion = "__RELAY_COMPLETION__:" + json.dumps({
            **command,
            "text": "Dispatched RR-247.",
        })

        def read_once(_fd, _size):
            shutdown_event.set()
            return (
                "dispatch RR-247\n"
                + raw_feedback
                + "\n"
                + completion
                + "\n"
            ).encode()

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge.os, "read", side_effect=read_once),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_queue_tts_text", return_value=True),
            mock.patch.object(
                voice_bridge,
                "_begin_relay_command",
                return_value=command,
            ) as begin_command,
            mock.patch.object(voice_bridge, "_relay_command_current", return_value=True),
            mock.patch.object(voice_bridge, "record_command_authorization"),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement", return_value=True),
            mock.patch.object(voice_bridge, "_start_pm_update_mode"),
            mock.patch.object(voice_bridge, "_publish_command") as publish_command,
            mock.patch.object(
                voice_bridge,
                "_schedule_foreground_reply_fallback",
            ) as schedule_fallback,
        ):
            voice_bridge._run_relay(
                worker,
                shutdown_event,
                messenger=messenger,
            )

        begin_command.assert_called_once_with("dispatch RR-247")
        publish_command.assert_called_once()
        schedule_fallback.assert_not_called()
        self.assertEqual(len(messenger.users), 1)
        self.assertEqual(messenger.users[0][0], "dispatch RR-247")
        self.assertEqual(messenger.finals, [{
            "text": "Dispatched RR-247.",
            "relay_command_seq": 1,
            "relay_command_id": "cmd-1",
            "speech_source": "completion",
        }])
        self.assertTrue(worker.input_queue.empty())

    def test_run_sidecar_bypasses_active_foreground_publication_path(self):
        worker = FakeTTSWorker()
        messenger = FakeMessenger()
        lane = FakeSidecarLane()
        shutdown_event = threading.Event()
        action = types.SimpleNamespace(kind="conversation", outcome="independent research")
        disposition_payload = {
            "intent_id": "cmd-2",
            "route": "run_sidecar",
            "target_work_ids": ["cmd-1"],
            "conflicting_work_ids": [],
            "public_reason": "Independent bounded public research.",
            "clarification_question": None,
            "authorization_effect": "preserve",
            "resource_claims": [],
        }
        disposition = types.SimpleNamespace(
            intent_id="cmd-2",
            route=voice_bridge.IntentRoute.RUN_SIDECAR,
            public_reason=disposition_payload["public_reason"],
            to_dict=lambda: disposition_payload,
        )

        def read_once(_fd, _size):
            shutdown_event.set()
            return b"In parallel, research and compare the public APIs\n"

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
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
            }),
            mock.patch.object(voice_bridge, "resolve_command_action", return_value=action),
            mock.patch.object(
                voice_bridge,
                "resolve_intent_disposition",
                return_value=disposition,
            ),
            mock.patch.object(voice_bridge, "format_command_for_agent", return_value="sidecar prompt"),
            mock.patch.object(voice_bridge, "_metadata_for_action", return_value={
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "cmd-2",
                "source_text": "In parallel, research and compare the public APIs",
                "work_disposition": disposition_payload,
            }),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement", return_value=True),
            mock.patch.object(
                voice_bridge,
                "_enqueue_sidecar_intent",
                return_value=True,
            ) as enqueue_sidecar,
            mock.patch.object(voice_bridge, "_start_pm_update_mode") as start_pm_update,
            mock.patch.object(voice_bridge, "_publish_command") as publish_command,
        ):
            voice_bridge._run_relay(
                worker,
                shutdown_event,
                messenger=messenger,
                sidecar_lane=lane,
            )

        enqueue_sidecar.assert_called_once()
        publish_command.assert_not_called()
        start_pm_update.assert_not_called()
        self.assertEqual(messenger.users[0][1]["work_disposition"], disposition_payload)

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
            self.publish_waiting_preview.assert_called_once_with("fresh response")

    def test_tts_queue_publishes_waiting_preview_after_enqueue(self):
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
            self.assertEqual(previews, [("fresh response", False)])
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
                event_log_path=None,
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
            self.assertEqual(payload["status"], "queued")
            self.assertTrue(payload["defer_processing"])
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
                event_log_path=None,
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

    def test_option_play_control_uses_play_or_replay_boundary(self):
        worker = FakeTTSWorker()
        worker.play_or_replay = mock.Mock(return_value=True)

        handled = voice_bridge._handle_relay_control_message("__PLAY__", worker)

        self.assertTrue(handled)
        worker.play_or_replay.assert_called_once_with()
        self.assertNotIn("play", worker.calls)

    def test_timestamped_option_and_visual_ack_controls_preserve_timing(self):
        worker = FakeTTSWorker()
        worker.play_or_replay = mock.Mock(return_value=True)
        worker.note_play_control = mock.Mock()
        worker.note_visual_acknowledgement = mock.Mock()

        with mock.patch.object(voice_bridge.time, "time", return_value=1_000.02):
            self.assertTrue(voice_bridge._handle_relay_control_message(
                "__PLAY__:1000.000000",
                worker,
            ))
        self.assertTrue(voice_bridge._handle_relay_control_message(
            "__PLAY_ACK__:1000.000000:1000.050000",
            worker,
        ))

        worker.note_play_control.assert_called_once_with(
            option_detected_at=1_000.0,
            fifo_received_at=1_000.02,
        )
        worker.note_visual_acknowledgement.assert_called_once_with(
            option_detected_at=1_000.0,
            acknowledged_at=1_000.05,
        )
        worker.play_or_replay.assert_called_once_with()

    def test_first_play_during_authoritative_preview_waits_for_matching_final_intent(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                command = voice_bridge._begin_relay_command(
                    "what changed",
                    state_path=state_path,
                    event_log_path=None,
                )
                command["provider"] = provider
                Path(state_path).write_text(json.dumps(command))
                executor = FakeTTSWorker()
                coordinator = voice_bridge.SpeechCoordinator(
                    executor,
                    is_current=lambda seq, command_id: (
                        seq,
                        command_id,
                    ) == (
                        command["relay_command_seq"],
                        command["relay_command_id"],
                    ),
                )
                messenger = FakeMessenger()
                payload = json.dumps({"text": "The authoritative result.", **command})

                with mock.patch.object(
                    voice_bridge,
                    "publish_waiting_preview",
                    side_effect=lambda _text: voice_bridge._handle_relay_control_message(
                        "__PLAY__",
                        coordinator,
                    ),
                ):
                    handled = voice_bridge._handle_orchestrator_reply_control(
                        payload,
                        tts_worker=coordinator,
                        messenger=messenger,
                        state_path=state_path,
                    )

                self.assertTrue(handled)
                self.assertEqual(executor.calls, [])

                speech = SpeechIntent.build(
                    spoken_text="Here is the result.",
                    display_text="The authoritative result.",
                    command_seq=command["relay_command_seq"],
                    command_id=command["relay_command_id"],
                    source="orchestrator",
                    kind="final",
                    authoritative=True,
                )
                self.assertTrue(coordinator.submit(speech))
                self.assertEqual(executor.calls, ["play"])

    def test_raw_control_shaped_json_is_quarantined_without_payload_logging(self):
        worker = FakeTTSWorker()
        private_values = [
            "dispatch RR-247",
            "private prompt",
            "secret tool output",
        ]
        samples = [
            json.dumps({
                "type": "__ORCHESTRATOR_REPLY__",
                "text": private_values[0],
                "prompt": private_values[1],
                "tool_output": private_values[2],
            }),
            json.dumps({
                "payload": {
                    "type": "__ORCHESTRATOR_REPLY__",
                    "text": private_values[0],
                },
            }),
            json.dumps({
                "type": "__UNKNOWN_RELAY_CONTROL__",
                "text": private_values[0],
            }),
            '{"type":"__ORCHESTRATOR_REPLY__","text":"dispatch RR-247"',
        ]

        stderr = io.StringIO()
        with mock.patch.object(voice_bridge.sys, "stderr", stderr):
            for sample in samples:
                with self.subTest(sample=sample):
                    self.assertTrue(voice_bridge._handle_relay_control_message(
                        sample,
                        worker,
                        event_log_path=None,
                    ))

        diagnostic = stderr.getvalue()
        self.assertEqual(diagnostic.count("quarantined_relay_control"), len(samples))
        self.assertIn("shape=nested", diagnostic)
        self.assertIn("control_type=unknown", diagnostic)
        self.assertIn("syntax=malformed", diagnostic)
        for private_value in private_values:
            self.assertNotIn(private_value, diagnostic)

    def test_unknown_prefixed_control_is_quarantined_but_token_prose_is_conversation(self):
        worker = FakeTTSWorker()

        self.assertTrue(voice_bridge._handle_relay_control_message(
            '__UNKNOWN_RELAY_CONTROL__:{"text":"dispatch RR-247"}',
            worker,
            event_log_path=None,
        ))
        self.assertFalse(voice_bridge._handle_relay_control_message(
            "Can you explain what __ORCHESTRATOR_REPLY__ means?",
            worker,
            event_log_path=None,
        ))

    def test_completion_hook_recovers_after_malformed_explicit_reply(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = voice_bridge._begin_relay_command(
                "dispatch RR-247",
                state_path=state_path,
                event_log_path=None,
            )
            messenger = FakeMessenger()
            worker = FakeTTSWorker()
            stderr = io.StringIO()

            with mock.patch.object(voice_bridge.sys, "stderr", stderr):
                self.assertTrue(voice_bridge._handle_relay_control_message(
                    '__ORCHESTRATOR_REPLY__:{"type":"__ORCHESTRATOR_REPLY__"',
                    worker,
                    messenger=messenger,
                    state_path=state_path,
                    event_log_path=None,
                ))
                self.assertTrue(voice_bridge._handle_provider_completion_control(
                    json.dumps({
                        **command,
                        "text": "Recovered the valid provider final.",
                    }),
                    tts_worker=worker,
                    messenger=messenger,
                    state_path=state_path,
                ))

            self.assertEqual(messenger.finals, [{
                "text": "Recovered the valid provider final.",
                "relay_command_seq": command["relay_command_seq"],
                "relay_command_id": command["relay_command_id"],
                "speech_source": "completion",
            }])
            self.assertNotIn("did not send a spoken final reply", stderr.getvalue())
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
            self.assertTrue(relay_completion_hook.handle_hook_payload(
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
            self.assertTrue(relay_completion_hook.handle_hook_payload(
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
            self.assertTrue(relay_completion_hook.handle_hook_payload(
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
            self.assertIn('"origin": "manual"', stored)
            self.assertNotIn("Refined private agent prompt", stored)
            self.assertNotIn("raw voice text", stored)
            self.assertNotIn("Improve documentation", stored)

    def test_completion_hook_tracks_manual_turn_boundaries_for_both_app_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                delivered: list[dict] = []

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "UserPromptSubmit",
                        "session_id": f"{provider}-manual-session",
                        "turn_id": "manual-turn",
                        "provider": provider,
                        "prompt": "private typed terminal text",
                    },
                    claim_path=os.path.join(temp_dir, "missing-claim.json"),
                    state_path=os.path.join(temp_dir, "missing-state.json"),
                    turns_path=turns_path,
                    now=20,
                    stderr=io.StringIO(),
                ))
                active = json.loads(Path(turns_path).read_text())["records"][0]
                self.assertEqual(active["state"], "active")
                self.assertEqual(active["origin"], "manual")
                self.assertEqual(active["provider"], provider)

                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "Stop",
                        "session_id": f"{provider}-manual-session",
                        "turn_id": "manual-turn",
                        "provider": provider,
                        "last_assistant_message": "private manual response",
                    },
                    state_path=os.path.join(temp_dir, "missing-state.json"),
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=21,
                    stderr=io.StringIO(),
                ))
                stored = Path(turns_path).read_text()
                completed = json.loads(stored)["records"][0]
                self.assertEqual(completed["state"], "completed_manual")
                self.assertEqual(delivered, [])
                self.assertNotIn("private typed terminal text", stored)
                self.assertNotIn("private manual response", stored)

    def test_completion_hook_releases_startup_identity_before_stale_relay_stop(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                provider_session_id = f"embedded-{provider}"

                startup = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-startup-identity",
                    "provider_session_id": provider_session_id,
                    "provider": provider,
                    "prompt": "private startup prompt",
                }
                relay_submit = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-persisted-session",
                    "provider_session_id": provider_session_id,
                    "provider": provider,
                    "prompt": "Claimed Relay prompt",
                }
                relay_stop = {
                    "hook_event_name": "Stop",
                    "session_id": f"{provider}-persisted-session",
                    "provider_session_id": provider_session_id,
                    "provider": provider,
                    "last_assistant_message": "stale private final",
                }
                if provider == "codex":
                    startup["turn_id"] = "startup-turn"
                    relay_submit["turn_id"] = "relay-turn"
                    relay_stop["turn_id"] = "relay-turn"

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    startup,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=10,
                    stderr=io.StringIO(),
                ))

                claim = {
                    "relay_command_seq": 41,
                    "relay_command_id": "cmd-41",
                    "agent_prompt": "Claimed Relay prompt",
                    "provider": provider,
                }
                Path(claim_path).write_text(json.dumps(claim))
                Path(state_path).write_text(json.dumps(claim))
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    relay_submit,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=11,
                    stderr=io.StringIO(),
                ))

                newer = {**claim, "relay_command_seq": 42, "relay_command_id": "cmd-42"}
                Path(state_path).write_text(json.dumps(newer))
                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    relay_stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda _payload: True,
                    now=12,
                    stderr=io.StringIO(),
                ))

                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual([record["state"] for record in records], ["orphaned", "stale"])
                self.assertEqual(records[0]["release_reason"], "superseded_by_prompt_submit")
                self.assertEqual(records[1]["release_reason"], "stale_current_command")
                self.assertFalse(any(record["state"] == "active" for record in records))
                stored = Path(turns_path).read_text()
                self.assertNotIn("private startup prompt", stored)
                self.assertNotIn("Claimed Relay prompt", stored)
                self.assertNotIn("stale private final", stored)

    def test_completion_hook_rebinds_duplicate_relay_prompt_identity_for_both_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                claim = {
                    "relay_command_seq": 51,
                    "relay_command_id": "cmd-51",
                    "agent_prompt": "One physical Relay prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                base = {
                    "hook_event_name": "UserPromptSubmit",
                    "provider_session_id": f"embedded-{provider}",
                    "provider": provider,
                    "prompt": claim["agent_prompt"],
                }
                first = {**base, "session_id": f"{provider}-startup"}
                rebound = {**base, "session_id": f"{provider}-persisted"}
                stop = {
                    "hook_event_name": "Stop",
                    "session_id": rebound["session_id"],
                    "provider_session_id": base["provider_session_id"],
                    "provider": provider,
                    "last_assistant_message": "one final",
                }
                if provider == "codex":
                    first["turn_id"] = "startup-turn"
                    rebound["turn_id"] = "persisted-turn"
                    stop["turn_id"] = "persisted-turn"

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    first,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=20,
                    stderr=io.StringIO(),
                ))
                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    rebound,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=21,
                    stderr=io.StringIO(),
                ))

                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual(sum(record["state"] == "active" for record in records), 1)
                self.assertEqual(records[-1]["session_id"], rebound["session_id"])
                self.assertEqual(records[-1]["relay_command_id"], claim["relay_command_id"])
                delivered: list[dict] = []
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=22,
                    stderr=io.StringIO(),
                ))
                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertFalse(any(record["state"] == "active" for record in records))
                self.assertEqual(records[-1]["state"], "completed_final")
                self.assertEqual(records[-1]["release_reason"], "provider_stop")
                self.assertEqual([item["relay_command_id"] for item in delivered], ["cmd-51"])

    def test_completion_hook_preserves_exact_manual_barrier_after_relay_turn(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                provider_session_id = f"embedded-{provider}"
                claim = {
                    "relay_command_seq": 61,
                    "relay_command_id": "cmd-61",
                    "agent_prompt": "Relay prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                relay_submit = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-session",
                    "provider_session_id": provider_session_id,
                    "provider": provider,
                    "prompt": claim["agent_prompt"],
                }
                relay_stop = {
                    **relay_submit,
                    "hook_event_name": "Stop",
                    "last_assistant_message": "Relay final",
                }
                manual_submit = {
                    **relay_submit,
                    "prompt": "private typed prompt",
                }
                manual_stop = {
                    **relay_stop,
                    "last_assistant_message": "private manual final",
                }
                if provider == "codex":
                    relay_submit["turn_id"] = "relay-turn"
                    relay_stop["turn_id"] = "relay-turn"
                    manual_submit["turn_id"] = "manual-turn"
                    manual_stop["turn_id"] = "manual-turn"

                relay_completion_hook.handle_hook_payload(
                    relay_submit,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=30,
                    stderr=io.StringIO(),
                )
                relay_completion_hook.handle_hook_payload(
                    relay_stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda _payload: True,
                    now=31,
                    stderr=io.StringIO(),
                )
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    manual_submit,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=32,
                    stderr=io.StringIO(),
                ))
                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual(records[-1]["state"], "active")
                self.assertEqual(records[-1]["origin"], "manual")

                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    manual_stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda _payload: True,
                    now=33,
                    stderr=io.StringIO(),
                ))
                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual(records[-1]["state"], "completed_manual")
                self.assertEqual(records[-1]["release_reason"], "provider_stop")

    def test_voice_bridge_provider_activity_is_scoped_to_embedded_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            command = {
                "relay_command_seq": 71,
                "relay_command_id": "cmd-71",
            }
            Path(turns_path).write_text(json.dumps({
                "records": [
                    {
                        **command,
                        "state": "completed_final",
                        "provider_session_id": "current-session",
                    },
                    {
                        **command,
                        "state": "active",
                        "origin": "manual",
                        "provider_session_id": "unrelated-session",
                    },
                ],
            }))

            self.assertEqual(
                voice_bridge._provider_turn_state(
                    command,
                    turns_path=turns_path,
                    provider_session_id="current-session",
                ),
                "completed_final",
            )
            self.assertFalse(voice_bridge._any_provider_turn_active(
                turns_path=turns_path,
                provider_session_id="current-session",
            ))
            self.assertTrue(voice_bridge._any_provider_turn_active(
                turns_path=turns_path,
                provider_session_id="unrelated-session",
            ))

    def test_completion_hook_separates_later_identical_manual_prompt_for_both_app_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                claim = {
                    "relay_command_seq": 23,
                    "relay_command_id": "cmd-23",
                    "agent_prompt": "Identical prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                delivered: list[dict] = []
                relay_turn = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-identical-session",
                    "provider": provider,
                    "prompt": "Identical prompt",
                }
                relay_stop = {
                    "hook_event_name": "Stop",
                    "session_id": f"{provider}-identical-session",
                    "provider": provider,
                    "last_assistant_message": "Relay final.",
                }
                manual_turn = dict(relay_turn)
                manual_stop = {
                    **relay_stop,
                    "last_assistant_message": "Manual final.",
                }
                if provider == "codex":
                    relay_turn["turn_id"] = "relay-turn"
                    relay_stop["turn_id"] = "relay-turn"
                    manual_turn["turn_id"] = "manual-turn"
                    manual_stop["turn_id"] = "manual-turn"

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    relay_turn,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=30,
                    stderr=io.StringIO(),
                ))
                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    relay_turn,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=30.1,
                    stderr=io.StringIO(),
                ))
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    relay_stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=31,
                    stderr=io.StringIO(),
                ))
                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    relay_stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=31.1,
                    stderr=io.StringIO(),
                ))

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    manual_turn,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=32,
                    stderr=io.StringIO(),
                ))
                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    manual_stop,
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=33,
                    stderr=io.StringIO(),
                ))

                records = json.loads(Path(turns_path).read_text())["records"]
                relay_records = [
                    record for record in records
                    if record.get("relay_command_id") == "cmd-23"
                ]
                manual_records = [
                    record for record in records
                    if record.get("origin") == "manual"
                ]
                self.assertEqual(len(relay_records), 1)
                self.assertEqual(relay_records[0]["state"], "completed_final")
                self.assertEqual(len(manual_records), 1)
                self.assertEqual(manual_records[0]["state"], "completed_manual")
                self.assertEqual(len(delivered), 1)
                self.assertEqual(delivered[0]["relay_command_id"], "cmd-23")
                self.assertEqual(delivered[0]["text"], "Relay final.")

    def test_completion_hook_reads_provider_native_active_context_fields(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_transcript = os.path.join(temp_dir, "codex.jsonl")
            Path(codex_transcript).write_text(json.dumps({
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {"total_tokens": 9_999_999},
                        "last_token_usage": {"total_tokens": 150000},
                    },
                },
            }) + "\n")
            self.assertEqual(
                relay_completion_hook._codex_active_context_tokens(codex_transcript),
                150000,
            )

            claude_transcript = os.path.join(temp_dir, "claude.jsonl")
            Path(claude_transcript).write_text(json.dumps({
                "type": "assistant",
                "isSidechain": False,
                "message": {
                    "usage": {
                        "input_tokens": 120000,
                        "cache_creation_input_tokens": 10000,
                        "cache_read_input_tokens": 20000,
                        "output_tokens": 50000,
                    }
                },
            }) + "\n")
            self.assertEqual(
                relay_completion_hook._claude_active_context_tokens(claude_transcript),
                150000,
            )
            with open(claude_transcript, "a") as transcript:
                transcript.write(json.dumps({
                    "type": "system",
                    "subtype": "compact_boundary",
                    "compactMetadata": {"preTokens": 150000, "postTokens": 32000},
                }) + "\n")
            self.assertEqual(
                relay_completion_hook._claude_active_context_tokens(claude_transcript),
                32000,
            )

    def test_compaction_diagnostics_are_bounded_and_distinguish_lifecycle(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            transcript = os.path.join(temp_dir, "provider.jsonl")
            events = os.path.join(temp_dir, "events.jsonl")
            Path(transcript).write_text(json.dumps({
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {"total_tokens": 9_999_999},
                        "last_token_usage": {"total_tokens": 150000},
                    },
                },
            }) + "\n")
            base = {
                "session_id": "session-compact",
                "transcript_path": transcript,
            }
            with mock.patch.dict(os.environ, {"RELAY_RUNNER_PROVIDER": "codex"}):
                relay_completion_hook._record_compaction_diagnostic(
                    {**base, "hook_event_name": "Stop"},
                    now=100,
                    events_path=events,
                )
                relay_completion_hook._record_compaction_diagnostic(
                    {**base, "hook_event_name": "PreCompact", "trigger": "auto"},
                    now=101,
                    events_path=events,
                )
                Path(transcript).write_text(json.dumps({
                    "type": "event_msg",
                    "payload": {
                        "type": "token_count",
                        "info": {
                            "total_token_usage": {"total_tokens": 9_999_999},
                            "last_token_usage": {"total_tokens": 32000},
                        },
                    },
                }) + "\n")
                relay_completion_hook._record_compaction_diagnostic(
                    {
                        **base,
                        "hook_event_name": "PostCompact",
                        "trigger": "auto",
                        "compact_summary": "private summary",
                    },
                    now=102,
                    events_path=events,
                )
                relay_completion_hook._record_compaction_diagnostic(
                    {**base, "hook_event_name": "StopFailure", "error": "server_error"},
                    now=103,
                    events_path=events,
                )

            records = [json.loads(line) for line in Path(events).read_text().splitlines()]
            self.assertEqual([record["stage"] for record in records], [
                "active_context_observed",
                "compaction_attempt",
                "compaction_confirmed",
                "provider_turn_failed",
            ])
            self.assertEqual(records[0]["threshold_state"], "exact")
            self.assertEqual(records[0]["outcome"], "idle")
            self.assertEqual(records[1]["attempt"], 1)
            self.assertEqual(records[1]["trigger"], "auto")
            self.assertTrue(records[2]["confirmation"])
            self.assertEqual(records[2]["attempt"], 1)
            self.assertEqual(records[2]["native_active_context_tokens"], 32000)
            self.assertEqual(records[2]["threshold_state"], "below")
            self.assertEqual(records[3]["failure_reason"], "server_error")
            self.assertTrue(all(record["provider"] == "codex" for record in records))
            rendered = Path(events).read_text()
            self.assertNotIn(transcript, rendered)
            self.assertNotIn("private summary", rendered)
            self.assertEqual(Path(events).stat().st_mode & 0o777, 0o600)

    def test_unconfirmed_compaction_remains_retryable_per_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            transcript = os.path.join(temp_dir, "codex.jsonl")
            events = os.path.join(temp_dir, "events.jsonl")
            Path(transcript).write_text(json.dumps({
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {"last_token_usage": {"total_tokens": 150001}},
                },
            }) + "\n")
            base = {
                "session_id": "session-retry",
                "transcript_path": transcript,
                "provider": "codex",
                "trigger": "auto",
            }

            relay_completion_hook._record_compaction_diagnostic(
                {**base, "hook_event_name": "PreCompact"},
                now=200,
                events_path=events,
            )
            relay_completion_hook._record_compaction_diagnostic(
                {**base, "hook_event_name": "PostCompact"},
                now=201,
                events_path=events,
            )
            Path(transcript).write_text(json.dumps({
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {"last_token_usage": {"total_tokens": 32000}},
                },
            }) + "\n")
            relay_completion_hook._record_compaction_diagnostic(
                {**base, "hook_event_name": "Stop"},
                now=202,
                events_path=events,
            )
            relay_completion_hook._record_compaction_diagnostic(
                {**base, "hook_event_name": "PreCompact"},
                now=203,
                events_path=events,
            )

            records = [json.loads(line) for line in Path(events).read_text().splitlines()]
            self.assertEqual(records[1]["stage"], "compaction_unconfirmed")
            self.assertFalse(records[1]["confirmation"])
            self.assertEqual(records[1]["failure_reason"], "native_context_not_reduced")
            self.assertEqual(records[2]["stage"], "compaction_confirmed")
            self.assertTrue(records[2]["confirmation"])
            self.assertEqual(records[2]["attempt"], 1)
            self.assertEqual([records[0]["attempt"], records[3]["attempt"]], [1, 2])

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

    def test_provider_hook_binds_recovered_and_middle_deliverable_intents(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as temp_dir:
                    state_path = os.path.join(temp_dir, "voice_command_state.json")
                    claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                    turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                    command_path = os.path.join(temp_dir, "voice_cmd_ready")
                    meta_path = command_path + ".meta"
                    inbox_path = os.path.join(temp_dir, "intent_inbox.sqlite3")
                    commands = [
                        {
                            "relay_command_seq": seq,
                            "relay_command_id": f"cmd-{seq}",
                            "intent_id": f"intent-{seq}",
                            "agent_prompt": f"Prompt {seq}",
                            "provider": provider,
                        }
                        for seq in (1, 2, 3)
                    ]
                    inbox = voice_bridge.IntentInbox(inbox_path)
                    for command in commands:
                        inbox.enqueue(command["agent_prompt"], command, "continue_current")
                    Path(state_path).write_text(json.dumps(commands[-1]))
                    voice_bridge.sync_deliverable_state(state_path, inbox)

                    inbox.materialize_next(
                        command_path=command_path,
                        metadata_path=meta_path,
                        transport="app-owned",
                    )
                    inbox.close()
                    os.remove(command_path)
                    os.remove(meta_path)

                    inbox = voice_bridge.IntentInbox(inbox_path)
                    recovered = inbox.materialize_next(
                        command_path=command_path,
                        metadata_path=meta_path,
                        transport="app-owned",
                    )
                    voice_bridge.sync_deliverable_state(state_path, inbox)

                    for index, claimed in enumerate((recovered, commands[1]), start=1):
                        self.assertIsNotNone(claimed)
                        Path(claim_path).write_text(json.dumps(claimed))
                        self.assertTrue(relay_completion_hook.handle_hook_payload(
                            {
                                "hook_event_name": "UserPromptSubmit",
                                "session_id": f"{provider}-rapid",
                                "turn_id": f"turn-{index}",
                                "prompt": claimed["agent_prompt"],
                                "provider": provider,
                            },
                            claim_path=claim_path,
                            state_path=state_path,
                            turns_path=turns_path,
                            now=100 + index,
                            stderr=io.StringIO(),
                        ))
                        self.assertTrue(inbox.observe_claim(
                            claimed,
                            provider_turn_seen=voice_bridge._provider_turn_seen(
                                claimed,
                                turns_path=turns_path,
                            ),
                        ))
                        os.remove(command_path)
                        os.remove(meta_path)
                        next_command = inbox.materialize_next(
                            command_path=command_path,
                            metadata_path=meta_path,
                            transport="app-owned",
                        )
                        voice_bridge.sync_deliverable_state(state_path, inbox)
                        if index == 1:
                            self.assertEqual(next_command["relay_command_id"], "cmd-2")

                    self.assertEqual(next_command["relay_command_id"], "cmd-3")
                    self.assertEqual(
                        [record["state"] for record in inbox.records()],
                        ["acked", "acked", "delivered"],
                    )
                    inbox.close()

    def test_restart_restores_recovered_reply_currentness_and_monotonic_sequence(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as temp_dir:
                    state_path = os.path.join(temp_dir, "voice_command_state.json")
                    claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                    turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                    command_path = os.path.join(temp_dir, "voice_cmd_ready")
                    meta_path = command_path + ".meta"
                    inbox_path = os.path.join(temp_dir, "intent_inbox.sqlite3")
                    command = {
                        "relay_command_seq": 7,
                        "relay_command_id": "cmd-7",
                        "intent_id": "intent-7",
                        "agent_prompt": "Recovered prompt",
                        "provider": provider,
                    }

                    inbox = voice_bridge.IntentInbox(inbox_path)
                    inbox.enqueue(command["agent_prompt"], command, "continue_current")
                    inbox.materialize_next(
                        command_path=command_path,
                        metadata_path=meta_path,
                        transport="app-owned",
                    )
                    inbox.close()
                    os.remove(command_path)
                    os.remove(meta_path)

                    restarted = voice_bridge.IntentInbox(inbox_path)
                    shutdown_event = threading.Event()
                    pump = voice_bridge._start_intent_inbox_pump(
                        restarted,
                        shutdown_event,
                        command_path=command_path,
                        meta_path=meta_path,
                        claimed_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        transport="app-owned",
                        poll_seconds=0.005,
                    )
                    try:
                        restored = json.loads(Path(state_path).read_text())
                        self.assertEqual(restored["relay_command_seq"], 7)
                        self.assertEqual(restored["relay_command_id"], "cmd-7")

                        for _ in range(100):
                            if os.path.exists(command_path) and os.path.exists(meta_path):
                                break
                            shutdown_event.wait(0.005)
                        self.assertTrue(os.path.exists(command_path))
                        recovered = json.loads(Path(meta_path).read_text())
                        Path(claim_path).write_text(json.dumps(recovered))

                        self.assertTrue(relay_completion_hook.handle_hook_payload(
                            {
                                "hook_event_name": "UserPromptSubmit",
                                "session_id": f"{provider}-restart",
                                "turn_id": "turn-7",
                                "prompt": recovered["agent_prompt"],
                                "provider": provider,
                            },
                            claim_path=claim_path,
                            state_path=state_path,
                            turns_path=turns_path,
                            now=70,
                            stderr=io.StringIO(),
                        ))
                        delivered: list[dict] = []
                        self.assertTrue(relay_completion_hook.handle_hook_payload(
                            {
                                "hook_event_name": "Stop",
                                "session_id": f"{provider}-restart",
                                "turn_id": "turn-7",
                                "last_assistant_message": "Recovered reply.",
                                "provider": provider,
                            },
                            claim_path=claim_path,
                            state_path=state_path,
                            turns_path=turns_path,
                            write_control=lambda payload: delivered.append(payload) or True,
                            now=71,
                            stderr=io.StringIO(),
                        ))
                        self.assertEqual(delivered[0]["relay_command_id"], "cmd-7")

                        next_command = voice_bridge._begin_relay_command(
                            "Next command",
                            state_path=state_path,
                            event_log_path=None,
                        )
                        self.assertEqual(next_command["relay_command_seq"], 8)
                    finally:
                        shutdown_event.set()
                        pump.join(timeout=1)
                        restarted.close()

    def test_manual_relay_bridge_claim_ack_advances_two_command_queue(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as temp_dir:
                    command_path = os.path.join(temp_dir, "voice_cmd_ready")
                    meta_path = command_path + ".meta"
                    claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                    manual_ack_path = os.path.join(temp_dir, "voice_cmd_manual_ack.json")
                    state_path = os.path.join(temp_dir, "voice_command_state.json")
                    turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                    inbox = voice_bridge.IntentInbox(
                        os.path.join(temp_dir, "intent_inbox.sqlite3")
                    )
                    for seq in (1, 2):
                        command = {
                            "relay_command_seq": seq,
                            "relay_command_id": f"cmd-{seq}",
                            "intent_id": f"intent-{seq}",
                            "agent_prompt": f"Manual prompt {seq}",
                            "provider": provider,
                        }
                        inbox.enqueue(
                            command["agent_prompt"],
                            command,
                            "continue_current",
                        )

                    shutdown_event = threading.Event()
                    pump = voice_bridge._start_intent_inbox_pump(
                        inbox,
                        shutdown_event,
                        command_path=command_path,
                        meta_path=meta_path,
                        claimed_path=claim_path,
                        manual_ack_path=manual_ack_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        transport="manual-relay-bridge",
                        poll_seconds=0.005,
                    )
                    try:
                        for _ in range(100):
                            if os.path.exists(command_path) and os.path.exists(meta_path):
                                break
                            shutdown_event.wait(0.005)
                        self.assertTrue(os.path.exists(command_path))

                        command_tmp = os.path.join(temp_dir, "claimed-command")
                        meta_tmp = command_tmp + ".meta"
                        os.replace(command_path, command_tmp)
                        os.replace(meta_path, meta_tmp)
                        Path(claim_path).write_bytes(Path(meta_tmp).read_bytes())
                        self.assertEqual(Path(command_tmp).read_text(), "Manual prompt 1")

                        for _ in range(100):
                            if inbox.records()[0]["state"] == "claimed":
                                break
                            shutdown_event.wait(0.005)
                        self.assertEqual(
                            [record["state"] for record in inbox.records()],
                            ["claimed", "pending"],
                        )
                        self.assertFalse(os.path.exists(command_path))
                        self.assertFalse(os.path.exists(turns_path))

                        Path(manual_ack_path).write_bytes(Path(meta_tmp).read_bytes())
                        os.unlink(command_tmp)
                        os.unlink(meta_tmp)

                        for _ in range(100):
                            if os.path.exists(command_path) and os.path.exists(meta_path):
                                break
                            shutdown_event.wait(0.005)
                        self.assertEqual(Path(command_path).read_text(), "Manual prompt 2")
                        self.assertEqual(
                            json.loads(Path(meta_path).read_text())["relay_command_id"],
                            "cmd-2",
                        )
                        self.assertEqual(
                            [record["state"] for record in inbox.records()],
                            ["acked", "delivered"],
                        )
                        self.assertFalse(os.path.exists(manual_ack_path))
                        self.assertFalse(os.path.exists(turns_path))
                    finally:
                        shutdown_event.set()
                        pump.join(timeout=1)
                        inbox.close()

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

    def test_completion_hook_drops_only_cancelled_item_from_shared_source_turn(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                Path(state_path).write_text(json.dumps({
                    "relay_command_seq": 1,
                    "relay_command_id": "multi",
                    "intent_id": "multi:item:2",
                    "cancelled_intent_ids": ["multi:item:1"],
                }))
                Path(turns_path).write_text(json.dumps({
                    "version": 1,
                    "records": [
                        {
                            "state": "active",
                            "session_id": f"{provider}-session",
                            "turn_id": "turn-1",
                            "relay_command_seq": 1,
                            "relay_command_id": "multi",
                            "intent_id": "multi:item:1",
                            "within_turn_order": 1,
                            "provider": provider,
                            "created_at": 1.0,
                            "updated_at": 1.0,
                        },
                        {
                            "state": "active",
                            "session_id": f"{provider}-session",
                            "turn_id": "turn-2",
                            "relay_command_seq": 1,
                            "relay_command_id": "multi",
                            "intent_id": "multi:item:2",
                            "within_turn_order": 2,
                            "provider": provider,
                            "created_at": 2.0,
                            "updated_at": 2.0,
                        },
                    ],
                }))
                completions: list[dict] = []

                cancelled = relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "Stop",
                        "session_id": f"{provider}-session",
                        "turn_id": "turn-1",
                        "provider": provider,
                        "last_assistant_message": "cancelled output",
                    },
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: completions.append(payload) or True,
                    now=3.0,
                    stderr=io.StringIO(),
                )
                surviving = relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "Stop",
                        "session_id": f"{provider}-session",
                        "turn_id": "turn-2",
                        "provider": provider,
                        "last_assistant_message": "surviving output",
                    },
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: completions.append(payload) or True,
                    now=4.0,
                    stderr=io.StringIO(),
                )

                self.assertFalse(cancelled)
                self.assertTrue(surviving)
                self.assertEqual([item["intent_id"] for item in completions], ["multi:item:2"])

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
        self.assertIn("intent_arbitration.py", script)
        self.assertIn("intent_inbox.py", script)
        self.assertIn("sidecar_lane.py", script)
        self.assertIn("speech_coordinator.py", script)
        self.assertIn("codex_model_catalog.py", script)
        self.assertNotIn('if [ -f "$PROJECT_ROOT/services/$f" ]', script)

    def test_build_bundle_includes_swiftterm_metal_resources(self):
        script_path = os.path.join(ROOT, "scripts", "build-dmg.sh")
        with open(script_path) as f:
            script = f.read()

        self.assertIn('SWIFTTERM_RESOURCE_BUNDLE="$BUILD_DIR/SwiftTerm_SwiftTerm.bundle"', script)
        self.assertIn('cp -R "$SWIFTTERM_RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"', script)
        self.assertIn('error: SwiftTerm resource bundle not found after swift build', script)

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

    def test_negated_stop_status_composes_as_additive_for_codex_and_claude(self):
        source_text = "don't stop the current work; just give me status"
        active_work = (voice_bridge.ActiveWork("1:active", ("repository",)),)

        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                relay_command = {
                    "provider": provider,
                    "relay_command_seq": 2,
                    "relay_command_id": f"{provider}-cmd-2",
                    "source_text": source_text,
                }
                action = voice_bridge.resolve_command_action(
                    source_text,
                    repo_path="/tmp/repo",
                    relay_command=relay_command,
                )
                disposition = voice_bridge.resolve_intent_disposition(
                    intent_id=relay_command["relay_command_id"],
                    action_kind=action.kind,
                    action_reason=action.reason,
                    source_text=source_text,
                    active_work=active_work,
                )
                metadata = voice_bridge._metadata_for_action(
                    action,
                    relay_command,
                    disposition,
                )

                self.assertEqual(action.kind, "conversation")
                self.assertEqual(
                    disposition.route,
                    voice_bridge.IntentRoute.CONTINUE_CURRENT,
                )
                self.assertEqual(
                    disposition.authorization_effect.value,
                    "preserve",
                )
                self.assertEqual(metadata["authorization_relationship"], "conversation")
                self.assertFalse(metadata["preempt_provider"])
                self.assertEqual(metadata["provider"], provider)

    def test_real_same_turn_work_resolves_to_two_provider_neutral_deliveries(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                command = {
                    "provider": provider,
                    "relay_command_seq": 11,
                    "relay_command_id": f"{provider}-11",
                    "source_text": "Fix login and add search",
                }

                resolved = voice_bridge._resolve_voice_work_items(
                    command["source_text"],
                    command,
                    repo_path="/tmp/repo",
                )

                self.assertEqual(
                    [entry["item"].source_text for entry in resolved],
                    ["Fix login", "add search"],
                )
                self.assertEqual(
                    [entry["action"].kind for entry in resolved],
                    ["create_ticket", "create_ticket"],
                )
                self.assertEqual(
                    [entry["metadata"]["within_turn_order"] for entry in resolved],
                    [1, 2],
                )
                self.assertEqual(
                    [entry["metadata"]["provider"] for entry in resolved],
                    [provider, provider],
                )

    def test_partial_leased_cancellation_requeues_survivor_for_codex_and_claude(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                command_path = os.path.join(temp_dir, "voice_cmd_ready")
                meta_path = command_path + ".meta"
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                inbox = voice_bridge.IntentInbox(os.path.join(temp_dir, "inbox.sqlite3"))
                command = {
                    "provider": provider,
                    "relay_command_seq": 1,
                    "relay_command_id": f"{provider}-1",
                    "source_text": "Fix login and add search",
                }
                resolved = voice_bridge._resolve_voice_work_items(
                    command["source_text"],
                    command,
                    repo_path=temp_dir,
                )
                for entry in resolved:
                    voice_bridge._publish_command(
                        entry["prompt"],
                        entry["metadata"],
                        command_path=command_path,
                        meta_path=meta_path,
                        state_path=state_path,
                        inbox=inbox,
                    )
                self.assertEqual(json.loads(Path(meta_path).read_text())["target"], "login")

                cancellation = {
                    "provider": provider,
                    "relay_command_seq": 2,
                    "relay_command_id": f"{provider}-2",
                    "source_text": "Cancel login",
                }
                cancelled = voice_bridge._resolve_voice_work_items(
                    cancellation["source_text"],
                    cancellation,
                    repo_path=temp_dir,
                )[0]
                voice_bridge._publish_command(
                    cancelled["prompt"],
                    cancelled["metadata"],
                    command_path=command_path,
                    meta_path=meta_path,
                    state_path=state_path,
                    inbox=inbox,
                )

                leased = json.loads(Path(meta_path).read_text())
                self.assertEqual(leased["target"], "search")
                self.assertEqual(leased["relay_command_seq"], 1)
                self.assertFalse(cancelled["metadata"]["preempt_provider"])
                records = inbox.records()
                self.assertEqual(records[0]["state"], "cancelled")
                self.assertEqual(records[1]["state"], "delivered")
                self.assertEqual(records[2]["state"], "pending")

    def test_replacement_language_revokes_only_resolved_item_for_both_providers(self):
        active_work = (
            voice_bridge.ActiveWork("login-item", ("repository",), "login"),
            voice_bridge.ActiveWork("search-item", ("repository",), "search"),
        )

        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                auth_path = os.path.join(temp_dir, "voice_command_authorizations.json")
                for order, work in enumerate(active_work, start=1):
                    voice_bridge.record_command_authorization(
                        auth_path,
                        {
                            "relay_command_seq": order,
                            "relay_command_id": f"{provider}-accepted-{order}",
                            "intent_id": work.work_id,
                            "target": work.target,
                        },
                        relationship="additive",
                        allowed_mutations=[{"kind": "orchestrator_command"}],
                    )

                command = {
                    "provider": provider,
                    "relay_command_seq": 3,
                    "relay_command_id": f"{provider}-replace",
                    "source_text": "Replace that with export",
                }
                replacement = voice_bridge._resolve_voice_work_items(
                    command["source_text"],
                    command,
                    repo_path=temp_dir,
                    active_work=active_work,
                )[0]
                disposition = replacement["disposition"]
                metadata = replacement["metadata"]

                self.assertEqual(
                    disposition.cancellation_scope,
                    voice_bridge.CancellationScope.ITEM,
                )
                self.assertEqual(disposition.target_work_ids, ("search-item",))
                self.assertEqual(metadata["cancellation_scope"], "item")
                self.assertEqual(metadata["target_intent_ids"], ["search-item"])
                self.assertEqual(
                    metadata["voice_work_item"]["cancellation_scope"],
                    "item",
                )
                self.assertEqual(
                    metadata["voice_work_item"]["target_intent_ids"],
                    ["search-item"],
                )
                self.assertEqual(
                    metadata["provider_preempt_intent_ids"],
                    ["search-item"],
                )

                voice_bridge.record_command_authorization(
                    auth_path,
                    metadata,
                    relationship=metadata["authorization_relationship"],
                    allowed_mutations=voice_bridge.allowed_mutations_for_metadata(metadata),
                )
                records = {
                    record["intent_id"]: record
                    for record in json.loads(Path(auth_path).read_text())["authorizations"]
                }
                self.assertEqual(records["login-item"]["status"], "active")
                self.assertEqual(records["search-item"]["status"], "revoked")

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

    def test_explicit_replace_releases_cancelled_inbox_transport_lease(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            inbox = voice_bridge.IntentInbox(os.path.join(temp_dir, "inbox.sqlite3"))

            first = {
                "relay_command_seq": 1,
                "relay_command_id": "cmd-1",
                "intent_id": "intent-1",
                "action": "create_ticket",
                "work_disposition": {"route": "queue_project_work"},
            }
            replacement = {
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "intent-2",
                "action": "create_ticket",
                "work_disposition": {"route": "replace_current"},
            }

            voice_bridge._publish_command(
                "first",
                first,
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                inbox=inbox,
            )
            self.assertEqual(Path(command_path).read_text(), "first")

            voice_bridge._publish_command(
                "replacement",
                replacement,
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
                inbox=inbox,
            )

            self.assertEqual(Path(command_path).read_text(), "replacement")
            self.assertEqual(
                [record["state"] for record in inbox.records()],
                ["cancelled", "delivered"],
            )
            state = json.loads(Path(state_path).read_text())
            self.assertEqual(
                [item["relay_command_id"] for item in state["deliverable_commands"]],
                ["cmd-2"],
            )

    def test_app_owned_sidecar_uses_lane_without_foreground_mailbox_deferral(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = command_path + ".meta"
            inbox = voice_bridge.IntentInbox(os.path.join(temp_dir, "inbox.sqlite3"))
            lane = FakeSidecarLane()
            command = {
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "intent-2",
                "source_text": "In parallel, research and compare the public APIs",
                "work_disposition": {
                    "route": "run_sidecar",
                    "public_reason": "Independent bounded public research.",
                },
            }

            accepted = voice_bridge._enqueue_sidecar_intent(
                prompt="sidecar agent prompt",
                source_text=command["source_text"],
                metadata=command,
                sidecar_lane=lane,
                inbox=inbox,
                state_path=state_path,
            )

            self.assertTrue(accepted)
            self.assertFalse(os.path.exists(command_path))
            self.assertFalse(os.path.exists(meta_path))
            self.assertIsNone(inbox.materialize_next(
                command_path=command_path,
                metadata_path=meta_path,
                transport="app-owned",
            ))
            self.assertEqual(lane.submissions[0][0], command["source_text"])
            self.assertEqual(inbox.records()[0]["route"], "run_sidecar")
            self.assertEqual(inbox.records()[0]["state"], "pending")

            messenger = FakeMessenger()
            started = voice_bridge.SidecarLifecycleEvent(
                phase="started",
                command=lane.submissions[0][1],
                public_summary="Independent bounded public research.",
            )
            completed = voice_bridge.SidecarLifecycleEvent(
                phase="completed",
                command=lane.submissions[0][1],
                public_summary="Independent bounded public research.",
            )
            self.assertTrue(voice_bridge._handle_sidecar_lifecycle(
                started,
                inbox=inbox,
                messenger=messenger,
                state_path=state_path,
            ))
            self.assertEqual(inbox.records()[0]["state"], "claimed")
            self.assertTrue(voice_bridge._handle_sidecar_lifecycle(
                completed,
                inbox=inbox,
                messenger=messenger,
                state_path=state_path,
            ))
            self.assertEqual(inbox.records()[0]["state"], "acked")
            self.assertEqual(
                [trace["kind"] for trace in messenger.traces],
                ["sidecar-started", "sidecar-completed"],
            )

    def test_sidecar_final_uses_work_valid_lifecycle_speech_after_newer_turn(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = {
                "relay_command_seq": 4,
                "relay_command_id": "cmd-4",
                "work_disposition": {
                    "route": "run_sidecar",
                    "public_reason": "Independent bounded public research.",
                },
            }
            Path(state_path).write_text(json.dumps(command))
            speech_queue = CapturingSpeechQueue()
            worker = types.SimpleNamespace(input_queue=speech_queue)
            voice_bridge._reset_foreground_reply_delivery_for_tests()

            with mock.patch.object(voice_bridge, "_publish_authoritative_preview"):
                delivered = voice_bridge._handle_sidecar_final(
                    "The APIs differ in their retry contracts.",
                    command,
                    tts_worker=worker,
                    messenger=None,
                    state_path=state_path,
                )

            self.assertTrue(delivered)
            self.assertEqual(len(speech_queue.submissions), 1)
            spoken, speech_metadata = speech_queue.submissions[0]
            self.assertEqual(spoken, "The APIs differ in their retry contracts.")
            self.assertEqual(speech_metadata["source"], "lifecycle")
            self.assertEqual(speech_metadata["kind"], "final")
            self.assertTrue(speech_metadata["authoritative"])
            self.assertEqual(
                speech_metadata["work_disposition"]["route"],
                "run_sidecar",
            )

            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 5,
                "relay_command_id": "cmd-5",
            }))
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            self.assertTrue(voice_bridge._handle_sidecar_final(
                "Still useful sidecar result.",
                command,
                tts_worker=worker,
                messenger=None,
                state_path=state_path,
            ))
            self.assertEqual(len(speech_queue.submissions), 2)
            spoken, speech_metadata = speech_queue.submissions[-1]
            self.assertEqual(spoken, "Still useful sidecar result.")
            self.assertEqual(speech_metadata["freshness_scope"], "work")
            self.assertEqual(speech_metadata["command_seq"], 4)
            self.assertEqual(speech_metadata["command_id"], "cmd-4")

    def test_sidecar_outcome_crosses_messenger_and_coordinator_for_both_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                with tempfile.TemporaryDirectory() as temp_dir:
                    voice_bridge._reset_foreground_reply_delivery_for_tests()
                    state_path = os.path.join(temp_dir, "voice_command_state.json")
                    current = {"relay_command_seq": 8, "relay_command_id": "cmd-8"}
                    Path(state_path).write_text(json.dumps(current))
                    executor = FakeTTSWorker()
                    coordinator = voice_bridge.SpeechCoordinator(
                        executor,
                        is_current=lambda seq, command_id: (seq, command_id) == (8, "cmd-8"),
                    )

                    def speak(text, command_seq, command_id, display_text, speech_metadata):
                        return voice_bridge._queue_tts_text(
                            json.dumps({
                                "text": text,
                                "display_text": display_text,
                                "relay_command_seq": command_seq,
                                "relay_command_id": command_id,
                            }),
                            coordinator.input_queue,
                            state_path=state_path,
                            allow_pending_command=True,
                            notify_waiting_preview=lambda _text: None,
                            **speech_metadata,
                        )

                    messenger = voice_bridge.MessengerRuntime(
                        ImmediateMessengerBackend("Here is the completed sidecar result."),
                        speak=speak,
                        is_current=lambda seq, command_id: (seq, command_id) == (8, "cmd-8"),
                        coverage_provider=coordinator.played_coverage,
                        realization_observer=coordinator.record_realization,
                    )
                    messenger.start()
                    self.addCleanup(messenger.shutdown)
                    command = {
                        "relay_command_seq": 4,
                        "relay_command_id": "cmd-4",
                        "provider": provider,
                        "work_disposition": {"route": "run_sidecar"},
                    }

                    with mock.patch.object(voice_bridge, "_publish_authoritative_preview"):
                        self.assertTrue(voice_bridge._handle_sidecar_final(
                            "Authoritative sidecar evidence.",
                            command,
                            tts_worker=coordinator,
                            messenger=messenger,
                            state_path=state_path,
                        ))

                    queued = executor.input_queue.get(timeout=1)
                    speech_intent = queued["_speech_intent"]
                    self.assertEqual(speech_intent["command_seq"], 4)
                    self.assertEqual(speech_intent["command_id"], "cmd-4")
                    self.assertEqual(speech_intent["source"], "lifecycle")
                    self.assertEqual(speech_intent["kind"], "final")
                    self.assertEqual(speech_intent["freshness_scope"], "work")
                    self.assertEqual(speech_intent["realization_decision"], "full")
                    self.assertTrue(executor.eligibility(speech_intent))

    def test_barge_in_makes_pending_coordinated_speech_ineligible(self):
        state = {"key": (1, "cmd-1")}
        executor = FakeTTSWorker()
        coordinator = voice_bridge.SpeechCoordinator(
            executor,
            is_current=lambda seq, command_id: state["key"] == (seq, command_id),
        )
        pending = SpeechIntent.build(
            spoken_text="Pending provider-neutral speech.",
            command_seq=1,
            command_id="cmd-1",
            source="orchestrator",
            kind="final",
            authoritative=True,
        )
        self.assertTrue(coordinator.submit(pending))

        self.assertTrue(voice_bridge._handle_relay_control_message(
            "__TTS_STOP__",
            coordinator,
        ))

        queued = executor.input_queue.get_nowait()["_speech_intent"]
        self.assertFalse(executor.eligibility(queued))
        state["key"] = (2, "cmd-2")
        coordinator.new_turn(2, "cmd-2")
        self.assertFalse(executor.eligibility(queued))
        coordinator.play()
        self.assertEqual(executor.calls, ["stop_playback"])

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

    def test_project_work_is_durably_queued_for_foreground_pm(self):
        relay_command = {"relay_command_seq": 1, "relay_command_id": "cmd-1"}
        action = voice_bridge.resolve_command_action(
            "fix the login bug",
            repo_path="/tmp/repo",
            relay_command=relay_command,
        )

        self.assertTrue(voice_bridge._should_fanout_raw_instruction_to_orchestrator(action))

        conversation = voice_bridge.resolve_command_action(
            "why is the board not updating",
            repo_path="/tmp/repo",
            relay_command=relay_command,
        )
        self.assertFalse(
            voice_bridge._should_fanout_raw_instruction_to_orchestrator(conversation)
        )

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
            self.assertEqual(stat.S_IMODE(os.stat(temp_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(event_path).st_mode), 0o600)

    def test_delivery_failed_recovery_names_the_actual_outcome(self):
        notifications: list[tuple[str, dict]] = []

        message = voice_bridge._surface_recoverable_command_status(
            {
                "recoverable_commands": [{
                    "relay_command_seq": 8,
                    "relay_command_id": "delivery-failed",
                    "status": "delivery_failed",
                }],
            },
            messenger=None,
            notify_state=lambda state, **payload: notifications.append((state, payload)),
        )

        self.assertIn("Delivery failed", message)
        self.assertIn("before a ticket action was confirmed", message)
        self.assertEqual(notifications, [("working", {"text": message})])

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
        self.assertEqual(
            script.count(
                'if [ -f "$meta_tmp" ]; then cp "$meta_tmp" '
                "/tmp/voice_cmd_manual_ack.json.tmp"
            ),
            4,
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
            script.index("Then send your authoritative user-facing response through Relay's canonical reply helper")
        ]
        codex_cleanup = script[
            script.index("After each handled command, stop only that command's heartbeat refresher"):
            script.index("Send the authoritative user-facing response through Relay's canonical reply helper")
        ]

        for cleanup in [claude_cleanup, codex_cleanup]:
            self.assertIn("preserving session metadata for app watchdog recovery", cleanup)
            self.assertIn("cat /tmp/voice_bridge.cwd", cleanup)
            self.assertIn("cat /tmp/voice_bridge.provider", cleanup)
            self.assertNotIn("rm -f /tmp/voice_in.fifo", cleanup)
            self.assertNotIn("voice_bridge.cwd /tmp/voice_bridge.provider", cleanup)
            self.assertNotIn("launchctl remove com.relay.voicebridge", cleanup)
            self.assertNotIn("VOICE_BRIDGE_LOG_REASON=restart", cleanup)

        self.assertNotIn("os.O_WRONLY | os.O_NONBLOCK", script)
        self.assertNotIn("python3 - <<'PY' > /tmp/tts_in.fifo", script)
        self.assertNotIn('print("__ORCHESTRATOR_REPLY__:" + json.dumps(payload)', script)
        self.assertEqual(
            script.count(
                "printf '%s' 'YOUR_AUTHORITATIVE_RESPONSE' | "
                "/usr/bin/python3 '__RELAY_REPLY_HELPER__'"
            ),
            2,
        )
        self.assertEqual(
            script.count('-e "s|__RELAY_REPLY_HELPER__|$relay_reply_helper_path|g"'),
            2,
        )
        self.assertEqual(script.count('"kind":"reasoning-summary"'), 2)
        self.assertNotIn("Voice bridge is ready. You can speak at any point.", script)

    def test_build_bundle_includes_provider_completion_hook_service(self):
        script_path = os.path.join(ROOT, "scripts", "build-dmg.sh")
        with open(script_path) as f:
            script = f.read()

        self.assertIn("relay_completion_hook.py", script)
        self.assertIn("relay_reply.py", script)


if __name__ == "__main__":
    unittest.main()
