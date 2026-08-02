from __future__ import annotations

import os
import json
import queue
import sys
import threading
import time
import unittest
from unittest.mock import patch


ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from messenger import (  # noqa: E402
    MESSENGER_SYSTEM_PROMPT,
    ClaudeMessengerBackend,
    CodexMessengerBackend,
    MessengerConfig,
    MessengerRuntime,
    resolve_messenger_catalog_selection,
    resolve_messenger_command,
)


CODEX_MODEL_LIST_FIXTURE = json.dumps({
    "data": [
        {
            "id": "gpt-5.7-sol",
            "model": "gpt-5.7-sol",
            "hidden": False,
            "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
        {
            "id": "gpt-6.0-sol",
            "model": "gpt-6.0-sol",
            "hidden": False,
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
    ],
})


class FakeBackend:
    def __init__(self, responses: list[str] | None = None):
        self.responses: queue.Queue[str] = queue.Queue()
        for response in responses or []:
            self.responses.put(response)
        self.prompts: list[str] = []
        self.started = threading.Event()
        self.interrupt_count = 0
        self.shutdown_count = 0

    def start(self) -> None:
        self.started.set()

    def ask(self, prompt: str, timeout: float = 60.0) -> str:
        self.prompts.append(prompt)
        return self.responses.get(timeout=timeout)

    def interrupt(self) -> None:
        self.interrupt_count += 1

    def shutdown(self) -> None:
        self.shutdown_count += 1


class BlockingBackend(FakeBackend):
    def __init__(self, first_response: str, later_responses: list[str] | None = None):
        super().__init__(later_responses)
        self.first_response = first_response
        self.first_prompt_started = threading.Event()
        self.release_first_response = threading.Event()

    def ask(self, prompt: str, timeout: float = 60.0) -> str:
        self.prompts.append(prompt)
        if not self.first_prompt_started.is_set():
            self.first_prompt_started.set()
            if not self.release_first_response.wait(timeout):
                raise queue.Empty("timed out waiting to release first messenger response")
            return self.first_response
        return self.responses.get(timeout=timeout)


def wait_until(predicate, timeout: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


class MessengerConfigTests(unittest.TestCase):
    def test_provider_defaults_select_fast_messenger_models(self):
        codex = MessengerConfig.from_app_config({"general": {"provider": "codex"}})
        claude = MessengerConfig.from_app_config({"general": {"provider": "claude"}})

        self.assertTrue(codex.enabled)
        self.assertEqual(codex.model, "sol")
        self.assertEqual(codex.effort, "default")
        self.assertEqual(claude.model, "best")
        self.assertEqual(claude.effort, "default")

    def test_explicit_messenger_settings_are_provider_validated(self):
        config = MessengerConfig.from_app_config({
            "general": {
                "provider": "claude",
                "messenger_enabled": False,
                "messenger_model": "sonnet",
                "messenger_effort": "low",
                "command": "/opt/bin/claude",
            }
        })

        self.assertFalse(config.enabled)
        self.assertEqual(config.command, "/opt/bin/claude")
        self.assertEqual(config.model, "sonnet")
        self.assertEqual(config.effort, "low")

        invalid = MessengerConfig.from_app_config({
            "general": {
                "provider": "codex",
                "messenger_model": "haiku",
                "messenger_effort": "ultra",
            }
        })
        self.assertEqual(invalid.model, "sol")
        self.assertEqual(invalid.effort, "default")

    def test_codex_messenger_family_resolves_from_runtime_catalogue(self):
        config = MessengerConfig(True, "codex", "codex", "sol", "default", "/tmp")

        with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": CODEX_MODEL_LIST_FIXTURE}):
            resolved = resolve_messenger_catalog_selection(config)

        self.assertEqual(resolved.model, "gpt-6.0-sol")
        self.assertEqual(resolved.effort, "medium")

    def test_prompt_forbids_work_and_hidden_reasoning(self):
        self.assertIn("Never use tools", MESSENGER_SYSTEM_PROMPT)
        self.assertIn("provider-visible", MESSENGER_SYSTEM_PROMPT)
        self.assertIn("hidden chain-of-thought", MESSENGER_SYSTEM_PROMPT)
        self.assertIn("first-person singular", MESSENGER_SYSTEM_PROMPT)
        self.assertIn("refer to them directly", MESSENGER_SYSTEM_PROMPT)
        self.assertIn("__SILENT__", MESSENGER_SYSTEM_PROMPT)

    def test_codex_command_resolution_prefers_bundled_chatgpt_cli_without_path(self):
        chatgpt = "/Applications/ChatGPT.app/Contents/Resources/codex"
        legacy = "/Applications/Codex.app/Contents/Resources/codex"

        self.assertEqual(
            resolve_messenger_command(
                "codex",
                "codex",
                is_executable=lambda path: path in {chatgpt, legacy},
                which=lambda name: None,
            ),
            [chatgpt],
        )
        self.assertEqual(
            resolve_messenger_command(
                "codex",
                "codex",
                is_executable=lambda path: path == legacy,
                which=lambda name: None,
            ),
            [legacy],
        )

    def test_claude_command_resolution_uses_configured_or_known_installed_binary(self):
        self.assertEqual(
            resolve_messenger_command(
                "claude",
                "/custom/bin/claude --flag",
                is_executable=lambda path: path == "/custom/bin/claude",
                which=lambda name: None,
            ),
            ["/custom/bin/claude", "--flag"],
        )
        self.assertEqual(
            resolve_messenger_command(
                "claude",
                "claude",
                is_executable=lambda path: path.endswith("/.local/bin/claude"),
                which=lambda name: None,
            ),
            [os.path.expanduser("~/.local/bin/claude")],
        )


class MessengerBackendContractTests(unittest.TestCase):
    def test_codex_backend_uses_persistent_app_server_without_tools(self):
        config = MessengerConfig(
            enabled=True,
            provider="codex",
            command="/opt/bin/codex",
            model="gpt-5.6-terra",
            effort="low",
            cwd="/tmp/project",
        )
        backend = CodexMessengerBackend(config)

        command = backend.spawn_command()
        params = backend.thread_start_params()

        self.assertEqual(command[:3], ["/opt/bin/codex", "app-server", "--stdio"])
        self.assertIn("features.shell_tool=false", command)
        self.assertIn("features.unified_exec=false", command)
        self.assertEqual(params["model"], "gpt-5.6-terra")
        self.assertEqual(params["sandbox"], "read-only")
        self.assertEqual(params["approvalPolicy"], "never")
        self.assertEqual(params["dynamicTools"], [])
        self.assertTrue(params["ephemeral"])

    def test_codex_backend_collects_completed_agent_message(self):
        config = MessengerConfig(True, "codex", "codex", "gpt-5.6-terra", "low", "/tmp")
        backend = CodexMessengerBackend(config)
        event = threading.Event()
        backend._turn_events["turn-1"] = event

        backend._handle_message({
            "method": "item/completed",
            "params": {
                "turnId": "turn-1",
                "item": {"id": "item-1", "type": "agentMessage", "text": "Fast reply"},
            },
        })
        backend._handle_message({
            "method": "turn/completed",
            "params": {
                "threadId": "thread-1",
                "turn": {"id": "turn-1", "status": "completed", "items": []},
            },
        })

        self.assertTrue(event.is_set())
        self.assertEqual(backend._turn_text["turn-1"], "Fast reply")

    def test_claude_backend_uses_stream_json_haiku_without_tools(self):
        config = MessengerConfig(
            enabled=True,
            provider="claude",
            command="claude",
            model="haiku",
            effort="default",
            cwd="/tmp/project",
        )
        backend = ClaudeMessengerBackend(config)

        command = backend.spawn_command()

        self.assertIn("--input-format", command)
        self.assertIn("stream-json", command)
        self.assertIn("--output-format", command)
        self.assertIn("--tools", command)
        self.assertEqual(command[command.index("--tools") + 1], "")
        self.assertEqual(command[command.index("--model") + 1], "haiku")
        self.assertNotIn("--effort", command)

    def test_claude_backend_collects_stream_result_and_session_id(self):
        class FakeProcess:
            stdout = iter([
                json.dumps({"type": "system", "session_id": "session-1"}) + "\n",
                json.dumps({"type": "result", "session_id": "session-1", "result": "Fast reply"}) + "\n",
            ])

        config = MessengerConfig(True, "claude", "claude", "haiku", "default", "/tmp")
        backend = ClaudeMessengerBackend(config)
        pending = {"event": threading.Event(), "text": "", "error": None}
        process = FakeProcess()
        backend._pending = pending
        backend._proc = process

        backend._read_stream(process)

        self.assertEqual(backend._session_id, "session-1")
        self.assertTrue(pending["event"].is_set())
        self.assertEqual(pending["text"], "Fast reply")


class MessengerRuntimeTests(unittest.TestCase):
    def test_task_user_turn_generates_contextual_handoff_acknowledgement(self):
        backend = FakeBackend(["I picked up the architecture request, and I’ll come back with the next step."])
        spoken: list[tuple[str, int, str]] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append((text, seq, command_id)),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            runtime.submit_user(
                "Implement the new architecture",
                {"relay_command_seq": 4, "relay_command_id": "cmd-4"},
            )

            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            self.assertIn("Implement the new architecture", backend.prompts[0])
            self.assertIn("brief contextual acknowledgement", backend.prompts[0])
            self.assertIn("uses first-person singular language", backend.prompts[0])
            self.assertIn("refer to the workers directly", backend.prompts[0])
            self.assertEqual(
                spoken[0],
                (
                    "I picked up the architecture request, and I’ll come back with the next step.",
                    4,
                    "cmd-4",
                ),
            )
        finally:
            runtime.shutdown()

    def test_user_turn_handoff_is_replayable_after_first_play(self):
        backend = FakeBackend(["I picked up the replay request."])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id, display_text, metadata: spoken.append(
                (text, seq, command_id, display_text, metadata)
            ),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            runtime.submit_user(
                "Fix replay",
                {"relay_command_seq": 5, "relay_command_id": "cmd-5"},
            )

            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            metadata = spoken[0][4]
            self.assertEqual(metadata["kind"], "handoff")
            self.assertTrue(metadata["replayable"])
        finally:
            runtime.shutdown()

    def test_progress_update_is_replayable_after_first_play(self):
        backend = FakeBackend([
            "I picked up the replay request.",
            "I’m checking the replay path now.",
        ])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id, display_text, metadata: spoken.append(
                (text, seq, command_id, display_text, metadata)
            ),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 6, "relay_command_id": "cmd-6"}
            runtime.submit_user("Fix replay", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))

            runtime.submit_trace({
                "kind": "reasoning-summary",
                "message": "Checking the replay path",
                "command": command,
            })
            self.assertTrue(wait_until(lambda: len(spoken) == 2))

            metadata = spoken[1][4]
            self.assertEqual(metadata["kind"], "progress")
            self.assertTrue(metadata["replayable"])
        finally:
            runtime.shutdown()

    def test_trace_and_final_share_bounded_context_and_only_current_reply_speaks(self):
        backend = FakeBackend([
            "I picked up the messenger work, and I’ll return with the next step.",
            "I’m checking the bridge wiring now.",
            "The messenger architecture is implemented and verified.",
        ])
        spoken: list[tuple[str, int, str]] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append((text, seq, command_id)),
            is_current=lambda seq, command_id: seq == 7 and command_id == "cmd-7",
            context_limit=6,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 7, "relay_command_id": "cmd-7"}
            runtime.submit_user("Build the fast messenger", command)
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))

            runtime.submit_trace({
                "kind": "reasoning-summary",
                "message": "Checking the voice bridge wiring",
                "command": command,
            })
            self.assertTrue(wait_until(lambda: len(spoken) == 2))

            runtime.submit_final({"text": "Implemented and verified.", **command})
            self.assertTrue(wait_until(lambda: len(spoken) == 3))

            self.assertEqual(
                spoken[0][0],
                "I picked up the messenger work, and I’ll return with the next step.",
            )
            self.assertEqual(spoken[1][0], "I’m checking the bridge wiring now.")
            self.assertEqual(spoken[2][0], "Implemented and verified.")
            self.assertIn("Checking the voice bridge wiring", backend.prompts[1])
            self.assertEqual(len(backend.prompts), 2)
            self.assertEqual(backend.interrupt_count, 0)
            self.assertLessEqual(runtime.context_size, 6)
        finally:
            runtime.shutdown()

    def test_unscoped_worker_lifecycle_trace_speaks_without_command_metadata(self):
        backend = FakeBackend(["RR-7 is awaiting review; it is not merged yet."])
        spoken: list[tuple[str, int | None, str | None]] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append((text, seq, command_id)),
            is_current=lambda seq, command_id: False,
        )
        runtime.start()
        try:
            accepted = runtime.submit_trace({
                "kind": "run-review-needed",
                "message": "RR-7 run 12 awaiting review",
                "source": "worker",
                "ticket_id": "RR-7",
                "run_id": 12,
            })

            self.assertTrue(accepted)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            self.assertEqual(spoken[0], ("RR-7 is awaiting review; it is not merged yet.", None, None))
            self.assertIn("WORKER LIFECYCLE (run-review-needed)", backend.prompts[0])
            self.assertIn("awaiting review is not done", backend.prompts[0])
        finally:
            runtime.shutdown()

    def test_unscoped_health_warning_speaks_without_command_metadata(self):
        backend = FakeBackend(["RR-7 is still alive, but it may need attention."])
        spoken: list[tuple[str, int | None, str | None]] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append((text, seq, command_id)),
            is_current=lambda seq, command_id: False,
        )
        runtime.start()
        try:
            accepted = runtime.submit_trace({
                "kind": "run-health-warning",
                "message": "RR-7 run 12 is alive but has no observable progress in the last 10 minutes",
                "source": "orchestrator",
                "ticket_id": "RR-7",
                "run_id": 12,
            })

            self.assertTrue(accepted)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            self.assertEqual(
                spoken[0],
                ("RR-7 is still alive, but it may need attention.", None, None),
            )
            self.assertIn("WORKER LIFECYCLE (run-health-warning)", backend.prompts[0])
        finally:
            runtime.shutdown()

    def test_silent_unscoped_worker_lifecycle_falls_back_to_event_text(self):
        backend = FakeBackend(["__SILENT__"])
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: False,
        )
        runtime.start()
        try:
            runtime.submit_trace({
                "kind": "run-merged",
                "message": "RR-7 run 12 merged",
                "source": "orchestrator",
                "ticket_id": "RR-7",
                "run_id": 12,
            })

            self.assertTrue(wait_until(lambda: spoken == ["RR-7 run 12 merged"]))
        finally:
            runtime.shutdown()

    def test_unscoped_worker_lifecycle_trace_survives_new_user_turn_queue_cleanup(self):
        backend = FakeBackend([
            "RR-8 failed and needs attention.",
            "I picked up the next request.",
        ])
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        try:
            self.assertTrue(runtime.submit_trace({
                "kind": "run-failed",
                "message": "RR-8 run 13 failed",
                "source": "worker",
                "ticket_id": "RR-8",
                "run_id": 13,
            }))
            self.assertTrue(runtime.submit_user(
                "What happened next?",
                {"relay_command_seq": 9, "relay_command_id": "cmd-9"},
            ))
            runtime.start()

            self.assertTrue(wait_until(lambda: spoken == [
                "RR-8 failed and needs attention.",
                "I picked up the next request.",
            ]))
        finally:
            runtime.shutdown()

    def test_duplicate_final_for_same_command_speaks_once(self):
        backend = FakeBackend(["__SILENT__", "The work is done."])
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 15, "relay_command_id": "cmd-15"}
            runtime.submit_user("Finish the task", command)
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))

            self.assertTrue(runtime.submit_final({"text": "Finished.", **command}))
            self.assertTrue(runtime.submit_final({"text": "Finished again.", **command}))

            self.assertTrue(wait_until(lambda: spoken == ["Finished."]))
            self.assertEqual(len(backend.prompts), 1)
        finally:
            runtime.shutdown()

    def test_final_replaces_queued_handoff_before_messenger_starts(self):
        backend = FakeBackend(["The work is complete."])
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        try:
            command = {"relay_command_seq": 17, "relay_command_id": "cmd-17"}
            self.assertTrue(runtime.submit_user("Finish the task", command))
            self.assertTrue(runtime.submit_final({"text": "Finished.", **command}))

            runtime.start()

            self.assertTrue(wait_until(lambda: spoken == ["Finished."]))
            self.assertEqual(len(backend.prompts), 0)
        finally:
            runtime.shutdown()

    def test_final_interrupts_inflight_handoff_and_speaks_only_final(self):
        backend = BlockingBackend(
            "I picked up the task, and I’ll return with the next step.",
            ["The work is complete."],
        )
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 18, "relay_command_id": "cmd-18"}
            self.assertTrue(runtime.submit_user("Finish the task", command))
            self.assertTrue(backend.first_prompt_started.wait(1.0))

            self.assertTrue(runtime.submit_final({"text": "Finished.", **command}))
            self.assertTrue(wait_until(lambda: backend.interrupt_count == 1))

            backend.release_first_response.set()

            self.assertTrue(
                wait_until(
                    lambda: spoken == ["Finished."] and len(backend.prompts) == 1,
                    timeout=2.0,
                )
            )
            self.assertNotIn("authoritative orchestrator reply", backend.prompts[0])
        finally:
            runtime.shutdown()

    def test_silent_final_falls_back_to_authoritative_text(self):
        backend = FakeBackend(["__SILENT__", "__SILENT__"])
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 11, "relay_command_id": "cmd-11"}
            runtime.submit_user("Give me the result", command)
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))
            runtime.submit_final({"text": "The authoritative result is ready.", **command})

            self.assertTrue(wait_until(lambda: spoken == ["The authoritative result is ready."]))
        finally:
            runtime.shutdown()

    def test_final_speech_preserves_authoritative_display_text(self):
        backend = FakeBackend(["__SILENT__", "Short spoken result."])
        spoken: list[tuple[str, int, str, str | None]] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id, display_text: spoken.append(
                (text, seq, command_id, display_text)
            ),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 16, "relay_command_id": "cmd-16"}
            runtime.submit_user("Give me the result", command)
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))
            runtime.submit_final({"text": "Authoritative provider result.", **command})

            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            self.assertEqual(
                spoken[0],
                (
                    "Authoritative provider result.",
                    16,
                    "cmd-16",
                    "Authoritative provider result.",
                ),
            )
        finally:
            runtime.shutdown()

    def test_sidecar_final_preserves_lifecycle_authority_metadata(self):
        backend = FakeBackend(["__SILENT__", "Verified sidecar result."])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id, display_text, metadata: spoken.append(
                (text, seq, command_id, display_text, metadata)
            ),
            is_current=lambda seq, command_id: True,
        )
        disposition = {
            "route": "run_sidecar",
            "public_reason": "Independent bounded public research.",
        }
        command = {
            "relay_command_seq": 19,
            "relay_command_id": "cmd-19",
            "work_disposition": disposition,
        }
        runtime.start()
        try:
            runtime.submit_user("Compare the public APIs", command)
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))
            runtime.submit_final({
                "text": "The verified comparison is ready.",
                "speech_source": "lifecycle",
                "work_disposition": disposition,
                **command,
            })

            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            metadata = spoken[0][4]
            self.assertEqual(metadata["source"], "lifecycle")
            self.assertEqual(metadata["kind"], "final")
            self.assertTrue(metadata["authoritative"])
            self.assertEqual(metadata["work_disposition"], disposition)
        finally:
            runtime.shutdown()

    def test_new_user_turn_interrupts_inflight_messenger_only(self):
        backend = FakeBackend(["__SILENT__", "__SILENT__"])
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: None,
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            runtime.submit_user("First", {"relay_command_seq": 1, "relay_command_id": "one"})
            runtime.submit_user("Second", {"relay_command_seq": 2, "relay_command_id": "two"})

            self.assertGreaterEqual(backend.interrupt_count, 1)
        finally:
            runtime.shutdown()

    def test_first_trace_waits_for_inflight_task_handoff_before_speaking(self):
        backend = BlockingBackend(
            "I picked up the bridge fix request, and I’ll return with a plan.",
            ["I’m checking the bridge wiring now."],
        )
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 12, "relay_command_id": "cmd-12"}
            runtime.submit_user("Fix the voice bridge race", command)
            self.assertTrue(backend.first_prompt_started.wait(1.0))

            runtime.submit_trace({
                "kind": "reasoning-summary",
                "message": "Checking the voice bridge wiring",
                "command": command,
            })

            time.sleep(0.05)
            self.assertEqual(spoken, [])
            self.assertEqual(len(backend.prompts), 1)
            self.assertEqual(backend.interrupt_count, 0)

            backend.release_first_response.set()

            self.assertTrue(wait_until(lambda: len(spoken) == 2 and len(backend.prompts) == 2, timeout=2.0))
            self.assertEqual(spoken, [
                "I picked up the bridge fix request, and I’ll return with a plan.",
                "I’m checking the bridge wiring now.",
            ])
        finally:
            runtime.shutdown()

    def test_clarification_trace_is_rendered_as_a_direct_user_question(self):
        backend = FakeBackend([
            "I picked up the test fix request, and I’ll come back with the next step.",
            "Which repository should I use?",
        ])
        spoken: list[str] = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda text, seq, command_id: spoken.append(text),
            is_current=lambda seq, command_id: True,
        )
        runtime.start()
        try:
            command = {"relay_command_seq": 9, "relay_command_id": "cmd-9"}
            runtime.submit_user("Fix the tests", command)
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 1))
            runtime.submit_trace({
                "kind": "clarification-request",
                "message": "Ask which repository should be changed",
                "command": command,
            })

            self.assertTrue(wait_until(lambda: spoken == [
                "I picked up the test fix request, and I’ll come back with the next step.",
                "Which repository should I use?",
            ]))
            self.assertIn("authoritative clarification request", backend.prompts[1])
        finally:
            runtime.shutdown()

    def test_final_synthesis_preserves_result_after_played_acknowledgement(self):
        backend = FakeBackend([
            "I picked up RR-263 and will return with the result.",
            json.dumps({
                "decision": "delta",
                "spoken_text": "RR-263 is implemented and verified; the focused tests pass.",
                "lifecycle_role": "conversation",
                "covered_facts": ["a model claim that must not become played coverage"],
            }),
        ])
        spoken = []
        observed = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "acknowledgement",
                "covered_facts": ("RR-263 was accepted",),
                "spoken_text": "I picked up RR-263 and will return with the result.",
            },),
            realization_observer=lambda *args, **kwargs: observed.append((args, kwargs)),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 31,
                "relay_command_id": "cmd-31",
                "work_disposition": {"route": "queue_project_work"},
            }
            runtime.submit_user("Implement RR-263", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            runtime.submit_final({"text": "RR-263 is implemented and verified.", **command})

            self.assertTrue(wait_until(lambda: len(spoken) == 2))
            self.assertEqual(spoken[1][0], "RR-263 is implemented and verified.")
            self.assertEqual(spoken[1][4]["lifecycle_role"], "result")
            self.assertEqual(spoken[1][4]["realization_decision"], "full")
            self.assertEqual(spoken[1][4]["covered_facts"], (spoken[1][0],))
            self.assertEqual(len(backend.prompts), 1)
            self.assertEqual(observed[0][1]["decision"], "full")
            self.assertEqual(observed[0][1]["reason"], "authoritative_final_direct")
        finally:
            runtime.shutdown()

    def test_redundant_plan_restatement_is_suppressed_after_played_handoff(self):
        backend = FakeBackend([
            "I picked up the bridge review and will check the wiring next.",
            json.dumps({
                "decision": "suppress",
                "spoken_text": "",
                "lifecycle_role": "progress",
                "covered_facts": [],
            }),
        ])
        spoken = []
        observed = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "acknowledgement",
                "covered_facts": ("bridge wiring will be checked next",),
                "spoken_text": "I will check the bridge wiring next.",
            },),
            realization_observer=lambda *args, **kwargs: observed.append(kwargs),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 32,
                "relay_command_id": "cmd-32",
                "work_disposition": {"route": "queue_project_work"},
            }
            runtime.submit_user("Review the bridge", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            runtime.submit_trace({
                "kind": "reasoning-summary",
                "message": "I will check the bridge wiring next.",
                "command": command,
            })

            self.assertTrue(wait_until(lambda: len(backend.prompts) == 2))
            self.assertTrue(wait_until(lambda: observed == [{
                "lifecycle_role": "progress",
                "decision": "suppress",
                "reason": "covered_by_played_speech",
            }]))
            self.assertEqual(len(spoken), 1)
        finally:
            runtime.shutdown()

    def test_redundant_progress_is_suppressed_but_clarification_fails_open(self):
        backend = FakeBackend([
            "I picked up the bridge review and will inspect the wiring.",
            json.dumps({
                "decision": "suppress",
                "spoken_text": "",
                "lifecycle_role": "progress",
                "covered_facts": [],
            }),
            json.dumps({
                "decision": "suppress",
                "spoken_text": "",
                "lifecycle_role": "decision",
                "covered_facts": [],
            }),
        ])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "acknowledgement",
                "covered_facts": ("bridge wiring will be inspected",),
                "spoken_text": "I will inspect the bridge wiring.",
            },),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 35,
                "relay_command_id": "cmd-35",
                "work_disposition": {"route": "queue_project_work"},
            }
            runtime.submit_user("Review the bridge", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            runtime.submit_trace({
                "kind": "reasoning-summary",
                "message": "I will inspect the bridge wiring.",
                "command": command,
            })
            self.assertTrue(wait_until(lambda: len(backend.prompts) == 2))
            self.assertEqual(len(spoken), 1)

            runtime.submit_trace({
                "kind": "clarification-request",
                "message": "Which bridge implementation should I inspect?",
                "command": command,
            })
            self.assertTrue(wait_until(lambda: len(spoken) == 2))
            self.assertEqual(spoken[1][0], "Which bridge implementation should I inspect?")
            self.assertEqual(spoken[1][4]["lifecycle_role"], "decision")
        finally:
            runtime.shutdown()

    def test_conversational_final_uses_authoritative_text_without_model_round_trip(self):
        backend = FakeBackend([
            "You’re welcome.",
            json.dumps({
                "decision": "suppress",
                "spoken_text": "",
                "lifecycle_role": "conversation",
                "covered_facts": [],
            }),
        ])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "conversation",
                "covered_facts": ("acknowledged thanks",),
                "spoken_text": "You’re welcome.",
            },),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 33,
                "relay_command_id": "cmd-33",
                "work_disposition": {"route": "continue_current"},
            }
            runtime.submit_user("Thanks", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            runtime.submit_final({"text": "You are welcome.", **command})

            self.assertTrue(wait_until(lambda: len(spoken) == 2))
            self.assertEqual(spoken[1][0], "You are welcome.")
            self.assertEqual(len(backend.prompts), 1)
        finally:
            runtime.shutdown()

    def test_actionable_final_ignores_model_lifecycle_role_and_fails_open(self):
        backend = FakeBackend([
            "I picked it up.",
            json.dumps({
                "decision": "suppress",
                "spoken_text": "",
                "lifecycle_role": "conversation",
                "covered_facts": ["RR-263 completed"],
            }),
        ])
        spoken = []
        observed = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "acknowledgement",
                "covered_facts": ("request accepted",),
                "spoken_text": "I picked it up.",
            },),
            realization_observer=lambda *args, **kwargs: observed.append(kwargs),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 41,
                "relay_command_id": "cmd-41",
                "work_disposition": {"route": "queue_project_work"},
            }
            runtime.submit_user("Handle RR-263", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            final = "RR-263 completed and run 35 passed."
            runtime.submit_final({"text": final, **command})

            self.assertTrue(wait_until(lambda: len(spoken) == 2))
            self.assertEqual(spoken[1][0], final)
            self.assertEqual(spoken[1][4]["lifecycle_role"], "result")
            self.assertEqual(spoken[1][4]["realization_decision"], "full")
            self.assertEqual(observed, [{
                "lifecycle_role": "result",
                "decision": "full",
                "reason": "authoritative_final_direct",
            }])
        finally:
            runtime.shutdown()

    def test_lossy_delta_and_malformed_arbitration_fail_open(self):
        responses = [
            json.dumps({
                "decision": "delta",
                "spoken_text": "RR-263 completed.",
                "lifecycle_role": "result",
                "covered_facts": ["run 42 failed", "deployment is blocked"],
            }),
            "not-json",
        ]
        for index, response in enumerate(responses, start=1):
            with self.subTest(response=response):
                backend = FakeBackend(["I picked it up.", response])
                spoken = []
                runtime = MessengerRuntime(
                    backend,
                    speak=lambda *args: spoken.append(args),
                    is_current=lambda seq, command_id: True,
                    coverage_provider=lambda seq, command_id: ({
                        "lifecycle_role": "acknowledgement",
                        "covered_facts": ("request accepted",),
                        "spoken_text": "I picked it up.",
                    },),
                )
                runtime.start()
                try:
                    command = {
                        "relay_command_seq": 40 + index,
                        "relay_command_id": f"cmd-{40 + index}",
                        "work_disposition": {"route": "queue_project_work"},
                    }
                    runtime.submit_user("Handle this", command)
                    self.assertTrue(wait_until(lambda: len(spoken) == 1))
                    final = "RR-263 completed, but run 42 failed and deployment is blocked."
                    runtime.submit_final({"text": final, **command})

                    self.assertTrue(wait_until(lambda: len(spoken) == 2))
                    self.assertEqual(spoken[1][0], final)
                    self.assertEqual(spoken[1][4]["realization_decision"], "full")
                    self.assertEqual(
                        spoken[1][4]["suppression_reason"],
                        "authoritative_final_direct",
                    )
                finally:
                    runtime.shutdown()

    def test_lossy_full_rewrite_fails_open_to_authoritative_text(self):
        backend = FakeBackend([
            "I picked it up.",
            json.dumps({"decision": "full", "spoken_text": "Done."}),
        ])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "acknowledgement",
                "covered_facts": ("request accepted",),
                "spoken_text": "I picked it up.",
            },),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 43,
                "relay_command_id": "cmd-43",
                "work_disposition": {"route": "queue_project_work"},
            }
            runtime.submit_user("Handle RR-263", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            final = (
                "RR-263 failed in run 42 because deployment is blocked. Decide whether to "
                "retry, then inspect the logs and review the report."
            )
            runtime.submit_final({"text": final, **command})

            self.assertTrue(wait_until(lambda: len(spoken) == 2))
            self.assertEqual(spoken[1][0], final)
            self.assertEqual(spoken[1][4]["realization_decision"], "full")
            self.assertEqual(
                spoken[1][4]["suppression_reason"],
                "authoritative_final_direct",
            )
        finally:
            runtime.shutdown()

    def test_delta_that_omits_next_action_verbs_fails_open(self):
        backend = FakeBackend([
            "I picked it up.",
            json.dumps({
                "decision": "delta",
                "spoken_text": "RR-263 passed run 39. The logs and deployment report are next.",
            }),
        ])
        spoken = []
        runtime = MessengerRuntime(
            backend,
            speak=lambda *args: spoken.append(args),
            is_current=lambda seq, command_id: True,
            coverage_provider=lambda seq, command_id: ({
                "lifecycle_role": "acknowledgement",
                "covered_facts": ("request accepted",),
                "spoken_text": "I picked it up.",
            },),
        )
        runtime.start()
        try:
            command = {
                "relay_command_seq": 44,
                "relay_command_id": "cmd-44",
                "work_disposition": {"route": "queue_project_work"},
            }
            runtime.submit_user("Handle RR-263", command)
            self.assertTrue(wait_until(lambda: len(spoken) == 1))
            final = (
                "RR-263 passed run 39. Inspect the logs and review the deployment report next."
            )
            runtime.submit_final({"text": final, **command})

            self.assertTrue(wait_until(lambda: len(spoken) == 2))
            self.assertEqual(spoken[1][0], final)
            self.assertEqual(spoken[1][4]["realization_decision"], "full")
            self.assertEqual(
                spoken[1][4]["suppression_reason"],
                "authoritative_final_direct",
            )
        finally:
            runtime.shutdown()

    def test_full_and_delta_relation_reversals_fail_open(self):
        cases = (
            (
                "full",
                "The unit test passed and the integration test failed.",
                "The unit test failed and the integration test passed.",
                "lossy_full",
            ),
            (
                "delta",
                "The unit test passed and the integration test failed.",
                "The unit test failed and the integration test passed.",
                "lossy_delta",
            ),
            (
                "full",
                "The deployment check passed.",
                "The deployment check did not pass.",
                "lossy_full",
            ),
            (
                "delta",
                "The deployment check passed.",
                "The deployment check did not pass.",
                "lossy_delta",
            ),
        )
        for index, (decision, authoritative, rewrite, reason) in enumerate(cases):
            with self.subTest(decision=decision, rewrite=rewrite):
                backend = FakeBackend([
                    "I picked it up.",
                    json.dumps({"decision": decision, "spoken_text": rewrite}),
                ])
                spoken = []
                runtime = MessengerRuntime(
                    backend,
                    speak=lambda *args: spoken.append(args),
                    is_current=lambda seq, command_id: True,
                    coverage_provider=lambda seq, command_id: ({
                        "lifecycle_role": "acknowledgement",
                        "covered_facts": ("request accepted",),
                        "spoken_text": "I picked it up.",
                    },),
                )
                runtime.start()
                try:
                    command = {
                        "relay_command_seq": 45 + index,
                        "relay_command_id": f"cmd-{45 + index}",
                        "work_disposition": {"route": "queue_project_work"},
                    }
                    runtime.submit_user("Check the results", command)
                    self.assertTrue(wait_until(lambda: len(spoken) == 1))
                    runtime.submit_final({"text": authoritative, **command})

                    self.assertTrue(wait_until(lambda: len(spoken) == 2))
                    self.assertEqual(spoken[1][0], authoritative)
                    self.assertEqual(spoken[1][4]["realization_decision"], "full")
                    self.assertEqual(
                        spoken[1][4]["suppression_reason"],
                        "authoritative_final_direct",
                    )
                finally:
                    runtime.shutdown()


if __name__ == "__main__":
    unittest.main()
