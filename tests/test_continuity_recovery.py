from __future__ import annotations

import os
import sys
import threading
import unittest


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from continuity_agent import RecoveryHealthEvidence  # noqa: E402
from continuity_recovery import (  # noqa: E402
    CAPABILITY_POLICIES,
    DISALLOWED_RECOVERY_OPERATIONS,
    RESTORE_PROCESSING_OBJECTIVE,
    ComponentOwnedRecoveryBroker,
    ProductionRecoveryCapability,
    RecoveryActionResult,
    RecoveryActionValidation,
    production_recovery_owners,
)


OBJECTIVE_EVIDENCE = {
    "speech_capture": ("capture_progress_observed", "transcription_started"),
    "transcription": ("transcription_completed", "command_created"),
    "bridge": ("bridge_process_alive", "bridge_heartbeat_fresh", "command_delivered"),
    "messenger": ("messenger_process_alive", "messenger_progress_observed"),
    "foreground_provider": ("provider_process_alive", "provider_processing_ready"),
    "orchestrator": ("orchestrator_heartbeat_fresh", "command_progress_observed"),
    "daemon": ("daemon_process_alive", "daemon_heartbeat_fresh"),
    "session": ("session_owner_alive", "session_heartbeat_fresh"),
    "command": ("command_progress_observed", "command_completed"),
}

COMPONENT_PHASE = {
    "speech_capture": "capture",
    "transcription": "transcription",
    "bridge": "delivery",
    "messenger": "component_liveness",
    "foreground_provider": "provider_turn",
    "orchestrator": "component_liveness",
    "daemon": "component_liveness",
    "session": "session_liveness",
    "command": "command_processing",
}


def incident(component="bridge", *, provider="none", generation=3):
    return {
        "schema_version": 1,
        "incident_id": "inc-123456789abc",
        "fingerprint": "fp-123456789012345678901234",
        "classification": "stalled",
        "session_id": "session-123456789012345678901234",
        "command_id": "command-123456789012345678901234",
        "component": component,
        "provider": provider,
        "recovery_generation": generation,
        "phase": COMPONENT_PHASE[component],
        "health": "unavailable",
        "timing": {"last_observed_at": 30.0},
        "recovery_objective": {
            "unavailable_capability": "sanitized objective",
            "restored_when": list(OBJECTIVE_EVIDENCE[component]),
        },
    }


class RecordingOwner:
    def __init__(self, owner):
        self.owner = owner
        self.inspections = []
        self.executions = []
        self.cleanups = []
        self.exact_target_owned = True
        self.liveness = "unhealthy"
        self.incident_active = True
        self.generation_matches = True
        self.command_phase = "none"
        self.command_phase_matches = True
        self.idempotency_state = "new"
        self.compensation_available = True
        self.cooldown_remaining = 0.0
        self.postcondition_override = None
        self.validation_health = RecoveryHealthEvidence()
        self.result = None
        self.cleanup_result = True

    def inspect(self, request):
        self.inspections.append(request)
        liveness = self.liveness
        policy = CAPABILITY_POLICIES[request.capability]
        if liveness == "unhealthy" and policy.required_liveness == {"confirmed_dead"}:
            liveness = "confirmed_dead"
        return RecoveryActionValidation(
            validation_token="validation_token",
            exact_target_owned=self.exact_target_owned,
            liveness=liveness,
            incident_active=self.incident_active,
            generation_matches=self.generation_matches,
            command_phase=self.command_phase,
            command_phase_matches=self.command_phase_matches,
            idempotency_state=self.idempotency_state,
            compensation_available=self.compensation_available,
            cooldown_remaining=self.cooldown_remaining,
            expected_postcondition=(
                self.postcondition_override or request.expected_postcondition
            ),
            health=self.validation_health,
        )

    def execute(self, request, validation, cancel_event):
        self.executions.append((request, validation, cancel_event))
        if self.result is not None:
            return self.result
        evidence = OBJECTIVE_EVIDENCE[request.component]
        return RecoveryActionResult(
            "applied",
            "component_action_applied",
            RecoveryHealthEvidence(True, 60, evidence),
        )

    def cleanup(self, request, validation):
        self.cleanups.append((request, validation))
        return self.cleanup_result


