"""Deterministic provider-turn faults against the production adapters."""

from __future__ import annotations

from contextlib import contextmanager
import io
import json
import math
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import time
from typing import Any, Iterator

from intent_inbox import IntentInbox
from messenger import MessengerRuntime
from provider_turn_broker import EffectReservation, ProviderTurnBroker
import relay_completion_hook
from speech_coordinator import SpeechCoordinator
import voice_bridge


PROVIDERS = ("codex", "claude")
PYTHON_RESTART_COMPONENTS = (
    "messenger",
    "foreground_provider",
    "daemon",
    "bridge",
)
RESTART_COMPONENTS = (*PYTHON_RESTART_COMPONENTS, "swift")
LIFECYCLE_BOUNDARIES = (
    "accepted",
    "delivered",
    "claimed",
    "acknowledgement_delayed",
    "acknowledged",
    "terminal",
    "effect_reserved",
)
DIAGNOSTIC_FIELDS = frozenset({
    "provider",
    "restart_component",
    "lifecycle_boundary",
    "invariant",
    "expected",
    "observed",
})
_OWNERSHIP_ENVIRONMENT = {
    "RELAY_APP_SESSION_ID": "fault-matrix-app",
    "RELAY_RECOVERY_GENERATION": "fault-matrix-generation",
    "RELAY_ACTOR_ROLE": "foreground_pm",
    "RELAY_FOREGROUND_GATE_HANDLE": "fault-matrix-gate",
}


def _finite_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def _observed_latency_ms(acknowledged_at: Any, playback_at: Any) -> float | None:
    start = _finite_float(acknowledged_at)
    end = _finite_float(playback_at)
    if start is None or end is None or end < start:
        return None
    latency = (end - start) * 1_000
    return round(latency, 3) if math.isfinite(latency) else None


def _same_invariant_value(expected: Any, observed: Any) -> bool:
    """Compare counts without allowing Python's True == 1 coercion."""
    if isinstance(expected, int) and not isinstance(expected, bool):
        return (
            isinstance(observed, int)
            and not isinstance(observed, bool)
            and expected == observed
        )
    if isinstance(expected, bool):
        return isinstance(observed, bool) and expected == observed
    return expected == observed


@contextmanager
def _provider_environment(provider: str) -> Iterator[None]:
    updates = {
        **_OWNERSHIP_ENVIRONMENT,
        "RELAY_RUNNER_PROVIDER": provider,
        "RELAY_PROVIDER_SESSION_ID": f"provider-session-{provider}",
    }
    previous = {name: os.environ.get(name) for name in updates}
    os.environ.update(updates)
    try:
        yield
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


class _SilentMessengerBackend:
    """Deterministic backend used by the production MessengerRuntime."""

    def __init__(self) -> None:
        self.started = False
        self.shutdown_count = 0

    def start(self) -> None:
        self.started = True

    def ask(self, _prompt: str, timeout: float = 60.0) -> str:
        del timeout
        return "__SILENT__"

    def interrupt(self) -> None:
        return None

    def shutdown(self) -> None:
        self.shutdown_count += 1
        self.started = False


class _MessengerAdapter:
    def __init__(self, command: dict[str, Any]) -> None:
        self.command = command
        self.backend = _SilentMessengerBackend()
        self.runtime = MessengerRuntime(
            self.backend,
            speak=lambda *_args, **_kwargs: None,
            is_current=lambda seq, command_id: (
                seq == command["relay_command_seq"]
                and command_id == command["relay_command_id"]
            ),
        )
        self.runtime.start()
        if not self.runtime.submit_user("private fault fixture", command):
            raise AssertionError("MessengerRuntime rejected the accepted command")

    def restart(self) -> tuple[_MessengerAdapter, dict[str, Any]]:
        old_runtime = self.runtime
        old_backend = self.backend
        self.runtime.shutdown()
        replacement = _MessengerAdapter(self.command)
        return replacement, {
            "instance_replaced": replacement.runtime is not old_runtime,
            "adapter": type(replacement.runtime).__name__,
            "closed_previous": old_backend.shutdown_count == 1,
        }

    def close(self) -> None:
        self.runtime.shutdown()


