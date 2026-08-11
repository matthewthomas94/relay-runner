#!/usr/bin/env python3
"""Relay Runner provider lifecycle hook transport.

The hook observes provider lifecycle JSON on stdin and publishes only Relay
voice-correlated final replies back to the bridge. It also records bounded
automatic-compaction lifecycle diagnostics. It intentionally avoids logging
prompt text, final response text, transcript paths, summaries, or raw payloads.
"""

from __future__ import annotations

import errno
import hashlib
import json
import os
import sys
import time
from typing import Callable, TextIO

VOICE_COMMAND_STATE_FILE = os.environ.get("VOICE_COMMAND_STATE_FILE", "/tmp/voice_command_state.json")
VOICE_COMMAND_CLAIM_FILE = os.environ.get("VOICE_COMMAND_CLAIM_FILE", "/tmp/voice_cmd_claimed.json")
VOICE_PROVIDER_TURNS_FILE = os.environ.get("VOICE_PROVIDER_TURNS_FILE", "/tmp/voice_provider_turns.json")
VOICE_FIFO = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")
PROVIDER_SESSION_ID = os.environ.get("RELAY_PROVIDER_SESSION_ID", "").strip()
PROVIDER_TURN_TTL_SECONDS = float(os.environ.get("VOICE_PROVIDER_TURN_TTL_SECONDS", "3600"))
PROVIDER_TURN_LIMIT = int(os.environ.get("VOICE_PROVIDER_TURN_LIMIT", "32"))
SESSION_EVENTS_FILE = os.environ.get("RELAY_SESSION_EVENTS", "")
CONTEXT_COMPACTION_EVENTS_FILE = os.environ.get(
    "RELAY_CONTEXT_COMPACTION_EVENTS", SESSION_EVENTS_FILE
)
try:
    AUTO_COMPACT_THRESHOLD_TOKENS = max(
        1, int(os.environ.get("RELAY_AUTO_COMPACT_THRESHOLD_TOKENS", "150000"))
    )
except ValueError:
    AUTO_COMPACT_THRESHOLD_TOKENS = 150000
TRANSCRIPT_TAIL_BYTES = 2 * 1024 * 1024

RELAY_COMPLETION_PREFIX = "__RELAY_COMPLETION__:"


def _read_json_file(path: str) -> dict:
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def _atomic_write_json(path: str, payload: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, sort_keys=True)
    os.replace(tmp, path)


def _recent_jsonl_objects(path: str, *, max_bytes: int = TRANSCRIPT_TAIL_BYTES):
    """Yield recent transcript objects newest-first without retaining content."""
    if not path:
        return
    path = os.path.expanduser(path)
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as transcript:
            offset = max(0, size - max_bytes)
            transcript.seek(offset)
            raw = transcript.read(max_bytes)
    except OSError:
        return
    lines = raw.splitlines()
    if offset > 0 and lines:
        lines = lines[1:]
    for line in reversed(lines):
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(value, dict):
            yield value


def _nonnegative_int(value) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed >= 0 else None


def _codex_active_context_tokens(transcript_path: str) -> int | None:
    for record in _recent_jsonl_objects(transcript_path):
        payload = record.get("payload") if record.get("type") == "event_msg" else record
        if not isinstance(payload, dict) or payload.get("type") != "token_count":
            continue
        info = payload.get("info")
        active_usage = info.get("last_token_usage") if isinstance(info, dict) else None
        if isinstance(active_usage, dict):
            return _nonnegative_int(active_usage.get("total_tokens"))
    return None


def _claude_active_context_tokens(transcript_path: str) -> int | None:
    for record in _recent_jsonl_objects(transcript_path):
        if record.get("type") == "system" and record.get("subtype") == "compact_boundary":
            metadata = record.get("compactMetadata")
            post_tokens = (
                _nonnegative_int(metadata.get("postTokens"))
                if isinstance(metadata, dict)
                else None
            )
            if post_tokens is not None:
                return post_tokens
        if record.get("type") != "assistant" or record.get("isSidechain") is True:
            continue
        message = record.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict):
            continue
        components = [
            _nonnegative_int(usage.get("input_tokens")),
            _nonnegative_int(usage.get("cache_creation_input_tokens")),
            _nonnegative_int(usage.get("cache_read_input_tokens")),
        ]
        if any(component is not None for component in components):
            return sum(component or 0 for component in components)
    return None


