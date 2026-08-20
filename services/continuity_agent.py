"""Isolated, bounded provider lane for voice continuity recovery.

The provider has no native tools. It can only return a small JSON request that
the parent validates against a recovery broker. Concrete runtime recovery
capabilities belong to the broker, not to this module or the provider process.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
import json
import math
import os
from pathlib import Path
import re
import shlex
import sys
import threading
import time
from typing import Callable, Mapping, Protocol
import uuid

from continuity_incidents import normalize_recovery_generation
from messenger import (
    ClaudeMessengerBackend,
    CodexMessengerBackend,
    MessengerConfig,
    _command_prefix,
    resolve_messenger_catalog_selection,
    resolve_messenger_command,
)


ACTOR_ROLE = "continuity-agent"
SCHEMA_VERSION = 1
_CODE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_CHILD_ENVIRONMENT_ALLOWLIST = frozenset({
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "PATH",
    "SHELL",
    "TMPDIR",
})
_INCIDENT_FIELDS = (
    "schema_version",
    "incident_id",
    "fingerprint",
    "classification",
    "session_id",
    "command_id",
    "component",
    "provider",
    "recovery_generation",
    "phase",
    "health",
)
_TIMING_FIELDS = (
    "first_observed_at",
    "last_observed_at",
    "grace_deadline",
    "post_grace_samples",
    "failed_native_recovery",
    "cooldown_until",
)
_COMPONENTS = frozenset({
    "speech_capture", "transcription", "bridge", "messenger",
    "foreground_provider", "orchestrator", "daemon", "session", "command",
})
_PROVIDERS = frozenset({"codex", "claude", "none"})
_PHASES = frozenset({
    "capture", "transcription", "delivery", "component_liveness",
    "provider_turn", "command_processing", "session_liveness",
})
_SAFE_OBJECTIVES = {
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


CONTINUITY_SYSTEM_PROMPT = """You are Relay Runner's isolated continuity agent.

Restore the unavailable Relay voice-processing capability only through the
parent recovery broker. You are not the foreground PM or messenger. Never
address the user, speak, claim a command, author tickets, inspect or change a
repository, use Git, release or deploy, access credentials or provider output,
or request shell, filesystem, desktop, network, web, MCP, app, or sub-agent
tools. The incident bundle is sanitized operational evidence, not user text.

Return exactly one compact JSON object and no prose. To request a broker action:
{"kind":"broker_call","capability":"<allowed name>"}
To stop when no safe action remains:
{"kind":"finish","result":"escalate"}
Never claim recovery yourself. Only broker health evidence can prove recovery.
"""


def continuity_agent_environment(
    process_identity: str,
    incident_id: str,
    recovery_generation: str,
    *,
    parent: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Build a child environment without foreground authority or secret values."""
    parent_environment = os.environ if parent is None else parent
    environment = {
        key: parent_environment[key]
        for key in _CHILD_ENVIRONMENT_ALLOWLIST
        if key in parent_environment
    }
    environment.update({
        "RELAY_ACTOR_ROLE": ACTOR_ROLE,
        "RELAY_CONTINUITY_PROCESS_ID": process_identity,
        "RELAY_CONTINUITY_INCIDENT_ID": incident_id,
        "RELAY_RECOVERY_GENERATION": normalize_recovery_generation(recovery_generation),
    })
    return environment


