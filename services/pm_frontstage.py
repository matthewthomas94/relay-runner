#!/usr/bin/env python3
"""Prototype Project Manager frontstage orchestration contracts.

This module is intentionally side-effect-free. It proves the PM/backstage split
around existing Relay command metadata without writing tickets or dispatching
workers itself.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Union

from command_actions import resolve_command_action


STATUS_PHASES = frozenset({"acknowledged", "planning", "outcome", "stale"})
STATUS_SOURCES = frozenset({"pm", "orchestrator", "worker", "review-worker"})
OUTCOME_KINDS = frozenset({"execute_solo", "delegate_plan", "needs_user"})
TRACE_KINDS = frozenset({
    "reasoning-summary",
    "clarification-request",
    "reading-context",
    "ticket-updating",
    "ticket-created",
    "dispatch-preparing",
    "dispatch-started",
    "dispatch-claimed",
    "run-running",
    "run-reviewing",
    "run-health-check",
    "run-health-warning",
    "run-review-needed",
    "run-merging",
    "run-merged",
    "run-reconciled",
    "run-verification-blocked",
    "run-verification-resumed",
    "run-succeeded",
    "run-failed",
    "run-canceled",
    "running-tests",
    "building",
    "installing",
    "preparing-response",
    "board-change",
})
TRACE_MESSAGE_MAX_LEN = 96
UPDATE_MODE_MESSAGE_MAX_LEN = 120
LIFECYCLE_DETAIL_TRACE_KINDS = frozenset({
    "run-health-warning",
    "run-review-needed",
    "run-merged",
    "run-reconciled",
    "run-verification-blocked",
    "run-verification-resumed",
    "run-succeeded",
    "run-failed",
    "run-canceled",
})
_COMMAND_LIKE_TRACE_RE = re.compile(
    r"(`|\$\(|&&|\|\||\s;\s|"
    r"\b(?:bash|cat|curl|git|grep|npm|pnpm|python|python3|sh|swift|xcodebuild|yarn|zsh)\s+)",
    re.IGNORECASE,
)
_PRIVATE_ACTIVITY_RE = re.compile(
    r"(transcript|source_text|tool\s+log|hidden\s+reasoning|chain[- ]of[- ]thought|scratchpad|prompt|secret|credential|password|token|api[_ -]?key)",
    re.IGNORECASE,
)

PROVIDER_PARITY_NOTES = (
    "The PM/frontstage event contract is provider-neutral for Codex and Claude. "
    "Provider-specific differences remain at launch/dispatch rendering: Codex "
    "uses model_reasoning_effort and Claude uses --effort, while both providers "
    "share cooperative stale-command checks."
)

BackstagePlanner = Callable[
    [str, dict[str, Any], Union[str, Path, None]],
    "BackstageOutcome",
]
CurrentCommandReader = Callable[[], Union[dict[str, Any], None]]
StatusEmitter = Callable[["PMStatusEvent"], None]
AcknowledgementBuilder = Callable[[str, "RelayCommandMetadata"], str]
UpdateStatusReader = Callable[[], "PMUpdateSnapshot"]


def _public_message(value: str) -> str:
    message = re.sub(r"\s+", " ", str(value or "")).strip()
    if not message:
        raise ValueError("status events require a public user-facing message")
    return message


def _clip_public_message(message: str, limit: int = TRACE_MESSAGE_MAX_LEN) -> str:
    if len(message) <= limit:
        return message
    return message[: max(0, limit - 3)].rstrip() + "..."


def _clip_update_message(message: str) -> str:
    return _clip_public_message(message, limit=UPDATE_MODE_MESSAGE_MAX_LEN)


def _public_trace_detail(value: str) -> str:
    message = _public_message(value)
    if _COMMAND_LIKE_TRACE_RE.search(message) or _PRIVATE_ACTIVITY_RE.search(message):
        raise ValueError("trace messages must not contain raw commands or private details")
    return message


def _public_update_activity(value: str | None) -> str | None:
    if value is None:
        return None
    message = _public_message(value)
    if _COMMAND_LIKE_TRACE_RE.search(message) or _PRIVATE_ACTIVITY_RE.search(message):
        return None
    return _clip_update_message(message)


def _coerce_seq(value: Any) -> int:
    if value is None or value == "":
        raise ValueError("relay command metadata requires relay_command_seq")
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid relay_command_seq: {value!r}") from exc


@dataclass(frozen=True)
class RelayCommandMetadata:
    relay_command_seq: int
    relay_command_id: str
    provider: str | None = None
    source_text: str | None = None

    @classmethod
    def from_dict(
        cls,
        payload: dict[str, Any] | None,
        *,
        source_text: str | None = None,
    ) -> "RelayCommandMetadata":
        data = payload or {}
        command_id = str(data.get("relay_command_id") or "").strip()
        if not command_id:
            raise ValueError("relay command metadata requires relay_command_id")
        provider = str(data.get("provider") or "").strip() or None
        raw_source = source_text if source_text is not None else data.get("source_text")
        return cls(
            relay_command_seq=_coerce_seq(data.get("relay_command_seq")),
            relay_command_id=command_id,
            provider=provider,
            source_text=str(raw_source) if raw_source is not None else None,
        )

    def matches(self, current: dict[str, Any] | None) -> bool:
        if not isinstance(current, dict):
            return False
        try:
            current_seq = _coerce_seq(current.get("relay_command_seq"))
        except ValueError:
            return False
        return (
            current_seq == self.relay_command_seq
            and str(current.get("relay_command_id") or "") == self.relay_command_id
        )

    def to_public_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "relay_command_seq": self.relay_command_seq,
            "relay_command_id": self.relay_command_id,
        }
        if self.provider:
            data["provider"] = self.provider
        return data

    def to_dispatch_fields(self) -> dict[str, Any]:
        return {
            "relay_command_seq": self.relay_command_seq,
            "relay_command_id": self.relay_command_id,
        }


@dataclass(frozen=True)
class PMStatusEvent:
    phase: str
    message: str
    source: str
    command: RelayCommandMetadata
    run_id: int | None = None
    ticket_id: str | None = None

    def __post_init__(self) -> None:
        phase = self.phase.strip().lower()
        source = self.source.strip().lower()
        if phase not in STATUS_PHASES:
            raise ValueError(f"invalid status phase: {self.phase!r}")
        if source not in STATUS_SOURCES:
            raise ValueError(f"invalid status source: {self.source!r}")
        object.__setattr__(self, "phase", phase)
        object.__setattr__(self, "source", source)
        object.__setattr__(self, "message", _public_message(self.message))
        if self.ticket_id:
            object.__setattr__(self, "ticket_id", self.ticket_id.upper())

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "phase": self.phase,
            "message": self.message,
            "source": self.source,
            "command": self.command.to_public_dict(),
        }
        if self.run_id is not None:
            data["run_id"] = self.run_id
        if self.ticket_id:
            data["ticket_id"] = self.ticket_id
        return data


def _trace_ticket_label(ticket_id: str | None) -> str:
    ticket = str(ticket_id or "").strip().upper()
    return ticket or "Ticket"


def default_orchestration_trace_message(
    kind: str,
    *,
    ticket_id: str | None = None,
    run_id: int | None = None,
) -> str:
    ticket = _trace_ticket_label(ticket_id)
    run_suffix = f" run {run_id}" if run_id is not None else ""
    messages = {
        "reasoning-summary": "Considering the next step",
        "clarification-request": "I need a little more detail",
        "reading-context": "Reading project context",
        "ticket-updating": f"Updating {ticket}",
        "ticket-created": f"Created ticket {ticket}",
        "dispatch-preparing": f"Preparing {ticket} dispatch",
        "dispatch-started": f"Dispatching {ticket}",
        "dispatch-claimed": f"{ticket}{run_suffix} claimed",
        "run-running": f"{ticket}{run_suffix} running",
        "run-reviewing": f"Reviewing {ticket}{run_suffix}",
        "run-health-check": f"{ticket}{run_suffix} health check passed",
        "run-health-warning": f"{ticket}{run_suffix} may need attention",
        "run-review-needed": f"{ticket}{run_suffix} awaiting review",
        "run-merging": f"Merging {ticket}{run_suffix}",
        "run-merged": f"{ticket}{run_suffix} merged",
        "run-reconciled": f"{ticket}{run_suffix} history reconciled",
        "run-verification-blocked": f"{ticket}{run_suffix} waiting on external verification",
        "run-verification-resumed": f"{ticket}{run_suffix} verification resumed",
        "run-succeeded": f"{ticket}{run_suffix} succeeded",
        "run-failed": f"{ticket}{run_suffix} failed",
        "run-canceled": f"{ticket}{run_suffix} canceled",
        "running-tests": "Running tests",
        "building": "Building project",
        "installing": "Installing dependencies",
        "preparing-response": "Preparing response",
        "board-change": f"Board updated for {ticket}" if ticket_id else "Board updated",
    }
    return messages[kind]


def orchestration_trace_status_phase(kind: str) -> str:
    return "outcome" if kind in {
        "run-succeeded",
        "run-failed",
        "run-canceled",
        "run-merged",
        "run-reconciled",
        "run-verification-blocked",
    } else "planning"


@dataclass(frozen=True)
class OrchestrationTraceEvent:
    kind: str
    source: str = "orchestrator"
    message: str | None = None
    command: RelayCommandMetadata | None = None
    run_id: int | None = None
    ticket_id: str | None = None
    lifecycle_detail: str | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        kind = self.kind.strip().lower()
        source = self.source.strip().lower()
        if kind not in TRACE_KINDS:
            raise ValueError(f"invalid orchestration trace kind: {self.kind!r}")
        if source not in STATUS_SOURCES:
            raise ValueError(f"invalid trace source: {self.source!r}")
        message = (
            self.message
            if self.message is not None
            else default_orchestration_trace_message(
                kind,
                ticket_id=self.ticket_id,
                run_id=self.run_id,
            )
        )
        public_detail = _public_trace_detail(message)
        object.__setattr__(self, "kind", kind)
        object.__setattr__(self, "source", source)
        object.__setattr__(self, "message", _clip_public_message(public_detail))
        if kind in LIFECYCLE_DETAIL_TRACE_KINDS:
            object.__setattr__(self, "lifecycle_detail", public_detail)
        if self.ticket_id:
            object.__setattr__(self, "ticket_id", self.ticket_id.upper())

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "kind": self.kind,
            "message": self.message,
            "source": self.source,
        }
        if self.lifecycle_detail is not None:
            data["lifecycle_detail"] = self.lifecycle_detail
        if self.command is not None:
            data["command"] = self.command.to_public_dict()
        if self.run_id is not None:
            data["run_id"] = self.run_id
        if self.ticket_id:
            data["ticket_id"] = self.ticket_id
        return data

    def to_status_event_dict(self) -> dict[str, Any] | None:
        if self.command is None:
            return None
        return PMStatusEvent(
            phase=orchestration_trace_status_phase(self.kind),
            message=self.message,
            source=self.source,
            command=self.command,
            ticket_id=self.ticket_id,
            run_id=self.run_id,
        ).to_dict()


@dataclass(frozen=True)
class DelegationRequest:
    ticket_id: str
    repo_path: str
    summary: str
    command: RelayCommandMetadata
    run_id: int | None = None
    pm_controls_dispatch: bool = True
    dependency_assumptions: tuple[str, ...] = ()
    worker_model: str | None = None
    worker_effort: str | None = None
    worker_sizing_rationale: str | None = None
    worker_provider_notes: str | None = None
    dispatcher_context: str | None = None

    def __post_init__(self) -> None:
        if not str(self.ticket_id or "").strip():
            raise ValueError("delegation requests require a ticket_id")
        if not str(self.repo_path or "").strip():
            raise ValueError("delegation requests require a repo_path")
        object.__setattr__(self, "ticket_id", str(self.ticket_id).upper())
        object.__setattr__(self, "repo_path", str(Path(self.repo_path).expanduser()))
        object.__setattr__(self, "summary", _public_message(self.summary))
        object.__setattr__(
            self,
            "dependency_assumptions",
            tuple(str(item).strip().upper() for item in self.dependency_assumptions if str(item).strip()),
        )
        for field in (
            "worker_model",
            "worker_effort",
            "worker_sizing_rationale",
            "worker_provider_notes",
            "dispatcher_context",
        ):
            value = getattr(self, field)
            if value is not None:
                object.__setattr__(self, field, _public_message(value))

    def to_dispatch_payload(self) -> dict[str, Any]:
        payload = {
            "ticket_id": self.ticket_id,
            "repo_path": self.repo_path,
        }
        if self.dispatcher_context:
            payload["context"] = self.dispatcher_context
        payload.update(self.command.to_dispatch_fields())
        return payload

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "ticket_id": self.ticket_id,
            "repo_path": self.repo_path,
            "summary": self.summary,
            "pm_controls_dispatch": self.pm_controls_dispatch,
            "dispatch_payload": self.to_dispatch_payload(),
        }
        if self.dependency_assumptions:
            data["dependency_assumptions"] = list(self.dependency_assumptions)
        for field in (
            "worker_model",
            "worker_effort",
            "worker_sizing_rationale",
            "worker_provider_notes",
            "dispatcher_context",
        ):
            value = getattr(self, field)
            if value:
                data[field] = value
        if self.run_id is not None:
            data["run_id"] = self.run_id
        return data


@dataclass(frozen=True)
class BackstageOutcome:
    kind: str
    message: str
    solo_action: str | None = None
    delegation_requests: tuple[DelegationRequest, ...] = ()
    max_parallel_workers: int = 0
    question: str | None = None

    def __post_init__(self) -> None:
        kind = self.kind.strip().lower()
        if kind not in OUTCOME_KINDS:
            raise ValueError(f"invalid backstage outcome kind: {self.kind!r}")
        object.__setattr__(self, "kind", kind)
        object.__setattr__(self, "message", _public_message(self.message))
        if self.question is not None:
            object.__setattr__(self, "question", _public_message(self.question))
        if self.solo_action is not None:
            object.__setattr__(self, "solo_action", _public_message(self.solo_action))
        requests = tuple(self.delegation_requests)
        object.__setattr__(self, "delegation_requests", requests)
        if kind == "delegate_plan":
            if not requests:
                raise ValueError("delegate_plan requires at least one delegation request")
            if self.max_parallel_workers < 1:
                object.__setattr__(self, "max_parallel_workers", len(requests))
        elif requests:
            raise ValueError(f"{kind} cannot carry delegation requests")

    @staticmethod
    def execute_solo(message: str, *, solo_action: str) -> "BackstageOutcome":
        return BackstageOutcome(
            kind="execute_solo",
            message=message,
            solo_action=solo_action,
        )

    @staticmethod
    def delegate_plan(
        message: str,
        requests: Iterable[DelegationRequest],
        *,
        max_parallel_workers: int | None = None,
    ) -> "BackstageOutcome":
        request_tuple = tuple(requests)
        return BackstageOutcome(
            kind="delegate_plan",
            message=message,
            delegation_requests=request_tuple,
            max_parallel_workers=max_parallel_workers or len(request_tuple),
        )

    @staticmethod
    def needs_user(message: str, *, question: str) -> "BackstageOutcome":
        return BackstageOutcome(
            kind="needs_user",
            message=message,
            question=question,
        )

    @property
    def primary_ticket_id(self) -> str | None:
        if not self.delegation_requests:
            return None
        return self.delegation_requests[0].ticket_id

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "kind": self.kind,
            "message": self.message,
        }
        if self.solo_action:
            data["solo_action"] = self.solo_action
        if self.question:
            data["question"] = self.question
        if self.delegation_requests:
            data["max_parallel_workers"] = self.max_parallel_workers
            data["delegation_requests"] = [
                request.to_dict() for request in self.delegation_requests
            ]
        return data


@dataclass(frozen=True)
class PMRunResult:
    status_events: tuple[PMStatusEvent, ...]
    outcome: BackstageOutcome | None
    stale: bool = False


@dataclass(frozen=True)
class PMUpdateRun:
    ticket_id: str | None
    run_id: int | None
    state: str
    activity: str | None = None

    def __post_init__(self) -> None:
        if self.ticket_id:
            object.__setattr__(self, "ticket_id", str(self.ticket_id).upper())
        object.__setattr__(self, "state", _public_message(self.state))
        object.__setattr__(self, "activity", _public_update_activity(self.activity))


@dataclass(frozen=True)
class PMUpdateSnapshot:
    session_state: str | None = None
    active_runs: tuple[PMUpdateRun, ...] = ()
    blocked_tickets: int = 0
    awaiting_merge: int = 0
    stale_runs: int = 0
    open_tickets: int = 0

    def signature(self, state: str) -> tuple[Any, ...]:
        return (
            state,
            tuple(
                (
                    run.ticket_id,
                    run.run_id,
                    run.state,
                    run.activity,
                )
                for run in self.active_runs
            ),
            self.blocked_tickets,
            self.awaiting_merge,
            self.stale_runs,
            self.open_tickets,
            self.session_state,
        )


@dataclass(frozen=True)
class PMUpdatePollResult:
    continue_running: bool
    state: str
    emitted_event: PMStatusEvent | None = None
    stale: bool = False


def _provider_key(value: Any) -> str | None:
    text = str(value or "").strip().lower()
    if not text:
        return None
    return "claude" if "claude" in text else "codex"


def _normalize_path_text(value: Any) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    return str(Path(raw).expanduser().resolve())


def _select_orchestrator_session(
    sessions_payload: dict[str, Any] | None,
    *,
    repo_path: str,
    provider: str | None = None,
    session_id: int | None = None,
) -> dict[str, Any] | None:
    sessions = []
    if isinstance(sessions_payload, dict):
        raw_sessions = sessions_payload.get("orchestrator_sessions", sessions_payload.get("sessions", []))
        if isinstance(raw_sessions, list):
            sessions = [row for row in raw_sessions if isinstance(row, dict)]
    repo = _normalize_path_text(repo_path)
    provider_key = _provider_key(provider)
    for row in sessions:
        if session_id is not None and int(row.get("id") or 0) == session_id:
            return row
    for row in sessions:
        if _normalize_path_text(row.get("repo_path")) != repo:
            continue
        if provider_key and _provider_key(row.get("provider_key")) != provider_key:
            continue
        return row
    return None


def _summary_item_for_repo(
    program_payload: dict[str, Any] | None,
    *,
    repo_path: str,
) -> dict[str, Any]:
    if not isinstance(program_payload, dict):
        return {}
    repo = _normalize_path_text(repo_path)
    items = program_payload.get("items")
    if not isinstance(items, list):
        return {}
    for item in items:
        if not isinstance(item, dict):
            continue
        project = item.get("project")
        if isinstance(project, dict) and _normalize_path_text(project.get("path")) == repo:
            return item
    return {}


def build_pm_update_snapshot(
    *,
    repo_path: str,
    sessions_payload: dict[str, Any] | None = None,
    runs_payload: dict[str, Any] | None = None,
    program_payload: dict[str, Any] | None = None,
    provider: str | None = None,
    session_id: int | None = None,
) -> PMUpdateSnapshot:
    repo = _normalize_path_text(repo_path)
    provider_key = _provider_key(provider)
    session = _select_orchestrator_session(
        sessions_payload,
        repo_path=repo,
        provider=provider_key,
        session_id=session_id,
    )
    raw_runs = []
    if isinstance(runs_payload, dict):
        payload_runs = runs_payload.get("runs")
        if isinstance(payload_runs, list):
            raw_runs = [row for row in payload_runs if isinstance(row, dict)]

    active_runs: list[PMUpdateRun] = []
    for row in raw_runs:
        if _normalize_path_text(row.get("repo_path")) != repo:
            continue
        if provider_key and _provider_key(row.get("provider_key")) != provider_key:
            continue
        state = str(row.get("state") or "").strip()
        if state not in {"Claimed", "Running"}:
            continue
        active_runs.append(PMUpdateRun(
            ticket_id=str(row.get("ticket_id") or "").strip() or None,
            run_id=int(row["id"]) if row.get("id") is not None else None,
            state=state,
            activity=str(row.get("activity") or "").strip() or None,
        ))

    summary = _summary_item_for_repo(program_payload, repo_path=repo)
    return PMUpdateSnapshot(
        session_state=str((session or {}).get("state") or "").strip().lower() or None,
        active_runs=tuple(active_runs[:3]),
        blocked_tickets=int(summary.get("blocked") or 0),
        awaiting_merge=int(summary.get("awaiting_merge") or 0),
        stale_runs=int(summary.get("stale_runs") or 0),
        open_tickets=int(summary.get("open_tickets") or 0),
    )


def _active_run_message(active_runs: tuple[PMUpdateRun, ...]) -> str:
    parts = []
    for run in active_runs[:2]:
        subject = run.ticket_id or "Worker"
        if run.run_id is not None:
            subject += f" run {run.run_id}"
        detail = run.activity or ("Starting work" if run.state == "Claimed" else "Working")
        parts.append(f"{subject}: {detail}")
    if len(active_runs) == 1:
        return _clip_update_message(parts[0])
    remaining = len(active_runs) - len(parts)
    prefix = f"{len(active_runs)} workers active"
    if remaining > 0:
        prefix += f" (+{remaining} more)"
    return _clip_update_message(prefix + ". " + "; ".join(parts))


def _count_phrase(count: int, singular: str, plural: str | None = None) -> str:
    word = singular if count == 1 else (plural or singular + "s")
    return f"{count} {word}"


def summarize_pm_update_snapshot(
    snapshot: PMUpdateSnapshot,
    *,
    startup_grace_active: bool,
    saw_progress: bool,
) -> tuple[str, str, str]:
    session_state = snapshot.session_state or "idle"
    if session_state in {"failed", "stopped", "stale"}:
        message_map = {
            "failed": "The orchestrator session needs attention before work can continue.",
            "stopped": "The orchestrator session stopped before finishing the status loop.",
            "stale": "The orchestrator session went stale, so update mode stopped.",
        }
        return session_state, "outcome", _clip_update_message(message_map[session_state])

    if snapshot.active_runs:
        return "awaiting_workers", "planning", _active_run_message(snapshot.active_runs)

    if snapshot.blocked_tickets or snapshot.stale_runs:
        parts = []
        if snapshot.blocked_tickets:
            parts.append(_count_phrase(snapshot.blocked_tickets, "blocked ticket"))
        if snapshot.stale_runs:
            parts.append(_count_phrase(snapshot.stale_runs, "stale run"))
        return "blocked", "planning", _clip_update_message("Needs attention: " + ", ".join(parts) + ".")

    if snapshot.awaiting_merge:
        return (
            "reviewing",
            "outcome",
            _clip_update_message(
                "Waiting on review or merge for "
                + _count_phrase(snapshot.awaiting_merge, "ticket")
                + "."
            ),
        )

    if startup_grace_active and not saw_progress:
        return "planning", "planning", "Planning the work and checking current status."

    return "idle", "outcome", "No active worker runs right now."


class PMUpdateMode:
    def __init__(
        self,
        *,
        command: RelayCommandMetadata,
        status_reader: UpdateStatusReader,
        current_command_reader: CurrentCommandReader | None = None,
        emit: StatusEmitter | None = None,
        cadence_seconds: float = 8.0,
        startup_grace_seconds: float = 6.0,
    ) -> None:
        self.command = command
        self.status_reader = status_reader
        self.current_command_reader = current_command_reader
        self.emit_callback = emit
        self.cadence_seconds = max(1.0, float(cadence_seconds))
        self.startup_grace_seconds = max(0.0, float(startup_grace_seconds))
        self.started_at = time.time()
        self.last_emitted_at = 0.0
        self.last_signature: tuple[Any, ...] | None = None
        self.state = "planning"
        self.saw_progress = False

    def poll(self, *, now: float | None = None) -> PMUpdatePollResult:
        moment = time.time() if now is None else now
        if not self._command_is_current():
            self.state = "stale"
            return PMUpdatePollResult(False, state="stale", stale=True)

        snapshot = self.status_reader()
        startup_grace_active = (moment - self.started_at) < self.startup_grace_seconds
        state, phase, message = summarize_pm_update_snapshot(
            snapshot,
            startup_grace_active=startup_grace_active,
            saw_progress=self.saw_progress,
        )
        if state in {"awaiting_workers", "blocked", "reviewing"}:
            self.saw_progress = True

        self.state = state
        signature = snapshot.signature(state)
        if self.last_signature is None and state == "planning" and not self.saw_progress:
            self.last_signature = signature
            return PMUpdatePollResult(True, state=state)
        changed = signature != self.last_signature
        terminal = state in {"failed", "stopped", "stale"} or (state == "idle" and (self.saw_progress or not startup_grace_active))
        event = None
        if changed or (self.last_emitted_at and (moment - self.last_emitted_at) >= self.cadence_seconds and state != "idle"):
            source = "worker" if snapshot.active_runs else "orchestrator"
            event = PMStatusEvent(
                phase=phase,
                message=message,
                source=source,
                command=self.command,
            )
            self.last_emitted_at = moment
            if self.emit_callback is not None:
                self.emit_callback(event)
        self.last_signature = signature
        return PMUpdatePollResult(not terminal, state=state, emitted_event=event)

    def _command_is_current(self) -> bool:
        if self.current_command_reader is None:
            return True
        return self.command.matches(self.current_command_reader())


def default_acknowledgement_builder(
    source_text: str,
    command: RelayCommandMetadata,
) -> str:
    del command
    text = source_text.lower()
    if re.search(r"\b(dispatch|delegate|hand off|spin up|worker)\b", text):
        return "Got it. I will route that through the PM."
    if re.search(r"\b(status|show|summari[sz]e|check|inspect)\b", text):
        return "Got it. I will check that."
    if re.search(r"\b(fix|debug|repair|build|implement|update|refactor)\b", text):
        return "Got it. I will work out the route."
    return "Got it. I am on it."


def default_backstage_planner(
    source_text: str,
    relay_command: dict[str, Any],
    repo_path: str | Path | None = None,
) -> BackstageOutcome:
    command = RelayCommandMetadata.from_dict(relay_command, source_text=source_text)
    action = resolve_command_action(
        source_text,
        repo_path=repo_path,
        relay_command=relay_command,
    )

    if action.kind == "dispatch_ticket" and action.ticket_id:
        request = DelegationRequest(
            ticket_id=action.ticket_id,
            repo_path=action.repo_path or str(Path(repo_path or Path.cwd()).expanduser()),
            summary=action.outcome,
            command=command,
        )
        return BackstageOutcome.delegate_plan(
            "The PM can dispatch one bounded worker with the Relay command attached.",
            [request],
            max_parallel_workers=1,
        )

    if action.kind in {"inline_work", "direct_action", "inspect_ticket", "control"}:
        return BackstageOutcome.execute_solo(
            "This can stay with the PM frontstage session.",
            solo_action=action.outcome,
        )

    if action.kind in {"create_ticket", "update_ticket"}:
        return BackstageOutcome.needs_user(
            "The PM needs a refined visible ticket before dispatching workers.",
            question="Confirm the target project, ticket shape, and acceptance criteria.",
        )

    return BackstageOutcome.needs_user(
        "The PM needs a clearer command before routing work.",
        question="What project or ticket should own this?",
    )


class PMFrontstagePrototype:
    def __init__(
        self,
        *,
        acknowledgement_builder: AcknowledgementBuilder = default_acknowledgement_builder,
        backstage_planner: BackstagePlanner = default_backstage_planner,
        current_command_reader: CurrentCommandReader | None = None,
        emit: StatusEmitter | None = None,
    ) -> None:
        self.acknowledgement_builder = acknowledgement_builder
        self.backstage_planner = backstage_planner
        self.current_command_reader = current_command_reader
        self.emit_callback = emit

    def handle_voice_command(
        self,
        source_text: str,
        relay_command: dict[str, Any],
        *,
        repo_path: str | Path | None = None,
    ) -> PMRunResult:
        command = RelayCommandMetadata.from_dict(relay_command, source_text=source_text)
        relay_fields = command.to_dispatch_fields()
        events: list[PMStatusEvent] = []

        def emit(event: PMStatusEvent) -> None:
            events.append(event)
            if self.emit_callback is not None:
                self.emit_callback(event)

        emit(PMStatusEvent(
            phase="acknowledged",
            message=self.acknowledgement_builder(source_text, command),
            source="pm",
            command=command,
        ))

        if not self._command_is_current(command, fallback=relay_fields):
            emit(self._stale_event(command))
            return PMRunResult(tuple(events), outcome=None, stale=True)

        outcome = self.backstage_planner(source_text, relay_fields, repo_path)
        if not self._command_is_current(command, fallback=relay_fields):
            emit(self._stale_event(command))
            return PMRunResult(tuple(events), outcome=None, stale=True)

        emit(PMStatusEvent(
            phase="outcome",
            message=outcome.message,
            source="orchestrator",
            command=command,
            ticket_id=outcome.primary_ticket_id,
        ))
        return PMRunResult(tuple(events), outcome=outcome, stale=False)

    def _command_is_current(
        self,
        command: RelayCommandMetadata,
        *,
        fallback: dict[str, Any],
    ) -> bool:
        if self.current_command_reader is None:
            current = fallback
        else:
            current = self.current_command_reader()
        return command.matches(current)

    @staticmethod
    def _stale_event(command: RelayCommandMetadata) -> PMStatusEvent:
        return PMStatusEvent(
            phase="stale",
            message="A newer command took over, so this request stopped before action.",
            source="pm",
            command=command,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Exercise the PM-frontstage orchestration prototype.",
    )
    parser.add_argument("--command", required=True, help="Voice command text to route.")
    parser.add_argument("--repo", default=".", help="Repo path used for routing.")
    parser.add_argument("--seq", type=int, default=1, help="Relay command sequence.")
    parser.add_argument("--id", default="demo-command", help="Relay command id.")
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    parser.add_argument(
        "--planner-delay-seconds",
        type=float,
        default=0.0,
        help="Optional artificial backstage delay to observe early status events.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    relay_command = {
        "relay_command_seq": args.seq,
        "relay_command_id": args.id,
        "provider": args.provider,
    }
    current = dict(relay_command)

    def planner(
        source_text: str,
        command_fields: dict[str, Any],
        repo_path: str | Path | None,
    ) -> BackstageOutcome:
        if args.planner_delay_seconds > 0:
            time.sleep(args.planner_delay_seconds)
        return default_backstage_planner(source_text, command_fields, repo_path)

    runner = PMFrontstagePrototype(
        backstage_planner=planner,
        current_command_reader=lambda: current,
        emit=lambda event: print(
            json.dumps({"status_event": event.to_dict()}, sort_keys=True),
            flush=True,
        ),
    )
    result = runner.handle_voice_command(
        args.command,
        relay_command,
        repo_path=args.repo,
    )
    print(json.dumps({
        "outcome": result.outcome.to_dict() if result.outcome else None,
        "provider_parity": PROVIDER_PARITY_NOTES,
        "stale": result.stale,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
