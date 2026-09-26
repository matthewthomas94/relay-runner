"""Dependency-free, provisional Task / Action / Discussion qualification.

Buckets describe a turn, never grant permission. The PM receives the original
turn and retains authority; control/cancellation keep their existing path.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import re


_POLITE_LEAD = re.compile(
    r"^\s*(?:(?:hey|hi|okay|ok|so|please)\b[,!\s]*)*"
    r"(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?",
    re.IGNORECASE,
)
_DISCUSSION_ONLY = re.compile(
    r"\b(?:only|just)\s+(?:(?:want|wanted|would\s+like)\s+)?(?:to\s+)?"
    r"(?:discuss|talk\s+(?:through|about)|research|explore|consider|understand)\b"
    r"|\b(?:this\s+is|it['’]?s)\s+(?:only|just)\s+(?:a\s+)?(?:discussion|research|question)\b"
    r"|\b(?:do\s+not|don['’]?t)\s+(?:implement|execute|build|change|do|start)\s+"
    r"(?:it|this|anything|any\s+work)(?:\s+yet)?(?:[.!?,;]|$)"
    r"|\b(?:do\s+not|don['’]?t)\s+(?:implement|execute|act)(?:\s+yet)?(?:[.!?,;]|$)",
    re.IGNORECASE,
)
_ASSENT = re.compile(
    r"^\s*(?:(?:yes|yeah|yep|okay|ok|sure)[,!\s]*)?"
    r"(?:do\s+(?:that|it)|go\s+ahead|proceed|continue)?[.!?\s]*$",
    re.IGNORECASE,
)
_ACTION = re.compile(
    r"^(?:open|launch|reveal|bring\s+up|focus|switch\s+to|close|quit|click|"
    r"double[- ]click|right[- ]click|scroll|press|tap|drag|type|select)\b"
    r"|^(?:start|stop|restart|run|spin\s+up)\s+(?:(?:a|the|our|my)\s+)?"
    r"(?:dev(?:elopment)?\s+server|localhost\s+server)\b"
    r"|^(?:send|write|draft|compose)\s+(?:(?:a|an|the)\s+)?(?:email|e-mail|message)\b",
    re.IGNORECASE,
)
_CLAUSE_BREAK = re.compile(r"[;.!?]\s+|\s+(?:and\s+then|then|and|but)\s+", re.IGNORECASE)
_WORK_LEAD = re.compile(
    r"^(?:fix|build|implement|refactor|create\s+(?:(?:a|the)\s+)?(?:ticket|spike)|"
    r"dispatch|delegate|update|add|remove|write|test)\b", re.IGNORECASE,
)
_DISCUSSION_LEAD = re.compile(r"^(?:discuss|research|explore|explain|why|how|what|was|should)\b", re.IGNORECASE)
_NO_DISPATCH = re.compile(
    r"\b(?:do\s+not|don['’]?t|never)\s+(?:dispatch|implement|execute|start\s+(?:a\s+)?worker)\b"
    r"|\bbacklog\s+only\b|\bonly\s+(?:create|write|draft)\s+(?:a\s+)?ticket\b",
    re.IGNORECASE,
)


def dispatch_forbidden(text: str) -> bool:
    return bool(_NO_DISPATCH.search(text or ""))


def foreground_action_requested(text: str) -> bool:
    return bool(_ACTION.search(_POLITE_LEAD.sub("", text or "", count=1)))


def discussion_only_requested(text: str) -> bool:
    """Recognize whole-turn research constraints, not scoped implementation limits."""
    matches = tuple(_DISCUSSION_ONLY.finditer(text or ""))
    if not matches:
        return False
    # "Create a ticket; do not implement it" still authorizes ticket authoring.
    if re.search(r"\b(?:create|write|draft)\s+(?:a\s+)?ticket\b", text, re.IGNORECASE):
        return any(not re.match(r"(?:do\s+not|don['’]?t)\b", match.group(), re.IGNORECASE) for match in matches)
    return True


def context_dependent_assent(text: str) -> bool:
    return bool((text or "").strip() and _ASSENT.fullmatch(text))


def mixed_bucket_request(text: str) -> bool:
    """Defer recognizably different operations with their full ordered wording."""
    buckets = set()
    for clause in _CLAUSE_BREAK.split(text or ""):
        clause = _POLITE_LEAD.sub("", clause.strip(), count=1)
        if _ACTION.search(clause):
            buckets.add("action")
        elif _WORK_LEAD.search(clause):
            buckets.add("task")
        elif _DISCUSSION_LEAD.search(clause):
            buckets.add("discussion")
    return len(buckets) > 1


def whole_turn_resolution_required(text: str) -> bool:
    return discussion_only_requested(text) or mixed_bucket_request(text) or dispatch_forbidden(text)


@dataclass(frozen=True)
class IntentQualification:
    bucket: str | None
    source: str = "deterministic"
    unresolved: bool = False
    mixed: bool = False
    reason: str = ""
    command_id: str | None = None
    command_seq: int | None = None

    def to_dict(self) -> dict:
        return asdict(self)


def qualify_intent(
    text: str,
    *,
    context=(),
    action_kind: str | None = None,
    action_reason: str | None = None,
    command_id: str | None = None,
    command_seq: int | None = None,
) -> IntentQualification:
    """Qualify without inference or effects; context is reserved for PM resolution.

    A bare assent cannot be resolved safely by a text-only rule even when context
    is supplied. It remains unresolved instead of manufacturing authorization.
    """
    if action_kind is None:
        from command_actions import classify_command

        action = classify_command(text)
        action_kind, action_reason = action.kind, action.reason
    mixed = mixed_bucket_request(text) and not discussion_only_requested(text)
    unresolved = mixed or context_dependent_assent(text) or not (text or "").strip()
    if action_kind == "control":
        bucket, unresolved, mixed = None, False, False
    elif action_kind == "direct_action":
        bucket = "action"
    elif action_kind in {"create_ticket", "update_ticket", "dispatch_ticket", "inline_work", "needs_project"}:
        bucket = "task"
    else:
        bucket = "discussion"
    return IntentQualification(
        bucket=bucket, unresolved=unresolved, mixed=mixed,
        reason="context_required" if context_dependent_assent(text) else (action_reason or action_kind or ""),
        command_id=command_id, command_seq=command_seq,
    )


def format_qualification_for_agent(qualification: IntentQualification) -> str:
    return (
        "\n\nRelay intent qualification (provisional):\n"
        f"- bucket: {qualification.bucket or 'control'}\n"
        f"- source: {qualification.source}\n"
        f"- unresolved: {str(qualification.unresolved).lower()}\n"
        f"- mixed: {str(qualification.mixed).lower()}\n"
        f"- command_id: {qualification.command_id}\n"
        f"- command_seq: {qualification.command_seq}\n"
        "- The PM qualifies the full original turn and may correct this hint. "
        "Task means authorized project/tracked work; Action means a bounded foreground operation; "
        "Discussion includes research and status with read-only tools.\n"
        "- This bucket does not authorize any effect. Apply whole-turn negations and corrections. "
        "Resolve references and mixed scope from conversation; preserve ordered requests and existing accepted work. "
        "Do not invent work from an assent, a discussion, or metadata. Ticket creation, dispatch, "
        "implementation and sending a message each require their applicable user authority."
    )