def _native_active_context_tokens(payload: dict, provider: str | None) -> int | None:
    transcript_path = str(payload.get("transcript_path") or "").strip()
    if provider == "codex":
        return _codex_active_context_tokens(transcript_path)
    if provider == "claude":
        return _claude_active_context_tokens(transcript_path)
    return None


def _append_session_event(event: dict, *, path: str = SESSION_EVENTS_FILE) -> None:
    if not path:
        return
    data = (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode()
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(descriptor, data)
        finally:
            os.close(descriptor)
        os.chmod(path, 0o600)
    except OSError:
        return


def _compaction_attempt_number(
    path: str,
    *,
    provider: str | None,
    session_id: str,
    advance: bool,
) -> int:
    latest = 0
    for record in _recent_jsonl_objects(path, max_bytes=256 * 1024):
        if (
            record.get("stage") != "compaction_attempt"
            or record.get("provider") != (provider or "unknown")
            or record.get("session_id") != session_id
        ):
            continue
        latest = _nonnegative_int(record.get("attempt")) or 0
        break
    return latest + 1 if advance else max(1, latest)


def _pending_unconfirmed_attempt(
    path: str,
    *,
    provider: str | None,
    session_id: str,
) -> int | None:
    for record in _recent_jsonl_objects(path, max_bytes=256 * 1024):
        if (
            record.get("provider") != (provider or "unknown")
            or record.get("session_id") != session_id
        ):
            continue
        stage = record.get("stage")
        if stage == "compaction_unconfirmed":
            return _nonnegative_int(record.get("attempt"))
        if stage in {"compaction_attempt", "compaction_confirmed"}:
            return None
    return None


def _record_compaction_diagnostic(
    payload: dict,
    *,
    now: float,
    events_path: str = CONTEXT_COMPACTION_EVENTS_FILE,
) -> None:
    event_name = _hook_event_name(payload)
    if event_name not in {
        "UserPromptSubmit",
        "Stop",
        "StopFailure",
        "PreCompact",
        "PostCompact",
    }:
        return
    provider = _provider_name(payload)
    active_tokens = _native_active_context_tokens(payload, provider)
    if active_tokens is None:
        threshold_state = "unknown"
    elif active_tokens < AUTO_COMPACT_THRESHOLD_TOKENS:
        threshold_state = "below"
    elif active_tokens == AUTO_COMPACT_THRESHOLD_TOKENS:
        threshold_state = "exact"
    else:
        threshold_state = "above"

    trigger = str(payload.get("trigger") or "").strip().lower() or None
    session_id = _session_id(payload)
    attempt = None
    if event_name in {"PreCompact", "PostCompact", "StopFailure"}:
        attempt = _compaction_attempt_number(
            events_path,
            provider=provider,
            session_id=session_id,
            advance=event_name == "PreCompact",
        )
    post_compact_confirmed = (
        event_name == "PostCompact"
        and active_tokens is not None
        and active_tokens < AUTO_COMPACT_THRESHOLD_TOKENS
    )
    delayed_confirmation_attempt = None
    if (
        event_name in {"UserPromptSubmit", "Stop"}
        and active_tokens is not None
        and active_tokens < AUTO_COMPACT_THRESHOLD_TOKENS
    ):
        delayed_confirmation_attempt = _pending_unconfirmed_attempt(
            events_path,
            provider=provider,
            session_id=session_id,
        )
    compaction_confirmed = post_compact_confirmed or delayed_confirmation_attempt is not None
    if delayed_confirmation_attempt is not None:
        attempt = delayed_confirmation_attempt
    stage_by_event = {
        "UserPromptSubmit": (
            "compaction_confirmed" if delayed_confirmation_attempt is not None
            else "active_context_observed"
        ),
        "Stop": (
            "compaction_confirmed" if delayed_confirmation_attempt is not None
            else "active_context_observed"
        ),
        "StopFailure": "provider_turn_failed",
        "PreCompact": "compaction_attempt",
        "PostCompact": (
            "compaction_confirmed" if post_compact_confirmed else "compaction_unconfirmed"
        ),
    }
    outcome_by_event = {
        "UserPromptSubmit": "confirmed" if delayed_confirmation_attempt is not None else "busy",
        "Stop": "confirmed" if delayed_confirmation_attempt is not None else "idle",
        "StopFailure": "failed",
        "PreCompact": "started",
        "PostCompact": "confirmed" if post_compact_confirmed else "unconfirmed",
    }
    raw_failure_reason = payload.get("error")
    failure_reason = (
        raw_failure_reason[:80]
        if isinstance(raw_failure_reason, str) and raw_failure_reason
        else None
    )
    event = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "stage": stage_by_event[event_name],
        "outcome": outcome_by_event[event_name],
        "provider": provider or "unknown",
        "session_id": session_id,
        "native_active_context_tokens": active_tokens,
        "threshold_tokens": AUTO_COMPACT_THRESHOLD_TOKENS,
        "threshold_state": threshold_state,
        "idle_boundary": "busy" if event_name == "UserPromptSubmit" else "provider_native",
        "attempt": attempt,
        "trigger": trigger,
        "confirmation": compaction_confirmed,
        "failure_reason": (
            "native_context_not_reduced"
            if event_name == "PostCompact" and not post_compact_confirmed
            else failure_reason
        ),
    }
    _append_session_event(event, path=events_path)