class _CompletionAdapter:
    def __init__(self, scenario: _Scenario) -> None:
        self.scenario = scenario
        self.provider_events: list[dict[str, Any]] = []

    def prompt_submitted(self) -> bool:
        payload = {
            "hook_event_name": "UserPromptSubmit",
            "session_id": self.scenario.command["session_id"],
            "turn_id": self.scenario.command["turn_id"],
            "provider_session_id": self.scenario.command["provider_session_id"],
            "prompt": "private fault fixture",
        }
        with _provider_environment(self.scenario.provider):
            return relay_completion_hook.handle_hook_payload(
                payload,
                claim_path=str(self.scenario.claim_path),
                state_path=str(self.scenario.state_path),
                turns_path=str(self.scenario.turns_path),
                write_provider_event=(
                    lambda event: self.provider_events.append(event) or True
                ),
                stderr=io.StringIO(),
            )

    def completed(self) -> tuple[bool, dict[str, Any] | None]:
        delivered: list[dict[str, Any]] = []
        payload = {
            "hook_event_name": "Stop",
            "session_id": self.scenario.command["session_id"],
            "turn_id": self.scenario.command["turn_id"],
            "provider_session_id": self.scenario.command["provider_session_id"],
            "last_assistant_message": "bounded final",
        }
        with _provider_environment(self.scenario.provider):
            handled = relay_completion_hook.handle_hook_payload(
                payload,
                state_path=str(self.scenario.state_path),
                turns_path=str(self.scenario.turns_path),
                write_control=lambda result: delivered.append(result) or True,
                stderr=io.StringIO(),
            )
        return handled, delivered[0] if delivered else None


class _ObservedSpeechWorker:
    """Runs the real SpeechCoordinator callback path without physical audio."""

    def __init__(self) -> None:
        self.input_queue: queue.Queue[dict[str, Any]] = queue.Queue()
        self.eligibility = None
        self.observer = None
        self.playback_count = 0

    def set_speech_callbacks(self, *, eligibility, observer) -> None:
        self.eligibility = eligibility
        self.observer = observer

    def play(self) -> None:
        payload = self.input_queue.get_nowait()
        intent = dict(payload.get("_speech_intent") or {})
        if self.eligibility is None or not self.eligibility(intent):
            raise AssertionError("SpeechCoordinator rejected its committed intent")
        self.playback_count += 1
        if self.observer is None:
            raise AssertionError("SpeechCoordinator observer was not installed")
        self.observer("afplay_started", intent)

    def skip(self) -> None:
        return None

    def stop_playback(self, *, reason: str = "user_stop") -> None:
        del reason

    def reload_config(self) -> None:
        return None

    def shutdown(self) -> None:
        return None