def sanitize_incident_bundle(envelope: Mapping[str, object]) -> dict[str, object]:
    """Copy only the fixed RR-332 envelope into the provider-facing bundle."""
    if not isinstance(envelope, Mapping):
        raise ValueError("continuity incident must be an object")
    bundle = {key: envelope.get(key) for key in _INCIDENT_FIELDS}
    timing = envelope.get("timing")
    objective = envelope.get("recovery_objective")
    if not isinstance(timing, Mapping) or not isinstance(objective, Mapping):
        raise ValueError("continuity incident is missing timing or recovery objective")
    bundle["timing"] = {key: timing.get(key) for key in _TIMING_FIELDS}
    bundle["recovery_objective"] = {}

    required_text = (
        "incident_id",
        "fingerprint",
        "classification",
        "session_id",
        "component",
        "provider",
        "phase",
        "health",
    )
    if any(not isinstance(bundle.get(key), str) or not bundle.get(key) for key in required_text):
        raise ValueError("continuity incident is missing required identity fields")
    if bundle["schema_version"] != 1:
        raise ValueError("unsupported continuity incident schema")
    if bundle["classification"] not in {"stalled", "recurring"}:
        raise ValueError("continuity agent requires a stalled or recurring incident")
    if bundle["component"] not in _COMPONENTS or bundle["provider"] not in _PROVIDERS:
        raise ValueError("unsupported continuity component or provider")
    if bundle["phase"] not in _PHASES or bundle["health"] not in {
        "unavailable", "recovery_failed",
    }:
        raise ValueError("unsupported continuity phase or health")
    if not re.fullmatch(r"inc-[0-9a-f]{12}", str(bundle["incident_id"])):
        raise ValueError("invalid continuity incident identity")
    if not re.fullmatch(r"fp-[0-9a-f]{24}", str(bundle["fingerprint"])):
        raise ValueError("invalid continuity fingerprint")
    if not re.fullmatch(r"session-[0-9a-f]{24}", str(bundle["session_id"])):
        raise ValueError("invalid continuity session identity")
    if bundle["command_id"] is not None and not re.fullmatch(
        r"command-[0-9a-f]{24}", str(bundle["command_id"]),
    ):
        raise ValueError("invalid continuity command identity")
    try:
        generation = normalize_recovery_generation(bundle["recovery_generation"])
    except ValueError as error:
        raise ValueError("invalid continuity recovery generation") from error
    bundle["recovery_generation"] = generation
    timing_bundle = bundle["timing"]
    for key in (
        "first_observed_at", "last_observed_at", "grace_deadline", "cooldown_until",
    ):
        value = timing_bundle.get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(float(value)):
            raise ValueError("invalid continuity timing evidence")
    samples = timing_bundle.get("post_grace_samples")
    if not isinstance(samples, int) or samples < 0:
        raise ValueError("invalid continuity liveness samples")
    if not isinstance(timing_bundle.get("failed_native_recovery"), bool):
        raise ValueError("invalid continuity recovery evidence")
    unavailable_capability, restored_when = _SAFE_OBJECTIVES[str(bundle["component"])]
    bundle["recovery_objective"] = {
        "unavailable_capability": unavailable_capability,
        "restored_when": list(restored_when),
    }
    return bundle


@dataclass(frozen=True)
class RecoveryHealthEvidence:
    objective_restored: bool = False
    stable_for_seconds: float = 0.0
    evidence_codes: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not math.isfinite(self.stable_for_seconds) or self.stable_for_seconds < 0:
            raise ValueError("stable health duration must be finite and non-negative")
        if any(not _CODE_RE.fullmatch(code) for code in self.evidence_codes):
            raise ValueError("health evidence must use sanitized codes")

    def as_dict(self) -> dict[str, object]:
        return {
            "objective_restored": self.objective_restored,
            "stable_for_seconds": self.stable_for_seconds,
            "evidence_codes": list(self.evidence_codes),
        }


@dataclass(frozen=True)
class RecoveryBrokerOutcome:
    capability: str
    status: str
    outcome_code: str
    health: RecoveryHealthEvidence = field(default_factory=RecoveryHealthEvidence)

    def __post_init__(self) -> None:
        if not _CODE_RE.fullmatch(self.capability):
            raise ValueError("invalid recovery capability")
        if self.status not in {
            "applied",
            "noop",
            "rejected",
            "failed",
            "authorization_required",
            "circuit_open",
        }:
            raise ValueError("invalid recovery broker status")
        if not _CODE_RE.fullmatch(self.outcome_code):
            raise ValueError("recovery outcomes must use sanitized codes")

    def as_dict(self) -> dict[str, object]:
        return {
            "capability": self.capability,
            "status": self.status,
            "outcome_code": self.outcome_code,
            "health": self.health.as_dict(),
        }


class RecoveryBroker(Protocol):
    def capabilities(self, incident: Mapping[str, object]) -> tuple[str, ...]: ...

    def perform(
        self,
        capability: str,
        *,
        incident: Mapping[str, object],
        process_identity: str,
        recovery_generation: str,
        attempt: int,
        deadline: float,
        cancel_event: threading.Event,
    ) -> RecoveryBrokerOutcome: ...