def _relay_command_key(command: dict | None) -> tuple[int, str] | None:
    if not isinstance(command, dict):
        return None
    command_id = str(command.get("relay_command_id") or "").strip()
    if not command_id:
        return None
    try:
        command_seq = int(command.get("relay_command_seq"))
    except (TypeError, ValueError):
        return None
    return command_seq, command_id


def _relay_intent_matches(left: dict | None, right: dict | None) -> bool:
    if _relay_command_key(left) != _relay_command_key(right):
        return False
    left_intent = str((left or {}).get("intent_id") or "").strip()
    right_intent = str((right or {}).get("intent_id") or "").strip()
    if left_intent or right_intent:
        return bool(left_intent) and left_intent == right_intent
    return True


def _relay_command_current(command: dict, *, state_path: str) -> bool:
    expected = _relay_command_key(command)
    if expected is None:
        return False
    current = _read_json_file(state_path)
    cancelled = current.get("cancelled_intent_ids")
    if isinstance(cancelled, list) and str(command.get("intent_id") or "") in {
        str(value) for value in cancelled
    }:
        return False
    return _relay_command_key(current) == expected


def _relay_command_deliverable(command: dict, *, state_path: str) -> bool:
    """Accept the exact leased inbox command even when a newer turn is current."""
    expected = _relay_command_key(command)
    if expected is None:
        return False
    state = _read_json_file(state_path)
    if _relay_command_key(state) == expected:
        return True
    deliverable = state.get("deliverable_commands")
    if not isinstance(deliverable, list):
        return False
    return any(
        isinstance(candidate, dict)
        and _relay_intent_matches(candidate, command)
        and str(candidate.get("state") or "") in {"pending", "delivered", "claimed"}
        for candidate in deliverable
    )


def _prompt_matches_claim(prompt: str, claim: dict) -> bool:
    agent_prompt = claim.get("agent_prompt")
    if isinstance(agent_prompt, str) and agent_prompt:
        return prompt == agent_prompt
    source_text = claim.get("source_text")
    return isinstance(source_text, str) and bool(source_text) and prompt == source_text


def _hook_event_name(payload: dict) -> str:
    return str(payload.get("hook_event_name") or payload.get("hookEventName") or "").strip()


def _provider_name(payload: dict, claim: dict | None = None) -> str | None:
    for value in (
        os.environ.get("RELAY_RUNNER_PROVIDER"),
        (claim or {}).get("provider"),
        payload.get("provider"),
    ):
        text = str(value or "").strip().lower()
        if text:
            return text
    return None


def _session_id(payload: dict) -> str:
    for key in ("session_id", "sessionId"):
        value = str(payload.get(key) or "").strip()
        if value:
            return value
    return "unknown"


def _turn_id(payload: dict) -> str | None:
    for key in ("turn_id", "turnId"):
        value = str(payload.get(key) or "").strip()
        if value:
            return value
    return None


def _provider_session_id(payload: dict) -> str | None:
    for key in ("provider_session_id", "providerSessionId"):
        value = str(payload.get(key) or "").strip()
        if value:
            return value
    return PROVIDER_SESSION_ID or None


