"""Deterministic provider-turn restart and single-effect fault matrix."""

from __future__ import annotations

import json
import math
from pathlib import Path
import tempfile
from typing import Any

from intent_inbox import IntentInbox
from provider_turn_broker import EffectReservation, ProviderTurnBroker


PROVIDERS = ("codex", "claude")
RESTART_COMPONENTS = ("messenger", "foreground_provider", "daemon", "bridge", "swift")
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
_RUNTIME_IDENTITY_FIELDS = (
    "app_session_id",
    "recovery_generation",
    "actor_role",
    "foreground_gate_handle",
    "provider",
    "provider_session_id",
    "session_id",
    "turn_id",
    "intent_id",
    "relay_command_seq",
    "relay_command_id",
    "origin",
    "created_at",
)


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


class _ComponentRuntime:
    """File-backed process surrogate with volatile generation and durable identity."""

    def __init__(self, path: Path, component: str):
        self.path = path
        self.component = component
        self.closed = False
        try:
            state = json.loads(path.read_text())
        except FileNotFoundError:
            state = {
                "schema_version": 1,
                "component": component,
                "generation": 1,
                "restart_count": 0,
                "last_boundary": None,
                "recovered_boundary": None,
                "identity": {},
            }
        if state.get("component") != component:
            raise AssertionError("component recovery state identity mismatch")
        self.state = state

    @property
    def generation(self) -> int:
        value = self.state.get("generation")
        if not isinstance(value, int) or isinstance(value, bool):
            raise AssertionError("component generation is not an integer")
        return value

    def _write(self) -> None:
        if self.closed:
            raise AssertionError("closed component runtime used")
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state, sort_keys=True))
        temporary.replace(self.path)

    def checkpoint(self, boundary: str, command: dict[str, Any]) -> None:
        self.state["last_boundary"] = boundary
        self.state["identity"] = {
            field: command[field]
            for field in _RUNTIME_IDENTITY_FIELDS
            if field in command
        }
        self._write()

    def recovered_command(self) -> dict[str, Any]:
        if self.closed:
            raise AssertionError("closed component runtime used")
        identity = self.state.get("identity")
        if not isinstance(identity, dict) or not identity:
            raise AssertionError("component did not recover command identity")
        return dict(identity)

    def restart(self, boundary: str) -> tuple[_ComponentRuntime, dict[str, Any]]:
        before_generation = self.generation
        self.closed = True
        reopened = _ComponentRuntime(self.path, self.component)
        recovered_boundary = reopened.state.get("last_boundary")
        reopened.state["generation"] = before_generation + 1
        reopened.state["restart_count"] = int(reopened.state.get("restart_count") or 0) + 1
        reopened.state["recovered_boundary"] = recovered_boundary
        reopened._write()
        return reopened, {
            "instance_replaced": reopened is not self,
            "before_generation": before_generation,
            "after_generation": reopened.generation,
            "recovered_boundary": recovered_boundary,
            "requested_boundary": boundary,
        }


