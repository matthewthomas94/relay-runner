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
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Union

from command_actions import resolve_command_action


STATUS_PHASES = frozenset({"acknowledged", "planning", "outcome", "stale"})
STATUS_SOURCES = frozenset({"pm", "orchestrator", "worker"})
OUTCOME_KINDS = frozenset({"execute_solo", "delegate_plan", "needs_user"})

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


def _public_message(value: str) -> str:
    message = re.sub(r"\s+", " ", str(value or "")).strip()
    if not message:
        raise ValueError("status events require a public user-facing message")
    return message


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


@dataclass(frozen=True)
class DelegationRequest:
    ticket_id: str
    repo_path: str
    summary: str
    command: RelayCommandMetadata
    run_id: int | None = None
    pm_controls_dispatch: bool = True

    def __post_init__(self) -> None:
        if not str(self.ticket_id or "").strip():
            raise ValueError("delegation requests require a ticket_id")
        if not str(self.repo_path or "").strip():
            raise ValueError("delegation requests require a repo_path")
        object.__setattr__(self, "ticket_id", str(self.ticket_id).upper())
        object.__setattr__(self, "repo_path", str(Path(self.repo_path).expanduser()))
        object.__setattr__(self, "summary", _public_message(self.summary))

    def to_dispatch_payload(self) -> dict[str, Any]:
        payload = {
            "ticket_id": self.ticket_id,
            "repo_path": self.repo_path,
        }
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

    if action.kind in {"inline_work", "inspect_ticket", "control"}:
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

        emit(PMStatusEvent(
            phase="planning",
            message="Checking the project and choosing the route.",
            source="orchestrator",
            command=command,
        ))

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