def _record_key(record: dict) -> str:
    session_id = str(record.get("session_id") or "unknown")
    turn_id = str(record.get("turn_id") or "").strip()
    if turn_id:
        return f"{session_id}:{turn_id}"
    local_turn_seq = _nonnegative_int(record.get("local_turn_seq"))
    if local_turn_seq is not None:
        return f"{session_id}:local:{local_turn_seq}"
    return session_id


def _load_turn_state(path: str, *, now: float | None = None) -> dict:
    now = time.time() if now is None else now
    raw = _read_json_file(path)
    records = raw.get("records") if isinstance(raw, dict) else None
    if not isinstance(records, list):
        records = []
    kept = []
    for record in records:
        if not isinstance(record, dict):
            continue
        updated_at = record.get("updated_at") or record.get("created_at") or now
        try:
            age = now - float(updated_at)
        except (TypeError, ValueError):
            age = 0
        if age <= PROVIDER_TURN_TTL_SECONDS:
            kept.append(record)
    return {
        "version": 1,
        "updated_at": now,
        "records": kept[-PROVIDER_TURN_LIMIT:],
    }


def _save_turn_state(path: str, state: dict) -> None:
    state["records"] = list(state.get("records") or [])[-PROVIDER_TURN_LIMIT:]
    _atomic_write_json(path, state)


def _upsert_turn_record(path: str, record: dict, *, now: float | None = None) -> None:
    now = time.time() if now is None else now
    state = _load_turn_state(path, now=now)
    key = _record_key(record)
    records = [r for r in state["records"] if _record_key(r) != key]
    record = dict(record)
    record["updated_at"] = now
    records.append(record)
    state["records"] = records
    state["updated_at"] = now
    _save_turn_state(path, state)


def _activate_turn_record(
    path: str,
    record: dict,
    *,
    now: float,
    release_reason: str = "superseded_by_prompt_submit",
) -> None:
    """Keep one physical foreground turn active per embedded provider session."""
    provider_session_id = str(record.get("provider_session_id") or "").strip()
    if not provider_session_id:
        _upsert_turn_record(path, record, now=now)
        return

    state = _load_turn_state(path, now=now)
    key = _record_key(record)
    records = []
    for existing in state["records"]:
        if _record_key(existing) == key:
            continue
        if (
            str(existing.get("provider_session_id") or "") == provider_session_id
            and str(existing.get("state") or "") == "active"
        ):
            existing = dict(existing)
            existing["state"] = "orphaned"
            existing["release_reason"] = release_reason
            existing["updated_at"] = now
        records.append(existing)
    record = dict(record)
    record["updated_at"] = now
    records.append(record)
    state["records"] = records
    state["updated_at"] = now
    _save_turn_state(path, state)


def _provider_matches(record: dict, payload: dict) -> bool:
    record_provider = str(record.get("provider") or "").strip().lower()
    payload_provider = _provider_name(payload)
    return not record_provider or not payload_provider or record_provider == payload_provider


def _find_turn_record(
    path: str,
    payload: dict,
    *,
    now: float | None = None,
) -> tuple[dict | None, str, list[dict]]:
    session_id = _session_id(payload)
    turn_id = _turn_id(payload)
    provider_session_id = _provider_session_id(payload)
    state = _load_turn_state(path, now=now)
    records = [
        r
        for r in state["records"]
        if str(r.get("session_id") or "") == session_id
        and (
            not provider_session_id
            or str(r.get("provider_session_id") or "") == provider_session_id
        )
    ]
    if turn_id:
        for record in reversed(records):
            if str(record.get("turn_id") or "") == turn_id:
                return record, "exact_native_identity", [record]
        if not provider_session_id:
            return None, "rejected_provider_session_missing", []
        candidates = [
            record
            for record in state["records"]
            if (
                str(record.get("provider_session_id") or "") == provider_session_id
                and str(record.get("turn_id") or "") == turn_id
                and _relay_command_key(record) is not None
                and _provider_matches(record, payload)
            )
        ]
        if len(candidates) == 1:
            return candidates[0], "provider_identity_reconciled", candidates
        if len(candidates) > 1:
            return None, "rejected_ambiguous_provider_identity", candidates
        return None, "rejected_no_exact_physical_turn", []
    active = [r for r in records if str(r.get("state") or "") == "active"]
    if len(active) == 1:
        return sorted(
            active,
            key=lambda r: float(r.get("updated_at") or r.get("created_at") or 0),
        )[0], "exact_native_session", active
    if len(active) > 1:
        return None, "rejected_ambiguous_native_session", active
    if records:
        return records[-1], "exact_native_session", [records[-1]]
    return None, "rejected_native_identity_mismatch", []