class _Scenario:
    def __init__(self, root: Path, provider: str, suffix: str):
        self.provider = provider
        self.root = root / f"{provider}-{suffix}"
        self.root.mkdir()
        self.database = self.root / "inbox.sqlite3"
        self.projection = self.root / "provider-turns.json"
        self.command_path = self.root / "voice_cmd_ready"
        self.metadata_path = self.root / "voice_cmd_ready.meta"
        self.clock = 100.0
        self.command = {
            "app_session_id": "app-session",
            "recovery_generation": "generation-1",
            "actor_role": "foreground_pm",
            "foreground_gate_handle": "gate-1",
            "provider": provider,
            "provider_session_id": f"provider-session-{provider}",
            "session_id": f"native-session-{provider}",
            "turn_id": f"native-turn-{provider}",
            "intent_id": f"intent-{provider}-{suffix}",
            "relay_command_seq": 1,
            "relay_command_id": f"command-{provider}-{suffix}",
            "origin": "relay",
            "created_at": self.clock,
        }
        self.runtimes = {
            component: _ComponentRuntime(self.root / f"{component}.json", component)
            for component in RESTART_COMPONENTS
        }
        self.inbox = self._open_inbox()
        self.broker = self._open_broker()
        self.stored = self.inbox.enqueue("private fixture", self.command, "continue_current")
        if not self.broker.activate(self.command, now=self.clock):
            raise AssertionError("accepted turn was not activated")
        self._checkpoint("accepted")

    def _open_inbox(self) -> IntentInbox:
        return IntentInbox(
            self.database,
            provider_turn_projection_path=self.projection,
        )

    def _open_broker(self) -> ProviderTurnBroker:
        return ProviderTurnBroker(self.database, projection_path=self.projection)

    def _checkpoint(self, boundary: str) -> None:
        for runtime in self.runtimes.values():
            runtime.checkpoint(boundary, self.command)

    def _recovered_command(self) -> dict[str, Any]:
        recovered = [runtime.recovered_command() for runtime in self.runtimes.values()]
        if any(command != recovered[0] for command in recovered[1:]):
            raise AssertionError("component recovery identities diverged")
        return recovered[0]

    def restart(self, component: str, boundary: str) -> dict[str, Any]:
        if component not in self.runtimes:
            raise ValueError(f"unsupported restart component: {component}")
        if component == "foreground_provider":
            self.broker.close()
            self.broker = self._open_broker()
        elif component == "daemon":
            self.inbox.close()
            self.inbox = self._open_inbox()
        elif component == "bridge":
            self.inbox.close()
            self.broker.close()
            self.inbox = self._open_inbox()
            self.broker = self._open_broker()
        reopened, evidence = self.runtimes[component].restart(boundary)
        self.runtimes[component] = reopened
        self._recovered_command()
        return evidence

    def deliver(self) -> None:
        self._recovered_command()
        materialized = self.inbox.materialize_next(
            command_path=str(self.command_path),
            metadata_path=str(self.metadata_path),
            transport="fault_matrix",
        )
        if materialized is not None:
            self.stored = materialized
        self._checkpoint("delivered")

    def claim(self, *, acknowledged: bool) -> None:
        self.clock += 0.02 if acknowledged else 0.01
        claimed = {**self._recovered_command(), **self.stored}
        if not self.inbox.observe_claim(
            claimed,
            provider_turn_seen=acknowledged,
            now=self.clock,
        ):
            raise AssertionError("claim identity was not observed")
        self._checkpoint("acknowledged" if acknowledged else "claimed")

    def delay_acknowledgement(self) -> bool:
        self.clock += 0.15
        row = next(
            record
            for record in self.inbox.records()
            if record["intent_id"] == self.command["intent_id"]
        )
        recovered_claim = (
            row["state"] == "pending"
            and row["claimed_at"] is not None
            and row["recovered_at"] is not None
        )
        delayed = row["acked_at"] is None and (
            row["state"] == "claimed" or recovered_claim
        )
        self._checkpoint("acknowledgement_delayed")
        return delayed

    def complete(self) -> None:
        self.clock += 0.02
        if not self.broker.transition(
            self._recovered_command(),
            to_state="completed_final",
            event_type="provider_completed",
            release_reason="provider_stop",
            now=self.clock,
        ):
            raise AssertionError("terminal acknowledgement was not accepted")
        if self.broker.transition(
            self._recovered_command(),
            to_state="completed_final",
            event_type="provider_completed",
            release_reason="provider_stop",
            now=self.clock + 0.01,
        ):
            raise AssertionError("duplicate terminal acknowledgement was accepted")
        self._checkpoint("terminal")

    def reserve_effect(self, *, checkpoint: bool) -> EffectReservation:
        self.clock += 0.02
        reservation = self.broker.reserve_effect(
            self._recovered_command(),
            now=self.clock,
        )
        if checkpoint:
            self._checkpoint("effect_reserved")
        return reservation

    def finish_effect(self, effect_id: str) -> None:
        acknowledgement = next(
            record["acked_at"]
            for record in self.inbox.records()
            if record["intent_id"] == self.command["intent_id"]
        )
        acknowledged_at = _finite_float(acknowledgement)
        if acknowledged_at is None:
            raise AssertionError("effect cannot play without a finite acknowledgement")
        self.clock = max(self.clock + 0.01, acknowledged_at + 0.36)
        self._recovered_command()
        self.broker.authorize_effect_delivery(effect_id, now=self.clock)
        self.broker.finish_effect(effect_id, delivered=True, now=self.clock)

    def observed_latency_ms(self) -> float | None:
        intent = next(
            record
            for record in self.inbox.records()
            if record["intent_id"] == self.command["intent_id"]
        )
        effects = self.broker.table_records("provider_turn_effects")
        delivered = [record for record in effects if record["state"] == "delivered"]
        if len(delivered) != 1:
            return None
        return _observed_latency_ms(intent["acked_at"], delivered[0]["updated_at"])

    def close(self) -> None:
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

        first = scenario.reserve_effect(checkpoint=True)
        if boundary == "effect_reserved":
            evidence = scenario.restart(component, boundary)
        competing = scenario.reserve_effect(checkpoint=False)
        if first.effect_id is not None:
            scenario.finish_effect(first.effect_id)

        transitions = scenario.broker.table_records("provider_turn_transitions")
        effects = scenario.broker.table_records("provider_turn_effects")
        counts = {
            event: sum(row["event_type"] == event for row in transitions)
            for event in ("intent_claimed", "intent_acknowledged", "provider_completed")
        }
        restart_recovered = bool(
            evidence
            and evidence["instance_replaced"]
            and evidence["after_generation"] == evidence["before_generation"] + 1
            and evidence["recovered_boundary"] == boundary
        )
        checks = {
            "restart_recovered_distinct_state": (True, restart_recovered),
            "delayed_acknowledgement_observed": (True, delayed),
            "one_claim": (1, counts["intent_claimed"]),
            "one_terminal_acknowledgement": (1, counts["intent_acknowledged"]),
            "one_provider_terminal": (1, counts["provider_completed"]),
            "one_user_visible_effect": (1, len(effects)),
            "competing_output_rejected": (False, competing.accepted),
            "effect_delivered": ("delivered", effects[0]["state"] if effects else None),
        }
        if not first.accepted:
            checks["first_effect_accepted"] = (True, first.accepted)
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
        reserved = (
            scenario.reserve_effect(checkpoint=True)
            if boundary == "effect_reserved"
            else None
        )
        cancelled = scenario.inbox.cancel_scoped({
            "intent_id": f"cancel-{provider}-{boundary}",
            "cancellation_scope": "item",
            "target_intent_ids": [scenario.command["intent_id"]],
        })
        if reserved is not None and reserved.effect_id is not None:
            scenario.finish_effect(reserved.effect_id)
        reservation = (
            reserved
            if reserved is not None
            else scenario.broker.reserve_effect(scenario._recovered_command(), now=104.0)
        )
        effects = scenario.broker.table_records("provider_turn_effects")
        checks = {
            "revocation_applied": ([scenario.command["intent_id"]], cancelled),
        }
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
                "late_effect_reason": ("turn_revoked", reservation.reason),
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
        reserved = (
            scenario.reserve_effect(checkpoint=True)
            if boundary == "effect_reserved"
            else None
        )
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
        if reserved is not None and reserved.effect_id is not None:
            scenario.finish_effect(reserved.effect_id)
        reservation = (
            reserved
            if reserved is not None
            else scenario.broker.reserve_effect(
                scenario._recovered_command(),
                now=104.0,
            )
        )
        effects = scenario.broker.table_records("provider_turn_effects")
        checks = {
            "replacement_revoked_older_turn": (1, cancelled_count),
        }
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
                "replaced_turn_reason": ("turn_revoked", reservation.reason),
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
    return ordered[index]


def run_fault_matrix(root: Path) -> dict[str, Any]:
    """Run provider-parity restart, callback, cancellation, and latency faults."""
    violations: list[dict[str, Any]] = []
    latencies: list[float] = []
    restart_recovery_count = 0
    normal_scenario_count = (
        len(PROVIDERS) * len(RESTART_COMPONENTS) * len(LIFECYCLE_BOUNDARIES)
    )
    for provider in PROVIDERS:
        for component in RESTART_COMPONENTS:
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

    if len(latencies) != normal_scenario_count:
        violations.append(_diagnostic(
            provider="all",
            component="normal_path",
            boundary="acknowledged",
            invariant="finite_observed_latency_sample_count",
            expected=normal_scenario_count,
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
    return {
        "schema_version": 1,
        "providers": list(PROVIDERS),
        "restart_components": list(RESTART_COMPONENTS),
        "lifecycle_boundaries": list(LIFECYCLE_BOUNDARIES),
        "normal_scenario_count": normal_scenario_count,
        "restart_recovery_count": restart_recovery_count,
        "delayed_acknowledgement_scenario_count": len(PROVIDERS) * len(RESTART_COMPONENTS),
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
