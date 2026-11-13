"""Voice bridge contract: the process, its start-up and shut-down, and the
control socket (docs/specs/voice-bridge-contract.md, "Process" and "Control
socket")."""

from __future__ import annotations

import os
import stat
import unittest

from bridge_contract_support import (
    STARTUP_GREETING,
    BridgeCase,
    is_fifo,
    read_jsonl,
    wait_until,
)


class ProcessContract:
    def test_startup_creates_the_fifos_and_sockets_at_their_configured_paths(self):
        """Process: the bridge makes `VOICE_FIFO` and the TTS FIFO, binds
        `BRIDGE_CONTROL_SOCK`, listens on `RELAY_REMOTE_SOCK` with mode 0600 and
        writes its pid to `voice_bridge.pid` in `RELAY_BRIDGE_RUNTIME_DIR`."""
        box = self.box
        self.assertTrue(is_fifo(box.voice_fifo))
        self.assertTrue(is_fifo(box.tts_fifo))
        self.assertTrue(stat.S_ISSOCK(os.stat(box.control_sock).st_mode))
        remote = os.stat(box.remote_sock)
        self.assertTrue(stat.S_ISSOCK(remote.st_mode))
        self.assertEqual(stat.S_IMODE(remote.st_mode), 0o600)
        self.assertEqual(box.runtime_file("voice_bridge.pid").read_text().strip(), str(box.process.pid))

    def test_startup_registers_the_orchestrator_session_and_heartbeats_it(self):
        """Process: start-up posts `/v1/orchestrator-session/ensure` for the
        working directory and then heartbeats the returned session every
        `ORCHESTRATOR_HEARTBEAT_SECONDS`."""
        ensure = self.box.orchestrator.requests("/v1/orchestrator-session/ensure")[0]["body"]
        self.assertEqual(ensure["repo_path"], os.path.realpath(self.box.repo))
        self.assertEqual(ensure["provider"], self.provider)
        self.assertEqual(ensure["source"], "relay-bridge")
        self.assertEqual(ensure["pid"], self.box.process.pid)
        self.assertEqual(ensure["state"], "idle")
        self.assertIsInstance(ensure["command_action_states"], list)
        heartbeats = wait_until(
            lambda: len(self.box.orchestrator.requests("/v1/orchestrator-session/heartbeat")) >= 3
            and self.box.orchestrator.requests("/v1/orchestrator-session/heartbeat"),
            message="three heartbeats",
        )
        for heartbeat in heartbeats:
            self.assertEqual(heartbeat["body"]["session_id"], self.box.orchestrator.session_id)
            self.assertEqual(heartbeat["body"]["provider"], self.provider)
            self.assertEqual(heartbeat["body"]["state"], "idle")

    def test_startup_starts_the_speech_service_with_the_session_paths(self):
        """Process: the bridge starts `RELAY_SPEECH_SERVICE_CMD` with
        `--socket $RELAY_SPEECH_SERVICE_SOCK --config <its config>`, passes the
        session's command state file, `SPEECH_EVENT_LOG` and `TTS_CONTROL_SOCK`,
        and says hello with protocol 1."""
        started = [record for record in self.box.speech_records() if record["record"] == "started"][0]
        self.assertEqual(started["ppid"], self.box.process.pid)
        self.assertEqual(started["socket"], str(self.box.speech_sock))
        self.assertEqual(started["config"], str(self.box.config_path))
        self.assertEqual(started["env"]["VOICE_COMMAND_STATE_FILE"], str(self.session.state_file))
        self.assertEqual(started["env"]["SPEECH_EVENT_LOG"], str(self.box.speech_event_log))
        self.assertEqual(started["env"]["TTS_CONTROL_SOCK"], str(self.box.tts_control))
        hello = self.box.speech_requests("hello")
        self.assertEqual(len(hello), 1)
        self.assertEqual(hello[0]["protocol"], 1)
        self.assertEqual(hello[0]["pid"], self.box.process.pid)

    def test_startup_greeting_is_spoken_once_without_a_command(self):
        """Process: without `--suppress-startup-greeting` the greeting is
        offered to speech once, as a fallback with no command."""
        greeting = self.box.wait_spoken(text=STARTUP_GREETING)
        self.assertEqual(greeting["source"], "fallback")
        self.assertEqual(greeting["kind"], "fallback")
        self.assertNotIn("command_seq", greeting)
        self.assertStays(lambda: len(self.box.spoken(text=STARTUP_GREETING)) == 1)

    def test_readiness_is_recorded_in_the_support_journal(self):
        """Process: once the FIFO is open the bridge records `bridge_readiness`
        `ready` for its provider in `RELAY_DIAGNOSTICS_DIR`."""
        journal = self.box.diagnostics / f"events-v1-shell-{self.box.process.pid}.jsonl"
        event = wait_until(
            lambda: [
                record for record in read_jsonl(journal)
                if record.get("phase") == "bridge_readiness" and record.get("outcome") == "ready"
            ],
            message="the readiness record",
        )[0]
        self.assertEqual(event["provider"], self.provider)
        self.assertEqual(event["process"], "shell")

    def test_shutdown_request_stops_the_bridge_and_removes_its_files(self):
        """Control socket: `shutdown` makes the bridge exit 0 after it asks the
        speech service to shut down, stops its orchestrator session and removes
        its sockets, FIFO, pid file and mailbox files."""
        box = self.box
        self.turn_delivered("what is on the board")
        self.assertEqual(box.stop(), 0)
        self.assertTrue(box.speech_requests("shutdown"))
        stop = box.orchestrator.requests("/v1/orchestrator-session/stop")
        self.assertEqual(stop[-1]["body"], {"session_id": box.orchestrator.session_id, "reason": "bridge stopped"})
        for path in (
            box.control_sock,
            box.tts_fifo,
            box.remote_sock,
            box.runtime_file("voice_bridge.pid"),
            self.session.ready,
            self.session.meta,
            self.session.state_file,
            self.session.claimed,
        ):
            self.assertFalse(path.exists(), f"{path.name} was left behind")

    def test_reload_rereads_the_speech_configuration(self):
        """Control socket: `reload` sends `reload_config` to the speech service."""
        self.box.control("reload")
        self.box.wait_speech_request("reload_config")

    def test_ping_and_unknown_commands_leave_the_bridge_running(self):
        """Control socket: `ping` and an unknown datagram change nothing."""
        before = len(self.box.speech_requests("speak"))
        for command in ("ping", "PING", "not-a-command", "{\"type\": \"unknown\"}"):
            self.box.control(command)
        self.assertStays(lambda: self.box.process.poll() is None and len(self.box.speech_requests("speak")) == before)
        self.turn_delivered("is the bridge still listening")

    def test_session_playback_states_are_published_to_the_overlay(self):
        """Control socket: while it listens, the bridge publishes the speech
        service's `session_playback_states` as a `session_playback` state
        datagram and the queue depth as `speech_queue`."""
        published = wait_until(lambda: self.box.states("session_playback", source="bridge"), message="session_playback")
        self.assertEqual(published[-1]["text"], "{}")
        depth = wait_until(lambda: self.box.states("speech_queue", source="bridge"), message="speech_queue")
        self.assertTrue(depth[-1]["text"].isdigit())