class _Scenario:
    def __init__(self, root: Path, provider: str, suffix: str):
        self.provider = provider
        self.root = root / f"{provider}-{suffix}"
        self.root.mkdir()
        self.turns_path = self.root / "voice_provider_turns.json"
        self.database = Path(str(self.turns_path) + ".sqlite3")
        self.projection = Path(str(self.turns_path) + ".v2.json")
        self.command_path = self.root / "voice_cmd_ready"
        self.metadata_path = self.root / "voice_cmd_ready.meta"
        self.claim_path = self.root / "voice_cmd_claimed.json"
        self.state_path = self.root / "voice_command_state.json"
        self.speech_log = self.root / "relay_speech_events.jsonl"
        self.command = {
            "app_session_id": _OWNERSHIP_ENVIRONMENT["RELAY_APP_SESSION_ID"],
            "recovery_generation": _OWNERSHIP_ENVIRONMENT["RELAY_RECOVERY_GENERATION"],
            "actor_role": _OWNERSHIP_ENVIRONMENT["RELAY_ACTOR_ROLE"],
            "foreground_gate_handle": _OWNERSHIP_ENVIRONMENT[
                "RELAY_FOREGROUND_GATE_HANDLE"
            ],
            "provider": provider,
            "provider_session_id": f"provider-session-{provider}",
            "session_id": f"native-session-{provider}",
            "turn_id": f"native-turn-{provider}-{suffix}",
            "intent_id": f"intent-{provider}-{suffix}",
            "relay_command_seq": 1,
            "relay_command_id": f"command-{provider}-{suffix}",
            "origin": "relay",
            "agent_prompt": "private fault fixture",
            "created_at": time.time(),
        }
        self.inbox = self._open_inbox()
        self.broker = self._open_broker()
        self.messenger = _MessengerAdapter(self.command)
        self.completion = _CompletionAdapter(self)
        self._open_speech_bridge()
        self.stored = self.inbox.enqueue(
            "private fault fixture",
            self.command,
            "continue_current",
        )
        self.final_payload: dict[str, Any] | None = None
        self.provider_bound = False

    def _open_inbox(self) -> IntentInbox:
        return IntentInbox(
            self.database,
            provider_turn_projection_path=self.projection,
        )

    def _open_broker(self) -> ProviderTurnBroker:
        return ProviderTurnBroker(self.database, projection_path=self.projection)

    def _open_speech_bridge(self) -> None:
        self.speech_worker = _ObservedSpeechWorker()
        self.speech = SpeechCoordinator(
            self.speech_worker,
            is_current=lambda seq, command_id: (
                seq == self.command["relay_command_seq"]
                and command_id == self.command["relay_command_id"]
            ),
            event_log_path=self.speech_log,
        )

    def _durable_identity_recovered(self) -> bool:
        intent = next(
            record
            for record in self.inbox.records()
            if record["intent_id"] == self.command["intent_id"]
        )
        turns = self.broker.table_records("provider_turns")
        return (
            intent["command_seq"] == self.command["relay_command_seq"]
            and intent["command_id"] == self.command["relay_command_id"]
            and all(
                record["command_seq"] == self.command["relay_command_seq"]
                and record["command_id"] == self.command["relay_command_id"]
                for record in turns
            )
        )

    def restart(self, component: str, boundary: str) -> dict[str, Any]:
        del boundary
        if component == "messenger":
            self.messenger, evidence = self.messenger.restart()
        elif component == "foreground_provider":
            previous = self.completion
            self.completion = _CompletionAdapter(self)
            evidence = {
                "instance_replaced": self.completion is not previous,
                "adapter": "relay_completion_hook",
                "closed_previous": True,
            }
        elif component == "daemon":
            previous = self.inbox
            previous.close()
            self.inbox = self._open_inbox()
            evidence = {
                "instance_replaced": self.inbox is not previous,
                "adapter": type(self.inbox).__name__,
                "closed_previous": True,
            }
        elif component == "bridge":
            previous_broker = self.broker
            previous_speech = self.speech
            previous_broker.close()
            previous_speech.shutdown()
            self.broker = self._open_broker()
            self._open_speech_bridge()
            evidence = {
                "instance_replaced": (
                    self.broker is not previous_broker
                    and self.speech is not previous_speech
                ),
                "adapter": "ProviderTurnBroker+SpeechCoordinator",
                "closed_previous": True,
            }
        else:
            raise ValueError(f"unsupported Python restart component: {component}")
        evidence["identity_recovered"] = self._durable_identity_recovered()
        return evidence

    def deliver(self) -> None:
        materialized = self.inbox.materialize_next(
            command_path=str(self.command_path),
            metadata_path=str(self.metadata_path),
            transport="fault_matrix",
        )
        if materialized is not None:
            self.stored = materialized
        self.state_path.write_text(json.dumps(self.stored, sort_keys=True))
        self.claim_path.write_text(json.dumps(self.stored, sort_keys=True))

    def claim(self, *, acknowledged: bool) -> None:
        claimed = {**self.command, **self.stored}
        if not self.provider_bound:
            if not self.completion.prompt_submitted():
                raise AssertionError("completion hook did not bind the provider prompt")
            self.provider_bound = True
        if not self.inbox.observe_claim(claimed, provider_turn_seen=acknowledged):
            raise AssertionError("claim identity was not observed")

    def delay_acknowledgement(self) -> bool:
        row = next(
            record
            for record in self.inbox.records()
            if record["intent_id"] == self.command["intent_id"]
        )
        recovered_claim = (
            row["state"] in {"pending", "review_required"}
            and row["claimed_at"] is not None
            and row["recovered_at"] is not None
        )
        return row["acked_at"] is None and (
            row["state"] == "claimed" or recovered_claim
        )

    def complete(self) -> None:
        handled, payload = self.completion.completed()
        if not handled or payload is None:
            raise AssertionError("completion hook did not emit the terminal payload")
        duplicate, _ = self.completion.completed()
        if duplicate:
            raise AssertionError("duplicate terminal callback was accepted")
        self.final_payload = payload

    def reserve_effect(self) -> EffectReservation:
        if self.final_payload is None:
            raise AssertionError("effect cannot be reserved before provider completion")
        return self.broker.reserve_effect(self.final_payload)

    def _submit_speech(self) -> bool:
        if self.final_payload is None:
            raise AssertionError("effect cannot play before provider completion")
        command = self.final_payload.get("relay_command")
        if not isinstance(command, dict):
            command = self.final_payload
        self.speech.note_play_control()
        delivered = voice_bridge._queue_tts_text(
            json.dumps({
                **command,
                "text": self.final_payload["text"],
                "display_text": self.final_payload["text"],
            }),
            self.speech.input_queue,
            state_path=str(self.state_path),
            allow_pending_command=True,
            notify_waiting_preview=lambda _text: None,
            source="orchestrator",
            kind="final",
            authoritative=True,
            semantic_brief="bounded final",
            replayable=True,
        )
        if delivered:
            self.speech.play()
        return delivered

    def deliver_effect(self, *, reserved: EffectReservation | None = None) -> bool:
        voice_bridge._reset_foreground_reply_delivery_for_tests()
        if reserved is None:
            if self.final_payload is None:
                raise AssertionError("missing completion payload")
            delivered = voice_bridge._handle_orchestrator_reply_control(
                json.dumps(self.final_payload),
                tts_worker=self.speech,
                messenger=None,
                state_path=str(self.state_path),
                provider_turn_broker=self.broker,
            )
            if delivered:
                self.speech.note_play_control()
                self.speech.play()
            return delivered
        if reserved.effect_id is None:
            return False
        if not self.broker.authorize_effect_delivery(reserved.effect_id):
            self.broker.finish_effect(reserved.effect_id, delivered=False)
            return False
        delivered = self._submit_speech()
        self.broker.finish_effect(reserved.effect_id, delivered=delivered)
        return delivered

    def observed_latency_ms(self) -> float | None:
        intent = next(
            record
            for record in self.inbox.records()
            if record["intent_id"] == self.command["intent_id"]
        )
        playback_records = [
            json.loads(line)
            for line in self.speech_log.read_text().splitlines()
            if line.strip()
        ] if self.speech_log.exists() else []
        playback = [
            record
            for record in playback_records
            if record.get("event") == "afplay_started"
            and record.get("relay_command_seq") == self.command["relay_command_seq"]
            and record.get("relay_command_id") == self.command["relay_command_id"]
        ]
        if len(playback) != 1:
            return None
        return _observed_latency_ms(intent["acked_at"], playback[0].get("at"))

    def close(self) -> None:
        self.messenger.close()
        self.speech.shutdown()
        self.inbox.close()
        self.broker.close()


