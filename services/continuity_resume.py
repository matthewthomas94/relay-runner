"""Deterministic handoff from continuity recovery to the foreground voice path."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Mapping

from continuity_incidents import normalize_recovery_generation, opaque_identifier


PLEASE_REPEAT_TEXT = (
    "Relay Runner is listening again, but your last speech was not captured. "
    "Please repeat your request."
)


@dataclass(frozen=True)
class ContinuityResumeDecision:
    phase: str
    action: str
    reason: str
    intent_id: str | None = None

    def as_dict(self) -> dict[str, str | None]:
        return {
            "phase": self.phase,
            "action": self.action,
            "reason": self.reason,
            "intent_id": self.intent_id,
        }


def _matching_record(
    opaque_command_id: str,
    records: Iterable[Mapping[str, Any]],
) -> Mapping[str, Any] | None:
    matches = []
    for record in records:
        native_command_id = str(record.get("command_id") or "").strip()
        if native_command_id and opaque_identifier("command", native_command_id) == opaque_command_id:
            matches.append(record)
    if not matches:
        return None
    ordered = sorted(
        matches,
        key=lambda item: (
            int(item.get("command_seq") or 0),
            int(item.get("within_turn_order") or 1),
            int(item.get("ordinal") or 0),
        ),
    )
    return next(
        (
            item for item in ordered
            if str(item.get("state") or "") not in {"cancelled", "completed"}
        ),
        ordered[-1],
    )


def plan_continuity_resume(
    incident: Mapping[str, Any],
    records: Iterable[Mapping[str, Any]],
    *,
    final_result: str,
    provider_turn_state: str | None = None,
) -> ContinuityResumeDecision:
    """Choose a fail-closed foreground action without reading command content."""
    normalize_recovery_generation(incident.get("recovery_generation"))
    if final_result != "restored":
        return ContinuityResumeDecision(
            "recovery_incomplete", "foreground_review", "stable_health_not_proven"
        )

    command_id = incident.get("command_id")
    if not command_id:
        return ContinuityResumeDecision(
            "speech_not_captured", "ask_repeat", "no_durable_command"
        )

    record = _matching_record(str(command_id), records)
    if record is None:
        return ContinuityResumeDecision(
            "command_state_unknown", "foreground_review", "durable_command_not_found"
        )

    state = str(record.get("state") or "")
    intent_id = str(record.get("intent_id") or "") or None
    if state == "pending":
        return ContinuityResumeDecision(
            "transcript_captured", "resume_exact", "captured_not_delivered", intent_id
        )
    if state in {"delivered", "recovery_pending"}:
        return ContinuityResumeDecision(
            "delivered_unclaimed", "resume_exact", "delivery_provably_unclaimed", intent_id
        )
    if state in {"claimed", "review_required"}:
        return ContinuityResumeDecision(
            "claimed_ambiguous", "foreground_review", "claim_may_have_started_effect", intent_id
        )
    if state == "acked":
        if provider_turn_state in {"active", "completed_final"}:
            return ContinuityResumeDecision(
                "in_flight_or_completed", "reattach", "authoritative_provider_state", intent_id
            )
        return ContinuityResumeDecision(
            "in_flight_or_completed",
            "foreground_review",
            "provider_state_ambiguous",
            intent_id,
        )
    if state in {"cancelled", "completed"}:
        return ContinuityResumeDecision(
            "completed_or_revoked", "noop", "terminal_command", intent_id
        )
    return ContinuityResumeDecision(
        "command_state_unknown", "foreground_review", "unsupported_command_state", intent_id
    )