def _record_age_ms(record: dict, *, now: float) -> int:
    created_at = record.get("created_at") or record.get("updated_at") or now
    try:
        return max(0, int(round((now - float(created_at)) * 1000)))
    except (TypeError, ValueError):
        return 0


def _emit_completion_correlation_diagnostic(
    payload: dict,
    *,
    candidates: list[dict],
    decision: str,
    release_reason: str,
    now: float,
    stderr: TextIO,
) -> None:
    diagnostic = {
        "candidate_count": len(candidates),
        "decision": decision,
        "event": _hook_event_name(payload),
        "native_session_id_to": _session_id(payload),
        "native_turn_id": _turn_id(payload),
        "provider": _provider_name(payload) or "unknown",
        "provider_session_id": _provider_session_id(payload),
        "release_reason": release_reason,
    }
    if len(candidates) == 1:
        record = candidates[0]
        diagnostic.update({
            "native_session_id_from": str(record.get("session_id") or "unknown"),
            "record_age_ms": _record_age_ms(record, now=now),
            "relay_command_seq": record.get("relay_command_seq"),
            "relay_command_id": record.get("relay_command_id"),
        })
        if record.get("intent_id") is not None:
            diagnostic["intent_id"] = record["intent_id"]
    elif candidates:
        diagnostic["candidate_commands"] = [
            {
                "relay_command_seq": record.get("relay_command_seq"),
                "relay_command_id": record.get("relay_command_id"),
                "intent_id": record.get("intent_id"),
                "record_age_ms": _record_age_ms(record, now=now),
            }
            for record in candidates
        ]
    print(
        "[relay_completion_hook] completion_correlation "
        + json.dumps(diagnostic, sort_keys=True, separators=(",", ":")),
        file=stderr,
    )


def _annotate_identity_reconciliation(record: dict, payload: dict, *, now: float) -> dict:
    annotated = dict(record)
    annotated["completion_correlation"] = "provider_identity_reconciled"
    annotated["completion_native_session_id"] = _session_id(payload)
    annotated["completion_record_age_ms"] = _record_age_ms(record, now=now)
    return annotated


def _command_turn_records(path: str, command: dict, *, now: float | None = None) -> list[dict]:
    key = _relay_command_key(command)
    if key is None:
        return []
    state = _load_turn_state(path, now=now)
    return [
        record
        for record in state["records"]
        if (
            isinstance(record, dict)
            and _relay_intent_matches(record, command)
            and str(record.get("state") or "") != "stale"
        )
    ]


def _command_bound_to_provider_turn(records: list[dict], payload: dict) -> bool:
    session_id = _session_id(payload)
    turn_id = _turn_id(payload)
    provider_session_id = _provider_session_id(payload)
    matching_session = [
        record
        for record in records
        if str(record.get("session_id") or "") == session_id
        and (
            not provider_session_id
            or str(record.get("provider_session_id") or "") == provider_session_id
        )
    ]
    if turn_id:
        return any(str(record.get("turn_id") or "") == turn_id for record in matching_session)
    return any(str(record.get("state") or "") == "active" for record in matching_session)


def _next_local_turn_seq(path: str, *, session_id: str, now: float) -> int:
    state = _load_turn_state(path, now=now)
    sequences = [
        _nonnegative_int(record.get("local_turn_seq")) or 0
        for record in state["records"]
        if str(record.get("session_id") or "") == session_id
    ]
    return max(sequences, default=0) + 1


def _write_bridge_control(payload: dict, *, fifo_path: str = VOICE_FIFO) -> bool:
    line = RELAY_COMPLETION_PREFIX + json.dumps(payload, sort_keys=True)
    try:
        fd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENXIO):
            return False
        raise
    with os.fdopen(fd, "w") as fifo:
        print(line, file=fifo)
    return True