def _diagnostic(
    *,
    provider: str,
    component: str,
    boundary: str,
    invariant: str,
    expected: Any,
    observed: Any,
) -> dict[str, Any]:
    return {
        "provider": provider,
        "restart_component": component,
        "lifecycle_boundary": boundary,
        "invariant": invariant,
        "expected": expected,
        "observed": observed,
    }


def _check_normal_case(
    root: Path,
    provider: str,
    component: str,
    boundary: str,
) -> tuple[list[dict[str, Any]], float | None, bool]:
    scenario = _Scenario(root, provider, f"{component}-{boundary}")
    violations: list[dict[str, Any]] = []
    try:
        evidence: dict[str, Any] | None = None
        if boundary == "accepted":
            evidence = scenario.restart(component, boundary)
        scenario.deliver()
        if boundary == "delivered":
            evidence = scenario.restart(component, boundary)
        scenario.claim(acknowledged=False)
        if boundary == "claimed":
            evidence = scenario.restart(component, boundary)
        delayed = scenario.delay_acknowledgement()
        if boundary == "acknowledgement_delayed":
            evidence = scenario.restart(component, boundary)
        scenario.claim(acknowledged=True)
        if boundary == "acknowledged":
            evidence = scenario.restart(component, boundary)
        scenario.complete()
        if boundary == "terminal":
            evidence = scenario.restart(component, boundary)

        reserved = None
        if boundary == "effect_reserved":
            reserved = scenario.reserve_effect()
            evidence = scenario.restart(component, boundary)
        delivered = scenario.deliver_effect(reserved=reserved)
        competing = scenario.reserve_effect()

        transitions = scenario.broker.table_records("provider_turn_transitions")
        effects = scenario.broker.table_records("provider_turn_effects")
        counts = {
            event: sum(row["event_type"] == event for row in transitions)
            for event in ("intent_claimed", "intent_acknowledged", "provider_completed")
        }
        restart_recovered = bool(
            evidence
            and evidence["instance_replaced"]
            and evidence["closed_previous"]
            and evidence["identity_recovered"]
        )
        checks = {
            "restart_recovered_real_adapter": (True, restart_recovered),
            "delayed_acknowledgement_observed": (True, delayed),
            "one_claim": (1, counts["intent_claimed"]),
            "one_terminal_acknowledgement": (1, counts["intent_acknowledged"]),
            "one_provider_terminal": (1, counts["provider_completed"]),
            "one_user_visible_effect": (1, len(effects)),
            "competing_output_rejected": (False, competing.accepted),
            "effect_delivered": ("delivered", effects[0]["state"] if effects else None),
            "speech_playback_observed": (True, delivered),
            "one_speech_playback": (1, scenario.speech_worker.playback_count),
        }
        for invariant, (expected, observed) in checks.items():
            if not _same_invariant_value(expected, observed):
                violations.append(_diagnostic(
                    provider=provider,
                    component=component,
                    boundary=boundary,
                    invariant=invariant,
                    expected=expected,
                    observed=observed,
                ))
        latency_ms = scenario.observed_latency_ms()
        if latency_ms is None:
            violations.append(_diagnostic(
                provider=provider,
                component=component,
                boundary=boundary,
                invariant="finite_observed_acknowledgement_to_playback",
                expected=True,
                observed=False,
            ))
        return violations, latency_ms, restart_recovered
    finally:
        scenario.close()


