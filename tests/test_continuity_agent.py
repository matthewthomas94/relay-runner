from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from continuity_agent import (  # noqa: E402
    ACTOR_ROLE,
    ClaudeContinuityBackend,
    CodexContinuityBackend,
    ContinuityAgentConfig,
    ContinuityAgentLane,
    RecoveryBrokerOutcome,
    RecoveryHealthEvidence,
    continuity_agent_environment,
    create_provider_session_factory,
    sanitize_incident_bundle,
)
from messenger import MessengerConfig  # noqa: E402
from orchestrator import Daemon  # noqa: E402


def incident(
    incident_id: str = "inc-123456789abc",
    *,
    fingerprint: str = "fp-123456789012345678901234",
) -> dict:
    return {
        "schema_version": 1,
        "incident_id": incident_id,
        "fingerprint": fingerprint,
        "classification": "stalled",
        "session_id": "session-123456789012345678901234",
        "command_id": "command-123456789012345678901234",
        "component": "bridge",
        "provider": "none",
        "recovery_generation": 3,
        "phase": "delivery",
        "health": "unavailable",
        "timing": {
            "first_observed_at": 10.0,
            "last_observed_at": 30.0,
            "grace_deadline": 25.0,
            "post_grace_samples": 2,
            "failed_native_recovery": False,
            "cooldown_until": 930.0,
        },
        "recovery_objective": {
            "unavailable_capability": "Relay Runner cannot deliver captured input.",
            "restored_when": ["bridge_process_alive", "command_delivered"],
        },
    }


class FakeSession:
    def __init__(self, decisions: list[str], *, provider: str = "codex"):
        self.provider = provider
        self.decisions = list(decisions)
        self.prompts = []
        self.timeouts = []
        self.shutdown_called = False

    def decide(self, prompt: str, timeout: float) -> str:
        self.prompts.append(prompt)
        self.timeouts.append(timeout)
        return self.decisions.pop(0)

    def interrupt(self) -> None:
        return None

    def shutdown(self) -> None:
        self.shutdown_called = True


class IterativeBroker:
    def __init__(self):
        self.calls = []

    def capabilities(self, _incident):
        return ("restart_bridge", "check_health")

    def perform(self, capability, **context):
        self.calls.append((capability, context))
        if capability == "restart_bridge":
            return RecoveryBrokerOutcome(
                capability,
                "applied",
                "bridge_restart_started",
                RecoveryHealthEvidence(False, 0, ("bridge_process_alive",)),
            )
        return RecoveryBrokerOutcome(
            capability,
            "noop",
            "processing_restored",
            RecoveryHealthEvidence(
                True,
                60,
                ("bridge_process_alive", "command_delivered"),
            ),
        )


