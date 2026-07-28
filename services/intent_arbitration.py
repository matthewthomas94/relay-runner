"""Provider-neutral arbitration for voice work received during active work."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
import re
from typing import Iterable


class IntentRoute(str, Enum):
    CONTINUE_CURRENT = "continue_current"
    RUN_SIDECAR = "run_sidecar"
    QUEUE_PROJECT_WORK = "queue_project_work"
    CLARIFY_PRIORITY = "clarify_priority"
    REPLACE_CURRENT = "replace_current"
    CONTROL_ONLY = "control_only"


class AuthorizationEffect(str, Enum):
    PRESERVE = "preserve"
    REVOKE_CONFLICTING = "revoke_conflicting"
    NONE = "none"


class ExclusiveResource(str, Enum):
    REPOSITORY = "repository"
    DESKTOP = "desktop"
    EXTERNAL_SIDE_EFFECT = "external_side_effect"


_EXPLICIT_REPLACE_RE = re.compile(
    r"\b(cancel|stop|abort|scratch\s+that|never\s+mind|nevermind|"
    r"actually\s+instead|replace\s+(?:that|it)|redirect|switch\s+to)\b",
    re.IGNORECASE,
)
_CANCEL_RE = re.compile(
    r"\b(cancel|stop|abort|scratch\s+that|never\s+mind|nevermind)\b",
    re.IGNORECASE,
)
_NEGATED_REPLACE_RE = re.compile(
    r"\b(?:don'?t|do\s+not|never|no\s+need\s+to)\s+"
    r"(?:\w+\s+){0,3}?"
    r"(?:cancel|stop|abort)(?:\s+(?:or|and)\s+(?:cancel|stop|abort))*\b",
    re.IGNORECASE,
)
_AMBIGUOUS_SWITCH_RE = re.compile(
    r"\b(should\s+(?:we|i)\s+switch|maybe\s+instead|could\s+(?:we|you)\s+switch)\b",
    re.IGNORECASE,
)
_SPEECH_ONLY_RE = re.compile(
    r"\b(?:be\s+quiet|mute|stop\s+(?:the\s+)?(?:audio|playback|speaking|talking))\b",
    re.IGNORECASE,
)
_ADDITIVE_RE = re.compile(
    r"\b(also|as\s+well|in\s+addition|another|and\s+then|while\s+you(?:'re|\s+are))\b",
    re.IGNORECASE,
)
_SIDECAR_RE = re.compile(
    r"\b(in\s+parallel|sidecar|meanwhile)\b.*"
    r"\b(research|inspect|look\s+up|compare|analy[sz]e|summari[sz]e|check)\b",
    re.IGNORECASE,
)
_MUTATION_RE = re.compile(
    r"\b(add|build|change|create|delete|dispatch|edit|fix|implement|install|"
    r"merge|push|remove|send|update|write)\b",
    re.IGNORECASE,
)
_RESOURCE_PATTERNS = {
    ExclusiveResource.REPOSITORY: re.compile(
        r"\b(code|codebase|file|files|project|repo|repository|source\s+tree|worktree)\b",
        re.IGNORECASE,
    ),
    ExclusiveResource.DESKTOP: re.compile(
        r"\b(browser|desktop|screenshot|window)\b|\bon[- ]screen\b",
        re.IGNORECASE,
    ),
    ExclusiveResource.EXTERNAL_SIDE_EFFECT: re.compile(
        r"\b(calendar|email|message|payment|post|publish|purchase|slack)\b",
        re.IGNORECASE,
    ),
}


@dataclass(frozen=True)
class ActiveWork:
    work_id: str
    resources: tuple[str, ...] = ()


@dataclass(frozen=True)
class IntentDisposition:
    intent_id: str
    route: IntentRoute
    target_work_ids: tuple[str, ...]
    conflicting_work_ids: tuple[str, ...]
    public_reason: str
    clarification_question: str | None
    authorization_effect: AuthorizationEffect
    resource_claims: tuple[str, ...] = ()

    def to_dict(self) -> dict:
        payload = asdict(self)
        payload["route"] = self.route.value
        payload["authorization_effect"] = self.authorization_effect.value
        payload["target_work_ids"] = list(self.target_work_ids)
        payload["conflicting_work_ids"] = list(self.conflicting_work_ids)
        payload["resource_claims"] = list(self.resource_claims)
        return payload


def inferred_resource_claims(source_text: str) -> tuple[str, ...]:
    text = str(source_text or "")
    return tuple(
        resource.value
        for resource, pattern in _RESOURCE_PATTERNS.items()
        if pattern.search(text)
    )


def explicit_replace_requested(source_text: str, *, action_reason: str = "") -> bool:
    """Return whether completed language positively requests work preemption."""
    text = str(source_text or "")
    negated = bool(_NEGATED_REPLACE_RE.search(text))
    unnegated_text = _NEGATED_REPLACE_RE.sub("", text)
    if _EXPLICIT_REPLACE_RE.search(unnegated_text):
        return True
    return action_reason.strip().lower() in {
        "cancel",
        "interrupt",
        "redirect",
        "replace",
    } and not negated


def explicit_cancel_requested(source_text: str) -> bool:
    """Return whether completed language positively requests cancellation."""
    text = _NEGATED_REPLACE_RE.sub("", str(source_text or ""))
    return bool(_CANCEL_RE.search(text))


def sidecar_eligible(
    *,
    source_text: str,
    active_work: Iterable[ActiveWork],
    requested_resources: Iterable[str] = (),
    project_mutation: bool = False,
) -> bool:
    """Return whether a bounded read-only sidecar can run without contention."""
    text = str(source_text or "")
    if project_mutation or _MUTATION_RE.search(text) or not _SIDECAR_RE.search(text):
        return False
    requested = {str(resource) for resource in requested_resources}
    exclusive = {resource.value for resource in ExclusiveResource}
    if requested & exclusive:
        return False
    active_resources = {
        str(resource)
        for work in active_work
        for resource in work.resources
    }
    return not bool(requested & active_resources)


def resolve_intent_disposition(
    *,
    intent_id: str,
    action_kind: str,
    action_reason: str | None,
    source_text: str,
    active_work: Iterable[ActiveWork] = (),
    requested_resources: Iterable[str] = (),
) -> IntentDisposition:
    """Resolve exactly one safe route relative to already accepted work."""
    active = tuple(active_work)
    active_ids = tuple(work.work_id for work in active)
    kind = str(action_kind or "conversation")
    reason = str(action_reason or "").strip().lower()
    text = str(source_text or "")
    if (
        kind == "control"
        and reason in {"cancel", "interrupt", "redirect", "replace"}
        and _NEGATED_REPLACE_RE.search(text)
        and not explicit_replace_requested(text, action_reason=reason)
    ):
        kind = "conversation"
        reason = ""
    resources = tuple(sorted({
        *(str(resource) for resource in requested_resources),
        *inferred_resource_claims(text),
    }))

    if kind == "control" and reason not in {"cancel", "interrupt", "redirect", "replace"}:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.CONTROL_ONLY,
            target_work_ids=(),
            conflicting_work_ids=(),
            public_reason="Handled as a speech or session control.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.NONE,
            resource_claims=resources,
        )

    if kind == "control" and _SPEECH_ONLY_RE.search(text):
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.CONTROL_ONLY,
            target_work_ids=active_ids,
            conflicting_work_ids=(),
            public_reason="Stopped speech without changing accepted work.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=resources,
        )

    if active and _AMBIGUOUS_SWITCH_RE.search(text):
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.CLARIFY_PRIORITY,
            target_work_ids=active_ids,
            conflicting_work_ids=active_ids,
            public_reason="Queueing and switching would produce materially different outcomes.",
            clarification_question="Should I queue this behind the current work, or switch to it now?",
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=resources,
        )

    explicit_replace = explicit_replace_requested(text, action_reason=reason)
    if active and explicit_replace:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.REPLACE_CURRENT,
            target_work_ids=(),
            conflicting_work_ids=active_ids,
            public_reason="The completed turn explicitly cancels or redirects active work.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.REVOKE_CONFLICTING,
            resource_claims=resources,
        )

    project_mutation = kind in {
        "create_ticket",
        "update_ticket",
        "dispatch_ticket",
        "inline_work",
    }
    if active and sidecar_eligible(
        source_text=text,
        active_work=active,
        requested_resources=resources,
        project_mutation=project_mutation,
    ):
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.RUN_SIDECAR,
            target_work_ids=active_ids,
            conflicting_work_ids=(),
            public_reason="The task is bounded, read-only, independently verifiable, and resource-safe.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=resources,
        )

    if active and _SIDECAR_RE.search(text) and not project_mutation:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.QUEUE_PROJECT_WORK,
            target_work_ids=active_ids,
            conflicting_work_ids=active_ids,
            public_reason="The requested parallel task conflicts with exclusive active resources, so it is queued.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=resources,
        )

    if project_mutation:
        reason_text = (
            "Project-changing work is queued on the native Relay ticket path."
            if active
            else "Project-changing work uses the native Relay ticket path."
        )
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.QUEUE_PROJECT_WORK,
            target_work_ids=active_ids,
            conflicting_work_ids=active_ids if active else (),
            public_reason=reason_text,
            clarification_question=None,
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=tuple(sorted({
                *resources,
                ExclusiveResource.REPOSITORY.value,
            })),
        )

    if kind == "control":
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.CONTROL_ONLY,
            target_work_ids=active_ids,
            conflicting_work_ids=(),
            public_reason="No active work required preemption.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.NONE,
            resource_claims=resources,
        )

    reason_text = (
        "The turn adds context, asks for status, or can safely steer active work."
        if active or _ADDITIVE_RE.search(text)
        else "The turn can proceed in the foreground orchestration context."
    )
    return IntentDisposition(
        intent_id=intent_id,
        route=IntentRoute.CONTINUE_CURRENT,
        target_work_ids=active_ids,
        conflicting_work_ids=(),
        public_reason=reason_text,
        clarification_question=None,
        authorization_effect=AuthorizationEffect.PRESERVE,
        resource_claims=resources,
    )


def authorization_relationship_for(disposition: IntentDisposition, *, fallback: str) -> str:
    """Map work arbitration to the existing bounded-mutation ledger."""
    if disposition.authorization_effect == AuthorizationEffect.REVOKE_CONFLICTING:
        return "redirect"
    if disposition.authorization_effect == AuthorizationEffect.PRESERVE:
        if disposition.route == IntentRoute.CONTINUE_CURRENT:
            return "conversation"
        return "additive"
    return fallback