def _advance_to(scenario: _Scenario, boundary: str) -> None:
    if boundary == "accepted":
        return
    scenario.deliver()
    if boundary == "delivered":
        return
    scenario.claim(acknowledged=False)
    if boundary == "claimed":
        return
    scenario.delay_acknowledgement()
    if boundary == "acknowledgement_delayed":
        return
    scenario.claim(acknowledged=True)
    if boundary == "acknowledged":
        return
    scenario.complete()


def _check_revocation_case(
    root: Path,
    provider: str,
    boundary: str,
) -> list[dict[str, Any]]:
    scenario = _Scenario(root, provider, f"revoked-{boundary}")
    try:
        _advance_to(scenario, boundary)
        reserved = scenario.reserve_effect() if boundary == "effect_reserved" else None
        cancelled = scenario.inbox.cancel_scoped({
            "intent_id": f"cancel-{provider}-{boundary}",
            "cancellation_scope": "item",
            "target_intent_ids": [scenario.command["intent_id"]],
        })
        if reserved is not None:
            scenario.deliver_effect(reserved=reserved)
        reservation = reserved or scenario.broker.reserve_effect(scenario.command)
        effects = scenario.broker.table_records("provider_turn_effects")
        checks = {"revocation_applied": ([scenario.command["intent_id"]], cancelled)}
        if boundary == "effect_reserved":
            checks.update({
                "effect_reserved_before_revocation": (True, reservation.accepted),
                "revoked_reserved_effect_failed": (
                    "failed",
                    effects[0]["state"] if effects else None,
                ),
                "no_revoked_delivered_effect": (
                    0,
                    sum(effect["state"] == "delivered" for effect in effects),
                ),
            })
        else:
            checks.update({
                "late_effect_rejected": (False, reservation.accepted),
                "late_effect_reason": (
                    "turn_missing" if boundary in {"accepted", "delivered"} else "turn_revoked",
                    reservation.reason,
                ),
                "no_revoked_effect": (0, len(effects)),
            })
        return [
            _diagnostic(
                provider=provider,
                component="cancellation",
                boundary=boundary,
                invariant=invariant,
                expected=expected,
                observed=observed,
            )
            for invariant, (expected, observed) in checks.items()
            if not _same_invariant_value(expected, observed)
        ]
    finally:
        scenario.close()