def _bind_prompt_submit(
    payload: dict,
    *,
    claim_path: str,
    state_path: str,
    turns_path: str,
    now: float,
) -> bool:
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt:
        return False
    if payload.get("parent_tool_use_id") or payload.get("parentToolUseId"):
        return False
    claim = _read_json_file(claim_path)
    correlated = bool(
        claim
        and _relay_command_deliverable(claim, state_path=state_path)
        and _prompt_matches_claim(prompt, claim)
    )

    provider_session_id = _provider_session_id(payload)
    command_records = _command_turn_records(turns_path, claim, now=now) if correlated else []
    if correlated and _command_bound_to_provider_turn(command_records, payload):
        return False
    active_command_records = [
        record
        for record in command_records
        if str(record.get("state") or "") == "active"
        and (
            not provider_session_id
            or str(record.get("provider_session_id") or "") == provider_session_id
        )
    ]
    if correlated and provider_session_id and active_command_records:
        # Codex can emit a startup-scoped prompt identity before its persisted
        # transcript session identity. Rebind the same logical Relay turn to
        # the newest native identity instead of inventing a manual barrier.
        record = dict(active_command_records[-1])
        record["session_id"] = _session_id(payload)
        record.pop("turn_id", None)
        record.pop("local_turn_seq", None)
        turn_id = _turn_id(payload)
        if turn_id:
            record["turn_id"] = turn_id
        else:
            record["local_turn_seq"] = _next_local_turn_seq(
                turns_path,
                session_id=record["session_id"],
                now=now,
            )
        _activate_turn_record(
            turns_path,
            record,
            now=now,
            release_reason="provider_identity_rebound",
        )
        return False
    # Matching text is not a provider-turn identity. Once the Relay command has
    # owned another turn, the same text in a new turn is ordinary manual input.
    if command_records:
        correlated = False

    if not correlated:
        session_id = _session_id(payload)
        record = {
            "state": "active",
            "origin": "manual",
            "session_id": session_id,
            "created_at": now,
        }
        turn_id = _turn_id(payload)
        if turn_id:
            record["turn_id"] = turn_id
        else:
            record["local_turn_seq"] = _next_local_turn_seq(
                turns_path,
                session_id=session_id,
                now=now,
            )
        provider = _provider_name(payload)
        if provider:
            record["provider"] = provider
        if provider_session_id:
            record["provider_session_id"] = provider_session_id
        _activate_turn_record(turns_path, record, now=now)
        return True

    key = _relay_command_key(claim)
    if key is None:
        return False
    record = {
        "state": "active",
        "session_id": _session_id(payload),
        "created_at": now,
        "relay_command_seq": key[0],
        "relay_command_id": key[1],
        "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
    }
    for field in ("intent_id", "within_turn_order", "target", "disposition", "cancellation_scope"):
        if claim.get(field) is not None:
            record[field] = claim[field]
    turn_id = _turn_id(payload)
    if turn_id:
        record["turn_id"] = turn_id
    provider = _provider_name(payload, claim)
    if provider:
        record["provider"] = provider
    if provider_session_id:
        record["provider_session_id"] = provider_session_id
    action = claim.get("action")
    if action:
        record["action"] = action
    _activate_turn_record(turns_path, record, now=now)
    return True


