"""Relay voice mutation authorization helpers.

Conversational freshness and project-mutation authorization are separate:
`voice_command_state.json` names the newest turn for replies/TTS, while this
module maintains a small sidecar ledger of still-authorized project mutations.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

AUTHORIZATION_CONTRACT_VERSION = 1
AUTHORIZATION_LIMIT = 32
SUPERSEDING_RELATIONSHIPS = frozenset({"replacement", "redirect", "interrupt", "cancel"})
NON_SUPERSEDING_RELATIONSHIPS = frozenset({
    "acknowledgement",
    "additive",
    "conversation",
    "inspection",
    "status",
    "control",
})

_ADDITIVE_RE = re.compile(
    r"\b(also|as\s+well|too|in\s+addition|another|next|and\s+then)\b",
    re.IGNORECASE,
)
_REDIRECT_RE = re.compile(
    r"\b(actually|instead|rather|redirect|switch|change\s+that\s+to|make\s+that)\b",
    re.IGNORECASE,
)
_NATURAL_CANCEL_RE = re.compile(
    r"\b(cancel|stop|abort|scratch\s+that|never\s+mind|nevermind)\b",
    re.IGNORECASE,
)
_TICKET_ID_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9]*-\d+)\b")


def _read_json_file(path: str | Path) -> dict[str, Any]:
    try:
        with Path(path).open() as f:
            data = json.load(f)
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def _atomic_write_json(path: str | Path, payload: dict[str, Any]) -> None:
    target = Path(path)
    tmp = target.with_name(target.name + ".tmp")
    with tmp.open("w") as f:
        json.dump(payload, f, sort_keys=True)
    tmp.replace(target)


def _coerce_seq(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def relay_command_key(command: dict[str, Any] | None) -> tuple[int, str] | None:
    if not isinstance(command, dict):
        return None
    seq = _coerce_seq(command.get("relay_command_seq"))
    command_id = str(command.get("relay_command_id") or "").strip()
    if seq is None or not command_id:
        return None
    return seq, command_id


def command_relationship(
    action_kind: str | None,
    *,
    reason: str | None = None,
    source_text: str | None = None,
) -> str:
    """Classify how a turn affects outstanding project-mutation authority."""
    kind = str(action_kind or "").strip()
    control_reason = str(reason or "").strip().lower()
    text = str(source_text or "")
    if kind == "control":
        if control_reason in {"interrupt", "cancel"}:
            return control_reason
        return "control"
    if kind == "inspect_ticket":
        return "inspection"
    if kind == "conversation":
        return "conversation"
    if kind == "direct_action":
        return "control"
    if kind in {"create_ticket", "update_ticket", "dispatch_ticket", "inline_work"}:
        if _NATURAL_CANCEL_RE.search(text):
            return "cancel"
        if _REDIRECT_RE.search(text):
            return "redirect"
        if _ADDITIVE_RE.search(text):
            return "additive"
        return "replacement"
    return "conversation"


def allowed_mutations_for_metadata(metadata: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the mutation shapes a published Relay command may start."""
    action = str(metadata.get("action") or "").strip()
    source_text = str(metadata.get("source_text") or "")
    ticket_id = str(metadata.get("ticket_id") or "").strip().upper()
    ticket_ids = [match.upper() for match in _TICKET_ID_RE.findall(source_text)]
    if ticket_id and ticket_id not in ticket_ids:
        ticket_ids.insert(0, ticket_id)

    if action == "dispatch_ticket":
        if len(ticket_ids) > 1:
            return [{"kind": "dispatch_ticket", "ticket_ids": ticket_ids}]
        return [{"kind": "dispatch_ticket", "ticket_id": ticket_id or "*"}]

    if action == "create_ticket":
        return [
            {
                "kind": "orchestrator_action",
                "action_kinds": [
                    "create_ticket",
                    "edit_ticket",
                    "update_dependencies",
                    "request_worker",
                ],
                "ticket_id": "*",
            },
            {"kind": "dispatch_ticket", "ticket_id": "*"},
            {"kind": "spike_followup_accept"},
            {"kind": "orchestrator_command"},
        ]

    if action == "update_ticket":
        return [
            {
                "kind": "orchestrator_action",
                "action_kinds": ["edit_ticket", "update_dependencies", "request_worker"],
                "ticket_id": ticket_id or "*",
            },
            {"kind": "dispatch_ticket", "ticket_id": ticket_id or "*"},
            {"kind": "spike_followup_accept"},
            {"kind": "orchestrator_command"},
        ]

    return []


