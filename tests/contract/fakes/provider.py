#!/usr/bin/env python3
"""Scripted stand-in for the `claude` and `codex` CLIs.

The contract suite puts wrappers named `claude` and `codex` on the daemon's
PATH; each runs this file with the provider name as its first argument. The
fake never reaches a model. It recognises the daemon's launch shapes, records
every invocation, and acts out the role named by the prompt on stdin.

State lives in the directory named by RELAY_CONTRACT_FAKE_STATE:

    invocations.jsonl      one JSON line per launch (argv, cwd, role, ...)
    plans/<role>.<id>.json  optional behaviour for one ticket or task
    plans/<role>.json       optional behaviour for every launch of that role

A plan is a JSON object. Keys every role understands:

    exit_code   int   exit with this status after the scripted output
    hold        path  wait until this file exists before doing anything
    events      list  extra provider output lines, emitted first

Role-specific keys are documented beside each role below. With no plan the
role does what a well-behaved worker would do.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

STATE = Path(os.environ.get("RELAY_CONTRACT_FAKE_STATE", ""))

CODEX_MODELS = {
    "data": [
        {
            "id": "gpt-6-sol",
            "model": "gpt-6-sol",
            "displayName": "Sol",
            "isDefault": True,
            "hidden": False,
            "supportedReasoningEfforts": [
                {"reasoningEffort": effort} for effort in ("low", "medium", "high", "xhigh")
            ],
            "defaultReasoningEffort": "medium",
        },
        {
            "id": "gpt-6-luna",
            "model": "gpt-6-luna",
            "displayName": "Luna",
            "isDefault": False,
            "hidden": False,
            "supportedReasoningEfforts": [
                {"reasoningEffort": effort} for effort in ("low", "medium", "high")
            ],
            "defaultReasoningEffort": "low",
        },
        {
            "id": "gpt-6-astra",
            "model": "gpt-6-astra",
            "displayName": "Astra",
            "isDefault": False,
            "hidden": False,
            "supportedReasoningEfforts": [
                {"reasoningEffort": effort}
                for effort in ("low", "medium", "high", "xhigh", "max", "ultra")
            ],
            "defaultReasoningEffort": "high",
        },
    ],
    "nextCursor": None,
}

SPIKE_RESULT = {
    "conclusions": ["The scripted spike reached a conclusion."],
    "evidence": [{"source": "README.md", "finding": "The snapshot contains the project readme."}],
    "uncertainties": ["Nothing was measured."],
    "recommended_next_steps": ["Write the follow-up implementation ticket."],
    "mutation_attempts": [],
    "research_access": {"status": "not_used", "detail": "Only the local snapshot was read."},
}

NOTE_METADATA = {
    "title": "Scripted note title",
    "summary": "A scripted summary of the captured note.",
}


def record(entry: dict) -> None:
    if not str(STATE):
        return
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "invocations.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")


def load_plan(role: str, identifier: str | None) -> dict:
    candidates = []
    if identifier:
        candidates.append(STATE / "plans" / f"{role}.{identifier}.json")
    candidates.append(STATE / "plans" / f"{role}.json")
    for path in candidates:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
    return {}


def git(*arguments: str, cwd: str | None = None) -> str:
    environment = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Scripted Worker",
        "GIT_AUTHOR_EMAIL": "worker@contract.invalid",
        "GIT_COMMITTER_NAME": "Scripted Worker",
        "GIT_COMMITTER_EMAIL": "worker@contract.invalid",
    }
    result = subprocess.run(
        ["git", *arguments], cwd=cwd, env=environment, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(f"fake provider: git {' '.join(arguments)} failed: {result.stderr}")
    return result.stdout.strip()


class Output:
    """Provider-shaped progress lines on stdout."""

    def __init__(self, provider: str) -> None:
        self.provider = provider
        self.counter = 0

    def line(self, payload: dict) -> None:
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def raw(self, text: str) -> None:
        sys.stdout.write(text.rstrip("\n") + "\n")
        sys.stdout.flush()

    def start(self) -> None:
        if self.provider == "claude":
            self.line({"type": "system", "subtype": "init", "session_id": "scripted"})
        else:
            self.line({"type": "thread.started", "thread_id": "scripted"})

    def command(self, command: str, description: str) -> None:
        self.counter += 1
        if self.provider == "claude":
            tool_id = f"toolu_{self.counter}"
            self.line({"type": "assistant", "message": {"content": [{
                "type": "tool_use", "id": tool_id, "name": "Bash",
                "input": {"command": command, "description": description},
            }]}})
            self.line({"type": "user", "message": {"content": [{
                "type": "tool_result", "tool_use_id": tool_id, "content": "ok",
            }]}})
        else:
            item_id = f"item_{self.counter}"
            item = {"id": item_id, "type": "command_execution", "command": command}
            self.line({"type": "item.started", "item": item})
            self.line({"type": "item.completed", "item": {**item, "exit_code": 0}})

    def finish(self, text: str, *, structured: dict | None = None) -> None:
        if self.provider == "claude":
            payload = {"type": "result", "subtype": "success", "is_error": False, "result": text}
            if structured is not None:
                payload["structured_output"] = structured
            self.line(payload)
        else:
            body = json.dumps(structured) if structured is not None else text
            self.counter += 1
            self.line({"type": "item.completed", "item": {
                "id": f"item_{self.counter}", "type": "agent_message", "text": body,
            }})
            self.line({"type": "turn.completed"})


def post(url: str, payload: dict) -> tuple[int, str]:
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def first(pattern: str, text: str) -> str | None:
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1) if match else None


def classify(prompt: str) -> tuple[str, str | None]:
    """Name the role a prompt asks for, and the ticket or task it concerns."""
    if prompt.startswith("You are a relay-runner review/merge sub-agent"):
        return "review", first(r"for ticket (\S+?)\. ", prompt)
    if prompt.startswith("You are a Relay Runner research-spike worker"):
        return "spike", first(r"bounded question in ticket (\S+) and", prompt)
    if prompt.startswith("You are a relay-runner implementation worker in an isolated source worktree"):
        return "artifact-implementation", first(r"^- Ticket: \*\*(.+?)\*\*", prompt)
    if prompt.startswith("You are a relay-runner sub-agent working on a single ticket"):
        return "implementation", first(r"^- Ticket: \*\*(.+?)\*\*", prompt)
    if prompt.startswith("You are a Relay Runner General task worker"):
        return "general", first(r'^  "id": "(.+?)"', prompt)
    return "unknown", None


def set_frontmatter(markdown: str, fields: dict[str, str]) -> str:
    lines = markdown.split("\n")
    closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    for key, value in fields.items():
        rendered = f"{key}: {value}"
        for index in range(1, closing):
            if lines[index].split(":", 1)[0].strip() == key:
                lines[index] = rendered
                break
        else:
            lines.insert(closing, rendered)
            closing += 1
    return "\n".join(lines)


def role_implementation(out: Output, prompt: str, ticket_id: str, plan: dict) -> int:
    """Legacy board worker: claim, change source, mark the ticket done.

    Plan keys: `outcome` is `done` (default), `verification_blocked`,
    `no_commit` (exit 0 without touching anything) or `partial` (claim only);
    `files` maps a relative source path to its new text.
    """
    run_id = first(r"^- Run ID: (\d+)", prompt)
    attempt = first(r"^- Attempt: (\d+)", prompt)
    branch = first(r"^- Branch: `(.+?)`", prompt)
    workspace = first(r"^- Assigned worktree cwd: `(.+?)`", prompt)
    outcome = plan.get("outcome", "done")
    if os.path.realpath(os.getcwd()) != os.path.realpath(workspace or ""):
        out.raw(f"fake provider: cwd {os.getcwd()} is not {workspace}")
        return 3
    if git("branch", "--show-current") != branch:
        out.raw("fake provider: branch mismatch")
        return 3
    if outcome == "no_commit":
        out.finish("I answered without doing the work.")
        return 0

    ticket_path = Path(".orchestrator") / f"{ticket_id}.md"
    relative_ticket = ticket_path.as_posix()
    out.command(f"cat {relative_ticket}", "Read the ticket")
    ticket_path.write_text(set_frontmatter(
        ticket_path.read_text(encoding="utf-8"),
        {"status": "in_progress", "run_id": str(run_id)},
    ), encoding="utf-8")
    git("add", "--", relative_ticket)
    git("commit", "--quiet", "-m", f"chore({ticket_id}): claim run {run_id}")
    if outcome == "partial":
        out.finish("Stopped partway.")
        return 0

    files = plan.get("files") or {f"work/{ticket_id}.txt": f"implemented by run {run_id}\n"}
    for relative, text in files.items():
        target = Path(relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        git("add", "--", relative)
    out.command("swift build", "Build the project")
    git("commit", "--quiet", "-m", f"feat: implement the scripted change ({ticket_id})")

    fields = {"status": "done"}
    if outcome == "verification_blocked":
        fields = {
            "status": "verification_blocked",
            "verification_blocker": plan.get("blocker", "The staging device is unavailable."),
            "verification_resume": plan.get("resume", "Retry once the staging device is online."),
        }
    body = set_frontmatter(ticket_path.read_text(encoding="utf-8"), fields).rstrip("\n")
    body += (
        f"\n\n## Run log\n\n- **Run {run_id}** (attempt {attempt}) - branch `{branch}`\n"
        "- Applied the scripted change.\n- Ticket is done.\n"
    )
    ticket_path.write_text(body, encoding="utf-8")
    git("add", "--", relative_ticket)
    git("commit", "--quiet", "-m", f"docs({ticket_id}): run {run_id} log")
    out.finish("Ticket complete.")
    return 0


def role_artifact_implementation(out: Output, prompt: str, ticket_id: str, plan: dict) -> int:
    """Artifact-lifecycle worker: commit source only, then post one outcome.

    Plan keys: `outcome` is `completed` (default), `verification_blocked`,
    `no_outcome` (commit but never post) or `no_commit`; `files` as above;
    `payload` is merged over the posted outcome.
    """
    run_id = first(r"^- Run ID: (\d+)", prompt)
    port_file = first(r'port_path = pathlib\.Path\("(.+?)"\)', prompt)
    outcome = plan.get("outcome", "completed")
    manifest = json.loads(Path(".orchestrator/.artifact-snapshot.json").read_text(encoding="utf-8"))
    out.command(f"cat .orchestrator/{ticket_id}.md", "Read the ticket snapshot")
    if outcome != "no_commit":
        files = plan.get("files") or {f"work/{ticket_id}.txt": f"implemented by run {run_id}\n"}
        for relative, text in files.items():
            target = Path(relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
            git("add", "--", relative)
        git("commit", "--quiet", "-m", f"feat: implement the scripted change ({ticket_id})")
    if outcome == "no_outcome":
        out.finish("Stopped without reporting.")
        return 0
    head = git("rev-parse", "HEAD")
    changed = git("diff", "--name-only", manifest["source_start_head"] + ".." + head).splitlines()
    payload = {
        "status": "completed",
        "summary": f"Applied the scripted change for {ticket_id}.",
        "changed_paths": changed,
        "verification": ["scripted verification passed"],
        "source_commit": head,
    }
    if outcome == "verification_blocked":
        payload.update(
            status="verification_blocked",
            verification_blocker=plan.get("blocker", "The staging device is unavailable."),
            verification_resume=plan.get("resume", "Retry once the staging device is online."),
        )
    payload.update(plan.get("payload") or {})
    port = int(Path(port_file).read_text(encoding="utf-8").strip())
    status, body = post(f"http://127.0.0.1:{port}/v1/runs/{run_id}/outcome", payload)
    record({"event": "outcome-posted", "run_id": int(run_id), "status": status, "body": body})
    out.finish("Outcome submitted.")
    return 0


def role_review(out: Output, prompt: str, ticket_id: str, plan: dict) -> int:
    """Review worker: post the decision named by `decision` (default accept).

    `decision: none` exits without deciding. `reason` and `redispatch` apply
    to a retry decision.
    """
    url = first(r'"(http://127\.0\.0\.1:\d+/v1/runs/\d+/review/decision)"', prompt)
    decision = plan.get("decision", "accept")
    out.command("git diff --stat", "Inspect the worker branch")
    if decision == "none":
        out.finish("No decision made.")
        return 0
    payload: dict = {"decision": decision}
    if decision == "retry":
        payload["reason"] = plan.get("reason", "The scripted reviewer asked for another attempt.")
        payload["redispatch"] = bool(plan.get("redispatch", False))
    status, body = post(url, payload)
    record({"event": "decision-posted", "ticket_id": ticket_id, "status": status, "body": body})
    out.finish(f"Decision {decision} submitted.")
    return 0


def role_spike(out: Output, prompt: str, ticket_id: str, plan: dict) -> int:
    """Spike worker: return the structured result in `result`, or the default.

    `tool` names a tool the spike pretends to call first (Claude only).
    """
    if plan.get("tool") and out.provider == "claude":
        out.line({"type": "assistant", "message": {"content": [{
            "type": "tool_use", "id": "toolu_spike", "name": plan["tool"], "input": {},
        }]}})
    out.finish("Spike complete.", structured=plan.get("result", SPIKE_RESULT))
    return 0


def role_general(out: Output, prompt: str, task_id: str, plan: dict) -> int:
    """General task worker: write deliverables and result.json in the cwd.

    Plan keys: `outcome` is `complete` (default) or `no_result`.
    """
    if plan.get("outcome") == "no_result":
        out.finish("Blocked.")
        return 0
    task = json.loads(prompt[prompt.index("{"):prompt.index("\n\nWhen finished")])
    Path("output.md").write_text(f"# {task['title']}\n\nScripted deliverable.\n", encoding="utf-8")
    Path("result.json").write_text(json.dumps({
        "summary": "Wrote the scripted deliverable.",
        "criteria": [
            {"criterion": criterion, "evidence": "Covered by output.md."}
            for criterion in task["acceptance_criteria"]
        ],
        "artifacts": ["output.md"],
    }), encoding="utf-8")
    out.finish("General task complete.")
    return 0


ROLES = {
    "implementation": role_implementation,
    "artifact-implementation": role_artifact_implementation,
    "review": role_review,
    "spike": role_spike,
    "general": role_general,
}


def wait_for_hold(plan: dict) -> None:
    hold = plan.get("hold")
    while hold and not Path(hold).exists():
        time.sleep(0.05)


def run_worker(provider: str, argv: list[str]) -> int:
    prompt = sys.stdin.read()
    role, identifier = classify(prompt)
    plan = load_plan(role, identifier)
    record({
        "event": "launch", "provider": provider, "argv": argv, "cwd": os.getcwd(),
        "role": role, "id": identifier, "pid": os.getpid(),
        "relay_environment": sorted(key for key in os.environ if key.startswith("RELAY_")),
    })
    wait_for_hold(plan)
    out = Output(provider)
    out.start()
    for event in plan.get("events", []):
        out.raw(event if isinstance(event, str) else json.dumps(event, separators=(",", ":")))
    handler = ROLES.get(role)
    if handler is None:
        out.raw(f"fake provider: unrecognised prompt: {prompt[:80]!r}")
        return 2
    status = handler(out, prompt, identifier or "", plan)
    return int(plan.get("exit_code", status))


def note_metadata(provider: str, argv: list[str]) -> int:
    payload = sys.stdin.read()
    plan = load_plan("note-metadata", None)
    record({"event": "launch", "provider": provider, "argv": argv, "cwd": os.getcwd(),
            "role": "note-metadata", "id": None, "pid": os.getpid(),
            "stdin_keys": sorted(json.loads(payload)) if payload.strip().startswith("{") else []})
    wait_for_hold(plan)
    fields = plan.get("result", NOTE_METADATA)
    if provider == "claude":
        sys.stdout.write(json.dumps({"type": "result", "is_error": False, "structured_output": fields}))
    else:
        target = argv[argv.index("--output-last-message") + 1]
        Path(target).write_text(json.dumps(fields), encoding="utf-8")
    return int(plan.get("exit_code", 0))


def codex_app_server(argv: list[str]) -> int:
    record({"event": "launch", "provider": "codex", "argv": argv, "cwd": os.getcwd(),
            "role": "app-server", "id": None, "pid": os.getpid()})
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if "id" not in message:
            continue
        if message.get("method") == "initialize":
            result: dict = {"userAgent": "scripted-codex"}
        elif message.get("method") == "model/list":
            result = CODEX_MODELS
        else:
            result = {}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
        sys.stdout.flush()
    return 0


def main() -> int:
    provider, argv = sys.argv[1], sys.argv[2:]
    if provider == "claude":
        if argv[:2] == ["auth", "status"]:
            plan = load_plan("auth", None)
            record({"event": "launch", "provider": provider, "argv": argv, "cwd": os.getcwd(),
                    "role": "auth", "id": None, "pid": os.getpid()})
            sys.stdout.write(json.dumps(plan.get("status") or {
                "loggedIn": True, "authMethod": "claude.ai",
                "apiProvider": "firstParty", "subscriptionType": "max",
            }))
            return 0
        if "--print" in argv and "--json-schema" in argv and "--system-prompt" in argv:
            return note_metadata(provider, argv)
        return run_worker(provider, argv)
    if "app-server" in argv:
        return codex_app_server(argv)
    if argv[-2:] == ["login", "status"]:
        plan = load_plan("auth", None)
        record({"event": "launch", "provider": provider, "argv": argv, "cwd": os.getcwd(),
                "role": "auth", "id": None, "pid": os.getpid()})
        sys.stdout.write(plan.get("login_status", "Logged in using ChatGPT") + "\n")
        return 0
    if "--output-last-message" in argv:
        return note_metadata(provider, argv)
    return run_worker(provider, argv)


if __name__ == "__main__":
    sys.exit(main())