class SuppressedGreetingContract:
    greeting = False

    def test_suppressed_greeting_also_skips_the_first_messenger_reply(self):
        """Process: `--suppress-startup-greeting` (the tutorial) speaks no
        greeting and does not hand the first user turn to the messenger; the
        second turn reaches it."""
        self.turn_delivered("this is the tutorial turn")
        self.assertStays(lambda: not self.box.messenger_prompts("user_turn"))
        self.assertFalse(self.box.spoken(text=STARTUP_GREETING))
        self.turn("this turn reaches the messenger")
        self.box.wait_messenger_prompt("user_turn", "this turn reaches the messenger")
        self.assertFalse(
            [prompt for prompt in self.box.messenger_prompts("user_turn") if "tutorial" in prompt["content"]]
        )


class WithoutOrchestratorContract:
    orchestrator = False

    def test_bridge_runs_and_delivers_commands_without_the_daemon(self):
        """Process: an unreachable daemon does not stop the bridge; commands
        are still delivered to the mailbox."""
        prompt, metadata = self.turn_delivered("summarise the release notes")
        self.assertTrue(prompt.startswith("summarise the release notes"))
        self.assertEqual(metadata["source_text"], "summarise the release notes")


class RecoverableCommandsContract:
    start_bridge = False

    def test_a_command_whose_delivery_failed_is_reported_at_startup(self):
        """Process: when `/v1/orchestrator-session/ensure` returns a
        recoverable command whose status is `delivery_failed`, the bridge
        reports it with a `working` state naming that outcome and asking the
        user to repeat the request."""
        self.box.orchestrator.recoverable_commands = [
            {"relay_command_seq": 8, "relay_command_id": "delivery-failed", "status": "delivery_failed"},
        ]
        self.box.start()
        working = wait_until(
            lambda: [state for state in self.box.states("working") if "Delivery failed" in (state.get("text") or "")],
            message="the delivery-failed report",
        )[0]
        self.assertIn("before a ticket action was confirmed", working["text"])
        self.assertIn("Repeat the request", working["text"])


class LeftoverPathsContract:
    start_bridge = False

    def test_leftover_files_at_the_fifo_paths_are_replaced_by_fifos(self):
        """Process: a regular file left at `VOICE_FIFO` or the TTS FIFO path is
        replaced by a FIFO."""
        self.box.voice_fifo.write_text("stale")
        self.box.tts_fifo.write_text("stale")
        self.box.start()
        self.assertTrue(is_fifo(self.box.voice_fifo))
        self.assertTrue(is_fifo(self.box.tts_fifo))
        self.turn_delivered("the fifo works")


class ClaudeProcess(ProcessContract, BridgeCase):
    provider = "claude"


class CodexProcess(ProcessContract, BridgeCase):
    provider = "codex"


class ClaudeSuppressedGreeting(SuppressedGreetingContract, BridgeCase):
    provider = "claude"


class CodexSuppressedGreeting(SuppressedGreetingContract, BridgeCase):
    provider = "codex"


class ClaudeWithoutOrchestrator(WithoutOrchestratorContract, BridgeCase):
    provider = "claude"


class CodexWithoutOrchestrator(WithoutOrchestratorContract, BridgeCase):
    provider = "codex"


class ClaudeRecoverableCommands(RecoverableCommandsContract, BridgeCase):
    provider = "claude"


class CodexRecoverableCommands(RecoverableCommandsContract, BridgeCase):
    provider = "codex"


class ClaudeLeftoverPaths(LeftoverPathsContract, BridgeCase):
    provider = "claude"


class CodexLeftoverPaths(LeftoverPathsContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