def _load_ledger(path: str | Path) -> dict[str, Any]:
    data = _read_json_file(path)
    authorizations = data.get("authorizations")
    if not isinstance(authorizations, list):
        authorizations = []
    return {
        "version": AUTHORIZATION_CONTRACT_VERSION,
        "updated_at": data.get("updated_at"),
        "authorizations": [item for item in authorizations if isinstance(item, dict)],
    }


def _find_record(
    records: list[dict[str, Any]],
    key: tuple[int, str],
    *,
    intent_id: str | None = None,
) -> dict[str, Any] | None:
    for record in reversed(records):
        if relay_command_key(record) != key:
            continue
        if intent_id is not None and str(record.get("intent_id") or "") != intent_id:
            continue
        return record
    return None


def _prune_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    active = [record for record in records if str(record.get("status") or "") == "active"]
    inactive = [record for record in records if str(record.get("status") or "") != "active"]
    return (inactive[-AUTHORIZATION_LIMIT:] + active)[-AUTHORIZATION_LIMIT:]


def record_command_authorization(
    path: str | Path,
    metadata: dict[str, Any],
    *,
    relationship: str | None = None,
    allowed_mutations: list[dict[str, Any]] | None = None,
    now: float | None = None,
) -> dict[str, Any]:
    """Apply a turn's explicit supersession relationship to the auth ledger."""
    key = relay_command_key(metadata)
    if key is None:
        return _load_ledger(path)
    now = time.time() if now is None else now
    relationship = relationship or str(metadata.get("authorization_relationship") or "conversation")
    allowed_mutations = (
        allowed_mutations
        if allowed_mutations is not None
        else allowed_mutations_for_metadata(metadata)
    )

    ledger = _load_ledger(path)
    records = list(ledger["authorizations"])
    intent_id = str(metadata.get("intent_id") or "").strip() or None
    if relationship in SUPERSEDING_RELATIONSHIPS:
        scope = str(metadata.get("cancellation_scope") or "").strip()
        target_ids = {
            str(value)
            for value in metadata.get("target_intent_ids") or []
            if str(value)
        }
        target_ticket = str(metadata.get("target") or metadata.get("ticket_id") or "").upper()
        for record in records:
            if relay_command_key(record) == key and str(record.get("intent_id") or "") == (intent_id or ""):
                continue
            if str(record.get("status") or "") != "active":
                continue
            if scope in {"item", "ticket"}:
                record_intent = str(record.get("intent_id") or "")
                record_ticket = str(record.get("target") or record.get("ticket_id") or "").upper()
                if target_ids and record_intent not in target_ids:
                    continue
                if not target_ids and target_ticket and record_ticket != target_ticket:
                    continue
                if not target_ids and not target_ticket:
                    continue
            record["status"] = "revoked"
            record["revoked_at"] = now
            record["revoked_by"] = {
                "relay_command_seq": key[0],
                "relay_command_id": key[1],
                "relationship": relationship,
                "intent_id": intent_id,
            }

    if allowed_mutations:
        record = _find_record(records, key, intent_id=intent_id)
        if record is None:
            record = {
                "relay_command_seq": key[0],
                "relay_command_id": key[1],
                "registered_at": now,
                "started_mutations": [],
                "canceled_mutations": [],
            }
            records.append(record)
        record.update({
            "status": "active",
            "relationship": relationship,
            "allowed_mutations": allowed_mutations,
            "updated_at": now,
        })
        for field in ("intent_id", "within_turn_order", "target", "disposition", "cancellation_scope"):
            if metadata.get(field) is not None:
                record[field] = metadata[field]

    ledger["authorizations"] = _prune_records(records)
    ledger["updated_at"] = now
    _atomic_write_json(path, ledger)
    return ledger


def authorization_exists(path: str | Path, relay_command_seq: Any, relay_command_id: Any) -> bool:
    key = relay_command_key({
        "relay_command_seq": relay_command_seq,
        "relay_command_id": relay_command_id,
    })
    if key is None:
        return False
    return _find_record(_load_ledger(path)["authorizations"], key) is not None


def _ticket_allowed(allowed: dict[str, Any], ticket_id: str) -> bool:
    ticket_ids = allowed.get("ticket_ids")
    if isinstance(ticket_ids, list):
        return ticket_id in {
            str(value).strip().upper()
            for value in ticket_ids
            if str(value).strip()
        }
    allowed_ticket = str(allowed.get("ticket_id") or "").strip().upper()
    if not allowed_ticket or allowed_ticket == "*":
        return True
    if allowed_ticket == ticket_id:
        return True
    return False


