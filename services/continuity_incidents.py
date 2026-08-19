"""Privacy-safe voice continuity incident classification.

Component owners translate their native liveness into ``Observation`` values.
This module deliberately has no access to transcripts, prompts, repositories,
provider output, or process arguments.  It decides when bounded evidence is
strong enough for a separate recovery owner to act.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
import math
from typing import Any, Callable, Mapping, Optional


SCHEMA_VERSION = 1
COMPONENTS = frozenset({
    "speech_capture",
    "transcription",
    "bridge",
    "messenger",
    "foreground_provider",
    "orchestrator",
    "daemon",
    "session",
    "command",
})
PHASES = frozenset({
    "capture",
    "transcription",
    "delivery",
    "component_liveness",
    "provider_turn",
    "command_processing",
    "session_liveness",
})
HEALTH_VALUES = frozenset({"healthy", "degraded", "unavailable", "recovery_failed", "completed"})
PROVIDERS = frozenset({"codex", "claude", "none"})
SUPPRESSION_REASONS = frozenset({"explicit_stop", "update", "reset"})

_CODEX_SIGNALS = {
    "turn_started": "healthy",
    "turn_progress": "healthy",
    "turn_completed": "completed",
    "turn_failed": "unavailable",
    "app_server_timeout": "unavailable",
    "process_exit": "unavailable",
}
_CLAUDE_SIGNALS = {
    "stream_started": "healthy",
    "stream_progress": "healthy",
    "result_success": "completed",
    "result_error": "unavailable",
    "timeout": "unavailable",
    "process_exit": "unavailable",
}

_OBJECTIVES = {
    "speech_capture": (
        "Relay Runner cannot capture speech for the active voice session.",
        ("capture_progress_observed", "transcription_started"),
    ),
    "transcription": (
        "Relay Runner cannot turn captured speech into a command.",
        ("transcription_completed", "command_created"),
    ),
    "bridge": (
        "Relay Runner cannot deliver captured input to the active session.",
        ("bridge_process_alive", "bridge_heartbeat_fresh", "command_delivered"),
    ),
    "messenger": (
        "Relay Runner cannot provide voice-session conversation updates.",
        ("messenger_process_alive", "messenger_progress_observed"),
    ),
    "foreground_provider": (
        "Relay Runner cannot continue foreground project processing.",
        ("provider_process_alive", "provider_progress_observed"),
    ),
    "orchestrator": (
        "Relay Runner cannot plan or route accepted project work.",
        ("orchestrator_heartbeat_fresh", "command_progress_observed"),
    ),
    "daemon": (
        "Relay Runner cannot continue daemon-owned project work.",
        ("daemon_process_alive", "daemon_heartbeat_fresh"),
    ),
    "session": (
        "Relay Runner cannot continue the active voice session.",
        ("session_owner_alive", "session_heartbeat_fresh"),
    ),
    "command": (
        "Relay Runner cannot advance an accepted voice command.",
        ("command_progress_observed", "command_completed"),
    ),
}


def opaque_identifier(kind: str, native_value: Any) -> str:
    """Create a stable identifier without retaining a native identifier."""
    if kind not in {"session", "command"}:
        raise ValueError("opaque identifier kind must be session or command")
    value = str(native_value or "")
    if not value:
        raise ValueError("opaque identifier source must not be empty")
    digest = hashlib.sha256(f"continuity-v1:{kind}:{value}".encode("utf-8")).hexdigest()
    return f"{kind}-{digest[:24]}"


def _validate_opaque(value: Optional[str], kind: str) -> None:
    if value is None and kind == "command":
        return
    prefix = f"{kind}-"
    suffix = str(value or "")[len(prefix):]
    if not str(value or "").startswith(prefix) or len(suffix) != 24:
        raise ValueError(f"{kind}_id must be created with opaque_identifier")
    if any(character not in "0123456789abcdef" for character in suffix):
        raise ValueError(f"invalid opaque {kind}_id")


@dataclass(frozen=True)
class Observation:
    session_id: str
    command_id: Optional[str]
    component: str
    provider: str
    recovery_generation: int
    phase: str
    health: str
    observed_at: float
    native_recovery_failed: bool = False

    def __post_init__(self) -> None:
        _validate_opaque(self.session_id, "session")
        _validate_opaque(self.command_id, "command")
        if self.component not in COMPONENTS:
            raise ValueError(f"unsupported component: {self.component}")
        if self.provider not in PROVIDERS:
            raise ValueError(f"unsupported provider: {self.provider}")
        if self.phase not in PHASES:
            raise ValueError(f"unsupported phase: {self.phase}")
        if self.health not in HEALTH_VALUES:
            raise ValueError(f"unsupported health: {self.health}")
        if self.recovery_generation < 0:
            raise ValueError("recovery_generation must not be negative")
        if not math.isfinite(self.observed_at):
            raise ValueError("observed_at must be finite")


def provider_observation(
    provider: str,
    signal: str,
    *,
    session_id: str,
    command_id: Optional[str],
    recovery_generation: int,
    observed_at: float,
) -> Observation:
    """Translate only allowlisted provider signals into the shared contract."""
    mappings = {"codex": _CODEX_SIGNALS, "claude": _CLAUDE_SIGNALS}
    try:
        health = mappings[provider][signal]
    except KeyError as error:
        raise ValueError("unsupported provider signal") from error
    return Observation(
        session_id=session_id,
        command_id=command_id,
        component="foreground_provider",
        provider=provider,
        recovery_generation=recovery_generation,
        phase="provider_turn",
        health=health,
        observed_at=observed_at,
    )


@dataclass(frozen=True)
class DetectorConfig:
    grace_periods: Mapping[str, float] = field(default_factory=lambda: {
        "speech_capture": 5.0,
        "transcription": 10.0,
        "bridge": 15.0,
        "messenger": 15.0,
        "foreground_provider": 30.0,
        "orchestrator": 30.0,
        "daemon": 30.0,
        "session": 30.0,
        "command": 30.0,
    })
    post_grace_samples: int = 2
    recurrence_count: int = 3
    recurrence_window: float = 30 * 60
    failed_recovery_count: int = 2
    failed_recovery_window: float = 10 * 60
    cooldown: float = 15 * 60

    def __post_init__(self) -> None:
        if set(self.grace_periods) != COMPONENTS:
            raise ValueError("grace_periods must name every supported component")
        if any(not math.isfinite(value) or value < 0 for value in self.grace_periods.values()):
            raise ValueError("grace periods must be finite and non-negative")
        if self.post_grace_samples < 2:
            raise ValueError("at least two post-grace liveness samples are required")


@dataclass(frozen=True)
class RecoveryObjective:
    unavailable_capability: str
    restored_when: tuple[str, ...]

    def as_dict(self) -> dict[str, object]:
        return {
            "unavailable_capability": self.unavailable_capability,
            "restored_when": list(self.restored_when),
        }


@dataclass(frozen=True)
class IncidentEnvelope:
    incident_id: str
    fingerprint: str
    classification: str
    session_id: str
    command_id: Optional[str]
    component: str
    provider: str
    recovery_generation: int
    phase: str
    health: str
    first_observed_at: float
    last_observed_at: float
    grace_deadline: float
    post_grace_samples: int
    failed_native_recovery: bool
    cooldown_until: float
    objective: RecoveryObjective

    def as_dict(self) -> dict[str, object]:
        return {
            "schema_version": SCHEMA_VERSION,
            "incident_id": self.incident_id,
            "fingerprint": self.fingerprint,
            "classification": self.classification,
            "session_id": self.session_id,
            "command_id": self.command_id,
            "component": self.component,
            "provider": self.provider,
            "recovery_generation": self.recovery_generation,
            "phase": self.phase,
            "health": self.health,
            "timing": {
                "first_observed_at": self.first_observed_at,
                "last_observed_at": self.last_observed_at,
                "grace_deadline": self.grace_deadline,
                "post_grace_samples": self.post_grace_samples,
                "failed_native_recovery": self.failed_native_recovery,
                "cooldown_until": self.cooldown_until,
            },
            "recovery_objective": self.objective.as_dict(),
        }


@dataclass(frozen=True)
class Classification:
    state: str
    fingerprint: Optional[str] = None
    envelope: Optional[IncidentEnvelope] = None
    suppression_reason: Optional[str] = None


@dataclass
class _Episode:
    first_observed_at: float
    last_observed_at: float
    last_post_grace_sample_at: Optional[float] = None
    post_grace_samples: int = 0
    failed_native_recovery: bool = False
    classification: Optional[str] = None


@dataclass(frozen=True)
class _Occurrence:
    observed_at: float
    session_id: str
    failed_native_recovery: bool


class ContinuityIncidentDetector:
    """Classify bounded liveness observations without initiating recovery."""

    def __init__(
        self,
        config: Optional[DetectorConfig] = None,
        *,
        emit: Optional[Callable[[dict[str, object]], None]] = None,
    ) -> None:
        self.config = config or DetectorConfig()
        self._emit = emit
        self._episodes: dict[tuple[str, str, Optional[str], int], _Episode] = {}
        self._history: dict[str, list[_Occurrence]] = {}
        self._cooldown_until: dict[str, float] = {}
        self._completed_commands: set[str] = set()

    @staticmethod
    def fingerprint(observation: Observation) -> str:
        material = json.dumps(
            [SCHEMA_VERSION, observation.component, observation.provider, observation.phase],
            separators=(",", ":"),
        )
        digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
        return f"fp-{digest[:24]}"

    def observe(
        self,
        observation: Observation,
        *,
        suppression: Optional[str] = None,
    ) -> Classification:
        fingerprint = self.fingerprint(observation)
        episode_key = (
            fingerprint,
            observation.session_id,
            observation.command_id,
            observation.recovery_generation,
        )
        if suppression is not None:
            if suppression not in SUPPRESSION_REASONS:
                raise ValueError("unsupported suppression reason")
            self._episodes.pop(episode_key, None)
            return Classification("suppressed", fingerprint, suppression_reason=suppression)

        if observation.command_id in self._completed_commands:
            self._episodes.pop(episode_key, None)
            return Classification("suppressed", fingerprint, suppression_reason="completed_work")

        if observation.health in {"healthy", "completed"}:
            self._episodes.pop(episode_key, None)
            if observation.health == "completed" and observation.command_id is not None:
                self._completed_commands.add(observation.command_id)
            return Classification(observation.health, fingerprint)

        episode = self._episodes.get(episode_key)
        if episode is None:
            episode = _Episode(observation.observed_at, observation.observed_at)
            self._episodes[episode_key] = episode
        elif observation.observed_at < episode.last_observed_at:
            raise ValueError("observations for an incident must be time ordered")
        episode.last_observed_at = observation.observed_at
        episode.failed_native_recovery = (
            episode.failed_native_recovery
            or observation.native_recovery_failed
            or observation.health == "recovery_failed"
        )

        grace_deadline = (
            episode.first_observed_at
            + self.config.grace_periods[observation.component]
        )
        if observation.observed_at >= grace_deadline:
            if (
                episode.last_post_grace_sample_at is None
                or observation.observed_at > episode.last_post_grace_sample_at
            ):
                episode.post_grace_samples += 1
                episode.last_post_grace_sample_at = observation.observed_at

        qualifies = (
            episode.failed_native_recovery
            or episode.post_grace_samples >= self.config.post_grace_samples
        )
        if not qualifies:
            return Classification("transient", fingerprint)
        if episode.classification is not None:
            return Classification(episode.classification, fingerprint)

        history = self._pruned_history(fingerprint, observation.observed_at)
        occurrence = _Occurrence(
            observation.observed_at,
            observation.session_id,
            episode.failed_native_recovery,
        )
        history.append(occurrence)
        self._history[fingerprint] = history
        classification = (
            "recurring"
            if self._is_recurring(history, observation.observed_at)
            else "stalled"
        )
        episode.classification = classification

        cooldown_until = self._cooldown_until.get(fingerprint, 0.0)
        if observation.observed_at < cooldown_until:
            return Classification(
                classification,
                fingerprint,
                suppression_reason="cooldown",
            )

        cooldown_until = observation.observed_at + self.config.cooldown
        self._cooldown_until[fingerprint] = cooldown_until
        capability, restored_when = _OBJECTIVES[observation.component]
        incident_material = (
            f"{fingerprint}:{observation.session_id}:{observation.command_id or 'none'}:"
            f"{episode.first_observed_at}:{observation.recovery_generation}"
        )
        incident_id = "inc-" + hashlib.sha256(incident_material.encode("utf-8")).hexdigest()[:12]
        envelope = IncidentEnvelope(
            incident_id=incident_id,
            fingerprint=fingerprint,
            classification=classification,
            session_id=observation.session_id,
            command_id=observation.command_id,
            component=observation.component,
            provider=observation.provider,
            recovery_generation=observation.recovery_generation,
            phase=observation.phase,
            health=observation.health,
            first_observed_at=episode.first_observed_at,
            last_observed_at=episode.last_observed_at,
            grace_deadline=grace_deadline,
            post_grace_samples=episode.post_grace_samples,
            failed_native_recovery=episode.failed_native_recovery,
            cooldown_until=cooldown_until,
            objective=RecoveryObjective(capability, restored_when),
        )
        payload = envelope.as_dict()
        if self._emit is not None:
            self._emit(payload)
        return Classification(classification, fingerprint, envelope)

    def _pruned_history(self, fingerprint: str, now: float) -> list[_Occurrence]:
        cutoff = now - self.config.recurrence_window
        return [item for item in self._history.get(fingerprint, []) if item.observed_at >= cutoff]

    def _is_recurring(self, history: list[_Occurrence], now: float) -> bool:
        if len(history) >= self.config.recurrence_count:
            return True
        recovery_cutoff = now - self.config.failed_recovery_window
        failed_recoveries = sum(
            item.failed_native_recovery
            for item in history
            if item.observed_at >= recovery_cutoff
        )
        if failed_recoveries >= self.config.failed_recovery_count:
            return True
        return len({item.session_id for item in history}) >= 2
