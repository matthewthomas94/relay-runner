"""Provider-neutral arbitration for voice work received during active work."""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
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


class CancellationScope(str, Enum):
    NONE = "none"
    ITEM = "item"
    TICKET = "ticket"
    ALL_WORK = "all_work"
    AMBIGUOUS = "ambiguous"


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
_GLOBAL_CANCEL_RE = re.compile(
    r"\b(?:all\s+(?:accepted\s+)?work|all\s+(?:the\s+)?(?:tasks|tickets|items)|"
    r"everything|every\s+(?:task|ticket|item)|the\s+whole\s+(?:queue|turn))\b",
    re.IGNORECASE,
)
_TICKET_ID_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9]*-\d+)\b")
_ITEM_START = (
    r"add|build|cancel|change|click|create|debug|delete|design|dispatch|drag|edit|fix|"
    r"focus|implement|install|launch|merge|never\s+mind|nevermind|open|press|redirect|"
    r"refactor|remove|repair|replace|reveal|run|scratch|scroll|select|ship|show|start|stop|"
    r"switch|tap|test|type|update|wire|write"
)
_ITEM_BOUNDARY_RE = re.compile(
    rf"(?<!go ahead)(?:\s*[.;]\s*|\s+\b(?:and(?:\s+then)?|but|then)\b\s+)"
    rf"(?=(?:please\s+)?(?:{_ITEM_START})\b)",
    re.IGNORECASE,
)
_CANCEL_TARGET_RE = re.compile(
    r"\b(?:cancel|stop|abort|scratch(?:\s+that)?|never\s+mind|nevermind)\b"
    r"(?:\s+(?:the|that|this|last|current))?\s*(.*)$",
    re.IGNORECASE,
)
_TARGET_STOP_WORDS = {
    "a", "all", "an", "and", "current", "everything", "item", "please",
    "task", "that", "the", "this", "ticket", "to", "work",
}
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
    target: str | None = None


@dataclass(frozen=True)
class VoiceWorkItem:
    """One stable, ordered unit recognized from a Relay voice turn."""

    intent_id: str
    source_command_seq: int
    source_command_id: str
    within_turn_order: int
    source_text: str
    target: str | None
    disposition: str = "accepted"
    cancellation_scope: CancellationScope = CancellationScope.NONE
    lifecycle_state: str = "recognized"
    target_intent_ids: tuple[str, ...] = ()

    def to_dict(self) -> dict:
        payload = asdict(self)
        payload["cancellation_scope"] = self.cancellation_scope.value
        payload["target_intent_ids"] = list(self.target_intent_ids)
        return payload


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
    cancellation_scope: CancellationScope = CancellationScope.NONE

    def to_dict(self) -> dict:
        payload = asdict(self)
        payload["route"] = self.route.value
        payload["authorization_effect"] = self.authorization_effect.value
        payload["target_work_ids"] = list(self.target_work_ids)
        payload["conflicting_work_ids"] = list(self.conflicting_work_ids)
        payload["resource_claims"] = list(self.resource_claims)
        payload["cancellation_scope"] = self.cancellation_scope.value
        return payload


def _target_words(value: str | None) -> set[str]:
    return {
        word.lower()
        for word in re.findall(r"[A-Za-z0-9_-]+", str(value or ""))
        if word.lower() not in _TARGET_STOP_WORDS
    }


def _item_target(source_text: str, *, cancellation: bool = False) -> str | None:
    ticket = _TICKET_ID_RE.search(source_text)
    if ticket:
        return ticket.group(1).upper()
    text = source_text.strip()
    if cancellation:
        match = _CANCEL_TARGET_RE.search(text)
        text = match.group(1).strip() if match else ""
    else:
        text = re.sub(rf"^\s*(?:please\s+)?(?:{_ITEM_START})\b\s*", "", text, flags=re.IGNORECASE)
    words = [word for word in re.findall(r"[A-Za-z0-9_-]+", text) if word.lower() not in _TARGET_STOP_WORDS]
    return " ".join(words[:6]).lower() or None


def _matching_prior_item(
    items: list[VoiceWorkItem],
    target: str | None,
    source_text: str,
) -> VoiceWorkItem | None:
    candidates = [item for item in items if item.lifecycle_state != "cancelled"]
    if not candidates:
        return None
    if re.search(r"\b(?:that|this|it|last)\b", source_text, re.IGNORECASE) and not target:
        return candidates[-1]
    target_words = _target_words(target)
    if target_words:
        for item in reversed(candidates):
            item_words = _target_words(item.target) | _target_words(item.source_text)
            if target_words <= item_words or target_words & item_words:
                return item
    return candidates[-1] if len(candidates) == 1 and not target else None


