from __future__ import annotations

import ast
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
from provider_turn_broker import ProviderTurnBroker  # noqa: E402
from speech_coordinator import SpeechIntent  # noqa: E402


def claim_ready_command(path: str) -> str:
    claim = path + ".claim"
    os.rename(path, claim)
    try:
        with open(claim) as f:
            return f.read()
    finally:
        os.remove(claim)


def wait_until(predicate, timeout: float = 1.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


class FakeTTSWorker:
    def __init__(self):
        self.calls: list[str] = []
        self.input_queue: queue.Queue = queue.Queue()
        self.eligibility = None
        self.observer = None

    def set_speech_callbacks(self, *, eligibility, observer):
        self.eligibility = eligibility
        self.observer = observer

    def stop_playback(self, *, reason="user_stop"):
        self.stop_reason = reason
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


class SynchronousTTSWorker(FakeTTSWorker):
    """Collect speech immediately, matching the production TTS queue boundary."""

    class InputQueue:
        def __init__(self, worker):
            self.worker = worker

        def put(self, payload):
            self.worker.collect(payload)

        def empty(self):
            return self.worker.pending is None

    def __init__(self, *, on_preview=None, on_queued=None):
        super().__init__()
        self.input_queue = self.InputQueue(self)
        self.on_preview = on_preview
        self.on_queued = on_queued
        self.pending = None
        self.current = None
        self.queued_payloads: list[dict] = []
        self.cancelled_payloads: list[dict] = []

    def collect(self, payload):
        intent = payload["_speech_intent"]
        if not self.eligibility(intent):
            self.cancelled_payloads.append(payload)
            self.observer("cancelled", intent)
            return
        if self.pending is not None:
            self.observer("cancelled", self.pending["_speech_intent"])
        self.pending = payload
        self.queued_payloads.append(payload)
        self.observer("queued", intent)
        if self.on_preview is not None:
            self.on_preview(payload["display_text"], intent)
        if self.on_queued is not None:
            self.on_queued(payload)

    def skip(self):
        super().skip()
        if self.current is not None:
            self.observer("cancelled", self.current["_speech_intent"])
            self.current = None
        if self.pending is not None:
            self.observer("cancelled", self.pending["_speech_intent"])
            self.pending = None

    def play(self):
        super().play()
        if self.pending is None:
            return
        intent = self.pending["_speech_intent"]
        if not self.eligibility(intent):
            self.cancelled_payloads.append(self.pending)
            self.pending = None
            self.observer("cancelled", intent)
            return
        self.current = self.pending
        self.pending = None
        self.observer("preparing", intent)
        self.observer("started", intent)

    def complete(self):
        payload = self.current
        self.current = None
        self.observer("completed", payload["_speech_intent"])


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
        ownership = mock.patch.dict(os.environ, {
            "RELAY_APP_SESSION_ID": "test-app-session",
            "RELAY_RECOVERY_GENERATION": "test-generation",
            "RELAY_ACTOR_ROLE": "foreground_pm",
            "RELAY_FOREGROUND_GATE_HANDLE": "test-gate",
        })
        ownership.start()
        self.addCleanup(ownership.stop)

    @staticmethod
    def foreground_ownership():
        return {
            "app_session_id": "test-app-session",
            "recovery_generation": "test-generation",
            "actor_role": "foreground_pm",
            "foreground_gate_handle": "test-gate",
        }

    def write_manual_submission_evidence(
        self,
        temp_dir: str,
        *,
        provider: str,
        provider_session_id: str,
        observed_at: float,
        **overrides,
    ) -> str:
        path = os.path.join(temp_dir, "relay_terminal_manual_submission.json")
        evidence = {
            **self.foreground_ownership(),
            "version": 1,
            "state": "pending",
            "submission_id": f"manual-{provider}-{observed_at}",
            "evidence_source": "relay_terminal_manual_submit",
            "observed_at": observed_at,
            "provider": provider,
            "provider_session_id": provider_session_id,
            **overrides,
        }
        Path(path).write_text(json.dumps(evidence))
        return path

    def test_relay_submits_messenger_before_command_classification(self):
        worker = FakeTTSWorker()
        messenger = FakeMessenger()
        shutdown_event = threading.Event()

        def read_once(_fd, _size):
            shutdown_event.set()
            return b"Investigate the speech delay\n"

        def resolve_after_submit(*_args, **_kwargs):
            self.assertEqual(len(messenger.users), 1)
            self.assertEqual(messenger.users[0][0], "Investigate the speech delay")
            return []

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge.os, "read", side_effect=read_once),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_begin_relay_command", return_value={
                "relay_command_seq": 1,
                "relay_command_id": "fast-submit",
                "received_at": 1.0,
            }),
            mock.patch.object(voice_bridge, "_active_work", return_value=[]),
            mock.patch.object(
                voice_bridge,
                "_resolve_voice_work_items",
                side_effect=resolve_after_submit,
            ),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement"),
        ):
            voice_bridge._run_relay(worker, shutdown_event, messenger=messenger)

        self.assertEqual(messenger.users[0][1]["relay_command_id"], "fast-submit")

    def test_explicitly_disabled_messenger_does_not_emit_degraded_prompt(self):
        worker = FakeTTSWorker()
        shutdown_event = threading.Event()

        def read_once(_fd, _size):
            shutdown_event.set()
            return b"Keep working\n"

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge.os, "read", side_effect=read_once),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_begin_relay_command", return_value={
                "relay_command_seq": 1,
                "relay_command_id": "messenger-disabled",
                "received_at": 1.0,
            }),
            mock.patch.object(voice_bridge, "_active_work", return_value=[]),
            mock.patch.object(voice_bridge, "_resolve_voice_work_items", return_value=[]),
            mock.patch.object(voice_bridge, "_queue_voice_acknowledgement"),
            mock.patch.object(voice_bridge, "_queue_messenger_degraded") as degraded,
        ):
            voice_bridge._run_relay(
                worker,
                shutdown_event,
                messenger=None,
                messenger_expected=False,
            )

        degraded.assert_not_called()

    def test_enabled_unavailable_messenger_queues_visible_audible_degraded_response_and_delivers_foreground(self):
        action = types.SimpleNamespace(kind="non_work", outcome="foreground command")
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                worker = FakeTTSWorker()
                speech = CapturingSpeechQueue()
                worker.input_queue = speech
                shutdown_event = threading.Event()

                def read_once(_fd, _size):
                    shutdown_event.set()
                    return b"Investigate the missing Messenger response\n"

                command = {
                    "relay_command_seq": 1,
                    "relay_command_id": f"missing-{provider}",
                    "provider": provider,
                }
                self.publish_waiting_preview.reset_mock()
                with (
                    mock.patch.object(voice_bridge.os, "unlink"),
                    mock.patch.object(voice_bridge.os, "close"),
                    mock.patch.object(voice_bridge.os, "read", side_effect=read_once),
                    mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
                    mock.patch.object(voice_bridge, "open_fifo", return_value=123),
                    mock.patch.object(voice_bridge.select, "select", return_value=([123], [], [])),
                    mock.patch.object(voice_bridge.threading, "Thread"),
                    mock.patch.object(voice_bridge, "_begin_relay_command", return_value=command),
                    mock.patch.object(voice_bridge, "_relay_command_current", return_value=True),
                    mock.patch.object(voice_bridge, "resolve_command_action", return_value=action),
                    mock.patch.object(voice_bridge, "format_command_for_agent", return_value="agent prompt"),
                    mock.patch.object(voice_bridge, "_metadata_for_action", return_value={
                        **command,
                        "action": "non_work",
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
                        messenger=None,
                        messenger_expected=True,
                    )

                degraded = [
                    (text, metadata)
                    for text, metadata in speech.submissions
                    if text == voice_bridge.MESSENGER_DEGRADED_TEXT
                ]
                self.assertEqual(len(degraded), 1)
                self.assertEqual(degraded[0][1]["source"], "fallback")
                self.assertEqual(degraded[0][1]["kind"], "handoff")
                self.assertEqual(degraded[0][1]["command_id"], f"missing-{provider}")
                self.assertIn(
                    mock.call(voice_bridge.MESSENGER_DEGRADED_TEXT),
                    self.publish_waiting_preview.call_args_list,
                )
                publish_command.assert_called_once()

    def test_completion_hook_requires_matching_foreground_owner_for_both_providers(self):
        for provider in ("codex", "claude"):
            with tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                command = {
                    "relay_command_seq": 1,
                    "relay_command_id": f"{provider}-command",
                    "agent_prompt": "bounded prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(command))
                Path(claim_path).write_text(json.dumps(command))
                prompt = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-session",
                    "turn_id": f"{provider}-turn",
                    "prompt": "bounded prompt",
                }

                with mock.patch.dict(os.environ, {
                    "RELAY_ACTOR_ROLE": "messenger",
                    "RELAY_RUNNER_PROVIDER": provider,
                }):
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        prompt,
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        stderr=io.StringIO(),
                    ))
                self.assertFalse(Path(turns_path).exists())

                with mock.patch.dict(os.environ, {"RELAY_RUNNER_PROVIDER": provider}):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        prompt,
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        stderr=io.StringIO(),
                    ))
                record = json.loads(Path(turns_path).read_text())["records"][0]
                self.assertEqual(record["app_session_id"], "test-app-session")
                self.assertEqual(record["recovery_generation"], "test-generation")
                self.assertEqual(record["actor_role"], "foreground_pm")
                self.assertEqual(record["foreground_gate_handle"], "test-gate")

                delivered = []
                stop = {
                    "hook_event_name": "Stop",
                    "session_id": f"{provider}-session",
                    "turn_id": f"{provider}-turn",
                    "last_assistant_message": "authoritative final",
                }
                with mock.patch.dict(os.environ, {
                    "RELAY_FOREGROUND_GATE_HANDLE": "competing-gate",
                    "RELAY_RUNNER_PROVIDER": provider,
                }):
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        stop,
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        stderr=io.StringIO(),
                    ))
                self.assertEqual(delivered, [])

                with mock.patch.dict(os.environ, {"RELAY_RUNNER_PROVIDER": provider}):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        stop,
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        stderr=io.StringIO(),
                    ))
                self.assertEqual(delivered[0]["text"], "authoritative final")

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

    def test_relay_readiness_waits_for_fifo_initialization(self):
        worker = FakeTTSWorker()
        shutdown_event = threading.Event()
        ready = mock.Mock()

        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=None),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_queue_tts_text", return_value=True),
        ):
            self.assertFalse(voice_bridge._run_relay(worker, shutdown_event, on_ready=ready))
        ready.assert_not_called()

        shutdown_event.set()
        with (
            mock.patch.object(voice_bridge.os, "unlink"),
            mock.patch.object(voice_bridge.os, "close"),
            mock.patch.object(voice_bridge, "ensure_fifo", return_value=True),
            mock.patch.object(voice_bridge, "open_fifo", return_value=123),
            mock.patch.object(voice_bridge.threading, "Thread"),
            mock.patch.object(voice_bridge, "_queue_tts_text", return_value=True),
        ):
            self.assertTrue(voice_bridge._run_relay(worker, shutdown_event, on_ready=ready))
        ready.assert_called_once_with()

    def test_bridge_readiness_preserves_provider_parity(self):
        for provider in ("codex", "claude"):
            with (
                self.subTest(provider=provider),
                mock.patch.dict(os.environ, {"RELAY_RUNNER_PROVIDER": provider}),
                mock.patch.object(voice_bridge, "record_support_event") as record,
            ):
                voice_bridge._record_bridge_readiness("ready")

            record.assert_called_once_with(
                process="shell",
                phase="bridge_readiness",
                outcome="ready",
                provider=provider,
            )

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
            mock.patch.object(
                voice_bridge,
                "_relay_command_current_or_preserved",
                return_value=True,
            ),
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

    def test_authoritative_playback_gate_and_preview_follow_accepted_intent(self):
        events: list[str] = []

        class OrderedSpeechQueue:
            def __init__(self, accepted: bool):
                self.accepted = accepted

            def submit_text(self, text: str, **metadata) -> bool:
                del text, metadata
                events.append("queued")
                return self.accepted

            def arm_waiting_playback(
                self,
                command_seq: int,
                command_id: str,
                *,
                kind: str = "final",
            ) -> None:
                del command_seq, command_id, kind
                events.append("armed")

        payload = json.dumps({
            "text": "The authoritative result.",
            "relay_command_seq": 7,
            "relay_command_id": "command-7",
        })
        with mock.patch.object(voice_bridge, "_relay_command_current", return_value=True):
            self.assertTrue(voice_bridge._queue_tts_text(
                payload,
                OrderedSpeechQueue(True),
                allow_pending_command=True,
                notify_waiting_preview=lambda _text: events.append("preview"),
                source="orchestrator",
                kind="final",
                authoritative=True,
            ))
        self.assertEqual(events, ["queued", "armed", "preview"])

        events.clear()
        with mock.patch.object(voice_bridge, "_relay_command_current", return_value=True):
            self.assertFalse(voice_bridge._queue_tts_text(
                payload,
                OrderedSpeechQueue(False),
                allow_pending_command=True,
                notify_waiting_preview=lambda _text: events.append("preview"),
                source="orchestrator",
                kind="final",
                authoritative=True,
            ))
        self.assertEqual(events, ["queued"])

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

    def test_long_progress_keeps_compact_notch_and_complete_messenger_detail(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            relay_command = voice_bridge._begin_relay_command(
                "review blocked verification",
                state_path=state_path,
                event_log_path=None,
            )
            detail = (
                "I found three verification-blocked tickets. I am separating their real-world "
                "evidence requirements from the checks that can run in this worktree now."
            )
            notifications: list[tuple[str, dict]] = []
            messenger = FakeMessenger()

            emitted = voice_bridge.emit_orchestration_trace(
                kind="reasoning-summary",
                relay_command=relay_command,
                message=detail,
                messenger=messenger,
                state_path=state_path,
                notify_state=lambda state, **kwargs: notifications.append((state, kwargs)),
            )

            self.assertTrue(emitted)
            compact = notifications[0][1]["text"]
            self.assertLessEqual(len(compact), 96)
            self.assertTrue(compact.endswith("..."))
            self.assertEqual(messenger.traces[0]["message"], compact)
            self.assertEqual(messenger.traces[0]["lifecycle_detail"], detail)

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
            preview.assert_not_called()
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
                previews = []
                coordinator = None
                executor = SynchronousTTSWorker(
                    on_preview=lambda text, speech: (
                        previews.append((text, speech)),
                        voice_bridge._handle_relay_control_message(
                            "__PLAY__",
                            coordinator,
                        ),
                    )
                )
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
                messenger = RejectingMessenger()
                payload = json.dumps({"text": "The authoritative result.", **command})

                handled = voice_bridge._handle_orchestrator_reply_control(
                    payload,
                    tts_worker=coordinator,
                    messenger=messenger,
                    state_path=state_path,
                )

                self.assertTrue(handled)
                self.assertEqual(executor.calls, ["play"])
                speech = executor.queued_payloads[-1]["_speech_intent"]
                self.assertEqual(previews, [("The authoritative result.", speech)])
                self.publish_waiting_preview.assert_not_called()
                self.assertEqual(speech["display_text"], "The authoritative result.")
                self.assertTrue(executor.eligibility(speech))

    def test_three_ordered_tool_turns_keep_latest_final_playable_and_replayable(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                event_log_path = os.path.join(temp_dir, "speech.jsonl")
                commands = [
                    {
                        "relay_command_seq": seq,
                        "relay_command_id": f"queued-{provider}-{seq}",
                        "provider": provider,
                        "work_disposition": {"route": "continue_current"},
                    }
                    for seq in (69, 70, 71)
                ]
                holder = {"key": voice_bridge._relay_command_key(commands[0])}
                previews = []
                advanced = False
                coordinator = None

                def advance_third_turn(payload):
                    nonlocal advanced
                    speech = payload["_speech_intent"]
                    if speech["command_seq"] != 70 or advanced:
                        return
                    advanced = True
                    holder["key"] = voice_bridge._relay_command_key(commands[2])
                    Path(state_path).write_text(json.dumps(commands[2]))
                    coordinator.new_turn(*holder["key"])

                executor = SynchronousTTSWorker(
                    on_preview=lambda text, speech: previews.append((text, speech)),
                    on_queued=advance_third_turn,
                )
                coordinator = voice_bridge.SpeechCoordinator(
                    executor,
                    is_current=lambda seq, command_id: holder["key"] == (seq, command_id),
                    event_log_path=event_log_path,
                )
                messenger = RejectingMessenger()
                finals = [f"Authoritative {provider} result {seq}." for seq in (69, 70, 71)]

                def deliver(index):
                    command = commands[index]
                    if provider == "claude":
                        payload = {
                            "provider": provider,
                            "event": "Stop",
                            "last_assistant_message": finals[index],
                            "relay_command": command,
                        }
                    else:
                        payload = {**command, "text": finals[index]}
                    return voice_bridge._handle_provider_completion_control(
                        json.dumps(payload),
                        tts_worker=coordinator,
                        messenger=messenger,
                        state_path=state_path,
                    )

                with mock.patch.object(voice_bridge, "_post_continuity_event"):
                    Path(state_path).write_text(json.dumps(commands[0]))
                    coordinator.new_turn(*holder["key"])
                    self.assertTrue(deliver(0))

                    holder["key"] = voice_bridge._relay_command_key(commands[1])
                    Path(state_path).write_text(json.dumps(commands[1]))
                    coordinator.new_turn(*holder["key"])
                    self.assertTrue(deliver(1))
                    self.assertTrue(advanced)

                    self.assertTrue(deliver(2))

                latest = executor.pending["_speech_intent"]
                self.assertEqual(
                    (latest["command_seq"], latest["command_id"]),
                    holder["key"],
                )
                self.assertEqual(latest["display_text"], finals[2])
                self.assertTrue(latest["utterance_id"])
                self.assertEqual(previews[-1], (finals[2], latest))
                self.publish_waiting_preview.assert_not_called()
                self.assertNotIn(
                    latest["utterance_id"],
                    {
                        payload["_speech_intent"]["utterance_id"]
                        for payload in executor.cancelled_payloads
                    },
                )

                coordinator.note_play_control()
                self.assertTrue(coordinator.play_or_replay())
                self.assertEqual(executor.current["_speech_intent"], latest)
                executor.complete()
                executor.calls.clear()

                coordinator.note_play_control()
                self.assertTrue(coordinator.play_or_replay())
                replay = executor.current["_speech_intent"]
                self.assertEqual(executor.calls, ["play"])
                self.assertNotEqual(replay["utterance_id"], latest["utterance_id"])
                self.assertEqual(replay["replay_of"], latest["original_utterance_id"])
                self.assertEqual(
                    (replay["command_seq"], replay["command_id"]),
                    (latest["command_seq"], latest["command_id"]),
                )
                self.assertEqual(replay["spoken_text"], finals[2])
                self.assertEqual(replay["display_text"], finals[2])

                records = [
                    json.loads(line)
                    for line in Path(event_log_path).read_text().splitlines()
                ]
                latest_events = [
                    record["event"]
                    for record in records
                    if record.get("utterance_id") == latest["utterance_id"]
                ]
                self.assertIn("queued", latest_events)
                self.assertNotIn("cancelled", latest_events)
                self.assertNotIn(finals[2], Path(event_log_path).read_text())

    def test_continue_current_handoff_yields_first_play_and_replay_to_authoritative_final(self):
        handoff = (
            "I received your request and will check the most recent Git commit’s "
            "subject, then return with the result."
        )
        final = "merge RR-347 worker run 105"
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                command = voice_bridge._begin_relay_command(
                    "Use the terminal to tell me the subject of the most recent git commit.",
                    state_path=state_path,
                    event_log_path=None,
                )
                command.update({
                    "provider": provider,
                    "work_disposition": {"route": "continue_current"},
                })
                Path(state_path).write_text(json.dumps(command))
                coordinator = None
                previews = []

                def publish_preview(text, speech):
                    previews.append((text, speech))
                    if text == final:
                        voice_bridge._handle_relay_control_message(
                            "__PLAY__",
                            coordinator,
                        )

                executor = SynchronousTTSWorker(on_preview=publish_preview)
                coordinator = voice_bridge.SpeechCoordinator(
                    executor,
                    is_current=lambda seq, command_id: (seq, command_id) == (
                        command["relay_command_seq"],
                        command["relay_command_id"],
                    ),
                )

                def submit_speech(
                    text,
                    command_seq,
                    command_id,
                    display_text=None,
                    speech_metadata=None,
                ):
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
                        **(speech_metadata or {}),
                    )

                messenger = voice_bridge.MessengerRuntime(
                    ImmediateMessengerBackend(handoff),
                    speak=submit_speech,
                    is_current=lambda seq, command_id: (seq, command_id) == (
                        command["relay_command_seq"],
                        command["relay_command_id"],
                    ),
                )
                messenger.start()
                try:
                    self.assertTrue(messenger.submit_user(
                        "Use the terminal to tell me the subject of the most recent git commit.",
                        command,
                    ))
                    self.assertTrue(wait_until(lambda: bool(executor.queued_payloads)))
                    first = executor.queued_payloads[-1]["_speech_intent"]
                    self.assertEqual(first["kind"], "handoff")
                    self.assertEqual(first["lifecycle_role"], "acknowledgement")
                    coordinator.note_play_control()
                    self.assertTrue(coordinator.play_or_replay())
                    executor.complete()
                    executor.calls.clear()
                    self.publish_waiting_preview.reset_mock()
                    previews.clear()

                    self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                        json.dumps({**command, "text": final}),
                        tts_worker=coordinator,
                        messenger=messenger,
                        state_path=state_path,
                    ))

                    authoritative = executor.queued_payloads[-1]["_speech_intent"]
                    self.publish_waiting_preview.assert_not_called()
                    self.assertEqual(previews, [(final, authoritative)])
                    self.assertEqual(executor.calls, ["play"])
                    self.assertEqual(authoritative["spoken_text"], final)
                    self.assertEqual(authoritative["display_text"], final)
                    self.assertEqual(
                        (
                            authoritative["command_seq"],
                            authoritative["command_id"],
                        ),
                        (
                            command["relay_command_seq"],
                            command["relay_command_id"],
                        ),
                    )
                    self.assertEqual(authoritative["kind"], "final")
                    self.assertTrue(executor.eligibility(authoritative))
                    executor.complete()
                    executor.calls.clear()

                    self.assertTrue(voice_bridge._handle_relay_control_message(
                        "__PLAY__",
                        coordinator,
                    ))
                    replay = executor.queued_payloads[-1]["_speech_intent"]
                    self.assertEqual(executor.calls, ["play"])
                    self.assertEqual(
                        replay["replay_of"],
                        authoritative["original_utterance_id"],
                    )
                    self.assertEqual(replay["spoken_text"], final)
                    self.assertEqual(replay["display_text"], final)
                    self.assertEqual(
                        (replay["command_seq"], replay["command_id"]),
                        (authoritative["command_seq"], authoritative["command_id"]),
                    )
                finally:
                    messenger.shutdown()

    def test_suppressed_conversation_final_leaves_replay_target_intact(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                command = voice_bridge._begin_relay_command(
                    "thanks",
                    state_path=state_path,
                    event_log_path=None,
                )
                command.update({
                    "provider": provider,
                    "work_disposition": {"route": "continue_current"},
                })
                Path(state_path).write_text(json.dumps(command))
                executor = FakeTTSWorker()
                coordinator = voice_bridge.SpeechCoordinator(
                    executor,
                    is_current=lambda seq, command_id: (seq, command_id) == (
                        command["relay_command_seq"],
                        command["relay_command_id"],
                    ),
                )

                def submit_speech(
                    text,
                    command_seq,
                    command_id,
                    display_text=None,
                    speech_metadata=None,
                ):
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
                        **(speech_metadata or {}),
                    )

                messenger = voice_bridge.MessengerRuntime(
                    mock.Mock(),
                    speak=submit_speech,
                    is_current=lambda seq, command_id: (seq, command_id) == (
                        command["relay_command_seq"],
                        command["relay_command_id"],
                    ),
                )
                self.assertTrue(messenger.submit_user("thanks", command))
                command_key = (
                    command["relay_command_seq"],
                    command["relay_command_id"],
                )
                with messenger._lock:
                    messenger._conversation_commands_answered.add(command_key)

                self.assertTrue(voice_bridge._queue_tts_text(
                    json.dumps({
                        "text": "You're welcome.",
                        "display_text": "You're welcome.",
                        "relay_command_seq": command["relay_command_seq"],
                        "relay_command_id": command["relay_command_id"],
                    }),
                    coordinator.input_queue,
                    state_path=state_path,
                    allow_pending_command=True,
                    source="messenger",
                    kind="handoff",
                    replayable=True,
                ))
                coordinator.note_play_control()
                self.assertTrue(coordinator.play_or_replay())
                original = executor.input_queue.get_nowait()["_speech_intent"]
                executor.observer("started", original)
                executor.observer("completed", original)
                executor.calls.clear()

                with mock.patch.object(voice_bridge, "publish_waiting_preview") as preview:
                    self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                        json.dumps({**command, "text": "Redundant foreground final."}),
                        tts_worker=coordinator,
                        messenger=messenger,
                        state_path=state_path,
                    ))

                preview.assert_not_called()
                self.assertTrue(coordinator.input_queue.empty())
                self.assertEqual(executor.calls, [])

                coordinator.note_play_control()
                self.assertTrue(coordinator.play_or_replay())
                replay = executor.input_queue.get_nowait()["_speech_intent"]
                self.assertEqual(replay["replay_of"], original["original_utterance_id"])
                self.assertEqual(replay["display_text"], "You're welcome.")
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

    def test_whitespace_separated_reserved_control_is_quarantined_without_payload_logging(self):
        worker = FakeTTSWorker()
        stderr = io.StringIO()

        with mock.patch.object(voice_bridge.sys, "stderr", stderr):
            self.assertTrue(voice_bridge._handle_relay_control_message(
                '__TRACE__ {"text":"private trace payload"}',
                worker,
                event_log_path=None,
            ))

        diagnostic = stderr.getvalue()
        self.assertIn("quarantined_relay_control", diagnostic)
        self.assertIn("control_type=trace", diagnostic)
        self.assertIn("syntax=malformed", diagnostic)
        self.assertIn("reason=noncanonical_separator", diagnostic)
        self.assertNotIn("private trace payload", diagnostic)

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

    def test_multi_item_orphaned_sibling_cancels_missing_final_for_both_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                first = {
                    "relay_command_seq": 318,
                    "relay_command_id": f"{provider}-multi",
                    "intent_id": f"{provider}-multi:item:1",
                    "within_turn_order": 1,
                    "provider": provider,
                }
                second = {
                    **first,
                    "intent_id": f"{provider}-multi:item:2",
                    "within_turn_order": 2,
                }
                Path(state_path).write_text(json.dumps({
                    **second,
                    "source_command_intents": [
                        {**first, "state": "acked"},
                        {**second, "state": "acked"},
                    ],
                    "deliverable_commands": [],
                    "cancelled_intent_ids": [],
                }))
                Path(turns_path).write_text(json.dumps({
                    "records": [
                        {
                            **first,
                            "session_id": f"{provider}-first",
                            "turn_id": "turn-1",
                            "state": "empty",
                        },
                        {
                            **second,
                            "session_id": f"{provider}-second",
                            "turn_id": "turn-2",
                            "state": "orphaned",
                            "release_reason": "superseded_by_prompt_submit",
                            "provider_ownership_disposition": "source_superseded",
                            "successor_record_key": f"{provider}-manual:manual-turn",
                        },
                        {
                            "provider": provider,
                            "origin": "manual",
                            "session_id": f"{provider}-manual",
                            "turn_id": "manual-turn",
                            "state": "completed_manual",
                            "release_reason": "provider_stop",
                        },
                    ],
                }))
                messenger = FakeMessenger()
                errors = io.StringIO()

                with mock.patch.object(voice_bridge.sys, "stderr", errors):
                    self.assertTrue(voice_bridge._handle_provider_completion_control(
                        json.dumps({**first, "completion_status": "empty"}),
                        tts_worker=FakeTTSWorker(),
                        messenger=messenger,
                        state_path=state_path,
                        turns_path=turns_path,
                        fallback_delay_seconds=0,
                    ))
                    time.sleep(0.05)

                self.assertEqual(messenger.finals, [])
                diagnostic = errors.getvalue()
                self.assertIn("decision=cancel", diagnostic)
                self.assertIn("reason=source_superseded", diagnostic)
                self.assertIn(f"intent_id={first['intent_id']}", diagnostic)
                self.assertNotIn("private", diagnostic)

    def test_missing_final_waits_for_pending_sibling_then_warns_when_it_is_cancelled(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            first = {
                "relay_command_seq": 319,
                "relay_command_id": "multi-pending",
                "intent_id": "multi-pending:item:1",
                "within_turn_order": 1,
                "provider": "codex",
            }
            second = {
                **first,
                "intent_id": "multi-pending:item:2",
                "within_turn_order": 2,
            }
            state = {
                **second,
                "source_command_intents": [
                    {**first, "state": "acked"},
                    {**second, "state": "pending"},
                ],
                "deliverable_commands": [{**second, "state": "pending"}],
                "cancelled_intent_ids": [],
            }
            Path(state_path).write_text(json.dumps(state))
            Path(turns_path).write_text(json.dumps({
                "records": [{**first, "state": "empty"}],
            }))
            messenger = FakeMessenger()

            with mock.patch.object(voice_bridge, "PROVIDER_COMPLETION_ACTIVE_POLL_SECONDS", 0.01):
                thread = voice_bridge._schedule_foreground_reply_fallback(
                    relay_command=first,
                    tts_worker=FakeTTSWorker(),
                    messenger=messenger,
                    state_path=state_path,
                    turns_path=turns_path,
                    command_path=os.path.join(temp_dir, "missing-ready"),
                    meta_path=os.path.join(temp_dir, "missing-meta"),
                    delay_seconds=0,
                )
                time.sleep(0.05)
                self.assertEqual(messenger.finals, [])
                state["source_command_intents"][1]["state"] = "cancelled"
                state["deliverable_commands"] = []
                state["cancelled_intent_ids"] = [second["intent_id"]]
                Path(state_path).write_text(json.dumps(state))
                thread.join(timeout=1)

            self.assertEqual(len(messenger.finals), 1)
            self.assertIn("did not send a spoken final reply", messenger.finals[0]["text"])

    def test_manual_takeover_records_explicit_source_supersession_for_both_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                claim = {
                    "relay_command_seq": 320,
                    "relay_command_id": f"{provider}-takeover",
                    "intent_id": f"{provider}-takeover:item:2",
                    "within_turn_order": 2,
                    "agent_prompt": "Private Relay prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                base = {
                    "provider": provider,
                    "provider_session_id": f"embedded-{provider}",
                }
                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=base["provider_session_id"],
                    observed_at=11,
                )
                relay_submit = {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-relay",
                    "turn_id": "relay-turn",
                    "prompt": claim["agent_prompt"],
                }
                manual_submit = {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-manual",
                    "turn_id": "manual-turn",
                    "prompt": "Private manual prompt",
                }
                if provider == "claude":
                    relay_submit.pop("turn_id")
                    manual_submit.pop("turn_id")

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    relay_submit,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=10,
                    stderr=io.StringIO(),
                ))
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    manual_submit,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    manual_submissions_path=manual_path,
                    now=11,
                    stderr=io.StringIO(),
                ))

                records = json.loads(Path(turns_path).read_text())["records"]
                relay_record, manual_record = records
                self.assertEqual(relay_record["state"], "orphaned")
                self.assertEqual(
                    relay_record["provider_ownership_disposition"],
                    "source_superseded",
                )
                self.assertEqual(
                    relay_record["successor_record_key"],
                    (
                        f"{provider}-manual:manual-turn"
                        if provider == "codex"
                        else f"{provider}-manual:local:1"
                    ),
                )
                self.assertEqual(manual_record["origin"], "manual")
                stored = Path(turns_path).read_text()
                self.assertNotIn("Private Relay prompt", stored)
                self.assertNotIn("Private manual prompt", stored)

    def test_duplicate_empty_sibling_completions_emit_one_source_warning(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            first = {
                "relay_command_seq": 321,
                "relay_command_id": "multi-empty",
                "intent_id": "multi-empty:item:1",
                "within_turn_order": 1,
                "provider": "codex",
            }
            second = {
                **first,
                "intent_id": "multi-empty:item:2",
                "within_turn_order": 2,
            }
            Path(state_path).write_text(json.dumps({
                **second,
                "source_command_intents": [
                    {**first, "state": "acked"},
                    {**second, "state": "acked"},
                ],
            }))
            Path(turns_path).write_text(json.dumps({
                "records": [
                    {**first, "state": "empty"},
                    {**second, "state": "empty"},
                ],
            }))
            messenger = FakeMessenger()
            worker = FakeTTSWorker()
            errors = io.StringIO()

            with mock.patch.object(voice_bridge.sys, "stderr", errors):
                for completion in (first, second):
                    self.assertTrue(voice_bridge._handle_provider_completion_control(
                        json.dumps({**completion, "completion_status": "empty"}),
                        tts_worker=worker,
                        messenger=messenger,
                        state_path=state_path,
                        turns_path=turns_path,
                        fallback_delay_seconds=0,
                    ))
                deadline = time.time() + 1
                while len(messenger.finals) < 1 and time.time() < deadline:
                    time.sleep(0.01)

            self.assertEqual(len(messenger.finals), 1)
            self.assertEqual(messenger.finals[0]["relay_command_id"], "multi-empty")
            self.assertEqual(errors.getvalue().count("event=emitted"), 1)

    def test_source_arbitration_ignores_other_embedded_provider_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            command = {
                "relay_command_seq": 322,
                "relay_command_id": "scoped-empty",
                "intent_id": "scoped-empty:item:1",
                "within_turn_order": 1,
            }
            Path(state_path).write_text(json.dumps({
                **command,
                "source_command_intents": [{**command, "state": "acked"}],
            }))
            Path(turns_path).write_text(json.dumps({
                "records": [
                    {
                        **command,
                        "state": "empty",
                        "provider_session_id": "current-session",
                    },
                    {
                        **self.foreground_ownership(),
                        "state": "active",
                        "origin": "manual",
                        "provider_session_id": "other-session",
                    },
                ],
            }))

            arbitration = voice_bridge._source_turn_reply_arbitration(
                command,
                state_path=state_path,
                turns_path=turns_path,
                command_path=os.path.join(temp_dir, "missing-ready"),
                meta_path=os.path.join(temp_dir, "missing-meta"),
                provider_session_id="current-session",
            )

            self.assertEqual(arbitration["decision"], "eligible")
            self.assertEqual(arbitration["provider_session_id"], "current-session")

    def test_sibling_takeover_terminalizes_only_the_replaced_intent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            first = {
                "relay_command_seq": 323,
                "relay_command_id": "sibling-takeover",
                "intent_id": "sibling-takeover:item:1",
                "within_turn_order": 1,
            }
            second = {
                **first,
                "intent_id": "sibling-takeover:item:2",
                "within_turn_order": 2,
            }
            Path(state_path).write_text(json.dumps({
                **second,
                "source_command_intents": [
                    {**first, "state": "acked"},
                    {**second, "state": "acked"},
                ],
            }))
            Path(turns_path).write_text(json.dumps({
                "records": [
                    {
                        **first,
                        "session_id": "first-session",
                        "turn_id": "first-turn",
                        "state": "orphaned",
                        "provider_ownership_disposition": "sibling_superseded",
                        "successor_record_key": "second-session:second-turn",
                    },
                    {
                        **second,
                        "session_id": "second-session",
                        "turn_id": "second-turn",
                        "state": "empty",
                    },
                ],
            }))

            arbitration = voice_bridge._source_turn_reply_arbitration(
                first,
                state_path=state_path,
                turns_path=turns_path,
                command_path=os.path.join(temp_dir, "missing-ready"),
                meta_path=os.path.join(temp_dir, "missing-meta"),
            )

            self.assertEqual(arbitration["decision"], "eligible")
            self.assertEqual(arbitration["reason"], "all_siblings_terminal_empty")

    def test_fully_cancelled_source_turn_never_emits_missing_final(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            command = {
                "relay_command_seq": 324,
                "relay_command_id": "cancelled-source",
                "intent_id": "cancelled-source:item:1",
                "within_turn_order": 1,
            }
            Path(state_path).write_text(json.dumps({
                **command,
                "source_command_intents": [{**command, "state": "cancelled"}],
                "cancelled_intent_ids": [command["intent_id"]],
            }))

            arbitration = voice_bridge._source_turn_reply_arbitration(
                command,
                state_path=state_path,
                turns_path=os.path.join(temp_dir, "missing-turns"),
                command_path=os.path.join(temp_dir, "missing-ready"),
                meta_path=os.path.join(temp_dir, "missing-meta"),
            )

            self.assertEqual(arbitration["decision"], "cancel")
            self.assertEqual(arbitration["reason"], "source_cancelled")

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
            provider_session_id = "embedded-codex"
            base = {
                "provider": "codex",
                "provider_session_id": provider_session_id,
            }

            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    **base,
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
            manual_path = self.write_manual_submission_evidence(
                temp_dir,
                provider="codex",
                provider_session_id=provider_session_id,
                observed_at=11,
            )
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-2",
                    "turn_id": "turn-2",
                    "prompt": "ordinary typed prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                manual_submissions_path=manual_path,
                now=11,
                stderr=io.StringIO(),
            ))
            manual_path = self.write_manual_submission_evidence(
                temp_dir,
                provider="codex",
                provider_session_id=provider_session_id,
                observed_at=12,
            )
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-3",
                    "turn_id": "turn-3",
                    "prompt": "Refined private agent prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                manual_submissions_path=manual_path,
                now=12,
                stderr=io.StringIO(),
            ))
            manual_path = self.write_manual_submission_evidence(
                temp_dir,
                provider="codex",
                provider_session_id=provider_session_id,
                observed_at=13,
            )
            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "session-4",
                    "turn_id": "turn-4",
                    "prompt": "Improve documentation in @filename",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                manual_submissions_path=manual_path,
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

    def test_unmatched_provider_continuation_preserves_exact_relay_turn(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                manual_path = os.path.join(temp_dir, "missing-manual-boundary.json")
                provider_session_id = f"embedded-{provider}"
                claim = {
                    "relay_command_seq": 348,
                    "relay_command_id": f"rr-348-{provider}",
                    "intent_id": f"rr-348-{provider}:item:1",
                    "agent_prompt": "Private Relay prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                base = {
                    "provider": provider,
                    "provider_session_id": provider_session_id,
                }
                relay_submit = {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-relay-session",
                    "turn_id": "relay-turn",
                    "prompt": claim["agent_prompt"],
                }
                continuation = {
                    **base,
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-continuation-session",
                    "turn_id": "continuation-turn",
                    "prompt": "Private custom-tool continuation",
                }
                relay_stop = {
                    **base,
                    "hook_event_name": "Stop",
                    "session_id": relay_submit["session_id"],
                    "turn_id": relay_submit["turn_id"],
                    "last_assistant_message": "Authoritative Relay final",
                }
                delivered: list[dict] = []
                errors = io.StringIO()
                with mock.patch.dict(os.environ, {
                    "RELAY_RUNNER_PROVIDER": provider,
                    "RELAY_PROVIDER_SESSION_ID": provider_session_id,
                }):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        relay_submit,
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        manual_submissions_path=manual_path,
                        now=100,
                        stderr=errors,
                    ))
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        continuation,
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        manual_submissions_path=manual_path,
                        now=100.1,
                        stderr=errors,
                    ))

                    records = json.loads(Path(turns_path).read_text())["records"]
                    self.assertEqual(len(records), 1)
                    self.assertEqual(records[0]["state"], "active")
                    self.assertEqual(records[0]["session_id"], relay_submit["session_id"])
                    self.assertNotIn("origin", records[0])

                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        relay_stop,
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        now=100.2,
                        stderr=errors,
                    ))
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        relay_stop,
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        now=100.3,
                        stderr=errors,
                    ))

                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["state"], "completed_final")
                self.assertEqual([item["relay_command_id"] for item in delivered], [claim["relay_command_id"]])
                self.assertEqual(delivered[0]["text"], "Authoritative Relay final")
                diagnostic = errors.getvalue()
                self.assertIn("quarantined_provider_continuation_no_manual_boundary", diagnostic)
                self.assertIn('"drain_result":"active_relay_turn_preserved"', diagnostic)
                self.assertNotIn("Private Relay prompt", diagnostic)
                self.assertNotIn("Private custom-tool continuation", diagnostic)
                self.assertNotIn("Authoritative Relay final", diagnostic)

    def test_manual_prompt_requires_exact_terminal_submit_boundary(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                provider_session_id = f"embedded-{provider}"
                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=provider_session_id,
                    observed_at=20,
                )
                payload = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-manual-session",
                    "turn_id": "manual-turn",
                    "provider_session_id": provider_session_id,
                    "provider": provider,
                    "prompt": "private typed terminal text",
                }
                errors = io.StringIO()
                with mock.patch.dict(os.environ, {
                    "RELAY_RUNNER_PROVIDER": provider,
                    "RELAY_PROVIDER_SESSION_ID": provider_session_id,
                }):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        payload,
                        claim_path=os.path.join(temp_dir, "missing-claim.json"),
                        state_path=os.path.join(temp_dir, "missing-state.json"),
                        turns_path=turns_path,
                        manual_submissions_path=manual_path,
                        now=20.1,
                        stderr=errors,
                    ))
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        {**payload, "session_id": f"{provider}-duplicate-session"},
                        claim_path=os.path.join(temp_dir, "missing-claim.json"),
                        state_path=os.path.join(temp_dir, "missing-state.json"),
                        turns_path=turns_path,
                        manual_submissions_path=manual_path,
                        now=20.2,
                        stderr=errors,
                    ))

                record = json.loads(Path(turns_path).read_text())["records"][0]
                self.assertEqual(record["state"], "active")
                self.assertEqual(record["origin"], "manual")
                self.assertEqual(record["manual_submit_evidence_source"], "relay_terminal_manual_submit")
                self.assertEqual(record["manual_submission_id"], f"manual-{provider}-20")
                evidence = json.loads(Path(manual_path).read_text())
                self.assertEqual(evidence["state"], "consumed")
                self.assertEqual(evidence["native_session_id"], payload["session_id"])
                diagnostic = errors.getvalue()
                self.assertIn('"decision":"accepted_terminal_manual_submit"', diagnostic)
                self.assertIn("quarantined_provider_continuation_boundary_consumed", diagnostic)
                self.assertNotIn("private typed terminal text", diagnostic)

    def test_manual_submit_evidence_rejects_stale_cross_session_and_ambiguous_boundaries(self):
        cases = (
            (
                "stale",
                {"observed_at": 1},
                "quarantined_provider_continuation_stale_boundary",
            ),
            (
                "cross_session",
                {"provider_session_id": "other-embedded-session"},
                "quarantined_provider_continuation_provider_session_mismatch",
            ),
            (
                "cross_owner",
                {"app_session_id": "other-app-session"},
                "quarantined_provider_continuation_foreground_mismatch",
            ),
            (
                "missing_nonce",
                {"submission_id": ""},
                "quarantined_provider_continuation_missing_nonce",
            ),
        )
        for provider in ("codex", "claude"):
            for name, overrides, expected_decision in cases:
                with (
                    self.subTest(provider=provider, case=name),
                    tempfile.TemporaryDirectory() as temp_dir,
                ):
                    turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                    provider_session_id = f"embedded-{provider}"
                    evidence_observed_at = overrides.get("observed_at", 20)
                    evidence_provider_session_id = overrides.get(
                        "provider_session_id",
                        provider_session_id,
                    )
                    evidence_overrides = {
                        key: value for key, value in overrides.items()
                        if key not in {"observed_at", "provider_session_id"}
                    }
                    manual_path = self.write_manual_submission_evidence(
                        temp_dir,
                        provider=provider,
                        provider_session_id=evidence_provider_session_id,
                        observed_at=evidence_observed_at,
                        **evidence_overrides,
                    )
                    errors = io.StringIO()
                    with mock.patch.dict(os.environ, {
                        "RELAY_RUNNER_PROVIDER": provider,
                        "RELAY_PROVIDER_SESSION_ID": provider_session_id,
                    }):
                        self.assertFalse(relay_completion_hook.handle_hook_payload(
                            {
                                "hook_event_name": "UserPromptSubmit",
                                "session_id": f"{provider}-continuation",
                                "turn_id": "continuation-turn",
                                "provider_session_id": provider_session_id,
                                "provider": provider,
                                "prompt": "private continuation",
                            },
                            claim_path=os.path.join(temp_dir, "missing-claim.json"),
                            state_path=os.path.join(temp_dir, "missing-state.json"),
                            turns_path=turns_path,
                            manual_submissions_path=manual_path,
                            now=20,
                            stderr=errors,
                        ))

                    self.assertEqual(
                        json.loads(Path(manual_path).read_text())["state"],
                        "pending",
                    )
                    self.assertFalse(Path(turns_path).exists())
                    self.assertIn(expected_decision, errors.getvalue())
                    self.assertNotIn("private continuation", errors.getvalue())

    def test_completion_hook_tracks_manual_turn_boundaries_for_both_app_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                delivered: list[dict] = []
                provider_session_id = f"embedded-{provider}"
                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=provider_session_id,
                    observed_at=20,
                )

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "UserPromptSubmit",
                        "session_id": f"{provider}-manual-session",
                        "turn_id": "manual-turn",
                        "provider_session_id": provider_session_id,
                        "provider": provider,
                        "prompt": "private typed terminal text",
                    },
                    claim_path=os.path.join(temp_dir, "missing-claim.json"),
                    state_path=os.path.join(temp_dir, "missing-state.json"),
                    turns_path=turns_path,
                    manual_submissions_path=manual_path,
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

                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=provider_session_id,
                    observed_at=10,
                )

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    startup,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    manual_submissions_path=manual_path,
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

    def test_completion_hook_preserves_active_final_for_newer_continue_current_command(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                claim = {
                    "relay_command_seq": 61,
                    "relay_command_id": "cmd-61",
                    "intent_id": "cmd-61:item:1",
                    "agent_prompt": "First queued prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                submit = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-session",
                    "turn_id": f"{provider}-turn-61",
                    "provider": provider,
                    "prompt": claim["agent_prompt"],
                }
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    submit,
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=30,
                    stderr=io.StringIO(),
                ))

                Path(state_path).write_text(json.dumps({
                    "relay_command_seq": 62,
                    "relay_command_id": "cmd-62",
                    "intent_id": "cmd-62:item:1",
                    "work_disposition": {
                        "route": "continue_current",
                        "authorization_effect": "preserve",
                        "cancellation_scope": "none",
                    },
                    "cancelled_intent_ids": [],
                }))
                delivered: list[dict] = []
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "Stop",
                        "session_id": submit["session_id"],
                        "turn_id": submit["turn_id"],
                        "provider": provider,
                        "last_assistant_message": "first queued reply",
                    },
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=31,
                    stderr=io.StringIO(),
                ))

                record = json.loads(Path(turns_path).read_text())["records"][0]
                self.assertEqual(record["state"], "completed_final")
                self.assertEqual(record["release_reason"], "provider_stop")
                self.assertEqual(delivered[0]["text"], "first queued reply")

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

    def test_completion_hook_reconciles_single_submit_stop_identity_drift(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                claim = {
                    "relay_command_seq": 52,
                    "relay_command_id": "cmd-52",
                    "intent_id": "cmd-52:item:1",
                    "agent_prompt": "Private Relay prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(claim))
                Path(claim_path).write_text(json.dumps(claim))
                provider_session_id = f"embedded-{provider}"

                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "UserPromptSubmit",
                        "session_id": f"{provider}-transient",
                        "turn_id": "physical-turn-52",
                        "provider_session_id": provider_session_id,
                        "provider": provider,
                        "prompt": claim["agent_prompt"],
                    },
                    claim_path=claim_path,
                    state_path=state_path,
                    turns_path=turns_path,
                    now=100,
                    stderr=io.StringIO(),
                ))

                errors = io.StringIO()
                delivered: list[dict] = []
                self.assertTrue(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "Stop",
                        "session_id": f"{provider}-persisted",
                        "turn_id": "physical-turn-52",
                        "provider_session_id": provider_session_id,
                        "provider": provider,
                        "last_assistant_message": "Private final",
                    },
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=100.2,
                    stderr=errors,
                ))

                record = json.loads(Path(turns_path).read_text())["records"][0]
                self.assertEqual(record["state"], "completed_final")
                self.assertEqual(record["release_reason"], "provider_stop_identity_reconciled")
                self.assertEqual(record["completion_correlation"], "provider_identity_reconciled")
                self.assertEqual(record["completion_native_session_id"], f"{provider}-persisted")
                self.assertEqual(record["completion_record_age_ms"], 200)
                self.assertEqual([item["relay_command_id"] for item in delivered], ["cmd-52"])
                diagnostic = errors.getvalue()
                self.assertIn('"decision":"accepted_provider_identity_reconciliation"', diagnostic)
                self.assertIn('"native_session_id_from":"' + provider + '-transient"', diagnostic)
                self.assertIn('"native_session_id_to":"' + provider + '-persisted"', diagnostic)
                self.assertIn('"relay_command_id":"cmd-52"', diagnostic)
                self.assertIn('"intent_id":"cmd-52:item:1"', diagnostic)
                self.assertNotIn("Private Relay prompt", Path(turns_path).read_text())
                self.assertNotIn("Private final", diagnostic)

                self.assertFalse(relay_completion_hook.handle_hook_payload(
                    {
                        "hook_event_name": "Stop",
                        "session_id": f"{provider}-persisted",
                        "turn_id": "physical-turn-52",
                        "provider_session_id": provider_session_id,
                        "provider": provider,
                        "last_assistant_message": "Private duplicate final",
                    },
                    state_path=state_path,
                    turns_path=turns_path,
                    write_control=lambda payload: delivered.append(payload) or True,
                    now=100.3,
                    stderr=errors,
                ))
                self.assertEqual([item["relay_command_id"] for item in delivered], ["cmd-52"])
                self.assertIn('"decision":"rejected_duplicate_provider_completion"', errors.getvalue())
                self.assertNotIn("Private duplicate final", errors.getvalue())

    def test_completion_hook_reconciles_exact_manual_turn_identity_drift(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                provider_session_id = f"embedded-{provider}"
                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=provider_session_id,
                    observed_at=100,
                )
                with mock.patch.dict(os.environ, {
                    "RELAY_RUNNER_PROVIDER": provider,
                    "RELAY_PROVIDER_SESSION_ID": provider_session_id,
                }):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "UserPromptSubmit",
                            "session_id": f"{provider}-transient",
                            "turn_id": "physical-manual-turn",
                            "provider_session_id": provider_session_id,
                            "provider": provider,
                            "prompt": "Private manual prompt",
                        },
                        claim_path=os.path.join(temp_dir, "missing-claim.json"),
                        turns_path=turns_path,
                        manual_submissions_path=manual_path,
                        now=100,
                        stderr=io.StringIO(),
                    ))

                    errors = io.StringIO()
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        {
                            "hook_event_name": "Stop",
                            "session_id": f"{provider}-persisted",
                            "turn_id": "physical-manual-turn",
                            "provider_session_id": provider_session_id,
                            "provider": provider,
                            "last_assistant_message": "Private manual final",
                        },
                        turns_path=turns_path,
                        now=100.2,
                        stderr=errors,
                    ))

                records = json.loads(Path(turns_path).read_text())["records"]
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["state"], "completed_manual")
                self.assertEqual(
                    records[0]["release_reason"],
                    "provider_stop_identity_reconciled",
                )
                self.assertEqual(
                    records[0]["completion_correlation"],
                    "provider_identity_reconciled",
                )
                self.assertEqual(
                    records[0]["completion_native_session_id"],
                    f"{provider}-persisted",
                )
                diagnostic = errors.getvalue()
                self.assertIn('"decision":"accepted_provider_identity_reconciliation"', diagnostic)
                self.assertIn('"release_reason":"provider_stop_identity_reconciled"', diagnostic)
                self.assertNotIn("Private manual prompt", Path(turns_path).read_text())
                self.assertNotIn("Private manual final", diagnostic)

    def test_completion_hook_reconciles_claude_stop_failure_identity_drift(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            claim = {
                "relay_command_seq": 59,
                "relay_command_id": "cmd-59",
                "agent_prompt": "Private failing prompt",
                "provider": "claude",
            }
            Path(state_path).write_text(json.dumps(claim))
            Path(claim_path).write_text(json.dumps(claim))
            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "claude-transient",
                    "turn_id": "physical-turn-59",
                    "provider_session_id": "embedded-claude",
                    "provider": "claude",
                    "prompt": claim["agent_prompt"],
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=150,
                stderr=io.StringIO(),
            )
            errors = io.StringIO()

            self.assertTrue(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "StopFailure",
                    "session_id": "claude-persisted",
                    "turn_id": "physical-turn-59",
                    "provider_session_id": "embedded-claude",
                    "provider": "claude",
                    "error": "private provider failure",
                },
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda _payload: True,
                now=150.1,
                stderr=errors,
            ))

            record = json.loads(Path(turns_path).read_text())["records"][0]
            self.assertEqual(record["state"], "failed")
            self.assertEqual(
                record["release_reason"],
                "provider_stop_failure_identity_reconciled",
            )
            self.assertNotIn("private provider failure", Path(turns_path).read_text())
            self.assertNotIn("private provider failure", errors.getvalue())

    def test_completion_hook_reconciled_stop_releases_stale_current_without_final(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            claim = {
                "relay_command_seq": 53,
                "relay_command_id": "cmd-53",
                "intent_id": "cmd-53:item:1",
                "agent_prompt": "Private stale prompt",
                "provider": "codex",
            }
            Path(state_path).write_text(json.dumps(claim))
            Path(claim_path).write_text(json.dumps(claim))
            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "codex-transient",
                    "turn_id": "physical-turn-53",
                    "provider_session_id": "embedded-codex",
                    "provider": "codex",
                    "prompt": claim["agent_prompt"],
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=200,
                stderr=io.StringIO(),
            )
            Path(state_path).write_text(json.dumps({
                **claim,
                "relay_command_seq": 54,
                "relay_command_id": "cmd-54",
                "intent_id": "cmd-54:item:1",
            }))
            delivered: list[dict] = []
            errors = io.StringIO()

            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "codex-persisted",
                    "turn_id": "physical-turn-53",
                    "provider_session_id": "embedded-codex",
                    "provider": "codex",
                    "last_assistant_message": "Private stale final",
                },
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda payload: delivered.append(payload) or True,
                now=200.1,
                stderr=errors,
            ))

            record = json.loads(Path(turns_path).read_text())["records"][0]
            self.assertEqual(record["state"], "stale")
            self.assertEqual(record["release_reason"], "stale_current_command_identity_reconciled")
            self.assertEqual(delivered, [])
            self.assertIn('"decision":"accepted_provider_identity_reconciliation"', errors.getvalue())
            self.assertNotIn("Private stale final", errors.getvalue())

    def test_completion_hook_rejects_ambiguous_identity_drift(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            Path(turns_path).write_text(json.dumps({
                "records": [
                    {
                        **self.foreground_ownership(),
                        "state": "active",
                        "session_id": "transient-one",
                        "turn_id": "ambiguous-turn",
                        "provider_session_id": "embedded-codex",
                        "provider": "codex",
                        "relay_command_seq": 55,
                        "relay_command_id": "cmd-55",
                        "created_at": 300,
                        "updated_at": 300,
                    },
                    {
                        **self.foreground_ownership(),
                        "state": "active",
                        "session_id": "transient-two",
                        "turn_id": "ambiguous-turn",
                        "provider_session_id": "embedded-codex",
                        "provider": "codex",
                        "relay_command_seq": 56,
                        "relay_command_id": "cmd-56",
                        "created_at": 300,
                        "updated_at": 300,
                    },
                ],
            }))
            errors = io.StringIO()

            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "persisted-session",
                    "turn_id": "ambiguous-turn",
                    "provider_session_id": "embedded-codex",
                    "provider": "codex",
                    "last_assistant_message": "Private ambiguous final",
                },
                state_path=os.path.join(temp_dir, "missing-state.json"),
                turns_path=turns_path,
                write_control=lambda _payload: True,
                now=300.1,
                stderr=errors,
            ))

            records = json.loads(Path(turns_path).read_text())["records"]
            self.assertTrue(all(record["state"] == "active" for record in records))
            diagnostic = errors.getvalue()
            self.assertIn('"decision":"rejected_ambiguous_provider_identity"', diagnostic)
            self.assertIn('"candidate_count":2', diagnostic)
            self.assertIn("ignored provider completion without Relay voice correlation", diagnostic)
            self.assertNotIn("Private ambiguous final", diagnostic)

    def test_late_identity_drifted_stop_cannot_release_newer_manual_or_other_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            claim = {
                "relay_command_seq": 57,
                "relay_command_id": "cmd-57",
                "agent_prompt": "Private Relay prompt",
                "provider": "codex",
            }
            Path(state_path).write_text(json.dumps(claim))
            Path(claim_path).write_text(json.dumps(claim))
            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "transient-old",
                    "turn_id": "old-turn",
                    "provider_session_id": "embedded-codex",
                    "provider": "codex",
                    "prompt": claim["agent_prompt"],
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                now=400,
                stderr=io.StringIO(),
            )
            manual_path = self.write_manual_submission_evidence(
                temp_dir,
                provider="codex",
                provider_session_id="embedded-codex",
                observed_at=401,
            )
            relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "persisted-session",
                    "turn_id": "manual-turn",
                    "provider_session_id": "embedded-codex",
                    "provider": "codex",
                    "prompt": "Private manual prompt",
                },
                claim_path=claim_path,
                state_path=state_path,
                turns_path=turns_path,
                manual_submissions_path=manual_path,
                now=401,
                stderr=io.StringIO(),
            )
            turn_state = json.loads(Path(turns_path).read_text())
            turn_state["records"].append({
                    "state": "active",
                    "session_id": "other-native-session",
                    "turn_id": "old-turn",
                    "provider_session_id": "other-embedded-session",
                    "provider": "codex",
                    "relay_command_seq": 58,
                    "relay_command_id": "cmd-58",
                    "created_at": 401,
                    "updated_at": 401,
            })
            Path(turns_path).write_text(json.dumps(turn_state))

            self.assertFalse(relay_completion_hook.handle_hook_payload(
                {
                    "hook_event_name": "Stop",
                    "session_id": "persisted-session",
                    "turn_id": "old-turn",
                    "provider_session_id": "embedded-codex",
                    "provider": "codex",
                    "last_assistant_message": "Private late final",
                },
                state_path=state_path,
                turns_path=turns_path,
                write_control=lambda _payload: True,
                now=402,
                stderr=io.StringIO(),
            ))

            records = json.loads(Path(turns_path).read_text())["records"]
            old_relay, manual, other_session = records
            self.assertEqual(old_relay["state"], "orphaned")
            self.assertEqual(manual["state"], "active")
            self.assertEqual(other_session["state"], "active")

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

                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=provider_session_id,
                    observed_at=32,
                )

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
                    manual_submissions_path=manual_path,
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
                provider_session_id = f"embedded-{provider}"
                relay_turn = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"{provider}-identical-session",
                    "provider_session_id": provider_session_id,
                    "provider": provider,
                    "prompt": "Identical prompt",
                }
                relay_stop = {
                    "hook_event_name": "Stop",
                    "session_id": f"{provider}-identical-session",
                    "provider_session_id": provider_session_id,
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

                manual_path = self.write_manual_submission_evidence(
                    temp_dir,
                    provider=provider,
                    provider_session_id=provider_session_id,
                    observed_at=32,
                )

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
                    manual_submissions_path=manual_path,
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

    def test_retained_bridge_adopts_exact_app_owned_provider_replacement_and_drains_in_order(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                voice_bridge._reset_foreground_reply_delivery_for_tests()
                command_path = os.path.join(temp_dir, "voice_cmd_ready")
                meta_path = command_path + ".meta"
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                projection_path = os.path.join(temp_dir, "voice_provider_turns_v2.json")
                inbox_path = os.path.join(temp_dir, "intent_inbox.sqlite3")
                manual_ack_path = os.path.join(temp_dir, "manual_ack.json")
                recovery_claim = {
                    "relay_command_seq": 78,
                    "relay_command_id": "cmd-78",
                    "intent_id": "intent-78",
                    "intent_delivery_id": "delivery:intent-78",
                    "intent_claim_id": "claim:intent-78",
                    "intent_ack_id": "ack:intent-78",
                    "provider": provider,
                }
                Path(claim_path).write_text(json.dumps(recovery_claim))
                Path(state_path).write_text(json.dumps(recovery_claim))
                ownership = voice_bridge.ProviderSessionOwnership(
                    provider_session_id="provider-session-old",
                    provider=provider,
                    app_session_id="test-app-session",
                    recovery_generation="test-generation",
                )
                transition = {
                    **recovery_claim,
                    "type": "continuity_provider_ready",
                    "event": "provider_ready",
                    "provider": provider,
                    "recovery_generation": "test-generation",
                    "previous_provider_session_id": "provider-session-old",
                    "provider_session_id": "provider-session-new",
                    "app_session_id": "test-app-session",
                    "actor_role": "foreground_pm",
                    "foreground_gate_handle": "replacement-gate",
                }
                with mock.patch.object(
                    voice_bridge, "_post_continuity_event", return_value={}
                ):
                    self.assertTrue(voice_bridge._handle_provider_turn_event_control(
                        json.dumps(transition),
                        provider_turn_broker=None,
                        provider_session_ownership=ownership,
                        claimed_path=claim_path,
                        state_path=state_path,
                    ))

                commands = [
                    {
                        "relay_command_seq": sequence,
                        "relay_command_id": f"cmd-{sequence}",
                        "intent_id": f"intent-{sequence}",
                        "agent_prompt": f"Read-only prompt {sequence}",
                        "provider": provider,
                        "work_disposition": {
                            "route": "continue_current",
                            "authorization_effect": "preserve",
                            "cancellation_scope": "none",
                        },
                        "cancelled_intent_ids": [],
                    }
                    for sequence in (79, 80, 81)
                ]
                inbox = voice_bridge.IntentInbox(
                    inbox_path,
                    provider_turn_projection_path=projection_path,
                )
                stored = [
                    inbox.enqueue(command["agent_prompt"], command, "continue_current")
                    for command in commands
                ]
                Path(state_path).write_text(json.dumps(stored[-1]))
                first = inbox.materialize_next(
                    command_path=command_path,
                    metadata_path=meta_path,
                    transport="app-owned",
                )
                self.assertEqual(first["relay_command_id"], "cmd-79")
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
                    transport="app-owned",
                    poll_seconds=0.005,
                    provider_session_ownership=ownership,
                )
                messenger = FakeMessenger()
                completion_payloads: list[dict] = []

                try:
                    current = first
                    for index, expected in enumerate(stored):
                        Path(claim_path).write_text(json.dumps(current))
                        for path in (command_path, meta_path):
                            try:
                                os.remove(path)
                            except FileNotFoundError:
                                pass

                        delivered: list[dict] = []
                        native_turn = f"{provider}-turn-{expected['relay_command_seq']}"
                        hook_environment = {
                            "RELAY_APP_SESSION_ID": "test-app-session",
                            "RELAY_RECOVERY_GENERATION": "test-generation",
                            "RELAY_ACTOR_ROLE": "foreground_pm",
                            "RELAY_FOREGROUND_GATE_HANDLE": "replacement-gate",
                            "RELAY_RUNNER_PROVIDER": provider,
                            "RELAY_PROVIDER_SESSION_ID": "provider-session-new",
                        }
                        with (
                            mock.patch.dict(os.environ, hook_environment, clear=False),
                            mock.patch.object(
                                relay_completion_hook,
                                "VOICE_PROVIDER_TURNS_FILE",
                                turns_path,
                            ),
                            mock.patch.object(
                                relay_completion_hook,
                                "VOICE_INTENT_INBOX",
                                inbox_path,
                            ),
                            mock.patch.object(
                                relay_completion_hook,
                                "VOICE_PROVIDER_TURN_PROJECTION_FILE",
                                projection_path,
                            ),
                        ):
                            self.assertTrue(relay_completion_hook.handle_hook_payload(
                                {
                                    "hook_event_name": "UserPromptSubmit",
                                    "session_id": f"{provider}-replacement",
                                    "turn_id": native_turn,
                                    "provider_session_id": "provider-session-new",
                                    "provider": provider,
                                    "prompt": current["agent_prompt"],
                                },
                                claim_path=claim_path,
                                state_path=state_path,
                                turns_path=turns_path,
                                now=100 + index * 2,
                                stderr=io.StringIO(),
                            ))
                            self.assertTrue(relay_completion_hook.handle_hook_payload(
                                {
                                    "hook_event_name": "Stop",
                                    "session_id": f"{provider}-replacement",
                                    "turn_id": native_turn,
                                    "provider_session_id": "provider-session-new",
                                    "provider": provider,
                                    "last_assistant_message": f"Final {expected['relay_command_seq']}",
                                },
                                claim_path=claim_path,
                                state_path=state_path,
                                turns_path=turns_path,
                                write_control=lambda payload: delivered.append(payload) or True,
                                now=101 + index * 2,
                                stderr=io.StringIO(),
                            ))

                        broker = ProviderTurnBroker(
                            inbox_path,
                            projection_path=projection_path,
                        )
                        try:
                            with mock.patch.object(
                                voice_bridge, "_post_continuity_event", return_value={}
                            ):
                                completion = json.dumps(delivered[0])
                                self.assertTrue(voice_bridge._handle_provider_completion_control(
                                    completion,
                                    tts_worker=FakeTTSWorker(),
                                    messenger=messenger,
                                    state_path=state_path,
                                    turns_path=turns_path,
                                    provider_turn_broker=broker,
                                ))
                                self.assertTrue(voice_bridge._handle_provider_completion_control(
                                    completion,
                                    tts_worker=FakeTTSWorker(),
                                    messenger=messenger,
                                    state_path=state_path,
                                    turns_path=turns_path,
                                    provider_turn_broker=broker,
                                ))
                        finally:
                            broker.close()
                        completion_payloads.append(delivered[0])

                        if index < 2:
                            started = time.monotonic()
                            self.assertTrue(wait_until(
                                lambda: os.path.exists(command_path)
                                and os.path.exists(meta_path),
                                timeout=0.5,
                            ))
                            self.assertLess(time.monotonic() - started, 0.5)
                            current = json.loads(Path(meta_path).read_text())
                            self.assertEqual(
                                current["relay_command_id"],
                                stored[index + 1]["relay_command_id"],
                            )
                        else:
                            self.assertTrue(wait_until(
                                lambda: all(
                                    record["state"] == "acked"
                                    for record in inbox.records()
                                )
                            ))

                    self.assertEqual(
                        [payload["relay_command_id"] for payload in completion_payloads],
                        ["cmd-79", "cmd-80", "cmd-81"],
                    )
                    self.assertEqual(
                        [payload["text"] for payload in messenger.finals],
                        ["Final 79", "Final 80", "Final 81"],
                    )
                finally:
                    shutdown_event.set()
                    pump.join(timeout=1)
                    inbox.close()

    def test_provider_session_replacement_rejects_stale_foreign_and_ambiguous_evidence(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            claim = {
                "relay_command_seq": 79,
                "relay_command_id": "cmd-79",
                "intent_id": "intent-79",
                "intent_delivery_id": "delivery:intent-79",
                "intent_claim_id": "claim:intent-79",
                "intent_ack_id": "ack:intent-79",
                "provider": "codex",
            }
            Path(state_path).write_text(json.dumps(claim))
            valid = {
                **claim,
                "previous_provider_session_id": "provider-session-old",
                "provider_session_id": "provider-session-new",
                "app_session_id": "test-app-session",
                "recovery_generation": "test-generation",
                "actor_role": "foreground_pm",
                "foreground_gate_handle": "replacement-gate",
            }
            invalid_cases = {
                "foreign_session": {"previous_provider_session_id": "foreign-session"},
                "foreign_app": {"app_session_id": "foreign-app"},
                "stale_generation": {"recovery_generation": "old-generation"},
                "wrong_claim": {"intent_claim_id": "claim:other"},
                "ambiguous_gate": {"foreground_gate_handle": ""},
            }
            for name, changes in invalid_cases.items():
                with self.subTest(name=name):
                    ownership = voice_bridge.ProviderSessionOwnership(
                        provider_session_id="provider-session-old",
                        provider="codex",
                        app_session_id="test-app-session",
                        recovery_generation="test-generation",
                    )
                    decision = ownership.authorize_transition(
                        {**valid, **changes},
                        claimed=claim,
                        state_path=state_path,
                    )
                    self.assertNotEqual(decision, "accepted_exact_app_owned_replacement")
                    self.assertEqual(
                        ownership.provider_session_id(),
                        "provider-session-old",
                    )

            for name, current in {
                "cancelled": {
                    **claim,
                    "cancelled_intent_ids": [claim["intent_id"]],
                },
                "replaced": {
                    "relay_command_seq": 80,
                    "relay_command_id": "cmd-80",
                    "intent_id": "intent-80",
                    "work_disposition": {
                        "route": "replace_current",
                        "authorization_effect": "revoke",
                        "cancellation_scope": "all_work",
                    },
                },
            }.items():
                with self.subTest(name=name):
                    Path(state_path).write_text(json.dumps(current))
                    ownership = voice_bridge.ProviderSessionOwnership(
                        provider_session_id="provider-session-old",
                        provider="codex",
                        app_session_id="test-app-session",
                        recovery_generation="test-generation",
                    )
                    self.assertEqual(
                        ownership.authorize_transition(
                            valid,
                            claimed=claim,
                            state_path=state_path,
                        ),
                        "claim_not_current_or_preserved",
                    )

            Path(state_path).write_text(json.dumps(claim))
            ownership = voice_bridge.ProviderSessionOwnership(
                provider_session_id="provider-session-old",
                provider="codex",
                app_session_id="test-app-session",
                recovery_generation="test-generation",
            )
            self.assertEqual(
                ownership.authorize_transition(valid, claimed=claim, state_path=state_path),
                "accepted_exact_app_owned_replacement",
            )
            turns_path = os.path.join(temp_dir, "provider_turns.json")
            Path(turns_path).write_text(json.dumps({
                "records": [{
                    **claim,
                    "state": "completed_final",
                    "provider_session_id": "provider-session-new",
                    "provider": "codex",
                    "app_session_id": "test-app-session",
                    "recovery_generation": "test-generation",
                    "actor_role": "foreground_pm",
                    "foreground_gate_handle": "foreign-gate",
                }],
            }))
            self.assertFalse(voice_bridge._provider_turn_seen(
                claim,
                turns_path=turns_path,
                provider_session_id=ownership.provider_session_id(),
                provider_ownership=ownership.provider_turn_scope(),
            ))
            turn_state = json.loads(Path(turns_path).read_text())
            turn_state["records"][0]["foreground_gate_handle"] = "replacement-gate"
            Path(turns_path).write_text(json.dumps(turn_state))
            with mock.patch.object(
                voice_bridge,
                "_PROVIDER_SESSION_OWNERSHIP",
                ownership,
            ):
                self.assertEqual(
                    voice_bridge._provider_turn_state(claim, turns_path=turns_path),
                    "completed_final",
                )

    def test_pump_releases_terminal_recovered_claim_before_materializing_next(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = command_path + ".meta"
            claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
            inbox_path = os.path.join(temp_dir, "intent_inbox.sqlite3")
            first = {
                "relay_command_seq": 1,
                "relay_command_id": "cmd-1",
                "intent_id": "intent-1",
                "provider": "codex",
            }
            second = {
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "intent-2",
                "provider": "codex",
            }
            turn = {
                "app_session_id": "app-session",
                "recovery_generation": "generation-1",
                "actor_role": "foreground_pm",
                "foreground_gate_handle": "gate-1",
                "provider": "codex",
                "provider_session_id": "provider-session",
                "session_id": "native-session",
                "turn_id": "native-turn",
                "origin": "relay",
                "intent_id": "intent-1",
                "relay_command_seq": 1,
                "relay_command_id": "cmd-1",
            }

            inbox = voice_bridge.IntentInbox(
                inbox_path,
                provider_turn_projection_path=turns_path,
            )
            broker = ProviderTurnBroker(inbox_path, projection_path=turns_path)
            stored = inbox.enqueue("private first prompt", first, "continue_current")
            inbox.enqueue("private second prompt", second, "continue_current")
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=meta_path,
                transport="app-owned",
            )
            inbox.observe_claim(stored, provider_turn_seen=False, now=100.0)
            broker.activate(turn, now=100.1)
            broker.transition(
                turn,
                to_state="completed_final",
                event_type="provider_final",
                release_reason="provider_stop",
                now=101.0,
            )
            os.unlink(command_path)
            os.unlink(meta_path)
            inbox.close()

            restarted = voice_bridge.IntentInbox(
                inbox_path,
                provider_turn_projection_path=turns_path,
            )
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
                for _ in range(100):
                    if restarted.records()[0]["state"] == "acked":
                        break
                    shutdown_event.wait(0.005)

                self.assertFalse(os.path.exists(meta_path))
                reservation = broker.reserve_effect(turn, now=101.1)
                self.assertTrue(reservation.accepted)
                self.assertTrue(
                    broker.authorize_effect_delivery(reservation.effect_id, now=101.2)
                )
                broker.finish_effect(reservation.effect_id, delivered=True, now=101.3)

                for _ in range(100):
                    if os.path.exists(meta_path):
                        break
                    shutdown_event.wait(0.005)

                materialized = json.loads(Path(meta_path).read_text())
                self.assertEqual(materialized["intent_id"], "intent-2")
                self.assertEqual(
                    [record["state"] for record in restarted.records()],
                    ["acked", "delivered"],
                )
                self.assertEqual(broker.state_for(turn), "completed_final")
            finally:
                shutdown_event.set()
                pump.join(timeout=1)
                restarted.close()
                broker.close()

    def test_terminal_empty_predecessor_does_not_strand_next_intent(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                command_path = os.path.join(temp_dir, "voice_cmd_ready")
                meta_path = command_path + ".meta"
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                inbox_path = os.path.join(temp_dir, "intent_inbox.sqlite3")
                first = {
                    **self.foreground_ownership(),
                    "relay_command_seq": 1,
                    "relay_command_id": "cmd-1",
                    "intent_id": "intent-1",
                    "provider": provider,
                }
                second = {
                    **self.foreground_ownership(),
                    "relay_command_seq": 2,
                    "relay_command_id": "cmd-2",
                    "intent_id": "intent-2",
                    "provider": provider,
                }
                turn = {
                    **first,
                    "provider_session_id": "provider-session",
                    "session_id": "native-session",
                    "turn_id": "native-turn",
                    "origin": "relay",
                }

                inbox = voice_bridge.IntentInbox(
                    inbox_path,
                    provider_turn_projection_path=turns_path,
                )
                broker = ProviderTurnBroker(inbox_path, projection_path=turns_path)
                self.addCleanup(inbox.close)
                self.addCleanup(broker.close)
                stored = inbox.enqueue("private first prompt", first, "continue_current")
                inbox.enqueue("private second prompt", second, "continue_current")
                inbox.materialize_next(
                    command_path=command_path,
                    metadata_path=meta_path,
                    transport="app-owned",
                )
                inbox.observe_claim(stored, provider_turn_seen=True, now=100.0)
                broker.activate(turn, now=100.1)
                broker.transition(
                    turn,
                    to_state="empty",
                    event_type="provider_empty",
                    release_reason="provider_stop",
                    now=101.0,
                )
                os.unlink(command_path)
                os.unlink(meta_path)

                materialized = inbox.materialize_next(
                    command_path=command_path,
                    metadata_path=meta_path,
                    transport="app-owned",
                )

                self.assertEqual(materialized["intent_id"], "intent-2")
                self.assertEqual(
                    [record["state"] for record in inbox.records()],
                    ["acked", "delivered"],
                )

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
                            **self.foreground_ownership(),
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
                            **self.foreground_ownership(),
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
                **self.foreground_ownership(),
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
                **self.foreground_ownership(),
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

    def test_provider_completion_control_preserves_reply_for_newer_continue_current(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            first = voice_bridge._begin_relay_command(
                "first",
                state_path=state_path,
                event_log_path=None,
            )
            first["intent_id"] = "first:item:1"
            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "second:item:1",
                "cancelled_intent_ids": [],
                "work_disposition": {
                    "route": "continue_current",
                    "authorization_effect": "preserve",
                    "cancellation_scope": "none",
                },
            }))
            messenger = FakeMessenger()

            self.assertTrue(voice_bridge._handle_provider_completion_control(
                json.dumps({"text": "First reply.", **first}),
                tts_worker=FakeTTSWorker(),
                messenger=messenger,
                state_path=state_path,
            ))
            self.assertEqual(messenger.finals, [{
                "text": "First reply.",
                "relay_command_seq": first["relay_command_seq"],
                "relay_command_id": first["relay_command_id"],
                "speech_source": "completion",
            }])

    def test_preserved_completion_falls_back_to_tts_after_messenger_advances(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            first = voice_bridge._begin_relay_command(
                "first",
                state_path=state_path,
                event_log_path=None,
            )
            first["intent_id"] = "first:item:1"
            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "second:item:1",
                "cancelled_intent_ids": [],
                "work_disposition": {
                    "route": "continue_current",
                    "authorization_effect": "preserve",
                    "cancellation_scope": "none",
                },
            }))
            messenger = RejectingMessenger()
            worker = FakeTTSWorker()

            self.assertTrue(voice_bridge._handle_provider_completion_control(
                json.dumps({"text": "First reply.", **first}),
                tts_worker=worker,
                messenger=messenger,
                state_path=state_path,
            ))
            self.assertEqual(worker.input_queue.get_nowait(), {
                "text": "First reply.",
                "display_text": "First reply.",
            })

    def test_preserved_completion_stays_fresh_in_speech_coordinator(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            first = voice_bridge._begin_relay_command(
                "first",
                state_path=state_path,
                event_log_path=None,
            )
            first["intent_id"] = "first:item:1"
            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
                "intent_id": "second:item:1",
                "cancelled_intent_ids": [],
                "work_disposition": {
                    "route": "continue_current",
                    "authorization_effect": "preserve",
                    "cancellation_scope": "none",
                },
            }))
            executor = FakeTTSWorker()
            coordinator = voice_bridge.SpeechCoordinator(
                executor,
                is_current=lambda seq, command_id: voice_bridge._relay_command_current(
                    seq,
                    command_id,
                    state_path=state_path,
                ),
                is_preserved=lambda seq, command_id, disposition: (
                    voice_bridge._relay_command_current_or_preserved(
                        {
                            "relay_command_seq": seq,
                            "relay_command_id": command_id,
                            "intent_id": disposition.get("intent_id"),
                        },
                        state_path=state_path,
                    )
                ),
            )

            self.assertTrue(voice_bridge._handle_provider_completion_control(
                json.dumps({"text": "First reply.", **first}),
                tts_worker=coordinator,
                messenger=RejectingMessenger(),
                state_path=state_path,
            ))
            queued = executor.input_queue.get_nowait()
            self.assertEqual(queued["text"], "First reply.")
            self.assertEqual(queued["_speech_intent"]["command_seq"], 1)
            self.assertEqual(
                queued["_speech_intent"]["work_disposition"]["intent_id"],
                "first:item:1",
            )

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

    def test_durable_broker_deduplicates_authoritative_effect_after_bridge_restart(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            ownership = self.foreground_ownership()
            command = {
                **ownership,
                "relay_command_seq": 324,
                "relay_command_id": "broker-effect",
                "intent_id": "broker-effect:item:1",
            }
            Path(state_path).write_text(json.dumps(command))
            broker = ProviderTurnBroker(database)
            self.addCleanup(broker.close)
            broker.activate({
                **command,
                "origin": "relay",
                "provider": "codex",
                "provider_session_id": "provider-session",
                "session_id": "native-session",
                "turn_id": "native-turn",
            })
            raw = json.dumps({**command, "text": "one authoritative effect"})
            first_messenger = FakeMessenger()
            second_messenger = FakeMessenger()
            voice_bridge._reset_foreground_reply_delivery_for_tests()

            self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                raw,
                tts_worker=FakeTTSWorker(),
                messenger=first_messenger,
                state_path=state_path,
                provider_turn_broker=broker,
            ))
            voice_bridge._reset_foreground_reply_delivery_for_tests()
            self.assertTrue(voice_bridge._handle_orchestrator_reply_control(
                raw,
                tts_worker=FakeTTSWorker(),
                messenger=second_messenger,
                state_path=state_path,
                provider_turn_broker=broker,
            ))

            self.assertEqual(len(first_messenger.finals), 1)
            self.assertEqual(second_messenger.finals, [])
            effects = broker.table_records("provider_turn_effects")
            self.assertEqual(len(effects), 1)
            self.assertEqual(effects[0]["state"], "delivered")

            termination = json.dumps({
                **ownership,
                "event": "provider_terminated",
                "event_id": "broker-teardown",
                "release_reason": "app_teardown",
                "provider_session_id": "provider-session",
            })
            self.assertTrue(voice_bridge._handle_provider_turn_event_control(
                termination,
                provider_turn_broker=broker,
            ))
            self.assertEqual(broker.table_records("provider_turns")[0]["state"], "terminated")

    def test_real_delivery_paths_reject_revocation_between_reserve_and_submission(self):
        for provider in ("codex", "claude"):
            for relationship in ("cancellation", "replacement"):
                for delivery_path in ("orchestrator_reply", "missing_reply"):
                    with self.subTest(
                        provider=provider,
                        relationship=relationship,
                        delivery_path=delivery_path,
                    ), tempfile.TemporaryDirectory() as temp_dir:
                        database = os.path.join(temp_dir, "inbox.sqlite3")
                        state_path = os.path.join(temp_dir, "voice_command_state.json")
                        command = {
                            **self.foreground_ownership(),
                            "relay_command_seq": 1,
                            "relay_command_id": f"{provider}-{relationship}-{delivery_path}",
                            "intent_id": f"intent-{provider}-{relationship}-{delivery_path}",
                            "provider": provider,
                        }
                        Path(state_path).write_text(json.dumps(command))
                        inbox = voice_bridge.IntentInbox(database)
                        broker = ProviderTurnBroker(database)
                        try:
                            inbox.enqueue("private prompt", command, "continue_current")
                            turn = {
                                **command,
                                "origin": "relay",
                                "provider_session_id": f"provider-session-{provider}",
                                "session_id": f"native-session-{provider}",
                                "turn_id": f"native-turn-{relationship}-{delivery_path}",
                            }
                            self.assertTrue(broker.activate(turn))
                            self.assertTrue(broker.transition(
                                turn,
                                to_state="completed_final",
                                event_type="provider_completed",
                                release_reason="provider_stop",
                            ))
                            voice_bridge._reset_foreground_reply_delivery_for_tests()
                            messenger = FakeMessenger()
                            original_reserve = voice_bridge._reserve_foreground_reply_delivery

                            def revoke_after_reservation(candidate):
                                reserved = original_reserve(candidate)
                                if relationship == "cancellation":
                                    cancelled = inbox.cancel_scoped({
                                        "intent_id": "cancel-current",
                                        "cancellation_scope": "item",
                                        "target_intent_ids": [command["intent_id"]],
                                    })
                                    self.assertEqual(cancelled, [command["intent_id"]])
                                else:
                                    self.assertEqual(inbox.cancel_pending_before(
                                        2,
                                        reason="replaced_by_newer_command",
                                    ), 1)
                                return reserved

                            with mock.patch.object(
                                voice_bridge,
                                "_reserve_foreground_reply_delivery",
                                side_effect=revoke_after_reservation,
                            ), mock.patch.object(voice_bridge, "_queue_tts_text") as queue_tts:
                                if delivery_path == "orchestrator_reply":
                                    delivered = voice_bridge._handle_orchestrator_reply_control(
                                        json.dumps({**command, "text": "late final"}),
                                        tts_worker=FakeTTSWorker(),
                                        messenger=messenger,
                                        state_path=state_path,
                                        provider_turn_broker=broker,
                                    )
                                else:
                                    delivered = voice_bridge._deliver_missing_foreground_reply(
                                        relay_command=command,
                                        tts_worker=FakeTTSWorker(),
                                        messenger=messenger,
                                        state_path=state_path,
                                        provider_turn_broker=broker,
                                    )

                            self.assertFalse(delivered)
                            self.assertEqual(messenger.finals, [])
                            queue_tts.assert_not_called()
                            effects = broker.table_records("provider_turn_effects")
                            self.assertEqual(len(effects), 1)
                            self.assertEqual(effects[0]["state"], "failed")
                        finally:
                            broker.close()
                            inbox.close()

    def test_real_delivery_paths_reject_revocation_before_reservation(self):
        for provider in ("codex", "claude"):
            for relationship in ("cancellation", "replacement"):
                for delivery_path in ("orchestrator_reply", "missing_reply"):
                    with self.subTest(
                        provider=provider,
                        relationship=relationship,
                        delivery_path=delivery_path,
                    ), tempfile.TemporaryDirectory() as temp_dir:
                        database = os.path.join(temp_dir, "inbox.sqlite3")
                        state_path = os.path.join(temp_dir, "voice_command_state.json")
                        command = {
                            **self.foreground_ownership(),
                            "relay_command_seq": 1,
                            "relay_command_id": f"{provider}-{relationship}-{delivery_path}",
                            "intent_id": f"intent-{provider}-{relationship}-{delivery_path}",
                            "provider": provider,
                        }
                        Path(state_path).write_text(json.dumps(command))
                        inbox = voice_bridge.IntentInbox(database)
                        broker = ProviderTurnBroker(database)
                        try:
                            inbox.enqueue("private prompt", command, "continue_current")
                            turn = {
                                **command,
                                "origin": "relay",
                                "provider_session_id": f"provider-session-{provider}",
                                "session_id": f"native-session-{provider}",
                                "turn_id": f"native-turn-{relationship}-{delivery_path}",
                            }
                            self.assertTrue(broker.activate(turn))
                            self.assertTrue(broker.transition(
                                turn,
                                to_state="completed_final",
                                event_type="provider_completed",
                                release_reason="provider_stop",
                            ))
                            if relationship == "cancellation":
                                cancelled = inbox.cancel_scoped({
                                    "intent_id": "cancel-current",
                                    "cancellation_scope": "item",
                                    "target_intent_ids": [command["intent_id"]],
                                })
                                self.assertEqual(cancelled, [command["intent_id"]])
                            else:
                                self.assertEqual(inbox.cancel_pending_before(
                                    2,
                                    reason="replaced_by_newer_command",
                                ), 1)

                            voice_bridge._reset_foreground_reply_delivery_for_tests()
                            messenger = FakeMessenger()
                            worker = FakeTTSWorker()
                            with mock.patch.object(
                                voice_bridge,
                                "PROVIDER_TURN_BROKER_MODE",
                                "dual_write",
                            ), mock.patch.object(voice_bridge, "_queue_tts_text") as queue_tts:
                                if delivery_path == "orchestrator_reply":
                                    delivered = voice_bridge._handle_orchestrator_reply_control(
                                        json.dumps({**command, "text": "late final"}),
                                        tts_worker=worker,
                                        messenger=messenger,
                                        state_path=state_path,
                                        provider_turn_broker=broker,
                                    )
                                else:
                                    delivered = voice_bridge._deliver_missing_foreground_reply(
                                        relay_command=command,
                                        tts_worker=worker,
                                        messenger=messenger,
                                        state_path=state_path,
                                        provider_turn_broker=broker,
                                    )

                            self.assertFalse(delivered)
                            self.assertEqual(messenger.finals, [])
                            queue_tts.assert_not_called()
                            self.assertTrue(worker.input_queue.empty())
                            self.assertFalse(voice_bridge._foreground_reply_delivered(command))
                            self.assertEqual(broker.table_records("provider_turn_effects"), [])
                        finally:
                            broker.close()
                            inbox.close()

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

    def test_pending_messenger_outcome_preserves_full_lifecycle_detail(self):
        messenger = FakeMessenger()
        requests: list[tuple[str, dict]] = []
        detail = (
            "RR-279 verification resumed: Mounted test on the currently running installed "
            "Relay Runner v0.4.35 after Screen Recording and Accessibility were granted."
        )
        outcome = {
            "id": 15,
            "payload": {
                "trace_event": {
                    "kind": "run-verification-resumed",
                    "message": detail[:93] + "...",
                    "lifecycle_detail": detail,
                    "source": "orchestrator",
                    "ticket_id": "RR-279",
                    "run_id": 15,
                }
            },
        }

        delivered = voice_bridge._deliver_pending_messenger_outcomes_once(
            orchestrator_session={"repo_path": "/tmp/repo", "provider": "claude"},
            messenger=messenger,
            request_get_json=lambda path, params: {"outcomes": [outcome]},
            request_json=lambda path, payload: requests.append((path, payload)) or {},
        )

        self.assertEqual(delivered, 1)
        self.assertEqual(messenger.traces[0]["lifecycle_detail"], detail)
        self.assertEqual(requests, [("/v1/messenger/outcomes/15/delivered", {})])

    def test_pending_messenger_outcome_poll_batches_recovered_backlog(self):
        messenger = FakeMessenger()
        requests: list[tuple[str, dict]] = []
        fetches: list[tuple[str, dict]] = []
        outcomes = [
            {
                "id": 4,
                "payload": {
                    "trace_event": {
                        "kind": "run-failed",
                        "message": "RR-7 run 12 failed",
                        "source": "worker",
                        "ticket_id": "RR-7",
                        "run_id": 12,
                    }
                },
            },
            {
                "id": 5,
                "payload": {
                    "trace_event": {
                        "kind": "run-verification-blocked",
                        "message": "RR-7 is waiting on external verification",
                        "source": "orchestrator",
                        "ticket_id": "RR-7",
                        "run_id": 12,
                    }
                },
            },
            {
                "id": 6,
                "payload": {
                    "trace_event": {
                        "kind": "run-merged",
                        "message": "RR-8 run 13 merged",
                        "source": "orchestrator",
                        "ticket_id": "RR-8",
                        "run_id": 13,
                    }
                },
            },
        ]

        delivered = voice_bridge._deliver_pending_messenger_outcomes_once(
            orchestrator_session={"repo_path": "/tmp/repo", "provider": "codex"},
            messenger=messenger,
            request_get_json=lambda path, params: (
                fetches.append((path, params)) or {"outcomes": outcomes}
            ),
            request_json=lambda path, payload: requests.append((path, payload)) or {},
        )

        self.assertEqual(delivered, 3)
        self.assertEqual(fetches[0][1]["limit"], 50)
        self.assertEqual(len(messenger.traces), 1)
        self.assertEqual(messenger.traces[0]["kind"], "run-health-warning")
        self.assertIn("3 Relay work updates", messenger.traces[0]["message"])
        self.assertIn("2 tickets", messenger.traces[0]["message"])
        self.assertEqual(messenger.traces[0]["ticket_ids"], ["RR-7", "RR-8"])
        self.assertEqual(
            requests,
            [
                ("/v1/messenger/outcomes/4/delivered", {}),
                ("/v1/messenger/outcomes/5/delivered", {}),
                ("/v1/messenger/outcomes/6/delivered", {}),
            ],
        )

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

    def test_build_bundle_includes_runtime_service_dependencies(self):
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
        self.assertIn("artifact_lifecycle.py", script)
        self.assertIn("artifact_migration.py", script)
        self.assertIn("artifact_migration_cli.py", script)
        self.assertIn("artifact_catalog.py", script)
        self.assertIn("artifact_retention.py", script)
        self.assertIn("artifact_rollout.py", script)
        self.assertIn("artifact_rollout_cli.py", script)
        self.assertIn("artifact_store.py", script)
        self.assertIn("artifact_sync.py", script)
        self.assertIn("artifact_verification.py", script)
        self.assertIn("artifact_verification_cli.py", script)
        self.assertIn("program_artifacts.py", script)
        self.assertIn("fresh_install.py", script)
        self.assertIn("fresh_install_cli.py", script)
        self.assertIn("followup_tickets.py", script)
        self.assertIn("relay-artifact-migrate", script)
        self.assertIn("relay-artifact-verify", script)
        self.assertIn("relay-artifact-rollout", script)
        self.assertIn("relay-runner-fresh-install", script)
        self.assertNotIn('if [ -f "$PROJECT_ROOT/services/$f" ]', script)

        manifest = (
            script.split("# Python services", 1)[1]
            .split("; do", 1)[0]
            .split("for f in ", 1)[1]
            .replace("\\\n", " ")
            .split()
        )
        bundled_modules = {
            Path(filename).stem for filename in manifest if filename.endswith(".py")
        }
        services_dir = Path(SERVICES)
        local_modules = {path.stem for path in services_dir.glob("*.py")}
        missing_dependencies: list[str] = []

        for importer in sorted(bundled_modules):
            tree = ast.parse((services_dir / f"{importer}.py").read_text())
            imported_names: list[str] = []
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imported_names.extend(alias.name for alias in node.names)
                elif isinstance(node, ast.ImportFrom) and node.module:
                    if node.module == "services":
                        imported_names.extend(alias.name for alias in node.names)
                    else:
                        imported_names.append(node.module)

            for imported_name in imported_names:
                parts = imported_name.split(".")
                dependency = parts[1] if parts[0] == "services" else parts[0]
                if dependency in local_modules and dependency not in bundled_modules:
                    missing_dependencies.append(f"{importer}.py -> {dependency}.py")

        self.assertEqual(missing_dependencies, [])

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

    def test_demo_self_explanation_is_provider_neutral_conversation(self):
        source_text = (
            "I'm demoing Relay Runner; please explain what it does to the audience."
        )

        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                command = {
                    "provider": provider,
                    "relay_command_seq": 10,
                    "relay_command_id": f"{provider}-demo-10",
                    "source_text": source_text,
                }

                resolved = voice_bridge._resolve_voice_work_items(
                    source_text,
                    command,
                    repo_path="/tmp/repo",
                )

                self.assertEqual(len(resolved), 1)
                self.assertEqual(resolved[0]["action"].kind, "conversation")
                self.assertEqual(
                    resolved[0]["action"].reason,
                    "relay_runner_self_explanation",
                )
                self.assertEqual(
                    resolved[0]["disposition"].route,
                    voice_bridge.IntentRoute.CONTINUE_CURRENT,
                )
                self.assertEqual(resolved[0]["metadata"]["provider"], provider)

    def test_information_query_voice_metadata_never_authorizes_project_mutation(self):
        read_only_cases = [
            ("So my question is, did we release a build containing RR-325 through RR-343?", "inspect_ticket"),
            ("Can you tell me whether RR-325 is done?", "inspect_ticket"),
            ("What is the status of RR-325?", "inspect_ticket"),
            ("Can you update me on RR-325?", "inspect_ticket"),
            ("Give me an update on RR-325.", "inspect_ticket"),
            ("Can you run me through RR-325?", "inspect_ticket"),
            ("Explain why the build failed.", "conversation"),
            ("Show me the build history.", "conversation"),
            ("Summarize the latest build.", "conversation"),
            ("Review the build history", "conversation"),
            ("Please review whether the release shipped.", "conversation"),
            ("Investigate why the build failed", "conversation"),
            ("Could you investigate whether RR-325 shipped?", "inspect_ticket"),
            ("Check whether the build shipped", "conversation"),
            ("Check if the latest build included RR-325.", "inspect_ticket"),
            ("Explain the RR-325 build failure.", "inspect_ticket"),
            ("Find evidence that RR-325 shipped in the build.", "inspect_ticket"),
            ("Have we shipped RR-325?", "inspect_ticket"),
            ("Will we ship RR-325 in the next release?", "inspect_ticket"),
            ("Do we have a clean build?", "conversation"),
        ]

        for provider in ("codex", "claude"):
            for index, (source_text, expected_kind) in enumerate(read_only_cases, start=1):
                with (
                    self.subTest(provider=provider, source_text=source_text),
                    tempfile.TemporaryDirectory() as temp_dir,
                ):
                    repo = Path(temp_dir)
                    orch = repo / ".orchestrator"
                    orch.mkdir()
                    config = orch / "config.toml"
                    config.write_text('prefix = "RR"\nnext_id = 400\n')
                    command = {
                        "provider": provider,
                        "relay_command_seq": index,
                        "relay_command_id": f"{provider}-query-{index}",
                        "source_text": source_text,
                    }

                    resolved = voice_bridge._resolve_voice_work_items(
                        source_text,
                        command,
                        repo_path=repo,
                    )

                    self.assertEqual(len(resolved), 1)
                    entry = resolved[0]
                    self.assertEqual(entry["action"].kind, expected_kind)
                    self.assertFalse(entry["action"].requires_ticket)
                    self.assertFalse(entry["metadata"]["requires_ticket"])
                    self.assertEqual(
                        entry["disposition"].route,
                        voice_bridge.IntentRoute.CONTINUE_CURRENT,
                    )
                    self.assertEqual(entry["metadata"]["provider"], provider)
                    self.assertEqual(
                        entry["metadata"]["authorization_relationship"],
                        "inspection" if expected_kind == "inspect_ticket" else "conversation",
                    )
                    self.assertNotIn(
                        "repository",
                        entry["disposition"].resource_claims,
                    )
                    self.assertEqual(
                        voice_bridge.allowed_mutations_for_metadata(entry["metadata"]),
                        [],
                    )
                    self.assertFalse(
                        voice_bridge._should_fanout_raw_instruction_to_orchestrator(
                            entry["action"]
                        )
                    )
                    self.assertEqual(
                        config.read_text(),
                        'prefix = "RR"\nnext_id = 400\n',
                    )
                    self.assertEqual(list(orch.glob("RR-*.md")), [])

    def test_explicit_mutation_voice_metadata_retains_authority_for_both_providers(self):
        mutation_cases = [
            ("Fix RR-325.", "update_ticket"),
            ("Update RR-325.", "update_ticket"),
            ("Build the release.", "create_ticket"),
            ("Run RR-325.", "dispatch_ticket"),
            ("Dispatch RR-325.", "dispatch_ticket"),
            ("Track an investigation into why the build failed.", "create_ticket"),
            ("Queue a review of the build history.", "create_ticket"),
            ("Delegate an investigation into why RR-325 failed.", "dispatch_ticket"),
            ("Track an investigation into RR-325.", "create_ticket"),
            ("Queue a review of RR-325.", "create_ticket"),
            ("Do a clean build.", "create_ticket"),
            ("Have the worker fix RR-325.", "dispatch_ticket"),
            ("Tell the worker to investigate RR-325.", "dispatch_ticket"),
            ("Ask the agent to review RR-325.", "dispatch_ticket"),
            ("I need a clean build.", "create_ticket"),
            ("Go ahead and build the release.", "create_ticket"),
            ("For RR-325, fix the auth bug", "update_ticket"),
            ("In RR-325, update the acceptance criteria", "update_ticket"),
        ]

        for provider in ("codex", "claude"):
            for index, (source_text, expected_kind) in enumerate(mutation_cases, start=1):
                with self.subTest(provider=provider, source_text=source_text):
                    command = {
                        "provider": provider,
                        "relay_command_seq": index,
                        "relay_command_id": f"{provider}-mutation-{index}",
                        "source_text": source_text,
                    }

                    resolved = voice_bridge._resolve_voice_work_items(
                        source_text,
                        command,
                        repo_path="/tmp/repo",
                    )

                    self.assertEqual(len(resolved), 1)
                    entry = resolved[0]
                    self.assertEqual(entry["action"].kind, expected_kind)
                    self.assertTrue(entry["action"].requires_ticket)
                    self.assertEqual(
                        entry["disposition"].route,
                        voice_bridge.IntentRoute.QUEUE_PROJECT_WORK,
                    )
                    self.assertEqual(entry["metadata"]["provider"], provider)
                    self.assertNotEqual(
                        voice_bridge.allowed_mutations_for_metadata(entry["metadata"]),
                        [],
                    )
                    self.assertTrue(
                        voice_bridge._should_fanout_raw_instruction_to_orchestrator(
                            entry["action"]
                        )
                    )

    def test_mixed_query_and_mutation_stays_one_non_mutating_clarification(self):
        mixed_cases = [
            "Is there a release, and if not, build one",
            "Can you run me through RR-325, and if it needs changes, update RR-325.",
            "What is the status of RR-325, then update RR-325.",
            "Can you run me through RR-325, then dispatch RR-325.",
            "Review the build history, then build the release.",
            "Investigate why the build failed, then repair it.",
            "Check whether the build shipped, and if not, build it.",
            "Please review RR-325 and merge it.",
        ]

        for provider in ("codex", "claude"):
            for index, source_text in enumerate(mixed_cases, start=1):
                with self.subTest(provider=provider, source_text=source_text):
                    command = {
                        "provider": provider,
                        "relay_command_seq": index,
                        "relay_command_id": f"{provider}-mixed-{index}",
                        "source_text": source_text,
                    }

                    resolved = voice_bridge._resolve_voice_work_items(
                        source_text,
                        command,
                        repo_path="/tmp/repo",
                    )

                    self.assertEqual(len(resolved), 1)
                    self.assertEqual(resolved[0]["action"].kind, "conversation")
                    self.assertFalse(resolved[0]["action"].requires_ticket)
                    self.assertEqual(
                        resolved[0]["disposition"].route,
                        voice_bridge.IntentRoute.CONTINUE_CURRENT,
                    )
                    self.assertEqual(
                        voice_bridge.allowed_mutations_for_metadata(resolved[0]["metadata"]),
                        [],
                    )
                    self.assertFalse(
                        voice_bridge._should_fanout_raw_instruction_to_orchestrator(
                            resolved[0]["action"]
                        )
                    )
                    self.assertIn("Ask one concise clarification", resolved[0]["prompt"])

    def test_ordered_mutation_clauses_without_a_query_retain_authority(self):
        source_text = "Fix RR-325, then dispatch RR-325."

        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                command = {
                    "provider": provider,
                    "relay_command_seq": 12,
                    "relay_command_id": f"{provider}-mutations-12",
                    "source_text": source_text,
                }

                resolved = voice_bridge._resolve_voice_work_items(
                    source_text,
                    command,
                    repo_path="/tmp/repo",
                )

                self.assertEqual(
                    [entry["action"].kind for entry in resolved],
                    ["update_ticket", "dispatch_ticket"],
                )
                self.assertEqual(
                    [entry["disposition"].route for entry in resolved],
                    [
                        voice_bridge.IntentRoute.QUEUE_PROJECT_WORK,
                        voice_bridge.IntentRoute.QUEUE_PROJECT_WORK,
                    ],
                )
                for entry in resolved:
                    self.assertNotEqual(
                        voice_bridge.allowed_mutations_for_metadata(entry["metadata"]),
                        [],
                    )
                    self.assertTrue(
                        voice_bridge._should_fanout_raw_instruction_to_orchestrator(
                            entry["action"]
                        )
                    )

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
            self.assertEqual(worker.stop_reason, "interrupt")
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

        direct_action = voice_bridge.resolve_command_action(
            "open Chrome",
            repo_path="/tmp/repo",
            relay_command=relay_command,
        )
        self.assertEqual(direct_action.kind, "direct_action")
        self.assertFalse(
            voice_bridge._should_fanout_raw_instruction_to_orchestrator(direct_action)
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

    def test_private_command_event_log_serializes_concurrent_captures(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            event_path = os.path.join(temp_dir, "voice_command_events.jsonl")
            start = threading.Barrier(8)
            errors = []

            def record(index: int) -> None:
                try:
                    start.wait(2)
                    voice_bridge._record_private_command_capture(
                        {
                            "relay_command_seq": index,
                            "relay_command_id": f"cmd-{index}",
                            "received_at": float(index),
                            "source_text": f"command {index}",
                            "action": "received",
                        },
                        event_log_path=event_path,
                        limit=8,
                    )
                except Exception as error:  # noqa: BLE001 - captured for thread assertion.
                    errors.append(error)

            threads = [threading.Thread(target=record, args=(index,)) for index in range(1, 9)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(3)

            self.assertEqual(errors, [])
            events = [json.loads(line) for line in Path(event_path).read_text().splitlines()]
            self.assertEqual(
                {event["relay_command_seq"] for event in events},
                set(range(1, 9)),
            )

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
            script.count("RELAY_ACTOR_ROLE=\"${RELAY_ACTOR_ROLE:-foreground_manual}\""),
            2,
        )
        self.assertEqual(script.count("/usr/bin/python3 '__RELAY_REPLY_HELPER__'"), 2)
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