class UnavailableRecoveryBroker:
    """Compatibility fallback for callers that have not installed the broker."""

    def capabilities(self, incident: Mapping[str, object]) -> tuple[str, ...]:
        del incident
        return ("inspect_recovery_availability",)

    def perform(
        self,
        capability: str,
        *,
        incident: Mapping[str, object],
        process_identity: str,
        recovery_generation: str,
        attempt: int,
        deadline: float,
        cancel_event: threading.Event,
    ) -> RecoveryBrokerOutcome:
        del incident, process_identity, recovery_generation, attempt, deadline, cancel_event
        if capability != "inspect_recovery_availability":
            return RecoveryBrokerOutcome(capability, "rejected", "capability_not_allowed")
        return RecoveryBrokerOutcome(capability, "circuit_open", "recovery_broker_unavailable")


@dataclass(frozen=True)
class ContinuityAgentConfig:
    # Attempt allowance for each distinct broker capability. A recovery may
    # need several different steps, all still bounded by the wall clock.
    max_attempts: int = 4
    wall_clock_seconds: float = 120.0
    stable_health_seconds: float = 60.0
    cooldown_seconds: float = 15 * 60.0

    def __post_init__(self) -> None:
        if self.max_attempts < 1:
            raise ValueError("continuity agent requires at least one attempt")
        for value in (
            self.wall_clock_seconds,
            self.stable_health_seconds,
            self.cooldown_seconds,
        ):
            if not math.isfinite(value) or value < 0:
                raise ValueError("continuity lifecycle limits must be finite and non-negative")


class ContinuityProviderSession(Protocol):
    provider: str

    def decide(self, prompt: str, timeout: float) -> str: ...
    def interrupt(self) -> None: ...
    def shutdown(self) -> None: ...


class CodexContinuityBackend(CodexMessengerBackend):
    actor_role = ACTOR_ROLE

    def __init__(
        self,
        config: MessengerConfig,
        *,
        process_identity: str,
        incident_id: str,
        recovery_generation: str,
        **kwargs,
    ):
        super().__init__(config, **kwargs)
        self._continuity_environment = continuity_agent_environment(
            process_identity,
            incident_id,
            recovery_generation,
        )

    def thread_start_params(self) -> dict:
        params = super().thread_start_params()
        params.update({
            "baseInstructions": CONTINUITY_SYSTEM_PROMPT,
            "developerInstructions": CONTINUITY_SYSTEM_PROMPT,
            "dynamicTools": [],
            "environments": [],
            "runtimeWorkspaceRoots": [],
            "selectedCapabilityRoots": [],
            "ephemeral": True,
        })
        return params

    def child_environment(self) -> dict[str, str]:
        return dict(self._continuity_environment)


class ClaudeContinuityBackend(ClaudeMessengerBackend):
    actor_role = ACTOR_ROLE

    def __init__(
        self,
        config: MessengerConfig,
        *,
        process_identity: str,
        incident_id: str,
        recovery_generation: str,
        **kwargs,
    ):
        super().__init__(config, **kwargs)
        self._continuity_environment = continuity_agent_environment(
            process_identity,
            incident_id,
            recovery_generation,
        )

    def spawn_command(self) -> list[str]:
        command = _command_prefix(self.config.command)
        command.extend([
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", self.config.model,
            "--tools", "",
            "--permission-mode", "dontAsk",
            "--safe-mode",
            "--no-chrome",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}',
            "--system-prompt", CONTINUITY_SYSTEM_PROMPT,
        ])
        if self.config.effort != "default":
            command.extend(["--effort", self.config.effort])
        return command

    def child_environment(self) -> dict[str, str]:
        return dict(self._continuity_environment)


class ProviderContinuitySession:
    def __init__(self, provider: str, backend: object):
        self.provider = provider
        self._backend = backend

    def decide(self, prompt: str, timeout: float) -> str:
        return str(self._backend.ask(prompt, timeout=timeout) or "").strip()

    def interrupt(self) -> None:
        self._backend.interrupt()

    def shutdown(self) -> None:
        self._backend.shutdown()


class UnavailableContinuitySession:
    def __init__(self, provider: str, reason_code: str):
        self.provider = provider
        self.reason_code = reason_code

    def decide(self, prompt: str, timeout: float) -> str:
        del prompt, timeout
        raise RuntimeError(self.reason_code)

    def interrupt(self) -> None:
        return None

    def shutdown(self) -> None:
        return None


