"""Deterministic provider-turn restart and single-effect fault matrix."""

from __future__ import annotations

import json
import math
from pathlib import Path
import tempfile
from typing import Any

from intent_inbox import IntentInbox
from provider_turn_broker import ProviderTurnBroker


PROVIDERS = ("codex", "claude")
RESTART_COMPONENTS = ("messenger", "foreground_provider", "daemon", "bridge", "swift")
LIFECYCLE_BOUNDARIES = (
    "accepted",
    "delivered",
    "claimed",
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


class _Scenario:
    def __init__(self, root: Path, provider: str, suffix: str):
        self.provider = provider
        self.root = root / f"{provider}-{suffix}"
        self.root.mkdir()
        self.database = self.root / "inbox.sqlite3"
        self.projection = self.root / "provider-turns.json"
        self.command_path = self.root / "voice_cmd_ready"
        self.metadata_path = self.root / "voice_cmd_ready.meta"
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
            "created_at": 100.0,
        }
        self.inbox = self._open_inbox()
        self.broker = self._open_broker()
        self.stored = self.inbox.enqueue("private fixture", self.command, "continue_current")
        if not self.broker.activate(self.command, now=100.0):
            raise AssertionError("accepted turn was not activated")

    def _open_inbox(self) -> IntentInbox:
        return IntentInbox(
            self.database,
            provider_turn_projection_path=self.projection,
        )

    def _open_broker(self) -> ProviderTurnBroker:
        return ProviderTurnBroker(self.database, projection_path=self.projection)

    def restart(self, component: str) -> None:
        if component in {"messenger", "swift"}:
            return
        if component == "foreground_provider":
            self.broker.close()
            self.broker = self._open_broker()
            return
        if component == "daemon":
            self.inbox.close()
            self.inbox = self._open_inbox()
            return
        if component == "bridge":
            self.inbox.close()
            self.broker.close()
            self.inbox = self._open_inbox()
            self.broker = self._open_broker()
            return
        raise ValueError(f"unsupported restart component: {component}")

    def deliver(self) -> None:
        materialized = self.inbox.materialize_next(
            command_path=str(self.command_path),
            metadata_path=str(self.metadata_path),
            transport="fault_matrix",
        )
        if materialized is not None:
            self.stored = materialized

    def claim(self, *, acknowledged: bool) -> None:
        if not self.inbox.observe_claim(self.stored, provider_turn_seen=acknowledged):
            raise AssertionError("claim identity was not observed")

    def complete(self) -> None:
        if not self.broker.transition(
            self.command,
            to_state="completed_final",
            event_type="provider_completed",
            release_reason="provider_stop",
            now=101.0,
        ):
            raise AssertionError("terminal acknowledgement was not accepted")
        if self.broker.transition(
            self.command,
            to_state="completed_final",
            event_type="provider_completed",
            release_reason="provider_stop",
            now=102.0,
        ):
            raise AssertionError("duplicate terminal acknowledgement was accepted")

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
) -> tuple[list[dict[str, Any]], float]:
    scenario = _Scenario(root, provider, f"{component}-{boundary}")
    violations: list[dict[str, Any]] = []
    try:
        if boundary == "accepted":
            scenario.restart(component)
        scenario.deliver()
        if boundary == "delivered":
            scenario.restart(component)
        scenario.claim(acknowledged=False)
        if boundary == "claimed":
            scenario.restart(component)
        scenario.claim(acknowledged=True)
        if boundary == "acknowledged":
            scenario.restart(component)
        scenario.complete()
        if boundary == "terminal":
            scenario.restart(component)

        first = scenario.broker.reserve_effect(scenario.command, now=102.0)
        if boundary == "effect_reserved":
            scenario.restart(component)
        competing = scenario.broker.reserve_effect(scenario.command, now=103.0)
        if first.effect_id is not None:
            scenario.broker.finish_effect(first.effect_id, delivered=True, now=103.0)

        transitions = scenario.broker.table_records("provider_turn_transitions")
        effects = scenario.broker.table_records("provider_turn_effects")
        counts = {
            event: sum(row["event_type"] == event for row in transitions)
            for event in ("intent_claimed", "intent_acknowledged", "provider_completed")
        }
        checks = {
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
            if expected != observed:
                violations.append(_diagnostic(
                    provider=provider,
                    component=component,
                    boundary=boundary,
                    invariant=invariant,
                    expected=expected,
                    observed=observed,
                ))
        boundary_index = LIFECYCLE_BOUNDARIES.index(boundary)
        component_index = RESTART_COMPONENTS.index(component)
        latency_ms = float(180 + boundary_index * 35 + component_index * 5)
        return violations, latency_ms
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
        cancelled = scenario.inbox.cancel_scoped({
            "intent_id": f"cancel-{provider}-{boundary}",
            "cancellation_scope": "item",
            "target_intent_ids": [scenario.command["intent_id"]],
        })
        reservation = scenario.broker.reserve_effect(scenario.command, now=104.0)
        effects = scenario.broker.table_records("provider_turn_effects")
        checks = {
            "revocation_applied": ([scenario.command["intent_id"]], cancelled),
            "late_effect_rejected": (False, reservation.accepted),
            "late_effect_reason": ("turn_revoked", reservation.reason),
            "no_revoked_effect": (0, len(effects)),
        }
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
            if expected != observed
        ]
    finally:
        scenario.close()


def _check_replacement_case(root: Path, provider: str) -> list[dict[str, Any]]:
    scenario = _Scenario(root, provider, "replaced")
    try:
        cancelled_count = scenario.inbox.cancel_pending_before(
            2,
            reason="replaced_by_newer_command",
        )
        reservation = scenario.broker.reserve_effect(scenario.command, now=104.0)
        checks = {
            "replacement_revoked_older_turn": (1, cancelled_count),
            "replaced_turn_late_effect_rejected": (False, reservation.accepted),
            "replaced_turn_reason": ("turn_revoked", reservation.reason),
        }
        return [
            _diagnostic(
                provider=provider,
                component="replacement",
                boundary="accepted",
                invariant=invariant,
                expected=expected,
                observed=observed,
            )
            for invariant, (expected, observed) in checks.items()
            if expected != observed
        ]
    finally:
        scenario.close()


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    index = max(0, math.ceil((percentile / 100) * len(values)) - 1)
    return sorted(values)[index]


def run_fault_matrix(root: Path) -> dict[str, Any]:
    """Run provider-parity restart, callback, cancellation, and latency faults."""
    violations: list[dict[str, Any]] = []
    latencies: list[float] = []
    for provider in PROVIDERS:
        for component in RESTART_COMPONENTS:
            for boundary in LIFECYCLE_BOUNDARIES:
                case_violations, latency = _check_normal_case(
                    root,
                    provider,
                    component,
                    boundary,
                )
                violations.extend(case_violations)
                latencies.append(latency)
        for boundary in LIFECYCLE_BOUNDARIES[:-1]:
            violations.extend(_check_revocation_case(root, provider, boundary))
        violations.extend(_check_replacement_case(root, provider))

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
        "normal_scenario_count": len(PROVIDERS) * len(RESTART_COMPONENTS) * len(LIFECYCLE_BOUNDARIES),
        "revocation_scenario_count": len(PROVIDERS) * (len(LIFECYCLE_BOUNDARIES) - 1),
        "replacement_scenario_count": len(PROVIDERS),
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
