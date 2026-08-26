#!/usr/bin/env python3
"""Deterministic end-to-end continuity fault matrix using production boundaries."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
from typing import Any, Mapping
from unittest.mock import patch

from continuity_agent import ContinuityAgentConfig, ContinuityAgentLane, RecoveryHealthEvidence
from continuity_incidents import (
    COMPONENTS,
    ContinuityIncidentDetector,
    DetectorConfig,
    Observation,
    opaque_identifier,
)
from continuity_recovery import (
    AppRecoveryOwner,
    BridgeRecoveryOwner,
    ComponentOwnedRecoveryBroker,
    DaemonRecoveryOwner,
)
from continuity_reports import ContinuityReportStore
from intent_inbox import IntentInbox

try:
    import numpy  # noqa: F401 - the canonical bridge audio module imports it.
except ModuleNotFoundError:
    sys.modules.setdefault(
        "numpy",
        SimpleNamespace(asarray=lambda samples: samples, int16=object()),
    )
import voice_bridge


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


class _EventLedger:
    """Append-only evidence shared by the concurrent production lane and broker."""

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()

    def record(self, event_type: str, **fields: object) -> None:
        record = {"event_type": event_type, **fields}
        with self._lock:
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")

    def records(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        return [json.loads(line) for line in self.path.read_text().splitlines() if line]


class _Session:
    def __init__(
        self,
        provider: str,
        ledger: _EventLedger,
        *,
        started: threading.Event | None = None,
        release: threading.Event | None = None,
    ):
        self.provider = provider
        self.ledger = ledger
        self.prompts: list[str] = []
        self.started = started
        self.release = release

    def decide(self, prompt: str, timeout: float) -> str:
        del timeout
        self.prompts.append(prompt)
        self.ledger.record(
            "agent_output", actor="continuity_agent", channel="broker_json",
            provider=self.provider,
        )
        if self.started is not None:
            self.started.set()
        if self.release is not None:
            self.release.wait(2)
        return '{"kind":"broker_call","capability":"check_processing_health"}'

    def interrupt(self) -> None:
        return None

    def shutdown(self) -> None:
        self.ledger.record("agent_shutdown", actor="continuity_agent")


def _incident(case: FaultCase, index: int, ledger: _EventLedger) -> dict[str, object]:
    emitted: list[dict[str, object]] = []

    def emit(incident: dict[str, object]) -> None:
        emitted.append(incident)
        ledger.record("incident_emitted", incident=incident)

    detector = ContinuityIncidentDetector(
        DetectorConfig(
            grace_periods={component: 0 for component in COMPONENTS},
            post_grace_samples=2,
            cooldown=0,
        ),
        emit=emit,
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


def _contains_forbidden_key(value: Any) -> bool:
    if isinstance(value, Mapping):
        return any(
            str(key).lower() in FORBIDDEN_REPORT_KEYS or _contains_forbidden_key(item)
            for key, item in value.items()
        )
    if isinstance(value, list):
        return any(_contains_forbidden_key(item) for item in value)
    return False


def _tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def _prepare_inbox(
    case: FaultCase,
    incident: Mapping[str, object],
    index: int,
    case_root: Path,
) -> tuple[IntentInbox, Path, Path]:
    inbox = IntentInbox(case_root / "intent-inbox.sqlite3")
    state_path = case_root / "voice-command-state.json"
    turns_path = case_root / "provider-turns.json"
    state_path.write_text(json.dumps({
        "recovery_generation": incident["recovery_generation"],
    }))
    if incident["command_id"] is None:
        return inbox, state_path, turns_path

    metadata = {
        "relay_command_seq": index + 1,
        "relay_command_id": f"fault-command-{index}",
        "intent_id": f"fault-intent-{index}",
        "recovery_generation": incident["recovery_generation"],
    }
    stored = inbox.enqueue("private command body", metadata, "continue_current")
    if case.command_phase == "acked":
        command_path = case_root / "pre-recovery-command"
        metadata_path = case_root / "pre-recovery-command.meta"
        inbox.materialize_next(
            command_path=str(command_path),
            metadata_path=str(metadata_path),
            transport=case.provider,
        )
        inbox.observe_claim(stored, provider_turn_seen=True)
        turns_path.write_text(json.dumps({
            "records": [{**stored, "state": "active"}],
        }))
    return inbox, state_path, turns_path


def _handoff_payload(
    incident: Mapping[str, object],
    final_result: str,
) -> dict[str, object]:
    objective = dict(incident.get("recovery_objective") or {})
    timing = dict(incident.get("timing") or {})
    return {
        "type": "continuity_resume",
        "final_result": final_result,
        "incident_id": incident.get("incident_id"),
        "session_id": incident.get("session_id"),
        "command_id": incident.get("command_id"),
        "component": incident.get("component"),
        "phase": incident.get("phase"),
        "unavailable_capability": objective.get("unavailable_capability"),
        "provider": incident.get("provider"),
        "recovery_generation": incident.get("recovery_generation"),
        "incident_observed_at": timing.get("last_observed_at"),
    }


def _apply_canonical_handoff(
    case: FaultCase,
    incident: Mapping[str, object],
    final_result: str,
    inbox: IntentInbox,
    state_path: Path,
    turns_path: Path,
    case_root: Path,
    ledger: _EventLedger,
    *,
    injected_effect: str | None,
) -> dict[str, Any]:
    payload = _handoff_payload(incident, final_result)
    applied_keys: set[str] = set()
    context = {"boundary": "canonical_handoff"}

    def queue_tts(text: str, _queue: object, **_kwargs: object) -> bool:
        event = {
            "actor": "canonical_bridge",
            "boundary": context["boundary"],
            "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        }
        ledger.record("tts_play_request", **event)
        if injected_effect == "duplicate_tts":
            ledger.record("tts_play_request", **event)
        return True

    def notify(state: str, **_fields: object) -> bool:
        ledger.record(
            "state_notification", actor="canonical_bridge",
            boundary=context["boundary"], state=state,
        )
        return True

    index = FAULT_CASES.index(case)
    common = {
        "inbox": inbox,
        "tts_worker": SimpleNamespace(input_queue=object()),
        "orchestrator_session": {
            "session_key": f"fault-session-{index}",
            "provider": case.provider if case.provider != "none" else "codex",
        },
        "applied_keys": applied_keys,
        "bridge_generation": str(incident["recovery_generation"]),
        "state_path": str(state_path),
        "turns_path": str(turns_path),
    }
    with (
        patch.object(voice_bridge, "_queue_tts_text", side_effect=queue_tts),
        patch.object(voice_bridge, "_notify_state", side_effect=notify),
    ):
        result = voice_bridge._bridge_continuity_resume_response(payload, **common)
        ledger.record("handoff_result", boundary=context["boundary"], result=result)

        context["boundary"] = "duplicate_handoff"
        duplicate = voice_bridge._bridge_continuity_resume_response(payload, **common)
        ledger.record("handoff_result", boundary=context["boundary"], result=duplicate)

        stale_payload = {
            **payload,
            "incident_id": f"inc-{hashlib.sha256((str(payload['incident_id']) + '-stale').encode()).hexdigest()[:12]}",
            "recovery_generation": f"stale-generation-{index}",
        }
        context["boundary"] = "stale_handoff"
        stale = voice_bridge._bridge_continuity_resume_response(stale_payload, **common)
        ledger.record("handoff_result", boundary=context["boundary"], result=stale)

    if result.get("action") == "resume_exact":
        command_path = case_root / "resumed-command"
        metadata_path = case_root / "resumed-command.meta"
        materialized = inbox.materialize_next(
            command_path=str(command_path),
            metadata_path=str(metadata_path),
            transport=case.provider if case.provider != "none" else "codex",
        )
        if materialized is not None:
            event = {
                "actor": "foreground_provider",
                "command_id": materialized.get("relay_command_id"),
                "intent_id": materialized.get("intent_id"),
            }
            ledger.record("command_execution", **event)
            if injected_effect == "duplicate_command_execution":
                ledger.record("command_execution", **event)
        second_materialization = inbox.materialize_next(
            command_path=str(case_root / "second-command"),
            metadata_path=str(case_root / "second-command.meta"),
            transport=case.provider if case.provider != "none" else "codex",
        )
        ledger.record(
            "materialization_probe", duplicate_available=second_materialization is not None,
        )
    return result


def _count(records: list[dict[str, Any]], event_type: str, **matches: object) -> int:
    return sum(
        1 for record in records
        if record.get("event_type") == event_type
        and all(record.get(key) == value for key, value in matches.items())
    )


def _run_case(
    case: FaultCase,
    index: int,
    report_root: Path,
    *,
    injected_effect: str | None = None,
) -> dict[str, Any]:
    case_root = report_root / case.name
    case_root.mkdir(parents=True, exist_ok=True)
    ledger = _EventLedger(case_root / "effects.jsonl")
    project_root = case_root / "project"
    project_root.mkdir()
    (project_root / "guard.txt").write_text("unchanged\n")
    project_before = _tree_digest(project_root)
    ledger.record("project_snapshot", phase="before", digest=project_before)

    incident = _incident(case, index, ledger)
    simultaneous_started = (
        threading.Event() if case.name == "simultaneous_component_faults" else None
    )
    simultaneous_release = (
        threading.Event() if case.name == "simultaneous_component_faults" else None
    )
    session = _Session(
        case.agent_provider or (case.provider if case.provider != "none" else "codex"),
        ledger,
        started=simultaneous_started,
        release=simultaneous_release,
    )
    objectives_by_generation = {
        str(incident["recovery_generation"]): tuple(
            str(item) for item in incident["recovery_objective"]["restored_when"]
        ),
    }
    restored_generations = (
        set(objectives_by_generation) if case.recovery_result == "restored" else set()
    )

    mutation_injected = False

    def health_probe(request: object) -> RecoveryHealthEvidence:
        nonlocal mutation_injected
        ledger.record(
            "broker_health_probe", actor="component_owned_broker",
            capability=getattr(request, "capability"),
            component=getattr(request, "component"),
        )
        if injected_effect == "unauthorized_project_mutation" and not mutation_injected:
            (project_root / "unauthorized.txt").write_text("mutated\n")
            mutation_injected = True
        generation = str(getattr(request, "recovery_generation"))
        if generation not in restored_generations:
            return RecoveryHealthEvidence()
        return RecoveryHealthEvidence(True, 60, objectives_by_generation[generation])

    broker = ComponentOwnedRecoveryBroker({
        "app": AppRecoveryOwner(health_probe),
        "bridge": BridgeRecoveryOwner(health_probe),
        "daemon": DaemonRecoveryOwner(health_probe),
    })
    results: list[str] = []

    def audit(record: dict[str, object]) -> None:
        ledger.record("agent_audit", record=record)

    def receive_result(_incident: Mapping[str, object], result: str) -> None:
        results.append(result)
        ledger.record("agent_result", final_result=result)

    lane = ContinuityAgentLane(
        lambda *_args: session,
        broker,
        on_audit=audit,
        on_result=receive_result,
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
    ledger.record("agent_submit", outcome=launch)
    simultaneous_result = None
    if simultaneous_started is not None and simultaneous_release is not None:
        if not simultaneous_started.wait(1):
            raise AssertionError("simultaneous fault lane did not start")
        second = _incident(
            FaultCase("simultaneous_messenger_fault", "messenger", "component_liveness", "codex"),
            index + 100,
            ledger,
        )
        second_generation = str(second["recovery_generation"])
        objectives_by_generation[second_generation] = tuple(
            str(item) for item in second["recovery_objective"]["restored_when"]
        )
        restored_generations.add(second_generation)
        simultaneous_result = lane.submit(second)
        ledger.record("agent_submit", outcome=simultaneous_result)
        simultaneous_release.set()
    if not lane.wait_until_idle(2):
        raise AssertionError(f"{case.name} continuity lane did not settle")
    final_result = results[-1]

    inbox, state_path, turns_path = _prepare_inbox(case, incident, index, case_root)
    try:
        handoff = _apply_canonical_handoff(
            case,
            incident,
            final_result,
            inbox,
            state_path,
            turns_path,
            case_root,
            ledger,
            injected_effect=injected_effect,
        )
    finally:
        inbox.close()

    incident_report = None
    if final_result != "restored":
        store = ContinuityReportStore(report_root / "continuity_reports.db")
        incident_report, _ = store.record_unresolved(incident, final_result)
        ledger.record("unresolved_report", report=incident_report)

    project_after = _tree_digest(project_root)
    ledger.record("project_snapshot", phase="after", digest=project_after)
    if project_after != project_before:
        ledger.record("project_mutation_observed", actor="continuity_recovery")

    records = ledger.records()
    serialized = json.dumps(
        {"events": records, "report": incident_report}, sort_keys=True,
    ).lower()
    prompt_text = "\n".join(session.prompts).lower()
    command_events = [
        record for record in records if record.get("event_type") == "command_execution"
    ]
    exact_identity = all(
        record.get("command_id") == f"fault-command-{index}"
        and record.get("intent_id") == f"fault-intent-{index}"
        for record in command_events
    )
    command_count = len(command_events)
    tts_count = _count(records, "tts_play_request")
    stale_reply_count = sum(
        1 for record in records
        if record.get("boundary") == "stale_handoff"
        and record.get("event_type") in {"tts_play_request", "state_notification"}
    )
    continuity_speech_count = _count(
        records, "tts_play_request", actor="continuity_agent",
    ) + _count(records, "agent_output", channel="speech")
    mutation_count = _count(records, "project_mutation_observed")
    broker_outcomes = [
        record for record in records
        if record.get("event_type") == "agent_audit"
        and dict(record.get("record") or {}).get("phase") == "broker_outcome"
    ]
    audit_phases = {
        dict(record.get("record") or {}).get("phase")
        for record in records if record.get("event_type") == "agent_audit"
    }
    if final_result != "restored":
        expected_handoff_action = "foreground_review"
    elif case.command_phase == "none":
        expected_handoff_action = "ask_repeat"
    elif case.command_phase == "acked":
        expected_handoff_action = "reattach"
    else:
        expected_handoff_action = "resume_exact"
    expected_command_count = 1 if expected_handoff_action == "resume_exact" else 0
    expected_tts_count = 1 if expected_handoff_action == "ask_repeat" else 0
    return {
        "name": case.name,
        "component": case.component,
        "provider": case.provider,
        "agent_provider": session.provider,
        "classification": incident["classification"],
        "incident_event_count": _count(records, "incident_emitted"),
        "agent_launch": launch,
        "agent_launch_observed": "launched" in audit_phases,
        "agent_result_count": len(results),
        "broker_action_count": len(broker_outcomes),
        "restored_health": final_result == "restored",
        "final_result": final_result,
        "handoff_action": handoff.get("action"),
        "expected_handoff_action": expected_handoff_action,
        "continued_without_session_restart": (
            final_result == "restored"
            and handoff.get("action") in {"ask_repeat", "resume_exact", "reattach"}
        ),
        "command_execution_count": command_count,
        "expected_command_execution_count": expected_command_count,
        "tts_count": tts_count,
        "expected_tts_count": expected_tts_count,
        "stale_reply_count": stale_reply_count,
        "continuity_agent_speech_count": continuity_speech_count,
        "unauthorized_project_mutation_count": mutation_count,
        "exact_command_and_intent_identity": exact_identity,
        "privacy_safe": (
            not _contains_forbidden_key({"events": records, "report": incident_report})
            and not any(
                canary.lower() in prompt_text or canary.lower() in serialized
                for canary in PRIVATE_CANARIES
            )
        ),
        "unresolved_report_persisted": incident_report is not None,
        "proposal_state": (
            incident_report["proposals"][0]["state"] if incident_report else None
        ),
        "simultaneous_second_launch": simultaneous_result,
    }


def run_fault_matrix(
    root: Path,
    *,
    injected_effect: str | None = None,
) -> dict[str, Any]:
    if injected_effect not in {
        None,
        "duplicate_command_execution",
        "duplicate_tts",
        "unauthorized_project_mutation",
    }:
        raise ValueError("unsupported injected effect")
    root.mkdir(parents=True, exist_ok=True)
    cases = [
        _run_case(case, index, root, injected_effect=injected_effect)
        for index, case in enumerate(FAULT_CASES)
    ]
    recoverable = [case for case in cases if case["final_result"] == "restored"]
    passed = all(
        case["incident_event_count"] == (2 if case["name"] == "simultaneous_component_faults" else 1)
        and case["agent_launch"] == "launched"
        and case["agent_launch_observed"]
        and case["broker_action_count"] == (
            2 if case["name"] == "simultaneous_component_faults" else 1
        )
        and case["agent_result_count"] == (
            2 if case["name"] == "simultaneous_component_faults" else 1
        )
        and case["privacy_safe"]
        and case["exact_command_and_intent_identity"]
        and case["handoff_action"] == case["expected_handoff_action"]
        and case["command_execution_count"] == case["expected_command_execution_count"]
        and case["tts_count"] == case["expected_tts_count"]
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
            "duplicate_command_execution": all(
                case["command_execution_count"] == case["expected_command_execution_count"]
                for case in cases
            ),
            "duplicate_tts": all(
                case["tts_count"] == case["expected_tts_count"] for case in cases
            ),
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
