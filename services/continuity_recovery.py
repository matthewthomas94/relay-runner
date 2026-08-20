"""Validated, component-owned runtime recovery for Relay voice processing.

The continuity provider can select a capability, but it cannot execute one.
This broker checks the fixed incident identity and a fresh component-owner
inspection before asking that owner to make a bounded Relay-runtime change.
There is deliberately no generic command, path, URL, or payload capability.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import math
import re
import threading
import time
from typing import Mapping, Protocol

from continuity_agent import RecoveryBrokerOutcome, RecoveryHealthEvidence


RESTORE_PROCESSING_OBJECTIVE = "restore_processing"
_CODE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_PROCESS_ID_RE = re.compile(r"^continuity-[0-9a-f]{32}$")
_LIVENESS = frozenset({
    "healthy", "slow", "unhealthy", "confirmed_dead", "unknown",
})
_IDEMPOTENCY_STATES = frozenset({"new", "applied", "compensated", "conflict"})
_SAFE_COMMAND_PHASES = frozenset({
    "none", "before_command", "captured", "undelivered", "unclaimed",
    "claimed", "in_flight",
})


@dataclass(frozen=True)
class RecoveryCapabilityPolicy:
    owner: str
    components: frozenset[str]
    phases: frozenset[str]
    postcondition: str
    max_attempts: int = 2
    cooldown_seconds: float = 5.0
    required_liveness: frozenset[str] = field(
        default_factory=lambda: frozenset({"unhealthy", "confirmed_dead"}),
    )
    command_phases: frozenset[str] = field(default_factory=lambda: _SAFE_COMMAND_PHASES)

    def __post_init__(self) -> None:
        if not _CODE_RE.fullmatch(self.owner) or not _CODE_RE.fullmatch(self.postcondition):
            raise ValueError("recovery policy uses an invalid owner or postcondition")
        if self.max_attempts < 1 or self.cooldown_seconds < 0:
            raise ValueError("recovery policy requires bounded attempts and cooldown")


_COMPONENT_OWNERS = {
    "speech_capture": "app",
    "transcription": "app",
    "bridge": "app",
    "messenger": "bridge",
    "foreground_provider": "app",
    "orchestrator": "daemon",
    "daemon": "app",
    "session": "bridge",
    "command": "daemon",
}


CAPABILITY_POLICIES = {
    "check_processing_health": RecoveryCapabilityPolicy(
        owner="dynamic",
        components=frozenset(_COMPONENT_OWNERS),
        phases=frozenset({
            "capture", "transcription", "delivery", "component_liveness",
            "provider_turn", "command_processing", "session_liveness",
        }),
        postcondition="processing_health_observed",
        max_attempts=4,
        cooldown_seconds=0,
        required_liveness=frozenset(_LIVENESS),
    ),
    "reinitialize_speech_capture": RecoveryCapabilityPolicy(
        owner="app",
        components=frozenset({"speech_capture"}),
        phases=frozenset({"capture"}),
        postcondition="capture_progress_observed",
    ),
    "reinitialize_transcription_delivery": RecoveryCapabilityPolicy(
        owner="app",
        components=frozenset({"transcription"}),
        phases=frozenset({"transcription", "delivery"}),
        postcondition="transcription_completed",
        command_phases=frozenset({"none", "before_command", "captured", "undelivered"}),
    ),
    "restart_bridge": RecoveryCapabilityPolicy(
        owner="app",
        components=frozenset({"bridge"}),
        phases=frozenset({"delivery", "component_liveness"}),
        postcondition="bridge_process_alive",
        required_liveness=frozenset({"confirmed_dead", "unhealthy"}),
    ),
    "restart_messenger": RecoveryCapabilityPolicy(
        owner="bridge",
        components=frozenset({"messenger"}),
        phases=frozenset({"component_liveness"}),
        postcondition="messenger_process_alive",
        required_liveness=frozenset({"confirmed_dead", "unhealthy"}),
    ),
    "restart_daemon": RecoveryCapabilityPolicy(
        owner="app",
        components=frozenset({"daemon"}),
        phases=frozenset({"component_liveness"}),
        postcondition="daemon_process_alive",
        required_liveness=frozenset({"confirmed_dead"}),
        max_attempts=1,
        cooldown_seconds=15,
    ),
    "reconnect_ipc": RecoveryCapabilityPolicy(
        owner="dynamic",
        components=frozenset({"bridge", "messenger", "orchestrator", "daemon", "session"}),
        phases=frozenset({"delivery", "component_liveness", "session_liveness"}),
        postcondition="ipc_connection_restored",
    ),
    "restore_session_registration": RecoveryCapabilityPolicy(
        owner="bridge",
        components=frozenset({"orchestrator", "session"}),
        phases=frozenset({"component_liveness", "session_liveness"}),
        postcondition="session_heartbeat_fresh",
    ),
    "release_dead_ownership": RecoveryCapabilityPolicy(
        owner="dynamic",
        components=frozenset({"foreground_provider", "orchestrator", "session", "command"}),
        phases=frozenset({
            "provider_turn", "component_liveness", "session_liveness", "command_processing",
        }),
        postcondition="dead_ownership_released",
        required_liveness=frozenset({"confirmed_dead"}),
        max_attempts=1,
    ),
    "launch_foreground_provider": RecoveryCapabilityPolicy(
        owner="app",
        components=frozenset({"foreground_provider", "session"}),
        phases=frozenset({"provider_turn", "session_liveness"}),
        postcondition="provider_process_alive",
        required_liveness=frozenset({"confirmed_dead"}),
        max_attempts=1,
        cooldown_seconds=15,
    ),
}


@dataclass(frozen=True)
class RecoveryActionRequest:
    capability: str
    incident_id: str
    session_id: str
    command_id: str | None
    component: str
    provider: str
    recovery_generation: int
    incident_phase: str
    process_identity: str
    attempt: int
    idempotency_key: str
    expected_postcondition: str
    deadline: float


@dataclass(frozen=True)
class RecoveryActionValidation:
    validation_token: str
    exact_target_owned: bool
    liveness: str
    incident_active: bool
    generation_matches: bool
    command_phase: str
    command_phase_matches: bool
    idempotency_state: str
    compensation_available: bool
    cooldown_remaining: float
    expected_postcondition: str
    health: RecoveryHealthEvidence = field(default_factory=RecoveryHealthEvidence)

    def __post_init__(self) -> None:
        if not _CODE_RE.fullmatch(self.validation_token):
            raise ValueError("component validation requires an opaque token")
        if self.liveness not in _LIVENESS:
            raise ValueError("component validation returned invalid liveness")
        if self.command_phase not in _SAFE_COMMAND_PHASES | {"completed", "ambiguous"}:
            raise ValueError("component validation returned invalid command phase")
        if self.idempotency_state not in _IDEMPOTENCY_STATES:
            raise ValueError("component validation returned invalid idempotency state")
        if not math.isfinite(self.cooldown_remaining) or self.cooldown_remaining < 0:
            raise ValueError("component validation returned invalid cooldown")
        if not _CODE_RE.fullmatch(self.expected_postcondition):
            raise ValueError("component validation returned invalid postcondition")


@dataclass(frozen=True)
class RecoveryActionResult:
    status: str
    outcome_code: str
    health: RecoveryHealthEvidence = field(default_factory=RecoveryHealthEvidence)
    ephemeral_state_created: bool = False
    health_worsened: bool = False

    def __post_init__(self) -> None:
        if self.status not in {"applied", "noop", "failed"}:
            raise ValueError("component owner returned invalid recovery status")
        if not _CODE_RE.fullmatch(self.outcome_code):
            raise ValueError("component owner returned unsanitized outcome")


class ComponentRecoveryOwner(Protocol):
    owner: str

    def inspect(self, request: RecoveryActionRequest) -> RecoveryActionValidation: ...

    def execute(
        self,
        request: RecoveryActionRequest,
        validation: RecoveryActionValidation,
        cancel_event: threading.Event,
    ) -> RecoveryActionResult: ...

    def cleanup(
        self,
        request: RecoveryActionRequest,
        validation: RecoveryActionValidation,
    ) -> bool: ...


class ComponentOwnedRecoveryBroker:
    """Fail-closed broker for the restore-processing objective."""

    objective = RESTORE_PROCESSING_OBJECTIVE

    def __init__(
        self,
        owners: Mapping[str, ComponentRecoveryOwner] | None = None,
        *,
        monotonic=time.monotonic,
    ):
        self._owners = dict(owners or {})
        for name, owner in self._owners.items():
            if name not in {"app", "bridge", "daemon"} or owner.owner != name:
                raise ValueError("recovery owner registry identity mismatch")
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._attempts: dict[str, int] = {}
        self._cooldowns: dict[str, float] = {}
        self._applied: set[str] = set()

    def capabilities(self, incident: Mapping[str, object]) -> tuple[str, ...]:
        component = str(incident.get("component") or "")
        phase = str(incident.get("phase") or "")
        available = []
        for capability, policy in CAPABILITY_POLICIES.items():
            owner_name = self._owner_name(policy, component)
            if (
                component in policy.components
                and phase in policy.phases
                and owner_name in self._owners
            ):
                available.append(capability)
        # The lane requires one bounded choice in order to reach a concise
        # escalation when the affected component owner is unavailable.
        return tuple(available or ("check_processing_health",))

    def perform(
        self,
        capability: str,
        *,
        incident: Mapping[str, object],
        process_identity: str,
        recovery_generation: int,
        attempt: int,
        deadline: float,
        cancel_event: threading.Event,
    ) -> RecoveryBrokerOutcome:
        policy = CAPABILITY_POLICIES.get(capability)
        if policy is None:
            return self._outcome(capability, "rejected", "capability_not_allowed")
        request_or_code = self._request(
            capability,
            policy,
            incident,
            process_identity,
            recovery_generation,
            attempt,
            deadline,
        )
        if isinstance(request_or_code, str):
            return self._outcome(capability, "rejected", request_or_code)
        request = request_or_code
        if cancel_event.is_set() or self._monotonic() >= deadline:
            return self._outcome(capability, "circuit_open", "recovery_budget_exhausted")
        owner = self._owners.get(self._owner_name(policy, request.component))
        if owner is None:
            return self._outcome(
                capability,
                "authorization_required",
                "component_owner_unavailable",
            )

        with self._lock:
            attempts = self._attempts.get(request.idempotency_key, 0)
            if attempts >= policy.max_attempts or attempt > policy.max_attempts:
                return self._outcome(capability, "circuit_open", "capability_attempt_cap_reached")
            broker_cooldown_active = (
                self._monotonic() < self._cooldowns.get(request.idempotency_key, 0)
            )
            self._attempts[request.idempotency_key] = attempts + 1

        validation = owner.inspect(request)
        rejection = self._validation_rejection(policy, request, validation)
        if rejection is not None:
            return self._outcome(capability, rejection[0], rejection[1], validation.health)
        with self._lock:
            already_applied = request.idempotency_key in self._applied
        if already_applied or validation.idempotency_state == "applied":
            return self._outcome(capability, "noop", "action_already_applied", validation.health)
        if broker_cooldown_active:
            return self._outcome(capability, "circuit_open", "capability_cooldown_active")
        if cancel_event.is_set() or self._monotonic() >= deadline:
            return self._outcome(capability, "circuit_open", "recovery_budget_exhausted")

        result = owner.execute(request, validation, cancel_event)
        if result.ephemeral_state_created and (result.status == "failed" or result.health_worsened):
            if not validation.compensation_available:
                return self._outcome(
                    capability,
                    "circuit_open",
                    "ephemeral_cleanup_unavailable",
                    result.health,
                )
            cleaned = owner.cleanup(request, validation)
            code = "ephemeral_cleanup_applied" if cleaned else "ephemeral_cleanup_failed"
            status = "failed" if cleaned else "circuit_open"
            return self._outcome(capability, status, code, result.health)
        if result.health_worsened:
            return self._outcome(
                capability,
                "circuit_open",
                "recovery_health_worsened",
                result.health,
            )

        health = self._validated_health(incident, result.health)
        if result.status == "applied":
            with self._lock:
                self._applied.add(request.idempotency_key)
                self._cooldowns[request.idempotency_key] = (
                    self._monotonic() + policy.cooldown_seconds
                )
        return self._outcome(capability, result.status, result.outcome_code, health)

    def _request(
        self,
        capability: str,
        policy: RecoveryCapabilityPolicy,
        incident: Mapping[str, object],
        process_identity: str,
        recovery_generation: int,
        attempt: int,
        deadline: float,
    ) -> RecoveryActionRequest | str:
        required = ("incident_id", "session_id", "component", "provider", "phase")
        if any(not isinstance(incident.get(key), str) or not incident.get(key) for key in required):
            return "invalid_incident_identity"
        try:
            incident_generation = int(incident.get("recovery_generation"))
        except (TypeError, ValueError):
            return "invalid_recovery_generation"
        component = str(incident["component"])
        phase = str(incident["phase"])
        if recovery_generation != incident_generation or recovery_generation < 0:
            return "recovery_generation_mismatch"
        if component not in policy.components or phase not in policy.phases:
            return "capability_outside_incident_scope"
        if not _PROCESS_ID_RE.fullmatch(process_identity):
            return "invalid_continuity_process"
        if not isinstance(attempt, int) or attempt < 1:
            return "invalid_recovery_attempt"
        if not isinstance(deadline, (int, float)) or not math.isfinite(deadline):
            return "invalid_recovery_deadline"
        command_id = incident.get("command_id")
        if command_id is not None and not isinstance(command_id, str):
            return "invalid_incident_identity"
        identity = "|".join((
            str(incident["incident_id"]), str(recovery_generation), capability,
            component, str(incident["session_id"]), str(command_id or "none"),
        ))
        idempotency_key = "recovery_" + hashlib.sha256(identity.encode()).hexdigest()[:24]
        return RecoveryActionRequest(
            capability=capability,
            incident_id=str(incident["incident_id"]),
            session_id=str(incident["session_id"]),
            command_id=command_id,
            component=component,
            provider=str(incident["provider"]),
            recovery_generation=recovery_generation,
            incident_phase=phase,
            process_identity=process_identity,
            attempt=attempt,
            idempotency_key=idempotency_key,
            expected_postcondition=policy.postcondition,
            deadline=float(deadline),
        )

    @staticmethod
    def _validation_rejection(
        policy: RecoveryCapabilityPolicy,
        request: RecoveryActionRequest,
        validation: RecoveryActionValidation,
    ) -> tuple[str, str] | None:
        if not validation.exact_target_owned:
            return "authorization_required", "target_ownership_not_proven"
        if not validation.incident_active or not validation.generation_matches:
            return "rejected", "stale_recovery_generation"
        if not validation.command_phase_matches:
            return "authorization_required", "command_phase_ambiguous"
        if validation.command_phase not in policy.command_phases:
            return "authorization_required", "command_replay_not_recoverable"
        if validation.liveness not in policy.required_liveness:
            code = "live_provider_must_not_be_killed" if (
                request.capability in {"release_dead_ownership", "launch_foreground_provider"}
                and validation.liveness in {"healthy", "slow"}
            ) else "target_health_not_proven"
            return "rejected", code
        if validation.idempotency_state == "conflict":
            return "authorization_required", "idempotency_conflict"
        if validation.cooldown_remaining > 0:
            return "circuit_open", "component_cooldown_active"
        if validation.expected_postcondition != policy.postcondition:
            return "rejected", "postcondition_mismatch"
        return None

    @staticmethod
    def _validated_health(
        incident: Mapping[str, object],
        health: RecoveryHealthEvidence,
    ) -> RecoveryHealthEvidence:
        objective = incident.get("recovery_objective")
        restored_when = objective.get("restored_when") if isinstance(objective, Mapping) else ()
        required = {
            code for code in restored_when or ()
            if isinstance(code, str) and _CODE_RE.fullmatch(code)
        }
        proven = health.objective_restored and bool(required) and required.issubset(
            health.evidence_codes,
        )
        return RecoveryHealthEvidence(
            objective_restored=proven,
            stable_for_seconds=health.stable_for_seconds,
            evidence_codes=health.evidence_codes,
        )

    @staticmethod
    def _owner_name(policy: RecoveryCapabilityPolicy, component: str) -> str:
        return _COMPONENT_OWNERS.get(component, "") if policy.owner == "dynamic" else policy.owner

    @staticmethod
    def _outcome(
        capability: str,
        status: str,
        code: str,
        health: RecoveryHealthEvidence | None = None,
    ) -> RecoveryBrokerOutcome:
        return RecoveryBrokerOutcome(
            capability,
            status,
            code,
            health or RecoveryHealthEvidence(),
        )


DISALLOWED_RECOVERY_OPERATIONS = frozenset({
    "edit_source", "edit_ticket", "change_git_state", "change_configuration",
    "change_authentication", "access_keychain", "change_permissions", "install_update",
    "install_software", "create_release", "deploy", "mutate_database",
    "mutate_durable_user_data", "send_message", "external_action", "cancel_live_work",
    "kill_live_provider", "switch_provider", "switch_model", "replay_ambiguous_command",
    "destructive_reset", "reinstall",
})
