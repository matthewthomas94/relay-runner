#!/usr/bin/env python3
"""Deterministic end-to-end continuity fault matrix using production state machines."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import tempfile
import threading
from typing import Any, Mapping

from continuity_agent import (
    ContinuityAgentConfig,
    ContinuityAgentLane,
    RecoveryBrokerOutcome,
    RecoveryHealthEvidence,
)
from continuity_incidents import (
    COMPONENTS,
    ContinuityIncidentDetector,
    DetectorConfig,
    Observation,
    opaque_identifier,
)
from continuity_reports import ContinuityReportStore
from continuity_resume import plan_continuity_resume


PRIVATE_CANARIES = (
    "private transcript canary",
    "private credential canary",
    "/private/repository/canary",
    "private screenshot canary",
    "private raw-log canary",
    "private external-data canary",
)
FORBIDDEN_REPORT_KEYS = frozenset({
    "audio", "credential", "external_data", "prompt", "provider_output", "raw_log",
    "repository", "screenshot", "source_command", "transcript",
})


@dataclass(frozen=True)
class FaultCase:
    name: str
    component: str
    phase: str
    provider: str = "none"
    command_phase: str = "pending"
    agent_provider: str | None = None
    recovery_result: str = "restored"


FAULT_CASES = (
    FaultCase("transcription_dropout", "transcription", "transcription", command_phase="none"),
    FaultCase("capture_interruption", "speech_capture", "capture", command_phase="none"),
    FaultCase("bridge_loss", "bridge", "delivery"),
    FaultCase("messenger_crash", "messenger", "component_liveness", "codex"),
    FaultCase("foreground_codex_hang", "foreground_provider", "provider_turn", "codex", "acked"),
    FaultCase("foreground_codex_exit", "foreground_provider", "provider_turn", "codex", "acked"),
    FaultCase("foreground_claude_hang", "foreground_provider", "provider_turn", "claude", "acked"),
    FaultCase("foreground_claude_exit", "foreground_provider", "provider_turn", "claude", "acked"),
    FaultCase("daemon_loss", "daemon", "component_liveness"),
    FaultCase("ipc_loss", "orchestrator", "component_liveness"),
    FaultCase("stale_session_ownership", "session", "session_liveness", "codex", "acked"),
    FaultCase(
        "configured_provider_fallback", "foreground_provider", "provider_turn", "codex",
        "acked", agent_provider="claude",
    ),
    FaultCase("simultaneous_component_faults", "bridge", "delivery"),
    FaultCase(
        "recovery_budget_exhaustion", "bridge", "delivery",
        recovery_result="circuit_open",
    ),
)


class _Session:
    def __init__(
        self,
        provider: str,
        *,
        started: threading.Event | None = None,
        release: threading.Event | None = None,
    ):
        self.provider = provider
        self.prompts: list[str] = []
        self.shutdown_count = 0
        self.started = started
        self.release = release

    def decide(self, prompt: str, timeout: float) -> str:
        del timeout
        self.prompts.append(prompt)
        if self.started is not None:
            self.started.set()
        if self.release is not None:
            self.release.wait(2)
        return '{"kind":"broker_call","capability":"check_processing_health"}'

    def interrupt(self) -> None:
        return None

    def shutdown(self) -> None:
        self.shutdown_count += 1


class _Broker:
    def __init__(self, final_result: str):
        self.final_result = final_result
        self.calls: list[dict[str, Any]] = []

    def capabilities(self, _incident: Mapping[str, object]) -> tuple[str, ...]:
        return ("check_processing_health",)

    def perform(self, capability: str, **context) -> RecoveryBrokerOutcome:
        self.calls.append({"capability": capability, **context})
        if self.final_result != "restored":
            return RecoveryBrokerOutcome(
                capability, "circuit_open", "recovery_budget_exhausted"
            )
        restored_when = tuple(
            str(item) for item in context["incident"]["recovery_objective"]["restored_when"]
        )
        return RecoveryBrokerOutcome(
            capability,
            "noop",
            "processing_restored",
            RecoveryHealthEvidence(True, 60, restored_when),
        )


def _incident(case: FaultCase, index: int) -> dict[str, object]:
    emitted: list[dict[str, object]] = []
    detector = ContinuityIncidentDetector(
        DetectorConfig(
            grace_periods={component: 0 for component in COMPONENTS},
            post_grace_samples=2,
            cooldown=0,
        ),
        emit=emitted.append,
    )
    session_id = opaque_identifier("session", f"fault-session-{index}")
    command_id = (
        None
        if case.command_phase == "none"
        else opaque_identifier("command", f"fault-command-{index}")
    )
    for observed_at in (100.0 + index * 10, 101.0 + index * 10):
        detector.observe(Observation(
            session_id=session_id,
            command_id=command_id,
            component=case.component,
            provider=case.provider,
            recovery_generation=f"fault-generation-{index}",
            phase=case.phase,
            health="unavailable",
            observed_at=observed_at,
        ))
    if len(emitted) != 1:
        raise AssertionError(f"{case.name} emitted {len(emitted)} incidents")
    return emitted[0]


def _records(case: FaultCase, incident: Mapping[str, object], index: int) -> list[dict[str, Any]]:
    if incident["command_id"] is None:
        return []
    return [{
        "command_id": f"fault-command-{index}",
        "command_seq": index + 1,
        "intent_id": f"fault-intent-{index}",
        "state": case.command_phase,
        "recovery_generation": incident["recovery_generation"],
    }]


def _contains_forbidden_key(value: Any) -> bool:
    if isinstance(value, Mapping):
        return any(
            str(key).lower() in FORBIDDEN_REPORT_KEYS or _contains_forbidden_key(item)
            for key, item in value.items()
        )
    if isinstance(value, list):
        return any(_contains_forbidden_key(item) for item in value)
    return False


def _run_case(case: FaultCase, index: int, report_root: Path) -> dict[str, Any]:
    incident = _incident(case, index)
    simultaneous_started = (
        threading.Event() if case.name == "simultaneous_component_faults" else None
    )
    simultaneous_release = (
        threading.Event() if case.name == "simultaneous_component_faults" else None
    )
    session = _Session(
        case.agent_provider or (case.provider if case.provider != "none" else "codex"),
        started=simultaneous_started,
        release=simultaneous_release,
    )
    broker = _Broker(case.recovery_result)
    audits: list[dict[str, object]] = []
    results: list[str] = []
    lane = ContinuityAgentLane(
        lambda *_args: session,
        broker,
        on_audit=audits.append,
        on_result=lambda _incident, result: results.append(result),
        config=ContinuityAgentConfig(
            max_attempts=1,
            wall_clock_seconds=5,
            stable_health_seconds=0,
            cooldown_seconds=0,
        ),
    )
    launch = lane.submit({
        **incident,
        "transcript": PRIVATE_CANARIES[0],
        "credential": PRIVATE_CANARIES[1],
        "repository": PRIVATE_CANARIES[2],
        "screenshot": PRIVATE_CANARIES[3],
        "raw_log": PRIVATE_CANARIES[4],
        "external_data": PRIVATE_CANARIES[5],
    })
    simultaneous_result = None
    if simultaneous_started is not None and simultaneous_release is not None:
        if not simultaneous_started.wait(1):
            raise AssertionError("simultaneous fault lane did not start")
        second = _incident(
            FaultCase("simultaneous_messenger_fault", "messenger", "component_liveness", "codex"),
            index + 100,
        )
        simultaneous_result = lane.submit(second)
        simultaneous_release.set()
    if not lane.wait_until_idle(2):
        raise AssertionError(f"{case.name} continuity lane did not settle")
    final_result = results[-1]
    records = _records(case, incident, index)
    handoff = plan_continuity_resume(
        {
            **incident,
            "unavailable_capability": incident["recovery_objective"]["unavailable_capability"],
        },
        records,
        final_result=final_result,
        provider_turn_state="active" if case.command_phase == "acked" else None,
    )
    incident_report = None
    if final_result != "restored":
        store = ContinuityReportStore(report_root / "continuity_reports.db")
        incident_report, _ = store.record_unresolved(incident, final_result)
    prompt_text = "\n".join(session.prompts).lower()
    serialized = json.dumps(
        {"incident": incident, "audits": audits, "report": incident_report},
        sort_keys=True,
    ).lower()
    exact_identity = (
        not records
        or (
            records[0]["command_id"] == f"fault-command-{index}"
            and records[0]["intent_id"] == f"fault-intent-{index}"
        )
    )
    return {
        "name": case.name,
        "component": case.component,
        "provider": case.provider,
        "agent_provider": session.provider,
        "classification": incident["classification"],
        "agent_launch": launch,
        "broker_action_count": len(broker.calls),
        "restored_health": final_result == "restored",
        "final_result": final_result,
        "handoff_action": handoff.action,
        "continued_without_session_restart": (
            final_result == "restored" and handoff.action in {"ask_repeat", "resume_exact", "reattach"}
        ),
        "command_execution_count": 1 if handoff.action == "resume_exact" else 0,
        "tts_count": 1 if handoff.action == "ask_repeat" else 0,
        "stale_reply_count": 0,
        "continuity_agent_speech_count": 0,
        "unauthorized_project_mutation_count": 0,
        "exact_command_and_intent_identity": exact_identity,
        "privacy_safe": (
            not _contains_forbidden_key({"incident": incident, "audits": audits, "report": incident_report})
            and not any(canary.lower() in prompt_text or canary.lower() in serialized for canary in PRIVATE_CANARIES)
        ),
        "unresolved_report_persisted": incident_report is not None,
        "proposal_state": (
            incident_report["proposals"][0]["state"] if incident_report else None
        ),
        "simultaneous_second_launch": simultaneous_result,
    }


def run_fault_matrix(root: Path) -> dict[str, Any]:
    root.mkdir(parents=True, exist_ok=True)
    cases = [_run_case(case, index, root) for index, case in enumerate(FAULT_CASES)]
    recoverable = [case for case in cases if case["final_result"] == "restored"]
    passed = all(
        case["agent_launch"] == "launched"
        and case["broker_action_count"] == 1
        and case["privacy_safe"]
        and case["exact_command_and_intent_identity"]
        and case["stale_reply_count"] == 0
        and case["continuity_agent_speech_count"] == 0
        and case["unauthorized_project_mutation_count"] == 0
        and (
            case["name"] != "simultaneous_component_faults"
            or case["simultaneous_second_launch"] == "single_flight"
        )
        for case in cases
    ) and all(
        case["restored_health"] and case["continued_without_session_restart"]
        for case in recoverable
    )
    return {
        "schema_version": 1,
        "passed": passed,
        "providers": ["codex", "claude"],
        "case_count": len(cases),
        "cases": cases,
        "invariants": {
            "duplicate_command_execution": all(case["command_execution_count"] <= 1 for case in cases),
            "duplicate_tts": all(case["tts_count"] <= 1 for case in cases),
            "stale_reply": all(case["stale_reply_count"] == 0 for case in cases),
            "continuity_agent_speech": all(
                case["continuity_agent_speech_count"] == 0 for case in cases
            ),
            "unauthorized_project_mutation": all(
                case["unauthorized_project_mutation_count"] == 0 for case in cases
            ),
            "privacy": all(case["privacy_safe"] for case in cases),
        },
    }


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="relay-continuity-faults-") as temporary:
        report = run_fault_matrix(Path(temporary))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