def _check_replacement_case(
    root: Path,
    provider: str,
    boundary: str,
) -> list[dict[str, Any]]:
    scenario = _Scenario(root, provider, f"replaced-{boundary}")
    try:
        _advance_to(scenario, boundary)
        reserved = scenario.reserve_effect() if boundary == "effect_reserved" else None
        cancelled_count = (
            len(scenario.inbox.cancel_scoped({
                "intent_id": f"replacement-{provider}-{boundary}",
                "cancellation_scope": "item",
                "target_intent_ids": [scenario.command["intent_id"]],
            }))
            if boundary == "effect_reserved"
            else scenario.inbox.cancel_pending_before(
                2,
                reason="replaced_by_newer_command",
            )
        )
        if reserved is not None:
            scenario.deliver_effect(reserved=reserved)
        reservation = reserved or scenario.broker.reserve_effect(scenario.command)
        effects = scenario.broker.table_records("provider_turn_effects")
        checks = {"replacement_revoked_older_turn": (1, cancelled_count)}
        if boundary == "effect_reserved":
            checks.update({
                "replacement_effect_reserved_before_revocation": (
                    True,
                    reservation.accepted,
                ),
                "replacement_reserved_effect_failed": (
                    "failed",
                    effects[0]["state"] if effects else None,
                ),
                "replacement_has_no_delivered_effect": (
                    0,
                    sum(effect["state"] == "delivered" for effect in effects),
                ),
            })
        else:
            checks.update({
                "replaced_turn_late_effect_rejected": (False, reservation.accepted),
                "replaced_turn_reason": (
                    "turn_missing" if boundary == "accepted" else "turn_revoked",
                    reservation.reason,
                ),
            })
        return [
            _diagnostic(
                provider=provider,
                component="replacement",
                boundary=boundary,
                invariant=invariant,
                expected=expected,
                observed=observed,
            )
            for invariant, (expected, observed) in checks.items()
            if not _same_invariant_value(expected, observed)
        ]
    finally:
        scenario.close()


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    finite = [_finite_float(value) for value in values]
    if any(value is None for value in finite):
        return None
    ordered = sorted(value for value in finite if value is not None)
    index = max(0, math.ceil((percentile / 100) * len(ordered)) - 1)
    return round(ordered[index], 3)


def _run_swift_projection_matrix(root: Path) -> dict[str, Any]:
    evidence_path = root / "swift-provider-turn-fault-evidence.json"
    environment = dict(os.environ)
    environment["RR325_SWIFT_EVIDENCE_PATH"] = str(evidence_path)
    repository = Path(__file__).resolve().parent.parent
    try:
        result = subprocess.run(
            [
                "swift",
                "test",
                "--skip-build",
                "--filter",
                "RelayVoiceCommandDeliveryTests/testRestartFaultMatrixEmitsEvidence",
            ],
            cwd=repository,
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "passed": False,
            "case_count": 0,
            "adapter": "RelayVoiceCommandDelivery",
            "failure": "swift_test_timeout",
        }
    if result.returncode != 0:
        return {
            "passed": False,
            "case_count": 0,
            "adapter": "RelayVoiceCommandDelivery",
            "failure": f"swift_test_exit_{result.returncode}",
        }
    try:
        evidence = json.loads(evidence_path.read_text())
    except (OSError, json.JSONDecodeError, TypeError):
        return {
            "passed": False,
            "case_count": 0,
            "adapter": "RelayVoiceCommandDelivery",
            "failure": "missing_or_malformed_swift_evidence",
        }
    return evidence if isinstance(evidence, dict) else {
        "passed": False,
        "case_count": 0,
        "adapter": "RelayVoiceCommandDelivery",
        "failure": "invalid_swift_evidence_shape",
    }