def _complete_turn(
    payload: dict,
    *,
    state_path: str,
    turns_path: str,
    write_control: Callable[[dict], bool],
    now: float,
    stderr: TextIO,
) -> bool:
    record, correlation, candidates = _find_turn_record(turns_path, payload, now=now)
    if not record:
        _emit_completion_correlation_diagnostic(
            payload,
            candidates=candidates,
            decision=correlation,
            release_reason="completion_not_correlated",
            now=now,
            stderr=stderr,
        )
        print("[relay_completion_hook] ignored provider completion without Relay voice correlation", file=stderr)
        return False
    if str(record.get("state") or "") != "active":
        if correlation == "provider_identity_reconciled":
            _emit_completion_correlation_diagnostic(
                payload,
                candidates=candidates,
                decision="rejected_duplicate_provider_completion",
                release_reason=str(record.get("release_reason") or "already_terminal"),
                now=now,
                stderr=stderr,
            )
        print("[relay_completion_hook] ignored duplicate provider completion", file=stderr)
        return False
    identity_reconciled = correlation == "provider_identity_reconciled"
    if _relay_command_key(record) is None:
        event = _hook_event_name(payload)
        completed = dict(record)
        completed["state"] = "failed_manual" if event == "StopFailure" else "completed_manual"
        completed["release_reason"] = (
            "provider_stop_failure" if event == "StopFailure" else "provider_stop"
        )
        _upsert_turn_record(turns_path, completed, now=now)
        return False
    if not _relay_command_current(record, state_path=state_path):
        stale_record = (
            _annotate_identity_reconciliation(record, payload, now=now)
            if identity_reconciled
            else dict(record)
        )
        stale_record["state"] = "stale"
        stale_record["release_reason"] = (
            "stale_current_command_identity_reconciled"
            if identity_reconciled
            else "stale_current_command"
        )
        _upsert_turn_record(turns_path, stale_record, now=now)
        if identity_reconciled:
            _emit_completion_correlation_diagnostic(
                payload,
                candidates=[stale_record],
                decision="accepted_provider_identity_reconciliation",
                release_reason=stale_record["release_reason"],
                now=now,
                stderr=stderr,
            )
        print("[relay_completion_hook] dropped stale Relay provider completion", file=stderr)
        return False

    event = _hook_event_name(payload)
    final_text = ""
    if event == "Stop":
        final_text = str(payload.get("last_assistant_message") or "").strip()
    completion = {
        "event": event,
        "relay_command_seq": record["relay_command_seq"],
        "relay_command_id": record["relay_command_id"],
        "session_id": record.get("session_id"),
    }
    for field in ("intent_id", "within_turn_order", "target", "disposition", "cancellation_scope"):
        if record.get(field) is not None:
            completion[field] = record[field]
    if record.get("turn_id"):
        completion["turn_id"] = record["turn_id"]
    if record.get("provider"):
        completion["provider"] = record["provider"]
    if record.get("action"):
        completion["action"] = record["action"]
    if final_text:
        completion["text"] = final_text
        state = "completed_final"
    else:
        completion["completion_status"] = "failed" if event == "StopFailure" else "empty"
        state = completion["completion_status"]

    delivered = write_control(completion)
    next_record = (
        _annotate_identity_reconciliation(record, payload, now=now)
        if identity_reconciled
        else dict(record)
    )
    next_record["state"] = state
    next_record["delivery"] = "sent" if delivered else "bridge_unavailable"
    if identity_reconciled:
        next_record["release_reason"] = (
            "provider_stop_failure_identity_reconciled"
            if event == "StopFailure"
            else "provider_stop_identity_reconciled"
        )
    else:
        next_record["release_reason"] = (
            "provider_stop_failure" if event == "StopFailure" else "provider_stop"
        )
    _upsert_turn_record(turns_path, next_record, now=now)
    if identity_reconciled:
        _emit_completion_correlation_diagnostic(
            payload,
            candidates=[next_record],
            decision="accepted_provider_identity_reconciliation",
            release_reason=next_record["release_reason"],
            now=now,
            stderr=stderr,
        )
    if not delivered:
        print(
            "[relay_completion_hook] Relay bridge unavailable; provider completion was not spoken. "
            "Check the terminal for the final result.",
            file=stderr,
        )
    return delivered


def handle_hook_payload(
    payload: dict,
    *,
    claim_path: str = VOICE_COMMAND_CLAIM_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    turns_path: str = VOICE_PROVIDER_TURNS_FILE,
    write_control: Callable[[dict], bool] = _write_bridge_control,
    now: float | None = None,
    stderr: TextIO = sys.stderr,
) -> bool:
    now = time.time() if now is None else now
    event = _hook_event_name(payload)
    _record_compaction_diagnostic(payload, now=now)
    if event == "UserPromptSubmit":
        return _bind_prompt_submit(
            payload,
            claim_path=claim_path,
            state_path=state_path,
            turns_path=turns_path,
            now=now,
        )
    if event in {"Stop", "StopFailure"}:
        if payload.get("stop_hook_active"):
            return False
        return _complete_turn(
            payload,
            state_path=state_path,
            turns_path=turns_path,
            write_control=write_control,
            now=now,
            stderr=stderr,
        )
    if event in {"PreCompact", "PostCompact"}:
        return False
    return False


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("[relay_completion_hook] ignored malformed hook JSON", file=sys.stderr)
        return 0
    if not isinstance(payload, dict):
        return 0
    try:
        handle_hook_payload(payload)
    except Exception as exc:
        print(f"[relay_completion_hook] hook transport failed: {type(exc).__name__}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
