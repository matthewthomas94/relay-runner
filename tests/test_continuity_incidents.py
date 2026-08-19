from __future__ import annotations

import json
import os
import sys
import unittest
from typing import Optional


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from continuity_incidents import (  # noqa: E402
    ContinuityIncidentDetector,
    DetectorConfig,
    Observation,
    opaque_identifier,
    provider_observation,
)


SESSION = opaque_identifier("session", "native-session-secret")
COMMAND = opaque_identifier("command", "native-command-secret")


def observation(
    component: str,
    at: float,
    *,
    health: str = "unavailable",
    phase: str = "component_liveness",
    session_id: str = SESSION,
    command_id: Optional[str] = COMMAND,
    provider: str = "none",
    failed_recovery: bool = False,
) -> Observation:
    return Observation(
        session_id=session_id,
        command_id=command_id,
        component=component,
        provider=provider,
        recovery_generation=2,
        phase=phase,
        health=health,
        observed_at=at,
        native_recovery_failed=failed_recovery,
    )


def classify_after_grace(
    detector: ContinuityIncidentDetector,
    component: str,
    start: float,
    **kwargs,
):
    detector.observe(observation(component, start, **kwargs))
    grace = detector.config.grace_periods[component]
    detector.observe(observation(component, start + grace, **kwargs))
    return detector.observe(observation(component, start + grace + 1, **kwargs))


