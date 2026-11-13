#!/usr/bin/env python3
"""Scripted `claude` and `codex` for the voice bridge's messenger.

The contract suite writes wrappers named `claude` and `codex` that run this
file with the provider name first. It speaks only the two messenger protocols
and never reaches a model:

- `claude auth status --json` answers as a signed-in subscription.
- `claude --print --input-format stream-json --output-format stream-json ...`
  reads `{"type":"user",...}` lines and answers each with stream-json
  `system`, `stream_event`, `assistant` and `result` lines.
- `codex app-server --stdio ...` answers JSON-RPC `initialize`, `model/list`,
  `thread/start`, `turn/start` and `turn/interrupt`, and reports each turn with
  `item/agentMessage/delta` and `turn/completed` notifications.

Every launch and every prompt is appended to `$RELAY_CONTRACT_MESSENGER_LOG`.
`$RELAY_CONTRACT_MESSENGER_SCRIPT` names a JSON file, read again for every
prompt, that scripts the replies:

    {"rules": [{"when": "<text in the event content>", "reply": "...",
                "delay": 0.0, "fail": false}]}

The first rule whose `when` occurs in the prompt's event content applies. An
`auth` object replaces the answer to `claude auth status --json`. A
`reply` may use `{content}` for that content. Without a matching rule a user
turn is answered `__HANDOFF__ Messenger heard: {content}`, a read-only
sidecar task (the text after `Independent user task:`) with
`Sidecar result: {content}`, a prompt that asks
for a realization object gets `{"decision": "full", "spoken_text": content}`,
and any other prompt is answered with its content. `fail` makes the turn fail.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import uuid

LOG = os.environ.get("RELAY_CONTRACT_MESSENGER_LOG", "")
SCRIPT = os.environ.get("RELAY_CONTRACT_MESSENGER_SCRIPT", "")

CODEX_MODELS = {
    "data": [
        {
            "id": "gpt-6-sol", "model": "gpt-6-sol", "displayName": "Sol",
            "isDefault": True, "hidden": False,
            "supportedReasoningEfforts": [{"reasoningEffort": e} for e in ("low", "medium", "high", "xhigh")],
            "defaultReasoningEffort": "medium",
        },
        {
            "id": "gpt-6-luna", "model": "gpt-6-luna", "displayName": "Luna",
            "isDefault": False, "hidden": False,
            "supportedReasoningEfforts": [{"reasoningEffort": e} for e in ("low", "medium", "high")],
            "defaultReasoningEffort": "low",
        },
    ],
    "nextCursor": None,
}

_EVENT_RE = re.compile(r"^Current event: (?P<kind>\S+)$", re.MULTILINE)
_SIDECAR_MARKER = "Independent user task:\n"
_CONTENT_RE = re.compile(
    r"Current event content:\n(?P<content>.*?)(?:\n\nSpeech that actually finished playing|\nReturn only )",
    re.DOTALL,
)


def record(entry: dict) -> None:
    if not LOG:
        return
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({**entry, "pid": os.getpid(), "at": time.time()}, sort_keys=True) + "\n")


def load_script() -> dict:
    try:
        with open(SCRIPT, encoding="utf-8") as handle:
            script = json.load(handle)
    except (OSError, ValueError):
        return {}
    return script if isinstance(script, dict) else {}


def load_rules() -> list:
    rules = load_script().get("rules")
    return rules if isinstance(rules, list) else []


# The environment names whose presence a case checks; values are not recorded.
WATCHED_ENVIRONMENT = (
    "RELAY_ACTOR_ROLE", "RELAY_PROVIDER_SESSION_ID", "RELAY_RUNNER_APP_SESSION",
    "RELAY_RECOVERY_GENERATION", "RELAY_FOREGROUND_GATE_HANDLE", "RELAY_REPLY_HELPER",
)


def launch_record(provider: str, argv: list) -> None:
    record({
        "record": "launch", "provider": provider, "argv": argv, "cwd": os.getcwd(),
        "env": {name: os.environ.get(name) for name in WATCHED_ENVIRONMENT if name in os.environ},
    })


def answer(provider: str, prompt: str) -> tuple[str, dict]:
    """The reply to one prompt, and the rule that chose it."""
    kind_match = _EVENT_RE.search(prompt)
    content_match = _CONTENT_RE.search(prompt)
    kind = kind_match.group("kind") if kind_match else ""
    content = content_match.group("content").strip() if content_match else ""
    if not kind and _SIDECAR_MARKER in prompt:
        # A read-only sidecar task runs on the same protocol as the messenger.
        kind = "sidecar_task"
        content = prompt.split(_SIDECAR_MARKER, 1)[1].strip()
    wants_object = "Return only the JSON object." in prompt
    rule = next(
        (rule for rule in load_rules() if isinstance(rule, dict) and str(rule.get("when", "")) in content),
        {},
    )
    if "reply" in rule:
        reply = str(rule["reply"]).replace("{content}", content)
    elif wants_object:
        reply = json.dumps({"decision": "full", "spoken_text": content})
    elif kind == "user_turn":
        reply = f"__HANDOFF__ Messenger heard: {content}"
    elif kind == "sidecar_task":
        reply = f"Sidecar result: {content}"
    else:
        reply = content
    record({
        "record": "prompt", "provider": provider, "event": kind, "content": content,
        "wants_object": wants_object, "reply": reply, "prompt": prompt,
    })
    return reply, rule


def claude(argv: list) -> int:
    if argv[:2] == ["auth", "status"]:
        launch_record("claude", argv)
        status = load_script().get("auth") or {
            "loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "subscriptionType": "max",
        }
        print(json.dumps(status))
        return 0
    launch_record("claude", argv)
    session_id = str(uuid.uuid4())
    if "--resume" in argv:
        session_id = argv[argv.index("--resume") + 1]

    def emit(payload: dict) -> None:
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()

    emit({"type": "system", "subtype": "init", "session_id": session_id})
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict) or message.get("type") != "user":
            continue
        content = message.get("message", {}).get("content")
        prompt = content if isinstance(content, str) else json.dumps(content)
        reply, rule = answer("claude", prompt)
        time.sleep(float(rule.get("delay") or 0))
        if rule.get("fail"):
            emit({"type": "result", "is_error": True, "result": "scripted failure", "session_id": session_id})
            continue
        emit({
            "type": "stream_event", "session_id": session_id,
            "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": reply}},
        })
        emit({
            "type": "assistant", "session_id": session_id,
            "message": {"role": "assistant", "content": [{"type": "text", "text": reply}]},
        })
        emit({"type": "result", "is_error": False, "result": reply, "session_id": session_id})
    return 0


def codex(argv: list) -> int:
    launch_record("codex", argv)
    if "app-server" not in argv:
        return 2
    write_lock = threading.Lock()
    counter = {"thread": 0, "turn": 0}
    interrupted: set = set()

    def emit(payload: dict) -> None:
        with write_lock:
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()

    def run_turn(thread_id: str, turn_id: str, prompt: str) -> None:
        reply, rule = answer("codex", prompt)
        deadline = time.monotonic() + float(rule.get("delay") or 0)
        while time.monotonic() < deadline and turn_id not in interrupted:
            time.sleep(0.01)
        if turn_id in interrupted:
            emit({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted", "items": []},
            }})
            return
        if rule.get("fail"):
            emit({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": thread_id,
                "turn": {"id": turn_id, "status": "failed", "error": {"message": "scripted failure"}, "items": []},
            }})
            return
        emit({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
            "threadId": thread_id, "turnId": turn_id, "delta": reply,
        }})
        emit({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": thread_id,
            "turn": {"id": turn_id, "status": "completed", "items": [
                {"type": "agentMessage", "text": reply, "phase": "final_answer"},
            ]},
        }})

    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if request_id is None:
            continue  # a notification such as `initialized`
        if method == "initialize":
            result = {"userAgent": "contract-fake"}
        elif method == "model/list":
            result = CODEX_MODELS
        elif method == "thread/start":
            counter["thread"] += 1
            record({"record": "thread", "provider": "codex", "params": params})
            result = {"thread": {"id": f"thread-{counter['thread']}"}}
        elif method == "turn/start":
            counter["turn"] += 1
            turn_id = f"turn-{counter['turn']}"
            items = params.get("input") or []
            prompt = "".join(str(item.get("text") or "") for item in items if isinstance(item, dict))
            emit({"jsonrpc": "2.0", "id": request_id, "result": {"turn": {"id": turn_id}}})
            threading.Thread(
                target=run_turn, args=(str(params.get("threadId") or ""), turn_id, prompt), daemon=True,
            ).start()
            continue
        elif method == "turn/interrupt":
            interrupted.add(str(params.get("turnId") or ""))
            record({"record": "interrupt", "provider": "codex", "params": params})
            result = {}
        else:
            emit({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unknown method"}})
            continue
        emit({"jsonrpc": "2.0", "id": request_id, "result": result})
    return 0


def main() -> int:
    provider, argv = sys.argv[1], sys.argv[2:]
    return claude(argv) if provider == "claude" else codex(argv)


if __name__ == "__main__":
    sys.exit(main())