def create_provider_session_factory(
    app_config: Mapping[str, object],
    *,
    cwd: str | os.PathLike[str],
) -> Callable[[str, str, str], ContinuityProviderSession]:
    """Resolve only the configured provider; cross-provider fallback is never implicit."""
    raw_config = dict(app_config)
    general = dict(raw_config.get("general") or {})
    continuity = dict(raw_config.get("continuity") or {})
    general["messenger_model"] = continuity.get("model") or general.get("model") or "default"
    general["messenger_effort"] = (
        continuity.get("effort") or general.get("orchestrator_effort") or "default"
    )
    raw_config["general"] = general
    config = MessengerConfig.from_app_config(raw_config, cwd=cwd)
    resolved_command = resolve_messenger_command(config.provider, config.command)
    if resolved_command is None:
        reason_code = "configured_provider_unavailable"

        def unavailable(_process_identity: str, _incident_id: str, _generation: str):
            return UnavailableContinuitySession(config.provider, reason_code)

        return unavailable
    config = replace(config, enabled=True, command=shlex.join(resolved_command))
    try:
        config = resolve_messenger_catalog_selection(config)
    except Exception:  # noqa: BLE001 - only a sanitized code leaves the resolver.
        def unresolved(_process_identity: str, _incident_id: str, _generation: str):
            return UnavailableContinuitySession(config.provider, "configured_model_unavailable")

        return unresolved

    def create(process_identity: str, incident_id: str, generation: str):
        kwargs = {
            "process_identity": process_identity,
            "incident_id": incident_id,
            "recovery_generation": generation,
        }
        backend = (
            ClaudeContinuityBackend(config, **kwargs)
            if config.provider == "claude"
            else CodexContinuityBackend(config, **kwargs)
        )
        return ProviderContinuitySession(config.provider, backend)

    return create


