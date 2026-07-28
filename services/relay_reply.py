#!/usr/bin/env python3
"""Publish a canonical foreground reply for the current Relay voice command.

The helper owns FIFO framing and command correlation so providers never need to
construct Relay control envelopes themselves. Diagnostics intentionally omit
reply text, prompt text, command ids, and raw payloads.
"""

from __future__ import annotations

import errno
import json
import os
import sys
from typing import TextIO

VOICE_COMMAND_STATE_FILE = os.environ.get("VOICE_COMMAND_STATE_FILE", "/tmp/voice_command_state.json")
VOICE_COMMAND_CLAIM_FILE = os.environ.get("VOICE_COMMAND_CLAIM_FILE", "/tmp/voice_cmd_claimed.json")
VOICE_FIFO = os.environ.get("VOICE_FIFO", "/tmp/voice_in.fifo")

ORCHESTRATOR_REPLY_PREFIX = "__ORCHESTRATOR_REPLY__:"


def _read_json_file(path: str) -> dict:
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


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


def encode_orchestrator_reply(text: str, command: dict) -> str:
    """Return the sole supported explicit foreground-reply wire envelope."""
    reply = str(text or "").strip()
    key = _relay_command_key(command)
    if not reply or key is None:
        raise ValueError("reply text and Relay command metadata are required")
    payload = {
        "relay_command_id": key[1],
        "relay_command_seq": key[0],
        "text": reply,
    }
    return ORCHESTRATOR_REPLY_PREFIX + json.dumps(payload, sort_keys=True)


def publish_current_reply(
    text: str,
    *,
    claim_path: str = VOICE_COMMAND_CLAIM_FILE,
    state_path: str = VOICE_COMMAND_STATE_FILE,
    fifo_path: str = VOICE_FIFO,
    stderr: TextIO = sys.stderr,
) -> bool:
    """Write one canonical reply only when the claimed command is still current."""
    claim = _read_json_file(claim_path)
    key = _relay_command_key(claim)
    if key is None:
        print("[relay_reply] reply not emitted: claimed command unavailable", file=stderr)
        return False
    if _relay_command_key(_read_json_file(state_path)) != key:
        print("[relay_reply] reply not emitted: claimed command is not current", file=stderr)
        return False
    try:
        line = encode_orchestrator_reply(text, claim)
    except ValueError:
        print("[relay_reply] reply not emitted: final text unavailable", file=stderr)
        return False
    try:
        fd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENXIO):
            print("[relay_reply] reply not emitted: Relay bridge unavailable", file=stderr)
            return False
        raise
    with os.fdopen(fd, "w") as fifo:
        print(line, file=fifo)
    return True


def main() -> int:
    publish_current_reply(sys.stdin.read())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