def _validate_swift_evidence(evidence: dict[str, Any]) -> list[dict[str, Any]]:
    expected_count = len(PROVIDERS) * len(LIFECYCLE_BOUNDARIES)
    checks = {
        "swift_projection_adapter": (
            "RelayVoiceCommandDelivery",
            evidence.get("adapter"),
        ),
        "swift_provider_parity": (list(PROVIDERS), evidence.get("providers")),
        "swift_boundary_parity": (
            list(LIFECYCLE_BOUNDARIES),
            evidence.get("lifecycle_boundaries"),
        ),
        "swift_restart_case_count": (expected_count, evidence.get("case_count")),
        "swift_restart_matrix_passed": (True, evidence.get("passed")),
    }
    return [
        _diagnostic(
            provider="all",
            component="swift",
            boundary="all",
            invariant=invariant,
            expected=expected,
            observed=observed,
        )
        for invariant, (expected, observed) in checks.items()
        if not _same_invariant_value(expected, observed)
    ]


def run_fault_matrix(
    root: Path,
    *,
    swift_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Run provider-parity adapter restarts, revocation, and real-path latency."""
    violations: list[dict[str, Any]] = []
    latencies: list[float] = []
    restart_recovery_count = 0
    python_scenario_count = (
        len(PROVIDERS) * len(PYTHON_RESTART_COMPONENTS) * len(LIFECYCLE_BOUNDARIES)
    )
    for provider in PROVIDERS:
        for component in PYTHON_RESTART_COMPONENTS:
            for boundary in LIFECYCLE_BOUNDARIES:
                case_violations, latency, restart_recovered = _check_normal_case(
                    root,
                    provider,
                    component,
                    boundary,
                )
                violations.extend(case_violations)
                if latency is not None:
                    latencies.append(latency)
                restart_recovery_count += int(restart_recovered)
        for boundary in LIFECYCLE_BOUNDARIES:
            violations.extend(_check_revocation_case(root, provider, boundary))
        for boundary in ("accepted", "effect_reserved"):
            violations.extend(_check_replacement_case(root, provider, boundary))

    swift_evidence = swift_evidence or _run_swift_projection_matrix(root)
    swift_violations = _validate_swift_evidence(swift_evidence)
    violations.extend(swift_violations)
    swift_case_count = int(swift_evidence.get("case_count") or 0)
    if not swift_violations:
        restart_recovery_count += swift_case_count

    if len(latencies) != python_scenario_count:
        violations.append(_diagnostic(
            provider="all",
            component="normal_path",
            boundary="acknowledged",
            invariant="finite_observed_latency_sample_count",
            expected=python_scenario_count,
            observed=len(latencies),
        ))
        p95_ms = None
    else:
        p95_ms = _percentile(latencies, 95)
    if p95_ms is not None and p95_ms > 500:
        violations.append(_diagnostic(
            provider="all",
            component="normal_path",
            boundary="acknowledged",
            invariant="acknowledgement_to_playback_p95_ms",
            expected="<=500",
            observed=p95_ms,
        ))
    normal_scenario_count = python_scenario_count + len(PROVIDERS) * len(LIFECYCLE_BOUNDARIES)
    return {
        "schema_version": 2,
        "providers": list(PROVIDERS),
        "restart_components": list(RESTART_COMPONENTS),
        "lifecycle_boundaries": list(LIFECYCLE_BOUNDARIES),
        "normal_scenario_count": normal_scenario_count,
        "python_scenario_count": python_scenario_count,
        "swift_scenario_count": swift_case_count,
        "restart_recovery_count": restart_recovery_count,
        "delayed_acknowledgement_scenario_count": (
            len(PROVIDERS) * len(PYTHON_RESTART_COMPONENTS)
        ),
        "revocation_scenario_count": len(PROVIDERS) * len(LIFECYCLE_BOUNDARIES),
        "replacement_scenario_count": len(PROVIDERS) * 2,
        "acknowledgement_to_playback_sample_count": len(latencies),
        "acknowledgement_to_playback_p95_ms": p95_ms,
        "passed": not violations,
        "violations": violations[:100],
    }


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        report = run_fault_matrix(Path(temp_dir))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