def broker_and_owners(now=100.0):
    owners = {name: RecordingOwner(name) for name in ("app", "bridge", "daemon")}
    return ComponentOwnedRecoveryBroker(owners, monotonic=lambda: now), owners


def perform(broker, capability, payload, *, generation=3, attempt=1):
    return broker.perform(
        capability,
        incident=payload,
        process_identity="continuity-1234567890abcdef1234567890abcdef",
        recovery_generation=generation,
        attempt=attempt,
        deadline=200.0,
        cancel_event=threading.Event(),
    )


def production_capabilities(*, owned=True, generation_matches=True):
    def inspect(request):
        policy = CAPABILITY_POLICIES[request.capability]
        liveness = (
            "confirmed_dead"
            if policy.required_liveness == {"confirmed_dead"}
            else "unhealthy"
        )
        command_phase = (
            "captured"
            if request.capability == "reinitialize_transcription_delivery"
            else "none"
        )
        return RecoveryActionValidation(
            validation_token="live_component_probe",
            exact_target_owned=owned,
            liveness=liveness,
            incident_active=True,
            generation_matches=generation_matches,
            command_phase=command_phase,
            command_phase_matches=True,
            idempotency_state="new",
            compensation_available=False,
            cooldown_remaining=0,
            expected_postcondition=request.expected_postcondition,
        )

    def execute(request, _validation, _cancel_event):
        return RecoveryActionResult(
            "applied",
            "component_action_applied",
            RecoveryHealthEvidence(True, 60, OBJECTIVE_EVIDENCE[request.component]),
        )

    return {
        capability: ProductionRecoveryCapability(inspect, execute)
        for capability in CAPABILITY_POLICIES
        if capability != "check_processing_health"
    }