def mutation_allowed(record: dict[str, Any], mutation: dict[str, Any]) -> bool:
    kind = str(mutation.get("kind") or "").strip()
    action_kind = str(mutation.get("action_kind") or "").strip()
    ticket_id = str(mutation.get("ticket_id") or "").strip().upper()
    for allowed in record.get("allowed_mutations") or []:
        if not isinstance(allowed, dict):
            continue
        if str(allowed.get("kind") or "").strip() != kind:
            continue
        action_kinds = allowed.get("action_kinds")
        if isinstance(action_kinds, list) and action_kind not in {str(value) for value in action_kinds}:
            continue
        if ticket_id and not _ticket_allowed(allowed, ticket_id):
            continue
        return True
    return False


def mutation_fingerprint(mutation: dict[str, Any]) -> str:
    kept = {
        key: mutation.get(key)
        for key in ("kind", "action_kind", "ticket_id", "action_index", "request_id")
        if mutation.get(key) is not None
    }
    return json.dumps(kept, sort_keys=True)


def validate_and_mark_mutation(
    path: str | Path,
    relay_command_seq: Any,
    relay_command_id: Any,
    mutation: dict[str, Any],
    *,
    relay_intent_id: str | None = None,
    now: float | None = None,
) -> dict[str, Any]:
    """Validate an active authorization and mark one bounded mutation started."""
    key = relay_command_key({
        "relay_command_seq": relay_command_seq,
        "relay_command_id": relay_command_id,
    })
    if key is None:
        raise ValueError("stale Relay command: missing mutation authorization metadata")

    now = time.time() if now is None else now
    ledger = _load_ledger(path)
    matching_records = [
        record
        for record in reversed(ledger["authorizations"])
        if relay_command_key(record) == key
        and (
            not relay_intent_id
            or str(record.get("intent_id") or "") == str(relay_intent_id)
        )
    ]
    record = next(
        (
            candidate
            for candidate in matching_records
            if str(candidate.get("status") or "") == "active"
            and mutation_allowed(candidate, mutation)
        ),
        matching_records[0] if matching_records else None,
    )
    if record is None:
        raise ValueError("stale Relay command: no mutation authorization was registered")
    if str(record.get("status") or "") != "active":
        revoked_by = record.get("revoked_by") if isinstance(record.get("revoked_by"), dict) else {}
        relationship = str(revoked_by.get("relationship") or "newer command")
        raise ValueError(
            "stale Relay command: mutation authorization was revoked by "
            f"a newer {relationship} turn"
        )
    if not mutation_allowed(record, mutation):
        raise ValueError("Relay command is not authorized for this mutation")

    fingerprint = mutation_fingerprint(mutation)
    started = record.setdefault("started_mutations", [])
    if fingerprint in {
        str(item.get("fingerprint") or "")
        for item in started
        if isinstance(item, dict)
    }:
        raise ValueError("replayed Relay mutation authorization")
    started.append({
        "fingerprint": fingerprint,
        "mutation": mutation,
        "started_at": now,
    })
    record["updated_at"] = now
    ledger["updated_at"] = now
    _atomic_write_json(path, ledger)
    return record


def mark_mutations_canceled(
    path: str | Path,
    relay_command_seq: Any,
    relay_command_id: Any,
    mutations: list[dict[str, Any]],
    *,
    reason: str,
    now: float | None = None,
) -> None:
    key = relay_command_key({
        "relay_command_seq": relay_command_seq,
        "relay_command_id": relay_command_id,
    })
    if key is None or not mutations:
        return
    now = time.time() if now is None else now
    ledger = _load_ledger(path)
    record = _find_record(ledger["authorizations"], key)
    if record is None:
        return
    canceled = record.setdefault("canceled_mutations", [])
    existing = {
        str(item.get("fingerprint") or "")
        for item in canceled
        if isinstance(item, dict)
    }
    for mutation in mutations:
        fingerprint = mutation_fingerprint(mutation)
        if fingerprint in existing:
            continue
        canceled.append({
            "fingerprint": fingerprint,
            "mutation": mutation,
            "canceled_at": now,
            "reason": reason,
        })
    record["updated_at"] = now
    ledger["updated_at"] = now
    _atomic_write_json(path, ledger)