class ContinuityIncidentDetectorTests(unittest.TestCase):
    def test_transient_and_explicit_lifecycle_states_do_not_emit(self):
        emitted = []
        detector = ContinuityIncidentDetector(emit=emitted.append)

        self.assertEqual(detector.observe(observation("bridge", 100)).state, "transient")
        self.assertEqual(
            detector.observe(observation("bridge", 110, health="healthy")).state,
            "healthy",
        )
        for reason in ("explicit_stop", "update", "reset"):
            result = detector.observe(observation("bridge", 200), suppression=reason)
            self.assertEqual(result.state, "suppressed")
            self.assertEqual(result.suppression_reason, reason)
        self.assertEqual(emitted, [])

    def test_dropped_transcription_before_command_creation_is_detected(self):
        detector = ContinuityIncidentDetector()

        result = classify_after_grace(
            detector,
            "transcription",
            100,
            phase="transcription",
            command_id=None,
        )

        self.assertEqual(result.state, "stalled")
        self.assertIsNone(result.envelope.command_id)
        self.assertEqual(result.envelope.component, "transcription")
        self.assertEqual(result.envelope.post_grace_samples, 2)
        self.assertIn(
            "turn captured speech into a command",
            result.envelope.objective.unavailable_capability,
        )
        self.assertIn("command_created", result.envelope.objective.restored_when)

    def test_captured_but_undelivered_input_uses_bridge_evidence(self):
        detector = ContinuityIncidentDetector()

        result = classify_after_grace(
            detector,
            "bridge",
            100,
            phase="delivery",
        )

        self.assertEqual(result.state, "stalled")
        payload = result.envelope.as_dict()
        self.assertEqual(payload["command_id"], COMMAND)
        self.assertEqual(payload["phase"], "delivery")
        self.assertEqual(payload["timing"]["post_grace_samples"], 2)
        self.assertIn("command_delivered", payload["recovery_objective"]["restored_when"])

    def test_failed_native_recovery_immediately_classifies_component_loss(self):
        detector = ContinuityIncidentDetector()

        result = detector.observe(observation(
            "messenger",
            100,
            health="recovery_failed",
            failed_recovery=True,
        ))

        self.assertEqual(result.state, "stalled")
        self.assertTrue(result.envelope.failed_native_recovery)
        self.assertEqual(result.envelope.post_grace_samples, 0)

    def test_concurrent_commands_do_not_share_liveness_samples(self):
        detector = ContinuityIncidentDetector()
        other_command = opaque_identifier("command", "other-native-command")
        detector.observe(observation("command", 100, phase="command_processing"))
        detector.observe(observation(
            "command",
            130,
            phase="command_processing",
            command_id=other_command,
        ))

        result = detector.observe(observation("command", 131, phase="command_processing"))

        self.assertEqual(result.state, "transient")
        self.assertIsNone(result.envelope)

    def test_codex_and_claude_adapters_classify_stalled_accepted_work_equally(self):
        results = []
        signals = {"codex": "app_server_timeout", "claude": "timeout"}
        for provider, signal in signals.items():
            detector = ContinuityIncidentDetector()
            detector.observe(provider_observation(
                provider,
                signal,
                session_id=SESSION,
                command_id=COMMAND,
                recovery_generation=2,
                observed_at=100,
            ))
            detector.observe(provider_observation(
                provider,
                signal,
                session_id=SESSION,
                command_id=COMMAND,
                recovery_generation=2,
                observed_at=130,
            ))
            results.append(detector.observe(provider_observation(
                provider,
                signal,
                session_id=SESSION,
                command_id=COMMAND,
                recovery_generation=2,
                observed_at=131,
            )))

        self.assertEqual([result.state for result in results], ["stalled", "stalled"])
        shapes = [set(result.envelope.as_dict()) for result in results]
        self.assertEqual(shapes[0], shapes[1])
        self.assertEqual(
            [result.envelope.objective for result in results],
            [results[0].envelope.objective, results[0].envelope.objective],
        )

    def test_completed_command_suppresses_later_weak_signals(self):
        detector = ContinuityIncidentDetector()
        completed = provider_observation(
            "codex",
            "turn_completed",
            session_id=SESSION,
            command_id=COMMAND,
            recovery_generation=2,
            observed_at=100,
        )
        self.assertEqual(detector.observe(completed).state, "completed")

        result = detector.observe(observation("command", 200, phase="command_processing"))

        self.assertEqual(result.state, "suppressed")
        self.assertEqual(result.suppression_reason, "completed_work")

    def test_cross_session_recurrence_is_stable_and_cooldown_prevents_relaunch(self):
        emitted = []
        detector = ContinuityIncidentDetector(
            DetectorConfig(cooldown=900),
            emit=emitted.append,
        )
        first = classify_after_grace(detector, "daemon", 100)
        detector.observe(observation("daemon", 200, health="healthy"))
        other_session = opaque_identifier("session", "other-native-session")
        second = classify_after_grace(
            detector,
            "daemon",
            300,
            session_id=other_session,
        )

        self.assertEqual(first.state, "stalled")
        self.assertEqual(second.state, "recurring")
        self.assertEqual(first.fingerprint, second.fingerprint)
        self.assertIsNone(second.envelope)
        self.assertEqual(second.suppression_reason, "cooldown")
        self.assertEqual(len(emitted), 1)

        detector.observe(observation("daemon", 400, health="healthy", session_id=other_session))
        third = classify_after_grace(
            detector,
            "daemon",
            1101,
            session_id=other_session,
        )
        self.assertEqual(third.state, "recurring")
        self.assertIsNotNone(third.envelope)
        self.assertEqual(len(emitted), 2)

    def test_incident_envelope_is_fixed_and_excludes_sensitive_native_data(self):
        detector = ContinuityIncidentDetector()
        result = detector.observe(observation(
            "command",
            100,
            phase="command_processing",
            health="recovery_failed",
            failed_recovery=True,
        ))

        serialized = json.dumps(result.envelope.as_dict(), sort_keys=True)
        for forbidden in (
            "native-session-secret",
            "native-command-secret",
            "transcript",
            "prompt",
            "repository",
            "credential",
            "screenshot",
            "provider_output",
        ):
            self.assertNotIn(forbidden, serialized)
        with self.assertRaises(ValueError):
            observation("command", 200, session_id="native-session-secret")
        with self.assertRaises(ValueError):
            provider_observation(
                "codex",
                "raw_error",
                session_id=SESSION,
                command_id=COMMAND,
                recovery_generation=2,
                observed_at=200,
            )


if __name__ == "__main__":
    unittest.main()
