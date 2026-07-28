#!/usr/bin/env python3
"""Relay Runner provider lifecycle hook transport.

The hook observes provider lifecycle JSON on stdin and publishes only Relay
voice-correlated final replies back to the bridge. It intentionally avoids
logging prompt text, final response text, transcript paths, or raw payloads.
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
PROVIDER_TURN_TTL_SECONDS = float(os.environ.get("VOICE_PROVIDER_TURN_TTL_SECONDS", "3600"))
PROVIDER_TURN_LIMIT = int(os.environ.get("VOICE_PROVIDER_TURN_LIMIT", "32"))

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


def _relay_command_current(command: dict, *, state_path: str) -> bool:
    expected = _relay_command_key(command)
    if expected is None:
        return False
    current = _read_json_file(state_path)
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
        and _relay_command_key(candidate) == expected
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


def _record_key(record: dict) -> str:
    session_id = str(record.get("session_id") or "unknown")
    turn_id = str(record.get("turn_id") or "").strip()
    return f"{session_id}:{turn_id}" if turn_id else session_id


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


def _find_turn_record(path: str, payload: dict, *, now: float | None = None) -> dict | None:
    session_id = _session_id(payload)
    turn_id = _turn_id(payload)
    state = _load_turn_state(path, now=now)
    records = [r for r in state["records"] if str(r.get("session_id") or "") == session_id]
    if turn_id:
        for record in reversed(records):
            if str(record.get("turn_id") or "") == turn_id:
                return record
    active = [r for r in records if str(r.get("state") or "") == "active"]
    if len(active) == 1:
        return sorted(
            active,
            key=lambda r: float(r.get("updated_at") or r.get("created_at") or 0),
        )[0]
    if len(active) > 1:
        return None
    return records[-1] if records else None


def _command_has_turn_record(path: str, command: dict, *, now: float | None = None) -> bool:
    key = _relay_command_key(command)
    if key is None:
        return False
    state = _load_turn_state(path, now=now)
    return any(
        isinstance(record, dict)
        and _relay_command_key(record) == key
        and str(record.get("state") or "") != "stale"
        for record in state["records"]
    )


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
    if not claim:
        return False
    if not _relay_command_deliverable(claim, state_path=state_path):
        return False
    if not _prompt_matches_claim(prompt, claim):
        return False

    key = _relay_command_key(claim)
    if key is None:
        return False
    if _command_has_turn_record(turns_path, claim, now=now):
        return False
    record = {
        "state": "active",
        "session_id": _session_id(payload),
        "created_at": now,
        "relay_command_seq": key[0],
        "relay_command_id": key[1],
        "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
    }
    turn_id = _turn_id(payload)
    if turn_id:
        record["turn_id"] = turn_id
    provider = _provider_name(payload, claim)
    if provider:
        record["provider"] = provider
    action = claim.get("action")
    if action:
        record["action"] = action
    _upsert_turn_record(turns_path, record, now=now)
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
    record = _find_turn_record(turns_path, payload, now=now)
    if not record:
        print("[relay_completion_hook] ignored provider completion without Relay voice correlation", file=stderr)
        return False
    if not _relay_command_current(record, state_path=state_path):
        stale_record = dict(record)
        stale_record["state"] = "stale"
        _upsert_turn_record(turns_path, stale_record, now=now)
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
    next_record = dict(record)
    next_record["state"] = state
    next_record["delivery"] = "sent" if delivered else "bridge_unavailable"
    _upsert_turn_record(turns_path, next_record, now=now)
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