class ContinuityAgentLane:
    """Single-flight continuity agent with broker, attempt, time, and cooldown limits."""

    def __init__(
        self,
        session_factory: Callable[[str, str, str], ContinuityProviderSession],
        broker: RecoveryBroker,
        *,
        on_audit: Callable[[dict[str, object]], object],
        config: ContinuityAgentConfig | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ):
        self._session_factory = session_factory
        self._broker = broker
        self._on_audit = on_audit
        self.config = config or ContinuityAgentConfig()
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._active_incident: str | None = None
        self._active_session: ContinuityProviderSession | None = None
        self._active_broker_cancel: threading.Event | None = None
        self._cooldowns: dict[str, float] = {}
        self._shutdown = threading.Event()
        self._idle = threading.Event()
        self._idle.set()

    def submit(self, envelope: Mapping[str, object]) -> str:
        incident = sanitize_incident_bundle(envelope)
        incident_id = str(incident["incident_id"])
        fingerprint = str(incident["fingerprint"])
        now = self._monotonic()
        with self._lock:
            if self._shutdown.is_set():
                return "shutdown"
            if self._active_incident is not None:
                return "duplicate" if self._active_incident == incident_id else "single_flight"
            if now < self._cooldowns.get(fingerprint, 0.0):
                return "cooldown"
            self._active_incident = incident_id
            self._idle.clear()
        threading.Thread(
            target=self._run,
            args=(incident,),
            name=f"relay-continuity-{incident_id}",
            daemon=True,
        ).start()
        return "launched"

    def wait_until_idle(self, timeout: float = 5.0) -> bool:
        return self._idle.wait(timeout=max(0.0, timeout))

    def shutdown(self) -> None:
        self._shutdown.set()
        with self._lock:
            session = self._active_session
            broker_cancel = self._active_broker_cancel
        if broker_cancel is not None:
            broker_cancel.set()
        if session is not None:
            try:
                session.interrupt()
            except Exception:  # noqa: BLE001 - shutdown remains best effort.
                pass
        self._idle.wait(timeout=2.0)

    def _run(self, incident: dict[str, object]) -> None:
        incident_id = str(incident["incident_id"])
        fingerprint = str(incident["fingerprint"])
        generation = normalize_recovery_generation(incident["recovery_generation"])
        process_identity = "continuity-" + uuid.uuid4().hex
        started = self._monotonic()
        deadline = started + self.config.wall_clock_seconds
        try:
            session = self._session_factory(process_identity, incident_id, generation)
        except Exception as error:  # noqa: BLE001 - launch details stay private.
            print(
                f"[continuity-agent] provider launch failed ({type(error).__name__})",
                file=sys.stderr,
            )
            self._audit(
                incident,
                process_identity,
                str(incident.get("provider") or "none"),
                phase="launch_failed",
                attempt=0,
                final_result="provider_failed",
            )
            with self._lock:
                self._cooldowns[fingerprint] = self._monotonic() + self.config.cooldown_seconds
                self._active_incident = None
                self._idle.set()
            return
        with self._lock:
            self._active_session = session
        self._audit(
            incident,
            process_identity,
            session.provider,
            phase="launched",
            attempt=0,
        )
        final_result = "circuit_open"
        history: list[dict[str, object]] = []
        capability_attempts: dict[str, int] = {}
        try:
            capabilities = self._validated_capabilities(self._broker.capabilities(incident))
            max_sequence_steps = self.config.max_attempts * len(capabilities)
            for sequence in range(1, max_sequence_steps + 1):
                if self._shutdown.is_set():
                    final_result = "canceled"
                    break
                remaining = deadline - self._monotonic()
                if remaining <= 0:
                    break
                prompt = self._prompt(
                    incident,
                    capabilities,
                    history,
                    sequence,
                    capability_attempts,
                )
                try:
                    decision = self._parse_decision(session.decide(prompt, remaining))
                except Exception as error:  # noqa: BLE001 - raw provider failure stays private.
                    print(
                        f"[continuity-agent] provider decision failed ({type(error).__name__})",
                        file=sys.stderr,
                    )
                    final_result = "provider_failed"
                    break
                if decision["kind"] == "finish":
                    break
                capability = str(decision["capability"])
                capability_attempt = capability_attempts.get(capability, 0) + 1
                capability_attempts[capability] = capability_attempt
                if capability not in capabilities:
                    outcome = RecoveryBrokerOutcome(
                        capability,
                        "rejected",
                        "capability_not_allowed",
                    )
                else:
                    try:
                        outcome = self._perform_broker_action(
                            capability,
                            incident=incident,
                            process_identity=process_identity,
                            recovery_generation=generation,
                            attempt=capability_attempt,
                            deadline=deadline,
                        )
                    except Exception as error:  # noqa: BLE001 - broker internals stay private.
                        print(
                            f"[continuity-agent] recovery broker failed ({type(error).__name__})",
                            file=sys.stderr,
                        )
                        outcome = RecoveryBrokerOutcome(
                            capability,
                            "failed",
                            "broker_call_failed",
                        )
                history.append(outcome.as_dict())
                self._audit(
                    incident,
                    process_identity,
                    session.provider,
                    phase="broker_outcome",
                    attempt=sequence,
                    outcome=outcome,
                )
                if (
                    outcome.health.objective_restored
                    and outcome.health.stable_for_seconds >= self.config.stable_health_seconds
                ):
                    final_result = "restored"
                    break
                if outcome.status == "authorization_required":
                    final_result = "authorization_required"
                    break
                if outcome.status == "circuit_open" and outcome.outcome_code in {
                    "recovery_budget_exhausted",
                    "broker_call_timed_out",
                    "recovery_health_worsened",
                    "ephemeral_cleanup_unavailable",
                    "ephemeral_cleanup_failed",
                }:
                    break
        except Exception as error:  # noqa: BLE001 - parent lane failure becomes sanitized state.
            print(
                f"[continuity-agent] recovery lane failed ({type(error).__name__})",
                file=sys.stderr,
            )
        finally:
            try:
                session.shutdown()
            except Exception:  # noqa: BLE001 - terminal audit still needs to be written.
                pass
            self._audit(
                incident,
                process_identity,
                session.provider,
                phase="completed",
                attempt=len(history),
                final_result=final_result,
            )
            with self._lock:
                self._cooldowns[fingerprint] = self._monotonic() + self.config.cooldown_seconds
                self._active_incident = None
                self._active_session = None
                self._idle.set()

    def _perform_broker_action(
        self,
        capability: str,
        *,
        incident: Mapping[str, object],
        process_identity: str,
        recovery_generation: str,
        attempt: int,
        deadline: float,
    ) -> RecoveryBrokerOutcome:
        remaining = deadline - self._monotonic()
        if remaining <= 0:
            return RecoveryBrokerOutcome(
                capability,
                "circuit_open",
                "broker_call_timed_out",
            )
        cancel_event = threading.Event()
        outcomes: list[RecoveryBrokerOutcome] = []
        errors: list[Exception] = []

        def perform() -> None:
            try:
                outcome = self._broker.perform(
                    capability,
                    incident=incident,
                    process_identity=process_identity,
                    recovery_generation=recovery_generation,
                    attempt=attempt,
                    deadline=deadline,
                    cancel_event=cancel_event,
                )
                if not isinstance(outcome, RecoveryBrokerOutcome):
                    raise ValueError("broker returned an invalid outcome")
                outcomes.append(outcome)
            except Exception as error:  # noqa: BLE001 - re-raised on the lane thread.
                errors.append(error)
        broker_thread = threading.Thread(
            target=perform,
            name=f"relay-continuity-broker-{capability}",
            daemon=True,
        )
        with self._lock:
            self._active_broker_cancel = cancel_event
            if self._shutdown.is_set():
                cancel_event.set()
        timed_out = False
        try:
            broker_thread.start()
            remaining = max(0.0, deadline - self._monotonic())
            broker_thread.join(timeout=remaining)
            timed_out = broker_thread.is_alive()
            if timed_out:
                cancel_event.set()
                broker_thread.join()
        finally:
            with self._lock:
                if self._active_broker_cancel is cancel_event:
                    self._active_broker_cancel = None
        if timed_out:
            return RecoveryBrokerOutcome(
                capability,
                "circuit_open",
                "broker_call_timed_out",
            )
        if errors:
            raise errors[0]
        return outcomes[0]

    @staticmethod
    def _validated_capabilities(capabilities: tuple[str, ...]) -> tuple[str, ...]:
        if not capabilities or any(not _CODE_RE.fullmatch(item) for item in capabilities):
            raise ValueError("recovery broker exposed invalid capabilities")
        return tuple(dict.fromkeys(capabilities))

    @staticmethod
    def _parse_decision(raw: str) -> dict[str, str]:
        try:
            decision = json.loads(raw)
        except (json.JSONDecodeError, TypeError) as error:
            raise ValueError("continuity agent returned invalid JSON") from error
        if not isinstance(decision, dict) or set(decision) - {"kind", "capability", "result"}:
            raise ValueError("continuity agent returned an invalid decision")
        if decision.get("kind") == "finish" and decision.get("result") == "escalate":
            return {"kind": "finish", "result": "escalate"}
        capability = decision.get("capability")
        if decision.get("kind") != "broker_call" or not isinstance(capability, str):
            raise ValueError("continuity agent returned an invalid broker request")
        if not _CODE_RE.fullmatch(capability):
            raise ValueError("continuity agent returned an invalid capability")
        return {"kind": "broker_call", "capability": capability}

    @staticmethod
    def _prompt(
        incident: Mapping[str, object],
        capabilities: tuple[str, ...],
        history: list[dict[str, object]],
        sequence: int,
        capability_attempts: Mapping[str, int],
    ) -> str:
        payload = {
            "incident": incident,
            "broker_objective": {
                "name": "restore_processing",
                **dict(incident["recovery_objective"]),
            },
            "broker_capabilities": list(capabilities),
            "sanitized_outcomes": history,
            "sequence": sequence,
            "capability_attempts": dict(capability_attempts),
        }
        return CONTINUITY_SYSTEM_PROMPT + "\n\nRecovery state:\n" + json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
        )

    def _audit(
        self,
        incident: Mapping[str, object],
        process_identity: str,
        provider: str,
        *,
        phase: str,
        attempt: int,
        outcome: RecoveryBrokerOutcome | None = None,
        final_result: str | None = None,
    ) -> None:
        record: dict[str, object] = {
            "schema_version": SCHEMA_VERSION,
            "recorded_at": time.time(),
            "incident_id": incident["incident_id"],
            "fingerprint": incident["fingerprint"],
            "actor_role": ACTOR_ROLE,
            "process_identity": process_identity,
            "provider": provider,
            "recovery_generation": incident["recovery_generation"],
            "phase": phase,
            "attempt": attempt,
        }
        if outcome is not None:
            record["broker_outcome"] = outcome.as_dict()
        if final_result is not None:
            record["final_result"] = final_result
        try:
            self._on_audit(record)
        except Exception as error:  # noqa: BLE001 - audit failure cannot strand the lane.
            print(
                f"[continuity-agent] audit callback failed ({type(error).__name__})",
                file=sys.stderr,
            )


def append_audit_record(path: Path, record: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(path, 0o600)