class ComponentOwnedRecoveryBrokerTests(unittest.TestCase):
    def test_restore_objective_exposes_every_required_component_capability(self):
        broker, _owners = broker_and_owners()
        exposed = set()
        for component in COMPONENT_PHASE:
            exposed.update(broker.capabilities(incident(component)))

        self.assertEqual(broker.objective, RESTORE_PROCESSING_OBJECTIVE)
        self.assertTrue({
            "reinitialize_speech_capture",
            "reinitialize_transcription_delivery",
            "restart_bridge",
            "restart_messenger",
            "restart_daemon",
            "reconnect_ipc",
            "restore_session_registration",
            "release_dead_ownership",
            "launch_foreground_provider",
            "check_processing_health",
        }.issubset(exposed))

    def test_allowed_actions_are_executed_only_by_the_registered_component_owner(self):
        cases = {
            "reinitialize_speech_capture": "speech_capture",
            "reinitialize_transcription_delivery": "transcription",
            "restart_bridge": "bridge",
            "restart_messenger": "messenger",
            "restart_daemon": "daemon",
            "reconnect_ipc": "bridge",
            "restore_session_registration": "session",
            "release_dead_ownership": "foreground_provider",
            "launch_foreground_provider": "foreground_provider",
            "check_processing_health": "command",
        }
        for capability, component in cases.items():
            with self.subTest(capability=capability):
                broker, owners = broker_and_owners()
                payload = incident(
                    component,
                    provider="codex" if component == "foreground_provider" else "none",
                )
                outcome = perform(broker, capability, payload)

                self.assertEqual(outcome.status, "applied")
                expected_owner = CAPABILITY_POLICIES[capability].owner
                if expected_owner == "dynamic":
                    expected_owner = {
                        "bridge": "app",
                        "command": "daemon",
                        "foreground_provider": "app",
                    }[component]
                self.assertEqual(len(owners[expected_owner].executions), 1)
                self.assertEqual(
                    sum(len(owner.executions) for owner in owners.values()),
                    1,
                )

    def test_disallowed_runtime_and_durable_operations_are_unreachable(self):
        broker, owners = broker_and_owners()
        for capability in DISALLOWED_RECOVERY_OPERATIONS:
            with self.subTest(capability=capability):
                outcome = perform(broker, capability, incident())
                self.assertEqual(outcome.status, "rejected")
                self.assertEqual(outcome.outcome_code, "capability_not_allowed")
        self.assertFalse(any(owner.inspections for owner in owners.values()))
        self.assertFalse(any(owner.executions for owner in owners.values()))

    def test_exact_ownership_generation_phase_and_postcondition_are_required(self):
        checks = (
            ("exact_target_owned", False, "authorization_required", "target_ownership_not_proven"),
            ("generation_matches", False, "rejected", "stale_recovery_generation"),
            ("command_phase_matches", False, "authorization_required", "command_phase_ambiguous"),
            ("postcondition_override", "wrong_postcondition", "rejected", "postcondition_mismatch"),
        )
        for attribute, value, status, code in checks:
            with self.subTest(attribute=attribute):
                broker, owners = broker_and_owners()
                setattr(owners["app"], attribute, value)
                outcome = perform(broker, "restart_bridge", incident())
                self.assertEqual((outcome.status, outcome.outcome_code), (status, code))
                self.assertEqual(owners["app"].executions, [])

        broker, owners = broker_and_owners()
        outcome = perform(broker, "restart_bridge", incident(), generation=4)
        self.assertEqual(outcome.outcome_code, "recovery_generation_mismatch")
        self.assertEqual(owners["app"].inspections, [])

    def test_slow_live_provider_is_never_released_or_replaced(self):
        for capability in ("release_dead_ownership", "launch_foreground_provider"):
            with self.subTest(capability=capability):
                broker, owners = broker_and_owners()
                owners["app"].liveness = "slow"
                outcome = perform(
                    broker,
                    capability,
                    incident("foreground_provider", provider="claude"),
                )
                self.assertEqual(outcome.status, "rejected")
                self.assertEqual(outcome.outcome_code, "live_provider_must_not_be_killed")
                self.assertEqual(owners["app"].executions, [])

    def test_classified_stall_authorizes_only_foreground_provider_release_or_relaunch(self):
        for capability in ("release_dead_ownership", "launch_foreground_provider"):
            with self.subTest(capability=capability):
                broker, owners = broker_and_owners()
                owners["app"].liveness = "stalled"
                outcome = perform(
                    broker,
                    capability,
                    incident("foreground_provider", provider="codex"),
                )
                self.assertEqual(outcome.status, "applied")
                self.assertEqual(len(owners["app"].executions), 1)

        broker, owners = broker_and_owners()
        owners["app"].liveness = "stalled"
        outcome = perform(
            broker,
            "launch_foreground_provider",
            incident("session", provider="codex"),
        )
        self.assertEqual(
            (outcome.status, outcome.outcome_code),
            ("rejected", "target_health_not_proven"),
        )
        self.assertEqual(owners["app"].executions, [])

    def test_idempotency_attempt_caps_and_component_cooldown_fail_closed(self):
        broker, owners = broker_and_owners()
        first = perform(broker, "restart_bridge", incident(), attempt=1)
        second = perform(broker, "restart_bridge", incident(), attempt=2)
        third = perform(broker, "restart_bridge", incident(), attempt=3)

        self.assertEqual(first.status, "applied")
        self.assertEqual((second.status, second.outcome_code), ("noop", "action_already_applied"))
        self.assertEqual(third.outcome_code, "capability_attempt_cap_reached")
        self.assertEqual(len(owners["app"].executions), 1)

        broker, owners = broker_and_owners()
        owners["app"].cooldown_remaining = 2
        outcome = perform(broker, "restart_bridge", incident())
        self.assertEqual((outcome.status, outcome.outcome_code), (
            "circuit_open", "component_cooldown_active",
        ))
        self.assertEqual(owners["app"].executions, [])

    def test_failed_or_worsening_ephemeral_action_is_cleaned_up(self):
        broker, owners = broker_and_owners()
        owners["app"].result = RecoveryActionResult(
            "failed",
            "bridge_restart_failed",
            ephemeral_state_created=True,
            health_worsened=True,
        )

        outcome = perform(broker, "restart_bridge", incident())

        self.assertEqual((outcome.status, outcome.outcome_code), (
            "failed", "ephemeral_cleanup_applied",
        ))
        self.assertEqual(len(owners["app"].cleanups), 1)

    def test_ephemeral_action_without_compensation_opens_the_circuit(self):
        broker, owners = broker_and_owners()
        owners["app"].compensation_available = False
        owners["app"].result = RecoveryActionResult(
            "failed",
            "bridge_restart_failed",
            ephemeral_state_created=True,
        )

        outcome = perform(broker, "restart_bridge", incident())

        self.assertEqual((outcome.status, outcome.outcome_code), (
            "circuit_open", "ephemeral_cleanup_unavailable",
        ))
        self.assertEqual(owners["app"].cleanups, [])

    def test_ambiguous_or_already_claimed_transcription_is_not_replayed(self):
        for command_phase in ("ambiguous", "claimed", "in_flight", "completed"):
            with self.subTest(command_phase=command_phase):
                broker, owners = broker_and_owners()
                owners["app"].command_phase = command_phase
                outcome = perform(
                    broker,
                    "reinitialize_transcription_delivery",
                    incident("transcription"),
                )
                self.assertEqual((outcome.status, outcome.outcome_code), (
                    "authorization_required", "command_replay_not_recoverable",
                ))
                self.assertEqual(owners["app"].executions, [])

    def test_owner_health_cannot_claim_restoration_without_full_objective_evidence(self):
        broker, owners = broker_and_owners()
        owners["app"].result = RecoveryActionResult(
            "applied",
            "bridge_restart_started",
            RecoveryHealthEvidence(True, 60, ("bridge_process_alive",)),
        )

        outcome = perform(broker, "restart_bridge", incident())

        self.assertFalse(outcome.health.objective_restored)
        self.assertEqual(outcome.health.stable_for_seconds, 60)

    def test_noop_and_rejection_health_require_full_objective_evidence(self):
        for status in ("noop", "rejected"):
            with self.subTest(status=status):
                broker, owners = broker_and_owners()
                owners["app"].validation_health = RecoveryHealthEvidence(
                    True,
                    60,
                    ("bridge_process_alive",),
                )
                if status == "noop":
                    owners["app"].idempotency_state = "applied"
                else:
                    owners["app"].exact_target_owned = False

                outcome = perform(broker, "restart_bridge", incident())

                expected_status = (
                    status if status == "noop" else "authorization_required"
                )
                self.assertEqual(outcome.status, expected_status)
                self.assertFalse(outcome.health.objective_restored)
                self.assertEqual(outcome.health.evidence_codes, ("bridge_process_alive",))

    def test_production_registry_exposes_fixed_actions_for_every_component(self):
        observed = []

        def probe(request):
            observed.append((request.component, request.recovery_generation))
            return RecoveryHealthEvidence()

        owners = production_recovery_owners(
            probe,
            capabilities=production_capabilities(),
        )
        broker = ComponentOwnedRecoveryBroker(owners, monotonic=lambda: 100.0)

        self.assertEqual(set(owners), {"app", "bridge", "daemon"})
        exposed = set()
        for component in COMPONENT_PHASE:
            with self.subTest(component=component):
                exposed.update(broker.capabilities(incident(component)))
                outcome = perform(broker, "check_processing_health", incident(component))
                self.assertEqual(
                    (outcome.status, outcome.outcome_code),
                    ("noop", "processing_health_checked"),
                )
        self.assertTrue(set(CAPABILITY_POLICIES).issubset(exposed))
        self.assertEqual(len(observed), len(COMPONENT_PHASE) * 2)

    def test_production_registry_cannot_silently_fall_back_to_health_only(self):
        with self.assertRaisesRegex(ValueError, "every fixed capability"):
            production_recovery_owners(
                lambda _request: RecoveryHealthEvidence(),
                capabilities={},
            )

    def test_production_adapter_rejects_stale_owner_before_fixed_action(self):
        executed = []
        capabilities = production_capabilities(owned=False)
        original = capabilities["restore_session_registration"]
        capabilities["restore_session_registration"] = ProductionRecoveryCapability(
            original.inspect,
            lambda request, validation, cancel_event: (
                executed.append((request, validation, cancel_event))
                or original.execute(request, validation, cancel_event)
            ),
        )
        owners = production_recovery_owners(
            lambda _request: RecoveryHealthEvidence(),
            capabilities=capabilities,
        )
        broker = ComponentOwnedRecoveryBroker(owners, monotonic=lambda: 100.0)

        self.assertIn(
            "restore_session_registration",
            broker.capabilities(incident("session")),
        )
        outcome = perform(
            broker,
            "restore_session_registration",
            incident("session"),
        )

        self.assertEqual(
            (outcome.status, outcome.outcome_code),
            ("authorization_required", "target_ownership_not_proven"),
        )
        self.assertEqual(executed, [])

    def test_production_adapter_rejects_stale_generation_before_fixed_action(self):
        owners = production_recovery_owners(
            lambda _request: RecoveryHealthEvidence(),
            capabilities=production_capabilities(generation_matches=False),
        )
        broker = ComponentOwnedRecoveryBroker(owners, monotonic=lambda: 100.0)

        outcome = perform(broker, "restart_bridge", incident("bridge"))

        self.assertEqual(
            (outcome.status, outcome.outcome_code),
            ("rejected", "stale_recovery_generation"),
        )

    def test_production_fixed_actions_execute_through_the_component_owner(self):
        owners = production_recovery_owners(
            lambda _request: RecoveryHealthEvidence(),
            capabilities=production_capabilities(),
        )
        cases = {
            "reinitialize_speech_capture": "speech_capture",
            "reinitialize_transcription_delivery": "transcription",
            "restart_bridge": "bridge",
            "restart_messenger": "messenger",
            "restart_daemon": "daemon",
            "reconnect_ipc": "orchestrator",
            "restore_session_registration": "session",
            "release_dead_ownership": "command",
            "launch_foreground_provider": "foreground_provider",
        }

        for capability, component in cases.items():
            with self.subTest(capability=capability):
                broker = ComponentOwnedRecoveryBroker(owners, monotonic=lambda: 100.0)
                outcome = perform(
                    broker,
                    capability,
                    incident(
                        component,
                        provider=(
                            "codex" if component == "foreground_provider" else "none"
                        ),
                    ),
                )
                self.assertEqual(
                    (outcome.status, outcome.outcome_code),
                    ("applied", "component_action_applied"),
                )

    def test_codex_and_claude_receive_identical_provider_recovery_capabilities(self):
        broker, _owners = broker_and_owners()
        codex = broker.capabilities(incident("foreground_provider", provider="codex"))
        claude = broker.capabilities(incident("foreground_provider", provider="claude"))

        self.assertEqual(codex, claude)
        self.assertIn("launch_foreground_provider", codex)
        self.assertNotIn("switch_provider", codex)
        self.assertNotIn("switch_model", codex)

    def test_missing_component_owner_returns_foreground_authorization_escalation(self):
        broker = ComponentOwnedRecoveryBroker(monotonic=lambda: 100.0)

        self.assertEqual(broker.capabilities(incident()), ("check_processing_health",))
        outcome = perform(broker, "check_processing_health", incident())

        self.assertEqual((outcome.status, outcome.outcome_code), (
            "authorization_required", "component_owner_unavailable",
        ))


if __name__ == "__main__":
    unittest.main()