def normalize_voice_work_items(
    source_text: str,
    *,
    relay_command_seq: int,
    relay_command_id: str,
) -> tuple[VoiceWorkItem, ...]:
    """Split a completed turn into durable ordered work/cancellation items."""
    text = str(source_text or "").strip()
    if not text:
        return ()
    clauses = [part.strip(" ,") for part in _ITEM_BOUNDARY_RE.split(text) if part.strip(" ,")]
    items: list[VoiceWorkItem] = []
    for order, clause in enumerate(clauses, start=1):
        cancellation = explicit_cancel_requested(clause)
        scope = CancellationScope.NONE
        target = _item_target(clause, cancellation=cancellation)
        target_ids: tuple[str, ...] = ()
        disposition = "accepted"
        if cancellation:
            if _GLOBAL_CANCEL_RE.search(clause):
                scope = CancellationScope.ALL_WORK
            elif _TICKET_ID_RE.search(clause):
                scope = CancellationScope.TICKET
            else:
                prior = _matching_prior_item(items, target, clause)
                if prior is not None:
                    scope = CancellationScope.ITEM
                    target_ids = (prior.intent_id,)
                    items[items.index(prior)] = replace(
                        prior,
                        disposition="abandoned",
                        cancellation_scope=CancellationScope.ITEM,
                        lifecycle_state="cancelled",
                    )
                elif target:
                    scope = CancellationScope.ITEM
                else:
                    scope = CancellationScope.AMBIGUOUS
            disposition = "cancellation"
        items.append(VoiceWorkItem(
            intent_id=f"{relay_command_id}:item:{order}",
            source_command_seq=int(relay_command_seq),
            source_command_id=str(relay_command_id),
            within_turn_order=order,
            source_text=clause,
            target=target,
            disposition=disposition,
            cancellation_scope=scope,
            lifecycle_state="recognized",
            target_intent_ids=target_ids,
        ))
    return tuple(items)


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
    cancellation_scope: CancellationScope | str | None = None,
    target_work_ids: Iterable[str] = (),
) -> IntentDisposition:
    """Resolve exactly one safe route relative to already accepted work."""
    active = tuple(active_work)
    active_ids = tuple(work.work_id for work in active)
    kind = str(action_kind or "conversation")
    reason = str(action_reason or "").strip().lower()
    text = str(source_text or "")
    if isinstance(cancellation_scope, CancellationScope):
        scope = cancellation_scope
    else:
        try:
            scope = CancellationScope(str(cancellation_scope or CancellationScope.NONE.value))
        except ValueError:
            scope = CancellationScope.AMBIGUOUS
    resolved_targets = tuple(str(value) for value in target_work_ids if str(value))
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
        *(
            (ExclusiveResource.DESKTOP.value,)
            if kind == "direct_action"
            else ()
        ),
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
    if explicit_replace and scope == CancellationScope.NONE:
        if reason == "interrupt" or _GLOBAL_CANCEL_RE.search(text):
            scope = CancellationScope.ALL_WORK
        elif _TICKET_ID_RE.search(text):
            scope = CancellationScope.TICKET
        elif re.search(r"\b(?:that|this|it|last|current)\b", text, re.IGNORECASE):
            scope = CancellationScope.ITEM
            if not resolved_targets and active_ids:
                resolved_targets = (active_ids[-1],)
        else:
            scope = CancellationScope.AMBIGUOUS
    if active and explicit_replace and scope == CancellationScope.AMBIGUOUS:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.CLARIFY_PRIORITY,
            target_work_ids=active_ids,
            conflicting_work_ids=(),
            public_reason="The cancellation target is ambiguous, so accepted work remains unchanged.",
            clarification_question="Which item or ticket should I cancel, or should I cancel all accepted work?",
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=resources,
            cancellation_scope=scope,
        )
    if active and explicit_replace:
        conflicts = active_ids if scope == CancellationScope.ALL_WORK else resolved_targets
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.REPLACE_CURRENT,
            target_work_ids=conflicts,
            conflicting_work_ids=conflicts,
            public_reason=(
                "The completed turn explicitly cancels all accepted work."
                if scope == CancellationScope.ALL_WORK
                else "The completed turn cancels only the resolved item or ticket."
            ),
            clarification_question=None,
            authorization_effect=AuthorizationEffect.REVOKE_CONFLICTING,
            resource_claims=resources,
            cancellation_scope=scope,
        )

    if explicit_replace and scope in {CancellationScope.ITEM, CancellationScope.TICKET}:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.REPLACE_CURRENT,
            target_work_ids=resolved_targets,
            conflicting_work_ids=resolved_targets,
            public_reason="Recorded a scoped cancellation without widening it to unrelated work.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.REVOKE_CONFLICTING,
            resource_claims=resources,
            cancellation_scope=scope,
        )

    if explicit_replace and scope == CancellationScope.ALL_WORK:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.REPLACE_CURRENT,
            target_work_ids=active_ids,
            conflicting_work_ids=active_ids,
            public_reason="The completed turn explicitly cancels all accepted work.",
            clarification_question=None,
            authorization_effect=AuthorizationEffect.REVOKE_CONFLICTING,
            resource_claims=resources,
            cancellation_scope=scope,
        )

    if explicit_replace and scope == CancellationScope.AMBIGUOUS:
        return IntentDisposition(
            intent_id=intent_id,
            route=IntentRoute.CLARIFY_PRIORITY,
            target_work_ids=(),
            conflicting_work_ids=(),
            public_reason="The cancellation target is ambiguous.",
            clarification_question="Which item or ticket should I cancel?",
            authorization_effect=AuthorizationEffect.PRESERVE,
            resource_claims=resources,
            cancellation_scope=scope,
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
            if fallback == "inspection":
                return fallback
            return "conversation"
        return "additive"
    return fallback