class ContinuityAgentTests(unittest.TestCase):
    def test_sanitized_bundle_excludes_private_and_unknown_fields(self):
        payload = incident()
        payload.update({
            "transcript": "private transcript",
            "prompt": "private prompt",
            "repository": "/private/repo",
            "credential": "private token",
            "provider_output": "private output",
            "screenshot": "private image",
        })
        payload["recovery_objective"] = {
            "unavailable_capability": "private objective transcript",
            "restored_when": ["private evidence transcript"],
        }

        cleaned = sanitize_incident_bundle(payload)
        serialized = json.dumps(cleaned, sort_keys=True)

        for private in (
            "private transcript",
            "private prompt",
            "/private/repo",
            "private token",
            "private output",
            "private image",
            "private objective transcript",
            "private evidence transcript",
        ):
            self.assertNotIn(private, serialized)
        self.assertEqual(cleaned["incident_id"], payload["incident_id"])

    def test_child_environment_has_identity_but_no_foreground_or_secret_authority(self):
        environment = continuity_agent_environment(
            "continuity-process",
            "inc-safe",
            4,
            parent={
                "HOME": "/Users/test",
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin",
                "OPENAI_API_KEY": "secret",
                "CUSTOM_ACCESS_TOKEN": "secret",
                "GH_TOKEN": "secret",
                "GITHUB_TOKEN": "secret",
                "AWS_ACCESS_KEY_ID": "secret",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "AWS_SESSION_TOKEN": "secret",
                "UNRECOGNIZED_CREDENTIAL_NAME": "secret",
                "BENIGN_PARENT_CONTEXT": "not needed by the provider",
                "RELAY_REPLY_HELPER": "/private/reply",
                "VOICE_COMMAND_CLAIM_FILE": "/private/claim",
                "VOICE_FIFO": "/private/voice",
                "TTS_CONTROL_SOCK": "/private/tts",
            },
        )

        self.assertEqual(environment["RELAY_ACTOR_ROLE"], ACTOR_ROLE)
        self.assertEqual(environment["RELAY_CONTINUITY_PROCESS_ID"], "continuity-process")
        self.assertEqual(environment["RELAY_CONTINUITY_INCIDENT_ID"], "inc-safe")
        self.assertEqual(environment["RELAY_RECOVERY_GENERATION"], "4")
        self.assertEqual(environment["HOME"], "/Users/test")
        self.assertEqual(environment["LANG"], "en_US.UTF-8")
        self.assertEqual(environment["PATH"], "/usr/bin")
        for excluded in (
            "OPENAI_API_KEY",
            "CUSTOM_ACCESS_TOKEN",
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
            "UNRECOGNIZED_CREDENTIAL_NAME",
            "BENIGN_PARENT_CONTEXT",
            "RELAY_REPLY_HELPER",
            "VOICE_COMMAND_CLAIM_FILE",
            "VOICE_FIFO",
            "TTS_CONTROL_SOCK",
        ):
            self.assertNotIn(excluded, environment)

    def test_codex_and_claude_have_equivalent_authority_boundaries(self):
        codex = CodexContinuityBackend(
            MessengerConfig(True, "codex", "/opt/codex", "gpt-test", "high", "/tmp"),
            process_identity="codex-process",
            incident_id="inc-codex",
            recovery_generation=1,
        )
        claude = ClaudeContinuityBackend(
            MessengerConfig(True, "claude", "/opt/claude", "sonnet", "high", "/tmp"),
            process_identity="claude-process",
            incident_id="inc-claude",
            recovery_generation=1,
        )

        self.assertEqual(codex.actor_role, ACTOR_ROLE)
        self.assertEqual(claude.actor_role, ACTOR_ROLE)
        codex_command = codex.spawn_command()
        codex_params = codex.thread_start_params()
        self.assertIn("features.shell_tool=false", codex_command)
        self.assertIn("features.unified_exec=false", codex_command)
        self.assertIn("tools.web_search=false", codex_command)
        self.assertIn("mcp_servers={}", codex_command)
        self.assertEqual(codex_params["dynamicTools"], [])
        self.assertEqual(codex_params["runtimeWorkspaceRoots"], [])
        claude_command = claude.spawn_command()
        self.assertIn("--tools", claude_command)
        self.assertEqual(claude_command[claude_command.index("--tools") + 1], "")
        for option in (
            "--safe-mode",
            "--no-chrome",
            "--no-session-persistence",
            "--strict-mcp-config",
        ):
            self.assertIn(option, claude_command)
        self.assertNotIn("WebSearch", claude_command)
        self.assertNotIn("Bash", claude_command)

    def test_lane_iterates_through_broker_until_stable_health(self):
        session = FakeSession([
            '{"kind":"broker_call","capability":"restart_bridge"}',
            '{"kind":"broker_call","capability":"check_health"}',
        ])
        identities = []

        def factory(process_identity, incident_id, generation):
            identities.append((process_identity, incident_id, generation))
            return session

        broker = IterativeBroker()
        audit = []
        lane = ContinuityAgentLane(
            factory,
            broker,
            on_audit=audit.append,
            config=ContinuityAgentConfig(
                max_attempts=3,
                wall_clock_seconds=10,
                stable_health_seconds=60,
                cooldown_seconds=0,
            ),
        )

        self.assertEqual(lane.submit(incident()), "launched")
        self.assertTrue(lane.wait_until_idle(2))

        self.assertEqual([call[0] for call in broker.calls], ["restart_bridge", "check_health"])
        self.assertEqual(identities[0][1:], ("inc-123456789abc", 3))
        self.assertTrue(identities[0][0].startswith("continuity-"))
        self.assertEqual([record["phase"] for record in audit], [
            "launched", "broker_outcome", "broker_outcome", "completed",
        ])
        self.assertEqual(audit[-1]["final_result"], "restored")
        self.assertTrue(session.shutdown_called)
        for prompt in session.prompts:
            self.assertNotIn("private transcript", prompt)
            self.assertNotIn("/private/repository", prompt)

    def test_single_flight_deduplication_and_cooldown(self):
        started = threading.Event()
        release = threading.Event()

        class BlockingSession(FakeSession):
            def decide(self, prompt, timeout):
                started.set()
                self.assert_wait = release.wait(2)
                return '{"kind":"finish","result":"escalate"}'

        sessions = []

        def factory(*_args):
            session = BlockingSession([])
            sessions.append(session)
            return session

        lane = ContinuityAgentLane(
            factory,
            IterativeBroker(),
            on_audit=lambda _record: None,
            config=ContinuityAgentConfig(cooldown_seconds=60),
        )
        first = incident()
        other = incident("inc-abcdef123456", fingerprint="fp-abcdef123456789012345678")

        self.assertEqual(lane.submit(first), "launched")
        self.assertTrue(started.wait(1))
        self.assertEqual(lane.submit(first), "duplicate")
        self.assertEqual(lane.submit(other), "single_flight")
        release.set()
        self.assertTrue(lane.wait_until_idle(2))
        self.assertEqual(lane.submit(first), "cooldown")
        self.assertEqual(len(sessions), 1)

    def test_attempt_exhaustion_opens_circuit_and_never_accepts_agent_health_claim(self):
        session = FakeSession([
            '{"kind":"broker_call","capability":"restart_bridge"}',
            '{"kind":"finish","result":"escalate"}',
        ])
        audit = []
        lane = ContinuityAgentLane(
            lambda *_args: session,
            IterativeBroker(),
            on_audit=audit.append,
            config=ContinuityAgentConfig(max_attempts=2, cooldown_seconds=0),
        )

        self.assertEqual(lane.submit(incident()), "launched")
        self.assertTrue(lane.wait_until_idle(2))

        self.assertEqual(audit[-1]["final_result"], "circuit_open")
        broker_records = [record for record in audit if record["phase"] == "broker_outcome"]
        self.assertEqual(len(broker_records), 1)

    def test_blocking_broker_cannot_overrun_wall_clock_budget(self):
        broker_started = threading.Event()
        release_broker = threading.Event()

        class BlockingBroker(IterativeBroker):
            def perform(self, capability, **context):
                self.calls.append((capability, context))
                broker_started.set()
                release_broker.wait()
                return RecoveryBrokerOutcome(capability, "noop", "broker_released")

        session = FakeSession([
            '{"kind":"broker_call","capability":"restart_bridge"}',
        ])
        audit = []
        lane = ContinuityAgentLane(
            lambda *_args: session,
            BlockingBroker(),
            on_audit=audit.append,
            config=ContinuityAgentConfig(
                max_attempts=1,
                wall_clock_seconds=0.05,
                cooldown_seconds=0,
            ),
        )

        try:
            started_at = time.monotonic()
            self.assertEqual(lane.submit(incident()), "launched")
            self.assertTrue(broker_started.wait(1))
            self.assertTrue(lane.wait_until_idle(1))
            self.assertLess(time.monotonic() - started_at, 0.5)
            self.assertEqual(audit[-2]["broker_outcome"]["status"], "circuit_open")
            self.assertEqual(
                audit[-2]["broker_outcome"]["outcome_code"],
                "broker_call_timed_out",
            )
            self.assertEqual(audit[-1]["final_result"], "circuit_open")
            self.assertTrue(session.shutdown_called)
        finally:
            release_broker.set()

    def test_configured_provider_never_silently_falls_back(self):
        app_config = {
            "general": {
                "provider": "claude",
                "command": "claude",
                "model": "sonnet",
                "orchestrator_effort": "high",
            }
        }
        with patch("continuity_agent.resolve_messenger_command", return_value=None):
            factory = create_provider_session_factory(app_config, cwd="/tmp")

        session = factory("process", "incident", 1)
        self.assertEqual(session.provider, "claude")
        with self.assertRaisesRegex(RuntimeError, "configured_provider_unavailable"):
            session.decide("{}", 1)

    def test_daemon_persists_incident_then_submits_to_lane(self):
        with tempfile.TemporaryDirectory() as tmp:
            submitted = []
            daemon = Daemon.__new__(Daemon)
            daemon.continuity_incident_path = Path(tmp) / "incidents.jsonl"
            daemon.continuity_agents = type(
                "Lane",
                (),
                {"submit": lambda _self, item: submitted.append(item)},
            )()

            daemon._emit_continuity_incident(incident())

            persisted = json.loads(daemon.continuity_incident_path.read_text())
            self.assertEqual(persisted["incident_id"], "inc-123456789abc")
            self.assertEqual(submitted[0]["incident_id"], "inc-123456789abc")


if __name__ == "__main__":
    unittest.main()
